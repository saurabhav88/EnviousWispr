#!/usr/bin/env python3
"""Alias suggestion benchmark — runs WordSuggestionService over labeled corpora,
scores per-case across 6 axes, gates per-category at 90% pass rate, and detects
scorer drift via a golden file. See issue #637.

Modes:
  run        (default)  drive runner over corpora, score against committed baseline. CI/local gate.
  baseline              drive runner, save scored output as new baseline. Requires --reason.
  meta-test             run scorer against golden_alias_scores.json; fail on rubric drift.

Exit codes:
  0  pass
  1  regression (gate failure)
  2  infra error (AFM unavailable, corpus missing, runner build missing)
  3  rubric drift (meta-test failed)

Design refs:
  docs/feature-requests/issue-637-2026-05-05-afm-prompt-revisit-harness.md
  docs/feature-requests/issue-637-2026-05-05-alias-eval-rubric.md
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from statistics import median
from typing import Optional

ROOT = Path(__file__).parent.parent.parent.resolve()
CORPUS_DIR = ROOT / "scripts/eval/corpus"
PUBLIC_CORPORA = [f"alias-corpus-{c}.jsonl" for c in "abcde"]
HOLDOUT_CORPUS = "alias-holdout-private.jsonl"
SMOKE_CORPUS = "alias-smoke.jsonl"

BASELINE_DIR = ROOT / "scripts/eval/baselines/alias-suggestions"
GOLDEN_FILE = ROOT / "scripts/eval/golden_alias_scores.json"
RUNS_DIR = ROOT / "benchmark-results/eval/alias-suggestions/runs"
RUNNER_BIN = ROOT / "scripts/eval/alias_runner/.build/release/AliasRunner"

# --- Rubric constants (locked 2026-05-05) ---

CATEGORIES = ("general", "person", "brand", "acronym", "domain")
ABSOLUTE_AXES = ("recall", "precision", "diversity", "category")
MIN_ABSOLUTE = 2  # each absolute axis must be >= 2 for a case to pass
PER_CATEGORY_PASS_THRESHOLD = 0.90  # locked 2026-05-05 question 2
DEGENERATION_RATE_CEILING = 0.05
REFUSAL_RATE_CEILING = 0.02
CATEGORY_ACCURACY_FLOOR = 0.90
MATCH_THRESHOLD = 0.86  # phonetic-or-no-space-edit-distance


# --- Scorer ---


def normalize(s: str) -> str:
    """Lowercase, trim, collapse whitespace, strip outer punctuation."""
    s = s.lower().strip()
    s = re.sub(r"\s+", " ", s)
    s = s.strip(".,;:!?\"'()[]{}")
    return s


def levenshtein(a: str, b: str) -> int:
    if len(a) < len(b):
        a, b = b, a
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        curr = [i]
        for j, cb in enumerate(b, 1):
            ins = curr[j - 1] + 1
            dele = prev[j] + 1
            sub = prev[j - 1] + (0 if ca == cb else 1)
            curr.append(min(ins, dele, sub))
        prev = curr
    return prev[-1]


def normalized_edit_similarity(a: str, b: str) -> float:
    """1.0 = identical, 0.0 = totally different. Uses Levenshtein."""
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    dist = levenshtein(a, b)
    return 1.0 - dist / max(len(a), len(b))


def match_score(suggestion: str, expected: str) -> float:
    """Per rubric §2 matching rule: max of normalized edit similarity and
    no-space normalized edit similarity. Returns 0.0-1.0.

    Note: rubric calls for `WordCorrector.score` which is a Swift-side
    phonetic edit distance. We mirror it here with normalized Levenshtein
    on lowercased input plus the no-space variant. Documented divergence
    from the Swift scorer; revisit if labels disagree with intuition.
    """
    a = normalize(suggestion)
    b = normalize(expected)
    if not a or not b:
        return 0.0
    direct = normalized_edit_similarity(a, b)
    no_space = normalized_edit_similarity(a.replace(" ", ""), b.replace(" ", ""))
    return max(direct, no_space)


@dataclass
class CaseResult:
    case_id: str
    canonical: str
    category_expected: str
    category_predicted: Optional[str]
    no_alias_expected: bool
    raw_aliases: list[str]
    filtered_aliases: list[str]
    latency_ms: int
    cold_start: bool
    timed_out: bool
    error: Optional[str]
    # Axes
    recall: int = 0
    precision: int = 0
    diversity: int = 0
    category: int = 0
    degeneration: int = 0
    refusal: int = 0
    matched_groups: list[str] = field(default_factory=list)
    case_pass: bool = False


def assign_matches(suggestions: list[str], groups: list[dict]) -> list[Optional[str]]:
    """Greedy highest-score one-to-one assignment of suggestions to expected
    groups. Returns a parallel list: per suggestion, the group_id matched (or None).
    """
    pairings: list[tuple[float, int, int]] = []  # (score, sug_idx, grp_idx)
    for si, sug in enumerate(suggestions):
        for gi, grp in enumerate(groups):
            best = 0.0
            for variant in grp.get("variants", []):
                best = max(best, match_score(sug, variant))
            if best >= MATCH_THRESHOLD:
                pairings.append((best, si, gi))
    pairings.sort(key=lambda t: -t[0])
    sug_taken: set[int] = set()
    grp_taken: set[int] = set()
    result: list[Optional[str]] = [None] * len(suggestions)
    for score, si, gi in pairings:
        if si in sug_taken or gi in grp_taken:
            continue
        sug_taken.add(si)
        grp_taken.add(gi)
        result[si] = groups[gi].get("id", f"grp-{gi}")
    return result


def is_plausible(alias: str, canonical: str, matched: Optional[str]) -> bool:
    a = normalize(alias)
    c = normalize(canonical)
    if not a:
        return False
    if a == c:
        return False
    sim = match_score(alias, canonical)
    if sim >= 0.95:
        return False
    if matched is not None:
        return True
    return sim >= 0.40


def cluster_count(aliases: list[str]) -> int:
    """Two aliases are in the same cluster if normalized strings are equal,
    no-space strings are equal, or alias-to-alias match score >= 0.90.
    """
    if not aliases:
        return 0
    parents = list(range(len(aliases)))

    def find(x: int) -> int:
        while parents[x] != x:
            parents[x] = parents[parents[x]]
            x = parents[x]
        return x

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parents[ra] = rb

    norms = [normalize(a) for a in aliases]
    no_space = [n.replace(" ", "") for n in norms]
    for i in range(len(aliases)):
        for j in range(i + 1, len(aliases)):
            if norms[i] == norms[j] or no_space[i] == no_space[j]:
                union(i, j)
                continue
            if match_score(aliases[i], aliases[j]) >= 0.90:
                union(i, j)
    return len({find(i) for i in range(len(aliases))})


def score_case(case: dict, runner_record: dict) -> CaseResult:
    """Apply the 6-axis scorecard to one case + runner record.

    case: corpus entry (canonical, category, expected_alias_groups, no_alias_expected, ...).
    runner_record: alias_runner JSONL line for this case.
    """
    canonical = case["canonical"]
    category_expected = case["category"]
    no_alias_expected = case.get("no_alias_expected", False)
    expected_groups = case.get("expected_alias_groups", []) or []
    acceptable_categories = case.get("acceptable_categories") or [category_expected]

    raw_aliases = list(runner_record.get("raw_aliases", []) or [])
    filtered_aliases = list(runner_record.get("filtered_aliases", []) or [])
    timed_out = bool(runner_record.get("timed_out", False))
    error = runner_record.get("error")
    predicted = runner_record.get("predicted_category")

    refusal = 1 if (timed_out or error is not None) else 0
    degeneration = 1 if (raw_aliases and not filtered_aliases) else 0

    # Recall axis
    if no_alias_expected:
        recall = 3 if not filtered_aliases else 0
    else:
        if not filtered_aliases:
            recall = 0
        else:
            matched = assign_matches(filtered_aliases, expected_groups)
            hits = sum(1 for m in matched if m is not None)
            n_groups = max(1, len(expected_groups))
            ratio = hits / n_groups
            if hits >= 3 or ratio >= 0.75:
                recall = 3
            elif hits >= 2 or ratio >= 0.50:
                recall = 2
            elif hits == 1:
                recall = 1
            else:
                recall = 0
        # Recompute matched for plausibility / diversity reuse
        matched = assign_matches(filtered_aliases, expected_groups)

    # Precision axis
    if no_alias_expected:
        precision = 3 if not filtered_aliases else 0
        matched_for_plaus: list[Optional[str]] = []
    else:
        matched_for_plaus = matched if filtered_aliases else []
        if not filtered_aliases:
            precision = 0
        else:
            plausible_flags = [
                is_plausible(a, canonical, matched_for_plaus[i] if i < len(matched_for_plaus) else None)
                for i, a in enumerate(filtered_aliases)
            ]
            ratio = sum(plausible_flags) / len(plausible_flags)
            any_invalid = any(not p for p in plausible_flags) and ratio < 0.6
            if ratio >= 0.80 and not any_invalid:
                precision = 3
            elif ratio >= 0.60 and not any_invalid:
                precision = 2
            elif ratio > 0:
                precision = 1
            else:
                precision = 0

    # Diversity axis
    if no_alias_expected:
        diversity = 3 if not filtered_aliases else 0
    else:
        clusters = cluster_count(filtered_aliases)
        if clusters >= 3:
            diversity = 3
        elif clusters == 2:
            diversity = 2
        elif clusters == 1:
            diversity = 1
        else:
            diversity = 0

    # Category axis
    if predicted is None:
        category = 0
    else:
        category = 3 if predicted in acceptable_categories else 0

    # Per-case pass
    if no_alias_expected:
        case_pass = (not filtered_aliases) and refusal == 0 and not timed_out
    else:
        case_pass = (
            recall >= MIN_ABSOLUTE
            and precision >= MIN_ABSOLUTE
            and diversity >= MIN_ABSOLUTE
            and category >= MIN_ABSOLUTE
            and degeneration == 0
            and refusal == 0
            and not timed_out
        )

    return CaseResult(
        case_id=case["id"],
        canonical=canonical,
        category_expected=category_expected,
        category_predicted=predicted,
        no_alias_expected=no_alias_expected,
        raw_aliases=raw_aliases,
        filtered_aliases=filtered_aliases,
        latency_ms=int(runner_record.get("latency_ms", 0) or 0),
        cold_start=bool(runner_record.get("cold_start", False)),
        timed_out=timed_out,
        error=error,
        recall=recall,
        precision=precision,
        diversity=diversity,
        category=category,
        degeneration=degeneration,
        refusal=refusal,
        matched_groups=[m for m in (matched if not no_alias_expected else []) if m],
        case_pass=case_pass,
    )


@dataclass
class CorpusSummary:
    corpus_name: str
    n_cases: int
    pass_rate: float
    per_category_pass: dict[str, float]
    per_category_count: dict[str, int]
    degeneration_rate: float
    refusal_rate: float
    category_accuracy: float
    latency_p50_ms: int
    latency_p95_ms: int
    cold_latency_p50_ms: Optional[int]
    side_gates_pass: bool
    failures: list[str]


def aggregate_corpus(corpus_name: str, cases: list[dict], results: list[CaseResult]) -> CorpusSummary:
    n = len(cases)
    by_category: dict[str, list[CaseResult]] = {c: [] for c in CATEGORIES}
    for case, res in zip(cases, results):
        cat = case["category"]
        if cat not in by_category:
            by_category[cat] = []
        by_category[cat].append(res)

    per_cat_pass = {
        cat: (sum(1 for r in lst if r.case_pass) / len(lst) if lst else 1.0)
        for cat, lst in by_category.items()
    }
    per_cat_count = {cat: len(lst) for cat, lst in by_category.items()}

    n_pass = sum(1 for r in results if r.case_pass)
    pass_rate = n_pass / n if n else 0.0

    aliasable = [r for r in results if not r.no_alias_expected]
    degen = sum(1 for r in aliasable if r.degeneration == 1)
    degen_rate = (degen / len(aliasable)) if aliasable else 0.0

    refused = sum(1 for r in results if r.refusal == 1)
    refusal_rate = (refused / n) if n else 0.0

    cat_correct = sum(1 for r in results if r.category == 3)
    cat_acc = (cat_correct / n) if n else 1.0

    latencies = [r.latency_ms for r in results if r.latency_ms > 0]
    p50 = int(median(latencies)) if latencies else 0
    p95 = int(sorted(latencies)[int(len(latencies) * 0.95)]) if latencies else 0
    cold_lats = [r.latency_ms for r in results if r.cold_start and r.latency_ms > 0]
    cold_p50 = int(median(cold_lats)) if cold_lats else None

    failures: list[str] = []
    for cat, rate in per_cat_pass.items():
        if per_cat_count[cat] > 0 and rate < PER_CATEGORY_PASS_THRESHOLD:
            failures.append(f"category {cat} pass rate {rate:.2%} < {PER_CATEGORY_PASS_THRESHOLD:.0%}")
    if degen_rate > DEGENERATION_RATE_CEILING:
        failures.append(f"degeneration rate {degen_rate:.2%} > {DEGENERATION_RATE_CEILING:.0%}")
    if refusal_rate > REFUSAL_RATE_CEILING:
        failures.append(f"refusal rate {refusal_rate:.2%} > {REFUSAL_RATE_CEILING:.0%}")
    if cat_acc < CATEGORY_ACCURACY_FLOOR:
        failures.append(f"category accuracy {cat_acc:.2%} < {CATEGORY_ACCURACY_FLOOR:.0%}")

    side_gates_pass = not failures

    return CorpusSummary(
        corpus_name=corpus_name,
        n_cases=n,
        pass_rate=pass_rate,
        per_category_pass=per_cat_pass,
        per_category_count=per_cat_count,
        degeneration_rate=degen_rate,
        refusal_rate=refusal_rate,
        category_accuracy=cat_acc,
        latency_p50_ms=p50,
        latency_p95_ms=p95,
        cold_latency_p50_ms=cold_p50,
        side_gates_pass=side_gates_pass,
        failures=failures,
    )


# --- Runner driver ---


def load_corpus(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out: list[dict] = []
    with path.open() as f:
        for ln, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError as e:
                infra_error(f"corpus {path}: line {ln} invalid JSON: {e}")
    return out


def load_jsonl(path: Path) -> list[dict]:
    out: list[dict] = []
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            out.append(json.loads(line))
    return out


def run_runner(corpus_path: Path, out_path: Path, disable_timeout: bool = True) -> int:
    if not RUNNER_BIN.exists():
        infra_error(
            f"AliasRunner binary missing at {RUNNER_BIN}. "
            "Build it with: cd scripts/eval/alias_runner && swift build -c release"
        )
    if os.environ.get("MOCK_AFM_UNAVAILABLE") == "1":
        infra_error("MOCK_AFM_UNAVAILABLE=1 — Apple Intelligence simulated unavailable")
    args = [str(RUNNER_BIN), "--corpus", str(corpus_path), "--out", str(out_path)]
    if disable_timeout:
        args.append("--disable-timeout")
    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode == 2:
        infra_error(f"AliasRunner exit 2 (infra): {proc.stderr.strip()}")
    if proc.returncode != 0:
        infra_error(f"AliasRunner exit {proc.returncode}: {proc.stderr.strip()}")
    return proc.returncode


# --- IO helpers ---


def infra_error(msg: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"INFRA-ERROR: {msg}", file=sys.stderr)
    print("Not a regression.", file=sys.stderr)
    sys.exit(2)


def fail_regression(msg: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"REGRESSION: {msg}", file=sys.stderr)
    sys.exit(1)


def fail_drift(msg: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"RUBRIC-DRIFT: {msg}", file=sys.stderr)
    sys.exit(3)


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%S")


# --- Mode: run / baseline ---


def index_records(records: list[dict]) -> dict[str, dict]:
    return {r["id"]: r for r in records}


def gather_corpora(include_holdout: bool) -> list[Path]:
    paths = [CORPUS_DIR / name for name in PUBLIC_CORPORA]
    if include_holdout:
        h = CORPUS_DIR / HOLDOUT_CORPUS
        if h.exists():
            paths.append(h)
    return paths


def serialize_summary(summary: CorpusSummary) -> dict:
    d = asdict(summary)
    d["per_category_pass"] = {k: round(v, 4) for k, v in summary.per_category_pass.items()}
    d["pass_rate"] = round(summary.pass_rate, 4)
    d["degeneration_rate"] = round(summary.degeneration_rate, 4)
    d["refusal_rate"] = round(summary.refusal_rate, 4)
    d["category_accuracy"] = round(summary.category_accuracy, 4)
    return d


def mode_baseline(reason: str, include_holdout: bool) -> int:
    if not reason.strip():
        infra_error("--mode baseline requires --reason")
    BASELINE_DIR.mkdir(parents=True, exist_ok=True)
    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    run_id = now_iso()
    run_dir = RUNS_DIR / run_id
    run_dir.mkdir(parents=True)

    cross_summaries: list[dict] = []
    cross_min_pass = 1.0
    for corpus_path in gather_corpora(include_holdout):
        if not corpus_path.exists():
            print(f"[skip] {corpus_path} not present", file=sys.stderr)
            continue
        corpus = load_corpus(corpus_path)
        if not corpus:
            print(f"[skip] {corpus_path} empty", file=sys.stderr)
            continue
        out_jsonl = run_dir / f"{corpus_path.stem}-runner.jsonl"
        run_runner(corpus_path, out_jsonl)
        records = index_records(load_jsonl(out_jsonl))
        results = [score_case(c, records.get(c["id"], {"error": "missing_record"})) for c in corpus]
        summary = aggregate_corpus(corpus_path.stem, corpus, results)
        cross_min_pass = min(cross_min_pass, summary.pass_rate)
        baseline_payload = {
            "captured_at": run_id,
            "reason": reason,
            "corpus": corpus_path.stem,
            "summary": serialize_summary(summary),
            "case_results": [asdict(r) for r in results],
        }
        baseline_path = BASELINE_DIR / f"apple-intelligence-{corpus_path.stem}.json"
        baseline_path.write_text(json.dumps(baseline_payload, indent=2, sort_keys=True) + "\n")
        cross_summaries.append(serialize_summary(summary))
        print(
            f"[baseline] {corpus_path.stem}: pass_rate={summary.pass_rate:.2%} "
            f"side_gates={'PASS' if summary.side_gates_pass else 'FAIL'}"
        )

    cross_path = run_dir / "cross-corpus-summary.json"
    cross_path.write_text(
        json.dumps(
            {
                "captured_at": run_id,
                "reason": reason,
                "cross_min_pass_rate": round(cross_min_pass, 4),
                "corpora": cross_summaries,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )
    print(f"\nBaseline captured. cross_min_pass={cross_min_pass:.2%}")
    print(f"Run artifacts: {run_dir}")
    print(f"Baseline files: {BASELINE_DIR}")
    return 0


def is_regression(baseline_case: dict, candidate: CaseResult) -> Optional[str]:
    """Per rubric §3 regression rules. Returns reason string or None."""
    if baseline_case.get("case_pass") and not candidate.case_pass:
        return "baseline passed, candidate fails"
    for axis in ABSOLUTE_AXES:
        b = int(baseline_case.get(axis, 0) or 0)
        c = getattr(candidate, axis)
        if b >= MIN_ABSOLUTE and c < MIN_ABSOLUTE:
            return f"axis {axis} dropped {b}->{c} (below MIN_ABSOLUTE)"
    for axis in ("degeneration", "refusal"):
        b = int(baseline_case.get(axis, 0) or 0)
        c = getattr(candidate, axis)
        if b == 0 and c == 1:
            return f"new {axis} trip"
    if baseline_case.get("no_alias_expected") and candidate.filtered_aliases and not baseline_case.get("filtered_aliases"):
        return "no-alias case started surfacing aliases"
    return None


def mode_run(include_holdout: bool) -> int:
    if not BASELINE_DIR.exists() or not any(BASELINE_DIR.glob("apple-intelligence-*.json")):
        infra_error(
            f"no baseline at {BASELINE_DIR}. Run: "
            "python3 scripts/eval/alias_suggestion_gate.py --mode baseline --reason '...'"
        )
    RUNS_DIR.mkdir(parents=True, exist_ok=True)
    run_id = now_iso()
    run_dir = RUNS_DIR / run_id
    run_dir.mkdir(parents=True)

    cross_min_pass = 1.0
    overall_failures: list[str] = []
    for corpus_path in gather_corpora(include_holdout):
        if not corpus_path.exists():
            continue
        baseline_path = BASELINE_DIR / f"apple-intelligence-{corpus_path.stem}.json"
        if not baseline_path.exists():
            print(f"[skip] no baseline for {corpus_path.stem}", file=sys.stderr)
            continue
        baseline = json.loads(baseline_path.read_text())
        baseline_cases = {r["case_id"]: r for r in baseline["case_results"]}

        corpus = load_corpus(corpus_path)
        out_jsonl = run_dir / f"{corpus_path.stem}-runner.jsonl"
        run_runner(corpus_path, out_jsonl)
        records = index_records(load_jsonl(out_jsonl))
        results = [score_case(c, records.get(c["id"], {"error": "missing_record"})) for c in corpus]
        summary = aggregate_corpus(corpus_path.stem, corpus, results)

        regressions: list[str] = []
        for r in results:
            b = baseline_cases.get(r.case_id)
            if not b:
                continue
            reason = is_regression(b, r)
            if reason:
                regressions.append(f"{r.case_id}: {reason}")

        if not summary.side_gates_pass:
            overall_failures.append(
                f"{corpus_path.stem}: side gates failed: {'; '.join(summary.failures)}"
            )
        if regressions:
            overall_failures.append(f"{corpus_path.stem}: {len(regressions)} regression(s)")
            for line in regressions[:10]:
                overall_failures.append(f"  {line}")
            if len(regressions) > 10:
                overall_failures.append(f"  ... and {len(regressions) - 10} more")

        cross_min_pass = min(cross_min_pass, summary.pass_rate)
        print(
            f"[run] {corpus_path.stem}: pass_rate={summary.pass_rate:.2%} "
            f"baseline={baseline['summary']['pass_rate']:.2%} "
            f"side_gates={'PASS' if summary.side_gates_pass else 'FAIL'} "
            f"regressions={len(regressions)}"
        )

    print(f"\ncross_min_pass={cross_min_pass:.2%}")
    if overall_failures:
        for line in overall_failures:
            print(line, file=sys.stderr)
        fail_regression(f"{len(overall_failures)} corpus-level issue(s)")
    print("PASS")
    return 0


# --- Mode: meta-test ---


def mode_meta_test() -> int:
    if not GOLDEN_FILE.exists():
        infra_error(f"no golden file at {GOLDEN_FILE}")
    golden = json.loads(GOLDEN_FILE.read_text())
    failures: list[str] = []
    for entry in golden:
        case = entry["case"]
        runner_record = entry["runner_record"]
        expected = entry["expected_axes"]
        result = score_case(case, runner_record)
        for axis_name in ("recall", "precision", "diversity", "category", "degeneration", "refusal"):
            actual = getattr(result, axis_name)
            if int(expected.get(axis_name, 0)) != int(actual):
                failures.append(
                    f"{case['id']}.{axis_name}: expected={expected.get(axis_name)} actual={actual}"
                )
        if bool(expected.get("case_pass", False)) != bool(result.case_pass):
            failures.append(
                f"{case['id']}.case_pass: expected={expected.get('case_pass')} actual={result.case_pass}"
            )
    if failures:
        for line in failures:
            print(line, file=sys.stderr)
        fail_drift(f"{len(failures)} axis mismatch(es) in golden set")
    print(f"meta-test PASS ({len(golden)} cases)")
    return 0


# --- CLI ---


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--mode", choices=["run", "baseline", "meta-test"], default="run")
    p.add_argument("--reason", help="Required for --mode baseline")
    p.add_argument(
        "--include-holdout",
        action="store_true",
        help="Include the private holdout corpus (final sign-off only).",
    )
    args = p.parse_args()

    if args.mode == "baseline":
        if not args.reason:
            infra_error("--mode baseline requires --reason")
        return mode_baseline(args.reason, args.include_holdout)
    if args.mode == "meta-test":
        return mode_meta_test()
    return mode_run(args.include_holdout)


if __name__ == "__main__":
    sys.exit(main())
