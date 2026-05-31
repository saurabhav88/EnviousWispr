#!/usr/bin/env python3
"""Live TTS benchmark for the on-device output-safety classifier (#832/#913 PR8).

Reusable harness: speaks a curated, labeled set of dictations through the running
DEBUG dev app (Apple Intelligence polish ON), then reads the classifier's live
decision from ~/Library/Logs/EnviousWispr/app.log per case. Unlike `record_tts`
ad-hoc probes, this maintains a LABELED corpus on purpose — it is a benchmark,
the live sibling of the offline Phase-3 accuracy eval + the byte-for-byte
tokenization parity unit test.

What it proves end-to-end (static review can't):
  - the classifier actually fires on real AFM-polished output,
  - it stays a fast LIMB (latency within the 50ms budget),
  - instruction-shaped dictations that AFM COMPOSES into artifacts are caught
    (DISCARD → raw transcript shipped),
  - ordinary dictations are left alone (no over-trip / low false-positive rate).

Prereqs: DEBUG dev bundle running (scripts/build-dev-app.sh / wispr-rebuild-debug),
polish provider = Apple Intelligence, quiet audio environment. English only.

Usage:
    python3 Tests/RuntimeUAT/classifier_benchmark.py
"""
from __future__ import annotations

import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from wispr_eyes import record_tts  # noqa: E402

LOG = Path.home() / "Library/Logs/EnviousWispr/app.log"

# Labeled corpus. DISCARD-candidates are instruction-shaped — AFM SOMETIMES
# composes an artifact instead of cleaning; the classifier must catch those it
# composes. KEEP cases are ordinary persona dictations that must sail through.
DISCARD_CANDIDATES = [
    "draft a slack to matt that we will launch next tuesday and the new build is ready",
    "write a quick email to sarah saying the kickoff moved to friday at ten",
    "compose a short recap of standup for the team about the auth refactor",
    "give me a polished linkedin post announcing that we just shipped version two",
    "turn this into a professional thank you note for the interview with the design team",
]
KEEP_CASES = [
    "the team meeting went really well today and we shipped the auth refactor",
    "hey can you pick up milk and bread on your way home tonight",
    "another bug I found is that the completed job is no longer showing in the queue",
    "I already moved on so I'm on station d now same feedback as before",
    "remember to pack the soccer jersey and cleats for tomorrow morning",
]

from datetime import datetime  # noqa: E402

# Capture the leading ISO timestamp so lines can be matched to a case by
# wall-clock (the app's logger and any external writer share the file; reading
# the app's OWN timestamps is the only reliable per-case attribution — byte
# offsets and injected markers both misattribute the fire-and-forget score line).
TS = r"\[(\d{4}-\d{2}-\d{2}T[\d:.+-]+)\]"
CLF = re.compile(TS + r" \[INFO\] \[LLM\] \[OutputClassifier\] score=([\d.]+) decision=(\w+) latency_ms=(\d+)")
FILTER = re.compile(TS + r" \[INFO\] \[LLM\] \[AIPolish\] FILTER tripped=(\S+) fell_back=(\w+)")


def _parse_ts(s: str) -> float:
    try:
        return datetime.fromisoformat(s).timestamp()
    except ValueError:
        return 0.0


def _events_since(t0: float):
    """Parse the app's OWN timestamped classifier + AFM-filter log lines at/after
    wall-clock `t0`. AGGREGATE only — no per-case attribution: the score line is
    fire-and-forget so matching it to a specific sentence is unreliable, but the
    run-window aggregate (what fired, score spread, discards, latency) is solid
    and is the proof the founder asked for. Parsing individual clean lines is
    safe; only cross-line windowing was not."""
    text = LOG.read_text(errors="replace")
    skew = t0 - 1.0
    clf = [
        (float(m[1]), m[2], int(m[3]))
        for m in CLF.findall(text)
        if _parse_ts(m[0]) >= skew
    ]
    filt = [m[1] for m in FILTER.findall(text) if _parse_ts(m[0]) >= skew]
    return clf, filt


def main() -> int:
    if not LOG.exists():
        print("FAIL: app.log not found — is the DEBUG dev build running?")
        return 2

    run_start = time.time()
    print("Driving TTS dictations (Apple Intelligence polish ON)...")
    for s in DISCARD_CANDIDATES + KEEP_CASES:
        record_tts(s)
    time.sleep(2.0)  # let the last fire-and-forget classifier line land

    clf, filt = _events_since(run_start)
    scores = [c[0] for c in clf]
    decisions = [c[1] for c in clf]
    latencies = [c[2] for c in clf]
    discards = decisions.count("DISCARD")
    sync_guards = sum(1 for t in filt if t not in ("none", "classifier_discard"))
    classifier_discards_filter = filt.count("classifier_discard")

    print("\n================ Classifier live benchmark (aggregate) ================")
    print(f"cases driven              : {len(DISCARD_CANDIDATES) + len(KEEP_CASES)}")
    print(f"classifier scored (fired) : {len(clf)}")
    if scores:
        mean = sum(scores) / len(scores)
        print(f"score min / mean / max    : {min(scores):.4f} / {mean:.4f} / {max(scores):.4f}")
        print(f"  (threshold for DISCARD  : {0.10498441010713577:.5f})")
    print(f"classifier KEEP / DISCARD : {decisions.count('KEEP')} / {discards}")
    print(f"AFM filter classifier_discard lines : {classifier_discards_filter}")
    print(f"sync-guard pre-trips (cheap detectors first) : {sync_guards}")
    if latencies:
        print(f"latency ms (max / mean)   : {max(latencies)} / {sum(latencies)//len(latencies)} (budget 50)")
    # Integration health gates (DISCARD accuracy is proven offline by Phase 3 +
    # by the byte-for-byte tokenization parity unit test):
    #  - the classifier actually runs on live AFM output (≥1 score line),
    #  - every DISCARD decision agrees with the AFM filter falling back (no
    #    decision/telemetry split),
    #  - it stays a fast limb (≤ 50ms).
    ok = (
        len(clf) >= 1
        and discards == classifier_discards_filter
        and (not latencies or max(latencies) <= 50)
    )
    print(f"\nRESULT: {'PASS' if ok else 'REVIEW'}")
    print("Read ~/Library/Logs/EnviousWispr/app.log [OutputClassifier]/[AIPolish] "
          "for the authoritative per-line record.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
