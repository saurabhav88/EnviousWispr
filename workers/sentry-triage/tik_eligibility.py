#!/usr/bin/env python3
"""TIK reopen/severity eligibility gate (issue #1143).

Pure decision function for the TIK Sentry-triage routine. Given the post-close
event set for a closed fingerprint plus the fix-version boundary, decide whether
a recurrence is a real regression (reopen), pre-fix-tail noise (hold), or
unprovable (ambiguous -> fail open).

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


def main(argv=None) -> int:
    try:
        raw = sys.stdin.read()
        data = json.loads(raw)
        result = decide(data)
    except Exception as exc:  # noqa: BLE001 -- fail OPEN on any helper error
        result = _out("ambiguous", f"helper error: {type(exc).__name__}: {exc}")
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
