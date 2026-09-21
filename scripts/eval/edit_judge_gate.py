#!/usr/bin/env python3
"""Edit-judge gate — issue #996 (learn custom words from the user's own edits).

Scores ONE correction-judge candidate over a labelled edit corpus that
`scripts/eval/alias_runner` `judge` emits, and says PASS or FAIL against the
plan's §3a thresholds. It owns edit-specific scoring only; runner invocation,
build and corpus discovery follow `alias_suggestion_gate.py`'s conventions
(`alias-eval.md` RULE: use-canonical-alias-harness).

Two partitions, and the gate never confuses them:

  frozen-report   the 209 council-reviewed rows in `edit-corpus-a.jsonl` and
                  `edit-corpus-a-holdout.jsonl`, frozen by
                  `edit-judge-frozen-manifest.json` (file digests plus the
                  content-hash set). No judge is trained, threshold-swept or
                  prompt-tuned on them. Scoring here REQUIRES a training
                  manifest for the judge (`edit_judge_data.py`), refuses any
                  overlap with the frozen rows by content hash or alias
                  family, and is the only result that counts as acceptance
                  evidence. An untrained arm (rules, AFM) files a manifest of
                  kind `untrained-arm`; a missing manifest fails closed.
  dev             any other labelled file (generated data, smoke fixtures).
                  Scored with the same arithmetic, printed with
                  `acceptance_evidence: false`, never a §3a verdict. A dev
                  file that overlaps the frozen rows by content hash or alias
                  family is REFUSED before any inference or scoring: a
                  "not evidence" label does not stop anyone tuning on it.

Every metric is reported with numerator and denominator, and a bypass (the
judge did not answer) stays IN the population: a bypass on a true correction
is a missed correction, never a discarded row. An undefined metric (zero
denominator) cannot pass.

Modes:
  validate-corpus   structure, strata, labels, disjointness, frozen manifest
  freeze            write the frozen manifest (refuses to overwrite)
  score             score a results JSONL against the corpus it was run on
  run               invoke the runner for a named judge, then score
  selftest          synthetic passing and failing scorecards prove the gate

Exit codes: 0 pass, 1 fail (a real verdict), 2 infra/usage.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).parent))
import edit_judge_data as data  # noqa: E402

ROOT = Path(__file__).parent.parent.parent.resolve()
CORPUS_DIR = ROOT / "scripts/eval/corpus"
WORKING_CORPUS = CORPUS_DIR / "edit-corpus-a.jsonl"
HOLDOUT_CORPUS = CORPUS_DIR / "edit-corpus-a-holdout.jsonl"
FROZEN_MANIFEST = CORPUS_DIR / "edit-judge-frozen-manifest.json"
FROZEN_PARTITIONS = {"working": WORKING_CORPUS, "holdout": HOLDOUT_CORPUS}
# Exam v2 (#996, founder 2026-09-19): about 100 rows per kind over the
# taxonomy in `exam-v2-taxonomy.json`, Luna-authored, Terra+Sol blind-labelled,
# Astra-adjudicated and quality-graded. A separate frozen manifest, append-only
# beside the legacy one: freezing v2 never touches the legacy 209 rows, and
# exposure is counted per exam.
EXAM_V2_CORPUS = CORPUS_DIR / "edit-judge-exam-v2.jsonl"
EXAM_V2_MANIFEST = CORPUS_DIR / "edit-judge-exam-v2-manifest.json"
EXAM_V2_TAXONOMY = CORPUS_DIR / "edit-judge-exam-v2-taxonomy.json"
EXAM_V2_PARTITIONS = {"exam": EXAM_V2_CORPUS}
EXAMS = {
    "legacy": {"manifest": FROZEN_MANIFEST, "partitions": FROZEN_PARTITIONS},
    "v2": {"manifest": EXAM_V2_MANIFEST, "partitions": EXAM_V2_PARTITIONS},
}
# A kind below this floor is not measurable at all and is left out of the
# exam file (recorded as absent); between the floor and the 100-row target a
# kind is frozen with its shortage recorded and its wider interval shown.
MIN_ROWS_PER_KIND = 20
TARGET_ROWS_PER_KIND = 100
RUNS_DIR = ROOT / "benchmark-results/eval/edit-judge/runs"
RUNNER_BIN = ROOT / "scripts/eval/alias_runner/.build/release/AliasRunner"

# --- Contract (plan §3a, locked 2026-09-18; frozen partitions added the same day) ---

PARTITIONS = ("dev", "frozen-report")
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
# Plan §3a after the 2026-09-19 pivot: the judge decides only whether an edit
# is a vocabulary fix worth PROPOSING; a person confirms every write. So the
# gate is correction recall, the false-proposal rate (`false_add_rate` keeps
# its key so older receipts still read) and latency. Alias precision and
# recall are ADVISORY: reported with denominators, never a verdict, including
# when undefined.
# Founder 2026-09-19 ("think about the human experience; no one will like the
# feature if it keeps triggering for wrong examples"): the false-proposal bar
# tightened from 0.05 to 0.02. Receipts scored before this change carry
# their own `thresholds` block, so they still read under the bar they met.
THRESHOLDS = {
    "correction_recall_min": 0.85,
    "false_add_rate_max": 0.02,
    "latency_p50_ms_max": 2000.0,
    "latency_p95_ms_max": 5000.0,
}
# Per-kind guardrails (founder 2026-09-19, from the Codex exam-design round):
# no positive kind below this recall, no negative kind above this
# false-proposal rate. They apply to rows that carry a `kind` (exam v2) and
# are reported, never invented, for rows that do not.
KIND_GUARDRAILS = {
    "kind_recall_min": 0.80,
    "kind_false_add_rate_max": 0.05,
}
ADVISORY = {
    "alias_precision_reference": 0.95,
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
# Judges whose records can never be acceptance evidence, whatever partition.
NON_EVIDENCE_JUDGES = ("fixture", "selftest")


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
    return data.sha256_file(path)


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
    # Content identity across splits: a re-labelled or re-id'd copy of a
    # working row must not sit in holdout either.
    w_hashes = {data.content_hash(r) for r in working}
    for r in holdout:
        if data.content_hash(r) in w_hashes:
            problems.append(f"holdout {r.get('id')} has the same content hash as a working row")
    return problems


def validate_exam_v2(rows: list[dict]) -> list[str]:
    """Exam v2 shape: every row valid, carries a `kind` from the taxonomy
    whose label and stratum it matches, `safe_alias` false (no alias claim
    is made by this exam), and every judged kind has at least
    MIN_ROWS_PER_KIND rows. Per-kind targets and shortages are reported by
    the authoring pipeline; a kind below the floor is a refusal here."""
    problems = validate_rows(rows, "exam")
    if problems:
        return problems
    if not EXAM_V2_TAXONOMY.exists():
        return [f"taxonomy missing: {EXAM_V2_TAXONOMY}"]
    taxonomy = json.loads(EXAM_V2_TAXONOMY.read_text(encoding="utf-8"))
    kinds = {k["kind"]: k for k in taxonomy["kinds"]}
    counts: dict[str, int] = {}
    for r in rows:
        k = kinds.get(r.get("kind"))
        if k is None:
            problems.append(f"{r['id']}: kind {r.get('kind')!r} is not in the taxonomy")
            continue
        if r["correction"] is not k["correction"] or r["stratum"] != k["stratum"]:
            problems.append(f"{r['id']}: label or stratum disagrees with kind {k['kind']}")
        if r["safe_alias"] is not False:
            problems.append(f"{r['id']}: exam v2 rows carry no alias claim (safe_alias must be false)")
        counts[k["kind"]] = counts.get(k["kind"], 0) + 1
    for name, n in counts.items():
        if n < MIN_ROWS_PER_KIND:
            problems.append(f"kind {name} has {n} rows, needs >= {MIN_ROWS_PER_KIND} (leave the kind out and record it as absent)")
    if not any(r["correction"] for r in rows) or not any(not r["correction"] for r in rows):
        problems.append("exam v2 needs both labels")
    # Diversity the taxonomy declares: unique replacement, unique sentence,
    # bounded frame reuse per kind and overall.
    reps = Counter(data.family_key(r) for r in rows)
    dup_reps = [k for k, n in reps.items() if n > 1]
    if dup_reps:
        problems.append(f"{len(dup_reps)} replacement(s) used by more than one row (first: {dup_reps[:3]})")
    sents = Counter(data._nfc(r["pasted"]).casefold() for r in rows)
    if any(n > 1 for n in sents.values()):
        problems.append("a pasted sentence is used by more than one row")
    per_kind_frame: dict = {}
    overall_frame: Counter = Counter()
    for r in rows:
        fr = str(r.get("frame", "")).strip().lower() or "no-frame"
        per_kind_frame.setdefault(r["kind"], Counter())[fr] += 1
        overall_frame[fr] += 1
    max_kind = taxonomy.get("max_rows_per_frame_per_kind", 2)
    max_all = taxonomy.get("max_rows_per_frame_overall", 10)
    over_kind = sum(1 for k, c in per_kind_frame.items() for fr, n in c.items() if n > max_kind)
    over_all = sum(1 for fr, n in overall_frame.items() if n > max_all)
    if over_kind or over_all:
        problems.append(f"frame reuse over the declared caps: {over_kind} kind/frame pairs above {max_kind}, {over_all} frames above {max_all}")
    return problems


def exam_v2_coverage(rows: list[dict]) -> dict:
    """Every kind's count against the target, including absent kinds: the
    freeze records this and the receipt reports it; nothing is padded."""
    taxonomy = json.loads(EXAM_V2_TAXONOMY.read_text(encoding="utf-8"))
    counts = Counter(r["kind"] for r in rows)
    return {
        "target": TARGET_ROWS_PER_KIND,
        "counts": dict(sorted(counts.items())),
        "short_kinds": {k["kind"]: TARGET_ROWS_PER_KIND - counts.get(k["kind"], 0) for k in taxonomy["kinds"] if 0 < counts.get(k["kind"], 0) < TARGET_ROWS_PER_KIND},
        "absent_kinds": sorted(k["kind"] for k in taxonomy["kinds"] if counts.get(k["kind"], 0) == 0),
    }


# --- Frozen partitions ---


def load_frozen(manifest_path: Path = FROZEN_MANIFEST, partitions: dict[str, Path] = FROZEN_PARTITIONS) -> tuple[dict, dict[str, list[dict]], list[str]]:
    """Read the frozen manifest and the frozen files; return (manifest, rows
    by partition, problems). Problems are anything that means the rows on
    disk are not the frozen ones, or the structure is not valid."""
    for p in list(partitions.values()) + [manifest_path]:
        if not p.exists():
            return {}, {}, [f"missing: {p}"]
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return {}, {}, [f"frozen manifest not JSON: {exc}"]
    loaded = {name: load_jsonl(path) for name, path in partitions.items()}
    if set(loaded) == {"working", "holdout"}:
        problems = validate_corpus(loaded["working"], loaded["holdout"])
    elif set(loaded) == {"exam"}:
        problems = validate_exam_v2(loaded["exam"])
    else:
        problems = [f"unknown partition layout {sorted(loaded)}"]
    if problems:
        return manifest, loaded, problems
    problems = data.check_frozen(manifest, partitions, loaded)
    if not problems and manifest.get("exam") == "v2":
        # The v2 manifest also binds its taxonomy and its parent (legacy)
        # manifest; a changed taxonomy or parent is not the frozen exam.
        if not EXAM_V2_TAXONOMY.exists() or sha256_file(EXAM_V2_TAXONOMY) != manifest.get("taxonomy_sha256"):
            problems.append("exam v2 taxonomy digest differs from the frozen manifest")
        if not FROZEN_MANIFEST.exists() or sha256_file(FROZEN_MANIFEST) != manifest.get("parent_legacy_manifest_sha256"):
            problems.append("exam v2 parent (legacy) manifest digest differs from the frozen manifest")
    return manifest, loaded, problems


def exam_identity(exam: str) -> dict:
    """Immutable identity of a frozen exam: its id and manifest digest."""
    path = EXAMS[exam]["manifest"]
    return {"exam": exam, "manifest_sha256": sha256_file(path) if path.exists() else None}


def load_exam(exam: str) -> tuple[dict, dict[str, list[dict]], list[str]]:
    """`load_frozen` for a named exam version."""
    if exam not in EXAMS:
        return {}, {}, [f"unknown exam {exam!r}; known: {sorted(EXAMS)}"]
    return load_frozen(EXAMS[exam]["manifest"], EXAMS[exam]["partitions"])


def frozen_manifests_present() -> list[dict]:
    """Every REGISTERED frozen exam, validated (files on disk are the frozen
    ones): dev inputs and training manifests must be disjoint from ALL of
    them. An exam whose files are missing or altered is an infra error, never
    a silently shorter list; only an exam that was never frozen (no manifest
    at all) is skipped, and named."""
    out = []
    for exam, spec in EXAMS.items():
        if not spec["manifest"].exists():
            continue
        manifest, _, problems = load_frozen(spec["manifest"], spec["partitions"])
        if problems:
            infra_error(f"frozen exam {exam} is not intact: " + "; ".join(problems[:5]))
        manifest = dict(manifest, _exam=exam, _manifest_sha256=sha256_file(spec["manifest"]))
        out.append(manifest)
    return out


def _same_exam(a: dict, b: dict) -> bool:
    return a.get("_manifest_sha256") is not None and a.get("_manifest_sha256") == b.get("_manifest_sha256")


def new_run_dir(stamp: str, judge: str, partition: str, runs_dir: Path = RUNS_DIR) -> Path:
    """A receipt directory that did not exist before this call. Two runs in
    the same second must not share (and silently overwrite) one receipt, so
    the name takes a suffix until `mkdir` succeeds exclusively."""
    base = f"{stamp}-{judge}-{partition}"
    for n in range(1000):
        candidate = runs_dir / (base if n == 0 else f"{base}-{n}")
        try:
            candidate.mkdir(parents=True, exist_ok=False)
            return candidate
        except FileExistsError:
            continue
    infra_error(f"could not allocate a receipt directory under {runs_dir}")


ATTEMPTS_LOG = RUNS_DIR / "attempts.jsonl"


def reserve_attempt(exam: str, exam_sha: Optional[str], judge: str, identity: dict, command: list[str], attempts_log: Path = ATTEMPTS_LOG) -> dict:
    """Append-only attempt ledger keyed by exam identity plus complete
    candidate identity, written BEFORE the runner launches. A second
    inference attempt for the same key is refused: one run per locked
    candidate per exam version is enforced here, not by counting scorecards.
    Returns the reservation record (status `started`)."""
    key = {"exam": exam, "exam_manifest_sha256": exam_sha, "judge": judge, "execution_identity": identity}
    key_digest = hashlib.sha256(json.dumps(key, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).hexdigest()
    prior = []
    if attempts_log.exists():
        for line in attempts_log.read_text(encoding="utf-8").splitlines():
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                infra_error(f"{attempts_log}: unreadable line; the attempt ledger must be repaired by hand, never rewritten")
            if rec.get("key_digest") == key_digest and rec.get("status") in ("started", "completed"):
                prior.append(rec)
    if prior:
        infra_error(f"an inference attempt for this exam and candidate identity already exists ({prior[0].get('started_at')}, status {prior[0].get('status')}); one run per locked candidate per exam version")
    rec = {"key_digest": key_digest, **key, "status": "started", "started_at": now_iso(), "command": command}
    attempts_log.parent.mkdir(parents=True, exist_ok=True)
    with attempts_log.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    return rec


def complete_attempt(rec: dict, status: str, run_dir: Optional[Path], attempts_log: Path = ATTEMPTS_LOG) -> None:
    """Append the terminal state of a reservation (`completed` or `infra`)."""
    done = dict(rec, status=status, ended_at=now_iso(), run_dir=str(run_dir) if run_dir else None)
    with attempts_log.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(done, ensure_ascii=False) + "\n")


def frozen_exposure(judge: str, runs_dir: Path = RUNS_DIR, exam: str = "legacy") -> dict:
    """How many frozen-report receipts already exist for this judge. The
    frozen rows are exposed to a judge every time it is scored on them; the
    count is printed so a reader can see how often a candidate's authors
    have looked at the report set."""
    prior: list[str] = []
    if runs_dir.exists():
        for card in sorted(runs_dir.glob("*/scorecard.json")):
            try:
                doc = json.loads(card.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            # Scorecards written before exam v2 carry no `exam` key: legacy.
            if doc.get("partition") == "frozen-report" and doc.get("judge") == judge and doc.get("exam", "legacy") == exam:
                prior.append(card.parent.name)
    return {"judge": judge, "exam": exam, "prior_frozen_report_runs": len(prior), "receipts": prior}


# --- Scoring ---


@dataclass
class Scorecard:
    judge: str
    partition: str = "dev"
    attempted: int = 0
    completed: int = 0
    bypass_counts: dict = field(default_factory=dict)
    positives: int = 0
    true_positives: int = 0
    negatives: int = 0
    false_positives: int = 0
    predicted_safe_aliases: int = 0
    correct_safe_aliases: int = 0
    labelled_safe_aliases: int = 0
    latencies_ms: list = field(default_factory=list)
    per_stratum: dict = field(default_factory=dict)
    per_kind: dict = field(default_factory=dict)
    languages: dict = field(default_factory=dict)
    probe_rows: int = 0
    training: Optional[dict] = None
    exam: str = "legacy"
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

    @property
    def alias_recall(self) -> Optional[float]:
        return None if self.labelled_safe_aliases == 0 else self.correct_safe_aliases / self.labelled_safe_aliases

    @property
    def acceptance_evidence(self) -> bool:
        """Only a clean frozen-report run of a real judge with a training
        manifest can be acceptance evidence. Dev and fixture results are
        numbers about the instrument or about development data."""
        return (
            self.partition == "frozen-report"
            and self.judge not in NON_EVIDENCE_JUDGES
            and self.training is not None
            and not self.problems
        )

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
        # Per-kind guardrails (founder 2026-09-19) on rows that carry a kind:
        # a big easy kind may not hide a failing one. A kind with no rows of
        # its label is reported, never invented.
        for kind, k in sorted(self.per_kind.items()):
            if k["positives"] > 0:
                recall = k["true_positives"] / k["positives"]
                if recall < KIND_GUARDRAILS["kind_recall_min"]:
                    reasons.append(f"kind {kind} recall {recall:.4f} >= {KIND_GUARDRAILS['kind_recall_min']} failed")
            if k["negatives"] > 0:
                far = k["false_positives"] / k["negatives"]
                if far > KIND_GUARDRAILS["kind_false_add_rate_max"]:
                    reasons.append(f"kind {kind} false_add_rate {far:.4f} <= {KIND_GUARDRAILS['kind_false_add_rate_max']} failed")
        return (not reasons, reasons)

    def to_dict(self) -> dict:
        passed, reasons = self.verdict()
        return {
            "judge": self.judge,
            "partition": self.partition,
            "acceptance_evidence": self.acceptance_evidence,
            "evidence_note": (
                "frozen-report run with a training manifest and no leakage"
                if self.acceptance_evidence
                else "NOT ACCEPTANCE EVIDENCE: dev, fixture or problem-bearing result"
            ),
            "pass": passed,
            "reasons": reasons,
            "exam": self.exam,
            "thresholds": THRESHOLDS,
            "kind_guardrails": KIND_GUARDRAILS if self.per_kind else None,
            "per_kind": self.per_kind,
            "advisory": {
                "note": "alias metrics never decide the verdict (plan §3a, pivot 2026-09-19)",
                "alias_precision_reference": ADVISORY["alias_precision_reference"],
                "alias_precision": {
                    "value": self.alias_precision,
                    "num": self.correct_safe_aliases,
                    "den": self.predicted_safe_aliases,
                },
                "alias_recall": {
                    "value": self.alias_recall,
                    "num": self.correct_safe_aliases,
                    "den": self.labelled_safe_aliases,
                },
            },
            "hash_version": data.HASH_VERSION,
            "training": self.training,
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
            "languages": self.languages,
            "probe_rows": self.probe_rows,
        }


def score(
    rows: list[dict], records: list[dict], judge_name: str = "", partition: str = "dev", training: Optional[dict] = None,
    exam: str = "legacy",
) -> Scorecard:
    """Score records against labelled rows. Structural defects become
    `problems`, which fail the verdict; they never shrink a denominator."""
    if partition not in PARTITIONS:
        raise ValueError(f"partition must be one of {PARTITIONS}")
    card = Scorecard(judge=judge_name, partition=partition, training=training, exam=exam)
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
    if partition == "frozen-report":
        if card.judge in NON_EVIDENCE_JUDGES:
            card.problems.append(f"judge {card.judge!r} results are never acceptance evidence on the frozen partition")
        if training is None:
            card.problems.append("frozen-report scoring needs a training manifest (missing)")
        else:
            if training.get("judge") != card.judge:
                card.problems.append(f"training manifest judge {training.get('judge')!r} is not the records' judge {card.judge!r}")
            # Results are bound to what actually RAN, not to a judge name: every
            # record must carry the manifest's execution identity. A record
            # without one (an unimplemented arm, a fixture) is unexecuted and
            # cannot be scored as that judge.
            expected = training.get("execution_identity")
            identity_problems = data.execution_identity_problems(expected, str(training.get("kind", "")))
            if identity_problems:
                card.problems.extend(f"training manifest: {p}" for p in identity_problems)
            else:
                mismatched = [
                    str(rec.get("id", "?")) for rec in records
                    if isinstance(rec, dict) and rec.get("execution_identity") != expected
                ]
                if mismatched:
                    card.problems.append(
                        f"{len(mismatched)} record(s) do not carry the manifest's execution identity"
                        f" (first: {', '.join(mismatched[:3])})"
                    )
    card.languages = data.language_coverage(rows)
    card.probe_rows = sum(1 for r in rows if r.get("probe") is True)

    for row in rows:
        card.attempted += 1
        stratum = row["stratum"]
        st = card.per_stratum.setdefault(
            stratum,
            {"rows": 0, "positives": 0, "true_positives": 0, "negatives": 0, "false_positives": 0, "bypass": 0},
        )
        st["rows"] += 1
        kd = None
        if isinstance(row.get("kind"), str):
            kd = card.per_kind.setdefault(row["kind"], {"rows": 0, "positives": 0, "true_positives": 0, "negatives": 0, "false_positives": 0, "bypass": 0})
            kd["rows"] += 1
        if row["correction"]:
            card.positives += 1
            st["positives"] += 1
            if kd: kd["positives"] += 1
        else:
            card.negatives += 1
            st["negatives"] += 1
            if kd: kd["negatives"] += 1
        # Population, not answers: a bypassed safe-alias row still counts in
        # the advisory recall denominator, the same way a bypassed correction
        # row still counts against correction recall.
        if row["safe_alias"]:
            card.labelled_safe_aliases += 1

        rec = by_id.get(row["id"])
        if rec is None:
            card.problems.append(f"missing result for {row['id']}")
            card.bypass_counts["missing"] = card.bypass_counts.get("missing", 0) + 1
            st["bypass"] += 1
            if kd: kd["bypass"] += 1
            continue
        outcome = rec.get("outcome")
        if outcome not in OUTCOMES:
            card.problems.append(f"{row['id']}: unknown outcome {outcome!r}")
            st["bypass"] += 1
            if kd: kd["bypass"] += 1
            continue
        # Latency is measured over EVERY attempt that reports one, bypasses
        # included: a slow deadline is exactly the latency the user waits for.
        latency = rec.get("latency_ms")
        if type(latency) not in (int, float) or not math.isfinite(latency) or latency < 0:
            card.problems.append(f"{row['id']}: latency_ms malformed")
            st["bypass"] += 1
            if kd: kd["bypass"] += 1
            continue
        card.latencies_ms.append(float(latency))
        if outcome != "verdict":
            card.bypass_counts[outcome] = card.bypass_counts.get(outcome, 0) + 1
            st["bypass"] += 1
            if kd: kd["bypass"] += 1
            if rec.get("decision") is not None:
                card.problems.append(f"{row['id']}: bypass {outcome} carries a decision")
            continue
        decision = rec.get("decision")
        if not isinstance(decision, dict):
            card.problems.append(f"{row['id']}: verdict without a decision")
            st["bypass"] += 1
            if kd: kd["bypass"] += 1
            continue
        vc = decision.get("vocabulary_correction")
        sa = decision.get("safe_alias")
        if type(vc) is not bool or type(sa) is not bool:
            card.problems.append(f"{row['id']}: decision booleans malformed")
            st["bypass"] += 1
            if kd: kd["bypass"] += 1
            continue
        if sa and not vc:
            # (false, true) is not one of the judge's three classes; a judge
            # that emits it is malformed, and the row is a bypass, never a
            # silently repaired (false, false).
            card.problems.append(f"{row['id']}: decision safe_alias=true with vocabulary_correction=false is not a class")
            st["bypass"] += 1
            if kd: kd["bypass"] += 1
            continue
        card.completed += 1
        if vc and row["correction"]:
            card.true_positives += 1
            st["true_positives"] += 1
            if kd: kd["true_positives"] += 1
        if vc and not row["correction"]:
            card.false_positives += 1
            st["false_positives"] += 1
            if kd: kd["false_positives"] += 1
        # An alias only exists if the word was learned, so precision is over
        # verdicts that both accept the correction and mark the alias safe.
        if vc and sa:
            card.predicted_safe_aliases += 1
            if row["safe_alias"]:
                card.correct_safe_aliases += 1
    return card


# --- Runner ---


def manifest_path_mode(manifest: Optional[Path]) -> str:
    """`judge` or `shape+judge`, as the bound manifest declares (default judge)."""
    if manifest is None or not manifest.exists():
        return "judge"
    try:
        doc = json.loads(manifest.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return "judge"
    mode = doc.get("path", "judge")
    if mode not in ("judge", "shape+judge"):
        infra_error(f"{manifest}: unknown path {mode!r}")
    return mode


def run_runner(corpus_path: Path, judge: str, out_path: Path, model_manifest: Optional[Path] = None) -> int:
    if not RUNNER_BIN.exists():
        infra_error(
            f"AliasRunner binary missing at {RUNNER_BIN}. "
            "Build it with: cd scripts/eval/alias_runner && swift build -c release"
        )
    args = [str(RUNNER_BIN), "judge", "--corpus", str(corpus_path), "--judge", judge, "--out", str(out_path), "--path", manifest_path_mode(model_manifest)]
    if judge.startswith("xenc-"):
        # A trained classifier runs from its bound export manifest; the runner
        # derives the execution identity from what that manifest points at.
        if model_manifest is None:
            infra_error(f"{judge} needs --training-manifest <export training-manifest.json> (the runner loads the classifier from it)")
        args += ["--model-manifest", str(model_manifest)]
    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode == 2:
        infra_error(f"AliasRunner judge exit 2 (usage/infra): {proc.stderr.strip()}")
    if proc.returncode not in (0, 3):
        infra_error(f"AliasRunner judge exit {proc.returncode}: {proc.stderr.strip()}")
    return proc.returncode


# --- Modes ---


def mode_validate(working_path: Path, holdout_path: Path, manifest_path: Path) -> int:
    for p in (working_path, holdout_path):
        if not p.exists():
            infra_error(f"corpus missing: {p}")
    working = load_jsonl(working_path)
    holdout = load_jsonl(holdout_path)
    problems = validate_corpus(working, holdout)
    frozen: dict = {"manifest": str(manifest_path), "present": manifest_path.exists(), "problems": []}
    if manifest_path.exists() and not problems:
        _, _, frozen_problems = load_frozen(manifest_path, {"working": working_path, "holdout": holdout_path})
        frozen["problems"] = frozen_problems
    elif not manifest_path.exists():
        frozen["problems"] = ["frozen manifest missing: run --mode freeze once the rows are final"]
    summary = {
        "working": {"path": str(working_path), "rows": len(working), "sha256": sha256_file(working_path)},
        "holdout": {"path": str(holdout_path), "rows": len(holdout), "sha256": sha256_file(holdout_path)},
        "strata": {s: sum(1 for r in working if r.get("stratum") == s) for s in STRATA},
        "holdout_strata": {s: sum(1 for r in holdout if r.get("stratum") == s) for s in STRATA},
        "languages": data.language_coverage(working + holdout),
        "probe_rows": sum(1 for r in working + holdout if r.get("probe") is True),
        "hash_version": data.HASH_VERSION,
        "frozen": frozen,
        "problems": problems,
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0 if not problems and not frozen["problems"] else 1


def mode_freeze(working_path: Path, holdout_path: Path, manifest_path: Path, refreeze: bool, note: str, exam: str = "legacy") -> int:
    """Write the frozen manifest. Refuses to overwrite: re-freezing means the
    report set changed, which is a founder-visible decision, so it takes an
    explicit flag and prints what changed. Exam v2 freezes its OWN manifest
    (append-only beside the legacy one) and must be disjoint from the legacy
    rows by hash and family."""
    if exam == "v2":
        if not EXAM_V2_CORPUS.exists():
            infra_error(f"corpus missing: {EXAM_V2_CORPUS}")
        rows = load_jsonl(EXAM_V2_CORPUS)
        problems = validate_exam_v2(rows)
        if problems:
            infra_error("cannot freeze an invalid exam v2: " + "; ".join(problems[:8]))
        legacy, _, lp = load_exam("legacy")
        if lp:
            infra_error("legacy exam is not intact: " + "; ".join(lp))
        _require_clean_dev_against(rows, legacy)
        if EXAM_V2_MANIFEST.exists():
            # Append-only: a changed exam is a NEW exam version with its own
            # id, never a replacement of v2 under the same name.
            infra_error(f"{EXAM_V2_MANIFEST} exists; exam v2 is frozen. A changed exam needs a new version (v3), not --refreeze")
        manifest = data.build_frozen_manifest([("exam", EXAM_V2_CORPUS, rows)], frozen_at=now_iso(), note=note)
        manifest["exam"] = "v2"
        manifest["taxonomy_sha256"] = sha256_file(EXAM_V2_TAXONOMY)
        manifest["parent_legacy_manifest_sha256"] = sha256_file(FROZEN_MANIFEST)
        coverage = exam_v2_coverage(rows)
        manifest["kinds"] = coverage["counts"]
        manifest["target_rows_per_kind"] = TARGET_ROWS_PER_KIND
        manifest["short_kinds"] = coverage["short_kinds"]
        manifest["absent_kinds"] = coverage["absent_kinds"]
        EXAM_V2_MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(json.dumps({"frozen": str(EXAM_V2_MANIFEST), "rows": len(rows), "kinds": manifest["kinds"]}, indent=2))
        return 0
    for p in (working_path, holdout_path):
        if not p.exists():
            infra_error(f"corpus missing: {p}")
    working = load_jsonl(working_path)
    holdout = load_jsonl(holdout_path)
    problems = validate_corpus(working, holdout)
    if problems:
        infra_error("cannot freeze an invalid corpus: " + "; ".join(problems))
    if manifest_path.exists() and not refreeze:
        infra_error(f"{manifest_path} exists; pass --refreeze to replace it (the report set is changing)")
    manifest = data.build_frozen_manifest(
        [("working", working_path, working), ("holdout", holdout_path, holdout)], frozen_at=now_iso(), note=note
    )
    if manifest_path.exists():
        old = json.loads(manifest_path.read_text(encoding="utf-8"))
        old_hashes, new_hashes = data.frozen_hashes(old), data.frozen_hashes(manifest)
        print(
            f"REFREEZE: {len(old_hashes - new_hashes)} row(s) removed, {len(new_hashes - old_hashes)} added, "
            f"{len(old_hashes & new_hashes)} unchanged",
            file=sys.stderr,
        )
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"frozen": str(manifest_path), "partitions": {p["name"]: p["rows"] for p in manifest["partitions"]}}, indent=2))
    return 0


def require_clean_dev(rows: list[dict], frozen: dict) -> None:
    """Refuse a dev file that overlaps the frozen rows by content hash or
    alias family, BEFORE any inference or scoring. Uses the same leakage
    check a training manifest goes through, so a renamed frozen row or a
    same-family sentence with different context is refused the same way.
    Checked against the given exam AND every other frozen exam on disk."""
    _require_clean_dev_against(rows, frozen)
    for m in frozen_manifests_present():
        if _same_exam(m, frozen) or m.get("frozen_at") == frozen.get("frozen_at"):
            continue
        _require_clean_dev_against(rows, m)


def _require_clean_dev_against(rows: list[dict], frozen: dict) -> None:
    probe = data.TrainingManifest(
        judge="dev-check",
        kind="trained",
        checkpoint="not-applicable",
        tokenizer="not-applicable",
        thresholds={},
        partitions={"dev": data.partition_manifest(rows)},
        provenance="dev input validation",
        hash_version=data.HASH_VERSION,
        execution_identity={"check": "dev-input"},
    )
    problems = data.leakage_problems(probe, frozen)
    if problems:
        infra_error("dev input overlaps the frozen report set: " + "; ".join(problems))


def _training_for(judge: str, manifest_path: Optional[Path], frozen: dict) -> dict:
    """Load and check the judge's training manifest for a frozen-report run.
    Any problem is infra (the run cannot be scored), never a low score."""
    if manifest_path is None:
        infra_error("frozen-report needs --training-manifest (an untrained arm files kind untrained-arm)")
    if not manifest_path.exists():
        infra_error(f"training manifest missing: {manifest_path}")
    tm = data.load_training_manifest(manifest_path)
    problems = list(tm.problems)
    if not problems and tm.judge != judge:
        problems.append(f"training manifest judge {tm.judge!r} is not {judge!r}")
    if not problems:
        # Against the exam being run AND every other frozen exam on disk.
        seen = set()
        for other in [frozen] + frozen_manifests_present():
            key = other.get("_manifest_sha256") or other.get("frozen_at")
            if key in seen:
                continue
            seen.add(key)
            problems.extend(data.leakage_problems(tm, other))
    if problems:
        infra_error("; ".join(problems))
    summary = tm.summary()
    summary["training_manifest_sha256"] = sha256_file(manifest_path)
    return summary


def mode_score(corpus_path: Path, results_path: Path, judge_name: str, partition: str, training_path: Optional[Path], exam: str = "legacy") -> int:
    if not corpus_path.exists() or not results_path.exists():
        infra_error("corpus or results file missing")
    training: Optional[dict] = None
    frozen, loaded, problems = load_exam(exam)
    if problems:
        infra_error(f"exam {exam} partitions are not intact: " + "; ".join(problems))
    if partition == "dev":
        rows = load_jsonl(corpus_path)
        row_problems = validate_rows(rows, "dev")
        if row_problems:
            infra_error("; ".join(row_problems))
        require_clean_dev(rows, frozen)
    if partition == "frozen-report":
        corpus_sha = sha256_file(corpus_path)
        if corpus_sha not in {p["file_sha256"] for p in frozen["partitions"]}:
            infra_error(f"{corpus_path} is not a frozen partition file; score it with --partition dev")
        if not judge_name:
            infra_error("frozen-report scoring needs --judge to bind the training manifest")
        training = _training_for(judge_name, training_path, frozen)
    card = score(load_jsonl(corpus_path), load_jsonl(results_path), judge_name, partition, training, exam=exam)
    print(json.dumps(card.to_dict(), indent=2, ensure_ascii=False))
    return 0 if card.verdict()[0] else 1


def mode_run(judge: str, partition: str, corpus_path: Optional[Path], training_path: Optional[Path], exam: str = "legacy") -> int:
    frozen, loaded, problems = load_exam(exam)
    if problems:
        infra_error(f"exam {exam} partitions are not intact: " + "; ".join(problems))
    stamp = now_iso()
    if partition == "dev":
        if corpus_path is None:
            infra_error("--partition dev needs --corpus <labelled jsonl>")
        if not corpus_path.exists():
            infra_error(f"corpus missing: {corpus_path}")
        rows = load_jsonl(corpus_path)
        row_problems = validate_rows(rows, "dev")
        if row_problems:
            infra_error("; ".join(row_problems))
        require_clean_dev(rows, frozen)
        run_dir = new_run_dir(stamp, judge, "dev")
        out_path = run_dir / "records.jsonl"
        rc = run_runner(corpus_path, judge, out_path, training_path)
        card = score(rows, load_jsonl(out_path), judge, "dev")
        summary = card.to_dict()
        summary["runner_exit"] = rc
        summary["corpus"] = {"path": str(corpus_path), "sha256": sha256_file(corpus_path), "rows": len(rows)}
        summary["frozen_overlap"] = "refused before the run (require_clean_dev), so zero by construction"
        (run_dir / "scorecard.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
        print(json.dumps(summary, indent=2, ensure_ascii=False))
        print(f"receipt: {run_dir}", file=sys.stderr)
        return 0 if summary["pass"] else 1

    training = _training_for(judge, training_path, frozen)
    exposure = frozen_exposure(judge, exam=exam)
    ident = exam_identity(exam)
    reservation = reserve_attempt(exam, ident["manifest_sha256"], judge, training.get("execution_identity") or {}, sys.argv)
    run_dir = new_run_dir(stamp, judge, "frozen-report" if exam == "legacy" else f"exam-{exam}")
    per_partition: dict[str, dict] = {}
    all_rows: list[dict] = []
    all_records: list[dict] = []
    runner_exits: dict[str, int] = {}
    try:
        for name, path in EXAMS[exam]["partitions"].items():
            out_path = run_dir / f"records-{name}.jsonl"
            runner_exits[name] = run_runner(path, judge, out_path, training_path)
            records = load_jsonl(out_path)
            rows = loaded[name]
            card = score(rows, records, judge, "frozen-report", training, exam=exam)
            per_partition[name] = card.to_dict()
            all_rows.extend(rows)
            all_records.extend(records)
    except SystemExit:
        complete_attempt(reservation, "infra", run_dir)
        raise
    complete_attempt(reservation, "completed", run_dir)
    pooled = score(all_rows, all_records, judge, "frozen-report", training, exam=exam)
    summary = pooled.to_dict()
    summary["per_partition"] = per_partition
    summary["runner_exit"] = runner_exits
    manifest_path = EXAMS[exam]["manifest"]
    summary["frozen"] = {
        "exam": exam,
        "manifest": str(manifest_path),
        "sha256": sha256_file(manifest_path),
        "partitions": {p["name"]: {"file_sha256": p["file_sha256"], "rows": p["rows"]} for p in frozen["partitions"]},
    }
    summary["frozen_exposure_before_this_run"] = exposure
    summary["attempt"] = {"key_digest": reservation["key_digest"], "ledger": str(ATTEMPTS_LOG)}
    (run_dir / "scorecard.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    print(f"receipt: {run_dir}", file=sys.stderr)
    return 0 if summary["pass"] else 1


# --- Selftest ---


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


SELFTEST_IDENTITY = {"checkpoint_sha256": "a" * 64, "tokenizer_sha256": "b" * 64, "config_sha256": "c" * 64}
SELFTEST_UNTRAINED_IDENTITY = {"config_sha256": "d" * 64, "environment": "selftest macOS"}


def _record(rid: str, vc: Optional[bool], sa: Optional[bool], outcome: str = "verdict", latency: float = 100.0,
            judge: str = "selftest", identity: Optional[dict] = None) -> dict:
    rec = {"id": rid, "judge": judge, "outcome": outcome, "latency_ms": latency, "decision": None}
    if outcome == "verdict":
        rec["decision"] = {"vocabulary_correction": vc, "safe_alias": sa}
    if identity is not None:
        rec["execution_identity"] = identity
    return rec


def _fake_hash(tag: str) -> str:
    import hashlib

    return hashlib.sha256(tag.encode("utf-8")).hexdigest()


def _training_doc(judge: str, kind: str = "trained", hashes: Optional[list[str]] = None, families: Optional[list[str]] = None,
                  identity: Optional[dict] = None) -> dict:
    """A well-formed manifest. For a trained judge the three partitions are
    DISJOINT by construction: `hashes`/`families` land in train, and dev and
    calibration get their own synthetic rows."""
    doc = {
        "judge": judge,
        "kind": kind,
        "checkpoint": "selftest-checkpoint",
        "tokenizer": "selftest-tokenizer",
        "thresholds": {"correctionAndSafe": 0.9},
        "provenance": "selftest",
        "hash_version": data.HASH_VERSION,
        "execution_identity": dict(
            (SELFTEST_IDENTITY if kind == "trained" else SELFTEST_UNTRAINED_IDENTITY) if identity is None else identity
        ),
        "partitions": {},
    }
    if kind == "trained":
        doc["partitions"] = {
            "train": {"hashes": hashes or [_fake_hash("train-row")], "families": families or ["train-family"]},
            "dev": {"hashes": [_fake_hash("dev-row")], "families": ["dev-family"]},
            "calibration": {"hashes": [_fake_hash("cal-row")], "families": ["cal-family"]},
        }
    return doc


def mode_selftest() -> int:
    """Two-way control: a scorecard that must PASS, several that must FAIL,
    each for the named reason, plus refusals on malformed input."""
    import tempfile

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
    check("dev partition is never acceptance evidence", card.partition == "dev" and card.acceptance_evidence is False)
    check("scorecard carries languages and probe count", card.languages == {"en": 40} and card.probe_rows == 0)

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
    wrong_name = score(rows, good, "afm-macos27")
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

    # False-add failure: two negatives accepted (0.10 > 0.02).
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
    check("unsafe aliases are advisory: detection still passes", ok and not reasons)
    check("alias precision denominators", card.predicted_safe_aliases == 20 and card.correct_safe_aliases == 10)
    check("alias precision is reported as advisory", card.to_dict()["advisory"]["alias_precision"]["value"] == 0.5)

    # (false, true) is not a class: a judge emitting it is malformed on that row.
    not_a_class = [dict(g) for g in good]
    not_a_class[0] = dict(not_a_class[0], decision={"vocabulary_correction": False, "safe_alias": True})
    card = score(rows, not_a_class)
    check("safe alias without correction is not a class", any("is not a class" in p for p in card.problems) and card.completed == 39)

    # Latency failure: p95 over budget while p50 is fine.
    slow = [
        _record(r["id"], r["correction"], r["safe_alias"], latency=9000.0 if i % 10 == 0 else 100.0)
        for i, r in enumerate(rows)
    ]
    card = score(rows, slow)
    ok, reasons = card.verdict()
    check("slow p95 fails", not ok and any(x.startswith("latency_p95") for x in reasons))
    check("slow p50 still fine", not any(x.startswith("latency_p50") for x in reasons))

    # Undefined advisory metric: every correction accepted with no alias marked
    # safe leaves alias precision undefined, and that still PASSES; the
    # advisory block says so with a null value.
    no_alias = [_record(r["id"], r["correction"], False, latency=50.0) for r in rows]
    card = score(rows, no_alias)
    ok, reasons = card.verdict()
    check("undefined alias precision does not fail detection", ok and not reasons)
    check("undefined alias precision is reported null", card.to_dict()["advisory"]["alias_precision"]["value"] is None)
    # A required metric that is undefined still fails: no negatives at all.
    only_positives = [r for r in rows if r["correction"]]
    card = score(only_positives, [_record(r["id"], True, False, latency=50.0) for r in only_positives])
    ok, reasons = card.verdict()
    check("undefined false-add rate fails", not ok and any("false_add_rate undefined" in x for x in reasons))
    # p50 over budget fails on its own.
    slow_all = [_record(r["id"], r["correction"], r["safe_alias"], latency=2500.0) for r in rows]
    card = score(rows, slow_all)
    ok, reasons = card.verdict()
    check("slow p50 fails", not ok and any(x.startswith("latency_p50") for x in reasons))

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

    # Frozen-report partition controls (pure, no files).
    real = [dict(g, judge="xenc-selftest", execution_identity=dict(SELFTEST_IDENTITY)) for g in good]
    tm = {"judge": "xenc-selftest", "kind": "trained", "execution_identity": dict(SELFTEST_IDENTITY)}
    card = score(rows, real, "xenc-selftest", "frozen-report", tm)
    check("frozen-report with a manifest, matching identity and a real judge is acceptance evidence", card.acceptance_evidence is True and card.verdict()[0])
    card = score(rows, real, "xenc-selftest", "frozen-report", None)
    check("frozen-report without a manifest is a problem", any("training manifest (missing)" in p for p in card.problems) and not card.acceptance_evidence)
    card = score(rows, real, "xenc-selftest", "frozen-report", dict(tm, judge="someone-else"))
    check("manifest for another judge is a problem", any("is not the records' judge" in p for p in card.problems))
    other_ckpt = [dict(r, execution_identity=dict(SELFTEST_IDENTITY, checkpoint_sha256="d" * 64)) for r in real]
    card = score(rows, other_ckpt, "xenc-selftest", "frozen-report", tm)
    check("records from another checkpoint under the same judge name are refused", any("execution identity" in p for p in card.problems) and not card.acceptance_evidence)
    one_off = [dict(r) for r in real]
    one_off[7] = dict(one_off[7], execution_identity=dict(SELFTEST_IDENTITY, tokenizer_sha256="e" * 64))
    card = score(rows, one_off, "xenc-selftest", "frozen-report", tm)
    check("a single record with another tokenizer is refused by id", any("1 record(s)" in p and "P7" in p for p in card.problems))
    unexecuted = [dict(g, judge="xenc-selftest") for g in good]
    card = score(rows, unexecuted, "xenc-selftest", "frozen-report", tm)
    check("records without any execution identity are unexecuted, never evidence", any("40 record(s)" in p for p in card.problems) and not card.acceptance_evidence)
    card = score(rows, real, "xenc-selftest", "frozen-report", dict(tm, execution_identity={}))
    check("a manifest without execution identity is a problem", any("must be a non-empty object" in p for p in card.problems))
    arbitrary = [dict(r, execution_identity={"x": "y"}) for r in real]
    card = score(rows, arbitrary, "xenc-selftest", "frozen-report", dict(tm, execution_identity={"x": "y"}))
    check("an arbitrary label is not an execution identity", any("checkpoint_sha256 must be a SHA-256 digest" in p for p in card.problems) and not card.acceptance_evidence)
    fixture_recs = [dict(g, judge="fixture") for g in good]
    card = score(rows, fixture_recs, "fixture", "frozen-report", {"judge": "fixture", "kind": "untrained-arm", "execution_identity": dict(SELFTEST_UNTRAINED_IDENTITY)})
    check("fixture on the frozen partition is never evidence", any("never acceptance evidence" in p for p in card.problems) and not card.acceptance_evidence)
    check("evidence flag drops when any problem exists", score(rows, real[:-1], "xenc-selftest", "frozen-report", tm).acceptance_evidence is False)
    try:
        score(rows, good, "", "holdout")
        check("unknown partition refused", False)
    except ValueError:
        check("unknown partition refused", True)

    # Corpus validation two-way control.
    w = _synthetic_rows(80, 80)
    h = [dict(r, id="H" + r["id"], pasted=r["pasted"] + " h", edited=r["edited"] + " h") for r in _synthetic_rows(30, 30)]
    check("synthetic corpus validates", validate_corpus(w, h) == [])
    leaked = h + [dict(w[0], id="LEAK")]
    check("cross-split duplicate case detected", any("duplicates a working case" in p for p in validate_corpus(w, leaked)))
    relabelled = h + [dict(w[0], id="RELABEL", correction=False, safe_alias=False, edited=w[0]["edited"])]
    check("cross-split relabelled copy detected by content hash", any("same content hash" in p for p in validate_corpus(w, relabelled)))
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

    # Frozen manifest two-way control on real files in a temp dir.
    with tempfile.TemporaryDirectory() as td:
        tdp = Path(td)
        wp, hp, mp = tdp / "w.jsonl", tdp / "h.jsonl", tdp / "frozen.json"
        data.write_jsonl(wp, w)
        data.write_jsonl(hp, h)
        parts = {"working": wp, "holdout": hp}
        manifest = data.build_frozen_manifest([("working", wp, w), ("holdout", hp, h)], "selftest", "selftest")
        mp.write_text(json.dumps(manifest))
        _, _, probs = load_frozen(mp, parts)
        check("frozen manifest matches unchanged files", probs == [])
        # Renaming ids keeps content hashes but changes the file digest: refused
        # by digest, and the hash set still reads equal (renaming never evades).
        renamed = [dict(r, id="R" + r["id"]) for r in w]
        data.write_jsonl(wp, renamed)
        _, _, probs = load_frozen(mp, parts)
        check("renamed ids are caught by the file digest", any("file sha256" in p for p in probs))
        check("renamed ids do not change the content-hash set", not any("content-hash set" in p for p in probs))
        # A content change is caught by both.
        mutated = [dict(r) for r in w]
        mutated[0] = dict(mutated[0], pasted=mutated[0]["pasted"] + "!", edited=mutated[0]["edited"] + "!")
        data.write_jsonl(wp, mutated)
        _, _, probs = load_frozen(mp, parts)
        check("a changed frozen row is caught by the content-hash set", any("content-hash set" in p for p in probs))
        data.write_jsonl(wp, w)
        _, _, probs = load_frozen(mp, parts)
        check("restoring the rows restores the frozen state", probs == [])
        stale = dict(manifest, hash_version="edit-judge-content-hash-v0")
        mp.write_text(json.dumps(stale))
        _, _, probs = load_frozen(mp, parts)
        check("a manifest with another hash version is refused", any("hash_version" in p for p in probs))
        erased = json.loads(json.dumps(manifest))
        for part in erased["partitions"]:
            part["families"] = []
        mp.write_text(json.dumps(erased))
        _, _, probs = load_frozen(mp, parts)
        check("erased frozen families are caught", any("families differ" in p for p in probs))
        no_parts = {"hash_version": data.HASH_VERSION, "partitions": []}
        mp.write_text(json.dumps(no_parts))
        _, _, probs = load_frozen(mp, parts)
        check("a manifest with no partitions is caught", any("has no partition" in p for p in probs))
        mp.write_text(json.dumps(manifest))

        # Dev input refusal: a renamed frozen row, and a same-family sentence
        # with different context, are both refused before any scoring.
        import io
        from contextlib import redirect_stderr

        def refused(rows_in: list[dict]) -> str:
            buf = io.StringIO()
            try:
                with redirect_stderr(buf):
                    require_clean_dev(rows_in, manifest)
            except SystemExit as exc:
                return buf.getvalue() if exc.code == 2 else "wrong exit"
            return ""

        clean_dev = [dict(r, id="D" + r["id"], replacement="Zeta", edited=r["pasted"].replace(r["original"], "Zeta", 1), original=r["original"], pasted=r["pasted"] + " zz") for r in w[:5]]
        check("a family-disjoint dev file is accepted", refused(clean_dev) == "")
        check("a renamed frozen row in a dev file is refused", "content hash" in refused([dict(w[0], id="RENAMED", correction=False, safe_alias=False)]))
        same_family = [dict(w[0], id="SF", pasted="totally new context Elena here", edited="totally new context Alina here")]
        check("a same-family dev row with new context is refused", "alias famil" in refused(same_family))

        # Training manifest + leakage two-way control against that frozen set.
        tmp_path = tdp / "training.json"
        clean = _training_doc("xenc-selftest", hashes=[data.content_hash({"language": "en", "original": "Zed", "replacement": "Zeta", "pasted": "call Zed now"})], families=["zeta"])
        tmp_path.write_text(json.dumps(clean))
        tm_loaded = data.load_training_manifest(tmp_path)
        check("clean training manifest loads", tm_loaded.problems == [])
        check("clean manifest has no leakage", data.leakage_problems(tm_loaded, manifest) == [])
        contaminated = _training_doc("xenc-selftest", hashes=[data.content_hash(w[0])], families=["zeta"])
        tmp_path.write_text(json.dumps(contaminated))
        tm_loaded = data.load_training_manifest(tmp_path)
        check("frozen hash in training data is leakage", any("content hash" in p for p in data.leakage_problems(tm_loaded, manifest)))
        renamed_row = dict(w[0], id="OTHER", correction=False, safe_alias=False)
        by_family = _training_doc("xenc-selftest", hashes=[data.content_hash({"language": "en", "original": "Zed", "replacement": "Zeta", "pasted": "call Zed now"})], families=[data.family_key(w[0])])
        tmp_path.write_text(json.dumps(by_family))
        tm_loaded = data.load_training_manifest(tmp_path)
        check("frozen family in training data is leakage", any("alias famil" in p for p in data.leakage_problems(tm_loaded, manifest)))
        check("a renamed, relabelled frozen row keeps its content hash", data.content_hash(renamed_row) == data.content_hash(w[0]))
        def manifest_problems_kind(doc: dict) -> list[str]:
            tmp_path.write_text(json.dumps(doc))
            return data.load_training_manifest(tmp_path).problems

        untrained = _training_doc("rules", kind="untrained-arm")
        tmp_path.write_text(json.dumps(untrained))
        tm_loaded = data.load_training_manifest(tmp_path)
        check("untrained arm manifest loads with no partitions", tm_loaded.problems == [] and tm_loaded.partitions == {})
        check("untrained arm summary carries its execution identity", tm_loaded.summary()["execution_identity"] == SELFTEST_UNTRAINED_IDENTITY)
        check("untrained arm identity needs config digest and environment", any("environment is required" in p for p in manifest_problems_kind(_training_doc("rules", kind="untrained-arm", identity={"config_sha256": "d" * 64}))))
        check("untrained arm identity needs a real config digest", any("config_sha256 must be a SHA-256 digest" in p for p in manifest_problems_kind(_training_doc("rules", kind="untrained-arm", identity={"config_sha256": "rules-v1", "environment": "mac"}))))
        for missing in ("checkpoint_sha256", "tokenizer_sha256", "config_sha256"):
            ident = {k: v for k, v in SELFTEST_IDENTITY.items() if k != missing}
            check(f"trained identity without {missing} is refused", any(f"{missing} must be a SHA-256 digest" in p for p in manifest_problems_kind(_training_doc("xenc-selftest", identity=ident))))
        check("trained identity with an arbitrary key only is refused", len(manifest_problems_kind(_training_doc("xenc-selftest", identity={"x": "y"}))) == 3)
        check("trained identity with a short digest is refused", any("checkpoint_sha256 must be a SHA-256 digest" in p for p in manifest_problems_kind(_training_doc("xenc-selftest", identity=dict(SELFTEST_IDENTITY, checkpoint_sha256="abc")))))
        check("valid trained and untrained identities load clean", manifest_problems_kind(_training_doc("xenc-selftest")) == [] and manifest_problems_kind(_training_doc("afm-macos27", kind="untrained-arm")) == [])
        for missing_key in ("judge", "kind", "checkpoint", "tokenizer", "thresholds", "partitions", "provenance", "hash_version", "execution_identity"):
            doc = dict(clean)
            del doc[missing_key]
            tmp_path.write_text(json.dumps(doc))
            check(f"training manifest without {missing_key} fails closed", any(missing_key in p for p in data.load_training_manifest(tmp_path).problems))

        def manifest_problems(doc: dict) -> list[str]:
            tmp_path.write_text(json.dumps(doc))
            return data.load_training_manifest(tmp_path).problems

        empty_train = _training_doc("xenc-selftest")
        empty_train["partitions"]["train"] = {"hashes": [], "families": []}
        check("trained judge with an empty partition fails closed", any("is empty" in p for p in manifest_problems(empty_train)))
        check("unreadable training manifest fails closed", data.load_training_manifest(tdp / "nope.json").problems != [])
        check("a cross-encoder cannot file an untrained-arm manifest", any("needs a trained manifest" in p for p in manifest_problems(_training_doc("xenc-mmbert-small", kind="untrained-arm"))))
        check("a non-hex content hash is refused", any("invalid content hash" in p for p in manifest_problems(_training_doc("xenc-selftest", hashes=["not-a-hash"]))))
        check("a non-canonical family key is refused", any("non-canonical family" in p for p in manifest_problems(_training_doc("xenc-selftest", families=["Kubernetes"]))))
        check("an empty family key is refused", any("non-canonical family" in p for p in manifest_problems(_training_doc("xenc-selftest", families=[""]))))
        dup_doc = _training_doc("xenc-selftest", hashes=[_fake_hash("x"), _fake_hash("x")])
        check("duplicate content hashes in one partition are refused", any("duplicate content hashes" in p for p in manifest_problems(dup_doc)))
        dup_fam = _training_doc("xenc-selftest", families=["fam", "fam"])
        check("duplicate families in one partition are refused", any("duplicate families" in p for p in manifest_problems(dup_fam)))
        crossed_doc = _training_doc("xenc-selftest")
        crossed_doc["partitions"]["calibration"] = dict(crossed_doc["partitions"]["train"])
        check("a row shared by train and calibration is refused", any("shares content with another training partition" in p for p in manifest_problems(crossed_doc)))
        crossed_fam = _training_doc("xenc-selftest")
        crossed_fam["partitions"]["dev"]["families"] = list(crossed_fam["partitions"]["train"]["families"])
        check("a family shared by train and dev is refused", any("shares a family with another training partition" in p for p in manifest_problems(crossed_fam)))
        no_fam = _training_doc("xenc-selftest")
        no_fam["partitions"]["dev"]["families"] = []
        check("a trained partition without families is refused", any("needs both hashes and families" in p for p in manifest_problems(no_fam)))
        bad_identity = _training_doc("xenc-selftest", identity={"checkpoint_sha256": ""})
        check("an execution identity with an empty value is refused", any("keys and values must be non-empty strings" in p for p in manifest_problems(bad_identity)))

    # Receipt directories never collide, even within one second.
    with tempfile.TemporaryDirectory() as td:
        a = new_run_dir("stamp", "rules", "frozen-report", Path(td))
        b = new_run_dir("stamp", "rules", "frozen-report", Path(td))
        check("two receipts in one second get distinct directories", a != b and a.exists() and b.exists())

    # Family split: every family on one side, deterministic, all rows kept.
    # 30 families of uneven size (1..8 rows each) so the greedy fill has
    # something to balance and every partition must end up non-empty.
    fam_rows = []
    for f in range(30):
        for k in range(1 + f % 8):
            fam_rows.append(
                {
                    "id": f"F{f}-{k}",
                    "stratum": STRATA[f % len(STRATA)],
                    "language": "en",
                    "pasted": f"ping Elena about item {f}-{k}",
                    "edited": f"ping Term{f} about item {f}-{k}",
                    "original": "Elena",
                    "replacement": f"Term{f}",
                    "correction": True,
                    "safe_alias": k % 2 == 0,
                    "label_source": "selftest",
                }
            )
    parts_a = data.split_by_family(fam_rows, "seed-1")
    parts_b = data.split_by_family(fam_rows, "seed-1")
    check("family split is deterministic", {k: [r["id"] for r in v] for k, v in parts_a.items()} == {k: [r["id"] for r in v] for k, v in parts_b.items()})
    check("family split keeps every row", sum(len(v) for v in parts_a.values()) == len(fam_rows))
    check("family split never crosses partitions", data.cross_partition_families(parts_a) == [])
    check("family split fills every partition", all(len(v) > 0 for v in parts_a.values()))
    crossed = {"train": parts_a["train"] + parts_a["dev"][:1], "dev": parts_a["dev"], "calibration": parts_a["calibration"]}
    check("a crossed family is detected", data.cross_partition_families(crossed) != [])
    check("three-class mapping round-trips", all(data.labels_from_class(data.three_class(c, s)) == (c, s) for c, s in ((False, False), (True, False), (True, True))))
    try:
        data.three_class(False, True)
        check("(false, true) is refused as a class", False)
    except ValueError:
        check("(false, true) is refused as a class", True)

    if failures:
        print(f"SELFTEST FAIL ({len(failures)} of {checks_run} checks):\n  " + "\n  ".join(failures))
        return 1
    print(f"SELFTEST PASS: {checks_run} checks")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--mode", choices=["validate-corpus", "freeze", "score", "run", "selftest"], required=True)
    p.add_argument("--working", type=Path, default=WORKING_CORPUS)
    p.add_argument("--holdout-corpus", type=Path, default=HOLDOUT_CORPUS)
    p.add_argument("--frozen-manifest", type=Path, default=FROZEN_MANIFEST)
    p.add_argument("--refreeze", action="store_true", help="freeze: replace an existing frozen manifest (the report set changes)")
    p.add_argument("--note", default="", help="freeze: provenance note stored in the manifest")
    p.add_argument("--corpus", type=Path, help="score: the corpus the results were run on; run --partition dev: the labelled dev file")
    p.add_argument("--results", type=Path, help="score: runner records JSONL")
    p.add_argument("--judge", help="run: judge candidate name; score: label for the scorecard")
    p.add_argument("--partition", choices=PARTITIONS, help="run/score: dev (never evidence) or frozen-report (needs --training-manifest)")
    p.add_argument("--training-manifest", type=Path, help="frozen-report: the judge's training manifest (edit_judge_data.py)")
    p.add_argument("--exam", choices=sorted(EXAMS), default="legacy", help="run/freeze: which frozen exam (legacy 209 rows, or v2)")
    args = p.parse_args()

    if args.mode == "validate-corpus":
        return mode_validate(args.working, args.holdout_corpus, args.frozen_manifest)
    if args.mode == "freeze":
        return mode_freeze(args.working, args.holdout_corpus, args.frozen_manifest, args.refreeze, args.note, exam=args.exam)
    if args.mode == "score":
        if not args.results:
            infra_error("--mode score needs --results")
        if not args.partition:
            infra_error("--mode score needs --partition dev|frozen-report")
        return mode_score(args.corpus or WORKING_CORPUS, args.results, args.judge or "", args.partition, args.training_manifest, exam=args.exam)
    if args.mode == "run":
        if not args.judge:
            infra_error("--mode run needs --judge")
        if not args.partition:
            infra_error("--mode run needs --partition dev|frozen-report")
        return mode_run(args.judge, args.partition, args.corpus, args.training_manifest, exam=args.exam)
    return mode_selftest()


if __name__ == "__main__":
    sys.exit(main())
