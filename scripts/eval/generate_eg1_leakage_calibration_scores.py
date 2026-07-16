#!/usr/bin/env python3
"""Seal canonical leakage score rows after full scanner-evidence recomputation."""

from __future__ import annotations

import argparse
from decimal import Decimal, ROUND_HALF_UP
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
from typing import Any

import numpy as np


SCHEMA_VERSION = "eg1-leakage-score-generator-v1"
ACCEPTED_NONCERTIFYING_STATUS = "calibration_required_noncertifying"
CANONICAL_SCANNER_PATH = "scripts/eval/scan_eg1_multilingual_development_leakage.py"
CANONICAL_SCANNER_SHA256 = "366774a4500a32cdc1e2577d8308e089287b38252ec5d2452cdae0af6816438d"
SCORE_QUANTUM = Decimal("0.00000001")


def quantize_score(value: float) -> float:
    return float(Decimal(str(value)).quantize(SCORE_QUANTUM, rounding=ROUND_HALF_UP))


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def load_scanner(path: Path, expected_sha256: str) -> Any:
    value = path.read_bytes()
    if sha256_bytes(value) != expected_sha256:
        raise ValueError("scanner bytes differ from their canonical binding")
    spec = importlib.util.spec_from_file_location("eg1_canonical_leakage_scanner", path)
    if spec is None or spec.loader is None:
        raise ValueError("cannot load canonical leakage scanner")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def verify_calibration_required_scanner_evidence(scanner: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    """Accept only the scanner's post-recomputation calibration-required stop."""
    try:
        scanner.verify_receipt(**arguments)
    except ValueError as error:
        expected = f"leakage receipt is non-certifying: {ACCEPTED_NONCERTIFYING_STATUS}"
        if str(error) != expected:
            raise
    else:
        raise ValueError("score calibration requires a production calibration-required receipt")
    receipt_path = Path(arguments["receipt_path"])
    receipt = json.loads(receipt_path.read_bytes())
    if receipt.get("backend") != "production" or receipt.get("status") != ACCEPTED_NONCERTIFYING_STATUS:
        raise ValueError("scanner evidence is not canonical production calibration evidence")
    return receipt


def decode_verification_arguments(value: dict[str, Any]) -> dict[str, Any]:
    required = {
        "receipt_path", "contract_path", "benchmark_path", "sources",
        "inventory_path", "source_receipt_paths", "blocked_registry_receipt_path",
        "expected_head", "model_dir",
    }
    if not isinstance(value, dict) or set(value) != required:
        raise ValueError("scanner verification argument schema changed")
    def bindings(rows: Any) -> dict[tuple[str, str], Path]:
        if not isinstance(rows, list):
            raise ValueError("scanner verification bindings are invalid")
        return {(row["role"], row["name"]): Path(row["path"]) for row in rows}
    return {
        "receipt_path": Path(value["receipt_path"]),
        "contract_path": Path(value["contract_path"]),
        "benchmark_path": Path(value["benchmark_path"]),
        "sources": bindings(value["sources"]),
        "inventory_path": Path(value["inventory_path"]),
        "source_receipt_paths": bindings(value["source_receipt_paths"]),
        "blocked_registry_receipt_path": Path(value["blocked_registry_receipt_path"]),
        "expected_head": value["expected_head"],
        "model_dir": Path(value["model_dir"]),
    }


def build_score_rows(scanner: Any, verification_arguments: dict[str, Any], pairs: list[dict[str, Any]]) -> bytes:
    contract = scanner.validate_contract(json.loads(Path(verification_arguments["contract_path"]).read_bytes()))
    backend = scanner.LocalSentenceTransformerBackend(
        Path(verification_arguments["model_dir"]), contract["embedding"]
    )
    output = []
    required = {
        "row_id", "family_component_id", "source_wave_id", "split", "language",
        "axis", "length_stratum", "behavior", "label", "left_text", "right_texts",
    }
    for pair in pairs:
        if not isinstance(pair, dict) or set(pair) != required:
            raise ValueError("score-pair input schema changed")
        left = pair["left_text"]
        references = pair["right_texts"]
        if not isinstance(left, str) or not left.strip() or not isinstance(references, list) or not references or any(not isinstance(value, str) or not value.strip() for value in references):
            raise ValueError("score-pair text is invalid")
        if pair["label"] == "related_positive" and len(references) != 1:
            raise ValueError("a related positive must have exactly one reference")
        if len(references) != len(set(references)):
            raise ValueError("caller-supplied reference pools may not contain duplicates")
        token = max(scanner.jaccard(scanner.token_ngrams(left, contract["token_ngram_width"]), scanner.token_ngrams(value, contract["token_ngram_width"])) for value in references)
        character = max(scanner.jaccard(scanner.character_ngrams(left, contract["character_ngram_width"]), scanner.character_ngrams(value, contract["character_ngram_width"])) for value in references)
        left_embedding = backend.encode_documents([left]).astype(np.float64)
        right_embeddings = backend.encode_documents(references).astype(np.float64)
        embedding = float(np.max(left_embedding @ right_embeddings.T))
        row = {key: pair[key] for key in required - {"left_text", "right_texts"}}
        row.update({
            "schema_version": "eg1-leakage-calibration-score-v1",
            "is_max_neighbor": pair["label"] == "hard_negative",
            "reference_family_count": len(references),
            "scores": {
                "token_ngram_jaccard": quantize_score(token),
                "character_ngram_jaccard": quantize_score(character),
                "embedding_cosine": quantize_score(embedding),
            },
        })
        output.append(row)
    return b"".join(canonical_json(row) for row in output)


def publish_bundle(bundle: Path, scores_bytes: bytes, receipt: dict[str, Any]) -> None:
    if bundle.exists() or not bundle.parent.is_dir():
        raise ValueError("score output bundle must be a new child of an existing directory")
    reserved = False
    try:
        bundle.mkdir()
        reserved = True
        for name, value in (("scores.jsonl", scores_bytes), ("receipt.json", canonical_json(receipt))):
            with (bundle / name).open("xb") as handle:
                if handle.write(value) != len(value):
                    raise OSError("short score evidence write")
                handle.flush()
                os.fsync(handle.fileno())
        descriptor = os.open(bundle, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except Exception:
        if reserved:
            shutil.rmtree(bundle, ignore_errors=True)
        raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scanner", type=Path, required=True)
    parser.add_argument("--scanner-sha256", required=True)
    parser.add_argument("--scanner-verification-arguments", type=Path, required=True)
    parser.add_argument("--pair-input", type=Path, required=True)
    parser.add_argument("--split", choices=("calibration", "validation"), required=True)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--producing-git-head", required=True)
    parser.add_argument("--generator-path", required=True)
    parser.add_argument("--upstream-scanner-receipt-path", required=True)
    parser.add_argument("--out-bundle", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.scanner.as_posix().endswith(CANONICAL_SCANNER_PATH) is False or args.scanner_sha256 != CANONICAL_SCANNER_SHA256:
        raise ValueError("scanner is not the contract-pinned canonical scanner")
    scanner = load_scanner(args.scanner, args.scanner_sha256)
    verification_arguments = decode_verification_arguments(
        json.loads(args.scanner_verification_arguments.read_bytes())
    )
    evidence = verify_calibration_required_scanner_evidence(scanner, verification_arguments)
    pair_bytes = args.pair_input.read_bytes()
    pairs = [json.loads(line) for line in pair_bytes.splitlines() if line.strip()]
    scores_bytes = build_score_rows(scanner, verification_arguments, pairs)
    rows = [json.loads(line) for line in scores_bytes.splitlines() if line.strip()]
    runtime = evidence["embedding_runtime"]["runtime_versions"]
    tree = evidence["embedding_runtime"]["model_tree"]
    receipt = {
        "schema_version": "eg1-leakage-score-generation-receipt-v1",
        "status": "operator_attested_noncertifying_scores",
        "split": args.split,
        "score_rows_sha256": sha256_bytes(scores_bytes),
        "score_row_count": len(rows),
        "contract_sha256": sha256_bytes(args.contract.read_bytes()),
        "producing_git_head": args.producing_git_head,
        "generator_path": args.generator_path,
        "generator_sha256": sha256_bytes(Path(__file__).read_bytes()),
        "upstream_scanner_receipt_path": args.upstream_scanner_receipt_path,
        "upstream_scanner_receipt_sha256": sha256_bytes(Path(verification_arguments["receipt_path"]).read_bytes()),
        "scanner_provenance_sha256": sha256_bytes(canonical_json(evidence["scanner_provenance"])),
        "model_tree_sha256": tree["tree_sha256"],
        "source_inventory_sha256": evidence["source_inventory_sha256"],
        "runtime_versions": runtime,
        "methods": ["token_ngram_jaccard", "character_ngram_jaccard", "embedding_cosine"],
        "axes": ["input_input", "output_output", "input_output", "output_input"],
        "score_decimals": 8,
        "contains_raw_text": False,
        "candidate_model_output_seen": False,
        "pair_input_sha256": sha256_bytes(pair_bytes),
        "quality_evidence": False,
        "production_thresholds_approved": False,
        "assurance_scope": "operator_attested_unsigned_pair_semantics_nonrelease",
    }
    publish_bundle(args.out_bundle, scores_bytes, receipt)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
