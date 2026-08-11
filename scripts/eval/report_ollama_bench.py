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
        run = load_json(p)
        # Case IDs are reused across corpus versions, so merging summaries built
        # from different corpora would compare models on different inputs while
        # every ID lined up perfectly. The runner records which corpus it used;
        # this is the only place that can notice a mismatch.
        run_corpus = run.get("corpus")
        if run_corpus is not None and Path(run_corpus).name != Path(args.corpus).name:
            print(f"FAIL: {p.name} was produced from corpus {run_corpus!r}, but this report "
                  f"was given {str(args.corpus)!r}; they are not comparable", file=sys.stderr)
            return 2
        for m in run["models"]:
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
        # A corrupt receipt is a refusal like any other and must name the MODEL,
        # not a line number. Reading it unguarded aborted the WHOLE report on one
        # bad file — losing fifteen good arms — and printed a traceback where
        # every sibling refusal prints "<model> (<arm>): <reason>; re-judge".
        # The caching layer has always shape-checked here (`receipt_cacheable`'s
        # isinstance guard); this closes the same gap in the ranking layer.
        # Guarded at the call site rather than inside `load_json`, because the
        # run-summary caller above wants a DIFFERENT message with no per-model
        # attribution, and one shared sentence would be wrong for both.
        try:
            summary = load_json(summary_path)
        # ValueError covers BOTH decode failures: json.JSONDecodeError and
        # UnicodeDecodeError (invalid UTF-8) are both subclasses, and a
        # JSONDecodeError-only tuple silently missed the second one.
        except (OSError, ValueError) as exc:
            problems.append(f"{model} ({cand_stem}): judge receipt is unreadable "
                            f"({exc.__class__.__name__}); re-judge")
            continue
        if not isinstance(summary, dict):
            problems.append(f"{model} ({cand_stem}): judge receipt is valid JSON but not "
                            f"an object ({type(summary).__name__}); re-judge")
            continue

        # A judge receipt can exist and still be PARTIAL. When cases are dropped
        # or engine-skipped, behavior_judge writes summary.json, marks its
        # release gate INCOMPLETE and exits nonzero — but this report read the
        # file anyway and ranked the model on whatever cases survived, which can
        # promote it to Recommended on a subset. Refuse the receipt instead: an
        # unranked model is a gap someone re-runs, a wrongly-ranked one is a
        # recommendation nobody re-checks.
        # Read the judge's own acceptance answer; do not infer one from the
        # verdict. Refusing only the literal string "INCOMPLETE" left two holes:
        # a receipt with a MISSING or UNKNOWN verdict sailed through and was
        # ranked (a synthesised `WEIRD_UNKNOWN_VALUE` came out #1 "Recommended"),
        # and `BLOCK` outranks incompleteness inside the gate, so a run that was
        # both quality-failed AND partial never said "INCOMPLETE" at all.
        # `cacheable` carries the real acceptance decision. The verdict allowlist
        # exists only to reject a receipt this gate could not have produced — an
        # absent or unknown verdict — and INCOMPLETE is included deliberately: a
        # model with some engine errors is INCOMPLETE by coverage yet FINISHED as
        # evidence, and `tier()` below ranks exactly that case "Not recommended".
        release_verdict = (summary.get("release_gate") or {}).get("verdict")
        if summary.get("cacheable") is not True \
                or release_verdict not in ("CLEAR", "BLOCK", "INCOMPLETE"):
            # A refusal must NAME ITS OWN REASON. Reporting the three gap counts
            # unconditionally printed "0 engine-skipped, 0 primary judge-dropped,
            # 0 adjudication-dropped" for a receipt written before `cacheable`
            # existed — all zeros, yet refused, which reads as "nothing is wrong
            # and I rejected it anyway". Measured against the real #1950 run data:
            # 14 of 16 arms produced exactly that. Same shape as the adjudication
            # message that printed two zeros before #2007 fixed it.
            #
            # These are genuinely different situations with different responses, so
            # they get different sentences: a pre-field receipt needs one re-judge
            # and nothing else, while a `cacheable: false` receipt has real gaps
            # worth reading.
            adj = summary.get("adjudication") or {}
            adj_dropped = adj.get("adjudication_missing_n")
            if adj_dropped is None:
                # A pre-#2007 receipt has no explicit count but DOES carry the
                # evidence, so defaulting to zero would claim "no adjudication
                # gap" from a receipt that proves one. `behavior_judge` sets
                # `rep_scores = [primary_premerge, adjudication]`, so
                # `wobble.rep_coverage[1]` is how many judged ids the
                # adjudication pass returned while `adjudicated_n` is how many
                # were selected; the difference is the drop. Only meaningful
                # when an adjudication pass ran — with none, `rep_coverage` has
                # a single entry and there is nothing to compare.
                #
                # This matters precisely for old receipts: a silently dropped
                # adjudication IS the defect #2007 was opened for, so the
                # receipts most likely to carry one are the legacy ones.
                rep_coverage = (summary.get("wobble") or {}).get("rep_coverage") or []
                adj_dropped = (max(0, adj.get("adjudicated_n", 0) - rep_coverage[1])
                               if len(rep_coverage) > 1 else 0)
            gaps = (f"{len(summary.get('skipped', []))} engine-skipped, "
                    f"{len(summary.get('missing_scores', []))} primary judge-dropped, "
                    f"{adj_dropped} adjudication-dropped")
            any_gap = (summary.get("skipped") or summary.get("missing_scores") or adj_dropped)

            # ORDER MATTERS, and cloud review caught it the other way round. A
            # receipt can be BOTH legacy AND carry a verdict this gate cannot
            # emit; checking field-absence first reported it as merely old and
            # suppressed the stronger signal. The two also carry different
            # ADVICE — "re-judge once" is wrong for a file that is not one of
            # ours — so the verdict check goes first.
            #
            # Safe against mislabelling a genuine legacy receipt: all 16 shipped
            # #1950 arms carry `BLOCK`, which is allowlisted, so a real
            # pre-#2007 receipt still reaches the legacy message below.
            if release_verdict not in ("CLEAR", "BLOCK", "INCOMPLETE"):
                problems.append(
                    f"{model} ({cand_stem}): judge receipt carries verdict "
                    f"{release_verdict!r}, which this gate cannot produce — the file is "
                    f"not one of ours or was hand-edited; re-judge")
            elif "cacheable" not in summary:
                # A pre-#2007 receipt still RECORDS its gaps; what it lacks is the
                # judge's acceptance answer. So report the recorded gaps when there
                # are any and stay silent about them when there are none — saying
                # "no gap is implied" unconditionally would have been false on the
                # real #1950 data, where llama3.2's receipt records four dropped
                # international scores.
                detail = (f"and records {gaps}" if any_gap
                          else "and records no gaps of its own")
                problems.append(
                    f"{model} ({cand_stem}): judge receipt predates the `cacheable` "
                    f"field (written before #2007) {detail}; re-judge once")
            else:
                problems.append(
                    f"{model} ({cand_stem}): judge receipt is not cacheable "
                    f"(verdict {release_verdict!r}) — {gaps}; re-judge")
            continue

        # Independent reconciliation against the RUN's own case count, because
        # the check above trusts the judge to have noticed its own gap. These are
        # two different sources, so agreeing is evidence and disagreeing is a
        # hole no single receipt could reveal.
        judge_overall = summary.get("overall") or {}
        scored = judge_overall.get("total_scored")
        infra_skipped = judge_overall.get("infra_skipped") or 0

        # The identity that is actually true: every case the runner attempted is
        # either scored or skipped. This previously compared the sum against
        # `cases - errors`, which only holds when `errors == 0` — so ANY run with
        # one engine error compared `19 + 1` against `19` and could never
        # reconcile. It was unreachable while the INCOMPLETE receipt was refused
        # outright; admitting INCOMPLETE for engine errors exposed it.
        if scored is None or scored + infra_skipped != sp["cases"]:
            problems.append(
                f"{model} ({cand_stem}): judged {scored} + {infra_skipped} skipped does not "
                f"reconcile with the run's {sp['cases']} attempted cases; re-judge")
            continue

        # And every skip must be ATTRIBUTABLE to an engine error, checked PER ENTRY
        # rather than by count. A count comparison is not an identity check: with
        # `errors=1` and one skip that is an empty-but-successful candidate, `1 == 1`
        # passes while the skip does not correspond to the error at all, and the
        # model is ranked on a mismatched subset.
        #
        # The runner increments `errors` only inside its except branch, so a 200
        # returning an empty string is skipped by the judge and counted as a SUCCESS.
        # `tier()` reads the run's error count and therefore cannot see it. Keying on
        # each entry's own `error` field works for receipts written before the precise
        # reasons existed too, since a genuine engine error has always recorded it.
        #
        # Refuse rather than penalise: an unranked model is a gap someone re-runs, a
        # wrongly-ranked one is a recommendation nobody re-checks.
        skipped_entries = summary.get("skipped") or []
        unattributed = [s for s in skipped_entries if not s.get("error")]
        if unattributed or len(skipped_entries) != sp["errors"]:
            detail = "; ".join(sorted({s.get("reason", "no reason recorded")
                                       for s in (unattributed or skipped_entries)})) or "none"
            problems.append(
                f"{model} ({cand_stem}): {len(skipped_entries)} judge skip(s) against "
                f"{sp['errors']} run error(s), and {len(unattributed)} skip(s) carry no engine "
                f"error — those produced no gradeable text on a successful call, which cannot "
                f"be ranked ({detail}); re-run those cases")
            continue

        # Same class as the receipt guard above; measured to fail identically.
        # The row shape-check is not padding: every consumer below reaches rows
        # through `pred(x)` predicates that call `.get`, so a valid-JSON
        # non-object row would crash there instead, one layer further from the
        # cause.
        try:
            per_case = [json.loads(l) for l in open(per_case_path) if l.strip()]
        # ValueError covers BOTH decode failures: json.JSONDecodeError and
        # UnicodeDecodeError (invalid UTF-8) are both subclasses, and a
        # JSONDecodeError-only tuple silently missed the second one.
        except (OSError, ValueError) as exc:
            problems.append(f"{model} ({cand_stem}): per_case.jsonl is unreadable "
                            f"({exc.__class__.__name__}); re-judge")
            continue
        if not all(isinstance(row, dict) for row in per_case):
            problems.append(f"{model} ({cand_stem}): per_case.jsonl contains a row that is "
                            f"not an object, so the language split cannot be computed; "
                            f"re-judge")
            continue

        # The language splits below are computed from per_case.jsonl while the
        # headline pass rate comes from summary.json. A truncated detail file
        # would therefore produce a report whose halves disagree, with nothing
        # saying so. Two sources agreeing is evidence; only comparing them makes
        # it evidence.
        summary_scored = (summary.get("overall") or {}).get("total_scored")
        if summary_scored is None or len(per_case) != summary_scored:
            problems.append(
                f"{model} ({cand_stem}): per_case.jsonl has {len(per_case)} rows but the "
                f"summary reports total_scored={summary_scored}; the detail file is "
                f"truncated or mismatched, so the language split cannot be trusted")
            continue

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
