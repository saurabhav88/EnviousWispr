#!/usr/bin/env python3
"""Which Macs exist for shared CI work, and what each may take (#4507).

The host list is LOCAL data, never committed (the repository is public):
~/.config/enviouswispr/mac-hosts.json, resolved from the OS account like the CI
queue's lock path, so a changed HOME cannot point it elsewhere. No file means
exactly one host, "local", which is today's single-Mac behavior. An unreadable or
invalid file fails closed: callers stop with exit 2 rather than guess.

Schema 1:
  {"schema": 1, "hosts": [{
     "name": "m5max",            # [a-z0-9-]{1,32}, unique
     "display": "M5 Max",        # optional, <= 24 chars, for the status strip
     "ssh": null,                # null for exactly one host (this Mac); else the ssh target
     "order": 0,                 # unique; lower is tried first
     "kinds": ["ci"],            # subset of ci|uat (uat routing is #4510)
     "ci_workers": 4,            # 1..4
     "root": "/Volumes/T9/ew",   # remote only: absolute work root
     "requires_mount": "/Volumes/T9",  # remote only: absolute path or null
     "audio": "real",            # real|blackhole
     "repo_url": "https://..."   # remote only
  }]}
The selector "local" always means the ssh:null host, whatever its name.

Usage:
  mac_hosts.py list            print the effective hosts as JSON
  mac_hosts.py check-config    exit 0 when the file is absent or valid, else 2
  mac_hosts.py sha             print the config's SHA-256 ("none" when absent); exit 2 if invalid
  mac_hosts.py eligible-ci [--real [FILTER ...]]
                               remote CI hosts usable now, in order (probe cached 60 s). --real: a
                               real-boundary run; it needs a host with audio "real" unless FILTERs
                               are given and every one names a suite in AUDIO_FREE_LIST
  mac_hosts.py local-workers   this Mac's ci_workers (4 when there is no config)
  mac_hosts.py --self-test
"""

import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import sys

# OS identity, not HOME. Tests rewrite this one literal in a private COPY.
CONFIG_PATH = Path(pwd.getpwuid(os.getuid()).pw_dir) / ".config/enviouswispr/mac-hosts.json"

NAME = re.compile(r"[a-z0-9-]{1,32}")
KINDS = {"ci", "uat"}
AUDIO = {"real", "blackhole"}
LOCAL_KEYS = {"name", "display", "ssh", "order", "kinds", "ci_workers", "audio"}
REMOTE_KEYS = LOCAL_KEYS | {"root", "requires_mount", "repo_url"}
# Real-boundary suites that need no live audio device (models, files, GPU only), so a backup
# Mac whose audio is "blackhole" may run them. Tracked; each entry's suite carries the
# `.audioDeviceFree` tag in its own source, and TestInventoryFreezeTests keeps the list and
# the tags identical.
AUDIO_FREE_LIST = Path(__file__).resolve().parents[1] / "real-boundary-audio-free.json"
IMPLICIT = {"name": "local", "display": "This Mac", "ssh": None, "order": 0,
            "kinds": ["ci", "uat"], "ci_workers": 4, "audio": "real"}


class ConfigError(ValueError):
    pass


def _host(entry, index):
    where = f"hosts[{index}]"
    if not isinstance(entry, dict):
        raise ConfigError(f"{where} must be an object")
    remote = entry.get("ssh") is not None
    allowed = REMOTE_KEYS if remote else LOCAL_KEYS
    unknown = set(entry) - allowed
    if unknown:
        raise ConfigError(f"{where} has unknown or misplaced keys: {', '.join(sorted(unknown))}")
    name = entry.get("name")
    if not isinstance(name, str) or not NAME.fullmatch(name):
        raise ConfigError(f"{where}.name must match [a-z0-9-]{{1,32}}")
    display = entry.get("display", name)
    if not isinstance(display, str) or not 0 < len(display) <= 24:
        raise ConfigError(f"{where}.display must be 1-24 characters")
    order = entry.get("order")
    if not isinstance(order, int) or isinstance(order, bool):
        raise ConfigError(f"{where}.order must be an integer")
    kinds = entry.get("kinds")
    if not isinstance(kinds, list) or not kinds or not set(kinds) <= KINDS or len(set(kinds)) != len(kinds):
        raise ConfigError(f"{where}.kinds must be a non-empty subset of ci, uat")
    workers = entry.get("ci_workers")
    if not isinstance(workers, int) or isinstance(workers, bool) or not 1 <= workers <= 4:
        raise ConfigError(f"{where}.ci_workers must be 1-4")
    if entry.get("audio") not in AUDIO:
        raise ConfigError(f"{where}.audio must be real or blackhole")
    host = {"name": name, "display": display, "ssh": entry.get("ssh"), "order": order,
            "kinds": list(kinds), "ci_workers": workers, "audio": entry["audio"]}
    if remote:
        if name == "local":
            raise ConfigError(f"{where}.name \"local\" is reserved for this Mac (the ssh: null host)")
        if not isinstance(entry["ssh"], str) or not entry["ssh"].strip():
            raise ConfigError(f"{where}.ssh must be a non-empty string or null")
        for key in ("root", "repo_url"):
            if not isinstance(entry.get(key), str) or not entry[key]:
                raise ConfigError(f"{where}.{key} is required for a remote host")
        if not entry["root"].startswith("/"):
            raise ConfigError(f"{where}.root must be absolute")
        mount = entry.get("requires_mount")
        if mount is not None and (not isinstance(mount, str) or not mount.startswith("/")):
            raise ConfigError(f"{where}.requires_mount must be an absolute path or null")
        host.update(root=entry["root"], requires_mount=mount, repo_url=entry["repo_url"])
    elif "ci" not in kinds or entry["audio"] != "real":
        # This Mac always runs its own test lanes first and has a real input
        # device; a setting that says otherwise would be silently ignored, so refuse it.
        raise ConfigError(f"{where} (this Mac, ssh: null) must list kind ci and audio real")
    return host


def parse(text):
    """Validate config text; return hosts sorted by order. Raises ConfigError."""
    try:
        data = json.loads(text)
    except json.JSONDecodeError as error:
        raise ConfigError(f"not valid JSON: {error}") from None
    if not isinstance(data, dict) or set(data) != {"schema", "hosts"} or data["schema"] != 1:
        raise ConfigError('top level must be exactly {"schema": 1, "hosts": [...]}')
    if not isinstance(data["hosts"], list) or not data["hosts"]:
        raise ConfigError("hosts must be a non-empty list")
    hosts = [_host(entry, i) for i, entry in enumerate(data["hosts"])]
    for key in ("name", "order"):
        values = [h[key] for h in hosts]
        if len(set(values)) != len(values):
            raise ConfigError(f"duplicate host {key}")
    if sum(h["ssh"] is None for h in hosts) != 1:
        raise ConfigError("exactly one host must have ssh: null (this Mac)")
    return sorted(hosts, key=lambda h: h["order"])


def load(path=None):
    """(hosts, config_sha256). No file: the implicit local host and sha "none"."""
    path = CONFIG_PATH if path is None else Path(path)
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return [dict(IMPLICIT)], "none"
    except OSError as error:
        raise ConfigError(f"cannot read {path}: {error}") from None
    return parse(raw.decode("utf-8", "strict")), hashlib.sha256(raw).hexdigest()


def resolve(hosts, selector):
    """The host for a selector; "local" means the ssh:null host."""
    for host in hosts:
        if (selector == "local" and host["ssh"] is None) or host["name"] == selector:
            return host
    raise ConfigError(f"no configured host named {selector!r}")


def slot_name(host):
    """The CI queue's slot key: "local" for this Mac, else the host name."""
    return "local" if host["ssh"] is None else host["name"]


# --- Remote facts (#4507 §3.1). Every SSH call: batch mode, strict host keys. ---
SSH_OPTIONS = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=5"]
PROBE_TTL = 60


def ssh_command(host, remote_command):
    return ["ssh", *SSH_OPTIONS, host["ssh"], remote_command]


def mount_check_script(host):
    """Shell that exits 0 only when the work root lies on the required mount.

    The mount must be a mount point (listed by /sbin/mount), on a device other than
    the system volume, and the root must resolve beneath it. Runs before any remote
    write, and again on the remote under the job lock. Exit 41: not mounted;
    42: same device as /; 43: root not beneath the mount."""
    import shlex
    root, mount = host["root"], host.get("requires_mount")
    if mount is None:
        return f"case {shlex.quote(root)} in /*) exit 0;; *) exit 43;; esac"
    m, r = shlex.quote(mount), shlex.quote(root)
    return (f"/sbin/mount | /usr/bin/grep -qF \" on \"{m}\" (\" || exit 41; "
            f"[ \"$(/usr/bin/stat -f %d {m})\" != \"$(/usr/bin/stat -f %d /)\" ] || exit 42; "
            f"case {r}/ in {m}/*) ;; *) exit 43;; esac; "
            f"[ ! -e {r} ] || [ \"$(/usr/bin/stat -f %d {r})\" = \"$(/usr/bin/stat -f %d {m})\" ] || exit 43")


def local_xcode_build():
    import subprocess
    out = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if line.startswith("Build version "):
            return line.split(" ", 2)[2].strip()
    return None


def probe(host, cache_dir=None, now=None):
    """Reachability, mount, Xcode build and free space for one remote host.

    Cached for PROBE_TTL seconds in cache_dir. A cached success only orders hosts;
    it never authorizes a remote write (the dispatcher and the remote supervisor
    re-check before writing)."""
    import shlex
    import subprocess
    import time as _time
    now = _time.time() if now is None else now
    cache = None if cache_dir is None else Path(cache_dir) / "probe.json"
    if cache is not None:
        try:
            cached = json.loads(cache.read_text())
            if now - cached.get("at", 0) < PROBE_TTL:
                return cached["facts"]
        except (OSError, ValueError, KeyError, TypeError):
            pass
    script = (f"( {mount_check_script(host)} ); m=$?; "
              "b=$(/usr/bin/xcodebuild -version 2>/dev/null | /usr/bin/sed -n 's/^Build version //p'); "
              f"f=$(/bin/df -g {shlex.quote(host.get('requires_mount') or '/')} 2>/dev/null | /usr/bin/awk 'NR==2{{print $4}}'); "
              "printf 'mount=%s\\nxcode=%s\\nfree_gb=%s\\n' \"$m\" \"$b\" \"$f\"")
    try:
        result = subprocess.run(ssh_command(host, script), capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired:
        facts = {"reachable": False, "reason": "ssh timed out"}
    else:
        values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
        if result.returncode != 0 or "mount" not in values:
            facts = {"reachable": False, "reason": (result.stderr.strip().splitlines() or ["ssh failed"])[-1]}
        else:
            reasons = {"0": None, "41": "work drive not mounted", "42": "work drive is the system disk",
                       "43": "work root is not on the work drive"}
            facts = {"reachable": True, "mount_ok": values["mount"] == "0",
                     "reason": reasons.get(values["mount"], f"mount check exit {values['mount']}"),
                     "xcode_build": values.get("xcode") or None,
                     "root_free_gb": int(values["free_gb"]) if values.get("free_gb", "").isdigit() else None}
    if cache is not None:
        try:
            cache.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            tmp = cache.with_name(f"probe.json.{os.getpid()}.tmp")
            tmp.write_text(json.dumps({"at": now, "facts": facts}))
            os.replace(tmp, cache)
        except OSError:
            pass
    return facts


def audio_free_suites(path=None):
    """The suites AUDIO_FREE_LIST names, as "Target/Suite". Raises ConfigError when the file
    is missing, unreadable or not exactly schema 1."""
    path = AUDIO_FREE_LIST if path is None else Path(path)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ConfigError(f"cannot read {path}: {error}") from None
    if not isinstance(data, dict) or set(data) != {"schema", "about", "suites"} or data["schema"] != 1:
        raise ConfigError(f'{path}: top level must be exactly {{"schema": 1, "about": ..., "suites": [...]}}')
    if not isinstance(data["suites"], list):
        raise ConfigError(f"{path}: suites must be a list")
    suites = set()
    for index, entry in enumerate(data["suites"]):
        if (not isinstance(entry, dict) or set(entry) != {"suite", "file"}
                or not isinstance(entry["suite"], str) or not isinstance(entry["file"], str)
                or not re.fullmatch(r"[A-Za-z0-9_]+/[A-Za-z0-9_.]+", entry["suite"])
                or not entry["file"].startswith("Tests/") or not entry["file"].endswith(".swift")):
            raise ConfigError(f'{path}: suites[{index}] must be {{"suite": "Target/Suite", "file": "Tests/....swift"}}')
        suites.add(entry["suite"])
    return suites


def needs_real_audio(filters, listed):
    """(needs, reason) for a real-boundary run with these test filters. Only a filtered run
    whose every filter names a listed suite (or a test inside one) needs no live audio device;
    an unfiltered run includes the microphone suites."""
    if not filters:
        return True, "an unfiltered real-boundary run includes suites that need a microphone"
    for raw in filters:
        selection = raw[len("-only-testing:"):] if raw.startswith("-only-testing:") else raw
        parts = selection.split("/")
        suite = "/".join(parts[:2]) if len(parts) >= 2 and all(parts[:2]) else None
        if suite not in listed:
            return True, f"{selection} is not a suite listed in {AUDIO_FREE_LIST.name}"
    return False, f"every selected suite is listed in {AUDIO_FREE_LIST.name}"


def eligible_ci(hosts, *, need_real, local_build, probe_fn):
    """CI hosts in order: the local host first when it takes CI work, then each
    remote that is reachable, has its work drive, the same Xcode build as this
    Mac, and (for real-boundary runs) real audio. Returns (eligible, skipped)."""
    eligible, skipped = [], []
    for host in hosts:
        if "ci" not in host["kinds"]:
            continue
        if need_real and host["audio"] != "real":
            skipped.append((host["name"], "no real audio for a real-boundary run"))
            continue
        if host["ssh"] is None:
            eligible.append(host)
            continue
        facts = probe_fn(host)
        if not facts.get("reachable"):
            skipped.append((host["name"], facts.get("reason") or "unreachable"))
        elif not facts.get("mount_ok"):
            skipped.append((host["name"], facts.get("reason") or "work drive unavailable"))
        elif facts.get("xcode_build") != local_build:
            skipped.append((host["name"], f"Xcode build {facts.get('xcode_build')} differs from {local_build}"))
        else:
            eligible.append(host)
    return eligible, skipped


def self_test():
    failures = []
    ran = []

    def check(label, ok):
        ran.append(label)
        if not ok:
            failures.append(label)

    hosts, sha = load(Path("/nonexistent/ew-mac-hosts.json"))
    check("absent config is one local host", len(hosts) == 1 and hosts[0]["ssh"] is None and sha == "none")
    good = json.dumps({"schema": 1, "hosts": [
        {"name": "main", "ssh": None, "order": 0, "kinds": ["ci"], "ci_workers": 4, "audio": "real"},
        {"name": "spare", "display": "Spare", "ssh": "spare-host", "order": 1, "kinds": ["ci"],
         "ci_workers": 2, "audio": "blackhole", "root": "/Volumes/X/ew",
         "requires_mount": "/Volumes/X", "repo_url": "https://example.invalid/r.git"}]})
    parsed = parse(good)
    check("valid config keeps order", [h["name"] for h in parsed] == ["main", "spare"])
    check("local selector finds the ssh:null host", resolve(parsed, "local")["name"] == "main")
    for label, bad in (
            ("two local hosts", good.replace('"ssh": "spare-host"', '"ssh": null')),
            ("unknown key", good.replace('"audio": "real"', '"audio": "real", "extra": 1')),
            ("workers out of range", good.replace('"ci_workers": 2', '"ci_workers": 5')),
            ("not json", good[:-1]),
            ("remote host named local", good.replace('"name": "spare"', '"name": "local"'))):
        try:
            parse(bad)
            refused = False
        except ConfigError:
            refused = True
        check(f"{label} refused", refused)
    # Real-boundary audio: only filters that all name listed suites run without real audio.
    listed = {"EnviousWisprASRTests/Free"}
    for label, filters, expected in (
            ("unfiltered run needs real audio", [], True),
            ("listed suite needs none", ["EnviousWisprASRTests/Free"], False),
            ("test in a listed suite needs none", ["-only-testing:EnviousWisprASRTests/Free/run()"], False),
            ("one unlisted filter needs real audio", ["EnviousWisprASRTests/Free", "EnviousWisprTests/Mic"], True),
            ("target only needs real audio", ["EnviousWisprASRTests"], True),
            ("suite prefix is not the suite", ["EnviousWisprASRTests/FreeMore"], True),
            ("empty suite part needs real audio", ["EnviousWisprASRTests/"], True)):
        check(label, needs_real_audio(filters, listed)[0] is expected)
    blackhole = [h for h in parsed if h["audio"] == "blackhole"]
    reachable = lambda host: {"reachable": True, "mount_ok": True, "xcode_build": "B1"}
    check("a real-audio run skips a blackhole host",
          eligible_ci(blackhole, need_real=True, local_build="B1", probe_fn=reachable)[0] == [])
    check("an audio-free run may use a blackhole host",
          [h["name"] for h in eligible_ci(blackhole, need_real=False, local_build="B1",
                                          probe_fn=reachable)[0]] == ["spare"])
    import tempfile
    with tempfile.TemporaryDirectory() as folder:
        listing = Path(folder) / "list.json"
        listing.write_text(json.dumps({"schema": 1, "about": "x", "suites": [
            {"suite": "EnviousWisprASRTests/Free", "file": "Tests/EnviousWisprASRTests/Free.swift"}]}))
        check("the audio-free list reads", audio_free_suites(listing) == {"EnviousWisprASRTests/Free"})
        for label, bad in (
                ("list with unknown key", {"schema": 1, "about": "x", "suites": [], "extra": 1}),
                ("list entry without file", {"schema": 1, "about": "x", "suites": [{"suite": "A/B"}]}),
                ("list entry not Target/Suite", {"schema": 1, "about": "x", "suites": [
                    {"suite": "A", "file": "Tests/A/B.swift"}]}),
                ("list of another schema", {"schema": 2, "about": "x", "suites": []})):
            listing.write_text(json.dumps(bad))
            try:
                audio_free_suites(listing)
                refused = False
            except ConfigError:
                refused = True
            check(f"{label} refused", refused)
    check("the tracked audio-free list reads", isinstance(audio_free_suites(), set))
    for label in failures:
        print(f"FAIL: {label}")
    print(f"mac_hosts self-test: {len(ran) - len(failures)} of {len(ran)} checks passed")
    return 1 if failures else 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    try:
        if argv == ["list"]:
            hosts, sha = load()
            print(json.dumps({"config_sha256": sha, "hosts": hosts}, indent=2))
            return 0
        if argv == ["check-config"]:
            load()
            return 0
        if argv == ["local-workers"]:
            # This Mac's grouped-test worker budget (its host entry's ci_workers).
            hosts, _ = load()
            print(next(h["ci_workers"] for h in hosts if h["ssh"] is None))
            return 0
        if argv == ["sha"]:
            print(load()[1])
            return 0
        if argv[:1] == ["eligible-ci"] and (len(argv) == 1 or argv[1] == "--real"):
            # Remote CI hosts that may take this run, in order, one name per line;
            # the local host is always the caller's first slot and is not listed.
            hosts, _ = load()
            need_real = False
            if len(argv) > 1:
                # A real-boundary run: real audio unless every filter names a listed suite.
                # An unreadable list fails toward real audio, loudly.
                try:
                    need_real, reason = needs_real_audio(argv[2:], audio_free_suites())
                except ConfigError as error:
                    need_real, reason = True, f"audio-free list unusable: {error}"
                print(f"==> real-boundary run needs real audio: {'yes' if need_real else 'no'} ({reason})",
                      file=sys.stderr)
            remotes = [h for h in hosts if h["ssh"] is not None]
            if not remotes:
                return 0
            build = local_xcode_build()
            def probe_fn(host):
                folder = (Path(pwd.getpwuid(os.getuid()).pw_dir)
                          / "Library/Caches/EnviousWispr/local-ci/hosts" / host["name"])
                return probe(host, cache_dir=folder)

            eligible, skipped = eligible_ci(hosts, need_real=need_real,
                                            local_build=build, probe_fn=probe_fn)
            for name, reason in skipped:
                print(f"==> {name} is not used for this run: {reason}", file=sys.stderr)
            for host in eligible:
                if host["ssh"] is not None:
                    print(host["name"])
            return 0
    except ConfigError as error:
        print(f"ERROR: Mac host config {CONFIG_PATH}: {error}", file=sys.stderr)
        return 2
    print("usage: mac_hosts.py list|check-config|sha|local-workers|eligible-ci [--real [FILTER ...]]|--self-test", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
