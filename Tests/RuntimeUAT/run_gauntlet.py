"""
Run a Lane A gauntlet sequentially against the running debug bundle, with
a between-scenario health check. If any scenario or its post-check leaves
the app in a non-idle / non-recovering state, stop immediately and report
which scenario was the last to run cleanly. Without this check a single
bad scenario silently invalidates every subsequent "pass" because the app
is already broken.

Usage:
    # Legacy Lane A gauntlet (health-check between scenarios):
    python3 Tests/RuntimeUAT/run_gauntlet.py --backend parakeet
    python3 Tests/RuntimeUAT/run_gauntlet.py --backend whisperKit


The #1317 dead-mic proof bench that used to live here was moved OFFLINE on
2026-07-11 (gitignored working copy under `docs/bench-offline/`): it was never a
CI gate and it needs a rethink rather than a patch. This runner now owns only the
Lane A gauntlet.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from faultInjection import (  # noqa: E402
    _assert_dictation_recovers,
    _parse_query_state,
    evaluate_trial,
    list_xpc_service_pids,
    query_state,
    run_scenario,
)

# #1317 deterministic dead-mic cells scored A/B in Phase 1.


# #1543: A4_audio_xpc_kill and A5_proxy_buffer_drop_watchdog were removed with
# the audio-capture boundary (both tested deleted host-side proxy DEBUG
# commands); audio interruption is covered by the Lane B real-hardware matrix.
PARAKEET_GAUNTLET = [
    "A1_rapid_stop_start",
    "A2_esc_cancel",
    "A3_asr_xpc_kill",
    "A6_settings_storm",
    "A7_app_quit",
    "A9_backend_switch_mid_record",
]

WHISPERKIT_GAUNTLET = [
    "A1_rapid_stop_start",
    "A2_esc_cancel",
    # A3 (ASR XPC kill) is Parakeet-only — WhisperKit ASR is in-process.
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
      2. XPC helper count is sane for the backend. #1543 removed the audio
         capture helper (capture is in-process), so the only service helper left
         is the ASR one — and WhisperKit's ASR is in-process too. Parakeet
         therefore expects the ASR helper present (1, up to 2 across a respawn);
         WhisperKit expects zero service helpers (up to 1 tolerated if a
         Parakeet-backed helper lingers from a prior scenario).
      3. A recovery dictation cycle reaches a non-error terminal state.
    """
    parsed = _parse_query_state(query_state())
    pipeline_state = parsed.get(backend_key, "")
    helpers = list_xpc_service_pids()

    state_ok = pipeline_state in {"idle", "complete", "ready"}
    if backend_key == "whisperkit":
        helpers_ok = len(helpers) <= 1
    else:
        helpers_ok = 1 <= len(helpers) <= 2

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




def _write_scorecard(bench: dict, out_path: str) -> None:
    Path(out_path).write_text(
        json.dumps(bench, indent=2, default=str) + "\n", encoding="utf-8")
    print(f"\nscorecard written: {out_path}")






def main(argv: list[str]) -> int:
    # Subcommand routing; no subcommand ⇒ legacy Lane A gauntlet (back-compat).

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
