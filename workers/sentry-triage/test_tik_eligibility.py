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
from tik_eligibility import decide, normalize_version, is_development, main  # noqa: E402

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
    # No fix info at all + a production event we can't classify -> ambiguous (reopen).
    out = decide({"events": [ev("v2.1.4")], "closed_at": CLOSED, "close_class": "unknown",
                  "fix_released_version": None, "fix_merged": False, "latest_release": "v2.1.4"})
    assert out["verdict"] == "ambiguous"
    assert out["family"] == "ambiguous"


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
