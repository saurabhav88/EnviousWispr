#!/usr/bin/env python3
"""Reset this Mac's EnviousWispr models and settings to first-install state for Setup UAT, and
put them back exactly (#4528).

  fresh_mac.py status            what is in place, and any unfinished backup
  fresh_mac.py prepare           move models and settings aside (needs the dev-app lock)
  fresh_mac.py restore DIR       put the originals back exactly; the test's state is kept in DIR

What `prepare` resets: the app's models (Application Support/EnviousWispr/Models), their
admission records (ModelDelivery), the cached signed Setup rules (SetupRules), the shared
Parakeet cache (Application Support/FluidAudio/Models: shared with other FluidAudio apps, so
quit those too) and both settings domains (com.enviouswispr.app, com.enviouswispr.app.dev, which
hold onboarding completion and the Setup checkpoint). It is a MODEL AND SETTINGS reset, not a
complete scratch install: cloud keys (Keychain and the dev key file), cloud-models.json,
History, custom words, recordings and privacy grants stay as they are.

Safety, in order (review fresh-mac-review-r1, 2026-11-13):
  1. Refuse while any EnviousWispr app, its polish helpers (llama-server, envious-decode) or an
     ASR service runs, unless this caller holds the dev-app lock; re-checked before each change.
     A process started by someone ignoring the lock is outside what a check can prevent: run it
     in an exclusive window.
  2. Refuse if the app's alternate storage root (~/EnviousWispr) exists, or an unfinished
     backup exists.
  3. Before ANY change: check every move stays on one disk, snapshot both settings domains
     (verified by reading the saved plist back) and write the full plan to an atomic manifest.
  4. Then rename folders (never delete) and clear the domains, journaling each step.
`restore` parks whatever the test left (folders and both domains) under DIR/test-state, puts
every original folder back, re-imports each original domain (or deletes one that did not exist),
and marks the backup restored so a second restore cannot undo later choices. Nothing is ever
deleted: DIR keeps the test's state until you remove it by hand.

Founder 2026-11-13: "you can remove the models", "make it look like it's scratch", both Macs,
"our laptop is a dev machine meant for testing".
"""

import datetime
import json
import os
import plistlib
import subprocess
import sys
import uuid
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

HOME = Path.home()
SUPPORT = HOME / "Library/Application Support"
FOLDERS = [
    SUPPORT / "EnviousWispr/Models",
    SUPPORT / "EnviousWispr/ModelDelivery",
    SUPPORT / "EnviousWispr/SetupRules",
    SUPPORT / "FluidAudio/Models",
]
ALTERNATE_ROOT = HOME / "EnviousWispr"
DOMAINS = ["com.enviouswispr.app", "com.enviouswispr.app.dev"]
BACKUPS = HOME / "EW-fresh-mac-backup"
MANIFEST = "manifest.json"
APPS = {"EnviousWispr", "EnviousWisprASRService"}
HELPERS = {"llama-server", "envious-decode"}  # ours only when they run from an EnviousWispr path


class Refused(SystemExit):
    pass


def running_processes():
    """Every EnviousWispr app (any location) and every polish helper run from an EnviousWispr
    bundle or folder. Another app's own llama-server (Ollama ships one) is not ours."""
    out = subprocess.run(["ps", "-eww", "-o", "pid=,comm="], capture_output=True, text=True,
                         check=True).stdout
    found = []
    for line in out.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2:
            raise RuntimeError(f"unreadable process row: {line!r}")
        pid, exe = fields
        name = Path(exe).name
        if name in APPS or (name in HELPERS and "EnviousWispr" in exe):
            found.append((int(pid), exe))
    return found


def require_stopped():
    found = running_processes()
    if found:
        raise Refused(f"refusing: quit these first: {found}")


def require_lock():
    """The machine-wide dev-app ownership decision every app mutation uses."""
    import dev_control
    try:
        dev_control.check_owner()
    except dev_control.DoorRefused as error:
        raise Refused(f"refusing: claim the dev-app lock first ({error})") from error


def domain_settings(domain):
    """The domain's settings. `defaults domains` keeps listing a deleted domain and `export`
    of a missing domain succeeds with an empty dictionary (measured 2026-11-13), so a domain
    counts as present only when it holds settings."""
    r = subprocess.run(["defaults", "export", domain, "-"], capture_output=True, check=True)
    settings = plistlib.loads(r.stdout)
    if not isinstance(settings, dict):
        raise RuntimeError(f"invalid settings export: {domain}")
    return settings, r.stdout


def snapshot_domain(domain, destination):
    """Saves one settings domain and proves the saved copy reads back identically."""
    expected, raw = domain_settings(domain)
    if not expected:
        return {"domain": domain, "present": False}
    with destination.open("xb") as f:
        f.write(raw)
        f.flush()
        os.fsync(f.fileno())
    with destination.open("rb") as f:
        if plistlib.load(f) != expected:
            raise RuntimeError(f"settings export did not read back: {domain}")
    return {"domain": domain, "present": True, "export": str(destination)}


def save_manifest(backup, manifest):
    path, temp = backup / MANIFEST, backup / (MANIFEST + ".tmp")
    with temp.open("w") as f:
        json.dump(manifest, f, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temp, path)
    fd = os.open(backup, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def backups():
    if not BACKUPS.exists():
        return []
    found = []
    for d in sorted(BACKUPS.iterdir()):
        m = d / MANIFEST
        if m.exists():
            found.append((d, json.loads(m.read_text())))
    return found


def unfinished():
    return [str(d) for d, m in backups() if not m.get("restored")]


def status():
    report = {"running": running_processes(), "alternate_root": ALTERNATE_ROOT.exists(),
              "unfinished_backups": unfinished(), "folders": {}, "domains": {}}
    for folder in FOLDERS:
        report["folders"][str(folder)] = folder.exists()
    for domain in DOMAINS:
        report["domains"][domain] = bool(domain_settings(domain)[0])
    return report


def require_mutation_window():
    """Checked immediately before every change: the lock is ours and nothing of ours runs."""
    require_lock()
    require_stopped()


def prepare():
    require_mutation_window()
    if ALTERNATE_ROOT.exists():
        raise Refused(f"refusing: the app's alternate storage root {ALTERNATE_ROOT} exists; "
                      "inspect it first")
    if unfinished():
        raise Refused(f"refusing: restore the unfinished backup first: {unfinished()}")
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = BACKUPS / stamp
    backup.mkdir(parents=True)
    plan = []
    for folder in FOLDERS:  # absent folders are recorded too, so restore returns them to absent
        target = backup / "folders" / folder.relative_to(HOME)
        present = os.path.lexists(folder)
        if present:
            target.parent.mkdir(parents=True, exist_ok=True)
            if folder.lstat().st_dev != target.parent.stat().st_dev:
                raise Refused(f"refusing: {folder} is on another disk; a move would copy")
        plan.append({"original": str(folder), "moved_to": str(target), "present": present,
                     "moved": False})
    domains = [snapshot_domain(d, backup / f"{d}.plist") for d in DOMAINS]
    manifest = {"created": stamp, "folders": plan, "domains": domains, "cleared": [],
                "restored": False}
    save_manifest(backup, manifest)  # the full plan exists before the first change
    for entry in plan:
        if not entry["present"]:
            continue
        require_mutation_window()
        Path(entry["original"]).rename(entry["moved_to"])
        if os.path.lexists(entry["original"]) or not os.path.lexists(entry["moved_to"]):
            raise RuntimeError(f"move did not land: {entry}")
        entry["moved"] = True
        save_manifest(backup, manifest)
    for entry in domains:
        if not entry["present"]:
            continue
        require_mutation_window()
        subprocess.run(["defaults", "delete", entry["domain"]], check=True, capture_output=True)
        manifest["cleared"].append(entry["domain"])
        save_manifest(backup, manifest)
    return {"backup": str(backup), **manifest}


def preserve_test_settings(backup, manifest):
    """Saves the test's settings once, journaled, so a retried restore reuses them."""
    directory = backup / "test-state"
    directory.mkdir(exist_ok=True)
    saved = manifest.setdefault("test_domains", {})
    for entry in manifest["domains"]:
        domain = entry["domain"]
        if domain not in saved:
            require_mutation_window()
            destination = directory / f"{domain}-{uuid.uuid4().hex}.plist"
            saved[domain] = snapshot_domain(domain, destination)
            save_manifest(backup, manifest)
        record = saved[domain]
        if record["present"]:
            with Path(record["export"]).open("rb") as f:
                if not isinstance(plistlib.load(f), dict):
                    raise RuntimeError(f"invalid saved test settings: {domain}")


def restore(backup_dir):
    require_mutation_window()
    backup = Path(backup_dir)
    manifest = json.loads((backup / MANIFEST).read_text())
    if manifest.get("restored"):
        raise Refused("refusing: this backup was already restored")
    preserve_test_settings(backup, manifest)
    test_state = backup / "test-state"
    report = {"folders_restored": [], "test_folders_kept": [], "domains": []}
    for entry in manifest["folders"]:
        original, moved = Path(entry["original"]), Path(entry["moved_to"])
        was_present = entry.get("present", True)
        if was_present and not os.path.lexists(moved):
            if not os.path.lexists(original):
                raise RuntimeError(f"original and backup both missing: {original}")
            continue  # never moved, or already restored
        original.parent.mkdir(parents=True, exist_ok=True)
        if os.path.lexists(original):  # what the test left (or created where nothing was)
            parked = test_state / original.relative_to(HOME)
            parked.parent.mkdir(parents=True, exist_ok=True)
            if os.path.lexists(parked):
                raise RuntimeError(f"restore conflict: {parked}")
            if original.lstat().st_dev != parked.parent.stat().st_dev:
                raise RuntimeError(f"cross-disk restore: {original}")
            require_mutation_window()
            original.rename(parked)
            report["test_folders_kept"].append(str(parked))
        if was_present:
            require_mutation_window()
            moved.rename(original)
            report["folders_restored"].append(str(original))
    for entry in manifest["domains"]:
        domain = entry["domain"]
        require_mutation_window()
        # `defaults import` merges into what is there (measured), so clear the domain first:
        # the test's own settings are already saved in test-state.
        if domain_settings(domain)[0]:
            subprocess.run(["defaults", "delete", domain], check=True, capture_output=True)
        if entry["present"]:
            subprocess.run(["defaults", "import", domain, entry["export"]], check=True)
        report["domains"].append(domain)
    manifest["restored"] = datetime.datetime.now().isoformat()
    save_manifest(backup, manifest)
    return report


def self_test():
    """Runs prepare, a simulated test run and restore inside a throwaway home folder with a
    throwaway settings domain; touches no real model, setting or lock."""
    import shutil
    import tempfile
    global HOME, SUPPORT, FOLDERS, ALTERNATE_ROOT, DOMAINS, BACKUPS
    saved = (HOME, SUPPORT, FOLDERS, ALTERNATE_ROOT, DOMAINS, BACKUPS)
    globals()["require_lock"] = lambda: None
    globals()["require_stopped"] = lambda: None
    root = Path(tempfile.mkdtemp(prefix="ew-fresh-selftest-"))
    domain = f"com.enviouswispr.fresh-selftest-{uuid.uuid4().hex[:8]}"
    failures = []

    def expect(ok, what):
        print(("PASS " if ok else "FAIL ") + what)
        if not ok:
            failures.append(what)

    try:
        HOME = root
        SUPPORT = root / "Library/Application Support"
        FOLDERS = [SUPPORT / "EnviousWispr/Models", SUPPORT / "EnviousWispr/SetupRules"]
        ALTERNATE_ROOT = root / "EnviousWispr"
        DOMAINS = [domain]
        BACKUPS = root / "EW-fresh-mac-backup"
        (FOLDERS[0] / "eg-1").mkdir(parents=True)
        (FOLDERS[0] / "eg-1/weights.bin").write_text("original")
        # SetupRules is absent before prepare: restore must return it to absent.
        subprocess.run(["defaults", "write", domain, "hasCompletedOnboarding", "-bool", "true"],
                       check=True)
        result = prepare()
        backup = Path(result["backup"])
        expect(not FOLDERS[0].exists(), "prepare moved the models aside")
        expect(not domain_settings(domain)[0], "prepare cleared the settings domain")
        expect(json.loads((backup / MANIFEST).read_text())["folders"][1]["present"] is False,
               "an absent folder is recorded as absent")
        try:
            prepare()
            expect(False, "a second prepare refuses while a backup is unfinished")
        except Refused:
            expect(True, "a second prepare refuses while a backup is unfinished")
        # The "test": a partial new download, a new rules cache, a new setting.
        (FOLDERS[0] / "eg-1").mkdir(parents=True)
        (FOLDERS[0] / "eg-1/weights.bin").write_text("partial")
        FOLDERS[1].mkdir(parents=True)
        subprocess.run(["defaults", "write", domain, "testOnly", "-bool", "true"], check=True)
        restore(str(backup))
        expect((FOLDERS[0] / "eg-1/weights.bin").read_text() == "original",
               "restore put the original models back")
        expect(not FOLDERS[1].exists(), "restore returned the absent folder to absent")
        kept = backup / "test-state" / FOLDERS[0].relative_to(root) / "eg-1/weights.bin"
        expect(kept.read_text() == "partial", "the test's download is kept in the backup")
        out = subprocess.run(["defaults", "read", domain, "hasCompletedOnboarding"],
                             capture_output=True, text=True).stdout.strip()
        test_only = subprocess.run(["defaults", "read", domain, "testOnly"],
                                   capture_output=True, text=True)
        expect(out == "1" and test_only.returncode != 0,
               "restore re-imported the original settings exactly")
        try:
            restore(str(backup))
            expect(False, "a second restore refuses")
        except Refused:
            expect(True, "a second restore refuses")
    finally:
        subprocess.run(["defaults", "delete", domain], capture_output=True)
        HOME, SUPPORT, FOLDERS, ALTERNATE_ROOT, DOMAINS, BACKUPS = saved
        shutil.rmtree(root)  # our own fresh temporary folder, created above
    print(f"{len(failures)} failure(s)")
    return len(failures)


def main(argv):
    if not argv or argv[0] == "status":
        result = status()
    elif argv[0] == "prepare":
        result = prepare()
    elif argv[0] == "--self-test":
        raise SystemExit(1 if self_test() else 0)
    elif argv[0] == "restore" and len(argv) == 2:
        result = restore(argv[1])
    else:
        raise SystemExit(__doc__)
    print(json.dumps(result, indent=2, default=str))


if __name__ == "__main__":
    main(sys.argv[1:])
