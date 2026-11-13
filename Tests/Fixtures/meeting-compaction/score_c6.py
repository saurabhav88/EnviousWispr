"""Score #3147 C6 `C6 raw` lines with the eval scorer the plan names, unchanged.

Usage: python3 -I score_c6.py <worktree> <test log>

Imports `wer` from <worktree>/scripts/eval/build_parakeet_corpus.py and reads the frozen
expectations from <worktree>/Tests/Fixtures/meeting-compaction/c6-matrix.json. Pools word errors
per engine over every matrix segment (original vs compacted) and fails (exit 1) when an engine is
missing, its rows are not the frozen cases, the suite did not pass whole, or (matrix version 2,
one-sided rule) its compacted WER exceeds its original WER by more than the gate. A lower compacted
WER passes and is reported as IMPROVED; every changed row is printed against its reference. A
missing or partial run is never a pass.
"""
import importlib.util
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

worktree, log = Path(sys.argv[1]), Path(sys.argv[2])
scorer_path = worktree / "scripts/eval/build_parakeet_corpus.py"
spec = importlib.util.spec_from_file_location("bpc", scorer_path)
bpc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bpc)
matrix = json.loads((worktree / "Tests/Fixtures/meeting-compaction/c6-matrix.json").read_text())
if matrix.get("version") != 2:
    sys.exit(f"c6-matrix.json is version {matrix.get('version')}; this scorer reads version 2")
gate = matrix["gates"]["maxWERIncreasePoints"]
expected_rows = matrix["expected"]["transcribedRowsPerEngine"]
engines = matrix["expected"]["engines"]


def ref_words(s: str) -> int:
    # Same tokenizer as bpc.wer's inner norm, to turn its rate back into an error count.
    return len(re.sub(r"[^\w\s']", " ", s.lower()).split())


text = log.read_text(errors="replace")
control = "C6 mode control=identity" in text
if control:
    print("identity control run: never C6 evidence")
rows = {}
for line in text.splitlines():
    i = line.find("C6 raw {")
    if i < 0:
        continue
    row = json.loads(line[i + len("C6 raw "):])
    rows[(row["engine"], row["track"], row["variant"], row["segment"])] = row  # echoed lines

print(f"scorer: {scorer_path} :: wer")
# The whole suite must have run and passed, not only its transcription rows.
count = matrix["expected"]["testsInSuite"]
failed = re.search(rf"Test run with {count} tests(?: in \d+ suites?)? passed\b", text) is None
if failed:
    print(f"suite: no passing 'Test run with {count} tests' line")
expected_keys = {
    (t["track"], v, str(s["index"]), s["clip"], s["language"])
    for t in matrix["meeting"]["tracks"]
    for s in t["segments"]
    for v in (["raw", "cleaned"] if t["cleanedTwin"] else ["raw"])
}
for engine in engines:
    mine = [r for k, r in sorted(rows.items()) if k[0] == engine]
    actual_keys = {(r["track"], r["variant"], r["segment"], r["clip"], r["language"]) for r in mine}
    if actual_keys != expected_keys:
        print(f"engine={engine}: rows are not the frozen cases: missing={sorted(expected_keys - actual_keys)} extra={sorted(actual_keys - expected_keys)}")
        failed = True
    words = original_errors = compressed_errors = 0.0
    for r in mine:
        n = ref_words(r["reference"])
        o = bpc.wer(r["reference"], r["original"])
        c = bpc.wer(r["reference"], r["compressed"])
        if n == 0:
            # No reference words (noise only): weight 0 in the pool, so it is checked on its own,
            # one-sided: the compacted take may not add words the original did not.
            # Word counts, because the eval scorer's empty-reference WER is 1.0 for any words.
            original_words = ref_words(r["original"])
            compacted_words = ref_words(r["compressed"])
            if compacted_words > original_words:
                print(f"empty-reference engine={engine} track={r['track']} segment={r['segment']} FAIL (compacted added words)")
                failed = True
            elif compacted_words < original_words:
                print(f"empty-reference engine={engine} track={r['track']} segment={r['segment']} IMPROVED")
        words += n
        original_errors += o * n
        compressed_errors += c * n
        print(
            f"row engine={engine} track={r['track']} variant={r['variant']} segment={r['segment']} "
            f"clip={r['clip']} words={n} originalWER={o*100:.2f} compressedWER={c*100:.2f} "
            f"sameText={r['original'] == r['compressed']}"
        )
        if r["original"] != r["compressed"]:
            # Every changed row, against its reference, for inspection (committed corpus text).
            print(f"  changed reference={r['reference']!r}")
            print(f"  changed original ={r['original']!r}")
            print(f"  changed compacted={r['compressed']!r}")
    if len(mine) != expected_rows or words == 0:
        print(f"total engine={engine} rows={len(mine)} expected={expected_rows} GATE FAIL (incomplete)")
        failed = True
        continue
    ow, cw = original_errors / words * 100, compressed_errors / words * 100
    delta = cw - ow
    ok = delta <= gate + 1e-9  # exactly the gate passes despite float rounding
    failed |= not ok
    note = " IMPROVED (compacted WER lower; changed rows above)" if delta < 0 else ""
    print(
        f"total engine={engine} rows={len(mine)} words={int(words)} originalWER={ow:.2f} "
        f"compressedWER={cw:.2f} deltaPoints={delta:.2f} maxIncrease={gate} "
        f"GATE {'PASS' if ok else 'FAIL'}{note}"
    )
if control:
    print(f"RESULT: CONTROL {'FAIL' if failed else 'PASS'} (not C6 evidence)")
    sys.exit(1 if failed else 2)
print(f"RESULT: {'FAIL' if failed else 'PASS'}")
sys.exit(1 if failed else 0)
