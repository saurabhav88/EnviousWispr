#!/usr/bin/env python3
"""scripts/remote-dev-app.py: app testing (UAT) on a backup Mac (#4510).

When another session holds this Mac's dev app, a session claims a backup Mac's
app slot instead (hosts with kind "uat" in ~/.config/enviouswispr/mac-hosts.json,
in order), builds its own tree there and runs the usual UAT commands over SSH.

  remote-dev-app.py claim --label L [--host auto|local|NAME] [--need real]
  remote-dev-app.py status
  remote-dev-app.py build   [--host NAME]
  remote-dev-app.py push    [--host NAME] FILE       copy a clip; prints its remote path
  remote-dev-app.py run     [--host NAME] uat|dev-control [ARGS...]
  remote-dev-app.py fetch   [--host NAME] REMOTE_PATH  copy back to build/remote-uat/<host>/
  remote-dev-app.py keys    [--host NAME] set PROVIDER --secret NAME | clear PROVIDER
  remote-dev-app.py release [--host NAME]
  remote-dev-app.py --self-test

Holds use the unmodified main-checkout scripts/lib/dev-app-lock.py, pointed at
~/Library/Caches/EnviousWispr/dev-app-lock-hosts/<host> (same identity, exit
codes 0 ok / 2 undecided / 3 held). `--host` defaults to the backup host this
session holds; every remote action refuses without that hold. Exit 4: the host
cannot be reached or set up. Recipes are names, not paths, so the Codex hook's
local-UAT route does not apply. Keys come from GCP through get-key and are piped
to the host's dev_control.py stdin; they are never printed, put in argv or
written to a file by this tool. Clear a key after its test.
"""
import argparse
import contextlib
import importlib.util
import io
import os
import shlex
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts/lib"))
import mac_hosts  # noqa: E402
import remote_ship  # noqa: E402

HOST_LOCKS = Path.home() / "Library/Caches/EnviousWispr/dev-app-lock-hosts"
GET_KEY = Path.home() / ".claude/bin/get-key"
RECIPES = {"uat": "Tests/RuntimeUAT/uat.py", "dev-control": "Tests/RuntimeUAT/dev_control.py"}
KEY_ENV = "EW_REMOTE_DEV_APP_KEY"
OK, UNDECIDED, HELD, SETUP = 0, 2, 3, 4
_LOCK = None


class SetupError(Exception):
    pass


def main_checkout():
    out = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise SetupError("cannot find the main checkout (git rev-parse failed)")
    return Path(out.stdout.strip()).parent


def lock_module():
    """The machine-wide lock owner, loaded from the MAIN checkout, never edited."""
    global _LOCK
    if _LOCK is None:
        path = main_checkout() / "scripts/lib/dev-app-lock.py"
        spec = importlib.util.spec_from_file_location("dev_app_lock_for_hosts", path)
        _LOCK = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_LOCK)
    return _LOCK


def host_lock(name, argv, quiet=False):
    """Run the lock owner's own CLI against one backup host's folder."""
    mod = lock_module()
    folder = HOST_LOCKS / name
    folder.mkdir(parents=True, exist_ok=True)
    saved = mod.LOCK_DIR
    mod.LOCK_DIR = str(folder)
    try:
        if quiet:
            with contextlib.redirect_stdout(io.StringIO()):
                return mod.main(argv)
        return mod.main(argv)
    finally:
        mod.LOCK_DIR = saved


def local_lock(argv):
    path = main_checkout() / "scripts/lib/dev-app-lock.py"
    return subprocess.run([sys.executable, str(path), *argv]).returncode


def backups(need_real=False):
    hosts, _ = mac_hosts.load()
    return [h for h in hosts if h["ssh"] is not None and "uat" in h["kinds"]
            and (not need_real or h["audio"] == "real")]


def held_host():
    for host in backups():
        if host_lock(host["name"], ["check"], quiet=True) == OK:
            return host
    return None


def claim(label, selector, need_real):
    if selector in ("auto", "local"):
        rc = local_lock(["claim", "--label", label, "--worktree", str(ROOT)])
        if rc == OK:
            print("HOST=local")
            return OK
        if selector == "local" or rc != HELD:
            return rc
    already = held_host()
    if already is not None:
        wrong_host = selector not in ("auto", "local") and selector != already["name"]
        if wrong_host or (need_real and already["audio"] != "real"):
            print(f"==> this session holds {already['name']}, which does not fit this request; "
                  "release it first: scripts/remote-dev-app.py release")
            return HELD
        print(f"==> this session already holds {already['name']} (one backup host at a time)")
        print(f"HOST={already['name']}")
        return OK
    candidates = backups(need_real)
    if selector not in ("auto", "local"):
        candidates = [h for h in candidates if h["name"] == selector]
        if not candidates:
            raise SetupError(f"host '{selector}' is not a backup host with kind uat"
                             + (" and real audio" if need_real else ""))
    if not candidates:
        print("==> no backup Mac can take app testing" + (" with a real microphone" if need_real else ""))
        return HELD
    rc = HELD
    for host in candidates:
        rc = host_lock(host["name"], ["claim", "--label", label, "--worktree", str(ROOT)])
        if rc == OK:
            print(f"HOST={host['name']}")
            return OK
    return rc


def require(selector):
    """The backup host this session holds; anything else is refused."""
    if selector:
        hosts, _ = mac_hosts.load()
        host = mac_hosts.resolve(hosts, selector)
        if host["ssh"] is None:
            raise SetupError("this Mac's dev app is not a remote target; use the local tools")
    else:
        host = held_host()
        if host is None:
            print("==> claim a backup Mac first: scripts/remote-dev-app.py claim --label <task>")
            sys.exit(HELD)
    if host_lock(host["name"], ["check"], quiet=True) != OK:
        with contextlib.redirect_stdout(sys.stderr):
            host_lock(host["name"], ["status"])
        print(f"==> this session does not hold {host['name']}; claim it first", file=sys.stderr)
        sys.exit(HELD)
    return host


def checkout(host):
    return f"{host['root']}/EnviousWispr-uat"


def ssh(host, script, input_bytes=None, stream=False, timeout=None):
    cmd = mac_hosts.ssh_command(host, script)
    if stream:
        return subprocess.run(cmd, input=input_bytes, timeout=timeout)
    return subprocess.run(cmd, input=input_bytes, capture_output=True, timeout=timeout)


def mount_ok(host):
    r = ssh(host, f"( {mac_hosts.mount_check_script(host)} ) || exit $?", timeout=60)
    if r.returncode != 0:
        raise SetupError({41: "work drive not mounted", 42: "work drive is the system disk",
                          43: "work root is not on the work drive"}.get(
                              r.returncode, (r.stderr or b"").decode(errors="replace").strip()
                              or f"cannot reach {host['name']}"))


def build(host):
    mount_ok(host)
    tree = remote_ship.dev_snapshot_tree(ROOT)
    remote_ship.refuse_unsupported(ROOT, tree)
    run_id = uuid.uuid4().hex
    q = shlex.quote
    co = checkout(host)
    b = f"{host['root']}/uat-inputs/{run_id}.bundle"
    ref = None
    with tempfile.TemporaryDirectory(prefix="ew-uat-") as tmp:
        local = Path(tmp) / "uat.bundle"
        try:
            commit, ref, _ = remote_ship.make_bundle(ROOT, tree, run_id, local)
            # The old stamp goes first, so a build that fails never looks like this tree.
            fetch_script = (f"set -e; C={q(co)}; B={q(b)}; "
                            f"[ -d \"$C/.git\" ] || git clone -q {q(host['repo_url'])} \"$C\"; cd \"$C\"; "
                            "rm -f .ew-uat-tree; "
                            "git bundle verify -q \"$B\" >/dev/null 2>&1 || { rm -f \"$B\"; exit 47; }; "
                            f"git fetch -q \"$B\" {q(ref + ':' + ref)}; rm -f \"$B\"; "
                            f"git checkout -q --detach {q(commit)}; git update-ref -d {q(ref)}; "
                            "git clean -q -ffdx -e .derivedData -e build")
            for attempt in (1, 2):
                r = ssh(host, f"mkdir -p {q(host['root'] + '/uat-inputs')}", timeout=60)
                if r.returncode == 0:
                    r = subprocess.run(["scp", "-q", *mac_hosts.SSH_OPTIONS, str(local), f"{host['ssh']}:{b}"],
                                       capture_output=True, timeout=600)
                if r.returncode != 0:
                    raise SetupError("could not copy the code to " + host["name"])
                r = ssh(host, fetch_script, timeout=600)
                if r.returncode == 47 and attempt == 1:
                    remote_ship.full_bundle(ROOT, ref, local)  # that checkout lacks newer main commits
                    continue
                break
            if r.returncode != 0:
                raise SetupError({47: "the code bundle could not be verified there"}.get(
                    r.returncode, (r.stderr or b"").decode(errors="replace").strip()
                    or f"checkout step exit {r.returncode}"))
        finally:
            if ref:
                remote_ship.drop_ref(ROOT, ref)
    print(f"==> {host['name']}: building development snapshot tree {tree}", flush=True)
    script = (f"cd {q(co)} && "
              # Signing over SSH needs the host's dedicated signing keychain unlocked
              # (same step as remote-job.py); its password file is never printed.
              "K=\"$HOME/Library/Keychains/ew-dev.keychain-db\"; P=\"$HOME/.config/ew-dev-keychain-pass\"; "
              "if [ -f \"$K\" ]; then security unlock-keychain -p \"$(cat \"$P\")\" \"$K\" || exit 49; fi; "
              f"bash scripts/build-dev-app.sh && printf '%s\\n' {q(tree)} > .ew-uat-tree")
    return ssh(host, script, stream=True).returncode


def warn_if_stale(host):
    r = ssh(host, f"cat {shlex.quote(checkout(host) + '/.ew-uat-tree')} 2>/dev/null", timeout=60)
    built = (r.stdout or b"").decode().strip()
    try:
        mine = remote_ship.dev_snapshot_tree(ROOT)
    except remote_ship.ShipError:
        mine = ""
    if not built:
        print(f"==> warning: no build of yours on {host['name']}; run: scripts/remote-dev-app.py build", flush=True)
    elif built != mine:
        print(f"==> warning: {host['name']} runs tree {built[:12]}, not this checkout's {mine[:12]}; "
              "run build first to test your code", flush=True)


def run(host, recipe, args):
    if recipe not in RECIPES:
        raise SetupError(f"unknown recipe '{recipe}' (use: {', '.join(RECIPES)})")
    warn_if_stale(host)
    q = shlex.quote
    script = f"cd {q(checkout(host))} && python3 {RECIPES[recipe]} " + " ".join(q(a) for a in args)
    return ssh(host, script, stream=True).returncode


def push(host, path):
    local = Path(path)
    if not local.is_file():
        raise SetupError(f"no such file: {path}")
    mount_ok(host)  # never write a clip onto the host's system disk
    q = shlex.quote
    folder = f"{host['root']}/uat-inputs/{uuid.uuid4().hex}"
    remote = f"{folder}/{local.name}"
    r = ssh(host, f"mkdir -p {q(folder)}", timeout=60)
    if r.returncode == 0:
        r = subprocess.run(["scp", "-q", *mac_hosts.SSH_OPTIONS, str(local), f"{host['ssh']}:{remote}"],
                           capture_output=True, timeout=600)
    if r.returncode != 0:
        raise SetupError(f"could not copy {local.name} to {host['name']}")
    print(remote)
    return OK


def fetch(host, remote_path):
    dest = ROOT / "build/remote-uat" / host["name"]
    dest.mkdir(parents=True, exist_ok=True)
    r = subprocess.run(["scp", "-q", "-r", *mac_hosts.SSH_OPTIONS, f"{host['ssh']}:{remote_path}", str(dest)],
                       capture_output=True, timeout=600)
    if r.returncode != 0:
        raise SetupError(f"could not fetch {remote_path}: {r.stderr.decode(errors='replace').strip()}")
    print(dest / Path(remote_path).name)
    return OK


def keys_set(host, provider, secret):
    """get-key exposes the key to our child only; the child pipes it to the host's stdin."""
    me = [sys.executable, str(Path(__file__).resolve()), "--feed-key", provider, "--host", host["name"]]
    return subprocess.run([str(GET_KEY), "launch", secret, KEY_ENV, "--", *me]).returncode


def feed_key(provider, host_name):
    key = os.environ.pop(KEY_ENV, "")
    if not key:
        print("==> no key was handed over by get-key", file=sys.stderr)
        return UNDECIDED
    host = require(host_name)
    script = (f"cd {shlex.quote(checkout(host))} && python3 {RECIPES['dev-control']} keys set "
              f"{shlex.quote(provider)}")
    r = ssh(host, script, input_bytes=(key + "\n").encode(), timeout=120)
    del key
    sys.stdout.write((r.stdout or b"").decode(errors="replace"))
    sys.stderr.write((r.stderr or b"").decode(errors="replace"))
    return r.returncode


def keys_clear(host, provider):
    script = (f"cd {shlex.quote(checkout(host))} && python3 {RECIPES['dev-control']} keys clear "
              f"{shlex.quote(provider)}")
    return ssh(host, script, stream=True, timeout=120).returncode


def status():
    print("this Mac:", end=" ", flush=True)
    local_lock(["status"])
    for host in backups():
        print(f"{host['name']}:", end=" ", flush=True)
        host_lock(host["name"], ["status"])
    return OK


def parse(argv):
    p = argparse.ArgumentParser(prog="remote-dev-app.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("claim")
    c.add_argument("--label", required=True)
    c.add_argument("--host", default="auto")
    c.add_argument("--need", choices=["real"], default=None)
    sub.add_parser("status")
    for name in ("build", "release"):
        sub.add_parser(name).add_argument("--host", default=None)
    for name, arg in (("push", "file"), ("fetch", "remote_path")):
        s = sub.add_parser(name)
        s.add_argument("--host", default=None)
        s.add_argument(arg)
    r = sub.add_parser("run")
    r.add_argument("--host", default=None)
    r.add_argument("recipe")
    r.add_argument("args", nargs=argparse.REMAINDER)
    k = sub.add_parser("keys")
    k.add_argument("--host", default=None)
    k.add_argument("action", choices=["set", "clear"])
    k.add_argument("provider")
    k.add_argument("--secret", default=None)
    return p.parse_args(argv)


def main(argv):
    if argv[:1] == ["--self-test"]:
        return self_test()
    if argv[:1] == ["--feed-key"] and len(argv) == 4 and argv[2] == "--host":
        return feed_key(argv[1], argv[3])
    args = parse(argv)
    try:
        if args.cmd == "claim":
            return claim(args.label, args.host, args.need == "real")
        if args.cmd == "status":
            return status()
        host = require(args.host)
        if args.cmd == "build":
            return build(host)
        if args.cmd == "push":
            return push(host, args.file)
        if args.cmd == "run":
            return run(host, args.recipe, args.args)
        if args.cmd == "fetch":
            return fetch(host, args.remote_path)
        if args.cmd == "keys":
            if args.action == "set":
                if not args.secret:
                    raise SetupError("keys set needs --secret NAME (a get-key secret name)")
                return keys_set(host, args.provider, args.secret)
            return keys_clear(host, args.provider)
        if args.cmd == "release":
            return host_lock(host["name"], ["release"])
    except (SetupError, remote_ship.ShipError, mac_hosts.ConfigError) as error:
        print(f"==> remote app testing SETUP FAILED: {error}", file=sys.stderr)
        return SETUP
    except subprocess.TimeoutExpired as error:
        print(f"==> remote app testing SETUP FAILED: timed out: {error}", file=sys.stderr)
        return SETUP
    return UNDECIDED


def self_test():
    """Claim order, the one-host limit and refusal without a hold, with fake lock
    folders, a fake host list and a stub local lock; nothing touches a real Mac."""
    global HOST_LOCKS, local_lock, backups
    import json
    results = []

    def case(name, ok):
        results.append(ok)
        print(f"{'ok  ' if ok else 'FAIL'} [{name}]")

    real_locks, real_local, real_backups = HOST_LOCKS, local_lock, backups
    # A fixed holder identity (this process), so the result does not depend on
    # whether the caller runs inside an agent session (a Terminal push, CI).
    mod = lock_module()
    real_find = mod.find_session
    me = {"kind": "claude", "pid": os.getpid(), "started": mod.process_info(os.getpid())[1]}
    mod.find_session = lambda native_session_id=None: me
    with tempfile.TemporaryDirectory(prefix="ew-remote-uat-test-") as tmp:
        HOST_LOCKS = Path(tmp) / "hosts"
        local_rc = {"rc": OK}
        local_lock = lambda argv: local_rc["rc"]  # noqa: E731
        fleet = [{"name": "m6", "ssh": "m6", "kinds": ["ci", "uat"], "audio": "blackhole"},
                 {"name": "m1", "ssh": "m1", "kinds": ["ci", "uat"], "audio": "real"}]
        backups = lambda need_real=False: [h for h in fleet if not need_real or h["audio"] == "real"]  # noqa: E731
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = claim("t", "auto", False)
            case("this Mac free: HOST=local", rc == OK and "HOST=local" in out.getvalue())
            local_rc["rc"] = HELD
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = claim("t", "auto", True)
            case("--need real skips a BlackHole-only host", rc == OK and "HOST=m1" in out.getvalue())
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = claim("t", "auto", False)
            case("one backup host per session: the held one is returned",
                 rc == OK and "HOST=m1" in out.getvalue() and "already holds" in out.getvalue())
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = claim("t", "m6", False)
            case("a held host that does not fit the request is refused, not reused",
                 rc == HELD and "release it first" in out.getvalue())
            with contextlib.redirect_stdout(io.StringIO()):
                host_lock("m1", ["release"])
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = claim("t", "auto", False)
            case("this Mac held: the first backup host in order", rc == OK and "HOST=m6" in out.getvalue())
            card = json.loads((HOST_LOCKS / "m6" / "holder.json").read_text())
            case("the hold uses the lock owner's own card", card.get("label") == "t" and "pid" in card)
            with contextlib.redirect_stdout(io.StringIO()):
                host_lock("m6", ["release"])
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    require(None)
                case("a remote action without a hold is refused", False)
            except SystemExit as stop:
                case("a remote action without a hold is refused", stop.code == HELD)
        finally:
            HOST_LOCKS, local_lock, backups = real_locks, real_local, real_backups
            mod.find_session = real_find
    src = Path(__file__).read_text()
    case("the key never reaches argv or a file: only stdin input_bytes", "input_bytes=(key" in src
         and "argv" not in src.split("def feed_key")[1].split("def keys_clear")[0])
    failed = results.count(False)
    print(f"remote-dev-app self-test: {len(results) - failed} of {len(results)} checks passed")
    return 0 if results and failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
