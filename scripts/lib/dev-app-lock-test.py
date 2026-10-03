#!/usr/bin/env python3
"""scripts/lib/dev-app-lock-test.py: two-way test for dev-app-lock.py (#3400).

Runs a PRIVATE COPY of the tool, never the live one: the copy's lock directory
points into a temp folder, so no real session's hold is touched. Each constant
rewrite must match exactly once or the test stops before running anything; a
missed rewrite would aim the test at the real lock.

A "session" here is a `/bin/bash` process (the copy's AGENT_NAMES is rewritten
to `bash`). It runs one or more tool commands, writes their exit codes and
output to files, then stays alive until the test kills it. Killing it is how
a holder session "exits".

    python3 scripts/lib/dev-app-lock-test.py
"""

import fcntl
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "dev-app-lock.py")

PASS = 0
FAIL = 0
SESSIONS = []


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}: {detail}")


def make_copy(tmp, name, rewrites):
    with open(TOOL) as f:
        src = f.read()
    for old, new in rewrites:
        if src.count(old) != 1:
            sys.exit(f"ABORT: rewrite target {old!r} found {src.count(old)} times "
                     "in dev-app-lock.py; refusing to run against an unknown copy")
        src = src.replace(old, new)
    path = os.path.join(tmp, name)
    with open(path, "w") as f:
        f.write(src)
    return path


def base_rewrites(lock_dir, agents='("bash",)', ps='"/bin/ps"'):
    return [
        ('LOCK_DIR = os.path.expanduser("~/Library/Caches/EnviousWispr/dev-app-lock")',
         f"LOCK_DIR = {lock_dir!r}"),
        ('AGENT_NAMES = ("claude", "codex")', f"AGENT_NAMES = {agents}"),
        ('PS = "/bin/ps"', f"PS = {ps}"),
    ]


class Session:
    """A bash process that runs tool commands, then idles until killed."""

    def __init__(self, tmp, tool, commands, start_gate=None, step_sleep=0):
        self.dir = tempfile.mkdtemp(dir=tmp)
        lines = []
        if start_gate:
            # Busy-wait on a file so many sessions fire at nearly the same moment.
            lines.append(f'while [ ! -e "{start_gate}" ]; do :; done')
        for i, cmd in enumerate(commands):
            if step_sleep and i:
                lines.append(f"sleep {step_sleep}")
            lines.append(f'"{sys.executable}" "{tool}" {cmd} > "{self.dir}/out{i}" 2>&1; '
                         f'echo $? > "{self.dir}/rc{i}"')
        # `exec`, not `sleep & wait`: a SIGKILLed bash orphans a background
        # child, which keeps this test's stdout open and stalls any pipe
        # reading it. `exec` keeps the pid and start time, so the holder
        # identity is unchanged.
        lines.append('exec sleep 600')
        self.proc = subprocess.Popen(["/bin/bash", "-c", "\n".join(lines)])
        self.n = len(commands)
        SESSIONS.append(self)

    def wait_done(self, timeout=30):
        deadline = time.time() + timeout
        last = os.path.join(self.dir, f"rc{self.n - 1}")
        while time.time() < deadline:
            if os.path.exists(last) and open(last).read().strip():
                return True
            time.sleep(0.05)
        return False

    def rc(self, i=0):
        return int(open(os.path.join(self.dir, f"rc{i}")).read().strip())

    def out(self, i=0):
        return open(os.path.join(self.dir, f"out{i}")).read()

    def kill(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGKILL)
            self.proc.wait()


def blocked_dir(tmp):
    """A path under a regular FILE, so the lock folder cannot be created."""
    path = os.path.join(tmp, "a-file")
    open(path, "a").close()
    return path


def run_tool(tool, *args):
    """Run the copy directly from this test (no bash session ancestor)."""
    p = subprocess.run([sys.executable, tool, *args], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def card(lock_dir):
    path = os.path.join(lock_dir, "holder.json")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)



def main():
    tmp = tempfile.mkdtemp(prefix="dev-app-lock-test.")
    try:
        lock = os.path.join(tmp, "lock")
        tool = make_copy(tmp, "tool.py", base_rewrites(lock))
        # The real read-then-write takes milliseconds, so claimers whose
        # startups differ by more than that never overlap, and a copy with the
        # flock removed still passed (measured). Holding the card open for
        # 0.3 s makes every claimer overlap: with the flock they queue, and
        # without it several read "free" and all write.
        slow = make_copy(tmp, "slow.py", base_rewrites(lock) + [
            ("        store.write(new)\n",
             "        time.sleep(0.3)\n        store.write(new)\n")])

        print("concurrency: 24 sessions claim at once")
        gate = os.path.join(tmp, "go")
        crowd = [Session(tmp, slow, ["claim --label crowd"], start_gate=gate)
                 for _ in range(24)]
        time.sleep(1.0)
        open(gate, "w").close()
        done = all(s.wait_done() for s in crowd)
        check("every claimer finished", done)
        rcs = [s.rc() for s in crowd]
        winners = [s for s in crowd if s.rc() == 0]
        check("exactly one winner", len(winners) == 1, f"exit codes {rcs}")
        check("every loser was told BUSY",
              all("BUSY" in s.out() for s in crowd if s.rc() == 3)
              and rcs.count(3) == 23, f"exit codes {rcs}")
        c = card(lock)
        winner = winners[0] if winners else None
        check("card names the winner session",
              c is not None and winner is not None and c["pid"] == winner.proc.pid,
              f"card {c}")

        print("live holder")
        late = Session(tmp, tool, ["claim --label late", "release"])
        late.wait_done()
        check("a second session is refused while the holder lives", late.rc(0) == 3,
              late.out(0))
        check("a non-holder cannot release", late.rc(1) == 3, late.out(1))
        check("the card is unchanged", card(lock) == c)
        rc, out = run_tool(tool, "status")
        check("status names the holder", rc == 0 and "held by bash session pid "
              f"{winner.proc.pid}" in out, out)

        print("no idle timer: a quiet live holder keeps the app")
        # Back-date the card by a day. With no timer, only exit or release
        # may end a hold, so a quiet live holder still wins.
        aged = dict(card(lock), claimed_at=c["claimed_at"] - 86400,
                    reminded_at=c["reminded_at"] - 86400)
        with open(os.path.join(lock, "holder.json"), "w") as f:
            json.dump(aged, f)
        quiet = Session(tmp, tool, ["claim --label quiet"])
        quiet.wait_done()
        check("a day-old hold by a live session is still BUSY", quiet.rc() == 3,
              quiet.out())

        print("holder session exited")
        for s in crowd:
            s.kill()
        again = Session(tmp, tool, ["claim --label first", "claim --label second",
                                    "release", "status"])
        again.wait_done()
        check("next claim takes over from the exited holder",
              again.rc(0) == 0 and "took over (holder session exited" in again.out(0),
              again.out(0))
        check("a second claim by the same session is 'already yours'",
              again.rc(1) == 0 and "already yours" in again.out(1), again.out(1))
        check("the holder can release", again.rc(2) == 0 and "released" in again.out(2),
              again.out(2))
        check("the lock is free after release", card(lock) is None)
        check("status says free", "free" in again.out(3), again.out(3))

        print("reminder for the holder only")
        lock7 = os.path.join(tmp, "lock7")
        rem_tool = make_copy(tmp, "rem.py", base_rewrites(lock7) + [
            ("REMIND_SECONDS = 30 * 60", "REMIND_SECONDS = 1")])
        holder = Session(tmp, rem_tool, ["claim --label rem", "remind --event PostToolUse"])
        holder.wait_done()
        check("no reminder before the interval",
              holder.rc(1) == 0 and holder.out(1) == "", holder.out(1))
        holder.kill()
        # One session: claim, wait past the interval, remind (expect one),
        # wait again, remind from a prompt hook (expect one, with that event).
        h = Session(tmp, rem_tool, ["claim --label rem2", "remind --event PostToolUse",
                                    "remind --event UserPromptSubmit"], step_sleep=1.2)
        h.wait_done()
        saved = card(lock7)
        check("the reminder time is saved, so the next one waits a full interval",
              saved["reminded_at"] > saved["claimed_at"] + 1, str(saved))
        out1 = h.out(1)
        try:
            msg = json.loads(out1)
            ctx = msg["hookSpecificOutput"]["additionalContext"]
            ev = msg["hookSpecificOutput"]["hookEventName"]
        except Exception:
            ctx, ev = "", ""
        check("after the interval the holder gets one reminder",
              h.rc(1) == 0 and "holds the shared dev app" in ctx and ev == "PostToolUse",
              out1)
        check("the reminder names the release command", "release" in ctx, ctx)
        check("the reminder carries the hook's own event name",
              '"hookEventName": "UserPromptSubmit"' in h.out(2), h.out(2))
        # Back-date the reminder so a non-holder WOULD be due if it counted.
        aged = dict(card(lock7), reminded_at=time.time() - 3600)
        with open(os.path.join(lock7, "holder.json"), "w") as f:
            json.dump(aged, f)
        rival = Session(tmp, rem_tool, ["remind --event PostToolUse"])
        rival.wait_done()
        check("a non-holder never gets a reminder",
              rival.rc() == 0 and rival.out() == "", rival.out())
        rc, out = run_tool(make_copy(tmp, "t2.py", base_rewrites(
            os.path.join(tmp, "nolock"))), "remind")
        check("remind with nobody holding exits 0 silently", rc == 0 and out == "", out)
        rc, out = run_tool(make_copy(tmp, "t3.py", base_rewrites(
            os.path.join(blocked_dir(tmp), "lock"))), "remind")
        check("remind never fails, even on a broken lock folder", rc == 0, out)
        with open(os.path.join(lock7, "holder.json"), "w") as f:
            f.write("{not json")
        rc, out = run_tool(rem_tool, "remind")
        check("remind never fails on a broken card", rc == 0 and out == "", out)

        # The reminder runs inside every tool call, so it must skip, not wait,
        # when another process holds the mutex. Hold the mutex from here while
        # a due reminder runs; a waiting reminder would never finish.
        lock9 = os.path.join(tmp, "lock9")
        nb_tool = make_copy(tmp, "nb.py", base_rewrites(lock9) + [
            ("REMIND_SECONDS = 30 * 60", "REMIND_SECONDS = 0")])
        nb = Session(tmp, nb_tool, ["claim --label nb", "remind"], step_sleep=1.0)
        rc0 = os.path.join(nb.dir, "rc0")
        deadline = time.time() + 30
        while not (os.path.exists(rc0) and open(rc0).read().strip()) \
                and time.time() < deadline:
            time.sleep(0.05)
        mfd = os.open(os.path.join(lock9, "mutex"), os.O_RDWR)
        fcntl.flock(mfd, fcntl.LOCK_EX)
        try:
            finished = nb.wait_done(timeout=5)
        finally:
            fcntl.flock(mfd, fcntl.LOCK_UN)
            os.close(mfd)
        check("a due reminder skips a busy mutex instead of waiting",
              finished and nb.rc(1) == 0 and nb.out(1) == "",
              nb.out(1) if finished else "still waiting after 5 s")

        # A process that exited but is not reaped yet: still listed, but gone.
        zombie_ps = os.path.join(tmp, "zombie-ps")
        with open(zombie_ps, "w") as f:
            f.write('#!/bin/sh\nfor a; do p=$a; done\n'
                    'echo "1 Thu Jan  1 00:00:00 1970 Z sh"\n')
        os.chmod(zombie_ps, 0o755)
        lock8 = os.path.join(tmp, "lock8")
        os.makedirs(lock8)
        zcard = dict(card(lock) or {}, version=3, kind="bash", pid=424242,
                     started="Thu Jan 1 00:00:00 1970", label="z", worktree="-",
                     claimed_at=time.time(), reminded_at=time.time(), nonce="z")
        with open(os.path.join(lock8, "holder.json"), "w") as f:
            json.dump(zcard, f)
        z_tool = make_copy(tmp, "z.py", base_rewrites(lock8, ps=repr(zombie_ps)))
        rc, out = run_tool(z_tool, "status")
        check("an exited but unreaped holder reads as exited",
              rc == 0 and "holder session exited" in out, out)

        print("founder run (no Claude or Codex ancestor)")
        lock3 = os.path.join(tmp, "lock3")
        held_tool = make_copy(tmp, "held.py", base_rewrites(lock3))
        hs = Session(tmp, held_tool, ["claim --label held"])
        hs.wait_done()
        before = card(lock3)
        founder_tool = make_copy(tmp, "founder.py",
                                 base_rewrites(lock3, agents='("no-such-agent",)'))
        rc, out = run_tool(founder_tool, "claim")
        check("a founder run is never blocked", rc == 0, out)
        check("a founder run names the holder", "heads-up" in out, out)
        check("a founder run writes nothing", card(lock3) == before)
        with open(os.path.join(lock3, "holder.json"), "w") as f:
            f.write("{not json")
        rc, out = run_tool(founder_tool, "claim")
        check("a founder run is not blocked by a broken card",
              rc == 0 and "founder run" in out, out)
        with open(os.path.join(lock3, "holder.json"), "w") as f:
            json.dump(before, f)

        print("same pid, different start time (pid reuse)")
        lock5 = os.path.join(tmp, "lock5")
        reuse_tool = make_copy(tmp, "reuse.py", base_rewrites(lock5))
        live = Session(tmp, reuse_tool, [])
        time.sleep(0.3)
        os.makedirs(lock5)
        fake = dict(before, pid=live.proc.pid, started="Thu Jan  1 00:00:00 1970")
        with open(os.path.join(lock5, "holder.json"), "w") as f:
            json.dump(fake, f)
        s2 = Session(tmp, reuse_tool, ["claim --label reuse"])
        s2.wait_done()
        check("a live pid with a different start time is not the holder",
              s2.rc() == 0 and "took over (holder session exited" in s2.out(),
              s2.out())

        print("fail closed")
        broken_ps = os.path.join(tmp, "broken-ps")
        with open(broken_ps, "w") as f:
            f.write("#!/bin/sh\necho boom >&2\nexit 2\n")
        os.chmod(broken_ps, 0o755)
        ps_tool = make_copy(tmp, "ps.py", base_rewrites(lock3, ps=repr(broken_ps)))
        rc, out = run_tool(ps_tool, "claim")
        check("a failing ps is 'cannot decide', not 'free'",
              rc == 2 and "cannot decide" in out, out)
        rc, out = run_tool(ps_tool, "status")
        check("status with a failing ps also refuses to guess", rc == 2, out)
        check("a failing ps leaves the card alone", card(lock3) == before)
        quiet_ps = os.path.join(tmp, "exit1-ps")
        with open(quiet_ps, "w") as f:
            f.write("#!/bin/sh\necho boom >&2\nexit 1\n")
        os.chmod(quiet_ps, 0o755)
        q_tool = make_copy(tmp, "q.py", base_rewrites(lock3, ps=repr(quiet_ps)))
        rc, out = run_tool(q_tool, "status")
        check("ps exiting 1 with an error is not 'gone'",
              rc == 2 and "cannot decide" in out, out)

        lock4 = os.path.join(tmp, "lock4")
        os.makedirs(lock4)
        with open(os.path.join(lock4, "holder.json"), "w") as f:
            # Otherwise valid, so only the version check can refuse it.
            json.dump(dict(before, version=2), f)
        v_tool = make_copy(tmp, "v.py", base_rewrites(lock4))
        s = Session(tmp, v_tool, ["claim"])
        s.wait_done()
        check("an older card version is refused, not overwritten",
              s.rc() == 2 and "version 2" in s.out() and
              json.load(open(os.path.join(lock4, "holder.json")))["version"] == 2,
              s.out())
        with open(os.path.join(lock4, "holder.json"), "w") as f:
            f.write("{not json")
        s = Session(tmp, v_tool, ["claim"])
        s.wait_done()
        check("an unreadable card is refused", s.rc() == 2, s.out())
        with open(os.path.join(lock4, "holder.json"), "w") as f:
            json.dump(dict(before, started=None), f)
        s = Session(tmp, v_tool, ["claim"])
        s.wait_done()
        check("a card with a wrong-typed field is refused, not a traceback",
              s.rc() == 2 and "cannot decide" in s.out()
              and "Traceback" not in s.out(), s.out())
        b_tool = make_copy(tmp, "b.py", base_rewrites(
            os.path.join(blocked_dir(tmp), "lock")))
        rc, out = run_tool(b_tool, "status")
        check("a lock folder that cannot be made is refused, not a traceback",
              rc == 2 and "cannot decide" in out and "Traceback" not in out, out)

        # A ps whose parent chain never reaches pid 1 (each pid reports pid+1
        # as its parent): the 64-step walk ends unfinished, which must be
        # "cannot decide", never "no session found" (a founder run).
        endless_ps = os.path.join(tmp, "endless-ps")
        with open(endless_ps, "w") as f:
            f.write('#!/bin/sh\nfor a; do p=$a; done\n'
                    'echo "$((p+1)) Thu Jan  1 00:00:00 1970 S sh"\n')
        os.chmod(endless_ps, 0o755)
        e_tool = make_copy(tmp, "e.py", base_rewrites(
            os.path.join(tmp, "lock6"), agents='("no-such-agent",)',
            ps=repr(endless_ps)))
        rc, out = run_tool(e_tool, "claim")
        check("an unfinished ancestor walk is not a founder run",
              rc == 2 and "did not reach pid 1" in out, out)

        print("session process names seen in practice")
        # Each fake ps reports every pid as a child of pid 1 with one comm, so
        # the tool's own parent is the only candidate. Real AGENT_NAMES.
        for label, comm, want in [
            ("interactive", "claude", "claude"),
            ("daemon-hosted session", "claude bg-spare", "claude"),
            ("daemon pty host is not a session", "claude bg-pty-host", "undecided"),
            ("native installer path",
             os.path.expanduser("~/.local/share/claude/versions/2.1.288"), "claude"),
            ("versions path outside the install folder",
             "/tmp/claude/versions/2.1.288", None),
            ("codex CLI binary",
             "/usr/local/lib/node_modules/@openai/codex/vendor/codex/codex", "codex"),
            ("desktop app is not a CLI session",
             "/Applications/Claude.app/Contents/MacOS/Claude", None),
            ("a shell is not a session", "/bin/zsh", None),
        ]:
            name_ps = os.path.join(tmp, f"name-ps-{abs(hash(comm))}")
            with open(name_ps, "w") as f:
                f.write(f'#!/bin/sh\necho "1 Thu Jan  1 00:00:00 1970 S {comm}"\n')
            os.chmod(name_ps, 0o755)
            n_lock = os.path.join(tmp, f"lock-n-{abs(hash(comm))}")
            n_tool = make_copy(tmp, f"n-{abs(hash(comm))}.py", [
                ('LOCK_DIR = os.path.expanduser("~/Library/Caches/EnviousWispr/dev-app-lock")',
                 f"LOCK_DIR = {n_lock!r}"),
                ('PS = "/bin/ps"', f"PS = {name_ps!r}")])
            rc, out = run_tool(n_tool, "claim", "--label", "n")
            if want == "undecided":
                ok = rc == 2 and "without a session process" in out
            elif want:
                ok = rc == 0 and f"claimed by {want} session" in out
            else:
                ok = rc == 0 and "founder run" in out
            check(f"{label} ({comm!r}) -> {want or 'founder run'}", ok, out)

        # Two candidates in one chain: the nearest (the session) must win, not
        # the shared host further up.
        chain_ps = os.path.join(tmp, "chain-ps")
        with open(chain_ps, "w") as f:
            f.write('#!/bin/sh\nfor a; do p=$a; done\n'
                    'if [ "$p" = 777 ]; then echo "1 Thu Jan  1 00:00:00 1970 S claude bg-pty-host"\n'
                    'else echo "777 Thu Jan  1 00:00:00 1970 S claude bg-spare"; fi\n')
        os.chmod(chain_ps, 0o755)
        c_lock = os.path.join(tmp, "lock-chain")
        c_tool = make_copy(tmp, "chain.py", [
            ('LOCK_DIR = os.path.expanduser("~/Library/Caches/EnviousWispr/dev-app-lock")',
             f"LOCK_DIR = {c_lock!r}"),
            ('PS = "/bin/ps"', f"PS = {chain_ps!r}")])
        rc, out = run_tool(c_tool, "claim", "--label", "chain")
        check("the nearest session wins over the host above it",
              rc == 0 and card(c_lock)["pid"] == os.getpid(), out)

        print("live tool targets the real lock")
        live_src = open(TOOL).read()
        check("live LOCK_DIR is the shared cache path",
              'LOCK_DIR = os.path.expanduser("~/Library/Caches/EnviousWispr/dev-app-lock")'
              in live_src)
        check("live AGENT_NAMES are claude and codex",
              'AGENT_NAMES = ("claude", "codex")' in live_src)
    finally:
        for s in SESSIONS:
            s.kill()
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
