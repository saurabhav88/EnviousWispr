#!/usr/bin/env python3
"""Render a sealed English list pilot into two gold-free EG-1 prompt arms."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from typing import Any

from eg1_shipped_request import build_user_message, output_token_budget
from eg1_english_list_contract import (
    load_contract,
    require_binding,
    validate_binding_commit,
)


EXPECTED_COUNT_PER_ROLE = 75
ROLES = ("positive_list", "prose_restraint")
SCRIPT_PATH = Path(__file__).resolve()
EVAL_DIR = SCRIPT_PATH.parent
REPO_ROOT = EVAL_DIR.parents[1]
SHIPPED_REQUEST = EVAL_DIR / "eg1_shipped_request.py"
CONTRACT_VERIFIER = EVAL_DIR / "eg1_english_list_contract.py"
LOCAL_WRAPPER = EVAL_DIR / "eg1_local_app_eval.py"
SUBSET_RUNNER = EVAL_DIR / "subset_polish_runner.py"
DUAL_ARM_ORCHESTRATOR = EVAL_DIR / "eg1_local_app_ab_eval.py"
DETERMINISTIC_SCORER = EVAL_DIR / "score_eg1_english_list_novel.py"
AB_SCORER = EVAL_DIR / "score_eg1_english_list_ab.py"
BLIND_PACKET_BUILDER = EVAL_DIR / "build_eg1_english_list_blind_review.py"
SEMANTIC_UNBLINDER = EVAL_DIR / "unblind_eg1_english_list_semantic_review.py"
DELIVERY_MANIFEST = (
    REPO_ROOT
    / "Sources"
    / "EnviousWispr"
    / "Resources"
    / "eg1-delivery-manifest.json"
)
CANONICAL_RUBRIC = (
    REPO_ROOT
    / "docs"
    / "experiments"
    / "eg1-multilingual"
    / "ENGLISH-LIST-SEMANTIC-REVIEW-RUBRIC-V1.md"
)
CANONICAL_BASELINE_PROMPT = EVAL_DIR / "prompts" / "eg1-polish-prompt-v1.txt"
CANONICAL_CANDIDATE_PROMPT = EVAL_DIR / "prompts" / "eg1-list-aware-v2.txt"
CANONICAL_DECISION_CONTRACT = (
    REPO_ROOT
    / "docs"
    / "experiments"
    / "eg1-multilingual"
    / "ENGLISH-LIST-PILOT75-DECISION-CONTRACT-V2.md"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--positive-corpus", required=True, type=Path)
    parser.add_argument("--restraint-corpus", required=True, type=Path)
    parser.add_argument("--baseline-prompt", required=True, type=Path)
    parser.add_argument("--candidate-prompt", required=True, type=Path)
    parser.add_argument("--assembly-receipt", required=True, type=Path)
    parser.add_argument("--decision-contract", required=True, type=Path)
    parser.add_argument("--expected-assembly-receipt-sha256", required=True)
    parser.add_argument("--expected-decision-contract-sha256", required=True)
    parser.add_argument("--expected-positive-sha256", required=True)
    parser.add_argument("--expected-restraint-sha256", required=True)
    parser.add_argument("--expected-baseline-prompt-sha256", required=True)
    parser.add_argument("--expected-candidate-prompt-sha256", required=True)
    parser.add_argument("--expected-baseline-model-visible-sha256", required=True)
    parser.add_argument("--expected-candidate-model-visible-sha256", required=True)
    parser.add_argument("--expected-renderer-sha256", required=True)
    parser.add_argument("--expected-shipped-request-sha256", required=True)
    parser.add_argument("--expected-git-head", required=True)
    parser.add_argument("--out-bundle", required=True, type=Path)
    return parser.parse_args()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_once(path: Path, label: str) -> tuple[bytes, str]:
    try:
        value = path.read_bytes()
    except OSError as error:
        raise ValueError(f"cannot read {label}") from error
    return value, sha256_bytes(value)


def require_expected_hash(actual: str, expected: str, label: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError(f"expected {label} SHA-256 is invalid")
    if actual != expected:
        raise ValueError(f"{label} SHA-256 differs from the predeclared value")


def parse_jsonl(value: bytes, label: str) -> list[dict[str, Any]]:
    try:
        text = value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"{label} is not UTF-8") from error
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"{label}:{line_number} is invalid JSON") from error
        if not isinstance(row, dict):
            raise ValueError(f"{label}:{line_number} is not an object")
        rows.append(row)
    if not rows:
        raise ValueError(f"{label} is empty")
    return rows


def validate_corpus(rows: list[dict[str, Any]], role: str, label: str) -> None:
    if role not in ROLES:
        raise ValueError(f"unknown role {role}")
    if len(rows) != EXPECTED_COUNT_PER_ROLE:
        raise ValueError(
            f"{label} must contain exactly {EXPECTED_COUNT_PER_ROLE} {role} rows"
        )
    seen: set[str] = set()
    for line_number, row in enumerate(rows, 1):
        case_id = row.get("id")
        transcript = row.get("input")
        if not isinstance(case_id, str) or not case_id:
            raise ValueError(f"{label}:{line_number} has an invalid id")
        if case_id in seen:
            raise ValueError(f"{label}:{line_number} has duplicate id {case_id!r}")
        if not isinstance(transcript, str) or not transcript.strip():
            raise ValueError(f"{label}:{line_number} has an invalid input")
        if (
            row.get("benchmark_role") != role
            or row.get("split") != "dev"
            or row.get("lang") != "en"
            or row.get("gold_status") != "candidate_unreviewed"
            or row.get("native_reviewed") is not False
            or row.get("training_eligible") is not False
        ):
            raise ValueError(f"{label}:{line_number} violates the pilot metadata contract")
        seen.add(case_id)


def read_prompt(value: bytes, label: str) -> str:
    try:
        text = value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"{label} is not UTF-8") from error
    prompt = "\n".join(
        line for line in text.splitlines() if not line.startswith("#")
    ).strip()
    if not prompt:
        raise ValueError(f"{label} has no model-visible text")
    if "{{" in prompt or "}}" in prompt:
        raise ValueError(f"{label} contains an unresolved template marker")
    return prompt


def render_rows(rows: list[dict[str, Any]], system: str) -> list[dict[str, Any]]:
    rendered: list[dict[str, Any]] = []
    for row in rows:
        transcript = row["input"]
        rendered.append(
            {
                "id": row["id"],
                "system": system,
                "user": build_user_message(transcript),
                "max_tokens": output_token_budget(transcript),
            }
        )
    return rendered


def encode_jsonl(rows: list[dict[str, Any]]) -> bytes:
    return b"".join(
        (json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n").encode("utf-8")
        for row in rows
    )


def canonical_request_identity(rows: list[dict[str, Any]]) -> str:
    value = [
        {"id": row["id"], "user": row["user"], "max_tokens": row["max_tokens"]}
        for row in rows
    ]
    return sha256_bytes(
        (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode(
            "utf-8"
        )
    )


def write_exclusive(path: Path, value: bytes) -> None:
    with path.open("xb") as handle:
        handle.write(value)
        handle.flush()
        os.fsync(handle.fileno())


def publish_bundle(
    output: Path, temp: Path, member_names: tuple[str, ...], receipt_bytes: bytes
) -> None:
    output.mkdir()
    try:
        for name in member_names:
            os.replace(temp / name, output / name)
        write_exclusive(output / "receipt.json", receipt_bytes)
    except BaseException:
        shutil.rmtree(output)
        raise


def git_head() -> str | None:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def require_git_state(expected_head: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", expected_head):
        raise ValueError("expected Git HEAD is invalid")
    head = git_head()
    if head != expected_head:
        raise ValueError("Git HEAD differs from the predeclared commit")
    try:
        tracked_status = subprocess.check_output(
            ["git", "status", "--porcelain", "--untracked-files=no"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError("cannot verify tracked worktree state") from error
    if tracked_status.strip():
        raise ValueError("tracked worktree is dirty")
    return head


def receipt_output(
    receipt: dict[str, Any], role: str, corpus_path: Path, corpus_sha: str
) -> dict[str, Any]:
    if receipt.get("status") != "portable_leakage_validation_pass_candidate_requires_independent_review":
        raise ValueError("assembly receipt has an unexpected status")
    try:
        output = receipt["outputs"][role]
    except (KeyError, TypeError) as error:
        raise ValueError(f"assembly receipt is missing {role} output") from error
    if not isinstance(output, dict):
        raise ValueError(f"assembly receipt {role} output is invalid")
    recorded_path = output.get("path")
    if not isinstance(recorded_path, str) or not recorded_path:
        raise ValueError(f"assembly receipt {role} path is invalid")
    relative_path = Path(recorded_path)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise ValueError(f"assembly receipt {role} path is not repository-relative")
    if (REPO_ROOT / relative_path).resolve() != corpus_path.resolve():
        raise ValueError(f"supplied {role} corpus is not the receipt-bound output")
    if output.get("sha256") != corpus_sha:
        raise ValueError(f"supplied {role} corpus differs from the assembly receipt")
    if output.get("row_count") != EXPECTED_COUNT_PER_ROLE:
        raise ValueError(f"assembly receipt {role} row count is invalid")
    return output


def public_path(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path.resolve())


def main() -> int:
    args = parse_args()
    output = args.out_bundle
    if output.exists() or output.is_symlink():
        raise SystemExit("--out-bundle already exists; refusing to overwrite evidence")
    if not output.parent.is_dir():
        raise SystemExit("--out-bundle parent directory must already exist")

    if args.baseline_prompt.resolve() != CANONICAL_BASELINE_PROMPT.resolve():
        raise ValueError("baseline prompt path is not the canonical shipped prompt")
    if args.candidate_prompt.resolve() != CANONICAL_CANDIDATE_PROMPT.resolve():
        raise ValueError("candidate prompt path is not the predeclared list-v2 prompt")
    if args.decision_contract.resolve() != CANONICAL_DECISION_CONTRACT.resolve():
        raise ValueError("decision contract path is not the canonical V2 contract")

    head = require_git_state(args.expected_git_head)
    assembly_receipt_bytes, assembly_receipt_sha = read_once(
        args.assembly_receipt, "assembly receipt"
    )
    require_expected_hash(
        assembly_receipt_sha,
        args.expected_assembly_receipt_sha256,
        "assembly receipt",
    )
    try:
        assembly_receipt = json.loads(assembly_receipt_bytes)
    except json.JSONDecodeError as error:
        raise ValueError("assembly receipt is invalid JSON") from error
    if not isinstance(assembly_receipt, dict):
        raise ValueError("assembly receipt is not an object")
    decision_contract_bytes, decision_contract_sha, bindings = load_contract(
        args.decision_contract
    )
    require_expected_hash(
        decision_contract_sha,
        args.expected_decision_contract_sha256,
        "decision contract",
    )
    require_binding(bindings, "assembly_receipt_sha256", assembly_receipt_sha)

    positive_bytes, positive_sha = read_once(args.positive_corpus, "positive corpus")
    restraint_bytes, restraint_sha = read_once(args.restraint_corpus, "restraint corpus")
    baseline_prompt_bytes, baseline_prompt_sha = read_once(
        args.baseline_prompt, "baseline prompt"
    )
    candidate_prompt_bytes, candidate_prompt_sha = read_once(
        args.candidate_prompt, "candidate prompt"
    )
    renderer_bytes, renderer_sha = read_once(SCRIPT_PATH, "renderer")
    shipped_request_bytes, shipped_request_sha = read_once(
        SHIPPED_REQUEST, "shipped request mirror"
    )
    require_expected_hash(positive_sha, args.expected_positive_sha256, "positive corpus")
    require_expected_hash(restraint_sha, args.expected_restraint_sha256, "restraint corpus")
    require_expected_hash(
        baseline_prompt_sha,
        args.expected_baseline_prompt_sha256,
        "baseline prompt",
    )
    require_expected_hash(
        candidate_prompt_sha,
        args.expected_candidate_prompt_sha256,
        "candidate prompt",
    )
    require_expected_hash(renderer_sha, args.expected_renderer_sha256, "renderer")
    require_expected_hash(
        shipped_request_sha,
        args.expected_shipped_request_sha256,
        "shipped request mirror",
    )
    bound_code = {
        "contract_verifier_sha256": CONTRACT_VERIFIER,
        "renderer_sha256": SCRIPT_PATH,
        "shipped_request_mirror_sha256": SHIPPED_REQUEST,
        "local_wrapper_sha256": LOCAL_WRAPPER,
        "subset_runner_sha256": SUBSET_RUNNER,
        "dual_arm_orchestrator_sha256": DUAL_ARM_ORCHESTRATOR,
        "deterministic_scorer_sha256": DETERMINISTIC_SCORER,
        "ab_scorer_sha256": AB_SCORER,
        "blind_packet_builder_sha256": BLIND_PACKET_BUILDER,
        "semantic_rubric_sha256": CANONICAL_RUBRIC,
        "semantic_unblinder_sha256": SEMANTIC_UNBLINDER,
        "delivery_manifest_sha256": DELIVERY_MANIFEST,
    }
    bound_code_receipts: dict[str, dict[str, str]] = {}
    for key, path in bound_code.items():
        _, actual_sha = read_once(path, key)
        require_binding(bindings, key, actual_sha)
        bound_code_receipts[key] = {"path": public_path(path), "sha256": actual_sha}
    for key, actual in (
        ("positive_corpus_sha256", positive_sha),
        ("restraint_corpus_sha256", restraint_sha),
        ("baseline_raw_prompt_sha256", baseline_prompt_sha),
        ("candidate_raw_prompt_sha256", candidate_prompt_sha),
    ):
        require_binding(bindings, key, actual)
    receipt_output(assembly_receipt, "positive_list", args.positive_corpus, positive_sha)
    receipt_output(assembly_receipt, "prose_restraint", args.restraint_corpus, restraint_sha)
    positive = parse_jsonl(positive_bytes, "positive corpus")
    restraint = parse_jsonl(restraint_bytes, "restraint corpus")
    validate_corpus(positive, "positive_list", "positive corpus")
    validate_corpus(restraint, "prose_restraint", "restraint corpus")
    all_rows = [*positive, *restraint]
    ids = [row["id"] for row in all_rows]
    if len(set(ids)) != len(ids):
        raise ValueError("case IDs overlap across positive and restraint corpora")

    baseline_system = read_prompt(baseline_prompt_bytes, "baseline prompt")
    candidate_system = read_prompt(candidate_prompt_bytes, "candidate prompt")
    baseline_visible_sha = sha256_bytes(baseline_system.encode("utf-8"))
    candidate_visible_sha = sha256_bytes(candidate_system.encode("utf-8"))
    require_expected_hash(
        baseline_visible_sha,
        args.expected_baseline_model_visible_sha256,
        "baseline model-visible prompt",
    )
    require_expected_hash(
        candidate_visible_sha,
        args.expected_candidate_model_visible_sha256,
        "candidate model-visible prompt",
    )
    require_binding(bindings, "baseline_model_visible_prompt_sha256", baseline_visible_sha)
    require_binding(bindings, "candidate_model_visible_prompt_sha256", candidate_visible_sha)
    if baseline_system == candidate_system:
        raise ValueError("baseline and candidate model-visible prompts are identical")
    baseline = render_rows(all_rows, baseline_system)
    candidate = render_rows(all_rows, candidate_system)
    baseline_identity = canonical_request_identity(baseline)
    candidate_identity = canonical_request_identity(candidate)
    if baseline_identity != candidate_identity:
        raise RuntimeError("prompt arms differ outside the system prompt")
    if any(set(row) != {"id", "system", "user", "max_tokens"} for row in baseline + candidate):
        raise RuntimeError("rendered rows contain non-request fields")

    baseline_bytes = encode_jsonl(baseline)
    candidate_bytes = encode_jsonl(candidate)
    baseline_sha = sha256_bytes(baseline_bytes)
    candidate_sha = sha256_bytes(candidate_bytes)
    id_sequence_sha = sha256_bytes(("\n".join(ids) + "\n").encode("utf-8"))

    temp = Path(tempfile.mkdtemp(prefix=".eg1-list-render-", dir=output.parent))
    try:
        write_exclusive(temp / "baseline.jsonl", baseline_bytes)
        write_exclusive(temp / "candidate.jsonl", candidate_bytes)
        if read_once(temp / "baseline.jsonl", "rendered baseline")[1] != baseline_sha:
            raise RuntimeError("rendered baseline changed after write")
        if read_once(temp / "candidate.jsonl", "rendered candidate")[1] != candidate_sha:
            raise RuntimeError("rendered candidate changed after write")
        bound_sources = (
            (args.assembly_receipt, assembly_receipt_sha, "assembly receipt"),
            (args.decision_contract, decision_contract_sha, "decision contract"),
            (args.positive_corpus, positive_sha, "positive corpus"),
            (args.restraint_corpus, restraint_sha, "restraint corpus"),
            (args.baseline_prompt, baseline_prompt_sha, "baseline prompt"),
            (args.candidate_prompt, candidate_prompt_sha, "candidate prompt"),
            (SCRIPT_PATH, renderer_sha, "renderer"),
            (SHIPPED_REQUEST, shipped_request_sha, "shipped request mirror"),
            *(
                (path, bound_code_receipts[key]["sha256"], key)
                for key, path in bound_code.items()
                if path not in {SCRIPT_PATH, SHIPPED_REQUEST}
            ),
        )
        for path, expected_sha, label in bound_sources:
            if read_once(path, label)[1] != expected_sha:
                raise RuntimeError(f"{label} changed during rendering")
        require_git_state(args.expected_git_head)
        execution_head = validate_binding_commit(bindings, args.decision_contract, REPO_ROOT)
        if execution_head != args.expected_git_head:
            raise ValueError("expected Git HEAD differs from the contract binding commit")
        receipt = {
            "status": "gold_free_prompt_arms_ready_for_exact_mac_evaluation",
            "provenance": {
                "git_head": head,
                "expected_git_head": args.expected_git_head,
                "tracked_worktree_clean": True,
                "bindings": bindings,
                "bound_code": bound_code_receipts,
                "renderer": {
                    "path": public_path(SCRIPT_PATH),
                    "sha256": renderer_sha,
                    "expected_sha256": args.expected_renderer_sha256,
                },
                "shipped_request_mirror": {
                    "path": public_path(SHIPPED_REQUEST),
                    "sha256": shipped_request_sha,
                    "expected_sha256": args.expected_shipped_request_sha256,
                },
                "assembly_receipt": {
                    "path": public_path(args.assembly_receipt),
                    "sha256": assembly_receipt_sha,
                    "expected_sha256": args.expected_assembly_receipt_sha256,
                },
                "decision_contract": {
                    "path": public_path(args.decision_contract),
                    "sha256": decision_contract_sha,
                    "expected_sha256": args.expected_decision_contract_sha256,
                },
            },
            "case_contract": {
                "count_per_role": EXPECTED_COUNT_PER_ROLE,
                "total_count": len(all_rows),
                "role_order": list(ROLES),
                "id_sequence_sha256": id_sequence_sha,
                "request_identity_sha256": baseline_identity,
                "identical_id_user_and_token_budget_across_arms": True,
                "only_system_prompt_differs_across_arms": True,
                "rendered_rows_are_gold_free": True,
            },
            "sources": {
                "positive_corpus": {
                    "path": public_path(args.positive_corpus),
                    "sha256": positive_sha,
                    "expected_sha256": args.expected_positive_sha256,
                    "rows": len(positive),
                },
                "restraint_corpus": {
                    "path": public_path(args.restraint_corpus),
                    "sha256": restraint_sha,
                    "expected_sha256": args.expected_restraint_sha256,
                    "rows": len(restraint),
                },
                "baseline_prompt": {
                    "path": public_path(args.baseline_prompt),
                    "sha256": baseline_prompt_sha,
                    "expected_sha256": args.expected_baseline_prompt_sha256,
                    "model_visible_sha256": baseline_visible_sha,
                    "expected_model_visible_sha256": args.expected_baseline_model_visible_sha256,
                },
                "candidate_prompt": {
                    "path": public_path(args.candidate_prompt),
                    "sha256": candidate_prompt_sha,
                    "expected_sha256": args.expected_candidate_prompt_sha256,
                    "model_visible_sha256": candidate_visible_sha,
                    "expected_model_visible_sha256": args.expected_candidate_model_visible_sha256,
                },
            },
            "outputs": {
                "baseline": {"path": "baseline.jsonl", "sha256": baseline_sha},
                "candidate": {"path": "candidate.jsonl", "sha256": candidate_sha},
            },
            "publication": {
                "strategy": "exclusive_bundle_reservation_receipt_last",
                "commit_marker": "receipt.json",
            },
        }
        receipt_bytes = (
            json.dumps(receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        ).encode("utf-8")

        publish_bundle(
            output,
            temp,
            ("baseline.jsonl", "candidate.jsonl"),
            receipt_bytes,
        )
    finally:
        shutil.rmtree(temp, ignore_errors=True)

    print(json.dumps({"bundle": public_path(output), "cases": len(all_rows)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
