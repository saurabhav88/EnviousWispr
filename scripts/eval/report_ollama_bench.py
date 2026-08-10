#!/usr/bin/env python3
"""Merge the #1950 speed and quality receipts into one ranked table.

TWO AXES, NOT ONE COMPOSITE. A single blended score would let a fast model hide
a trust-breaking failure behind good latency. The ranking is therefore two hard
gates followed by one sort:

  Gate A — SPEED. Median latency must be inside `LLMPolishStep.maxDuration`
           (15s). Past it the user never receives the polish at all, so quality
           is not a question that arises.
  Gate B — TRUST. Zero S4. S4 is the judge's trust-breaking tier: a changed name,
           an invented fact, an obeyed instruction, unusable output. One is
           enough to disqualify a model we would put in front of users.
  SORT   — pass rate, then median latency.

INTERNATIONAL IS REPORTED SEPARATELY, NOT FOLDED IN. A model can be strong in
English and answer a Spanish dictation in English; averaging the two hides
exactly the failure the international cases exist to find.

FAIL CLOSED. A model with a speed receipt but no quality receipt (or the reverse)
is an error, not a row with blanks — a half-measured model silently ranked low
is worse than no ranking.

Usage:
  python3 scripts/eval/report_ollama_bench.py \
      --run-summaries scripts/eval/runs/ollama-bench-1950/candidates/run-summary-*.json \
      --judged scripts/eval/runs/ollama-bench-1950/judged \
      --corpus scripts/eval/corpus/ollama_bench_v1.jsonl \
      --out scripts/eval/runs/ollama-bench-1950/report.md
"""
import argparse
import json
import sys
from pathlib import Path

PIPELINE_DEADLINE_MS = 15_000


def slug(model: str) -> str:
    return model.replace(":", "-").replace(".", "-").replace("/", "-")


def load_json(p: Path):
    with open(p) as f:
        return json.load(f)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-summaries", required=True, nargs="+", type=Path)
    ap.add_argument("--judged", required=True, type=Path)
    ap.add_argument("--corpus", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    intl_ids = set()
    with open(args.corpus) as f:
        for line in f:
            line = line.strip()
            if line:
                row = json.loads(line)
                if row.get("input_source") == "hand_written_international":
                    intl_ids.add(row["id"])
    if not intl_ids:
        print("FAIL: corpus contains no international cases; the split would be vacuous",
              file=sys.stderr)
        return 2

    # Keyed by (model, arm), NOT by model alone. The documented invocation globs
    # `run-summary-*.json`, so reporting a shipped run together with a
    # `--suffix` / `--think-override` / repeat-penalty arm passes the SAME model
    # more than once. Keying by model silently kept whichever arm was read last
    # and printed a report that looked complete, which is the worst shape a
    # measurement tool can have: a number whose scope is smaller than it appears.
    # The arm identity was already available in the candidate path the runner
    # records; only the key ignored it.
    speed: dict[tuple[str, str], dict] = {}
    for p in args.run_summaries:
        if not p.exists():
            print(f"FAIL: missing run summary {p}", file=sys.stderr)
            return 2
        for m in load_json(p)["models"]:
            key = (m["model"], Path(m["candidates"]).stem)
            if key in speed:
                # Same model AND same arm from two summaries is ambiguous input,
                # not a mergeable duplicate. Fail closed rather than pick one.
                print(f"FAIL: {key[0]} arm {key[1]!r} appears in more than one run "
                      f"summary; pass one summary per arm", file=sys.stderr)
                return 2
            speed[key] = m

    rows = []
    problems = []
    for (model, cand_stem), sp in speed.items():
        jdir = args.judged / cand_stem
        summary_path = jdir / "summary.json"
        per_case_path = jdir / "per_case.jsonl"
        if not summary_path.exists() or not per_case_path.exists():
            # A model that failed EVERY request produced nothing to judge, so a
            # missing receipt is the expected state and not an error. Any other
            # missing receipt is a hole, and a hole silently ranked low is worse
            # than no ranking at all.
            if sp["errors"] >= sp["cases"]:
                rows.append({
                    "model": model, "arm": cand_stem,
                    "isRemote": sp["isRemote"], "thinks": sp["thinks"],
                    "thinkSent": sp["thinkSent"], "parameterSize": sp.get("parameterSize"),
                    "quantization": sp.get("quantization"), "errors": sp["errors"],
                    "cases": sp["cases"], "medianMs": sp["latencyMsMedian"],
                    "meanMs": sp["latencyMsMean"], "maxMs": sp["latencyMsMax"],
                    "overDeadline": sp["overDeadline"], "passPct": None, "s4": 0,
                    "eng": {"n": 0, "pass_pct": None, "s3": 0, "s4": 0},
                    "intl": {"n": 0, "pass_pct": None, "s3": 0, "s4": 0},
                    "failure_types": {},
                    "unmeasuredReason": sp.get("warm", ""),
                })
                continue
            problems.append(f"{model}: no quality receipt at {jdir}")
            continue
        summary = load_json(summary_path)

        # A judge receipt can exist and still be PARTIAL. When cases are dropped
        # or engine-skipped, behavior_judge writes summary.json, marks its
        # release gate INCOMPLETE and exits nonzero — but this report read the
        # file anyway and ranked the model on whatever cases survived, which can
        # promote it to Recommended on a subset. Refuse the receipt instead: an
        # unranked model is a gap someone re-runs, a wrongly-ranked one is a
        # recommendation nobody re-checks.
        release_verdict = (summary.get("release_gate") or {}).get("verdict")
        if release_verdict == "INCOMPLETE":
            problems.append(
                f"{model} ({cand_stem}): judge receipt is INCOMPLETE — "
                f"{len(summary.get('skipped', []))} engine-skipped, "
                f"{len(summary.get('missing_scores', []))} judge-dropped; re-judge the gaps")
            continue

        # Independent reconciliation against the RUN's own case count, because
        # the check above trusts the judge to have noticed its own gap. These are
        # two different sources, so agreeing is evidence and disagreeing is a
        # hole no single receipt could reveal.
        judge_overall = summary.get("overall") or {}
        scored = judge_overall.get("total_scored")
        infra_skipped = judge_overall.get("infra_skipped") or 0
        expected_scored = sp["cases"] - sp["errors"]
        if scored is None or scored + infra_skipped != expected_scored:
            problems.append(
                f"{model} ({cand_stem}): judged {scored} + {infra_skipped} skipped does not "
                f"reconcile with the run's {expected_scored} non-error cases; re-judge")
            continue

        per_case = [json.loads(l) for l in open(per_case_path) if l.strip()]

        def split(pred):
            items = [x for x in per_case if pred(x)]
            n = len(items)
            passed = sum(1 for x in items if x["verdict"] in ("pass", "minor"))
            return {
                "n": n,
                "pass_pct": round(100 * passed / n, 1) if n else None,
                "s3": sum(1 for x in items if x["severity"] == "S3"),
                "s4": sum(1 for x in items if x["severity"] == "S4"),
            }

        eng = split(lambda x: x["id"] not in intl_ids)
        intl = split(lambda x: x["id"] in intl_ids)
        overall = summary.get("overall", {})
        rows.append({
            "model": model,
            "arm": cand_stem,
            "isRemote": sp["isRemote"],
            "thinks": sp["thinks"],
            "thinkSent": sp["thinkSent"],
            "parameterSize": sp.get("parameterSize"),
            "quantization": sp.get("quantization"),
            "errors": sp["errors"],
            "cases": sp["cases"],
            "medianMs": sp["latencyMsMedian"],
            "meanMs": sp["latencyMsMean"],
            "maxMs": sp["latencyMsMax"],
            "overDeadline": sp["overDeadline"],
            "passPct": overall.get("pass_rate_pct"),
            "s4": overall.get("critical_fail_count", 0),
            "eng": eng,
            "intl": intl,
            "failure_types": overall.get("failure_type_counts", {}),
        })

    if problems:
        print("FAIL: incomplete receipts:\n  " + "\n  ".join(problems), file=sys.stderr)
        return 2
    if not rows:
        print("FAIL: no models to report", file=sys.stderr)
        return 2

    def tier(r) -> str:
        # UNMEASURED is not a quality verdict and must not be ranked as one. A
        # model that refused every request behind a paywall produced no evidence
        # either way; sorting it to the bottom would read as "we tested it and it
        # was bad", which is a claim the run cannot support.
        if r["errors"] >= r["cases"]:
            return "Not measurable"
        if r["medianMs"] is None or r["medianMs"] > PIPELINE_DEADLINE_MS:
            return "Not recommended"
        if r["s4"] > 0:
            return "Not recommended"
        if r["errors"] > 0:
            # A partial failure IS evidence: at shipped settings this model
            # sometimes returns nothing the user can paste.
            return "Not recommended"
        if (r["passPct"] or 0) >= 70:
            return "Recommended"
        return "Usable"

    for r in rows:
        r["tier"] = tier(r)

    order = {"Recommended": 0, "Usable": 1, "Not recommended": 2, "Not measurable": 3}
    rows.sort(key=lambda r: (order[r["tier"]], -(r["passPct"] or 0), r["medianMs"] or 10**9))

    def ms(v):
        return "—" if v is None else (f"{v/1000:.1f}s" if v >= 1000 else f"{v}ms")

    # Preserving both arms in the DATA is pointless if the reader cannot tell
    # them apart in the artifact they actually read. Disambiguate only where it
    # is needed: a model with one arm keeps its bare name, so the ordinary
    # single-run report is unchanged, while two arms of the same model are
    # labelled with the arm that produced each row.
    arm_counts: dict[str, int] = {}
    for r in rows:
        arm_counts[r["model"]] = arm_counts.get(r["model"], 0) + 1

    lines = []
    lines.append("| # | Model | Where | Pass | English | International | S4 | Median | Max | Verdict |")
    lines.append("|---:|---|---|---:|---:|---:|---:|---:|---:|---|")
    for i, r in enumerate(rows, 1):
        where = "Ollama cloud" if r["isRemote"] else "Your Mac"
        label = f"`{r['model']}`"
        if arm_counts[r["model"]] > 1:
            label = f"{label} <br>_{r['arm']}_"
        eng = f"{r['eng']['pass_pct']}%" if r["eng"]["pass_pct"] is not None else "—"
        intl = f"{r['intl']['pass_pct']}%" if r["intl"]["pass_pct"] is not None else "—"
        errnote = f" ({r['errors']} err)" if r["errors"] else ""
        overall = "—" if r["passPct"] is None else f"{r['passPct']}%"
        lines.append(
            f"| {i} | {label} | {where} | {overall} | {eng} | {intl} | "
            f"{r['s4']} | {ms(r['medianMs'])} | {ms(r['maxMs'])}{errnote} | {r['tier']} |")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(lines) + "\n")
    with open(args.out.with_suffix(".json"), "w") as f:
        json.dump(rows, f, indent=2)
    print("\n".join(lines))
    print(f"\nwrote {args.out} and {args.out.with_suffix('.json')}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
