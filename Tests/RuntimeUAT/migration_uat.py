#!/usr/bin/env python3
"""Live UAT driver for the Parakeet migration (#2697).

Runs against the REAL directories on this Mac. No fixtures, no redirected root.
The founder's bar: "synthetic tests don't pass the benchmark here - you need REAL
product testing, run the migration live on the laptop."

Every check fails CLOSED. A missing artifact is INVALID evidence, never a pass.
Every wait below polls a real signal — a process leaving the table, a log line
arriving, a file appearing — with a deadline as the fallback, never a bare sleep
standing in for the condition.
"""
import json, os, pathlib, shutil, signal, subprocess, sys, time

HOME = pathlib.Path.home()
APPSUP = HOME / "Library/Application Support"
DONOR = APPSUP / "FluidAudio/Models/parakeet-tdt-0.6b-v3"
OWNED = APPSUP / "EnviousWispr/Models/parakeet-tdt-0.6b-v3"
META = APPSUP / "EnviousWispr/ModelDelivery"
BACKUP = HOME / "EnviousWispr-donor-backup-2697"
LOG = HOME / "Library/Logs/EnviousWispr/app.log"
APP = pathlib.Path(
    "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr-2697/build/EnviousWispr Local.app")
EXEC = APP / "Contents/MacOS/EnviousWispr"

# The ONLY roots this script may ever delete inside. Anything else is a bug.
DELETABLE_ROOTS = [OWNED, META]


def fingerprint(root: pathlib.Path) -> dict:
    """path -> (size, inode). Inode as well as size: a move, or a replace with
    identical content, leaves the size equal and is exactly the outcome this
    change exists to prevent."""
    out = {}
    if not root.exists():
        return out
    for p in sorted(root.rglob("*")):
        if p.is_file() and not p.is_symlink():
            st = p.stat()
            out[str(p.relative_to(root))] = (st.st_size, st.st_ino)
    return out


def guard_deletable(path: pathlib.Path):
    real = path.resolve()
    for allowed in DELETABLE_ROOTS:
        try:
            real.relative_to(allowed.resolve().parent)
            return
        except ValueError:
            continue
    raise SystemExit(f"REFUSING to touch {path}: outside the declared roots")


def app_pids() -> list[int]:
    r = subprocess.run(["pgrep", "-f", str(EXEC)], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split()]


def quit_app(hard: bool):
    """TERM or KILL every instance of OUR build, then wait for the process table
    to actually show them gone."""
    for pid in app_pids():
        os.kill(pid, signal.SIGKILL if hard else signal.SIGTERM)
    if not wait_for(lambda: not app_pids(), 10, "the app to leave the process table"):
        for pid in app_pids():
            os.kill(pid, signal.SIGKILL)


def log_offset() -> int:
    return LOG.stat().st_size if LOG.exists() else 0


def log_since(offset: int) -> str:
    if not LOG.exists():
        return ""
    with open(LOG, "rb") as f:
        f.seek(offset)
        return f.read().decode("utf-8", "replace")


def launch():
    """Launch, retrying a LaunchServices refusal.

    `open` can return -600 for a few hundred milliseconds after a SIGKILL, while
    macOS still has the dead process registered. That is a race in the harness,
    not in the app, so it retries rather than failing the case it was about to
    measure."""
    last = None
    for _ in range(10):
        r = subprocess.run(["open", "-a", str(APP)], capture_output=True, text=True)
        if r.returncode == 0:
            return
        last = r.stderr.strip()
        time.sleep(0.5)  # settle: LaunchServices still holds the killed process
    raise SystemExit(f"could not launch after 10 attempts: {last}")


def wait_for(predicate, seconds: float, what: str) -> bool:
    """Poll a REAL condition until it holds, with a deadline as the fallback."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.1)  # settle: poll interval between real-signal checks, not a wait for the signal itself
    print(f"  TIMEOUT waiting for {what}")
    return False


def simulate_upgrade():
    """Put the machine into the state of a user about to update: the model is in
    the OLD shared folder, not in ours, with no migration record and no
    admission marker."""
    guard_deletable(OWNED)
    if OWNED.exists():
        shutil.rmtree(OWNED)
    for pattern in ("*legacy-migration.json", "parakeet*admission.json"):
        for f in META.glob(pattern):
            guard_deletable(f)
            f.unlink()


def donor_intact(before: dict) -> bool:
    after = fingerprint(DONOR)
    if before == after:
        return True
    missing = sorted(set(before) - set(after))
    changed = sorted(k for k in set(before) & set(after) if before[k] != after[k])
    print(f"  DONOR CHANGED. missing={missing} changed={changed}")
    return False


def record_state():
    for rec in META.glob("*legacy-migration.json"):
        try:
            return json.loads(rec.read_text()).get("state")
        except Exception as exc:
            return f"UNREADABLE:{exc}"
    return None


def main():
    if not EXEC.exists():
        raise SystemExit(f"no dev app at {EXEC}")
    if not BACKUP.exists():
        raise SystemExit("refusing to run without the donor backup")
    print(f"donor  {len(fingerprint(DONOR))} files")
    print(f"owned  {len(fingerprint(OWNED))} files")
    print(f"record {record_state()}")
    print(f"app    {'running' if app_pids() else 'not running'}")


if __name__ == "__main__":
    main()
