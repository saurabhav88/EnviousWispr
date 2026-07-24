#!/usr/bin/env python3
"""Produce one lock-bound exact-Mac EG-1 generation receipt.

This producer records stable app process and path identities, renders requests
with the shipping mirror, and runs one sealed suite. It requires app-embedded
build provenance covered by a valid code signature, rechecks each recorded
identity, signs the receipt with an exportable custodian key, and publishes it
last. The signature and operator pin protect the recorded evidence; they do not
authenticate independent producer execution or the bytes already loaded by the
app. The producer never records the local bearer credential or prints prompt or
model output text.
"""

from __future__ import annotations

import sys as _bootstrap_sys

if __name__ == "__main__" and not _bootstrap_sys.flags.isolated:
    _bootstrap_sys.stderr.write(
        "exact-Mac receipt production failed: run with isolated Python (python3 -I)\n"
    )
    raise SystemExit(2)

import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from typing import Any


def _load_absolute_sibling(module_name: str, filename: str) -> Any:
    path = Path(__file__).resolve().with_name(filename)
    if not path.is_file() or path.is_symlink():
        raise ImportError(f"required evidence sibling {filename} is unavailable")
    existing = sys.modules.get(module_name)
    if existing is not None and Path(getattr(existing, "__file__", "")).resolve() == path:
        return existing
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load evidence sibling {filename}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


gate = _load_absolute_sibling(
    "eg1_exact_mac_finalist_gate", "eg1_exact_mac_finalist_gate.py"
)
_local_app = _load_absolute_sibling("eg1_local_app_eval", "eg1_local_app_eval.py")
_local_app.configure_external_tools(gate.external_tool_bindings({"pgrep", "ps"}))
LocalServer = _local_app.LocalServer
LocalServerDiscoveryError = _local_app.LocalServerDiscoveryError
discover_server = _local_app.discover_server
runner_environment = _local_app.runner_environment
verify_ready = _local_app.verify_ready


SCRIPT_PATH = Path(__file__).resolve()
EVAL_DIR = SCRIPT_PATH.parent
RUNNER = EVAL_DIR / "subset_polish_runner.py"
CANONICAL_SHIPPED_PROMPT = EVAL_DIR / "prompts" / "eg1-polish-prompt-v1.txt"
PRODUCER_SCHEMA = "eg1-exact-mac-receipt-producer-v1"


class ReceiptProducerError(RuntimeError):
    """The exact-Mac runtime or requested evidence did not match the lock."""


def path_identity_sha256(path: Path) -> str:
    return gate.sha256_bytes((str(path.resolve()) + "\n").encode("utf-8"))


def model_artifact_sha256(server: LocalServer) -> str:
    artifact = server.model_artifact
    if artifact is None:
        raise ReceiptProducerError("live model artifact identity is unavailable")
    identity = {
        "component_sha256": sorted(sha for _, _, sha in artifact.components),
    }
    return gate.sha256_bytes(gate.canonical_json(identity).encode("utf-8"))


def app_identity(server: LocalServer) -> dict[str, str]:
    app = server.app_bundle
    paths = {
        "app_bundle_manifest_sha256": app
        / "Contents"
        / "_CodeSignature"
        / "CodeResources",
        "app_executable_sha256": app / "Contents" / "MacOS" / "EnviousWispr",
        "llama_server_sha256": app / "Contents" / "Resources" / "llama-server",
        "app_system_prompt_resource_sha256": app
        / gate.APP_SYSTEM_PROMPT_RELATIVE_PATH,
        "app_build_provenance_sha256": app
        / gate.APP_BUILD_PROVENANCE_RELATIVE_PATH,
    }
    identity = {"app_bundle_path_sha256": path_identity_sha256(app)}
    for field, path in paths.items():
        if not path.is_file() or path.is_symlink():
            if field in {
                "app_build_provenance_sha256",
                "app_system_prompt_resource_sha256",
            }:
                raise ReceiptProducerError(
                    "app lacks required exact-Mac build provenance/prompt; current builds are not certifiable"
                )
            raise ReceiptProducerError(f"live app {field} source is unavailable")
        identity[field] = gate.sha256_file(path.resolve())
    identity["shipped_runtime_flags_sha256"] = gate.shipped_runtime_flags_sha256()
    identity["swift_runtime_identity_sha256"] = gate.swift_runtime_identity_sha256()
    identity["python_runtime_identity_sha256"] = gate.python_runtime_identity_sha256()
    identity["external_toolchain_identity_sha256"] = (
        gate.external_toolchain_identity_sha256()
    )
    return identity


def require_signed_provenance_inventory(app: Path) -> None:
    try:
        codesign = gate.pinned_external_tool("codesign")
        completed = subprocess.run(
            [str(codesign), "--verify", "--deep", "--strict", str(app)],
            check=False,
            env=gate.sanitized_external_tool_environment(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError as error:
        raise ReceiptProducerError("cannot verify the live app code signature") from error
    if completed.returncode != 0:
        raise ReceiptProducerError("live app code signature is invalid")
    manifest_path = app / "Contents" / "_CodeSignature" / "CodeResources"
    try:
        manifest = plistlib.loads(manifest_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        raise ReceiptProducerError("live app CodeResources is not a valid plist") from error
    if not isinstance(manifest, dict):
        raise ReceiptProducerError("live app CodeResources inventory is invalid")
    required = {
        str(gate.APP_BUILD_PROVENANCE_RELATIVE_PATH.relative_to("Contents")),
        str(gate.APP_SYSTEM_PROMPT_RELATIVE_PATH.relative_to("Contents")),
    }
    inventories = [manifest.get("files"), manifest.get("files2")]
    covered = {
        path
        for inventory in inventories
        if isinstance(inventory, dict)
        for path in required
        if path in inventory
    }
    if covered != required:
        raise ReceiptProducerError(
            "app build provenance/prompt is not covered by the CodeResources inventory"
        )


def verify_app_build_provenance(
    server: LocalServer, lock: dict[str, Any], arm: str, identity: dict[str, str]
) -> None:
    """Require future build-owned proof that app bytes match the eval mirror."""

    provenance_path = server.app_bundle / gate.APP_BUILD_PROVENANCE_RELATIVE_PATH
    if not provenance_path.is_file() or provenance_path.is_symlink():
        raise ReceiptProducerError(
            "app lacks required exact-Mac build provenance; current builds are not certifiable"
        )
    require_signed_provenance_inventory(server.app_bundle)
    value, digest = gate.read_once(provenance_path.resolve(), "app build provenance")
    if digest != lock["arms"][arm]["app_build_provenance_sha256"]:
        raise ReceiptProducerError("app build provenance differs from the locked arm")
    provenance = gate.parse_json(value, "app build provenance")
    gate.require_exact_fields(
        provenance,
        gate.APP_BUILD_PROVENANCE_FIELDS,
        "app build provenance",
    )
    expected = {
        "schema_version": gate.APP_BUILD_PROVENANCE_SCHEMA,
        "build_git_head": lock["execution_git_head"],
        "app_executable_sha256": identity["app_executable_sha256"],
        "llama_server_sha256": identity["llama_server_sha256"],
        "delivery_manifest_sha256": lock["arms"][arm]["delivery_manifest_sha256"],
        "system_prompt_source_sha256": lock["arms"][arm][
            "system_prompt_source_sha256"
        ],
        "system_prompt_sha256": lock["arms"][arm]["system_prompt_sha256"],
        "evaluation_config_sha256": lock["arms"][arm]["evaluation_config_sha256"],
        "app_system_prompt_resource_sha256": identity[
            "app_system_prompt_resource_sha256"
        ],
        **{
            field: gate.sha256_file(path)
            for field, path in gate.APP_BUILD_SOURCE_PATHS.items()
        },
    }
    if provenance != expected:
        raise ReceiptProducerError(
            "app build provenance does not bind the locked shipped prompt/request/runtime"
        )

    embedded_prompt = model_visible_system_prompt(
        (server.app_bundle / gate.APP_SYSTEM_PROMPT_RELATIVE_PATH).read_bytes()
    )
    if gate.sha256_bytes(embedded_prompt.encode("utf-8")) != lock["arms"][arm][
        "system_prompt_sha256"
    ]:
        raise ReceiptProducerError(
            "app-embedded compiled system prompt differs from the locked shipped prompt"
        )


def load_signing_keys(
    lock: dict[str, Any], private_key_path: Path, public_key_path: Path
) -> tuple[bytes, bytes, dict[Path, str]]:
    paths = {
        "attestation private key": private_key_path.expanduser().absolute(),
        "attestation public key": public_key_path.expanduser().absolute(),
    }
    values: dict[str, bytes] = {}
    snapshots: dict[Path, str] = {}
    for label, path in paths.items():
        if not path.is_file() or path.is_symlink():
            raise ReceiptProducerError(f"{label} is unavailable or is a symlink")
        resolved = path.resolve()
        value, digest = gate.read_once(resolved, label)
        values[label] = value
        snapshots[resolved] = digest
    locked = lock["attestation"]
    if snapshots[paths["attestation public key"].resolve()] != locked[
        "public_key_sha256"
    ]:
        raise ReceiptProducerError("attestation public key differs from the finalist lock")
    probe = b"eg1-exact-mac-attestation-key-pair-v1"
    signature = sign_ed25519(probe, values["attestation private key"])
    if not gate.verify_ed25519_signature(
        probe, signature, values["attestation public key"]
    ):
        raise ReceiptProducerError("attestation private/public key pair does not match")
    return (
        values["attestation private key"],
        values["attestation public key"],
        snapshots,
    )


def sign_ed25519(payload: bytes, private_key: bytes) -> bytes:
    with tempfile.TemporaryDirectory(prefix="eg1-receipt-sign-") as raw_temp:
        temp = Path(raw_temp)
        private_key_path = temp / "private.pem"
        payload_path = temp / "payload.json"
        signature_path = temp / "signature.bin"
        private_key_path.write_bytes(private_key)
        private_key_path.chmod(0o600)
        payload_path.write_bytes(payload)
        try:
            openssl = gate.pinned_external_tool("openssl")
            completed = subprocess.run(
                [
                    str(openssl),
                    "pkeyutl",
                    "-sign",
                    "-inkey",
                    str(private_key_path),
                    "-rawin",
                    "-in",
                    str(payload_path),
                    "-out",
                    str(signature_path),
                ],
                check=False,
                env=gate.sanitized_external_tool_environment(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except OSError as error:
            raise ReceiptProducerError("cannot run Ed25519 receipt signing") from error
        if completed.returncode != 0 or not signature_path.is_file():
            raise ReceiptProducerError("Ed25519 receipt signing failed")
        signature = signature_path.read_bytes()
    if len(signature) != 64:
        raise ReceiptProducerError("Ed25519 receipt signature has an invalid size")
    return signature


def runtime_session_id(server: LocalServer) -> str:
    try:
        ps = gate.pinned_external_tool("ps")
        environment = gate.sanitized_external_tool_environment()
        app_started = subprocess.check_output(
            [str(ps), "-p", str(server.parent_pid), "-o", "lstart="],
            env=environment,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        server_started = subprocess.check_output(
            [str(ps), "-p", str(server.pid), "-o", "lstart="],
            env=environment,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise ReceiptProducerError("cannot establish exact-Mac runtime session") from error
    if not app_started or not server_started:
        raise ReceiptProducerError("exact-Mac runtime session start identity is missing")
    value = gate.canonical_json(
        {
            "app_pid": server.parent_pid,
            "app_started": app_started,
            "server_pid": server.pid,
            "server_started": server_started,
            "app_bundle": str(server.app_bundle),
        }
    )
    return f"mac-{gate.sha256_bytes(value.encode('utf-8'))[:32]}"


def same_server(before: LocalServer, after: LocalServer) -> bool:
    return (
        before.pid == after.pid
        and before.parent_pid == after.parent_pid
        and before.app_bundle == after.app_bundle
        and before.host == after.host
        and before.port == after.port
        and before.credential == after.credential
        and before.model_path == after.model_path
        and before.model_artifact == after.model_artifact
    )


def verify_locked_runtime(
    server: LocalServer, lock: dict[str, Any], arm: str
) -> dict[str, str]:
    if server.host != "127.0.0.1" or server.model_artifact is None:
        raise ReceiptProducerError("live server is not the verified shipping runtime")
    identity = app_identity(server)
    verify_app_build_provenance(server, lock, arm, identity)
    for field in gate.RUNTIME_HASH_FIELDS:
        if identity[field] != lock["runtime"][field]:
            raise ReceiptProducerError(f"live shared runtime {field} differs from the lock")
    for field in gate.ARM_RUNTIME_FIELDS:
        if identity[field] != lock["arms"][arm][field]:
            raise ReceiptProducerError(f"live per-arm runtime {field} differs from the lock")
    if server.model_artifact.manifest_sha256 != lock["arms"][arm][
        "delivery_manifest_sha256"
    ]:
        raise ReceiptProducerError("live delivery manifest differs from the locked arm")
    if model_artifact_sha256(server) != lock["arms"][arm]["model_artifact_sha256"]:
        raise ReceiptProducerError("live model artifact differs from the locked arm")
    return identity


def render_prompts(
    cases: list[tuple[str, str, str]], system: str, shipped_request: Any
) -> tuple[bytes, bytes, list[dict[str, Any]]]:
    evidence_rows: list[dict[str, Any]] = []
    runner_rows: list[dict[str, Any]] = []
    for case_id, input_text, language in cases:
        try:
            max_tokens = shipped_request.output_token_budget(input_text)
        except ValueError as error:
            raise ReceiptProducerError(
                "token budget needs a trusted Swift-rendered request"
            ) from error
        if shipped_request.input_would_bypass_polish(input_text, language):
            action = "short_input_bypass"
        elif shipped_request.input_would_bypass_context(input_text, max_tokens):
            action = "context_bypass"
        else:
            action = "dispatch_eg1"
        runner_row = {
            "id": case_id,
            "system": system,
            "user": shipped_request.build_user_message(input_text),
            "max_tokens": max_tokens,
        }
        evidence_rows.append(
            {
                "id": case_id,
                "controlled_language": language,
                "action": action,
                "system": runner_row["system"] if action == "dispatch_eg1" else None,
                "user": runner_row["user"] if action == "dispatch_eg1" else None,
                "max_tokens": (
                    runner_row["max_tokens"] if action == "dispatch_eg1" else None
                ),
            }
        )
        if action == "dispatch_eg1":
            runner_rows.append(runner_row)
    serialize = lambda rows: "".join(
        json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n" for row in rows
    ).encode("utf-8")
    return serialize(evidence_rows), serialize(runner_rows), evidence_rows


def model_visible_system_prompt(value: bytes) -> str:
    try:
        text = value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ReceiptProducerError("system prompt is not valid UTF-8") from error
    prompt = "\n".join(
        line for line in text.splitlines() if not line.startswith("#")
    ).strip()
    if not prompt:
        raise ReceiptProducerError("system prompt has no model-visible text")
    if "{{" in prompt or "}}" in prompt:
        raise ReceiptProducerError("system prompt contains an unresolved template marker")
    return prompt


def write_exclusive(path: Path, value: bytes) -> None:
    with path.open("xb") as handle:
        handle.write(value)
        handle.flush()
        os.fsync(handle.fileno())


def publish_bundle(output: Path, temp: Path, receipt_bytes: bytes) -> None:
    created = False
    try:
        output.mkdir()
        created = True
        os.replace(temp / "prompts.jsonl", output / "prompts.jsonl")
        os.replace(temp / "raw-output.jsonl", output / "raw-output.jsonl")
        os.replace(temp / "output.jsonl", output / "output.jsonl")
        write_exclusive(output / "receipt.json", receipt_bytes)
    except BaseException:
        if created:
            shutil.rmtree(output, ignore_errors=True)
        raise


def produce_receipt(
    *,
    lock_path: Path,
    corpus_paths: dict[str, Path],
    arm: str,
    suite: str,
    app_bundle: Path,
    system_prompt_path: Path,
    attestation_private_key_path: Path,
    attestation_public_key_path: Path,
    output_bundle: Path,
) -> dict[str, Any]:
    gate.reject_import_shadows()
    if arm not in gate.ARMS or suite not in gate.SUITES:
        raise ReceiptProducerError("arm or suite is invalid")
    if output_bundle.exists() or output_bundle.is_symlink():
        raise ReceiptProducerError("output bundle already exists")
    if not output_bundle.parent.is_dir():
        raise ReceiptProducerError("output bundle parent is missing")

    lock_path = lock_path.expanduser().absolute()
    if not lock_path.is_file() or lock_path.is_symlink():
        raise ReceiptProducerError("finalist lock is unavailable or is a symlink")
    lock, lock_sha, tooling = gate.load_lock(lock_path.resolve())
    private_key, public_key, signing_key_snapshots = load_signing_keys(
        lock, attestation_private_key_path, attestation_public_key_path
    )
    gate.require_git_state(lock["execution_git_head"])
    cases_by_suite, corpus_snapshots = gate.load_corpora(lock, corpus_paths)
    shipped_request = gate.load_shipped_request_module()
    control_snapshots = {
        lock_path.resolve(): lock_sha,
        gate.CONTRACT_PATH: gate.sha256_file(gate.CONTRACT_PATH),
        **{path: tooling[name] for name, path in gate.TOOLING_PATHS.items()},
        **signing_key_snapshots,
    }

    source_paths = {
        "system prompt": system_prompt_path.expanduser().absolute(),
    }
    if source_paths["system prompt"].resolve() != CANONICAL_SHIPPED_PROMPT.resolve():
        raise ReceiptProducerError("system prompt path is not the canonical shipped prompt")
    source_snapshots: dict[Path, str] = {}
    source_bytes: dict[str, bytes] = {}
    for label, path in source_paths.items():
        if not path.is_file() or path.is_symlink():
            raise ReceiptProducerError(f"{label} is unavailable or is a symlink")
        value, source_sha = gate.read_once(path.resolve(), label)
        source_bytes[label] = value
        source_snapshots[path.resolve()] = source_sha
    if source_snapshots[source_paths["system prompt"].resolve()] != lock["arms"][arm][
        "system_prompt_source_sha256"
    ]:
        raise ReceiptProducerError("system prompt differs from the locked arm")
    system_prompt = model_visible_system_prompt(source_bytes["system prompt"])
    if gate.sha256_bytes(system_prompt.encode("utf-8")) != lock["arms"][arm][
        "system_prompt_sha256"
    ]:
        raise ReceiptProducerError(
            "model-visible system prompt differs from the locked shipped prompt"
        )
    if lock["arms"][arm][
        "evaluation_config_sha256"
    ] != gate.executed_evaluation_config_sha256(
        lock["arms"][arm]["system_prompt_sha256"]
    ):
        raise ReceiptProducerError(
            "locked evaluation config differs from the settings this producer executes"
        )

    server = discover_server(app_bundle)
    verify_ready(server)
    runtime_identity = verify_locked_runtime(server, lock, arm)
    embedded_system_prompt = model_visible_system_prompt(
        (server.app_bundle / gate.APP_SYSTEM_PROMPT_RELATIVE_PATH).read_bytes()
    )
    if embedded_system_prompt != system_prompt:
        raise ReceiptProducerError(
            "build-generated app system prompt differs from the canonical eval prompt"
        )
    session_id = runtime_session_id(server)
    prompt_bytes, runner_prompt_bytes, prompt_rows = render_prompts(
        cases_by_suite[suite], embedded_system_prompt, shipped_request
    )

    temp = Path(tempfile.mkdtemp(prefix=".eg1-exact-mac-", dir=output_bundle.parent))
    try:
        prompt_path = temp / "prompts.jsonl"
        runner_prompt_path = temp / "runner-prompts.jsonl"
        raw_output_path = temp / "raw-output.jsonl"
        output_path = temp / "output.jsonl"
        write_exclusive(prompt_path, prompt_bytes)
        write_exclusive(runner_prompt_path, runner_prompt_bytes)
        if runner_prompt_bytes:
            swift_launcher, swift_executable = gate.pinned_swift_runtime_paths()
            swift_environment = gate.sanitized_external_tool_environment(swift=True)
            environment = runner_environment(server.credential)
            environment.update(swift_environment)
            command = [
                sys.executable,
                "-I",
                "-E",
                "-s",
                str(RUNNER),
                "--prompts",
                str(runner_prompt_path),
                "--provider",
                "openai",
                "--model",
                gate.MODEL_ID,
                "--out",
                str(raw_output_path),
                "--workers",
                "1",
                "--endpoint",
                server.endpoint,
                "--eg1-shipped-request",
                "--eg1-swift-launcher",
                str(swift_launcher),
                "--eg1-swift-launcher-path-sha256",
                gate.swift_runtime_identity()["swift_launcher_path_sha256"],
                "--eg1-swift-executable",
                str(swift_executable),
                "--eg1-swift-executable-path-sha256",
                gate.swift_runtime_identity()["swift_executable_path_sha256"],
                "--eg1-swift-executable-sha256",
                gate.swift_runtime_identity()["swift_executable_sha256"],
                "--eg1-swift-developer-dir",
                swift_environment.get("DEVELOPER_DIR", "none"),
                "--eg1-swift-environment-sha256",
                gate.swift_environment_sha256(swift_environment),
            ]
            _, python_executable = gate.pinned_python_runtime_paths()
            try:
                completed = subprocess.run(
                    command,
                    check=False,
                    executable=str(python_executable),
                    env=environment,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            finally:
                environment.pop("OPENAI_API_KEY", None)
            if completed.returncode != 0:
                raise ReceiptProducerError("exact-Mac generation runner failed")
        else:
            write_exclusive(raw_output_path, b"")
        after = discover_server(app_bundle, server.pid)
        verify_ready(after)
        if not same_server(server, after):
            raise ReceiptProducerError("exact-Mac server identity changed during generation")
        if verify_locked_runtime(after, lock, arm) != runtime_identity:
            raise ReceiptProducerError("exact-Mac runtime identity changed during generation")
        if runtime_session_id(after) != session_id:
            raise ReceiptProducerError("exact-Mac runtime session changed during generation")

        raw_output_bytes, raw_output_sha = gate.read_once(
            raw_output_path, "raw generation output"
        )
        expected_ids = [case_id for case_id, _, _ in cases_by_suite[suite]]
        dispatched_ids = [
            row["id"] for row in prompt_rows if row["action"] == "dispatch_eg1"
        ]
        raw_output_rows, errors, empty = gate.validate_generation_output(
            raw_output_bytes,
            expected_ids=dispatched_ids,
            label="raw generation output",
        )
        if errors or empty:
            raise ReceiptProducerError(
                "raw generation output is partial, failed, or empty"
            )
        output_rows, fallback_count = gate.build_delivered_output_rows(
            expected_cases=cases_by_suite[suite],
            prompt_rows=prompt_rows,
            raw_rows=raw_output_rows,
            apply_message_output_validation=(
                shipped_request.apply_message_output_validation
            ),
        )
        output_bytes = "".join(
            json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
            for row in output_rows
        ).encode("utf-8")
        write_exclusive(output_path, output_bytes)
        output_sha = gate.sha256_bytes(output_bytes)

        gate.require_git_state(lock["execution_git_head"])
        gate.recheck_snapshots(
            {**control_snapshots, **corpus_snapshots, **source_snapshots}
        )
        if gate.current_tooling_hashes() != tooling:
            raise ReceiptProducerError("locked tooling changed during generation")
        prompt_sha = gate.sha256_bytes(prompt_bytes)
        if gate.sha256_file(prompt_path) != prompt_sha:
            raise ReceiptProducerError("rendered prompts changed during generation")

        runtime = {
            **runtime_identity,
            "session_id": session_id,
            "app_pid": server.parent_pid,
            "server_pid": server.pid,
            "parent_pid": server.parent_pid,
            "loopback_host": server.host,
            "workers": 1,
            "stable_process_and_path_identity_before_after": True,
            "loaded_executable_and_model_bytes_attested": False,
            "credential_present": True,
            "credential_recorded": False,
        }
        model = {
            key: value
            for key, value in lock["arms"][arm].items()
            if key not in {"designation", *gate.ARM_RUNTIME_FIELDS}
        }
        receipt = {
            "schema_version": gate.RECEIPT_SCHEMA,
            "lock_manifest_sha256": lock_sha,
            "arm": arm,
            "suite": suite,
            "execution_git_head": lock["execution_git_head"],
            "tracked_worktree_clean": True,
            "tooling": tooling,
            "producer": {
                "schema_version": PRODUCER_SCHEMA,
                "script_sha256": tooling["exact_mac_receipt_producer_sha256"],
                "receipt_written_by_key_holding_process": True,
                "non_exportable_external_signer_verified": False,
                "loaded_runtime_bytes_verified": False,
            },
            "runtime": runtime,
            "model": model,
            "corpus": lock["suites"][suite],
            "rendered_prompts": {
                "file": "prompts.jsonl",
                "sha256": prompt_sha,
                "row_count": len(expected_ids),
            },
            "raw_generation_output": {
                "file": "raw-output.jsonl",
                "sha256": raw_output_sha,
                "row_count": len(raw_output_rows),
                "generation_error_count": 0,
                "empty_output_count": 0,
            },
            "generation_output": {
                "file": "output.jsonl",
                "sha256": output_sha,
                "row_count": len(output_rows),
                "generation_error_count": 0,
                "empty_output_count": 0,
                "post_validation_fallback_count": fallback_count,
            },
        }
        payload = gate.receipt_attestation_payload(receipt)
        signature = sign_ed25519(payload, private_key)
        if not gate.verify_ed25519_signature(payload, signature, public_key):
            raise ReceiptProducerError("new receipt signature failed local verification")
        receipt["attestation"] = {
            "algorithm": lock["attestation"]["algorithm"],
            "key_id": lock["attestation"]["key_id"],
            "public_key_sha256": lock["attestation"]["public_key_sha256"],
            "payload_sha256": gate.sha256_bytes(payload),
            "signature_base64": base64.b64encode(signature).decode("ascii"),
        }
        receipt_bytes = (
            json.dumps(receipt, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        ).encode("utf-8")
        gate.require_git_state(lock["execution_git_head"])
        gate.recheck_snapshots(
            {**control_snapshots, **corpus_snapshots, **source_snapshots}
        )
        if gate.sha256_file(prompt_path) != prompt_sha:
            raise ReceiptProducerError("rendered prompts changed before publication")
        if gate.sha256_file(raw_output_path) != raw_output_sha:
            raise ReceiptProducerError("raw generation output changed before publication")
        if gate.sha256_file(output_path) != output_sha:
            raise ReceiptProducerError("delivered output changed before publication")
        publish_bundle(output_bundle, temp, receipt_bytes)
        return receipt
    finally:
        shutil.rmtree(temp, ignore_errors=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock-manifest", required=True, type=Path)
    parser.add_argument("--corpus", action="append", default=[])
    parser.add_argument("--arm", required=True, choices=gate.ARMS)
    parser.add_argument("--suite", required=True, choices=gate.SUITES)
    parser.add_argument("--app-bundle", required=True, type=Path)
    parser.add_argument("--system-prompt", required=True, type=Path)
    parser.add_argument("--attestation-private-key", required=True, type=Path)
    parser.add_argument("--attestation-public-key", required=True, type=Path)
    parser.add_argument("--out-bundle", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        receipt = produce_receipt(
            lock_path=args.lock_manifest,
            corpus_paths=gate.parse_corpus_specs(args.corpus),
            arm=args.arm,
            suite=args.suite,
            app_bundle=args.app_bundle,
            system_prompt_path=args.system_prompt,
            attestation_private_key_path=args.attestation_private_key,
            attestation_public_key_path=args.attestation_public_key,
            output_bundle=args.out_bundle.expanduser().absolute(),
        )
    except (
        gate.FinalistGateError,
        LocalServerDiscoveryError,
        ReceiptProducerError,
        OSError,
    ) as error:
        print(f"exact-Mac receipt production failed: {error}", file=sys.stderr)
        return 2
    print(
        gate.canonical_json(
            {
                "status": "custodian_signed_path_evidence_receipt_complete",
                "arm": receipt["arm"],
                "suite": receipt["suite"],
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
