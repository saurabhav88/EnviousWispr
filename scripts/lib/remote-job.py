#!/usr/bin/env python3
"""Remote job supervisor: runs ON a backup Mac, one job per persistent checkout (#4507 §3.4).

  remote-job.py run --run-dir DIR --checkout DIR
  remote-job.py status --checkout DIR

`run` is launched from the run's own staged copy (never the persistent
checkout's copy, which may be older). DIR/run.json, written by the dispatcher,
names the run id, commit, tree, mode, fingerprint, Xcode build, work root/mount,
the forwarded environment and the runner arguments.

Order, all while holding <checkout>.job.lock (a flock; a predecessor is waited
for at most 60 s, then refused by name):
  1. claim the run once (run.json.claimed, exclusive create);
  2. re-check the work drive and root, the Xcode build and the signing keychain;
  3. check out the commit, clean everything but .derivedData and build/, and
     verify `git write-tree` and the compiled-bytes fingerprint;
  4. full runs: the receipt owner's capture eligibility must pass;
  5. run `scripts/xcode-test.sh --host local ...` in its own process group,
     stdin /dev/null, raw output streamed to this process's stdout;
  6. stop and reap the whole job group, clear a validation lock no process can
     own any more, package result/ (status, environment, lane logs, receipt);
  7. print `EW-REMOTE-EXIT=<code>`.
Controller liveness: this process's stdin is the dispatcher's control channel.
A heartbeat line arrives every 15 s; EOF, SIGHUP or 90 s without one means the
controller is gone, and the job group is stopped (TERM, 15 s, KILL) before the
lock is released. Output never counts as a heartbeat.
Setup failures exit 4 and are never test results.
"""

import fcntl
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import remote_ship  # noqa: E402  (the staged copy beside this file)

SETUP_EXIT = 4
HEARTBEAT_LIMIT = 90
GRACE_SECONDS = 15
LOCK_WAIT = 60
ALLOWED_ENV = ("EW_NO_OUTPUT_LIMIT_SECS", "TEST_RUNNER_EW_REAL_BOUNDARY",
               "TEST_RUNNER_EW_WRITE_TEST_INVENTORY_BASELINE")


class SetupError(RuntimeError):
    pass


def lstart(pid):
    out = subprocess.run(["/bin/ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                         env={"LC_ALL": "C", "TZ": "UTC", "PATH": "/usr/bin:/bin"}).stdout.strip()
    return out or None


def lock_paths(checkout):
    checkout = Path(checkout)
    return checkout.with_name(checkout.name + ".job.lock"), checkout.with_name(checkout.name + ".job.json")


def take_job_lock(checkout):
    lock, card = lock_paths(checkout)
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    deadline = time.monotonic() + LOCK_WAIT
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.monotonic() >= deadline:
                try:
                    holder = json.loads(card.read_text()).get("run_id")
                except (OSError, ValueError):
                    holder = "unknown"
                os.close(fd)
                raise SetupError(f"the previous job ({holder}) is still stopping on this Mac")
            time.sleep(1)


def write_card(checkout, run_id, phase):
    _, card = lock_paths(checkout)
    tmp = card.with_name(card.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps({"run_id": run_id, "pid": os.getpid(), "lstart": lstart(os.getpid()),
                               "phase": phase, "at": time.time()}))
    os.replace(tmp, card)


def check_drive(record):
    root, mount = record["root"], record.get("requires_mount")
    if mount is None:
        return
    mounted = subprocess.run(["/sbin/mount"], capture_output=True, text=True).stdout
    if f" on {mount} (" not in mounted:
        raise SetupError(f"work drive {mount} is not mounted")
    if os.stat(mount).st_dev == os.stat("/").st_dev:
        raise SetupError(f"work drive {mount} is the system disk")
    if not (root + "/").startswith(mount.rstrip("/") + "/") or os.stat(root).st_dev != os.stat(mount).st_dev:
        raise SetupError(f"work root {root} is not on {mount}")


def check_toolchain(record):
    out = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout
    build = next((l.split(" ", 2)[2] for l in out.splitlines() if l.startswith("Build version ")), None)
    if build != record["xcode_build"]:
        raise SetupError(f"Xcode build {build} differs from the dispatching Mac's {record['xcode_build']}")


def unlock_keychain():
    keychain = Path.home() / "Library/Keychains/ew-dev.keychain-db"
    password_file = Path.home() / ".config/ew-dev-keychain-pass"
    if not keychain.exists():
        return  # no dedicated signing keychain on this Mac; xcode-test.sh decides Dev vs Debug
    result = subprocess.run(["security", "unlock-keychain", "-p", password_file.read_text().strip(), str(keychain)],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise SetupError("could not unlock the signing keychain")


def prepare_checkout(checkout, record):
    commit, tree = record["commit"], record["tree"]
    remote_ship.git(checkout, "checkout", "--force", "--detach", commit)
    remote_ship.git(checkout, "clean", "-ffdx", "-e", ".derivedData", "-e", "build")
    if remote_ship.git(checkout, "write-tree") != tree:
        raise SetupError("the checked-out tree differs from the shipped tree")
    if remote_ship.fingerprint(checkout, tree) != record["fingerprint"]:
        raise SetupError("the compiled bytes on this Mac differ from the dispatching Mac's")
    if record["mode"] == "full":
        result = subprocess.run([sys.executable, str(Path(checkout) / "scripts/lib/validation-receipt.py"),
                                 "capture", "--root", str(checkout)], capture_output=True, text=True)
        if result.returncode != 0:
            raise SetupError("the receipt capture refused this tree: " + (result.stderr or result.stdout).strip())


def job_env(record):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("EW_", "TEST_RUNNER_"))}
    forwarded = {k: v for k, v in record["env"].items() if k in ALLOWED_ENV}
    if forwarded != record["env"]:
        raise SetupError("the run record names a variable outside the forwarding allowlist")
    env.update(forwarded)
    env.update(EW_REMOTE_CHILD="1", EW_FORWARD_WORKER_OUTPUT="1",
               EW_LOCAL_TEST_WORKERS=str(record["ci_workers"]))
    return env


def stop_group(pid):
    for sig, wait in ((signal.SIGTERM, GRACE_SECONDS), (signal.SIGKILL, 0)):
        try:
            os.killpg(pid, sig)
        except ProcessLookupError:
            return
        except PermissionError:
            pass
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            try:
                os.killpg(pid, 0)
            except (ProcessLookupError, PermissionError):
                return
            time.sleep(0.1)


def supervise(proc, lane_log):
    """Stream the job's raw output; watch the control channel. Returns the
    job's exit code, or None when the controller is gone."""
    out = sys.stdout.buffer
    job_fd, control = proc.stdout.fileno(), sys.stdin.fileno()
    last_heartbeat = time.monotonic()
    lost = []
    signal.signal(signal.SIGHUP, lambda *_: lost.append("SIGHUP"))
    watch = [job_fd, control]
    while True:
        if lost or time.monotonic() - last_heartbeat > HEARTBEAT_LIMIT:
            return None
        ready, _, _ = select.select(watch, [], [], 1.0)
        if control in ready:
            data = os.read(control, 4096)
            if not data:
                return None  # EOF: the controller closed the channel or the SSH session died
            last_heartbeat = time.monotonic()
        if job_fd in ready:
            data = os.read(job_fd, 65536)
            if not data:
                watch.remove(job_fd)
            else:
                out.write(data)
                out.flush()
                lane_log.write(data)
        if job_fd not in watch:
            status = os.waitid(os.P_PID, proc.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            if status is not None:
                return status.si_status if status.si_code == os.CLD_EXITED else 128 + status.si_status


def package(checkout, run_dir, run_started):
    result = Path(run_dir) / "result"
    receipt = Path(checkout) / ".derivedData/Test/ew-validation-receipt.json"
    if receipt.exists() and receipt.stat().st_mtime >= run_started:
        shutil.copy2(receipt, result / "ew-validation-receipt.json")
    latest = Path(checkout) / "build/latest-lane"
    if latest.exists():
        shutil.copytree(latest.resolve(), result / "lane", ignore=shutil.ignore_patterns("*.xcresult"),
                        dirs_exist_ok=True)


def run(run_dir, checkout):
    run_dir, checkout = Path(run_dir), Path(checkout)
    record = json.loads((run_dir / "run.json").read_text())
    os.close(os.open(run_dir / "run.json.claimed", os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
    result = run_dir / "result"
    result.mkdir()
    lock_fd = take_job_lock(checkout)
    code, proc = SETUP_EXIT, None
    started = time.time()
    try:
        write_card(checkout, record["run_id"], "checks")
        check_drive(record)
        check_toolchain(record)
        unlock_keychain()
        write_card(checkout, record["run_id"], "checkout")
        prepare_checkout(checkout, record)
        env = job_env(record)
        (result / "env.json").write_text(json.dumps({k: env[k] for k in sorted(env) if k.startswith(("EW_", "TEST_RUNNER_"))}))
        write_card(checkout, record["run_id"], "running")
        with (result / "lane.log").open("wb") as lane_log:
            proc = subprocess.Popen(["bash", str(checkout / "scripts/xcode-test.sh"), "--host", "local",
                                     *record["args"]], cwd=checkout, env=env, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
            outcome = supervise(proc, lane_log)
        if outcome is None:
            code = SETUP_EXIT
            print("==> remote job: the controller is gone; stopping the job", flush=True)
        else:
            code = outcome
    except (SetupError, remote_ship.ShipError, OSError, ValueError, KeyError) as error:
        print(f"==> remote job SETUP FAILED: {error}", flush=True)
        code = SETUP_EXIT
    finally:
        if proc is not None:
            stop_group(proc.pid)
            proc.wait()
            proc.stdout.close()
        # No process of this checkout can be alive now (the job lock serializes them
        # and the group is reaped), so a leftover validation lock is stale.
        shutil.rmtree(checkout / ".derivedData/Test/.ew-validation.lock", ignore_errors=True)
        try:
            write_card(checkout, record["run_id"], "packaging")
            package(checkout, run_dir, started)
            (result / "status.json").write_text(json.dumps({"exit": code, "run_id": record["run_id"]}))
            write_card(checkout, record["run_id"], "done")
        except OSError as error:
            print(f"==> remote job: packaging failed: {error}", flush=True)
        os.close(lock_fd)
    print(f"EW-REMOTE-EXIT={code}", flush=True)
    return code


def status(checkout):
    lock, card = lock_paths(checkout)
    state = "free"
    if lock.exists():
        fd = os.open(lock, os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
            fcntl.flock(fd, fcntl.LOCK_UN)
        except BlockingIOError:
            state = "held"
        finally:
            os.close(fd)
    try:
        info = json.loads(card.read_text())
    except (OSError, ValueError):
        info = {}
    print(json.dumps({"state": state, "run_id": info.get("run_id"), "phase": info.get("phase"),
                      "since": info.get("at")}))
    return 0


def main(argv):
    if len(argv) == 5 and argv[0] == "run" and argv[1] == "--run-dir" and argv[3] == "--checkout":
        return run(argv[2], argv[4])
    if len(argv) == 3 and argv[0] == "status" and argv[1] == "--checkout":
        return status(argv[2])
    print("usage: remote-job.py run --run-dir DIR --checkout DIR | status --checkout DIR", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
