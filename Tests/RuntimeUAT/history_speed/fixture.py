#!/usr/bin/env python3
"""The one owner of the History speed fixture: its seed, its working homes and app launches.

Issue #4586, plan D0. Every History speed driver resolves its fixture home and starts the app
through this module, so isolation, ownership and identity rules live in one place.

The fixture
    A founder-free History library (27,018 dictations, 2,571 imports, 37 meetings at the time
    of import) copied from a `prelaunch-data` folder whose original location and generator are
    NOT recorded. This module does not reconstruct that generator. It keeps the corpus as an
    immutable SEED (the three source categories plus a SHA-256 manifest) and regenerates fresh
    WORKING HOMES from it. Derived state (HistoryCatalog, HTTPStorages, rules, locks) is never
    part of the seed; the app rebuilds it.

Isolation, and its known limit
    A launch sets HOME and CFFIXED_USER_HOME to the working home and runs the app under
    `sandbox-exec` with a profile that denies the founder's real History folders, real
    EnviousWispr preferences writes, containers, logs, and all outbound network. The saved
    evidence of the 2026-11-14 speed run records that the app still wrote `lastHistoryTab`
    into the real `com.enviouswispr.app` preferences and wrote `~/Library/HTTPStorages`. So
    HOME redirection does NOT isolate preferences: whether this profile closes that leak is
    NOT VERIFIED and must be proven live before a driver relies on it (PR 0 chunk 2).

Ownership
    Launching or stopping the app requires the shared dev-app lock (`dev_control.check_owner`,
    the same decision every dev-control mutation makes). A launch refuses when any EnviousWispr
    instance with the same executable is already running, or when the running set cannot be
    read. A stop acts only on a PID this module started and re-verifies its executable first.

Commands (run from the repository root):
    python3 Tests/RuntimeUAT/history_speed/fixture.py seed --source <Application Support/EnviousWispr> --seed <new dir>
    python3 Tests/RuntimeUAT/history_speed/fixture.py verify --seed <dir>
    python3 Tests/RuntimeUAT/history_speed/fixture.py regenerate --seed <dir> --home <new dir>
    python3 Tests/RuntimeUAT/history_speed/fixture.py launch --app <EnviousWispr.app> --home <dir> --dry-run
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

SEED_CATEGORIES = ("transcripts", "Meetings", "recordings")
MANIFEST = "manifest.json"
APP_SUPPORT = Path("Library/Application Support/EnviousWispr")
PROFILE_NAME = "isolated-release.sb"
EXECUTABLE = Path("Contents/MacOS/EnviousWispr")
RUNTIME_UAT = Path(__file__).resolve().parent.parent
REMOVE_TREE = RUNTIME_UAT.parent.parent / "scripts/lib/remove-tree.py"
SUBJECT_BUNDLE_ID = "com.enviouswispr.app.historyspeed"
PRODUCTION_DOMAIN = "com.enviouswispr.app"
API_KEY_FOLDER = ".enviouswispr-keys"          # KeychainManager file fallback (homeDirectoryForCurrentUser)
RECOVERY_KEY_FOLDER = ".enviouswispr-recovery-keys"  # RecoveryKeyStore file fallback


class FixtureError(Exception):
    """A seed, home or launch request that this module refuses."""


# ---------------------------------------------------------------- seed


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _files(root: Path) -> list[Path]:
    """Every regular file under root, sorted; a symlink anywhere is refused (it could leave the tree)."""
    found = []
    for directory, subdirs, names in os.walk(root, followlinks=False):
        for name in subdirs + names:
            if (Path(directory) / name).is_symlink():
                raise FixtureError(f"symlink inside fixture: {Path(directory) / name}")
        found += [Path(directory) / name for name in names]
    return sorted(found)


def _inventory(root: Path) -> dict[str, dict[str, str]]:
    """{category: {relative path: sha256}} for the three source categories under root."""
    inventory = {}
    for category in SEED_CATEGORIES:
        base = root / category
        if not base.is_dir() or base.is_symlink():
            raise FixtureError(f"missing source category: {base}")
        inventory[category] = {str(p.relative_to(base)): _sha256(p) for p in _files(base)}
    return inventory


def build_seed(source: Path, seed: Path) -> dict:
    """Copy the three source categories from an `Application Support/EnviousWispr` folder into a
    new seed folder and write its manifest. Refuses an existing seed folder."""
    source, seed = source.resolve(), Path(os.path.abspath(seed))
    if seed.exists():
        raise FixtureError(f"seed already exists: {seed}")
    if not seed.parent.is_dir():
        raise FixtureError(f"seed parent does not exist: {seed.parent}")
    seed.mkdir(mode=0o700)
    for category in SEED_CATEGORIES:
        if not (source / category).is_dir():
            raise FixtureError(f"missing source category: {source / category}")
        subprocess.run(["/usr/bin/ditto", str(source / category), str(seed / category)], check=True)
    inventory = _inventory(seed)
    manifest = {
        "issue": 4586,
        "origin": "prelaunch-data (original location and generator not recorded)",
        "imported_from": str(source),
        "categories": inventory,
        "counts": {c: len(files) for c, files in inventory.items()},
    }
    (seed / MANIFEST).write_text(json.dumps(manifest, indent=1, sort_keys=True))
    return manifest


def load_manifest(seed: Path) -> dict:
    path = seed / MANIFEST
    if not path.is_file():
        raise FixtureError(f"seed has no manifest: {path}")
    manifest = json.loads(path.read_text())
    if sorted(manifest.get("categories", {})) != sorted(SEED_CATEGORIES):
        raise FixtureError(f"manifest categories are not {SEED_CATEGORIES}: {path}")
    return manifest


def _compare(expected: dict, actual: dict, where: Path) -> None:
    for category in SEED_CATEGORIES:
        want, got = expected[category], actual[category]
        missing = sorted(set(want) - set(got))
        extra = sorted(set(got) - set(want))
        changed = sorted(p for p in set(want) & set(got) if want[p] != got[p])
        if missing or extra or changed:
            raise FixtureError(
                f"{where / category} differs from the manifest: "
                f"{len(missing)} missing, {len(extra)} extra, {len(changed)} changed "
                f"(first: {(missing + extra + changed)[0]})")


def verify_seed(seed: Path) -> dict:
    """Raise unless every file in the seed matches its manifest exactly."""
    manifest = load_manifest(seed)
    _compare(manifest["categories"], _inventory(seed), seed)
    return manifest


# ---------------------------------------------------------------- working homes


def _refuse_unsafe_home(home: Path) -> None:
    real = Path.home().resolve()
    resolved = Path(os.path.abspath(home))
    if resolved.exists() or resolved.is_symlink():
        raise FixtureError(f"home already exists: {resolved}")
    if not resolved.parent.is_dir():
        raise FixtureError(f"home parent does not exist: {resolved.parent}")
    parent = resolved.parent.resolve()
    if resolved == real or parent == real or real / "Library" in (parent, *parent.parents):
        raise FixtureError(f"refusing a home inside the real home or Library: {resolved}")


def regenerate_home(seed: Path, home: Path) -> Path:
    """Create a fresh working home from a verified seed and verify the copy. Refuses an existing
    or unsafe destination; never deletes anything."""
    manifest = verify_seed(seed)
    _refuse_unsafe_home(home)
    home = Path(os.path.abspath(home))
    support = home / APP_SUPPORT
    support.mkdir(mode=0o700, parents=True)
    for category in SEED_CATEGORIES:
        subprocess.run(["/usr/bin/ditto", str(seed / category), str(support / category)], check=True)
    _compare(manifest["categories"], _inventory(support), support)
    (home / PROFILE_NAME).write_text(sandbox_profile(Path.home()))
    return home


def catalog_dir(home: Path) -> Path:
    """The derived catalog folder a driver may delete to force a cold rebuild."""
    return home / APP_SUPPORT / "HistoryCatalog"


def transcripts_dir(home: Path) -> Path:
    return home / APP_SUPPORT / "transcripts"


# ---------------------------------------------------------------- launch


def _sb_string(path: Path) -> str:
    text = str(path)
    if '"' in text or "\\" in text:
        raise FixtureError(f"path cannot be written into a sandbox profile: {text}")
    return f'"{text}"'


def sandbox_profile(real_home: Path) -> str:
    """The isolation profile, parameterized by the real home it protects (the 2026-11-14 profile
    hard-coded one user's paths)."""
    support = _sb_string(real_home / "Library/Application Support/EnviousWispr")
    legacy = _sb_string(real_home / "EnviousWispr")
    containers = _sb_string(real_home / "Library/Containers/com.enviouswispr.app")
    logs = _sb_string(real_home / "Library/Logs/EnviousWispr")
    prefs = str(real_home / "Library/Preferences").replace(".", "\\.")
    api_keys = _sb_string(real_home / API_KEY_FOLDER)
    recovery_keys = _sb_string(real_home / RECOVERY_KEY_FOLDER)
    http = _sb_string(real_home / "Library/HTTPStorages" / PRODUCTION_DOMAIN)
    cookies = _sb_string(real_home / "Library/HTTPStorages" / f"{PRODUCTION_DOMAIN}.binarycookies")
    return "\n".join([
        "(version 1)",
        "(allow default)",
        f"(deny file-write* (subpath {support}))",
        f"(deny file-read-data (subpath {support}))",
        f"(deny file-write* (subpath {legacy}))",
        f"(deny file-read-data (subpath {legacy}))",
        f'(deny file-write* (regex #"^{prefs}/com\\.enviouswispr\\..*"))',
        f"(deny file-write* (subpath {containers}))",
        f"(deny file-write* (subpath {logs}))",
        # #4586 chunk 2: the real home's credential fallbacks and production HTTP storage. With
        # CFFIXED_USER_HOME set these resolve inside the fixture home anyway; the denies are
        # defence in depth.
        f"(deny file-write* (subpath {api_keys}))",
        f"(deny file-read-data (subpath {api_keys}))",
        f"(deny file-write* (subpath {recovery_keys}))",
        f"(deny file-read-data (subpath {recovery_keys}))",
        f"(deny file-write* (subpath {http}))",
        f"(deny file-write* (literal {cookies}))",
        "(deny network-outbound)",
        "",
    ])


@dataclass(frozen=True)
class LaunchPlan:
    argv: tuple[str, ...]
    env: dict[str, str]
    executable: str


def _plist_identity(app: Path) -> str | None:
    """The bundle identifier in the app's Info.plist, or None when it cannot be read."""
    import plistlib
    try:
        with open(Path(app) / "Contents/Info.plist", "rb") as handle:
            return plistlib.load(handle).get("CFBundleIdentifier")
    except (OSError, ValueError, plistlib.InvalidFileException):
        return None


def launch_plan(app: Path, home: Path, base_env: dict[str, str] | None = None) -> LaunchPlan:
    """The exact command and child environment for one isolated launch. Pure: reads nothing but the
    given paths and never changes the caller's environment."""
    app, home = Path(os.path.abspath(app)), Path(os.path.abspath(home))
    executable = app / EXECUTABLE
    if not executable.is_file():
        raise FixtureError(f"no app executable: {executable}")
    # Only the renamed measurement subject may launch, on every route including the CLI: the
    # production identity would use production Keychain services and preferences (PR #4658 review).
    identity = _plist_identity(app)
    if identity != SUBJECT_BUNDLE_ID:
        raise FixtureError(f"{app} has bundle identifier {identity!r}, not the renamed subject {SUBJECT_BUNDLE_ID}; "
                           f"prepare it with prepare_subject first")
    profile = home / PROFILE_NAME
    if not (home / APP_SUPPORT).is_dir() or not profile.is_file():
        raise FixtureError(f"not a regenerated fixture home: {home}")
    env = dict(os.environ if base_env is None else base_env)
    env["HOME"] = str(home)
    env["CFFIXED_USER_HOME"] = str(home)
    argv = ("/usr/bin/sandbox-exec", "-f", str(profile), str(executable),
            "-onboardingState", "completed")
    return LaunchPlan(argv=argv, env=env, executable=str(executable))


def prepare_subject(app: Path, dest: Path, expected_sha256: str) -> Path:
    """Copy the pinned Release app to a fresh owned folder and rename its bundle identifier to
    SUBJECT_BUNDLE_ID, so every preference write follows that throwaway identity (#4596). The
    executable bytes must equal `expected_sha256` before and after; the source app is untouched."""
    app, dest = Path(os.path.abspath(app)), Path(os.path.abspath(dest))
    if dest.exists() or dest.is_symlink():
        raise FixtureError(f"subject folder already exists: {dest}")
    if not dest.parent.is_dir():
        raise FixtureError(f"subject parent does not exist: {dest.parent}")
    if _sha256(app / EXECUTABLE) != expected_sha256:
        raise FixtureError(f"pinned executable hash differs from {expected_sha256}: {app / EXECUTABLE}")
    dest.mkdir(mode=0o700)
    subject = dest / app.name
    subprocess.run(["/usr/bin/ditto", str(app), str(subject)], check=True)
    plist = subject / "Contents/Info.plist"
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {SUBJECT_BUNDLE_ID}", str(plist)],
                   check=True)
    identity = subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", str(plist)],
                              capture_output=True, text=True, check=True).stdout.strip()
    if identity != SUBJECT_BUNDLE_ID:
        raise FixtureError(f"subject bundle identifier is {identity!r}")
    if _sha256(subject / EXECUTABLE) != expected_sha256:
        raise FixtureError("subject executable bytes changed during the copy")
    return subject


def require_subject_pid(pid: int, subject: Path, *, comm=None) -> str:
    """Return the subject's executable path when `pid` runs exactly it; refuse otherwise. The
    expected path comes from the prepared subject, never from the pid, so the production app or a
    peer's dev build can never pass."""
    if subject_identity(subject) != SUBJECT_BUNDLE_ID:
        raise FixtureError(f"{subject} is not the renamed measurement subject")
    expected = str(Path(os.path.abspath(subject)) / EXECUTABLE)
    running = (comm or _comm)(pid)
    if running != expected:
        raise FixtureError(f"pid {pid} runs {running!r}, not the subject {expected}")
    return expected


def subject_identity(subject: Path) -> str:
    plist = Path(subject) / "Contents/Info.plist"
    return subprocess.run(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", str(plist)],
                          capture_output=True, text=True, check=True).stdout.strip()


def export_domain(domain: str, run=subprocess.run):
    """A read-only snapshot of a preferences domain as a Python object, or None when it does not
    exist. Never writes. `defaults export` prints an empty dictionary with exit 0 for a domain that
    never existed (measured 2026-11-15), so existence is decided by `defaults read`, which reports
    "Domain ... not found"."""
    import plistlib
    probe = run(["/usr/bin/defaults", "read", domain], capture_output=True)
    if probe.returncode != 0:
        if b"not found" in probe.stderr or b"does not exist" in probe.stderr:
            return None
        raise FixtureError(f"cannot read {domain}: {probe.stderr.decode(errors='replace').strip()}")
    result = run(["/usr/bin/defaults", "export", domain, "-"], capture_output=True)
    if result.returncode != 0:
        raise FixtureError(f"cannot export {domain}: {result.stderr.decode(errors='replace').strip()}")
    return plistlib.loads(result.stdout)


def throwaway_paths(real_home: Path) -> dict:
    """Everything the renamed subject may create in the real home, by its own identity."""
    return {"preferences": real_home / "Library/Preferences" / f"{SUBJECT_BUNDLE_ID}.plist",
            "http_storage": real_home / "Library/HTTPStorages" / SUBJECT_BUNDLE_ID,
            "cookies": real_home / "Library/HTTPStorages" / f"{SUBJECT_BUNDLE_ID}.binarycookies"}


def refuse_existing_throwaway(real_home: Path, export=export_domain) -> None:
    """Before a session: the throwaway identity must have no state yet, so everything found after
    the session is this session's to remove."""
    found = [str(p) for p in throwaway_paths(real_home).values() if p.exists() or p.is_symlink()]
    if export(SUBJECT_BUNDLE_ID) is not None:
        found.append(f"defaults domain {SUBJECT_BUNDLE_ID}")
    if found:
        raise FixtureError(f"throwaway state already exists, refusing to start: {found}")


def cleanup_throwaway(real_home: Path, *, remover=None, run=subprocess.run, export=export_domain) -> list:
    """After a session: remove the throwaway identity's preferences and HTTP storage. Called only
    after `refuse_existing_throwaway` proved none existed before this session."""
    # The only identity this may ever delete is the renamed subject's own, never production's.
    if SUBJECT_BUNDLE_ID == PRODUCTION_DOMAIN or not SUBJECT_BUNDLE_ID.endswith(".historyspeed"):
        raise FixtureError(f"refusing to delete the state of {SUBJECT_BUNDLE_ID!r}")
    removed = []
    if run(["/usr/bin/defaults", "delete", SUBJECT_BUNDLE_ID], capture_output=True).returncode == 0:
        removed.append(f"defaults domain {SUBJECT_BUNDLE_ID}")
    paths = throwaway_paths(real_home)
    for key in ("preferences", "cookies"):
        if paths[key].is_file() and not paths[key].is_symlink():
            paths[key].unlink()
            removed.append(str(paths[key]))
    remover = remover or _load_remover()
    status = remover.remove_tree(str(real_home / "Library/HTTPStorages"), str(paths["http_storage"]))
    if status == remover.REMOVED:
        removed.append(str(paths["http_storage"]))
    elif status != remover.ABSENT:
        raise FixtureError(f"throwaway HTTP storage removal refused (status {status})")
    left = [str(p) for p in paths.values() if p.exists() or p.is_symlink()]
    if export(SUBJECT_BUNDLE_ID) is not None:
        left.append(f"defaults domain {SUBJECT_BUNDLE_ID}")
    if left:
        raise FixtureError(f"throwaway state still present after cleanup: {left}")
    return removed


class ContainedSession:
    """One live session of the renamed subject on a fixture home (#4586 chunk 2).

    Enter: lock ownership, no pre-existing throwaway state, a read-only snapshot of the production
    preferences domain, then the launch. Exit: stop the owned process, compare the production
    domain with the snapshot (a difference is raised as a finding and is NEVER restored over:
    another writer may have changed it legitimately), then remove this session's throwaway state.
    """

    def __init__(self, subject: Path, home: Path, log: Path, *, real_home: Path | None = None,
                 owner_check=None, launcher=None, stopper=None, export=None, cleanup=None, comm=None):
        self.subject, self.home, self.log = Path(subject), Path(home), Path(log)
        self.real_home = real_home or Path(pwd_home())
        self.owner_check = owner_check or _default_owner_check
        self.launcher = launcher or (lambda: launch(self.subject, self.home, self.log, owner_check=self.owner_check))
        self.stopper = stopper or (lambda pid, exe: stop(pid, exe, owner_check=self.owner_check))
        self.export = export or export_domain
        self.cleanup = cleanup or (lambda: cleanup_throwaway(self.real_home))
        self.comm = comm or _comm
        self.pid = None
        self.executable = str(self.subject / EXECUTABLE)
        self.report = {}

    def __enter__(self):
        self.owner_check()
        if subject_identity(self.subject) != SUBJECT_BUNDLE_ID:
            raise FixtureError(f"subject is not renamed to {SUBJECT_BUNDLE_ID}: {self.subject}")
        refuse_existing_throwaway(self.real_home, export=self.export)
        self.before = self.export(PRODUCTION_DOMAIN)
        self.pid = self.launcher()
        return self

    def __exit__(self, *exc):
        problems = []
        stopped = self.pid is None
        try:
            if self.pid is not None:
                self.stopper(self.pid, self.executable)
                stopped = self.comm(self.pid) is None   # confirmed exit, not the stopper's word
                if not stopped:
                    problems.append(f"stop: pid {self.pid} still running")
        except Exception as error:
            problems.append(f"stop: {error}")
        self.report["stopped"] = stopped
        changed = []
        try:   # comparison and cleanup are attempted independently; both failures are reported
            after = self.export(PRODUCTION_DOMAIN)
            changed = sorted(k for k in set(self.before or {}) | set(after or {})
                             if (self.before or {}).get(k) != (after or {}).get(k))
        except Exception as error:
            problems.append(f"production comparison: {error}")
        self.report["production_changed_keys"] = changed
        if not stopped:
            problems.append("cleanup skipped: the subject may still be writing its throwaway state")
        else:
            try:
                self.owner_check()   # still ours before touching anything
                self.report["removed"] = self.cleanup()
            except Exception as error:
                problems.append(f"cleanup: {error}")
        if changed:
            problems.append(f"production preferences changed during the session (not restored): {changed}")
        if problems:
            raise FixtureError("; ".join(problems))
        return False


def pwd_home() -> str:
    """The real home from the user database, independent of HOME and CFFIXED_USER_HOME."""
    import pwd
    return pwd.getpwuid(os.getuid()).pw_dir


def _default_owner_check():
    sys.path.insert(0, str(RUNTIME_UAT))
    import dev_control
    dev_control.check_owner()


def _default_instances():
    sys.path.insert(0, str(RUNTIME_UAT))
    import instance_guard
    return instance_guard.running_enviouswispr_instances()


def _comm(pid: int) -> str | None:
    """The executable of `pid`, or None when the process is gone. A `ps` failure is "could not
    tell" and raises: macOS `ps -p` exits 1 with no output at all for an absent PID, and prints a
    message for every real error."""
    result = subprocess.run(["/bin/ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True)
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()
    if result.returncode == 1 and not result.stdout.strip() and not result.stderr.strip():
        return None
    raise FixtureError(f"cannot read pid {pid} (exit {result.returncode}): {result.stderr.strip()}")


LAST_SPAWN_AT = None   # mach_absolute_time() taken immediately before the last launch's spawn


def _mach_now() -> int:
    import ctypes
    libc = ctypes.CDLL("/usr/lib/libSystem.dylib")
    libc.mach_absolute_time.restype = ctypes.c_uint64
    return libc.mach_absolute_time()


def launch(app: Path, home: Path, log: Path, *, owner_check=_default_owner_check,
           instances=_default_instances, spawn=subprocess.Popen) -> int:
    """Start one isolated app and return its PID. Refuses without the dev-app lock, when the running
    instance set cannot be read, or when an instance of the same executable is already running."""
    plan = launch_plan(app, home)
    owner_check()
    try:
        running = instances()
    except Exception as error:
        raise FixtureError(f"cannot read running EnviousWispr instances: {error}") from error
    if running is None:
        raise FixtureError("cannot read running EnviousWispr instances")
    clashes = sorted(pid for pid, exe in running.items() if exe == plan.executable)
    if clashes:
        raise FixtureError(f"{plan.executable} already running as {clashes}")
    with open(log, "ab") as sink:
        # Every check is done: the spawn timestamp sits immediately beside the spawn (#4586 WP-A).
        global LAST_SPAWN_AT
        LAST_SPAWN_AT = _mach_now()
        process = spawn(list(plan.argv), env=plan.env, stdout=sink, stderr=sink,
                        stdin=subprocess.DEVNULL, start_new_session=True)
    return process.pid


def stop(pid: int, executable: str, *, owner_check=_default_owner_check, comm=_comm,
         kill=os.kill, sleep=time.sleep, timeout: float = 5.0) -> bool:
    """TERM, then KILL, one PID this caller started, after re-verifying it still runs `executable`.
    Returns False when the PID is already gone; refuses a PID running anything else."""
    owner_check()
    current = comm(pid)
    if current is None:
        return False
    if current != executable:
        raise FixtureError(f"pid {pid} runs {current}, not {executable}; refusing to stop it")
    kill(pid, signal.SIGTERM)
    if _gone(pid, comm, sleep, timeout):
        return True
    if comm(pid) == executable:
        kill(pid, signal.SIGKILL)
    if _gone(pid, comm, sleep, timeout):
        return True
    raise FixtureError(f"pid {pid} ({executable}) still running after TERM and KILL")


def _gone(pid, comm, sleep, timeout: float) -> bool:
    remaining = timeout
    while remaining > 0:
        if comm(pid) is None:
            return True
        sleep(0.05)
        remaining -= 0.05
    return comm(pid) is None


def _load_remover():
    """The repository's physical deletion boundary (`scripts/lib/remove-tree.py`, #4197), loaded the
    way its other caller does, without import-cache writes."""
    import types
    module = types.ModuleType("ew_remove_tree")
    module.__file__ = str(REMOVE_TREE)
    exec(compile(REMOVE_TREE.read_bytes(), str(REMOVE_TREE), "exec"), module.__dict__)
    return module


def reset_catalog(home: Path, *, owner_check=_default_owner_check, remover=None) -> bool:
    """Delete only the derived catalog of a regenerated fixture home, after the ownership check, so
    the next launch rebuilds it cold. Returns False when there was no catalog. Deletion goes through
    `remove-tree.py`, which refuses linked or mounted components and stays on one filesystem."""
    owner_check()
    home = Path(os.path.realpath(home))
    if not (home / APP_SUPPORT).is_dir() or not (home / PROFILE_NAME).is_file():
        raise FixtureError(f"not a regenerated fixture home: {home}")
    remover = remover or _load_remover()
    status = remover.remove_tree(str(home / APP_SUPPORT), str(catalog_dir(home)))
    if status == remover.REMOVED:
        return True
    if status == remover.ABSENT:
        return False
    raise FixtureError(f"catalog deletion refused or incomplete (remove-tree status {status}): {catalog_dir(home)}")


# ---------------------------------------------------------------- command line


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("seed", help="build a new seed from an Application Support/EnviousWispr folder")
    p.add_argument("--source", type=Path, required=True)
    p.add_argument("--seed", type=Path, required=True)
    p = sub.add_parser("verify", help="check every seed file against its manifest")
    p.add_argument("--seed", type=Path, required=True)
    p = sub.add_parser("regenerate", help="create a fresh working home from a seed")
    p.add_argument("--seed", type=Path, required=True)
    p.add_argument("--home", type=Path, required=True)
    p = sub.add_parser("launch", help="start the app on a working home (needs the dev-app lock)")
    p.add_argument("--app", type=Path, required=True)
    p.add_argument("--home", type=Path, required=True)
    p.add_argument("--log", type=Path, default=Path(os.devnull))
    p.add_argument("--dry-run", action="store_true", help="print the command; start nothing")
    args = parser.parse_args(argv)
    try:
        if args.command == "seed":
            print(json.dumps(build_seed(args.source, args.seed)["counts"]))
        elif args.command == "verify":
            print(json.dumps(verify_seed(args.seed)["counts"]))
        elif args.command == "regenerate":
            print(regenerate_home(args.seed, args.home))
        elif args.dry_run:
            plan = launch_plan(args.app, args.home)
            print(json.dumps({"argv": plan.argv, "HOME": plan.env["HOME"],
                              "CFFIXED_USER_HOME": plan.env["CFFIXED_USER_HOME"]}))
        else:
            print(launch(args.app, args.home, args.log))
    except FixtureError as error:
        print(f"fixture: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
