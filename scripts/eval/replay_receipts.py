#!/usr/bin/env python3
"""Replay every registry receipt through behavior_judge.py at ZERO judge cost.

Each receipt's `per_case.jsonl` holds the judge's verdicts, and `--verdicts`
re-aggregates from them without calling the judge. So the SCORING code can be
re-run over frozen judge output, which makes "did this refactor change any
score" a MEASUREMENT rather than an assertion.

Run once before touching the scorer and once after; diff the two JSON outputs.
An identical diff is the only evidence that a rubric-identity change is
score-neutral.

FAILS LOUD, never silently skips: a receipt whose inputs cannot be resolved is
recorded as `unresolved` with the reason, and the summary prints the count. A
replay that disagrees with its own stored summary is recorded as `mismatch` —
that is a defect in the harness or a moved input, and it means this receipt
cannot serve as evidence either way.

Usage: replay_all_receipts.py <out.json> [--limit N]
"""

import json
import pathlib
import subprocess
import sys
import tempfile

# Derived from THIS file, never a literal and never cwd: a hardcoded absolute
# path pins whatever branch another checkout happens to be on, and a relative
# one verifies against whichever tree the caller stood in.
REPO = pathlib.Path(__file__).resolve().parents[2]
JUDGE = REPO / "scripts/eval/behavior_judge.py"
REGISTRY = REPO / "scripts/eval/model-registry.json"

# `judge_stable` is the ONE check a replay legitimately cannot reproduce: it
# compares pass-rate across judge REPLICATIONS, and a replay re-aggregates a
# single frozen set of verdicts, so there is nothing to replicate. Measured
# rather than assumed — across the first five receipts the ONLY difference was
# this check's absence, every check present in both agreed exactly, and the
# replay never invented a check. Dropping it is therefore a normalisation, not a
# weakening; `dropped_checks` is emitted so a SECOND unreproducible check could
# never hide inside the same exemption.
REPLAY_CANNOT_REPRODUCE = {"judge_stable"}

# Produced by the GATE, not the scorer. Recorded in the fingerprint so
# diff_replays.py can report gate movement, but never compared against a stored
# receipt — see the note at the comparison.
GATE_FIELDS = {"gate_verdict", "gate_checks"}


# The fields that carry a SCORE. A refactor may not move any of them.
def fingerprint(summary: dict) -> dict:
    o = summary.get("overall", {})
    g = summary.get("release_gate", {})
    checks = g.get("checks") or []
    kept = [c for c in checks if c.get("check") not in REPLAY_CANNOT_REPRODUCE]
    dropped = sorted(c.get("check") for c in checks
                     if c.get("check") in REPLAY_CANNOT_REPRODUCE)
    del dropped  # reported by dropped_checks(), never compared — see below
    return {
        "pass_rate_pct": o.get("pass_rate_pct"),
        "critical_fail_count": o.get("critical_fail_count"),
        "s3_count": o.get("s3_count"),
        "n": o.get("n"),
        "per_behavior": summary.get("per_behavior"),
        "trap_metrics": summary.get("trap_metrics"),
        "passthrough_safety": summary.get("passthrough_safety"),
        "mixed_metrics": summary.get("mixed_metrics"),
        "critical_smoke": summary.get("critical_smoke"),
        "pairwise": summary.get("pairwise"),
        "run_complete": summary.get("run_complete"),
        "gate_verdict": g.get("verdict"),
        "gate_checks": kept,
    }


def dropped_checks(summary: dict) -> list[str]:
    """Which unreproducible checks this summary carried. Reported beside the
    comparison, never inside it."""
    return sorted(c.get("check") for c in (summary.get("release_gate", {}).get("checks") or [])
                  if c.get("check") in REPLAY_CANNOT_REPRODUCE)


def resolve(name: str, receipt_dir: pathlib.Path) -> pathlib.Path | None:
    """Find an input file named in meta. Tries the receipt's own run dir first,
    then the corpus dir, then a repo-wide search — the last one is why this is a
    function and not a constant: receipts span months and inputs have moved."""
    if not name:
        return None
    for cand in (receipt_dir / name,
                 receipt_dir.parent / name,
                 REPO / "scripts/eval/corpus" / name,
                 REPO / name):
        if cand.exists():
            return cand
    hits = sorted((REPO / "scripts/eval").rglob(name))
    return hits[0] if len(hits) == 1 else None


def main() -> int:
    out_path = pathlib.Path(sys.argv[1])
    limit = None
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])

    reg = json.loads(REGISTRY.read_text())
    targets = []
    for art in reg["artifacts"]:
        for ev in art.get("evaluations", []):
            targets.append((art["artifactId"], ev))
    if limit:
        targets = targets[:limit]

    results = {}
    counts = {"replayed": 0, "mismatch": 0, "unresolved": 0, "judge_error": 0}

    for artifact_id, ev in targets:
        key = f"{artifact_id}::{ev['summaryPath']}"
        sp = REPO / ev["summaryPath"]
        if not sp.exists():
            results[key] = {"state": "unresolved", "why": f"summary missing: {ev['summaryPath']}"}
            counts["unresolved"] += 1
            continue
        stored = json.loads(sp.read_text())
        meta = stored.get("meta", {})
        rdir = sp.parent
        verdicts = rdir / "per_case.jsonl"
        if not verdicts.exists():
            results[key] = {"state": "unresolved", "why": "no per_case.jsonl beside summary"}
            counts["unresolved"] += 1
            continue

        corpora = [resolve(c, rdir) for c in (meta.get("corpus_files") or [])]
        cand = resolve(meta.get("candidates_file"), rdir)
        prod = resolve(meta.get("production_file"), rdir)
        if not corpora or any(c is None for c in corpora) or cand is None:
            results[key] = {"state": "unresolved",
                            "why": f"corpus={meta.get('corpus_files')} candidates={meta.get('candidates_file')}"}
            counts["unresolved"] += 1
            continue

        with tempfile.TemporaryDirectory() as td:
            cmd = [sys.executable, "-u", str(JUDGE), "--system", meta.get("system", "new"),
                   "--corpus", *[str(c) for c in corpora],
                   "--candidates", str(cand),
                   "--verdicts", str(verdicts),
                   "--out", td]
            if prod is not None:
                cmd += ["--production", str(prod)]
            proc = subprocess.run(cmd, capture_output=True, text=True, cwd=str(REPO))
            replayed_path = pathlib.Path(td) / "summary.json"
            # The judge's EXIT CODE is the release-gate verdict, not a run
            # status: a BLOCK exits 1 having scored everything correctly. So the
            # oracle is the ARTIFACT, never the code.
            if not replayed_path.exists():
                results[key] = {"state": "judge_error", "rc": proc.returncode,
                                "stderr": proc.stderr[-400:]}
                counts["judge_error"] += 1
                continue
            replayed = json.loads(replayed_path.read_text())

        fp_new = fingerprint(replayed)
        fp_old = fingerprint(stored)
        # Compare only the SCORING fields against the stored receipt. The GATE is
        # expected to differ the moment anyone edits release_gate.py, so including
        # it would turn every receipt into a `mismatch` and destroy the one signal
        # this state carries: a score that no longer reproduces. Gate movement is
        # the business of diff_replays.py, which compares two REPLAYS.
        cmp_new = {k: v for k, v in fp_new.items() if k not in GATE_FIELDS}
        cmp_old = {k: v for k, v in fp_old.items() if k not in GATE_FIELDS}
        entry = {"state": "replayed", "fingerprint": fp_new,
                 "agrees_with_stored": cmp_new == cmp_old,
                 "dropped_from_stored": dropped_checks(stored),
                 "dropped_from_replay": dropped_checks(replayed),
                 "rubricIdentity": ev.get("rubricIdentity"),
                 "corpus": ev.get("corpus"), "casesScored": ev.get("casesScored")}
        if cmp_new != cmp_old:
            entry["state"] = "mismatch"
            entry["stored_fingerprint"] = fp_old
            counts["mismatch"] += 1
        else:
            counts["replayed"] += 1
        results[key] = entry
        print(f"[{entry['state']:>10}] {key}", flush=True)

    out_path.write_text(json.dumps({"counts": counts, "results": results},
                                   indent=1, sort_keys=True))
    print("\n--- counts ---")
    for k, v in counts.items():
        print(f"  {k}: {v}")
    print(f"\nwrote {out_path}")
    # A mismatch against the STORED summary means this receipt cannot serve as
    # evidence in either direction; say so loudly rather than exiting 0.
    return 1 if counts["mismatch"] or counts["judge_error"] else 0


if __name__ == "__main__":
    sys.exit(main())
