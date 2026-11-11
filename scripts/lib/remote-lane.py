#!/usr/bin/env python3
"""Run this checkout's test lane on a backup Mac (#4507 §3.3-§3.4, §3.7).

  remote-lane.py env-check
      exit 0 when nothing in this environment stops remote routing; else exit 3
      naming the variable (the run then stays on this Mac).
  remote-lane.py run --host NAME --start JSON|"" -- RUNNER-ARGS...
      called by scripts/xcode-test.sh while it holds NAME's CI slot descriptor.

`run`: snapshot (a full eligible run ships the captured index tree from --start;
anything else ships a development snapshot, which never becomes push proof),
refuse unsupported trees, fingerprint the compiled bytes, check the work drive
BEFORE any remote write, create the run directory exclusively, ship a bundle of a
commit under a unique temporary ref (verified remotely; one retry with a
self-contained bundle), stage the shipped supervisor in the run directory, and
run it with this process's heartbeat on its stdin. Raw output streams through;
1500 s of silence on the stream closes the session (exit 5, hung); a lost session
or any setup failure exits 4 (never a test result). Results come back to
build/lanes/remote-<run id>/ in this checkout. Only this run's bundle and ref are
removed afterwards. A passing full run's receipt is adopted through
scripts/lib/validation-receipt.py adopt (same tree, same Xcode build).
"""

import importlib.util
import json
import os
from pathlib import Path
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
import remote_ship  # noqa: E402


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


hosts_mod = _load("mac_hosts", HERE / "mac_hosts.py")
watch = _load("output_watchdog", HERE / "output-watchdog.py")

SETUP_EXIT = 4
HUNG_EXIT = 5
STREAM_LIMIT = 1500
HEARTBEAT_EVERY = 15
# Forwarded to the remote runner (the supervisor checks the same list).
FORWARD = ("EW_NO_OUTPUT_LIMIT_SECS", "TEST_RUNNER_EW_REAL_BOUNDARY",
           "TEST_RUNNER_EW_WRITE_TEST_INVENTORY_BASELINE")
# Set by the runner for this run; meaningful only on this Mac.
INTERNAL = ("EW_HUNG_MARKER", "EW_RUNNER_PID", "EW_CARD_HOST")


def env_blockers():
    names = sorted(k for k in os.environ if k.startswith(("EW_", "TEST_RUNNER_"))
                   and k not in FORWARD and k not in INTERNAL)
    return names


class Remote:
    def __init__(self, host):
        self.host = host
        self.root = host["root"]
        self.checkout = f"{self.root}/EnviousWispr-ci"

    def ssh(self, script, input_bytes=None, timeout=600):
        return subprocess.run(hosts_mod.ssh_command(self.host, script), input=input_bytes,
                              capture_output=True, timeout=timeout)

    def scp_to(self, local, remote):
        return subprocess.run(["scp", "-q", *hosts_mod.SSH_OPTIONS, str(local),
                               f"{self.host['ssh']}:{remote}"], capture_output=True, timeout=600)

    def scp_from(self, remote, local):
        return subprocess.run(["scp", "-q", "-r", *hosts_mod.SSH_OPTIONS,
                               f"{self.host['ssh']}:{remote}", str(local)], capture_output=True, timeout=600)


def fail(message):
    print(f"==> remote run SETUP FAILED: {message}", flush=True)
    return SETUP_EXIT


def adopt_receipt(start, remote_receipt, host_name):
    """A passing full run: the receipt owner publishes the backup Mac's receipt here."""
    if not remote_receipt.exists():
        print("==> validation receipt: NOT issued (the backup Mac issued none); "
              "a push of build inputs will be refused", flush=True)
        return 0
    result = subprocess.run([sys.executable, str(ROOT / "scripts/lib/validation-receipt.py"), "adopt",
                             "--root", str(ROOT), "--start", start, "--from", str(remote_receipt),
                             "--tested-on", host_name], capture_output=True, text=True)
    if result.returncode == 0:
        print(f"==> validation receipt: issued from {host_name} ({result.stdout.strip()})", flush=True)
        return 0
    reason = (result.stderr or result.stdout).strip()
    if result.returncode == 3:
        print(f"==> validation receipt: NOT issued ({reason}); a push of build inputs will be refused",
              flush=True)
        return 0
    print(f"ERROR: the backup Mac's receipt was not accepted: {reason}", flush=True)
    return 1


def run(host_name, start, args):
    hosts, _sha = hosts_mod.load()
    host = hosts_mod.resolve(hosts, host_name)
    if host["ssh"] is None:
        return fail("the local host is not a remote target")
    blockers = env_blockers()
    if blockers:
        return fail("these settings only apply on this Mac: " + ", ".join(blockers))
    full = bool(start)
    try:  # setup, so a failure here is exit 4, never a traceback or a test result
        tree = json.loads(start)["tree"] if full else remote_ship.dev_snapshot_tree(ROOT)
        remote_ship.refuse_unsupported(ROOT, tree)
        fingerprint = remote_ship.fingerprint(ROOT, tree)
    except (remote_ship.ShipError, OSError, ValueError, KeyError) as error:
        return fail(f"could not snapshot this checkout: {error}")
    run_id = uuid.uuid4().hex
    remote = Remote(host)
    run_dir = f"{remote.root}/runs/{run_id}"
    q = shlex.quote
    print(f"==> remote run {run_id} on {host['name']}: {'full' if full else 'development snapshot'} tree {tree}",
          flush=True)

    tmp = Path(tempfile.mkdtemp(prefix="ew-remote-"))
    ref = None
    try:
        commit, ref, _ = remote_ship.make_bundle(ROOT, tree, run_id, tmp / "transfer.bundle")
        record = {"run_id": run_id, "commit": commit, "tree": tree, "mode": "full" if full else "filtered",
                  "fingerprint": fingerprint, "xcode_build": hosts_mod.local_xcode_build(),
                  "root": host["root"], "requires_mount": host.get("requires_mount"),
                  "ci_workers": host["ci_workers"], "args": list(args),
                  "env": {k: os.environ[k] for k in FORWARD if k in os.environ}}
        # 1. Before ANY remote write: the work drive, then the exclusive run directory.
        pre = remote.ssh(f"( {hosts_mod.mount_check_script(host)} ) || exit $?; "
                         f"mkdir -p {q(remote.root + '/runs')} && mkdir {q(run_dir)} && cat > {q(run_dir + '/run.json')}",
                         input_bytes=json.dumps(record).encode())
        if pre.returncode != 0:
            return fail({41: "work drive not mounted", 42: "work drive is the system disk",
                         43: "work root is not on the work drive"}.get(pre.returncode,
                         pre.stderr.decode(errors="replace").strip() or f"preflight exit {pre.returncode}"))
        # 2. Ship, verify, fetch, stage the run's own supervisor.
        bootstrap = (f"set -e; C={q(remote.checkout)}; R={q(run_dir)}; "
                     f"[ -d \"$C/.git\" ] || git clone -q {q(host['repo_url'])} \"$C\"; cd \"$C\"; "
                     "git bundle verify -q \"$R/transfer.bundle\" >/dev/null 2>&1 || exit 47; "
                     f"git fetch -q \"$R/transfer.bundle\" {q(ref + ':' + ref)}; "
                     f"[ \"$(git rev-parse {q(commit + '^{tree}')})\" = {q(tree)} ] || exit 48; "
                     "mkdir \"$R/supervisor\"; "
                     f"git archive {q(commit)} scripts/lib/remote-job.py scripts/lib/remote_ship.py "
                     "| tar -x -C \"$R/supervisor\"")
        for attempt in (1, 2):
            sent = remote.scp_to(tmp / "transfer.bundle", f"{run_dir}/transfer.bundle")
            if sent.returncode != 0:
                return fail("could not copy the bundle: " + sent.stderr.decode(errors="replace").strip())
            boot = remote.ssh(bootstrap)
            if boot.returncode == 47 and attempt == 1:
                remote_ship.full_bundle(ROOT, ref, tmp / "transfer.bundle")  # prerequisites missing there
                continue
            break
        if boot.returncode != 0:
            return fail({47: "the bundle could not be verified", 48: "the fetched tree differs"}.get(
                boot.returncode, boot.stderr.decode(errors="replace").strip() or f"bootstrap exit {boot.returncode}"))
        code = supervise(remote, run_dir, host)
        local_results = ROOT / "build/lanes" / f"remote-{run_id}"
        local_results.parent.mkdir(parents=True, exist_ok=True)
        fetched = remote.scp_from(f"{run_dir}/result", local_results)
        if fetched.returncode != 0:
            # The remote test outcome is reported as is; the missing results make
            # this run a setup failure, never a test pass or a test failure.
            print(f"==> remote test exit was {code}, but its results could not be fetched", flush=True)
            return fail(f"results not fetched from {run_dir}/result")
        print(f"==> remote results: {local_results}", flush=True)
        if full and code == 0:
            return adopt_receipt(start, local_results / "ew-validation-receipt.json", host["name"])
        return code
    except remote_ship.ShipError as error:
        return fail(str(error))
    except subprocess.TimeoutExpired as error:
        return fail(f"a remote step timed out: {error}")
    finally:
        if ref:
            remote_ship.drop_ref(ROOT, ref)
            try:
                Remote(host).ssh(f"rm -f {q(run_dir + '/transfer.bundle')}; "
                                 f"git -C {q(remote.checkout)} update-ref -d {q(ref)} 2>/dev/null; true", timeout=60)
            except subprocess.TimeoutExpired:
                pass
        for item in tmp.iterdir():
            item.unlink()
        tmp.rmdir()


def supervise(remote, run_dir, host):
    """Run the staged supervisor; heartbeat on its stdin; stream its output."""
    command = (f"exec python3 {shlex.quote(run_dir + '/supervisor/scripts/lib/remote-job.py')} run "
               f"--run-dir {shlex.quote(run_dir)} --checkout {shlex.quote(remote.checkout)}")
    proc = subprocess.Popen(hosts_mod.ssh_command(host, command), stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    stop = threading.Event()
    received = []

    def heartbeat():
        while not stop.wait(HEARTBEAT_EVERY):
            try:
                proc.stdin.write(b"hb\n")
                proc.stdin.flush()
            except (BrokenPipeError, ValueError, OSError):
                return

    def on_signal(signum, _frame):
        received.append(signum)

    previous = {s: signal.signal(s, on_signal) for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    threading.Thread(target=heartbeat, daemon=True).start()
    os.environ["EW_CARD_HOST"] = host["name"]  # this run holds the backup Mac's slot card
    card = watch.CardToucher()
    clock = watch.SilenceClock("remote stream")
    out, fd = sys.stdout.buffer, proc.stdout.fileno()
    remote_exit, tail, hung = None, b"", False
    try:
        while True:
            if received:
                break
            remaining = STREAM_LIMIT - clock.silent_for()
            if remaining <= 0:
                hung = True
                break
            ready, _, _ = select.select([fd], [], [], min(remaining, 1.0))
            if not ready:
                if proc.poll() is not None:
                    break
                continue
            data = os.read(fd, 65536)
            if not data:
                break
            out.write(data)
            out.flush()
            clock.saw(data)
            card.touch()
            tail = (tail + data)[-4096:]
            for line in tail.splitlines():
                if line.startswith(b"EW-REMOTE-EXIT="):
                    remote_exit = int(line.split(b"=", 1)[1] or SETUP_EXIT)
    finally:
        stop.set()
        try:
            proc.stdin.close()  # EOF on the control channel: the supervisor stops its job
        except OSError:
            pass
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        for sig, old in previous.items():
            signal.signal(sig, old)
    if hung:
        text = clock.diagnostic(STREAM_LIMIT)
        watch.record_hung(text)
        print(f"==> HUNG: {text}", flush=True)
        return HUNG_EXIT
    if received:
        return 128 + received[0]
    if remote_exit is None:
        print("==> remote run: the session ended without a result (lost connection)", flush=True)
        return SETUP_EXIT
    if remote_exit == HUNG_EXIT:
        for line in tail.decode(errors="replace").splitlines():
            if line.startswith("==> HUNG: "):
                watch.record_hung(line[len("==> HUNG: "):])
    return remote_exit


def main(argv):
    if argv == ["env-check"]:
        blockers = env_blockers()
        if blockers:
            print("==> remote routing off for this run: " + ", ".join(blockers) + " only apply on this Mac",
                  flush=True)
            return 3
        return 0
    if len(argv) >= 5 and argv[0] == "run" and argv[1] == "--host" and argv[3] == "--start" and "--" in argv:
        split = argv.index("--")
        try:
            return run(argv[2], argv[4] if split > 4 else "", argv[split + 1:])
        except hosts_mod.ConfigError as error:
            return fail(f"host list: {error}")
    print("usage: remote-lane.py env-check | run --host NAME --start JSON -- ARGS...", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
