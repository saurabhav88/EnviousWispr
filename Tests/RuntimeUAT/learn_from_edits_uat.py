#!/usr/bin/env python3
"""Live UAT for the Self-Learning Dictionary (#996, auto-learn with Undo), the
founder's pre-PR gate, end to end.

    python3 Tests/RuntimeUAT/learn_from_edits_uat.py --run-dir <dir> --export <fp32 dir>

Run with the screen UNLOCKED and hands off the Mac. It dictates a sentence
through the speaker into a real TextEdit document, makes a scripted fix through
accessibility, waits for the word to be SAVED (`learn_added`) and for the
3-second Undo pill (`learn_undo_shown`), presses Undo through accessibility,
lets another pill expire under the pointer, reads Your Words for the sparkle
and the Auto-learned filter, and reads every verdict from `app.log` and from
`custom-words.json`. Every step waits on a SIGNAL the app produces, with a
deadline as the fallback, never as the mechanism (`wait_for` returns whether
the signal arrived). The one thing the app does not log is the pill LEAVING
without Undo: that verdict is the Undo button's absence through accessibility
inside a wall-clock bound, plus the word still being in the file.

Codified AFTER a hand-driven round 1 (founder 2026-09-20: the first UAT round
is driven by hand, the script comes after) and rewritten for the 2026-09-21
pivot (no question to answer, no waiting list: the word is added at once and a pill
offers Undo for 3 seconds; hover does not pause it). What round 1 taught this
file still holds: the heard form is whatever the recogniser DELIVERED between
two anchor words, never a fixed regex; the target must be a word the
recogniser does not already know; `custom-words.json` is a dictionary, so
"empty" keeps its shape with `words: []`; `test_recording` answers a bool and
the delivered text is read from TextEdit; the pill never takes keyboard focus;
and a take must not start until the menu bar's "Start Recording" item exists.

WHAT IT TOUCHES AND PUTS BACK
-----------------------------
The dev app shares `~/Library/Application Support/EnviousWispr/custom-words.json`
with the shipped app (code-uat.md RULE: uat-writes-reach-the-founders-REAL-data).
It is snapshotted byte for byte before the first case and restored, with the
app down, in `finally`; the restore is verified by bytes AND by parsed per-key
equality. The `learnFromEdits` default in `com.enviouswispr.app` and the
launchd `EW_LEARN_FROM_EDITS_JUDGE_EXPORT` value are snapshotted and restored
the same way, as are the learned-word check doors: `EW_LEARNED_CHECK_UAT_APPROVE`
and both engines' adapter doors (`EW_LEARNED_CHECK_EG1_ADAPTER`,
`EW_LEARNED_CHECK_EG1_THRESHOLD`, `EW_LEARNED_CHECK_S1_ADAPTER`,
`EW_LEARNED_CHECK_S1_THRESHOLD`). The retired ask-first ledger (`correction-proposals.json`) is
NEVER written or restored by this script: the app deletes it once at launch,
and the run records only whether it was present before and after. A failed
restore exits 3 and overrides every pass.

PRECONDITIONS, CHECKED, LOUD
----------------------------
1. Screen unlocked (a locked screen has no text field; the paste reports
   `tier=clipboard_only` and the run LOOKS real).
2. Exactly one dev instance, and it is THIS worktree's build, or none.
3. The door is ACTIVE for this launch: the app's own
   `learn-from-edits UAT door ACTIVE` line after every relaunch.
4. TextEdit's text area can be written and read back through accessibility
   (proved before any verdict depends on it).

EXIT CODES: 0 every arm PASS, 1 a product FAIL, 2 INSTRUMENT (the run could not
produce a verdict), 3 restore unverified (overrides everything).
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import simulate_input as si  # noqa: E402
import wispr_eyes as w  # noqa: E402
from ui_helpers import (  # noqa: E402
    find_app_pid, find_element, get_attr, get_ax_app, perform_action, set_attr,
)

WORKTREE = os.path.dirname(os.path.dirname(HERE))
APP = os.path.join(WORKTREE, "build", "EnviousWispr Local.app")
APP_BIN = os.path.join(APP, "Contents", "MacOS", "EnviousWispr")
LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")
SUPPORT = os.path.expanduser("~/Library/Application Support/EnviousWispr")
WORDS = os.path.join(SUPPORT, "custom-words.json")
# The retired ask-first ledger. Read for the receipt only; never written.
LEGACY_LEDGER = os.path.join(SUPPORT, "correction-proposals.json")
DOMAIN = "com.enviouswispr.app"
ENV_KEY = "EW_LEARN_FROM_EDITS_JUDGE_EXPORT"
DOOR_ACTIVE = "learn-from-edits UAT door ACTIVE"

# The pairs: the founder's own custom words (2026-09-20: "try EnviousWispr and
# other custom words that I have set up historically"), spoken through the
# local voice as their known MISHEARING so the recogniser delivers that form
# with the word list cleared. Judge v9 scores every one as a correction
# (p1 >= 0.9998, scored through the Python path before this run). The negative
# control is a rewrite v9 refuses (p1 = 0.0). `heard` is a case-insensitive
# regex for the delivered form; the exact target already present is INSTRUMENT.
class Pair:
    """A sentence with ONE word the recogniser is expected to mishear, framed by
    two anchor words. The heard form is read from the delivered text between the
    anchors, so the case follows what the recogniser actually produced."""

    def __init__(self, sentence, expect, before, after, correct, negative=None):
        self.sentence, self.expect, self.correct = sentence, expect, correct
        self.before, self.after = before, after
        self.negative = negative  # (from, to) for the rewrite control

    def heard_in(self, text):
        m = re.search(re.escape(self.before) + r"\s+(.+?)\s+" + re.escape(self.after), text, re.IGNORECASE)
        return m.group(1) if m else None

# Targets the recogniser does NOT know (round 1, 2026-09-20: it delivered
# "Zorab", "PixieI" and "that ish" for these), so there is something to fix.
# A word typed in by hand, with no learned marks: the control the Auto-learned
# filter must hide. Seeded before the expiry case (same launch as the Your
# Words case that reads it).
MANUAL_WORD = "Manual Control"

PAIRS = {
    "new-word-undo": Pair("Ask sorab about the invoices today", "invoices", "Ask", "about", "Saurabh"),
    "existing-word": Pair("Check the pixii dashboard tonight", "dashboard", "the", "dashboard", "pixii"),
    "expiry-under-hover": Pair("Send the report to Vaish today", "report", "to", "today", "Vaish"),
    "admission-refused": Pair("Ask sorab about the invoices today", "invoices", "Ask", "about", "Saurabh"),
    "negative": Pair("Send the invoices to the team today", "team", "Send", "to", "the invoices",
                     negative=("the invoices", "a coffee")),
    "toggle-off": Pair("Ask sorab about the invoices today", "invoices", "Ask", "about", "Saurabh"),
    "next-dictation": Pair("Ask sorab about the invoices today", "invoices", "Ask", "about", "Saurabh"),
    "deletion-only": Pair("Send the report to Vaish today", "report", "Send", "to", "report"),
    "learned-check": Pair("The day Tuist regenerated my whole project", "project", "day", "regenerated", "Tuist"),
}

results = []
run_dir = None


class Aborted(Exception):
    """INSTRUMENT: the run cannot produce a meaningful verdict."""


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def record(arm, status, detail=""):
    results.append({"arm": arm, "status": status, "detail": detail, "at": now_iso()})
    print(f"  {status}  {arm}{('  :: ' + detail) if detail else ''}", flush=True)


def check(arm, ok, detail=""):
    record(arm, "PASS" if ok else "FAIL", detail)
    return ok


def wait_for(what, predicate, deadline=45.0, poll=0.25):
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        try:
            value = predicate()
        except Exception as error:  # a flaky read is not a signal
            value = None
            print(f"    (read error while waiting for {what}: {error})")
        if value:
            return value
        time.sleep(poll)  # settle: poll interval between reads of the signal
    print(f"    (no signal: {what} within {deadline:.0f}s)")
    return None


def save(name, data):
    path = os.path.join(run_dir, name)
    with open(path, "w") as fh:
        if isinstance(data, (dict, list)):
            json.dump(data, fh, indent=1, sort_keys=True, default=str)
        else:
            fh.write(str(data))
    return path


# --- log ------------------------------------------------------------------

def log_mark():
    # aware, like every other harness mark: `app.log` stamps carry an offset
    return datetime.now().astimezone()


def log_since(mark):
    return "\n".join(w.log_entries_since(mark))


def has(mark, token):
    return token in log_since(mark)


def learn_lines(mark):
    return [line for line in w.log_entries_since(mark) if "[LearnFromEdits]" in line]


# --- screen / app ----------------------------------------------------------

def screen_is_locked():
    import Quartz
    d = Quartz.CGSessionCopyCurrentDictionary()
    return bool(d.get("CGSSessionScreenIsLocked", 0)) if d else False


def running_instances():
    """Every running EnviousWispr bundle, {pid: executable}: the shared guard,
    which also sees a Release test host (`EnviousWispr.app`, production bundle
    id) that a `Local.app` regex would miss and TERM past."""
    from instance_guard import running_enviouswispr_instances
    # The guard keys by the pid's TEXT; AX needs the number (a str pid made
    # `AXUIElementCreateApplication` answer an app with no windows, front-door
    # run 2026-09-20 16:46Z).
    return {int(pid): path for pid, path in running_enviouswispr_instances().items()}


def stop_app():
    for pid, path in running_instances().items():
        if path == APP_BIN:
            subprocess.run(["kill", "-TERM", str(pid)], check=False)
    if not wait_for("this worktree's app to exit",
                    lambda: all(p != APP_BIN for p in running_instances().values()), deadline=20.0):
        raise Aborted("the dev app did not exit within 20s; refusing to touch settings under it")


def expected_door_threshold():
    """The detection threshold of the export the launch environment names."""
    export = launchctl_get()
    if not export:
        raise Aborted(f"{ENV_KEY} is unset; the door cannot be checked")
    with open(os.path.join(export, "training-manifest-shaped.json")) as fh:
        return float(json.load(fh)["decision_config"]["detection_threshold"])


def start_app():
    mark = log_mark()
    subprocess.run(["open", "-n", APP], check=True)
    if not wait_for("the app's door banner", lambda: has(mark, DOOR_ACTIVE), deadline=90.0):
        raise Aborted("the relaunched app never logged the UAT door as ACTIVE")
    banner = [l for l in w.log_entries_since(mark) if DOOR_ACTIVE in l][-1]
    # The banner must name the export this run installed and ITS threshold (the
    # export's own decision config), never a remembered revision's: the judge
    # under test changes between rounds (v9 in 2026-09-20, v31 from 2026-09-25).
    expected = expected_door_threshold()
    got = re.search(r"threshold=([0-9.eE-]+)", banner)
    if "arm=classifier" not in banner or got is None or abs(float(got.group(1)) - expected) > 1e-9:
        raise Aborted(f"door banner does not name the installed export's threshold {expected}: {banner}")
    if not wait_for("startup scan", lambda: has(mark, "scan finished"), deadline=60.0):
        raise Aborted("the app did not reach a ready state")
    # The menu-driven take taps the status item's "Start Recording". Right after
    # launch that item does not exist yet, and the harness's tap then falls
    # into a fuzzy system-wide menu walk that never returns (scripted run 3,
    # 2026-09-20). Wait for the exact item, the same lookup `tap` tries first.
    w.connect()
    if not wait_for("the Start Recording menu item",
                    lambda: w._find_match(w._app, "Start Recording", None, exact=True), deadline=30.0):
        raise Aborted("the relaunched app never exposed its Start Recording menu item")
    time.sleep(1.0)  # settle: the overlay host and paste registry finish their first render; no ack
    return banner


def app_pid():
    for pid, path in running_instances().items():
        if path == APP_BIN:
            return pid
    return None


# --- defaults / launchctl --------------------------------------------------

def defaults_snapshot():
    r = subprocess.run(["defaults", "read-type", DOMAIN, "learnFromEdits"], capture_output=True, text=True)
    if r.returncode != 0:
        return {"present": False}
    v = subprocess.run(["defaults", "read", DOMAIN, "learnFromEdits"], capture_output=True, text=True).stdout.strip()
    return {"present": True, "type": r.stdout.strip(), "value": v}


def defaults_write_bool(value):
    subprocess.run(["defaults", "write", DOMAIN, "learnFromEdits", "-bool", "true" if value else "false"], check=True)


def defaults_restore(snap):
    if not snap["present"]:
        subprocess.run(["defaults", "delete", DOMAIN, "learnFromEdits"], check=False, capture_output=True)
        return
    if "boolean" in snap["type"]:
        defaults_write_bool(snap["value"] in ("1", "true", "YES"))
    elif "integer" in snap["type"]:
        subprocess.run(["defaults", "write", DOMAIN, "learnFromEdits", "-int", snap["value"]], check=True)
    else:
        subprocess.run(["defaults", "write", DOMAIN, "learnFromEdits", snap["value"]], check=True)


CHECK_ENV_KEY = "EW_LEARNED_CHECK_UAT_APPROVE"
# Every engine's real checker Debug doors (#3105: EG-1 and S1-mini). This run clears
# them so its no-checker cases see no checker, whichever engine is selected and
# whatever the founder's dev build is testing, and restores them.
CHECKER_DOOR_KEYS = (
    "EW_LEARNED_CHECK_EG1_ADAPTER", "EW_LEARNED_CHECK_EG1_THRESHOLD",
    "EW_LEARNED_CHECK_S1_ADAPTER", "EW_LEARNED_CHECK_S1_THRESHOLD",
)


def env_get(key):
    # A failed read raises: it must never look like an unset door. An unset key
    # exits 0 with empty output (measured 2026-09-26).
    v = subprocess.run(["launchctl", "getenv", key], capture_output=True, text=True, check=True).stdout.strip()
    return v or None


def env_set(key, value):
    if value is None:
        subprocess.run(["launchctl", "unsetenv", key], check=True)
    else:
        subprocess.run(["launchctl", "setenv", key, value], check=True)


def check_door_get():
    return env_get(CHECK_ENV_KEY)


def check_door_set(value):
    if value is None:
        subprocess.run(["launchctl", "unsetenv", CHECK_ENV_KEY], check=True)
    else:
        subprocess.run(["launchctl", "setenv", CHECK_ENV_KEY, value], check=True)


def launchctl_get():
    return env_get(ENV_KEY)


def launchctl_set(value):
    if value is None:
        subprocess.run(["launchctl", "unsetenv", ENV_KEY], check=True)
    else:
        subprocess.run(["launchctl", "setenv", ENV_KEY, value], check=True)


# --- files -----------------------------------------------------------------

def file_snapshot(path):
    if not os.path.exists(path):
        return {"exists": False}
    with open(path, "rb") as fh:
        data = fh.read()
    st = os.stat(path)
    try:
        parsed = json.loads(data.decode("utf-8"))
    except Exception:
        parsed = None
    return {"exists": True, "bytes": data, "mode": st.st_mode & 0o777,
            "sha256": hashlib.sha256(data).hexdigest(), "parsed": parsed}


def file_restore(path, snap):
    if not snap["exists"]:
        if os.path.exists(path):
            os.remove(path)
        return
    tmp = path + ".uat-restore"
    with open(tmp, "wb") as fh:
        fh.write(snap["bytes"])
    os.chmod(tmp, snap["mode"])
    os.replace(tmp, path)


def keyed(parsed, kind):
    """Parsed content as {key: entry} for the per-key restore check."""
    if parsed is None:
        return None
    if kind == "words":
        entries = parsed.get("words", parsed) if isinstance(parsed, dict) else parsed
        if isinstance(entries, dict):
            return entries
        return {e.get("id", i): e for i, e in enumerate(entries)}
    return parsed


def verify_restore(path, snap, kind):
    after = file_snapshot(path)
    if snap["exists"] != after["exists"]:
        return False, "existence differs"
    if not snap["exists"]:
        return True, "absent before and after"
    if snap["sha256"] != after["sha256"]:
        return False, "bytes differ"
    if keyed(snap["parsed"], kind) != keyed(after["parsed"], kind):
        return False, "parsed per-key content differs"
    return True, "bytes and per-key content equal"


def words_now():
    snap = file_snapshot(WORDS)
    return keyed(snap["parsed"], "words") if snap["exists"] else {}


def legacy_ledger_present():
    """The retired ask-first file. The app removes it once at launch; this
    script never writes it and reports only whether it exists."""
    return os.path.exists(LEGACY_LEDGER)


def word_named(name):
    for entry in (words_now() or {}).values():
        if isinstance(entry, dict) and str(entry.get("canonical", "")).lower() == name.lower():
            return entry
    return None


def learned_alias(pair, heard_text):
    """The heard form is on the word AND marked as learned (the sparkle's
    source: `learnedAliases`), which is what separates an auto-learned
    sound-alike from one typed in by hand."""
    word = word_named(pair.correct)
    if not word:
        return False
    aliases = [a.lower() for a in (word.get("aliases") or [])]
    learned = [a.lower() for a in (word.get("learnedAliases") or [])]
    return heard_text.lower() in aliases and heard_text.lower() in learned


def seeded_words_like(snapshot, canonical):
    """An otherwise empty list that already carries ONE word by canonical (no
    sound-alikes), for the existing-word case: the fix must attach the
    mishearing to it rather than create a second word."""
    base = empty_words_like(snapshot)
    parsed = dict(base["parsed"])
    parsed["words"] = [{"id": "00000000-0000-4000-8000-0000000000aa", "canonical": canonical,
                        "aliases": [], "category": "general", "source": "user", "isEnabled": True}]
    raw = json.dumps(parsed).encode("utf-8")
    return {"exists": True, "bytes": raw, "mode": 0o600, "sha256": hashlib.sha256(raw).hexdigest(), "parsed": parsed}


# The misspellings a user would already have fixed for the learned-check word:
# the check asks only where one of them reappears (founder 2026-09-25, known
# aliases only). "twist" and "Twoist" are hearings of Tuist from the founder's own
# dictionary; "toast" is the unit tests' twin. A take whose hearing is none of them
# aborts as an instrument result, never a failure.
LEARNED_ALIASES = ["toast", "twist", "Twoist"]


def learned_word_seed(snapshot, canonical):
    """One word the app LEARNED (#3105): `learnedAt` set, with the misspellings
    it was learned from. Its uses go through the learned-word check only."""
    base = empty_words_like(snapshot)
    parsed = dict(base["parsed"])
    parsed["words"] = [{"id": "00000000-0000-4000-8000-0000000000bb", "canonical": canonical,
                        "aliases": list(LEARNED_ALIASES), "category": "general", "source": "user",
                        "isEnabled": True, "learnedAliases": list(LEARNED_ALIASES),
                        "learnedAt": 780000000}]
    raw = json.dumps(parsed).encode("utf-8")
    return {"exists": True, "bytes": raw, "mode": 0o600, "sha256": hashlib.sha256(raw).hexdigest(), "parsed": parsed}


# --- TextEdit ---------------------------------------------------------------

def textedit_area(path):
    pid = find_app_pid("TextEdit")
    if pid is None:
        return None
    app = get_ax_app(pid)
    want = os.path.basename(path)
    for window in (get_attr(app, "AXWindows") or []):
        if str(get_attr(window, "AXTitle") or "") != want:
            continue
        return find_element(window, role="AXTextArea")
    return None


def field_text(path):
    area = textedit_area(path)
    if area is None:
        return None
    return str(get_attr(area, "AXValue") or "")


def new_doc(name):
    path = f"/tmp/ew-lfe-{name}.txt"
    # A window left open by an earlier run would see the truncation below as "changed by another
    # application" and raise an autosave sheet that takes focus from the text area, so every paste
    # falls back to clipboard-only. Close any such window first.
    close_doc(path)
    if textedit_area(path) is not None:
        close_doc(path)  # a Revert above keeps the window open; close it once more
    open(path, "w").close()
    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    if not wait_for("the TextEdit window", lambda: textedit_area(path) is not None, deadline=15.0):
        raise Aborted("TextEdit did not open the document")
    time.sleep(1.0)  # settle: window focus; macOS exposes no observable ack for it
    return path


def prove_oracle(path):
    marker = "ew-uat-oracle-check"
    area = textedit_area(path)
    set_attr(area, "AXValue", marker)
    got = wait_for("the oracle to read back", lambda: (field_text(path) or "").strip() == marker, deadline=5.0)
    set_attr(area, "AXValue", "")
    cleared = wait_for("the oracle to clear", lambda: (field_text(path) or "") == "", deadline=5.0)
    if not (got and cleared):
        raise Aborted("TextEdit's text area could not be written and read back through accessibility")


def close_doc(path):
    pid = find_app_pid("TextEdit")
    if pid is None:
        return
    app = get_ax_app(pid)
    for window in (get_attr(app, "AXWindows") or []):
        if str(get_attr(window, "AXTitle") or "") == os.path.basename(path):
            button = get_attr(window, "AXCloseButton")
            if button is not None:
                perform_action(button, "AXPress")
    # An unsaved-changes sheet may follow ("Delete" discards), or the autosave-conflict sheet
    # ("Revert" keeps the file on disk). Neither has an ack.
    for _ in range(3):
        time.sleep(0.5)  # settle: the sheet appears with no observable ack
        pid = find_app_pid("TextEdit")
        if pid is None:
            break
        app = get_ax_app(pid)
        button = (find_element(app, role="AXButton", title="Delete")
                  or find_element(app, role="AXButton", title="Revert"))
        if button is None:
            break
        perform_action(button, "AXPress")


# --- the dictation ------------------------------------------------------------

def dictate(path, label, pair, need_heard=True):
    """One take through the (BlackHole) speaker into the TextEdit document.

    INSTRUMENT when the recogniser did not supply the precondition (the heard
    form must be in the delivered text and the exact target must not be) or the
    paste did not name TextEdit.
    """
    subprocess.run(["open", "-a", "TextEdit", path], check=True)
    time.sleep(0.8)  # settle: TextEdit frontmost before the menu-driven take; no ack
    mark = log_mark()
    # The local `say` voice: no cloud spend (GR-NO-CLOUD-SPEND).
    clip = w.tts(pair.sentence, engine="say")
    size = os.path.getsize(clip) if os.path.exists(clip) else 0
    if size < 8192:
        raise Aborted(f"{label}: the speech clip is missing or too small to be speech ({size} bytes)")
    ok = w.test_recording(audio=clip, expect=pair.expect, timeout=45.0)  # a bool; verdicts come from app.log
    save(f"{label}-take.json", {"ok": bool(ok), "sentence": pair.sentence, "expect": pair.expect})
    if not wait_for("the paste cascade line", lambda: re.search(r"Paste cascade: tier=\S+, app=com\.apple\.TextEdit", log_since(mark)), deadline=20.0):
        raise Aborted(f"{label}: the paste did not name TextEdit (wrong frontmost app)")
    text = wait_for("the delivered text", lambda: field_text(path) or None, deadline=10.0)
    save(f"{label}-delivered.txt", text or "")
    # Diagnostic, not a verdict: a loopback that goes to digital zero before the
    # hold ends can retire the mic mid-take (uat-testing.md, silent-uat rule).
    # Recorded so a missing save or pill can be read against it.
    if has(mark, "dead_mic_retire_attempted"):
        print(f"    (diagnostic: {label}: dead_mic_retire_attempted during the take)")
        save(f"{label}-mic-retired.txt", "dead_mic_retire_attempted during the take\n")
    if not text:
        raise Aborted(f"{label}: nothing was delivered to the document")
    if need_heard:
        heard = pair.heard_in(text)
        if heard is None:
            raise Aborted(f"{label}: the anchors {pair.before!r}..{pair.after!r} are not in the delivered text {text!r}")
        if heard.lower() == pair.correct.lower() or pair.correct.lower() in text.lower():
            raise Aborted(f"{label}: the recogniser already delivered the target {pair.correct!r}; nothing to fix")
        return mark, text, heard
    return mark, text, None


def apply_fix(path, label, src, dst, is_regex=False):
    """Replace ONE occurrence, case-insensitively, keeping every other character."""
    area = textedit_area(path)
    before = str(get_attr(area, "AXValue") or "")
    m = re.search(src if is_regex else re.escape(src), before, re.IGNORECASE)
    if not m:
        raise Aborted(f"{label}: '{src}' is not in the delivered text {before!r}")
    edited = before[:m.start()] + dst + before[m.end():]
    set_attr(area, "AXValue", edited)
    if not wait_for("the edit to land", lambda: field_text(path) == edited, deadline=5.0):
        raise Aborted(f"{label}: the accessibility edit did not land")
    save(f"{label}-edited.txt", edited)
    return m.group(0), edited


def clear_field(path):
    area = textedit_area(path)
    if area is not None:
        set_attr(area, "AXValue", "")


# --- the pill ---------------------------------------------------------------

def undo_button():
    """The Undo pill's one button, by its accessibility label. The pill shows
    for 3 seconds after admission, so callers wait on `learn_undo_shown` first
    and look with a short deadline."""
    pid = app_pid()
    if pid is None:
        return None
    app = get_ax_app(pid)
    for window in (get_attr(app, "AXWindows") or []):
        b = (find_element(window, role="AXButton", description="Undo", max_depth=12)
             or find_element(window, role="AXButton", title="Undo", max_depth=12))
        if b is not None:
            return b
    return None


def pill_frame():
    """The Undo button's own frame (the pill is the capsule around it), so a
    hover lands ON the pill and not on whichever window came first."""
    button = undo_button()
    if button is None:
        return None
    from ui_helpers import element_frame
    return element_frame(button)


def parse_judged(line):
    """The `learn_judged` wire row as a dict, or None. `accepted=0` alone is not
    a refusal: `outcome` names a bypass (`deadline`, `malformed`, ...) when the
    judge never answered (Codex drill review, 2026-09-20)."""
    match = re.search(r"learn_judged arm=(\w+) outcome=(\w+) candidates=(\d+) accepted=(\d+)", line or "")
    if match is None:
        return None
    return {"arm": match.group(1), "outcome": match.group(2),
            "candidates": int(match.group(3)), "accepted": int(match.group(4))}


def finish_restore(snaps, initially_running, app_stopped, audio_restored):
    """The one restore receipt both drills print: files, defaults, launchctl,
    audio route, and the app's initial running state (relaunched AND seen
    running, never an unchecked `open`). Returns (restored, receipt)."""
    # Each step runs whatever an earlier one raised; the readbacks decide.
    env_restored = True
    try:
        launchctl_set(snaps["launchctl"])
    except Exception as error:
        env_restored = False
        print(f"LAUNCHCTL RESTORE FAILED: {error}")
    if app_stopped:
        try:
            file_restore(WORDS, snaps["words"])
            defaults_restore(snaps["defaults"])
        except Exception as error:
            print(f"FILE RESTORE FAILED: {error}")
        ok_w, why_w = verify_restore(WORDS, snaps["words"], "words")
    else:
        ok_w, why_w = False, "not restored: the app did not stop"
    ok_d = defaults_snapshot() == snaps["defaults"]
    try:
        ok_e = env_restored and launchctl_get() == snaps["launchctl"]
    except Exception as error:
        ok_e = False
        print(f"LAUNCHCTL READBACK FAILED: {error}")
    running_restored = not initially_running
    if initially_running and app_stopped and ok_w:
        launched = subprocess.run(["open", "-n", APP], capture_output=True, text=True).returncode == 0
        running_restored = launched and bool(wait_for("the initially running app to return", lambda: app_pid() is not None, deadline=20.0))
    restored = audio_restored and app_stopped and ok_w and ok_d and ok_e and running_restored
    receipt = (f"audio={audio_restored}; app_stopped={app_stopped}; words={why_w}; "
               f"legacy_ledger_present={legacy_ledger_present()} (never written by this script); "
               f"defaults={ok_d}; launchctl={ok_e}; running_state={running_restored}")
    return restored, receipt


def find_button_by_prefix(element, prefix, depth=0, max_depth=12):
    if depth > max_depth or element is None:
        return None
    if get_attr(element, "AXRole") == "AXButton":
        for attr in ("AXDescription", "AXTitle"):
            if str(get_attr(element, attr) or "").startswith(prefix):
                return element
    for child in (get_attr(element, "AXChildren") or []):
        hit = find_button_by_prefix(child, prefix, depth + 1, max_depth)
        if hit is not None:
            return hit
    return None


def screenshot(name):
    path = os.path.join(run_dir, name)
    try:
        w.screenshot(path, window=False)
    except Exception as error:
        print(f"    (screenshot failed: {error})")
    return os.path.exists(path) and os.path.getsize(path) > 0


class PillNotAdmitted(Exception):
    """Judged and SAVED, but the overlay refused the Undo pill. After a mic
    retire in the same take that is the rig, not the product: the retire ends
    the take as an interruption, the app shows `Recording interrupted` for
    2.5 s, and a pill asking for the slot meanwhile is refused by design; the
    word stays saved with no Undo. Without a retire it is a product FAIL."""

    def __init__(self, label, retired):
        self.retired = retired
        super().__init__(f"{label}: judged and saved (learn_added) but learn_undo_shown never came"
                         + (" after dead_mic_retire_attempted in the same take (rig)" if retired else ""))


class SaveRefused(Exception):
    """`learn_save_failed reason=...`: the product refused or lost the save.
    A terminal FAIL for the arm, never a success and never the rig."""

    def __init__(self, label, reason):
        self.reason = reason
        super().__init__(f"{label}: learn_save_failed reason={reason}")


def parse_judged_pair(mark):
    """The Debug `judged "<original>" -> "<corrected>" verdict=...` line: the
    exact pair the watcher sent, so the landed check follows what the aligner
    found (one changed word of a two-word fix) without any text in telemetry."""
    match = re.search(r'judged "([^"]*)" -> "([^"]*)" verdict=', log_since(mark))
    return (match.group(1), match.group(2)) if match else None


def wait_judged(mark, deadline=12.0):
    judged = wait_for("learn_judged", lambda: re.search(r"learn_judged arm=classifier outcome=\w+ candidates=\d+ accepted=\d+", log_since(mark)), deadline=deadline)
    return judged.group(0) if judged else None


def wait_added(mark, label, expect_pill=True):
    """After a judged correction: the SAVE (`learn_added state=...`) and, when
    the slot is free, the pill (`learn_undo_shown`). A refused save is a
    terminal failure named by its reason, never a success."""
    added = wait_for("learn_added", lambda: re.search(r"learn_added state=(\w+)", log_since(mark)), deadline=8.0)
    if not added:
        failed = re.search(r"learn_save_failed reason=(\w+)", log_since(mark))
        if failed:
            raise SaveRefused(label, failed.group(1))
        return None
    if not expect_pill:
        return added.group(1)
    shown = wait_for("learn_undo_shown", lambda: has(mark, "learn_undo_shown"), deadline=4.0)
    if not shown:
        raise PillNotAdmitted(label, retired=has(mark, "dead_mic_retire_attempted"))
    return added.group(1)


# --- cases ------------------------------------------------------------------

def empty_words_like(snapshot):
    """The word file is a DICTIONARY (`builtinsVersion`, `deletedBuiltinIds`,
    `version`, `words`); "empty" keeps that shape with `words: []`. A bare `[]`
    is the wrong type (round 1 caught it before it reached the app)."""
    parsed = snapshot.get("parsed") if snapshot.get("exists") else None
    base = dict(parsed) if isinstance(parsed, dict) else {"builtinsVersion": 1, "deletedBuiltinIds": [], "version": 1}
    base["words"] = []
    raw = json.dumps(base).encode("utf-8")
    return {"exists": True, "bytes": raw, "mode": 0o600, "sha256": hashlib.sha256(raw).hexdigest(), "parsed": base}


def relaunch_for_case(snaps, toggle_on, export, words=None):
    """Each case starts from an EMPTY word list (founder 2026-09-20: clear my
    custom words, saved to the side, for the run), or the one seeded word a
    case asks for, so the founder's historical words are learned fresh; the
    originals come back in `finally`. The retired ledger is not touched."""
    stop_app()
    file_restore(WORDS, words or empty_words_like(snaps["words"]))
    defaults_write_bool(toggle_on)
    launchctl_set(export)
    return start_app()


def alias_landed(pair, heard_text):
    word = word_named(pair.correct)
    return bool(word) and heard_text.lower() in [a.lower() for a in (word.get("aliases") or [])]


def press_undo(label):
    """Find and press the pill's Undo button. The window is 3 seconds from
    admission, so the search deadline is short and a miss is the rig's
    timing (INSTRUMENT), not the product."""
    button = wait_for("the pill's Undo button", undo_button, deadline=1.5)
    if button is None:
        raise Aborted(f"{label}: learn_undo_shown but no AX 'Undo' button inside the window (timing or accessibility)")
    perform_action(button, "AXPress")


def case_new_word_undo(path):
    """A word EnviousWispr did not have: saved at once (`learn_added
    state=new_word`), the pill says Added, Undo removes it exactly."""
    pair = PAIRS["new-word-undo"]
    mark, _, heard = dictate(path, "new-word-undo", pair)
    apply_fix(path, "new-word-undo", heard, pair.correct)
    judged = wait_judged(mark)
    if not judged:
        return check("new-word-undo", False, "no learn_judged after the fix")
    if "accepted=1" not in judged:
        return check("new-word-undo", False, f"judge refused the known-positive pair: {judged}")
    state = wait_added(mark, "new-word-undo")
    if state is None:
        return check("new-word-undo", False, "judged accepted but no learn_added and no learn_save_failed")
    saved = wait_for("the word in custom-words.json", lambda: learned_alias(pair, heard), deadline=3.0)
    check("new-word-saved", state == "new_word" and bool(saved), f"heard={heard!r} state={state} saved_with_learned_alias={bool(saved)}")
    press_undo("new-word-undo")
    undone = wait_for("learn_undone", lambda: re.search(r"learn_undone kind=(\w+) outcome=(\w+)", log_since(mark)), deadline=6.0)
    if not screenshot("new-word-undone.png"):
        raise Aborted("new-word-undo: the Undone screenshot is missing or empty (visual proof required)")
    removed = wait_for("the word to leave custom-words.json", lambda: word_named(pair.correct) is None, deadline=5.0)
    ok = bool(undone) and undone.group(1) == "added" and undone.group(2) == "undone" and bool(removed)
    return check("new-word-undo", ok, f"undone={undone.group(0) if undone else None} removed={bool(removed)}")


def case_existing_word(path):
    """The corrected word is ALREADY in Your Words (seeded, no sound-alikes):
    the fix attaches the mishearing to it (`learn_added state=existing_word`,
    the pill says updated), Undo is not pressed, and the sound-alike is marked
    learned. Then the NEXT dictation of the same sentence, when it carries that
    learned alias again: the learned alias alone must not insert the canonical
    target (#3105: with no word check installed, a learned alias is inert)."""
    pair = PAIRS["existing-word"]
    mark, _, heard = dictate(path, "existing-word", pair)
    apply_fix(path, "existing-word", heard, pair.correct)
    judged = wait_judged(mark)
    if not judged:
        return check("existing-word", False, "no learn_judged after the fix")
    if "accepted=1" not in judged:
        return check("existing-word", False, f"judge refused the known-positive pair: {judged}")
    state = wait_added(mark, "existing-word")
    if state is None:
        return check("existing-word", False, "judged accepted but no learn_added and no learn_save_failed")
    if not screenshot("existing-word-pill.png"):
        raise Aborted("existing-word: the pill screenshot is missing or empty (visual proof required)")
    landed = wait_for("the learned sound-alike on the seeded word", lambda: learned_alias(pair, heard), deadline=5.0)
    one_word = sum(1 for e in (words_now() or {}).values() if isinstance(e, dict) and str(e.get("canonical", "")).lower() == pair.correct.lower()) == 1
    ok = state == "existing_word" and bool(landed) and one_word
    check("existing-word", ok, f"heard={heard!r} state={state} learned_alias={bool(landed)} one_word={one_word}")
    # No Undo: the pill leaves on its own and the word persists (checked again
    # after the window in `case_persists_then_your_words`).
    # Positive half first (code-uat.md FACT: a-negative-UAT-result-must-be-attributed):
    # the take reached the corrector and the recogniser delivered THE LEARNED
    # ALIAS again; only then does "the target is absent" say the learned alias
    # held. A different garble ("Pixie Eye" after "PixieI", 2026-09-26) is not
    # the alias: the old Word Correction may fuzzy-match it to the hand-added
    # word, which says nothing about the learned alias. One retake, then the
    # half is INSTRUMENT (no verdict), never a product FAIL.
    for attempt in (1, 2):
        raw_heard = None  # per take, so a retake's record never shows the first take's hearing
        clear_field(path)
        mark2, text2, heard2 = dictate(path, "learned-alias", pair, need_heard=False)
        reached = wait_for("the take's Word Correction line", lambda: has(mark2, "WordCorrection enter"), deadline=10.0)
        if not reached:
            raise Aborted(f"learned-alias: the take never reached Word Correction (delivered={text2!r})")
        heard_again = pair.heard_in(text2 or "")
        if heard_again is None:
            # The recogniser dropped an anchor word: a transient hearing, so it
            # spends the one retake rather than ending the case.
            continue
        raw = re.search(r"\[RAW ASR\] (.*)", log_since(mark2) or "")
        raw_heard = pair.heard_in(raw.group(1)) if raw else None
        # The alias must reach BOTH the recogniser's output and the delivered text: a
        # correction that turned it into some other non-target word tests nothing here.
        if raw_heard is not None and raw_heard.lower() == heard.lower() and heard_again.lower() == heard.lower():
            break
    else:
        record("learned-alias-not-swapped", "INSTRUMENT",
               f"the recogniser never delivered the learned alias {heard!r} again (raw heard={raw_heard!r} delivered={text2!r})")
        return ok
    check("learned-alias-not-swapped", pair.correct.lower() not in text2.lower(),
          f"heard={heard_again!r} delivered_has_target={pair.correct.lower() in text2.lower()} delivered={text2!r}")
    return ok


def case_deletion_only(path):
    """#3105: a fix that only deletes letters (a half-typed edit) never reaches
    the judge, and the watch's end row counts it as `unfinished_edits`. The
    positive half is the observation-ended line itself, which carries the count."""
    pair = PAIRS["deletion-only"]
    mark, _, _ = dictate(path, "deletion-only", pair, need_heard=False)
    apply_fix(path, "deletion-only", "report", "rep")
    # Let the edit SETTLE before ending the watch: an edit cleared inside the
    # quiet interval is never filtered at all (round 1 of this arm: settled_bursts=0).
    if not wait_for("the edit to settle", lambda: has(mark, "learn_settle trigger="), deadline=15.0):
        raise Aborted("deletion-only: the edit never settled")
    clear_field(path)
    ended = wait_for("observation end", lambda: re.search(r"learn_observation_ended reason=\w+ settled_bursts=(\d+) app_class=\w+ duration_ms=\d+ unfinished_edits=(\d+)", log_since(mark)), deadline=15.0)
    if not ended:
        return check("deletion-only", False, "no learn_observation_ended line with unfinished_edits")
    lines = "\n".join(learn_lines(mark))
    ok = ended.group(2) == "1" and "learn_judged" not in lines and "learn_added" not in lines
    return check("deletion-only", ok, f"ended={ended.group(0)} judged={'learn_judged' in lines} added={'learn_added' in lines}")


def park_pointer():
    """Park the pointer top-left, over nothing that reacts to a bare move, so
    no case starts with it over the pill's place (the pill does not pause
    under hover, but a screenshot of it should show it unobstructed)."""
    si.move_mouse(4, 4)
    time.sleep(0.2)  # settle: the move reaches the overlay before the next step


def hover_pill():
    """Put the pointer ON the pill. The 3-second window must not pause or
    extend (founder: "hovering over pill does not stop the timer")."""
    frame = pill_frame()
    if frame is None:
        return False
    si.move_mouse(int(frame["x"] + frame["width"] / 2), int(frame["y"] + frame["height"] / 2))
    return True


def case_expiry_under_hover(path):
    """No Undo pressed: the pill leaves by itself at 3 seconds with the pointer
    over it, and the word stays. The app logs no "pill ended" token; the
    verdict is the Undo button's absence inside a wall-clock bound (3 s plus
    0.5 s of accessibility slack) with no `learn_undone`, plus the word in
    the file afterwards. The pointer must have reached the pill."""
    pair = PAIRS["expiry-under-hover"]
    mark, _, heard = dictate(path, "expiry-under-hover", pair)
    apply_fix(path, "expiry-under-hover", heard, pair.correct)
    judged = wait_judged(mark)
    if not judged:
        return check("expiry-under-hover", False, "no learn_judged after the fix")
    state = wait_added(mark, "expiry-under-hover")
    if state is None:
        return check("expiry-under-hover", False, "judged but no learn_added")
    shown_at = time.monotonic()
    hovered = hover_pill()
    if not screenshot("expiry-under-hover-pill.png"):
        raise Aborted("expiry-under-hover: the pill screenshot is missing or empty (visual proof required)")
    gone = wait_for("the Undo button to leave", lambda: undo_button() is None, deadline=3.5)
    left_after = time.monotonic() - shown_at
    park_pointer()
    persisted = wait_for("the word still in custom-words.json", lambda: learned_alias(pair, heard), deadline=2.0)
    undone = has(mark, "learn_undone")
    # `hovered` is REQUIRED: a run that never reached the pill would prove
    # only that pills expire, not that hover leaves the window alone.
    ok = hovered and bool(gone) and left_after <= 3.5 and not undone and bool(persisted)
    return check("expiry-under-hover", ok,
                 f"heard={heard!r} hovered={hovered} pill_gone={bool(gone)} left_after_s={left_after:.2f} undone={undone} persisted={bool(persisted)}")


def your_words_window(app):
    for window in (get_attr(app, "AXWindows") or []):
        if str(get_attr(window, "AXTitle") or "") == "EnviousWispr":
            return window
    return None


SPARKLE_LABEL = "learned from your edits"


def word_label(app, canonical):
    """The Your Words row's word text, by AXValue, AXTitle or AXDescription."""
    win = your_words_window(app)
    if win is None:
        return None
    return (find_element(win, value=canonical, max_depth=18)
            or find_element(win, title=canonical, max_depth=18)
            or find_element(win, description=canonical, max_depth=18))


def sparkled_row(app, canonical):
    """The Your Words row for `canonical` carries the sparkle: the row's word
    text is present AND a separate image labelled `learned from your edits`
    sits in the same row (an ancestor within three levels of the word text
    has that image as a descendant). The sparkle is its own accessibility
    element, never a value on the word."""
    label = word_label(app, canonical)
    if label is None:
        return None
    # The sparkle is the image labelled `learned from your edits` drawn on the
    # SAME LINE as the word, just to its right. Geometry, not tree shape: the
    # list flattens rows into one group, so a parent walk finds another
    # word's sparkle (live runs 2026-09-22, twice). The seeded manual word
    # must read unsparkled through this same oracle (the control).
    from ui_helpers import element_frame
    box = element_frame(label)
    win = your_words_window(app)
    if box is None or win is None:
        return None
    mid = box["y"] + box["height"] / 2
    for sparkle in all_elements(win, description=SPARKLE_LABEL):
        frame = element_frame(sparkle)
        if frame is None:
            continue
        same_line = frame["y"] <= mid <= frame["y"] + frame["height"]
        to_the_right = box["x"] + box["width"] - 2 <= frame["x"] <= box["x"] + box["width"] + 40
        if same_line and to_the_right:
            return label
    return None


def all_elements(element, description, depth=0, max_depth=18):
    """Every descendant whose AXDescription equals `description`."""
    out = []
    if depth > max_depth or element is None:
        return out
    if get_attr(element, "AXDescription") == description:
        out.append(element)
    for child in (get_attr(element, "AXChildren") or []):
        out.extend(all_elements(child, description, depth + 1, max_depth))
    return out


def auto_learned_pill(app):
    win = your_words_window(app)
    if win is None:
        return None
    return (find_element(win, role="AXButton", description="Auto-learned", max_depth=16)
            or find_element(win, role="AXButton", title="Auto-learned", max_depth=16))


def case_persists_then_your_words(path):
    """After the previous case's pill expired, the learned word is still in
    Your Words with its sparkle, and the Auto-learned filter shows it. Both
    screenshots are the visual proof the founder asked for."""
    pair = PAIRS["expiry-under-hover"]
    word = word_named(pair.correct)
    if not word:
        return check("persists-in-your-words", False, f"{pair.correct} is not in custom-words.json after the pill expired")
    w.connect()
    w.nav("Dictionary")
    app = get_ax_app(app_pid())
    # The seeded MANUAL word is the control: it has no sparkle, and the
    # Auto-learned filter must hide it while the learned word stays.
    manual = wait_for("the seeded manual word's row", lambda: word_label(app, MANUAL_WORD), deadline=8.0)
    row = wait_for("the sparkled Your Words row", lambda: sparkled_row(app, pair.correct), deadline=8.0)
    if not screenshot("your-words-sparkle.png"):
        raise Aborted("persists-in-your-words: the Your Words screenshot is missing or empty (visual proof required)")
    manual_sparkled = sparkled_row(app, MANUAL_WORD) is not None
    check("your-words-sparkle", row is not None and manual is not None and not manual_sparkled,
          f"learned_row_sparkled={row is not None} manual_row_present={manual is not None} manual_sparkled={manual_sparkled} learnedAliases={word.get('learnedAliases')}")
    pill = wait_for("the Auto-learned filter pill", lambda: auto_learned_pill(app), deadline=6.0)
    if pill is None:
        w.close_window()
        return check("auto-learned-filter", False, "no 'Auto-learned' filter pill")
    pressed = perform_action(pill, "AXPress")
    hidden = wait_for("the manual word to leave the filtered list", lambda: word_label(app, MANUAL_WORD) is None, deadline=4.0)
    still = sparkled_row(app, pair.correct)
    if not screenshot("your-words-auto-learned-filter.png"):
        raise Aborted("auto-learned-filter: the filtered screenshot is missing or empty (visual proof required)")
    w.close_window()
    ok = bool(pressed) and still is not None and bool(hidden)
    return check("auto-learned-filter", ok,
                 f"pressed={bool(pressed)} learned_row_visible_under_filter={still is not None} manual_row_hidden={bool(hidden)}")


def case_admission_refused(path):
    """The control for `learn_added` WITHOUT `learn_undo_shown`: the fix is
    flushed by the next recording (#3090: a live watch is finished, not
    cancelled, and an unflushed fix is judged), and the pill asks for the slot
    while the recording holds it. The word is saved; no Undo is offered."""
    pair = PAIRS["admission-refused"]
    mark, _, heard = dictate(path, "admission-refused", pair)
    apply_fix(path, "admission-refused", heard, pair.correct)
    w.connect()
    started = w.tap("Start Recording")
    ended = wait_for("observation ended by the next dictation", lambda: re.search(r"learn_observation_ended reason=next_dictation_started settled_bursts=\d+", log_since(mark)), deadline=10.0)
    judged = wait_judged(mark, deadline=10.0)
    state = wait_added(mark, "admission-refused", expect_pill=False) if judged else None
    wait_for("the recording to start", lambda: has(mark, "Recording started"), deadline=10.0)
    time.sleep(1.5)  # settle: the pill's admission is decided while the recording holds the slot
    shown = has(mark, "learn_undo_shown")
    w.tap("Stop Recording")
    wait_for("the take's terminal", lambda: has(mark, "dictation_terminal") or has(mark, "Pipeline timing TOTAL"), deadline=45.0)
    saved = learned_alias(pair, heard)
    ok = bool(started) and bool(ended) and state is not None and not shown and saved
    return check("admission-refused", ok,
                 f"started={bool(started)} ended={bool(ended)} state={state} undo_shown={shown} saved={saved}")


def case_negative(path):
    pair = PAIRS["negative"]
    mark, _, _ = dictate(path, "negative", pair, need_heard=False)
    src, dst = pair.negative
    apply_fix(path, "negative", src, dst)
    judged = wait_judged(mark)
    if not judged:
        return check("negative", False, "no learn_judged after the rewrite-shaped edit")
    # The claim is an ABSENCE (no save, no pill), bounded by the observation's end.
    clear_field(path)
    wait_for("observation end", lambda: has(mark, "learn_observation_ended"), deadline=12.0)
    lines = "\n".join(learn_lines(mark))
    return check("negative", "accepted=0" in judged and "learn_added" not in lines and "learn_undo_shown" not in lines,
                 f"judged={judged} added={'learn_added' in lines} undo_shown={'learn_undo_shown' in lines}")


def case_toggle_off(path):
    pair = PAIRS["toggle-off"]
    mark, _, heard = dictate(path, "toggle-off", pair)
    apply_fix(path, "toggle-off", heard, pair.correct)
    skipped = wait_for("learn_skipped toggle_off", lambda: has(mark, "learn_skipped reason=toggle_off"), deadline=10.0)
    lines = "\n".join(learn_lines(mark))
    return check("toggle-off", bool(skipped) and "learn_judged" not in lines and "learn_added" not in lines,
                 f"skipped={bool(skipped)} judged={'learn_judged' in lines}")


def case_next_dictation(path):
    """No fix, then the next recording: the watch ends as
    `next_dictation_started` with nothing to flush, so nothing is judged."""
    pair = PAIRS["next-dictation"]
    mark, _, _ = dictate(path, "next-dictation", pair)
    w.connect()
    started = w.tap("Start Recording")
    ended = wait_for("observation ended by the next dictation", lambda: re.search(r"learn_observation_ended reason=next_dictation_started settled_bursts=\d+", log_since(mark)), deadline=10.0)
    wait_for("the recording to start", lambda: has(mark, "Recording started"), deadline=10.0)
    w.tap("Stop Recording")
    wait_for("the take's terminal", lambda: has(mark, "dictation_terminal") or has(mark, "Pipeline timing TOTAL"), deadline=45.0)
    lines = "\n".join(learn_lines(mark))
    return check("next-dictation-ends-watch", bool(started) and bool(ended) and "learn_judged" not in lines and "learn_added" not in lines,
                 f"started={bool(started)} ended={bool(ended)} judged={'learn_judged' in lines}")


CHECK_LINE = re.compile(
    r"LearnedWordCheck: flagged=(\d+) approved=(\d+) applied=(\d+) contested=(\d+) latency_ms=(\d+) arm=(\S+) reason=(\S+)")


def case_learned_check(path):
    """#3105 wiring, end to end in the real app with the Debug door's scripted
    checker (approves every question whose listed word is Tuist): the step runs
    after Word Correction, asks where a seeded misspelling reappears, writes
    Tuist at the approved spots, and logs its counts. Proves the chain, not
    model quality."""
    pair = PAIRS["learned-check"]
    mark, text, _ = dictate(path, "learned-check", pair, need_heard=False)
    line = wait_for("the LearnedWordCheck line", lambda: CHECK_LINE.search(log_since(mark)), deadline=15.0)
    if not line:
        return check("learned-check", False, "no LearnedWordCheck line (the step did not run)")
    flagged, applied, arm = int(line.group(1)), int(line.group(3)), line.group(6)
    if flagged == 0:
        # The recogniser wrote none of the seeded misspellings (or wrote Tuist
        # itself): nothing to ask, so the take proves nothing about the step.
        raise Aborted(f"learned-check: no seeded misspelling to flag (line={line.group(0)} delivered={text!r})")
    ok = arm == "uat_scripted" and applied >= 1 and "tuist" in (text or "").lower()
    return check("learned-check", ok, f"line={line.group(0)} delivered={text!r}")


def case_learned_check_door_off(path):
    """The control: the same learned word and sentence with NO checker installed
    (every engine's adapter door cleared, so no engine has a checker): the step still runs, records
    `arm=none reason=no_checker`, and the learned word never swaps by itself."""
    pair = PAIRS["learned-check"]
    mark, text, _ = dictate(path, "learned-check-off", pair, need_heard=False)
    reached = wait_for("the take's terminal", lambda: has(mark, "Pipeline timing TOTAL"), deadline=20.0)
    if not reached:
        raise Aborted("learned-check-off: the take never completed")
    # Positive input first (code-uat.md FACT: a-negative-UAT-result-must-be-attributed):
    # "unchanged" says something only when the take carried a seeded misspelling.
    heard = pair.heard_in(text or "")
    if heard is None or heard.lower() not in {a.lower() for a in LEARNED_ALIASES}:
        raise Aborted(f"learned-check-off: no seeded misspelling was heard (heard={heard!r} delivered={text!r})")
    # The step logs from its own task, which can land after the terminal line.
    line = wait_for("the LearnedWordCheck line", lambda: CHECK_LINE.search(log_since(mark)), deadline=15.0)
    if not line:
        return check("learned-check-door-off", False, f"no LearnedWordCheck line delivered={text!r}")
    applied, arm, reason = int(line.group(3)), line.group(6), line.group(7)
    ok = arm == "none" and reason == "no_checker" and applied == 0 and pair.correct.lower() not in text.lower()
    return check("learned-check-door-off", ok, f"heard={heard!r} line={line.group(0)} delivered={text!r}")


# --- audio ------------------------------------------------------------------

BAND_SCRIPT = os.path.expanduser(
    "~/Developer/EnviousLabs/EnviousWispr/docs/feature-requests/issue-1946-artifacts/2026-09-08-live-uat-background-band.py")


def audio_route():
    """`AudioRoute` from the #1946 artifact (main checkout, gitignored): apply
    BlackHole to output + input and pick it in Settings → Microphone by AX;
    restore reads the values back."""
    import importlib.util
    if not os.path.exists(BAND_SCRIPT):
        raise Aborted(f"the BlackHole route helper is missing: {BAND_SCRIPT}")
    spec = importlib.util.spec_from_file_location("band", BAND_SCRIPT)
    band = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(band)
    return band.AudioRoute()


# --- main -------------------------------------------------------------------

def main():
    global run_dir
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--export", required=True, help="the locked candidate's fp32 export directory")
    parser.add_argument("--only", default="", help="comma-separated arms to run (default all)")
    args = parser.parse_args()
    run_dir = os.path.abspath(args.run_dir)
    os.makedirs(run_dir, exist_ok=True)
    only = set(a for a in args.only.split(",") if a)

    if screen_is_locked():
        raise Aborted("the screen is locked; unlock it and hands off the Mac")
    others = [p for p in running_instances().values() if p != APP_BIN]
    if others:
        raise Aborted(f"another EnviousWispr instance is running: {others}; refusing to choose")
    initially_running = app_pid() is not None

    head = subprocess.run(["git", "-C", WORKTREE, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    snaps = {"words": file_snapshot(WORDS), "defaults": defaults_snapshot(), "launchctl": launchctl_get(),
             "checkdoor": check_door_get(), "checker_doors": {key: env_get(key) for key in CHECKER_DOOR_KEYS}}
    save("before-custom-words.json", {k: v for k, v in snaps["words"].items() if k != "bytes"})
    save("before-legacy-ledger.json", {"present": legacy_ledger_present(), "path": LEGACY_LEDGER, "note": "read only; the app deletes it at launch; this script never writes it"})
    save("before-defaults-and-launchctl.json", {"defaults": snaps["defaults"], "launchctl": snaps["launchctl"],
                                                "checker_doors": snaps["checker_doors"]})
    with open(APP_BIN, "rb") as fh:
        bin_sha = hashlib.sha256(fh.read()).hexdigest()
    save("subject.json", {"head": head, "app": APP_BIN, "bin_sha256": bin_sha,
                          "bin_mtime": os.path.getmtime(APP_BIN), "export": args.export, "pairs": {k: [v.sentence, v.before, v.after, v.correct] for k, v in PAIRS.items()},
                          "voice": "say (local)", "started": now_iso()})
    log_start = log_mark()
    exit_code = 0
    doc = None
    route = None
    try:
        for key in CHECKER_DOOR_KEYS:
            env_set(key, None)
        # Inaudible: BlackHole for BOTH system output and input, and the app's
        # own mic picker set through the UI (uat-testing.md RULE:
        # silent-uat-via-blackhole-and-select-the-mic-in-the-UI). The proven
        # implementation lives in the main checkout's #1946 artifact.
        if app_pid() is None:
            # the mic picker is set through the app's own Settings, so the
            # subject must be up before the route is applied
            launchctl_set(args.export)
            start_app()
        route = audio_route()
        route.apply()
        doc = new_doc("learn")
        prove_oracle(doc)
        # (name, toggle on, words the case starts from or None for empty, relaunch first, fn)
        cases = [
            ("new-word-undo", True, None, True, case_new_word_undo),
            ("existing-word", True, "seed", True, case_existing_word),
            ("expiry-under-hover", True, "manual", True, case_expiry_under_hover),
            # Same launch as the case before it: the word it learned must persist.
            ("persists-in-your-words", True, None, False, case_persists_then_your_words),
            ("admission-refused", True, None, True, case_admission_refused),
            ("negative", True, None, True, case_negative),
            ("toggle-off", False, None, True, case_toggle_off),
            ("next-dictation", True, None, True, case_next_dictation),
            ("deletion-only", True, None, True, case_deletion_only),
            ("learned-check", True, "learned", True, case_learned_check),
            ("learned-check-door-off", True, "learned", True, case_learned_check_door_off),
        ]
        for name, toggle_on, seed, relaunch, fn in cases:
            if only and name not in only:
                continue
            print(f"\n=== {name} ===", flush=True)
            case_mark = log_mark()
            park_pointer()
            if relaunch:
                words = None
                if seed == "seed":
                    words = seeded_words_like(snaps["words"], PAIRS[name].correct)
                elif seed == "manual":
                    words = seeded_words_like(snaps["words"], MANUAL_WORD)
                elif seed == "learned":
                    words = learned_word_seed(snaps["words"], PAIRS[name.replace("-door-off", "")].correct)
                # The learned-check door is ON only for its own case (#3105).
                check_door_set("Tuist" if name == "learned-check" else None)
                relaunch_for_case(snaps, toggle_on, args.export, words=words)
                clear_field(doc)
            try:
                fn(doc)
            except PillNotAdmitted as error:
                record(name, "INSTRUMENT" if error.retired else "FAIL", str(error))
            except SaveRefused as error:
                record(name, "FAIL", str(error))
            except Aborted as error:
                record(name, "INSTRUMENT", str(error))
            finally:
                save(f"{name}-learn-lines.txt", "\n".join(learn_lines(case_mark)))
                save(f"{name}-words.json", words_now())
    except Aborted as error:
        record("run", "INSTRUMENT", str(error))
    finally:
        try:
            if doc:
                close_doc(doc)
        except Exception as error:
            print(f"    (closing the document failed: {error})")
        # The app's mic picker is restored through the UI, so the app must be
        # up (it is: every case leaves it running) before it is stopped for
        # the file restore.
        # Every part of the restore counts toward `restored` (exit 3 overrides
        # everything): the sound devices, the app being down before shared files
        # are touched, and the files/defaults/launchctl themselves. Shared data is
        # NOT rewritten under a running app: a stop failure leaves it as the
        # cases left it and says so, rather than racing the app's own writes.
        audio_restored = route is None
        try:
            if route is not None:
                route.restore()
                audio_restored = True
        except Exception as error:
            record("audio-restore", "FAIL", str(error))
        app_stopped = False
        try:
            stop_app()
            app_stopped = True
        except Exception as error:
            record("app-stop", "FAIL", str(error))
        # The launch environment is safe to restore whether or not the app is
        # down (launchd state, not the app's files); the rest waits for a stop.
        # Each step runs whatever an earlier one raised; the verification below
        # decides the verdict.
        env_restored = True
        for key, value in [(ENV_KEY, snaps["launchctl"]), (CHECK_ENV_KEY, snaps["checkdoor"])] + list(snaps["checker_doors"].items()):
            try:
                env_set(key, value)
            except Exception as error:
                env_restored = False
                record("env-restore", "FAIL", f"{key}: {error}")
        if app_stopped:
            try:
                file_restore(WORDS, snaps["words"])
                defaults_restore(snaps["defaults"])
            except Exception as error:
                record("file-restore", "FAIL", str(error))
            ok_w, why_w = verify_restore(WORDS, snaps["words"], "words")
        else:
            ok_w, why_w = False, "not restored: the app did not stop"
        after_defaults = defaults_snapshot()
        ok_d = after_defaults == snaps["defaults"]
        after_launchctl = None
        try:
            after_launchctl = launchctl_get()
            ok_e = env_restored and after_launchctl == snaps["launchctl"] and check_door_get() == snaps["checkdoor"] \
                and all(env_get(key) == value for key, value in snaps["checker_doors"].items())
        except Exception as error:
            ok_e = False
            record("env-readback", "FAIL", str(error))
        save("restore-verification.json", {"audio": audio_restored, "app_stopped": app_stopped,
                                           "words": [ok_w, why_w],
                                           "legacy_ledger_present_after": legacy_ledger_present(),
                                           "defaults": [ok_d, after_defaults], "launchctl": [ok_e, after_launchctl]})
        restored = audio_restored and app_stopped and ok_w and ok_d and ok_e
        record("restore", "PASS" if restored else "FAIL",
               f"audio={audio_restored}; app_stopped={app_stopped}; words={why_w}; legacy_ledger_present={legacy_ledger_present()}; defaults={ok_d}; launchctl={ok_e}")
        save("app-log.txt", log_since(log_start))
        statuses = [r["status"] for r in results]
        if not restored:
            exit_code = 3
        elif "FAIL" in statuses:
            exit_code = 1
        elif "INSTRUMENT" in statuses:
            exit_code = 2
        save("summary.json", {"exit_code": exit_code, "results": results, "finished": now_iso()})
        # Leave the Mac as found: the launch environment is the RESTORED value
        # (never re-set to --export here), and the app comes back only if it was
        # running when the drill began.
        if initially_running and app_stopped:
            try:
                subprocess.run(["open", "-n", APP], check=False)
            except Exception:
                pass
    print(f"\nEXIT {exit_code}")
    return exit_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Aborted as error:
        print(f"INSTRUMENT: {error}")
        sys.exit(2)
