#!/usr/bin/env python3
"""Convert the trained output-safety classifier checkpoint to the shipped Core ML package.

This is the RECIPE for `Sources/EnviousWisprLLM/Resources/OutputClassifier.mlpackage`.
It is tracked so the conversion settings that ship to users are reviewable in the
repo. It does NOT make the model reproducible from a fresh clone: the trained
checkpoint and the pinned virtualenv live under gitignored `artifacts/`
(`.gitignore:219-220`). Reproducing the artifact requires that tree.

Inputs (gitignored, must exist locally):
    artifacts/issue-832-classifier-probe/
      phase2-models/MiniLM-L6-reformat2-13/checkpoint-best/   <- trained weights (#949 retrain)
      phase3-convert-trained.py                               <- owns the wrapper + trace
      .venv-ml/                                               <- pinned toolchain

Run:
    cd artifacts/issue-832-classifier-probe
    ./.venv-ml/bin/python ../../scripts/convert-output-classifier.py \
        ../../Sources/EnviousWisprLLM/Resources/OutputClassifier.mlpackage

From a worktree the artifact tree is absent (it is gitignored, so it exists only
in the main checkout). Point at it explicitly:
    --probe-dir /path/to/main/checkout/artifacts/issue-832-classifier-probe

Why FLOAT32 (#1226, 2026-07-28). The model shipped at FLOAT16 until v1.x. On
hardware where Core ML does not place it on the Neural Engine, fp16 attention
overflows: CPU-only scoring returns all-NaN and CPU+GPU returns a single constant
logit, silently disabling the safety classifier. Measured on M4 by excluding the
ANE, which reproduces the M5 field symptom without M5 hardware. FLOAT32 makes the
model placement-independent — all four compute units agree to ~2.7e-06 in
probability. Full evidence and the decision:
`docs/feature-requests/issue-1226-2026-07-15-output-classifier-compute-fallback.md`.

Changing anything here changes the shipped model bytes. That breaks
`OutputClassifierManifest.mlpackageSHA256` (regenerate from this script's output)
and requires re-running the three-corpus x four-compute-unit gate before commit.
"""

import argparse
import hashlib
import importlib.util
import shutil
import sys
import time
from pathlib import Path

# Toolchain the shipped artifact was produced with. A different toolchain can
# change the emitted graph, so refuse rather than silently produce other bytes.
EXPECTED_COREMLTOOLS = "9.0"
EXPECTED_TRANSFORMERS = "4.50.0"

PROBE_DIR_NAME = "artifacts/issue-832-classifier-probe"
CHECKPOINT_REL = "phase2-models/MiniLM-L6-reformat2-13/checkpoint-best"
CONVERTER_REL = "phase3-convert-trained.py"


def die(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def package_sha256(package: Path) -> str:
    """Mirror of `OutputClassifierContractTests.mlpackageDigestMatchesManifest`
    (`Tests/EnviousWisprTests/LLM/OutputClassifierContractTests.swift:103-120`):
    sha256 over sorted "<relpath> <filesha256>" lines. The LINES are sorted, not
    the paths — sorting paths can order differently when one path is a prefix of
    another. Kept identical so the printed value can be pasted straight into
    `OutputClassifierManifest.mlpackageSHA256`."""
    lines = []
    for path in package.rglob("*"):
        if not path.is_file():
            continue
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        lines.append(f"{path.relative_to(package).as_posix()} {digest}")
    lines.sort()
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="destination .mlpackage path")
    parser.add_argument(
        "--probe-dir",
        type=Path,
        default=repo_root() / PROBE_DIR_NAME,
        help=f"artifact tree containing the checkpoint (default: <repo>/{PROBE_DIR_NAME})",
    )
    args = parser.parse_args()

    try:
        import coremltools as ct
        import numpy as np
        import torch
        import transformers
        from transformers import AutoTokenizer
    except ImportError as exc:
        die(
            f"{exc}. Run this with the pinned interpreter: "
            f"{PROBE_DIR_NAME}/.venv-ml/bin/python"
        )

    if ct.__version__ != EXPECTED_COREMLTOOLS:
        die(
            f"coremltools {ct.__version__}, expected {EXPECTED_COREMLTOOLS}. "
            "A different converter can emit a different graph; update this pin "
            "deliberately and re-run the numerical gate."
        )
    if transformers.__version__ != EXPECTED_TRANSFORMERS:
        die(
            f"transformers {transformers.__version__}, expected {EXPECTED_TRANSFORMERS}."
        )

    probe = args.probe_dir.resolve()
    checkpoint = probe / CHECKPOINT_REL
    converter = probe / CONVERTER_REL
    for required in (probe, checkpoint, converter):
        if not required.exists():
            die(f"missing {required} — the gitignored artifact tree is required")

    # Import the converter that produced the shipped model so the wrapper, the
    # traced graph, and MAX_LEN come from one place. Reimplementing the trace
    # here would let it drift from the artifact it is supposed to reproduce.
    spec = importlib.util.spec_from_file_location("phase3_convert", converter)
    phase3 = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(phase3)

    output = args.output.resolve()
    print(f"checkpoint : {checkpoint}")
    print(f"precision  : FLOAT32")
    print(f"max length : {phase3.MAX_LEN}")
    print(f"output     : {output}")

    torch.set_num_threads(1)

    # MiniLM is BERT-family, so it takes token_type_ids: three inputs.
    wrapper = phase3.BertFamilyWrapper(str(checkpoint)).eval()
    tokenizer = AutoTokenizer.from_pretrained(str(checkpoint))
    sample = phase3.make_sample(tokenizer, has_token_types=True)

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, sample, strict=False, check_trace=False)

    inputs = [
        ct.TensorType(name="input_ids", shape=(1, phase3.MAX_LEN), dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=(1, phase3.MAX_LEN), dtype=np.int32),
        ct.TensorType(name="token_type_ids", shape=(1, phase3.MAX_LEN), dtype=np.int32),
    ]

    if output.exists():
        shutil.rmtree(output)

    started = time.time()
    model = ct.convert(
        traced,
        inputs=inputs,
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS14,
    )
    model.save(str(output))

    disk_mb = sum(f.stat().st_size for f in output.rglob("*") if f.is_file()) / 1e6
    print(f"\nconverted in {time.time() - started:.1f}s — {disk_mb:.1f} MB on disk")
    print(f"mlpackageSHA256 = {package_sha256(output)}")
    print(
        "\nNext: run the three-corpus x four-compute-unit gate against THESE bytes "
        "before committing, then paste the hash above into "
        "Sources/EnviousWisprLLM/OutputClassifierManifest.swift."
    )


if __name__ == "__main__":
    main()
