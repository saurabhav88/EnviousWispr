#!/usr/bin/env python3
"""Train and calibrate a three-class cross-encoder edit judge offline (#996 chunk 2c).

One predeclared experiment per run: backbone revision, tokenizer digests,
seed, class order, encoding contract, optimizer, stopping rule and the
calibration objective are fixed BEFORE the first optimizer step and written
into the run's `experiment.json`. The frozen report rows are never read for
scores: every partition is checked against the frozen manifest by content
hash and alias family before training, and the trainer refuses on overlap.

Classes (index order is part of the execution identity):
  0 notCorrection        -> (vocabulary_correction false, safe_alias false)
  1 correctionButUnsafe  -> (true, false)
  2 correctionAndSafe    -> (true, true)

Decision rule (predeclared, `DECISION_RULE`):
  vocabulary_correction := p[1] + p[2] > p[0]
  safe_alias            := vocabulary_correction and p[2] >= safe_threshold
`safe_threshold` is chosen on the DEV partition as the smallest grid value
whose one-sided 95% Wilson lower bound of alias precision is >= 0.95 (the
plan's bar), breaking ties by alias recall; the locked value is then
reported on the untouched CALIBRATION partition. No qualifying threshold is
an explicit outcome, never a pass.

Outputs, under `<artifacts>/runs/<run id>/`:
  experiment.json      the locked experiment (before training)
  checkpoint/          backbone + head weights (safetensors) + tokenizer files
  training-manifest.json   `edit_judge_data` training manifest with execution identity
  metrics.json         per-epoch dev metrics, calibration sweep, locked results

Toolchain: the pinned probe venv (`edit-judge-requirements.txt`).
Run from the worktree:
  <main>/artifacts/issue-996-edit-judge/.venv/bin/python scripts/eval/train_edit_judge.py \\
      --artifacts <main>/artifacts/issue-996-edit-judge --candidate xenc-xlmr-base
Add `--smoke` for the pipeline smoke (a few steps on a few rows; never a result).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import random
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).parent))
import edit_judge_data as data  # noqa: E402
import edit_judge_gate as gate  # noqa: E402
import probe_edit_judge_compatibility as probe  # noqa: E402

CLASS_ORDER = ("notCorrection", "correctionButUnsafe", "correctionAndSafe")
DECISION_RULE = "vocabulary_correction := p[1]+p[2] > p[0]; safe_alias := vocabulary_correction and p[2] >= safe_threshold"
SAFE_THRESHOLD_GRID = [round(0.50 + 0.01 * i, 2) for i in range(50)]  # 0.50 .. 0.99
ALIAS_PRECISION_LB_MIN = 0.95
WILSON_Z_ONE_SIDED_95 = 1.6448536269514722

# --- Detection objective (#996 pivot, chunk 4a-ii) ---
# The pivot asks ONE question of the judge: is this edit a vocabulary
# correction. A classifier trained on that question has two outputs; the
# three-class Core contract is preserved at the boundary by mapping a
# positive to `correctionButUnsafe` (safeAlias=false means "no claim", never
# a product veto) and a negative to `notCorrection`.
DETECTION_CLASS_ORDER = ("notCorrection", "correction")
DETECTION_RULE = "vocabulary_correction := p[1] >= detection_threshold; safe_alias := false"
DETECTION_THRESHOLD_GRID = [round(0.05 + 0.01 * i, 2) for i in range(91)]  # 0.05 .. 0.95
# Predeclared selection on DEV (plan §3a bars; wording adopted from the Codex
# 4a-ii round 1 review): eligible thresholds need correction recall >= 0.85
# AND a one-sided 95% Wilson UPPER bound of the false-proposal rate <= 0.02.
# Choose highest recall, then lowest false-proposal upper bound, then highest
# threshold. None eligible: development qualification false; for diagnosis,
# the lowest upper bound among thresholds with recall >= 0.85 (ties: highest
# recall, then highest threshold); none reaching that recall: highest
# macro-F1, then highest threshold. Locked before calibration is inspected;
# calibration reported once. Development qualification is not runtime
# qualification. Alias metrics play no part.
FALSE_PROPOSAL_UB_MAX = 0.02  # founder 2026-09-19: the false-proposal bar is 0.02
DETECTION_RECALL_MIN = 0.85
OBJECTIVES = ("three-class", "detection")


def wilson_upper_bound(successes: int, trials: int, z: float = WILSON_Z_ONE_SIDED_95) -> float | None:
    """One-sided 95% Wilson upper bound of a proportion; None when trials == 0."""
    if trials <= 0:
        return None
    p = successes / trials
    denom = 1 + z * z / trials
    centre = p + z * z / (2 * trials)
    margin = z * math.sqrt(p * (1 - p) / trials + z * z / (4 * trials * trials))
    return (centre + margin) / denom


def decide_detection(probs: list[float], detection_threshold: float) -> tuple[bool, bool]:
    """The predeclared detection rule on one probability pair."""
    if len(probs) != 2 or not all(math.isfinite(x) for x in probs):
        raise ValueError("expected two finite probabilities")
    return probs[1] >= detection_threshold, False


def score_detection(rows: list[dict], probs: list[list[float]], detection_threshold: float) -> dict:
    """Recall and false-proposal rate with denominators and Wilson bounds, per
    language and per stratum, on labelled rows."""
    if len(rows) != len(probs):
        raise ValueError("rows and probabilities differ in length")
    def bucket():
        return {"positives": 0, "true_positives": 0, "negatives": 0, "false_positives": 0}
    total = bucket()
    per_language: dict[str, dict] = {}
    per_stratum: dict[str, dict] = {}
    for row, p in zip(rows, probs):
        vc, _ = decide_detection(p, detection_threshold)
        # The shipped path: alignment drops casing/punctuation-only runs
        # before the judge (plan step 5), so they never become proposals.
        if vc and data.stage_one_shape_drop(row["original"], row["replacement"]):
            vc = False
        for b in (total, per_language.setdefault(row["language"], bucket()), per_stratum.setdefault(row.get("stratum", "?"), bucket())):
            if row["correction"]:
                b["positives"] += 1
                b["true_positives"] += int(vc)
            else:
                b["negatives"] += 1
                b["false_positives"] += int(vc)
    tp, pos, fp, neg = total["true_positives"], total["positives"], total["false_positives"], total["negatives"]
    return {
        "detection_threshold": detection_threshold,
        "correction_recall": {"value": None if pos == 0 else tp / pos, "num": tp, "den": pos, "wilson_lb_95": wilson_lower_bound(tp, pos)},
        "false_add_rate": {"value": None if neg == 0 else fp / neg, "num": fp, "den": neg, "wilson_ub_95": wilson_upper_bound(fp, neg)},
        "per_language": per_language,
        "per_stratum": per_stratum,
    }


def _macro_f1_binary(rows: list[dict], probs: list[list[float]], threshold: float) -> float:
    tp = fp = fn = tn = 0
    for r, p in zip(rows, probs):
        pred = p[1] >= threshold and not data.stage_one_shape_drop(r["original"], r["replacement"])
        truth = bool(r["correction"])
        if pred and truth:
            tp += 1
        elif pred:
            fp += 1
        elif truth:
            fn += 1
        else:
            tn += 1
    f1_pos = 0.0 if tp == 0 else 2 * tp / (2 * tp + fp + fn)
    f1_neg = 0.0 if tn == 0 else 2 * tn / (2 * tn + fn + fp)
    return (f1_pos + f1_neg) / 2


def select_detection_threshold(rows: list[dict], probs: list[list[float]], grid: list[float] = DETECTION_THRESHOLD_GRID, ub_max: float = FALSE_PROPOSAL_UB_MAX, recall_min: float = DETECTION_RECALL_MIN) -> dict:
    """The predeclared objective above; `branch` says which clause chose and
    `qualifying` is true only for the eligible clause."""
    sweep = []
    for t in grid:
        s = score_detection(rows, probs, t)
        sweep.append({
            "detection_threshold": t,
            "correction_recall": s["correction_recall"],
            "false_add_rate": s["false_add_rate"],
            "macro_f1": _macro_f1_binary(rows, probs, t),
        })
    defined = [e for e in sweep if e["correction_recall"]["value"] is not None and e["false_add_rate"]["wilson_ub_95"] is not None]
    eligible = [e for e in defined if e["correction_recall"]["value"] >= recall_min and e["false_add_rate"]["wilson_ub_95"] <= ub_max]
    reached = [e for e in defined if e["correction_recall"]["value"] >= recall_min]
    if eligible:
        best = max(eligible, key=lambda e: (e["correction_recall"]["value"], -e["false_add_rate"]["wilson_ub_95"], e["detection_threshold"]))
        branch = "eligible: recall >= recall_min and false-proposal upper bound <= ub_max"
    elif reached:
        best = min(reached, key=lambda e: (e["false_add_rate"]["wilson_ub_95"], -e["correction_recall"]["value"], -e["detection_threshold"]))
        branch = "diagnostic: recall reached, false-proposal upper bound above ub_max"
    elif defined:
        best = max(defined, key=lambda e: (e["macro_f1"], e["detection_threshold"]))
        branch = "diagnostic: no threshold reached recall_min; highest macro-F1"
    else:
        best = None
        branch = "undefined: a required metric has no denominator"
    return {"qualifying": bool(eligible), "branch": branch, "selected": best, "ub_max": ub_max, "recall_min": recall_min, "grid": [grid[0], grid[-1], len(grid)], "sweep": sweep}


def selection_rule_text(objective: "Objective", dual: bool) -> str:
    """The ONE description of how the locked threshold is chosen; written to
    the experiment (`calibration_objective`, `detection_selection.rule`) and
    the training manifest so a reader can tell which population selected."""
    if objective.name != "detection":
        return "smallest grid safe_threshold whose one-sided 95% Wilson lower bound of alias precision on dev >= 0.95, ties by alias recall; locked value reported on calibration"
    if dual:
        return (f"dual population: a grid detection_threshold is eligible only when correction recall >= {DETECTION_RECALL_MIN} AND the one-sided 95% Wilson upper bound of the false-proposal rate <= {FALSE_PROPOSAL_UB_MAX} "
                "on BOTH the dev partition and the cross_dev partition; among eligible thresholds maximise the lower recall, then minimise the higher upper bound, then take the higher threshold; "
                "no eligible threshold is a development failure (diagnostic pick reported, qualifying false); locked value reported on calibration")
    return (f"single population: highest correction recall among grid detection_thresholds whose one-sided 95% Wilson upper bound of the dev false-proposal rate <= {FALSE_PROPOSAL_UB_MAX}; "
            f"else smallest upper bound with recall >= {DETECTION_RECALL_MIN} (non-qualifying); locked value reported on calibration")


def select_detection_threshold_dual(main_rows: list[dict], main_probs: list[list[float]], cross_rows: list[dict], cross_probs: list[list[float]], grid: list[float] = DETECTION_THRESHOLD_GRID, ub_max: float = FALSE_PROPOSAL_UB_MAX, recall_min: float = DETECTION_RECALL_MIN) -> dict:
    """Codex 4a-ii round 3 rule (adopted, founder 2026-09-19): a threshold is
    development-eligible only if recall >= recall_min AND the one-sided 95%
    Wilson upper bound on false proposals <= ub_max SEPARATELY on the main
    development partition and on the cross-author partition; undefined
    metrics fail. Among eligible thresholds: maximise the LOWER of the two
    recalls, then minimise the HIGHER false-proposal upper bound, then the
    higher threshold. No eligible threshold = development failure: the
    diagnostic pick is reported for reading only and `qualifying` is False;
    the bar is never lowered."""
    sweep = []
    for t in grid:
        m = score_detection(main_rows, main_probs, t)
        c = score_detection(cross_rows, cross_probs, t)
        entry = {"detection_threshold": t, "main": {"correction_recall": m["correction_recall"], "false_add_rate": m["false_add_rate"]}, "cross": {"correction_recall": c["correction_recall"], "false_add_rate": c["false_add_rate"]}}
        rs = [m["correction_recall"]["value"], c["correction_recall"]["value"]]
        ubs = [m["false_add_rate"]["wilson_ub_95"], c["false_add_rate"]["wilson_ub_95"]]
        entry["defined"] = all(x is not None for x in rs + ubs)
        entry["min_recall"] = min(rs) if entry["defined"] else None
        entry["max_ub"] = max(ubs) if entry["defined"] else None
        sweep.append(entry)
    defined = [e for e in sweep if e["defined"]]
    eligible = [e for e in defined if e["min_recall"] >= recall_min and e["max_ub"] <= ub_max]
    if eligible:
        best = max(eligible, key=lambda e: (e["min_recall"], -e["max_ub"], e["detection_threshold"]))
        branch = "eligible on both populations: min recall >= recall_min and max false-proposal upper bound <= ub_max"
    elif defined:
        reached = [e for e in defined if e["min_recall"] >= recall_min]
        if reached:
            best = min(reached, key=lambda e: (e["max_ub"], -e["min_recall"], -e["detection_threshold"]))
            branch = "development failure: recall reached on both, max false-proposal upper bound above ub_max"
        else:
            best = max(defined, key=lambda e: (e["min_recall"], -e["max_ub"], e["detection_threshold"]))
            branch = "development failure: no threshold reaches recall_min on both populations"
    else:
        best = None
        branch = "undefined: a required metric has no denominator on one population"
    return {"qualifying": bool(eligible), "branch": branch, "selected": best, "ub_max": ub_max, "recall_min": recall_min, "grid": [grid[0], grid[-1], len(grid)], "populations": ["dev", "cross_dev"], "sweep": sweep}


def family_row_weights(rows: list[dict], objective: "Objective") -> tuple[list[float], dict]:
    """Training-loss weights (Codex 4a-ii round 1, adopted): within each
    class every alias family carries equal total weight, split evenly over
    its rows; the classes are then normalised to equal total weight. Returns
    one weight per row (mean 1.0) and an accounting by source, language and
    stratum. Metrics never use these weights."""
    labels = [objective.label(r) for r in rows]
    n_classes = len(objective.class_order)
    fam_counts: dict[tuple[int, str], int] = {}
    for r, y in zip(rows, labels):
        key = (y, data.family_key(r))
        fam_counts[key] = fam_counts.get(key, 0) + 1
    families_per_class = [sum(1 for (y, _) in fam_counts if y == c) for c in range(n_classes)]
    raw = []
    for r, y in zip(rows, labels):
        # Family weight 1/(families in class) shared by its rows, class total 1.
        raw.append(1.0 / (families_per_class[y] * fam_counts[(y, data.family_key(r))]))
    mean = sum(raw) / len(raw)
    weights = [w / mean for w in raw]
    def bucket(keyf):
        out: dict = {}
        for r, y, w in zip(rows, labels, weights):
            b = out.setdefault(keyf(r), {"rows": 0, "effective_weight": 0.0})
            b["rows"] += 1
            b["effective_weight"] += w
        return {k: {"rows": v["rows"], "effective_weight": round(v["effective_weight"], 2)} for k, v in sorted(out.items())}
    accounting = {
        "classes": {objective.class_order[c]: {"rows": labels.count(c), "families": families_per_class[c]} for c in range(n_classes)},
        "by_source": bucket(lambda r: r.get("authored_file", "templates")),
        "by_language": bucket(lambda r: r["language"]),
        "by_stratum": bucket(lambda r: r["stratum"]),
    }
    return weights, accounting


class Objective:
    """What one run optimises and how its outputs decide; the converter and
    the runner read the same fields back from `decision_config`."""

    def __init__(self, name: str):
        if name not in OBJECTIVES:
            raise ValueError(f"unknown objective {name!r}")
        self.name = name
        if name == "detection":
            self.class_order = DETECTION_CLASS_ORDER
            self.decision_rule = DETECTION_RULE
            self.threshold_key = "detection_threshold"
        else:
            self.class_order = CLASS_ORDER
            self.decision_rule = DECISION_RULE
            self.threshold_key = "safe_threshold"

    def label(self, row: dict) -> int:
        if self.name == "detection":
            return 1 if row["correction"] else 0
        return CLASS_ORDER.index(data.three_class(row["correction"], row["safe_alias"]))

    def decide(self, probs: list[float], threshold: float) -> tuple[bool, bool]:
        return decide_detection(probs, threshold) if self.name == "detection" else decide(probs, threshold)

    def score(self, rows: list[dict], probs: list[list[float]], threshold: float) -> dict:
        return score_detection(rows, probs, threshold) if self.name == "detection" else score_decisions(rows, probs, threshold)

    def select(self, rows: list[dict], probs: list[list[float]]) -> dict:
        return select_detection_threshold(rows, probs) if self.name == "detection" else select_safe_threshold(rows, probs)

    def select_dual(self, rows: list[dict], probs: list[list[float]], cross_rows: list[dict], cross_probs: list[list[float]]) -> dict:
        if self.name != "detection":
            raise ValueError("a cross-author development partition is only defined for the detection objective")
        return select_detection_threshold_dual(rows, probs, cross_rows, cross_probs)

    def selected_threshold(self, selection: dict) -> float | None:
        if self.name == "detection":
            return None if selection["selected"] is None else selection["selected"]["detection_threshold"]
        return selection["selected"]["safe_threshold"] if selection["qualifying"] else None


def objective_from_config(cfg: dict) -> Objective:
    """The objective a manifest's decision_config was written under; older
    manifests (chunk 2c/3) carry no `objective` and are three-class."""
    return Objective(cfg.get("objective", "three-class"))


# --- Pure helpers (tested) ---


def wilson_lower_bound(successes: int, trials: int, z: float = WILSON_Z_ONE_SIDED_95) -> float | None:
    """One-sided 95% Wilson lower bound of a proportion; None when trials == 0."""
    if trials <= 0:
        return None
    p = successes / trials
    denom = 1 + z * z / trials
    centre = p + z * z / (2 * trials)
    margin = z * math.sqrt(p * (1 - p) / trials + z * z / (4 * trials * trials))
    return (centre - margin) / denom


def decide(probs: list[float], safe_threshold: float) -> tuple[bool, bool]:
    """The predeclared decision rule on one probability triple."""
    if len(probs) != 3 or not all(math.isfinite(x) for x in probs):
        raise ValueError("expected three finite probabilities")
    vc = probs[1] + probs[2] > probs[0]
    sa = vc and probs[2] >= safe_threshold
    return vc, sa


def score_decisions(rows: list[dict], probs: list[list[float]], safe_threshold: float) -> dict:
    """Recall / false-add / alias precision with denominators and the Wilson
    lower bound for alias precision, on labelled rows."""
    if len(rows) != len(probs):
        raise ValueError("rows and probabilities differ in length")
    positives = true_positives = negatives = false_positives = 0
    predicted_safe = correct_safe = 0
    per_language: dict[str, dict] = {}
    for row, p in zip(rows, probs):
        vc, sa = decide(p, safe_threshold)
        lang = per_language.setdefault(row["language"], {"rows": 0, "positives": 0, "true_positives": 0, "negatives": 0, "false_positives": 0, "predicted_safe": 0, "correct_safe": 0})
        lang["rows"] += 1
        if row["correction"]:
            positives += 1
            lang["positives"] += 1
            if vc:
                true_positives += 1
                lang["true_positives"] += 1
        else:
            negatives += 1
            lang["negatives"] += 1
            if vc:
                false_positives += 1
                lang["false_positives"] += 1
        if vc and sa:
            predicted_safe += 1
            lang["predicted_safe"] += 1
            if row["safe_alias"]:
                correct_safe += 1
                lang["correct_safe"] += 1
    alias_precision = None if predicted_safe == 0 else correct_safe / predicted_safe
    return {
        "safe_threshold": safe_threshold,
        "correction_recall": {"value": None if positives == 0 else true_positives / positives, "num": true_positives, "den": positives},
        "false_add_rate": {"value": None if negatives == 0 else false_positives / negatives, "num": false_positives, "den": negatives},
        "alias_precision": {"value": alias_precision, "num": correct_safe, "den": predicted_safe, "wilson_lb_95": wilson_lower_bound(correct_safe, predicted_safe)},
        "alias_recall": {"value": None if sum(1 for r in rows if r["safe_alias"]) == 0 else correct_safe / sum(1 for r in rows if r["safe_alias"]), "num": correct_safe, "den": sum(1 for r in rows if r["safe_alias"])},
        "per_language": per_language,
    }


def select_safe_threshold(rows: list[dict], probs: list[list[float]], grid: list[float] = SAFE_THRESHOLD_GRID, lb_min: float = ALIAS_PRECISION_LB_MIN) -> dict:
    """Smallest grid value whose Wilson lower bound of alias precision meets
    `lb_min`, ties broken by alias recall; `qualifying: False` when none does."""
    best = None
    sweep = []
    for t in grid:
        s = score_decisions(rows, probs, t)
        lb = s["alias_precision"]["wilson_lb_95"]
        recall = s["alias_recall"]["value"]
        sweep.append({"safe_threshold": t, "alias_precision": s["alias_precision"], "alias_recall": s["alias_recall"]})
        if lb is not None and lb >= lb_min:
            if best is None or (recall is not None and recall > best["alias_recall"]):
                best = {"safe_threshold": t, "alias_recall": recall if recall is not None else -1.0, "wilson_lb_95": lb}
    return {"qualifying": best is not None, "selected": best, "lb_min": lb_min, "grid": [grid[0], grid[-1], len(grid)], "sweep": sweep}


def config_digest(payload: dict) -> str:
    return hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).hexdigest()


def tree_digest(folder: Path) -> str:
    h = hashlib.sha256()
    for f in sorted(p for p in folder.rglob("*") if p.is_file()):
        h.update(f.relative_to(folder).as_posix().encode("utf-8"))
        h.update(f.read_bytes())
    return h.hexdigest()


# --- Data ---


def load_partition(dev_dir: Path, name: str, manifest: dict) -> list[dict]:
    """The rows of one partition, verified against the split manifest: file
    digest, row count, content-hash set AND family set (a manifest that lies
    about its families cannot pass), plus the row-level review and language
    requirements."""
    if manifest.get("hash_version") != data.HASH_VERSION:
        raise RuntimeError("split manifest uses an unsupported hash version")
    part = manifest["partitions"][name]
    path = dev_dir / part["path"]
    if data.sha256_file(path) != part["file_sha256"]:
        raise RuntimeError(f"{name}: file digest differs from split-manifest.json")
    rows = data.read_jsonl(path)
    problems = gate.validate_rows(rows, name)
    if problems:
        raise RuntimeError(f"{name}: " + "; ".join(problems[:3]))
    for r in rows:
        if r.get("review_status") not in data.REVIEWED_STATUSES or r.get("language") in (None, "", "und"):
            raise RuntimeError(f"{name}: row {r.get('id')} is not reviewed labelled data with a language")
    if part.get("rows") != len(rows):
        raise RuntimeError(f"{name}: row count differs from consumed rows")
    if sorted(data.content_hash(r) for r in rows) != sorted(part["hashes"]):
        raise RuntimeError(f"{name}: content hashes differ from split-manifest.json")
    if sorted({data.family_key(r) for r in rows}) != sorted(part["families"]):
        raise RuntimeError(f"{name}: families differ from consumed rows")
    return rows


def load_cross_dev(path: Path) -> list[dict]:
    """A cross-author development partition: validated labelled rows with a
    review status, a language and BOTH detection classes present. Hash and
    family disjointness from the other partitions and every frozen exam is
    checked by `refuse_frozen_overlap_all`, never assumed."""
    rows = data.read_jsonl(path)
    problems = gate.validate_rows(rows, "cross_dev")
    if problems:
        raise RuntimeError("cross_dev: " + "; ".join(problems[:3]))
    for r in rows:
        if r.get("review_status") not in data.REVIEWED_STATUSES or r.get("language") in (None, "", "und"):
            raise RuntimeError(f"cross_dev: row {r.get('id')} is not reviewed labelled data with a language")
    if not any(r["correction"] for r in rows) or not any(not r["correction"] for r in rows):
        raise RuntimeError("cross_dev: both classes must be present")
    return rows


def refuse_frozen_overlap_all(partitions: dict[str, list[dict]]) -> None:
    """`refuse_frozen_overlap` against EVERY frozen exam on disk (legacy and
    exam v2): a training row may not share a hash or family with any exam."""
    for manifest in gate.frozen_manifests_present():
        refuse_frozen_overlap(partitions, manifest)


def refuse_frozen_overlap(partitions: dict[str, list[dict]], frozen: dict) -> None:
    """Leakage and cross-partition checks derived from the CONSUMED rows,
    never from a manifest's declarations."""
    derived = {n: data.partition_manifest(rows) for n, rows in partitions.items()}
    tm = data.TrainingManifest(
        judge="trainer-check", kind="trained", checkpoint="-", tokenizer="-", thresholds={},
        partitions=derived, provenance="trainer input check", hash_version=data.HASH_VERSION,
        execution_identity={"checkpoint_sha256": "0" * 64, "tokenizer_sha256": "0" * 64, "config_sha256": "0" * 64})
    problems = data.leakage_problems(tm, frozen)
    crossing = []
    seen_h: set[str] = set()
    seen_f: set[str] = set()
    for n, p in derived.items():
        if seen_h & set(p["hashes"]):
            crossing.append(f"{n} shares rows with another partition")
        if seen_f & set(p["families"]):
            crossing.append(f"{n} shares families with another partition")
        seen_h |= set(p["hashes"])
        seen_f |= set(p["families"])
    if problems or crossing:
        raise RuntimeError("; ".join(problems + crossing))


# Candidates with a retained clearing receipt (upstream parity, conversion,
# four placements). XLM-R: chunk 2b run 20260918T222412Z-047f6d13. mmBERT-small:
# chunk 4a-ii, after the NumPy pin (edit-judge-requirements.txt). The receipt
# passed on the command line must still clear the candidate on its own.
TRAINABLE_CANDIDATES = frozenset({"xenc-xlmr-base", "xenc-mmbert-small"})


def load_compat_receipt(path: Path, candidate: str) -> dict:
    """The retained compatibility receipt that clears `candidate` for
    training: the upstream tokenizer at exact parity, a successful
    conversion and all four placements ok. Returns its entry (revision,
    tokenizer digests, toolchain) or raises."""
    doc = json.loads(path.read_text(encoding="utf-8"))
    entry = next((c for c in doc.get("candidates", []) if c.get("name") == candidate), None)
    if entry is None:
        raise RuntimeError(f"{path}: no entry for {candidate}")
    up = entry.get("upstream", {})
    if not (up.get("loaded") and up.get("compared", 0) > 0 and up.get("matched") == up.get("compared")):
        raise RuntimeError(f"{candidate}: upstream tokenizer parity is not proven in {path}")
    if not entry.get("conversion", {}).get("ok"):
        raise RuntimeError(f"{candidate}: conversion did not succeed in {path}")
    placement = entry.get("placement", {})
    if set(placement) != {"cpuOnly", "cpuAndGPU", "cpuAndNeuralEngine", "all"} or not all(v.get("ok") for v in placement.values()):
        raise RuntimeError(f"{candidate}: not all four placements ok in {path}")
    receipt_problems = probe.toolchain_problems(doc.get("toolchain", {}))
    if receipt_problems:
        # A receipt that never recorded a pinned key (the chunk 2b reports
        # predate the NumPy pin) fails here; rerun the probe, never patch it.
        raise RuntimeError(f"{path}: toolchain differs from the pinned one: " + "; ".join(receipt_problems))
    if not entry.get("revision"):
        raise RuntimeError(f"{candidate}: receipt carries no revision")
    return {"revision": entry["revision"], "tokenizer_files_sha256": entry.get("tokenizer_files_sha256", {}), "toolchain": doc["toolchain"], "receipt": str(path), "receipt_sha256": data.sha256_file(path)}


def encode_rows(rows: list[dict], contract: dict, encode) -> list[dict]:
    """Pair-encode every row with the Python mirror of the shipped adapter:
    input = `Edit: original → replacement`, output = `Sentence: pasted`."""
    out = []
    for r in rows:
        enc = probe.mirror_pair_encoding(contract, encode, f"{r['original']} → {r['replacement']}", r["pasted"])
        out.append(enc)
    return out


def verify_shape_parity(rows: list[dict], runner: Path, workdir: Path) -> dict:
    """The Python mirror of the stage-1 shape rule against the shipped Swift
    rule on EVERY row the trainer will score, through the runner's `shape`
    door. Mismatches are refused: dev numbers must describe the same rule the
    eval runner applies. Flags are cached beside the run for the receipt."""
    req = workdir / "shape-request.json"
    out = workdir / "shape-response.json"
    req.write_text(json.dumps({"pairs": [{"original": r["original"], "replacement": r["replacement"]} for r in rows]}, ensure_ascii=False), encoding="utf-8")
    proc = subprocess.run([str(runner), "shape", "--request", str(req), "--out", str(out)], capture_output=True, text=True)
    if proc.returncode != 0:
        return {"ok": False, "error": f"runner exit {proc.returncode}: {proc.stderr[:200]}"}
    resp = json.loads(out.read_text(encoding="utf-8"))
    swift = resp.get("drops")
    if not isinstance(swift, list) or len(swift) != len(rows):
        return {"ok": False, "error": "runner returned a different pair count"}
    mine = [data.stage_one_shape_drop(r["original"], r["replacement"]) for r in rows]
    mismatches = [{"id": r["id"], "swift": s_, "python": m} for r, s_, m in zip(rows, swift, mine) if s_ != m]
    return {"ok": not mismatches, "policy": resp.get("policy"), "compared": len(rows), "dropped": sum(1 for x in swift if x), "mismatches": mismatches[:20], "mismatch_count": len(mismatches)}


def verify_upstream_parity(tokenizer_dir: Path, texts: list[str], runner: Path, workdir: Path, contract_path: Optional[Path] = None, pairs: Optional[list[tuple[str, str]]] = None) -> dict:
    """The exact segments the trainer tokenizes, through the runner's
    upstream stack; every id list must match the reference tokenizer. With a
    contract and pairs, the runner's contract-assembled pairs (specials,
    truncation, padding) must match the Python mirror the trainer feeds the
    model: what trains is what the Swift arm will assemble."""
    from transformers import AutoTokenizer

    tok = AutoTokenizer.from_pretrained(tokenizer_dir)
    req = workdir / "parity-request.json"
    out = workdir / "parity-response.json"
    request = {"tokenizer_folder": str(tokenizer_dir), "texts": texts}
    if contract_path is not None and pairs is not None:
        request["contract"] = str(contract_path)
        request["pairs"] = [{"input": a, "output": b} for a, b in pairs]
    req.write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")
    proc = subprocess.run([str(runner), "tokenize", "--request", str(req), "--out", str(out), "--stack", "upstream"], capture_output=True, text=True)
    if proc.returncode != 0:
        return {"ok": False, "error": f"runner exit {proc.returncode}: {proc.stderr[:200]}"}
    resp = json.loads(out.read_text(encoding="utf-8"))
    if not resp.get("loaded"):
        return {"ok": False, "error": resp.get("error")}
    got = {e["text"]: e["ids"] for e in resp["texts"]}
    if set(got) != set(texts):
        return {"ok": False, "error": "runner returned a different text set"}
    mismatches = [t for t in texts if got[t] != tok(t, add_special_tokens=False)["input_ids"]]
    result = {"ok": not mismatches, "compared": len(texts), "matched": len(texts) - len(mismatches), "stack": resp.get("stack")}
    if contract_path is not None and pairs is not None:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        encode = lambda text: tok(text, add_special_tokens=False)["input_ids"]  # noqa: E731
        if resp.get("contract_error"):
            result["pairs"] = {"compared": 0, "matched": 0, "contract_error": resp["contract_error"]}
            result["ok"] = False
        else:
            pp = probe.pair_parity(contract, encode, pairs, resp.get("pairs") or [])
            result["pairs"] = pp
            result["ok"] = result["ok"] and pp["matched"] == pp["compared"] and pp["compared"] > 0 and pp.get("padded", 0) > 0
    return result


# --- Training ---


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--artifacts", type=Path, required=True)
    p.add_argument("--candidate", choices=list(probe.CANDIDATES), default="xenc-xlmr-base")
    p.add_argument("--dev-dir", type=Path, help="default <artifacts>/dev")
    p.add_argument("--seed", type=int, default=996)
    p.add_argument("--epochs", type=int, default=3)
    p.add_argument("--lr", type=float, default=2e-5)
    p.add_argument("--batch-size", type=int, default=16)
    p.add_argument("--smoke", action="store_true", help="a few steps on a few rows; a pipeline check, never a result")
    p.add_argument("--compat-receipt", type=Path, required=True, help="retained compatibility report.json that clears the candidate (revision is taken from it)")
    p.add_argument("--objective", choices=list(OBJECTIVES), default="three-class", help="detection: two-way head on `correction` with the predeclared false-proposal/recall selection (pivot); three-class: the chunk 2c alias objective")
    p.add_argument("--cross-dev", type=Path, help="detection: a separately authored, independently labelled cross-author development partition (jsonl); threshold selection must then qualify on BOTH dev and this partition (Codex 4a-ii round 3 rule)")
    p.add_argument("--loss-normalisation", choices=["global", "batch"], default="global", help="detection: `global` = mean(loss*w) with global family weights (the declared objective); `batch` = sum(loss*w)/sum(w) per minibatch (the pre-2026-09-19 behaviour, kept for a controlled comparison and recorded in the experiment)")
    args = p.parse_args()
    objective = Objective(args.objective)
    if args.candidate not in TRAINABLE_CANDIDATES:
        print(f"INFRA-ERROR: {args.candidate} is not cleared for training; cleared: {sorted(TRAINABLE_CANDIDATES)} (mDeBERTa fails tokenizer load and conversion on this stack, chunk 2b)", file=sys.stderr)
        return 2

    import numpy as np
    import torch
    import transformers
    from transformers import AutoModel, AutoTokenizer

    toolchain = probe.toolchain_report()
    toolchain_problems = probe.toolchain_problems(toolchain)
    if toolchain_problems:
        print("INFRA-ERROR: toolchain is not the pinned one: " + "; ".join(toolchain_problems), file=sys.stderr)
        return 2
    if not probe.RUNNER_BIN.exists():
        print(f"INFRA-ERROR: runner missing at {probe.RUNNER_BIN}", file=sys.stderr)
        return 2

    dev_dir = args.dev_dir or (args.artifacts / "dev")
    split_manifest = json.loads((dev_dir / "split-manifest.json").read_text(encoding="utf-8"))
    frozen, _, problems = gate.load_frozen()
    if problems:
        print("INFRA-ERROR: frozen partitions are not intact: " + "; ".join(problems), file=sys.stderr)
        return 2
    try:
        compat = load_compat_receipt(args.compat_receipt, args.candidate)
        train_rows = load_partition(dev_dir, "train", split_manifest)
        dev_rows = load_partition(dev_dir, "dev", split_manifest)
        cal_rows = load_partition(dev_dir, "calibration", split_manifest)
        cross_rows = load_cross_dev(args.cross_dev) if args.cross_dev else []
        refuse_frozen_overlap_all({"train": train_rows, "dev": dev_rows, "calibration": cal_rows, **({"cross_dev": cross_rows} if cross_rows else {})})
    except RuntimeError as exc:
        print(f"INFRA-ERROR: {exc}", file=sys.stderr)
        return 2
    if args.cross_dev and args.objective != "detection":
        print("INFRA-ERROR: --cross-dev is only defined for --objective detection", file=sys.stderr)
        return 2
    if args.smoke:
        random.Random(args.seed).shuffle(train_rows)
        train_rows, dev_rows, cal_rows = train_rows[:48], dev_rows[:24], cal_rows[:24]

    spec = probe.CANDIDATES[args.candidate]
    revision = compat["revision"]
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid4().hex[:8] + ("-smoke" if args.smoke else "")
    run_dir = args.artifacts / "runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=False)
    ckpt_dir = run_dir / "checkpoint"
    ckpt_dir.mkdir()
    tok_dir = ckpt_dir / "tokenizer"
    tok_dir.mkdir()
    model_dir = ckpt_dir / "model"
    model_dir.mkdir()

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    tok = AutoTokenizer.from_pretrained(spec["hf"], revision=revision)
    tok.save_pretrained(tok_dir)
    tokenizer_digest = tree_digest(tok_dir)
    tokenizer_inventory = {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(tok_dir.iterdir()) if f.is_file()}
    specials = {"pad": tok.pad_token_id, "cls": tok.cls_token_id, "sep": tok.sep_token_id, "bos": tok.bos_token_id if tok.bos_token_id is not None else tok.cls_token_id, "eos": tok.eos_token_id if tok.eos_token_id is not None else tok.sep_token_id}
    if any(v is None for v in specials.values()):
        print(f"INFRA-ERROR: tokenizer specials incomplete: {specials}", file=sys.stderr)
        return 2
    if tok.unk_token_id is not None and any(v == tok.unk_token_id for k, v in specials.items() if k != "pad"):
        # mmBERT resolves the literal strings [CLS]/[SEP] to <unk>; a contract
        # built from those would train on unknown tokens in the special slots.
        print(f"INFRA-ERROR: a special token resolves to <unk> ({tok.unk_token_id}): {specials}", file=sys.stderr)
        return 2
    contract = probe.build_contract(args.candidate, spec, specials)
    (run_dir / "tokenizer-contract.json").write_text(json.dumps(contract, indent=2), encoding="utf-8")
    encode = lambda text: tok(text, add_special_tokens=False)["input_ids"]  # noqa: E731

    # Exact tokenization of the training prefixes and segments through the
    # runner's upstream stack, before anything is fitted.
    sample = random.Random(args.seed).sample(train_rows, min(40, len(train_rows)))
    parity_texts = list(dict.fromkeys(
        [contract["inputPrefix"] + f"{r['original']} → {r['replacement']}" for r in sample]
        + [contract["outputPrefix"] + r["pasted"] for r in sample]
        + [contract["inputPrefix"], contract["outputPrefix"]]))
    # Pairs as the trainer feeds them (input = "original → replacement",
    # output = pasted), plus the probe's long fixtures so truncation is
    # exercised and an empty side so the specials still assemble.
    parity_pairs = [(f"{r['original']} → {r['replacement']}", r["pasted"]) for r in sample[:12]] + list(probe.PAIR_FIXTURES) + [("", sample[0]["pasted"]), (f"{sample[0]['original']} → {sample[0]['replacement']}", "")]
    parity = verify_upstream_parity(tok_dir, parity_texts, probe.RUNNER_BIN, run_dir, run_dir / "tokenizer-contract.json", parity_pairs)
    if not parity.get("ok"):
        print(f"INFRA-ERROR: upstream tokenizer parity failed on training segments: {parity}", file=sys.stderr)
        return 2
    shape_parity = {"skipped": "three-class objective"}
    if objective.name == "detection":
        shape_parity = verify_shape_parity(train_rows + dev_rows + cal_rows + cross_rows, probe.RUNNER_BIN, run_dir)
        if not shape_parity.get("ok"):
            print(f"INFRA-ERROR: stage-1 shape rule mirror disagrees with the Swift rule: {shape_parity}", file=sys.stderr)
            return 2

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    needs_types = spec["token_types"] == "bert_segments"
    counts = [sum(1 for r in train_rows if objective.label(r) == i) for i in range(len(objective.class_order))]
    total = sum(counts)
    class_weights = [total / (len(objective.class_order) * max(1, c)) for c in counts]
    experiment = {
        "run_id": run_id,
        "smoke": args.smoke,
        "candidate": args.candidate,
        "hf": spec["hf"],
        "revision": revision,
        "compat_receipt": compat,
        "tokenizer_sha256": tokenizer_digest,
        "tokenizer_inventory": tokenizer_inventory,
        "toolchain": {**toolchain, "device": device},
        "runner_sha256": hashlib.sha256(probe.RUNNER_BIN.read_bytes()).hexdigest(),
        "upstream_parity": parity,
        "shape_parity": shape_parity,
        "seed": args.seed,
        "objective": objective.name,
        "class_order": list(objective.class_order),
        "class_counts_train": dict(zip(objective.class_order, counts)),
        "decision_rule": objective.decision_rule,
        "safe_threshold_grid": [SAFE_THRESHOLD_GRID[0], SAFE_THRESHOLD_GRID[-1], len(SAFE_THRESHOLD_GRID)] if objective.name == "three-class" else None,
        "alias_precision_lb_min": ALIAS_PRECISION_LB_MIN if objective.name == "three-class" else None,
        "detection_threshold_grid": [DETECTION_THRESHOLD_GRID[0], DETECTION_THRESHOLD_GRID[-1], len(DETECTION_THRESHOLD_GRID)] if objective.name == "detection" else None,
        "detection_selection": {"false_proposal_ub_max": FALSE_PROPOSAL_UB_MAX, "recall_min": DETECTION_RECALL_MIN, "populations": ["dev", "cross_dev"] if cross_rows else ["dev"], "rule": selection_rule_text(objective, bool(cross_rows))} if objective.name == "detection" else None,
        "cross_dev": {"path": str(args.cross_dev), "rows": len(cross_rows), "file_sha256": data.sha256_file(args.cross_dev), "positives": sum(1 for r in cross_rows if r["correction"]), "negatives": sum(1 for r in cross_rows if not r["correction"]), "families": len({data.family_key(r) for r in cross_rows}), "label_sources": sorted({str(r.get("label_source", ""))[:80] for r in cross_rows})} if cross_rows else None,
        "dev_dir": str(dev_dir),
        "encoding": {"contract": "tokenizer-contract.json", "input": "Edit: {original} → {replacement}", "output": "Sentence: {pasted}", "max_length": contract["maxLength"], "pooling": "CLS"},
        "optimizer": {"name": "AdamW", "lr": args.lr, "weight_decay": 0.01, "batch_size": args.batch_size, "epochs": args.epochs, "class_weights": class_weights, "loss": "cross-entropy"},
        "stopping_rule": ("keep the epoch with the best dev macro-F1 at threshold 0.50 with the stage-1 shape rule applied (same subject as threshold selection); no early stop below epochs" if objective.name == "detection" else "keep the epoch with the best dev macro-F1 over the three classes; no early stop below epochs"),
        "shape_rule": "EditRunShape-v1 (edit_judge_data.stage_one_shape_drop mirror; parity pinned against the Swift runner before training)" if objective.name == "detection" else None,
        "calibration_objective": selection_rule_text(objective, bool(cross_rows)),
        "partitions": {n: {"rows": len(rs), "file_sha256": split_manifest["partitions"][n]["file_sha256"]} for n, rs in (("train", train_rows), ("dev", dev_rows), ("calibration", cal_rows))},
        "split_manifest_sha256": data.sha256_file(dev_dir / "split-manifest.json"),
        "locked_at": datetime.now(timezone.utc).isoformat(),
    }
    (run_dir / "experiment.json").write_text(json.dumps(experiment, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    kwargs = {"attn_implementation": "eager"} if spec["hf"].startswith("jhu-clsp/mmBERT") else {}
    backbone = AutoModel.from_pretrained(spec["hf"], revision=revision, **kwargs)
    hidden = backbone.config.hidden_size

    class Judge(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.backbone = backbone
            self.head = torch.nn.Linear(hidden, len(objective.class_order))

        def forward(self, input_ids, attention_mask, token_type_ids=None):
            if needs_types and token_type_ids is not None:
                out = self.backbone(input_ids=input_ids, attention_mask=attention_mask, token_type_ids=token_type_ids)
            else:
                out = self.backbone(input_ids=input_ids, attention_mask=attention_mask)
            return self.head(out.last_hidden_state[:, 0, :])

    model = Judge().to(device)

    def tensors(rows):
        enc = encode_rows(rows, contract, encode)
        ids = torch.tensor([e["input_ids"] for e in enc], dtype=torch.long)
        mask = torch.tensor([e["attention_mask"] for e in enc], dtype=torch.long)
        types = torch.tensor([e["token_type_ids"] for e in enc], dtype=torch.long)
        labels = torch.tensor([objective.label(r) for r in rows], dtype=torch.long)
        return ids, mask, types, labels

    train_t = tensors(train_rows)
    dev_t = tensors(dev_rows)
    cal_t = tensors(cal_rows)

    def predict(t) -> list[list[float]]:
        model.eval()
        probs = []
        with torch.no_grad():
            for i in range(0, len(t[0]), 64):
                ids, mask, types = (x[i : i + 64].to(device) for x in t[:3])
                logits = model(ids, mask, types if needs_types else None).float()
                if not torch.isfinite(logits).all():
                    raise RuntimeError("non-finite logits during evaluation")
                probs.extend(torch.softmax(logits, dim=-1).cpu().tolist())
        return probs

    def macro_f1(rows, probs) -> float:
        f1s = []
        n_classes = len(objective.class_order)
        for c in range(n_classes):
            tp = fp = fn = 0
            for r, pr in zip(rows, probs):
                truth = objective.label(r)
                pred = max(range(n_classes), key=lambda k: pr[k])
                if pred == c and truth == c:
                    tp += 1
                elif pred == c:
                    fp += 1
                elif truth == c:
                    fn += 1
            f1s.append(0.0 if tp == 0 else 2 * tp / (2 * tp + fp + fn))
        return sum(f1s) / len(f1s)

    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)
    if objective.name == "detection":
        row_weights, weight_accounting = family_row_weights(train_rows, objective)
        row_weight_t = torch.tensor(row_weights, dtype=torch.float32)
        experiment["training_weights"] = {"rule": "equal weight per alias family within a class, classes equalised, loss only", "loss_normalisation": args.loss_normalisation, **weight_accounting}
        (run_dir / "experiment.json").write_text(json.dumps(experiment, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        per_row_loss = torch.nn.CrossEntropyLoss(reduction="none")

        def loss_fn(logits, labels, batch_index):
            # Global weights (mean 1.0 over the training set), NOT renormalised
            # per minibatch: renormalising would cancel the family weighting
            # under uniform row sampling (Codex 4a-ii round 2). `batch` keeps
            # the earlier behaviour for a controlled comparison only.
            w = row_weight_t[batch_index].to(logits.device)
            weighted = per_row_loss(logits, labels) * w
            return weighted.mean() if args.loss_normalisation == "global" else weighted.sum() / w.sum()
    else:
        class_loss = torch.nn.CrossEntropyLoss(weight=torch.tensor(class_weights, dtype=torch.float32).to(device))

        def loss_fn(logits, labels, batch_index):
            return class_loss(logits, labels)
    steps_total = 0
    epochs_log = []
    best = {"macro_f1": -1.0, "epoch": None}
    best_state = None
    max_steps = 3 if args.smoke else None
    t_start = time.time()
    for epoch in range(1, args.epochs + 1):
        model.train()
        order = list(range(len(train_t[0])))
        random.Random(args.seed + epoch).shuffle(order)
        losses = []
        for i in range(0, len(order), args.batch_size):
            batch = order[i : i + args.batch_size]
            ids, mask, types, labels = (x[batch].to(device) for x in train_t)
            logits = model(ids, mask, types if needs_types else None)
            loss = loss_fn(logits.float(), labels, torch.tensor(batch))
            if not torch.isfinite(loss):
                print("INFRA-ERROR: non-finite loss", file=sys.stderr)
                return 2
            optimizer.zero_grad()
            loss.backward()
            grad_norm = torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            if not torch.isfinite(grad_norm):
                print("INFRA-ERROR: non-finite gradient norm", file=sys.stderr)
                return 2
            optimizer.step()
            losses.append(loss.item())
            steps_total += 1
            if max_steps and steps_total >= max_steps:
                break
        dev_probs = predict(dev_t)
        # Detection: the epoch is chosen on the same subject the threshold is
        # chosen on (shape rule applied, fixed 0.50); three-class keeps argmax.
        f1 = _macro_f1_binary(dev_rows, dev_probs, 0.50) if objective.name == "detection" else macro_f1(dev_rows, dev_probs)
        epochs_log.append({"epoch": epoch, "steps": steps_total, "train_loss_mean": sum(losses) / max(1, len(losses)), "dev_macro_f1": f1, "elapsed_s": round(time.time() - t_start, 1)})
        print(json.dumps(epochs_log[-1]))
        if f1 > best["macro_f1"]:
            best = {"macro_f1": f1, "epoch": epoch}
            best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
        if max_steps and steps_total >= max_steps:
            break
    if best_state is None or steps_total == 0:
        print("INFRA-ERROR: no optimizer step ran", file=sys.stderr)
        return 2
    model.load_state_dict(best_state)

    # Calibration on dev, locked value checked on calibration.
    dev_probs = predict(dev_t)
    cross_probs = predict(tensors(cross_rows)) if cross_rows else None
    selection = objective.select_dual(dev_rows, dev_probs, cross_rows, cross_probs) if cross_rows else objective.select(dev_rows, dev_probs)
    single_population_reference = objective.select(dev_rows, dev_probs) if cross_rows else None
    cal_probs = predict(cal_t)
    locked = objective.selected_threshold(selection)
    results = {
        "objective": objective.name,
        "best_epoch": best,
        "epochs": epochs_log,
        "steps_total": steps_total,
        "dev_selection": {k: v for k, v in selection.items() if k != "sweep"},
        "dev_sweep": selection["sweep"],
        "dev_at_locked": objective.score(dev_rows, dev_probs, locked) if locked is not None else None,
        "calibration_at_locked": objective.score(cal_rows, cal_probs, locked) if locked is not None else None,
        "calibration_argmax_reference": objective.score(cal_rows, cal_probs, 0.5),
        "cross_dev_at_locked": objective.score(cross_rows, cross_probs, locked) if cross_rows and locked is not None else None,
        "dev_only_selection_reference": {k: v for k, v in single_population_reference.items() if k != "sweep"} if single_population_reference else None,
        "not_acceptance_evidence": "development, cross-author development and calibration partitions only; the frozen report rows were never scored",
    }

    # Save the checkpoint and bind the artifact.
    model.backbone.save_pretrained(model_dir, safe_serialization=True)
    from safetensors.torch import save_file

    save_file({k: v.detach().cpu().contiguous() for k, v in model.head.state_dict().items()}, str(model_dir / "head.safetensors"))
    checkpoint_digest = tree_digest(model_dir)
    decision_config = {
        "objective": objective.name,
        "class_order": list(objective.class_order),
        "decision_rule": objective.decision_rule,
        objective.threshold_key: locked,
        "encoding": experiment["encoding"],
        "contract_sha256": data.sha256_file(run_dir / "tokenizer-contract.json"),
        "precision_variant": "fp32-pytorch",
        "package_sha256": None,
    }
    execution_identity = {"checkpoint_sha256": checkpoint_digest, "tokenizer_sha256": tokenizer_digest, "config_sha256": config_digest(decision_config)}
    training_manifest = {
        "judge": args.candidate,
        "kind": "trained",
        "checkpoint": str(model_dir),
        "tokenizer": str(tok_dir),
        "tokenizer_inventory": tokenizer_inventory,
        "thresholds": {objective.threshold_key: locked, "qualifying": selection["qualifying"], **({"branch": selection["branch"], "selection_populations": selection.get("populations", ["dev"]), "selection_rule": selection_rule_text(objective, bool(cross_rows))} if objective.name == "detection" else {})},
        "provenance": f"train_edit_judge.py run {run_id}; templates {split_manifest['templates_version']} sha {split_manifest['templates_sha256'][:12]}; revision {revision}",
        "hash_version": data.HASH_VERSION,
        "execution_identity": execution_identity,
        "decision_config": decision_config,
        # Every population that touched selection is declared, so a later
        # frozen exam is checked against the cross-author rows too (Codex 4a-ii
        # round 4 F1). The cross partition is derived from the consumed rows
        # and bound to its file digest in `experiment.cross_dev`.
        "partitions": {**{n: {"hashes": split_manifest["partitions"][n]["hashes"], "families": split_manifest["partitions"][n]["families"]} for n in ("train", "dev", "calibration")},
                       **({"cross_dev": {k: data.partition_manifest(cross_rows)[k] for k in ("hashes", "families")}} if cross_rows else {})},
    }
    (run_dir / "training-manifest.json").write_text(json.dumps(training_manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    loaded = data.load_training_manifest(run_dir / "training-manifest.json")
    results["training_manifest_problems"] = loaded.problems + data.leakage_problems(loaded, frozen)
    results["execution_identity"] = execution_identity
    (run_dir / "metrics.json").write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    summary = {
        "run": str(run_dir),
        "steps": steps_total,
        "best_epoch": best,
        "qualifying_threshold": locked,
        "objective": objective.name,
        "dev_at_locked": {k: results["dev_at_locked"][k] for k in ("correction_recall", "false_add_rate")} if locked is not None else None,
        "calibration_at_locked": {k: results["calibration_at_locked"][k] for k in ("correction_recall", "false_add_rate")} if locked is not None else None,
        "manifest_problems": results["training_manifest_problems"],
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0 if not results["training_manifest_problems"] else 1


if __name__ == "__main__":
    sys.exit(main())
