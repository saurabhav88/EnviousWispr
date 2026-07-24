#!/usr/bin/env python3
"""Build a metadata-only embedding-neighbor queue for EG-1 replay review."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
from typing import Any, Callable, Protocol, Sequence

import numpy as np

from build_eg1_replay_inventory import (
    canonical_json,
    fingerprint_row,
    rows_from_bytes,
    sha256_bytes,
)


SCRIPT_PATH = Path(__file__).resolve()
REPO_ROOT = SCRIPT_PATH.parents[2]
DEFAULT_CONTRACT = (
    REPO_ROOT / "scripts/eval/contracts/eg1_replay_semantic_screen_v1.json"
)
SCHEMA_VERSION = "eg1-replay-semantic-screen-v1"
QUEUE_SCHEMA_VERSION = "eg1-replay-semantic-review-queue-v1"
RECEIPT_SCHEMA_VERSION = "eg1-replay-semantic-screen-receipt-v1"
QUEUE_FILENAME = "semantic_review_queue.jsonl"
RECEIPT_FILENAME = "receipt.json"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SHA1_RE = re.compile(r"^[0-9a-f]{40}$")
COMPARISON_AXES = (
    "input_input",
    "output_output",
    "input_output",
    "output_input",
)


class EmbeddingBackend(Protocol):
    runtime_versions: dict[str, str]
    max_seq_length: int

    def preflight_token_lengths(self, texts: Sequence[str]) -> int: ...

    def encode_documents(self, texts: Sequence[str]) -> np.ndarray: ...


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument("--inventory-bundle", required=True, type=Path)
    parser.add_argument("--model-dir", required=True, type=Path)
    parser.add_argument("--out-bundle", required=True, type=Path)
    parser.add_argument("--expected-git-head", required=True)
    parser.add_argument("--smoke-candidates", type=int)
    return parser.parse_args()


def read_once(path: Path) -> tuple[bytes, str]:
    value = path.read_bytes()
    return value, sha256_bytes(value)


def write_exclusive(path: Path, value: bytes) -> None:
    with path.open("xb") as handle:
        written = handle.write(value)
        if written != len(value):
            raise OSError("short evidence write")
        handle.flush()
        os.fsync(handle.fileno())


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def relative_repo_path(path: Path, repo_root: Path) -> str:
    try:
        return str(path.resolve().relative_to(repo_root.resolve()))
    except ValueError as error:
        raise ValueError("bound path must be inside the repository") from error


def git_output(repo_root: Path, *arguments: str) -> bytes:
    try:
        return subprocess.run(
            ["git", *arguments],
            cwd=repo_root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError("cannot verify Git state") from error


def validate_git_state(
    expected_head: str,
    repo_root: Path,
    tracked_paths: Sequence[Path],
) -> str:
    if not SHA1_RE.fullmatch(expected_head):
        raise ValueError("expected Git HEAD must be a lowercase SHA-1")
    actual_head = git_output(repo_root, "rev-parse", "HEAD").decode().strip()
    if actual_head != expected_head:
        raise ValueError("Git HEAD differs from the predeclared commit")
    if git_output(repo_root, "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("tracked worktree must be clean before publication")
    for path in tracked_paths:
        relative = relative_repo_path(path, repo_root)
        committed = git_output(repo_root, "show", f"{actual_head}:{relative}")
        if sha256_bytes(committed) != read_once(path)[1]:
            raise ValueError(f"committed bytes differ from live file: {relative}")
    return actual_head


def git_committed_bytes(
    repo_root: Path, execution_head: str, relative_path: str
) -> bytes | None:
    try:
        return subprocess.run(
            ["git", "show", f"{execution_head}:{relative_path}"],
            cwd=repo_root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return None


def require_ignored_output(output: Path, repo_root: Path) -> None:
    try:
        relative = output.resolve().relative_to(repo_root.resolve())
    except ValueError as error:
        raise ValueError("output bundle must be inside the repository") from error
    result = subprocess.run(
        ["git", "check-ignore", "-q", "--", str(relative)],
        cwd=repo_root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise ValueError("output bundle must be covered by a repository ignore rule")


def require_private_source_untracked_ignored(path: Path, repo_root: Path) -> None:
    relative = relative_repo_path(path, repo_root)
    tracked = subprocess.run(
        ["git", "ls-files", "--error-unmatch", "--", relative],
        cwd=repo_root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    ignored = subprocess.run(
        ["git", "check-ignore", "-q", "--", relative],
        cwd=repo_root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if tracked.returncode == 0 or ignored.returncode != 0:
        raise ValueError("private semantic-screen source must stay untracked and ignored")


def require_hash(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
        raise ValueError(f"{label} must be a lowercase SHA-256")
    return value


def parse_object_bytes(value: bytes, label: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is not valid JSON") from error
    if not isinstance(parsed, dict):
        raise ValueError(f"{label} must be an object")
    return parsed


def validate_contract(contract: dict[str, Any]) -> None:
    if set(contract) != {
        "schema_version",
        "status",
        "tool_bindings",
        "inventory_binding",
        "sources",
        "embedding",
        "policy",
        "expected_counts",
    }:
        raise ValueError("semantic-screen contract schema changed")
    if contract.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("semantic-screen contract version changed")
    if contract.get("status") != "screening_only_manual_approval_required":
        raise ValueError("semantic-screen contract is not screening-only")
    policy = contract.get("policy")
    if policy != {
        "candidate_selector": "candidate_only",
        "neighbor_queue_scope": "all_candidates",
        "embedding_auto_approval": False,
        "semantic_family_approval": "pending",
        "meaning_safety_approval": "pending",
        "native_editorial_approval": "pending",
        "training_eligible": False,
        "training_export_enabled": False,
        "tracked_output_contains_private_text_or_raw_ids": False,
    }:
        raise ValueError("semantic-screen policy changed")
    expected_counts = contract.get("expected_counts")
    if not isinstance(expected_counts, dict) or set(expected_counts) != {
        "inventory_rows",
        "candidate_only_rows",
        "reference_rows",
        "full_review_queue_rows",
        "training_eligible_rows",
    }:
        raise ValueError("semantic-screen expected-count schema changed")
    if any(type(value) is not int or value < 0 for value in expected_counts.values()):
        raise ValueError("semantic-screen expected counts are invalid")
    embedding = contract.get("embedding")
    if not isinstance(embedding, dict) or set(embedding) != {
        "repo_id",
        "revision",
        "tree_sha256",
        "file_count",
        "total_bytes",
        "embedding_dimension",
        "pooling",
        "prompt_name",
        "device",
        "model_dtype",
        "output_precision",
        "normalize_embeddings",
        "max_seq_length",
        "batch_size",
        "comparison_batch_size",
        "comparison_axes",
        "score_decimals",
        "top_k",
        "runtime_versions",
    }:
        raise ValueError("semantic-screen embedding schema changed")
    if embedding.get("comparison_axes") != list(COMPARISON_AXES):
        raise ValueError("semantic-screen comparison axes changed")
    if embedding.get("pooling") != "last_token":
        raise ValueError("semantic-screen pooling changed")
    if embedding.get("prompt_name") != "document":
        raise ValueError("semantic-screen prompt changed")
    if embedding.get("normalize_embeddings") is not True:
        raise ValueError("semantic-screen embeddings must be normalized")
    for name in (
        "file_count",
        "total_bytes",
        "embedding_dimension",
        "max_seq_length",
        "batch_size",
        "comparison_batch_size",
        "score_decimals",
        "top_k",
    ):
        if type(embedding.get(name)) is not int or embedding[name] <= 0:
            raise ValueError(f"semantic-screen embedding {name} is invalid")
    require_hash(embedding.get("tree_sha256"), "embedding tree hash")
    if not isinstance(embedding.get("runtime_versions"), dict) or not embedding[
        "runtime_versions"
    ]:
        raise ValueError("semantic-screen runtime versions are invalid")


def expected_tool_binding_paths(
    repo_root: Path, script_path: Path
) -> dict[str, str]:
    return {
        "screening_builder": relative_repo_path(script_path, repo_root),
        "inventory_builder": "scripts/eval/build_eg1_replay_inventory.py",
        "inventory_normalizer": "scripts/eval/eg1_replay_normalizer_v1.py",
    }


def validate_tool_bindings(
    contract: dict[str, Any], repo_root: Path, script_path: Path
) -> dict[str, dict[str, str]]:
    bindings = contract.get("tool_bindings")
    expected_paths = expected_tool_binding_paths(repo_root, script_path)
    if not isinstance(bindings, dict) or set(bindings) != set(expected_paths):
        raise ValueError("semantic-screen tool inventory changed")
    result: dict[str, dict[str, str]] = {}
    for name, relative_path in expected_paths.items():
        binding = bindings.get(name)
        if not isinstance(binding, dict) or set(binding) != {"path", "sha256"}:
            raise ValueError("semantic-screen tool binding schema changed")
        if binding.get("path") != relative_path:
            raise ValueError(f"semantic-screen {name} path changed")
        path = repo_root / relative_path
        actual_sha = read_once(path)[1]
        if binding.get("sha256") != actual_sha:
            raise ValueError(f"semantic-screen {name} hash changed")
        result[name] = {"path": relative_path, "sha256": actual_sha}
    return result


def validate_producing_tool_bindings(
    contract: dict[str, Any],
    repo_root: Path,
    script_path: Path,
    execution_head: str,
) -> dict[str, dict[str, str]]:
    bindings = contract.get("tool_bindings")
    expected_paths = expected_tool_binding_paths(repo_root, script_path)
    if not isinstance(bindings, dict) or set(bindings) != set(expected_paths):
        raise ValueError("semantic-screen producing tool inventory changed")
    result: dict[str, dict[str, str]] = {}
    for name, relative_path in expected_paths.items():
        binding = bindings.get(name)
        if not isinstance(binding, dict) or set(binding) != {"path", "sha256"}:
            raise ValueError("semantic-screen producing tool binding schema changed")
        if binding.get("path") != relative_path:
            raise ValueError(f"semantic-screen producing {name} path changed")
        expected_sha = require_hash(
            binding.get("sha256"), f"semantic-screen producing {name} hash"
        )
        committed = git_committed_bytes(repo_root, execution_head, relative_path)
        if committed is None or sha256_bytes(committed) != expected_sha:
            raise ValueError("semantic-screen producing control binding is invalid")
        result[name] = {"path": relative_path, "sha256": expected_sha}
    return result


def validate_inventory_bundle(
    contract: dict[str, Any], inventory_bundle: Path, repo_root: Path
) -> tuple[list[dict[str, Any]], dict[str, Any], dict[str, bytes]]:
    binding = contract.get("inventory_binding")
    expected_binding_fields = {
        "bundle_path",
        "receipt_filename",
        "receipt_sha256",
        "receipt_payload_sha256",
        "execution_git_head",
        "inventory_filename",
        "inventory_sha256",
        "inventory_rows",
        "candidate_only_rows",
    }
    if not isinstance(binding, dict) or set(binding) != expected_binding_fields:
        raise ValueError("semantic-screen inventory binding schema changed")
    if relative_repo_path(inventory_bundle, repo_root) != binding.get("bundle_path"):
        raise ValueError("semantic-screen inventory bundle path changed")
    receipt_path = inventory_bundle / binding["receipt_filename"]
    inventory_path = inventory_bundle / binding["inventory_filename"]
    receipt_bytes, receipt_sha = read_once(receipt_path)
    inventory_bytes, inventory_sha = read_once(inventory_path)
    if receipt_sha != require_hash(binding.get("receipt_sha256"), "receipt hash"):
        raise ValueError("coordinator receipt differs from the semantic-screen contract")
    if inventory_sha != require_hash(binding.get("inventory_sha256"), "inventory hash"):
        raise ValueError("replay inventory differs from the semantic-screen contract")
    receipt = parse_object_bytes(receipt_bytes, "coordinator receipt")
    if receipt.get("schema_version") != "eg1-replay-inventory-v1":
        raise ValueError("coordinator receipt schema changed")
    if receipt.get("execution_git_head") != binding.get("execution_git_head"):
        raise ValueError("coordinator receipt producing commit changed")
    payload_hash = receipt.get("receipt_payload_sha256")
    payload = dict(receipt)
    payload.pop("receipt_payload_sha256", None)
    if payload_hash != sha256_bytes(canonical_json(payload)) or payload_hash != binding.get(
        "receipt_payload_sha256"
    ):
        raise ValueError("coordinator receipt payload binding is invalid")
    inventory_record = receipt.get("inventory")
    if inventory_record != {
        "path": binding["inventory_filename"],
        "sha256": inventory_sha,
        "row_count": binding["inventory_rows"],
    }:
        raise ValueError("coordinator receipt inventory binding changed")
    counts = receipt.get("observed_counts")
    if not isinstance(counts, dict) or counts.get("total_replay_rows") != binding.get(
        "inventory_rows"
    ) or counts.get("candidate_only") != binding.get("candidate_only_rows"):
        raise ValueError("coordinator receipt counts changed")
    if counts.get("training_eligible") != 0 or counts.get("unresolved") != 0:
        raise ValueError("coordinator inventory is not safely resolved")
    rows = rows_from_bytes(inventory_bytes, "replay inventory")
    if len(rows) != binding["inventory_rows"]:
        raise ValueError("replay inventory row count changed")
    expected_row_fields = {
        "row_fingerprint_sha256",
        "decision",
        "reason_codes",
        "training_eligible",
    }
    fingerprints: set[str] = set()
    candidate_count = 0
    for row_number, row in enumerate(rows, 1):
        if set(row) != expected_row_fields:
            raise ValueError(f"replay inventory row {row_number} schema changed")
        fingerprint = require_hash(
            row.get("row_fingerprint_sha256"), "inventory row fingerprint"
        )
        if fingerprint in fingerprints:
            raise ValueError("replay inventory contains duplicate fingerprints")
        fingerprints.add(fingerprint)
        if row.get("training_eligible") is not False:
            raise ValueError("replay inventory contains a training-eligible row")
        if row.get("decision") == "candidate_only":
            candidate_count += 1
    if candidate_count != binding["candidate_only_rows"]:
        raise ValueError("replay inventory candidate count changed")
    return rows, receipt, {
        str(receipt_path): receipt_bytes,
        str(inventory_path): inventory_bytes,
    }


def load_source(
    repo_root: Path, source: dict[str, Any], label: str
) -> tuple[list[dict[str, Any]], bytes, dict[str, Any]]:
    if not isinstance(source, dict) or set(source) != {
        "path",
        "sha256",
        "row_count",
        "input_field",
        "output_field",
    }:
        raise ValueError(f"{label} source binding schema changed")
    relative = source.get("path")
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        raise ValueError(f"{label} source path is invalid")
    path = repo_root / relative
    try:
        path.resolve().relative_to(repo_root.resolve())
    except ValueError as error:
        raise ValueError(f"{label} source escapes the repository") from error
    require_private_source_untracked_ignored(path, repo_root)
    value, actual_sha = read_once(path)
    if actual_sha != require_hash(source.get("sha256"), f"{label} source hash"):
        raise ValueError(f"{label} source hash changed")
    rows = rows_from_bytes(value, label)
    if len(rows) != source.get("row_count"):
        raise ValueError(f"{label} source row count changed")
    for row_number, row in enumerate(rows, 1):
        for field_name in (source["input_field"], source["output_field"]):
            if not isinstance(row.get(field_name), str) or not row[field_name].strip():
                raise ValueError(f"{label} row {row_number} text schema changed")
    return rows, value, {
        "path": relative,
        "sha256": actual_sha,
        "row_count": len(rows),
        "input_field": source["input_field"],
        "output_field": source["output_field"],
    }


def bind_inventory_to_sources(
    inventory_rows: Sequence[dict[str, Any]], replay_rows: Sequence[dict[str, Any]]
) -> list[dict[str, Any]]:
    replay_by_fingerprint: dict[str, dict[str, Any]] = {}
    for row in replay_rows:
        fingerprint = fingerprint_row(row)
        if fingerprint in replay_by_fingerprint:
            raise ValueError("replay source contains duplicate canonical rows")
        replay_by_fingerprint[fingerprint] = row
    inventory_fingerprints = {
        row["row_fingerprint_sha256"] for row in inventory_rows
    }
    if set(replay_by_fingerprint) != inventory_fingerprints:
        raise ValueError("replay source and inventory fingerprint sets differ")
    candidates = [
        replay_by_fingerprint[row["row_fingerprint_sha256"]]
        for row in inventory_rows
        if row["decision"] == "candidate_only"
    ]
    return sorted(candidates, key=fingerprint_row)


def model_tree_receipt(model_dir: Path) -> dict[str, Any]:
    files: list[dict[str, Any]] = []
    for path in sorted(value for value in model_dir.rglob("*") if value.is_file()):
        digest = hashlib.sha256()
        size = 0
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(block)
                size += len(block)
        files.append(
            {
                "path": str(path.relative_to(model_dir)),
                "sha256": digest.hexdigest(),
                "size_bytes": size,
            }
        )
    return {
        "tree_sha256": sha256_bytes(canonical_json(files)),
        "file_count": len(files),
        "total_bytes": sum(value["size_bytes"] for value in files),
    }


def validate_model_tree(contract: dict[str, Any], model_dir: Path) -> dict[str, Any]:
    expected = contract["embedding"]
    if model_dir.name != expected["revision"]:
        raise ValueError("local embedding model revision path changed")
    observed = model_tree_receipt(model_dir)
    for field in ("tree_sha256", "file_count", "total_bytes"):
        if observed[field] != expected[field]:
            raise ValueError(f"local embedding model {field} changed")
    return {
        "repo_id": expected["repo_id"],
        "revision": expected["revision"],
        **observed,
    }


class LocalSentenceTransformerBackend:
    def __init__(self, model_dir: Path, embedding: dict[str, Any]) -> None:
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        os.environ["TOKENIZERS_PARALLELISM"] = "false"
        try:
            import sentence_transformers
            from sentence_transformers import SentenceTransformer
            import torch
            import transformers
        except ImportError as error:
            raise ValueError("local embedding runtime dependencies are unavailable") from error
        self.runtime_versions = {
            "sentence_transformers": sentence_transformers.__version__,
            "transformers": transformers.__version__,
            "torch": torch.__version__,
            "numpy": np.__version__,
        }
        if self.runtime_versions != embedding["runtime_versions"]:
            raise ValueError("local embedding runtime versions changed")
        if embedding["device"] != "mps" or embedding["model_dtype"] != "float16":
            raise ValueError("unsupported local embedding execution contract")
        if not torch.backends.mps.is_available():
            raise ValueError("the pinned local MPS embedding device is unavailable")
        torch.manual_seed(0)
        torch.use_deterministic_algorithms(True)
        try:
            self.model = SentenceTransformer(
                str(model_dir),
                device="mps",
                trust_remote_code=False,
                local_files_only=True,
                model_kwargs={"torch_dtype": torch.float16},
            )
        except Exception as error:
            raise ValueError("local embedding model failed to load") from error
        self.model.eval()
        self.max_seq_length = int(self.model.max_seq_length)
        if self.max_seq_length != embedding["max_seq_length"]:
            raise ValueError("local embedding model maximum sequence length changed")
        self.batch_size = embedding["batch_size"]
        self.dimension = embedding["embedding_dimension"]

    def preflight_token_lengths(self, texts: Sequence[str]) -> int:
        maximum = 0
        try:
            for offset in range(0, len(texts), self.batch_size):
                encoded = self.model.tokenizer(
                    list(texts[offset : offset + self.batch_size]),
                    padding=False,
                    truncation=False,
                    add_special_tokens=True,
                )
                maximum = max(maximum, *(len(value) for value in encoded["input_ids"]))
        except Exception as error:
            raise ValueError("local embedding token preflight failed") from error
        if maximum > self.max_seq_length:
            raise ValueError("semantic-screen text exceeds the pinned embedding context")
        return maximum

    def encode_documents(self, texts: Sequence[str]) -> np.ndarray:
        try:
            values = self.model.encode_document(
                list(texts),
                prompt_name="document",
                batch_size=self.batch_size,
                show_progress_bar=False,
                precision="float32",
                convert_to_numpy=True,
                normalize_embeddings=True,
            )
        except Exception as error:
            raise ValueError("local embedding inference failed") from error
        result = np.asarray(values, dtype=np.float32)
        if result.shape != (len(texts), self.dimension):
            raise ValueError("local embedding output shape changed")
        norms = np.linalg.norm(result, axis=1)
        if not np.all(np.isfinite(result)) or not np.allclose(norms, 1.0, atol=1e-3):
            raise ValueError("local embedding output is invalid")
        return result


def make_review_queue(
    candidates: Sequence[dict[str, Any]],
    references: Sequence[dict[str, Any]],
    *,
    candidate_input_field: str,
    candidate_output_field: str,
    reference_input_field: str,
    reference_output_field: str,
    backend: EmbeddingBackend,
    embedding: dict[str, Any],
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    candidate_fingerprints = [fingerprint_row(row) for row in candidates]
    reference_pairs = sorted(
        ((fingerprint_row(row), row) for row in references), key=lambda value: value[0]
    )
    reference_fingerprints = [value[0] for value in reference_pairs]
    sorted_references = [value[1] for value in reference_pairs]
    candidate_inputs = [row[candidate_input_field] for row in candidates]
    candidate_outputs = [row[candidate_output_field] for row in candidates]
    reference_inputs = [row[reference_input_field] for row in sorted_references]
    reference_outputs = [row[reference_output_field] for row in sorted_references]
    text_groups = (
        candidate_inputs,
        candidate_outputs,
        reference_inputs,
        reference_outputs,
    )
    max_tokens = max(backend.preflight_token_lengths(group) for group in text_groups)
    candidate_input_vectors = backend.encode_documents(candidate_inputs)
    candidate_output_vectors = backend.encode_documents(candidate_outputs)
    reference_input_vectors = backend.encode_documents(reference_inputs)
    reference_output_vectors = backend.encode_documents(reference_outputs)
    decimals = embedding["score_decimals"]
    top_k = embedding["top_k"]
    comparison_batch_size = embedding["comparison_batch_size"]
    queue: list[dict[str, Any]] = []
    nearest_scores: list[float] = []
    for start in range(0, len(candidates), comparison_batch_size):
        stop = min(start + comparison_batch_size, len(candidates))
        matrices = (
            candidate_input_vectors[start:stop] @ reference_input_vectors.T,
            candidate_output_vectors[start:stop] @ reference_output_vectors.T,
            candidate_input_vectors[start:stop] @ reference_output_vectors.T,
            candidate_output_vectors[start:stop] @ reference_input_vectors.T,
        )
        for local_index, candidate_index in enumerate(range(start, stop)):
            component_rows = [
                np.round(
                    np.clip(matrix[local_index], -1.0, 1.0).astype(np.float64),
                    decimals,
                )
                for matrix in matrices
            ]
            maximums = np.maximum.reduce(component_rows)
            order = sorted(
                range(len(reference_fingerprints)),
                key=lambda index: (
                    -float(maximums[index]),
                    reference_fingerprints[index],
                ),
            )[:top_k]
            neighbors: list[dict[str, Any]] = []
            for reference_index in order:
                scores = {
                    axis: float(component_rows[axis_index][reference_index])
                    for axis_index, axis in enumerate(COMPARISON_AXES)
                }
                dominant = min(
                    COMPARISON_AXES,
                    key=lambda axis: (-scores[axis], COMPARISON_AXES.index(axis)),
                )
                neighbors.append(
                    {
                        "reference_row_fingerprint_sha256": reference_fingerprints[
                            reference_index
                        ],
                        "max_cosine": float(maximums[reference_index]),
                        "dominant_comparison": dominant,
                        "component_cosines": scores,
                    }
                )
            nearest_scores.append(neighbors[0]["max_cosine"])
            queue.append(
                {
                    "schema_version": QUEUE_SCHEMA_VERSION,
                    "candidate_row_fingerprint_sha256": candidate_fingerprints[
                        candidate_index
                    ],
                    "neighbors": neighbors,
                    "embedding_neighbors_ready": True,
                    "semantic_family_approval": "pending",
                    "meaning_safety_approval": "pending",
                    "native_editorial_approval": "pending",
                    "training_eligible": False,
                }
            )
    sorted_scores = sorted(nearest_scores)

    def quantile(numerator: int, denominator: int) -> float:
        if not sorted_scores:
            return 0.0
        index = math.ceil((len(sorted_scores) - 1) * numerator / denominator)
        return sorted_scores[index]

    summary = {
        "screened_candidates": len(queue),
        "reference_rows": len(references),
        "neighbors_per_candidate": top_k,
        "manual_semantic_review_pending": len(queue),
        "native_editorial_review_pending": len(queue),
        "training_eligible": 0,
        "maximum_observed_tokens": max_tokens,
        "nearest_neighbor_cosine": {
            "minimum": sorted_scores[0] if sorted_scores else 0.0,
            "p50": quantile(1, 2),
            "p90": quantile(9, 10),
            "p95": quantile(19, 20),
            "p99": quantile(99, 100),
            "maximum": sorted_scores[-1] if sorted_scores else 0.0,
            "quantile_method": "nearest_rank_ceiling_n_minus_one",
        },
    }
    return queue, summary


def validate_queue_rows(
    rows: Sequence[dict[str, Any]],
    *,
    expected_candidate_fingerprints: Sequence[str],
    valid_reference_fingerprints: set[str],
    top_k: int,
    score_decimals: int,
) -> None:
    allowed_axes = set(COMPARISON_AXES)
    fingerprints: set[str] = set()
    for row_number, row in enumerate(rows, 1):
        if set(row) != {
            "schema_version",
            "candidate_row_fingerprint_sha256",
            "neighbors",
            "embedding_neighbors_ready",
            "semantic_family_approval",
            "meaning_safety_approval",
            "native_editorial_approval",
            "training_eligible",
        }:
            raise ValueError(f"semantic-review queue row {row_number} schema changed")
        if row.get("schema_version") != QUEUE_SCHEMA_VERSION:
            raise ValueError("semantic-review queue schema version changed")
        fingerprint = require_hash(
            row.get("candidate_row_fingerprint_sha256"), "candidate fingerprint"
        )
        if fingerprint in fingerprints:
            raise ValueError("semantic-review queue contains duplicate candidates")
        fingerprints.add(fingerprint)
        if (
            row.get("embedding_neighbors_ready") is not True
            or row.get("semantic_family_approval") != "pending"
            or row.get("meaning_safety_approval") != "pending"
            or row.get("native_editorial_approval") != "pending"
            or row.get("training_eligible") is not False
        ):
            raise ValueError("semantic-review queue fabricates an approval")
        neighbors = row.get("neighbors")
        if not isinstance(neighbors, list) or len(neighbors) != top_k:
            raise ValueError("semantic-review queue neighbor count changed")
        neighbor_fingerprints: set[str] = set()
        prior_key: tuple[float, str] | None = None
        for neighbor in neighbors:
            if not isinstance(neighbor, dict) or set(neighbor) != {
                "reference_row_fingerprint_sha256",
                "max_cosine",
                "dominant_comparison",
                "component_cosines",
            }:
                raise ValueError("semantic-review queue neighbor schema changed")
            reference = require_hash(
                neighbor.get("reference_row_fingerprint_sha256"),
                "reference fingerprint",
            )
            if reference in neighbor_fingerprints:
                raise ValueError("semantic-review queue repeats a neighbor")
            neighbor_fingerprints.add(reference)
            scores = neighbor.get("component_cosines")
            if not isinstance(scores, dict) or set(scores) != allowed_axes:
                raise ValueError("semantic-review queue component scores changed")
            if any(
                not isinstance(score, (int, float))
                or isinstance(score, bool)
                or not math.isfinite(score)
                or not -1.0 <= score <= 1.0
                or round(score, score_decimals) != score
                for score in scores.values()
            ):
                raise ValueError("semantic-review queue contains an invalid cosine")
            maximum = neighbor.get("max_cosine")
            if (
                not isinstance(maximum, (int, float))
                or isinstance(maximum, bool)
                or not math.isfinite(maximum)
                or round(maximum, score_decimals) != maximum
                or maximum != max(scores.values())
            ):
                raise ValueError("semantic-review queue maximum cosine is invalid")
            dominant = min(
                COMPARISON_AXES,
                key=lambda axis: (-scores[axis], COMPARISON_AXES.index(axis)),
            )
            if neighbor.get("dominant_comparison") != dominant:
                raise ValueError("semantic-review queue dominant comparison is invalid")
            if reference not in valid_reference_fingerprints:
                raise ValueError("semantic-review queue references an unknown row")
            key = (-maximum, reference)
            if prior_key is not None and key < prior_key:
                raise ValueError("semantic-review queue neighbors are not deterministically sorted")
            prior_key = key
    if [row["candidate_row_fingerprint_sha256"] for row in rows] != list(
        expected_candidate_fingerprints
    ):
        raise ValueError("semantic-review queue row count changed")


def expected_summary(
    rows: Sequence[dict[str, Any]],
    *,
    reference_rows: int,
    top_k: int,
    maximum_observed_tokens: int,
) -> dict[str, Any]:
    scores = sorted(row["neighbors"][0]["max_cosine"] for row in rows)

    def quantile(numerator: int, denominator: int) -> float:
        if not scores:
            return 0.0
        index = math.ceil((len(scores) - 1) * numerator / denominator)
        return scores[index]

    return {
        "screened_candidates": len(rows),
        "reference_rows": reference_rows,
        "neighbors_per_candidate": top_k,
        "manual_semantic_review_pending": len(rows),
        "native_editorial_review_pending": len(rows),
        "training_eligible": 0,
        "maximum_observed_tokens": maximum_observed_tokens,
        "nearest_neighbor_cosine": {
            "minimum": scores[0] if scores else 0.0,
            "p50": quantile(1, 2),
            "p90": quantile(9, 10),
            "p95": quantile(19, 20),
            "p99": quantile(99, 100),
            "maximum": scores[-1] if scores else 0.0,
            "quantile_method": "nearest_rank_ceiling_n_minus_one",
        },
    }


def build_bundle(
    contract_path: Path,
    inventory_bundle: Path,
    model_dir: Path,
    output: Path,
    expected_head: str,
    *,
    smoke_candidates: int | None = None,
    repo_root: Path = REPO_ROOT,
    script_path: Path = SCRIPT_PATH,
    backend_factory: Callable[[Path, dict[str, Any]], EmbeddingBackend] = (
        LocalSentenceTransformerBackend
    ),
) -> dict[str, Any]:
    repo_root = repo_root.resolve()
    contract_path = contract_path.resolve()
    inventory_bundle = inventory_bundle.resolve()
    model_dir = model_dir.resolve()
    output = output.absolute()
    if smoke_candidates is not None and smoke_candidates <= 0:
        raise ValueError("smoke candidate count must be positive")
    if output.exists() or output.is_symlink():
        raise ValueError("output bundle already exists; refusing to overwrite evidence")
    if not output.parent.is_dir():
        raise ValueError("output bundle parent directory must already exist")
    require_ignored_output(output, repo_root)
    tracked_paths = (
        script_path,
        contract_path,
        repo_root / "scripts/eval/build_eg1_replay_inventory.py",
        repo_root / "scripts/eval/eg1_replay_normalizer_v1.py",
    )
    execution_head = validate_git_state(
        expected_head, repo_root, tracked_paths
    )
    contract_bytes, contract_sha = read_once(contract_path)
    contract = parse_object_bytes(contract_bytes, "semantic-screen contract")
    validate_contract(contract)
    tool_receipts = validate_tool_bindings(contract, repo_root, script_path)
    inventory_rows, coordinator_receipt, captured_inventory = validate_inventory_bundle(
        contract, inventory_bundle, repo_root
    )
    sources = contract.get("sources")
    if not isinstance(sources, dict) or set(sources) != {
        "replay_training_original",
        "historical_type_b_all",
    }:
        raise ValueError("semantic-screen source inventory changed")
    replay_rows, replay_bytes, replay_receipt = load_source(
        repo_root, sources["replay_training_original"], "replay source"
    )
    reference_rows, reference_bytes, reference_receipt = load_source(
        repo_root, sources["historical_type_b_all"], "reference source"
    )
    coordinator_sources = {
        row.get("role"): row for row in coordinator_receipt.get("sources", [])
    }
    for role, source_receipt in (
        ("replay_training_original", replay_receipt),
        ("historical_type_b_all", reference_receipt),
    ):
        coordinator = coordinator_sources.get(role)
        if not isinstance(coordinator, dict) or {
            key: coordinator.get(key) for key in ("path", "sha256", "row_count")
        } != {key: source_receipt[key] for key in ("path", "sha256", "row_count")}:
            raise ValueError(f"{role} differs from the coordinator receipt")
    candidates = bind_inventory_to_sources(inventory_rows, replay_rows)
    expected_counts = contract["expected_counts"]
    if (
        len(inventory_rows) != expected_counts["inventory_rows"]
        or len(candidates) != expected_counts["candidate_only_rows"]
        or len(reference_rows) != expected_counts["reference_rows"]
    ):
        raise ValueError("semantic-screen source counts differ from contract")
    run_mode = "full"
    selected_candidates = candidates
    if smoke_candidates is not None:
        run_mode = "smoke"
        selected_candidates = candidates[: min(smoke_candidates, len(candidates))]
    model_receipt = validate_model_tree(contract, model_dir)
    backend = backend_factory(model_dir, contract["embedding"])
    if backend.runtime_versions != contract["embedding"]["runtime_versions"]:
        raise ValueError("embedding backend runtime versions changed")
    queue, summary = make_review_queue(
        selected_candidates,
        reference_rows,
        candidate_input_field=replay_receipt["input_field"],
        candidate_output_field=replay_receipt["output_field"],
        reference_input_field=reference_receipt["input_field"],
        reference_output_field=reference_receipt["output_field"],
        backend=backend,
        embedding=contract["embedding"],
    )
    validate_queue_rows(
        queue,
        expected_candidate_fingerprints=[
            fingerprint_row(row) for row in selected_candidates
        ],
        valid_reference_fingerprints={
            fingerprint_row(row) for row in reference_rows
        },
        top_k=contract["embedding"]["top_k"],
        score_decimals=contract["embedding"]["score_decimals"],
    )
    if summary["training_eligible"] != expected_counts["training_eligible_rows"]:
        raise ValueError("semantic-screen produced a training-eligible row")
    queue_bytes = b"".join(canonical_json(row) for row in queue)
    receipt_payload: dict[str, Any] = {
        "schema_version": RECEIPT_SCHEMA_VERSION,
        "status": "embedding_complete_manual_semantic_native_pending",
        "publication_strategy": "receipt_last",
        "execution_git_head": execution_head,
        "contract": {
            "path": relative_repo_path(contract_path, repo_root),
            "sha256": contract_sha,
        },
        "tool_bindings": tool_receipts,
        "run_scope": {
            "mode": run_mode,
            "complete_candidate_population": run_mode == "full",
            "screened_candidates": len(queue),
            "total_candidate_population": len(candidates),
        },
        "inventory_binding": contract["inventory_binding"],
        "sources": {
            "replay_training_original": replay_receipt,
            "historical_type_b_all": reference_receipt,
        },
        "embedding": {
            **model_receipt,
            "runtime_versions": backend.runtime_versions,
            "device": contract["embedding"]["device"],
            "model_dtype": contract["embedding"]["model_dtype"],
            "output_precision": contract["embedding"]["output_precision"],
            "pooling": contract["embedding"]["pooling"],
            "prompt_name": contract["embedding"]["prompt_name"],
            "normalize_embeddings": True,
            "embedding_dimension": contract["embedding"]["embedding_dimension"],
            "max_seq_length": backend.max_seq_length,
            "comparison_axes": list(COMPARISON_AXES),
            "score_decimals": contract["embedding"]["score_decimals"],
            "top_k": contract["embedding"]["top_k"],
        },
        "summary": summary,
        "approval_gates": {
            "embedding_screen": "complete",
            "manual_semantic_family_review": "pending",
            "meaning_safety_review": "pending",
            "native_editorial_review": "pending",
            "training_export": "prohibited",
            "training_eligible_rows": 0,
        },
        "privacy": {
            "metadata_only_queue": True,
            "private_text_published": False,
            "raw_source_ids_published": False,
        },
        "artifact": {
            "path": QUEUE_FILENAME,
            "sha256": sha256_bytes(queue_bytes),
            "row_count": len(queue),
        },
    }
    receipt_payload["receipt_payload_sha256"] = sha256_bytes(
        canonical_json(receipt_payload)
    )
    receipt_bytes = canonical_json(receipt_payload)
    output.mkdir()
    try:
        write_exclusive(output / QUEUE_FILENAME, queue_bytes)
        if read_once(repo_root / replay_receipt["path"])[1] != sha256_bytes(replay_bytes):
            raise ValueError("replay source changed during semantic screening")
        if read_once(repo_root / reference_receipt["path"])[1] != sha256_bytes(
            reference_bytes
        ):
            raise ValueError("reference source changed during semantic screening")
        for path_string, value in captured_inventory.items():
            if read_once(Path(path_string))[1] != sha256_bytes(value):
                raise ValueError("coordinator inventory changed during semantic screening")
        if validate_model_tree(contract, model_dir) != model_receipt:
            raise ValueError("embedding model changed during semantic screening")
        validate_git_state(expected_head, repo_root, tracked_paths)
        validate_tool_bindings(contract, repo_root, script_path)
        write_exclusive(output / RECEIPT_FILENAME, receipt_bytes)
        fsync_directory(output)
    except BaseException:
        shutil.rmtree(output, ignore_errors=True)
        raise
    return receipt_payload


def validate_published_bundle(
    contract_path: Path,
    inventory_bundle: Path,
    model_dir: Path,
    bundle: Path,
    *,
    trusted_receipt_sha256: str,
    repo_root: Path = REPO_ROOT,
    script_path: Path = SCRIPT_PATH,
) -> dict[str, Any]:
    repo_root = repo_root.resolve()
    contract_path = contract_path.resolve()
    inventory_bundle = inventory_bundle.resolve()
    model_dir = model_dir.resolve()
    bundle = bundle.resolve()
    receipt_path = bundle / RECEIPT_FILENAME
    queue_path = bundle / QUEUE_FILENAME
    try:
        members = list(bundle.iterdir())
    except OSError as error:
        raise ValueError("semantic-screen bundle cannot be enumerated") from error
    if (
        {path.name for path in members} != {RECEIPT_FILENAME, QUEUE_FILENAME}
        or any(not path.is_file() or path.is_symlink() for path in members)
    ):
        raise ValueError("semantic-screen bundle contains undeclared artifacts")
    receipt_bytes, receipt_sha = read_once(receipt_path)
    if receipt_sha != require_hash(
        trusted_receipt_sha256, "trusted semantic-screen receipt hash"
    ):
        raise ValueError("semantic-screen receipt differs from the trusted result")
    queue_bytes, queue_sha = read_once(queue_path)
    receipt = parse_object_bytes(receipt_bytes, "semantic-screen receipt")
    if set(receipt) != {
        "schema_version",
        "status",
        "publication_strategy",
        "execution_git_head",
        "contract",
        "tool_bindings",
        "run_scope",
        "inventory_binding",
        "sources",
        "embedding",
        "summary",
        "approval_gates",
        "privacy",
        "artifact",
        "receipt_payload_sha256",
    }:
        raise ValueError("semantic-screen receipt schema changed")
    if receipt.get("schema_version") != RECEIPT_SCHEMA_VERSION:
        raise ValueError("semantic-screen receipt schema changed")
    if (
        receipt.get("status") != "embedding_complete_manual_semantic_native_pending"
        or receipt.get("publication_strategy") != "receipt_last"
    ):
        raise ValueError("semantic-screen receipt status changed")
    execution_head = receipt.get("execution_git_head")
    if not isinstance(execution_head, str) or not SHA1_RE.fullmatch(execution_head):
        raise ValueError("semantic-screen receipt producing commit is invalid")
    contract_relative = relative_repo_path(contract_path, repo_root)
    contract_record = receipt.get("contract")
    if (
        not isinstance(contract_record, dict)
        or set(contract_record) != {"path", "sha256"}
        or contract_record.get("path") != contract_relative
    ):
        raise ValueError("semantic-screen receipt contract binding changed")
    contract_sha = require_hash(
        contract_record.get("sha256"), "semantic-screen producing contract hash"
    )
    committed_contract = git_committed_bytes(
        repo_root, execution_head, contract_relative
    )
    if committed_contract is None or sha256_bytes(committed_contract) != contract_sha:
        raise ValueError("semantic-screen producing contract binding is invalid")
    contract = parse_object_bytes(committed_contract, "producing semantic-screen contract")
    validate_contract(contract)
    tool_receipts = validate_producing_tool_bindings(
        contract, repo_root, script_path, execution_head
    )
    if receipt.get("tool_bindings") != tool_receipts:
        raise ValueError("semantic-screen receipt tool inventory changed")
    payload_hash = receipt.get("receipt_payload_sha256")
    payload = dict(receipt)
    payload.pop("receipt_payload_sha256", None)
    if payload_hash != sha256_bytes(canonical_json(payload)):
        raise ValueError("semantic-screen receipt payload binding is invalid")
    inventory_rows, coordinator_receipt, _ = validate_inventory_bundle(
        contract, inventory_bundle, repo_root
    )
    model_receipt = validate_model_tree(contract, model_dir)
    sources = contract.get("sources")
    if not isinstance(sources, dict) or set(sources) != {
        "replay_training_original",
        "historical_type_b_all",
    }:
        raise ValueError("semantic-screen source inventory changed")
    replay_rows, _, replay_receipt = load_source(
        repo_root, sources["replay_training_original"], "replay source"
    )
    reference_rows, _, reference_receipt = load_source(
        repo_root, sources["historical_type_b_all"], "reference source"
    )
    coordinator_sources = {
        row.get("role"): row for row in coordinator_receipt.get("sources", [])
    }
    for role, source_receipt in (
        ("replay_training_original", replay_receipt),
        ("historical_type_b_all", reference_receipt),
    ):
        coordinator = coordinator_sources.get(role)
        if not isinstance(coordinator, dict) or {
            key: coordinator.get(key) for key in ("path", "sha256", "row_count")
        } != {key: source_receipt[key] for key in ("path", "sha256", "row_count")}:
            raise ValueError(f"{role} differs from the coordinator receipt")
    candidates = bind_inventory_to_sources(inventory_rows, replay_rows)
    expected_counts = contract["expected_counts"]
    if (
        len(inventory_rows) != expected_counts["inventory_rows"]
        or len(candidates) != expected_counts["candidate_only_rows"]
        or len(reference_rows) != expected_counts["reference_rows"]
    ):
        raise ValueError("semantic-screen source counts differ from contract")
    rows = rows_from_bytes(queue_bytes, "semantic-review queue")
    run_scope = receipt.get("run_scope")
    if not isinstance(run_scope, dict) or set(run_scope) != {
        "mode",
        "complete_candidate_population",
        "screened_candidates",
        "total_candidate_population",
    }:
        raise ValueError("semantic-screen receipt run scope changed")
    mode = run_scope.get("mode")
    if mode not in {"smoke", "full"}:
        raise ValueError("semantic-screen receipt run mode changed")
    expected_candidate_fingerprints = [fingerprint_row(row) for row in candidates]
    if mode == "smoke":
        screened = run_scope.get("screened_candidates")
        if (
            type(screened) is not int
            or not 0 < screened <= len(candidates)
            or run_scope.get("complete_candidate_population") is not False
        ):
            raise ValueError("semantic-screen smoke scope changed")
        expected_candidate_fingerprints = expected_candidate_fingerprints[:screened]
    elif (
        run_scope.get("complete_candidate_population") is not True
        or run_scope.get("screened_candidates")
        != expected_counts["full_review_queue_rows"]
    ):
        raise ValueError("semantic-screen full scope changed")
    if (
        run_scope.get("screened_candidates") != len(rows)
        or run_scope.get("total_candidate_population") != len(candidates)
    ):
        raise ValueError("semantic-screen receipt run scope changed")
    artifact = receipt.get("artifact")
    if artifact != {
        "path": QUEUE_FILENAME,
        "sha256": queue_sha,
        "row_count": len(rows),
    }:
        raise ValueError("semantic-screen receipt artifact binding changed")
    validate_queue_rows(
        rows,
        expected_candidate_fingerprints=expected_candidate_fingerprints,
        valid_reference_fingerprints={
            fingerprint_row(row) for row in reference_rows
        },
        top_k=contract["embedding"]["top_k"],
        score_decimals=contract["embedding"]["score_decimals"],
    )
    if receipt.get("inventory_binding") != contract["inventory_binding"]:
        raise ValueError("semantic-screen receipt inventory binding changed")
    if receipt.get("sources") != {
        "replay_training_original": replay_receipt,
        "historical_type_b_all": reference_receipt,
    }:
        raise ValueError("semantic-screen receipt source binding changed")
    expected_embedding_receipt = {
        **model_receipt,
        "runtime_versions": contract["embedding"]["runtime_versions"],
        "device": contract["embedding"]["device"],
        "model_dtype": contract["embedding"]["model_dtype"],
        "output_precision": contract["embedding"]["output_precision"],
        "pooling": contract["embedding"]["pooling"],
        "prompt_name": contract["embedding"]["prompt_name"],
        "normalize_embeddings": True,
        "embedding_dimension": contract["embedding"]["embedding_dimension"],
        "max_seq_length": contract["embedding"]["max_seq_length"],
        "comparison_axes": list(COMPARISON_AXES),
        "score_decimals": contract["embedding"]["score_decimals"],
        "top_k": contract["embedding"]["top_k"],
    }
    if receipt.get("embedding") != expected_embedding_receipt:
        raise ValueError("semantic-screen receipt embedding binding changed")
    summary = receipt.get("summary")
    if not isinstance(summary, dict):
        raise ValueError("semantic-screen receipt summary changed")
    maximum_tokens = summary.get("maximum_observed_tokens")
    if (
        type(maximum_tokens) is not int
        or maximum_tokens <= 0
        or maximum_tokens > contract["embedding"]["max_seq_length"]
        or summary
        != expected_summary(
            rows,
            reference_rows=len(reference_rows),
            top_k=contract["embedding"]["top_k"],
            maximum_observed_tokens=maximum_tokens,
        )
    ):
        raise ValueError("semantic-screen receipt summary changed")
    if receipt.get("approval_gates") != {
        "embedding_screen": "complete",
        "manual_semantic_family_review": "pending",
        "meaning_safety_review": "pending",
        "native_editorial_review": "pending",
        "training_export": "prohibited",
        "training_eligible_rows": 0,
    }:
        raise ValueError("semantic-screen receipt fabricates an approval")
    if receipt.get("privacy") != {
        "metadata_only_queue": True,
        "private_text_published": False,
        "raw_source_ids_published": False,
    }:
        raise ValueError("semantic-screen receipt privacy declaration changed")
    return receipt


def main() -> int:
    args = parse_args()
    try:
        receipt = build_bundle(
            args.contract,
            args.inventory_bundle,
            args.model_dir,
            args.out_bundle,
            args.expected_git_head,
            smoke_candidates=args.smoke_candidates,
        )
    except (OSError, ValueError):
        raise SystemExit("semantic screening failed closed") from None
    print(
        json.dumps(
            {
                "artifact_sha256": receipt["artifact"]["sha256"],
                "receipt_sha256": sha256_bytes(canonical_json(receipt)),
                "run_scope": receipt["run_scope"],
                "summary": receipt["summary"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
