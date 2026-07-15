#!/usr/bin/env python3
"""Run exact EG-1 evaluation without printing the app's local credential.

The EnviousWispr app chooses a loopback port and bearer credential at launch.
This wrapper discovers both inside the process, validates that the server belongs
to an EnviousWispr app bundle, and passes the credential to the existing runner
only through its child environment.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.request


EVAL_DIR = Path(__file__).resolve().parent
RUNNER = EVAL_DIR / "subset_polish_runner.py"
SHIPPED_RUNTIME_FLAGS = {
    "-c": "16384",
    "-fa": "on",
    "--cache-type-k": "q8_0",
    "--cache-type-v": "q8_0",
}


class LocalServerDiscoveryError(RuntimeError):
    """The live app server could not be identified without ambiguity."""


@dataclass(frozen=True)
class ModelArtifactIdentity:
    entrypoint_path: Path
    revision: str
    manifest_sha256: str
    total_bytes: int
    components: tuple[tuple[str, int, str], ...]

    def public_receipt(self) -> dict[str, object]:
        return {
            "entrypoint_path": str(self.entrypoint_path),
            "revision": self.revision,
            "manifest_sha256": self.manifest_sha256,
            "total_bytes": self.total_bytes,
            "components": [
                {"file": name, "size_bytes": size, "sha256": sha}
                for name, size, sha in self.components
            ],
            "all_component_hashes_verified": True,
        }


@dataclass(frozen=True)
class LocalServer:
    pid: int
    parent_pid: int
    app_bundle: Path
    host: str
    port: int
    credential: str = field(repr=False)
    model_path: Path | None = None
    model_artifact: ModelArtifactIdentity | None = None

    @property
    def endpoint(self) -> str:
        return f"http://{self.host}:{self.port}/v1/chat/completions"

    def public_summary(self) -> str:
        artifact = (
            f" model_revision={self.model_artifact.revision}"
            f" model_manifest_sha256={self.model_artifact.manifest_sha256}"
            if self.model_artifact is not None
            else " model_artifact_verified=false"
        )
        return (
            f"server_pid={self.pid} app_bundle={self.app_bundle} "
            f"endpoint={self.endpoint}{artifact} "
            "credential_present=true"
        )


def _run_text(command: list[str]) -> str:
    completed = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    if completed.returncode != 0:
        raise LocalServerDiscoveryError("local EG-1 process discovery failed")
    return completed.stdout.strip()


def _single_flag_value(command_line: str, flag: str) -> str:
    matches = re.findall(rf"(?:^|\s){re.escape(flag)}\s+(\S+)", command_line)
    if len(matches) != 1:
        raise LocalServerDiscoveryError(f"expected exactly one {flag} value")
    return matches[0]


def parse_server_flags(command_line: str) -> tuple[str, int, str]:
    """Extract safe connection fields without including values in errors."""

    host = _single_flag_value(command_line, "--host")
    port_text = _single_flag_value(command_line, "--port")
    credential = _single_flag_value(command_line, "--api-key")

    if host != "127.0.0.1":
        raise LocalServerDiscoveryError("local EG-1 server is not loopback-only")
    try:
        port = int(port_text)
    except ValueError as error:
        raise LocalServerDiscoveryError("local EG-1 server port is invalid") from error
    if not 1 <= port <= 65535:
        raise LocalServerDiscoveryError("local EG-1 server port is out of range")
    if len(credential) < 32 or any(character.isspace() for character in credential):
        raise LocalServerDiscoveryError("local EG-1 server credential is invalid")
    return host, port, credential


def validate_shipped_runtime_flags(command_line: str) -> None:
    for flag, expected in SHIPPED_RUNTIME_FLAGS.items():
        if _single_flag_value(command_line, flag) != expected:
            raise LocalServerDiscoveryError(
                f"local EG-1 server does not use the shipped {flag} setting"
            )


def parse_model_path(command_line: str) -> Path:
    next_flags = (
        "--host",
        "--port",
        "--api-key",
        "-c",
        "-fa",
        "--cache-type-k",
        "--cache-type-v",
    )
    boundary = "|".join(re.escape(value) for value in next_flags)
    matches = re.findall(
        rf"(?:^|\s)-m\s+(.+?)(?=\s+(?:{boundary})(?:\s|$)|$)",
        command_line,
    )
    if len(matches) != 1:
        raise LocalServerDiscoveryError("expected exactly one local EG-1 model path")
    value = matches[0].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        value = value[1:-1]
    if not value:
        raise LocalServerDiscoveryError("local EG-1 model path is invalid")
    return Path(value)


def _stable_file_sha256(path: Path, expected_size: int) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            stat_before = os.fstat(handle.fileno())
            total = 0
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                total += len(chunk)
                digest.update(chunk)
            stat_after = os.fstat(handle.fileno())
    except OSError as error:
        raise LocalServerDiscoveryError("local EG-1 model component is unavailable") from error
    identity_before = (
        stat_before.st_dev,
        stat_before.st_ino,
        stat_before.st_size,
        stat_before.st_mtime_ns,
    )
    identity_after = (
        stat_after.st_dev,
        stat_after.st_ino,
        stat_after.st_size,
        stat_after.st_mtime_ns,
    )
    if identity_before != identity_after or total != expected_size:
        raise LocalServerDiscoveryError("local EG-1 model component changed while hashing")
    return digest.hexdigest()


def verify_model_artifact(app_bundle: Path, model_path: Path) -> ModelArtifactIdentity:
    manifest_path = app_bundle / "Contents" / "Resources" / "eg1-delivery-manifest.json"
    try:
        manifest_bytes = manifest_path.read_bytes()
        manifest = json.loads(manifest_bytes)
        resolved_model = model_path.resolve(strict=True)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LocalServerDiscoveryError("local EG-1 delivery identity is unavailable") from error
    if not isinstance(manifest, dict):
        raise LocalServerDiscoveryError("local EG-1 delivery manifest is invalid")
    identity = manifest.get("identity")
    admission = manifest.get("admission")
    files = manifest.get("files")
    if (
        not isinstance(identity, dict)
        or identity.get("name") != "eg-1"
        or not isinstance(identity.get("revision"), str)
        or not identity["revision"]
        or not isinstance(admission, dict)
        or admission.get("layout") != "componentSet"
        or not isinstance(admission.get("entrypointFile"), str)
        or not isinstance(files, list)
        or not files
    ):
        raise LocalServerDiscoveryError("local EG-1 delivery manifest is invalid")
    if resolved_model.name != admission["entrypointFile"]:
        raise LocalServerDiscoveryError("llama-server is not using the manifest entrypoint")

    model_directory = resolved_model.parent
    components: list[tuple[str, int, str]] = []
    seen: set[str] = set()
    total_bytes = 0
    for record in files:
        if not isinstance(record, dict):
            raise LocalServerDiscoveryError("local EG-1 component record is invalid")
        name = record.get("installPath")
        size = record.get("sizeBytes")
        expected_sha = record.get("sha256")
        if (
            not isinstance(name, str)
            or not name
            or name in seen
            or Path(name).is_absolute()
            or len(Path(name).parts) != 1
            or not isinstance(size, int)
            or size <= 0
            or not isinstance(expected_sha, str)
            or not re.fullmatch(r"[0-9a-f]{64}", expected_sha)
        ):
            raise LocalServerDiscoveryError("local EG-1 component record is invalid")
        component = model_directory / name
        try:
            if component.is_symlink() or component.resolve(strict=True).parent != model_directory:
                raise LocalServerDiscoveryError("local EG-1 component path is invalid")
        except OSError as error:
            raise LocalServerDiscoveryError("local EG-1 component is unavailable") from error
        actual_sha = _stable_file_sha256(component, size)
        if actual_sha != expected_sha:
            raise LocalServerDiscoveryError("local EG-1 component hash is invalid")
        seen.add(name)
        total_bytes += size
        components.append((name, size, actual_sha))
    if total_bytes != manifest.get("totalBytes"):
        raise LocalServerDiscoveryError("local EG-1 total size is invalid")
    if admission["entrypointFile"] not in seen:
        raise LocalServerDiscoveryError("local EG-1 entrypoint is not declared")
    return ModelArtifactIdentity(
        entrypoint_path=resolved_model,
        revision=identity["revision"],
        manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(),
        total_bytes=total_bytes,
        components=tuple(components),
    )


def _app_bundle_for(executable: Path, expected_leaf: tuple[str, str]) -> Path:
    if executable.name != expected_leaf[1] or executable.parent.name != expected_leaf[0]:
        raise LocalServerDiscoveryError("local EG-1 process has an unexpected executable path")
    try:
        contents = executable.parent.parent
        app_bundle = contents.parent
    except IndexError as error:
        raise LocalServerDiscoveryError("local EG-1 process has an incomplete bundle path") from error
    if contents.name != "Contents" or app_bundle.suffix != ".app":
        raise LocalServerDiscoveryError("local EG-1 process is not inside an app bundle")
    return app_bundle


def discover_server(
    expected_app_bundle: Path, server_pid: int | None = None
) -> LocalServer:
    if server_pid is None:
        pid_text = _run_text(["pgrep", "-x", "llama-server"])
        pid_values = [value for value in pid_text.splitlines() if value.strip()]
        if len(pid_values) != 1:
            raise LocalServerDiscoveryError(
                "expected exactly one llama-server; pass --server-pid after checking PIDs only"
            )
        try:
            server_pid = int(pid_values[0])
        except ValueError as error:
            raise LocalServerDiscoveryError("llama-server PID is invalid") from error
    if server_pid <= 0:
        raise LocalServerDiscoveryError("llama-server PID is invalid")

    parent_text = _run_text(["ps", "-p", str(server_pid), "-o", "ppid="])
    try:
        parent_pid = int(parent_text)
    except ValueError as error:
        raise LocalServerDiscoveryError("llama-server parent PID is invalid") from error

    server_executable = Path(
        _run_text(["ps", "-p", str(server_pid), "-o", "comm="])
    )
    parent_executable = Path(
        _run_text(["ps", "-p", str(parent_pid), "-o", "comm="])
    )
    try:
        server_app = _app_bundle_for(
            server_executable, ("Resources", "llama-server")
        ).resolve(strict=True)
        parent_app = _app_bundle_for(
            parent_executable, ("MacOS", "EnviousWispr")
        ).resolve(strict=True)
    except OSError as error:
        raise LocalServerDiscoveryError("local EG-1 app bundle is unavailable") from error
    if server_app != parent_app:
        raise LocalServerDiscoveryError("llama-server does not belong to its parent app")
    try:
        expected_app = expected_app_bundle.resolve(strict=True)
    except OSError as error:
        raise LocalServerDiscoveryError("expected app bundle is unavailable") from error
    if server_app != expected_app:
        raise LocalServerDiscoveryError("llama-server belongs to a different app bundle")

    command_line = _run_text(
        ["ps", "-p", str(server_pid), "-ww", "-o", "args="]
    )
    host, port, credential = parse_server_flags(command_line)
    validate_shipped_runtime_flags(command_line)
    raw_model_path = parse_model_path(command_line)
    model_artifact = verify_model_artifact(server_app, raw_model_path)
    return LocalServer(
        pid=server_pid,
        parent_pid=parent_pid,
        app_bundle=server_app,
        host=host,
        port=port,
        credential=credential,
        model_path=model_artifact.entrypoint_path,
        model_artifact=model_artifact,
    )


def verify_ready(server: LocalServer) -> None:
    request = urllib.request.Request(
        f"http://{server.host}:{server.port}/health",
        headers={"Authorization": f"Bearer {server.credential}"},
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=2) as response:
            if response.status != 200:
                raise LocalServerDiscoveryError("local EG-1 endpoint is not ready")
    except (OSError, urllib.error.URLError) as error:
        raise LocalServerDiscoveryError("local EG-1 endpoint is not ready") from error


def runner_environment(credential: str) -> dict[str, str]:
    return {
        "OPENAI_API_KEY": credential,
        "NO_PROXY": "127.0.0.1",
        "no_proxy": "127.0.0.1",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prompts")
    parser.add_argument("--model", choices=("eg-1",), default="eg-1")
    parser.add_argument("--out")
    parser.add_argument("--server-pid", type=int)
    parser.add_argument("--app-bundle", required=True, type=Path)
    parser.add_argument("--preflight-only", action="store_true")
    args = parser.parse_args()

    if not args.preflight_only and (not args.prompts or not args.out):
        parser.error("--prompts and --out are required unless --preflight-only is used")
    if not args.preflight_only:
        prompts_path = Path(args.prompts)
        output_path = Path(args.out)
        if not prompts_path.is_file():
            parser.error("--prompts must name an existing file")
        if output_path.exists() or output_path.is_symlink():
            parser.error("--out already exists; refusing to overwrite evaluation evidence")
        if not output_path.parent.is_dir():
            parser.error("--out parent directory must already exist")

    try:
        server = discover_server(args.app_bundle, args.server_pid)
        verify_ready(server)
    except LocalServerDiscoveryError as error:
        print(f"EG-1 local preflight failed: {error}", file=sys.stderr)
        return 2

    print(server.public_summary(), flush=True)
    if args.preflight_only:
        return 0

    environment = runner_environment(server.credential)
    command = [
        sys.executable,
        "-E",
        "-s",
        str(RUNNER),
        "--prompts",
        args.prompts,
        "--provider",
        "openai",
        "--model",
        args.model,
        "--out",
        args.out,
        "--workers",
        "1",
        "--endpoint",
        server.endpoint,
        "--eg1-shipped-request",
    ]
    try:
        completed = subprocess.run(command, check=False, env=environment)
    finally:
        environment.pop("OPENAI_API_KEY", None)
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
