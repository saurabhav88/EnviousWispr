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


def base_rewrites(lock_dir, agents='("bash",)', idle="15 * 60", ps='"/bin/ps"'):
    return [
        ('LOCK_DIR = os.path.expanduser("~/Library/Caches/EnviousWispr/dev-app-lock")',
         f"LOCK_DIR = {lock_dir!r}"),
        ('AGENT_NAMES = ("claude", "codex")', f"AGENT_NAMES = {agents}"),
        ("IDLE_SECONDS = 15 * 60", f"IDLE_SECONDS = {idle}"),
        ('PS = "/bin/ps"', f"PS = {ps}"),
    ]


class Session:
    """A bash process that runs tool commands, then idles until killed."""

    def __init__(self, tmp, tool, commands, start_gate=None):
        self.dir = tempfile.mkdtemp(dir=tmp)
        lines = []
        if start_gate:
            # Busy-wait on a file so many sessions fire at nearly the same moment.
            lines.append(f'while [ ! -e "{start_gate}" ]; do :; done')
        for i, cmd in enumerate(commands):
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

        print("stale: holder session exited")
        for s in crowd:
            s.kill()
        again = Session(tmp, tool, ["claim --label first", "claim --label second",
                                    "release", "status"])
        again.wait_done()
        check("next claim takes over from the exited holder",
              again.rc(0) == 0 and "took over (its session has exited" in again.out(0),
              again.out(0))
        check("a second claim by the same session renews",
              again.rc(1) == 0 and "renewed" in again.out(1), again.out(1))
        check("the holder can release", again.rc(2) == 0 and "released" in again.out(2),
              again.out(2))
        check("the lock is free after release", card(lock) is None)
        check("status says free", "free" in again.out(3), again.out(3))

        print("stale: holder idle")
        lock2 = os.path.join(tmp, "lock2")
        idle_tool = make_copy(tmp, "idle.py", base_rewrites(lock2, idle="1"))
        holder = Session(tmp, idle_tool, ["claim --label idle"])
        holder.wait_done()
        check("idle holder claimed", holder.rc() == 0, holder.out())
        early = Session(tmp, idle_tool, ["claim --label early"])
        early.wait_done()
        check("a claim inside the idle window is refused", early.rc() == 3, early.out())
        time.sleep(1.5)
        later = Session(tmp, idle_tool, ["claim --label later"])
        later.wait_done()
        check("a claim after the idle window takes over",
              later.rc() == 0 and "no claim for over" in later.out(), later.out())

        print("founder run (no Claude or Codex ancestor)")
        lock3 = os.path.join(tmp, "lock3")
        held_tool = make_copy(tmp, "held.py", base_rewrites(lock3))
        h = Session(tmp, held_tool, ["claim --label held"])
        h.wait_done()
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
        fake = dict(before, pid=live.proc.pid, started="Thu Jan  1 00:00:00 1970",
                    last_action_at=time.time(), claimed_at=time.time())
        with open(os.path.join(lock5, "holder.json"), "w") as f:
            json.dump(fake, f)
        s2 = Session(tmp, reuse_tool, ["claim --label reuse"])
        s2.wait_done()
        check("a live pid with a different start time is not the holder",
              s2.rc() == 0 and "took over (its session has exited" in s2.out(),
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
            json.dump({"version": 99, "pid": 1}, f)
        v_tool = make_copy(tmp, "v.py", base_rewrites(lock4))
        s = Session(tmp, v_tool, ["claim"])
        s.wait_done()
        check("an unknown card version is refused, not overwritten",
              s.rc() == 2 and json.load(open(os.path.join(lock4, "holder.json")))
              ["version"] == 99, s.out())
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
        blocked = os.path.join(tmp, "not-a-dir")
        open(blocked, "w").close()
        b_tool = make_copy(tmp, "b.py", base_rewrites(os.path.join(blocked, "lock")))
        rc, out = run_tool(b_tool, "status")
        check("a lock folder that cannot be made is refused, not a traceback",
              rc == 2 and "cannot decide" in out and "Traceback" not in out, out)

        print("live tool targets the real lock")
        live = open(TOOL).read()
        check("live LOCK_DIR is the shared cache path",
              'LOCK_DIR = os.path.expanduser("~/Library/Caches/EnviousWispr/dev-app-lock")'
              in live)
        check("live AGENT_NAMES are claude and codex",
              'AGENT_NAMES = ("claude", "codex")' in live)
    finally:
        for s in SESSIONS:
            s.kill()
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
