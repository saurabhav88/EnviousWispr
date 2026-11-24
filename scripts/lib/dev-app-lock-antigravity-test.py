#!/usr/bin/env python3
"""scripts/lib/dev-app-lock-antigravity-test.py: an Antigravity chat is its own holder (#4913).

Runs PRIVATE COPIES of dev-app-lock.py with a temp lock folder, never the live
lock. Each rewrite must match once or the test stops. Process-chain cases
(synthetic) use a fake `ps` that prints the real `comm` strings measured on
2026-11-23 for shell -> language_server -> app; the card cases involve no
process; one case runs a real process tree with real /bin/ps (Darwin only).

    python3 scripts/lib/dev-app-lock-antigravity-test.py
"""

import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "dev-app-lock.py")
SERVER = "/Applications/Antigravity.app/Contents/Resources/bin/language_server"
APP = "/Applications/Antigravity.app/Contents/MacOS/Antigravity"
COORD = "58f49564-16d1-4413-aab0-9d610faba3d5"
WORKER = "dde083cf-e29b-4c0f-97f6-adb6be01936b"
PASS = FAIL = 0
ANCHOR = 'LOCK_DIR = os.path.expanduser("~/Library/Caches/EnviousWispr/dev-app-lock")'


def check(name, cond, detail=""):
    global PASS, FAIL
    PASS, FAIL = PASS + bool(cond), FAIL + (not cond)
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + ("" if cond else f": {detail}"))


def copy_tool(tmp, name, lock_dir, ps=None, extra=()):
    src = open(TOOL).read()
    rewrites = [(ANCHOR, f"LOCK_DIR = {lock_dir!r}")]
    if ps:
        rewrites.append(('PS = "/bin/ps"', f"PS = {ps!r}"))
    for old, new in [*rewrites, *extra]:
        if src.count(old) != 1:
            sys.exit(f"ABORT: rewrite target {old!r} found {src.count(old)} times")
        src = src.replace(old, new)
    path = os.path.join(tmp, name)
    open(path, "w").write(src)
    return path


def fake_ps(tmp, name, chain):
    """chain: comms from the tool's parent upward. The parent is THIS process."""
    table, pid = [], os.getpid()
    for i, comm in enumerate(chain):
        nxt = pid + 1000 if i + 1 < len(chain) else 1
        table.append(f"{pid} {nxt} {comm}")
        pid = nxt
    tab = os.path.join(tmp, f"{name}.table")
    open(tab, "w").write("\n".join(table) + "\n")
    path = os.path.join(tmp, f"{name}-ps")
    open(path, "w").write(
        "#!/bin/sh\nfor a; do p=$a; done\n"
        f"awk -v p=\"$p\" '$1==p {{ f=1; o=$2; $1=\"\"; $2=\"\"; sub(/^  /,\"\"); "
        f"print o \" Thu Jan  1 00:00:00 1970 S \" $0 }} END {{ if (!f) exit 1 }}' {shlex.quote(tab)}\n")
    os.chmod(path, 0o755)
    return path


def run(tool, *args, env=None, stdin=None):
    clean = {k: v for k, v in os.environ.items() if not k.startswith(("CODEX_", "ANTIGRAVITY_"))}
    p = subprocess.run([sys.executable, tool, *args], capture_output=True, text=True,
                       input=stdin if stdin is not None else "", env=dict(clean, **(env or {})))
    return p.returncode, p.stdout + p.stderr


def card(lock_dir):
    path = os.path.join(lock_dir, "holder.json")
    return json.load(open(path)) if os.path.exists(path) else None


def main():
    tmp = tempfile.mkdtemp(prefix="ew-agy-lock-test-")
    try:
        chain = [os.path.join("/bin", "zsh"), SERVER, APP]
        lock = os.path.join(tmp, "lock")
        ps = fake_ps(tmp, "agy", chain)
        tool = copy_tool(tmp, "agy.py", lock, ps)
        coord, worker = {"ANTIGRAVITY_CONVERSATION_ID": COORD}, {"ANTIGRAVITY_CONVERSATION_ID": WORKER}

        print("synthetic chains: shell -> language_server -> app")
        rc, out = run(tool, "claim", "--label", "coordinator", env=coord)
        c = card(lock)
        check("a chat claims: exit 0, card v5, kind antigravity, its conversation id",
              rc == 0 and c and c["version"] == 5 and c["kind"] == "antigravity"
              and c["session_id"] == COORD, out)
        rc, out = run(tool, "status")
        check("status names the conversation id", COORD in out, out)
        before = open(os.path.join(lock, "holder.json"), "rb").read()
        rc, out = run(tool, "claim", env=worker)
        check("a swarm worker (own id, same server) is refused while another holds: exit 3",
              rc == 3 and "BUSY" in out, out)
        rc, out = run(tool, "release", env=worker)
        check("that worker cannot release the coordinator's hold",
              rc == 3 and open(os.path.join(lock, "holder.json"), "rb").read() == before, out)
        rc, out = run(tool, "claim", env=coord)
        check("the same chat claiming again is already yours", rc == 0 and "already yours" in out, out)
        # A wait event for this hold (as a Claude hook would write) must not release it.
        nonce = card(lock)["nonce"]
        open(os.path.join(lock, f"wait-{nonce}.1000000000.set"), "w").close()
        rc, out = run(tool, "status")
        check("an Antigravity hold has no waiting release (a stale wait event is ignored and not shown)",
              "held by antigravity" in out and "free" not in out and "waiting" not in out, out)
        rc, out = run(tool, "wait-mark", stdin=json.dumps(
            {"hook_event_name": "Stop", "last_assistant_message": "x — NEED YOU"}), env=coord)
        left = sorted(n for n in os.listdir(lock) if n.startswith("wait-"))
        check("wait-mark from an Antigravity chat does nothing", rc == 0 and out == ""
              and left == [f"wait-{nonce}.1000000000.set"], (out, left))
        card_path = os.path.join(lock, "holder.json")
        due = dict(card(lock), reminded_at=0)
        with open(card_path, "w") as f:
            json.dump(due, f)
        check("remind from an Antigravity chat does nothing (even when a reminder is due)",
              run(tool, "remind", env=coord) == (0, "") and card(lock) == due)
        rc, out = run(tool, "release", env=coord)
        check("the chat releases", rc == 0 and card(lock) is None, out)

        print("identity that cannot be decided is busy, never a founder run")
        for label, env in [("missing id", {}), ("invalid id", {"ANTIGRAVITY_CONVERSATION_ID": "nope"})]:
            rc, out = run(tool, "claim", env=env)
            check(f"recognised server, {label}: exit 2, no card", rc == 2 and card(lock) is None, out)
        for label, comm in [("cut name (language_serve)", "language_serve"),
                            ("server outside the install roots", "/opt/x/Antigravity.app/Contents/Resources/bin/language_server"),
                            ("IDE-style server path", "/Applications/Antigravity IDE.app/Contents/Resources/bin/language_server")]:
            t = copy_tool(tmp, "cut.py", os.path.join(tmp, "lock-cut"),
                          fake_ps(tmp, "cut", ["/bin/zsh", comm, APP]))
            rc, out = run(t, "claim", env=coord)
            check(f"{label}: exit 2, never founder", rc == 2 and card(os.path.join(tmp, "lock-cut")) is None, out)

        print("nearest agent wins, both ways; env alone is not an agent")
        for label, comm, env, want in [
                ("claude inside an Antigravity shell", "claude", coord, "claimed by claude"),
                ("codex inside an Antigravity shell", "/usr/local/lib/node_modules/@openai/codex/vendor/codex/codex",
                 dict(coord, CODEX_THREAD_ID="fixture-codex"), "claimed by codex")]:
            lk = os.path.join(tmp, "lock-near")
            t = copy_tool(tmp, "near.py", lk, fake_ps(tmp, "near", ["/bin/zsh", comm, "/bin/zsh", SERVER, APP]))
            rc, out = run(t, "claim", env=env)
            check(label, rc == 0 and want in out, out)
            shutil.rmtree(lk, ignore_errors=True)
        lk = os.path.join(tmp, "lock-hand")
        t = copy_tool(tmp, "hand.py", lk, fake_ps(tmp, "hand", ["/bin/zsh", "/Applications/Terminal.app/Contents/MacOS/Terminal"]))
        for label, env in [("leaked ANTIGRAVITY_* in a hand-opened Terminal", dict(coord, ANTIGRAVITY_AGENT="1")),
                           ("no variables, no agent", {})]:
            rc, out = run(t, "claim", env=env)
            check(f"{label}: founder run, nothing written",
                  rc == 0 and "founder run" in out and card(lk) is None, out)

        print("card validation")
        for label, body in [("v5 with kind claude", {"version": 5, "kind": "claude"}),
                            ("v4 with kind antigravity", {"version": 4, "kind": "antigravity", "session_id": COORD}),
                            ("v5 antigravity, bad chat id", {"version": 5, "kind": "antigravity", "session_id": "x"}),
                            ("v4 with an unknown kind", {"version": 4, "kind": "antigravty"}),
                            ("unknown version 6", {"version": 6, "kind": "antigravity", "session_id": COORD})]:
            lk = os.path.join(tmp, "lock-card")
            os.makedirs(lk, exist_ok=True)
            base = {"pid": os.getpid(), "started": "x", "label": "", "worktree": "", "claimed_at": 1.0,
                    "reminded_at": 1.0, "nonce": "abc"}
            open(os.path.join(lk, "holder.json"), "w").write(json.dumps({**base, **body}))
            t = copy_tool(tmp, "card.py", lk, ps)
            rc, out = run(t, "claim", env=coord)
            check(f"{label}: refused, exit 2, card left alone",
                  rc == 2 and card(lk)["kind"] == body["kind"], out)
        shutil.rmtree(lk, ignore_errors=True)

        if sys.platform == "darwin" and os.access("/usr/bin/cc", os.X_OK):
            print("real process tree, real /bin/ps")
            root = os.path.join(tmp, "Antigravity.app/Contents/Resources/bin")
            os.makedirs(root)
            server = os.path.join(root, "language_server")
            # A copied Apple binary is killed (exit 137) and a copied python
            # re-executes itself from its install, so the stand-in server is a
            # 3-line C program that runs the shell command it is given.
            src = os.path.join(tmp, "server.c")
            open(src, "w").write("#include <stdlib.h>\nint main(int c,char**v){return system(v[1]);}\n")
            built = subprocess.run(["/usr/bin/cc", "-o", server, src], capture_output=True, text=True)
            rl = os.path.join(tmp, "lock-real")
            rt = copy_tool(tmp, "real.py", rl, None, extra=[(
                '"(?:/Applications|" + re.escape(os.path.expanduser("~/Applications")) + ")"',
                f"re.escape({tmp!r})")])
            env = dict(os.environ, ANTIGRAVITY_CONVERSATION_ID=COORD)
            p = subprocess.run([server, f'"{sys.executable}" "{rt}" claim --label real'],
                               capture_output=True, text=True, env=env) if built.returncode == 0 \
                else subprocess.CompletedProcess([], 1, "", "no server built")
            c = card(rl)
            check("a real server process (full comm path from ps) is recognised as antigravity",
                  built.returncode == 0 and c and c["kind"] == "antigravity"
                  and c["session_id"] == COORD, (built.stderr, p.stdout, p.stderr))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"dev-app-lock antigravity test: {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
