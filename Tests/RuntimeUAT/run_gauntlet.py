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

    # #1317 dead-mic proof bench (one build; needs a stamped manifest):
    python3 Tests/RuntimeUAT/run_gauntlet.py dead-mic \
        --manifest /tmp/bench/candidate.manifest.json \
        --backend parakeet --label candidate --scorecard /tmp/bench/candidate.json

    # Stamp a build manifest AFTER building an A/B arm:
    python3 Tests/RuntimeUAT/run_gauntlet.py write-manifest \
        --bundle "build/EnviousWispr Local.app" --source-ref v2.3.2 \
        --source-sha $(git rev-parse HEAD) --clean-tree \
        --contract-version zerofill-v1 --out /tmp/bench/candidate.manifest.json

The bundle must already be running with EW_FAULT_INJECTION=1 set
(via the wispr-rebuild-debug skill). The A/B comparison is two dead-mic runs
(one per build, sequential — shared bundle id) plus a diff of the two
scorecards; this runner owns per-build execution, manifest stamping, and
aggregation (no third runner, per plan §3c).
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
    write_build_manifest,
)

# #1317 deterministic dead-mic cells scored A/B in Phase 1.
DEAD_MIC_SCENARIOS = [
    "Z1_all_zero_from_start",
    "Z2_valid_then_all_zero",
    "Z3_bounded_zero_then_restore",
]


PARAKEET_GAUNTLET = [
    "A1_rapid_stop_start",
    "A2_esc_cancel",
    "A3_asr_xpc_kill",
    "A4_audio_xpc_kill",
    "A5_proxy_buffer_drop_watchdog",
    "A6_settings_storm",
    "A7_app_quit",
    "A9_backend_switch_mid_record",
]

WHISPERKIT_GAUNTLET = [
    "A1_rapid_stop_start",
    "A2_esc_cancel",
    # A3 (ASR XPC kill) is Parakeet-only — WhisperKit ASR is in-process.
    "A4_audio_xpc_kill",
    "A5_proxy_buffer_drop_watchdog",
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


def run_dead_mic_bench(manifest_path: str, backend: str, label: str) -> dict:
    """#1317 dead-mic proof bench against the currently running build. Baseline
    mode: a valid-evidence PRODUCT failure is recorded and does NOT abort the run
    (so the full scorecard is produced); an INVALID-evidence trial flags the whole
    bench invalid (nonzero exit). The running app must already be on `backend`;
    this runner records the label, it does not switch backends."""
    print(f"=== #1317 dead-mic bench — build={label} backend={backend} ===")
    print(f"manifest: {manifest_path}")
    print(f"pre-state: {query_state()}")

    cells = []
    any_invalid = False
    for i, name in enumerate(DEAD_MIC_SCENARIOS, 1):
        print(f"\n--- [{i}/{len(DEAD_MIC_SCENARIOS)}] {name} ---")
        t0 = time.monotonic()
        try:
            wrapped = run_scenario(name, manifest_path=manifest_path)
            inner = wrapped.get("result", {})
        except Exception as e:  # noqa: BLE001 — a raising scenario is invalid evidence
            print(f"  scenario raised: {type(e).__name__}: {e}")
            cells.append({
                "scenario": name, "evidence_valid": False, "passed": False,
                "reason": f"scenario raised {type(e).__name__}: {e}",
                "elapsed_seconds": time.monotonic() - t0,
                "assertions": {}, "evidence": {},
            })
            any_invalid = True
            continue

        passed, reason = evaluate_trial(name, inner)
        ev_valid = bool(inner.get("evidence_valid", True))
        if not ev_valid:
            any_invalid = True
        cells.append({
            "scenario": name,
            "evidence_valid": ev_valid,
            "passed": passed,
            "reason": reason,
            "elapsed_seconds": wrapped.get("elapsed_seconds"),
            "assertions": inner.get("assertions", {}),
            "evidence": inner.get("evidence", {}),
        })
        tag = "OK" if passed else ("INVALID" if not ev_valid else "PRODUCT-FAIL")
        print(f"  {tag}  {reason}")
        print(f"  assertions={inner.get('assertions', {})}")

    print(f"\nfinal-state: {query_state()}")
    return {
        "label": label,
        "backend": backend,
        "manifest_path": manifest_path,
        "any_invalid": any_invalid,
        "cells": cells,
    }


def _write_scorecard(bench: dict, out_path: str) -> None:
    Path(out_path).write_text(
        json.dumps(bench, indent=2, default=str) + "\n", encoding="utf-8")
    print(f"\nscorecard written: {out_path}")


def _cmd_dead_mic(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="run_gauntlet.py dead-mic")
    p.add_argument("--manifest", required=True, help="build manifest JSON path")
    p.add_argument("--backend", choices=["parakeet", "whisperKit"], default="parakeet")
    p.add_argument("--label", required=True, help="build label, e.g. candidate / v2.3.2")
    p.add_argument("--scorecard", help="write the JSON scorecard here")
    args = p.parse_args(argv)
    bench = run_dead_mic_bench(args.manifest, args.backend, args.label)
    if args.scorecard:
        _write_scorecard(bench, args.scorecard)
    n_invalid = sum(1 for c in bench["cells"] if not c["evidence_valid"])
    n_fail = sum(1 for c in bench["cells"] if c["evidence_valid"] and not c["passed"])
    print(f"\n=== bench summary: {len(bench['cells'])} cells, "
          f"{n_invalid} invalid-evidence, {n_fail} product-fail ===")
    # Baseline contract: nonzero only when any trial has INVALID evidence.
    return 1 if bench["any_invalid"] else 0


def _cmd_write_manifest(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="run_gauntlet.py write-manifest")
    p.add_argument("--bundle", required=True, help="path to the built .app")
    p.add_argument("--source-ref", required=True, help="git ref/tag the build came from")
    p.add_argument("--source-sha", required=True, help="full commit SHA")
    p.add_argument("--clean-tree", action="store_true", help="working tree was clean")
    p.add_argument("--contract-version", required=True, help="injector contract version")
    p.add_argument("--out", required=True, help="manifest JSON output path")
    args = p.parse_args(argv)
    manifest = write_build_manifest(
        bundle_path=args.bundle, source_ref=args.source_ref, source_sha=args.source_sha,
        clean_tree=args.clean_tree, contract_version=args.contract_version, out_path=args.out)
    print(f"manifest written: {args.out}")
    print(f"  app_sha256={manifest['app_sha256'][:16]}…  "
          f"audio={manifest['audio_helper_sha256'][:16]}…  "
          f"asr={manifest['asr_helper_sha256'][:16]}…")
    return 0


def main(argv: list[str]) -> int:
    # Subcommand routing; no subcommand ⇒ legacy Lane A gauntlet (back-compat).
    if argv and argv[0] == "dead-mic":
        return _cmd_dead_mic(argv[1:])
    if argv and argv[0] == "write-manifest":
        return _cmd_write_manifest(argv[1:])

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
