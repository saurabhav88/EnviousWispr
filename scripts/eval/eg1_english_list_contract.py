"""Strict parser for the executable EG-1 English list pilot V2 contract."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import subprocess
from typing import Any


BINDINGS_BEGIN = "<!-- EG1_LIST_V2_BINDINGS_BEGIN -->"
BINDINGS_END = "<!-- EG1_LIST_V2_BINDINGS_END -->"
REQUIRED_BINDINGS = (
    "assembly_receipt_sha256",
    "positive_corpus_sha256",
    "restraint_corpus_sha256",
    "baseline_raw_prompt_sha256",
    "baseline_model_visible_prompt_sha256",
    "candidate_raw_prompt_sha256",
    "candidate_model_visible_prompt_sha256",
    "contract_verifier_sha256",
    "renderer_sha256",
    "shipped_request_mirror_sha256",
    "local_wrapper_sha256",
    "subset_runner_sha256",
    "dual_arm_orchestrator_sha256",
    "deterministic_scorer_sha256",
    "ab_scorer_sha256",
    "blind_packet_builder_sha256",
    "semantic_rubric_sha256",
    "semantic_unblinder_sha256",
    "delivery_manifest_sha256",
    "code_anchor_git_sha1",
)
SHA256_KEYS = tuple(key for key in REQUIRED_BINDINGS if key.endswith("_sha256"))
SHA1_KEYS = ("code_anchor_git_sha1",)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def load_contract(path: Path) -> tuple[bytes, str, dict[str, str]]:
    value = path.read_bytes()
    try:
        text = value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("decision contract is not UTF-8") from error
    if text.count(BINDINGS_BEGIN) != 1 or text.count(BINDINGS_END) != 1:
        raise ValueError("decision contract must contain exactly one bindings block")
    body = text.split(BINDINGS_BEGIN, 1)[1].split(BINDINGS_END, 1)[0].strip()
    if body.startswith("```json") and body.endswith("```"):
        body = body[len("```json") : -len("```")].strip()
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, item in pairs:
            if key in result:
                raise ValueError(f"duplicate decision contract binding: {key}")
            result[key] = item
        return result

    try:
        parsed: Any = json.loads(body, object_pairs_hook=reject_duplicate_keys)
    except json.JSONDecodeError as error:
        raise ValueError("decision contract bindings are invalid JSON") from error
    if not isinstance(parsed, dict) or set(parsed) != set(REQUIRED_BINDINGS):
        raise ValueError("decision contract bindings are missing, duplicate, or unexpected")
    if any(not isinstance(value, str) for value in parsed.values()):
        raise ValueError("decision contract bindings must be strings")
    for key in SHA256_KEYS:
        if not re.fullmatch(r"[0-9a-f]{64}", parsed[key]):
            raise ValueError(f"decision contract binding {key} is not a sealed SHA-256")
    for key in SHA1_KEYS:
        if not re.fullmatch(r"[0-9a-f]{40}", parsed[key]):
            raise ValueError(f"decision contract binding {key} is not a sealed Git SHA-1")
    return value, sha256_bytes(value), dict(parsed)


def require_binding(bindings: dict[str, str], key: str, actual: str) -> None:
    if key not in bindings:
        raise ValueError(f"decision contract is missing {key}")
    if bindings[key] != actual:
        raise ValueError(f"actual {key} differs from the executable decision contract")


def current_git_head(repo_root: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
            cwd=repo_root,
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError("cannot read Git HEAD") from error


def validate_binding_commit(
    bindings: dict[str, str], contract_path: Path, repo_root: Path
) -> str:
    """Require HEAD = one contract-only binding commit atop the code anchor.

    A contract cannot contain its own eventual commit hash. The non-circular
    proof is a code anchor followed by exactly one commit whose only changed
    path is this contract.
    """

    anchor = bindings["code_anchor_git_sha1"]
    head = current_git_head(repo_root)
    try:
        parent = subprocess.check_output(
            ["git", "rev-parse", "HEAD^"],
            text=True,
            stderr=subprocess.DEVNULL,
            cwd=repo_root,
        ).strip()
        changed = subprocess.check_output(
            ["git", "diff", "--name-only", f"{anchor}..{head}"],
            text=True,
            stderr=subprocess.DEVNULL,
            cwd=repo_root,
        ).splitlines()
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError("cannot verify the decision-contract binding commit") from error
    expected_path = str(contract_path.resolve().relative_to(repo_root.resolve()))
    if parent != anchor or changed != [expected_path]:
        raise ValueError(
            "HEAD must be one contract-only binding commit atop the declared code anchor"
        )
    return head
