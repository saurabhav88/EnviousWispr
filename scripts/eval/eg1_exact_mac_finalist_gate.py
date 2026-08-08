#!/usr/bin/env python3
"""Validate a locked two-model exact-Mac receipt set without running a model.

The prompt-only 75+75 orchestrator proves one app process and one model stayed
stable while two prompt arms ran. A future weight finalist needs a different
shape: one current baseline, one locked finalist, two separate runtime sessions,
and the same pair carried unchanged across development, frozen, and Type B V2.
The sibling producer records stable app process and path identities and
publishes each receipt last. This validator checks the custodian signature,
binds the producer code hash, and requires an operator-predeclared hash pin for
all six receipts before it checks cross-suite consistency. These controls prove
the integrity of the recorded evidence, not independent producer execution or
the bytes already loaded by the app. The validator never launches the app and
never generates or scores candidate text.
"""

from __future__ import annotations

import sys as _bootstrap_sys

if __name__ == "__main__" and not _bootstrap_sys.flags.isolated:
    _bootstrap_sys.stderr.write(
        "exact-Mac finalist gate failed: run with isolated Python (python3 -I)\n"
    )
    raise SystemExit(2)

import argparse
import base64
import binascii
from functools import lru_cache
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, Callable, Iterable


SCRIPT_PATH = Path(__file__).resolve()
EVAL_DIR = SCRIPT_PATH.parent
REPO_ROOT = EVAL_DIR.parents[1]
CONTRACT_PATH = EVAL_DIR / "contracts" / "eg1_exact_mac_finalist_gate_v1.json"
LOCAL_WRAPPER = EVAL_DIR / "eg1_local_app_eval.py"
RUNNER = EVAL_DIR / "subset_polish_runner.py"
SHIPPED_REQUEST = EVAL_DIR / "eg1_shipped_request.py"
SWIFT_STRING_COUNT_ORACLE = EVAL_DIR / "eg1_swift_string_count_oracle.swift"
RECEIPT_PRODUCER = EVAL_DIR / "eg1_exact_mac_receipt_producer.py"
APP_BUILD_PROVENANCE_RELATIVE_PATH = Path(
    "Contents/Resources/eg1-exact-mac-build-provenance.json"
)
APP_SYSTEM_PROMPT_RELATIVE_PATH = Path(
    "Contents/Resources/eg1-exact-mac-system-prompt.txt"
)
APP_BUILD_SOURCE_PATHS = {
    "prompt_builder_source_sha256": REPO_ROOT
    / "Sources/EnviousWisprLLM/Prompting/EGOnePromptBuilder.swift",
    "pipeline_source_sha256": REPO_ROOT
    / "Sources/EnviousWisprPipeline/LLMPolishStep.swift",
    "connector_source_sha256": REPO_ROOT
    / "Sources/EnviousWisprLLM/EGOne/EGOneConnector.swift",
    "runtime_source_sha256": REPO_ROOT
    / "Sources/EnviousWisprLLM/EGOne/EGOneRuntime.swift",
    "shipped_request_mirror_sha256": SHIPPED_REQUEST,
    "swift_string_count_oracle_sha256": SWIFT_STRING_COUNT_ORACLE,
}

ARMS = ("baseline", "finalist")
SUITES = ("development", "frozen", "type_b_v2")
MODEL_ID = "eg-1"
CONTEXT_TOKENS = 16384
CONTEXT_OVERHEAD_TOKENS = 256
LOCK_SCHEMA = "eg1-exact-mac-finalist-lock-v1"
RECEIPT_SCHEMA = "eg1-exact-mac-generation-receipt-v1"
VALIDATED_SCHEMA = "eg1-exact-mac-finalist-validated-v1"
EVIDENCE_PIN_SCHEMA = "eg1-exact-mac-receipt-pin-v1"
APP_BUILD_PROVENANCE_SCHEMA = "eg1-exact-mac-app-build-provenance-v1"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]*$")

SHIPPED_RUNTIME_FLAGS = {
    "-c": "16384",
    "-fa": "on",
    "--cache-type-k": "q8_0",
    "--cache-type-v": "q8_0",
}
SUITE_CASE_COUNT_POLICY = {
    "development": {"exact": 800},
    "frozen": {"minimum": 1600, "multiple_of": 400},
    "type_b_v2": {"exact": 1890},
}
TOOLING_PATHS = {
    "exact_mac_validator_sha256": SCRIPT_PATH,
    "exact_mac_receipt_producer_sha256": RECEIPT_PRODUCER,
    "local_app_wrapper_sha256": LOCAL_WRAPPER,
    "subset_runner_sha256": RUNNER,
    "shipped_request_mirror_sha256": SHIPPED_REQUEST,
    "swift_string_count_oracle_sha256": SWIFT_STRING_COUNT_ORACLE,
}
EXTERNAL_TOOL_CANDIDATES = {
    "codesign": (Path("/usr/bin/codesign"),),
    "git": (Path("/usr/bin/git"),),
    "openssl": (
        Path("/opt/homebrew/opt/openssl@3/bin/openssl"),
        Path("/usr/local/opt/openssl@3/bin/openssl"),
        Path("/opt/homebrew/bin/openssl"),
        Path("/usr/local/bin/openssl"),
    ),
    "pgrep": (Path("/usr/bin/pgrep"),),
    "ps": (Path("/bin/ps"),),
    "sw_vers": (Path("/usr/bin/sw_vers"),),
    "xcrun": (Path("/usr/bin/xcrun"),),
}
# `/usr/bin/security` was audited but is intentionally absent: this evidence
# lane never invokes it. Adding unused binaries would create needless lock drift.
RUNTIME_HASH_FIELDS = {
    "app_executable_sha256",
    "llama_server_sha256",
    "app_system_prompt_resource_sha256",
    "shipped_runtime_flags_sha256",
    "swift_runtime_identity_sha256",
    "python_runtime_identity_sha256",
    "external_toolchain_identity_sha256",
}
ARM_RUNTIME_FIELDS = {
    "app_bundle_path_sha256",
    "app_bundle_manifest_sha256",
    "app_build_provenance_sha256",
}
ARM_FIELDS = {
    "designation",
    "model_id",
    "model_artifact_sha256",
    "delivery_manifest_sha256",
    "evaluation_config_sha256",
    "system_prompt_source_sha256",
    "system_prompt_sha256",
} | ARM_RUNTIME_FIELDS
SUITE_FIELDS = {
    "corpus_sha256",
    "case_count",
    "case_id_field",
    "input_field",
    "language_field",
}
LOCK_FIELDS = {
    "schema_version",
    "status",
    "lock_id",
    "gate_contract_sha256",
    "execution_git_head",
    "tracked_worktree_clean_required",
    "tooling",
    "runtime",
    "arms",
    "suites",
    "authorization",
    "attestation",
}
RECEIPT_FIELDS = {
    "schema_version",
    "lock_manifest_sha256",
    "arm",
    "suite",
    "execution_git_head",
    "tracked_worktree_clean",
    "tooling",
    "runtime",
    "model",
    "corpus",
    "rendered_prompts",
    "raw_generation_output",
    "generation_output",
    "producer",
    "attestation",
}
RUNTIME_RECEIPT_FIELDS = RUNTIME_HASH_FIELDS | {
    *ARM_RUNTIME_FIELDS,
    "session_id",
    "app_pid",
    "server_pid",
    "parent_pid",
    "loopback_host",
    "workers",
    "stable_process_and_path_identity_before_after",
    "loaded_executable_and_model_bytes_attested",
    "credential_present",
    "credential_recorded",
}
PRODUCER_RECEIPT_FIELDS = {
    "schema_version",
    "script_sha256",
    "receipt_written_by_key_holding_process",
    "non_exportable_external_signer_verified",
    "loaded_runtime_bytes_verified",
}
MODEL_RECEIPT_FIELDS = ARM_FIELDS - {"designation"} - ARM_RUNTIME_FIELDS
FILE_RECEIPT_FIELDS = {"file", "sha256", "row_count"}
OUTPUT_RECEIPT_FIELDS = FILE_RECEIPT_FIELDS | {
    "generation_error_count",
    "empty_output_count",
}
DELIVERED_OUTPUT_RECEIPT_FIELDS = OUTPUT_RECEIPT_FIELDS | {
    "post_validation_fallback_count"
}
AUTHORIZATION_FIELDS = {
    "one_locked_finalist",
    "frozen_opened_only_after_lock",
    "type_b_v2_one_shot",
}
RUNTIME_CONTRACT_FIELDS = {
    "model_id",
    "loopback_host",
    "workers",
    "exact_shipped_flags",
    "same_executable_and_runtime_hashes_for_both_arms",
    "per_arm_bundle_and_delivery_manifest_hashes",
    "same_shipped_system_prompt_for_both_arms",
    "same_runtime_session_for_all_suites_within_an_arm",
    "distinct_runtime_sessions_between_arms",
    "stable_process_and_path_identity_before_and_after_each_suite",
    "loaded_executable_and_model_bytes_attested",
    "swift_string_count_uses_lock_pinned_native_runtime",
    "python_evaluation_uses_lock_pinned_isolated_runtime",
    "external_executables_are_lock_pinned",
    "credential_recorded",
}
EVIDENCE_CONTRACT_FIELDS = {
    "receipt_count",
    "one_receipt_per_arm_and_suite",
    "receipts_bind_lock_manifest",
    "receipts_bind_clean_execution_git_head",
    "receipts_bind_app_bundle_model_path_prompt_and_corpus_hashes",
    "evaluation_config_hash_is_derived_from_executed_settings",
    "shipped_short_input_bypass_is_mirrored",
    "raw_outputs_are_transformed_by_post_validation_mirror",
    "controlled_language_from_locked_corpus_not_live_lid",
    "post_validation_is_mirror_not_app_executed",
    "swift_oracle_source_and_runtime_are_pinned",
    "generation_child_uses_lock_pinned_swift_runtime",
    "evidence_cli_refuses_nonisolated_python",
    "receipt_signatures_are_verified_before_acceptance",
    "receipt_hashes_are_operator_pinned_before_validation",
    "rendered_user_requests_match_corpus_inputs",
    "prompt_requests_match_across_arms",
    "output_ids_match_corpus_order",
    "duplicate_or_missing_ids_fail",
    "generation_errors_or_empty_outputs_fail",
    "output_files_are_reopened_and_rehashed",
    "validated_manifest_publishes_exclusively_after_all_checks",
}
EVIDENCE_PIN_FIELDS = {
    "schema_version",
    "lock_manifest_sha256",
    "receipts",
}
EVIDENCE_PIN_RECEIPT_FIELDS = {"arm", "suite", "receipt_sha256"}
ATTESTATION_LOCK_FIELDS = {"algorithm", "key_id", "public_key_sha256"}
ATTESTATION_RECEIPT_FIELDS = {
    "algorithm",
    "key_id",
    "public_key_sha256",
    "payload_sha256",
    "signature_base64",
}
APP_BUILD_PROVENANCE_FIELDS = {
    "schema_version",
    "build_git_head",
    "app_executable_sha256",
    "llama_server_sha256",
    "delivery_manifest_sha256",
    "system_prompt_source_sha256",
    "system_prompt_sha256",
    "evaluation_config_sha256",
    "app_system_prompt_resource_sha256",
    *APP_BUILD_SOURCE_PATHS,
}
RUNTIME_PROVENANCE_CONTRACT = {
    "generation_receipt_writer": "scripts/eval/eg1_exact_mac_receipt_producer.py",
    "receipt_signature_scope": "exportable_custodian_key_content_integrity_only",
    "non_exportable_external_signer_verified": False,
    "independent_pin_custody_verified": False,
    "loaded_executable_and_model_bytes_verified": False,
    "sibling_import_bytes_preverified_before_execution": False,
    "external_tool_paths_and_bytes_lock_pinned": True,
    "signed_app_build_provenance_required": True,
    "build_generated_app_prompt_required": True,
    "app_bundle_signature_verification": "codesign_verify_deep_strict",
    "validator_scope": "custodian_signed_operator_pinned_controlled_path_and_mirror_evidence",
    "may_claim_exact_mac_evidence_complete": False,
}
RAW_OUTPUT_ALLOWED_FIELDS = {
    "id",
    "candidate",
    "latencyMs",
    "attempts",
    "finishReason",
    "error",
}
OUTPUT_ALLOWED_FIELDS = RAW_OUTPUT_ALLOWED_FIELDS | {
    "deliveryPath",
    "fallbackReason",
}
DELIVERY_PATHS = {
    "model",
    "short_input_bypass",
    "context_bypass",
    "post_validation_fallback",
}
IMPORT_SHADOW_NAMES = {
    "argparse",
    "atexit",
    "base64",
    "binascii",
    "concurrent",
    "functools",
    "hashlib",
    "http",
    "importlib",
    "json",
    "os",
    "pathlib",
    "plistlib",
    "re",
    "selectors",
    "shutil",
    "sitecustomize",
    "subprocess",
    "sys",
    "tempfile",
    "threading",
    "typing",
    "urllib",
    "usercustomize",
}


class FinalistGateError(ValueError):
    """The evidence set is incomplete, mixed, or not bound to the lock."""


def load_shipped_request_module() -> Any:
    spec = importlib.util.spec_from_file_location(
        "_eg1_exact_mac_shipped_request", SHIPPED_REQUEST
    )
    if spec is None or spec.loader is None:
        raise FinalistGateError("cannot load the shipped request mirror")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if not callable(getattr(module, "build_user_message", None)) or not callable(
        getattr(module, "output_token_budget", None)
    ) or not callable(getattr(module, "input_would_bypass_polish", None)) or not callable(
        getattr(module, "apply_message_output_validation", None)
    ) or not callable(getattr(module, "input_would_bypass_context", None)) or not callable(
        getattr(module, "swift_character_count", None)
    ):
        raise FinalistGateError("shipped request mirror is incomplete")
    if Path(getattr(module, "SWIFT_STRING_COUNT_ORACLE", "")).resolve() != (
        SWIFT_STRING_COUNT_ORACLE.resolve()
    ):
        raise FinalistGateError("shipped request mirror uses a different Swift oracle")
    configure_swift = getattr(module, "configure_swift_count_executable", None)
    if not callable(configure_swift):
        raise FinalistGateError("shipped request mirror cannot bind the Swift executable")
    runtime_identity = swift_runtime_identity()
    swift_launcher, swift_executable = resolve_swift_runtime_paths()
    try:
        configure_swift(
            swift_launcher,
            swift_executable,
            runtime_identity["swift_executable_sha256"],
            sanitized_external_tool_environment(swift=True),
        )
    except ValueError as error:
        raise FinalistGateError("cannot bind the lock-pinned Swift executable") from error
    return module


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    try:
        return sha256_bytes(path.read_bytes())
    except OSError as error:
        raise FinalistGateError(f"cannot read evidence file {path.name}") from error


def _observe_external_tool(name: str) -> tuple[Path, dict[str, str]]:
    candidates = EXTERNAL_TOOL_CANDIDATES.get(name)
    if not candidates:
        raise FinalistGateError(f"external evidence tool {name} is not approved")
    for candidate in candidates:
        try:
            canonical = candidate.resolve(strict=True)
        except OSError:
            continue
        if (
            not canonical.is_absolute()
            or not canonical.is_file()
            or canonical.is_symlink()
            or not os.access(canonical, os.X_OK)
        ):
            continue
        identity = {
            "canonical_path_sha256": sha256_bytes(
                str(canonical).encode("utf-8")
            ),
            "executable_sha256": sha256_file(canonical),
        }
        return canonical, identity
    raise FinalistGateError(f"approved external evidence tool {name} is unavailable")


@lru_cache(maxsize=1)
def external_toolchain_identity() -> dict[str, dict[str, str]]:
    """Capture canonical path and executable bytes for every evidence tool."""

    return {
        name: _observe_external_tool(name)[1]
        for name in sorted(EXTERNAL_TOOL_CANDIDATES)
    }


def external_toolchain_identity_sha256() -> str:
    observed = {
        name: _observe_external_tool(name)[1]
        for name in sorted(EXTERNAL_TOOL_CANDIDATES)
    }
    if observed != external_toolchain_identity():
        raise FinalistGateError("external evidence toolchain has drifted")
    return sha256_bytes(
        canonical_json(observed).encode("utf-8")
    )


def pinned_external_tool(name: str) -> Path:
    """Return the locked executable only if its path and bytes still match."""

    canonical, observed = _observe_external_tool(name)
    if observed != external_toolchain_identity().get(name):
        raise FinalistGateError(f"external evidence tool {name} has drifted")
    return canonical


def external_tool_bindings(names: set[str]) -> dict[str, dict[str, str]]:
    identity = external_toolchain_identity()
    if not names.issubset(identity):
        raise FinalistGateError("external evidence tool binding is invalid")
    return {
        name: {
            "path": str(pinned_external_tool(name)),
            **identity[name],
        }
        for name in sorted(names)
    }


def sanitized_external_tool_environment(*, swift: bool = False) -> dict[str, str]:
    """Allow only stable variables needed by pinned native command-line tools."""

    environment = {
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    }
    if swift:
        environment.update({"HOME": "/tmp", "TMPDIR": "/tmp"})
        developer_dir = os.environ.get("DEVELOPER_DIR")
        if developer_dir:
            try:
                resolved = Path(developer_dir).resolve(strict=True)
            except OSError as error:
                raise FinalistGateError("DEVELOPER_DIR is unavailable") from error
            if not resolved.is_dir():
                raise FinalistGateError("DEVELOPER_DIR is invalid")
            environment["DEVELOPER_DIR"] = str(resolved)
    return environment


def swift_environment_sha256(environment: dict[str, str]) -> str:
    return sha256_bytes(canonical_json(environment).encode("utf-8"))


def read_once(path: Path, label: str) -> tuple[bytes, str]:
    try:
        value = path.read_bytes()
    except OSError as error:
        raise FinalistGateError(f"cannot read {label}") from error
    return value, sha256_bytes(value)


def parse_json(value: bytes, label: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise FinalistGateError(f"{label} is invalid JSON") from error
    if not isinstance(parsed, dict):
        raise FinalistGateError(f"{label} must be a JSON object")
    return parsed


def parse_jsonl(value: bytes, label: str) -> list[dict[str, Any]]:
    try:
        text = value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise FinalistGateError(f"{label} is not UTF-8") from error
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise FinalistGateError(
                f"{label} line {line_number} is invalid JSON"
            ) from error
        if not isinstance(row, dict):
            raise FinalistGateError(f"{label} line {line_number} is not an object")
        rows.append(row)
    return rows


def valid_sha(value: Any) -> bool:
    return (
        isinstance(value, str)
        and SHA256_RE.fullmatch(value) is not None
        and value != "0" * 64
    )


def require_sha(value: Any, label: str) -> str:
    if not valid_sha(value):
        raise FinalistGateError(f"{label} SHA-256 is invalid")
    return value


def require_exact_fields(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise FinalistGateError(f"{label} field set is invalid")
    return value


def load_attestation_public_key(
    lock: dict[str, Any], path: Path
) -> tuple[bytes, str, Path]:
    """Load the out-of-band receipt-verification key pinned by the finalist lock."""

    attestation = require_exact_fields(
        lock.get("attestation"), ATTESTATION_LOCK_FIELDS, "finalist lock attestation"
    )
    if attestation.get("algorithm") != "ed25519":
        raise FinalistGateError("finalist lock attestation algorithm is invalid")
    key_id = attestation.get("key_id")
    if not isinstance(key_id, str) or not IDENTIFIER_RE.fullmatch(key_id):
        raise FinalistGateError("finalist lock attestation key ID is invalid")
    require_sha(attestation.get("public_key_sha256"), "attestation public key")

    path = path.expanduser().absolute()
    if not path.is_file() or path.is_symlink():
        raise FinalistGateError("attestation public key is unavailable or is a symlink")
    path = path.resolve()
    value, digest = read_once(path, "attestation public key")
    if digest != attestation["public_key_sha256"]:
        raise FinalistGateError("attestation public key differs from the finalist lock")
    return value, digest, path


def receipt_attestation_payload(receipt: dict[str, Any]) -> bytes:
    payload = dict(receipt)
    payload.pop("attestation", None)
    return canonical_json(payload).encode("utf-8")


def verify_ed25519_signature(payload: bytes, signature: bytes, public_key: bytes) -> bool:
    if len(signature) != 64:
        return False
    with tempfile.TemporaryDirectory(prefix="eg1-receipt-verify-") as raw_temp:
        temp = Path(raw_temp)
        public_key_path = temp / "public.pem"
        payload_path = temp / "payload.json"
        signature_path = temp / "signature.bin"
        public_key_path.write_bytes(public_key)
        payload_path.write_bytes(payload)
        signature_path.write_bytes(signature)
        try:
            openssl = pinned_external_tool("openssl")
            completed = subprocess.run(
                [
                    str(openssl),
                    "pkeyutl",
                    "-verify",
                    "-pubin",
                    "-inkey",
                    str(public_key_path),
                    "-rawin",
                    "-in",
                    str(payload_path),
                    "-sigfile",
                    str(signature_path),
                ],
                check=False,
                env=sanitized_external_tool_environment(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError as error:
            raise FinalistGateError("cannot run Ed25519 receipt verification") from error
    return completed.returncode == 0


def verify_receipt_attestation(
    receipt: dict[str, Any], lock: dict[str, Any], public_key: bytes
) -> None:
    """Authenticate a receipt before trusting its producer/runtime claims."""

    locked = require_exact_fields(
        lock.get("attestation"), ATTESTATION_LOCK_FIELDS, "finalist lock attestation"
    )
    attestation = require_exact_fields(
        receipt.get("attestation"),
        ATTESTATION_RECEIPT_FIELDS,
        "generation receipt attestation",
    )
    for field in ("algorithm", "key_id", "public_key_sha256"):
        if attestation.get(field) != locked[field]:
            raise FinalistGateError(
                "generation receipt attestation differs from the finalist lock"
            )
    payload = receipt_attestation_payload(receipt)
    payload_sha = sha256_bytes(payload)
    if attestation.get("payload_sha256") != payload_sha:
        raise FinalistGateError("generation receipt attestation payload hash is invalid")
    signature_value = attestation.get("signature_base64")
    if not isinstance(signature_value, str):
        raise FinalistGateError("generation receipt attestation signature is invalid")
    try:
        signature = base64.b64decode(signature_value, validate=True)
    except (binascii.Error, ValueError) as error:
        raise FinalistGateError(
            "generation receipt attestation signature is invalid"
        ) from error
    if not verify_ed25519_signature(payload, signature, public_key):
        raise FinalistGateError(
            "generation receipt signature is not valid for the lock-pinned key"
        )


def shipped_runtime_flags_sha256() -> str:
    return sha256_bytes(canonical_json(SHIPPED_RUNTIME_FLAGS).encode("utf-8"))


@lru_cache(maxsize=1)
def swift_runtime_identity() -> dict[str, str]:
    """Pin the native grapheme oracle's toolchain and macOS Unicode runtime."""

    try:
        swift_launcher, swift_path = resolve_swift_runtime_paths()
        swift_version = subprocess.check_output(
            [str(swift_launcher), "--version"],
            executable=str(swift_path),
            env=sanitized_external_tool_environment(swift=True),
            text=True,
            stderr=subprocess.STDOUT,
        ).strip()
        sw_vers = pinned_external_tool("sw_vers")
        product_version = subprocess.check_output(
            [str(sw_vers), "-productVersion"],
            env=sanitized_external_tool_environment(),
            text=True,
        ).strip()
        build_version = subprocess.check_output(
            [str(sw_vers), "-buildVersion"],
            env=sanitized_external_tool_environment(),
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise FinalistGateError("cannot identify the native Swift grapheme runtime") from error
    if not swift_version or not product_version or not build_version:
        raise FinalistGateError("native Swift grapheme runtime identity is incomplete")
    return {
        "swift_launcher_path_sha256": sha256_bytes(str(swift_launcher).encode("utf-8")),
        "swift_executable_path_sha256": sha256_bytes(str(swift_path).encode("utf-8")),
        "swift_executable_sha256": sha256_file(swift_path),
        "swift_version_sha256": sha256_bytes(swift_version.encode("utf-8")),
        "developer_dir_sha256": sha256_bytes(
            sanitized_external_tool_environment(swift=True)
            .get("DEVELOPER_DIR", "none")
            .encode("utf-8")
        ),
        "macos_product_version": product_version,
        "macos_build_version": build_version,
    }


def resolve_swift_runtime_paths() -> tuple[Path, Path]:
    try:
        xcrun = pinned_external_tool("xcrun")
        launcher = Path(
            subprocess.check_output(
                [str(xcrun), "--find", "swift"],
                env=sanitized_external_tool_environment(swift=True),
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        ).absolute()
        return launcher, launcher.resolve(strict=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise FinalistGateError("cannot resolve the native Swift grapheme runtime") from error


def pinned_swift_runtime_paths() -> tuple[Path, Path]:
    launcher, executable = resolve_swift_runtime_paths()
    expected = swift_runtime_identity()
    observed = {
        "swift_launcher_path_sha256": sha256_bytes(str(launcher).encode("utf-8")),
        "swift_executable_path_sha256": sha256_bytes(
            str(executable).encode("utf-8")
        ),
        "swift_executable_sha256": sha256_file(executable),
    }
    if any(expected[field] != value for field, value in observed.items()):
        raise FinalistGateError("native Swift evidence runtime has drifted")
    return launcher, executable


def swift_runtime_identity_sha256() -> str:
    return sha256_bytes(canonical_json(swift_runtime_identity()).encode("utf-8"))


@lru_cache(maxsize=1)
def python_runtime_identity() -> dict[str, str]:
    """Pin the isolated interpreter used to validate and produce evidence."""

    launcher, executable = resolve_python_runtime_paths()
    os_identity = swift_runtime_identity()
    return {
        "python_launcher_path_sha256": sha256_bytes(str(launcher).encode("utf-8")),
        "python_executable_path_sha256": sha256_bytes(str(executable).encode("utf-8")),
        "python_executable_sha256": sha256_file(executable),
        "python_version_sha256": sha256_bytes(sys.version.encode("utf-8")),
        "python_cache_tag": sys.implementation.cache_tag or "none",
        "macos_product_version": os_identity["macos_product_version"],
        "macos_build_version": os_identity["macos_build_version"],
    }


def resolve_python_runtime_paths() -> tuple[Path, Path]:
    launcher = Path(sys.executable).absolute()
    try:
        return launcher, launcher.resolve(strict=True)
    except OSError as error:
        raise FinalistGateError("cannot identify the Python evidence runtime") from error


def pinned_python_runtime_paths() -> tuple[Path, Path]:
    launcher, executable = resolve_python_runtime_paths()
    expected = python_runtime_identity()
    observed = {
        "python_launcher_path_sha256": sha256_bytes(str(launcher).encode("utf-8")),
        "python_executable_path_sha256": sha256_bytes(
            str(executable).encode("utf-8")
        ),
        "python_executable_sha256": sha256_file(executable),
    }
    if any(expected[field] != value for field, value in observed.items()):
        raise FinalistGateError("Python evidence runtime has drifted")
    return launcher, executable


def python_runtime_identity_sha256() -> str:
    return sha256_bytes(canonical_json(python_runtime_identity()).encode("utf-8"))


def reject_import_shadows() -> None:
    """Reject local names that could shadow evidence-process dependencies."""

    for name in sorted(IMPORT_SHADOW_NAMES):
        candidates = (
            EVAL_DIR / f"{name}.py",
            EVAL_DIR / f"{name}.pyc",
            EVAL_DIR / f"{name}.so",
            EVAL_DIR / name,
        )
        if any(candidate.exists() or candidate.is_symlink() for candidate in candidates):
            raise FinalistGateError(
                f"eval root contains forbidden import shadow {name}"
            )


def require_isolated_cli() -> None:
    if not sys.flags.isolated:
        raise FinalistGateError(
            "evidence CLI requires isolated Python; run with python3 -I"
        )
    reject_import_shadows()


def executed_evaluation_config(system_prompt_sha256: str) -> dict[str, Any]:
    require_sha(system_prompt_sha256, "system prompt")
    return {
        "schema_version": "eg1-exact-mac-executed-evaluation-config-v1",
        "model_id": MODEL_ID,
        "provider": "openai_compatible_loopback",
        "workers": 1,
        "temperature": 0,
        "system_prompt_sha256": system_prompt_sha256,
        "user_message_policy": "eg1_shipped_transcript_wrapper_and_tag_neutralization",
        "max_tokens_policy": "swift_string_count_floor_256",
        "context_tokens": CONTEXT_TOKENS,
        "context_overhead_tokens": CONTEXT_OVERHEAD_TOKENS,
        "runtime_flags": SHIPPED_RUNTIME_FLAGS,
        "logical_timeout_seconds": 15,
        "connection_attempts": 2,
        "retry_wait_milliseconds": 750,
        "response_policy": "eg1_shipped_cleanup_and_truncation_bypass",
        "short_input_policy": "controlled_language_shipped_polish_bypass_mirror",
        "post_generation_policy": "shipped_message_mode_output_validation_mirror",
        "language_source": "locked_corpus_controlled_language_not_live_app_lid",
        "delivery_claim": "python_mirror_not_literal_app_pipeline_execution",
        "swift_string_count_oracle_sha256": sha256_file(SWIFT_STRING_COUNT_ORACLE),
        "swift_unicode_parity_oracle_protocol": "operation_tab_base64_v1",
        "swift_runtime_identity": swift_runtime_identity(),
        "generation_child_swift_runtime_policy": (
            "required_lock_pinned_cli_paths_hash_and_environment"
        ),
        "python_runtime_identity": python_runtime_identity(),
        "external_toolchain_identity": external_toolchain_identity(),
        "python_isolated_mode_required": True,
    }


def executed_evaluation_config_sha256(system_prompt_sha256: str) -> str:
    return sha256_bytes(
        canonical_json(executed_evaluation_config(system_prompt_sha256)).encode("utf-8")
    )


def current_tooling_hashes() -> dict[str, str]:
    return {name: sha256_file(path) for name, path in TOOLING_PATHS.items()}


def require_git_state(expected_head: str) -> None:
    if not isinstance(expected_head, str) or not GIT_SHA_RE.fullmatch(expected_head):
        raise FinalistGateError("execution Git HEAD is invalid")
    try:
        git = pinned_external_tool("git")
        git_environment = sanitized_external_tool_environment()
        git_environment.update(
            {
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_TERMINAL_PROMPT": "0",
            }
        )
        head = subprocess.check_output(
            [str(git), "rev-parse", "HEAD"],
            cwd=REPO_ROOT,
            env=git_environment,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        status = subprocess.check_output(
            [str(git), "status", "--porcelain", "--untracked-files=no"],
            cwd=REPO_ROOT,
            env=git_environment,
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise FinalistGateError("cannot verify execution Git state") from error
    if head != expected_head:
        raise FinalistGateError("current Git HEAD differs from the locked execution commit")
    if status.strip():
        raise FinalistGateError("tracked worktree is dirty")


def load_gate_contract() -> tuple[dict[str, Any], str]:
    value, digest = read_once(CONTRACT_PATH, "exact-Mac gate contract")
    contract = parse_json(value, "exact-Mac gate contract")
    expected_fields = {
        "schema_version",
        "status",
        "required_arms",
        "required_suites",
        "suite_case_count_policy",
        "runtime_contract",
        "runtime_provenance",
        "evidence_contract",
    }
    require_exact_fields(contract, expected_fields, "exact-Mac gate contract")
    if contract.get("schema_version") != "eg1-exact-mac-finalist-gate-contract-v1":
        raise FinalistGateError("exact-Mac gate contract schema is invalid")
    if contract.get("status") != "definition_only_no_finalist_locked":
        raise FinalistGateError("exact-Mac gate contract status is invalid")
    if contract.get("required_arms") != list(ARMS):
        raise FinalistGateError("exact-Mac gate contract arm order is invalid")
    if contract.get("required_suites") != list(SUITES):
        raise FinalistGateError("exact-Mac gate contract suite order is invalid")
    runtime = require_exact_fields(
        contract.get("runtime_contract"),
        RUNTIME_CONTRACT_FIELDS,
        "exact-Mac runtime contract",
    )
    if (
        runtime.get("model_id") != MODEL_ID
        or runtime.get("loopback_host") != "127.0.0.1"
        or runtime.get("workers") != 1
        or runtime.get("exact_shipped_flags") != SHIPPED_RUNTIME_FLAGS
        or runtime.get("credential_recorded") is not False
    ):
        raise FinalistGateError("exact-Mac runtime contract is invalid")
    required_runtime_booleans = {
        "same_executable_and_runtime_hashes_for_both_arms",
        "per_arm_bundle_and_delivery_manifest_hashes",
        "same_shipped_system_prompt_for_both_arms",
        "same_runtime_session_for_all_suites_within_an_arm",
        "distinct_runtime_sessions_between_arms",
        "stable_process_and_path_identity_before_and_after_each_suite",
        "swift_string_count_uses_lock_pinned_native_runtime",
        "python_evaluation_uses_lock_pinned_isolated_runtime",
        "external_executables_are_lock_pinned",
    }
    if any(runtime.get(field) is not True for field in required_runtime_booleans):
        raise FinalistGateError("exact-Mac runtime contract is incomplete")
    if runtime.get("loaded_executable_and_model_bytes_attested") is not False:
        raise FinalistGateError("exact-Mac runtime contract overclaims loaded bytes")
    if contract.get("runtime_provenance") != RUNTIME_PROVENANCE_CONTRACT:
        raise FinalistGateError("exact-Mac runtime provenance contract is invalid")
    evidence = require_exact_fields(
        contract.get("evidence_contract"),
        EVIDENCE_CONTRACT_FIELDS,
        "exact-Mac evidence contract",
    )
    if evidence.get("receipt_count") != 6:
        raise FinalistGateError("exact-Mac evidence contract is invalid")
    if any(value is not True for key, value in evidence.items() if key != "receipt_count"):
        raise FinalistGateError("exact-Mac evidence contract is incomplete")
    return contract, digest


def validate_case_count_policy(contract: dict[str, Any], suites: dict[str, Any]) -> None:
    policy = contract.get("suite_case_count_policy")
    if policy != SUITE_CASE_COUNT_POLICY:
        raise FinalistGateError("suite case-count policy is invalid")
    for suite in SUITES:
        count = suites[suite].get("case_count")
        if type(count) is not int or count <= 0:
            raise FinalistGateError(f"{suite} case count is invalid")
        rule = policy.get(suite)
        if "exact" in rule:
            if count != rule["exact"]:
                raise FinalistGateError(
                    f"{suite} case count violates the gate contract"
                )
        elif "minimum" in rule:
            minimum = rule["minimum"]
            multiple = rule["multiple_of"]
            if (
                type(minimum) is not int
                or type(multiple) is not int
                or minimum <= 0
                or multiple <= 0
                or count < minimum
                or count % multiple != 0
            ):
                raise FinalistGateError(f"{suite} case count violates the gate contract")
        else:
            raise FinalistGateError(f"{suite} case-count policy is invalid")


def load_lock(path: Path) -> tuple[dict[str, Any], str, dict[str, str]]:
    value, digest = read_once(path, "finalist lock manifest")
    lock = parse_json(value, "finalist lock manifest")
    require_exact_fields(lock, LOCK_FIELDS, "finalist lock manifest")
    if lock.get("schema_version") != LOCK_SCHEMA:
        raise FinalistGateError("finalist lock schema is invalid")
    if lock.get("status") != "locked_for_exact_mac_finalist_gate":
        raise FinalistGateError("finalist lock status is not executable")
    lock_id = lock.get("lock_id")
    if not isinstance(lock_id, str) or not IDENTIFIER_RE.fullmatch(lock_id):
        raise FinalistGateError("finalist lock ID is invalid")
    if lock.get("tracked_worktree_clean_required") is not True:
        raise FinalistGateError("finalist lock does not require a clean tracked worktree")
    head = lock.get("execution_git_head")
    if not isinstance(head, str) or not GIT_SHA_RE.fullmatch(head):
        raise FinalistGateError("finalist lock Git HEAD is invalid")

    _, contract_sha = load_gate_contract()
    if lock.get("gate_contract_sha256") != contract_sha:
        raise FinalistGateError("finalist lock binds a different gate contract")

    tooling = require_exact_fields(
        lock.get("tooling"), set(TOOLING_PATHS), "finalist lock tooling"
    )
    actual_tooling = current_tooling_hashes()
    if tooling != actual_tooling:
        raise FinalistGateError("finalist lock tooling hashes differ from current bytes")

    runtime = require_exact_fields(
        lock.get("runtime"), RUNTIME_HASH_FIELDS, "finalist lock runtime"
    )
    for field in RUNTIME_HASH_FIELDS:
        require_sha(runtime.get(field), f"finalist lock runtime {field}")
    if runtime["shipped_runtime_flags_sha256"] != shipped_runtime_flags_sha256():
        raise FinalistGateError("finalist lock runtime flags are not the shipped flags")
    if (
        runtime["external_toolchain_identity_sha256"]
        != external_toolchain_identity_sha256()
    ):
        raise FinalistGateError("finalist lock external toolchain identity has drifted")
    if runtime["swift_runtime_identity_sha256"] != swift_runtime_identity_sha256():
        raise FinalistGateError("finalist lock Swift/macOS runtime identity has drifted")
    if runtime["python_runtime_identity_sha256"] != python_runtime_identity_sha256():
        raise FinalistGateError("finalist lock Python runtime identity has drifted")

    arms = lock.get("arms")
    if not isinstance(arms, dict) or set(arms) != set(ARMS):
        raise FinalistGateError("finalist lock must contain exactly baseline and finalist")
    expected_designation = {
        "baseline": "current_shipping_baseline",
        "finalist": "locked_finalist",
    }
    for arm in ARMS:
        record = require_exact_fields(arms[arm], ARM_FIELDS, f"finalist lock {arm}")
        if record.get("designation") != expected_designation[arm]:
            raise FinalistGateError(f"finalist lock {arm} designation is invalid")
        if record.get("model_id") != MODEL_ID:
            raise FinalistGateError(f"finalist lock {arm} model ID is invalid")
        for field in ARM_FIELDS - {"designation", "model_id"}:
            require_sha(record.get(field), f"finalist lock {arm} {field}")
    if arms["baseline"]["model_artifact_sha256"] == arms["finalist"]["model_artifact_sha256"]:
        raise FinalistGateError("baseline and finalist model artifacts must be distinct")
    if (
        arms["baseline"]["model_artifact_sha256"],
        arms["baseline"]["evaluation_config_sha256"],
    ) == (
        arms["finalist"]["model_artifact_sha256"],
        arms["finalist"]["evaluation_config_sha256"],
    ):
        raise FinalistGateError("baseline and finalist artifact/config pairs must be distinct")
    for field in ("system_prompt_source_sha256", "system_prompt_sha256"):
        if arms["baseline"][field] != arms["finalist"][field]:
            raise FinalistGateError(
                "baseline and finalist must use the same shipped system prompt"
            )
    for arm in ARMS:
        if arms[arm]["evaluation_config_sha256"] != executed_evaluation_config_sha256(
            arms[arm]["system_prompt_sha256"]
        ):
            raise FinalistGateError(
                f"finalist lock {arm} evaluation config is not the executed config"
            )

    suites = lock.get("suites")
    if not isinstance(suites, dict) or set(suites) != set(SUITES):
        raise FinalistGateError("finalist lock suite inventory is invalid")
    for suite in SUITES:
        record = require_exact_fields(suites[suite], SUITE_FIELDS, f"finalist lock {suite}")
        require_sha(record.get("corpus_sha256"), f"finalist lock {suite} corpus")
        if record.get("case_id_field") not in {"id", "case_id"}:
            raise FinalistGateError(f"finalist lock {suite} case ID field is invalid")
        if record.get("input_field") != "asr_input":
            raise FinalistGateError(f"finalist lock {suite} input field is invalid")
        if record.get("language_field") != "language":
            raise FinalistGateError(f"finalist lock {suite} language field is invalid")
    contract, _ = load_gate_contract()
    validate_case_count_policy(contract, suites)

    authorization = require_exact_fields(
        lock.get("authorization"), AUTHORIZATION_FIELDS, "finalist lock authorization"
    )
    if any(authorization.get(field) is not True for field in AUTHORIZATION_FIELDS):
        raise FinalistGateError("finalist lock authorization is incomplete")
    attestation = require_exact_fields(
        lock.get("attestation"), ATTESTATION_LOCK_FIELDS, "finalist lock attestation"
    )
    if attestation.get("algorithm") != "ed25519":
        raise FinalistGateError("finalist lock attestation algorithm is invalid")
    key_id = attestation.get("key_id")
    if not isinstance(key_id, str) or not IDENTIFIER_RE.fullmatch(key_id):
        raise FinalistGateError("finalist lock attestation key ID is invalid")
    require_sha(attestation.get("public_key_sha256"), "attestation public key")
    return lock, digest, actual_tooling


def load_evidence_pin(
    path: Path, *, expected_sha256: str, lock_sha256: str
) -> tuple[dict[tuple[str, str], str], str, Path]:
    """Load the operator-predeclared hash pin for the six receipts.

    The producer does not create or modify this file. The operator/decision lane
    must pin its SHA-256 out of band and pass that expected hash explicitly.
    """

    require_sha(expected_sha256, "expected evidence pin")
    path = path.expanduser().absolute()
    if not path.is_file() or path.is_symlink():
        raise FinalistGateError("evidence pin is unavailable or is a symlink")
    path = path.resolve()
    value, actual_sha = read_once(path, "evidence pin")
    if actual_sha != expected_sha256:
        raise FinalistGateError("evidence pin differs from its predeclared SHA-256")
    pin = parse_json(value, "evidence pin")
    require_exact_fields(pin, EVIDENCE_PIN_FIELDS, "evidence pin")
    if pin.get("schema_version") != EVIDENCE_PIN_SCHEMA:
        raise FinalistGateError("evidence pin schema is invalid")
    if pin.get("lock_manifest_sha256") != lock_sha256:
        raise FinalistGateError("evidence pin binds a different finalist lock")
    entries = pin.get("receipts")
    if not isinstance(entries, list) or len(entries) != len(ARMS) * len(SUITES):
        raise FinalistGateError("evidence pin must contain exactly six receipts")
    pinned: dict[tuple[str, str], str] = {}
    for entry in entries:
        record = require_exact_fields(
            entry, EVIDENCE_PIN_RECEIPT_FIELDS, "evidence pin receipt"
        )
        pair = (record.get("arm"), record.get("suite"))
        if pair[0] not in ARMS or pair[1] not in SUITES or pair in pinned:
            raise FinalistGateError("evidence pin receipt mapping is invalid or duplicated")
        pinned[pair] = require_sha(
            record.get("receipt_sha256"), "evidence pin receipt"
        )
    expected_pairs = {(arm, suite) for arm in ARMS for suite in SUITES}
    if set(pinned) != expected_pairs:
        raise FinalistGateError("evidence pin receipt inventory is incomplete")
    return pinned, actual_sha, path


def parse_corpus_specs(values: Iterable[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        if "=" not in value:
            raise FinalistGateError("--corpus must use SUITE=PATH")
        suite, raw_path = value.split("=", 1)
        if suite not in SUITES or suite in result or not raw_path:
            raise FinalistGateError("corpus suite mapping is invalid or duplicated")
        result[suite] = Path(raw_path).expanduser().absolute()
    if set(result) != set(SUITES):
        raise FinalistGateError("exactly one corpus path is required for every suite")
    if len(set(result.values())) != len(result):
        raise FinalistGateError("corpus paths must be distinct")
    return result


def load_corpora(
    lock: dict[str, Any], paths: dict[str, Path]
) -> tuple[dict[str, list[tuple[str, str, str]]], dict[Path, str]]:
    cases_by_suite: dict[str, list[tuple[str, str, str]]] = {}
    snapshots: dict[Path, str] = {}
    all_ids: set[str] = set()
    for suite in SUITES:
        path = paths[suite]
        if not path.is_file() or path.is_symlink():
            raise FinalistGateError(f"{suite} corpus is unavailable or is a symlink")
        resolved_path = path.resolve()
        value, digest = read_once(resolved_path, f"{suite} corpus")
        expected = lock["suites"][suite]
        if digest != expected["corpus_sha256"]:
            raise FinalistGateError(f"{suite} corpus differs from the finalist lock")
        rows = parse_jsonl(value, f"{suite} corpus")
        if len(rows) != expected["case_count"]:
            raise FinalistGateError(f"{suite} corpus row count differs from the finalist lock")
        field = expected["case_id_field"]
        ids = [row.get(field) for row in rows]
        if any(not isinstance(case_id, str) or not case_id for case_id in ids):
            raise FinalistGateError(f"{suite} corpus contains an invalid case ID")
        if len(set(ids)) != len(ids):
            raise FinalistGateError(f"{suite} corpus contains duplicate case IDs")
        overlap = all_ids.intersection(ids)
        if overlap:
            raise FinalistGateError("case IDs must be disjoint across finalist-gate suites")
        all_ids.update(ids)
        input_field = expected["input_field"]
        inputs = [row.get(input_field) for row in rows]
        if any(not isinstance(input_text, str) or not input_text for input_text in inputs):
            raise FinalistGateError(f"{suite} corpus contains an invalid input")
        language_field = expected["language_field"]
        languages = [row.get(language_field) for row in rows]
        if any(
            not isinstance(language, str)
            or re.fullmatch(r"[a-z]{2,3}", language) is None
            for language in languages
        ):
            raise FinalistGateError(f"{suite} corpus contains an invalid language")
        cases_by_suite[suite] = list(zip(ids, inputs, languages))
        snapshots[resolved_path] = digest
    return cases_by_suite, snapshots


def direct_child_file(bundle: Path, value: Any, label: str) -> Path:
    if not isinstance(value, str) or not value:
        raise FinalistGateError(f"{label} file name is invalid")
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts or len(relative.parts) != 1:
        raise FinalistGateError(f"{label} must be a direct receipt-bundle child")
    path = bundle / relative
    if not path.is_file() or path.is_symlink():
        raise FinalistGateError(f"{label} is unavailable or is a symlink")
    return path.resolve()


def validate_rendered_prompts(
    value: bytes,
    *,
    expected_cases: list[tuple[str, str, str]],
    expected_system_sha: str,
    build_user_message: Callable[[str], str],
    output_token_budget: Callable[[str], int],
    input_would_bypass_polish: Callable[[str, str], bool],
    input_would_bypass_context: Callable[[str, int], bool],
    label: str,
) -> tuple[list[tuple[str, str, int]], list[dict[str, Any]]]:
    rows = parse_jsonl(value, label)
    if len(rows) != len(expected_cases):
        raise FinalistGateError(f"{label} row count is incomplete")
    requests: list[tuple[str, str, int]] = []
    for index, row in enumerate(rows):
        if set(row) != {
            "id",
            "controlled_language",
            "action",
            "system",
            "user",
            "max_tokens",
        }:
            raise FinalistGateError(f"{label} row field set is invalid")
        case_id = row.get("id")
        language = row.get("controlled_language")
        action = row.get("action")
        system = row.get("system")
        user = row.get("user")
        max_tokens = row.get("max_tokens")
        expected_id, input_text, expected_language = expected_cases[index]
        if case_id != expected_id:
            raise FinalistGateError(f"{label} ID sequence differs from its corpus")
        if language != expected_language:
            raise FinalistGateError(f"{label} language sequence differs from its corpus")
        try:
            expected_max_tokens = output_token_budget(input_text)
        except ValueError as error:
            raise FinalistGateError(
                f"{label} token budget needs a trusted Swift-rendered request"
            ) from error
        if input_would_bypass_polish(input_text, expected_language):
            expected_action = "short_input_bypass"
        elif input_would_bypass_context(input_text, expected_max_tokens):
            expected_action = "context_bypass"
        else:
            expected_action = "dispatch_eg1"
        if action != expected_action:
            raise FinalistGateError(f"{label} dispatch action differs from the shipped app")
        if action != "dispatch_eg1":
            if system is not None or user is not None or max_tokens is not None:
                raise FinalistGateError(f"{label} bypass row exposes a model request")
            continue
        if not isinstance(system, str) or not system:
            raise FinalistGateError(f"{label} contains an invalid system prompt")
        if sha256_bytes(system.encode("utf-8")) != expected_system_sha:
            raise FinalistGateError(f"{label} system prompt differs from the locked prompt")
        if not isinstance(user, str) or not user:
            raise FinalistGateError(f"{label} contains an invalid user request")
        expected_user = build_user_message(input_text)
        if user != expected_user:
            raise FinalistGateError(f"{label} user request differs from its corpus")
        if type(max_tokens) is not int or max_tokens <= 0:
            raise FinalistGateError(f"{label} contains an invalid token budget")
        if max_tokens != expected_max_tokens:
            raise FinalistGateError(f"{label} token budget differs from the shipped request")
        requests.append((case_id, user, max_tokens))
    return requests, rows


def build_delivered_output_rows(
    *,
    expected_cases: list[tuple[str, str, str]],
    prompt_rows: list[dict[str, Any]],
    raw_rows: list[dict[str, Any]],
    apply_message_output_validation: Callable[[str, str], tuple[str, str | None]],
) -> tuple[list[dict[str, Any]], int]:
    """Build the controlled-language Python mirror of all-case delivery."""

    raw_by_id = {row["id"]: row for row in raw_rows}
    delivered: list[dict[str, Any]] = []
    fallback_count = 0
    for (case_id, input_text, _), prompt in zip(expected_cases, prompt_rows):
        action = prompt["action"]
        if action != "dispatch_eg1":
            delivered.append(
                {
                    "id": case_id,
                    "candidate": input_text,
                    "latencyMs": 0,
                    "attempts": 0,
                    "deliveryPath": action,
                }
            )
            continue
        raw = raw_by_id.get(case_id)
        if raw is None:
            raise FinalistGateError("raw generation output omits a dispatched case")
        try:
            candidate, fallback_reason = apply_message_output_validation(
                raw["candidate"], input_text
            )
        except ValueError as error:
            raise FinalistGateError(
                "delivered output needs a trusted compiled Swift parity oracle"
            ) from error
        row = dict(raw)
        row["candidate"] = candidate
        if fallback_reason is None:
            row["deliveryPath"] = "model"
        else:
            fallback_count += 1
            row["deliveryPath"] = "post_validation_fallback"
            row["fallbackReason"] = fallback_reason
        delivered.append(row)
    return delivered, fallback_count


def validate_delivered_output(
    value: bytes, *, expected_rows: list[dict[str, Any]], label: str
) -> list[dict[str, Any]]:
    rows = parse_jsonl(value, label)
    if rows != expected_rows:
        raise FinalistGateError(
            f"{label} differs from the shipped all-case delivery sequence"
        )
    for row in rows:
        if set(row) - OUTPUT_ALLOWED_FIELDS:
            raise FinalistGateError(f"{label} row contains unknown output fields")
        if row.get("deliveryPath") not in DELIVERY_PATHS:
            raise FinalistGateError(f"{label} contains an invalid delivery path")
        if not isinstance(row.get("candidate"), str) or not row["candidate"].strip():
            raise FinalistGateError(f"{label} contains an empty delivered output")
    return rows


def validate_generation_output(
    value: bytes, *, expected_ids: list[str], label: str
) -> tuple[list[dict[str, Any]], int, int]:
    rows = parse_jsonl(value, label)
    if len(rows) != len(expected_ids):
        raise FinalistGateError(f"{label} row count is incomplete")
    error_count = 0
    empty_count = 0
    for index, row in enumerate(rows):
        if not {"id", "candidate", "latencyMs", "attempts"}.issubset(row):
            raise FinalistGateError(f"{label} row is missing required output fields")
        if set(row) - RAW_OUTPUT_ALLOWED_FIELDS:
            raise FinalistGateError(f"{label} row contains unknown output fields")
        if row.get("id") != expected_ids[index]:
            raise FinalistGateError(f"{label} ID sequence differs from its corpus")
        candidate = row.get("candidate")
        if not isinstance(candidate, str) or not candidate.strip():
            empty_count += 1
        if row.get("error") not in (None, ""):
            error_count += 1
        latency = row.get("latencyMs")
        attempts = row.get("attempts")
        if type(latency) is not int or latency < 0:
            raise FinalistGateError(f"{label} contains an invalid latency")
        if type(attempts) is not int or attempts < 1:
            raise FinalistGateError(f"{label} contains an invalid attempt count")
        if "finishReason" in row:
            if not isinstance(row["finishReason"], str):
                raise FinalistGateError(f"{label} contains an invalid finish reason")
            if row["finishReason"] == "length":
                raise FinalistGateError(f"{label} contains a truncated output")
    if len({row["id"] for row in rows}) != len(rows):
        raise FinalistGateError(f"{label} contains duplicate output IDs")
    return rows, error_count, empty_count


def validate_receipt(
    path: Path,
    *,
    lock: dict[str, Any],
    lock_sha: str,
    tooling: dict[str, str],
    cases_by_suite: dict[str, list[tuple[str, str, str]]],
    build_user_message: Callable[[str], str],
    output_token_budget: Callable[[str], int],
    input_would_bypass_polish: Callable[[str, str], bool],
    input_would_bypass_context: Callable[[str, int], bool],
    apply_message_output_validation: Callable[[str, str], tuple[str, str | None]],
    attestation_public_key: bytes,
    used_files: set[Path],
    snapshots: dict[Path, str],
) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise FinalistGateError("generation receipt is unavailable or is a symlink")
    resolved_receipt = path.resolve()
    if resolved_receipt in used_files:
        raise FinalistGateError("generation receipt path is duplicated")
    used_files.add(resolved_receipt)
    value, receipt_sha = read_once(resolved_receipt, "generation receipt")
    receipt = parse_json(value, "generation receipt")
    require_exact_fields(receipt, RECEIPT_FIELDS, "generation receipt")
    if receipt.get("schema_version") != RECEIPT_SCHEMA:
        raise FinalistGateError("generation receipt schema is invalid")
    arm = receipt.get("arm")
    suite = receipt.get("suite")
    if arm not in ARMS or suite not in SUITES:
        raise FinalistGateError("generation receipt arm or suite is invalid")
    if receipt.get("lock_manifest_sha256") != lock_sha:
        raise FinalistGateError("generation receipt binds a different finalist lock")
    if receipt.get("execution_git_head") != lock["execution_git_head"]:
        raise FinalistGateError("generation receipt Git HEAD differs from the finalist lock")
    if receipt.get("tracked_worktree_clean") is not True:
        raise FinalistGateError("generation receipt did not prove a clean tracked worktree")
    if receipt.get("tooling") != tooling:
        raise FinalistGateError("generation receipt tooling differs from the finalist lock")

    verify_receipt_attestation(receipt, lock, attestation_public_key)

    producer = require_exact_fields(
        receipt.get("producer"),
        PRODUCER_RECEIPT_FIELDS,
        "generation receipt producer",
    )
    if (
        producer.get("schema_version") != "eg1-exact-mac-receipt-producer-v1"
        or producer.get("script_sha256")
        != tooling["exact_mac_receipt_producer_sha256"]
        or producer.get("receipt_written_by_key_holding_process") is not True
        or producer.get("non_exportable_external_signer_verified") is not False
        or producer.get("loaded_runtime_bytes_verified") is not False
    ):
        raise FinalistGateError(
            "generation receipt key-holder/writer metadata differs from the lock"
        )

    runtime = require_exact_fields(
        receipt.get("runtime"), RUNTIME_RECEIPT_FIELDS, "generation receipt runtime"
    )
    for field in RUNTIME_HASH_FIELDS:
        if runtime.get(field) != lock["runtime"][field]:
            raise FinalistGateError("generation receipt app/runtime hash differs from the lock")
    for field in ARM_RUNTIME_FIELDS:
        if runtime.get(field) != lock["arms"][arm][field]:
            raise FinalistGateError(
                "generation receipt per-arm bundle hash differs from the lock"
            )
    session_id = runtime.get("session_id")
    if not isinstance(session_id, str) or not IDENTIFIER_RE.fullmatch(session_id):
        raise FinalistGateError("generation receipt runtime session ID is invalid")
    for field in ("app_pid", "server_pid", "parent_pid"):
        if type(runtime.get(field)) is not int or runtime[field] <= 0:
            raise FinalistGateError(f"generation receipt runtime {field} is invalid")
    if runtime["parent_pid"] != runtime["app_pid"]:
        raise FinalistGateError("generation receipt server parent is not the app process")
    if (
        runtime.get("loopback_host") != "127.0.0.1"
        or runtime.get("workers") != 1
        or runtime.get("stable_process_and_path_identity_before_after") is not True
        or runtime.get("loaded_executable_and_model_bytes_attested") is not False
        or runtime.get("credential_present") is not True
        or runtime.get("credential_recorded") is not False
    ):
        raise FinalistGateError("generation receipt runtime controls are invalid")

    model = require_exact_fields(
        receipt.get("model"), MODEL_RECEIPT_FIELDS, "generation receipt model"
    )
    expected_model = {
        key: value
        for key, value in lock["arms"][arm].items()
        if key not in {"designation", *ARM_RUNTIME_FIELDS}
    }
    if model != expected_model:
        raise FinalistGateError("generation receipt model/prompt hashes differ from the lock")

    corpus = require_exact_fields(
        receipt.get("corpus"), SUITE_FIELDS, "generation receipt corpus"
    )
    if corpus != lock["suites"][suite]:
        raise FinalistGateError("generation receipt corpus differs from the lock")
    expected_cases = cases_by_suite[suite]
    expected_ids = [case_id for case_id, _, _ in expected_cases]

    prompt_record = require_exact_fields(
        receipt.get("rendered_prompts"),
        FILE_RECEIPT_FIELDS,
        "generation receipt rendered prompts",
    )
    raw_output_record = require_exact_fields(
        receipt.get("raw_generation_output"),
        OUTPUT_RECEIPT_FIELDS,
        "generation receipt raw output",
    )
    output_record = require_exact_fields(
        receipt.get("generation_output"),
        DELIVERED_OUTPUT_RECEIPT_FIELDS,
        "generation receipt delivered output",
    )
    bundle = resolved_receipt.parent
    prompt_path = direct_child_file(bundle, prompt_record.get("file"), "rendered prompts")
    raw_output_path = direct_child_file(
        bundle, raw_output_record.get("file"), "raw generation output"
    )
    output_path = direct_child_file(
        bundle, output_record.get("file"), "delivered generation output"
    )
    for evidence_path in (prompt_path, raw_output_path, output_path):
        if evidence_path in used_files:
            raise FinalistGateError("prompt or output evidence file is reused")
        used_files.add(evidence_path)

    prompt_bytes, prompt_sha = read_once(prompt_path, "rendered prompts")
    require_sha(prompt_record.get("sha256"), "rendered prompts")
    if prompt_sha != prompt_record["sha256"]:
        raise FinalistGateError("rendered prompts differ from their receipt")
    if prompt_record.get("row_count") != len(expected_ids):
        raise FinalistGateError("rendered prompt receipt row count is invalid")
    request_identity, prompt_rows = validate_rendered_prompts(
        prompt_bytes,
        expected_cases=expected_cases,
        expected_system_sha=model["system_prompt_sha256"],
        build_user_message=build_user_message,
        output_token_budget=output_token_budget,
        input_would_bypass_polish=input_would_bypass_polish,
        input_would_bypass_context=input_would_bypass_context,
        label="rendered prompts",
    )

    dispatched_ids = [case_id for case_id, _, _ in request_identity]
    raw_output_bytes, raw_output_sha = read_once(
        raw_output_path, "raw generation output"
    )
    require_sha(raw_output_record.get("sha256"), "raw generation output")
    if raw_output_sha != raw_output_record["sha256"]:
        raise FinalistGateError("raw generation output differs from its receipt")
    if raw_output_record.get("row_count") != len(dispatched_ids):
        raise FinalistGateError("raw generation output receipt row count is invalid")
    raw_rows, raw_error_count, raw_empty_count = validate_generation_output(
        raw_output_bytes, expected_ids=dispatched_ids, label="raw generation output"
    )
    if raw_output_record.get("generation_error_count") != raw_error_count:
        raise FinalistGateError("raw generation output receipt error count is invalid")
    if raw_output_record.get("empty_output_count") != raw_empty_count:
        raise FinalistGateError("raw generation output receipt empty count is invalid")
    if raw_error_count != 0 or raw_empty_count != 0:
        raise FinalistGateError("raw generation output is partial, failed, or empty")

    expected_delivered_rows, fallback_count = build_delivered_output_rows(
        expected_cases=expected_cases,
        prompt_rows=prompt_rows,
        raw_rows=raw_rows,
        apply_message_output_validation=apply_message_output_validation,
    )
    output_bytes, output_sha = read_once(output_path, "generation output")
    require_sha(output_record.get("sha256"), "generation output")
    if output_sha != output_record["sha256"]:
        raise FinalistGateError("generation output differs from its receipt")
    if output_record.get("row_count") != len(expected_ids):
        raise FinalistGateError("generation output receipt row count is invalid")
    validate_delivered_output(
        output_bytes,
        expected_rows=expected_delivered_rows,
        label="generation output",
    )
    if output_record.get("generation_error_count") != 0:
        raise FinalistGateError("generation output receipt error count is invalid")
    if output_record.get("empty_output_count") != 0:
        raise FinalistGateError("generation output receipt empty count is invalid")
    if output_record.get("post_validation_fallback_count") != fallback_count:
        raise FinalistGateError("generation output fallback count is invalid")

    snapshots.update(
        {
            resolved_receipt: receipt_sha,
            prompt_path: prompt_sha,
            raw_output_path: raw_output_sha,
            output_path: output_sha,
        }
    )
    return {
        "arm": arm,
        "suite": suite,
        "receipt_sha256": receipt_sha,
        "producer": producer,
        "runtime": runtime,
        "model": model,
        "request_identity": request_identity,
        "rendered_prompts_sha256": prompt_sha,
        "raw_generation_output_sha256": raw_output_sha,
        "generation_output_sha256": output_sha,
        "case_count": len(expected_ids),
    }


def validate_cross_receipt_contract(records: list[dict[str, Any]]) -> None:
    expected_pairs = {(arm, suite) for arm in ARMS for suite in SUITES}
    observed_pairs = [(record["arm"], record["suite"]) for record in records]
    if len(records) != len(expected_pairs) or set(observed_pairs) != expected_pairs:
        raise FinalistGateError(
            "exactly one generation receipt is required for each arm and suite"
        )
    if len(set(observed_pairs)) != len(observed_pairs):
        raise FinalistGateError("generation receipt arm/suite mapping is duplicated")

    session_by_arm: dict[str, tuple[Any, ...]] = {}
    for arm in ARMS:
        arm_records = [record for record in records if record["arm"] == arm]
        identities = {
            (
                record["runtime"]["session_id"],
                record["runtime"]["app_pid"],
                record["runtime"]["server_pid"],
                record["runtime"]["parent_pid"],
            )
            for record in arm_records
        }
        if len(identities) != 1:
            raise FinalistGateError("runtime session changed between suites within an arm")
        session_by_arm[arm] = next(iter(identities))
    if session_by_arm["baseline"][0] == session_by_arm["finalist"][0]:
        raise FinalistGateError("baseline and finalist reused one runtime session ID")
    if session_by_arm["baseline"][1:3] == session_by_arm["finalist"][1:3]:
        raise FinalistGateError("baseline and finalist reused one app/server process pair")

    for suite in SUITES:
        baseline = next(
            record
            for record in records
            if record["arm"] == "baseline" and record["suite"] == suite
        )
        finalist = next(
            record
            for record in records
            if record["arm"] == "finalist" and record["suite"] == suite
        )
        if baseline["request_identity"] != finalist["request_identity"]:
            raise FinalistGateError(
                f"{suite} prompt requests differ across arms"
            )


def recheck_snapshots(snapshots: dict[Path, str]) -> None:
    for path, expected_sha in snapshots.items():
        if not path.is_file() or path.is_symlink() or sha256_file(path) != expected_sha:
            raise FinalistGateError("evidence changed during finalist-gate validation")


def build_validated_manifest(
    *,
    lock: dict[str, Any],
    lock_sha: str,
    contract_sha: str,
    evidence_pin_sha: str,
    records: list[dict[str, Any]],
) -> dict[str, Any]:
    by_pair = {(record["arm"], record["suite"]): record for record in records}
    arms: dict[str, Any] = {}
    for arm in ARMS:
        sample = by_pair[(arm, SUITES[0])]
        arms[arm] = {
            "designation": lock["arms"][arm]["designation"],
            "model": sample["model"],
            "runtime_session_id": sample["runtime"]["session_id"],
            "app_pid": sample["runtime"]["app_pid"],
            "server_pid": sample["runtime"]["server_pid"],
        }
    suites: dict[str, Any] = {}
    for suite in SUITES:
        suites[suite] = {
            "corpus": lock["suites"][suite],
            "receipts": {
                arm: {
                    "receipt_sha256": by_pair[(arm, suite)]["receipt_sha256"],
                    "rendered_prompts_sha256": by_pair[(arm, suite)][
                        "rendered_prompts_sha256"
                    ],
                    "generation_output_sha256": by_pair[(arm, suite)][
                        "generation_output_sha256"
                    ],
                    "case_count": by_pair[(arm, suite)]["case_count"],
                }
                for arm in ARMS
            },
        }
    return {
        "schema_version": VALIDATED_SCHEMA,
        "status": "custodian_signed_operator_pinned_controlled_evidence_complete",
        "lock_id": lock["lock_id"],
        "lock_manifest_sha256": lock_sha,
        "gate_contract_sha256": contract_sha,
        "evidence_pin_sha256": evidence_pin_sha,
        "execution_git_head": lock["execution_git_head"],
        "tracked_worktree_clean": True,
        "tooling": lock["tooling"],
        "runtime": lock["runtime"],
        "arms": arms,
        "suites": suites,
        "publication": {
            "strategy": "exclusive_validated_manifest_after_complete_recheck",
            "raw_text_in_manifest": False,
            "process_topology_and_path_identity_observed": True,
            "loaded_executable_and_model_bytes_verified": False,
            "receipt_custodian_signature_verified": True,
            "signature_proves_producer_execution": False,
            "non_exportable_external_signer_verified": False,
            "signed_app_build_provenance_verified": True,
            "operator_supplied_receipt_hash_pin_verified": True,
            "independent_pin_custody_verified": False,
            "sibling_import_bytes_preverified_before_execution": False,
            "external_tool_paths_and_bytes_verified": True,
            "controlled_language_from_locked_corpus": True,
            "post_validation_reconstructed_by_python_mirror": True,
            "claims_exact_mac_evidence_complete": False,
            "claims_literal_end_user_delivery_parity": False,
        },
    }


def validate_gate(
    *,
    lock_path: Path,
    corpus_paths: dict[str, Path],
    receipt_paths: list[Path],
    attestation_public_key_path: Path,
    evidence_pin_path: Path,
    expected_evidence_pin_sha256: str,
) -> tuple[dict[str, Any], dict[Path, str]]:
    reject_import_shadows()
    lock_path = lock_path.expanduser().absolute()
    if not lock_path.is_file() or lock_path.is_symlink():
        raise FinalistGateError("finalist lock is unavailable or is a symlink")
    lock_path = lock_path.resolve()
    if len(receipt_paths) != len(ARMS) * len(SUITES):
        raise FinalistGateError(
            "exactly one generation receipt is required for each arm and suite"
        )
    lock, lock_sha, tooling = load_lock(lock_path)
    public_key, public_key_sha, public_key_path = load_attestation_public_key(
        lock, attestation_public_key_path
    )
    pinned_receipts, evidence_pin_sha, evidence_pin_path = load_evidence_pin(
        evidence_pin_path,
        expected_sha256=expected_evidence_pin_sha256,
        lock_sha256=lock_sha,
    )
    require_git_state(lock["execution_git_head"])
    shipped_request_module = load_shipped_request_module()
    cases_by_suite, snapshots = load_corpora(lock, corpus_paths)
    contract_sha = sha256_file(CONTRACT_PATH)
    snapshots.update(
        {
            lock_path: lock_sha,
            public_key_path: public_key_sha,
            evidence_pin_path: evidence_pin_sha,
            CONTRACT_PATH: contract_sha,
            **{path: tooling[name] for name, path in TOOLING_PATHS.items()},
        }
    )
    used_files: set[Path] = set(snapshots)
    records = [
        validate_receipt(
            path.expanduser().absolute(),
            lock=lock,
            lock_sha=lock_sha,
            tooling=tooling,
            cases_by_suite=cases_by_suite,
            build_user_message=shipped_request_module.build_user_message,
            output_token_budget=shipped_request_module.output_token_budget,
            input_would_bypass_polish=(
                shipped_request_module.input_would_bypass_polish
            ),
            input_would_bypass_context=(
                shipped_request_module.input_would_bypass_context
            ),
            apply_message_output_validation=(
                shipped_request_module.apply_message_output_validation
            ),
            attestation_public_key=public_key,
            used_files=used_files,
            snapshots=snapshots,
        )
        for path in receipt_paths
    ]
    validate_cross_receipt_contract(records)
    observed_receipts = {
        (record["arm"], record["suite"]): record["receipt_sha256"]
        for record in records
    }
    if observed_receipts != pinned_receipts:
        raise FinalistGateError(
            "generation receipt hashes differ from the operator-predeclared evidence pin"
        )
    require_git_state(lock["execution_git_head"])
    recheck_snapshots(snapshots)
    manifest = build_validated_manifest(
        lock=lock,
        lock_sha=lock_sha,
        contract_sha=contract_sha,
        evidence_pin_sha=evidence_pin_sha,
        records=records,
    )
    return manifest, snapshots


def write_exclusive(path: Path, value: bytes) -> None:
    created = False
    try:
        with path.open("xb") as handle:
            created = True
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        if created:
            try:
                path.unlink(missing_ok=True)
            except OSError:
                pass
        raise


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock-manifest", required=True, type=Path)
    parser.add_argument(
        "--corpus",
        action="append",
        default=[],
        help="One SUITE=PATH binding for development, frozen, and type_b_v2.",
    )
    parser.add_argument(
        "--generation-receipt", action="append", default=[], type=Path
    )
    parser.add_argument("--attestation-public-key", required=True, type=Path)
    parser.add_argument("--evidence-pin-manifest", required=True, type=Path)
    parser.add_argument("--expected-evidence-pin-sha256", required=True)
    parser.add_argument("--manifest-out", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    try:
        require_isolated_cli()
    except FinalistGateError as error:
        print(f"exact-Mac finalist gate failed: {error}", file=sys.stderr)
        return 2
    args = parse_args()
    output = args.manifest_out.expanduser().absolute()
    if output.exists() or output.is_symlink():
        print("exact-Mac finalist gate failed: output already exists", file=sys.stderr)
        return 2
    if not output.parent.is_dir():
        print("exact-Mac finalist gate failed: output parent is missing", file=sys.stderr)
        return 2
    try:
        corpus_paths = parse_corpus_specs(args.corpus)
        manifest, snapshots = validate_gate(
            lock_path=args.lock_manifest,
            corpus_paths=corpus_paths,
            receipt_paths=args.generation_receipt,
            attestation_public_key_path=args.attestation_public_key,
            evidence_pin_path=args.evidence_pin_manifest,
            expected_evidence_pin_sha256=args.expected_evidence_pin_sha256,
        )
        manifest_bytes = (
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        ).encode("utf-8")
        require_git_state(manifest["execution_git_head"])
        recheck_snapshots(snapshots)
        write_exclusive(output, manifest_bytes)
    except (FinalistGateError, OSError) as error:
        print(f"exact-Mac finalist gate failed: {error}", file=sys.stderr)
        return 2
    print(
        canonical_json(
            {
                "status": manifest["status"],
                "manifest_sha256": sha256_bytes(manifest_bytes),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
