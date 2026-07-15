#!/usr/bin/env python3
"""Unit tests for tik_eligibility.decide (issue #1143).

Run: python3 -m pytest workers/sentry-triage/test_tik_eligibility.py
  or: python3 workers/sentry-triage/test_tik_eligibility.py   (self-runner, no pytest dep)

Each test is one council/Codex validation case. The whole point of this file is
that the reopen/hold/ambiguous boundary is PROVABLE before the gate ships to an
unattended daily cron.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tik_eligibility import (  # noqa: E402
    decide, decide_create, normalize_version, is_development, main,
)

CLOSED = "2026-06-17T06:00:00Z"


def ev(release, *, env="production", build="release", user="u1", when="2026-06-20T00:00:00Z"):
    return {"release": release, "environment": env, "build_type": build,
            "user_id": user, "dateCreated": when}


# ---- normalize_version ------------------------------------------------------

def test_normalize_strips_bundle_and_v():
    assert normalize_version("com.enviouswispr.app@2.1.0") == (2, 1, 0)
    assert normalize_version("v2.1.10") == (2, 1, 10)
    assert normalize_version("2.1.0+build45") == (2, 1, 0)
    assert normalize_version("com.enviouswispr.app@2.0.3-4-gabcdef-dev") == (2, 0, 3)


def test_normalize_ordering_two_digit():
    # 2.1.10 must sort ABOVE 2.1.9 (numeric, not lexical)
    assert normalize_version("2.1.10") > normalize_version("2.1.9")


def test_normalize_unparseable_is_none():
    assert normalize_version("garbage") is None
    assert normalize_version("") is None
    assert normalize_version(None) is None


def test_is_development_signals():
    assert is_development(ev("x@2.1.0", build="debug")) is True
    assert is_development(ev("x@2.1.0", env="development")) is True
    assert is_development(ev("com.enviouswispr.app@2.0.3-4-gabcdef-dev")) is True
    assert is_development(ev("com.enviouswispr.app@2.1.0")) is False


# ---- council validation cases ----------------------------------------------

def test_case1_merged_but_unreleased_all_prefix_holds():
    # The #979 case: fix merged, in no release; all prod events on pre-fix builds.
    out = decide({"events": [ev("com.enviouswispr.app@2.1.0"), ev("com.enviouswispr.app@2.1.4", user="u2")],
                  "closed_at": CLOSED, "close_class": "telemetry-noise",
                  "fix_released_version": None, "fix_merged": True, "latest_release": "v2.1.4"})
    assert out["verdict"] == "hold-prefix-tail"
    assert out["family"] == "hold"


def test_case2_fixed_release_regression_reopens():
    out = decide({"events": [ev("v2.1.5")],
                  "closed_at": CLOSED, "close_class": "fixed",
                  "fix_released_version": "v2.1.5", "fix_merged": True, "latest_release": "v2.1.5"})
    assert out["verdict"] == "reopen-eligible"
    assert out["eligible_user_count"] == 1


def test_case3_mixed_prefix_and_postfix_reopens_eligible_counts_postfix_only():
    events = [ev("v2.1.0", user=f"old{i}") for i in range(100)] + [ev("v2.1.5", user="new1")]
    out = decide({"events": events, "closed_at": CLOSED, "close_class": "fixed",
                  "fix_released_version": "v2.1.5", "fix_merged": True, "latest_release": "v2.1.5"})
    assert out["verdict"] == "reopen-eligible"
    # eligible counts ONLY the post-fix event, not the 100 pre-fix
    assert out["eligible_user_count"] == 1
    assert out["eligible_count"] == 1


def test_case4_dev_only_spike_excluded_no_customer_severity():
    # The #440 case: hundreds of events, one dev user.
    events = [ev("com.enviouswispr.app@2.0.3-4-gabcdef-dev", build="debug",
                 env="development", user="founder") for _ in range(259)]
    out = decide({"events": events, "closed_at": CLOSED, "close_class": "unknown",
                  "fix_released_version": None, "fix_merged": False, "latest_release": "v2.1.4"})
    assert out["family"] == "hold"
    assert out["verdict"] == "hold-dev-only"
    assert out["excluded_dev_count"] == 259
    assert out["eligible_user_count"] == 0


def test_case5_dogfood_build_with_fix_is_canary():
    out = decide({"events": [ev("v2.1.5-2-gabc123-dev", build="debug", env="development", user="founder")],
                  "closed_at": CLOSED, "close_class": "fixed",
                  "fix_released_version": "v2.1.5", "fix_merged": True, "latest_release": "v2.1.5"})
    assert out["verdict"] == "dev-canary-postfix"
    assert out["family"] == "canary"


def test_case6_notabug_volume_growth_holds():
    events = [ev("v2.1.4", user=f"u{i}") for i in range(20)]
    out = decide({"events": events, "closed_at": CLOSED, "close_class": "not-a-bug",
                  "fix_released_version": None, "fix_merged": False, "latest_release": "v2.1.4"})
    assert out["verdict"] == "hold-nonbug"


def test_case7_duplicate_routes_to_canonical():
    out = decide({"events": [ev("v2.1.4")], "closed_at": CLOSED, "close_class": "duplicate",
                  "fix_released_version": None, "fix_merged": False, "latest_release": "v2.1.4"})
    assert out["verdict"] == "route-to-canonical"
    assert out["family"] == "route"


def test_case8_unknown_close_current_release_event_fails_open():
    # No fix info at all + a production event we can't classify -> ambiguous.
    # #1431 (2026-07-15): family is manual-review, NOT reopen -- uncertainty stays
    # visible but must never mutate a closed issue's state on its own.
    out = decide({"events": [ev("v2.1.4")], "closed_at": CLOSED, "close_class": "unknown",
                  "fix_released_version": None, "fix_merged": False, "latest_release": "v2.1.4"})
    assert out["verdict"] == "ambiguous"
    assert out["family"] == "manual-review"


def test_reopen_eligible_family_is_reopen_not_auto_reopen():
    # #1431: reopen-eligible still means "release-eligible for consideration" --
    # the family name is unchanged; the routine (not this pure gate) decides
    # whether to actually reopen by comparing disposition against prior evidence.
    out = decide({"events": [ev("v2.1.5")], "closed_at": CLOSED, "close_class": "fixed",
                  "fix_released_version": "v2.1.5", "fix_merged": True, "latest_release": "v2.1.5"})
    assert out["verdict"] == "reopen-eligible"
    assert out["family"] == "reopen"


def test_case9_malformed_release_never_prefix():
    out = decide({"events": [ev("not-a-version")], "closed_at": CLOSED, "close_class": "fixed",
                  "fix_released_version": "v2.1.5", "fix_merged": True, "latest_release": "v2.1.5"})
    # unparseable production release -> unknown relation -> ambiguous, never pre-fix/hold
    assert out["verdict"] == "ambiguous"


def test_case10_semver_normalization_postfix():
    out = decide({"events": [ev("com.enviouswispr.app@2.1.10")],
                  "closed_at": CLOSED, "close_class": "fixed",
                  "fix_released_version": "v2.1.9", "fix_merged": True, "latest_release": "v2.1.10"})
    assert out["verdict"] == "reopen-eligible"  # 2.1.10 >= 2.1.9


def test_case11_empty_events_no_activity_holds_safely():
    out = decide({"events": [], "closed_at": CLOSED, "close_class": "fixed",
                  "fix_released_version": "v2.1.5", "fix_merged": True, "latest_release": "v2.1.5"})
    assert out["verdict"] == "no-postclose-activity"
    assert out["family"] == "hold"


def test_case12_preclose_events_ignored():
    out = decide({"events": [ev("v2.1.5", when="2026-06-01T00:00:00Z")],  # before CLOSED
                  "closed_at": CLOSED, "close_class": "fixed",
                  "fix_released_version": "v2.1.5", "fix_merged": True, "latest_release": "v2.1.5"})
    # the only event predates the close -> no post-close activity
    assert out["verdict"] == "no-postclose-activity"


# ---- fail-open guards (the Codex round-2/3 defect class) --------------------

def test_fix_merged_false_with_no_release_is_unknown_not_prefix():
    # If the routine could NOT prove the commit (fix_merged=False, fix_released=None),
    # a production event must NOT be classed pre-fix/hold -> ambiguous (fail open).
    out = decide({"events": [ev("v2.1.0")], "closed_at": CLOSED, "close_class": "fixed",
                  "fix_released_version": None, "fix_merged": False, "latest_release": "v2.1.4"})
    assert out["verdict"] == "ambiguous"


def test_unparseable_timestamp_included_not_dropped():
    out = decide({"events": [ev("v2.1.5", when="not-a-date")],
                  "closed_at": CLOSED, "close_class": "fixed",
                  "fix_released_version": "v2.1.5", "fix_merged": True, "latest_release": "v2.1.5"})
    # bad timestamp is conservatively treated as post-close -> the event still counts
    assert out["verdict"] == "reopen-eligible"


def test_helper_errors_fail_open_via_cli():
    # Malformed stdin must yield ambiguous (fail open), exit 0.
    proc = subprocess.run([sys.executable, str(Path(__file__).resolve().parent / "tik_eligibility.py")],
                          input="not json", capture_output=True, text=True)
    assert proc.returncode == 0
    assert json.loads(proc.stdout)["verdict"] == "ambiguous"


def test_truncated_events_downgrade_hold_to_ambiguous():
    # A prefix-tail hold is unsafe if we could not read every page -> fail open.
    base = {"events": [ev("v2.1.0")], "closed_at": CLOSED, "close_class": "telemetry-noise",
            "fix_released_version": None, "fix_merged": True, "latest_release": "v2.1.4"}
    assert decide({**base, "events_truncated": False})["verdict"] == "hold-prefix-tail"
    assert decide({**base, "events_truncated": True})["verdict"] == "ambiguous"


def test_truncated_does_not_downgrade_reopen():
    # reopen-eligible already reopens -> truncation is irrelevant.
    reopen = decide({"events": [ev("v2.1.5")], "closed_at": CLOSED, "close_class": "fixed",
                     "fix_released_version": "v2.1.5", "fix_merged": True,
                     "latest_release": "v2.1.5", "events_truncated": True})
    assert reopen["verdict"] == "reopen-eligible"


def test_truncated_downgrades_nonbug_too():
    # not-a-bug still SUPPRESSES a reopen, and the new-signature check needs complete
    # data -> truncation must fail it open like every other hold.
    nonbug = decide({"events": [ev("v2.1.4")], "closed_at": CLOSED, "close_class": "not-a-bug",
                     "fix_released_version": None, "fix_merged": False,
                     "latest_release": "v2.1.4", "events_truncated": True})
    assert nonbug["verdict"] == "ambiguous"


def test_canary_surfaced_even_when_production_is_prefix_tail():
    # All prod pre-fix, but a fix-containing dogfood build still emits.
    events = [ev("v2.1.0", user="real"),
              ev("v2.1.5-2-gabc-dev", build="debug", env="development", user="founder")]
    out = decide({"events": events, "closed_at": CLOSED, "close_class": "telemetry-noise",
                  "fix_released_version": "v2.1.5", "fix_merged": True, "latest_release": "v2.1.5"})
    assert out["verdict"] == "hold-prefix-tail"   # customers: still hold
    assert out["dev_canary"].get("count") == 1    # but the canary is not hidden


def test_mixed_dev_and_prefix_prod_excludes_dev_and_holds():
    events = [ev("v2.1.0", user="real"), ev("v2.1.0-1-gabc-dev", build="debug", user="founder")]
    out = decide({"events": events, "closed_at": CLOSED, "close_class": "telemetry-noise",
                  "fix_released_version": None, "fix_merged": True, "latest_release": "v2.1.4"})
    assert out["verdict"] == "hold-prefix-tail"
    assert out["excluded_dev_count"] == 1


def test_fractional_second_event_in_close_second_is_post_close():
    # Event 0.5s into the close second must count as post-close (not dropped by a
    # string compare where '.' < 'Z').
    out = decide({"events": [ev("v2.1.5", when="2026-06-17T06:00:00.500Z")],
                  "closed_at": "2026-06-17T06:00:00Z", "close_class": "fixed",
                  "fix_released_version": "v2.1.5", "fix_merged": True, "latest_release": "v2.1.5"})
    assert out["verdict"] == "reopen-eligible"  # the event is post-close and post-fix


def test_string_false_fix_merged_does_not_prove_hold():
    # Shell-built JSON with fix_merged="false" must NOT be coerced to True.
    out = decide({"events": [ev("v2.1.0")], "closed_at": CLOSED, "close_class": "fixed",
                  "fix_released_version": None, "fix_merged": "false", "latest_release": "v2.1.4"})
    assert out["verdict"] == "ambiguous"  # unproven -> fail open, NOT hold-prefix-tail


def test_string_true_fix_merged_is_honored():
    out = decide({"events": [ev("v2.1.0")], "closed_at": CLOSED, "close_class": "telemetry-noise",
                  "fix_released_version": None, "fix_merged": "true", "latest_release": "v2.1.4"})
    assert out["verdict"] == "hold-prefix-tail"


def test_string_true_events_truncated_downgrades():
    out = decide({"events": [ev("v2.1.0")], "closed_at": CLOSED, "close_class": "telemetry-noise",
                  "fix_released_version": None, "fix_merged": True, "latest_release": "v2.1.4",
                  "events_truncated": "true"})
    assert out["verdict"] == "ambiguous"


# ---- comprehensive-sweep hardening (Codex final sweep, 9 findings) ----------

def test_missing_events_is_ambiguous_not_noactivity():
    # Missing fetch is NOT proof of no activity.
    out = decide({"closed_at": CLOSED, "close_class": "fixed",
                  "fix_released_version": "v2.1.5", "fix_merged": True, "latest_release": "v2.1.5"})
    assert out["verdict"] == "ambiguous"
    # but an explicitly-empty list IS a provable no-activity hold
    out2 = decide({"events": [], "closed_at": CLOSED, "close_class": "fixed",
                   "fix_released_version": "v2.1.5", "fix_merged": True, "latest_release": "v2.1.5"})
    assert out2["verdict"] == "no-postclose-activity"


def test_bad_closed_at_downgrades_hold():
    out = decide({"events": [ev("v2.1.0")], "closed_at": "not-a-date",
                  "close_class": "telemetry-noise", "fix_released_version": None,
                  "fix_merged": True, "latest_release": "v2.1.4"})
    assert out["verdict"] == "ambiguous"


def test_naive_closed_at_downgrades_hold():
    out = decide({"events": [ev("v2.1.0")], "closed_at": "2026-06-17T06:00:00",  # no tz
                  "close_class": "telemetry-noise", "fix_released_version": None,
                  "fix_merged": True, "latest_release": "v2.1.4"})
    assert out["verdict"] == "ambiguous"


def test_naive_event_timestamp_downgrades_hold():
    # Finding 4: malformed/naive event time must not be silently held as pre-fix.
    out = decide({"events": [ev("v2.1.0", when="2026-06-20T00:00:00")],  # no tz
                  "closed_at": CLOSED, "close_class": "telemetry-noise",
                  "fix_released_version": None, "fix_merged": True, "latest_release": "v2.1.4"})
    assert out["verdict"] == "ambiguous"


def test_offset_timestamps_compared_correctly():
    # Event at 08:00+02:00 == 06:00Z, one hour after a 05:00Z close -> post-close, post-fix.
    out = decide({"events": [ev("v2.1.5", when="2026-06-17T08:00:00+02:00")],
                  "closed_at": "2026-06-17T05:00:00Z", "close_class": "fixed",
                  "fix_released_version": "v2.1.5", "fix_merged": True, "latest_release": "v2.1.5"})
    assert out["verdict"] == "reopen-eligible"


def test_strict_semver_rejects_prerelease_4part_leading_zero():
    assert normalize_version("v2.1.5-beta.1") is None
    assert normalize_version("v2.1.5.1") is None
    assert normalize_version("v02.001.004") is None
    # but a real prod build that is all pre-fix-of-an-unparseable... stays safe:
    out = decide({"events": [ev("v2.1.5-beta.1")], "closed_at": CLOSED, "close_class": "fixed",
                  "fix_released_version": "v2.1.9", "fix_merged": True, "latest_release": "v2.1.9"})
    assert out["verdict"] == "ambiguous"  # unparseable prod release -> unknown -> fail open


def test_close_class_trailing_space_normalized():
    out = decide({"events": [ev("v2.1.4")], "closed_at": CLOSED, "close_class": "not-a-bug ",
                  "fix_released_version": None, "fix_merged": False, "latest_release": "v2.1.4"})
    assert out["verdict"] == "hold-nonbug"  # 'not-a-bug ' stripped to 'not-a-bug'


def test_merged_unreleased_event_newer_than_latest_tag_fails_open():
    # Fix merged-but-unreleased, but an event is on a build NEWER than the latest tag
    # we know (stale fetch / untagged build) -> can't prove pre-fix -> fail open.
    out = decide({"events": [ev("v2.1.6")], "closed_at": CLOSED, "close_class": "telemetry-noise",
                  "fix_released_version": None, "fix_merged": True, "latest_release": "v2.1.4"})
    assert out["verdict"] == "ambiguous"
    # an event at-or-below the latest tag still holds as pre-fix
    held = decide({"events": [ev("v2.1.4")], "closed_at": CLOSED, "close_class": "telemetry-noise",
                   "fix_released_version": None, "fix_merged": True, "latest_release": "v2.1.4"})
    assert held["verdict"] == "hold-prefix-tail"


def test_merged_unreleased_missing_latest_release_fails_open():
    out = decide({"events": [ev("v2.1.0")], "closed_at": CLOSED, "close_class": "telemetry-noise",
                  "fix_released_version": None, "fix_merged": True, "latest_release": None})
    assert out["verdict"] == "ambiguous"  # no trustworthy ceiling -> cannot prove pre-fix


def test_nonbug_with_broken_input_fails_open():
    # not-a-bug + missing events -> cannot verify no new signature -> ambiguous.
    out = decide({"close_class": "not-a-bug", "closed_at": CLOSED,
                  "fix_released_version": None, "fix_merged": False, "latest_release": "v2.1.4"})
    assert out["verdict"] == "ambiguous"


def test_garbage_close_class_becomes_unknown():
    out = decide({"events": [ev("v2.1.4")], "closed_at": CLOSED, "close_class": "frobnicated",
                  "fix_released_version": None, "fix_merged": False, "latest_release": "v2.1.4"})
    assert out["verdict"] == "ambiguous"  # unknown class + no fix info -> fail open


def test_null_user_ids_do_not_underscore_severity():
    # 10 eligible post-fix events with null user_id must count as 10 users, not 0.
    events = [ev("v2.1.5", user=None) for _ in range(10)]
    out = decide({"events": events, "closed_at": CLOSED, "close_class": "fixed",
                  "fix_released_version": "v2.1.5", "fix_merged": True, "latest_release": "v2.1.5"})
    assert out["verdict"] == "reopen-eligible"
    assert out["eligible_user_count"] == 10  # conservative: anon events each count


# ---- decide_create: create-path eligibility gate (issue #1218) --------------
#
# The create gate answers "should a brand-new fingerprint with no GitHub issue
# become a ticket". family in {create, suppress, digest}; the routine only branches
# on `family`. Fails OPEN (create) on anything not provably dev-only-self-healed.

def cev(*, env="development", build="debug",
        release="com.enviouswispr.app@2.2.0-3-gabc123-dev",
        level="error", synthetic=None, user="founder", when="2026-06-24T00:00:00Z"):
    """A DEV event by default (the #1192-#1215 class). Override fields per case."""
    e = {"release": release, "environment": env, "build_type": build,
         "user_id": user, "dateCreated": when, "level": level}
    if synthetic is not None:
        e["synthetic"] = synthetic
    return e


def pev(*, release="com.enviouswispr.app@2.2.0", level="error", user="u1"):
    """A PRODUCTION event (release build, production env)."""
    return {"release": release, "environment": "production", "build_type": "release",
            "user_id": user, "dateCreated": "2026-06-24T00:00:00Z", "level": level}


def dc_full(events, **kw):
    """decide_create over a PROVABLY COMPLETE event list (events_truncated=False).

    The create gate REQUIRES `events_truncated` -- a MISSING flag fails open to create
    (Codex #1218 r3), since the flag is the gate's only completeness signal. Branch
    tests that assert digest/suppress must therefore prove completeness; this wrapper
    states that once instead of repeating it at every call site."""
    return decide_create({"events": events, "events_truncated": False, **kw})


def test_create_production_event_creates():
    out = decide_create({"events": [pev()]})
    assert out["verdict"] == "create"
    assert out["family"] == "create"


def test_create_mixed_prod_and_dev_creates():
    # One real production event among dev noise still creates (real customer signal).
    out = decide_create({"events": [cev(), pev(user="real")]})
    assert out["family"] == "create"
    assert out["dev_count"] == 1
    assert out["event_count"] == 2


def test_create_all_dev_all_synthetic_suppresses():
    # Deliberate fault-injection crash-test -> suppress, never a ticket.
    out = dc_full([cev(synthetic="true", level="fatal"),
                   cev(synthetic="true", level="fatal")])
    assert out["verdict"] == "suppress-synthetic"
    assert out["family"] == "suppress"


def test_create_all_dev_untagged_fatal_creates_canary():
    # An untagged dev crash could be a real new-crash -> create-visible.
    out = decide_create({"events": [cev(level="fatal")]})
    assert out["verdict"] == "create-dev-fatal"
    assert out["family"] == "create"


def test_create_all_dev_handled_error_digests():
    # The target class: dev-only, handled, self-healed -> digest, NOT a ticket.
    out = dc_full([cev(level="error")])
    assert out["verdict"] == "digest-dev-only"
    assert out["family"] == "digest"


def test_create_empty_events_fails_open_to_create():
    out = decide_create({"events": []})
    assert out["family"] == "create"


def test_create_missing_events_fails_open_to_create():
    # Missing fetch is NOT proof of "nothing real" -> create (visible).
    out = decide_create({})
    assert out["family"] == "create"


def test_create_all_dev_warning_level_fails_open():
    # All-dev but not provably all-handled-error (warning) -> fail open to create.
    out = decide_create({"events": [cev(level="warning")]})
    assert out["family"] == "create"
    assert out["verdict"] == "create"


def test_create_unknown_level_no_fallback_fails_open():
    # No per-event level AND no issue_level -> unclassifiable -> fail open.
    e = cev()
    del e["level"]
    out = decide_create({"events": [e]})
    assert out["family"] == "create"


def test_create_synthetic_string_true_is_coerced():
    # Sentry tag value is the string "true"; it must coerce to a real suppress.
    out = dc_full([cev(synthetic="true")])
    assert out["family"] == "suppress"


def test_create_synthetic_absent_is_not_suppressed():
    # Absence of the tag means "unknown", never "known-synthetic" -> not suppressed.
    out = dc_full([cev(level="error")])  # no synthetic key
    assert out["family"] == "digest"  # falls to the handled-error class, not suppress


def test_create_per_event_level_overrides_issue_level():
    # event.level=fatal must win over issue_level=error -> create-dev-fatal.
    out = decide_create({"events": [cev(level="fatal")], "issue_level": "error"})
    assert out["verdict"] == "create-dev-fatal"


def test_create_issue_level_fallback_when_event_level_absent():
    # SINGLE-event fingerprint (latest == only event) -> the issue_level fallback is
    # exact -> digest (handled class).
    e = cev()
    del e["level"]
    out = dc_full([e], issue_level="error")
    assert out["verdict"] == "digest-dev-only"


def test_create_multi_event_missing_per_event_level_fails_open():
    # Codex P2 (#1218 review r4): in a MULTI-event list, a non-synthetic event missing
    # its OWN `level` is unclassifiable -- the issue/latest-level fallback (valid only
    # for a single-event fingerprint) must NOT mask it as 'error' and digest the whole
    # fingerprint; that event could have been a fatal. Fail open to create.
    e_no_level = cev()
    del e_no_level["level"]
    out = dc_full([cev(level="error"), e_no_level], issue_level="error")
    assert out["family"] == "create"


def test_create_untagged_fatal_mixed_with_synthetic_still_creates():
    # A genuine (untagged) dev fatal alongside a synthetic one is NOT all-synthetic,
    # so branch 2 fails and the untagged fatal surfaces (create-dev-fatal).
    out = decide_create({"events": [cev(synthetic="true", level="fatal"),
                                    cev(level="fatal")]})
    assert out["verdict"] == "create-dev-fatal"


def test_create_partial_synthetic_handled_errors_digest():
    # Some synthetic, some not, all handled errors -> not all-synthetic, no fatal,
    # all-error -> digest (no ticket either way; harmless).
    out = dc_full([cev(synthetic="true"), cev()])
    assert out["verdict"] == "digest-dev-only"


def test_create_synthetic_fatal_plus_untagged_handled_digests():
    # Codex P2 (#1218 review r1): a TAGGED fault-injection FATAL alongside an UNTAGGED
    # handled dev error must NOT create. The synthetic fatal is a deliberate crash-test
    # and is excluded from the dev signal; the only real signal is the handled error
    # (the digest class). Before the fix this filed a ticket for the crash-test.
    out = dc_full([cev(synthetic="true", level="fatal"), cev(level="error")])
    assert out["verdict"] == "digest-dev-only"
    assert out["family"] == "digest"


def test_create_cli_create_flag_dispatches_to_decide_create():
    # `--create` routes to decide_create; a digest fixture returns family=digest.
    payload = json.dumps({"events": [cev(level="error")], "events_truncated": False})
    proc = subprocess.run(
        [sys.executable, str(Path(__file__).resolve().parent / "tik_eligibility.py"), "--create"],
        input=payload, capture_output=True, text=True)
    assert proc.returncode == 0
    assert json.loads(proc.stdout)["family"] == "digest"


def test_create_cli_without_flag_is_reopen_gate():
    # No flag -> the existing reopen gate (decide) -> ambiguous on this fail-open input.
    # Proves the live Step 2.6.5 invocation is byte-for-byte unchanged.
    payload = json.dumps({"events": [ev("v2.1.4")], "closed_at": CLOSED,
                          "close_class": "unknown", "fix_released_version": None,
                          "fix_merged": False, "latest_release": "v2.1.4"})
    proc = subprocess.run(
        [sys.executable, str(Path(__file__).resolve().parent / "tik_eligibility.py")],
        input=payload, capture_output=True, text=True)
    assert proc.returncode == 0
    assert json.loads(proc.stdout)["verdict"] == "ambiguous"


def test_create_cli_create_flag_fails_open_on_bad_json():
    # Malformed stdin under --create must fail OPEN to create (visible), exit 0.
    proc = subprocess.run(
        [sys.executable, str(Path(__file__).resolve().parent / "tik_eligibility.py"), "--create"],
        input="not json", capture_output=True, text=True)
    assert proc.returncode == 0
    assert json.loads(proc.stdout)["family"] == "create"


def test_create_8_fingerprint_regression_zero_creates():
    # The metric (plan 3a): decide_create over the 8 dev-only self-healed fingerprints
    # filed 2026-06-24 (ENVIOUSWISPR-1B/1C/1D/1E/1F/1G/1J/1K) returns NO create for any.
    # Each is modeled as its real class: a single dev, handled (level=error),
    # self-healed event from the founder's dogfood machine.
    shortids = ["1B", "1C", "1D", "1E", "1F", "1G", "1J", "1K"]
    for sid in shortids:
        out = dc_full([cev(level="error", user=f"founder-{sid}")])
        assert out["family"] in {"digest", "suppress"}, f"{sid} -> {out}"
        assert out["family"] != "create", f"{sid} wrongly created: {out}"


def test_create_missing_events_truncated_fails_open_on_suppress():
    # Codex P2 (#1218 review r3): events_truncated is REQUIRED. A digest/suppress with
    # NO events_truncated key cannot prove the list is complete -> fail open to create.
    # (Same events that digest/suppress WITH events_truncated=False, per dc_full above.)
    assert decide_create({"events": [cev(level="error")]})["family"] == "create"
    assert decide_create({"events": [cev(synthetic="true")]})["family"] == "create"


def test_create_truncated_downgrades_digest_to_create():
    # Codex P2 (#1218 review r2): a digest on a TRUNCATED list is unsafe — an unread
    # page could hold a production/fatal event -> fail open to create.
    base = {"events": [cev(level="error")]}
    assert decide_create({**base, "events_truncated": False})["family"] == "digest"
    assert decide_create({**base, "events_truncated": True})["family"] == "create"


def test_create_truncated_downgrades_suppress_to_create():
    base = {"events": [cev(synthetic="true")]}
    assert decide_create({**base, "events_truncated": False})["family"] == "suppress"
    assert decide_create({**base, "events_truncated": True})["family"] == "create"


def test_create_truncated_does_not_change_create():
    # A create verdict is already visible -> truncation is irrelevant (like the reopen
    # gate's test_truncated_does_not_downgrade_reopen).
    base = {"events": [cev(level="fatal")]}  # create-dev-fatal
    assert decide_create({**base, "events_truncated": True})["verdict"] == "create-dev-fatal"


def test_create_truncated_string_true_is_coerced():
    # Shell-built JSON passes "true"/"false" as strings; only a real true downgrades.
    out = decide_create({"events": [cev(level="error")], "events_truncated": "true"})
    assert out["family"] == "create"


# ---- self-runner (no pytest dependency in the routine sandbox) --------------

def _run_all():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"FAIL {fn.__name__}: {e}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"ERROR {fn.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(fns) - failed}/{len(fns)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(_run_all())
