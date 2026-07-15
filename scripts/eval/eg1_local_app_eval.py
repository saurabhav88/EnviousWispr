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
class LocalServer:
    pid: int
    parent_pid: int
    app_bundle: Path
    host: str
    port: int
    credential: str = field(repr=False)

    @property
    def endpoint(self) -> str:
        return f"http://{self.host}:{self.port}/v1/chat/completions"

    def public_summary(self) -> str:
        return (
            f"server_pid={self.pid} app_bundle={self.app_bundle} "
            f"endpoint={self.endpoint} "
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
    return LocalServer(
        pid=server_pid,
        parent_pid=parent_pid,
        app_bundle=server_app,
        host=host,
        port=port,
        credential=credential,
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
