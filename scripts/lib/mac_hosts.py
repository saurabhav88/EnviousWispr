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
        if argv == ["sha"]:
            print(load()[1])
            return 0
    except ConfigError as error:
        print(f"ERROR: Mac host config {CONFIG_PATH}: {error}", file=sys.stderr)
        return 2
    print("usage: mac_hosts.py list|check-config|sha|--self-test", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
