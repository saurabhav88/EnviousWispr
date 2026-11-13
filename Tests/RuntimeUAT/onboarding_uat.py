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

# The Setup window's title in the app's language (German: "Einrichtung"); `EW_UAT_SETUP_TITLE`
# overrides it for a run in another language.
SETUP_TITLE = os.environ.get("EW_UAT_SETUP_TITLE", "Setup")
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
        # App appearance, changed only by the shell screenshots (light and dark).
        "appearancePreference",
        # The record shortcut, changed by the key screen's popular-key row (D5,
        # `ShortcutSettings.assign(_:to: .record, in:)` writes the key code, then the modifiers).
        "toggleKeyCode", "toggleModifiersRaw",
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
        # M73: the language pick itself re-forms the advice; its reply shows it.
        r = run.send("chooseLanguage", value=case["language"])
        rec = r.get("recommended") or {}
        s.expect(rec.get("speech") == case["speech"] and rec.get("polish") == case["polish"],
                 f"ram {case['ram']} + {case['language']}: {case['speech']} / {case['polish']}",
                 rec)
    for afm in ("available", "unavailable"):
        r = run.app.call("onboarding", "profile", "--ram", "16", "--afm", afm)
        run.reset(s, f"start a flow with Apple Intelligence {afm}")
        run.send("next")
        r = run.send("chooseLanguage", value="auto")
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


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def s_consent_off(run, speech):
    """Usage metrics OFF: a visit with picks and an abandon must send no Setup rows. The run
    records the consent-off window; PostHog is read for that window AFTER the run (the
    harness cannot see the vendor), so this scenario's own checks cover only the switch."""
    s = Scenario("consent_off")
    before = run.app.call("settings", "get", "shareUsageMetrics").get("value")
    s.fixture("usage metrics switched off through the door (allowlisted; restored at the end)")
    run.app.call("settings", "set", "shareUsageMetrics", "false")
    off = run.app.call("settings", "get", "shareUsageMetrics").get("value")
    s.expect(off is False, "usage metrics read off", off)
    run.window["consent_off_start"] = utc_now()
    run.reset(s, "a visit with consent off")
    run.walk_to_downloads(s, speech)
    run.app.call("onboarding", "stop")  # ends the visit: with consent on this sends choices
    run.window["consent_off_end"] = utc_now()
    run.app.call("settings", "set", "shareUsageMetrics", json.dumps(before))
    back = run.app.call("settings", "get", "shareUsageMetrics").get("value")
    s.expect(back == before, "usage metrics back to the founder's value", back)
    s.notes.append("VENDOR CHECK OWED: no onboarding.* rows in PostHog (environment=development) "
                   "between window.consent_off_start and window.consent_off_end")
    return s


SHELL_STEPS = ("welcome", "language", "speechPick", "polishPick", "permissions", "practice")


def window_id(pid, title):
    """The on-screen CGWindowID of `pid`'s window named `title`, or None (needs Quartz)."""
    from Quartz import CGWindowListCopyWindowInfo, kCGNullWindowID, kCGWindowListOptionOnScreenOnly
    for w in CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID) or []:
        if w.get("kCGWindowOwnerPID") == pid and w.get("kCGWindowName") == title:
            return w.get("kCGWindowNumber")
    return None


def setup_window_ax(pid, title=None):
    """(window title or None, every AXDescription/AXTitle text under it) for `pid`'s window
    named `title`, read from the running app's accessibility tree."""
    from ui_helpers import get_ax_app, get_attr
    title = title or SETUP_TITLE
    window = next((w for w in (get_attr(get_ax_app(pid), "AXWindows") or [])
                   if get_attr(w, "AXTitle") == title), None)
    if window is None:
        return None, []
    texts, stack = [], [window]
    while stack and len(texts) < 500:
        el = stack.pop()
        for attr in ("AXDescription", "AXTitle", "AXValue", "AXLabel"):
            v = get_attr(el, attr)
            if isinstance(v, str) and v:
                texts.append(v)
        stack.extend(get_attr(el, "AXChildren") or [])
    return get_attr(window, "AXTitle"), texts


def capture_window(wid, path):
    """Captures one window to `path`; True only for exit 0 and a fresh, nonempty file."""
    if os.path.exists(path):
        os.remove(path)
    started = time.time()
    done = subprocess.run(["screencapture", "-x", "-o", "-l", str(wid), path],
                          capture_output=True, timeout=10)
    return (done.returncode == 0 and os.path.exists(path) and os.path.getsize(path) > 0
            and os.path.getmtime(path) >= started - 1)


def setup_elements(pid, role, title=None):
    """Every element of `role` in `pid`'s window `title`, with its title/description/value."""
    from ui_helpers import get_ax_app, get_attr
    title = title or SETUP_TITLE
    window = next((w for w in (get_attr(get_ax_app(pid), "AXWindows") or [])
                   if get_attr(w, "AXTitle") == title), None)
    found, stack = [], [window] if window is not None else []
    while stack:
        el = stack.pop()
        if get_attr(el, "AXRole") == role:
            found.append(el)
        stack.extend(get_attr(el, "AXChildren") or [])
    return found


def ax_press(element):
    """AXPress through the real accessibility path; True when the press was delivered.
    A SwiftUI button whose action moves Setup on answers kAXErrorFailure (-25200) although the
    action ran (measured 2026-11-13 on "Try your first dictation" and "Continue without AI
    polish": the next state check passed every time, and the element was still valid 0.3 s
    later while the screen faded out). So -25200 counts as delivered; any other error does
    not. A delivered press proves nothing alone: every caller asserts the outcome after it."""
    from ApplicationServices import AXUIElementPerformAction
    return AXUIElementPerformAction(element, "AXPress") in (0, -25200)


def setup_button(pid, name):
    from ui_helpers import get_attr
    for b in setup_elements(pid, "AXButton"):
        if name in (get_attr(b, "AXTitle"), get_attr(b, "AXDescription")):
            return b
    return None


def setup_field(pid):
    fields = setup_elements(pid, "AXTextField")
    return fields[0] if len(fields) == 1 else None


def post_keys(pid, text=None, keycode=None, flags=0):
    """Keyboard events delivered to `pid` only (CGEventPostToPid), never to the frontmost app,
    so a person using the Mac is not typed into. `text` types Unicode; `keycode` presses one key."""
    from Quartz import (CGEventCreateKeyboardEvent, CGEventKeyboardSetUnicodeString,
                        CGEventPostToPid, CGEventSetFlags)
    def send(down, code=0, chars=None):
        ev = CGEventCreateKeyboardEvent(None, code, down)
        if chars is not None:
            CGEventKeyboardSetUnicodeString(ev, len(chars), chars)
        if flags:
            CGEventSetFlags(ev, flags)
        CGEventPostToPid(pid, ev)
    if text is not None:
        for ch in text:
            send(True, 0, ch)
            send(False, 0, ch)
            time.sleep(0.02)  # test-fixture-timer: one character per event, in order
    if keycode is not None:
        send(True, keycode)
        send(False, keycode)
    time.sleep(0.2)  # test-fixture-timer: the field publishes its text on the next run loop turn


KEY_RETURN, KEY_A, KEY_DELETE, KEY_ESCAPE = 36, 0, 51, 53
FLAG_CMD = 1 << 20


def s_screens_d1(run, speech):
    """D1: Welcome and Language through their real controls (AX press, AX value, AX confirm),
    with light/dark captures of each state. The Mac's language is faked for advice only
    (`onboarding profile --lang`); appearance is set through the door and restored."""
    from ui_helpers import get_attr, set_attr
    s = Scenario("screens_d1")
    pid = run.app.client.pid
    shots = os.path.join(run.artifacts, "shots")
    os.makedirs(shots, exist_ok=True)
    before = run.app.call("settings", "get", "appearance").get("value")

    def shot(name):
        wid = window_id(pid, SETUP_TITLE)
        path = os.path.join(shots, f"d1-{name}.png")
        s.expect(wid is not None and capture_window(wid, path), f"captured {name}", path)

    def settle(seconds=0.6):
        time.sleep(seconds)  # test-fixture-timer: the screen entrance / greeting runs on screen

    def type_language(text):
        field = setup_field(pid)
        s.expect(field is not None, "one language field")
        if field is not None:
            set_attr(field, "AXFocused", True)
        post_keys(pid, keycode=KEY_A, flags=FLAG_CMD)  # select all
        post_keys(pid, keycode=KEY_DELETE)
        post_keys(pid, text=text)
        settle(0.4)

    for appearance in ("light", "dark"):
        run.app.call("settings", "set", "appearance", json.dumps(appearance))
        run.app.call("onboarding", "profile", "--lang", "de")
        run.reset(s, f"fresh flow, Mac language faked German ({appearance})")
        run.app.call("onboarding", "present")
        settle()
        shot(f"{appearance}-welcome")
        start = setup_button(pid, "Set up dictation")
        s.expect(start is not None and ax_press(start),
                 f"pressed Set up dictation ({appearance})")
        st = run.until(lambda x: x.get("step") == "language", 4, "language")
        s.expect(st.get("step") == "language", "Set up dictation reaches Language", st.get("step"))
        settle(0.3)
        field = setup_field(pid)
        s.expect(field is not None and get_attr(field, "AXValue") == "Deutsch",
                 "the Mac's language is pre-filled", field is not None and get_attr(field, "AXValue"))
        shot(f"{appearance}-language-guess")
        settle(0.5)
        shot(f"{appearance}-language-greeting")
        type_language("zzqxw")
        cont = setup_button(pid, "Continue")
        s.expect(cont is not None and get_attr(cont, "AXEnabled") is False,
                 "Continue is disabled for unmatched text", cont is not None and get_attr(cont, "AXEnabled"))
        shot(f"{appearance}-language-nomatch")
        if appearance == "light":
            ax_press(cont)
            st = run.status()
            s.expect(st.get("step") == "language" and (st.get("choices") or {}).get("language") is None,
                     "a disabled Continue commits nothing", (st.get("step"), st.get("choices")))
            type_language("Japanese")
            post_keys(pid, keycode=KEY_RETURN)  # Return in the field
            st = run.until(lambda x: x.get("step") == "speechPick", 4, "speechPick")
            s.expect(st.get("step") == "speechPick"
                     and (st.get("choices") or {}).get("language") == "ja"
                     and (st.get("recommended") or {}).get("speech") == "whisper",
                     "Return commits Japanese and the advice is Whisper (M73)",
                     (st.get("step"), st.get("choices"), st.get("recommended")))
            run.send("back")
            st = run.until(lambda x: x.get("step") == "language", 4, "back")
            settle(0.3)
            field = setup_field(pid)
            s.expect(field is not None and get_attr(field, "AXValue") == "日本語",
                     "Back shows the committed language, not the Mac's guess",
                     field is not None and get_attr(field, "AXValue"))
            type_language("Deutsch")
            cont = setup_button(pid, "Continue")
            s.expect(cont is not None and ax_press(cont), "pressed Continue")
            st = run.until(lambda x: x.get("step") == "speechPick", 4, "speechPick")
            s.expect((st.get("choices") or {}).get("language") == "de",
                     "Continue commits German through the same path", st.get("choices"))
        run.app.call("onboarding", "profile", "--lang", "none")
        run.reset(s, f"fresh flow, Mac language unknown ({appearance})")
        run.send("next")
        settle()
        field = setup_field(pid)
        s.expect(field is not None and (get_attr(field, "AXValue") or "") == "",
                 "an unknown Mac language starts blank", field is not None and get_attr(field, "AXValue"))
        shot(f"{appearance}-language-blank")
    title, texts = setup_window_ax(pid)
    s.expect(any("Your main dictation language" in t for t in texts),
             "the field's accessibility label", [t for t in texts if "language" in t.lower()][:5])
    run.app.call("onboarding", "profile", "--clear")
    run.app.call("settings", "set", "appearance", json.dumps(before))
    run.app.call("onboarding", "stop")
    s.notes.append(f"VISUAL REVIEW OWED: {shots} d1-* against the source-of-truth mockup")
    return s


def s_screens_d2(run, speech):
    """D2: Speech pick and Compare through their real controls (AX press), light and dark:
    open Compare, select a tile WITHOUT advancing, go back to the card, accept; plus Japanese,
    where Parakeet's tile is disabled. Only engines installed on this Mac are accepted (the
    read-only catalog); a missing-model download is clean-Mac UAT."""
    from ui_helpers import get_attr
    s = Scenario("screens_d2")
    pid = run.app.client.pid
    shots = os.path.join(run.artifacts, "shots")
    os.makedirs(shots, exist_ok=True)
    before = run.app.call("settings", "get", "appearance").get("value")

    def shot(name):
        wid = window_id(pid, SETUP_TITLE)
        path = os.path.join(shots, f"d2-{name}.png")
        s.expect(wid is not None and capture_window(wid, path), f"captured {name}", path)

    def settle(seconds=0.6):
        time.sleep(seconds)  # test-fixture-timer: the screen entrance runs on screen

    def press(name):
        b = setup_button(pid, name)
        s.expect(b is not None and ax_press(b), f"pressed {name}")
        settle(0.4)

    def to_speech(language):
        run.reset(s, f"fresh flow for {language}")
        run.send("next")
        run.send("chooseLanguage", value=language)
        run.send("next")
        settle()

    installed = (settled_catalog(run).get("speech") or {})
    for appearance in ("light", "dark"):
        run.app.call("settings", "set", "appearance", json.dumps(appearance))
        run.reset(s, "fresh flow")
        run.app.call("onboarding", "present")
        to_speech("en")
        st = run.status()
        s.expect(st.get("step") == "speechPick" and (st.get("recommended") or {}).get("speech") == "parakeet",
                 "English recommends Parakeet", (st.get("step"), st.get("recommended")))
        shot(f"{appearance}-pick-parakeet")
        press("Compare speech models")
        s.expect(run.status().get("step") == "speechCompare", "the link opens Compare")
        shot(f"{appearance}-compare")
        press("Whisper")
        st = run.status()
        s.expect(st.get("step") == "speechCompare" and (st.get("choices") or {}).get("speech") is None,
                 "a tile click stays on Compare and commits nothing", (st.get("step"), st.get("choices")))
        s.expect(setup_button(pid, "Use Whisper") is not None, "the CTA names the selected tile")
        shot(f"{appearance}-compare-whisper")
        press("Recommended options")
        st = run.status()
        s.expect(st.get("step") == "speechPick" and setup_button(pid, "Use Whisper") is not None,
                 "Recommended options keeps the pending pick and the CTA agrees", st.get("step"))
        shot(f"{appearance}-pick-whisper")
        if appearance == "light":
            if installed.get("whisper") == "installed":
                press("Use Whisper")
                st = run.until(lambda x: x.get("step") == "polishIntro", 4, "polishIntro")
                s.expect(st.get("step") == "polishIntro" and (st.get("choices") or {}).get("speech") == "whisper",
                         "Use Whisper commits Whisper and moves on", (st.get("step"), st.get("choices")))
            else:
                s.uncovered.append("accepting Whisper: not installed on this Mac (clean-Mac UAT)")
        to_speech("ja")
        st = run.status()
        s.expect((st.get("recommended") or {}).get("speech") == "whisper"
                 and setup_button(pid, "Use Whisper") is not None,
                 "Japanese shows Whisper", st.get("recommended"))
        shot(f"{appearance}-pick-whisper-japanese")
        press("Compare speech models")
        parakeet = next((b for b in setup_elements(pid, "AXButton")
                         if (get_attr(b, "AXTitle") or get_attr(b, "AXDescription") or "").startswith("Parakeet")), None)
        s.expect(parakeet is not None and get_attr(parakeet, "AXEnabled") is False,
                 "Japanese disables the Parakeet tile", parakeet is not None and get_attr(parakeet, "AXEnabled"))
        value = (get_attr(parakeet, "AXValue") or "") if parakeet is not None else ""
        s.expect(all(part in value for part in ("for 30 s of speech", "languages", "download",
                                                 "Whisper is the one for")),
                 "VoiceOver reads the disabled tile's facts and reason", value)
        whisper = setup_button(pid, "Whisper")
        wvalue = (get_attr(whisper, "AXValue") or "") if whisper is not None else ""
        s.expect(all(part in wvalue for part in ("for 30 s of speech", "99+ languages", "download")),
                 "VoiceOver reads the recommended tile's facts", wvalue)
        shot(f"{appearance}-compare-japanese")
    run.app.call("settings", "set", "appearance", json.dumps(before))
    run.app.call("onboarding", "stop")
    s.notes.append(f"VISUAL REVIEW OWED: {shots} d2-* against the source-of-truth mockup")
    return s


def s_screens_d3a(run, speech):
    """D3a: Polish intro, AI polish pick and local See all through their real controls (AX
    press), light and dark. The Mac's memory and Apple Intelligence state are faked for ADVICE
    only (`onboarding profile`, a labelled fixture: it never proves Apple Intelligence runs).
    Card/tile clicks must commit nothing; Continue commits exactly the named model; an Apple
    Intelligence change on a mounted screen re-forms the cards. Only installed local models are
    accepted; a missing-model download is clean-Mac UAT."""
    from ui_helpers import get_attr
    s = Scenario("screens_d3a")
    pid = run.app.client.pid
    shots = os.path.join(run.artifacts, "shots")
    os.makedirs(shots, exist_ok=True)
    before = run.app.call("settings", "get", "appearance").get("value")

    def shot(name):
        wid = window_id(pid, SETUP_TITLE)
        path = os.path.join(shots, f"d3a-{name}.png")
        s.expect(wid is not None and capture_window(wid, path), f"captured {name}", path)

    def settle(seconds=0.7):
        time.sleep(seconds)  # test-fixture-timer: the screen entrance and card rise run on screen

    def press(name):
        b = setup_button(pid, name)
        s.expect(b is not None and ax_press(b), f"pressed {name}")
        settle(0.4)

    def has(name):
        return setup_button(pid, name) is not None

    def value(name):
        b = setup_button(pid, name)
        return (get_attr(b, "AXValue") or "") if b is not None else ""

    def to_intro(language, ram, afm):
        run.app.call("onboarding", "profile", "--ram", str(ram), "--afm", afm)
        run.reset(s, f"fresh flow: {language}, {ram} GB, Apple Intelligence {afm} (advice fixture)")
        run.send("next")
        run.send("chooseLanguage", value=language)
        run.send("next")
        run.send("chooseSpeech", value=speech)
        st = run.until(lambda x: x.get("step") == "polishIntro", 4, "polishIntro")
        s.expect(st.get("step") == "polishIntro", "Speech commit reaches Polish intro", st.get("step"))
        settle()

    have, _ = installed_polish(run)
    for appearance in ("light", "dark"):
        run.app.call("settings", "set", "appearance", json.dumps(appearance))
        run.reset(s, "fresh flow")
        run.app.call("onboarding", "present")
        to_intro("en", 16, "available")
        _, texts = setup_window_ax(pid)
        points = ["Fixes filler words", "Formats numbers, dates and times", "Corrects grammar",
                  "Formats lists", "Recognizes when you misspeak", "Formats emails"]
        s.expect(all(any(p in t for t in texts) for p in points), "the intro shows all six capabilities",
                 [p for p in points if not any(p in t for t in texts)])
        shot(f"{appearance}-intro")
        press("Choose my AI polish")
        st = run.until(lambda x: x.get("step") == "polishPick", 4, "polishPick")
        s.expect(st.get("step") == "polishPick", "Choose my AI polish opens the cards", st.get("step"))
        settle()
        s.expect(has("Apple Intelligence") and has("EG-1 Mini") and has("Continue with EG-1 Mini"),
                 "available: Apple Intelligence + EG-1 Mini, EG-1 Mini preselected",
                 (has("Apple Intelligence"), has("EG-1 Mini"), has("Continue with EG-1 Mini")))
        s.expect("Recommended" in value("EG-1 Mini") and "download" in value("EG-1 Mini"),
                 "VoiceOver reads the card's tag and size", value("EG-1 Mini"))
        shot(f"{appearance}-pick-afm")
        press("Apple Intelligence")
        st = run.status()
        s.expect(st.get("step") == "polishPick" and (st.get("choices") or {}).get("polish") is None
                 and has("Continue with Apple Intelligence"),
                 "a card click commits nothing and the CTA names it", (st.get("step"), st.get("choices")))
        press("See all")
        s.expect(run.status().get("step") == "polishSeeAll" and has("Continue with Apple Intelligence"),
                 "See all keeps the pending pick", run.status().get("step"))
        s.expect(all(has(n) for n in ("EG-1", "EG-1 Mini", "EG-1 Micro", "Apple Intelligence", "S1-mini")),
                 "See all lists three EG-1 sizes, Apple Intelligence and S1-mini")
        s.expect("Best for this Mac" in value("EG-1 Mini") and "milliseconds polish" in value("EG-1 Mini"),
                 "VoiceOver reads the tile's recommendation and measured speed", value("EG-1 Mini"))
        shot(f"{appearance}-seeall-afm")
        press("EG-1")
        st = run.status()
        s.expect(st.get("step") == "polishSeeAll" and (st.get("choices") or {}).get("polish") is None
                 and has("Continue with EG-1"), "a tile click commits nothing", st.get("choices"))
        press("Recommended options")
        s.expect(run.status().get("step") == "polishPick" and has("Continue with EG-1")
                 and (run.status().get("choices") or {}).get("polish") is None,
                 "back on the cards, the See all EG-1 pick survives and the CTA names it (mockup hideAll)")
        press("EG-1 Mini")  # pick the recommended card again before Apple Intelligence changes
        # Apple Intelligence turns off while the cards are on screen (advice fixture).
        run.app.call("onboarding", "profile", "--ram", "16", "--afm", "turnedOff")
        settle(1.0)
        s.expect(not has("Apple Intelligence") and has("EG-1 Mini") and has("EG-1")
                 and has("Continue with EG-1 Mini"),
                 "the cards re-form to EG-1 Mini + EG-1 with no stale Apple card or CTA",
                 (has("Apple Intelligence"), has("EG-1"), has("Continue with EG-1 Mini")))
        shot(f"{appearance}-pick-noafm")
        press("See all")
        apple = setup_button(pid, "Apple Intelligence")
        s.expect(apple is not None and get_attr(apple, "AXEnabled") is False
                 and "Turn it on in System Settings first." in value("Apple Intelligence"),
                 "turned off: Apple Intelligence disabled with its reason", value("Apple Intelligence"))
        s.expect(has("Open Settings"), "turned off offers Open Settings (not pressed: opens System Settings)")
        shot(f"{appearance}-seeall-noafm")
        if appearance == "light":
            run.app.call("onboarding", "profile", "--ram", "16", "--afm", "gettingReady")
            settle(1.0)
            s.expect(has("Check again"), "getting ready offers Check again")
            press("Check again")
            s.expect(run.status().get("step") == "polishSeeAll", "Check again keeps the screen")
            run.app.call("onboarding", "profile", "--ram", "16", "--afm", "unavailable")
            settle(1.0)
            s.expect("Not available on this Mac right now." in value("Apple Intelligence"),
                     "unknown availability claims no reason", value("Apple Intelligence"))
            press("Skip AI polish")
            st = run.until(lambda x: x.get("step") == "downloads", 4, "downloads")
            s.expect(st.get("step") == "downloads" and (st.get("choices") or {}).get("polish") == "off",
                     "Skip AI polish stores off and moves on", (st.get("step"), st.get("choices")))
            s.expect(((st.get("downloads") or {}).get("polish")) in (None, "notNeeded", "none"),
                     "Skip starts no polish download", st.get("downloads"))
            eg = next((m for m in ("eg1.micro", "eg1.mini", "eg1.full") if m in have), None)
            if eg:
                name = {"eg1.micro": "EG-1 Micro", "eg1.mini": "EG-1 Mini", "eg1.full": "EG-1"}[eg]
                to_intro("en", 16, "turnedOff")
                run.send("next")
                settle()
                press("See all")
                press(name)
                press(f"Continue with {name}")
                st = run.until(lambda x: x.get("step") == "downloads", 4, "downloads")
                s.expect(st.get("step") == "downloads" and (st.get("choices") or {}).get("polish") == eg,
                         f"Continue commits exactly {name}", (st.get("step"), st.get("choices")))
            else:
                s.uncovered.append("accepting a local EG-1 size: none installed here (clean-Mac UAT)")
        # 8 GB English: Micro recommended with Mini beside it; a locked other language disables S1-mini.
        to_intro("en", 8, "unavailable")
        run.send("next")
        settle()
        s.expect(has("EG-1 Micro") and has("EG-1 Mini") and has("Continue with EG-1 Micro"),
                 "8 GB: EG-1 Micro preselected with EG-1 Mini")
        shot(f"{appearance}-pick-8gb")
        to_intro("ja", 16, "unavailable")
        run.send("next")
        settle()
        press("See all")
        s1 = setup_button(pid, "S1-mini")
        s.expect(s1 is not None and get_attr(s1, "AXEnabled") is False
                 and "For English dictation" in value("S1-mini") and "Superwhisper" in value("S1-mini"),
                 "Japanese: S1-mini disabled with its reason and credit", value("S1-mini"))
        shot(f"{appearance}-seeall-japanese")
    run.app.call("onboarding", "profile", "--clear")
    run.app.call("settings", "set", "appearance", json.dumps(before))
    run.app.call("onboarding", "stop")
    s.notes.append(f"VISUAL REVIEW OWED: {shots} d3a-* against the source-of-truth mockup")
    return s


def s_screens_d5(run, speech):
    """D5 integration: the key screen reached with real events (permissions simulated as granted,
    no OS prompt), through its real controls: the popular-key row writes the record shortcut
    through the settings owner (restored at the end with the rest of the snapshot), the main key
    reads it back, Back and Continue route. Live keyboard rehearsal stays a human/real-keyboard
    check (synthetic per-process events bypass the global hotkey path, so they prove nothing
    about the hotkey pause); the pause/resume balance is covered by SetupShortcutTests."""
    from ui_helpers import get_attr
    s = Scenario("screens_d5")
    pid = run.app.client.pid
    shots = os.path.join(run.artifacts, "shots")
    os.makedirs(shots, exist_ok=True)
    before = run.app.call("settings", "get", "appearance").get("value")

    def shot(name):
        wid = window_id(pid, SETUP_TITLE)
        path = os.path.join(shots, f"d5-{name}.png")
        s.expect(wid is not None and capture_window(wid, path), f"captured {name}", path)

    def settle(seconds=0.7):
        time.sleep(seconds)  # test-fixture-timer: the screen entrance runs on screen

    def press(name):
        b = setup_button(pid, name)
        s.expect(b is not None and ax_press(b), f"pressed {name}")
        settle(0.4)

    def main_key_value():
        b = setup_button(pid, "Change dictation key")
        return (get_attr(b, "AXValue") or "") if b is not None else ""

    def to_key():
        run.reset(s, "fresh flow to the key screen")
        run.app.call("onboarding", "permissions", "--mic", "granted", "--ax", "granted")
        run.send("next")
        run.send("chooseLanguage", value="en")
        run.send("next")
        run.send("chooseSpeech", value=speech)
        run.send("next")
        run.send("skipPolish")
        run.send("next")
        st = run.until(lambda x: x.get("step") == "key", 4, "key")
        s.expect(st.get("step") == "key", "granted permissions lead to the key screen", st.get("step"))
        settle()

    for appearance in ("light", "dark"):
        run.app.call("settings", "set", "appearance", json.dumps(appearance))
        run.reset(s, "fresh flow")
        run.app.call("onboarding", "present")
        to_key()
        _, texts = setup_window_ax(pid)
        s.expect(any(t in ("Ready to dictate!", "Meet your dictation key") for t in texts),
                 "the key screen's headline", [t for t in texts if "dictat" in t.lower()][:4])
        s.expect(main_key_value() != "", "VoiceOver reads the current key", main_key_value())
        shot(f"{appearance}-key")
        if appearance == "light":
            original = main_key_value()
            # The value spells the key with its symbol ("Right ⌥"), so pick one it cannot be.
            target = "Left Command" if "⌥" in original else "Right Option"
            press(target)
            after = main_key_value()
            s.expect(after != original and run.status().get("step") == "key",
                     f"{target} becomes the dictation key and the screen stays", (original, after))
            shot("light-key-changed")
            post_keys(pid, keycode=KEY_ESCAPE)  # Escape is the screen's Back (no visible button)
            st = run.until(lambda x: x.get("step") != "key", 3, "back")
            s.expect(st.get("step") == "permissions",
                     "Escape goes Back to Permissions", st.get("step"))
            if run.status().get("step") != "key":
                run.send("next")
                run.until(lambda x: x.get("step") == "key", 4, "key")
                settle()
            press("Try your first dictation")
            st = run.until(lambda x: x.get("step") in ("gettingReady", "practice"), 4, "continue")
            s.expect(st.get("step") in ("gettingReady", "practice"),
                     "Continue moves to Getting ready or Practice", st.get("step"))
    run.app.call("onboarding", "permissions", "--clear")
    run.app.call("settings", "set", "appearance", json.dumps(before))
    run.app.call("onboarding", "stop")
    s.notes.append(f"VISUAL REVIEW OWED: {shots} d5-* against the source-of-truth mockup")
    s.notes.append("HUMAN CHECK OWED: hold and double-press the real key on the key screen; "
                   "dictation must not start while the screen is key, and must work after leaving it")
    return s


def s_screens_d4b(run, speech):
    """D4b integration: the Permissions screen reached with real events, every state driven by
    the DEBUG permission simulation (no macOS prompt, no System Settings pane, no permission
    telemetry): not asked, microphone allowed, a row waiting for System Settings, both allowed
    (the flow's own auto-advance to the key screen) and microphone turned off. A real OS grant is
    clean-Mac UAT."""
    from ui_helpers import get_attr
    s = Scenario("screens_d4b")
    pid = run.app.client.pid
    shots = os.path.join(run.artifacts, "shots")
    os.makedirs(shots, exist_ok=True)
    before = run.app.call("settings", "get", "appearance").get("value")

    def shot(name):
        wid = window_id(pid, SETUP_TITLE)
        path = os.path.join(shots, f"d4b-{name}.png")
        s.expect(wid is not None and capture_window(wid, path), f"captured {name}", path)

    def settle(seconds=0.8):
        time.sleep(seconds)  # test-fixture-timer: the screen entrance and grant bounce run on screen

    def texts():
        return setup_window_ax(pid)[1]

    def says(phrase):
        return any(phrase in t for t in texts())

    def press(name):
        b = setup_button(pid, name)
        s.expect(b is not None and ax_press(b), f"pressed {name}")
        settle(0.5)

    def simulate(mic, ax):
        run.app.call("onboarding", "permissions", "--mic", mic, "--ax", ax)
        settle()

    def to_permissions(mic, ax):
        run.reset(s, f"fresh flow to Permissions (simulated mic {mic}, ax {ax})")
        simulate(mic, ax)
        run.send("next")
        run.send("chooseLanguage", value="en")
        run.send("next")
        run.send("chooseSpeech", value=speech)
        run.send("next")
        run.send("skipPolish")
        run.send("next")
        st = run.until(lambda x: x.get("step") == "permissions", 4, "permissions")
        s.expect(st.get("step") == "permissions", "Downloads continues to Permissions", st.get("step"))
        settle()

    for appearance in ("light", "dark"):
        run.app.call("settings", "set", "appearance", json.dumps(appearance))
        run.reset(s, "fresh flow")
        run.app.call("onboarding", "present")
        to_permissions("notDetermined", "denied")
        s.expect(says("Two quick permissions") and setup_button(pid, "Allow microphone") is not None,
                 "not asked: two permissions, the microphone row offers Allow")
        shot(f"{appearance}-not-asked")
        if appearance == "light":
            press("Allow microphone")
            s.expect(run.status().get("step") == "permissions",
                     "Allow under simulation shows no prompt and stays", run.status().get("step"))
        simulate("granted", "denied")
        s.expect(says("Two quick permissions") and setup_button(pid, "Open System Settings") is not None,
                 "microphone allowed: the screen redraws live and Accessibility offers System Settings")
        shot(f"{appearance}-mic-allowed")
        if appearance == "light":
            press("Open System Settings")
            s.expect(says("Waiting for the switch in System Settings")
                     and setup_button(pid, "Open System Settings again") is not None,
                     "Accessibility waits for System Settings, and a repeat press reopens it")
            shot("light-waiting")
        simulate("granted", "granted")
        st = run.until(lambda x: x.get("step") == "key", 5, "key")
        s.expect(st.get("step") == "key", "both allowed: the flow moves on to the key screen by itself",
                 st.get("step"))
        to_permissions("denied", "denied")
        s.expect(says("One switch to flip") and setup_button(pid, "Open System Settings") is not None,
                 "microphone turned off: one switch to flip, Open System Settings")
        shot(f"{appearance}-mic-off")
        if appearance == "light":
            press("Back")
            st = run.until(lambda x: x.get("step") == "downloads", 4, "back")
            s.expect(st.get("step") == "downloads",
                     "the visible Back leaves Permissions (no dead end on a restricted Mac)",
                     st.get("step"))
    run.app.call("onboarding", "permissions", "--clear")
    run.app.call("settings", "set", "appearance", json.dumps(before))
    run.app.call("onboarding", "stop")
    s.notes.append(f"VISUAL REVIEW OWED: {shots} d4b-* against the source-of-truth mockup")
    s.notes.append("CLEAN-MAC UAT OWED: real macOS microphone prompt and Accessibility grant")
    return s


def s_screens_d4a(run, speech):
    """D4a: Downloads and Getting ready through their real controls (AX press), light and dark,
    with the approved faults at their existing boundaries: polish-fail (Getting ready's polish
    Try again) and warm-fail (the warm-up Try again), each cleared and recovered; the polish-off
    card's Turn on; Continue setup; entering an already-finished Downloads does not bounce.
    Installed-only hardware cannot reach a missing-model download, disk-short preflight or a
    slow transfer while downloading: those stay clean-Mac UAT."""
    s = Scenario("screens_d4a")
    pid = run.app.client.pid
    shots = os.path.join(run.artifacts, "shots")
    os.makedirs(shots, exist_ok=True)
    before = run.app.call("settings", "get", "appearance").get("value")
    have, _ = installed_polish(run)
    eg = next((m for m in ("eg1.micro", "eg1.mini", "eg1.full") if m in have), None)

    def shot(name):
        wid = window_id(pid, SETUP_TITLE)
        path = os.path.join(shots, f"d4a-{name}.png")
        s.expect(wid is not None and capture_window(wid, path), f"captured {name}", path)

    def settle(seconds=0.8):
        time.sleep(seconds)  # test-fixture-timer: the screen entrance and card rise run on screen

    def says(phrase):
        return any(phrase in t for t in setup_window_ax(pid)[1])

    def press(name):
        b = setup_button(pid, name)
        s.expect(b is not None and ax_press(b), f"pressed {name}")
        settle(0.6)

    def to_downloads(polish_event):
        run.reset(s, f"fresh flow to Downloads ({polish_event})")
        run.send("next")
        run.send("chooseLanguage", value="en")
        run.send("next")
        run.send("chooseSpeech", value=speech)
        run.send("next")
        if polish_event == "skip":
            run.send("skipPolish")
        else:
            run.send("choosePolish", value=polish_event)
        st = run.until(lambda x: x.get("step") == "downloads", 4, "downloads")
        s.expect(st.get("step") == "downloads", "the polish choice reaches Downloads", st.get("step"))
        settle()

    for appearance in ("light", "dark"):
        run.app.call("settings", "set", "appearance", json.dumps(appearance))
        run.reset(s, "fresh flow")
        run.app.call("onboarding", "present")
        to_downloads("skip")
        s.expect(says("Turned off") and setup_button(pid, "Turn on") is not None,
                 "polish off: the card offers Turn on")
        time.sleep(2.5)  # test-fixture-timer: longer than the 1.6 s countdown, to prove no bounce
        st = run.status()
        s.expect(st.get("step") == "downloads" and st.get("countingDown") is False,
                 "an already-finished Downloads does not bounce onward", (st.get("step"), st.get("countingDown")))
        shot(f"{appearance}-finished-polish-off")
        if appearance == "light":
            press("Turn on")
            s.expect(run.status().get("step") == "polishPick", "Turn on returns to the polish choice")
            to_downloads("skip")
            press("Continue setup")
            st = run.status()
            # This Mac's real grants may already be on: Permissions then moves on to Key by itself.
            s.expect(st.get("step") in ("permissions", "key"),
                     "Continue setup moves on to Permissions", st.get("step"))
        if not eg:
            s.uncovered.append("Getting ready with a local polish model: none installed here (clean-Mac UAT)")
            continue
        # Getting ready with a failing polish load (fault), then recovery.
        run.app.call("onboarding", "fault", "polish-fail")
        run.app.call("onboarding", "permissions", "--mic", "granted", "--ax", "granted")
        to_downloads(eg)
        run.send("next")  # Permissions: granted, moves to Key
        run.until(lambda x: x.get("step") == "key", 4, "key")
        run.send("next")
        st = run.until(lambda x: x.get("step") == "gettingReady", 5, "gettingReady")
        s.expect(st.get("step") == "gettingReady", "a failing polish load holds Getting ready", st.get("step"))
        st = run.until(lambda x: (x.get("readiness") or {}).get("polishFailed") is True, 8, "polishFailed")
        settle()
        s.expect(says("The model did not start") and setup_button(pid, "Try again") is not None
                 and setup_button(pid, "Continue without AI polish") is not None,
                 "polish failure: its own Try again and a way forward without polish")
        shot(f"{appearance}-polish-failed")
        if appearance == "light":
            press("Try again")  # with the fault still on: honest, still failed
            st = run.until(lambda x: (x.get("readiness") or {}).get("polishFailed") is True, 6, "still failed")
            s.expect((st.get("readiness") or {}).get("polishFailed") is True and run.status().get("step") == "gettingReady",
                     "Try again under a persisting failure stays honest", st.get("readiness"))
            run.app.call("onboarding", "fault", "polish-fail", "--off")
            run.app.call("onboarding", "retry-polish")
            st = run.until(lambda x: (x.get("readiness") or {}).get("polishReady") is True, 20, "polishReady")
            s.expect((st.get("readiness") or {}).get("polishReady") is True,
                     "after the fault clears, Try again loads the model", st.get("readiness"))
        else:
            press("Continue without AI polish")
            st = run.status()
            s.expect((st.get("choices") or {}).get("polish") == "off",
                     "Continue without AI polish stores off", st.get("choices"))
        run.app.call("onboarding", "fault", "--clear")
        # Warm-up failure on Getting ready, then the door's Try again.
        if appearance == "light":
            run.app.call("onboarding", "fault", "warm-fail")
            to_downloads("skip")
            run.send("next")
            run.until(lambda x: x.get("step") == "key", 4, "key")
            run.send("next")
            st = run.until(lambda x: x.get("warmFailed") is True or x.get("step") == "practice", 12, "warmFailed")
            settle()
            if st.get("warmFailed"):
                s.expect(says("Start dictation again") and setup_button(pid, "Try again") is not None,
                         "warm failure: Start dictation again with its Try again")
                shot("light-warm-failed")
                run.app.call("onboarding", "fault", "warm-fail", "--off")
                r = run.app.call("onboarding", "retry-warmup")
                s.expect(r.get("warmFailed") is False, "retry-warmup clears the failure (not proof of warmth)",
                         r.get("warmFailed"))
                st = run.until(lambda x: x.get("step") == "practice", 20, "practice")
                s.expect(st.get("step") == "practice", "a warm engine moves Getting ready to Practice",
                         st.get("step"))
            else:
                s.uncovered.append("warm-fail: the engine was already warm here")
            run.app.call("onboarding", "fault", "--clear")
        run.app.call("onboarding", "permissions", "--clear")
    run.app.call("settings", "set", "appearance", json.dumps(before))
    run.app.call("onboarding", "stop")
    s.uncovered.append("missing-model download, disk-short preflight, slow transfer, countdown hide: clean-Mac UAT")
    s.notes.append(f"VISUAL REVIEW OWED: {shots} d4a-* against the source-of-truth mockup")
    return s


def s_shell(run, speech):
    """D0: the new Setup shell shown for the session (DEBUG `onboarding present`), captured in
    light and dark at a few steps. Visual evidence only: positioning uses `goto`, which proves
    nothing about prerequisites. Appearance is set through the door and restored at the end."""
    s = Scenario("shell")
    shots = os.path.join(run.artifacts, "shots")
    os.makedirs(shots, exist_ok=True)
    before = run.app.call("settings", "get", "appearance").get("value")
    run.reset(s, "a fresh flow for the shell")
    r = run.app.call("onboarding", "present")
    s.expect(r.get("presented") is True, "present shows the Setup window", r.get("presented"))
    again = run.app.call("onboarding", "present")
    s.expect(again.get("presented") is True and again.get("step") == r.get("step"),
             "a second present refocuses without moving the flow", again.get("step"))
    for appearance in ("light", "dark"):
        run.app.call("settings", "set", "appearance", json.dumps(appearance))
        for step in SHELL_STEPS:
            run.app.call("onboarding", "goto", step)
            time.sleep(0.6)  # test-fixture-timer: the 0.32 s screen entrance settles before capture
            wid = window_id(run.app.client.pid, SETUP_TITLE)
            path = os.path.join(shots, f"shell-{appearance}-{step}.png")
            if wid is None:
                s.expect(False, f"Setup window found for {appearance}/{step}")
                continue
            s.expect(capture_window(wid, path), f"captured {appearance}/{step}", path)
            if appearance == "light" and step == "polishPick":
                title, texts = setup_window_ax(run.app.client.pid)
                s.expect(title == SETUP_TITLE, "the window's accessibility title is Setup", title)
                s.expect(any(t.startswith("Step 3 of 6") for t in texts),
                         "the step strip reads Step 3 of 6 to VoiceOver",
                         [t for t in texts if "Step" in t])
    run.app.call("settings", "set", "appearance", json.dumps(before))
    run.app.call("onboarding", "stop")
    st = run.status()
    s.expect(st.get("presented") is False, "stop closes the Setup window", st.get("presented"))
    s.notes.append(f"VISUAL REVIEW OWED: {shots} against the source-of-truth mockup")
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



def s_screens_d3b(run, speech):
    """D3b: See all's On your Mac / Cloud tabs and the cloud panel through real controls (AX
    press, keys posted to this app only), light and dark. Only a SYNTHETIC key is typed, into a
    provider slot the door reports EMPTY in this dev app's own credential store (never the
    production Keychain, never a founder key); the provider rejects it, and Add my key later must
    remove it again. Ollama is never offered. An accepted key, the model picker and its VoiceOver
    label need a real key and stay a human check."""
    from ui_helpers import set_attr
    s = Scenario("screens_d3b")
    pid = run.app.client.pid
    shots = os.path.join(run.artifacts, "shots")
    os.makedirs(shots, exist_ok=True)
    before = run.app.call("settings", "get", "appearance").get("value")
    names = {"openAI": "OpenAI", "gemini": "Google Gemini", "claude": "Claude"}
    synthetic = "uat-synthetic-0000"  # short on purpose: not a real key shape

    def shot(name):
        wid = window_id(pid, SETUP_TITLE)
        path = os.path.join(shots, f"d3b-{name}.png")
        s.expect(wid is not None and capture_window(wid, path), f"captured {name}", path)

    def settle(seconds=0.6):
        time.sleep(seconds)  # test-fixture-timer: the screen entrance and panel rise run on screen

    def press(name):
        b = setup_button(pid, name)
        s.expect(b is not None and ax_press(b), f"pressed {name}")
        settle(0.4)

    def has(name):
        return setup_button(pid, name) is not None

    def texts():
        return setup_window_ax(pid)[1]

    def saved():
        return run.app.call("status").get("savedKeys") or {}

    def to_see_all():
        run.app.call("onboarding", "profile", "--ram", "16", "--afm", "available")
        run.reset(s, "fresh flow to See all")
        run.app.call("onboarding", "present")
        run.send("next")
        run.send("chooseLanguage", value="en")
        run.send("next")
        run.send("chooseSpeech", value=speech)
        run.send("next")  # AI polish pick
        st = run.until(lambda x: x.get("step") == "polishPick", 4, "polishPick")
        s.expect(st.get("step") == "polishPick", "reached AI polish pick", st.get("step"))
        settle()
        press("See all")
        st = run.until(lambda x: x.get("step") == "polishSeeAll", 4, "polishSeeAll")
        s.expect(st.get("step") == "polishSeeAll", "See all is on screen", st.get("step"))
        settle()

    keys_before, empty = None, None
    for appearance in ("light", "dark"):
        run.app.call("settings", "set", "appearance", json.dumps(appearance))
        to_see_all()
        s.expect(has("On your Mac") and has("Cloud"), "See all shows the two tabs")
        s.expect(has("Continue with EG-1 Mini") and has("Skip AI polish"),
                 "On your Mac keeps the local tiles and footer")
        shot(f"{appearance}-mac-tab")
        press("Cloud")
        if keys_before is None:
            # The panel's first read settles each slot's presence ("unknown" until something reads
            # it); the baseline is taken once that read has finished.
            deadline = time.monotonic() + 5
            keys_before = saved()
            while time.monotonic() < deadline and "unknown" in keys_before.values():
                time.sleep(0.25)  # test-fixture-timer: the panel's key read runs on the lane
                keys_before = saved()
            s.expect("unknown" not in keys_before.values(),
                     "key slots before any key action (presence metadata only)", keys_before)
            empty = next((p for p in ("claude", "gemini", "openAI")
                          if keys_before.get(p) == "absent"), None)
        s.expect(all(has(n) for n in names.values()), "Cloud offers OpenAI, Google Gemini and Claude")
        t = texts()
        s.expect(not any("Ollama" in x for x in t) and not has("Set up later"),
                 "Ollama is never offered in Setup", [x for x in t if "Ollama" in x])
        s.expect(has("Check my key") and has("Add my key later") and has("Recommended options"),
                 "the panel's own footer shows")
        shot(f"{appearance}-cloud-tab")
        press("On your Mac")
        s.expect(has("Continue with EG-1 Mini"), "back on On your Mac")
        press("Cloud")
        s.expect(has("Check my key"), "Cloud again: the same panel")
        st = run.status()
        s.expect(st.get("step") == "polishSeeAll" and (st.get("choices") or {}).get("polish") is None,
                 "tab switches commit nothing", (st.get("step"), st.get("choices")))
        if appearance == "light":
            # Check my key runs ONLY on a provider whose slot is empty: a saved key loads into the
            # field, and checking it again could remove it if that check did not pass.
            if empty is None:
                s.uncovered.append(
                    f"empty-key and rejected-key checks: no empty provider slot here {keys_before}")
            else:
                press(names[empty])
                press("Check my key")  # empty field
                s.expect(any("Paste your" in x and "key in the box first" in x for x in texts()),
                         "an empty key asks for a paste first")
                field = setup_field(pid)
                s.expect(field is not None, f"one {names[empty]} key field")
                if field is not None:
                    set_attr(field, "AXFocused", True)
                post_keys(pid, text=synthetic)
                post_keys(pid, keycode=KEY_RETURN)  # Return checks the key (onSubmit)
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline and not any(
                        "That key did not work" in x for x in texts()):
                    time.sleep(0.5)  # test-fixture-timer: the provider answers over the network
                s.expect(any("That key did not work" in x for x in texts()),
                         f"{names[empty]} rejects the synthetic key and says so")
                shot(f"{appearance}-rejected")
                s.expect(saved().get(empty) == "present", "the checked key is stored until leaving",
                         saved().get(empty))
                press("Add my key later")
                st = run.until(lambda x: x.get("step") != "polishSeeAll", 4, "left See all")
                s.expect((st.get("choices") or {}).get("polish") == "off",
                         "Add my key later stores AI polish off and moves on",
                         (st.get("step"), st.get("choices")))
                after = None
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    after = saved().get(empty)
                    if after == "absent":
                        break
                    time.sleep(0.25)  # test-fixture-timer: the removal runs on the credential lane
                s.expect(after == "absent", "the rejected synthetic key was removed", after)
        else:
            press("Add my key later")
            st = run.until(lambda x: x.get("step") != "polishSeeAll", 4, "left See all")
            s.expect((st.get("choices") or {}).get("polish") == "off", "dark: Add my key later stores off",
                     st.get("choices"))
    keys_after = saved()
    s.expect(keys_after == keys_before, "every key slot ends as it started", (keys_before, keys_after))
    s.uncovered.append("an accepted key, the model picker and its VoiceOver label: needs a real key "
                       "(human check)")
    run.app.call("settings", "set", "appearance", json.dumps(before))
    return s


def s_screens_e(run, speech):
    """E: the closing film reached the real way (Practice's success event), in light and dark.
    Light: Watch again, then Launch EnviousWispr before the last scene skips the film; dark: the
    film plays to its last scene and Launch EnviousWispr finishes it. Both complete Setup
    durably. Permissions are simulated through the door and cleared at the end."""
    s = Scenario("screens_e")
    pid = run.app.client.pid
    shots = os.path.join(run.artifacts, "shots")
    os.makedirs(shots, exist_ok=True)
    before = run.app.call("settings", "get", "appearance").get("value")
    film_seconds = 35.5  # FilmScript.length (seven scenes)

    def shot(name):
        wid = window_id(pid, SETUP_TITLE)
        path = os.path.join(shots, f"e-{name}.png")
        s.expect(wid is not None and capture_window(wid, path), f"captured {name}", path)

    def press(name):
        b = setup_button(pid, name)
        s.expect(b is not None and ax_press(b), f"pressed {name}")

    def to_film(label):
        run.reset(s, f"a fresh flow to the film ({label})")
        run.app.call("onboarding", "present")
        run.walk_to_downloads(s, speech)
        run.send("next")
        run.app.call("onboarding", "permissions", "--mic", "granted", "--ax", "granted")
        st = run.until(lambda x: x.get("step") == "key", 8, "key")
        s.expect(st.get("step") == "key", "granted permissions move to Key", st.get("step"))
        run.send("next")
        st = run.until(lambda x: x.get("step") == "practice", 60, "practice")
        s.expect(st.get("step") == "practice", "readiness opens Practice", st.get("step"))
        r = run.send("practiceSucceeded")
        s.expect(r.get("step") == "film", "a practice success opens the film", r.get("step"))
        time.sleep(1.0)  # test-fixture-timer: the film's first scene rises on screen

    for appearance in ("light", "dark"):
        run.app.call("settings", "set", "appearance", json.dumps(appearance))
        to_film(appearance)
        s.expect(setup_button(pid, "Launch EnviousWispr") is not None
                 and setup_button(pid, "Watch again") is not None,
                 "the film shows Launch EnviousWispr and Watch again")
        shot(f"{appearance}-scene1")
        time.sleep(9.0)  # test-fixture-timer: into the third scene (words land)
        shot(f"{appearance}-scene3")
        if appearance == "light":
            press("Watch again")
            time.sleep(1.0)  # test-fixture-timer: back on the first scene
            shot("light-replayed")
            press("Launch EnviousWispr")  # before the last scene: skips the film
        else:
            time.sleep(film_seconds - 9.0)  # test-fixture-timer: the film reaches its last scene
            shot("dark-last-scene")
            press("Launch EnviousWispr")  # on the last scene: finishes the film
        st = run.until(lambda x: x.get("active") is False, 6, "completed")
        s.expect(st.get("active") is False and st.get("legacyState") == "completed",
                 f"{appearance}: Launch EnviousWispr completes Setup durably",
                 (st.get("active"), st.get("legacyState")))
        run.app.call("onboarding", "permissions", "--clear")
    s.uncovered.append("D9 main window after Launch EnviousWispr and the film_finished row in "
                       "PostHog: D7a cutover and the telemetry round")
    run.app.call("settings", "set", "appearance", json.dumps(before))
    return s


DE_STEPS = ["welcome", "language", "speechPick", "speechCompare", "polishIntro", "polishPick",
            "polishSeeAll", "downloads", "permissions", "key", "gettingReady", "film"]


def s_screens_de(run, speech):
    """G: every real Setup screen in German, light and dark, for the truncation and layout
    review (plan §3.7). The app must already run in German (`AppleLanguages (de)` in the dev
    domain, set and removed by the operator around the run). Positioning uses `goto`, so this
    is visual evidence only; the See all Cloud tab and the film's last scene are captured too."""
    s = Scenario("screens_de")
    pid = run.app.client.pid
    shots = os.path.join(run.artifacts, "shots")
    os.makedirs(shots, exist_ok=True)
    before = run.app.call("settings", "get", "appearance").get("value")
    run.app.call("onboarding", "profile", "--ram", "16", "--afm", "available", "--lang", "de")
    run.reset(s, "a fresh flow for the German sweep")
    run.app.call("onboarding", "present")

    def shot(name):
        wid = window_id(pid, SETUP_TITLE)
        path = os.path.join(shots, f"de-{name}.png")
        s.expect(wid is not None and capture_window(wid, path), f"captured {name}", path)

    for appearance in ("light", "dark"):
        run.app.call("settings", "set", "appearance", json.dumps(appearance))
        # A fresh flow per appearance: a ready flow moves Getting ready on to Practice by itself.
        run.reset(s, f"a fresh flow for the {appearance} screens")
        run.app.call("onboarding", "present")
        for step in DE_STEPS:
            if step == "permissions":
                # Real grants skip Permissions; the door's simulation shows the screen itself.
                run.app.call("onboarding", "permissions", "--mic", "notDetermined", "--ax", "denied")
            run.app.call("onboarding", "goto", step)
            time.sleep(0.8)  # test-fixture-timer: the screen entrance and rises settle
            on = run.status().get("step")
            s.expect(on == step, f"{appearance}: the requested screen is on screen ({step})", on)
            shot(f"{appearance}-{step}")
            if step == "permissions":
                run.app.call("onboarding", "permissions", "--clear")
            if step == "polishPick" and appearance == "light":
                _, texts = setup_window_ax(pid)
                s.expect(any(t.startswith("Schritt 3 von 6") for t in texts),
                         "the app runs in German (the step strip reads Schritt 3 von 6)",
                         [t for t in texts if "Schritt" in t or "Step" in t])
            if step == "polishSeeAll":
                cloud = setup_button(pid, "Cloud")
                s.expect(cloud is not None and ax_press(cloud), "pressed Cloud")
                time.sleep(0.6)  # test-fixture-timer: the panel rises
                shot(f"{appearance}-polishSeeAll-cloud")
            if step == "film":
                time.sleep(34.0)  # test-fixture-timer: the film reaches its last scene
                shot(f"{appearance}-film-last")
        # Practice with its editor: reached the real way (installed models, granted permissions).
        run.reset(s, f"a fresh flow to Practice ({appearance})")
        run.app.call("onboarding", "present")
        run.walk_to_downloads(s, speech)
        run.send("next")
        run.app.call("onboarding", "permissions", "--mic", "granted", "--ax", "granted")
        run.until(lambda x: x.get("step") == "key", 8, "key")
        run.send("next")
        st = run.until(lambda x: x.get("step") == "practice" and x.get("practiceUsable") is True,
                       60, "practice usable")
        s.expect(st.get("step") == "practice" and st.get("practiceUsable") is True,
                 f"{appearance}: Practice is ready", (st.get("step"), st.get("practiceUsable")))
        time.sleep(0.8)  # test-fixture-timer: the editor rises
        _, texts = setup_window_ax(pid)
        # The editor's hint is hidden from VoiceOver by design; the German practice line is read.
        s.expect(any("Ähm, ich glaube" in t for t in texts),
                 f"{appearance}: the German Practice line is on screen")
        shot(f"{appearance}-practice")
        run.app.call("onboarding", "permissions", "--clear")
    run.app.call("settings", "set", "appearance", json.dumps(before))
    run.app.call("onboarding", "profile", "--clear")
    run.app.call("onboarding", "stop")
    s.notes.append(f"VISUAL REVIEW OWED: {shots} de-* for truncation and layout")
    return s

def s_practice_spoken(run, speech):
    """U10/U11 (plan §11.1): accept every recommendation, reach Practice the real way, and speak
    the practice line through the audio rig (BlackHole) while holding the real dictation key.
    The take must land in the Practice box: the editor's text is read back through AX and must
    contain the cleaned line. Inputs from the operator, run only by name:
    EW_UAT_PRACTICE_LANG (en|de; for de the app must already run in German),
    EW_UAT_PRACTICE_AUDIO (the spoken line, e.g. Azure TTS), EW_UAT_PRACTICE_EXPECT (the cleaned
    line, compared without case or punctuation)."""
    import re
    import audio_rig
    import wispr_eyes as w
    s = Scenario("practice_spoken")
    lang = os.environ.get("EW_UAT_PRACTICE_LANG", "en")
    audio = os.environ.get("EW_UAT_PRACTICE_AUDIO", "")
    expected = os.environ.get("EW_UAT_PRACTICE_EXPECT", "")
    if not (audio and os.path.exists(audio) and expected):
        s.expect(False, "practice audio and expected line given", (audio, expected))
        return s
    pid = run.app.client.pid
    shots = os.path.join(run.artifacts, "shots")
    os.makedirs(shots, exist_ok=True)

    def norm(text):
        return " ".join(re.sub(r"[^\w\s]", " ", text.lower()).split())

    run.reset(s, "a fresh flow for the spoken practice take")
    run.app.call("onboarding", "present")
    run.send("next")
    run.send("chooseLanguage", value=lang)
    run.send("next")
    rec = run.status().get("recommended") or {}
    s.notes.append(f"recommended: {rec}")
    run.send("chooseSpeech", value=rec.get("speech") or speech)
    run.send("next")
    run.send("next")  # polish intro to the pick
    reply = run.send("next")  # the preselected (recommended) card
    # Downloads, or straight past it when every chosen model is already installed.
    s.expect(reply.get("step") in ("downloads", "permissions", "key"),
             "the recommended polish moves on from the pick", reply.get("step"))
    chosen = run.status().get("choices") or {}
    s.notes.append(f"choices: {chosen}")
    s.expect(chosen.get("polish") == rec.get("polish"),
             "the committed polish is the recommended one", (chosen.get("polish"), rec.get("polish")))
    if run.status().get("step") == "downloads":
        run.send("next")
    run.app.call("onboarding", "permissions", "--mic", "granted", "--ax", "granted")
    run.until(lambda x: x.get("step") == "key", 8, "key")
    run.send("next")
    st = run.until(lambda x: x.get("step") == "practice" and x.get("practiceUsable") is True,
                   180, "practice usable")
    s.expect(st.get("step") == "practice" and st.get("practiceUsable") is True,
             "Practice is ready with the recommended models", (st.get("step"), st.get("practiceUsable")))
    if st.get("step") != "practice":
        run.app.call("onboarding", "permissions", "--clear")
        run.app.call("onboarding", "stop")
        return s
    time.sleep(1.0)  # test-fixture-timer: the editor rises and takes focus
    wid = window_id(pid, SETUP_TITLE)
    if wid is not None:
        capture_window(wid, os.path.join(shots, f"practice-{lang}-before.png"))
    try:
        # Bring forward THIS build by path: `open -b` can launch another registered copy (#4556).
        bundle = run.app.bundle

        class ThisBuild(audio_rig.AppTarget):
            def activate(self):
                subprocess.run(["open", bundle], capture_output=True)

        with audio_rig.AudioRig(target=ThisBuild("com.enviouswispr.app.dev")):
            result = w.record_tts(sentence=f"practice line ({lang})", audio=audio,
                                  wait=25.0, until_terminal=True)
    except Exception as exc:  # SETUP FAILED or COULD NOT TELL from the rig: not an app result
        s.expect(False, "the audio rig ran the take", repr(exc))
        result = {}
    s.notes.append(f"raw: {result.get('raw_asr')!r}")
    s.notes.append(f"polished: {result.get('polished')!r} via {result.get('provider')!r}")
    time.sleep(1.0)  # test-fixture-timer: the editor shows the pasted text
    _, texts = setup_window_ax(pid)
    want = norm(expected)
    hit = [t for t in texts if want in norm(t)]
    s.expect(bool(hit), "the cleaned practice line landed in the Practice box",
             [t for t in texts if len(t) > 20][:6])
    s.expect(bool(result.get("success")), "the take completed in the app's own log",
             result.get("raw_asr"))
    wid = window_id(pid, SETUP_TITLE)
    if wid is not None:
        capture_window(wid, os.path.join(shots, f"practice-{lang}-after.png"))
    s.notes.append(f"after the take the step is {run.status().get('step')}")
    run.app.call("onboarding", "permissions", "--clear")
    run.app.call("onboarding", "stop")
    return s


def expected_pick(table, facts):
    """The first row of a Setup rules table whose conditions all hold (plan §3.2), evaluated
    here from the rules file and this Mac's own facts: an oracle independent of SetupRules."""
    for row in table:
        when = row.get("when") or {}
        ok = True
        for key, want in when.items():
            if key == "memoryAtLeastGiB":
                ok = ok and facts["memory_gib"] >= want
            elif key == "memoryBelowGiB":
                ok = ok and facts["memory_gib"] < want
            elif key == "lockedNonEnglish":
                ok = ok and facts["locked_non_english"] == want
            elif key == "languageIn":
                ok = ok and facts["language_in"].get(want, False)
            elif key == "primary":
                ok = ok and facts.get("primary") == want
            else:
                raise HarnessError(f"rules condition {key} has no oracle here")
        if ok:
            return row["pick"]
    raise HarnessError("a rules table had no catch-all row")


def s_detect(run, speech):
    """The recommendation on THIS Mac's real hardware (no fake profile): Setup's recommended
    speech engine and AI polish size must equal the rules file's answer for this Mac's memory and
    the chosen language, computed independently here. Languages: en (Parakeet's set) and hi
    (outside it, plan U12). Run it on a fresh Mac (fresh_mac.py prepare) so nothing installed or
    saved can influence the advice."""
    s = Scenario("detect")
    rules_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                              "Sources/EnviousWisprServices/Resources/setup-rules.json")
    with open(rules_path) as fh:
        rules = json.load(fh)
    memory_gib = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True,
                                    text=True, check=True).stdout) // (1 << 30)
    s.notes.append(f"this Mac: {memory_gib} GiB; rules {rules.get('rulesVersion')} "
                   f"revision {rules.get('revision')}")
    run.app.call("onboarding", "profile", "--clear")
    # Parakeet's language set, by the languages the plan names (U10 en, U12 hi).
    for language, in_parakeet in (("en", True), ("hi", False)):
        run.reset(s, f"a fresh flow for the {language} advice")
        run.app.call("onboarding", "present")
        run.send("next")
        run.send("chooseLanguage", value=language)
        st = run.status()
        rec = st.get("recommended") or {}
        facts = {"memory_gib": memory_gib, "locked_non_english": language != "en",
                 "language_in": {"parakeet": in_parakeet}}
        want_speech = expected_pick(rules["speech"]["choice"], facts)
        want_polish = expected_pick(rules["polish"]["primary"], facts)
        s.expect(rec.get("speech") == want_speech,
                 f"{language}: the recommended speech engine follows the rules",
                 (rec.get("speech"), want_speech))
        s.expect(rec.get("polish") == want_polish,
                 f"{language}: the recommended AI polish size follows this Mac's memory",
                 (rec.get("polish"), want_polish))
        s.expect(rec.get("rulesVersion") == rules.get("rulesVersion"),
                 f"{language}: Setup reports the rules it used", rec.get("rulesVersion"))
    run.app.call("onboarding", "stop")
    return s


SCENARIOS = {
    "fresh": s_fresh, "resume": s_resume, "restart": s_restart, "profiles": s_profiles,
    "permissions": s_permissions, "faults": s_faults, "completion": s_completion,
    "interrupted": s_interrupted, "consent_off": s_consent_off,
    "shell": s_shell, "screens_d1": s_screens_d1, "screens_d2": s_screens_d2,
    "screens_d3a": s_screens_d3a, "screens_d5": s_screens_d5,
    "screens_d4a": s_screens_d4a,
    "screens_d4b": s_screens_d4b,
    "screens_d3b": s_screens_d3b,
    "screens_e": s_screens_e,
    "screens_de": s_screens_de,
    "practice_spoken": s_practice_spoken,
    "detect": s_detect,
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
    # Only an explicit --scenario runs these: screens_de needs the app in German (AppleLanguages
    # de); practice_spoken needs the operator's audio inputs.
    names = args.scenario or [name for name in SCENARIOS
                              if name not in ("screens_de", "practice_spoken")]
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
