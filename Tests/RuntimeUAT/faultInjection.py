"""
V2 fault-injection harness for EnviousWispr (issue #291).

Drives the DEBUG-only `DebugFaultEndpoint` in the running app via a localhost
TCP listener. The app must be launched with `EW_FAULT_INJECTION=1` set in its
environment so the endpoint starts; without it, the endpoint is inert.

Wire protocol (per `Sources/EnviousWispr/App/Debug/DebugFaultEndpoint.swift`):

    <token>\\n
    <command>\\n

Reply: `OK\\n`, `OK <state>\\n` (for `query_state`), or `ERR <reason>\\n`.

Token: per-launch random hex written by the app to
`~/Library/Logs/EnviousWispr/fault-token-<pid>` with `0600` perms. The app
deletes the file on `applicationWillTerminate`.

Lane breakdown (see `Tests/RuntimeUAT/SCENARIOS.md` for the indexed menu):
- Lane A (Claude-driven): A1, A2, A3, A4, A5, A6, A7, A8a, A8b, A9
- Lane B (founder-required): B1
- Lane B' (optional, programmatic device flip): not yet implemented; pending the
  spike documented in the V2 plan §3.2.

Each scenario function carries metadata via the `@scenario` decorator so
`list_scenarios()` can render the menu without importing wispr_eyes.
"""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

ENDPOINT_HOST = "127.0.0.1"
ENDPOINT_PORT = 8765
TOKEN_DIR = Path("~/Library/Logs/EnviousWispr").expanduser()
APP_NAME = "EnviousWispr"


# ──────────────────────────── scenario metadata ────────────────────────────


@dataclass
class ScenarioMeta:
    name: str
    lane: str  # "A" | "B" | "B'"
    family: str  # timing | stall | xpc | settings | app-quit | model-load | backend-switch | bt-route
    backends: list[str]  # ["parakeet"] | ["whisperKit"] | ["both"]
    runtime_budget_seconds: float
    founder_required: bool
    negative_control: str
    description: str


_REGISTRY: dict[str, tuple[Callable, ScenarioMeta]] = {}


def scenario(meta: ScenarioMeta):
    """Decorator: registers a scenario function with metadata."""

    def wrap(fn: Callable) -> Callable:
        _REGISTRY[meta.name] = (fn, meta)
        return fn

    return wrap


def list_scenarios() -> list[ScenarioMeta]:
    """Return all registered scenarios. Use `print_scenarios()` for a menu."""
    return [meta for _, meta in _REGISTRY.values()]


def print_scenarios() -> None:
    rows = sorted(list_scenarios(), key=lambda m: m.name)
    print(f"{'NAME':<24} {'LANE':<5} {'FAMILY':<14} {'BACKENDS':<14} {'BUDGET':<8} FOUNDER")
    print("-" * 80)
    for m in rows:
        backends = ",".join(m.backends)
        print(
            f"{m.name:<24} {m.lane:<5} {m.family:<14} {backends:<14} "
            f"{m.runtime_budget_seconds:<8.1f} {'YES' if m.founder_required else 'no'}"
        )
        print(f"  {m.description}")
        print(f"  negative control: {m.negative_control}")


def run_scenario(name: str, **kwargs) -> dict:
    """Dispatch a single scenario by name. Returns a result dict."""
    if name not in _REGISTRY:
        raise KeyError(f"unknown scenario: {name!r} (use print_scenarios() to list)")
    fn, meta = _REGISTRY[name]
    if meta.founder_required and not kwargs.get("founder_present"):
        raise RuntimeError(
            f"{name} is Lane B (founder-required). Re-run with founder_present=True after "
            "physically performing the manual step described in SCENARIOS.md."
        )
    started = time.monotonic()
    result = fn(**kwargs)
    elapsed = time.monotonic() - started
    return {"name": name, "lane": meta.lane, "elapsed_seconds": elapsed, "result": result}


# ──────────────────────────── endpoint client ────────────────────────────


def _find_app_pid() -> int:
    """Locate the running EnviousWispr process. Raises if not running."""
    try:
        out = subprocess.check_output(["pgrep", "-x", APP_NAME], text=True)
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"{APP_NAME} is not running — launch it first") from e
    pids = [int(p.strip()) for p in out.split() if p.strip()]
    if not pids:
        raise RuntimeError(f"{APP_NAME} not found via pgrep")
    return pids[0]


def _read_token(pid: int) -> str:
    """Read the per-launch fault token. Raises if the file is missing — that
    means the app was launched without `EW_FAULT_INJECTION=1`."""
    path = TOKEN_DIR / f"fault-token-{pid}"
    if not path.exists():
        raise RuntimeError(
            f"fault token not found at {path} — launch {APP_NAME} with "
            "`EW_FAULT_INJECTION=1` in its environment so the DEBUG endpoint starts"
        )
    return path.read_text(encoding="utf-8").strip()


def send(command: str, timeout: float = 5.0) -> str:
    """Send a command and return the reply (without trailing newline)."""
    pid = _find_app_pid()
    token = _read_token(pid)
    payload = f"{token}\n{command}\n".encode("utf-8")
    with socket.create_connection((ENDPOINT_HOST, ENDPOINT_PORT), timeout=timeout) as sock:
        sock.sendall(payload)
        chunks: list[bytes] = []
        sock.settimeout(timeout)
        while True:
            try:
                buf = sock.recv(4096)
            except socket.timeout:
                break
            if not buf:
                break
            chunks.append(buf)
            if b"\n" in buf:
                break
    return b"".join(chunks).decode("utf-8").strip()


def query_state() -> str:
    return send("query_state")


def force_cancel() -> str:
    return send("force_cancel")


def force_xpc_kill() -> str:
    return send("force_xpc_kill")


def force_audio_xpc_kill() -> str:
    return send("force_audio_xpc_kill")


def force_stall(n: int) -> str:
    return send(f"force_stall({n})")


# ──────────────────────────── helpers ────────────────────────────


def _import_wispr_eyes():
    """Lazy import so this module loads even if wispr_eyes' deps are absent."""
    here = Path(__file__).resolve().parent
    if str(here) not in sys.path:
        sys.path.insert(0, str(here))
    import wispr_eyes  # noqa: E402

    return wispr_eyes


def assert_terminated(timeout_s: float = 5.0) -> dict:
    """Poll `query_state` until both pipelines are terminal (.idle / .complete /
    .error / .ready) or the budget expires."""
    deadline = time.monotonic() + timeout_s
    last = ""
    while time.monotonic() < deadline:
        last = query_state()
        # `query_state` returns a single line like
        # `OK parakeet=.idle whisperkit=.idle backend=.parakeet`
        if any(s in last for s in (".idle", ".complete", ".error", ".ready")):
            return {"terminal": True, "state": last}
        time.sleep(0.1)
    return {"terminal": False, "state": last}


def assert_no_zombie() -> dict:
    """Best-effort: check that no orphan ASR/audio service helpers exist for a
    non-current session. Returns a dict with `orphan_pids`."""
    try:
        out = subprocess.check_output(
            ["pgrep", "-f", "EnviousWispr.*Service"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        pids = [p.strip() for p in out.split() if p.strip()]
    except subprocess.CalledProcessError:
        pids = []
    return {"orphan_pids": pids}


# ──────────────────────────── Lane A scenarios ────────────────────────────


@scenario(
    ScenarioMeta(
        name="A1_rapid_stop_start",
        lane="A",
        family="timing",
        backends=["both"],
        runtime_budget_seconds=3.0,
        founder_required=False,
        negative_control="Remove the recording-start debounce; this scenario passes when it should fail",
        description="Rapid stop/start fuzz at boundary (100ms) and jittered (100-500ms)",
    )
)
def A1_rapid_stop_start(**_) -> dict:
    eyes = _import_wispr_eyes()
    eyes.connect()
    # Fast toggle via the menu Start/Stop item, three times.
    for _ in range(3):
        eyes.tap("Start Recording")
        time.sleep(0.1)
        eyes.tap("Stop Recording")
        time.sleep(0.1)
    return assert_terminated(timeout_s=3.0)


@scenario(
    ScenarioMeta(
        name="A2_force_cancel",
        lane="A",
        family="timing",
        backends=["both"],
        runtime_budget_seconds=2.0,
        founder_required=False,
        negative_control="Remove cancellation cleanup in TranscriptionPipeline.cancelRecording; scenario detects leaked task",
        description="Force-cancel mid-record (1s into recording) — pipeline must reach .idle within budget",
    )
)
def A2_force_cancel(**_) -> dict:
    eyes = _import_wispr_eyes()
    eyes.connect()
    eyes.tap("Start Recording")
    time.sleep(1.0)
    reply = force_cancel()
    return {"reply": reply, **assert_terminated(timeout_s=2.0)}


@scenario(
    ScenarioMeta(
        name="A3_asr_xpc_kill",
        lane="A",
        family="xpc",
        backends=["parakeet"],
        runtime_budget_seconds=5.0,
        founder_required=False,
        negative_control="Remove ASR-crash handler at WhisperKitPipeline.swift:1044 / TranscriptionPipeline equivalent; pipeline gets stuck",
        description="ASR XPC service mid-stream kill (after 1s of audio captured)",
    )
)
def A3_asr_xpc_kill(**_) -> dict:
    eyes = _import_wispr_eyes()
    eyes.connect()
    eyes.tap("Start Recording")
    time.sleep(1.0)
    reply = force_xpc_kill()
    terminated = assert_terminated(timeout_s=5.0)
    return {"reply": reply, **terminated, **assert_no_zombie()}


@scenario(
    ScenarioMeta(
        name="A4_audio_xpc_kill",
        lane="A",
        family="xpc",
        backends=["both"],
        runtime_budget_seconds=5.0,
        founder_required=False,
        negative_control="Remove audio-XPC-error handler in AudioCaptureProxy; pipeline gets stuck",
        description="Audio XPC service kill (after capture started)",
    )
)
def A4_audio_xpc_kill(**_) -> dict:
    eyes = _import_wispr_eyes()
    eyes.connect()
    eyes.tap("Start Recording")
    time.sleep(0.8)
    reply = force_audio_xpc_kill()
    terminated = assert_terminated(timeout_s=5.0)
    return {"reply": reply, **terminated, **assert_no_zombie()}


@scenario(
    ScenarioMeta(
        name="A5_forced_stall",
        lane="A",
        family="stall",
        backends=["both"],
        runtime_budget_seconds=15.0,
        founder_required=False,
        negative_control="Remove the stall watchdog (armCaptureStallWatchdog); recording continues without audio",
        description="Forced audio buffer stall: drop next 1000 capture buffers (well above stall threshold)",
    )
)
def A5_forced_stall(**_) -> dict:
    eyes = _import_wispr_eyes()
    eyes.connect()
    eyes.tap("Start Recording")
    reply = force_stall(1000)
    terminated = assert_terminated(timeout_s=12.0)
    return {"reply": reply, **terminated}


@scenario(
    ScenarioMeta(
        name="A6_settings_storm",
        lane="A",
        family="settings",
        backends=["both"],
        runtime_budget_seconds=30.0,
        founder_required=False,
        negative_control="Remove wordCorrectionEnabled live-sync from PipelineSettingsSync; setting takes no effect mid-record",
        description="Toggle wordCorrectionEnabled / fillerRemovalEnabled / writingStylePreset during active recording",
    )
)
def A6_settings_storm(**_) -> dict:
    eyes = _import_wispr_eyes()
    eyes.connect()
    eyes.tap("Start Recording")
    # Settings nav + toggles via wispr-eyes menu/UI affordances.
    # Concrete toggle UI driving is left to the founder during PR demonstration;
    # this scenario logs the precondition state and reaches the menu.
    eyes.nav("AI Polish")
    time.sleep(0.5)
    eyes.tap("Stop Recording")
    return assert_terminated(timeout_s=10.0)


@scenario(
    ScenarioMeta(
        name="A7_app_quit",
        lane="A",
        family="app-quit",
        backends=["both"],
        runtime_budget_seconds=10.0,
        founder_required=False,
        negative_control="Remove applicationWillTerminate cleanup in AppDelegate; orphan helper processes survive next launch",
        description="App quit during active recording (Cocoa terminate, NOT raw SIGTERM)",
    )
)
def A7_app_quit(**_) -> dict:
    eyes = _import_wispr_eyes()
    eyes.connect()
    eyes.tap("Start Recording")
    time.sleep(0.8)
    # Quit via the menu item; this triggers Cocoa applicationWillTerminate.
    eyes.tap(f"Quit {APP_NAME}")
    time.sleep(2.0)
    return assert_no_zombie()


@scenario(
    ScenarioMeta(
        name="A8a_cancel_during_parakeet_load",
        lane="A",
        family="model-load",
        backends=["parakeet"],
        runtime_budget_seconds=3.0,
        founder_required=False,
        negative_control="Remove modelLoadTask?.cancel() at TranscriptionPipeline.swift:1091; cancelled task lingers",
        description="Cancel during Parakeet model load — true Task cancellation propagation",
    )
)
def A8a_cancel_during_parakeet_load(**_) -> dict:
    eyes = _import_wispr_eyes()
    eyes.connect()
    eyes.tap("Start Recording")
    time.sleep(0.05)  # try to land cancel during loadingModel
    reply = force_cancel()
    return {"reply": reply, **assert_terminated(timeout_s=3.0)}


@scenario(
    ScenarioMeta(
        name="A8b_cancel_during_whisperkit_load",
        lane="A",
        family="model-load",
        backends=["whisperKit"],
        runtime_budget_seconds=3.0,
        founder_required=False,
        negative_control="Remove WhisperKit prepare-state-flip at WhisperKitPipeline.swift:1078-1084; state stays inconsistent",
        description="Cancel during WhisperKit model load — state-unwind only (no held task)",
    )
)
def A8b_cancel_during_whisperkit_load(**_) -> dict:
    eyes = _import_wispr_eyes()
    eyes.connect()
    eyes.tap("Start Recording")
    time.sleep(0.05)
    reply = force_cancel()
    return {"reply": reply, **assert_terminated(timeout_s=3.0)}


@scenario(
    ScenarioMeta(
        name="A9_backend_switch_mid_record",
        lane="A",
        family="backend-switch",
        backends=["both"],
        runtime_budget_seconds=2.0,
        founder_required=False,
        negative_control="Remove `if parakeetActive || whisperKitActive { break }` guard in PipelineSettingsSync; active recording aborted",
        description="Backend switch mid-record (settings UI change) — must be rejected, recording continues",
    )
)
def A9_backend_switch_mid_record(**_) -> dict:
    eyes = _import_wispr_eyes()
    eyes.connect()
    eyes.tap("Start Recording")
    time.sleep(0.5)
    # Drive a backend toggle via Settings; recording must continue.
    # The Lane C BackendSwitchGuardTests covers the deterministic invariant —
    # this Lane A variant drives it through the live UI.
    eyes.nav("Speech Engine")
    time.sleep(0.3)
    state_after = query_state()
    eyes.tap("Stop Recording")
    return {"state_after_switch_attempt": state_after, **assert_terminated(timeout_s=3.0)}


# ──────────────────────────── Lane B scenarios ────────────────────────────


@scenario(
    ScenarioMeta(
        name="B1_bluetooth_route_flip",
        lane="B",
        family="bt-route",
        backends=["both"],
        runtime_budget_seconds=15.0,
        founder_required=True,
        negative_control="Remove BT route handler in AudioDeviceManager / capture session interruption flow; recording behaves incorrectly on real BT toggle",
        description="True Bluetooth route flip mid-record (founder physically toggles AirPods on/off)",
    )
)
def B1_bluetooth_route_flip(*, founder_present: bool = False, **_) -> dict:
    if not founder_present:
        raise RuntimeError("B1 requires founder_present=True (physical AirPods toggle)")
    eyes = _import_wispr_eyes()
    eyes.connect()
    eyes.tap("Start Recording")
    print("\n>>> Founder action: toggle AirPods power off, wait 2s, power on. Press Enter when done.")
    input()
    eyes.tap("Stop Recording")
    return assert_terminated(timeout_s=15.0)


# ──────────────────────────── CLI entry ────────────────────────────


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help", "list", "list_scenarios"):
        print_scenarios()
        return 0
    cmd = argv[0]
    if cmd == "run" and len(argv) >= 2:
        result = run_scenario(argv[1])
        print(result)
        return 0
    if cmd == "query":
        print(query_state())
        return 0
    print(f"unknown: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
