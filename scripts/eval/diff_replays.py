#!/usr/bin/env python3
"""Compare two replay runs and answer ONE question: did any SCORE move.

The gate is expected to change — that is the point of the refactor — so gate
fields are reported separately and never counted as a score difference. Mixing
them would make the answer unreadable in exactly the direction that hides a real
regression.

Usage: diff_replays.py <before.json> <after.json>
"""

import json
import pathlib
import sys

# Everything here is produced by the SCORING code. None of it may move.
SCORE_FIELDS = ["pass_rate_pct", "critical_fail_count", "s3_count", "n",
                "per_behavior", "trap_metrics", "passthrough_safety",
                "mixed_metrics", "critical_smoke", "pairwise", "run_complete"]
# Produced by the gate, which this refactor deliberately changes.
GATE_FIELDS = ["gate_verdict", "gate_checks"]

before = json.loads(pathlib.Path(sys.argv[1]).read_text())["results"]
after = json.loads(pathlib.Path(sys.argv[2]).read_text())["results"]

only_before = sorted(set(before) - set(after))
only_after = sorted(set(after) - set(before))
shared = sorted(set(before) & set(after))

score_moves, gate_moves, unusable = [], [], []
for k in shared:
    b, a = before[k], after[k]
    if "fingerprint" not in b or "fingerprint" not in a:
        unusable.append((k, b.get("state"), a.get("state")))
        continue
    fb, fa = b["fingerprint"], a["fingerprint"]
    moved = [f for f in SCORE_FIELDS if fb.get(f) != fa.get(f)]
    if moved:
        score_moves.append((k, moved, {f: (fb.get(f), fa.get(f)) for f in moved}))
    gmoved = [f for f in GATE_FIELDS if fb.get(f) != fa.get(f)]
    if gmoved:
        gate_moves.append((k, gmoved))

print(f"receipts compared : {len(shared)}")
print(f"only in before    : {len(only_before)}  {only_before[:3]}")
print(f"only in after     : {len(only_after)}  {only_after[:3]}")
print(f"unusable (no fingerprint on one side): {len(unusable)}")
for k, sb, sa in unusable:
    print(f"    {k}  before={sb} after={sa}")

print(f"\nSCORES MOVED  : {len(score_moves)}")
for k, moved, detail in score_moves:
    print(f"  {k}\n    fields: {moved}")
    for f, (bv, av) in detail.items():
        print(f"      {f}: {json.dumps(bv)[:160]}  ->  {json.dumps(av)[:160]}")

print(f"\nGATE CHANGED  : {len(gate_moves)} (expected — the gate is what this refactor edits)")

if only_before or only_after or unusable:
    print("\nVERDICT: INCONCLUSIVE — the two runs do not cover the same receipts")
    sys.exit(2)
if score_moves:
    print("\nVERDICT: NOT SCORE-NEUTRAL — the refactor moved a score")
    sys.exit(1)
print(f"\nVERDICT: SCORE-NEUTRAL across all {len(shared)} receipts")
