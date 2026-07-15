#!/usr/bin/env python3
"""Run a receipt-producing, metadata-only leakage scan for EG-1 development data."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Protocol, Sequence

import numpy as np

SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
V2_PATH = SCRIPT_PATH.parent / "multilingual_benchmark_v2.py"
REPLAY_PATH = SCRIPT_PATH.parent / "screen_eg1_replay_semantic_neighbors.py"
REPLAY_INVENTORY_PATH = SCRIPT_PATH.parent / "build_eg1_replay_inventory.py"
REPLAY_NORMALIZER_PATH = SCRIPT_PATH.parent / "eg1_replay_normalizer_v1.py"
V2_SHA256 = "0f2772b9b1d989a2c0f7a8b6898a182b2f6782bfdc397319b4bd9d73ac6a47d7"
REPLAY_SHA256 = "094cab008f265484da7fb38d92e0148f063cc02941a616d4c88f39284f8cddd9"
REPLAY_INVENTORY_SHA256 = "1d8920a705b8c0dee8d54e7e2fd97de98e571212ef641858caf8ee33637b3927"
REPLAY_NORMALIZER_SHA256 = "33ac563c1c5e09f88d0d7ab25a2a5f10070f3bfda0e71cbe1d00b57b86c961ef"
EVAL_DIR_TEXT = str(SCRIPT_PATH.parent)
if EVAL_DIR_TEXT in sys.path:
    sys.path.remove(EVAL_DIR_TEXT)
sys.path.insert(0, EVAL_DIR_TEXT)


def load_pinned_module(name: str, path: Path, expected_sha256: str) -> Any:
    source = path.read_bytes()
    if hashlib.sha256(source).hexdigest() != expected_sha256:
        raise RuntimeError(f"pinned dependency differs before import: {path.name}")
    existing = sys.modules.get(name)
    if (
        existing is not None
        and Path(getattr(existing, "__file__", "")).resolve() == path.resolve()
        and getattr(existing, "_EG1_AUTHENTICATED_SOURCE_SHA256", None)
        == expected_sha256
    ):
        return existing
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load pinned dependency: {path.name}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        exec(compile(source, str(path), "exec"), module.__dict__)
    except Exception:
        if sys.modules.get(name) is module:
            sys.modules.pop(name, None)
        raise
    module._EG1_AUTHENTICATED_SOURCE_SHA256 = expected_sha256
    return module


v2 = load_pinned_module("eg1_pinned_multilingual_benchmark_v2", V2_PATH, V2_SHA256)
replay_normalizer = load_pinned_module("eg1_replay_normalizer_v1", REPLAY_NORMALIZER_PATH, REPLAY_NORMALIZER_SHA256)
replay_inventory = load_pinned_module("build_eg1_replay_inventory", REPLAY_INVENTORY_PATH, REPLAY_INVENTORY_SHA256)
replay = load_pinned_module("eg1_pinned_replay_semantic_neighbors", REPLAY_PATH, REPLAY_SHA256)


DEFAULT_CONTRACT = REPO_ROOT / "scripts/eval/contracts/eg1_multilingual_development_leakage_scanner_v1.json"
SCHEMA_VERSION = "eg1-multilingual-development-leakage-scanner-v1"
RECEIPT_SCHEMA_VERSION = "eg1-multilingual-development-leakage-receipt-v1"
RAW_ROLES = frozenset({"training", "prior_eval"})
REGISTRY_ROLES = frozenset({"blocked_family_registry", "blocked_text_hash_registry"})
METHODS = ("exact_normalized", "token_ngram_jaccard", "character_ngram_jaccard", "embedding_cosine")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
LEAKAGE_SOURCE_RECEIPT_SCHEMA = "eg1-multilingual-leakage-source-receipt-v1"
LEAKAGE_INVENTORY_SCHEMA = "eg1-multilingual-leakage-inventory-v1"
ASSURANCE_SCOPE = "operator_attested_unsigned_private_evidence_reopened_by_verifier"
REPLAY_BACKEND_PATH = "scripts/eval/screen_eg1_replay_semantic_neighbors.py"
REPLAY_BACKEND_SHA256 = REPLAY_SHA256
V2_PATH_RELATIVE = "scripts/eval/multilingual_benchmark_v2.py"
REPLAY_INVENTORY_PATH_RELATIVE = "scripts/eval/build_eg1_replay_inventory.py"
REPLAY_NORMALIZER_PATH_RELATIVE = "scripts/eval/eg1_replay_normalizer_v1.py"
EXPECTED_EMBEDDING_IDENTITY = {
    "repo_id": "Qwen/Qwen3-Embedding-0.6B",
    "revision": "97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3",
    "tree_sha256": "087413375b109d83ccd69bff217f841ce9029e9a6d7d3804129d65a5f9bf319e",
    "file_count": 10,
    "total_bytes": 1207487354,
    "embedding_dimension": 1024,
    "pooling": "last_token",
    "prompt_name": "document",
    "batch_size": 32,
    "comparison_batch_size": 128,
    "device": "mps",
    "execution_scope": "mac_mps_canonical_aliensv_calibration_only",
    "model_dtype": "float16",
    "output_precision": "float32",
    "normalize_embeddings": True,
    "max_seq_length": 32768,
    "comparison_axes": ["input_input", "output_output", "input_output", "output_input"],
    "score_decimals": 6,
    "top_k": 5,
    "runtime_versions": {"sentence_transformers": "5.6.0", "transformers": "5.12.1", "torch": "2.12.1", "numpy": "2.4.6"},
}


class EmbeddingBackend(Protocol):
    runtime_versions: dict[str, str]

    def encode_documents(self, texts: Sequence[str]) -> np.ndarray: ...


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot_files(paths: Sequence[Path]) -> dict[str, str]:
    return {str(path.resolve()): sha256_bytes(path.read_bytes()) for path in paths}


def capture_files(paths: Sequence[Path]) -> dict[str, bytes]:
    return {str(path.resolve()): path.read_bytes() for path in paths}


def captured(captures: dict[str, bytes], path: Path) -> bytes:
    return captures[str(path.resolve())]


def regular_sibling_files(path: Path) -> list[Path]:
    result: list[Path] = []
    for sibling in sorted(path.resolve().parent.iterdir()):
        if sibling.is_symlink():
            raise ValueError(f"evidence bundle contains a symlink: {sibling.name}")
        if sibling.is_file():
            result.append(sibling)
        elif not sibling.is_dir():
            raise ValueError(f"evidence bundle contains a non-regular entry: {sibling.name}")
    return result


def model_file_fingerprint(model_dir: Path) -> dict[str, str]:
    if model_dir.is_symlink() or not model_dir.is_dir():
        raise ValueError("embedding model directory is not regular")
    result: dict[str, str] = {}
    for path in sorted(model_dir.rglob("*")):
        relative = str(path.relative_to(model_dir))
        if path.is_symlink():
            raise ValueError(f"embedding model contains a symlink: {relative}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError(f"embedding model contains a non-regular entry: {relative}")
        result[relative] = sha256_file(path)
    if not result:
        raise ValueError("embedding model directory contains no files")
    return result


def read_json(path: Path, label: str) -> Any:
    return read_json_bytes(path.read_bytes(), label)


def read_json_bytes(value: bytes, label: str) -> Any:
    try:
        return json.loads(value.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is not valid JSON") from error


def read_records(path: Path, label: str) -> list[dict[str, Any]]:
    return read_records_bytes(path.read_bytes(), label)


def read_records_bytes(value: bytes, label: str) -> list[dict[str, Any]]:
    raw = value.decode("utf-8")
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        parsed = [json.loads(line) for line in raw.splitlines() if line.strip()]
    if isinstance(parsed, dict):
        selected = False
        for field in ("rows", "records", "items", "families"):
            if isinstance(parsed.get(field), list):
                parsed = parsed[field]
                selected = True
                break
        if not selected:
            parsed = [parsed]
    if not isinstance(parsed, list) or not all(isinstance(row, dict) for row in parsed):
        raise ValueError(f"{label} must contain JSON records")
    return parsed


def parse_bound_specs(specs: Sequence[str], label: str) -> dict[tuple[str, str], Path]:
    result: dict[tuple[str, str], Path] = {}
    for spec in specs:
        identity, separator, raw_path = spec.partition("=")
        parts = identity.split(":", 1)
        if separator != "=" or len(parts) != 2 or not all(parts) or not raw_path:
            raise ValueError(f"{label} must use ROLE:NAME=PATH")
        key = (parts[0], parts[1])
        if parts[0] not in v2.LEAKAGE_ROLES or not v2.IDENTIFIER_RE.fullmatch(parts[1]):
            raise ValueError(f"invalid {label} identity: {key}")
        if key in result:
            raise ValueError(f"duplicate {label}: {key}")
        path = Path(raw_path).expanduser().resolve()
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"missing {label}: {key}")
        result[key] = path
    return result


def extract_texts(rows: Sequence[dict[str, Any]]) -> list[str]:
    fields = ("asr_input", "gold_output", "input", "output", "expected_output")
    return [value for row in rows for field in fields if isinstance((value := row.get(field)), str) and value.strip()]


def text_sides(rows: Sequence[dict[str, Any]], role: str) -> tuple[list[str], list[str]]:
    if role == "benchmark":
        input_fields, output_fields = ("asr_input",), ("gold_output",)
    elif role in RAW_ROLES:
        input_fields, output_fields = ("asr_input", "input"), ("expected_output", "gold_output", "output")
    else:
        return [], []
    inputs = [value for row in rows for field in input_fields if isinstance((value := row.get(field)), str) and value.strip()]
    outputs = [value for row in rows for field in output_fields if isinstance((value := row.get(field)), str) and value.strip()]
    return inputs, outputs


def token_ngrams(value: str, width: int) -> set[tuple[str, ...]]:
    tokens = v2.normalize_text(value).split()
    return {tuple(tokens[index:index + width]) for index in range(max(0, len(tokens) - width + 1))}


def character_ngrams(value: str, width: int) -> set[str]:
    normalized = v2.normalize_text(value)
    return {normalized[index:index + width] for index in range(max(0, len(normalized) - width + 1))}


def jaccard(left: set[Any], right: set[Any]) -> float:
    if not left and not right:
        return 0.0
    if not left or not right:
        return 0.0
    return len(left & right) / len(left | right)


def pairwise_jaccard_stats(candidates: Sequence[str], references: Sequence[str], *, width: int, characters: bool, threshold: float | None) -> tuple[float, int | None]:
    builder = character_ngrams if characters else token_ngrams
    candidate_sets = [builder(value, width) for value in candidates]
    reference_sets = [builder(value, width) for value in references]
    maximum = 0.0
    violations = 0
    for left in candidate_sets:
        for right in reference_sets:
            score = jaccard(left, right)
            maximum = max(maximum, score)
            if threshold is not None and score >= threshold:
                violations += 1
    return maximum, violations if threshold is not None else None


def cosine_stats(candidates: Sequence[str], references: Sequence[str], backend: EmbeddingBackend, threshold: float | None) -> tuple[float, int | None]:
    if not candidates or not references:
        return 0.0, 0
    preflight = getattr(backend, "preflight_token_lengths", None)
    if callable(preflight):
        preflight(candidates)
        preflight(references)
    left = backend.encode_documents(candidates)
    right = backend.encode_documents(references)
    scores = np.clip(left @ right.T, -1.0, 1.0)
    return float(np.max(scores)), (int(np.count_nonzero(scores >= threshold)) if threshold is not None else None)


class SyntheticEmbeddingBackend:
    """Deterministic real computation for tests, never quality evidence."""

    runtime_versions = {"backend": "sha256-token-projection-v1", "numpy": np.__version__}

    def __init__(self, dimensions: int = 256) -> None:
        self.dimensions = dimensions

    def encode_documents(self, texts: Sequence[str]) -> np.ndarray:
        result = np.zeros((len(texts), self.dimensions), dtype=np.float32)
        for row_index, text in enumerate(texts):
            features = v2.normalize_text(text).split() or [""]
            for feature in features:
                digest = hashlib.sha256(feature.encode()).digest()
                index = int.from_bytes(digest[:4], "big") % self.dimensions
                result[row_index, index] += -1.0 if digest[4] & 1 else 1.0
            norm = np.linalg.norm(result[row_index])
            if norm:
                result[row_index] /= norm
        return result


model_tree_receipt = replay.model_tree_receipt
LocalSentenceTransformerBackend = replay.LocalSentenceTransformerBackend


def validate_contract(contract: Any) -> dict[str, Any]:
    if not isinstance(contract, dict) or contract.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("scanner contract version changed")
    if set(contract) != {"schema_version", "required_methods", "token_ngram_width", "character_ngram_width", "production_thresholds", "synthetic_test_only_thresholds", "embedding", "replay_backend_binding", "multilingual_validator_binding", "replay_inventory_binding", "replay_normalizer_binding"}:
        raise ValueError("scanner contract schema changed")
    if contract.get("replay_backend_binding") != {"path": REPLAY_BACKEND_PATH, "sha256": REPLAY_BACKEND_SHA256}:
        raise ValueError("replay backend binding changed")
    if contract.get("multilingual_validator_binding") != {"path": V2_PATH_RELATIVE, "sha256": V2_SHA256}:
        raise ValueError("multilingual validator binding changed")
    if contract.get("replay_inventory_binding") != {"path": REPLAY_INVENTORY_PATH_RELATIVE, "sha256": REPLAY_INVENTORY_SHA256}:
        raise ValueError("replay inventory binding changed")
    if contract.get("replay_normalizer_binding") != {"path": REPLAY_NORMALIZER_PATH_RELATIVE, "sha256": REPLAY_NORMALIZER_SHA256}:
        raise ValueError("replay normalizer binding changed")
    if contract.get("required_methods") != list(METHODS):
        raise ValueError("required leakage methods changed")
    if contract.get("production_thresholds") != {method: "calibration_required" for method in METHODS[1:]}:
        raise ValueError("production thresholds must remain calibration_required")
    if any(type(contract.get(field)) is not int or contract[field] <= 0 for field in ("token_ngram_width", "character_ngram_width")):
        raise ValueError("n-gram widths are invalid")
    thresholds = contract.get("synthetic_test_only_thresholds")
    if not isinstance(thresholds, dict) or set(thresholds) != set(METHODS[1:]) or any(type(value) not in {int, float} or not 0 < value <= 1 for value in thresholds.values()):
        raise ValueError("synthetic thresholds are invalid")
    embedding = contract.get("embedding")
    if embedding != EXPECTED_EMBEDDING_IDENTITY:
        raise ValueError("embedding contract identity changed")
    return contract


def threshold_status(score: float, threshold: float) -> str:
    return "failed" if score >= threshold else "passed"


def validate_git_controls(expected_head: str, contract_path: Path, producing_head: str | None = None) -> dict[str, str]:
    if producing_head not in {None, expected_head}:
        raise ValueError("historical controls require producer-closure authentication")
    actual = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, check=True, text=True, stdout=subprocess.PIPE).stdout.strip()
    if actual != expected_head:
        raise ValueError("Git HEAD differs from expected head")
    if subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=REPO_ROOT, check=True, stdout=subprocess.PIPE).stdout:
        raise ValueError("tracked worktree must be clean")
    tracked_eval_python = {
        line
        for line in subprocess.run(
            ["git", "ls-tree", "-r", "--name-only", expected_head, "--", "scripts/eval"],
            cwd=REPO_ROOT,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        ).stdout.splitlines()
        if line.endswith(".py")
    }
    live_eval_python = {
        str(path.relative_to(REPO_ROOT))
        for path in (REPO_ROOT / "scripts/eval").rglob("*.py")
    }
    shadows = sorted(live_eval_python - tracked_eval_python)
    if shadows:
        raise ValueError(
            "untracked scripts/eval Python shadow(s) must be removed: "
            + ", ".join(shadows)
        )
    result = {}
    for label, path in (("scanner_sha256", SCRIPT_PATH), ("contract_sha256", contract_path.resolve()), ("replay_backend_sha256", REPO_ROOT / REPLAY_BACKEND_PATH), ("multilingual_validator_sha256", REPO_ROOT / V2_PATH_RELATIVE), ("replay_inventory_sha256", REPO_ROOT / REPLAY_INVENTORY_PATH_RELATIVE), ("replay_normalizer_sha256", REPO_ROOT / REPLAY_NORMALIZER_PATH_RELATIVE)):
        relative = path.relative_to(REPO_ROOT)
        committed = subprocess.run(["git", "show", f"{expected_head}:{relative}"], cwd=REPO_ROOT, check=True, stdout=subprocess.PIPE).stdout
        live = path.read_bytes()
        if committed != live:
            raise ValueError(f"committed {label} differs from live bytes")
        result[label] = sha256_bytes(live)
    if result["replay_backend_sha256"] != REPLAY_BACKEND_SHA256:
        raise ValueError("replay backend dependency hash changed")
    if result["multilingual_validator_sha256"] != V2_SHA256:
        raise ValueError("multilingual validator dependency hash changed")
    if result["replay_inventory_sha256"] != REPLAY_INVENTORY_SHA256:
        raise ValueError("replay inventory dependency hash changed")
    if result["replay_normalizer_sha256"] != REPLAY_NORMALIZER_SHA256:
        raise ValueError("replay normalizer dependency hash changed")
    return result


def require_git_ancestor(ancestor: Any, descendant: str, label: str) -> None:
    if not isinstance(ancestor, str) or not re.fullmatch(r"[0-9a-f]{40}", ancestor):
        raise ValueError(f"{label} producing Git head is invalid")
    result = subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, descendant], cwd=REPO_ROOT)
    if result.returncode != 0:
        raise ValueError(f"{label} producing Git head is not an ancestor")


PRODUCER_CONTROL_PATHS = {
    "scanner_sha256": "scripts/eval/scan_eg1_multilingual_development_leakage.py",
    "replay_backend_sha256": REPLAY_BACKEND_PATH,
    "multilingual_validator_sha256": V2_PATH_RELATIVE,
    "replay_inventory_sha256": REPLAY_INVENTORY_PATH_RELATIVE,
    "replay_normalizer_sha256": REPLAY_NORMALIZER_PATH_RELATIVE,
}


def _git_blob_bytes(commit: str, relative: str) -> bytes:
    try:
        entry = subprocess.run(
            ["git", "ls-tree", commit, "--", relative],
            cwd=REPO_ROOT,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout.strip()
        metadata, separator, observed_path = entry.partition("\t")
        mode, kind, _object_id = metadata.split()
        if (
            separator != "\t"
            or observed_path != relative
            or kind != "blob"
            or mode not in {"100644", "100755"}
        ):
            raise ValueError
        return subprocess.run(
            ["git", "show", f"{commit}:{relative}"],
            cwd=REPO_ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        raise ValueError(f"producer control is not a regular committed blob: {relative}") from error


def authenticate_producing_closure(
    receipt: dict[str, Any],
    *,
    producing_head: str,
    expected_head: str,
    contract_relative: str,
) -> dict[str, Any]:
    """Authenticate historical code without comparing it to descendant live files."""
    require_git_ancestor(producing_head, expected_head, "scanner")
    paths = {"contract_sha256": contract_relative, **PRODUCER_CONTROL_PATHS}
    blobs = {relative: _git_blob_bytes(producing_head, relative) for relative in paths.values()}
    controls = {
        label: sha256_bytes(blobs[relative]) for label, relative in paths.items()
    }
    if receipt.get("contract_sha256") != controls["contract_sha256"]:
        raise ValueError("receipt contract hash does not match producer closure")
    provenance = receipt.get("scanner_provenance")
    provenance_fields = {
        "scanner_id",
        "scanner_path",
        "scanner_sha256",
        "replay_backend_path",
        "replay_backend_sha256",
        "replay_inventory_path",
        "replay_inventory_sha256",
        "replay_normalizer_path",
        "replay_normalizer_sha256",
        "multilingual_validator_path",
        "multilingual_validator_sha256",
        "producing_git_head",
        "execution_status",
        "operator_attested_execution",
        "assurance_scope",
    }
    expected_provenance = {
        "scanner_id": SCHEMA_VERSION,
        "scanner_path": PRODUCER_CONTROL_PATHS["scanner_sha256"],
        "scanner_sha256": controls["scanner_sha256"],
        "replay_backend_path": REPLAY_BACKEND_PATH,
        "replay_backend_sha256": controls["replay_backend_sha256"],
        "replay_inventory_path": REPLAY_INVENTORY_PATH_RELATIVE,
        "replay_inventory_sha256": controls["replay_inventory_sha256"],
        "replay_normalizer_path": REPLAY_NORMALIZER_PATH_RELATIVE,
        "replay_normalizer_sha256": controls["replay_normalizer_sha256"],
        "multilingual_validator_path": V2_PATH_RELATIVE,
        "multilingual_validator_sha256": controls["multilingual_validator_sha256"],
        "producing_git_head": producing_head,
        "execution_status": receipt.get("status"),
        "operator_attested_execution": False,
        "assurance_scope": "development_only_nonrelease",
    }
    if (
        not isinstance(provenance, dict)
        or set(provenance) != provenance_fields
        or provenance != expected_provenance
    ):
        raise ValueError("receipt scanner provenance does not match producer closure")
    try:
        contract = read_json_bytes(blobs[contract_relative], "producer scanner contract")
    except ValueError as error:
        raise ValueError("producer scanner contract is invalid") from error
    bindings = {
        "replay_backend_binding": (
            REPLAY_BACKEND_PATH,
            controls["replay_backend_sha256"],
        ),
        "multilingual_validator_binding": (
            V2_PATH_RELATIVE,
            controls["multilingual_validator_sha256"],
        ),
        "replay_inventory_binding": (
            REPLAY_INVENTORY_PATH_RELATIVE,
            controls["replay_inventory_sha256"],
        ),
        "replay_normalizer_binding": (
            REPLAY_NORMALIZER_PATH_RELATIVE,
            controls["replay_normalizer_sha256"],
        ),
    }
    for field, (path, digest) in bindings.items():
        if not isinstance(contract, dict) or contract.get(field) != {
            "path": path,
            "sha256": digest,
        }:
            raise ValueError(f"producer scanner contract {field} is stale")
    return {"controls": controls, "blobs": blobs}


HISTORICAL_VERIFY_CHILD = r'''
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys

scanner_path, config_path, result_path = map(Path, sys.argv[1:4])
config = json.loads(config_path.read_text(encoding="utf-8"))
receipt_path = Path(config["receipt_path"])
receipt_sha256 = hashlib.sha256(receipt_path.read_bytes()).hexdigest()
result = {"receipt_sha256": receipt_sha256}
try:
    spec = importlib.util.spec_from_file_location("eg1_historical_scanner", scanner_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("historical scanner loader is unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules["eg1_historical_scanner"] = module
    spec.loader.exec_module(module)
    sources = {
        (row["role"], row["name"]): Path(row["path"])
        for row in config["sources"]
    }
    source_receipts = {
        (row["role"], row["name"]): Path(row["path"])
        for row in config["source_receipts"]
    }
    module.verify_receipt(
        receipt_path,
        contract_path=Path(config["contract_path"]),
        benchmark_path=Path(config["benchmark_path"]),
        sources=sources,
        inventory_path=Path(config["inventory_path"]),
        source_receipt_paths=source_receipts,
        blocked_registry_receipt_path=Path(config["blocked_registry_receipt_path"]),
        expected_head=config["expected_head"],
        model_dir=(Path(config["model_dir"]) if config["model_dir"] else None),
    )
    result.update({"status": "verified", "error": None})
except BaseException as error:
    result.update({"status": "error", "error": str(error)})
payload = (json.dumps(result, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
descriptor = os.open(result_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "wb") as handle:
    handle.write(payload)
    handle.flush()
    os.fsync(handle.fileno())
'''


def run_historical_receipt_verification(
    *,
    producing_head: str,
    producer_closure: dict[str, Any],
    contract_relative: str,
    receipt_path: Path,
    benchmark_path: Path,
    sources: dict[tuple[str, str], Path],
    inventory_path: Path,
    source_receipt_paths: dict[tuple[str, str], Path],
    blocked_registry_receipt_path: Path,
    blocked_bundle_paths: Sequence[Path],
    model_dir: Path | None,
    evidence_captures: dict[str, bytes],
    model_fingerprint: dict[str, str] | None,
    receipt_sha256: str,
) -> None:
    temporary_root = Path(tempfile.mkdtemp(prefix="eg1-historical-scanner-"))
    os.chmod(temporary_root, 0o700)
    clone = temporary_root / "producer"
    config_path = temporary_root / "config.json"
    result_path = temporary_root / "result.json"
    try:
        subprocess.run(
            ["git", "clone", "--shared", "--no-checkout", "--quiet", str(REPO_ROOT), str(clone)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        subprocess.run(
            ["git", "-c", "advice.detachedHead=false", "checkout", "--detach", "--quiet", producing_head],
            cwd=clone,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        for relative, expected_bytes in producer_closure["blobs"].items():
            checked_out = clone / relative
            if (
                checked_out.is_symlink()
                or not checked_out.is_file()
                or checked_out.read_bytes() != expected_bytes
            ):
                raise ValueError(f"producer checkout differs from authenticated blob: {relative}")
        evidence_root = temporary_root / "evidence"
        evidence_root.mkdir(mode=0o700)
        snapshot_paths: dict[Path, Path] = {}

        def materialize(path: Path) -> Path:
            resolved = path.resolve()
            existing = snapshot_paths.get(resolved)
            if existing is not None:
                return existing
            data = evidence_captures.get(str(resolved))
            if data is None:
                raise ValueError(f"historical evidence was not captured: {resolved.name}")
            target = evidence_root / f"{len(snapshot_paths):04d}-{resolved.name}"
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            snapshot_paths[resolved] = target
            return target

        blocked_snapshot_root = evidence_root / "blocked-bundle"
        blocked_snapshot_root.mkdir(mode=0o700)
        for sibling in blocked_bundle_paths:
            resolved = sibling.resolve()
            data = evidence_captures.get(str(resolved))
            if data is None:
                raise ValueError(
                    f"blocked-registry dependency was not captured: {sibling.name}"
                )
            target = blocked_snapshot_root / sibling.name
            descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            snapshot_paths[resolved] = target

        model_snapshot: Path | None = None
        if model_dir is not None:
            if model_fingerprint is None:
                raise ValueError("historical model fingerprint is missing")
            model_snapshot = temporary_root / "model"
            model_snapshot.mkdir(mode=0o700)
            for relative, expected_digest in model_fingerprint.items():
                source = model_dir / relative
                target = model_snapshot / relative
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                shutil.copyfile(source, target)
                os.chmod(target, 0o400)
                if sha256_file(target) != expected_digest:
                    raise ValueError(
                        f"embedding model changed while snapshotting: {relative}"
                    )
        config = {
            "receipt_path": str(materialize(receipt_path)),
            "contract_path": str((clone / contract_relative).resolve()),
            "benchmark_path": str(materialize(benchmark_path)),
            "sources": [
                {"role": role, "name": name, "path": str(materialize(path))}
                for (role, name), path in sorted(sources.items())
            ],
            "inventory_path": str(materialize(inventory_path)),
            "source_receipts": [
                {"role": role, "name": name, "path": str(materialize(path))}
                for (role, name), path in sorted(source_receipt_paths.items())
            ],
            "blocked_registry_receipt_path": str(materialize(blocked_registry_receipt_path)),
            "expected_head": producing_head,
            "model_dir": str(model_snapshot) if model_snapshot is not None else None,
        }
        descriptor = os.open(config_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(canonical_json(config))
            handle.flush()
            os.fsync(handle.fileno())
        completed = subprocess.run(
            [
                sys.executable,
                "-I",
                "-c",
                HISTORICAL_VERIFY_CHILD,
                str(clone / PRODUCER_CONTROL_PATHS["scanner_sha256"]),
                str(config_path),
                str(result_path),
            ],
            cwd=clone,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode != 0 or not result_path.is_file() or result_path.is_symlink():
            raise ValueError("historical scanner subprocess failed closed")
        result = read_json(result_path, "historical scanner result")
        if (
            not isinstance(result, dict)
            or set(result) != {"status", "error", "receipt_sha256"}
            or result.get("receipt_sha256") != receipt_sha256
        ):
            raise ValueError("historical scanner result binding is invalid")
        if result.get("status") != "verified" or result.get("error") is not None:
            error = result.get("error")
            if not isinstance(error, str) or not error:
                error = "historical scanner rejected the receipt"
            raise ValueError(error)
    finally:
        try:
            shutil.rmtree(temporary_root)
        except OSError as error:
            raise ValueError(
                "historical scanner temporary evidence cleanup failed"
            ) from error


def validate_blocked_receipt_path(blocked_path: Path, blocked_bytes: bytes, sources: Sequence[v2.LeakageSource], expected_head: str) -> None:
    """v2 needs sibling paths, so reopen only for validation and prove bytes stayed captured."""
    receipt = read_json_bytes(blocked_bytes, "blocked registry receipt")
    require_git_ancestor(receipt.get("execution_git_head"), expected_head, "blocked registry receipt")
    if blocked_path.read_bytes() != blocked_bytes:
        raise ValueError("blocked registry receipt changed before v2 validation")
    try:
        v2.validate_blocked_registry_receipt(blocked_path, sources=sources)
    except v2.BenchmarkValidationError as error:
        raise ValueError("blocked registry receipt is invalid") from error
    if blocked_path.read_bytes() != blocked_bytes:
        raise ValueError("blocked registry receipt changed during v2 validation")


def validate_source_evidence(inventory_path: Path, receipt_paths: dict[tuple[str, str], Path], sources: dict[tuple[str, str], Path], expected_head: str, captures: dict[str, bytes] | None = None) -> None:
    get = (lambda path: captured(captures, path)) if captures is not None else (lambda path: path.read_bytes())
    inventory = read_json_bytes(get(inventory_path), "source inventory")
    inventory_fields = {"schema_version", "status", "inventory_id", "producing_git_head", "operator_attested_exhaustive", "candidate_model_output_seen", "assurance_scope", "sources"}
    if not isinstance(inventory, dict) or set(inventory) != inventory_fields or inventory.get("schema_version") != LEAKAGE_INVENTORY_SCHEMA or inventory.get("status") != "exhaustive_source_inventory_operator_attested" or inventory.get("operator_attested_exhaustive") is not True or inventory.get("candidate_model_output_seen") is not False or inventory.get("assurance_scope") != ASSURANCE_SCOPE or not isinstance(inventory.get("inventory_id"), str) or not v2.IDENTIFIER_RE.fullmatch(inventory["inventory_id"]):
        raise ValueError("source inventory is not operator-attested exhaustive")
    entries = inventory.get("sources")
    if not isinstance(entries, list):
        raise ValueError("source inventory sources are missing")
    require_git_ancestor(inventory.get("producing_git_head"), expected_head, "source inventory")
    inventory_map = {(row.get("role"), row.get("name")): row for row in entries if isinstance(row, dict)}
    if len(entries) != len(inventory_map) or set(inventory_map) != set(sources) or set(receipt_paths) != set(sources) or {role for role, _ in sources} != set(v2.REQUIRED_FROZEN_LEAKAGE_ROLES):
        raise ValueError("source evidence identities differ from sources")
    for key, source_path in sources.items():
        source_sha = sha256_bytes(get(source_path))
        count = len(read_records_bytes(get(source_path), f"source {key}"))
        entry = inventory_map[key]
        if set(entry) != {"role", "name", "sha256", "record_count", "producer_receipt_sha256"}:
            raise ValueError(f"source inventory entry schema changed: {key}")
        if entry.get("sha256") != source_sha or entry.get("record_count") != count:
            raise ValueError(f"source inventory binding is stale: {key}")
        receipt_path = receipt_paths[key]
        receipt = read_json_bytes(get(receipt_path), f"source receipt {key}")
        require_git_ancestor(receipt.get("producing_git_head"), expected_head, f"source receipt {key}")
        receipt_fields = {"schema_version", "status", "role", "name", "source_sha256", "record_count", "producing_git_head", "producer_id", "operator_attested_exhaustive", "candidate_model_output_seen", "assurance_scope"}
        expected = {"schema_version": LEAKAGE_SOURCE_RECEIPT_SCHEMA, "status": "exhaustive_source_operator_attested", "role": key[0], "name": key[1], "source_sha256": source_sha, "record_count": count, "producing_git_head": receipt.get("producing_git_head"), "producer_id": receipt.get("producer_id"), "operator_attested_exhaustive": True, "candidate_model_output_seen": False, "assurance_scope": ASSURANCE_SCOPE}
        if set(receipt) != receipt_fields or receipt != expected or not isinstance(receipt.get("producer_id"), str) or not v2.IDENTIFIER_RE.fullmatch(receipt["producer_id"]):
            raise ValueError(f"source receipt binding is stale: {key}")
        if entry.get("producer_receipt_sha256") != sha256_bytes(get(receipt_path)):
            raise ValueError(f"source inventory receipt hash is stale: {key}")


def scan(*, contract: dict[str, Any], benchmark_rows: Sequence[dict[str, Any]], sources: dict[tuple[str, str], Path], backend_name: str, embedding_backend: EmbeddingBackend, source_bytes: dict[tuple[str, str], bytes] | None = None) -> tuple[list[dict[str, Any]], str]:
    candidate_inputs, candidate_outputs = text_sides(benchmark_rows, "benchmark")
    candidate_texts = candidate_inputs + candidate_outputs
    if not candidate_texts:
        raise ValueError("benchmark has no scannable text")
    results = []
    synthetic_thresholds = contract["synthetic_test_only_thresholds"]
    for (role, name), path in sorted(sources.items()):
        value = source_bytes[(role, name)] if source_bytes is not None else path.read_bytes()
        rows = read_records_bytes(value, f"{role}:{name}")
        texts = extract_texts(rows)
        source = {"role": role, "name": name, "sha256": sha256_bytes(value), "record_count": len(rows), "authenticated_raw_text_count": len(texts)}
        methods: dict[str, Any] = {}
        if role in REGISTRY_ROLES:
            if texts:
                raise ValueError(f"{role}:{name} registry unexpectedly contains raw text")
            registry_values = {str(value) for row in rows for value in row.values() if isinstance(value, str)}
            if role == "blocked_text_hash_registry":
                candidate_values = {
                    sha256_bytes(v2.normalize_text(value).encode("utf-8"))
                    for value in candidate_texts
                }
            else:
                candidate_values = {
                    str(row["semantic_family_id"])
                    for row in benchmark_rows
                    if isinstance(row.get("semantic_family_id"), str)
                }
            matches = candidate_values & registry_values
            methods["exact_normalized"] = {"status": "passed" if not matches else "failed", "matches": len(matches)}
            for method in METHODS[1:]:
                methods[method] = {"status": "not_applicable_no_raw_text", "authenticated_raw_text_count": 0}
        elif role in RAW_ROLES:
            if not texts:
                raise ValueError(f"{role}:{name} has no authenticated raw text")
            normalized_candidates = [v2.normalize_text(value) for value in candidate_texts]
            normalized_sources = [v2.normalize_text(value) for value in texts]
            exact = set(normalized_candidates) & set(normalized_sources)
            exact_violations = sum(left == right for left in normalized_candidates for right in normalized_sources)
            thresholds = synthetic_thresholds if backend_name == "synthetic_test_only" else {method: None for method in METHODS[1:]}
            source_inputs, source_outputs = text_sides(rows, role)
            embedding_axes = {
                "input_input": cosine_stats(candidate_inputs, source_inputs, embedding_backend, thresholds["embedding_cosine"]),
                "output_output": cosine_stats(candidate_outputs, source_outputs, embedding_backend, thresholds["embedding_cosine"]),
                "input_output": cosine_stats(candidate_inputs, source_outputs, embedding_backend, thresholds["embedding_cosine"]),
                "output_input": cosine_stats(candidate_outputs, source_inputs, embedding_backend, thresholds["embedding_cosine"]),
            }
            embedding_axis_counts = {
                "input_input": len(candidate_inputs) * len(source_inputs),
                "output_output": len(candidate_outputs) * len(source_outputs),
                "input_output": len(candidate_inputs) * len(source_outputs),
                "output_input": len(candidate_outputs) * len(source_inputs),
            }
            scores = {
                "token_ngram_jaccard": pairwise_jaccard_stats(candidate_texts, texts, width=contract["token_ngram_width"], characters=False, threshold=thresholds["token_ngram_jaccard"]),
                "character_ngram_jaccard": pairwise_jaccard_stats(candidate_texts, texts, width=contract["character_ngram_width"], characters=True, threshold=thresholds["character_ngram_jaccard"]),
                "embedding_cosine": (max(value[0] for value in embedding_axes.values()), None if backend_name == "production" else sum(value[1] or 0 for value in embedding_axes.values())),
            }
            comparisons = len(candidate_texts) * len(texts)
            methods["exact_normalized"] = {"status": "passed" if not exact else "failed", "matches": len(exact), "comparison_count": comparisons, "violation_count": exact_violations}
            for method, (score, violation_count) in scores.items():
                if backend_name == "production":
                    status, threshold = "calibration_required", None
                else:
                    threshold = synthetic_thresholds[method]
                    status = threshold_status(score, threshold)
                methods[method] = {"status": status, "maximum_score": round(score, 8), "threshold": threshold, "comparison_count": comparisons, "violation_count": violation_count}
                if method == "embedding_cosine":
                    methods[method]["comparison_count"] = len(candidate_inputs) * len(source_inputs) + len(candidate_outputs) * len(source_outputs) + len(candidate_inputs) * len(source_outputs) + len(candidate_outputs) * len(source_inputs)
                    methods[method]["axes"] = {axis: {"maximum_score": round(values[0], 8), "violation_count": values[1], "comparison_count": embedding_axis_counts[axis]} for axis, values in embedding_axes.items()}
        else:
            raise ValueError(f"unsupported leakage role: {role}")
        results.append({"source": source, "methods": methods})
    all_exact = all(row["methods"]["exact_normalized"]["status"] == "passed" for row in results)
    if backend_name == "production":
        overall = "calibration_required_noncertifying" if all_exact else "failed"
    else:
        statuses = [method["status"] for row in results for method in row["methods"].values()]
        overall = "synthetic_not_quality_evidence" if all(value in {"passed", "not_applicable_no_raw_text"} for value in statuses) else "failed"
    return results, overall


def build_expected_receipt(*, backend_name: str, status: str, benchmark_bytes: bytes, benchmark_rows: Sequence[dict[str, Any]], contract_bytes: bytes, inventory_bytes: bytes, blocked_receipt_bytes: bytes, controls: dict[str, str], expected_head: str, tree: dict[str, Any] | None, runtime_versions: dict[str, str], results: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "schema_version": RECEIPT_SCHEMA_VERSION,
        "status": status,
        "backend": backend_name,
        "benchmark_sha256": sha256_bytes(benchmark_bytes),
        "benchmark_content_sha256": v2.benchmark_content_sha256(benchmark_rows),
        "contract_sha256": sha256_bytes(contract_bytes),
        "source_inventory_sha256": sha256_bytes(inventory_bytes),
        "blocked_registry_receipt_sha256": sha256_bytes(blocked_receipt_bytes),
        "scanner_provenance": {"scanner_id": SCHEMA_VERSION, "scanner_path": str(SCRIPT_PATH.relative_to(REPO_ROOT)), "scanner_sha256": controls["scanner_sha256"], "replay_backend_path": REPLAY_BACKEND_PATH, "replay_backend_sha256": controls["replay_backend_sha256"], "replay_inventory_path": REPLAY_INVENTORY_PATH_RELATIVE, "replay_inventory_sha256": controls["replay_inventory_sha256"], "replay_normalizer_path": REPLAY_NORMALIZER_PATH_RELATIVE, "replay_normalizer_sha256": controls["replay_normalizer_sha256"], "multilingual_validator_path": V2_PATH_RELATIVE, "multilingual_validator_sha256": controls["multilingual_validator_sha256"], "producing_git_head": expected_head, "execution_status": status, "operator_attested_execution": False, "assurance_scope": "development_only_nonrelease"},
        "embedding_runtime": {"model_tree": tree, "runtime_versions": runtime_versions},
        "results": results,
        "contains_raw_text": False,
    }


def publish_receipt(out: Path, receipt_bytes: bytes, prepublication_check: Any) -> None:
    if not out.parent.is_dir():
        raise ValueError("output bundle parent must already exist")
    reserved = False
    try:
        out.mkdir()
        reserved = True
        prepublication_check()
        receipt_path = out / "receipt.json"
        with receipt_path.open("xb") as handle:
            handle.write(receipt_bytes)
            handle.flush()
            os.fsync(handle.fileno())
        directory = os.open(out, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except Exception:
        if reserved and out.exists():
            for child in out.iterdir():
                child.unlink()
            out.rmdir()
        raise


def verify_receipt(
    receipt_path: Path,
    *,
    contract_path: Path,
    benchmark_path: Path,
    sources: dict[tuple[str, str], Path],
    inventory_path: Path,
    source_receipt_paths: dict[tuple[str, str], Path],
    blocked_registry_receipt_path: Path,
    expected_head: str,
    model_dir: Path | None,
) -> dict[str, Any]:
    """Recompute all scanner-controlled fields and reject non-certifying evidence."""
    blocked_bundle_paths = regular_sibling_files(blocked_registry_receipt_path)
    watched = list(dict.fromkeys([receipt_path, contract_path, benchmark_path, inventory_path, blocked_registry_receipt_path, *blocked_bundle_paths, *sources.values(), *source_receipt_paths.values()]))
    captures = capture_files(watched)
    contract = validate_contract(read_json_bytes(captured(captures, contract_path), "scanner contract"))
    receipt = read_json_bytes(captured(captures, receipt_path), "leakage receipt")
    receipt_fields = {"schema_version", "status", "backend", "benchmark_sha256", "benchmark_content_sha256", "contract_sha256", "source_inventory_sha256", "blocked_registry_receipt_sha256", "scanner_provenance", "embedding_runtime", "results", "contains_raw_text"}
    if not isinstance(receipt, dict) or set(receipt) != receipt_fields or receipt.get("schema_version") != RECEIPT_SCHEMA_VERSION or receipt.get("contains_raw_text") is not False:
        raise ValueError("leakage receipt schema is invalid")
    provenance = receipt.get("scanner_provenance")
    producing_head = provenance.get("producing_git_head") if isinstance(provenance, dict) else None
    controls = validate_git_controls(expected_head, contract_path)
    require_git_ancestor(producing_head, expected_head, "scanner")
    if producing_head != expected_head:
        try:
            contract_relative = str(
                contract_path.resolve().relative_to(REPO_ROOT.resolve())
            )
        except ValueError as error:
            raise ValueError("scanner contract must be inside the repository") from error
        producer_closure = authenticate_producing_closure(
            receipt,
            producing_head=producing_head,
            expected_head=expected_head,
            contract_relative=contract_relative,
        )
        backend_name = receipt.get("backend")
        if backend_name not in {"production", "synthetic_test_only"}:
            raise ValueError("receipt backend is invalid")
        if backend_name == "production" and model_dir is None:
            raise ValueError("production receipt verification requires model_dir")
        model_before = model_file_fingerprint(model_dir) if model_dir is not None else None
        verification_error: BaseException | None = None
        try:
            run_historical_receipt_verification(
                producing_head=producing_head,
                producer_closure=producer_closure,
                contract_relative=contract_relative,
                receipt_path=receipt_path,
                benchmark_path=benchmark_path,
                sources=sources,
                inventory_path=inventory_path,
                source_receipt_paths=source_receipt_paths,
                blocked_registry_receipt_path=blocked_registry_receipt_path,
                blocked_bundle_paths=blocked_bundle_paths,
                model_dir=model_dir,
                evidence_captures=captures,
                model_fingerprint=model_before,
                receipt_sha256=sha256_bytes(captured(captures, receipt_path)),
            )
        except BaseException as error:
            verification_error = error
        mutation_errors: list[str] = []
        if capture_files(watched) != captures:
            mutation_errors.append("leakage evidence changed during historical verification")
        try:
            if validate_git_controls(expected_head, contract_path) != controls:
                mutation_errors.append("current scanner controls changed during historical verification")
            if (
                authenticate_producing_closure(
                    receipt,
                    producing_head=producing_head,
                    expected_head=expected_head,
                    contract_relative=contract_relative,
                )
                != producer_closure
            ):
                mutation_errors.append("producer closure changed during historical verification")
        except BaseException as error:
            mutation_errors.append(f"scanner closure changed during historical verification: {error}")
        if model_dir is not None and model_file_fingerprint(model_dir) != model_before:
            mutation_errors.append("embedding model tree changed during historical verification")
        if mutation_errors:
            raise ValueError("; ".join(mutation_errors)) from verification_error
        if verification_error is not None:
            raise verification_error
        return receipt
    validate_source_evidence(inventory_path, source_receipt_paths, sources, expected_head, captures)
    backend_name = receipt.get("backend")
    if backend_name not in {"production", "synthetic_test_only"}:
        raise ValueError("receipt backend is invalid")
    if backend_name == "production":
        if model_dir is None:
            raise ValueError("production receipt verification requires model_dir")
        tree = model_tree_receipt(model_dir)
        expected_tree = {key: contract["embedding"][key] for key in ("tree_sha256", "file_count", "total_bytes")}
        if tree != expected_tree:
            raise ValueError("local embedding model tree changed")
        embedding_backend: EmbeddingBackend = LocalSentenceTransformerBackend(model_dir, contract["embedding"])
    else:
        tree = None
        embedding_backend = SyntheticEmbeddingBackend()
    rows = read_records_bytes(captured(captures, benchmark_path), "benchmark")
    source_bytes = {key: captured(captures, path) for key, path in sources.items()}
    results, status = scan(contract=contract, benchmark_rows=rows, sources=sources, backend_name=backend_name, embedding_backend=embedding_backend, source_bytes=source_bytes)
    blocked_sources = [v2.LeakageSource(role, name, path, sha256_bytes(source_bytes[(role, name)])) for (role, name), path in sorted(sources.items())]
    validate_blocked_receipt_path(blocked_registry_receipt_path, captured(captures, blocked_registry_receipt_path), blocked_sources, expected_head)
    expected = build_expected_receipt(backend_name=backend_name, status=status, benchmark_bytes=captured(captures, benchmark_path), benchmark_rows=rows, contract_bytes=captured(captures, contract_path), inventory_bytes=captured(captures, inventory_path), blocked_receipt_bytes=captured(captures, blocked_registry_receipt_path), controls=controls, expected_head=producing_head, tree=tree, runtime_versions=embedding_backend.runtime_versions, results=results)
    if receipt != expected:
        raise ValueError("leakage receipt recomputation differs")
    if capture_files(watched) != captures or validate_git_controls(expected_head, contract_path) != controls:
        raise ValueError("leakage evidence changed during verification")
    if model_dir is not None and model_tree_receipt(model_dir) != tree:
        raise ValueError("embedding model tree changed during verification")
    if status != "all_required_methods_passed":
        raise ValueError(f"leakage receipt is non-certifying: {status}")
    return receipt


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument("--benchmark", required=True, type=Path)
    parser.add_argument("--source", action="append", required=True)
    parser.add_argument("--source-inventory", required=True, type=Path)
    parser.add_argument("--source-receipt", action="append", required=True)
    parser.add_argument("--blocked-registry-receipt", required=True, type=Path)
    parser.add_argument("--model-dir", type=Path)
    parser.add_argument("--out-bundle", required=True, type=Path)
    parser.add_argument("--expected-git-head", required=True)
    parser.add_argument("--backend", choices=("production", "synthetic_test_only"), required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    sources = parse_bound_specs(args.source, "source")
    receipts = parse_bound_specs(args.source_receipt, "source receipt")
    watched = [args.contract, args.benchmark, args.source_inventory, args.blocked_registry_receipt, *sources.values(), *receipts.values()]
    captures = capture_files(watched)
    contract = validate_contract(read_json_bytes(captured(captures, args.contract), "scanner contract"))
    validate_source_evidence(args.source_inventory, receipts, sources, args.expected_git_head, captures)
    parsed_sources = [v2.LeakageSource(role, name, path, sha256_bytes(captured(captures, path))) for (role, name), path in sorted(sources.items())]
    validate_blocked_receipt_path(args.blocked_registry_receipt, captured(captures, args.blocked_registry_receipt), parsed_sources, args.expected_git_head)
    benchmark_rows = read_records_bytes(captured(captures, args.benchmark), "benchmark")
    execution_head = args.expected_git_head
    controls = validate_git_controls(execution_head, args.contract)
    if args.backend == "production":
        if args.model_dir is None:
            raise ValueError("production backend requires --model-dir")
        tree = model_tree_receipt(args.model_dir)
        expected_tree = {key: contract["embedding"][key] for key in ("tree_sha256", "file_count", "total_bytes")}
        if tree != expected_tree:
            raise ValueError("local embedding model tree changed")
        embedding_backend: EmbeddingBackend = LocalSentenceTransformerBackend(args.model_dir, contract["embedding"])
    else:
        tree = None
        embedding_backend = SyntheticEmbeddingBackend()
    source_bytes = {key: captured(captures, path) for key, path in sources.items()}
    results, status = scan(contract=contract, benchmark_rows=benchmark_rows, sources=sources, backend_name=args.backend, embedding_backend=embedding_backend, source_bytes=source_bytes)
    if capture_files(watched) != captures or validate_git_controls(execution_head, args.contract) != controls:
        raise ValueError("leakage evidence changed during scan")
    if args.backend == "production" and model_tree_receipt(args.model_dir) != tree:
        raise ValueError("embedding model tree changed during scan")
    out = args.out_bundle.resolve()
    if out.exists():
        raise ValueError("output bundle already exists")
    try:
        relative_out = out.relative_to(REPO_ROOT)
    except ValueError as error:
        raise ValueError("output bundle must be inside the repository") from error
    ignored = subprocess.run(
        ["git", "check-ignore", "-q", "--", str(relative_out)],
        cwd=REPO_ROOT,
    )
    if ignored.returncode != 0:
        raise ValueError("output bundle must be ignored")
    receipt = build_expected_receipt(backend_name=args.backend, status=status, benchmark_bytes=captured(captures, args.benchmark), benchmark_rows=benchmark_rows, contract_bytes=captured(captures, args.contract), inventory_bytes=captured(captures, args.source_inventory), blocked_receipt_bytes=captured(captures, args.blocked_registry_receipt), controls=controls, expected_head=execution_head, tree=tree, runtime_versions=embedding_backend.runtime_versions, results=results)
    def prepublication_check() -> None:
        if capture_files(watched) != captures or validate_git_controls(execution_head, args.contract) != controls:
            raise ValueError("leakage evidence changed before publication")
        if args.backend == "production" and model_tree_receipt(args.model_dir) != tree:
            raise ValueError("embedding model tree changed before publication")
    publish_receipt(out, canonical_json(receipt), prepublication_check)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
