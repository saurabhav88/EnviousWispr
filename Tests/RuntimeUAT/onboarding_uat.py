#!/usr/bin/env python3
"""The new Setup's backend UAT through the real dev control door (#4528 chunk I1).

    python3 Tests/RuntimeUAT/onboarding_uat.py --self-test
    python3 Tests/RuntimeUAT/onboarding_uat.py run --artifacts <run folder> [--scenario NAME ...]
    python3 Tests/RuntimeUAT/onboarding_uat.py recover --artifacts <run folder>

WHAT IT PROVES. Setup's backend (coordinator, checkpoint, restore, runtime, simulation and
faults) driven with the same events Setup's buttons send, read back from the door's `status`
and the settings store. It does NOT prove Setup's screens, real permission prompts, a practice
dictation or the film: those are chunks D and E.

SETTINGS SAFETY (plan §3.11 M69). The dev build reads and writes EVERY `SettingsManager` key in
the shared suite `com.enviouswispr.app`, the founder's real store; other owners write
`com.enviouswispr.app.dev`. So before any change the harness:
1. refuses unless this caller holds the dev-app lock and exactly one dev app from THIS checkout
   runs (pid and executable pinned for every call);
2. exports both domains, typed (`defaults export`), into a private recovery file (0600) in the
   run folder, and refuses to start while an earlier recovery file is unresolved;
3. at the end (pass, failure or Ctrl-C) stops the door session, clears every simulation, QUITS
   the app the way a person does (an Apple Events quit, after re-verifying that the one running
   dev app is this checkout's pinned pid; never TERM or KILL), restores the keys in `ALLOWLIST`
   that changed, relaunches the same bundle and reads every key back from a fresh export.
A quit that does not finish stops the whole run with the recovery file kept (the app may still
write settings, so nothing is restored under it). A crash report written by the quit is an app
result: the run fails and the report is named in the receipt.
A changed key outside `ALLOWLIST` is a DISCOVERY: reported, never restored or ignored, and the
run fails until the plan classifies it. A restore that does not read back fails the run, and
the recovery file keeps its `recover` instructions.
"""

import argparse
import datetime
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import defaults_store  # noqa: E402
import dev_control  # noqa: E402

SHARED = "com.enviouswispr.app"
DEV = "com.enviouswispr.app.dev"
DOMAINS = (SHARED, DEV)

# Every key the enumerated Setup paths can write (plan §3.11 M69). Anything else that changes
# during a run is a discovery.
ALLOWLIST = {
    SHARED: {
        # onboardingState didSet, restartOnboarding, checkpoint writes.
        "onboardingState", "hasCompletedOnboarding", "ew.onboarding.everCompleted",
        "ew.onboarding.checkpoint.v1",
        # migrateMeetingSummaryEngineIfNeeded on completion (only when the key is absent).
        "meetingSummaryLLMProvider", "meetingSummaryLLMModel", "meetingSummaryOllamaModel",
        "meetingSummaryCloudModelByProvider",
        # writeLanguage, writeSelectedBackend, writePolishSelection, writeNonLocalPolish.
        "languageMode", "whisperKitLanguage", "selectedBackend", "llmProvider", "lastLLMProvider",
        "llmModel", "egOneSize", "cloudModelByProvider",
        # Consent, changed only by the telemetry suppression check.
        "shareUsageMetrics",
    },
    DEV: set(),
}

# App-owned records that launches and Apple Intelligence availability checks write on their own
# (round 0, plan M69): reported every run, never restored (that would revert the app's own
# history) and never a failure.
AMBIENT = {
    SHARED: set(),
    DEV: {"SULastCheckTime", "aiDiagnosticsHistory", "aiDiagnosticsLatestReport"},
}

HOLD_ENV = "EW_UAT_ONBOARDING_BACKEND"
# Every dev build shares this bundle id (tools-and-apps.md RULE: dev-bundle-id-collision), so
# the quit is sent only after proving the pinned pid is the ONLY running dev app.
DEV_BUNDLE_ID = "com.enviouswispr.app.dev"
RECOVERY = "onboarding-uat-recovery.plist"
RECEIPT = "onboarding-uat-receipt.json"
POLL = 0.5  # test-fixture-timer: the door has no push channel; status is read on this cadence


class HarnessError(Exception):
    """The harness cannot continue safely (setup, identity, ownership or restore)."""


class QuitFailed(HarnessError):
    """The app did not quit: the run stops and keeps its recovery file."""


CRASH_REPORTS = os.path.expanduser("~/Library/Logs/DiagnosticReports")
# Door calls that only read. Anything else counts as a change the run must clean up.
READ_ONLY_CALLS = {("onboarding", "status"), ("status",), ("meeting", "status"),
                   ("settings", "list")}


# ---------------------------------------------------------------------------------------------
# The recovery snapshot
# ---------------------------------------------------------------------------------------------

def _inside_git(path):
    got = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True)
    return got.returncode == 0


def recovery_path(artifacts):
    return os.path.join(artifacts, RECOVERY)


def take_snapshot(artifacts, domains=DOMAINS, export=defaults_store.export_domain):
    """Exports every domain into a private recovery file; refuses an unresolved earlier one."""
    if _inside_git(artifacts):
        raise HarnessError(f"{artifacts} is inside a git checkout; recovery data stays out of git")
    os.makedirs(artifacts, exist_ok=True)
    path = recovery_path(artifacts)
    if os.path.exists(path):
        with open(path, "rb") as fh:
            earlier = plistlib.load(fh)
        if not earlier.get("resolved"):
            raise HarnessError(
                f"an unresolved recovery snapshot exists at {path}; run `recover` first")
    snap = {
        "taken_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "resolved": False,
        "domains": {d: export(d) for d in domains},
        "recover": f"python3 {os.path.abspath(__file__)} recover --artifacts {artifacts}",
    }
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as fh:
        plistlib.dump(snap, fh)
    os.chmod(path, 0o600)
    return snap


def load_snapshot(artifacts):
    with open(recovery_path(artifacts), "rb") as fh:
        return plistlib.load(fh)


def mark_resolved(artifacts):
    path = recovery_path(artifacts)
    snap = load_snapshot(artifacts)
    snap["resolved"] = True
    snap["resolved_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    with open(path, "wb") as fh:
        plistlib.dump(snap, fh)


_ABSENT = object()


def changed_keys(before, after):
    """Keys whose presence, type or value differ (structural, `defaults_store` equality)."""
    keys = set(before) | set(after)
    out = set()
    for k in keys:
        a, b = before.get(k, _ABSENT), after.get(k, _ABSENT)
        if a is _ABSENT or b is _ABSENT:
            if a is not b:
                out.add(k)
        elif not defaults_store.same_plist_value(b, a):
            out.add(k)
    return out


def plan_restore(snap, now, allowlist=ALLOWLIST, ambient=None):
    """({domain: {key: value or None}}, {domain: [discovered keys]}); ambient keys (app-owned
    records, `AMBIENT`) are neither restored nor discoveries (see `ambient_changes`)."""
    ambient = AMBIENT if ambient is None else ambient
    restore, discoveries = {}, {}
    for domain, before in snap["domains"].items():
        changed = changed_keys(before, now[domain])
        allowed = allowlist.get(domain, set())
        restore[domain] = {k: before.get(k) for k in sorted(changed & allowed)}
        found = sorted(changed - allowed - ambient.get(domain, set()))
        if found:
            discoveries[domain] = found
    return restore, discoveries


def ambient_changes(snap, now, ambient=None):
    ambient = AMBIENT if ambient is None else ambient
    return {d: sorted(changed_keys(before, now[d]) & ambient.get(d, set()))
            for d, before in snap["domains"].items()}


def restore_keys(restore, restore_plist=defaults_store.restore_plist):
    """{domain: {key: landed}} after putting each key back exactly."""
    return {d: (restore_plist(d, keys) if keys else {}) for d, keys in restore.items()}


# ---------------------------------------------------------------------------------------------
# The app: one dev app from this checkout, pinned and quit by its verified pid
# ---------------------------------------------------------------------------------------------

class App:
    def __init__(self, worktree, boundaries=None):
        self.worktree = worktree
        self.boundaries = boundaries or dev_control.Boundaries()
        self.bundle = os.path.join(worktree, "build", "EnviousWispr Local.app")
        self.executable = os.path.join(self.bundle, "Contents", "MacOS", "EnviousWispr")
        self.client = None
        self.quit_failed = None
        self.crash_reports = []
        # True once a door call that can change the app or its settings was SENT (set before the
        # call, so a lost reply still counts as a change): only then does cleanup stop, quit and
        # relaunch it. Read-only calls never set it.
        self.mutated = False

    def _mine(self):
        return [int(p) for p, exe in self.boundaries.instances().items() if exe == self.executable]

    def attach(self):
        """Pins the one running dev app from this checkout; refuses anything else."""
        running = self.boundaries.instances()
        dev = {int(p): e for p, e in running.items()
               if e.endswith(dev_control.DEV_EXECUTABLE_SUFFIX)}
        mine = [p for p, e in dev.items() if e == self.executable]
        if len(dev) != 1 or len(mine) != 1:
            raise HarnessError(
                f"need exactly one dev app and it must be {self.executable}; running: {dev}")
        self.client = dev_control.DoorClient(mine[0], self.boundaries)
        return self.client

    def call(self, *argv):
        if tuple(argv) not in READ_ONLY_CALLS:
            self.mutated = True
        return self.client.call(list(argv))

    def quit(self, timeout=30.0):
        """Quits like a person (Apple Events `quit`, so the app's own termination runs) after
        re-verifying that the ONLY running dev app is the pinned pid from this checkout: the
        event is addressed by bundle id, which every dev build shares. Never TERM or KILL. A quit
        that does not finish raises `QuitFailed`; a crash report written by it is recorded."""
        if self.quit_failed:
            raise QuitFailed(self.quit_failed)
        pid = self.client.pid
        dev = {int(p): e for p, e in self.boundaries.instances().items()
               if e.endswith(dev_control.DEV_EXECUTABLE_SUFFIX)}
        if dev != {pid: self.executable}:
            raise HarnessError(f"refusing to quit: running dev apps {dev}, pinned {pid}")
        children = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True,
                                  text=True).stdout.split()
        started = time.time()
        sent = subprocess.run(
            ["osascript", "-e", f'tell application id "{DEV_BUNDLE_ID}" to quit'],
            capture_output=True, text=True)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and pid in self._mine():
            time.sleep(POLL)  # test-fixture-timer: a quit has no completion signal to wait on
        if pid in self._mine():
            self.quit_failed = (f"pid {pid} still running {timeout:.0f} s after a quit request "
                                f"(osascript rc={sent.returncode} {sent.stderr.strip()!r})")
            raise QuitFailed(self.quit_failed)
        alive = [c for c in children if _alive(int(c))]
        if alive:
            self.quit_failed = f"children of pid {pid} outlived the quit: {alive}"
            raise QuitFailed(self.quit_failed)
        self.crash_reports += new_crash_reports(started)
        self.client = None

    def launch(self, hold, timeout=60.0):
        """Opens this checkout's bundle (holding Setup for the door when `hold`), then pins it."""
        if self._mine():
            raise HarnessError("this checkout's app is already running; quit it first")
        argv = ["open", "-n", self.bundle]
        if hold:
            argv[2:2] = ["--env", f"{HOLD_ENV}=1"]
        subprocess.run(argv, check=True)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if len(self._mine()) == 1:
                try:
                    self.attach()
                    self.call("onboarding", "status")
                    return self.client
                except (HarnessError, dev_control.DoorRefused):
                    pass
            time.sleep(POLL)  # test-fixture-timer: waiting for the door socket after launch
        raise HarnessError(f"{self.bundle} did not answer the door within {timeout} s")


def _alive(pid):
    try:
        os.kill(pid, 0)  # signal 0: existence check only, nothing is sent
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def new_crash_reports(since, directory=CRASH_REPORTS):
    """EnviousWispr crash reports written at or after `since` (epoch seconds)."""
    try:
        names = os.listdir(directory)
    except FileNotFoundError:
        return []
    found = []
    for name in names:
        if name.startswith("EnviousWispr") and name.endswith((".ips", ".crash")):
            path = os.path.join(directory, name)
            if os.path.getmtime(path) >= since - 1:
                found.append(path)
    return sorted(found)


# ---------------------------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------------------------

class Scenario:
    def __init__(self, name):
        self.name = name
        self.checks = []
        self.notes = []
        self.uncovered = []

    def expect(self, ok, label, detail=None):
        self.checks.append({"check": label, "ok": bool(ok), "detail": detail})
        return ok

    def fixture(self, label):
        self.notes.append(f"FIXTURE (not a passed transition): {label}")

    @property
    def passed(self):
        return bool(self.checks) and all(c["ok"] for c in self.checks) and not self.uncovered

    def receipt(self):
        return {"scenario": self.name, "passed": self.passed, "checks": self.checks,
                "notes": self.notes, "uncovered": self.uncovered}


class Run:
    def __init__(self, app, artifacts):
        self.app = app
        self.artifacts = artifacts
        self.scenarios = []
        self.window = {"start": datetime.datetime.now(datetime.timezone.utc).isoformat()}

    def status(self):
        return self.app.call("onboarding", "status")

    def send(self, event, **kw):
        argv = ["onboarding", "send", event]
        for k, v in kw.items():
            argv += [f"--{k}", v]
        return self.app.call(*argv)

    def until(self, predicate, timeout, what):
        """The latest status once `predicate(status)` holds; the last status on timeout."""
        deadline = time.monotonic() + timeout
        st = self.status()
        while not predicate(st) and time.monotonic() < deadline:
            time.sleep(POLL)  # test-fixture-timer: status has no push channel
            st = self.status()
        return st

    def reset(self, s, why):
        s.fixture(f"onboarding reset ({why})")
        return self.app.call("onboarding", "reset")

    def walk_to_downloads(self, s, speech, polish_event=("skipPolish",)):
        """Welcome to Downloads with real send events; returns the last reply."""
        self.send("next")
        self.send("chooseLanguage", value="auto")
        self.send("next")
        self.send("chooseSpeech", value=speech)
        self.send("next")
        reply = self.send(*polish_event[:1], **(polish_event[1] if len(polish_event) > 1 else {}))
        s.expect(reply.get("step") == "downloads", "reached Downloads with real events",
                 reply.get("step"))
        return reply


def busy_reasons(call):
    """Why the app is busy with the person's own work, from read-only door calls only. Empty
    means the harness may start; anything else refuses before any change (plan M69 (d))."""
    reasons = []
    st = call("status")
    driver = (st.get("activeDriver") or {}).get("state")
    if driver not in ("idle", "complete", "error", "advisory"):
        reasons.append(f"dictation is {driver}")
    if st.get("fileImportRunning"):
        reasons.append("a file import is running")
    meeting = call("meeting", "status")
    phase = (meeting.get("phase") or {}).get("name")
    if phase != "idle":
        reasons.append(f"a meeting is {phase}")
    if meeting.get("processing"):
        reasons.append("a meeting is still processing")
    ob = call("onboarding", "status")
    if ob.get("legacyWindowVisible") or ob.get("legacyTasks"):
        reasons.append("the old onboarding is open or working")
    return reasons


def settled_catalog(run, timeout=30):
    """The door's read-only phase catalog once no entry is still resolving (a just-launched
    owner may not have reported yet). Reading it never chooses or downloads anything."""
    def settled(st):
        cat = st.get("catalog") or {}
        phases = list((cat.get("speech") or {}).values()) + list((cat.get("polish") or {}).values())
        return bool(cat) and not any(p in ("unknown", "verifying") for p in phases)
    return run.until(settled, timeout, "phase catalog").get("catalog") or {}


def installed_speech(run, observed):
    """The speech engine already on this Mac, from the door's read-only catalog: nothing is
    chosen, so a Mac missing an engine never starts its download here (plan M69 (a)). Every
    engine's phase is recorded in `observed` for the receipt."""
    run.reset(Scenario("probe"), "probe installed engines (read-only catalog)")
    speech = settled_catalog(run).get("speech") or {}
    observed.update(speech)
    for engine in ("parakeet", "whisper"):
        if speech.get(engine) == "installed":
            return engine
    return None


def installed_polish(run):
    """Local polish ids already installed / not installed, from the read-only catalog."""
    polish = settled_catalog(run).get("polish") or {}
    return ([k for k, v in sorted(polish.items()) if v == "installed"],
            [k for k, v in sorted(polish.items()) if v != "installed"])


def s_fresh(run, speech):
    s = Scenario("fresh")
    st = run.reset(s, "arrange an incomplete Setup at Welcome")
    s.expect(st.get("step") == "welcome", "reset lands on Welcome", st.get("step"))
    r = run.send("next")
    s.expect(r.get("outcome") == "moved" and r.get("step") == "language", "Next moves to Language")
    s.expect(r.get("checkpoint") == "language", "checkpoint saved at Language", r.get("checkpoint"))
    r = run.send("chooseLanguage", value="auto")
    s.expect((r.get("choices") or {}).get("language") == "auto", "language pick recorded")
    run.send("next")
    r = run.send("chooseSpeech", value=speech)
    s.expect(r.get("step") == "polishIntro" and (r.get("choices") or {}).get("speech") == speech,
             "speech pick moves to the polish intro", r.get("step"))
    s.expect((r.get("downloads") or {}).get("speech") == "installed",
             "the installed engine is adopted (no download)", r.get("downloads"))
    run.send("next")
    r = run.send("skipPolish")
    s.expect(r.get("step") == "downloads" and (r.get("choices") or {}).get("polish") == "off",
             "Skip AI polish reaches Downloads with polish off", r.get("choices"))
    s.expect(r.get("checkpoint") == "downloads", "checkpoint follows the step", r.get("checkpoint"))
    s.expect(r.get("legacyState") == "needsModelDownload",
             "legacy projection is settingUp (stored as needsModelDownload)",
             r.get("legacyState"))
    return s


def s_resume(run, speech):
    s = Scenario("resume")
    before = run.status()
    picks = before.get("choices")
    r = run.app.call("onboarding", "stop")
    s.expect(r.get("owner") != "backend" and r.get("checkpoint") == before.get("checkpoint"),
             "stop gives Setup back and keeps the checkpoint", r.get("checkpoint"))
    r = run.app.call("onboarding", "begin")
    s.expect(r.get("opened") is True and r.get("step") == before.get("step")
             and r.get("choices") == picks, "begin resumes the same step and picks", r.get("step"))
    # Across a relaunch: the checkpoint is the only state that survives.
    run.app.call("onboarding", "stop")
    s.fixture("identity-checked quit and relaunch with the launch hold")
    run.app.quit()
    run.app.launch(hold=True)
    st = run.status()
    s.expect(st.get("owner") == "backend" and not st.get("legacyWindowVisible"),
             "the launch hold kept the old onboarding closed", st.get("owner"))
    s.expect(st.get("checkpoint") == before.get("checkpoint"), "checkpoint survived the relaunch")
    r = run.app.call("onboarding", "begin")
    s.expect(r.get("step") == before.get("step") and r.get("choices") == picks,
             "begin after relaunch resumes the same step and picks", r.get("step"))
    return s


def s_restart(run, speech):
    s = Scenario("restart")
    r = run.app.call("onboarding", "reset")
    s.expect(r.get("step") == "welcome", "reset returns to Welcome", r.get("step"))
    s.expect(r.get("checkpoint") is None, "reset deleted the checkpoint", r.get("checkpoint"))
    s.expect(all(v is None for v in (r.get("choices") or {}).values()), "picks cleared",
             r.get("choices"))
    s.expect(r.get("block") is None and r.get("legacyState") == "needsMicPermission",
             "no block; legacy projection notStarted (stored as needsMicPermission)",
             r.get("legacyState"))
    return s


# The approved rules (`SetupRules.builtInJSON`, plan D1/D2), written out independently:
# polish primary by memory, mini for a locked non-English language below 16 GiB; Parakeet when
# it transcribes the language, else Whisper.
PROFILE_CASES = [
    {"ram": 8, "language": "auto", "speech": "parakeet", "polish": "eg1.micro"},
    {"ram": 8, "language": "de", "speech": "parakeet", "polish": "eg1.mini"},
    {"ram": 16, "language": "auto", "speech": "parakeet", "polish": "eg1.mini"},
    {"ram": 32, "language": "auto", "speech": "parakeet", "polish": "eg1.full"},
    {"ram": 8, "language": "ja", "speech": "whisper", "polish": "eg1.mini"},
]


def s_profiles(run, speech):
    s = Scenario("profiles")
    for case in PROFILE_CASES:
        r = run.app.call("onboarding", "profile", "--ram", str(case["ram"]))
        s.expect(((r.get("simulated") or {}).get("profile") or {}).get("ram") == case["ram"],
                 f"profile ram {case['ram']} is labelled simulated")
        run.reset(s, f"start a flow under ram {case['ram']}")
        run.send("next")
        run.send("chooseLanguage", value=case["language"])
        # The flow's recommendation is frozen at a fresh start (plan DELIVERY GATE): reset is
        # the supported way to read the advice for the language just picked.
        r = run.reset(s, "read the advice for the picked language (frozen-recommendation gate)")
        rec = r.get("recommended") or {}
        s.expect(rec.get("speech") == case["speech"] and rec.get("polish") == case["polish"],
                 f"ram {case['ram']} + {case['language']}: {case['speech']} / {case['polish']}",
                 rec)
    for afm in ("available", "unavailable"):
        r = run.app.call("onboarding", "profile", "--ram", "16", "--afm", afm)
        run.app.call("onboarding", "send", "next")
        run.send("chooseLanguage", value="auto")
        r = run.reset(s, f"read advice with Apple Intelligence {afm}")
        s.expect((r.get("recommended") or {}).get("polish") == "eg1.mini",
                 f"Apple Intelligence {afm} keeps EG-1 preselected (D1/D2)", r.get("recommended"))
    r = run.app.call("onboarding", "profile", "--clear")
    s.expect((r.get("simulated") or {}).get("profile") is None, "profile clear removes the fake")
    return s


def s_permissions(run, speech):
    s = Scenario("permissions")
    run.reset(s, "a flow to position at Permissions")
    run.app.call("onboarding", "permissions", "--mic", "denied", "--ax", "denied")
    s.fixture("goto permissions (DEBUG positioning)")
    run.app.call("onboarding", "goto", "permissions")
    st = run.until(lambda x: (x.get("readiness") or {}).get("microphone") is False, 6,
                   "denied read")
    rd = st.get("readiness") or {}
    s.expect(rd.get("microphone") is False and rd.get("accessibility") is False,
             "denied grants read not granted", rd)
    r = run.send("next")
    s.expect(r.get("outcome") == "refused", "Next is refused without both grants", r.get("reason"))
    run.app.call("onboarding", "permissions", "--mic", "notDetermined", "--ax", "granted")
    st = run.until(lambda x: (x.get("readiness") or {}).get("accessibility") is True, 6, "ax")
    s.expect((st.get("readiness") or {}).get("microphone") is False and st.get("step") ==
             "permissions", "notDetermined microphone still holds Permissions")
    run.app.call("onboarding", "permissions", "--mic", "granted", "--ax", "granted")
    st = run.until(lambda x: x.get("step") == "key", 8, "move to key")
    s.expect(st.get("step") == "key", "granting both moves to Key through live readiness",
             st.get("step"))
    r = run.app.call("onboarding", "permissions", "--clear")
    s.expect((r.get("simulated") or {}).get("permissions") is None, "permissions clear")
    return s


def s_faults(run, speech):
    s = Scenario("faults")
    run.reset(s, "a flow at Downloads for the faults")
    run.walk_to_downloads(s, speech)
    base = run.until(lambda x: (x.get("readiness") or {}).get("engineWarm") is True, 30, "warm")
    s.expect((base.get("readiness") or {}).get("engineWarm") is True,
             "baseline: the installed engine is warm", base.get("readiness"))

    run.app.call("onboarding", "fault", "warm-fail")
    st = run.until(lambda x: (x.get("readiness") or {}).get("engineWarm") is False, 8, "warm-fail")
    s.expect((st.get("readiness") or {}).get("engineWarm") is False, "warm-fail: engine reads not warm")
    run.app.call("onboarding", "fault", "warm-fail", "--off")
    st = run.until(lambda x: (x.get("readiness") or {}).get("engineWarm") is True, 15, "recover")
    s.expect((st.get("readiness") or {}).get("engineWarm") is True, "warm-fail cleared: warm again")

    run.app.call("onboarding", "fault", "download-fail")
    st = run.until(lambda x: False, 3, "dl-fail")
    # By design (OnboardingDebugFaults) the fault fakes only a model that is NOT on this Mac.
    s.expect((st.get("downloads") or {}).get("speech") == "installed",
             "download-fail leaves an installed model installed", st.get("downloads"))
    s.uncovered.append("download-fail on a model that is not on this Mac: every speech engine "
                       "Setup offers is installed here (the fault never fakes an installed one)")
    run.app.call("onboarding", "fault", "download-fail", "--off")

    run.app.call("onboarding", "fault", "slow-network")
    st = run.until(lambda x: x.get("networkSlow") is True, 45, "slow")
    s.expect(st.get("networkSlow") is True,
             "slow-network: the notice shows after the real 10 s window + 20 s threshold")
    run.app.call("onboarding", "fault", "slow-network", "--off")
    st = run.until(lambda x: x.get("networkSlow") is False, 10, "slow-off")
    s.expect(st.get("networkSlow") is False, "slow-network cleared: notice gone")

    # key-invalid and polish-fail need a cloud or a local polish pick.
    run.send("turnPolishOn")
    run.send("seeAllPolish")
    run.app.call("onboarding", "fault", "key-invalid")
    r = run.send("chooseCloud", provider="openAI", model="gpt-4o-mini")
    st = run.until(lambda x: x.get("step") == "downloads", 4, "cloud")
    s.expect((st.get("readiness") or {}).get("polishReady") is False,
             "key-invalid: the cloud pick reads not ready", st.get("readiness"))
    run.app.call("onboarding", "fault", "key-invalid", "--off")
    s.uncovered.append("key-invalid recovery needs a saved, checked cloud key (no key is created "
                       "or read by this harness); recovery is chunk D's key-step UAT")

    have, missing = installed_polish(run)
    if not missing:
        s.uncovered.append("disk-short: every offered model is installed here, so the preflight "
                           "has nothing to block")
    else:
        # Only with the fault active: the preflight must block this pick before any transfer.
        run.app.call("onboarding", "fault", "disk-short")
        run.send("turnPolishOn")
        run.send("seeAllPolish")
        run.send("choosePolish", value=missing[-1])
        st = run.until(lambda x: x.get("block") is not None, 8, "disk block")
        s.expect((st.get("block") or {}).get("kind") == "insufficientDisk",
                 "disk-short: the preflight blocks before any transfer", st.get("block"))
        s.expect((st.get("downloads") or {}).get("polish") in ("notStarted", "paused"),
                 "disk-short: no transfer started", st.get("downloads"))
        run.app.call("onboarding", "fault", "disk-short", "--off")
        if (st.get("block") or {}).get("kind") != "insufficientDisk":
            # A preflight that failed to block must not keep downloading: reset cancels the
            # flow's owned transfers (OnboardingCoordinator.cancelOwnedTransfers).
            run.app.call("onboarding", "reset")

    have, _ = installed_polish(run)
    if not have:
        s.uncovered.append("polish-fail: no local polish model is installed here")
    else:
        run.app.call("onboarding", "fault", "polish-fail")
        run.send("turnPolishOn")
        run.send("seeAllPolish")
        run.send("choosePolish", value=have[0])
        st = run.until(lambda x: x.get("step") == "downloads", 4, "polish")
        s.expect((st.get("readiness") or {}).get("polishReady") is False,
                 f"polish-fail: {have[0]} reads not ready", st.get("readiness"))
    run.app.call("onboarding", "fault", "--clear")
    st = run.status()
    s.expect((st.get("simulated") or {}).get("faults") == [], "faults cleared")
    s.expect((st.get("downloads") or {}).get("speech") == "installed",
             "installed speech model preserved after every fault", st.get("downloads"))
    return s


def s_completion(run, speech):
    s = Scenario("completion")
    run.reset(s, "a fresh flow to finish")
    run.walk_to_downloads(s, speech)
    r = run.send("next")
    s.expect(r.get("step") == "permissions", "Downloads Next reaches Permissions", r.get("step"))
    run.app.call("onboarding", "permissions", "--mic", "granted", "--ax", "granted")
    st = run.until(lambda x: x.get("step") == "key", 8, "key")
    s.expect(st.get("step") == "key", "granted permissions move to Key")
    run.send("next")
    st = run.until(lambda x: x.get("step") == "practice", 60, "practice")
    s.expect(st.get("step") == "practice" and st.get("practiceUsable") is True,
             "live readiness opens Practice", st.get("step"))
    r = run.send("skipPractice")
    s.expect(r.get("active") is False, "Skip practice finishes Setup", r)
    s.expect(r.get("legacyState") == "completed" and r.get("checkpoint") is None,
             "completion is durable and deletes the checkpoint",
             (r.get("legacyState"), r.get("checkpoint")))
    s.expect(r.get("owner") != "backend", "completion gives Setup back", r.get("owner"))
    run.app.call("onboarding", "permissions", "--clear")
    return s


def s_interrupted(run, speech):
    s = Scenario("interrupted")
    run.app.call("onboarding", "stop")
    s.fixture("quit, then a typed done-checkpoint with legacy settingUp written while quit")
    run.app.quit()
    now = time.time()
    checkpoint = json.dumps({
        "version": 1, "step": "done",
        "choices": {"speech": speech, "polish": "off"},
        "practiceOutcome": "skipped", "startedAt": now - 120, "savedAt": now - 60,
    }).encode()
    merged = defaults_store.export_domain(SHARED)
    # `settingUp` is stored under its legacy raw value (`OnboardingState.settingUp`).
    merged.update({"onboardingState": "needsModelDownload", "hasCompletedOnboarding": False,
                   "ew.onboarding.checkpoint.v1": checkpoint})
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "fixture.plist")
        with open(path, "wb") as fh:
            plistlib.dump(merged, fh)
        subprocess.run(["defaults", "import", SHARED, path], check=True)
    run.app.launch(hold=True)
    r = run.app.call("onboarding", "begin")
    s.expect(r.get("opened") is False, "an interrupted completion opens no Setup", r.get("opened"))
    s.expect(r.get("legacyState") == "completed" and r.get("checkpoint") is None,
             "completion recovered: completed, checkpoint gone",
             (r.get("legacyState"), r.get("checkpoint")))
    s.expect(r.get("owner") != "backend", "Setup given back", r.get("owner"))
    return s


SCENARIOS = {
    "fresh": s_fresh, "resume": s_resume, "restart": s_restart, "profiles": s_profiles,
    "permissions": s_permissions, "faults": s_faults, "completion": s_completion,
    "interrupted": s_interrupted,
}


# ---------------------------------------------------------------------------------------------
# Run and restore
# ---------------------------------------------------------------------------------------------

def quiesce(app):
    """Stop the session and clear every simulation (each call only if the app answers)."""
    for argv in (("onboarding", "stop"), ("onboarding", "profile", "--clear"),
                 ("onboarding", "permissions", "--clear"), ("onboarding", "fault", "--clear")):
        try:
            app.call(*argv)
        except dev_control.DoorRefused:
            pass


def running_dev_apps(boundaries):
    """{pid: executable} for every running dev app, from ANY checkout."""
    return {int(p): e for p, e in boundaries.instances().items()
            if e.endswith(dev_control.DEV_EXECUTABLE_SUFFIX)}


def live_protected(call):
    """The live (in-app) values of the protected shared keys the door exposes, from ONE
    `settings list` reply."""
    rows = call("settings", "list").get("settings") or []
    live = {r.get("key"): r.get("value") for r in rows if isinstance(r, dict)}
    return {k: live[k] for k in sorted(ALLOWLIST[SHARED]) if k in live}


def restore_ok(report):
    """A restore is resolved only when every restored key read back, no protected key differs
    after the write OR after the relaunch, the relaunch answered, and nothing unclassified
    changed (plan M69 (b)). Anything else keeps the recovery file for `recover`."""
    return (report.get("relaunched", True)
            and all(all(v.values()) for v in report["landed"].values())
            and not any(report["allowlisted_still_different"].values())
            and not any(report["discoveries"].values())
            and not any(report.get("after_relaunch_protected", {}).values())
            and not any(report.get("after_relaunch_discoveries", {}).values())
            and not report.get("live_mismatch")
            and not report.get("not_written"))


def restore(app, artifacts, live_before=None):
    """Restores a run's settings, from whichever state cleanup finds the app in:
    - attached (the run changed something): stop the session, quit it like a person;
    - relaunched but its door unreachable: attach by executable, else stop (QuitFailed);
    - never changed anything: no quit, no write, compare only;
    - a lost reply on a mutating call counts as changed (`App.call`).
    Before any write, NO dev app from any checkout may be running (checked independently of
    the harness's own bookkeeping). After the write it relaunches, then compares the persisted
    domains AND the live values (`live_before`, read through the door before the first change).
    The recovery file is resolved only if every comparison passed (`restore_ok`)."""
    snap = load_snapshot(artifacts)
    owned = app.mutated
    if owned:
        if app.client is None and app._mine():
            try:
                app.attach()
            except HarnessError as error:
                raise QuitFailed(f"the relaunched app's door is unreachable: {error}") from error
        if app.client is not None:
            quiesce(app)
            app.quit()
    running = running_dev_apps(app.boundaries)
    if running and owned:
        raise QuitFailed(f"dev apps still running {running}; restore never writes behind one")
    now = {d: defaults_store.export_domain(d) for d in snap["domains"]}
    plan, discoveries = plan_restore(snap, now)
    report = {"restored": {}, "landed": {}, "discoveries": discoveries,
              "ambient_changed": ambient_changes(snap, now), "quit_and_relaunched": owned}
    if running:
        # The run never changed anything and the app is still running: nothing is written.
        report["not_written"] = {d: sorted(k) for d, k in plan.items() if k}
        after = now
    else:
        report["restored"] = {d: sorted(keys) for d, keys in plan.items()}
        report["landed"] = restore_keys(plan)
        after = {d: defaults_store.export_domain(d) for d in snap["domains"]}
    report["allowlisted_still_different"] = {
        d: sorted(changed_keys(snap["domains"][d], after[d]) & ALLOWLIST.get(d, set()))
        for d in snap["domains"]}
    if owned:
        try:
            app.launch(hold=False)
        except HarnessError as error:
            report["relaunched"] = False
            report["relaunch_error"] = str(error)
        relaunched = {d: defaults_store.export_domain(d) for d in snap["domains"]}
        _, drift = plan_restore(snap, relaunched)
        report["after_relaunch_protected"] = {
            d: sorted(changed_keys(snap["domains"][d], relaunched[d]) & ALLOWLIST.get(d, set()))
            for d in snap["domains"]}
        report["after_relaunch_discoveries"] = drift
        if live_before is not None and report.get("relaunched", True):
            live_after = live_protected(app.call)
            report["live_compared"] = sorted(live_before)
            report["live_mismatch"] = {
                k: [live_before[k], live_after.get(k)] for k in live_before
                if not defaults_store.same_plist_value(live_before[k], live_after.get(k))}
    report["ok"] = restore_ok(report)
    if report["ok"]:
        mark_resolved(artifacts)
    return report


def cmd_run(args):
    worktree = os.path.abspath(args.worktree)
    artifacts = os.path.abspath(args.artifacts)
    dev_control.check_owner()
    app = App(worktree)
    app.attach()
    busy = busy_reasons(app.call)
    if busy:
        # Never started: no snapshot, no reset, no quit; the person's work is left alone.
        raise HarnessError("the app is busy, not starting: " + "; ".join(busy))
    live_before = live_protected(app.call)  # read-only, before the first change
    take_snapshot(artifacts)
    run = Run(app, artifacts)
    names = args.scenario or list(SCENARIOS)
    result = {"build": app.executable, "pid_at_start": app.client.pid, "scenarios": []}
    restore_report = None
    try:
        app.call("onboarding", "stop")
        observed = {}
        speech = installed_speech(run, observed)
        result["speech_phases_seen"] = observed
        if speech is None:
            raise HarnessError("no installed speech engine: the harness never downloads one")
        result["installed_speech"] = speech
        for name in names:
            try:
                s = SCENARIOS[name](run, speech)
            except QuitFailed:
                raise  # the app may still be writing settings: stop the run, keep recovery
            except (dev_control.DoorRefused, HarnessError) as error:
                s = Scenario(name)
                s.expect(False, "scenario raised", f"{type(error).__name__}: {error}")
            result["scenarios"].append(s.receipt())
    finally:
        run.window["end"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        result["window"] = run.window
        try:
            restore_report = restore(app, artifacts, live_before)
        except QuitFailed as error:
            restore_report = {"ok": False, "quit_failed": str(error), "discoveries": {},
                              "recovery": "kept; quit the app by hand, then run `recover`"}
        result["restore"] = restore_report
        result["crash_reports"] = app.crash_reports
        result["pid_at_end"] = app.client.pid if app.client else None
        with open(os.path.join(artifacts, RECEIPT), "w") as fh:
            json.dump(result, fh, indent=2, default=str)
    if "quit_failed" in restore_report:
        raise QuitFailed(restore_report["quit_failed"])
    passed = all(s["passed"] for s in result["scenarios"]) and restore_report["ok"] \
        and not restore_report["discoveries"] and not app.crash_reports
    summary = {"passed": passed, "restore_ok": restore_report["ok"],
               "discoveries": restore_report["discoveries"],
               "crash_reports": app.crash_reports,
               "scenarios": {s["scenario"]: s["passed"] for s in result["scenarios"]},
               "receipt": os.path.join(artifacts, RECEIPT)}
    print(json.dumps(summary, indent=2))
    return 0 if passed else 1


def recover(artifacts, boundaries=None, owner=None, restore_plist=None):
    """Manual recovery after a crash or a failed quit. It writes the shared settings domains, so
    it first requires the dev-app lock (`dev_control.check_owner`) and that NO dev app from any
    checkout is running (plan M69 (c)); a refusal writes nothing and keeps the snapshot."""
    boundaries = boundaries or dev_control.Boundaries()
    (owner or dev_control.check_owner)(boundaries)
    running = {int(p): e for p, e in boundaries.instances().items()
               if e.endswith(dev_control.DEV_EXECUTABLE_SUFFIX)}
    if running:
        raise HarnessError(f"quit every dev app first; recover never writes behind one: {running}")
    snap = load_snapshot(artifacts)
    if snap.get("resolved"):
        return {"ok": True, "already_resolved": True}
    now = {d: defaults_store.export_domain(d) for d in snap["domains"]}
    plan, discoveries = plan_restore(snap, now)
    landed = restore_keys(plan, **({"restore_plist": restore_plist} if restore_plist else {}))
    after = {d: defaults_store.export_domain(d) for d in snap["domains"]}
    back = {d: sorted(changed_keys(snap["domains"][d], after[d]) & ALLOWLIST.get(d, set()))
            for d in snap["domains"]}
    report = {"restored": {d: sorted(k) for d, k in plan.items()}, "landed": landed,
              "allowlisted_still_different": back, "discoveries": discoveries}
    report["ok"] = restore_ok(report)
    if report["ok"]:
        mark_resolved(artifacts)
    return report


def cmd_recover(args):
    report = recover(os.path.abspath(args.artifacts))
    print(json.dumps(report, indent=2, default=str))
    return 0 if report["ok"] else 1


# ---------------------------------------------------------------------------------------------
# Self-test: the safety contract on a throwaway domain, no app
# ---------------------------------------------------------------------------------------------

def self_test():
    failures = []

    def check(ok, label):
        print(("PASS " if ok else "FAIL ") + label)
        if not ok:
            failures.append(label)

    domain = f"com.enviouswispr.uat.selftest.{os.getpid()}"
    subprocess.run(["defaults", "delete", domain], capture_output=True)
    tmp = tempfile.mkdtemp(prefix="onboarding-uat-selftest-")
    try:
        # Seed: Data, a bool, a string; one key absent.
        seed = {"ew.onboarding.checkpoint.v1": b"\x00\x01{json}", "hasCompletedOnboarding": True,
                "onboardingState": "completed", "bystander": "keep"}
        path = os.path.join(tmp, "seed.plist")
        with open(path, "wb") as fh:
            plistlib.dump(seed, fh)
        subprocess.run(["defaults", "import", domain, path], check=True)
        allow = {domain: {"ew.onboarding.checkpoint.v1", "hasCompletedOnboarding",
                          "onboardingState", "languageMode"}}
        art = os.path.join(tmp, "art")
        snap = take_snapshot(art, domains=(domain,))
        mode = os.stat(recovery_path(art)).st_mode & 0o777
        check(mode == 0o600, f"recovery file is private (mode {oct(mode)})")
        try:
            take_snapshot(art, domains=(domain,))
            check(False, "an unresolved snapshot refuses a second run")
        except HarnessError:
            check(True, "an unresolved snapshot refuses a second run")
        # Mutate: change types, delete Data, add an absent allowlisted key, a bystander, and an
        # unlisted key (a discovery).
        subprocess.run(["defaults", "delete", domain, "ew.onboarding.checkpoint.v1"], check=True)
        # A real type change (`defaults write -int` keeps an existing boolean's type, measured).
        subprocess.run(["defaults", "write", domain, "hasCompletedOnboarding", "-string", "1"],
                       check=True)
        subprocess.run(["defaults", "write", domain, "onboardingState", "notStarted"], check=True)
        subprocess.run(["defaults", "write", domain, "languageMode", "x"], check=True)
        subprocess.run(["defaults", "write", domain, "unlisted", "y"], check=True)
        subprocess.run(["defaults", "write", domain, "bystander", "changed"], check=True)
        now = {domain: defaults_store.export_domain(domain)}
        plan, found = plan_restore(load_snapshot(art), now, allowlist=allow)
        check(set(plan[domain]) == {"ew.onboarding.checkpoint.v1", "hasCompletedOnboarding",
                                    "onboardingState", "languageMode"},
              "restore set = changed allowlisted keys (a bool turned string included)")
        check(found.get(domain) == ["bystander", "unlisted"],
              "unlisted changes are discoveries, not restored")
        _, quiet = plan_restore(load_snapshot(art), now, allowlist=allow,
                                ambient={domain: {"bystander"}})
        check(quiet.get(domain) == ["unlisted"]
              and ambient_changes(load_snapshot(art), now, {domain: {"bystander"}})[domain]
              == ["bystander"], "app-owned ambient keys are reported, not discoveries")
        landed = restore_keys(plan)
        check(all(landed[domain].values()), "every restored key reads back")
        after = defaults_store.export_domain(domain)
        check(after.get("ew.onboarding.checkpoint.v1") == seed["ew.onboarding.checkpoint.v1"]
              and type(after.get("hasCompletedOnboarding")) is bool
              and "languageMode" not in after,
              "Data, bool type and absence restored exactly")
        check(after.get("bystander") == "changed" and after.get("unlisted") == "y",
              "keys outside the restore set are left as they are")
        mark_resolved(art)
        check(load_snapshot(art)["resolved"] is True, "resolved after a verified restore")
        snap2 = take_snapshot(art, domains=(domain,))
        check(snap2["resolved"] is False, "a resolved snapshot allows the next run")
        # Snapshot inside git is refused.
        try:
            take_snapshot(HERE, domains=(domain,))
            check(False, "recovery data inside a git checkout is refused")
        except HarnessError:
            check(True, "recovery data inside a git checkout is refused")
        # Identity: an app from another checkout, or two dev apps, is refused.

        class Fake:
            def __init__(self, table):
                self.table = table

            def instances(self):
                return self.table

        app = App("/tmp/wt", Fake({1: "/other/build/EnviousWispr Local.app/Contents/MacOS/"
                                      "EnviousWispr"}))
        try:
            app.attach()
            check(False, "another checkout's app is refused")
        except HarnessError:
            check(True, "another checkout's app is refused")
        app = App("/tmp/wt", Fake({1: app.executable, 2: "/x/build/EnviousWispr Local.app/"
                                   "Contents/MacOS/EnviousWispr"}))
        try:
            app.attach()
            check(False, "two dev apps are refused")
        except HarnessError:
            check(True, "two dev apps are refused")
        # Quit: refused unless the pinned pid is the only dev app; never sends anything then.
        class Pinned:
            pid = 1

        two = App("/tmp/wt", Fake({1: "/tmp/wt/build/EnviousWispr Local.app/Contents/MacOS/"
                                   "EnviousWispr",
                                   2: "/x/build/EnviousWispr Local.app/Contents/MacOS/EnviousWispr"}))
        two.client = Pinned()
        try:
            two.quit(timeout=0)
            check(False, "a quit with two dev apps running is refused")
        except QuitFailed:
            check(False, "a quit with two dev apps running is refused (not a quit failure)")
        except HarnessError:
            check(True, "a quit with two dev apps running is refused")
        stuck = App("/tmp/wt", Fake({}))
        stuck.quit_failed = "earlier quit did not finish"
        try:
            stuck.quit()
            check(False, "after a failed quit, every later quit stops the run")
        except QuitFailed:
            check(True, "after a failed quit, every later quit stops the run")
        # Crash reports: only EnviousWispr reports written since the quit started count.
        reports = os.path.join(tmp, "reports")
        os.makedirs(reports)
        for name, age in (("EnviousWispr-old.ips", 600), ("EnviousWispr-new.ips", 0),
                          ("OtherApp-new.ips", 0), ("EnviousWispr-notes.txt", 0)):
            f = os.path.join(reports, name)
            open(f, "w").close()
            os.utime(f, (time.time() - age, time.time() - age))
        found = [os.path.basename(f) for f in new_crash_reports(time.time() - 60, reports)]
        check(found == ["EnviousWispr-new.ips"], f"only the new EnviousWispr report counts {found}")
        check(new_crash_reports(0, os.path.join(tmp, "missing")) == [],
              "a missing reports folder is no reports")
        # M69 (a): discovery reads the catalog only; it never chooses (and so never downloads).
        class Recording:
            def __init__(self, replies):
                self.calls, self.replies = [], replies
                self.mutated = False

            def call(self, *argv):
                if len(argv) == 1 and isinstance(argv[0], list):  # a DoorClient takes a list
                    argv = tuple(argv[0])
                self.calls.append(argv)
                return self.replies.get(argv, {})

        catalog = {"speech": {"parakeet": "notStarted", "whisper": "installed"},
                   "polish": {"eg1.micro": "installed", "eg1.full": "notStarted"}}
        fake_app = Recording({("onboarding", "status"): {"catalog": catalog}})
        probe = Run(fake_app, tmp)
        seen = {}
        check(installed_speech(probe, seen) == "whisper" and seen == catalog["speech"],
              "the installed engine comes from the catalog")
        check(installed_polish(probe) == (["eg1.micro"], ["eg1.full"]),
              "installed and missing polish come from the catalog")
        sent = [c for c in fake_app.calls if c[:2] == ("onboarding", "send")]
        check(sent == [], f"discovery sends no choose event (sent {sent})")
        # M69 (d): the busy preflight only reads, and each kind of busy work refuses.
        idle = {("status",): {"activeDriver": {"state": "idle"}, "fileImportRunning": False},
                ("meeting", "status"): {"phase": {"name": "idle"}, "processing": None},
                ("onboarding", "status"): {"legacyWindowVisible": False, "legacyTasks": 0}}
        quiet = Recording(idle)
        check(busy_reasons(quiet.call) == [], "an idle app is not busy")
        check(all(c in READ_ONLY_CALLS for c in quiet.calls), "the preflight only reads")
        for key, patch, label in (
                (("status",), {"activeDriver": {"state": "recording"}}, "dictating"),
                (("status",), {"activeDriver": {"state": "idle"}, "fileImportRunning": True},
                 "importing"),
                (("meeting", "status"), {"phase": {"name": "recording"}}, "in a meeting"),
                (("onboarding", "status"), {"legacyWindowVisible": True}, "old onboarding open")):
            replies = dict(idle)
            replies[key] = patch
            check(busy_reasons(Recording(replies).call) != [], f"busy when {label}")
        # Read-only calls never count as a change; a mutating one does.
        tracked = App("/tmp/wt", Fake({}))
        tracked.client = Recording({})
        tracked.call("onboarding", "status")
        tracked.call("meeting", "status")
        check(tracked.mutated is False, "read-only calls are not a change")
        tracked.call("onboarding", "reset")
        check(tracked.mutated is True, "a reset is a change")
        # A run that changed nothing is never quit by cleanup.
        class NoQuit(App):
            def quit(self, timeout=30.0):
                raise AssertionError("quit called")
        untouched = NoQuit("/tmp/wt", Fake({}))
        untouched.client = Recording({})
        try:
            report = restore(untouched, art)
            check(report.get("quit_and_relaunched") is False, "an unchanged run is not quit")
        except AssertionError:
            check(False, "an unchanged run is not quit")
        # Restoration entry states (I1a r2): a lost reply on a mutating call is a change.
        class LostReply:
            def call(self, argv):
                raise dev_control.DoorRefused("noReply", "the reply was lost", 2)

        lossy = App("/tmp/wt", Fake({}))
        lossy.client = LostReply()
        try:
            lossy.call("onboarding", "status")
        except dev_control.DoorRefused:
            pass
        check(lossy.mutated is False, "a lost read-only reply is not a change")
        try:
            lossy.call("onboarding", "send", "next")
        except dev_control.DoorRefused:
            pass
        check(lossy.mutated is True, "a lost reply on a mutating call counts as a change")
        # Relaunched but unreachable: our executable runs with no attachable door.
        art4 = os.path.join(tmp, "art4")
        take_snapshot(art4, domains=(domain,))
        subprocess.run(["defaults", "write", domain, "hasCompletedOnboarding", "-bool", "NO"],
                       check=True)
        before_unreachable = defaults_store.export_domain(domain)

        class Unreachable(App):
            def attach(self):
                raise HarnessError("no door")

        ghost = Unreachable("/tmp/wt", Fake({}))
        ghost.boundaries = Fake({9: ghost.executable})
        ghost.mutated = True
        try:
            restore(ghost, art4)
            check(False, "an unreachable relaunched app stops the restore")
        except QuitFailed:
            check(defaults_store.export_domain(domain) == before_unreachable
                  and load_snapshot(art4)["resolved"] is False,
                  "an unreachable relaunched app stops the restore and writes nothing")
        # Never changed, but a dev app runs: compare only, never write behind it.
        idle_app = App("/tmp/wt", Fake({4: "/tmp/wt/build/EnviousWispr Local.app/Contents/MacOS/"
                                           "EnviousWispr"}))
        report = restore(idle_app, art4)
        check(defaults_store.export_domain(domain) == before_unreachable
              and report["ok"] is False and load_snapshot(art4)["resolved"] is False,
              "an unchanged run with the app running writes nothing and keeps recovery")
        # M69 (b): drift after the relaunch, or a discovery, keeps the recovery file.
        good = {"landed": {domain: {"k": True}}, "allowlisted_still_different": {domain: []},
                "discoveries": {}, "after_relaunch_protected": {domain: []},
                "after_relaunch_discoveries": {}}
        check(restore_ok(good) is True, "a clean read-back resolves")
        for field, value, label in (
                ("after_relaunch_protected", {domain: ["languageMode"]}, "protected drift"),
                ("after_relaunch_discoveries", {domain: ["x"]}, "a new key after relaunch"),
                ("discoveries", {domain: ["x"]}, "an unclassified discovery"),
                ("relaunched", False, "a failed relaunch"),
                ("live_mismatch", {"languageMode": ["auto", "de"]}, "a live value mismatch"),
                ("not_written", {domain: ["k"]}, "a change left unwritten")):
            bad = dict(good)
            bad[field] = value
            check(restore_ok(bad) is False, f"{label} keeps recovery")
        # M69 (c): recover refuses without ownership, or with any dev app running, and writes
        # nothing.
        snap3 = take_snapshot(os.path.join(tmp, "art3"), domains=(domain,))
        subprocess.run(["defaults", "write", domain, "bystander", "moved"], check=True)
        before_recover = defaults_store.export_domain(domain)

        def refuse(_):
            raise dev_control.DoorRefused("notOwner", "another session holds the lock", 3)

        art3 = os.path.join(tmp, "art3")
        for label, kwargs in (
                ("without the dev-app lock", {"owner": refuse, "boundaries": Fake({})}),
                ("while another checkout's dev app runs",
                 {"owner": lambda _: "mine",
                  "boundaries": Fake({7: "/other/build/EnviousWispr Local.app/Contents/MacOS/"
                                         "EnviousWispr"})})):
            try:
                recover(art3, **kwargs)
                check(False, f"recover refuses {label}")
            except (HarnessError, dev_control.DoorRefused):
                untouched_domain = defaults_store.export_domain(domain) == before_recover
                check(untouched_domain and load_snapshot(art3)["resolved"] is False,
                      f"recover refuses {label} and writes nothing")
        # Changed-key detection is structural.
        check(changed_keys({"a": True}, {"a": 1}) == {"a"}, "bool vs int is a change")
        check(changed_keys({"a": b"x"}, {}) == {"a"}, "a deleted Data key is a change")
        check(changed_keys({}, {"a": None or ""}) == {"a"}, "a new key is a change")
    finally:
        subprocess.run(["defaults", "delete", domain], capture_output=True)
    print(f"{len(failures)} failure(s)")
    return 1 if failures else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--self-test", action="store_true")
    sub = parser.add_subparsers(dest="cmd")
    for name in ("run", "recover"):
        p = sub.add_parser(name)
        p.add_argument("--artifacts", required=True, help="run folder outside git")
        p.add_argument("--worktree", default=os.path.dirname(os.path.dirname(HERE)))
        if name == "run":
            p.add_argument("--scenario", action="append", choices=list(SCENARIOS))
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if args.cmd == "run":
        return cmd_run(args)
    if args.cmd == "recover":
        return cmd_recover(args)
    parser.print_help()
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except HarnessError as error:
        print(json.dumps({"error": str(error)}))
        sys.exit(2)
