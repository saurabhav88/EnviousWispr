"""
V2 fault-injection harness for EnviousWispr (issue #291).

Drives the DEBUG-only `DebugFaultEndpoint` in the running app via a localhost
TCP listener. To run end-to-end: invoke the `wispr-rebuild-debug` skill, which
compiles `-c debug` (so `#if DEBUG` seams are present) and launches the debug
bundle with `EW_FAULT_INJECTION=1` set via `open --env`. Without both gates
satisfied (DEBUG build AND env var), the endpoint is inert. The release path
(the shipped release build) does NOT contain the endpoint — by design.

Wire protocol (per `Sources/EnviousWisprAppKit/App/Debug/DebugFaultEndpoint.swift`):

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
import re
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime
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


def _try_endpoint_token(token: str, timeout: float = 2.0) -> bool:
    """Attempt one raw round-trip against the DEBUG socket with a GIVEN
    token, bypassing `_find_app_pid`/`_read_token` entirely (used to
    disambiguate — calling `send()` here would recurse). Returns True only
    on a genuine `OK` reply; `ERR auth` (wrong token) and any connection
    failure both return False."""
    payload = f"{token}\nquery_state\n".encode("utf-8")
    try:
        with socket.create_connection((ENDPOINT_HOST, ENDPOINT_PORT), timeout=timeout) as sock:
            sock.sendall(payload)
            sock.settimeout(timeout)
            chunks: list[bytes] = []
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
        return b"".join(chunks).decode("utf-8").strip().startswith("OK")
    except OSError:
        return False


def _find_app_pid() -> int:
    """Locate the running EnviousWispr process under fault-injection test
    (the one with a live per-launch token — see `_read_token`), not just
    the first `pgrep -x` match. On a shared machine, multiple `EnviousWispr`
    processes can be running at once (dev + production, or another
    worktree's dev build): a bare `pids[0]` pick is ambiguous, and callers
    that only read/write state through the DEBUG socket are protected by
    `_read_token` raising on a token mismatch — but callers that derive a
    real SIGKILL target from this PID (`_app_bundle_path`,
    `force_xpc_process_kill`) need the RIGHT pid up front, not a
    fail-loud-after-the-fact guard.

    Codex code-diff r13: two DIFFERENT debug worktrees can each have their
    own live fault token at once (this project's single-dev-instance policy
    is a tooling convention, `build-dev-app.sh` killing prior instances
    before launching — not something macOS enforces, so two independently
    invoked dev builds CAN run concurrently). Picking the first token-
    bearing PID in that case can silently target the wrong instance. Since
    the endpoint listens on one fixed loopback port shared by whichever
    process actually bound it, and rejects a mismatched token with
    `ERR auth` (`DebugFaultEndpoint.swift`), a real connection attempt with
    each candidate's own token reliably identifies the one instance the
    listener actually accepts — no guessing required. Raises if no running
    instance has a fault token, or if more than one candidate's token is
    (implausibly) BOTH accepted, since that would mean two listeners
    somehow share one token."""
    try:
        out = subprocess.check_output(["pgrep", "-x", APP_NAME], text=True)
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"{APP_NAME} is not running — launch it first") from e
    pids = [int(p.strip()) for p in out.split() if p.strip()]
    if not pids:
        raise RuntimeError(f"{APP_NAME} not found via pgrep")
    candidates = [pid for pid in pids if (TOKEN_DIR / f"fault-token-{pid}").exists()]
    if not candidates:
        raise RuntimeError(
            f"none of the running {APP_NAME} processes ({pids}) has a fault token — "
            "invoke the `wispr-rebuild-debug` skill to launch with EW_FAULT_INJECTION=1 set."
        )
    if len(candidates) == 1:
        return candidates[0]
    accepted = [
        pid for pid in candidates
        if _try_endpoint_token((TOKEN_DIR / f"fault-token-{pid}").read_text(encoding="utf-8").strip())
    ]
    if len(accepted) != 1:
        raise RuntimeError(
            f"ambiguous fault-injection target: {len(candidates)} running {APP_NAME} "
            f"processes have a live token ({candidates}), and the endpoint accepted "
            f"{len(accepted)} of them ({accepted}) — expected exactly 1. Quit the "
            "unrelated instance(s) before running fault-injection scenarios."
        )
    return accepted[0]


def _app_bundle_path() -> str:
    """The `.app` bundle path of the SPECIFIC EnviousWispr instance under
    fault-injection test (resolved via `_find_app_pid`'s token-verified
    PID), e.g. `/Users/.../EnviousWispr-recovery-v2-p1/build/EnviousWispr
    Local.app`. Used to scope real-process-kill fault injection
    (`force_xpc_process_kill`) to THIS instance's own XPC helper only —
    `EnviousWisprASRService` is reparented to launchd (PPID 1) on spawn, not
    the requesting app, so process-tree ancestry can't be used to scope it;
    each app bundle carries its own copy of the service under
    `Contents/XPCServices/`, so the bundle path prefix is the reliable
    discriminator between instances (Codex code-diff r12: a bare
    `pgrep -f "EnviousWispr.*Service"` match kills every running instance's
    helper, dev and production alike)."""
    pid = _find_app_pid()
    command = subprocess.check_output(
        ["ps", "-o", "command=", "-p", str(pid)], text=True
    ).strip()
    marker = ".app/"
    idx = command.find(marker)
    if idx == -1:
        raise RuntimeError(f"could not find '.app/' in command for pid {pid}: {command!r}")
    return command[: idx + len(".app")]


def _read_token(pid: int) -> str:
    """Read the per-launch fault token. Raises if the file is missing — that
    means the app was not launched via `wispr-rebuild-debug` (or equivalent
    debug-bundle path that sets `EW_FAULT_INJECTION=1`)."""
    path = TOKEN_DIR / f"fault-token-{pid}"
    if not path.exists():
        raise RuntimeError(
            f"fault token not found at {path} — invoke the `wispr-rebuild-debug` "
            "skill to build and launch the debug bundle with EW_FAULT_INJECTION=1 set. "
            "The shipped release build does not contain the endpoint."
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


def _scoped_xpc_service_pids(bundle_path: str) -> list[str]:
    """PIDs of `EnviousWisprASRService` processes whose executable lives
    INSIDE `bundle_path` — the properly-scoped counterpart to
    `list_xpc_service_pids()` (which matches every running instance
    system-wide) for callers that are about to SIGKILL, not just count."""
    try:
        out = subprocess.check_output(
            ["pgrep", "-f", "EnviousWispr.*Service"], text=True, stderr=subprocess.DEVNULL
        )
    except subprocess.CalledProcessError:
        return []
    matched = []
    for pid_str in out.split():
        pid = pid_str.strip()
        if not pid:
            continue
        try:
            command = subprocess.check_output(
                ["ps", "-o", "command=", "-p", pid], text=True
            ).strip()
        except subprocess.CalledProcessError:
            continue  # process exited between pgrep and ps — not a match either way
        if command.startswith(bundle_path):
            matched.append(pid)
    return matched


def force_xpc_process_kill() -> list[str]:
    """Kill the REAL ASR XPC helper process(es) with SIGKILL — a genuine
    crash, distinct from `force_xpc_kill()`'s connection-only invalidation
    (`forceConnectionTerminationNow`, which leaves the helper process alive
    and the model resident). #1707 Codex code-diff r11: the connection-only
    fault was measured at 99-127ms recovery and produced a 2.0s deadline
    that then failed 4-of-5 real crash trials — a real process kill forces
    launchd to respawn a genuinely fresh process and reload the model cold,
    the actual ~4.2s p99 scenario the corrected 8.0s deadline protects.

    Codex code-diff r12: scoped to THIS app instance's own XPC helper via
    `_scoped_xpc_service_pids` — a bare `list_xpc_service_pids()` match
    would SIGKILL every running instance's helper system-wide (another
    worktree's dev build, or a production install running alongside it on
    a shared machine), interrupting a real, unrelated dictation in
    progress. Returns the PIDs that were killed (macOS respawns under new
    PIDs)."""
    pids = _scoped_xpc_service_pids(_app_bundle_path())
    for pid in pids:
        subprocess.run(["kill", "-9", pid], check=False)
    return pids


# #1543: audio capture is in-process now — the audio-boundary DEBUG commands
# (force_audio_xpc_kill / force_proxy_buffer_drop / force_audio_wedge_start) and
# their scenarios were removed with the audio-capture boundary. The ASR-service
# kill (force_xpc_kill) and the in-process zero-fill injector below remain.


# ─────────────────── #1317 proof-bench: zero-fill injector client ───────────────
#
# The proof bench reproduces the production dead-mic fault (all-zero / "digital
# silence" audio, `zombie_engine_zero_peak`) deterministically, proves the
# injector actually fired, and measures whether the running build handles a dead
# take HONESTLY (no fabricated text) vs silently. Every gate fails CLOSED: a
# missing artifact is INVALID evidence, never a defaulted pass.

# Fixed canary phrase for the log-backed recovery oracle. Four uncommon-but-real
# English words → strong ASR targets that will not appear by accident. Newness is
# proven by a rotation-safe LogCursor, not by phrase uniqueness.

APP_LOG_PATH = Path("~/Library/Logs/EnviousWispr/app.log").expanduser()

# App-owned honest-handling marker for a dead take: the pipeline detected no
# speech and skipped ASR instead of fabricating text. Peak is 0.0000 for a fully
# zero-filled take. (RecordingSessionKernel.swift:1206-1210.)








def _parse_bool(s: str) -> bool:
    # Swift `Bool` string interpolation is lowercase "true"/"false".
    if s == "true":
        return True
    if s == "false":
        return False
    raise ValueError(f"not a bool: {s!r}")




# ──────────────────────────── helpers ────────────────────────────


def _import_wispr_eyes():
    """Lazy import so this module loads even if wispr_eyes' deps are absent."""
    here = Path(__file__).resolve().parent
    if str(here) not in sys.path:
        sys.path.insert(0, str(here))
    import wispr_eyes  # noqa: E402

    return wispr_eyes


_TERMINAL_TOKENS = ("idle", "complete", "error", "ready")


def _parse_query_state(reply: str) -> dict[str, str]:
    """Parse `OK parakeet=<state> whisperkit=<state> backend=<X>` into a dict.
    Returns `{}` if the reply doesn't match the expected shape."""
    if not reply.startswith("OK "):
        return {}
    parts: dict[str, str] = {}
    for token in reply[3:].split():
        if "=" in token:
            k, v = token.split("=", 1)
            parts[k] = v
    return parts


def _backend_pipeline_key(backend: str) -> str:
    # `backend=.parakeet` / `backend=.whisperKit` → which pipeline-state key matters
    if "whisper" in backend.lower():
        return "whisperkit"
    return "parakeet"


def assert_terminated(timeout_s: float = 5.0) -> dict:
    """Poll `query_state` until the ACTIVE backend's pipeline reaches a
    terminal state (.idle / .complete / .error / .ready) or the budget
    expires.

    The `query_state` reply always carries both pipeline states; the
    inactive backend is typically idle or ready while the active one is
    still running. Checking "any pipeline terminal" would always return
    True immediately and silently mask Lane A regressions (Codex P1
    feedback on PR #544). We must check the active backend specifically.
    """
    deadline = time.monotonic() + timeout_s
    last = ""
    while time.monotonic() < deadline:
        last = query_state()
        parsed = _parse_query_state(last)
        backend = parsed.get("backend", "")
        active_key = _backend_pipeline_key(backend)
        active_state = parsed.get(active_key, "")
        if active_state and any(t in active_state for t in _TERMINAL_TOKENS):
            return {"terminal": True, "state": last, "active": active_state}
        time.sleep(0.1)
    return {"terminal": False, "state": last}


def list_xpc_service_pids() -> list[str]:
    """Return PIDs of all live EnviousWispr XPC service helpers
    (`EnviousWisprASRService`; audio capture is in-process since #1543).

    On macOS, XPC services are launchd-managed: invalidating the connection
    does not terminate the helper process — launchd respawns it as needed.
    The right "no leak" assertion is therefore a delta check: count after
    the fault must not exceed count before.
    """
    try:
        out = subprocess.check_output(
            ["pgrep", "-f", "EnviousWispr.*Service"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
        return [p.strip() for p in out.split() if p.strip()]
    except subprocess.CalledProcessError:
        return []


def assert_no_xpc_leak(before: list[str]) -> dict:
    """Confirm the XPC service helper count did not grow after a fault.

    Returns `{"leaked": False, "before": [...], "after": [...]}` on a
    pass; `leaked: True` if more service helpers exist now than before.
    Identity changes (PID rotation) are expected and not a leak — only
    a net increase is a leak.
    """
    after = list_xpc_service_pids()
    return {"leaked": len(after) > len(before), "before": before, "after": after}


# Backwards-compatible alias retained for existing scenarios that still call
# the old name. New code should use `list_xpc_service_pids` + `assert_no_xpc_leak`.
def assert_no_zombie() -> dict:
    pids = list_xpc_service_pids()
    return {"orphan_pids": pids}


# ──────────────────────────── recording control helpers ────────────────────


_RIGHT_CMD_KEYCODE = 54
_ESC_KEYCODE = 53


def _ptt_keycode() -> int:
    """The app's configured PTT key (shared-suite `toggleKeyCode`), falling
    back to Right Command. The dev bundle reads the founder's REAL settings
    (#923), so a hardcoded keycode silently misses when the configured key
    differs — 2026-07-09: taps posted Right Cmd (54) while the configured key
    was Right Option (61); zero presses reached the app and the A11 recovery
    cycle failed without exercising anything."""
    try:
        out = subprocess.run(
            ["defaults", "read", "com.enviouswispr.app", "toggleKeyCode"],
            capture_output=True, text=True, timeout=5,
        )
        return int(out.stdout.strip())
    except Exception:
        return _RIGHT_CMD_KEYCODE


def _import_simulate_input():
    """Lazy import so this module loads even if Quartz isn't available."""
    here = Path(__file__).resolve().parent
    if str(here) not in sys.path:
        sys.path.insert(0, str(here))
    import simulate_input  # noqa: E402

    return simulate_input


def _active_state() -> str:
    """Return the active backend's pipeline state string (e.g. `idle`,
    `recording`, `transcribing`)."""
    parsed = _parse_query_state(query_state())
    return parsed.get(_backend_pipeline_key(parsed.get("backend", "")), "")


def _tap_rcmd(hold_s: float = 0.05) -> None:
    """Single PTT-key press+release (configured key via `_ptt_keycode`).
    Hold time matches a quick PTT tap.

    HotkeyService treats a single tap-and-release with a 500 ms debounce —
    if no second press arrives, it fires onStopRecording. Use double-tap to
    enter hands-free locked mode for sustained recording.
    """
    sim = _import_simulate_input()
    keycode = _ptt_keycode()
    sim.modifier_down(keycode)
    time.sleep(hold_s)
    sim.modifier_up(keycode)






def _start_recording_locked(*, gap_s: float = 0.25, settle_s: float = 0.8,
                            timeout_s: float = 4.0,
                            post_lock_dwell_s: float = 0.6) -> bool:
    """Enter hands-free locked recording via double-tap.

    Two Right-Cmd taps within HotkeyService's 500 ms double-press window
    transitions to `isRecordingLocked = true`, which suppresses the
    debounced stop-on-release and keeps recording until the next single
    tap. Verifies post-state and retries if the first attempt missed
    (handles the first-of-process CGEvent ghost we observed 2026-05-02).

    Timing safety (against HotkeyService's gestures):
    - `gap_s = 250 ms` keeps both taps comfortably inside the 500 ms
      double-press window without crowding the upper bound.
    - `post_lock_dwell_s = 600 ms` lets HotkeyService's `lockTime`
      cooldown elapse before any subsequent tap. Without this dwell, a
      tap landing within 500 ms of `lockTime` is silently ignored
      ('Press ignored — lock cooldown'), or worse, stacks with two
      retry-loop taps to look like a triple-press cancel gesture.
    """
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if "recording" in _active_state():
            time.sleep(post_lock_dwell_s)
            return True
        _tap_rcmd()
        time.sleep(gap_s)
        _tap_rcmd()
        time.sleep(settle_s)
        if "recording" in _active_state():
            time.sleep(post_lock_dwell_s)
            return True
        # Don't pile retry taps onto an unstable state — pause before
        # the next attempt so the previous tap pair can fully settle.
        time.sleep(0.4)
    return "recording" in _active_state()


def _stop_recording_locked(*, settle_s: float = 1.5) -> bool:
    """Single tap to exit hands-free locked recording, then wait for terminal.

    Returns True if pipeline reached idle/complete within `settle_s`.
    """
    _tap_rcmd()
    deadline = time.monotonic() + settle_s
    while time.monotonic() < deadline:
        st = _active_state()
        if any(t in st for t in _TERMINAL_TOKENS):
            return True
        time.sleep(0.1)
    return any(t in _active_state() for t in _TERMINAL_TOKENS)


def _activate_app() -> None:
    """Bring the dev bundle to the foreground so keystrokes (ESC,
    arrow keys, etc.) are routed to it.

    Right-Cmd is registered by HotkeyService as a global Carbon hotkey
    and fires regardless of focus, but bare-Escape is not a true
    system-wide hotkey on macOS — the OS lets the foreground app
    consume it first. Without explicit activation, an ESC keystroke
    sent while Claude Code or another app is foreground would cancel
    that app instead of the dictation. Confirmed empirically 2026-05-02.
    """
    subprocess.run(
        ["osascript", "-e",
         'tell application id "com.enviouswispr.app.dev" to activate'],
        check=False, capture_output=True,
    )
    time.sleep(0.2)  # let WindowServer settle the focus change


def _press_esc() -> None:
    """Send a single Escape keystroke — the user-real cancel gesture for
    an in-flight dictation. ESC is what the app binds for cancel; the
    `force_cancel` debug endpoint command bypasses the keybind and would
    not exercise the same code path."""
    sim = _import_simulate_input()
    # Escape is a regular (non-modifier) key — use the standard down/up via
    # CGEventCreateKeyboardEvent rather than flagsChanged.
    from Quartz import (  # type: ignore[import-not-found]
        CGEventCreateKeyboardEvent,
        CGEventPost,
        kCGHIDEventTap,
    )

    down = CGEventCreateKeyboardEvent(None, _ESC_KEYCODE, True)
    up = CGEventCreateKeyboardEvent(None, _ESC_KEYCODE, False)
    CGEventPost(kCGHIDEventTap, down)
    time.sleep(0.03)
    CGEventPost(kCGHIDEventTap, up)


def _assert_dictation_recovers(
    *,
    sentence: str = "recovery check the cat sat on the mat",
    record_seconds: float = 2.5,
    settle_timeout_s: float = 8.0,
) -> dict:
    """Run an end-to-end dictation cycle after a fault was injected, and
    confirm the software actually recovered — not just that the previous
    cycle reached a terminal state.

    Sequence:
      1. Force pipeline back to idle if it's still in error/recording
         (a single rcmd tap clears most non-idle states; double-tap won't
         enter lock from non-idle).
      2. Double-tap to enter hands-free locked recording.
      3. Play TTS audio for `record_seconds` so capture has real audio.
      4. Single-tap to exit lock.
      5. Wait up to `settle_timeout_s` for the pipeline to reach a non-
         error terminal state (`complete` or `idle`).

    Returns a dict capturing what happened so the caller can decide if
    recovery passed:
        {
            "recovered": bool,                  # True if final state in {complete, idle} and not error
            "second_cycle_reached_recording": bool,
            "second_cycle_terminal_state": str,  # the active state at end
            "second_cycle_elapsed_s": float,
        }
    """
    t_start = time.monotonic()
    # Step 1: clear any non-idle state so double-tap can enter lock.
    state = _active_state()
    if "error" in state or "recording" in state:
        _tap_rcmd()
        time.sleep(0.8)
    # Step 2: enter locked recording.
    locked = _start_recording_locked()
    if not locked:
        return {
            "recovered": False,
            "second_cycle_reached_recording": False,
            "second_cycle_terminal_state": _active_state(),
            "second_cycle_elapsed_s": time.monotonic() - t_start,
        }
    # Step 3: play TTS during the recording window.
    with _TTSAudio(sentence):
        time.sleep(record_seconds)
    # Step 4: exit lock.
    _stop_recording_locked(settle_s=0.5)
    # Step 5: wait for terminal state.
    deadline = time.monotonic() + settle_timeout_s
    final = ""
    while time.monotonic() < deadline:
        final = _active_state()
        # `complete` is the success signal; `idle` is acceptable when the
        # backend short-circuits (e.g. nothing to transcribe). `error` is
        # a recovery failure.
        if "complete" in final or final == "idle":
            break
        if "error" in final:
            break
        time.sleep(0.1)
    elapsed = time.monotonic() - t_start
    recovered = ("complete" in final or final == "idle") and "error" not in final
    return {
        "recovered": recovered,
        "second_cycle_reached_recording": True,
        "second_cycle_terminal_state": final,
        "second_cycle_elapsed_s": elapsed,
    }


def _wait_for_app_exit(timeout_s: float = 10.0) -> bool:
    """Poll until no `EnviousWispr Local.app` main process remains."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        result = subprocess.run(
            ["pgrep", "-f", "EnviousWispr Local.app/Contents/MacOS/EnviousWispr"],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            return True
        time.sleep(0.2)
    return False


def _wait_for_endpoint(timeout_s: float = 10.0) -> bool:
    """Poll the DebugFaultEndpoint until it responds, after a relaunch.

    The token file and the endpoint listener are both written by the
    running app after `applicationDidFinishLaunching`. Until that path
    completes, `query_state` raises (token missing) or the connection
    refuses (endpoint not listening). Tolerate both as transient.
    """
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            reply = query_state()
            if reply.startswith("OK "):
                return True
        except (RuntimeError, ConnectionError, OSError):
            pass
        time.sleep(0.3)
    return False


def _relaunch_app() -> dict:
    """Re-open the dev bundle with EW_FAULT_INJECTION=1 set so the
    DebugFaultEndpoint comes back up. Used by scenarios that terminate
    the app (A7) and still need a recovery cycle.
    """
    bundle_path = (
        "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/build/"
        "EnviousWispr Local.app"
    )
    subprocess.run(
        ["open", "--env", "EW_FAULT_INJECTION=1", bundle_path],
        check=False,
    )
    endpoint_up = _wait_for_endpoint(timeout_s=12.0)
    return {"relaunched": endpoint_up}


class _TTSAudio:
    """Context manager that plays TTS audio in the background while the
    `with` block runs, so capture-side scenarios have real audio flowing
    through the heart path during fault injection.

    Usage:
        with _TTSAudio("the quick brown fox jumps over the lazy dog"):
            # recording is active here, audio is being captured
            force_xpc_kill()
    """

    def __init__(self, sentence: str = "the quick brown fox jumps over "
                 "the lazy dog and the dog does not chase the fox"):
        self.sentence = sentence
        self._proc: Optional[subprocess.Popen] = None
        self._wav: Optional[str] = None

    def __enter__(self):
        eyes = _import_wispr_eyes()
        # Reuse the existing TTS helper (OpenAI echo by default, with
        # macOS `say` fallback) — see Tests/RuntimeUAT/wispr_eyes.py.
        self._wav = eyes.tts(self.sentence)
        self._proc = subprocess.Popen(
            ["afplay", self._wav],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return self

    def __exit__(self, *_exc):
        if self._proc is not None:
            try:
                self._proc.terminate()
                self._proc.wait(timeout=1.0)
            except Exception:
                self._proc.kill()
        return False


# ─────────────────── #1317 proof-bench: build-identity manifest ──────────────
#
# Before any zero-fill trial is trusted, the harness proves the SINGLE running app
# is exactly the build a manifest describes: one PID, its executable path == the
# manifest path, and app + both embedded XPC helper SHA-256 hashes match. Two dev
# builds share bundle id `com.enviouswispr.app.dev`, so the two A/B arms run
# sequentially and identity is verified per trial (dev-bundle-id-collision).
# Source SHA is manifest provenance stamped at build time, NOT inferred from
# Info.plist (build-dev-app.sh stamps no git SHA).

# Our embedded XPC executable inside the .app (audio capture is in-process since
# #1543). Sparkle's Downloader/Installer are excluded — not ours.
_APP_EXE_REL = "Contents/MacOS/EnviousWispr"
_ASR_HELPER_REL = (
    "Contents/XPCServices/EnviousWisprASRService.xpc/Contents/MacOS/"
    "EnviousWisprASRService"
)


def compute_sha256(path) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def discover_bundle_executables(bundle_path) -> dict:
    """Absolute paths of our three executables inside the .app:
    {app, audio_helper, asr_helper}. Raises if any is missing.

    abspath (NOT resolve): verify_running_identity compares app_path against the
    argv[0] that `ps` reports for an `open`-launched app, which is absolute but
    symlink-UNresolved. resolve() could expand a symlink/firmlink and diverge
    from that argv[0], turning the intended build into invalid evidence when the
    caller passes the documented relative --bundle. Cloud review PR #1504."""
    bundle = Path(os.path.abspath(bundle_path))
    paths = {
        "app": bundle / _APP_EXE_REL,
        "asr_helper": bundle / _ASR_HELPER_REL,
    }
    for label, p in paths.items():
        if not p.exists():
            raise RuntimeError(f"bundle missing {label} executable at {p}")
    return {k: str(v) for k, v in paths.items()}




def _bundle_identifier(bundle_path) -> str:
    plist = Path(bundle_path) / "Contents" / "Info.plist"
    try:
        out = subprocess.check_output(
            ["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", str(plist)],
            text=True,
        )
        return out.strip()
    except (subprocess.CalledProcessError, OSError):
        return ""




def _running_app_executable_path(pid: int) -> str:
    """argv[0] of the running app = its executable path (open-launched apps carry
    the full path). Proves the running PID is the build we hashed."""
    out = subprocess.check_output(["ps", "-o", "command=", "-p", str(pid)], text=True).strip()
    marker = ".app/Contents/MacOS/EnviousWispr"
    idx = out.find(marker)
    return out if idx == -1 else out[: idx + len(marker)]


def _proc_start_epoch(pid: int):
    """Epoch seconds when PID started, or None on any failure. `ps -o lstart=` in
    the C locale gives a stable `Sat Jul 11 15:36:48 2026`. Used to prove the
    RUNNING image is the build we hashed: a stale process (image A) left running
    when a new build (image B) is copied over the same shared-bundle-id path would
    otherwise pass identity — argv[0] path matches and the on-disk hash matches
    manifest B — while actually executing image A. Its start predates B's build."""
    try:
        raw = subprocess.check_output(
            ["ps", "-o", "lstart=", "-p", str(pid)], text=True,
            env={**os.environ, "LC_ALL": "C"}).strip()
        return datetime.strptime(raw, "%a %b %d %H:%M:%S %Y").timestamp()
    except (subprocess.CalledProcessError, ValueError, OSError):
        return None




# ─────────────────── #1317 proof-bench: canary log oracle ────────────────────




def _normalize_tokens(text: str) -> set:
    import re
    return set(re.sub(r"[^a-z0-9]+", " ", text.lower()).split())








# ─────────────────── #1317 proof-bench: evidence / trial schema ──────────────










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
    """Spam Right-Cmd to fuzz the hotkey debounce, then verify the pipeline
    can be cleanly stopped after the chaos.

    Validate-then-automate (2026-05-02): menu taps ("Start Recording" /
    "Stop Recording") cannot drive this scenario — macOS status-bar menu
    items do not enumerate their children in the AX tree until the menu
    is open. Hand-validation showed Right-Cmd CGEvent taps (keycode 54,
    50 ms hold) reliably toggle recording, and that an even-tap-count
    chaos phase can leave the pipeline stuck in `.recording` because
    some taps are debounced. The scenario therefore needs an explicit
    cleanup tap after a settle pause to guarantee `.idle`.
    """
    import random

    # Phase 1 — boundary fuzz at 100 ms (debounce should swallow most).
    for _ in range(6):
        _tap_rcmd()
        time.sleep(0.1)
    # Phase 2 — jittered fuzz (100–500 ms).
    for _ in range(6):
        _tap_rcmd()
        time.sleep(random.uniform(0.1, 0.5))
    # Phase 3 — settle past the debounce window so the next tap is honored.
    time.sleep(1.0)
    # Phase 4 — cleanup tap if the chaos left us stuck recording.
    if "recording" in _active_state():
        _tap_rcmd()
    return assert_terminated(timeout_s=3.0)


@scenario(
    ScenarioMeta(
        name="A2_esc_cancel",
        lane="A",
        family="timing",
        backends=["both"],
        runtime_budget_seconds=4.0,
        founder_required=False,
        negative_control="Remove cancellation cleanup in TranscriptionPipeline.cancelRecording; scenario detects leaked task",
        description="ESC mid-record (1 s into recording, audio flowing) — pipeline must reach idle within budget",
    )
)
def A2_esc_cancel(**_) -> dict:
    """User behavior: dictation in progress, audio is flowing, user hits
    Escape to cancel. The keybind path (HotkeyService cancel hotkey) must
    propagate to the pipeline and reach a terminal state.

    Validate-then-automate notes (2026-05-02):
    - Sustained recording requires double-tap → hands-free locked mode
      (`_start_recording_locked`); a single tap auto-stops after the
      500 ms PTT debounce window.
    - ESC is the user-real cancel gesture. The `force_cancel` debug
      endpoint command bypasses the keybind and would not exercise the
      same wiring this scenario claims to test.
    - TTS audio flows during the test so the cancel happens against an
      active capture session, not silence.
    """
    if not _start_recording_locked():
        return {"terminal": False, "reason": "could not enter recording", "state": query_state()}
    with _TTSAudio():
        time.sleep(1.0)  # let audio flow into the pipeline
        _activate_app()  # ESC must reach EnviousWispr, not whatever else is foreground
        _press_esc()
        result = assert_terminated(timeout_s=4.0)
    esc_landed = any(t in _active_state() for t in _TERMINAL_TOKENS)
    result["esc_drove_cancel"] = esc_landed
    if not esc_landed:
        # safety-net cleanup if ESC was somehow swallowed
        _tap_rcmd()
        time.sleep(1.0)
    return result


# #1707 Codex code-diff r5/r11: the poll below must outlast the production
# recovery deadline (`ParakeetEngineAdapter.asrInterruptionRecoveryDeadlineSec`,
# measured 2026-07-20 at 8.0s against a REAL helper-process crash — 27/30
# real trials recovered in 4159-4215ms, p99=4215ms;
# `docs/audits/2026-07-20-recovery-v2-phase1-asr-recovery-latency.txt`) PLUS
# normal decode/finalize/paste time — otherwise a legitimately slow-but-
# successful salvage near the deadline polls out before reaching `.complete`
# and the scenario wrongly reports a regression. Keep this ahead of that
# constant by a healthy margin.
_ASR_RECOVERY_POLL_TIMEOUT_S = 15.0

# The kernel's own precomputed recovery-latency line
# (RecordingSessionKernel.swift, recoverFromASRInterruption call site) is the
# single source of truth for whether the SALVAGE MECHANISM itself succeeded
# — distinct from whether the ultimate dictation completed with real text,
# which also depends on the captured audio's VAD-detectable content quality
# (a test-environment confound, not something #1707 controls: verified
# directly with real OpenAI TTS speech — not just the say/Evan fallback —
# and the interrupted take STILL floored to `.asrInterrupted` on a "zero
# segments, near-silent peak" VAD read, pointing at a mic/system-volume
# level issue on this machine/session rather than TTS voice quality; the
# widened floor in RecordingSessionKernel.interruptedTerminalFloor correctly
# maps a successful recovery whose decode legitimately finds no speech to
# `.asrInterrupted` either way).
_ASR_RECOVERY_LOG_RE = re.compile(r"ASR recovery latency: (\d+)ms outcome=(\w+) sid=")


def _read_asr_recovery_outcome(start_pos: int, timeout_s: float = 10.0) -> Optional[dict]:
    """Poll `app.log` from `start_pos` for the kernel's own recovery-outcome
    line. Returns `{"elapsed_ms": int, "outcome": str}` or `None` if it never
    appears (recovery was never attempted at all — a different, worse bug).

    Codex code-diff r8/r11: app.log rotates at 5x10MB (AppLogger); if it
    rotates mid-poll, the new file is smaller than `start_pos` and a blind
    `seek` would silently skip the line forever. Detect a shrink (current
    size < last-seen size) and reset to the start of the new file instead.
    r11: rotation can also have already happened BEFORE this function is
    even called (between the caller capturing `start_pos` and this poll
    loop starting) — comparing only against a `last_size` initialized here
    can never see that, since both start from the same already-rotated
    file. Compare against `pos` (the caller's own offset) too, not just the
    previous iteration's own tracked size."""
    deadline = time.monotonic() + timeout_s
    pos = start_pos
    last_size = APP_LOG_PATH.stat().st_size if APP_LOG_PATH.exists() else 0
    if last_size < pos:
        pos = 0  # already rotated/truncated before polling even began
    while time.monotonic() < deadline:
        current_size = APP_LOG_PATH.stat().st_size if APP_LOG_PATH.exists() else 0
        if current_size < last_size or current_size < pos:
            pos = 0  # rotated/truncated since the last poll — start over
        last_size = current_size
        with open(APP_LOG_PATH, encoding="utf-8", errors="replace") as fh:
            fh.seek(pos)
            lines = fh.readlines()
            pos = fh.tell()
        for line in lines:
            m = _ASR_RECOVERY_LOG_RE.search(line)
            if m:
                return {"elapsed_ms": int(m.group(1)), "outcome": m.group(2)}
        # deadline-fallback: poll cadence while waiting for the kernel's log line; `timeout_s` above bounds total time.
        time.sleep(0.1)
    return None


@scenario(
    ScenarioMeta(
        name="A3_asr_xpc_kill",
        lane="A",
        family="xpc",
        backends=["parakeet"],
        runtime_budget_seconds=30.0,
        founder_required=False,
        negative_control="Remove ASREngineAdapter.recoverFromASRInterruption() / revert #1707; the dictation is discarded instead of salvaged",
        description="ASR XPC connection invalidated mid-stream while TTS audio is flowing — #1707: the already-captured audio is salvaged (reconnect + decode) rather than the dictation being discarded; falls back to a terminal error only if reconnect genuinely fails, no XPC helper leak",
    )
)
def A3_asr_xpc_kill(**_) -> dict:
    """User behavior: dictation in progress with audio flowing, the ASR
    XPC helper process crashes. #1707: the pipeline now salvages the
    recording — it reconnects (through a genuinely respawned process, cold
    model reload included) and decodes the audio already captured before
    the crash, so the user gets their text pasted instead of losing the
    dictation. Only a genuine reconnect failure surfaces a "service
    crashed" message.

    Notes 2026-07-20 (#1707 Codex code-diff r11):
    - "Kill" means a real `kill -9` on the actual
      `EnviousWisprASRService` process (`force_xpc_process_kill`), NOT
      `force_xpc_kill()`'s `forceConnectionTerminationNow()` (which only
      invalidates the connection object and leaves the helper process,
      and its resident model, alive). An earlier version of this scenario
      used the connection-only kill — recovery completed in ~100ms every
      time, which never exercises the slow path a genuine crash takes
      (~4.2s p99, cold model reload in a freshly-spawned process,
      `docs/audits/2026-07-20-recovery-v2-phase1-asr-recovery-latency.txt`)
      and would have silently let a regression in THAT path ship
      undetected. macOS/launchd respawns the process under a new PID; the
      leak assertion compares helper counts before/after, not "any helper
      survives" (that would always be true and silently pass).
    - TTS audio must be flowing so the crash lands while the ASR side is
      actually streaming. Without audio, the kill exercises only the
      disconnect path, not the mid-stream error wiring this scenario
      claims to test.
    - `assert_terminated`'s `_TERMINAL_TOKENS` accept both "complete" and
      "error" as terminal, so reaching a terminal state alone no longer
      proves the fix — a build that regressed back to the old discard
      behavior would still pass that check.
    - `salvage_succeeded` reads the kernel's own precomputed
      "ASR recovery latency: ...outcome=..." log line
      (`_read_asr_recovery_outcome`), not the final pipeline state. The
      final RecordingOutcome can floor to `.asrInterrupted` even after a
      genuinely SUCCESSFUL recovery if the captured audio's VAD-detectable
      content quality is poor — verified directly (r11) with real OpenAI
      TTS speech, not just the say/Evan fallback, and the interrupted take
      still floored on a near-silent VAD read (peak ~0.006-0.009),
      pointing at a mic/system-volume level issue on this machine/session
      rather than TTS voice quality. Either way, the widened floor
      (RecordingSessionKernel.interruptedTerminalFloor) correctly maps a
      successful recovery whose decode legitimately finds no speech to
      `.asrInterrupted`. That is a test-audio-capture confound, not a
      recovery-mechanism regression, and gating on the final state alone
      (an earlier version of this scenario, Codex code-diff r7) produced
      exactly that false failure live.
    - The poll budget (`_ASR_RECOVERY_POLL_TIMEOUT_S`) is deliberately wider
      than the production recovery deadline (Codex code-diff r5): a legit
      slow-but-successful salvage near that deadline still needs time to
      decode/finalize/paste afterward, and a poll that expires mid-decode
      would misreport a real success as a failure.
    """
    pre_helpers = list_xpc_service_pids()
    if not _start_recording_locked():
        return {"terminal": False, "reason": "could not enter recording", "state": query_state()}
    with open(APP_LOG_PATH, encoding="utf-8", errors="replace") as fh:
        fh.seek(0, 2)
        log_start_pos = fh.tell()
    with _TTSAudio():
        time.sleep(1.0)  # let audio stream into ASR
        killed_pids = force_xpc_process_kill()
        terminated = assert_terminated(timeout_s=_ASR_RECOVERY_POLL_TIMEOUT_S)
    leak = assert_no_xpc_leak(pre_helpers)
    # #1707: the recovery mechanism's own verdict — see the docstring note
    # above for why this, not the final pipeline state, is the gate.
    recovery_log = _read_asr_recovery_outcome(log_start_pos)
    salvage_succeeded = bool(recovery_log) and recovery_log["outcome"] == "readyForBatchDecode"
    # Recovery check: a graceful failure that wedges the next dictation
    # is indistinguishable from a crash. Confirm the user can actually
    # keep dictating after the fault.
    recovery = _assert_dictation_recovers()
    outcome = {
        "killed_pids": killed_pids, **terminated, **leak,
        "recovery_log": recovery_log,
        "salvage_succeeded": salvage_succeeded,
        **recovery,
    }
    # A3 predates the evidence_valid/assertions schema (`evaluate_trial`
    # passes any scenario missing that key unconditionally, "legacy scenario
    # (no evidence schema)"), so the only way this scenario can fail is to
    # raise — a returned `False` field is otherwise silently discarded and a
    # regression would still report PASS (Codex code-diff r4). r8: gate on
    # ALL three real invariants, not just recovery — a reconnect that
    # succeeds but then leaks an XPC helper, or leaves the next dictation
    # wedged, is still a real #1707 regression that `salvage_succeeded`
    # alone would miss.
    failures = []
    if not salvage_succeeded:
        failures.append("recoverFromASRInterruption() did not reach readyForBatchDecode")
    if leak.get("leaked"):
        failures.append("an XPC helper leaked after the salvage")
    if not recovery.get("recovered"):
        failures.append("the next dictation did not recover after the fault")
    if failures:
        raise AssertionError(f"A3 failed: {'; '.join(failures)}. {outcome}")
    return outcome


# #1543: scenarios A4_audio_xpc_kill and A5_proxy_buffer_drop_watchdog were
# removed with the audio-capture boundary — both tested the deleted host-side
# proxy DEBUG commands. Real OS-level audio interruption testing (BT route flip,
# Zoom/Discord coexistence) still lives in docs/LANE_B_AUDIO_TESTS.md; the
# capture-stall watchdog is exercised in-process by the #1317 zero-fill
# proof-bench scenarios below.


_DEV_BUNDLE_ID = "com.enviouswispr.app.dev"
_WRITING_STYLE_BUTTON_LABELS = {
    "formal": "Formal — Professional tone, proper grammar",
    "standard": "Standard — Clean up grammar and punctuation",
    "friendly": "Friendly — Casual, conversational tone",
}


def _read_setting(key: str) -> Optional[str]:
    """Read a UserDefaults value from the dev app's domain."""
    try:
        out = subprocess.check_output(
            ["defaults", "read", _DEV_BUNDLE_ID, key],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
        return out
    except subprocess.CalledProcessError:
        return None


@scenario(
    ScenarioMeta(
        name="A6_settings_storm",
        lane="A",
        family="settings",
        backends=["both"],
        runtime_budget_seconds=30.0,
        founder_required=False,
        negative_control="Remove wordCorrectionEnabled live-sync from PipelineSettingsSync; setting takes no effect mid-record",
        description="Toggle wordCorrectionEnabled / fillerRemovalEnabled during active recording",
    )
)
def A6_settings_storm(**_) -> dict:
    """User behavior: dictation in progress, user opens Settings and
    flips heart-side toggles whose live-sync runs *during* an active
    recording — `wordCorrectionEnabled` (Your Words tab) and
    `fillerRemovalEnabled` (Transcription tab). These two flow through
    `PipelineSettingsSync` and modify the streaming-time inline post-
    process; the negative control on this scenario specifically names
    `wordCorrectionEnabled live-sync from PipelineSettingsSync`.

    Notes 2026-05-02:
    - Toggles in the AI Polish tab (writing style, Deep reasoning) are
      LIMBS — their copy explicitly says "Changes made during a recording
      apply to the next recording." So they do not exercise the live-sync
      hot path and are not what this scenario is for.
    - `noiseSuppression` was the heaviest live-sync (cancelled recording +
      rebuilt engine), but the toggle was removed in #734 because the rebuild
      path was structurally hostile to the heart and Apple Voice Processing
      was empirically unhelpful for ASR. No longer relevant to this scenario.
    - Pre-state is captured before the storm and restored after, so
      successive runs do not accumulate side effects on the user's
      configured custom-words / filler-removal preferences.
    """
    eyes = _import_wispr_eyes()
    eyes.connect()

    # Capture pre-state so we can restore after the storm.
    pre_word_correction = _read_setting("wordCorrectionEnabled")  # "0"/"1"/None
    pre_filler_removal = _read_setting("fillerRemovalEnabled")

    if not _start_recording_locked():
        return {"terminal": False, "reason": "could not enter recording", "state": query_state()}
    with _TTSAudio():
        time.sleep(0.5)  # let audio flow into streaming ASR
        # Storm 1: flip wordCorrectionEnabled twice on the Your Words tab.
        eyes.nav("Your Words")
        time.sleep(0.4)
        eyes.tap("Enable custom words")
        time.sleep(0.25)
        eyes.tap("Enable custom words")
        time.sleep(0.25)
        # Storm 2: flip fillerRemovalEnabled twice on the Transcription tab.
        eyes.nav("Transcription")
        time.sleep(0.4)
        eyes.tap("Remove filler words (um, uh, hmm...)")
        time.sleep(0.25)
        eyes.tap("Remove filler words (um, uh, hmm...)")
        time.sleep(0.25)
        # Continue recording briefly after the storm so the streaming
        # path sees both states with audio still flowing.
        time.sleep(0.5)
    # Stop recording (single tap exits hands-free lock).
    _stop_recording_locked(settle_s=2.0)
    terminated = assert_terminated(timeout_s=10.0)
    recovery = _assert_dictation_recovers()

    # Restore pre-state so successive runs do not accumulate. The toggles
    # were each flipped twice during the storm so they should already
    # match pre-state, but read defaults to confirm and re-flip if not.
    eyes.nav("Your Words")
    time.sleep(0.4)
    if (_read_setting("wordCorrectionEnabled") or "0") != (pre_word_correction or "0"):
        eyes.tap("Enable custom words")
        time.sleep(0.3)
    eyes.nav("Transcription")
    time.sleep(0.4)
    if (_read_setting("fillerRemovalEnabled") or "0") != (pre_filler_removal or "0"):
        eyes.tap("Remove filler words (um, uh, hmm...)")
        time.sleep(0.3)

    restored = {
        "pre_word_correction": pre_word_correction,
        "post_word_correction": _read_setting("wordCorrectionEnabled"),
        "pre_filler_removal": pre_filler_removal,
        "post_filler_removal": _read_setting("fillerRemovalEnabled"),
    }
    return {**terminated, **recovery, "settings_restored": restored}


@scenario(
    ScenarioMeta(
        name="A7_app_quit",
        lane="A",
        family="app-quit",
        backends=["both"],
        runtime_budget_seconds=30.0,
        founder_required=False,
        negative_control="Remove applicationWillTerminate cleanup in AppDelegate; orphan helper processes survive next launch",
        description="Cocoa quit mid-recording with audio flowing — no orphan helpers survive, app relaunches cleanly, next dictation works",
    )
)
def A7_app_quit(**_) -> dict:
    """User behavior: dictation in progress, user hits Cmd+Q. The app's
    `applicationWillTerminate` must clean up audio + ASR helpers — no
    orphan processes survive next launch. After relaunch the user must
    be able to dictate again normally.

    Notes 2026-05-02:
    - Cocoa quit is the user-real path (osascript `quit`); SIGKILL
      (`kill -9`) bypasses applicationWillTerminate and would not
      exercise this scenario.
    - TTS audio must be flowing so the quit happens against an active
      capture session (helpers actively allocated + connected), not an
      idle pipeline.
    - After the quit, the harness relaunches the bundle with
      EW_FAULT_INJECTION=1 so the recovery cycle can run end-to-end
      through the normal dictation path.
    """
    pre_helpers = list_xpc_service_pids()
    if not _start_recording_locked():
        return {"terminal": False, "reason": "could not enter recording", "state": query_state()}
    with _TTSAudio():
        time.sleep(0.8)  # warm-up: audio flowing into pipeline
        # Cocoa quit — triggers applicationWillTerminate cleanup.
        subprocess.run(
            ["osascript", "-e",
             'tell application id "com.enviouswispr.app.dev" to quit'],
            check=False, capture_output=True,
        )
        exited_cleanly = _wait_for_app_exit(timeout_s=10.0)
    # Give launchd a moment to reap helpers.
    time.sleep(2.0)
    post_helpers = list_xpc_service_pids()
    # Negative-control assertion: no orphan helpers from the killed
    # session. Helpers from before the test (pre_helpers) should be
    # gone too — the app's lifecycle owns them.
    orphans_remain = bool(post_helpers)
    # Relaunch + recovery cycle.
    relaunched = _relaunch_app()
    recovery = _assert_dictation_recovers() if relaunched["relaunched"] else {
        "recovered": False,
        "reason": "endpoint did not come up after relaunch",
    }
    return {
        "exited_cleanly": exited_cleanly,
        "pre_helpers": pre_helpers,
        "post_helpers": post_helpers,
        "orphans_remain": orphans_remain,
        **relaunched,
        **recovery,
    }


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
    """User behavior: dictation in progress with audio flowing, user
    opens Settings → Transcription and taps the OTHER engine button.
    The PipelineSettingsSync guard at line 90 must drop the switch
    silently (logs 'Backend switch blocked'), the active recording
    must finalize on the original backend, and `query_state` must
    show the original backend throughout.

    Notes 2026-05-02:
    - The UI text under the engine buttons says 'Changes made during
      a recording apply to the next recording.' That text is mildly
      misleading — the code (PipelineSettingsSync.swift:90 case) BLOCKS
      and DISCARDS the switch entirely; it does not buffer it for the
      next recording. UserDefaults `selectedBackend` does flip
      (SwiftUI binding writes through), but the asrManager never
      receives a `switchBackend(to:)` call.
    - The harness restores `selectedBackend` after the test by
      tapping the original engine button once recording has
      finalized, so successive runs do not leave UserDefaults in a
      lying state.
    """
    eyes = _import_wispr_eyes()
    eyes.connect()

    # Pre-state: assert idle, capture starting backend.
    if "idle" not in _active_state():
        _stop_recording_locked(settle_s=2.0)
    pre_backend = _read_setting("selectedBackend") or "parakeet"
    target_button_for_switch_attempt = (
        "Multi-Language" if pre_backend.lower() == "parakeet" else "Fast (English)"
    )
    target_button_for_restore = (
        "Fast (English)" if pre_backend.lower() == "parakeet" else "Multi-Language"
    )

    if not _start_recording_locked():
        return {"terminal": False, "reason": "could not enter recording", "state": query_state()}

    pipeline_state_during = ""
    pipeline_state_after_settle = ""
    # Hold the switched state long enough for a human to actually
    # perceive the visual flip in the Transcription tab. Without this
    # dwell the buttons toggle and toggle back in <1s — the test passes
    # in the data but a watching reviewer can't visually confirm it.
    display_dwell_seconds = 3.0
    with _TTSAudio():
        time.sleep(0.5)  # let audio flow into the active backend
        eyes.nav("Transcription")
        time.sleep(0.4)
        # Attempt the switch — should be blocked by the guard.
        eyes.tap(target_button_for_switch_attempt)
        time.sleep(0.3)
        # Snapshot which PIPELINE is actually doing the work. The
        # `backend=` field in query_state mirrors UserDefaults, which
        # SwiftUI flips immediately. The truthful signal is which
        # pipeline reports a non-idle state.
        pipeline_state_during = query_state()
        # Dwell so the swap is visible to a human reviewer.
        time.sleep(display_dwell_seconds)

    _stop_recording_locked(settle_s=2.0)
    pipeline_state_after_settle = query_state()
    terminated = assert_terminated(timeout_s=10.0)

    # Restore: tap the original engine button so UserDefaults matches reality.
    eyes.nav("Transcription")
    time.sleep(0.4)
    if (_read_setting("selectedBackend") or "").lower() != pre_backend.lower():
        eyes.tap(target_button_for_restore)
        time.sleep(0.4)

    recovery = _assert_dictation_recovers()

    # The truthful "switch_was_blocked" signal: during the recording,
    # the ORIGINAL backend's pipeline state was non-idle, and the OTHER
    # backend's pipeline state was idle. (If the switch had succeeded,
    # the original would have torn down to idle and the other would
    # have started recording.)
    parsed_during = _parse_query_state(pipeline_state_during)
    pre_backend_key = "parakeet" if pre_backend.lower() == "parakeet" else "whisperkit"
    other_key = "whisperkit" if pre_backend_key == "parakeet" else "parakeet"
    pre_backend_active = parsed_during.get(pre_backend_key, "") not in {"", "idle"}
    other_idle = parsed_during.get(other_key, "") in {"idle", ""}
    switch_was_blocked = pre_backend_active and other_idle

    return {
        **terminated,
        **recovery,
        "pre_backend": pre_backend,
        "pipeline_state_during": pipeline_state_during,
        "pipeline_state_after_settle": pipeline_state_after_settle,
        "switch_was_blocked": switch_was_blocked,
        "post_backend_userdefaults": _read_setting("selectedBackend"),
    }



APP_LOG_PATH = Path("~/Library/Logs/EnviousWispr/app.log").expanduser()


# #1543: scenario A10_audio_start_wedge_retry was removed with the audio-capture
# boundary — it tested the deleted XPC line-death start-retry (#1194), which
# cannot occur with capture in-process (no line to wedge).


@scenario(
    ScenarioMeta(
        name="A11_asr_kill_mid_model_load",
        lane="A",
        family="model-load",
        backends=["parakeet"],
        runtime_budget_seconds=30.0,
        founder_required=False,
        negative_control="Remove the pendingLoadCompletion resume from ASRManagerProxy's invalidation handler; the warm-up await hangs, isLoadInFlight never clears, and the recovery dictation stays blocked on a permanent 'warming' readiness (the #1388 119/126 defect)",
        description="ASR XPC connection invalidated mid-MODEL-LOAD (not mid-stream, A3's shape) — the pending load continuation must resume with the typed transport error, the warm-up must reach a terminal outcome, and the next dictation must succeed",
    )
)
def A11_asr_kill_mid_model_load(**_) -> dict:
    """User behavior: the speech service dies while the model is LOADING
    (cold press / launch warm-up), not while streaming. Before #1388 step 1
    the pending load reply was never resumed on invalidation: the warm-up
    await hung, the guard slot leaked, and no terminal telemetry ever fired
    (119 of 126 production wedge fires reached no outcome). The contract now
    requires the invalidation handler to resume the pending continuation
    with `serviceUnreachable`; the adapter's one-shot transport retry then
    reconnects to the respawned helper, so the user-visible outcome is a
    clean recovery or an honest error — never a stuck 'warming' state.

    #1388 notes:
    - The first force_xpc_kill drops the resident model (the invalidation
      handler clears isModelLoaded), so the next press takes the COLD path
      and drives a real in-flight loadModel.
    - The second force_xpc_kill lands ~0.4s into that load; Parakeet's load
      floor is multi-second, so the mid-load window is comfortable. This is
      a deliberate RACE PLACEMENT (the A8a precedent), not a wait-for-done —
      there is no signal for "the load is now mid-flight" by design.
    - Verdict is signal-based: pipeline state must reach a terminal token
      and the recovery dictation must PASS (before the fix, the leaked
      isLoadInFlight pinned readiness at 'warming' and blocked every
      subsequent press — the discriminating oracle). The wedge guard must
      NOT fire during the drill (the kill produces a typed error path, not
      a silence the detector should claim).
    """
    log_offset = APP_LOG_PATH.stat().st_size if APP_LOG_PATH.exists() else 0
    pre_helpers = list_xpc_service_pids()
    # 1. Drop the resident model so the next press drives a real cold load.
    reply_unload = force_xpc_kill()
    time.sleep(1.0)  # settle: async invalidation handler must clear isModelLoaded before the press
    # 2. A PTT press on the cold engine takes the BLOCKED cold-press path and
    #    drives ensureEngineWarm(.coldPress) — the sessionless warm-up this
    #    drill targets. First-run learning (2026-07-09): the MENU tap does NOT
    #    take this path after an idle-reap kill — the #959 design lets a menu
    #    press mint a session with an in-session re-warm, which is A3's shape,
    #    not this drill's. Only the PTT press logs "press blocked" and arms
    #    the sessionless guard.
    _tap_rcmd()
    time.sleep(0.2)  # settle: deliberate race placement inside the load window (A8a precedent)
    # 3. Kill the service mid-load. On a warm file cache the cached load can
    #    complete in <1s, so the kill may land AFTER completion — that run is
    #    a benign miss, reported honestly via window_hit below, not a pass
    #    that silently proved nothing.
    reply_kill = force_xpc_kill()
    terminated = assert_terminated(timeout_s=15.0)
    leak = assert_no_xpc_leak(pre_helpers)
    # 4. The contract's user-visible proof: dictation works after the fault.
    #    The recovery window must ride out the post-kill respawn + reload
    #    (multi-second); presses during 'warming' are refused by design.
    time.sleep(8.0)  # settle: ride out the post-kill service respawn + model reload before the recovery cycle
    recovery = _assert_dictation_recovers()

    tail = ""
    if APP_LOG_PATH.exists():
        with open(APP_LOG_PATH, "r", errors="replace") as f:
            f.seek(log_offset)
            tail = f.read()
    return {
        "reply_unload": reply_unload,
        "reply_kill": reply_kill,
        **terminated,
        **leak,
        **recovery,
        "wedge_guard_fired": "[WedgeGuard] sessionless wedge fired" in tail,
        # The drill exercised its target seam only if the press was BLOCKED
        # (sessionless path armed) — otherwise the kill landed on a different
        # shape and this run proved recovery only.
        "window_hit": "press blocked" in tail and "armed reason=cold_press" in tail,
    }


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


# ─────────────────── #1317 proof-bench: dead-mic zero-fill scenarios ─────────
#
# Deterministic runtime cells scored A/B in Phase 1. Each returns the two-class
# schema {evidence_valid, evidence, assertions}: a product FAILURE with valid
# evidence is a real measurement; missing/ambiguous evidence is INVALID (never a
# defaulted pass). `n` (LIVE-sample budgets) are kwargs so the live A/B run tunes
# them against real TTS cadence without editing this file.












# ──────────────────────────── CLI entry ────────────────────────────


# Required assertions per proof-bench scenario: the must-be-true product claims
# for THIS build to "pass" the cell in a strict standalone run. A valid-evidence
# product failure still exits nonzero here; the A/B baseline mode (run_gauntlet.py)
# is what continues through product failures to build the full scorecard.


def evaluate_trial(name: str, inner: dict) -> tuple[bool, str]:
    """(passed, reason) for a scenario result under the strict contract: evidence
    must be valid AND every required assertion true. Legacy scenarios with no
    evidence schema always pass (they carry their own inline verdicts)."""
    if "evidence_valid" not in inner:
        return True, "legacy scenario (no evidence schema)"
    if not inner.get("evidence_valid"):
        return False, f"EVIDENCE INVALID: {inner.get('evidence', {}).get('reason')}"
    required = _REQUIRED_ASSERTIONS.get(name, [])
    failed = [a for a in required if not inner.get("assertions", {}).get(a)]
    if failed:
        return False, f"required assertions failed: {failed}"
    return True, "ok"


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help", "list", "list_scenarios"):
        print_scenarios()
        return 0
    cmd = argv[0]
    if cmd == "run" and len(argv) >= 2:
        wrapped = run_scenario(argv[1])
        print(wrapped)
        passed, reason = evaluate_trial(argv[1], wrapped.get("result", {}))
        if not passed:
            print(reason, file=sys.stderr)
            return 1
        return 0
    if cmd == "query":
        print(query_state())
        return 0
    print(f"unknown: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
