# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp==2.2.0"]
# ///
"""MCP server for the #3765 dev control door: one tool per CLI command, each a subprocess
call to `dev_control.py`, which keeps every check (instance, identity, dev-app lock, framing,
unknown outcomes). This file decides nothing the CLI decides.

Run:  uv run --script Tests/RuntimeUAT/dev_control_mcp.py
Self-test:  uv run --script Tests/RuntimeUAT/dev_control_mcp_self_test.py

Environment:
  EW_DEV_WORKTREE    the checkout whose dev build the tools drive (default: the MAIN
                     checkout of this file's repository); passed to the CLI as --worktree
  EW_DEV_CLI_PYTHON  the interpreter that runs the CLI (default /usr/bin/python3, which has
                     PyObjC for `file transcribe`; the isolated MCP environment does not)

`ew_keys_set` takes the NAME of a stored secret, never a key. The key is resolved by
`get-key launch` into the child's environment and handed to the CLI on stdin; it never
appears in a tool argument, argv, a reply, a log line or an error.

stdout belongs to the MCP transport; diagnostics go to stderr.
"""

import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CLI_PYTHON = "/usr/bin/python3"
GET_KEY = os.path.expanduser("~/.claude/bin/get-key")
KEY_ENV = "EW_DEV_CONTROL_KEY"
SECRET_NAME = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")
KEY_PROVIDERS = ("openai", "gemini", "claude")
MODEL_BACKENDS = ("parakeet", "whisper")
# Seconds a CLI call may take before the tool gives up watching it. A wait or a file
# transcription adds its own timeout on top.
CALL_SECONDS = float(os.environ.get("EW_DEV_MCP_CALL_SECONDS", "60"))

# Test seams, both logged to stderr when used: the CLI script and the secret launcher.
CLI_PATH = os.environ.get("EW_DEV_CONTROL_CLI") or os.path.join(HERE, "dev_control.py")
if os.environ.get("EW_DEV_CONTROL_CLI"):
    print(f"dev_control_mcp: CLI overridden to {CLI_PATH}", file=sys.stderr)
if os.environ.get("EW_DEV_GET_KEY"):
    GET_KEY = os.environ["EW_DEV_GET_KEY"]
    print(f"dev_control_mcp: secret launcher overridden to {GET_KEY}", file=sys.stderr)


def worktree():
    """EW_DEV_WORKTREE, or the main checkout as the CLI's own resolver finds it."""
    configured = os.environ.get("EW_DEV_WORKTREE")
    if configured:
        return configured
    if HERE not in sys.path:
        sys.path.insert(0, HERE)
    import dev_control
    main = dev_control._main_worktree(HERE)
    if main is None:
        raise RuntimeError("cannot resolve the main checkout; set EW_DEV_WORKTREE")
    return main


def words_add_args(word, aliases):
    """`words add` arguments. Option values are attached with `=`, so one that starts with a
    dash stays a value; the word follows `--`."""
    return ["words", "add", *[f"--alias={alias}" for alias in aliases or []], "--", word]


def words_update_args(id, word, aliases, clear_aliases):
    """`words update` arguments. `aliases=None` leaves them alone; `aliases=[]` (or
    `clear_aliases`) clears them."""
    args = ["words", "update"]
    if word is not None:
        args.append(f"--word={word}")
    args += [f"--alias={alias}" for alias in aliases or []]
    if clear_aliases or aliases == []:
        args.append("--clear-aliases")
    return args + ["--", id]


def cli_python():
    return os.environ.get("EW_DEV_CLI_PYTHON") or DEFAULT_CLI_PYTHON


def cli_argv(*args):
    """The CLI invocation for one command, as an argument list (no shell)."""
    return [cli_python(), CLI_PATH, "--worktree", worktree(), *args]


def run_cli(args, timeout, stdin=None):
    """(exit status, stdout text) of one CLI run; stderr goes to ours. A timeout stops
    watching and is reported as such; nothing is retried."""
    try:
        done = subprocess.run(cli_argv(*args), input=stdin, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, ""
    sys.stderr.write(done.stderr.decode("utf-8", "replace"))
    return done.returncode, done.stdout.decode("utf-8", "replace")


def feed_key(provider):
    """`--feed-key PROVIDER`: run under `get-key launch`, so the key arrives in KEY_ENV; hand
    it to `dev_control.py keys set` on stdin and pass the CLI's stdout and exit through.
    The key is removed from the environment before the CLI starts. Stdlib only."""
    value = os.environ.pop(KEY_ENV, None)
    if not value:
        print(json.dumps({"ok": False, "error": {
            "code": "secretUnavailable", "message": "the launcher supplied no key"}}))
        return 1
    try:
        done = subprocess.run(cli_argv("keys", "set", provider), input=value.encode("utf-8"),
                              capture_output=True, timeout=CALL_SECONDS)
    except subprocess.TimeoutExpired:
        print(json.dumps({"ok": False, "error": {
            "code": "timedOut", "message": "keys set did not answer; read status before retrying"}}))
        return 1
    sys.stdout.write(done.stdout.decode("utf-8", "replace"))
    return done.returncode


def build_server():
    from typing import Any, Literal

    from mcp.server import MCPServer
    from mcp.types import CallToolResult, TextContent

    server = MCPServer(
        "ew-dev",
        instructions=(
            "Drives a running EnviousWispr dev build through dev_control.py. Mutations need "
            "the shared dev-app lock. A nonzero CLI exit is an error result whose text is the "
            "CLI's JSON (dictation start errors keep their receipt). Settings writes persist "
            "in the shared preferences; snapshot and restore what you change."))

    def result(status, text, timed_out_message):
        if status is None:
            text = json.dumps({"ok": False, "error": {"code": "timedOut",
                                                      "message": timed_out_message}})
        return CallToolResult(content=[TextContent(type="text", text=text)],
                              is_error=status != 0)

    def call(*args, timeout=CALL_SECONDS, mutation=False):
        status, text = run_cli(args, timeout)
        note = ("the command did not answer in time; its outcome is unknown: read state "
                "before retrying" if mutation else "the command did not answer in time")
        return result(status, text, note)

    @server.tool()
    def ew_status() -> CallToolResult:
        """Engine, model, import and saved-key state of the dev build."""
        return call("status")

    @server.tool()
    def ew_settings_list() -> CallToolResult:
        """Every setting with its value, kind and deferral."""
        return call("settings", "list")

    @server.tool()
    def ew_settings_get(key: str) -> CallToolResult:
        """One setting by its key."""
        return call("settings", "get", "--", key)

    @server.tool()
    def ew_settings_set(key: str, value: Any, force: bool = False) -> CallToolResult:
        """Write one setting. `value` is the JSON value; `force` skips the screens' checks."""
        args = ["settings", "set"] + (["--force"] if force else []) + [
            "--", key, json.dumps(value, allow_nan=False)]
        return call(*args, mutation=True)

    @server.tool()
    def ew_language_set(code: str) -> CallToolResult:
        """The language picker's choice: a row code (de, en, en-gb, ...) or auto."""
        return call("language", "set", "--", code, mutation=True)

    @server.tool()
    def ew_channel_set(device_uid: str, channel: int) -> CallToolResult:
        """Pick a connected multi-input microphone's input (0 is Input 1)."""
        return call("channel", "set", "--", device_uid, str(int(channel)), mutation=True)

    @server.tool()
    def ew_shortcut_set(role: Literal["record", "cancel", "quickAdd", "pasteLast", "copyLast"],
                        key_code: int, modifiers: int) -> CallToolResult:
        """Save a Keybinds shortcut whole, checked as the screen checks it. `modifiers` is the
        modifier-flags integer (0 for none); recording is stored as the toggle pair."""
        return call("shortcut", "set", "--", role, str(int(key_code)), str(int(modifiers)),
                    mutation=True)

    @server.tool()
    def ew_keys_set(provider: Literal["openai", "gemini", "claude"],
                    secret_name: str) -> CallToolResult:
        """Save a provider's API key from a stored secret NAME (get-key), never a key value.
        Replies with presence only."""
        if provider not in KEY_PROVIDERS or not SECRET_NAME.fullmatch(secret_name):
            return result(2, json.dumps({"ok": False, "error": {
                "code": "usage", "message": "provider or secret name is not valid"}}), "")
        launch = [GET_KEY, "launch", secret_name, KEY_ENV, "--",
                  sys.executable, os.path.abspath(__file__), "--feed-key", provider]
        try:
            done = subprocess.run(launch, capture_output=True, timeout=CALL_SECONDS + 30)
        except subprocess.TimeoutExpired:
            return result(None, "", "keys set did not answer; read status before retrying")
        # The launcher's stderr is dropped, never forwarded: it is the one place outside the
        # child that could mention the secret it fetched.
        text = done.stdout.decode("utf-8", "replace")
        if done.returncode != 0 and not text.strip():
            text = json.dumps({"ok": False, "error": {
                "code": "secretUnavailable",
                "message": "the secret launcher failed (check get-key --check NAME)"}})
        return result(done.returncode, text, "")

    @server.tool()
    def ew_keys_clear(provider: Literal["openai", "gemini", "claude"]) -> CallToolResult:
        """Clear a provider's saved API key."""
        return call("keys", "clear", provider, mutation=True)

    @server.tool()
    def ew_words_list() -> CallToolResult:
        """Your Words, in order."""
        return call("words", "list")

    @server.tool()
    def ew_words_add(word: str, aliases: list[str] | None = None) -> CallToolResult:
        """Add a word, with optional aliases."""
        return call(*words_add_args(word, aliases), mutation=True)

    @server.tool()
    def ew_words_update(id: str, word: str | None = None, aliases: list[str] | None = None,
                        clear_aliases: bool = False) -> CallToolResult:
        """Change a word's spelling and/or replace its aliases; `aliases=[]` clears them."""
        return call(*words_update_args(id, word, aliases, clear_aliases), mutation=True)

    @server.tool()
    def ew_words_remove(id: str) -> CallToolResult:
        """Remove a word by id."""
        return call("words", "remove", "--", id, mutation=True)

    @server.tool()
    def ew_history_list(limit: int | None = None) -> CallToolResult:
        """History rows, newest first (summaries)."""
        return call("history", "list", *([] if limit is None else ["--limit", str(limit)]))

    @server.tool()
    def ew_history_get(id: str) -> CallToolResult:
        """One History row with its text fields."""
        return call("history", "get", "--", id)

    @server.tool()
    def ew_dictation_start(front_app: str | None = None) -> CallToolResult:
        """Start one take on the active engine; returns its receipt."""
        args = ["dictation", "start"] + ([] if front_app is None else ["--front-app", front_app])
        return call(*args, mutation=True)

    @server.tool()
    def ew_dictation_stop(receipt: dict[str, Any]) -> CallToolResult:
        """Stop the take a receipt names."""
        return call("dictation", "stop", "--receipt", json.dumps(receipt), mutation=True)

    @server.tool()
    def ew_dictation_cancel() -> CallToolResult:
        """Press Cancel on the active engine's take."""
        return call("dictation", "cancel", mutation=True)

    @server.tool()
    def ew_dictation_receipt(receipt: dict[str, Any]) -> CallToolResult:
        """Pending, or the take's frozen result."""
        return call("dictation", "receipt", "--receipt", json.dumps(receipt))

    @server.tool()
    def ew_dictation_wait(receipt: dict[str, Any], timeout: float = 120.0) -> CallToolResult:
        """Wait for that take's own result and saved History row; a timeout never stops it."""
        return call("dictation", "wait", "--receipt", json.dumps(receipt),
                    "--timeout", repr(float(timeout)), timeout=CALL_SECONDS + float(timeout))

    @server.tool()
    def ew_meeting_start(entry_point: Literal["history", "menu"] = "menu",
                         call_sound: bool | None = None) -> CallToolResult:
        """Ask the EnviousMeet Start the menu and page use; call_sound overrides this request
        only. waitingForExplainer means a person must answer the page's explainer."""
        args = ["meeting", "start", "--entry-point", entry_point]
        if call_sound is not None:
            args.append("--call-sound" if call_sound else "--no-call-sound")
        return call(*args, mutation=True)

    @server.tool()
    def ew_meeting_stop(id: str) -> CallToolResult:
        """Stop the meeting recording with that id."""
        return call("meeting", "stop", "--", id, mutation=True)

    @server.tool()
    def ew_meeting_status() -> CallToolResult:
        """EnviousMeet's live state: phase, processing stage, notice, pending Start steps."""
        return call("meeting", "status")

    @server.tool()
    def ew_meeting_list(limit: int | None = None) -> CallToolResult:
        """Saved meetings, newest first (records, no text)."""
        return call("meeting", "list", *([] if limit is None else ["--limit", str(limit)]))

    @server.tool()
    def ew_meeting_get(id: str, turn_offset: int | None = None, turn_limit: int | None = None,
                       include_text: bool = False) -> CallToolResult:
        """One meeting with its History row's turns (echo flagged) and visible projection."""
        args = ["meeting", "get"]
        if turn_offset is not None:
            args += ["--turn-offset", str(turn_offset)]
        if turn_limit is not None:
            args += ["--turn-limit", str(turn_limit)]
        if include_text:
            args.append("--include-text")
        return call(*args, "--", id)

    @server.tool()
    def ew_meeting_retry(id: str) -> CallToolResult:
        """Transcribe a finished, failed or interrupted meeting again."""
        return call("meeting", "retry", "--", id, mutation=True)

    @server.tool()
    def ew_meeting_delete_audio(id: str) -> CallToolResult:
        """Delete a meeting's audio, keeping its transcript."""
        return call("meeting", "delete-audio", "--", id, mutation=True)

    @server.tool()
    def ew_meeting_delete(id: str) -> CallToolResult:
        """Delete a meeting: audio, record and History row."""
        return call("meeting", "delete", "--", id, mutation=True)

    @server.tool()
    def ew_meeting_notes_get(id: str) -> CallToolResult:
        """A meeting's notes as saved, read from disk first."""
        return call("meeting", "notes-get", "--", id)

    @server.tool()
    def ew_meeting_notes_set(id: str, notes: str) -> CallToolResult:
        """Type and save a meeting's notes, as the Notes tab does."""
        return call("meeting", "notes-set", f"--text={notes}", "--", id, mutation=True)

    @server.tool()
    def ew_meeting_summary_get(id: str) -> CallToolResult:
        """A meeting's summary: text, origin, out of date, owed, and what is writing it."""
        return call("meeting", "summary-get", "--", id)

    @server.tool()
    def ew_meeting_summary_write(id: str, replace: bool = False) -> CallToolResult:
        """Write summary / Write again; replace confirms replacing an edited summary. Returns at
        the start: poll ew_meeting_summary_get."""
        args = ["meeting", "summary-write"] + (["--replace"] if replace else [])
        return call(*args, "--", id, mutation=True)

    @server.tool()
    def ew_meeting_live() -> CallToolResult:
        """The recording meeting's live words (memory only), or null."""
        return call("meeting", "live")

    @server.tool()
    def ew_models_download(backend: Literal["parakeet", "whisper"]) -> CallToolResult:
        """Press the model's Download (Whisper) or Resume (Parakeet)."""
        return call("models", "download", backend, mutation=True)

    @server.tool()
    def ew_models_cancel(backend: Literal["parakeet", "whisper"]) -> CallToolResult:
        """Cancel the model's download."""
        return call("models", "cancel", backend, mutation=True)

    @server.tool()
    def ew_file_transcribe(path: str, timeout: float = 900.0) -> CallToolResult:
        """Transcribe a file through Transcribe a File; adds a History row."""
        return call("file", "transcribe", "--timeout", repr(float(timeout)), "--", path,
                    timeout=CALL_SECONDS + float(timeout), mutation=True)

    return server


def main(argv):
    if len(argv) == 2 and argv[0] == "--feed-key" and argv[1] in KEY_PROVIDERS:
        return feed_key(argv[1])
    if argv:
        print("usage: dev_control_mcp.py   (or --feed-key PROVIDER, used by ew_keys_set)",
              file=sys.stderr)
        return 2
    build_server().run(transport="stdio")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
