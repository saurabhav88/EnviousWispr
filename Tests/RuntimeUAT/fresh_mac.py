#!/usr/bin/env python3
"""Make this Mac look like a first EnviousWispr install for Setup UAT, and put it back (#4528).

  fresh_mac.py status            what is in place and what a fresh run would move
  fresh_mac.py prepare           move models and settings aside (refuses while any app runs)
  fresh_mac.py restore DIR       move back whatever is still missing, import the settings

`prepare` MOVES (renames on the same disk), never deletes, so `restore` is instant and nothing
is lost if a test download fails. It moves:
  - ~/Library/Application Support/EnviousWispr/Models        every downloaded model
  - ~/Library/Application Support/EnviousWispr/ModelDelivery  the admission records
  - ~/Library/Application Support/EnviousWispr/SetupRules     the cached signed Setup rules
  - ~/Library/Application Support/FluidAudio/Models           the shared Parakeet cache (the app
                                                              adopts an older copy in place)
and exports, then deletes, the settings domains com.enviouswispr.app and com.enviouswispr.app.dev.
It never touches the Keychain (cloud keys), History, custom words, recordings or privacy grants.

`restore DIR` puts back each moved folder whose original path is now absent; a folder the test
downloaded again stays, and its old copy remains in DIR for you to delete by hand. Settings are
imported from the export, replacing what the test wrote. The backup DIR is never deleted here.

Founder 2026-11-13: "you can remove the models", "make it look like it's scratch", both Macs.
"""

import datetime
import json
import os
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
SUPPORT = HOME / "Library/Application Support"
FOLDERS = [
    SUPPORT / "EnviousWispr/Models",
    SUPPORT / "EnviousWispr/ModelDelivery",
    SUPPORT / "EnviousWispr/SetupRules",
    SUPPORT / "FluidAudio/Models",
]
DOMAINS = ["com.enviouswispr.app", "com.enviouswispr.app.dev"]
BACKUPS = HOME / "EW-fresh-mac-backup"
MANIFEST = "manifest.json"


def running_apps():
    """Every running EnviousWispr app, production or dev, by executable path (never by name)."""
    out = subprocess.run(["ps", "-eww", "-o", "pid=,comm="], capture_output=True, text=True,
                         check=True).stdout
    apps = []
    for line in out.splitlines():
        pid, _, exe = line.strip().partition(" ")
        if exe.strip().endswith(".app/Contents/MacOS/EnviousWispr"):
            apps.append((int(pid), exe.strip()))
    return apps


def size_gib(path):
    out = subprocess.run(["du", "-sk", str(path)], capture_output=True, text=True)
    try:
        return round(int(out.stdout.split()[0]) / 1048576, 2)
    except (IndexError, ValueError):
        return None


def status():
    report = {"running": running_apps(), "folders": {}, "domains": {}}
    for folder in FOLDERS:
        report["folders"][str(folder)] = (
            {"present": True, "gib": size_gib(folder)} if folder.exists() else {"present": False})
    for domain in DOMAINS:
        r = subprocess.run(["defaults", "export", domain, "-"], capture_output=True)
        report["domains"][domain] = {"present": r.returncode == 0 and len(r.stdout) > 0,
                                     "bytes": len(r.stdout)}
    return report


def prepare():
    apps = running_apps()
    if apps:
        raise SystemExit(f"refusing: quit every EnviousWispr app first: {apps}")
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = BACKUPS / stamp
    backup.mkdir(parents=True)
    manifest = {"created": stamp, "folders": [], "domains": []}
    for folder in FOLDERS:
        if not folder.exists():
            continue
        target = backup / "folders" / folder.relative_to(HOME)
        target.parent.mkdir(parents=True, exist_ok=True)
        if os.stat(folder).st_dev != os.stat(target.parent).st_dev:
            raise SystemExit(f"refusing: {folder} is on another disk; a move would copy")
        folder.rename(target)
        if folder.exists() or not target.exists():
            raise SystemExit(f"move did not land: {folder} -> {target}")
        manifest["folders"].append({"original": str(folder), "moved_to": str(target)})
    for domain in DOMAINS:
        plist = backup / f"{domain}.plist"
        r = subprocess.run(["defaults", "export", domain, str(plist)], capture_output=True)
        if r.returncode != 0:
            continue  # the domain does not exist: already fresh
        subprocess.run(["defaults", "delete", domain], check=True, capture_output=True)
        manifest["domains"].append({"domain": domain, "export": str(plist)})
    (backup / MANIFEST).write_text(json.dumps(manifest, indent=2))
    return {"backup": str(backup), **manifest}


def restore(backup_dir):
    backup = Path(backup_dir)
    manifest = json.loads((backup / MANIFEST).read_text())
    apps = running_apps()
    if apps:
        raise SystemExit(f"refusing: quit every EnviousWispr app first: {apps}")
    report = {"restored": [], "kept_new": [], "domains": []}
    for entry in manifest["folders"]:
        original, moved = Path(entry["original"]), Path(entry["moved_to"])
        if original.exists():
            report["kept_new"].append(str(original))  # the test downloaded it again
        elif moved.exists():
            original.parent.mkdir(parents=True, exist_ok=True)
            moved.rename(original)
            report["restored"].append(str(original))
    for entry in manifest["domains"]:
        subprocess.run(["defaults", "import", entry["domain"], entry["export"]], check=True)
        report["domains"].append(entry["domain"])
    return report


def main(argv):
    if not argv or argv[0] == "status":
        result = status()
    elif argv[0] == "prepare":
        result = prepare()
    elif argv[0] == "restore" and len(argv) == 2:
        result = restore(argv[1])
    else:
        raise SystemExit(__doc__)
    print(json.dumps(result, indent=2, default=str))


if __name__ == "__main__":
    main(sys.argv[1:])
