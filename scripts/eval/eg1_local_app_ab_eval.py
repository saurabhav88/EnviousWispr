#!/usr/bin/env python3
"""Run two sealed EG-1 prompt arms through one verified app-owned server."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any

from eg1_local_app_eval import (
    LocalServer,
    ModelArtifactIdentity,
    discover_server,
    runner_environment,
    verify_ready,
)
from eg1_english_list_contract import (
    load_contract,
    require_binding,
    validate_binding_commit,
)


SCRIPT_PATH = Path(__file__).resolve()
EVAL_DIR = SCRIPT_PATH.parent
REPO_ROOT = EVAL_DIR.parents[1]
LOCAL_WRAPPER = EVAL_DIR / "eg1_local_app_eval.py"
RUNNER = EVAL_DIR / "subset_polish_runner.py"
SHIPPED_REQUEST = EVAL_DIR / "eg1_shipped_request.py"
CONTRACT_VERIFIER = EVAL_DIR / "eg1_english_list_contract.py"
CANONICAL_DECISION_CONTRACT = (
    REPO_ROOT
    / "docs"
    / "experiments"
    / "eg1-multilingual"
    / "ENGLISH-LIST-PILOT75-DECISION-CONTRACT-V2.md"
)
EXPECTED_ARMS = ("baseline", "candidate")
EXPECTED_CASES = 150


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--render-bundle", required=True, type=Path)
    parser.add_argument("--decision-contract", required=True, type=Path)
    parser.add_argument("--app-bundle", required=True, type=Path)
    parser.add_argument("--out-bundle", required=True, type=Path)
    parser.add_argument("--expected-render-receipt-sha256", required=True)
    parser.add_argument("--expected-decision-contract-sha256", required=True)
    parser.add_argument("--expected-orchestrator-sha256", required=True)
    parser.add_argument("--expected-local-wrapper-sha256", required=True)
    parser.add_argument("--expected-runner-sha256", required=True)
    parser.add_argument("--expected-shipped-request-sha256", required=True)
    parser.add_argument("--expected-git-head", required=True)
    return parser.parse_args()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_once(path: Path, label: str) -> tuple[bytes, str]:
    try:
        value = path.read_bytes()
    except OSError as error:
        raise ValueError(f"cannot read {label}") from error
    return value, sha256_bytes(value)


def require_hash(actual: str, expected: str, label: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError(f"expected {label} SHA-256 is invalid")
    if actual != expected:
        raise ValueError(f"{label} SHA-256 differs from the predeclared value")


def git_head() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError("cannot verify Git HEAD") from error


def require_git_state(expected_head: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", expected_head):
        raise ValueError("expected Git HEAD is invalid")
    head = git_head()
    if head != expected_head:
        raise ValueError("Git HEAD differs from the predeclared commit")
    try:
        status = subprocess.check_output(
            ["git", "status", "--porcelain", "--untracked-files=no"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError("cannot verify tracked worktree state") from error
    if status.strip():
        raise ValueError("tracked worktree is dirty")
    return head


def parse_json(value: bytes, label: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise ValueError(f"{label} is invalid JSON") from error
    if not isinstance(parsed, dict):
        raise ValueError(f"{label} is not an object")
    return parsed


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
    return rows


def public_path(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path.resolve())


def relative_bundle_file(bundle: Path, value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} path is invalid")
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts or len(relative.parts) != 1:
        raise ValueError(f"{label} path is not a direct bundle child")
    path = bundle / relative
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"{label} file is unavailable")
    return path


def load_render_bundle(
    bundle: Path, expected_receipt_sha: str, decision_contract_sha: str
) -> tuple[dict[str, Any], Path, Path, dict[str, str]]:
    receipt_path = bundle / "receipt.json"
    receipt_bytes, receipt_sha = read_once(receipt_path, "render receipt")
    require_hash(receipt_sha, expected_receipt_sha, "render receipt")
    receipt = parse_json(receipt_bytes, "render receipt")
    if receipt.get("status") != "gold_free_prompt_arms_ready_for_exact_mac_evaluation":
        raise ValueError("render receipt status is not runnable")
    contract = receipt.get("case_contract")
    if not isinstance(contract, dict) or any(
        contract.get(key) is not True
        for key in (
            "identical_id_user_and_token_budget_across_arms",
            "only_system_prompt_differs_across_arms",
            "rendered_rows_are_gold_free",
        )
    ):
        raise ValueError("render receipt arm-equivalence contract is invalid")
    if contract.get("total_count") != EXPECTED_CASES:
        raise ValueError("render receipt case count is invalid")
    try:
        recorded_contract_sha = receipt["provenance"]["decision_contract"]["sha256"]
    except (KeyError, TypeError) as error:
        raise ValueError("render receipt does not bind the decision contract") from error
    if recorded_contract_sha != decision_contract_sha:
        raise ValueError("render receipt binds a different decision contract")

    paths: dict[str, Path] = {}
    hashes: dict[str, str] = {}
    for arm in EXPECTED_ARMS:
        try:
            output = receipt["outputs"][arm]
        except (KeyError, TypeError) as error:
            raise ValueError(f"render receipt is missing {arm}") from error
        if not isinstance(output, dict):
            raise ValueError(f"render receipt {arm} output is invalid")
        path = relative_bundle_file(bundle, output.get("path"), f"rendered {arm}")
        value, actual_sha = read_once(path, f"rendered {arm}")
        if actual_sha != output.get("sha256"):
            raise ValueError(f"rendered {arm} differs from its receipt")
        rows = parse_jsonl(value, f"rendered {arm}")
        if len(rows) != EXPECTED_CASES or any(
            set(row) != {"id", "system", "user", "max_tokens"} for row in rows
        ):
            raise ValueError(f"rendered {arm} rows violate the request contract")
        paths[arm] = path
        hashes[arm] = actual_sha
    baseline_rows = parse_jsonl(paths["baseline"].read_bytes(), "rendered baseline")
    candidate_rows = parse_jsonl(paths["candidate"].read_bytes(), "rendered candidate")
    for baseline, candidate in zip(baseline_rows, candidate_rows, strict=True):
        for field in ("id", "user", "max_tokens"):
            if baseline[field] != candidate[field]:
                raise ValueError("rendered arms differ outside the system prompt")
        if baseline["system"] == candidate["system"]:
            raise ValueError("rendered arm system prompts are identical")
    return receipt, paths["baseline"], paths["candidate"], hashes


def same_server(expected: LocalServer, actual: LocalServer) -> bool:
    return (
        expected.pid == actual.pid
        and expected.parent_pid == actual.parent_pid
        and expected.app_bundle == actual.app_bundle
        and expected.host == actual.host
        and expected.port == actual.port
        and expected.credential == actual.credential
        and expected.model_path == actual.model_path
        and expected.model_artifact == actual.model_artifact
    )


def recheck_server(initial: LocalServer, app_bundle: Path) -> None:
    current = discover_server(app_bundle, initial.pid)
    verify_ready(current)
    if not same_server(initial, current):
        raise RuntimeError("app-owned EG-1 server identity changed during the A/B run")


def validate_arm_output(
    prompt_path: Path, output_path: Path, arm: str
) -> dict[str, Any]:
    prompt_rows = parse_jsonl(prompt_path.read_bytes(), f"rendered {arm}")
    output_bytes, output_sha = read_once(output_path, f"{arm} model output")
    output_rows = parse_jsonl(output_bytes, f"{arm} model output")
    prompt_ids = [row["id"] for row in prompt_rows]
    output_ids = [row.get("id") for row in output_rows]
    if output_ids != prompt_ids or len(set(output_ids)) != len(output_ids):
        raise ValueError(f"{arm} output IDs/order differ from the rendered prompts")
    errors = [row["id"] for row in output_rows if row.get("error") not in (None, "")]
    empty = [
        row["id"]
        for row in output_rows
        if not isinstance(row.get("candidate"), str) or not row["candidate"].strip()
    ]
    return {
        "path": f"{arm}.jsonl",
        "sha256": output_sha,
        "row_count": len(output_rows),
        "id_sequence_sha256": sha256_bytes(("\n".join(prompt_ids) + "\n").encode()),
        "inference_error_count": len(errors),
        "inference_error_ids": errors,
        "empty_output_count": len(empty),
        "empty_output_ids": empty,
    }


def run_arm(
    arm: str,
    prompt_path: Path,
    output_path: Path,
    server: LocalServer,
    app_bundle: Path,
) -> tuple[int, dict[str, Any]]:
    recheck_server(server, app_bundle)
    command = [
        sys.executable,
        "-E",
        "-s",
        str(RUNNER),
        "--prompts",
        str(prompt_path),
        "--provider",
        "openai",
        "--model",
        "eg-1",
        "--out",
        str(output_path),
        "--workers",
        "1",
        "--endpoint",
        server.endpoint,
        "--eg1-shipped-request",
    ]
    environment = runner_environment(server.credential)
    try:
        completed = subprocess.run(
            command,
            check=False,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    finally:
        environment.pop("OPENAI_API_KEY", None)
    recheck_server(server, app_bundle)
    if not output_path.is_file() or output_path.is_symlink():
        raise RuntimeError(f"{arm} runner did not produce an exclusive output file")
    result = validate_arm_output(prompt_path, output_path, arm)
    result["runner_returncode"] = completed.returncode
    return completed.returncode, result


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


def main() -> int:
    args = parse_args()
    output = args.out_bundle
    if output.exists() or output.is_symlink():
        raise SystemExit("--out-bundle already exists; refusing to overwrite A/B evidence")
    if not output.parent.is_dir():
        raise SystemExit("--out-bundle parent directory must already exist")
    if args.decision_contract.resolve() != CANONICAL_DECISION_CONTRACT.resolve():
        raise ValueError("decision contract path is not the canonical V2 contract")

    head = require_git_state(args.expected_git_head)
    _, contract_sha, bindings = load_contract(args.decision_contract)
    require_hash(
        contract_sha,
        args.expected_decision_contract_sha256,
        "decision contract",
    )
    execution_head = validate_binding_commit(
        bindings, args.decision_contract, REPO_ROOT
    )
    if execution_head != head:
        raise ValueError("expected Git HEAD differs from the contract binding commit")
    sources = {
        "contract_verifier": (
            CONTRACT_VERIFIER,
            bindings["contract_verifier_sha256"],
            "contract_verifier_sha256",
        ),
        "orchestrator": (
            SCRIPT_PATH,
            args.expected_orchestrator_sha256,
            "dual_arm_orchestrator_sha256",
        ),
        "local_wrapper": (
            LOCAL_WRAPPER,
            args.expected_local_wrapper_sha256,
            "local_wrapper_sha256",
        ),
        "runner": (
            RUNNER,
            args.expected_runner_sha256,
            "subset_runner_sha256",
        ),
        "shipped_request": (
            SHIPPED_REQUEST,
            args.expected_shipped_request_sha256,
            "shipped_request_mirror_sha256",
        ),
        "decision_contract": (
            args.decision_contract,
            args.expected_decision_contract_sha256,
            None,
        ),
    }
    source_receipts: dict[str, dict[str, str]] = {}
    source_bytes: dict[str, tuple[Path, str]] = {}
    for label, (path, expected_sha, binding_key) in sources.items():
        _, actual_sha = read_once(path, label)
        require_hash(actual_sha, expected_sha, label)
        if binding_key is not None:
            require_binding(bindings, binding_key, actual_sha)
        source_receipts[label] = {
            "path": public_path(path),
            "sha256": actual_sha,
            "expected_sha256": expected_sha,
        }
        source_bytes[label] = (path, actual_sha)

    render_receipt_bytes, render_receipt_sha = read_once(
        args.render_bundle / "receipt.json", "render receipt"
    )
    require_hash(
        render_receipt_sha, args.expected_render_receipt_sha256, "render receipt"
    )
    render_receipt, baseline_prompts, candidate_prompts, rendered_hashes = load_render_bundle(
        args.render_bundle,
        args.expected_render_receipt_sha256,
        source_receipts["decision_contract"]["sha256"],
    )
    try:
        render_bindings = render_receipt["provenance"]["bindings"]
    except (KeyError, TypeError) as error:
        raise ValueError("render receipt does not carry contract bindings") from error
    if render_bindings != bindings:
        raise ValueError("render receipt bindings differ from the executable contract")

    server = discover_server(args.app_bundle)
    verify_ready(server)
    if server.model_path is None or server.model_artifact is None:
        raise RuntimeError("live EG-1 model artifact identity was not verified")
    require_binding(
        bindings,
        "delivery_manifest_sha256",
        server.model_artifact.manifest_sha256,
    )
    temp = Path(tempfile.mkdtemp(prefix=".eg1-mac-ab-", dir=output.parent))
    try:
        prompt_snapshots: dict[str, Path] = {}
        for arm, source in (
            ("baseline", baseline_prompts),
            ("candidate", candidate_prompts),
        ):
            prompt_bytes, prompt_sha = read_once(source, f"rendered {arm}")
            if prompt_sha != rendered_hashes[arm]:
                raise RuntimeError(f"rendered {arm} changed before the A/B run")
            snapshot = temp / f"{arm}-prompts.jsonl"
            write_exclusive(snapshot, prompt_bytes)
            if read_once(snapshot, f"{arm} prompt snapshot")[1] != prompt_sha:
                raise RuntimeError(f"{arm} prompt snapshot changed after write")
            prompt_snapshots[arm] = snapshot

        arm_receipts: dict[str, dict[str, Any]] = {}
        returncodes: dict[str, int] = {}
        for arm in EXPECTED_ARMS:
            returncode, arm_receipt = run_arm(
                arm,
                prompt_snapshots[arm],
                temp / f"{arm}.jsonl",
                server,
                args.app_bundle,
            )
            returncodes[arm] = returncode
            arm_receipts[arm] = arm_receipt
        recheck_server(server, args.app_bundle)

        for label, (path, expected_sha) in source_bytes.items():
            if read_once(path, label)[1] != expected_sha:
                raise RuntimeError(f"{label} changed during the A/B run")
        if read_once(args.render_bundle / "receipt.json", "render receipt")[1] != render_receipt_sha:
            raise RuntimeError("render receipt changed during the A/B run")
        for arm, source in (
            ("baseline", baseline_prompts),
            ("candidate", candidate_prompts),
        ):
            if read_once(source, f"rendered {arm}")[1] != rendered_hashes[arm]:
                raise RuntimeError(f"rendered {arm} changed during the A/B run")
        require_git_state(args.expected_git_head)
        if validate_binding_commit(bindings, args.decision_contract, REPO_ROOT) != head:
            raise RuntimeError("decision-contract binding commit changed during the A/B run")

        healthy = all(returncodes[arm] == 0 for arm in EXPECTED_ARMS) and all(
            arm_receipts[arm]["inference_error_count"] == 0
            and arm_receipts[arm]["empty_output_count"] == 0
            for arm in EXPECTED_ARMS
        )
        receipt = {
            "status": (
                "connector_wire_exact_ab_complete_semantic_review_pending"
                if healthy
                else "connector_wire_exact_ab_failed_inference_health_gate"
            ),
            "scope": {
                "connector_wire_exact": True,
                "paste_equivalent": False,
                "model_id": "eg-1",
                "arm_order": list(EXPECTED_ARMS),
                "same_server_identity_before_and_after_each_arm": True,
                "both_arms_zero_errors_and_empty_outputs": healthy,
            },
            "runtime": {
                "server_pid": server.pid,
                "parent_pid": server.parent_pid,
                "app_bundle": str(server.app_bundle),
                "endpoint": server.endpoint,
                "credential_present": True,
                "credential_recorded": False,
                "model_artifact": server.model_artifact.public_receipt(),
            },
            "provenance": {
                "git_head": head,
                "expected_git_head": args.expected_git_head,
                "tracked_worktree_clean": True,
                "bindings": bindings,
                "render_receipt": {
                    "path": public_path(args.render_bundle / "receipt.json"),
                    "sha256": render_receipt_sha,
                    "expected_sha256": args.expected_render_receipt_sha256,
                },
                "sources": source_receipts,
            },
            "arms": {
                arm: {
                    **arm_receipts[arm],
                    "rendered_prompts_sha256": rendered_hashes[arm],
                }
                for arm in EXPECTED_ARMS
            },
            "publication": {
                "strategy": "exclusive_bundle_reservation_receipt_last",
                "commit_marker": "receipt.json",
            },
        }
        receipt_bytes = (
            json.dumps(receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        ).encode()
        publish_bundle(
            output,
            temp,
            tuple(f"{arm}.jsonl" for arm in EXPECTED_ARMS),
            receipt_bytes,
        )
    finally:
        shutil.rmtree(temp, ignore_errors=True)

    print(
        json.dumps(
            {
                "bundle": public_path(output),
                "status": receipt["status"],
                "server_pid": server.pid,
            }
        )
    )
    return 0 if healthy else 2


if __name__ == "__main__":
    raise SystemExit(main())
