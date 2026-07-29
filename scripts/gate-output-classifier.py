#!/usr/bin/env python3
"""Numerical gate for a candidate output-safety classifier package.

Run this against the EXACT bytes that will be committed, every time
`Sources/EnviousWisprLLM/Resources/OutputClassifier.mlpackage` changes. Re-running
the converter after gating invalidates the gate: convert, then gate, then commit.

What it checks, and why each part exists (#1226, 2026-07-28):

  * FOUR compute units, not one. The defect this gate was built for is invisible
    on the then-default `.all` path: at FLOAT16 the model returned all-NaN under
    CPU-only and a single constant logit under CPU+GPU, so the classifier
    silently failed on hardware that placed it off the Neural Engine. A gate that
    only exercises `.all` reports green on a model that is broken in the field.

  * THREE corpora, not the one the old conversion script points at.
    `phase3-convert-trained.py`'s `DEV_FILE` is `pair-dev-v5` — the PRE-#949 dev
    set. `eval.json` names the real ones: the threshold was calibrated on
    `reformat-dev-v6`, and the shipped quality commitments (discard recall, keep
    FPR) live on the locked test set `pair-test-v5`. Gating the wrong corpus
    missed the knife-edge row `reformat-03718` entirely.

  * Flips against the CURRENTLY SHIPPED model, per compute unit, not aggregate
    score drift. A decision flip is the only thing a user can observe.

Known-accepted result for the FP32 conversion: exactly one flip on the
calibration dev split (`reformat-03718`, 5.46e-08 from the threshold — an
undecidable row the shipped model already disagrees with PyTorch about), and zero
flips on the locked test set and holdout. The defaults below encode that. Any
other result is a stop.

BASELINE FIDELITY — the whole axis, enumerated rather than patched one review
round at a time. The comparison is only meaningful if the reference reproduces
the decisions users ACTUALLY RECEIVED, and four separate inputs decide that:

  1. Which model bytes.   Guarded: identical candidate/reference paths are refused,
                          because a model compared with itself always shows zero flips.
  2. Which threshold.     `--reference-threshold`. A retrain that moves
                          `discardThreshold` otherwise judges the old model by the
                          new rule, and rows between the two values cancel out.
  3. Which compute policy. `--reference-compute-unit`, defaulting to the policy the
                          app ships. `.all` and `.cpuAndNeuralEngine` already
                          disagree on `reformat-03718`, so scoring the baseline
                          under a policy users do not run lets a candidate preserve
                          those decisions while changing what users get.
  4. Which tokenization.  NOT guarded, and it cannot be from inside this script:
                          both models are scored with the ONE tokenizer in
                          `--probe-dir`'s checkpoint. If a retrain changes the
                          tokenizer or the pair-encoding contract, this comparison
                          is INVALID — the reference is being fed inputs it never
                          saw in production. Regenerate the baseline decisions with
                          the old tokenizer instead of trusting a run of this gate.

Plus validity: a reference that returns NaN or collapses to one value is rejected
before any decision is derived, so the gate's own baseline cannot be the defect it
exists to catch.

Inputs are gitignored (`.gitignore:219-220`); this needs the local artifact tree
and its pinned interpreter.

Run:
    cd artifacts/issue-832-classifier-probe
    ./.venv-ml/bin/python ../../scripts/gate-output-classifier.py \
        --candidate ../../Sources/EnviousWisprLLM/Resources/OutputClassifier.mlpackage \
        --reference <shipped .mlpackage to compare decisions against>

From a worktree, pass `--probe-dir <main checkout>/artifacts/issue-832-classifier-probe`.
"""

import argparse
import hashlib
import importlib.util
import json
import re
import sys
from itertools import combinations
from pathlib import Path

PROBE_DIR_NAME = "artifacts/issue-832-classifier-probe"
CHECKPOINT_REL = "phase2-models/MiniLM-L6-reformat2-13/checkpoint-best"
HELPERS_REL = "phase2_train_helpers.py"
MANIFEST_REL = "Sources/EnviousWisprLLM/OutputClassifierManifest.swift"
MAX_LENGTH = 128
# Cap on ids printed per failure line. The complete set always goes to --report.
MAX_REPORTED_IDS = 10

# The compute-unit policy the app requests today (`CoreMLOutputClassifier.load`).
# The baseline must be scored with the policy that produced the decisions users
# ACTUALLY RECEIVED, not with Core ML's default — `.all` and `.cpuAndNeuralEngine`
# already disagree on `reformat-03718`, so a candidate could preserve every `.all`
# decision while changing what users get, and still pass.
SHIPPED_COMPUTE_UNIT = "cpu_and_ne"
COMPUTE_UNIT_NAMES = ("all", "cpu_only", "cpu_and_gpu", "cpu_and_ne")

# corpus key -> (filename, max tolerated flips, ids allowed to flip)
#
# The allowlist is load-bearing and not redundant with the count. A count-only
# check passes when a DIFFERENT row flips, and passes again when each compute
# unit flips a different row — so a real decision regression could clear a gate
# whose stated rule is "any other result stops the work". Only `reformat-03718`
# is undecidable (5.46e-08 from the threshold); every other flip is a regression.
CORPORA = {
    "calibration_dev": ("reformat-dev-v6.harmtagged.jsonl", 1, {"reformat-03718"}),
    "locked_test": ("pair-test-v5.harmtagged.jsonl", 0, set()),
    "reformat_holdout": ("reformat-holdout.jsonl", 0, set()),
}


def die(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def package_digest(package: Path) -> str:
    """Content identity of a `.mlpackage` directory: sha256 over sorted
    "<relpath> <filesha256>" lines. Same construction as
    `OutputClassifierManifest.mlpackageSHA256`, used here only to tell two
    packages apart by their BYTES rather than by where they happen to sit."""
    lines = []
    for path in package.rglob("*"):
        if not path.is_file():
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines.append(f"{path.relative_to(package).as_posix()} {digest}")
    lines.sort()
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()


def discard_threshold() -> float:
    """Read the threshold from the Swift manifest rather than copying it.

    A stale copy here would not fail loudly — it would quietly measure decisions
    against the wrong boundary and still print a confident verdict, which is the
    exact class of silent-wrong-answer this gate exists to catch. Parsing fails
    closed instead.
    """
    manifest = repo_root() / MANIFEST_REL
    if not manifest.exists():
        die(f"missing {manifest}; cannot read the discard threshold")
    match = re.search(
        r"discardThreshold\s*=\s*([0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)", manifest.read_text()
    )
    if not match:
        die(f"could not parse discardThreshold from {manifest}")
    return float(match.group(1))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument(
        "--reference",
        type=Path,
        required=True,
        help="the model whose decisions the candidate must match (normally the shipped one)",
    )
    parser.add_argument("--probe-dir", type=Path, default=repo_root() / PROBE_DIR_NAME)
    parser.add_argument("--report", type=Path, help="write the full result as JSON here")
    parser.add_argument(
        "--reference-compute-unit",
        choices=sorted(COMPUTE_UNIT_NAMES),
        default=SHIPPED_COMPUTE_UNIT,
        help=(
            "the compute-unit policy the REFERENCE model shipped with. Defaults to "
            f"'{SHIPPED_COMPUTE_UNIT}', the policy the app requests today "
            "(CoreMLOutputClassifier.load). Pass 'all' when the reference predates "
            "#1226, which is when the app stopped using the Core ML default."
        ),
    )
    parser.add_argument(
        "--reference-threshold",
        type=float,
        help=(
            "the threshold the REFERENCE model shipped with. Defaults to the "
            "current one. Pass it explicitly whenever a retrain also moves "
            "discardThreshold, or the comparison is against decisions no user "
            "ever received."
        ),
    )
    args = parser.parse_args()

    global DISCARD_THRESHOLD
    DISCARD_THRESHOLD = discard_threshold()
    # Evaluating the reference with the CANDIDATE's threshold measures flips
    # against decisions users never got: a retrain that moves the threshold
    # reclassifies rows on both sides, and rows that sit between the old and new
    # values cancel out of the comparison entirely.
    reference_threshold = (
        args.reference_threshold if args.reference_threshold is not None else DISCARD_THRESHOLD
    )
    print(f"discard threshold (from {MANIFEST_REL}): {DISCARD_THRESHOLD}")
    if reference_threshold != DISCARD_THRESHOLD:
        print(f"reference threshold (explicit): {reference_threshold}")

    try:
        import coremltools as ct
        import numpy as np
        import torch
        from transformers import AutoTokenizer
    except ImportError as exc:
        die(f"{exc}. Use the pinned interpreter: {PROBE_DIR_NAME}/.venv-ml/bin/python")

    probe = args.probe_dir.resolve()
    checkpoint = probe / CHECKPOINT_REL
    helpers = probe / HELPERS_REL
    for required in (probe, checkpoint, helpers, args.candidate, args.reference):
        if not required.exists():
            die(f"missing {required}")

    # A model compared with ITSELF records zero flips no matter what it does, so
    # a self-comparison is a guaranteed pass that proves nothing. This is easy to
    # hit by accident: the converter writes straight to the tracked resource path,
    # so pointing --reference at that same path after converting compares the new
    # model with the new model.
    #
    # Compare CONTENT, not paths. A path check alone passes when the candidate has
    # been copied somewhere else and that copy is handed back as the reference —
    # different paths, identical bytes, same worthless comparison. Cloud review
    # caught exactly that gap in the path-only version of this guard.
    if args.candidate.resolve() == args.reference.resolve():
        die(
            f"--candidate and --reference resolve to the same package "
            f"({args.candidate.resolve()}). The reference must be the model whose "
            "decisions users currently receive — keep a copy from git before "
            "overwriting the tracked path."
        )
    if package_digest(args.candidate) == package_digest(args.reference):
        die(
            "--candidate and --reference are DIFFERENT paths holding IDENTICAL "
            f"bytes ({args.candidate} vs {args.reference}). Comparing a model with "
            "a copy of itself always reports zero flips, so the verdict would be "
            "meaningless. Point --reference at the model users currently receive."
        )

    # Reuse the training-time dataset class so tokenization is the one path
    # training, the original conversion gate, and this gate all share.
    spec = importlib.util.spec_from_file_location("phase2_train_helpers", helpers)
    helper_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper_module)

    tokenizer = AutoTokenizer.from_pretrained(str(checkpoint))
    units = {
        "all": ct.ComputeUnit.ALL,
        "cpu_only": ct.ComputeUnit.CPU_ONLY,
        "cpu_and_gpu": ct.ComputeUnit.CPU_AND_GPU,
        "cpu_and_ne": ct.ComputeUnit.CPU_AND_NE,
    }

    def sigmoid(x):
        return 1.0 / (1.0 + np.exp(-x))

    report = {
        "threshold": DISCARD_THRESHOLD,
        "reference_threshold": reference_threshold,
        "reference_compute_unit": args.reference_compute_unit,
        "candidate": str(args.candidate),
        "reference": str(args.reference),
        "corpora": {},
    }
    failures = []

    for name, (filename, max_flips, allowed_flip_ids) in CORPORA.items():
        path = probe / filename
        if not path.exists():
            die(f"missing corpus {path}")
        dataset = helper_module.PairDataset(str(path), tokenizer, max_length=MAX_LENGTH)
        row_ids = [
            json.loads(line).get("id", str(index))
            for index, line in enumerate(path.open())
        ]
        print(f"\n=== {name}: {len(dataset)} rows ({filename}) ===", flush=True)

        def features(index):
            item = dataset[index]
            encoded = {
                "input_ids": item["input_ids"].unsqueeze(0).to(torch.int32).numpy(),
                "attention_mask": item["attention_mask"]
                .unsqueeze(0)
                .to(torch.int32)
                .numpy(),
            }
            if "token_type_ids" in item:
                encoded["token_type_ids"] = (
                    item["token_type_ids"].unsqueeze(0).to(torch.int32).numpy()
                )
            return encoded

        def score(package, unit):
            model = ct.models.MLModel(str(package), compute_units=unit)
            out = np.empty(len(dataset))
            for index in range(len(dataset)):
                try:
                    out[index] = float(
                        np.ravel(model.predict(features(index))["logits"])[0]
                    )
                except Exception:
                    out[index] = np.nan
            return out

        reference_probabilities = sigmoid(score(args.reference, units[args.reference_compute_unit]))
        # The reference must be VALIDATED before its decisions are derived, or the
        # gate's own baseline can be the bug it exists to catch. On hardware that
        # places the FLOAT16 reference off the Neural Engine it returns NaN, and
        # `NaN >= threshold` is False — so every reference row silently becomes
        # KEEP, and a badly shifted candidate can then match it and pass. A
        # collapsed reference (one constant value) fails the same way.
        reference_nan = int(np.isnan(reference_probabilities).sum())
        reference_distinct = int(
            len(np.unique(reference_probabilities[~np.isnan(reference_probabilities)]))
        )
        if reference_nan:
            die(
                f"{name}: reference produced {reference_nan} non-finite scores. The "
                "baseline is unusable on this machine, so any verdict would be "
                "meaningless — do not trust a pass from this run."
            )
        if reference_distinct < 2:
            die(
                f"{name}: reference collapsed to {reference_distinct} distinct value(s). "
                "The baseline is degenerate, so any verdict would be meaningless."
            )
        reference_discards = reference_probabilities >= reference_threshold
        print(
            f"  reference({args.reference_compute_unit}) discards "
            f"{int(reference_discards.sum())} @ threshold {reference_threshold}",
            flush=True,
        )

        probabilities = {}
        for unit_name, unit in units.items():
            probability = sigmoid(score(args.candidate, unit))
            probabilities[unit_name] = probability
            decisions = probability >= DISCARD_THRESHOLD
            nan_count = int(np.isnan(probability).sum())
            distinct = int(len(np.unique(probability[~np.isnan(probability)])))
            flipped_indices = np.flatnonzero(reference_discards != decisions)
            flipped_ids = [
                row_ids[i] if i < len(row_ids) else str(i) for i in flipped_indices
            ]
            flips = len(flipped_ids)
            ordered_flips = sorted(flipped_ids)
            flipped_note = ""
            if ordered_flips:
                suffix = (
                    f" (+{len(ordered_flips) - MAX_REPORTED_IDS} more)"
                    if len(ordered_flips) > MAX_REPORTED_IDS
                    else ""
                )
                flipped_note = f"  flipped {ordered_flips[:MAX_REPORTED_IDS]}{suffix}"
            print(
                f"  {unit_name:<12} discards {int(decisions.sum()):>5}  distinct {distinct:>5}"
                f"  nan {nan_count:>5}  flips {flips}{flipped_note}",
                flush=True,
            )
            # NaN and a collapsed output are the two shapes the FLOAT16 model
            # failed in. Flag them explicitly rather than letting them surface
            # only as a flip count, which they may not.
            if nan_count:
                failures.append(f"{name}/{unit_name}: {nan_count} NaN scores")
            if distinct < 2:
                failures.append(
                    f"{name}/{unit_name}: degenerate output, {distinct} distinct value(s)"
                )
            if flips > max_flips:
                failures.append(
                    f"{name}/{unit_name}: {flips} decision flips vs reference (max {max_flips})"
                )
            # Identity, not just count: a different row flipping is a regression
            # even when the count is within budget, and each compute unit could
            # otherwise flip its own distinct row and still pass.
            unexpected = sorted(set(flipped_ids) - allowed_flip_ids)
            if unexpected:
                # Cap the list: a wholesale failure flips thousands of rows, and
                # a report that dumps every id buries the other findings under
                # it. The full set is in the JSON report.
                shown = ", ".join(unexpected[:MAX_REPORTED_IDS])
                more = (
                    f" (+{len(unexpected) - MAX_REPORTED_IDS} more)"
                    if len(unexpected) > MAX_REPORTED_IDS
                    else ""
                )
                failures.append(
                    f"{name}/{unit_name}: decision flipped on {len(unexpected)} unexpected "
                    f"row(s): {shown}{more}; only "
                    f"{sorted(allowed_flip_ids) or 'no rows'} may flip"
                )

        cross_max = max(
            float(np.nanmax(np.abs(probabilities[a] - probabilities[b])))
            for a, b in combinations(probabilities, 2)
        )
        cross_flips = sum(
            int(
                (
                    (probabilities[a] >= DISCARD_THRESHOLD)
                    != (probabilities[b] >= DISCARD_THRESHOLD)
                ).sum()
            )
            for a, b in combinations(probabilities, 2)
        )
        margins = np.abs(probabilities["all"] - DISCARD_THRESHOLD)
        closest = [
            {
                "id": row_ids[i] if i < len(row_ids) else str(i),
                "probability": float(probabilities["all"][i]),
                "margin": float(margins[i]),
            }
            for i in np.argsort(margins)[:5]
        ]
        print(
            f"  cross-compute max probability diff {cross_max:.9f}"
            f"   cross-compute decision flips {cross_flips}"
        )
        for row in closest:
            print(
                f"    closest {row['id']:<20} p={row['probability']:.9f}"
                f"  margin={row['margin']:.3e}"
            )

        report["corpora"][name] = {
            "file": filename,
            "rows": len(dataset),
            "reference_discards": int(reference_discards.sum()),
            "flips_vs_reference": {
                unit_name: int(
                    (
                        reference_discards
                        != (probabilities[unit_name] >= DISCARD_THRESHOLD)
                    ).sum()
                )
                for unit_name in probabilities
            },
            "max_flips_allowed": max_flips,
            "allowed_flip_ids": sorted(allowed_flip_ids),
            "flipped_ids": {
                unit_name: sorted(
                    row_ids[i] if i < len(row_ids) else str(i)
                    for i in np.flatnonzero(
                        reference_discards
                        != (probabilities[unit_name] >= DISCARD_THRESHOLD)
                    )
                )
                for unit_name in probabilities
            },
            "nan": {
                unit_name: int(np.isnan(probabilities[unit_name]).sum())
                for unit_name in probabilities
            },
            "cross_compute_max_probability_diff": cross_max,
            "cross_compute_decision_flips": cross_flips,
            "closest_margin_rows": closest,
        }

    report["failures"] = failures
    if args.report:
        args.report.write_text(json.dumps(report, indent=2))
        print(f"\nwrote {args.report}")

    if failures:
        print("\nGATE FAILED:")
        for failure in failures:
            print(f"  - {failure}")
        raise SystemExit(1)
    print("\nGATE PASSED")


if __name__ == "__main__":
    main()
