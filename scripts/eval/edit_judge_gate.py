#!/usr/bin/env python3
"""Edit-judge gate — issue #996 (learn custom words from the user's own edits).

Scores ONE correction-judge candidate over the labelled edit corpus that
`scripts/eval/alias_runner` `judge` emits, and says PASS or FAIL against the
plan's §3a thresholds. It owns edit-specific scoring only; runner invocation,
build and corpus discovery follow `alias_suggestion_gate.py`'s conventions
(`alias-eval.md` RULE: use-canonical-alias-harness).

Every metric is reported with numerator and denominator, and a bypass (the
judge did not answer) stays IN the population: a bypass on a true correction
is a missed correction, never a discarded row. An undefined metric (zero
denominator) cannot pass.

Modes:
  validate-corpus   structure, strata, labels, disjointness of working/holdout
  score             score a results JSONL against the corpus it was run on
  run               invoke the runner for a named judge, then score
  selftest          synthetic passing and failing scorecards prove the gate

Exit codes: 0 pass, 1 fail (a real verdict), 2 infra/usage.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).parent.parent.parent.resolve()
CORPUS_DIR = ROOT / "scripts/eval/corpus"
WORKING_CORPUS = CORPUS_DIR / "edit-corpus-a.jsonl"
HOLDOUT_CORPUS = CORPUS_DIR / "edit-corpus-a-holdout.jsonl"
RUNS_DIR = ROOT / "benchmark-results/eval/edit-judge/runs"
RUNNER_BIN = ROOT / "scripts/eval/alias_runner/.build/release/AliasRunner"

# --- Contract (plan §3a, locked 2026-09-18) ---

STRATA = (
    "person",
    "brand",
    "acronym",
    "domain",
    "ambiguous_name",
    "rewording",
    "grammar_punctuation",
    "instruction_like",
    "non_english",
)
MIN_WORKING_ROWS = 150
MIN_HOLDOUT_ROWS = 50
THRESHOLDS = {
    "correction_recall_min": 0.85,
    "false_add_rate_max": 0.05,
    "alias_precision_min": 0.95,
    "latency_p50_ms_max": 2000.0,
    "latency_p95_ms_max": 5000.0,
}
REQUIRED_ROW_KEYS = {
    "id": str,
    "stratum": str,
    "language": str,
    "pasted": str,
    "edited": str,
    "original": str,
    "replacement": str,
    "correction": bool,
    "safe_alias": bool,
    "label_source": str,
}
OUTCOMES = ("verdict", "unavailable", "not_granted", "deadline", "cancelled", "malformed", "unimplemented")
BYPASS_OUTCOMES = tuple(o for o in OUTCOMES if o != "verdict")


# --- IO ---


def load_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    with path.open(encoding="utf-8") as fh:
        for n, line in enumerate(fh, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                infra_error(f"{path}:{n}: not JSON ({exc})")
    return rows


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def infra_error(msg: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"INFRA-ERROR: {msg}", file=sys.stderr)
    sys.exit(2)


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")


# --- Corpus validation ---


def validate_rows(rows: list[dict], name: str) -> list[str]:
    """Structural problems in one split. Empty list means clean."""
    problems: list[str] = []
    seen: set[str] = set()
    seen_cases: set[tuple] = set()
    for i, row in enumerate(rows, start=1):
        where = f"{name} row {i}"
        if not isinstance(row, dict):
            problems.append(f"{where}: row must be an object")
            continue
        for key, typ in REQUIRED_ROW_KEYS.items():
            if key not in row:
                problems.append(f"{where}: missing {key}")
                continue
            # bool is an int subclass; require the exact type so 0/1 cannot
            # stand in for a label.
            if type(row[key]) is not typ:
                problems.append(f"{where}: {key} must be {typ.__name__}, got {type(row[key]).__name__}")
        if problems and problems[-1].startswith(where):
            continue
        if row["id"] in seen:
            problems.append(f"{where}: duplicate id {row['id']}")
        seen.add(row["id"])
        if row["stratum"] not in STRATA:
            problems.append(f"{where}: unknown stratum {row['stratum']}")
        if row["original"] == row["replacement"]:
            problems.append(f"{where}: original equals replacement")
        if row["pasted"].count(row["original"]) != 1:
            problems.append(f"{where}: original must occur exactly once inside pasted")
        elif row["pasted"].replace(row["original"], row["replacement"], 1) != row["edited"]:
            problems.append(f"{where}: edited is not pasted with the one run replaced (multi-change row)")
        if row["replacement"] not in row["edited"]:
            problems.append(f"{where}: replacement is not inside edited")
        if row["pasted"] == row["edited"]:
            problems.append(f"{where}: pasted equals edited")
        if row["safe_alias"] and not row["correction"]:
            problems.append(f"{where}: safe_alias cannot be true when correction is false")
        if not row["label_source"].strip():
            problems.append(f"{where}: empty label_source")
        if "probe" in row and type(row["probe"]) is not bool:
            problems.append(f"{where}: probe must be bool when present")
        case = (row["pasted"], row["edited"])
        if case in seen_cases:
            problems.append(f"{where}: duplicates an earlier case in {name}")
        seen_cases.add(case)
    return problems


def validate_corpus(working: list[dict], holdout: list[dict]) -> list[str]:
    problems = validate_rows(working, "working") + validate_rows(holdout, "holdout")
    if problems:
        return problems
    if len(working) < MIN_WORKING_ROWS:
        problems.append(f"working has {len(working)} rows, needs >= {MIN_WORKING_ROWS}")
    if len(holdout) < MIN_HOLDOUT_ROWS:
        problems.append(f"holdout has {len(holdout)} rows, needs >= {MIN_HOLDOUT_ROWS}")
    for split_name, rows in (("working", working), ("holdout", holdout)):
        present = {r.get("stratum") for r in rows}
        for s in STRATA:
            if s not in present:
                problems.append(f"{split_name}: stratum {s} has no rows")
        labels = {(r.get("correction"), r.get("safe_alias")) for r in rows}
        if not any(c is True for c, _ in labels):
            problems.append(f"{split_name}: no correction=true rows")
        if not any(c is False for c, _ in labels):
            problems.append(f"{split_name}: no correction=false rows")
        if not any(s is True for _, s in labels):
            problems.append(f"{split_name}: no safe_alias=true rows")
        if not any(c is True and s is False for c, s in labels):
            problems.append(f"{split_name}: no correction=true with safe_alias=false rows")
    w_ids = {r.get("id") for r in working}
    h_ids = {r.get("id") for r in holdout}
    for dup in sorted(w_ids & h_ids):
        problems.append(f"id {dup} appears in both splits")
    w_cases = {(r.get("pasted"), r.get("edited")) for r in working}
    for r in holdout:
        if (r.get("pasted"), r.get("edited")) in w_cases:
            problems.append(f"holdout {r.get('id')} duplicates a working case")
    return problems


# --- Scoring ---


@dataclass
class Scorecard:
    judge: str
    attempted: int = 0
    completed: int = 0
    bypass_counts: dict = field(default_factory=dict)
    positives: int = 0
    true_positives: int = 0
    negatives: int = 0
    false_positives: int = 0
    predicted_safe_aliases: int = 0
    correct_safe_aliases: int = 0
    latencies_ms: list = field(default_factory=list)
    per_stratum: dict = field(default_factory=dict)
    problems: list = field(default_factory=list)

    @property
    def correction_recall(self) -> Optional[float]:
        return None if self.positives == 0 else self.true_positives / self.positives

    @property
    def false_add_rate(self) -> Optional[float]:
        return None if self.negatives == 0 else self.false_positives / self.negatives

    @property
    def alias_precision(self) -> Optional[float]:
        return None if self.predicted_safe_aliases == 0 else self.correct_safe_aliases / self.predicted_safe_aliases

    def percentile(self, p: float) -> Optional[float]:
        if not self.latencies_ms:
            return None
        xs = sorted(self.latencies_ms)
        k = max(0, min(len(xs) - 1, int(round((p / 100.0) * (len(xs) - 1)))))
        return xs[k]

    def verdict(self) -> tuple[bool, list[str]]:
        reasons: list[str] = list(self.problems)
        checks = [
            ("correction_recall", self.correction_recall, ">=", THRESHOLDS["correction_recall_min"]),
            ("false_add_rate", self.false_add_rate, "<=", THRESHOLDS["false_add_rate_max"]),
            ("alias_precision", self.alias_precision, ">=", THRESHOLDS["alias_precision_min"]),
            ("latency_p50_ms", self.percentile(50), "<=", THRESHOLDS["latency_p50_ms_max"]),
            ("latency_p95_ms", self.percentile(95), "<=", THRESHOLDS["latency_p95_ms_max"]),
        ]
        for name, value, op, bound in checks:
            if value is None:
                reasons.append(f"{name} undefined (zero denominator)")
                continue
            ok = value >= bound if op == ">=" else value <= bound
            if not ok:
                reasons.append(f"{name} {value:.4f} {op} {bound} failed")
        return (not reasons, reasons)

    def to_dict(self) -> dict:
        passed, reasons = self.verdict()
        return {
            "judge": self.judge,
            "pass": passed,
            "reasons": reasons,
            "thresholds": THRESHOLDS,
            "attempted": self.attempted,
            "completed": self.completed,
            "bypass_counts": dict(sorted(self.bypass_counts.items())),
            "correction_recall": {"value": self.correction_recall, "num": self.true_positives, "den": self.positives},
            "false_add_rate": {"value": self.false_add_rate, "num": self.false_positives, "den": self.negatives},
            "alias_precision": {
                "value": self.alias_precision,
                "num": self.correct_safe_aliases,
                "den": self.predicted_safe_aliases,
            },
            "latency_ms": {"p50": self.percentile(50), "p95": self.percentile(95), "n": len(self.latencies_ms)},
            "per_stratum": self.per_stratum,
        }


def score(rows: list[dict], records: list[dict], judge_name: str = "") -> Scorecard:
    """Score records against labelled rows. Structural defects become
    `problems`, which fail the verdict; they never shrink a denominator."""
    card = Scorecard(judge=judge_name)
    card.problems.extend(validate_rows(rows, "score"))
    if card.problems:
        return card
    by_id: dict[str, dict] = {}
    for rec in records:
        if not isinstance(rec, dict):
            card.problems.append("result must be an object")
            continue
        actual_judge = rec.get("judge")
        if not isinstance(actual_judge, str) or not actual_judge.strip():
            card.problems.append("result has no judge identity")
        elif not card.judge:
            card.judge = actual_judge
        elif actual_judge != card.judge:
            card.problems.append(f"judge mismatch: expected {card.judge}, got {actual_judge}")
        rid = rec.get("id")
        if not isinstance(rid, str):
            card.problems.append("record without a string id")
            continue
        if rid in by_id:
            card.problems.append(f"duplicate result id {rid}")
        by_id[rid] = rec
    row_ids = {r["id"] for r in rows}
    for extra in sorted(set(by_id) - row_ids):
        card.problems.append(f"result id {extra} is not in the corpus")
    if not rows:
        card.problems.append("empty corpus")
        return card
    if not records:
        card.problems.append("empty results")

    for row in rows:
        card.attempted += 1
        stratum = row["stratum"]
        st = card.per_stratum.setdefault(
            stratum,
            {"rows": 0, "positives": 0, "true_positives": 0, "negatives": 0, "false_positives": 0, "bypass": 0},
        )
        st["rows"] += 1
        if row["correction"]:
            card.positives += 1
            st["positives"] += 1
        else:
            card.negatives += 1
            st["negatives"] += 1

        rec = by_id.get(row["id"])
        if rec is None:
            card.problems.append(f"missing result for {row['id']}")
            card.bypass_counts["missing"] = card.bypass_counts.get("missing", 0) + 1
            st["bypass"] += 1
            continue
        outcome = rec.get("outcome")
        if outcome not in OUTCOMES:
            card.problems.append(f"{row['id']}: unknown outcome {outcome!r}")
            st["bypass"] += 1
            continue
        # Latency is measured over EVERY attempt that reports one, bypasses
        # included: a slow deadline is exactly the latency the user waits for.
        latency = rec.get("latency_ms")
        if type(latency) not in (int, float) or not math.isfinite(latency) or latency < 0:
            card.problems.append(f"{row['id']}: latency_ms malformed")
            st["bypass"] += 1
            continue
        card.latencies_ms.append(float(latency))
        if outcome != "verdict":
            card.bypass_counts[outcome] = card.bypass_counts.get(outcome, 0) + 1
            st["bypass"] += 1
            if rec.get("decision") is not None:
                card.problems.append(f"{row['id']}: bypass {outcome} carries a decision")
            continue
        decision = rec.get("decision")
        if not isinstance(decision, dict):
            card.problems.append(f"{row['id']}: verdict without a decision")
            st["bypass"] += 1
            continue
        vc = decision.get("vocabulary_correction")
        sa = decision.get("safe_alias")
        if type(vc) is not bool or type(sa) is not bool:
            card.problems.append(f"{row['id']}: decision booleans malformed")
            st["bypass"] += 1
            continue
        card.completed += 1
        if vc and row["correction"]:
            card.true_positives += 1
            st["true_positives"] += 1
        if vc and not row["correction"]:
            card.false_positives += 1
            st["false_positives"] += 1
        # An alias only exists if the word was learned, so precision is over
        # verdicts that both accept the correction and mark the alias safe.
        if vc and sa:
            card.predicted_safe_aliases += 1
            if row["safe_alias"]:
                card.correct_safe_aliases += 1
    return card


# --- Runner ---


def run_runner(corpus_path: Path, judge: str, out_path: Path) -> int:
    if not RUNNER_BIN.exists():
        infra_error(
            f"AliasRunner binary missing at {RUNNER_BIN}. "
            "Build it with: cd scripts/eval/alias_runner && swift build -c release"
        )
    args = [str(RUNNER_BIN), "judge", "--corpus", str(corpus_path), "--judge", judge, "--out", str(out_path)]
    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode == 2:
        infra_error(f"AliasRunner judge exit 2 (usage/infra): {proc.stderr.strip()}")
    if proc.returncode not in (0, 3):
        infra_error(f"AliasRunner judge exit {proc.returncode}: {proc.stderr.strip()}")
    return proc.returncode


# --- Modes ---


def mode_validate(working_path: Path, holdout_path: Path) -> int:
    for p in (working_path, holdout_path):
        if not p.exists():
            infra_error(f"corpus missing: {p}")
    working = load_jsonl(working_path)
    holdout = load_jsonl(holdout_path)
    problems = validate_corpus(working, holdout)
    summary = {
        "working": {"path": str(working_path), "rows": len(working), "sha256": sha256_file(working_path)},
        "holdout": {"path": str(holdout_path), "rows": len(holdout), "sha256": sha256_file(holdout_path)},
        "strata": {s: sum(1 for r in working if r.get("stratum") == s) for s in STRATA},
        "holdout_strata": {s: sum(1 for r in holdout if r.get("stratum") == s) for s in STRATA},
        "problems": problems,
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0 if not problems else 1


def mode_score(corpus_path: Path, results_path: Path, judge_name: str) -> int:
    if not corpus_path.exists() or not results_path.exists():
        infra_error("corpus or results file missing")
    card = score(load_jsonl(corpus_path), load_jsonl(results_path), judge_name)
    print(json.dumps(card.to_dict(), indent=2, ensure_ascii=False))
    return 0 if card.verdict()[0] else 1


def mode_run(judge: str, holdout: bool) -> int:
    for p in (WORKING_CORPUS, HOLDOUT_CORPUS):
        if not p.exists():
            infra_error(f"corpus missing: {p}")
    problems = validate_corpus(load_jsonl(WORKING_CORPUS), load_jsonl(HOLDOUT_CORPUS))
    if problems:
        infra_error("; ".join(problems))
    corpus_path = HOLDOUT_CORPUS if holdout else WORKING_CORPUS
    run_dir = RUNS_DIR / f"{now_iso()}-{judge}{'-holdout' if holdout else ''}"
    run_dir.mkdir(parents=True, exist_ok=True)
    out_path = run_dir / "records.jsonl"
    rc = run_runner(corpus_path, judge, out_path)
    card = score(load_jsonl(corpus_path), load_jsonl(out_path), judge)
    summary = card.to_dict()
    summary["runner_exit"] = rc
    summary["corpus"] = {"path": str(corpus_path), "sha256": sha256_file(corpus_path)}
    (run_dir / "scorecard.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    print(f"receipt: {run_dir}", file=sys.stderr)
    return 0 if summary["pass"] else 1


def _synthetic_rows(n_pos: int, n_neg: int) -> list[dict]:
    rows = []
    for i in range(n_pos):
        rows.append(
            {
                "id": f"P{i}",
                "stratum": STRATA[i % len(STRATA)],
                "language": "en",
                "pasted": f"send it to Elena {i}",
                "edited": f"send it to Alina {i}",
                "original": "Elena",
                "replacement": "Alina",
                "correction": True,
                "safe_alias": i % 2 == 0,
                "label_source": "selftest",
            }
        )
    for i in range(n_neg):
        rows.append(
            {
                "id": f"N{i}",
                "stratum": STRATA[i % len(STRATA)],
                "language": "en",
                "pasted": f"let us know by Friday {i}",
                "edited": f"let me know by Friday {i}",
                "original": "us",
                "replacement": "me",
                "correction": False,
                "safe_alias": False,
                "label_source": "selftest",
            }
        )
    return rows


def _record(rid: str, vc: Optional[bool], sa: Optional[bool], outcome: str = "verdict", latency: float = 100.0,
            judge: str = "selftest") -> dict:
    rec = {"id": rid, "judge": judge, "outcome": outcome, "latency_ms": latency, "decision": None}
    if outcome == "verdict":
        rec["decision"] = {"vocabulary_correction": vc, "safe_alias": sa}
    return rec


def mode_selftest() -> int:
    """Two-way control: a scorecard that must PASS, several that must FAIL,
    each for the named reason, plus refusals on malformed input."""
    failures: list[str] = []
    checks_run = 0

    def check(name: str, cond: bool) -> None:
        nonlocal checks_run
        checks_run += 1
        if not cond:
            failures.append(name)

    rows = _synthetic_rows(20, 20)
    # Passing set: every positive accepted with the labelled alias safety,
    # negatives rejected, fast.
    good = [_record(r["id"], r["correction"], r["safe_alias"], latency=50.0) for r in rows]
    card = score(rows, good)
    ok, reasons = card.verdict()
    check("passing scorecard passes", ok and not reasons)
    check("passing recall denominators", card.true_positives == 20 and card.positives == 20)
    check("passing alias precision uses only learned rows", card.predicted_safe_aliases == 10 and card.correct_safe_aliases == 10)
    check("passing bypass counts empty", card.bypass_counts == {})

    # Recall failure: four bypasses on positives stay in the denominator.
    bypassed = [
        _record(r["id"], None, None, outcome="deadline") if r["id"] in {"P0", "P1", "P2", "P3"} else
        _record(r["id"], r["correction"], r["safe_alias"])
        for r in rows
    ]
    card = score(rows, bypassed)
    ok, reasons = card.verdict()
    check("bypass on positives fails recall", not ok and any(x.startswith("correction_recall") for x in reasons))
    check("bypass counted", card.bypass_counts == {"deadline": 4} and card.positives == 20 and card.true_positives == 16)
    check("card takes its judge identity from the records", card.judge == "selftest")

    # Slow bypasses count in latency: four 9 s deadlines among fast verdicts push p95 over budget.
    slow_bypass = [
        _record(r["id"], None, None, outcome="deadline", latency=9000.0) if r["id"] in {"P0", "P1", "N0", "N1"} else
        _record(r["id"], r["correction"], r["safe_alias"], latency=50.0)
        for r in rows
    ]
    card = score(rows, slow_bypass)
    ok, reasons = card.verdict()
    check("slow bypasses fail p95", any(x.startswith("latency_p95") for x in reasons) and len(card.latencies_ms) == 40)

    # Judge identity controls.
    wrong_name = score(rows, good, "j3-afm-macos27")
    check("scorecard name that disagrees with the records is a problem", any("judge mismatch" in p for p in wrong_name.problems))
    mixed = [dict(g) for g in good]
    mixed[3] = dict(mixed[3], judge="other")
    check("mixed judges in one results file is a problem", any("judge mismatch" in p for p in score(rows, mixed).problems))
    nameless = [dict(g) for g in good]
    nameless[0] = dict(nameless[0], judge="")
    check("a record without a judge is a problem", any("no judge identity" in p for p in score(rows, nameless).problems))
    for bad in (float("nan"), float("inf"), -1.0, None, "fast"):
        broken = [dict(g) for g in good]
        broken[0] = dict(broken[0], latency_ms=bad)
        check(f"latency {bad!r} is malformed", any("latency_ms malformed" in p for p in score(rows, broken).problems))

    # Score-level corpus validation: bad labels or a duplicated corpus row never reach the metrics.
    int_rows = [dict(rows[0], correction=1)] + rows[1:]
    check("score refuses int labels", any("must be bool" in p for p in score(int_rows, good).problems))
    dup_rows = rows + [dict(rows[0])]
    check("score refuses a duplicated corpus row", any("duplicate id" in p for p in score(dup_rows, good).problems))
    dup_case = rows + [dict(rows[0], id="P-DUP")]
    check("score refuses a duplicated case under a new id", any("duplicates an earlier case" in p for p in score(dup_case, good).problems))
    not_object = rows + ["oops"]
    check("score refuses a non-object row", any("row must be an object" in p for p in score(not_object, good).problems))
    check("score refuses a non-object record", any("result must be an object" in p for p in score(rows, good + ["oops"]).problems))

    # False-add failure: two negatives accepted (0.10 > 0.05).
    fp = [
        _record(r["id"], True, False) if r["id"] in {"N0", "N1"} else _record(r["id"], r["correction"], r["safe_alias"])
        for r in rows
    ]
    card = score(rows, fp)
    ok, reasons = card.verdict()
    check("false adds fail", not ok and any(x.startswith("false_add_rate") for x in reasons))
    check("false-add denominators", card.false_positives == 2 and card.negatives == 20)

    # Alias precision failure: alias marked safe where the label says unsafe.
    unsafe = [
        _record(r["id"], r["correction"], True if r["correction"] else False) for r in rows
    ]
    card = score(rows, unsafe)
    ok, reasons = card.verdict()
    check("unsafe aliases fail precision", not ok and any(x.startswith("alias_precision") for x in reasons))
    check("alias precision denominators", card.predicted_safe_aliases == 20 and card.correct_safe_aliases == 10)

    # Latency failure: p95 over budget while p50 is fine.
    slow = [
        _record(r["id"], r["correction"], r["safe_alias"], latency=9000.0 if i % 10 == 0 else 100.0)
        for i, r in enumerate(rows)
    ]
    card = score(rows, slow)
    ok, reasons = card.verdict()
    check("slow p95 fails", not ok and any(x.startswith("latency_p95") for x in reasons))
    check("slow p50 still fine", not any(x.startswith("latency_p50") for x in reasons))

    # Undefined metric: no learned row at all means alias precision is undefined, and that FAILS.
    none_learned = [_record(r["id"], False, False) for r in rows]
    card = score(rows, none_learned)
    ok, reasons = card.verdict()
    check("undefined alias precision fails", not ok and any("alias_precision undefined" in x for x in reasons))

    # Structural refusals, each visible by name.
    missing = good[:-1]
    card = score(rows, missing)
    check("missing result id is a problem", any(p.startswith("missing result for") for p in card.problems))
    dup = good + [good[0]]
    card = score(rows, dup)
    check("duplicate result id is a problem", any(p.startswith("duplicate result id") for p in card.problems))
    extra = good + [_record("ZZZ", True, True)]
    card = score(rows, extra)
    check("extra result id is a problem", any("not in the corpus" in p for p in card.problems))
    bad_bool = [dict(g) for g in good]
    bad_bool[0] = dict(bad_bool[0], decision={"vocabulary_correction": 1, "safe_alias": True})
    card = score(rows, bad_bool)
    check("non-bool decision is a problem", any("booleans malformed" in p for p in card.problems))
    bad_outcome = [dict(g) for g in good]
    bad_outcome[0] = dict(bad_outcome[0], outcome="maybe")
    card = score(rows, bad_outcome)
    check("unknown outcome is a problem", any("unknown outcome" in p for p in card.problems))
    card = score(rows, [])
    ok, _ = card.verdict()
    check("empty results fail", not ok and "empty results" in card.problems)
    card = score([], good)
    ok, _ = card.verdict()
    check("empty corpus fails", not ok and "empty corpus" in card.problems)

    # Corpus validation two-way control.
    w = _synthetic_rows(80, 80)
    h = [dict(r, id="H" + r["id"], pasted=r["pasted"] + " h", edited=r["edited"] + " h") for r in _synthetic_rows(30, 30)]
    check("synthetic corpus validates", validate_corpus(w, h) == [])
    leaked = h + [dict(w[0], id="LEAK")]
    check("cross-split duplicate case detected", any("duplicates a working case" in p for p in validate_corpus(w, leaked)))
    same_id = h + [dict(h[0], id=w[0]["id"], pasted="x y", edited="x z", original="y", replacement="z")]
    check("cross-split duplicate id detected", any("appears in both splits" in p for p in validate_corpus(w, same_id)))
    short = w[:100]
    check("short working corpus detected", any("needs >= 150" in p for p in validate_corpus(short, h)))
    bad_label = [dict(w[0], id="BAD", correction=False, safe_alias=True)] + w[1:]
    check("safe_alias without correction detected", any("safe_alias cannot be true" in p for p in validate_corpus(bad_label, h)))
    int_label = [dict(w[0], correction=1)] + w[1:]
    check("int standing in for bool detected", any("must be bool" in p for p in validate_corpus(int_label, h)))
    ambiguous = [dict(w[0], pasted="Elena and Elena", edited="Alina and Elena", original="Elena", replacement="Alina")] + w[1:]
    check("ambiguous original detected", any("exactly once" in p for p in validate_corpus(ambiguous, h)))
    multi = [dict(w[0], edited=w[0]["edited"] + " extra")] + w[1:]
    check("multi-change row detected", any("multi-change" in p for p in validate_corpus(multi, h)))

    if failures:
        print(f"SELFTEST FAIL ({len(failures)} of {checks_run} checks):\n  " + "\n  ".join(failures))
        return 1
    print(f"SELFTEST PASS: {checks_run} checks")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mode", choices=["validate-corpus", "score", "run", "selftest"], required=True)
    p.add_argument("--working", type=Path, default=WORKING_CORPUS)
    p.add_argument("--holdout-corpus", type=Path, default=HOLDOUT_CORPUS)
    p.add_argument("--corpus", type=Path, help="score: the corpus the results were run on")
    p.add_argument("--results", type=Path, help="score: runner records JSONL")
    p.add_argument("--judge", help="run: judge candidate name; score: label for the scorecard")
    p.add_argument("--holdout", action="store_true", help="run: score the holdout split instead of working")
    args = p.parse_args()

    if args.mode == "validate-corpus":
        return mode_validate(args.working, args.holdout_corpus)
    if args.mode == "score":
        if not args.results:
            infra_error("--mode score needs --results")
        return mode_score(args.corpus or WORKING_CORPUS, args.results, args.judge or "")
    if args.mode == "run":
        if not args.judge:
            infra_error("--mode run needs --judge")
        return mode_run(args.judge, args.holdout)
    return mode_selftest()


if __name__ == "__main__":
    sys.exit(main())
