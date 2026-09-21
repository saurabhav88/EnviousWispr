#!/usr/bin/env python3
"""Write the bundled delivery manifest for the correction judge (#996 phase D).

The judge ships as a Core ML package: a DIRECTORY of files (`Manifest.json`,
`Data/com.apple.CoreML/model.mlmodel`, the weights, …) plus the training
manifest the runtime loader reads beside it. The delivery layer moves FILES
(contract §4), so every regular file under the examined export directory
becomes one manifest entry with its size and SHA-256, fetch path == install
path, exactly like Parakeet's nested `.mlmodelc` entries.

The runtime loader (`CoreMLCorrectionJudge.load`) reads more than the export
directory: the tokenizer contract and the tokenizer folder live in the RUN
directory on the training machine. A delivered folder must be self-contained,
so this tool first STAGES one: the export directory's files plus
`tokenizer-contract.json` and `tokenizer/` copied from the run, into
`--stage-dir` (refused if it exists). The manifest is computed from that staged
folder, which is also what gets uploaded to the mirror byte for byte.

Inputs are gitignored (under artifacts/); the output is the tracked resource,
digest included (the digest rule is `scripts/regen-delivery-manifest-digest.py`'s,
imported, so there is one implementation of it).

    usage: build-edit-judge-delivery-manifest.py --export <dir> --stage-dir <dir>
               --revision <id> --min-app-version <x.y.z>
               [--run <dir>]   (default: three levels above --export, the trainer's layout)
               [--out Sources/EnviousWispr/Resources/edit-judge-delivery-manifest.json]
               [--base-url https://models.enviouslabs.co/edit-judge/<revision>/]

Refuses (exit 2): a stage dir that exists, an export with no
`training-manifest-shaped.json` or no `.mlpackage`, a run with no
`tokenizer-contract.json` or `checkpoint/tokenizer/tokenizer.json`, a symlink,
or a path that would fail the manifest's structural rules.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import shutil
import sys
from pathlib import Path

RUNTIME_MANIFEST = "training-manifest-shaped.json"
VERIFICATION = "verification.json"
CONTRACT = "tokenizer-contract.json"
TOKENIZER_DIR = "tokenizer"
FAMILY = "edit_judge"
NAME = "xenc-mmbert-small"
VARIANT = "fp16"
RUNTIME_ABI = "coreml-edit-judge-v1"
DEFAULT_OUT = Path("Sources/EnviousWispr/Resources/edit-judge-delivery-manifest.json")

_regen_path = Path(__file__).resolve().parent / "regen-delivery-manifest-digest.py"
_spec = importlib.util.spec_from_file_location("regen_delivery_manifest_digest", _regen_path)
_regen = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(_regen)


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def stage(export: Path, run: Path, stage_dir: Path) -> Path:
    """Copy the export plus the run's contract and tokenizer into one folder."""
    if stage_dir.exists():
        raise SystemExit(f"refused: stage dir exists: {stage_dir}")
    for name in (RUNTIME_MANIFEST, VERIFICATION):
        if not (export / name).is_file():
            raise SystemExit(f"refused: {export} has no {name}")
    packages = sorted(p for p in export.iterdir() if p.suffix == ".mlpackage" and p.is_dir())
    if len(packages) != 1:
        raise SystemExit(f"refused: {export} needs exactly one .mlpackage, found {len(packages)}")
    contract = run / CONTRACT
    tokenizer = run / "checkpoint" / TOKENIZER_DIR
    if not contract.is_file():
        raise SystemExit(f"refused: {run} has no {CONTRACT}")
    if not (tokenizer / "tokenizer.json").is_file():
        raise SystemExit(f"refused: {tokenizer} has no tokenizer.json")
    for p in list(export.rglob("*")) + list(tokenizer.rglob("*")) + [contract]:
        if p.is_symlink():
            raise SystemExit(f"refused: symlink in inputs: {p}")
    # Only what the runtime loader reads (contract §4c); the export's other
    # receipts (`training-manifest.json`, logs) stay with the run.
    stage_dir.mkdir(parents=True)
    for name in (RUNTIME_MANIFEST, VERIFICATION):
        shutil.copy2(export / name, stage_dir / name)
    shutil.copytree(packages[0], stage_dir / packages[0].name, symlinks=False)
    shutil.copy2(contract, stage_dir / CONTRACT)
    shutil.copytree(tokenizer, stage_dir / TOKENIZER_DIR, symlinks=False)
    return stage_dir


def runtime_identity_digest(folder: Path) -> str:
    """`CoreMLCorrectionJudge.classifierIdentityDigest`, exactly: the package,
    tokenizer and decision-config SHA-256s the runtime manifest binds, folded
    into one line. The delivery manifest carries it so the fetch policy can
    refuse a download whose bytes no qualification names."""
    manifest = json.loads((folder / RUNTIME_MANIFEST).read_text())
    identity = manifest["execution_identity"]
    package = manifest["decision_config"]["package_sha256"]
    material = (
        f"package_sha256={package}\n"
        f"tokenizer_sha256={identity['tokenizer_sha256']}\n"
        f"config_sha256={identity['config_sha256']}\n"
    )
    return hashlib.sha256(material.encode()).hexdigest()


def collect_files(folder: Path) -> list[dict]:
    entries = []
    for p in sorted(folder.rglob("*")):
        if p.is_symlink():
            raise SystemExit(f"refused: symlink in export: {p}")
        if not p.is_file():
            continue
        rel = p.relative_to(folder).as_posix()
        if rel.startswith("/") or ".." in rel.split("/"):
            raise SystemExit(f"refused: unsafe path {rel}")
        # `component` is the top path segment (contract §4c): the package
        # directory for every file inside the .mlpackage, the tokenizer folder
        # for its files, the file itself for a top-level receipt or contract.
        # `DeliveryManifest.validateStructure` refuses anything else.
        entries.append(
            {
                "path": rel,
                "installPath": rel,
                "sizeBytes": p.stat().st_size,
                "sha256": sha256_of(p),
                "component": rel.split("/")[0],
            }
        )
    if not entries:
        raise SystemExit(f"refused: {folder} holds no regular files")
    return entries


def build(folder: Path, revision: str, min_app_version: str, base_url: str) -> dict:
    files = collect_files(folder)
    manifest = {
        "schemaVersion": 1,
        "identity": {
            "family": FAMILY,
            "name": NAME,
            "revision": revision,
            "variant": VARIANT,
            "runtimeABI": RUNTIME_ABI,
        },
        "runtimeCompatibility": {"minAppVersion": min_app_version},
        "runtimeIdentityDigest": runtime_identity_digest(folder),
        "files": files,
        "optionalFiles": [],
        "totalBytes": sum(f["sizeBytes"] for f in files),
        "sources": [{"id": "our_copy", "baseURL": base_url}],
        "license": {
            "name": "Envious Labs weights; base model mmBERT-small (Apache-2.0)",
            "url": "https://huggingface.co/jhu-clsp/mmBERT-small",
        },
        "admission": {
            "layout": "componentSet",
            "installLocation": "editJudgeCache",
            "diskHeadroomFactor": "2.2",
            "evictPreviousRevisions": True,
            "entrypointFile": RUNTIME_MANIFEST,
        },
    }
    manifest["manifestDigest"] = _regen.canonical_digest(manifest)
    return manifest


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--export", type=Path, required=True)
    p.add_argument("--stage-dir", type=Path, required=True)
    p.add_argument("--run", type=Path, default=None)
    p.add_argument("--revision", required=True)
    p.add_argument("--min-app-version", required=True)
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p.add_argument("--base-url", default=None)
    a = p.parse_args(argv[1:])
    base_url = a.base_url or f"https://models.enviouslabs.co/edit-judge/{a.revision}/"
    if not base_url.endswith("/"):
        raise SystemExit("refused: --base-url must end with /")
    export = a.export.resolve()
    run = (a.run or export.parent.parent.parent).resolve()
    staged = stage(export, run, a.stage_dir.resolve())
    manifest = build(staged, a.revision, a.min_app_version, base_url)
    a.out.write_text(json.dumps(manifest, indent=2) + "\n")
    print(
        f"staged {staged}\nwrote {a.out}: {len(manifest['files'])} files, "
        f"{manifest['totalBytes']:,} bytes, digest {manifest['manifestDigest'][:12]}…"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
