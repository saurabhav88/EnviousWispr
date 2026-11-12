#!/usr/bin/env python3
"""Read-only view of every shared-work slot on every configured Mac (#4507).

  mac-slots.py status [--json]
  mac-slots.py --self-test

CI state comes from the lock itself (a separate non-blocking shared-lock probe of
the slot file), never from a holder card: a held slot with no live card is
"held_unknown" (an older runner). Missing slot files read as free; nothing is
created, written or cached here. Local app testing (UAT) is read from the
existing dev-app lock card without involving its owner; a backup Mac's app
testing (#4510) is read the same way from the card scripts/remote-dev-app.py
keeps for it on THIS Mac (dev-app-lock-hosts/<host>/holder.json). Each backup Mac's job state comes from its remote
supervisor over SSH (`remote-job.py status`), even when this Mac holds no slot
for it; a Mac that does not answer shows as unreachable. Exit 2 when the host
list is invalid.
"""

import fcntl
import importlib.util
import json
import os
from pathlib import Path
import pwd
import sys
import time

HERE = Path(__file__).resolve().parent
# OS identity, not HOME. Tests rewrite this one literal in a private COPY.
UAT_CARD = Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Caches/EnviousWispr/dev-app-lock/holder.json"
# Backup-Mac app-testing holds, one folder per host name (scripts/remote-dev-app.py HOST_LOCKS).
UAT_HOST_CARDS = Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Caches/EnviousWispr/dev-app-lock-hosts"


def _module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def ci_state(queue, host):
    """free | held | held_unknown, plus the live card when there is one."""
    path = queue.host_slot_path(host)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return "free", None
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            card = queue.read_card(host)
            return ("held" if card else "held_unknown"), card
        fcntl.flock(fd, fcntl.LOCK_UN)
        return "free", None
    finally:
        os.close(fd)


def uat_hold(lock, card_path):
    """One dev-app slot's effective state, using the unchanged owner's own read
    helpers (holder liveness and the 10-minute founder-wait rule) without taking
    its mutex or creating its folder. Anything it cannot decide is "unknown".
    The owner reads wait events from its LOCK_DIR, so it points at the card's
    folder for the read, as scripts/remote-dev-app.py does for its holds."""
    try:
        card = json.loads(card_path.read_text())
    except FileNotFoundError:
        return {"state": "free", "holder": None}
    except (OSError, ValueError):
        return {"state": "unknown", "holder": None}
    if not isinstance(card, dict) or type(card.get("pid")) is not int or not isinstance(card.get("started"), str):
        return {"state": "unknown", "holder": None}
    now = time.time()
    saved = getattr(lock, "LOCK_DIR", None)
    try:
        if saved is not None:
            lock.LOCK_DIR = str(card_path.parent)
        alive = lock.holder_alive(card)
        expired = alive and lock.wait_expired(card, now)
    except Exception:  # the owner's Undecided or a malformed field: never guess
        return {"state": "unknown", "holder": None}
    finally:
        if saved is not None:
            lock.LOCK_DIR = saved
    if not alive or expired:
        return {"state": "free", "holder": None}
    return {"state": "held",
            "holder": {"label": card.get("label"), "session_kind": card.get("kind"),
                       "worktree": card.get("worktree"),
                       "elapsed_s": int(now - card.get("claimed_at", now))}}


def orphan_hosts(queue, configured):
    """Slot folders on this Mac for hosts no longer in the host list that still
    hold a lock or a live card: shown, never silently dropped."""
    folder = queue.host_slot_path("local").parent / "hosts"
    try:
        names = sorted(p.name for p in folder.iterdir() if p.is_dir())
    except FileNotFoundError:
        return []
    out = []
    for name in names:
        if name in configured or not queue.HOST_NAME.fullmatch(name):
            continue
        state, card = ci_state(queue, name)
        if state != "free" or queue.read_card(name):
            holder = None if card is None else {"label": card.get("label"), "worktree": card.get("worktree")}
            out.append({"name": name, "display": name, "local": False, "orphan": True,
                        "slots": {"ci": {"state": "orphan", "lock": state, "holder": holder}}})
    return out


def status(hosts_module, queue, lock, remote_job_fn=None):
    hosts, sha = hosts_module.load()
    now = time.time()
    out = {"schema": 1, "config_sha256": sha, "hosts": []}
    for host in hosts:
        slot = hosts_module.slot_name(host)
        entry = {"name": host["name"], "display": host.get("display", host["name"]),
                 "local": host["ssh"] is None, "slots": {}}
        if "ci" in host["kinds"]:
            state, card = ci_state(queue, slot)
            holder = None
            if card:
                last = card.get("last_output_at")
                holder = {"label": card.get("label"), "kind": card.get("kind"),
                          "worktree": card.get("worktree"),
                          "elapsed_s": int(now - card.get("claimed_at", now)),
                          "last_output_age_s": None if last is None else int(now - last)}
            entry["slots"]["ci"] = {"state": state, "holder": holder}
        if "uat" in host["kinds"]:
            card = UAT_CARD if host["ssh"] is None else UAT_HOST_CARDS / host["name"] / "holder.json"
            entry["slots"]["uat"] = uat_hold(lock, card)
        if host["ssh"] is not None:
            entry["remote_job"] = remote_job_fn(hosts_module, host) if remote_job_fn else "not queried"
        out["hosts"].append(entry)
    out["hosts"].extend(orphan_hosts(queue, {hosts_module.slot_name(h) for h in hosts}))
    return out


def remote_job(hosts_module, host):
    """The backup Mac's supervisor state: free, or held with run id and phase."""
    import shlex
    import subprocess
    checkout = f"{host['root']}/EnviousWispr-ci"
    command = (f"python3 {shlex.quote(checkout + '/scripts/lib/remote-job.py')} status "
               f"--checkout {shlex.quote(checkout)}")
    try:
        result = subprocess.run(hosts_module.ssh_command(host, command), capture_output=True,
                                text=True, timeout=15)
        return json.loads(result.stdout) if result.returncode == 0 else {"state": "unreachable"}
    except (subprocess.TimeoutExpired, ValueError, OSError):
        return {"state": "unreachable"}


def text(report):
    lines = []
    for host in report["hosts"]:
        parts = []
        for kind in ("ci", "uat"):
            slot = host["slots"].get(kind)
            if slot is None:
                continue
            holder = slot.get("holder")
            if holder:
                parts.append(f"{kind.upper()}: {holder.get('label')} {holder.get('elapsed_s', 0) // 60}m")
            else:
                parts.append(f"{kind.upper()}: {slot['state']}")
        job = host.get("remote_job")
        if isinstance(job, dict):
            parts.append("JOB: " + (f"{job.get('phase') or 'running'} ({job.get('run_id')})"
                                    if job.get("state") == "held" else job.get("state", "unknown")))
        lines.append(f"{host['display']}: " + " · ".join(parts))
    return "\n".join(lines)


def self_test():
    import subprocess
    import tempfile
    global UAT_CARD, UAT_HOST_CARDS
    queue_src = (HERE / "local-ci-queue.py").read_text()
    definition = 'LOCK_PATH = Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Caches/EnviousWispr/local-ci/runner.lock"'
    hosts_src = (HERE / "lib/mac_hosts.py").read_text()
    config_definition = 'CONFIG_PATH = Path(pwd.getpwuid(os.getuid()).pw_dir) / ".config/enviouswispr/mac-hosts.json"'
    checks, failures = 0, []
    with tempfile.TemporaryDirectory(prefix="ew-mac-slots-") as tmp:
        root = Path(tmp)
        lock = root / "local-ci/runner.lock"
        config = root / "mac-hosts.json"
        if queue_src.count(definition) != 1 or hosts_src.count(config_definition) != 1:
            print("FAIL: private-copy rewrite literals not found")
            return 1
        (root / "queue.py").write_text(queue_src.replace(definition, f"LOCK_PATH = Path({str(lock)!r})"))
        (root / "hosts.py").write_text(hosts_src.replace(config_definition, f"CONFIG_PATH = Path({str(config)!r})"))
        UAT_CARD = root / "dev-app-lock/holder.json"
        UAT_HOST_CARDS = root / "dev-app-lock-hosts"
        queue = _module("queue_copy", root / "queue.py")
        hosts = _module("hosts_copy", root / "hosts.py")
        config.write_text(json.dumps({"schema": 1, "hosts": [
            {"name": "main", "ssh": None, "order": 0, "kinds": ["ci"], "ci_workers": 4, "audio": "real"},
            {"name": "spare", "ssh": "spare-host", "order": 1, "kinds": ["ci"], "ci_workers": 2,
             "audio": "blackhole", "root": "/x", "requires_mount": None, "repo_url": "https://e.invalid"}]}))
        report = status(hosts, queue, None)
        checks += 1
        if [h["slots"]["ci"]["state"] for h in report["hosts"]] != ["free", "free"] or lock.exists():
            failures.append("missing slot files read as free and are not created")
        subprocess.run([sys.executable, str(root / "queue.py"), "prepare-host", "spare"],
                       check=True, capture_output=True)
        holder = os.open(queue.host_slot_path("spare"), os.O_RDWR)
        try:
            fcntl.flock(holder, fcntl.LOCK_EX)
            report = status(hosts, queue, None)
            checks += 1
            if report["hosts"][1]["slots"]["ci"]["state"] != "held_unknown":
                failures.append("a held slot without a live card is held_unknown, never free")
            # The host is removed from the list while its slot is still held.
            config.write_text(json.dumps({"schema": 1, "hosts": [
                {"name": "main", "ssh": None, "order": 0, "kinds": ["ci", "uat"], "ci_workers": 4, "audio": "real"}]}))
            checks += 1
            if [h["name"] for h in status(hosts, queue, None)["hosts"] if h.get("orphan")] != ["spare"]:
                failures.append("a removed host that still holds its slot is shown as an orphan")
        finally:
            os.close(holder)
        checks += 1
        if len(status(hosts, queue, None)["hosts"]) != 1:
            failures.append("a released slot of a removed host is no longer shown")
        # A local app-testing card whose session has ended reads as free (the
        # owner's own liveness helper decides; a stub stands in for it here).
        UAT_CARD.parent.mkdir()
        UAT_CARD.write_text(json.dumps({"pid": 4242, "started": "x", "kind": "claude", "label": "old"}))

        class Ended:
            @staticmethod
            def holder_alive(_card):
                return False

        checks += 1
        if status(hosts, queue, Ended)["hosts"][0]["slots"]["uat"]["state"] != "free":
            failures.append("an ended app-testing hold reads as free")
        # A backup Mac with kind uat reads the hold remote-dev-app.py keeps for it
        # here: free with no card, the holder's label while its session lives,
        # with the owner pointed at that host's folder for the read.
        config.write_text(json.dumps({"schema": 1, "hosts": [
            {"name": "main", "ssh": None, "order": 0, "kinds": ["ci", "uat"], "ci_workers": 4, "audio": "real"},
            {"name": "spare", "ssh": "spare-host", "order": 1, "kinds": ["ci", "uat"], "ci_workers": 2,
             "audio": "blackhole", "root": "/x", "requires_mount": None, "repo_url": "https://e.invalid"}]}))

        class Alive:
            LOCK_DIR = "unchanged"
            seen = []

            @staticmethod
            def holder_alive(_card):
                Alive.seen.append(Alive.LOCK_DIR)
                return True

            @staticmethod
            def wait_expired(_card, _now):
                return False

        checks += 1
        if status(hosts, queue, Alive)["hosts"][1]["slots"]["uat"]["state"] != "free":
            failures.append("a backup Mac with no app-testing card reads as free")
        host_card = UAT_HOST_CARDS / "spare/holder.json"
        host_card.parent.mkdir(parents=True)
        host_card.write_text(json.dumps({"pid": 4343, "started": "y", "kind": "claude", "label": "uat-spare",
                                         "claimed_at": time.time() - 180}))
        uat = status(hosts, queue, Alive)["hosts"][1]["slots"]["uat"]
        checks += 1
        line = text({"hosts": [{"display": "spare", "slots": {"uat": uat}}]})
        if uat["state"] != "held" or line != "spare: UAT: uat-spare 3m":
            failures.append("a live backup-Mac app-testing hold shows its label and minutes")
        checks += 1
        if Alive.seen[-1] != str(host_card.parent) or Alive.LOCK_DIR != "unchanged":
            failures.append("the owner reads a backup Mac's hold from that host's folder, then is restored")
    for label in failures:
        print(f"FAIL: {label}")
    print(f"mac-slots self-test: {checks - len(failures)} of {checks} checks passed")
    return 1 if failures else 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    if argv not in (["status"], ["status", "--json"]):
        print("usage: mac-slots.py status [--json] | --self-test", file=sys.stderr)
        return 2
    hosts_module = _module("mac_hosts", HERE / "lib/mac_hosts.py")
    queue = _module("local_ci_queue", HERE / "local-ci-queue.py")
    lock = _module("dev_app_lock", HERE / "lib/dev-app-lock.py")
    try:
        report = status(hosts_module, queue, lock, remote_job_fn=remote_job)
    except hosts_module.ConfigError as error:
        print(f"ERROR: Mac host config: {error}", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2) if argv[-1] == "--json" else text(report))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
