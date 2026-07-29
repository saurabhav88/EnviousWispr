#!/usr/bin/env python3
"""Regenerate the committed golden score fixtures for the output-safety classifier.

Run this whenever `Sources/EnviousWisprLLM/Resources/OutputClassifier.mlpackage`
changes. It scores the committed pretokenized fixtures against the committed
model and rewrites the expected probabilities the Swift suite asserts against
(`OutputClassifierGoldenScoreTests`).

Everything it reads is tracked, so this needs only `coremltools` — not the
gitignored artifact tree. It is the numerical counterpart to the tokenization
parity fixture: parity proves Swift tokenizes identically to Python, and these
scores prove the model still turns those tokens into the same decisions.

Fixtures rewritten, both in Tests/EnviousWisprTests/Resources/OutputClassifier/:
    MiniLM-L6.golden-scores.jsonl   50 rows, scored from MiniLM-L6.parity50.pretokenized.jsonl
    MiniLM-L6.boundary-row.jsonl    1 row, the knife-edge case (see below)

The boundary row (#1226). `reformat-03718` sits ~5e-08 in probability from the
discard threshold — far closer than the ~2.7e-06 spread between compute units, so
which side it lands on is not stable and never was: the FLOAT16 model that shipped
before disagreed with the PyTorch reference on it by 4e-04. It is pinned by
PROBABILITY only, never by decision, so a future flip there reads as the known
coin-flip it is rather than a regression.

Run:
    ./scripts/emit-output-classifier-golden.py            # any interpreter with coremltools
"""

import argparse
import json
import math
import re
import sys
from pathlib import Path

MANIFEST_REL = "Sources/EnviousWisprLLM/OutputClassifierManifest.swift"
FIXTURES_REL = "Tests/EnviousWisprTests/Resources/OutputClassifier"
PACKAGE_REL = "Sources/EnviousWisprLLM/Resources/OutputClassifier.mlpackage"
PRETOKENIZED_NAME = "MiniLM-L6.parity50.pretokenized.jsonl"
GOLDEN_NAME = "MiniLM-L6.golden-scores.jsonl"
BOUNDARY_NAME = "MiniLM-L6.boundary-row.jsonl"


def die(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def read_jsonl(path: Path) -> list:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def discard_threshold() -> float:
    """Read the threshold from the Swift manifest rather than copying it. A stale
    copy would silently bake wrong decisions into the fixture the Swift suite then
    asserts against, so parsing fails closed instead."""
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
    parser.add_argument("--package", type=Path, default=repo_root() / PACKAGE_REL)
    parser.add_argument("--fixtures", type=Path, default=repo_root() / FIXTURES_REL)
    args = parser.parse_args()

    try:
        import coremltools as ct
        import numpy as np
    except ImportError as exc:
        die(f"{exc}. Install coremltools, or use artifacts/issue-832-classifier-probe/.venv-ml/bin/python")

    for required in (args.package, args.fixtures):
        if not required.exists():
            die(f"missing {required}")

    global DISCARD_THRESHOLD
    DISCARD_THRESHOLD = discard_threshold()
    print(f"discard threshold (from {MANIFEST_REL}): {DISCARD_THRESHOLD}")

    model = ct.models.MLModel(str(args.package), compute_units=ct.ComputeUnit.ALL)

    def score(row: dict) -> tuple:
        features = {
            name: np.array([row[name]], dtype=np.int32)
            for name in ("input_ids", "attention_mask", "token_type_ids")
        }
        logit = float(np.ravel(model.predict(features)["logits"])[0])
        probability = 1.0 / (1.0 + math.exp(-logit))
        if not math.isfinite(probability):
            die(f"non-finite score for row {row.get('id')}")
        return logit, probability

    pretokenized = args.fixtures / PRETOKENIZED_NAME
    if not pretokenized.exists():
        die(f"missing {pretokenized}")
    rows = read_jsonl(pretokenized)
    if len(rows) != 50:
        die(f"expected 50 pretokenized rows, found {len(rows)}")
    # A count alone is satisfied by a duplicate that replaced another row, which
    # would bake a duplicated id into the golden fixture every downstream check
    # then trusts.
    if len({row["id"] for row in rows}) != 50:
        die(
            f"pretokenized fixture has duplicate ids: {len(rows)} rows, "
            f"{len({row['id'] for row in rows})} unique"
        )

    golden_lines = []
    closest = None
    for row in rows:
        logit, probability = score(row)
        margin = abs(probability - DISCARD_THRESHOLD)
        if closest is None or margin < closest[1]:
            closest = (row["id"], margin)
        golden_lines.append(
            json.dumps(
                {
                    "id": row["id"],
                    "logit": logit,
                    "prob": probability,
                    "decision": "DISCARD" if probability >= DISCARD_THRESHOLD else "KEEP",
                }
            )
        )
    (args.fixtures / GOLDEN_NAME).write_text("\n".join(golden_lines) + "\n")
    print(f"wrote {GOLDEN_NAME}: {len(golden_lines)} rows")
    print(f"  closest row to the threshold: {closest[0]} at margin {closest[1]:.3e}")
    # The 50 parity rows are meant to be decision-stable. If one drifts inside the
    # cross-compute spread it is no longer safe to decision-pin, and the Swift
    # test would start flaking on other hardware rather than failing honestly.
    if closest[1] < 1e-3:
        die(
            f"row {closest[0]} is {closest[1]:.3e} from the threshold — too close to "
            "decision-pin. Move it to the boundary fixture or replace it."
        )

    boundary_path = args.fixtures / BOUNDARY_NAME
    if not boundary_path.exists():
        die(
            f"missing {boundary_path}. It carries the knife-edge row's pretokenized "
            "ids and cannot be regenerated without the gitignored corpus."
        )
    boundary_rows = read_jsonl(boundary_path)
    if len(boundary_rows) != 1:
        die(f"expected exactly 1 boundary row, found {len(boundary_rows)}")
    boundary = boundary_rows[0]
    logit, probability = score(boundary)
    boundary["logit"] = logit
    boundary["prob"] = probability
    boundary["margin"] = abs(probability - DISCARD_THRESHOLD)
    boundary_path.write_text(json.dumps(boundary) + "\n")
    print(
        f"wrote {BOUNDARY_NAME}: {boundary['id']} prob={probability:.9f} "
        f"margin={boundary['margin']:.3e}"
    )


if __name__ == "__main__":
    main()
