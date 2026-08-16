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


# Why a receipt is refused is classified in ONE place, shared with
# `judge_ollama_bench.sh`, because two copies in two languages diverged twice in
# one PR — the shell announced "predates the `cacheable` field" about files this
# script correctly called hand-edited and then corrupt. A comment asking for
# parity cannot enforce it; a shared module can.
from receipt_state import (  # noqa: E402
    MALFORMED_METADATA,
    NOT_CACHEABLE,
    UNSUPPORTED_VERDICT,
    _as_dict,
    _as_list,
    adjudication_dropped,
    classify,
)


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
        release_verdict = _as_dict(summary.get("release_gate")).get("verdict")
        state, malformed = classify(summary_path)
        if state != NOT_CACHEABLE or summary.get("cacheable") is not True:
            # A refusal must NAME ITS OWN REASON. Reporting the three gap counts
            # unconditionally printed "0 engine-skipped, 0 primary judge-dropped,
            # 0 adjudication-dropped" for a receipt written before `cacheable`
            # existed — all zeros, yet refused, which reads as "nothing is wrong
            # and I rejected it anyway". Measured against the real #1950 run data:
            # 14 of 16 arms produced exactly that. Same shape as the adjudication
            # message that printed two zeros before #2007 fixed it.
            #
            # THREE REASONS, IN THIS ORDER, AND THE ORDER IS THE DESIGN.
            #
            # The verdict is classified FIRST, before any other field is read.
            # Two independent reasons, both found by review the other way round:
            # a receipt can be BOTH legacy AND carry a verdict this gate cannot
            # emit, and calling that one "merely old" suppresses the stronger
            # signal while giving the wrong advice ("re-judge once" is not what
            # you do with a file that is not ours). Second, an unsupported
            # verdict is the marker of a hand-edited file, which is exactly where
            # malformed metadata lives — so classifying it before touching
            # `adjudication` or `wobble` means the crash-prone reads never run
            # for the receipts most likely to break them.
            #
            # Safe against mislabelling a genuine legacy receipt: all 16 shipped
            # #1950 arms carry `BLOCK`, which is allowlisted, so a real
            # pre-#2007 receipt still reaches the legacy message below.
            if state == UNSUPPORTED_VERDICT:
                problems.append(
                    f"{model} ({cand_stem}): judge receipt carries verdict "
                    f"{release_verdict!r}, which this gate cannot produce — the file is "
                    f"not one of ours or was hand-edited; re-judge")
                continue

            if state == MALFORMED_METADATA:
                # Coercing a corrupt `"skipped": "not a list"` to `[]` would
                # manufacture "records no gaps of its own" about a receipt that
                # records nothing usable — a false claim, and the very defect this
                # change set exists to remove. A malformed field is no evidence the
                # gap is zero, so it is named rather than erased.
                problems.append(
                    f"{model} ({cand_stem}): judge receipt has malformed "
                    f"{', '.join(malformed)}, so its gap counts prove nothing — "
                    f"the file is corrupt or hand-edited; re-judge")
                continue

            skipped = _as_list(summary.get("skipped"))
            missing = _as_list(summary.get("missing_scores"))
            adj_dropped = adjudication_dropped(summary)
            gaps = (f"{len(skipped)} engine-skipped, "
                    f"{len(missing)} primary judge-dropped, "
                    f"{adj_dropped} adjudication-dropped")
            any_gap = bool(skipped or missing or adj_dropped)

            if "cacheable" not in summary:
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
        # Carried onto the row so the one-judge-per-scoreboard check below has something to read.
        # A check reading fields the rows do not carry would group everything under one key and
        # never fire — a guard that arms nothing, which is worse than no guard because it reads
        # as one.
        #
        # `meta` is shape-checked, not merely defaulted: a hand-edited or truncated
        # `"meta": [...]` is truthy, so `or {}` leaves a list and the `.get()` below raises
        # AttributeError — aborting the whole report with a traceback instead of naming the one
        # bad receipt, which is what the surrounding per-model handling exists to do.
        # ABSENT and MALFORMED are different states and must not be conflated. A receipt with no
        # `meta` at all is a legacy one and ranks fine; a receipt whose `meta` is present but not
        # an object has been truncated or hand-edited and cannot be trusted to say who graded it.
        # Treating absent as malformed rejected every pre-meta receipt, which the existing
        # fixtures caught immediately.
        receipt_meta = summary.get("meta")
        if receipt_meta is None:
            receipt_meta = {}
        elif not isinstance(receipt_meta, dict):
            problems.append(
                f"{model} ({cand_stem}): receipt `meta` is {type(receipt_meta).__name__}, not an "
                f"object, so its judge cannot be identified")
            receipt_meta = {}
        rows.append({
            "model": model,
            "arm": cand_stem,
            # A POSITIVE marker that this row came from a receipt. The judge check skips rows
            # without it. Inferring "no receipt" from a missing judge field was how an
            # unmeasurable arm — every case errored, so no receipt exists — got counted as its
            # own judge and made any benchmark containing one falsely unreportable.
            "from_receipt": True,
            "judge": receipt_meta.get("judge"),
            "judge_identity": receipt_meta.get("judge_identity"),
            # WHICH RUBRIC graded this arm. Without it on the row, the mixing guard
            # below reads a field nobody sets and can never fire.
            "rubric_identity": receipt_meta.get("rubric_identity"),
            "judge_model_version": receipt_meta.get("judge_model_version"),
            # WHETHER THE JUDGE SAW THE ANSWER KEY. Top-level on the receipt, not
            # under `meta`. Without it on the row, a blind arm and a sighted arm
            # rank together as though they were measured the same way, and they
            # were not: showing the key moved 122 of 472 verdicts. That is a
            # larger effect than any arm difference this report exists to rank.
            "judge_blind": summary.get("judge_blind"),
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

    # ONE JUDGE PER SCOREBOARD, enforced here because this is the layer that combines arms.
    #
    # This closes a class the sweep cannot close from its side, and cloud review pointed at it
    # three times before I moved: a partial sweep, an interrupted sweep, a hand-copied receipt or
    # a repointed deployment all leave some arms graded by one judge and some by another. The
    # sweep was patched repeatedly to keep stale receipts out of this path, but a ranking that
    # combines receipts is the thing that has to check they are comparable — validating a receipt
    # by whether it PARSES, and never by who produced it, is what let every one of those routes
    # through.
    #
    # Reads the identity the receipt carries. `judge` alone is not enough: an Azure deployment can
    # be repointed in place, so `judge_model_version` distinguishes two runs that share an id.
    # A receipt written before that field existed reports None, which groups with other legacy
    # receipts and still separates them from anything newer.
    # Compares the FULL identity the sweep computed, not just the judge id and model version.
    # `judge_identity` folds in the endpoint host and the API version too, so two different Azure
    # resources that happen to serve the same model string no longer compare equal — which the
    # earlier (judge, version) pair could not distinguish even though the resume stamp already
    # did. None groups with None, so a field of legacy receipts still ranks together while
    # mixing a legacy receipt with an identified one refuses, because their provenance genuinely
    # cannot be shown to match.
    judges = {}
    for row in rows:
        if not row.get("from_receipt"):
            continue          # unmeasurable or skipped: no receipt, so no judge to compare
        # Each field is coerced to a hashable str-or-None. A malformed nested value — a
        # hand-edited `"judge_identity": []` inside an otherwise well-formed `meta` — makes the
        # tuple unhashable and `setdefault` aborts the whole report with a TypeError, which is
        # the same failure the outer `meta` shape check was added to prevent, one level in.
        # Shape-checking a container and then trusting its contents is half a check.
        key = []
        for field in ("judge", "judge_identity", "judge_model_version", "rubric_identity"):
            value = row.get(field)
            if value is not None and not isinstance(value, str):
                problems.append(
                    f"{row.get('model')} ({row.get('arm')}): receipt `meta.{field}` is "
                    f"{type(value).__name__}, not a string, so its judge cannot be identified")
                value = None
            key.append(value)
        # Blinding is validated separately because it is the one identity field
        # that is a BOOL on the receipt, so the str-or-None coercion above would
        # reject every well-formed value. Three legal states, and `None` is a
        # real one (verdicts imported, this scorer did no judging and cannot say)
        # rather than a missing answer — so it groups with other unknowns instead
        # of being quietly folded into "sighted".
        blind_value = row.get("judge_blind")
        if blind_value is None:
            key.append(None)
        elif isinstance(blind_value, bool):
            key.append("blind" if blind_value else "sighted")
        else:
            problems.append(
                f"{row.get('model')} ({row.get('arm')}): receipt `judge_blind` is "
                f"{type(blind_value).__name__}, not a boolean, so it cannot be shown "
                f"whether that arm was graded against the answer key")
            key.append(None)
        judges.setdefault(tuple(key), []).append(row.get("model"))
    if len(judges) > 1:
        detail = "; ".join(
            f"{j[1] or j[0]}"
            + (f" serving {j[2]}" if j[2] else "")
            + (f" under rubric {j[3]}" if len(j) > 3 and j[3] else "")
            # Named explicitly, because blinding can be the ONLY differing field.
            # Without this the refusal prints two groups that look identical and
            # gives no reason, which reads as a bug in the guard rather than as
            # the real incompatibility it is.
            + (f" ({'no answer key shown' if j[4] == 'blind' else 'answer key shown'})"
               if len(j) > 4 and j[4] else
               (" (blinding unknown: verdicts were imported)" if len(j) > 4 else ""))
            + f": {', '.join(sorted(m for m in models if m))}"
            for j, models in sorted(judges.items(), key=lambda kv: str(kv)))
        problems.append(
            "this run mixes judges or rubrics, so the ranking would not be a "
            f"comparison — {detail}. Re-grade every arm with one judge and one rubric.")

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
