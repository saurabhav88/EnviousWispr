#!/usr/bin/env python3
"""Paired comparison of two model arms graded on the SAME cases.

WHY PAIRED, and why the unpaired number is not enough here. `behavior_judge.py`
measures its own instability by re-judging a sample twice: on the EG-1 baseline
run that wobble was **4.7pp**. So two independently-computed pass rates that
differ by less than about five points are not distinguishable from the judge
disagreeing with itself, and quoting such a gap as a model improvement would be
reading noise.

A paired read is far more sensitive because both arms saw the identical case and
the identical rubric, so anything that shifts BOTH verdicts together cancels. The
question stops being "are these two rates different" and becomes "of the cases
where the two arms DISAGREE, do they lean one way", which is McNemar's test.

Reported deliberately:
  * the 2x2 concordance table, so the reader sees how much of the corpus actually
    moved rather than only the net;
  * an exact two-sided binomial p on the discordant pairs (no normal
    approximation, which misbehaves exactly when few cases move);
  * critical (S4) movement counted SEPARATELY, because a change that trades three
    soft fails for one new critical is a regression however the pass rate reads;
  * every flipped case id, because a net number nobody reads case-by-case is how
    a rubric artefact gets shipped as a model win.

`pass` means pass+minor, matching behavior_judge's own headline definition.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from math import comb
from pathlib import Path

PASSING = {"pass", "minor"}


def load_unique(p: Path) -> dict[str, dict]:
    """One row per id, or refuse: a score or candidate file with one id twice (an appended
    rerun, a concatenation) would otherwise keep whichever row came last, and the
    concordance counts would depend on row order while exiting 0."""
    out: dict[str, dict] = {}
    if not p.exists():
        sys.exit(f"FATAL: missing {p}")
    for line in p.read_text().splitlines():
        if line.strip():
            d = json.loads(line)
            cid = str(d["id"])
            if cid in out:
                sys.exit(f"FATAL: {p}: duplicate id {cid}")
            out[cid] = d
    if not out:
        sys.exit(f"FATAL: {p} has no rows")
    return out


def passed(row: dict) -> bool:
    return row.get("verdict") in PASSING


def exact_two_sided_binomial(b: int, c: int) -> float:
    """P(|discordance| at least this extreme) under p=0.5. Exact, not normal:
    with few discordant pairs the approximation is worst precisely where the
    answer matters."""
    n = b + c
    if n == 0:
        return 1.0
    k = min(b, c)
    tail = sum(comb(n, i) for i in range(0, k + 1))
    return min(1.0, 2.0 * tail / (2 ** n))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True, type=Path, help="baseline per_case.jsonl")
    ap.add_argument("--b", required=True, type=Path, help="candidate per_case.jsonl")
    ap.add_argument("--a-name", default="A")
    ap.add_argument("--b-name", default="B")
    ap.add_argument("--json-out", type=Path, default=None)
    ap.add_argument("--show-flips", type=int, default=25)
    # #2851 phase 2: the packed-versus-isolated measurement. `--packing-report` prints,
    # per arm, how many rows carry production's fallback and why, and the two run
    # receipts side by side. It exits nonzero only on three MECHANICAL mismatches: a row
    # without `section_status` (an isolated arm run without `--validate`), a graded row
    # whose `candidate_output` is not the supplied candidate (scores and candidates from
    # different runs), and a duplicate id. Whether the two arms are the same experiment
    # apart from packing is the OPERATOR's reading of the receipts; nothing here
    # certifies it (PR #2902: four cloud rounds and a local enumeration each found a
    # further axis such a check would have to cover, so the check was deleted rather than
    # extended; #2904 carries the enumeration).
    ap.add_argument("--packing-report", action="store_true",
                    help="with --a-candidates/--b-candidates: print fallback counts and both run "
                         "receipts; refuse only rows missing section_status, foreign "
                         "candidate_output, or duplicate ids")
    ap.add_argument("--a-candidates", type=Path, default=None)
    ap.add_argument("--b-candidates", type=Path, default=None)
    args = ap.parse_args()

    A, B = load_unique(args.a), load_unique(args.b)
    shared = sorted(set(A) & set(B))
    if not shared:
        sys.exit("FATAL: the two score files share no case ids")

    if args.packing_report:
        if not args.a_candidates or not args.b_candidates:
            ap.error("--packing-report requires both --a-candidates and --b-candidates")
        receipts: dict[str, list[dict | None]] = {}
        for name, grades, path in ((args.a_name, A, args.a_candidates),
                                   (args.b_name, B, args.b_candidates)):
            candidates = load_unique(path)
            for cid, row in candidates.items():
                if not row.get("section_status"):
                    sys.exit(f"FATAL: {name}/{cid}: section_status missing; rerun the isolated "
                             "arm with --validate (pack mode always writes it)")
            missing = set(grades) - set(candidates)
            if missing:
                sys.exit(f"FATAL: {name}: graded cases with no candidate row: {sorted(missing)[:10]}")
            # PROVENANCE: the graded row carries the text the judge saw (`candidate_output`,
            # behavior_judge.py per_case), so scores cannot be paired with a candidate
            # file they did not come from.
            foreign = [cid for cid in grades
                       if (grades[cid].get("candidate_output") or "") != (candidates[cid].get("candidate") or "")]
            if foreign:
                sys.exit(f"FATAL: {name}: {len(foreign)} graded rows carry a candidate_output that is "
                         f"not the supplied candidate (first: {foreign[:5]}); the scores and the "
                         "candidate file are from different runs, or the judge wrote no "
                         "candidate_output")
            fallbacks = {cid: row["section_status"] for cid, row in candidates.items()
                         if row["section_status"] != "accepted"}
            print(f"{name}: {len(fallbacks)} fallback rows of {len(candidates)}: "
                  f"{json.dumps(fallbacks)[:600]}", file=sys.stderr)
            distinct = {json.dumps(row.get("run"), sort_keys=True) for row in candidates.values()}
            receipts[name] = [json.loads(r) for r in sorted(distinct)]
        print("run receipts, side by side (data for the operator; this report does not "
              "certify that the two arms are the same experiment apart from packing):",
              file=sys.stderr)
        for name in (args.a_name, args.b_name):
            for r in receipts[name]:
                print(f"  {name}: {json.dumps(r, sort_keys=True)}", file=sys.stderr)
        print("  not in the receipt: key route and endpoint, corpus file and --limit, --workers "
              "and retries, pack contents beyond the file name, the judge's own inputs; hold "
              "those equal yourself (#2904 lists the open axes)", file=sys.stderr)

    both_pass = both_fail = 0
    a_only: list[str] = []   # A passed, B failed  -> candidate REGRESSED
    b_only: list[str] = []   # B passed, A failed  -> candidate IMPROVED
    for i in shared:
        pa, pb = passed(A[i]), passed(B[i])
        if pa and pb:
            both_pass += 1
        elif not pa and not pb:
            both_fail += 1
        elif pa:
            a_only.append(i)
        else:
            b_only.append(i)

    n = len(shared)
    a_rate = 100.0 * (both_pass + len(a_only)) / n
    b_rate = 100.0 * (both_pass + len(b_only)) / n
    p = exact_two_sided_binomial(len(a_only), len(b_only))

    a_s4 = {i for i in shared if A[i].get("severity") == "S4"}
    b_s4 = {i for i in shared if B[i].get("severity") == "S4"}

    print(f"PAIRED COMPARISON on {n} cases graded by both arms")
    print(f"  A = {args.a_name}   ({len(A)} scored)")
    print(f"  B = {args.b_name}   ({len(B)} scored)")
    if len(A) != n or len(B) != n:
        print("  NOTE: rates below are recomputed on the shared set and will differ "
              "from each arm's own scoreboard.")
    print()
    print(f"  pass+minor   A {a_rate:5.1f}%    B {b_rate:5.1f}%    "
          f"delta {b_rate - a_rate:+.1f}pp")
    print()
    print("  concordance")
    print(f"    both pass            {both_pass:5d}")
    print(f"    both fail            {both_fail:5d}")
    print(f"    A pass, B fail       {len(a_only):5d}   <- candidate regressed")
    print(f"    B pass, A fail       {len(b_only):5d}   <- candidate improved")
    print(f"    discordant           {len(a_only) + len(b_only):5d}"
          f"   ({100.0*(len(a_only)+len(b_only))/n:.1f}% of corpus moved)")
    print()
    print(f"  McNemar exact two-sided p = {p:.4g}")
    if p < 0.05 and len(b_only) != len(a_only):
        who = args.b_name if len(b_only) > len(a_only) else args.a_name
        print(f"    -> the difference is unlikely to be chance; {who} is ahead.")
    else:
        print("    -> NOT distinguishable from chance. Do not report this as an "
              "improvement or a regression.")
    print()
    print("  criticals (S4)")
    print(f"    A {len(a_s4):5d}      B {len(b_s4):5d}      delta {len(b_s4)-len(a_s4):+d}")
    print(f"    new in B (A was clean)   {len(b_s4 - a_s4):5d}")
    print(f"    fixed in B               {len(a_s4 - b_s4):5d}")
    if b_s4 - a_s4:
        print(f"    NEW CRITICAL IDS: {sorted(b_s4 - a_s4)[:20]}")

    print()
    print(f"  {'category':<44} {'n':>5} {'A':>7} {'B':>7} {'delta':>7} {'A>B':>5} {'B>A':>5}")
    by_cat = defaultdict(list)
    for i in shared:
        by_cat[A[i].get("behavior") or "?"].append(i)
    cat_rows = []
    for c, ids in sorted(by_cat.items()):
        ra = 100.0 * sum(passed(A[i]) for i in ids) / len(ids)
        rb = 100.0 * sum(passed(B[i]) for i in ids) / len(ids)
        reg = sum(1 for i in ids if passed(A[i]) and not passed(B[i]))
        imp = sum(1 for i in ids if passed(B[i]) and not passed(A[i]))
        print(f"  {c:<44} {len(ids):>5} {ra:>6.1f}% {rb:>6.1f}% {rb-ra:>+6.1f} "
              f"{reg:>5} {imp:>5}")
        cat_rows.append({"category": c, "n": len(ids), "a": ra, "b": rb,
                         "delta": rb - ra, "regressed": reg, "improved": imp})

    if args.show_flips:
        print(f"\n  REGRESSED (A passed, B failed), first {args.show_flips}:")
        for i in a_only[:args.show_flips]:
            print(f"    {i}  {A[i].get('behavior','?')}  B:{B[i].get('verdict')}"
                  f"/{B[i].get('severity','')}  {str(B[i].get('reason',''))[:90]}")
        print(f"\n  IMPROVED (B passed, A failed), first {args.show_flips}:")
        for i in b_only[:args.show_flips]:
            print(f"    {i}  {A[i].get('behavior','?')}  A:{A[i].get('verdict')}"
                  f"/{A[i].get('severity','')}  {str(A[i].get('reason',''))[:90]}")

    if args.json_out:
        args.json_out.write_text(json.dumps({
            "n_shared": n, "a_name": args.a_name, "b_name": args.b_name,
            "a_rate": a_rate, "b_rate": b_rate, "delta_pp": b_rate - a_rate,
            "both_pass": both_pass, "both_fail": both_fail,
            "a_pass_b_fail": len(a_only), "b_pass_a_fail": len(b_only),
            "mcnemar_exact_p": p,
            "a_s4": len(a_s4), "b_s4": len(b_s4),
            "new_criticals": sorted(b_s4 - a_s4), "fixed_criticals": sorted(a_s4 - b_s4),
            "regressed_ids": a_only, "improved_ids": b_only,
            "per_category": cat_rows,
        }, indent=1))
        print(f"\nwrote {args.json_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
