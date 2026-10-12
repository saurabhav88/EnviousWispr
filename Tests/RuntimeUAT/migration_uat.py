#!/usr/bin/env python3
"""Live UAT driver for the Parakeet v3 -> Ultra upgrade (#3546; replaces the #2697 driver).

Runs against the REAL directories on this Mac. Every check fails CLOSED: a missing
artifact or a timeout is a failure, never a pass. Every wait polls a real signal
(a process leaving the table, a log line arriving) with a deadline as the fallback.

Default mode is a read-only PREFLIGHT: it reports what the drill would act on and
changes nothing. `--drill` runs the upgrade path a v3 user takes:

  stage   owned v3 restored from --backup (APFS clone), Ultra and its upgrade state removed
  launch1 v3 serves; Ultra downloads in the background and is admitted; v3 is NOT retired
          (admission alone is not activation)
  launch2 the launch is a selection point: Ultra activates and the owned v3 is retired
  launch3 the owned v3 is not re-created (no v3 admission line; founder 2026-10-12)

The shared FluidAudio donor is read-only throughout and fingerprinted at every step.
Deletions are confined to the app-owned Models and ModelDelivery folders. Claim the
dev-app lock (scripts/lib/dev-app-lock.py in the main checkout) before `--drill`.

Usage:
  python3 Tests/RuntimeUAT/migration_uat.py --app "<worktree>/build/EnviousWispr Local.app"
  python3 Tests/RuntimeUAT/migration_uat.py --app "<...>.app" --drill --backup <dir with v3 files>
"""
import argparse, os, pathlib, plistlib, re, signal, subprocess, sys, time

APPSUP = pathlib.Path.home() / "Library/Application Support"
DONOR = APPSUP / "FluidAudio/Models/parakeet-tdt-0.6b-v3"
DATA = APPSUP / "EnviousWispr"
MODELS = DATA / "Models"
META = DATA / "ModelDelivery"
OWNED_V3 = MODELS / "parakeet-tdt-0.6b-v3"
ULTRA = MODELS / "parakeet-ultra"
LOG = pathlib.Path.home() / "Library/Logs/EnviousWispr/app.log"
V3_LINE = "parakeet-parakeet-tdt-0.6b-v3-coreml-"
ULTRA_LINE = "parakeet-parakeet-ultra-coreml-"
# Any EnviousWispr bundle, release or development: another running copy refuses the drill.
APP_EXE = re.compile(r"\s*(\d+) (/.*\.app/Contents/MacOS/EnviousWispr)$")


class Fail(Exception):
    pass


def fingerprint(root: pathlib.Path) -> dict:
    """relative path -> (size, inode, mtime_ns); empty when the folder is absent."""
    out = {}
    if root.exists():
        for p in sorted(root.rglob("*")):
            if p.is_file() and not p.is_symlink():
                st = p.stat()
                out[str(p.relative_to(root))] = (st.st_size, st.st_ino, st.st_mtime_ns)
    return out


def exe_of(pid: int) -> str:
    r = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True)
    return r.stdout.strip()


def dev_instances() -> list:
    r = subprocess.run(["ps", "-eww", "-o", "pid=,comm="], capture_output=True, text=True, check=True)
    return [(int(m.group(1)), m.group(2)) for m in map(APP_EXE.match, r.stdout.splitlines()) if m]


class App:
    def __init__(self, bundle: pathlib.Path):
        self.bundle = bundle.resolve()
        self.exe = str(self.bundle / "Contents/MacOS/EnviousWispr")
        if not os.access(self.exe, os.X_OK):
            raise Fail(f"no dev app executable at {self.exe}")
        with open(self.bundle / "Contents/Info.plist", "rb") as f:
            bundle_id = plistlib.load(f).get("CFBundleIdentifier")
        if bundle_id != "com.enviouswispr.app.dev":
            raise Fail(f"refusing non-development app: {bundle_id!r}")

    def pid(self):
        rows = dev_instances()
        others = [r for r in rows if r[1] != self.exe]
        if others:
            raise Fail(f"another dev app is running, refusing: {others}")
        ours = [p for p, e in rows if e == self.exe]
        if len(ours) > 1:
            raise Fail(f"more than one instance of this build: {ours}")
        return ours[0] if ours else None

    def stop(self):
        """TERM this build and its helpers, wait for every one to leave, KILL stragglers, and
        refuse (never proceed to a cache mutation) while any of them is still running."""
        pid = self.pid()
        if pid is None:
            return
        children = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
        targets = [(pid, self.exe)]
        for child in map(int, children):
            identity = exe_of(child)
            if identity.startswith(str(self.bundle) + "/"):
                targets.append((child, identity))

        def signal_all(sig):
            for target, identity in targets:
                if exe_of(target) == identity:
                    try:
                        os.kill(target, sig)
                    except ProcessLookupError:
                        pass

        def gone():
            return all(exe_of(p) != identity for p, identity in targets)

        signal_all(signal.SIGTERM)
        if not wait_for(gone, 15, "the app and its helpers to exit"):
            signal_all(signal.SIGKILL)
            if not wait_for(gone, 15, "forced app shutdown"):
                raise Fail("app or helper still running; refusing cache mutation")

    def start(self) -> int:
        if self.pid() is not None:
            raise Fail("app already running")
        subprocess.run(["open", str(self.bundle)], check=True, capture_output=True)
        if not wait_for(lambda: self.pid() is not None, 20, "the app to start"):
            raise Fail("app did not start")
        return self.pid()


def wait_for(predicate, seconds: float, what: str) -> bool:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.25)  # settle: poll interval between real-signal checks
    print(f"  TIMEOUT waiting for {what}", flush=True)
    return False


def log_offset() -> int:
    return LOG.stat().st_size if LOG.exists() else 0


def log_since(offset: int) -> str:
    with open(LOG, "rb") as f:
        f.seek(offset)
        return f.read().decode("utf-8", "replace")


def wait_line(offset: int, needle: str, seconds: float) -> str:
    found = []

    def seen():
        found[:] = [l for l in log_since(offset).splitlines() if needle in l]
        return bool(found)

    if not wait_for(seen, seconds, f"log line containing {needle!r}"):
        raise Fail(f"no log line containing {needle!r} within {seconds}s")
    return found[0]


def remove_owned(path: pathlib.Path, app: App):
    """Delete an app-owned model folder or marker. Refuses anything outside Models or
    ModelDelivery, anything inside the donor, a mount point, or a running app."""
    real = pathlib.Path(os.path.realpath(path))
    inside = any(str(real).startswith(str(root) + "/") for root in (MODELS, META))
    if not inside or str(real).startswith(os.path.realpath(DONOR)):
        raise Fail(f"refusing to remove {real}")
    if app.pid() is not None:
        raise Fail("app is running; stop it first")
    if not os.path.lexists(real):
        return
    if real.is_dir() and not real.is_symlink():
        if os.path.ismount(real):
            raise Fail(f"{real} is a mount point")
        r = subprocess.run(["find", str(real), "-xdev", "-delete"], capture_output=True, text=True)
        if r.stderr.strip():
            print("  find stderr:", r.stderr.strip(), flush=True)
    else:
        real.unlink()
    if os.path.lexists(real):
        raise Fail(f"{real} still exists after removal")


def report(app: App, donor: dict):
    print(f"app     {app.exe}", flush=True)
    print(f"running {app.pid()}")
    print(f"donor   {len(donor)} files at {DONOR}")
    print(f"ownedV3 {len(fingerprint(OWNED_V3))} files")
    print(f"ultra   {len(fingerprint(ULTRA))} files")
    print(f"markers {sorted(p.name for p in META.glob('parakeet-*'))}")


def stage_v3_user(app: App, backup: pathlib.Path, donor: dict):
    files = fingerprint(backup)
    if not files or {k: v[0] for k, v in files.items()} != {k: v[0] for k, v in donor.items()}:
        raise Fail(f"backup {backup} does not hold the donor's v3 file set")
    app.stop()
    remove_owned(OWNED_V3, app)
    remove_owned(ULTRA, app)
    for p in META.glob("parakeet-*"):
        if ULTRA_LINE in p.name or p.name.startswith("parakeet-upgrade-") or \
                (V3_LINE in p.name and p.name.endswith(".admission.json")):
            remove_owned(p, app)
    subprocess.run(["cp", "-cR", str(backup), str(OWNED_V3)], check=True)


def drill(app: App, backup: pathlib.Path) -> None:
    donor = fingerprint(DONOR)
    stage_v3_user(app, backup, donor)

    off = log_offset()
    app.start()
    line = wait_line(off, f"admitted {ULTRA_LINE}", 1200)
    print(f"launch1 Ultra admitted: {line}", flush=True)
    if f"retired {V3_LINE}" in log_since(off) or not fingerprint(OWNED_V3):
        raise Fail("launch1: v3 was retired by admission alone")
    print("launch1 v3 still present after admission: PASS", flush=True)
    app.stop()

    off = log_offset()
    app.start()
    print(f"launch2 {wait_line(off, f'retired {V3_LINE}', 180)}", flush=True)
    if fingerprint(OWNED_V3):
        raise Fail("launch2: owned v3 still present after activation")
    print("launch2 Ultra activated and owned v3 retired: PASS", flush=True)
    app.stop()

    off = log_offset()
    app.start()
    wait_line(off, f"retired {V3_LINE}", 180)  # the activation of this launch
    if f"admitted {V3_LINE}" in log_since(off) or fingerprint(OWNED_V3):
        raise Fail("launch3: owned v3 was re-created")
    print("launch3 owned v3 not re-created: PASS", flush=True)

    if fingerprint(DONOR) != donor:
        raise Fail("the shared FluidAudio donor changed")
    print("donor unchanged: PASS", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--app", required=True, type=pathlib.Path, help="dev app bundle to drive")
    ap.add_argument("--drill", action="store_true", help="run the upgrade drill (mutates owned state)")
    ap.add_argument("--backup", type=pathlib.Path, help="directory holding a v3 copy (required for --drill)")
    a = ap.parse_args()
    try:
        app = App(a.app)
        report(app, fingerprint(DONOR))
        if not a.drill:
            print("preflight only: nothing was changed")
            return 0
        if not a.backup or not a.backup.is_dir():
            raise Fail("--drill needs --backup <dir>")
        drill(app, a.backup.resolve())
        print("DRILL PASS")
        return 0
    except Fail as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
