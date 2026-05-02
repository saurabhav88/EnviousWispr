"""
Run a Lane A gauntlet sequentially against the running debug bundle, with
a between-scenario health check. If any scenario or its post-check leaves
the app in a non-idle / non-recovering state, stop immediately and report
which scenario was the last to run cleanly. Without this check a single
bad scenario silently invalidates every subsequent "pass" because the app
is already broken.

Usage:
    python3 Tests/RuntimeUAT/run_gauntlet.py --backend parakeet
    python3 Tests/RuntimeUAT/run_gauntlet.py --backend whisperKit

The bundle must already be running with EW_FAULT_INJECTION=1 set
(via the wispr-rebuild-debug skill).
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from faultInjection import (  # noqa: E402
    _assert_dictation_recovers,
    _parse_query_state,
    list_xpc_service_pids,
    query_state,
    run_scenario,
)


PARAKEET_GAUNTLET = [
    "A1_rapid_stop_start",
    "A2_esc_cancel",
    "A3_asr_xpc_kill",
    "A4_audio_xpc_kill",
    "A5_forced_stall",
    "A6_settings_storm",
    "A7_app_quit",
    "A9_backend_switch_mid_record",
]

WHISPERKIT_GAUNTLET = [
    "A1_rapid_stop_start",
    "A2_esc_cancel",
    # A3 (ASR XPC kill) is Parakeet-only — WhisperKit ASR is in-process.
    "A4_audio_xpc_kill",
    "A5_forced_stall",
    "A6_settings_storm",
    "A7_app_quit",
    "A9_backend_switch_mid_record",
]


def health_check(backend_key: str) -> dict:
    """After a scenario, verify the app is in a state where the next
    scenario can meaningfully run.

    Checks:
      1. Active backend's pipeline state is idle/complete/ready (NOT
         error — issue #555 means error states leave the overlay stuck).
      2. XPC helper count is sane (1-3).
      3. A recovery dictation cycle reaches a non-error terminal state.
    """
    parsed = _parse_query_state(query_state())
    pipeline_state = parsed.get(backend_key, "")
    helpers = list_xpc_service_pids()

    state_ok = pipeline_state in {"idle", "complete", "ready"}
    helpers_ok = 1 <= len(helpers) <= 3

    if not state_ok:
        return {
            "healthy": False,
            "reason": f"pipeline state {pipeline_state!r} not idle/complete/ready",
            "pipeline_state": pipeline_state,
            "helpers": helpers,
        }
    if not helpers_ok:
        return {
            "healthy": False,
            "reason": f"helper count {len(helpers)} out of expected range",
            "pipeline_state": pipeline_state,
            "helpers": helpers,
        }

    recovery = _assert_dictation_recovers()
    if not recovery.get("recovered"):
        return {
            "healthy": False,
            "reason": "post-scenario recovery dictation failed",
            "pipeline_state": pipeline_state,
            "helpers": helpers,
            "recovery": recovery,
        }
    return {
        "healthy": True,
        "pipeline_state": pipeline_state,
        "helpers": helpers,
        "recovery_terminal_state": recovery.get("second_cycle_terminal_state"),
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", choices=["parakeet", "whisperKit"],
                        default="parakeet")
    args = parser.parse_args(argv)

    backend_key = "parakeet" if args.backend == "parakeet" else "whisperkit"
    scenarios = (PARAKEET_GAUNTLET if args.backend == "parakeet"
                 else WHISPERKIT_GAUNTLET)

    print(f"=== Lane A gauntlet — {args.backend} ===")
    print(f"pre-state: {query_state()}")

    results = []
    for i, scenario in enumerate(scenarios, 1):
        print(f"\n--- [{i}/{len(scenarios)}] {scenario} ---")
        t0 = time.monotonic()
        try:
            scenario_result = run_scenario(scenario)
            elapsed = scenario_result.get("elapsed_seconds", time.monotonic() - t0)
            inner = scenario_result.get("result", {})
            print(f"  elapsed={elapsed:.1f}s")
            print(f"  result={inner}")
        except Exception as e:
            print(f"  scenario raised: {type(e).__name__}: {e}")
            results.append({
                "scenario": scenario, "passed": False,
                "reason": "scenario raised exception", "exception": str(e),
            })
            print(f"\n!!! gauntlet aborted at {scenario} (raised exception) !!!")
            break

        print(f"  health check (active backend = {backend_key})...")
        health = health_check(backend_key)
        results.append({
            "scenario": scenario,
            "elapsed_s": elapsed,
            "scenario_result": inner,
            "health": health,
        })
        if not health["healthy"]:
            print(f"  health FAIL: {health['reason']}")
            print(f"  pipeline_state={health['pipeline_state']}, "
                  f"helpers={health['helpers']}")
            print(f"\n!!! gauntlet aborted at {scenario} — app no longer healthy !!!")
            print(f"    {len(scenarios) - i} scenarios skipped: {scenarios[i:]}")
            break
        print(f"  health OK  pipeline={health['pipeline_state']}  "
              f"helpers={len(health['helpers'])}  "
              f"recovery={health['recovery_terminal_state']}")

    print("\n=== Summary ===")
    for r in results:
        scen = r["scenario"]
        if r.get("health", {}).get("healthy"):
            print(f"  PASS  {scen}")
        else:
            reason = r.get("health", {}).get("reason") or r.get("reason") or "?"
            print(f"  FAIL  {scen}  ({reason})")
    print(f"\nfinal-state: {query_state()}")
    return 0 if all(r.get("health", {}).get("healthy") for r in results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
