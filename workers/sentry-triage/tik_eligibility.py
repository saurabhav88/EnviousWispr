#!/usr/bin/env python3
"""TIK Sentry-triage eligibility gates (issue #1143 reopen, #1218 create).

Two pure decision functions for the TIK Sentry-triage routine, sharing the
`is_development()` dev-detector and a fail-open philosophy (anything unprovable
stays VISIBLE, never silently suppressed):
  - `decide()` (#1143) -- the REOPEN gate. Given the post-close event set for a
    closed fingerprint plus the fix-version boundary, decide whether a recurrence is
    a real regression (reopen), pre-fix-tail noise (hold), or unprovable (ambiguous).
  - `decide_create()` (#1218) -- the CREATE gate. Given the event list for a NEW
    fingerprint that has no GitHub issue, decide whether it becomes a ticket (create),
    is deliberate fault-injection noise (suppress), or is a dev-only self-healed error
    to list in the run digest (digest). See its own docstring for the branch order.

DESIGN INVARIANTS (council 2026-06-21, 2 rounds; Codex grounded review 3 rounds):
  - HOLD requires PROOF. Anything we cannot prove benign fails OPEN (ambiguous ->
    the routine reopens or files visible triage). We never silently suppress.
  - Severity is scored on the ELIGIBLE partition (post-close, production, on a
    release that actually contains the fix), never the Sentry lifetime aggregate.
  - Dev/dogfood events never count toward customer severity, but a dev build that
    DOES contain the fix is kept as an early-warning canary.
  - This module does NO network and NO git. The routine resolves the fix boundary
    (stamp or local-git-only derivation) and the event list, then pipes JSON here.
    Keeping it pure is what makes the gate unit-testable before it ships.

Input (JSON on stdin): see EXPECTED_INPUT_SHAPE below.
Output (JSON on stdout): {"verdict", "family", "reason", "eligible_user_count",
  "eligible_count", "excluded_dev_count", "observed_production_releases",
  "dev_canary"}.
On any internal error: prints an `ambiguous` verdict (fail open) and exits 0, so a
helper bug can never become a silent hold.
"""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone

EXPECTED_INPUT_SHAPE = {
    "events": "list of {release, environment, build_type, user_id, dateCreated}",
    "closed_at": "ISO8601 string",
    "close_class": "fixed|fixed-merged-unreleased|telemetry-noise|not-a-bug|by-design|duplicate|unknown",
    "fix_released_version": "vX.Y.Z or null",
    "fix_merged": "bool (true ONLY when the fix commit is proven present + ancestor of main)",
    "latest_release": "vX.Y.Z (current shipped release)",
    "events_truncated": "bool (true if the caller could NOT read every Sentry events page). "
                        "A HOLD that asserts 'all events are pre-fix/dev/none' is unsafe when "
                        "events may be missing -> downgrade those holds to ambiguous (fail open).",
}

# Every verdict that SUPPRESSES a customer reopen (does not reopen, does not route
# to a canonical). Each of these is only valid on complete, trustworthy input -- a
# truncated page or a malformed/missing field could hide a real regression, so any of
# them must fail OPEN (downgrade to ambiguous) when input completeness is in doubt.
# `hold-nonbug` is included: even a human "not a bug" close relies on the model being
# able to spot a NEW signature in the events, which it cannot do on broken/partial data.
# (route-to-canonical is excluded -- it is close-class-driven and events-independent.)
_HOLD_VERDICTS = {"hold-prefix-tail", "hold-nonbug", "hold-dev-only",
                  "no-postclose-activity", "dev-canary-postfix"}

# Verdict -> action family. The routine branches on `family`.
#   reopen   : reopen the issue (regression). Severity from eligible counts.
#   hold     : leave closed; post a throttled audit comment.
#   ambiguous: FAIL OPEN -- reopen + `unverified-regression`, never silent.
#   route    : duplicate -> apply policy on the canonical issue, never the dup.
#   canary   : do not reopen for customers; internal early-warning note only.
VERDICT_FAMILY = {
    "reopen-eligible": "reopen",
    "ambiguous": "ambiguous",
    "hold-prefix-tail": "hold",
    "hold-nonbug": "hold",
    "hold-dev-only": "hold",
    "no-postclose-activity": "hold",
    "dev-canary-postfix": "canary",
    "route-to-canonical": "route",
}

# STRICT: MAJOR.MINOR.PATCH (no leading zeros) followed by ONLY end-of-string,
# +buildmeta, or our dev suffix (-N-gHASH[-dev] / -dev). Anything else (prerelease
# like -beta.1, a 4th component like .1) -> no match -> None -> relation unknown ->
# fail open. (Lenient parsing of a weird production version could mis-class -> hold.)
_SEMVER_RE = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:\+[0-9A-Za-z.\-]+|-\d+-g[0-9a-f]+(?:-dev)?|-dev)?$",
    re.IGNORECASE,
)
_DEV_SUFFIX_RE = re.compile(r"-\d+-g[0-9a-f]+", re.IGNORECASE)

DOCUMENTED_CLASSES = {
    "fixed", "fixed-merged-unreleased", "telemetry-noise",
    "not-a-bug", "by-design", "duplicate", "unknown",
}


def normalize_version(release: str | None):
    """Strip bundle prefix / leading v -> (major, minor, patch) or None (strict).

    Accepts: 'com.enviouswispr.app@2.1.0' -> (2,1,0); 'v2.1.10' -> (2,1,10);
    'com.enviouswispr.app@2.0.3-4-gabcdef-dev' -> (2,0,3); '2.1.0+build45' -> (2,1,0).
    Rejects (-> None -> unknown -> fail open): '2.1.5-beta.1', '2.1.5.1', '02.001.004'.
    """
    if not release or not isinstance(release, str):
        return None
    tail = release.split("@", 1)[1] if "@" in release else release
    tail = tail.strip()
    if tail[:1] in ("v", "V"):
        tail = tail[1:]
    m = _SEMVER_RE.match(tail)
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)))


def is_development(event: dict) -> bool:
    """Dev/dogfood if build_type=debug, environment=development, or a -dev/-N-g release.

    app.build_type is the authoritative signal; environment + release suffix back it up.
    """
    bt = (event.get("build_type") or "").lower()
    if bt == "debug":
        return True
    if bt == "release":
        # explicit production build; release-suffix heuristic below is a backstop only
        env = (event.get("environment") or "").lower()
        rel = event.get("release") or ""
        return "development" in env or "-dev" in rel.lower() or bool(_DEV_SUFFIX_RE.search(rel))
    env = (event.get("environment") or "").lower()
    rel = event.get("release") or ""
    if "development" in env:
        return True
    if "-dev" in rel.lower() or _DEV_SUFFIX_RE.search(rel):
        return True
    return False


def _parse_iso(ts: str | None):
    """ISO8601 -> aware datetime, or None if unparseable.

    Must be a real datetime parse, NOT a string compare: Sentry stamps fractional
    seconds ('...06:00:00.500Z') while GitHub closed_at is whole seconds
    ('...06:00:00Z'), and lexicographically '.' < 'Z' would wrongly sort the
    fractional event BEFORE the close, dropping a real post-close event.
    """
    if not ts or not isinstance(ts, str):
        return None
    t = ts.strip()
    if t.endswith("Z"):
        t = t[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(t)
    except ValueError:
        return None
    # A NAIVE timestamp (no tz) is NOT proof — assuming UTC could drop a real
    # post-close event recorded in another offset. Reject -> caller fails open.
    return dt if dt.tzinfo is not None else None


def _as_bool(v) -> bool:
    """Strict truthiness for shell-built JSON: only real `true` / "true" is True.

    bool("false") is True in Python, so a string boolean from the shell would wrongly
    'prove' a fix merged and silently hold. Anything not provably true -> False, which
    is the fail-OPEN direction (unproven -> ambiguous -> reopen)."""
    if v is True:
        return True
    if isinstance(v, str):
        return v.strip().lower() == "true"
    return False


def is_post_close(event: dict, closed_at_key) -> bool:
    """Post-close if dateCreated > closed_at. Unparseable timestamp => INCLUDE
    (conservative: never silently drop potential evidence)."""
    if closed_at_key is None:
        return True
    ek = _parse_iso(event.get("dateCreated"))
    if ek is None:
        return True
    return ek > closed_at_key


def classify_relation(event: dict, fix_released_version, fix_merged: bool,
                       latest_release=None) -> str:
    """pre-fix | post-fix | unknown for a single production event."""
    ev = normalize_version(event.get("release"))
    if ev is None:
        return "unknown"
    if fix_released_version is not None:
        fv = normalize_version(fix_released_version)
        if fv is None:
            return "unknown"
        return "post-fix" if ev >= fv else "pre-fix"
    # No released version known. A PROVEN merged-but-unreleased fix means every
    # release <= the latest tag we know about is pre-fix. BUT an event on a build
    # NEWER than `latest_release` (stale/shallow tag fetch, or an untagged newer
    # build) might be on a release that SHIPPED the fix since -- we cannot prove it
    # pre-fix, so it is unknown -> fail open. (fix_merged is set true only after the
    # routine proved the commit exists + is an ancestor of main -- see plan 3.2.)
    if fix_merged:
        lr = normalize_version(latest_release)
        if lr is None:
            return "unknown"          # no trustworthy ceiling -> cannot prove pre-fix
        return "pre-fix" if ev <= lr else "unknown"
    return "unknown"


def _inputs_incomplete(data: dict) -> str | None:
    """Return a reason string if inputs cannot support a PROVABLE hold, else None.

    A hold asserts 'we saw every post-close event and none is post-fix'. That proof
    collapses if we can't trust the close boundary or the event timestamps. Any such
    gap must fail OPEN (downgrade holds to ambiguous), never silently hold.
    """
    if _parse_iso(data.get("closed_at")) is None:
        return "closed_at missing/invalid/naive (no tz)"
    events = data.get("events")
    if not isinstance(events, list):
        return "events not provided as a list (missing fetch != no activity)"
    for e in events:
        if not isinstance(e, dict) or _parse_iso(e.get("dateCreated")) is None:
            return "an event has a missing/invalid/naive dateCreated"
    return None


def decide(data: dict) -> dict:
    result = _decide_inner(data)
    # A hold is only valid if we saw every post-close event AND can trust the
    # boundary/timestamps. Truncated pages OR incomplete/untrustworthy inputs
    # both defeat that proof -> downgrade any hold-family verdict to ambiguous.
    if result["verdict"] in _HOLD_VERDICTS:
        reason = None
        if _as_bool(data.get("events_truncated")):
            reason = "event list truncated (unread pages)"
        else:
            reason = _inputs_incomplete(data)
        if reason:
            return _out("ambiguous",
                        f"cannot prove '{result['verdict']}' ({reason}); a hidden/post-fix "
                        f"event could be a real regression -> fail open",
                        excluded_dev_count=result.get("excluded_dev_count", 0),
                        observed=result.get("observed_production_releases", []),
                        dev_canary=result.get("dev_canary", {}))
    return result


def _decide_inner(data: dict) -> dict:
    close_class = (data.get("close_class") or "unknown").strip().lower()
    if close_class not in DOCUMENTED_CLASSES:
        close_class = "unknown"  # malformed/unrecognized class -> treat as unknown
    fix_released = data.get("fix_released_version")
    fix_merged = _as_bool(data.get("fix_merged"))
    latest_release = data.get("latest_release")
    closed_at_key = _parse_iso(data.get("closed_at"))
    events = data.get("events") if isinstance(data.get("events"), list) else []

    # 1. Duplicate: never reopen the dup; route to canonical.
    if close_class == "duplicate":
        return _out("route-to-canonical",
                    "closed as duplicate; apply recurrence policy on the canonical issue")

    # Partition post-close events by channel.
    post = [e for e in events if is_post_close(e, closed_at_key)]
    prod = [e for e in post if not is_development(e)]
    dev = [e for e in post if is_development(e)]
    excluded_dev_count = len(dev)

    # A fix-containing dogfood build still emitting is an early-warning canary,
    # surfaced even when production is a clean pre-fix tail (computed up front so
    # the prefix-tail return below does not hide it).
    dev_postfix = [e for e in dev
                   if classify_relation(e, fix_released, fix_merged, latest_release) == "post-fix"]
    canary = {"count": len(dev_postfix)} if dev_postfix else {}

    # 2. Closed not-a-bug / by-design: volume never reopens. A materially new
    #    signature can escalate, but that is the model's judgment, not this gate.
    if close_class in ("not-a-bug", "by-design"):
        return _out("hold-nonbug",
                    "closed as not-a-bug/by-design; volume growth alone does not reopen",
                    excluded_dev_count=excluded_dev_count, dev_canary=canary)

    # 3. Production relation partition.
    prod_rel = [(e, classify_relation(e, fix_released, fix_merged, latest_release)) for e in prod]
    observed = _summarize_releases(prod_rel)

    has_postfix = any(r == "post-fix" for _, r in prod_rel)
    has_unknown = any(r == "unknown" for _, r in prod_rel)

    if has_postfix:
        eligible = [e for e, r in prod_rel if r == "post-fix"]
        return _out("reopen-eligible",
                    "production event(s) on a release that contains the fix",
                    eligible_user_count=_distinct_users(eligible),
                    eligible_count=len(eligible),
                    excluded_dev_count=excluded_dev_count,
                    observed=observed, dev_canary=canary)

    if has_unknown:
        # Cannot prove pre-fix for at least one production event -> fail open.
        return _out("ambiguous",
                    "production event(s) with an unresolvable release relation; fail open",
                    excluded_dev_count=excluded_dev_count, observed=observed, dev_canary=canary)

    if prod_rel:  # non-empty and all pre-fix
        return _out("hold-prefix-tail",
                    "all post-close production events are on pre-fix releases",
                    excluded_dev_count=excluded_dev_count, observed=observed,
                    dev_canary=canary)

    # 4. No post-close PRODUCTION events. Consider the dev canary.
    if dev_postfix:
        return _out("dev-canary-postfix",
                    "fix-containing dev/dogfood build still emits; internal early warning",
                    excluded_dev_count=excluded_dev_count, dev_canary=canary)
    if dev:
        return _out("hold-dev-only",
                    "only dev/dogfood events post-close; no customer-facing signal",
                    excluded_dev_count=excluded_dev_count)

    # 5. Nothing fired post-close at all -> no regression to act on (provably safe).
    return _out("no-postclose-activity",
                "no post-close events (production or dev); not a recurrence")


def _summarize_releases(prod_rel):
    agg = {}
    for e, r in prod_rel:
        rel = e.get("release") or "unknown"
        a = agg.setdefault(rel, {"release": rel, "relation": r, "users": set(), "count": 0})
        a["count"] += 1
        uid = e.get("user_id")
        if uid:
            a["users"].add(uid)
    return [{"release": a["release"], "relation": a["relation"],
             "users": len(a["users"]), "count": a["count"]} for a in agg.values()]


def _distinct_users(events) -> int:
    """Distinct eligible users, counting each null/missing user_id as its OWN user.

    Severity must never be under-scored: 10 eligible events with null user_id could be
    10 distinct people, so counting them as 0 would hide a P0. Over-counting (treating
    each anonymous event as distinct) is the safe direction for severity.
    """
    known = {e.get("user_id") for e in events if e.get("user_id")}
    anon = sum(1 for e in events if not e.get("user_id"))
    return len(known) + anon


def _out(verdict, reason, eligible_user_count=0, eligible_count=0,
         excluded_dev_count=0, observed=None, dev_canary=None):
    return {
        "verdict": verdict,
        "family": VERDICT_FAMILY[verdict],
        "reason": reason,
        "eligible_user_count": eligible_user_count,
        "eligible_count": eligible_count,
        "excluded_dev_count": excluded_dev_count,
        "observed_production_releases": observed or [],
        "dev_canary": dev_canary or {},
    }


# ---- create-path decision (issue #1218) ------------------------------------
#
# Path A of the routine (a brand-new Sentry fingerprint with no GitHub issue) had
# NO environment gate -- it created a ticket for every new fingerprint, so dev-only,
# self-healed, single-event errors from the founder's dogfood machine became tracked
# issues (#1192-#1215). `decide_create` is the create-path sibling of `decide()`. It
# deliberately does NOT reuse `decide()`: that one is reopen-shaped (built around
# closed_at + post-close partitioning); a create decision has no close boundary and a
# different question ("should this exist at all"). Both share the `is_development()`
# dev-detector -- the single authority for "is this dev" -- and the same fail-open
# philosophy: anything we cannot PROVE is dev-only-and-self-healed becomes a VISIBLE
# create, never a silent drop.

# Create-path verdict -> action family. The routine Path A branches on `family`.
#   create  : file the GitHub issue (real production signal, untagged dev fatal, or
#             fail-open on unclassifiable input).
#   suppress: do NOT file; deliberate fault-injection noise (every event synthetic).
#   digest  : do NOT file; list the fingerprint in the run-summary DEV_DIGEST so the
#             founder still sees it at a glance (the dev-only self-healed class).
CREATE_VERDICT_FAMILY = {
    "create": "create",
    "create-dev-fatal": "create",
    "suppress-synthetic": "suppress",
    "digest-dev-only": "digest",
}

# Create-path verdicts that SUPPRESS a ticket (do not create). On a truncated event
# list (the fetch hit the page cap with more pages pending) a hidden later page could
# carry a real production/fatal event, so any of these must fail OPEN (downgrade to
# create) when `events_truncated` is set -- mirrors the reopen gate's `_HOLD_VERDICTS`.
_CREATE_SUPPRESSING_VERDICTS = {"suppress-synthetic", "digest-dev-only"}


def _effective_level(event: dict, issue_level) -> str | None:
    """Per-event `level`, falling back to the issue/latest-event level Path A reads.

    Returns the lowercased level string, or None when neither is present/usable. None
    means 'cannot classify' -> the caller fails OPEN to create, never digests."""
    for src in (event.get("level"), issue_level):
        if isinstance(src, str) and src.strip():
            return src.strip().lower()
    return None


def decide_create(data: dict) -> dict:
    """Create-path eligibility gate (#1218): should a NEW fingerprint become a ticket?

    Input (JSON): {events: [{environment, build_type, release, level, synthetic,
    user_id, dateCreated}], issue_level, events_truncated}. `issue_level` is the
    aggregate/latest-event level Path A severity already reads -- the per-event `level`
    fallback. Operates over the event LIST (not a scalar) so a multi-event fingerprint
    partitions correctly. Output: {verdict, family, reason, dev_count, event_count};
    family in {create, suppress, digest}. Fails OPEN (create) on empty/unclassifiable
    input AND on a truncated event list (unread pages could hide a real event).
    """
    result = _decide_create_inner(data)
    # A digest/suppress decision is only valid on a PROVABLY COMPLETE event list. The
    # `events_truncated` flag is REQUIRED on the input and is this gate's ONLY
    # completeness signal -- unlike the reopen gate, which ALSO has _inputs_incomplete
    # (closed_at + per-event timestamps) as a second guard. So treat a MISSING flag as
    # "not proven complete" (default True) and downgrade any suppressing verdict to a
    # visible create, exactly as an explicit `events_truncated=true` does. A hidden
    # later page could carry a production or fatal event; fail open, never silent-suppress.
    if (result["verdict"] in _CREATE_SUPPRESSING_VERDICTS
            and _as_bool(data.get("events_truncated", True))):
        return _out_create(
            "create",
            f"cannot {result['family']} on a truncated event list "
            f"(unread pages could hide a production/fatal event); fail open",
            dev_count=result.get("dev_count", 0),
            event_count=result.get("event_count", 0))
    return result


def _decide_create_inner(data: dict) -> dict:
    events = data.get("events") if isinstance(data.get("events"), list) else []
    issue_level = data.get("issue_level")

    # No events (empty list / missing fetch / unparseable) -> fail OPEN to create.
    # Never silently drop a potential real issue (mirrors the reopen gate's invariant).
    if not events:
        return _out_create("create",
                           "no events to classify (empty / missing / fetch failure); fail open")

    dev = [e for e in events if is_development(e)]

    # 1. Any production (non-dev) event -> create. Real customer signal; create as today.
    if len(dev) < len(events):
        return _out_create("create",
                           "at least one production event; real signal, create as today",
                           dev_count=len(dev), event_count=len(events))

    # All events are dev from here. A `synthetic=true` event is a DELIBERATE
    # fault-injection test -- it never justifies a ticket, so exclude every synthetic
    # event from the dev signal and classify on the non-synthetic remainder. Excluding
    # here (not just in the all-synthetic branch) is what stops a tagged synthetic fatal
    # mixed with an untagged handled error from creating a ticket for a crash test
    # (Codex #1218 review).
    nonsynthetic = [e for e in events if not _as_bool(e.get("synthetic"))]

    # 2. Every event synthetic (no real signal left) -> suppress. Deliberate test noise.
    if not nonsynthetic:
        return _out_create("suppress-synthetic",
                           "all events dev and synthetic=true (deliberate fault-injection test)",
                           dev_count=len(dev), event_count=len(events))

    # The issue/latest-event level fallback is EXACT only for a single-event fingerprint
    # (latest == the only event). In a multi-event list, copying the latest level onto a
    # DIFFERENT event whose own level is missing could mask a fatal -> allow the fallback
    # only when the whole list is one event; otherwise a missing per-event level is
    # unclassifiable (None) and fails open at branch 5 (Codex #1218 review).
    allow_level_fallback = len(events) == 1
    levels = [_effective_level(e, issue_level if allow_level_fallback else None)
              for e in nonsynthetic]

    # 3. A non-synthetic (untagged) dev fatal -> create (dev canary). An untagged dev
    #    crash could be a real new-crash; fail toward visible. Synthetic fatals were
    #    excluded above, so this catches only genuine dev crashes.
    if any(lvl == "fatal" for lvl in levels):
        return _out_create("create-dev-fatal",
                           "untagged dev fatal; a real dev crash is canary-worthy, create",
                           dev_count=len(dev), event_count=len(events))

    # 4. All non-synthetic dev events are handled errors -> digest. The #1192-#1215
    #    class: handled, self-healed, no customer signal. No ticket.
    if all(lvl == "error" for lvl in levels):
        return _out_create("digest-dev-only",
                           "all-dev handled error, self-healed, no customer signal; digest not ticket",
                           dev_count=len(dev), event_count=len(events))

    # 5. The non-synthetic level set is not provably all-handled-error (mixed / warning /
    #    info / unknown) -> fail OPEN to create. We stay silent ONLY when we can PROVE
    #    the dev-only-self-healed class; anything else stays visible.
    return _out_create("create",
                       "dev events but level set not provably all-handled-error; fail open",
                       dev_count=len(dev), event_count=len(events))


def _out_create(verdict, reason, dev_count=0, event_count=0):
    return {
        "verdict": verdict,
        "family": CREATE_VERDICT_FAMILY[verdict],
        "reason": reason,
        "dev_count": dev_count,
        "event_count": event_count,
    }


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    create_mode = "--create" in argv  # default (no flag) stays the reopen gate -> decide()
    try:
        raw = sys.stdin.read()
        data = json.loads(raw)
        result = decide_create(data) if create_mode else decide(data)
    except Exception as exc:  # noqa: BLE001 -- fail OPEN on any helper error
        # Fail-open shape differs per gate: reopen -> ambiguous (visible reopen),
        # create -> create (visible new ticket). Neither can become a silent drop.
        result = (_out_create("create", f"helper error: {type(exc).__name__}: {exc}")
                  if create_mode
                  else _out("ambiguous", f"helper error: {type(exc).__name__}: {exc}"))
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
