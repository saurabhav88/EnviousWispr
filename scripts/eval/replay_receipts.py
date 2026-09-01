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

import hashlib
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
# Receipts live under `scripts/eval/runs/`, which is GITIGNORED — so a WORKTREE has
# none of them and every receipt resolves as missing. The code root and the receipt
# root are therefore two different questions, and conflating them made a worktree run
# report 71 individual unresolved receipts rather than one missing directory.
# Defaults to the code root; point it at the main checkout from a worktree.
RECEIPTS_ROOT = REPO

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


# EXCLUDED BY NAME, and the list is short on purpose. An INCLUDE list is a partial
# check wearing a complete one's clothes: it covers the fields whoever wrote it
# thought of, and a scorer change touching any other field passes. The first version
# of this digest hashed four fields — id, verdict, severity, behavior — and cloud
# review pointed out that `coerce_new_score()` also emits scored booleans,
# `pairwise_vs_production`, `failure_types` and changed-content detail, none of which
# were covered. So the rule inverts: hash EVERYTHING, and name the few fields that
# are not a score.
#
# `latencyMs` is wall-clock and differs run to run, so including it would make every
# comparison fail. `rationale` is the judge's free text, which a replay carries
# through verbatim from the frozen verdicts; it is not produced by the scorer.
PER_CASE_EXCLUDE = {"latencyMs", "rationale"}


def per_case_digest(per_case_path: pathlib.Path) -> str | None:
    """A digest over EVERY scored field of EVERY per-case row, keyed by case id.

    The aggregates below can agree while individual verdicts move: swap a `pass`
    for a `minor` in one case and the reverse in another within the same behavior
    and the pass rate, the S4 count and the per-behavior table are all unchanged.
    Cloud review raised this on PR #2576 — without it, "SCORES MOVED: 0" is a claim
    about TOTALS wearing the words of a claim about scores.

    Sorted by id so row ORDER cannot register as a change; JSON-serialised with
    sorted keys so key order cannot either. Returns None when the file is absent,
    which the caller must treat as unusable rather than as agreement.
    """
    if not per_case_path.exists():
        return None
    rows = []
    for line in per_case_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except ValueError:
            return None
        rows.append((str(r.get("id")),
                     {k: v for k, v in sorted(r.items()) if k not in PER_CASE_EXCLUDE}))
    rows.sort(key=lambda t: t[0])
    return hashlib.sha256(
        json.dumps(rows, sort_keys=True, ensure_ascii=False).encode("utf-8")
    ).hexdigest()[:16]


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
                 RECEIPTS_ROOT / "scripts/eval/corpus" / name,
                 REPO / "scripts/eval/corpus" / name,
                 RECEIPTS_ROOT / name):
        if cand.exists():
            return cand
    hits = sorted((RECEIPTS_ROOT / "scripts/eval").rglob(name))
    return hits[0] if len(hits) == 1 else None


def main() -> int:
    out_path = pathlib.Path(sys.argv[1])
    limit = None
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])
    global RECEIPTS_ROOT
    if "--receipts-root" in sys.argv:
        RECEIPTS_ROOT = pathlib.Path(sys.argv[sys.argv.index("--receipts-root") + 1]).resolve()

    # REFUSE on the missing DIRECTORY, loudly and once. Reporting it as N missing
    # receipts describes the symptom N times and names the cause zero times.
    runs = RECEIPTS_ROOT / "scripts/eval/runs"
    if not runs.is_dir():
        print(f"REFUSE: no receipts under {runs}. That directory is gitignored, so a "
              f"worktree does not have it — pass --receipts-root <main checkout>.",
              file=sys.stderr)
        return 2

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
        sp = RECEIPTS_ROOT / ev["summaryPath"]
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
        # A NAMED production file that does not resolve is UNRESOLVED, not "run it
        # without --production". Dropping it silently removes the pairwise evidence
        # from the fingerprint, and if BOTH arms drop it the same way the comparison
        # still reports score-neutral over a receipt neither arm fully scored.
        prod_named = meta.get("production_file")
        if not corpora or any(c is None for c in corpora) or cand is None or (
                prod_named and prod is None):
            results[key] = {"state": "unresolved",
                            "why": (f"corpus={meta.get('corpus_files')} "
                                    f"candidates={meta.get('candidates_file')} "
                                    f"production={prod_named}"
                                    + (" (NAMED but unresolvable)"
                                       if prod_named and prod is None else ""))}
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
            # Read INSIDE the temp dir's lifetime, or the digest is always None
            # and the strongest half of this comparison silently vanishes.
            replay_digest = per_case_digest(pathlib.Path(td) / "per_case.jsonl")

        fp_new = fingerprint(replayed)
        fp_old = fingerprint(stored)
        # Compare only the SCORING fields against the stored receipt. The GATE is
        # expected to differ the moment anyone edits release_gate.py, so including
        # it would turn every receipt into a `mismatch` and destroy the one signal
        # this state carries: a score that no longer reproduces. Gate movement is
        # the business of diff_replays.py, which compares two REPLAYS.
        cmp_new = {k: v for k, v in fp_new.items() if k not in GATE_FIELDS}
        cmp_old = {k: v for k, v in fp_old.items() if k not in GATE_FIELDS}
        fp_new["per_case_digest"] = replay_digest
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
    # UNRESOLVED counts too. A run where nothing resolved produces "replayed: 0,
    # mismatch: 0" and exited 0 — a sweep whose emptiness reads as success, which is
    # this repo's silent-empty family arriving in the tool built to prevent it.
    # Measured: a worktree run resolved NOTHING and still exited 0.
    bad = counts["mismatch"] + counts["judge_error"] + counts["unresolved"]
    if counts["replayed"] == 0:
        print("REFUSE: not one receipt replayed; this is an instrument failure, "
              "not a clean result", file=sys.stderr)
        return 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
