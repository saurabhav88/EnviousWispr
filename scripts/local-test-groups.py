#!/usr/bin/env python3
"""Overlap reviewed source checks with serial stateful tests (#4056).

Execution and verdicts stay in lib/xcode-test-run.sh. This owner coordinates
processes, derives complementary selections, and preserves a complete result.
No app-state suite runs concurrently with another app-state suite.
"""

import argparse
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import unquote, urlsplit


# Exact suite types, not tags or filenames. The credential file also contains
# key-writing suites, and TestInventoryFreezeTests has a baseline writer. Neither
# belongs in the source group. New/unlisted suites remain in the serial group.
SOURCE_SUITES = (
    "DesktopEffectIsolationFreezeTests",
    "ProviderSetupCredentialOwnershipTests",
    "SettingsMapRegistrationTests",
    "SentryScopeWriterFreezeTests",
)
TARGET = "EnviousWisprTests"
REQUIRED = f"{TARGET} EnviousWisprDesktopEffectsTests EnviousWisprASRTests"
# Existing owned-process termination precedent: scripts/mutation-battery.py.
TERMINATION_GRACE_SECONDS = 10
SIGNALS = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM, signal.SIGQUIT)


def inventory(payload):
    """Keep case identities/results AND parameter rows, without run URL prefixes."""
    if not isinstance(payload, dict) or not isinstance(payload.get("testNodes"), list):
        raise ValueError("result payload has no testNodes array")
    found = {}

    def arguments(node):
        return tuple((child.get("nodeType"), child.get("name"), child.get("result"),
                      arguments(child)) for child in node.get("children") or []
                     if child.get("nodeType") != "Failure Message")

    def walk(node, target=None):
        if not isinstance(node, dict):
            raise ValueError("invalid result node")
        if node.get("nodeType") == "Unit test bundle":
            target = node.get("name")
        if node.get("nodeType") == "Test Case":
            if not isinstance(target, str) or not target:
                raise ValueError("test case has no bundle identity")
            url = node.get("nodeIdentifierURL")
            if url:
                parts = unquote(urlsplit(url).path).strip("/").split("/")
                if target not in parts:
                    raise ValueError(f"test URL does not name {target}: {url}")
                identity = "/".join(parts[parts.index(target):])
            else:
                name = node.get("nodeIdentifier")
                if not isinstance(name, str) or not name:
                    raise ValueError("test case has no identifier")
                identity = name if name.startswith(target + "/") else target + "/" + name
            if identity in found:
                raise ValueError(f"duplicate test case: {identity}")
            found[identity] = (node.get("result"), arguments(node))
            return
        for child in node.get("children") or []:
            walk(child, target)

    for root in payload["testNodes"]:
        walk(root)
    if not found:
        raise ValueError("result contains no test cases")
    return found


def read_inventory(bundle):
    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)],
        check=True, capture_output=True, text=True)
    return inventory(json.loads(result.stdout))


def check_partition(source, remainder):
    selected = {f"{TARGET}/{suite}" for suite in SOURCE_SUITES}
    source_suites = {"/".join(identity.split("/")[:2]) for identity in source}
    remaining_suites = {"/".join(identity.split("/")[:2]) for identity in remainder}
    if source_suites != selected:
        raise ValueError(f"source suite membership differs: missing={sorted(selected - source_suites)}, "
                         f"unexpected={sorted(source_suites - selected)}")
    if selected & remaining_suites:
        raise ValueError(f"source suites also ran in the serial group: {sorted(selected & remaining_suites)}")
    if source.keys() & remainder.keys():
        raise ValueError("test identities overlap between groups")


def observed_exit(proc):
    """Observe completion WITHOUT releasing this child's reserved PID/PGID."""
    status = os.waitid(os.P_PID, proc.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    if status is None:
        return None
    if status.si_code == os.CLD_EXITED:
        return status.si_status
    if status.si_code in (os.CLD_KILLED, os.CLD_DUMPED):
        return -status.si_status
    raise RuntimeError(f"unexpected child exit state: {status}")


def signal_owned_group(proc, sig):
    try:
        os.killpg(proc.pid, sig)
    except ProcessLookupError:
        pass
    except PermissionError:
        # Darwin reports EPERM for a group containing only zombies. Accept
        # that state only after a complete census positively establishes it;
        # a terminated leader alone says nothing about its descendants.
        if observed_exit(proc) is None:
            raise
        output = subprocess.check_output(["ps", "-axo", "pid=,pgid=,stat="], text=True)
        members = []
        for line in output.splitlines():
            pid, pgid, state = line.split()
            if int(pgid) == proc.pid:
                members.append((int(pid), state))
        if (not any(pid == proc.pid for pid, _ in members)
                or any(not state.startswith("Z") for _, state in members)):
            raise


def stop_children(children):
    """Stop only sessions created by this supervisor, then reap their leaders."""
    # Signal handlers only record cancellation. Cleanup cannot be interrupted by
    # another handled signal, nor can a signal interrupt spawn before registration.
    failures = []
    for proc in children:
        try:
            signal_owned_group(proc, signal.SIGTERM)
        except Exception as error:
            failures.append(error)
    try:
        deadline = time.monotonic() + TERMINATION_GRACE_SECONDS
        for proc in children:
            while observed_exit(proc) is None and time.monotonic() < deadline:
                time.sleep(0.01)
    finally:
        # Even a completed leader remains an unreaped child until ALL group
        # signalling is finished. Its PID cannot be reused by another session
        # during a long wait for the other group. Reaping it in poll()/wait()
        # earlier would make a later killpg target a potentially unrelated job.
        for proc in children:
            try:
                signal_owned_group(proc, signal.SIGKILL)
            except Exception as error:
                failures.append(error)
        for proc in children:
            proc.wait()
    if failures:
        raise RuntimeError(f"owned group cleanup failed: {failures}")


def run_groups(opts):
    required = ("P_PID", "WEXITED", "WNOHANG", "WNOWAIT", "CLD_EXITED", "CLD_KILLED", "CLD_DUMPED")
    if not callable(getattr(os, "waitid", None)) or any(not hasattr(os, key) for key in required):
        raise RuntimeError("local test groups require POSIX waitid with WNOWAIT")
    root = Path(__file__).resolve().parent.parent
    output = Path(opts.result_bundle)
    log = Path(opts.log)
    if output.exists():
        raise ValueError(f"result already exists: {output}")
    group_dir = Path(tempfile.mkdtemp(prefix="test-groups-", dir=log.parent))
    selectors = [f"{TARGET}/{suite}" for suite in SOURCE_SUITES]
    groups = (
        ("source", TARGET, ["-only-testing:" + name for name in selectors]),
        ("serial", REQUIRED, ["-skip-testing:" + name for name in selectors]),
    )
    cancelled = []

    def cancel(signum, _frame):
        # Never raise here: Popen must finish and register its owned process
        # before cancellation can unwind. This closes the spawn/signal window.
        if not cancelled:
            cancelled.append(signum)

    previous = {sig: signal.signal(sig, cancel) for sig in SIGNALS}
    # Explicit SIG_IGN would auto-reap children. Keep this single-purpose
    # supervisor's children waitable until owned-group cleanup is complete.
    previous[signal.SIGCHLD] = signal.signal(signal.SIGCHLD, signal.SIG_DFL)
    children, handles = [], []
    try:
        for name, required, args in groups:
            if cancelled:
                raise InterruptedError(f"interrupted by signal {cancelled[0]}")
            prefix = group_dir / name
            app_log = group_dir / (name + "-app-log")
            app_log.mkdir()
            env = dict(os.environ, TEST_RUNNER_EW_APP_LOG_DIRECTORY=str(app_log),
                       TEST_RUNNER_CI=os.environ.get("CI", ""))
            handle = (group_dir / (name + "-driver.log")).open("w")
            handles.append(handle)
            command = [
                "bash", "-c", '. "$1"; shift; ew_run_tests "$@"', "local-test-group",
                str(root / "scripts/lib/xcode-test-run.sh"), opts.products, opts.scheme,
                str(prefix), f"Debug {name} group", required,
                "-parallel-testing-enabled", "NO", *args,
            ]
            print(f"==> Debug {name} group: {prefix}.log", flush=True)
            children.append(subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.DEVNULL,
                                             stdout=handle, stderr=subprocess.STDOUT,
                                             start_new_session=True))
        pending = set(range(len(children)))
        while pending:
            if cancelled:
                raise InterruptedError(f"interrupted by signal {cancelled[0]}")
            for index in tuple(pending):
                rc = observed_exit(children[index])
                if rc is None:
                    continue
                pending.remove(index)
                name = groups[index][0]
                driver = group_dir / (name + "-driver.log")
                if rc:
                    detail = "\n".join(driver.read_text(errors="replace").splitlines()[-25:])
                    raise RuntimeError(f"Debug {name} group failed (exit {rc}):\n{detail}")
                print(f"==> Debug {name} group completed", flush=True)
            if pending:
                time.sleep(0.05)
        if cancelled:
            raise InterruptedError(f"interrupted by signal {cancelled[0]}")
        source = read_inventory(group_dir / "source.xcresult")
        remainder = read_inventory(group_dir / "serial.xcresult")
        check_partition(source, remainder)
        if cancelled:
            raise InterruptedError(f"interrupted by signal {cancelled[0]}")
        subprocess.run(["xcrun", "xcresulttool", "merge", "--output-path", str(output),
                        str(group_dir / "source.xcresult"), str(group_dir / "serial.xcresult")], check=True)
        merged = read_inventory(output)
        if merged != source | remainder:
            raise ValueError("merged result does not preserve every original test case and parameter result")
        if cancelled:
            raise InterruptedError(f"interrupted by signal {cancelled[0]}")
        with log.open("wb") as combined:
            for name, _, _ in groups:
                with (group_dir / (name + ".log")).open("rb") as part:
                    shutil.copyfileobj(part, combined)
        print(f"==> Debug groups: {len(source)} source + {len(remainder)} serial test cases; "
              "all results preserved", flush=True)
    finally:
        # Reap owned groups before the parent runner can release its validation
        # lock, including launch/parse/merge failures and top-level cancellation.
        original_error = sys.exc_info()[1]
        try:
            stop_children(children)
        except BaseException:
            if original_error is not None:
                print(f"ERROR: original test group failure: {original_error}", file=sys.stderr)
            raise
        finally:
            for handle in handles:
                handle.close()
            for sig, old in previous.items():
                signal.signal(sig, old)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products", required=True)
    parser.add_argument("--scheme", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--result-bundle", required=True)
    opts = parser.parse_args()
    started = time.monotonic()
    try:
        run_groups(opts)
    except BaseException as error:
        print(f"ERROR: Debug test groups: {error}", file=sys.stderr, flush=True)
        return 1
    print(f"==> phase debug grouped execution: {time.monotonic() - started:.3f}s", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
