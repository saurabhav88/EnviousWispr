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
SCORE_FIELDS = ["per_case_digest",
                "pass_rate_pct", "critical_fail_count", "s3_count", "n",
                "per_behavior", "trap_metrics", "passthrough_safety",
                "mixed_metrics", "critical_smoke", "pairwise", "run_complete"]
# Produced by the gate, which this refactor deliberately changes.
GATE_FIELDS = ["gate_verdict", "gate_checks"]

before = json.loads(pathlib.Path(sys.argv[1]).read_text())["results"]
after = json.loads(pathlib.Path(sys.argv[2]).read_text())["results"]

only_before = sorted(set(before) - set(after))
only_after = sorted(set(after) - set(before))
shared = sorted(set(before) & set(after))

score_moves, gate_moves, unusable, caveated = [], [], [], []
for k in shared:
    b, a = before[k], after[k]
    # THREE buckets, because two is what makes this wrong in one direction or the
    # other. Cloud review (PR #2576) was right that a `mismatch` entry still carries
    # a fingerprint, so a bare key test counts it as ordinary evidence. Dropping it
    # outright is the over-correction: `mismatch` describes disagreement with the
    # STORED receipt, and this tool compares the two REPLAYS, where that is not the
    # question. Measured here — dropping them lost 2 of 71 receipts that both arms
    # had scored identically.
    #
    # So: a missing fingerprint or a missing per-case digest is UNUSABLE and fatal
    # (`None == None` compares equal and would silently retire the strongest field).
    # A state that DIFFERS between the arms is unusable too — the arms did not do the
    # same thing. Both arms in the same non-replayed state are COMPARED AND FLAGGED:
    # the comparison is valid, and the flag is there because a receipt whose inputs
    # resolved WRONG would also agree with itself across arms, which is the hazard
    # the finding was pointing at.
    if ("fingerprint" not in b or "fingerprint" not in a
            or b["fingerprint"].get("per_case_digest") is None
            or a["fingerprint"].get("per_case_digest") is None
            or b.get("state") != a.get("state")):
        unusable.append((k, b.get("state"), a.get("state")))
        continue
    if b.get("state") != "replayed":
        caveated.append((k, b.get("state")))
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
print(f"unusable (fatal): {len(unusable)}")
for k, sb, sa in unusable:
    print(f"    {k}  before={sb} after={sa}")
print(f"compared but FLAGGED (both arms in the same non-replayed state): {len(caveated)}")
for k, st in caveated:
    print(f"    {k}  state={st} in both arms — the arms are comparable to each other, "
          f"but neither reproduces its stored receipt; read the reason before relying on it")

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
clean = len(shared) - len(caveated)
print(f"\nVERDICT: SCORE-NEUTRAL across all {len(shared)} receipts "
      f"({clean} reproducing their stored receipt, {len(caveated)} compared and flagged)")
