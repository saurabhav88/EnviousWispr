#!/usr/bin/env python3
"""Live UAT for learn-from-edits (#996), the founder's pre-PR gate, end to end.

    python3 Tests/RuntimeUAT/learn_from_edits_uat.py --run-dir <dir> --export <fp32 dir>

Run with the screen UNLOCKED and hands off the Mac. It dictates a sentence
through the speaker into a real TextEdit document, makes a scripted fix through
accessibility, waits for the overlay card, presses Accept / Reject, lets one
card expire into Pending and accepts it there, and reads every verdict from
`app.log` and from the two files the feature writes. Every step waits on a
SIGNAL the app produces, with a deadline as the fallback, never as the
mechanism (`wait_for` returns whether the signal arrived).

Codified AFTER a hand-driven round 1 (founder 2026-09-20: the first UAT round
is driven by hand, the script comes after). What that round taught this file:
the heard form is whatever the recogniser DELIVERED between two anchor words,
never a fixed regex; the target must be a word the recogniser does not already
know (EnviousWispr is a built-in; Qualtrics, Malavika and Parvati come out
right from Parakeet, so there is nothing to fix); `custom-words.json` is a
dictionary, so "empty" keeps its shape with `words: []`; `test_recording`
answers a bool and the delivered text is read from TextEdit; the card never
takes keyboard focus, so there is no Escape arm (the Escape path was removed
from the product the same day); and a take must not start until the menu bar's
"Start Recording" item exists, or the harness tap falls into a system-wide
menu walk that never returns.

WHAT IT TOUCHES AND PUTS BACK
-----------------------------
The dev app shares `~/Library/Application Support/EnviousWispr/custom-words.json`
and `correction-proposals.json` with the shipped app (code-uat.md RULE:
uat-writes-reach-the-founders-REAL-data). Both are snapshotted byte for byte
before the first case and restored, with the app down, in `finally`; the
restore is verified by bytes AND by parsed per-key equality. The `learnFromEdits`
default in `com.enviouswispr.app` and the launchd `EW_LEARN_FROM_EDITS_JUDGE_EXPORT`
value are snapshotted and restored the same way. A failed restore exits 3 and
overrides every pass.

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
LEDGER = os.path.join(SUPPORT, "correction-proposals.json")
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
PAIRS = {
    "card-accept": Pair("Ask sorab about the invoices today", "invoices", "Ask", "about", "Saurabh"),
    "card-reject": Pair("Check the pixii dashboard tonight", "dashboard", "the", "dashboard", "pixii"),
    "expiry-pending": Pair("Send the report to Vaish today", "report", "to", "today", "Vaish"),
    "negative": Pair("Send the invoices to the team today", "team", "Send", "to", "the invoices",
                     negative=("the invoices", "a coffee")),
    "toggle-off": Pair("Ask sorab about the invoices today", "invoices", "Ask", "about", "Saurabh"),
    "next-dictation": Pair("Ask sorab about the invoices today", "invoices", "Ask", "about", "Saurabh"),
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


def start_app():
    mark = log_mark()
    subprocess.run(["open", "-n", APP], check=True)
    if not wait_for("the app's door banner", lambda: has(mark, DOOR_ACTIVE), deadline=90.0):
        raise Aborted("the relaunched app never logged the UAT door as ACTIVE")
    banner = [l for l in w.log_entries_since(mark) if DOOR_ACTIVE in l][-1]
    if "threshold=0.06" not in banner or "arm=classifier" not in banner:
        raise Aborted(f"door banner is not the v9 door: {banner}")
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


def launchctl_get():
    r = subprocess.run(["launchctl", "getenv", ENV_KEY], capture_output=True, text=True)
    v = r.stdout.strip()
    return v if v else None


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
    proposals = {p["id"]: p for p in parsed.get("proposals", [])}
    rejected = {r["pairKey"]: r for r in parsed.get("rejectedPairs", [])}
    return {"proposals": proposals, "rejectedPairs": rejected}


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


def ledger_now():
    snap = file_snapshot(LEDGER)
    if snap["exists"] and snap["parsed"]:
        return keyed(snap["parsed"], "ledger")
    return {"proposals": {}, "rejectedPairs": {}}


def word_named(name):
    for entry in (words_now() or {}).values():
        if isinstance(entry, dict) and str(entry.get("canonical", "")).lower() == name.lower():
            return entry
    return None


def open_proposals(pair):
    heard, correct = pair
    return [p for p in ledger_now()["proposals"].values()
            if p.get("original", "").lower() == heard.lower() and p.get("corrected", "").lower() == correct.lower()]


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
    # An unsaved-changes sheet may follow; "Delete" discards. It has no ack.
    for _ in range(3):
        time.sleep(0.5)  # settle: the sheet appears with no observable ack
        pid = find_app_pid("TextEdit")
        if pid is None:
            break
        app = get_ax_app(pid)
        button = find_element(app, role="AXButton", title="Delete")
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
    # Recorded so an unshown card can be read against it.
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


# --- the card ---------------------------------------------------------------

def card_button(kind, correct):
    pid = app_pid()
    if pid is None:
        return None
    app = get_ax_app(pid)
    label = f"Accept: learn {correct}" if kind == "accept" else f"Reject: don't learn {correct}"
    for window in (get_attr(app, "AXWindows") or []):
        b = find_element(window, role="AXButton", description=label, max_depth=12)
        if b is None:
            b = find_element(window, role="AXButton", title=label, max_depth=12)
        if b is not None:
            return b
    return None


def screenshot(name):
    path = os.path.join(run_dir, name)
    try:
        w.screenshot(path, window=False)
    except Exception as error:
        print(f"    (screenshot failed: {error})")
    return os.path.exists(path) and os.path.getsize(path) > 0


class CardNotAdmitted(Exception):
    """Judged and proposed, but the overlay refused the card. After a mic
    retire in the same take that is the rig, not the product: the retire ends
    the take as an interruption, the app shows `Recording interrupted` for
    2.5 s, and a card asking for the slot meanwhile is declined into Pending by
    design (Codex trace 2026-09-20: PipelineStateChangeDispatch.swift:48,
    DictationLifecycleCoordinator.swift:597, PillCatalog.swift:220,
    OverlayReducer.swift:666). Without a retire it is a product FAIL."""

    def __init__(self, label, retired):
        self.retired = retired
        super().__init__(f"{label}: judged and proposed but learn_card_shown never came"
                         + (" after dead_mic_retire_attempted in the same take (rig)" if retired else ""))


def wait_judged_and_card(mark, label, expect_card=True):
    judged = wait_for("learn_judged", lambda: re.search(r"learn_judged arm=classifier outcome=\w+ candidates=\d+ accepted=\d+", log_since(mark)), deadline=12.0)
    if not judged:
        return None
    if not expect_card:
        return judged.group(0)
    shown = wait_for("learn_card_shown", lambda: has(mark, "learn_card_shown"), deadline=8.0)
    if not shown:
        if has(mark, "learn_proposed"):
            raise CardNotAdmitted(label, retired=has(mark, "dead_mic_retire_attempted"))
        return None
    if not screenshot(f"{label}.png"):
        raise Aborted(f"{label}: the card screenshot is missing or empty (visual proof required)")
    return judged.group(0)


# --- cases ------------------------------------------------------------------

EMPTY_LEDGER = {"exists": False}


def empty_words_like(snapshot):
    """The word file is a DICTIONARY (`builtinsVersion`, `deletedBuiltinIds`,
    `version`, `words`); "empty" keeps that shape with `words: []`. A bare `[]`
    is the wrong type (round 1 caught it before it reached the app)."""
    parsed = snapshot.get("parsed") if snapshot.get("exists") else None
    base = dict(parsed) if isinstance(parsed, dict) else {"builtinsVersion": 1, "deletedBuiltinIds": [], "version": 1}
    base["words"] = []
    raw = json.dumps(base).encode("utf-8")
    return {"exists": True, "bytes": raw, "mode": 0o600, "sha256": hashlib.sha256(raw).hexdigest(), "parsed": base}


def relaunch_for_case(snaps, toggle_on, export):
    """Each case starts from an EMPTY word list and NO ledger (founder
    2026-09-20: clear my custom words, saved to the side, for the run), so the
    founder's historical words are learned fresh; the originals come back in
    `finally`."""
    stop_app()
    file_restore(WORDS, empty_words_like(snaps["words"]))
    file_restore(LEDGER, EMPTY_LEDGER)
    defaults_write_bool(toggle_on)
    launchctl_set(export)
    return start_app()


def alias_landed(pair, heard_text):
    word = word_named(pair.correct)
    return bool(word) and heard_text.lower() in [a.lower() for a in (word.get("aliases") or [])]


def case_card_accept(path):
    pair = PAIRS["card-accept"]
    mark, _, heard = dictate(path, "card-accept", pair)
    apply_fix(path, "card-accept", heard, pair.correct)
    judged = wait_judged_and_card(mark, "card-accept")
    if not judged:
        return check("card-accept", False, "no learn_judged + learn_card_shown after the fix")
    if "accepted=1" not in judged:
        return check("card-accept", False, f"judge refused the known-positive pair: {judged}")
    button = wait_for("the card's Accept button", lambda: card_button("accept", pair.correct), deadline=6.0)
    if button is None:
        return check("card-accept", False, f"learn_card_shown but no AX 'Accept: learn {pair.correct}' button (accessibility defect)")
    perform_action(button, "AXPress")
    resolved = wait_for("the accept to resolve", lambda: re.search(r"learn_resolved decision=accepted surface=card", log_since(mark)), deadline=10.0)
    landed = wait_for("the word in custom-words.json", lambda: alias_landed(pair, heard), deadline=5.0)
    ok = bool(resolved) and bool(landed)
    check("card-accept", ok, f"heard={heard!r} resolved={bool(resolved)} landed={bool(landed)}")
    # The learned word on the NEXT dictation of the same sentence.
    clear_field(path)
    mark2, text2, _ = dictate(path, "learned-alias", pair, need_heard=False)
    corrected = wait_for("the corrector's OUT line", lambda: re.search(r"CORRECTION_DEBUG.*OUT:.*" + re.escape(pair.correct), log_since(mark2)), deadline=10.0)
    check("learned-alias", bool(corrected) and pair.correct in text2, f"corrector_out={bool(corrected)} delivered_has_target={pair.correct in text2} delivered={text2!r}")
    return ok


def case_card_reject(path):
    pair = PAIRS["card-reject"]
    mark, _, heard = dictate(path, "card-reject", pair)
    apply_fix(path, "card-reject", heard, pair.correct)
    judged = wait_judged_and_card(mark, "card-reject")
    if not judged:
        return check("card-reject", False, "no learn_judged + learn_card_shown")
    words_before = words_now()
    button = wait_for("the card's Reject button", lambda: card_button("reject", pair.correct), deadline=6.0)
    if button is None:
        return check("card-reject", False, "no AX 'Reject' button")
    perform_action(button, "AXPress")
    resolved = wait_for("the reject to resolve", lambda: re.search(r"learn_resolved decision=rejected surface=card", log_since(mark)), deadline=10.0)
    tombstoned = wait_for("the tombstone", lambda: any(pair.correct.lower() in k.lower() for k in ledger_now()["rejectedPairs"]), deadline=5.0)
    check("card-reject", bool(resolved) and bool(tombstoned) and words_now() == words_before,
          f"heard={heard!r} resolved={bool(resolved)} tombstoned={bool(tombstoned)} vocabulary_unchanged={words_now() == words_before}")
    # The rejected pair is never offered again.
    clear_field(path)
    mark2, _, heard2 = dictate(path, "rejected-repeat", pair)
    if heard2.lower() != heard.lower():
        record("rejected-pair-stays-rejected", "INSTRUMENT", f"the repeat was heard as {heard2!r}, not {heard!r}; a different pair proves nothing")
        return
    apply_fix(path, "rejected-repeat", heard2, pair.correct)
    # The claim is an ABSENCE (no card); the presence that bounds it is the
    # observation's end after the field is cleared.
    time.sleep(4.0)  # settle: the watcher's quiet window must pass before the field is cleared
    clear_field(path)
    ended = wait_for("observation end", lambda: has(mark2, "learn_observation_ended"), deadline=12.0)
    lines = "\n".join(learn_lines(mark2))
    offered = ("learn_proposed" in lines) or ("learn_card_shown" in lines)
    check("rejected-pair-stays-rejected", bool(ended) and not offered,
          f"observation_ended={bool(ended)} offered_again={offered}")


def settings_window(app):
    """The Settings window, never the overlay: an app-wide search for
    `Accept: learn <word>` can find the CARD's button while it is still on
    screen and press that instead (scripted run 2026-09-20 16:18Z did)."""
    for window in (get_attr(app, "AXWindows") or []):
        if str(get_attr(window, "AXTitle") or "") == "EnviousWispr":
            return window
    return None


def pending_row(app):
    win = settings_window(app)
    if win is None:
        return None
    return (find_element(win, role="AXButton", description="Pending, 1 waiting", max_depth=14)
            or find_element(win, role="AXButton", title="Pending, 1 waiting", max_depth=14))


def pending_accept(app, correct):
    win = settings_window(app)
    if win is None:
        return None
    return (find_element(win, role="AXButton", description=f"Accept: learn {correct}", max_depth=16)
            or find_element(win, role="AXButton", title=f"Accept: learn {correct}", max_depth=16))


def card_frame(correct):
    pid = app_pid()
    if pid is None:
        return None
    app = get_ax_app(pid)
    for window in (get_attr(app, "AXWindows") or []):
        if find_element(window, role="AXButton", description=f"Accept: learn {correct}", max_depth=12) is not None:
            from ui_helpers import element_frame
            return element_frame(window)
    return None


def park_pointer():
    """Hover pauses the card's dwell, so a pointer left where the card appears
    (bottom centre) makes 'expiry' impossible (scripted run 2026-09-20 16:18Z:
    the card never expired and the run's own earlier click was the cause).
    Park it top-left, over nothing that reacts to a bare move."""
    si.move_mouse(4, 4)
    time.sleep(0.2)  # settle: hover-exit reaches the overlay before the next step


def pointer_outside(frame):
    import Quartz
    from AppKit import NSEvent
    loc = NSEvent.mouseLocation()
    if loc is None or frame is None:
        return None
    # AX frames are top-left origin; NSEvent is bottom-left. Compare on x only
    # plus a height check through the screen height.
    screen_h = Quartz.CGDisplayPixelsHigh(Quartz.CGMainDisplayID())
    x, y = float(loc.x), screen_h - float(loc.y)
    inside = frame["x"] <= x <= frame["x"] + frame["width"] and frame["y"] <= y <= frame["y"] + frame["height"]
    return not inside


def open_proposals_for(pair):
    return [p for p in ledger_now()["proposals"].values()
            if p.get("corrected", "").lower() == pair.correct.lower()]


def case_expiry_pending(path):
    """An unanswered card expires into Pending (no hover), and Accept there
    saves the word. The card has no keyboard dismiss, so expiry is the only
    no-decision path a person can take."""
    pair = PAIRS["expiry-pending"]
    mark, _, heard = dictate(path, "expiry-pending", pair)
    apply_fix(path, "expiry-pending", heard, pair.correct)
    judged = wait_judged_and_card(mark, "expiry-pending")
    if not judged:
        return check("expiry-pending", False, "no learn_judged + learn_card_shown")
    outside = pointer_outside(card_frame(pair.correct))
    if outside is False:
        park_pointer()  # hover-exit restarts the dwell from full; the wait below covers it
    expired = wait_for("learn_card_expired", lambda: has(mark, "learn_card_expired"), deadline=12.0)
    pending = open_proposals_for(pair)
    still_pending = bool(pending) and pending[0].get("status") == "pending" and pending[0].get("overlayAttempted") is True
    check("expiry-pending", bool(expired) and still_pending, f"heard={heard!r} expired={bool(expired)} pending={still_pending}")
    w.connect()
    w.nav("Dictionary")
    app = get_ax_app(app_pid())
    row = wait_for("the Pending rail row with a badge", lambda: pending_row(app), deadline=8.0)
    if row is None:
        return check("pending-accept", False, "no 'Pending, 1 waiting' rail row")
    perform_action(row, "AXPress")
    accept = wait_for("the Pending row's Accept", lambda: pending_accept(app, pair.correct), deadline=8.0)
    if not screenshot("pending-expiry.png"):
        raise Aborted("expiry-pending: the Pending screenshot is missing or empty (visual proof required)")
    if accept is None:
        return check("pending-accept", False, f"Pending tab shows no 'Accept: learn {pair.correct}' row")
    perform_action(accept, "AXPress")
    resolved = wait_for("the Pending accept", lambda: re.search(r"learn_resolved decision=accepted surface=pending", log_since(mark)), deadline=10.0)
    landed = wait_for("the word in custom-words.json", lambda: alias_landed(pair, heard), deadline=5.0)
    w.close_window()
    return check("pending-accept", bool(resolved) and bool(landed), f"resolved={bool(resolved)} landed={bool(landed)}")


def case_negative(path):
    pair = PAIRS["negative"]
    mark, _, _ = dictate(path, "negative", pair, need_heard=False)
    src, dst = pair.negative
    apply_fix(path, "negative", src, dst)
    judged = wait_judged_and_card(mark, "negative", expect_card=False)
    if not judged:
        return check("negative", False, "no learn_judged after the rewrite-shaped edit")
    # The claim is an ABSENCE (no card), bounded by the observation's end.
    clear_field(path)
    wait_for("observation end", lambda: has(mark, "learn_observation_ended"), deadline=12.0)
    lines = "\n".join(learn_lines(mark))
    return check("negative", "accepted=0" in judged and "learn_proposed" not in lines and "learn_card_shown" not in lines,
                 f"judged={judged} proposed={'learn_proposed' in lines} card={'learn_card_shown' in lines}")


def case_toggle_off(path):
    pair = PAIRS["toggle-off"]
    mark, _, heard = dictate(path, "toggle-off", pair)
    apply_fix(path, "toggle-off", heard, pair.correct)
    skipped = wait_for("learn_skipped toggle_off", lambda: has(mark, "learn_skipped reason=toggle_off"), deadline=10.0)
    lines = "\n".join(learn_lines(mark))
    return check("toggle-off", bool(skipped) and "learn_judged" not in lines and "learn_proposed" not in lines,
                 f"skipped={bool(skipped)} judged={'learn_judged' in lines}")


def case_next_dictation(path):
    pair = PAIRS["next-dictation"]
    mark, _, heard = dictate(path, "next-dictation", pair)
    apply_fix(path, "next-dictation", heard, pair.correct)
    # Start the next recording BEFORE the quiet window settles.
    w.connect()
    started = w.tap("Start Recording")
    ended = wait_for("observation ended by the next dictation", lambda: re.search(r"learn_observation_ended reason=next_dictation_started settled_bursts=\d+", log_since(mark)), deadline=10.0)
    wait_for("the recording to start", lambda: has(mark, "Recording started"), deadline=10.0)
    w.tap("Stop Recording")
    wait_for("the take's terminal", lambda: has(mark, "dictation_terminal") or has(mark, "Pipeline timing TOTAL"), deadline=45.0)
    lines = "\n".join(learn_lines(mark))
    return check("next-dictation-cancels-watch", bool(started) and bool(ended) and "learn_judged" not in lines and "learn_card_shown" not in lines,
                 f"started={bool(started)} ended={bool(ended)} judged={'learn_judged' in lines}")


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
    snaps = {"words": file_snapshot(WORDS), "ledger": file_snapshot(LEDGER),
             "defaults": defaults_snapshot(), "launchctl": launchctl_get()}
    save("before-custom-words.json", {k: v for k, v in snaps["words"].items() if k != "bytes"})
    save("before-correction-proposals.json", {k: v for k, v in snaps["ledger"].items() if k != "bytes"})
    save("before-defaults-and-launchctl.json", {"defaults": snaps["defaults"], "launchctl": snaps["launchctl"]})
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
        cases = [
            ("card-accept", True, case_card_accept),
            ("card-reject", True, case_card_reject),
            ("expiry-pending", True, case_expiry_pending),
            ("negative", True, case_negative),
            ("toggle-off", False, case_toggle_off),
            ("next-dictation", True, case_next_dictation),
        ]
        for name, toggle_on, fn in cases:
            if only and name not in only:
                continue
            print(f"\n=== {name} ===", flush=True)
            case_mark = log_mark()
            park_pointer()
            relaunch_for_case(snaps, toggle_on, args.export)
            clear_field(doc)
            try:
                fn(doc)
            except CardNotAdmitted as error:
                record(name, "INSTRUMENT" if error.retired else "FAIL", str(error))
            except Aborted as error:
                record(name, "INSTRUMENT", str(error))
            finally:
                save(f"{name}-learn-lines.txt", "\n".join(learn_lines(case_mark)))
                save(f"{name}-ledger.json", ledger_now())
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
        except Aborted as error:
            record("app-stop", "FAIL", str(error))
        if app_stopped:
            file_restore(WORDS, snaps["words"])
            file_restore(LEDGER, snaps["ledger"])
            defaults_restore(snaps["defaults"])
            launchctl_set(snaps["launchctl"])
            ok_w, why_w = verify_restore(WORDS, snaps["words"], "words")
            ok_l, why_l = verify_restore(LEDGER, snaps["ledger"], "ledger")
        else:
            ok_w, why_w = False, "not restored: the app did not stop"
            ok_l, why_l = False, "not restored: the app did not stop"
        after_defaults = defaults_snapshot()
        ok_d = after_defaults == snaps["defaults"]
        ok_e = launchctl_get() == snaps["launchctl"]
        save("restore-verification.json", {"audio": audio_restored, "app_stopped": app_stopped,
                                           "words": [ok_w, why_w], "ledger": [ok_l, why_l],
                                           "defaults": [ok_d, after_defaults], "launchctl": [ok_e, launchctl_get()]})
        restored = audio_restored and app_stopped and ok_w and ok_l and ok_d and ok_e
        record("restore", "PASS" if restored else "FAIL",
               f"audio={audio_restored}; app_stopped={app_stopped}; words={why_w}; ledger={why_l}; defaults={ok_d}; launchctl={ok_e}")
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
        if initially_running:
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
