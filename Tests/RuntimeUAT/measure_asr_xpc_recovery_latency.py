#!/usr/bin/env python3
"""#1707: measure real Parakeet ASR-XPC recovery latency against the live
dev app, to set `ParakeetEngineAdapter.asrInterruptionRecoveryDeadlineSec`
from a grep-cited p99-over-30-samples deadline
(validation-discipline.md RULE: timeout-numbers-need-distribution-evidence).

Prereqs: dev app rebuilt + relaunched via `wispr-rebuild-debug` (DEBUG build,
EW_FAULT_INJECTION=1), Parakeet backend selected, Accessibility + mic granted.

Usage: python3 Tests/RuntimeUAT/measure_asr_xpc_recovery_latency.py [N]
  N = trial count (default 30).

Codex code-diff r6 found the first version of this script wrong twice over:
app.log's ISO8601 timestamps are second-granularity only (nowhere near
enough to resolve a sub-second interval), and the marker it used
("Pipeline timing: ASR started") actually fires from `markASRTimingStart`
BEFORE the recovery await even begins, not after it completes — so the
"measured" 50-111ms distribution was really just Python polling-loop
overhead. Fixed at the source instead of trying to patch the symptom: the
kernel now measures its own recovery window with a high-resolution Swift
clock and logs the precomputed value directly
(RecordingSessionKernel.swift, "ASR recovery latency: <N>ms outcome=...").
This script does nothing but grep that one authoritative line out of
app.log per trial — no timing inference of its own, and the same line
fires in production on every real crash, so it also becomes real field
data to revisit this deadline against later.

Codex code-diff r11 found a SECOND, deeper problem: this script used
`force_xpc_kill()` (`ASRManagerProxy.forceConnectionTerminationNow`), which
only invalidates the XPC connection — the helper PROCESS stays alive and
the model stays resident. That measures a real but much easier scenario
than the one #1707 targets ("the ASR helper crashed"). Fixed: now uses
`force_xpc_process_kill()`, a real `kill -9` on the actual
`EnviousWisprASRService` process (confirmed respawned under a new PID by
`list_xpc_service_pids()`), forcing a genuine cold reload.

Last run 2026-07-20 (real process crash): 27/30 trials recovered in
4159-4215ms (p99=4215ms); the other 3 (each the first trial after a fresh
dev-app launch) were faster (154ms/161ms/3195ms), almost certainly
benefiting from launch-time OS file-cache warmth rather than representing
steady-state field behavior. Raw output:
docs/audits/2026-07-20-recovery-v2-phase1-asr-recovery-latency.txt
(gitignored — local only; also records the earlier, superseded
connection-only measurement for history). Re-run after any change to the
reconnect path (warmUp(), ASRManagerProxy, or the XPC service itself) to
re-validate the deadline still has headroom.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from faultInjection import (  # noqa: E402
    APP_LOG_PATH,
    _active_state,
    _read_asr_recovery_outcome,
    _start_recording_locked,
    _stop_recording_locked,
    _tap_rcmd,
    _TTSAudio,
    force_xpc_process_kill,
)

POLL_TIMEOUT_S = 15.0


def _reset_to_idle() -> None:
    state = _active_state()
    if "error" in state or "recording" in state or "transcrib" in state:
        _tap_rcmd()
        # settle: let the hotkey-debounce/state-transition finish before the next read; no callback exists on this DEBUG endpoint to await instead.
        time.sleep(0.8)


def run_trial(index: int) -> dict:
    _reset_to_idle()
    if not _start_recording_locked():
        return {"index": index, "ok": False, "reason": "could not start recording"}
    with open(APP_LOG_PATH, encoding="utf-8", errors="replace") as fh:
        fh.seek(0, 2)
        start_pos = fh.tell()
    with _TTSAudio():
        # settle: let audio actually stream into the live ASR connection before killing it — a kill against an idle connection tests a different path.
        time.sleep(1.0)
        force_xpc_process_kill()
        result = _read_asr_recovery_outcome(start_pos, timeout_s=POLL_TIMEOUT_S)
    _stop_recording_locked(settle_s=0.3)
    if result is None:
        return {"index": index, "ok": True, "outcome": "timeout"}
    return {"index": index, "ok": True, **result}


def main(argv: list[str]) -> int:
    n = int(argv[0]) if argv else 30
    trials = []
    for i in range(n):
        result = run_trial(i)
        print(f"trial {i + 1}/{n}: {result}")
        trials.append(result)
        # settle: let the app fully return to idle before the next trial — no cross-trial state signal exists on the DEBUG endpoint to poll.
        time.sleep(1.0)

    succeeded = [t["elapsed_ms"] for t in trials if t.get("outcome") == "readyForBatchDecode"]
    other = [t for t in trials if t.get("outcome") != "readyForBatchDecode"]

    print("\n--- #1707 ASR-XPC recovery latency (ms), readyForBatchDecode trials only ---")
    print(f"n={len(succeeded)}/{n} readyForBatchDecode, {len(other)} other (see below)")
    if succeeded:
        sorted_ms = sorted(succeeded)
        mean = sum(sorted_ms) / len(sorted_ms)
        print(f"min={sorted_ms[0]:.1f} max={sorted_ms[-1]:.1f} mean={mean:.1f}")
        p50_idx = len(sorted_ms) // 2
        print(f"p50={sorted_ms[p50_idx]:.1f}")
        if len(sorted_ms) >= 20:
            p95_idx = min(len(sorted_ms) - 1, int(len(sorted_ms) * 0.95))
            p99_idx = min(len(sorted_ms) - 1, int(len(sorted_ms) * 0.99))
            print(f"p95={sorted_ms[p95_idx]:.1f} p99={sorted_ms[p99_idx]:.1f}")
    if other:
        print("\nnon-success trials (investigate before trusting the deadline):")
        for t in other:
            print(f"  {t}")
        # Codex code-diff r8: a run with any non-readyForBatchDecode trial is
        # an invalid sample set for tuning the deadline — exit nonzero so it
        # can never be mistaken for a clean 30/30 measurement.
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
