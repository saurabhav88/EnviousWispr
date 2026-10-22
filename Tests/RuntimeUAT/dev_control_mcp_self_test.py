# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp==2.2.0"]
# ///
"""Self-test for `dev_control_mcp.py` (#3765): the real pinned MCP server over stdio, with
the CLI and the secret launcher replaced by recording fakes at their process boundaries.

Harness Contract: this checks the instrument agents drive the dev build through from a Claude
Code session. When it fails, a tool runs the wrong command, reports a failure as success, or
lets a key reach a reply. No customer sees it.

Run:  uv run --script Tests/RuntimeUAT/dev_control_mcp_self_test.py
Prints one JSON document; exit 0 only when every check passed.
"""

import asyncio
import hashlib
import json
import os
import shutil
import sys
import tempfile
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "dev_control_mcp.py")

EXPECTED_TOOLS = {
    "ew_status", "ew_settings_list", "ew_settings_get", "ew_settings_set", "ew_language_set",
    "ew_channel_set", "ew_shortcut_set",
    "ew_keys_set", "ew_keys_clear", "ew_words_list", "ew_words_add", "ew_words_update",
    "ew_words_remove", "ew_history_list", "ew_history_get", "ew_dictation_start",
    "ew_dictation_stop", "ew_dictation_cancel", "ew_dictation_receipt", "ew_dictation_wait",
    "ew_models_download", "ew_models_cancel", "ew_file_transcribe",
    "ew_meeting_start", "ew_meeting_stop", "ew_meeting_status", "ew_meeting_list",
    "ew_meeting_get", "ew_meeting_retry", "ew_meeting_delete_audio", "ew_meeting_delete",
}
RECEIPT = {"launch": "0b7c2a1e-0000-4000-8000-000000000001", "backend": "parakeet",
           "take": "5f1d7a3c-0000-4000-8000-000000000002"}

# A recording stand-in for dev_control.py: logs argv, the stdin's SHA-256 and whether the
# key variable reached it, then answers by command.
FAKE_CLI = r'''
import hashlib, json, os, sys, time
args = sys.argv[1:]
data = sys.stdin.buffer.read() if args[2:4] == ["keys", "set"] else b""
with open(os.environ["EW_FAKE_LOG"], "a") as log:
    log.write(json.dumps({"python": sys.executable, "argv": args,
                          "stdin_sha": hashlib.sha256(data).hexdigest() if data else None,
                          "key_in_env": "EW_DEV_CONTROL_KEY" in os.environ}) + "\n")
cmd = args[2:]
def out(doc, code):
    print(json.dumps(doc)); sys.exit(code)
if cmd[:2] == ["history", "list"] and "--limit" in cmd and cmd[cmd.index("--limit") + 1] == "199":
    time.sleep(30)
if cmd[:3] == ["dictation", "start", "--front-app"] and cmd[3] == "lost.app":
    out({"ok": False, "error": {"code": "frontAppLost", "message": "m", "receipt": json.loads(os.environ["EW_FAKE_RECEIPT"])}}, 1)
if cmd[:2] == ["file", "transcribe"]:
    out({"ok": False, "error": {"code": "dependencyUnavailable", "message": "no PyObjC"}}, 1)
if cmd[:2] == ["keys", "set"]:
    out({"ok": True, "result": {"provider": cmd[2], "stored": True, "presence": "present"}}, 0)
out({"ok": True, "result": {"echo": cmd}}, 0)
'''

# A stand-in for get-key: `launch NAME VAR -- cmd...` puts the named synthetic secret in VAR
# and runs cmd; `missing` fails with a message that names the secret it was after.
FAKE_GET_KEY = r'''
import os, sys
args = sys.argv[1:]
secrets = {"test-key": os.environ["EW_FAKE_SECRET"]}
if args[0] != "launch" or args[3] != "--":
    sys.exit(64)
name, var, cmd = args[1], args[2], args[4:]
if name not in secrets:
    sys.stderr.write("get-key: error: cannot read " + name + " " + os.environ["EW_FAKE_SECRET"] + "\n")
    sys.exit(1)
os.environ[var] = secrets[name]
os.execv(cmd[0], cmd)
'''


class Results:
    def __init__(self):
        self.passed = 0
        self.failures = []

    def check(self, name, condition, detail=""):
        if condition:
            self.passed += 1
            print(f"  ok      {name}", file=sys.stderr)
        else:
            self.failures.append(f"{name}: {detail}")
            print(f"  FAIL    {name}: {detail}", file=sys.stderr)


def read_log(path):
    if not os.path.exists(path):
        return []
    with open(path) as handle:
        return [json.loads(line) for line in handle if line.strip()]


async def run_cases(r, base):
    from mcp import ClientSession
    from mcp.client.stdio import StdioServerParameters, stdio_client

    fake_cli = os.path.join(base, "fake_cli.py")
    fake_get_key = os.path.join(base, "fake_get_key.py")
    with open(fake_cli, "w") as handle:
        handle.write(FAKE_CLI)
    with open(fake_get_key, "w") as handle:
        handle.write("#!" + sys.executable + "\n" + FAKE_GET_KEY)
    os.chmod(fake_get_key, 0o700)
    log = os.path.join(base, "calls.jsonl")
    worktree = os.path.join(base, "wt")
    os.makedirs(worktree)
    secret = "sk-synthetic-" + uuid.uuid4().hex
    env = dict(os.environ)
    env.update({
        "EW_DEV_CONTROL_CLI": fake_cli, "EW_DEV_GET_KEY": fake_get_key,
        "EW_DEV_WORKTREE": worktree, "EW_DEV_CLI_PYTHON": sys.executable,
        "EW_DEV_MCP_CALL_SECONDS": "3", "EW_FAKE_LOG": log, "EW_FAKE_SECRET": secret,
        "EW_FAKE_RECEIPT": json.dumps(RECEIPT),
    })
    params = StdioServerParameters(command="uv", args=["run", "--script", SERVER], env=env)
    exchanges = 0

    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            exchanges += 1
            listed = await session.list_tools()
            exchanges += 1
            tools = {tool.name: tool for tool in listed.tools}
            r.check("tools/list names exactly the agreed tools", set(tools) == EXPECTED_TOOLS,
                    f"extra={set(tools) - EXPECTED_TOOLS} missing={EXPECTED_TOOLS - set(tools)}")
            models_schema = json.dumps(tools["ew_models_download"].input_schema)
            keys_schema = tools["ew_keys_set"].input_schema
            r.check("typed schemas: model backends and key providers are closed choices",
                    "whisper" in models_schema and "parakeet" in models_schema
                    and set(keys_schema.get("required", [])) == {"provider", "secret_name"}
                    and "value" not in json.dumps(keys_schema), models_schema)
            r.check("typed schemas: settings set has a boolean force",
                    tools["ew_settings_set"].input_schema["properties"]["force"].get("type")
                    == "boolean", json.dumps(tools["ew_settings_set"].input_schema))

            async def call(name, arguments=None):
                nonlocal exchanges
                exchanges += 1
                before = len(read_log(log))
                reply = await session.call_tool(name, arguments or {})
                text = "".join(getattr(part, "text", "") for part in reply.content)
                return reply, text, read_log(log)[before:]

            reply, text, calls = await call("ew_status")
            r.check("a read runs the CLI with the configured interpreter, worktree and argv",
                    not reply.is_error and json.loads(text)["result"]["echo"] == ["status"]
                    and len(calls) == 1 and calls[0]["python"] == sys.executable
                    and calls[0]["argv"] == ["--worktree", worktree, "status"],
                    f"{text} {calls}")

            reply, text, calls = await call(
                "ew_settings_set", {"key": "fillerRemovalEnabled", "value": False, "force": True})
            r.check("a mutation passes typed JSON after --, with --force",
                    not reply.is_error and len(calls) == 1 and calls[0]["argv"][2:] == [
                        "settings", "set", "--force", "--", "fillerRemovalEnabled", "false"],
                    f"{calls}")

            reply, text, calls = await call("ew_words_add", {"word": "-dash", "aliases": ["a b"]})
            r.check("a positional that starts with a dash stays a positional",
                    calls and calls[0]["argv"][2:] == ["words", "add", "--alias=a b", "--",
                                                       "-dash"], f"{calls}")

            reply, text, calls = await call("ew_channel_set", {"device_uid": "-mic", "channel": 1})
            r.check("channel set passes the device after -- and the input as an integer",
                    not reply.is_error and calls and calls[0]["argv"][2:] == [
                        "channel", "set", "--", "-mic", "1"], f"{calls}")

            reply, text, calls = await call(
                "ew_shortcut_set", {"role": "quickAdd", "key_code": 40, "modifiers": 393216})
            r.check("shortcut set passes role, key code and modifiers after -- as integers",
                    not reply.is_error and calls and calls[0]["argv"][2:] == [
                        "shortcut", "set", "--", "quickAdd", "40", "393216"], f"{calls}")

            reply, text, calls = await call("ew_dictation_start", {"front_app": "lost.app"})
            document = json.loads(text) if text.strip() else {}
            r.check("a nonzero CLI exit is an MCP error that keeps error.receipt",
                    reply.is_error and document.get("error", {}).get("receipt") == RECEIPT,
                    f"is_error={reply.is_error} {text}")

            reply, text, calls = await call("ew_dictation_wait", {"receipt": RECEIPT, "timeout": 5})
            r.check("wait passes the receipt and its timeout",
                    not reply.is_error and calls and calls[0]["argv"][2:] == [
                        "dictation", "wait", "--receipt", json.dumps(RECEIPT), "--timeout", "5.0"],
                    f"{calls}")

            reply, text, calls = await call("ew_file_transcribe", {"path": "/abs/clip.m4a"})
            r.check("file transcribe's dependency refusal stays an explicit error",
                    reply.is_error and "dependencyUnavailable" in text, text)

            reply, text, calls = await call(
                "ew_keys_set", {"provider": "openai", "secret_name": "test-key"})
            digest = hashlib.sha256(secret.encode()).hexdigest()
            r.check("a secret name reaches the CLI as stdin only, removed from its environment",
                    not reply.is_error and len(calls) == 1
                    and calls[0]["argv"][2:] == ["keys", "set", "openai"]
                    and calls[0]["stdin_sha"] == digest and calls[0]["key_in_env"] is False
                    and secret not in text and secret not in json.dumps(calls),
                    f"{text} {calls}")

            reply, text, calls = await call(
                "ew_keys_set", {"provider": "openai", "secret_name": "missing"})
            r.check("a launcher failure is an error that never forwards its stderr",
                    reply.is_error and calls == [] and secret not in text
                    and "secretUnavailable" in text, text)

            for bad in ("../x", "A B", "x" * 80, ""):
                reply, text, calls = await call(
                    "ew_keys_set", {"provider": "openai", "secret_name": bad})
                r.check(f"an invalid secret name {bad[:12]!r} is refused before launching",
                        reply.is_error and calls == [], text)

            reply, text, calls = await call("ew_history_list", {"limit": 199})
            r.check("a CLI that does not answer times out once, with no retry",
                    reply.is_error and "timedOut" in text and len(calls) == 1, f"{text} {calls}")

            reply, text, calls = await call(
                "ew_meeting_start", {"entry_point": "history", "call_sound": False})
            r.check("meeting start passes the entry point and this request's call-sound flag",
                    not reply.is_error and calls and calls[0]["argv"][2:] == [
                        "meeting", "start", "--entry-point", "history", "--no-call-sound"],
                    f"{calls}")

            reply, text, calls = await call(
                "ew_meeting_get", {"id": "-m", "turn_limit": 5, "include_text": True})
            r.check("meeting get passes paging flags and the id after --",
                    not reply.is_error and calls and calls[0]["argv"][2:] == [
                        "meeting", "get", "--turn-limit", "5", "--include-text", "--", "-m"],
                    f"{calls}")

            reply, text, calls = await call("ew_meeting_delete_audio", {"id": "m1"})
            r.check("meeting delete-audio maps to the CLI's delete-audio verb",
                    not reply.is_error and calls and calls[0]["argv"][2:] == [
                        "meeting", "delete-audio", "--", "m1"], f"{calls}")

            reply, text, calls = await call("ew_models_download", {"backend": "whisper"})
            r.check("models download maps to the CLI's models command",
                    not reply.is_error and calls[0]["argv"][2:] == ["models", "download",
                                                                    "whisper"], f"{calls}")
            try:
                reply = await session.call_tool("ew_models_download", {"backend": "sherpa"})
                refused = reply.is_error
            except Exception:
                refused = True
            exchanges += 1
            r.check("a backend outside the closed choice is refused", refused, "")
    return exchanges


def offline_cases(r):
    """The wrappers' argument builders through the SHIPPED CLI parser, and worktree
    resolution, with no server and no subprocess."""
    sys.path.insert(0, HERE)
    import dev_control
    import dev_control_mcp as mcp_server

    def parsed(args):
        return dev_control.build_parser().parse_args(["--worktree", "/x", *args])

    word_id = str(uuid.uuid4())
    for label, args, check in (
        ("add: dash-leading word and alias stay values",
         mcp_server.words_add_args("-dash", ["-alias", "a b"]),
         lambda a: a.word == "-dash" and a.alias == ["-alias", "a b"]),
        ("add: no aliases",
         mcp_server.words_add_args("Fooflux", None), lambda a: a.alias is None),
        ("update: omitted aliases leave them alone",
         mcp_server.words_update_args(word_id, "W", None, False),
         lambda a: a.word == "W" and a.alias is None and not a.clear_aliases),
        ("update: an empty alias list clears them",
         mcp_server.words_update_args(word_id, None, [], False),
         lambda a: a.alias is None and a.clear_aliases and a.id == word_id),
        ("update: clearing alongside a spelling change",
         mcp_server.words_update_args(word_id, "-W", [], False),
         lambda a: a.word == "-W" and a.clear_aliases),
        ("update: dash-leading aliases replace them",
         mcp_server.words_update_args(word_id, None, ["-x"], False),
         lambda a: a.alias == ["-x"] and not a.clear_aliases),
    ):
        try:
            ok = check(parsed(args))
            detail = str(args)
        except (dev_control.CliError, SystemExit) as error:
            ok, detail = False, f"{args}: {error}"
        r.check(f"shipped parser: {label}", ok, detail)

    saved = os.environ.pop("EW_DEV_WORKTREE", None)
    real = dev_control._main_worktree
    try:
        os.environ["EW_DEV_WORKTREE"] = "/explicit/tree"
        r.check("worktree: an explicit EW_DEV_WORKTREE wins",
                mcp_server.worktree() == "/explicit/tree", mcp_server.worktree())
        del os.environ["EW_DEV_WORKTREE"]
        expected = real(HERE)
        r.check("worktree: the default is the main checkout the CLI resolver names",
                expected is not None and mcp_server.worktree() == expected,
                f"{mcp_server.worktree()} vs {expected}")
        here_checkout = os.path.realpath(os.path.dirname(os.path.dirname(HERE)))
        if os.path.isfile(os.path.join(here_checkout, ".git")):  # running from a side worktree
            r.check("worktree: from a side worktree the default is NOT that worktree",
                    mcp_server.worktree() != here_checkout, mcp_server.worktree())
        dev_control._main_worktree = lambda here: None
        try:
            mcp_server.cli_argv("status")
            refused = False
        except RuntimeError:
            refused = True
        r.check("worktree: an unresolvable main checkout refuses before any argv exists",
                refused, "")
    finally:
        dev_control._main_worktree = real
        if saved is not None:
            os.environ["EW_DEV_WORKTREE"] = saved


def main():
    r = Results()
    offline_cases(r)
    base = tempfile.mkdtemp(prefix="ewdc-mcp-selftest-")
    try:
        exchanges = asyncio.run(run_cases(r, base))
    except Exception as error:  # a broken protocol run must still print one document
        exchanges = 0
        r.failures.append(f"protocol run failed: {type(error).__name__}: {error}")
    finally:
        shutil.rmtree(base, ignore_errors=True)
    if exchanges == 0:
        r.failures.append("no MCP exchange happened")
    ok = not r.failures and r.passed > 0
    print(f"dev_control_mcp self-test: {r.passed} passed, {len(r.failures)} failed", file=sys.stderr)
    print(json.dumps({"ok": ok, "result": {"selfTest": {
        "cases": r.passed, "tools": len(EXPECTED_TOOLS), "exchanges": exchanges,
        "failures": r.failures}}}))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
