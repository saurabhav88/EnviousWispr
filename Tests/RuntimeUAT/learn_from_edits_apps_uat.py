#!/usr/bin/env python3
"""Learn-from-edits across REAL destination apps (#996): does the feature see
a fix made in each app the way a person makes it, with the keyboard?

    python3 Tests/RuntimeUAT/learn_from_edits_apps_uat.py --run-dir <dir> --export <fp32 dir> \\
        [--apps slack,discord,whatsapp,gmail,word,excel,notes,mail,safari,vscode,ghostty,obsidian,textedit]

Per app: open a fresh text field, dictate the carrier sentence (ends in "sorab") through
BlackHole, wait for the paste, then fix the LAST word with the keyboard the
way a person does (backspace over it, type "Saurabh"), and read what the
feature did from `app.log`: was the paste watched (`learn_skipped` names why
not), did the watch see the edit (`learn_observation_ended` names how it
ended), did the judge run, did the card come, did Accept land. One row per
app with the deciding token. The fix is typed, never set through
accessibility, because the question is whether the feature can SEE a fix in
that app, and setting the value would answer a different question.

Safety: no Enter/Return is ever pressed in any app; every app is asserted
frontmost before each keystroke; each field is cleared afterwards
(select-all, delete) and Mail's draft is discarded. Chat apps get text in
their compose box only. Word list emptied for the run and restored after,
verified byte for byte (same mechanics as `learn_from_edits_uat.py`).

Exit 0 when every app has a verdict, 2 when an app could not be staged
(INSTRUMENT), 3 when the restore is unverified.
"""

import argparse
import contextlib
import io
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import learn_from_edits_uat as d  # noqa: E402
import simulate_input as si  # noqa: E402
import wispr_eyes as w  # noqa: E402
from ui_helpers import activate_app, element_frame, find_app_pid, find_element, get_attr, get_ax_app, perform_action, set_attr  # noqa: E402
from learn_from_edits_uat import find_button_by_prefix  # noqa: E402

# The carrier is a plain English sentence with the mishearing in it. Its
# language read no longer gates anything (every language is eligible, founder
# 2026-09-21; the `language_unsupported` skip of the 2026-09-20 baseline is
# gone), so the sentence is kept for continuity with the baseline scorecard.
SENTENCE = "Please send the invoices for this month to sorab"
# --paragraph: the same mishearing in the MIDDLE of a three-sentence paragraph
# (founder, 2026-09-20: "let's try longer sentences, like full paragraphs").
# The fix then needs the caret moved back into the text, which a person does
# with a click; the drill places the caret through the field's own selected
# range (settable in every host measured today) and types from there. The
# read-back must show the fix at the anchor or the row is INSTRUMENT.
PARAGRAPH = (
    "I went through the numbers with the team this morning and we are in good shape for the quarter. "
    "Please send the invoices for this month to sorab. "
    "He will forward them to finance before the end of the week so nothing slips."
)
PARAGRAPH_BEFORE, PARAGRAPH_AFTER = "month to", "He will"
EXPECT = "invoices"
CORRECT = "Saurabh"
LOCAL_PAGE = "/tmp/ew-lfe-matrix.html"
GMAIL_COMPOSE = "https://mail.google.com/mail/?view=cm&fs=1&tf=1"  # a full-screen compose with an empty body

APPS = {
    # name: (bundle id, app name for AppleScript / activation, kind)
    "textedit": ("com.apple.TextEdit", "TextEdit", "native"),
    "notes": ("com.apple.Notes", "Notes", "native"),
    "mail": ("com.apple.mail", "Mail", "native"),
    "safari": ("com.apple.Safari", "Safari", "browser"),
    "gmail": ("com.google.Chrome", "Google Chrome", "browser"),  # Gmail compose in Chrome (founder: "for chrome test in gmail")
    "word": ("com.microsoft.Word", "Microsoft Word", "native"),
    "excel": ("com.microsoft.Excel", "Microsoft Excel", "native"),
    "slack": ("com.tinyspeck.slackmacgap", "Slack", "electron"),
    "vscode": ("com.microsoft.VSCode", "Visual Studio Code", "electron"),
    "ghostty": ("com.mitchellh.ghostty", "Ghostty", "terminal"),
    "discord": ("com.hnc.Discord", "Discord", "electron"),
    "obsidian": ("md.obsidian", "Obsidian", "electron"),
    "whatsapp": ("net.whatsapp.WhatsApp", "WhatsApp", "electron"),
}


def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True)


def frontmost_bundle():
    return osa('tell application "System Events" to get bundle identifier of first application process whose frontmost is true').stdout.strip()


def pid_for(bundle, app_name):
    out = osa(f'tell application "System Events" to get unix id of first application process whose bundle identifier is "{bundle}"')
    try:
        return int(out.stdout.strip())
    except ValueError:
        return find_app_pid(app_name)


def require_frontmost(bundle):
    """Every keystroke lands on the frontmost app; refuse to type anywhere else."""
    front = frontmost_bundle()
    if front.lower() != bundle.lower():
        raise d.Aborted(f"frontmost is {front!r}, not {bundle!r}; refusing to type")


def press(key, bundle, **mods):
    require_frontmost(bundle)
    si.press_key(key, **mods)
    time.sleep(0.04)  # settle: one keystroke per event-tap turn; a burst drops keys and there is no ack per key


def type_text(text, bundle):
    # One check per keystroke, not per string: focus can move mid-word and the
    # rest of the name would land in another app (Codex drill review).
    for character in text:
        require_frontmost(bundle)
        si.type_text(character)


def focused_value(pid):
    app = get_ax_app(pid)
    el = get_attr(app, "AXFocusedUIElement")
    if el is None:
        return None
    v = get_attr(el, "AXValue")
    return None if v is None else str(v)


def final_text_from_log(mark):
    """The text the app delivered, reconstructed from the CORRECTION_DEBUG
    chain (RAW ASR, then every step's OUT) plus the cursor repair's trailing
    space. Used where the destination's field cannot be read back."""
    text = None
    trailing_space = False
    for line in w.log_entries_since(mark):
        m = re.search(r"CORRECTION_DEBUG \[RAW ASR\] (.*)$", line)
        if m:
            text = m.group(1)
        m = re.search(r"CORRECTION_DEBUG \[[^\]]+\] OUT: (.*)$", line)
        if m:
            text = m.group(1)
        if "CURSOR_REPAIR" in line and "trailing_space" in line:
            trailing_space = True
    if text is None:
        return None
    return text + (" " if trailing_space and not text.endswith(" ") else "")


COMPOSE_LABELS = ("message ", "message#", "type a message", "type to ")


def compose_box(win):
    """The chat composer among a window's text areas: the one whose label names
    a message, or the only text area there is; None when ambiguous."""
    if win is None:
        return None
    areas = []
    def walk(el, depth):
        if depth > 30:
            return
        if get_attr(el, "AXRole") == "AXTextArea":
            areas.append(el)
        for child in (get_attr(el, "AXChildren") or []):
            walk(child, depth + 1)
    walk(win, 0)
    labelled = []
    for area in areas:
        label = (str(get_attr(area, "AXDescription") or "") + " " + str(get_attr(area, "AXPlaceholderValue") or "")).lower()
        if any(label.startswith(k) or (" " + k) in label for k in COMPOSE_LABELS):
            labelled.append(area)
    # Exactly one labelled composer, or exactly one text area at all; tree order
    # alone is no proof of a composer (Codex drill round 5).
    if len(labelled) == 1:
        return labelled[0]
    if not labelled and len(areas) == 1:
        return areas[0]
    return None


def place_caret(pid, offset, bundle):
    """Put the caret at a UTF-16 offset of the focused field through its
    selected range (the caret is a zero-length selection). Returns False when
    the host refuses, so the caller can say so instead of typing blind."""
    from ApplicationServices import AXValueCreate, kAXValueCFRangeType
    from Foundation import NSRange
    require_frontmost(bundle)
    app = get_ax_app(pid)
    el = get_attr(app, "AXFocusedUIElement")
    if el is None:
        return False
    value = AXValueCreate(kAXValueCFRangeType, NSRange(offset, 0))
    if not set_attr(el, "AXSelectedTextRange", value):
        return False
    time.sleep(0.3)  # settle: the caret moves; no ack
    return True


def click_into(element, what, bundle):
    """Put the caret in a text field the way a person does: one click in its
    middle. Setting `AXFocused` through accessibility leaves some hosts (Mail's
    web body, Chrome's contenteditable) with no focused TEXT element, and the
    paste cascade then falls to clipboard-only (measured 2026-09-20)."""
    require_frontmost(bundle)
    frame = element_frame(element)
    if not frame:
        raise d.Aborted(f"{what}: no frame to click")
    si.click(frame["x"] + frame["width"] / 2, frame["y"] + min(frame["height"] / 2, 40))
    time.sleep(0.5)  # settle: the click lands and the caret appears; no ack


def mail_compose_windows(app_el):
    return [w for w in (get_attr(app_el, "AXWindows") or []) if "learn-from-edits check" in str(get_attr(w, "AXTitle") or "")]


def dismiss_mail_alerts(app_el):
    """Mail can hang an alert sheet on a new compose window (on this Mac: the
    iCloud "Update Your Forward To Email Address" notice). While the sheet is
    up the focused element is the sheet, the paste cascade sees no text
    element, and the take falls to clipboard-only (measured 2026-09-20).
    Press its OK; a sheet with more than one button is left alone."""
    for win in mail_compose_windows(app_el):
        sheet = find_element(win, role="AXSheet", max_depth=4)
        if sheet is None:
            continue
        buttons = [c for c in (get_attr(sheet, "AXChildren") or []) if get_attr(c, "AXRole") == "AXButton"]
        if len(buttons) == 1:
            perform_action(buttons[0], "AXPress")
            time.sleep(0.5)  # settle: the sheet slides away; no ack


def discard_mail_drafts(app_el):
    """Close every compose window this script opened and choose Don't Save."""
    for _ in range(6):
        wins = mail_compose_windows(app_el)
        if not wins:
            return True
        win = wins[0]
        dismiss_mail_alerts(app_el)
        perform_action(win, "AXRaise")
        close = next((c for c in (get_attr(win, "AXChildren") or []) if get_attr(c, "AXSubrole") == "AXCloseButton"), None)
        if close is None:
            return False
        perform_action(close, "AXPress")
        def dont_save():
            sheet = find_element(win, role="AXSheet", max_depth=6)
            for c in (get_attr(sheet, "AXChildren") or []) if sheet is not None else []:
                if get_attr(c, "AXRole") == "AXButton" and str(get_attr(c, "AXTitle") or "").startswith("Don"):
                    return c
            return None
        btn = d.wait_for("the Don't Save button", dont_save, deadline=5.0)
        if btn is not None:
            perform_action(btn, "AXPress")
        time.sleep(0.8)  # settle: the window closes; no ack
    return not mail_compose_windows(app_el)


def wait_frontmost(bundle, deadline=6.0):
    return d.wait_for(f"{bundle} frontmost", lambda: frontmost_bundle().lower() == bundle.lower(), deadline=deadline)


# ---------------------------------------------------------------- staging --

def stage(app):
    """Open a fresh, focused text field in `app`; return (pid, doc path or None)."""
    bundle, name, kind = APPS[app]
    if app == "textedit":
        path = d.new_doc("matrix")
        return find_app_pid("TextEdit"), path
    if app == "safari":
        with open(LOCAL_PAGE, "w") as fh:
            fh.write('<!doctype html><meta charset="utf-8"><title>ew lfe matrix</title>'
                     '<body style="font:18px sans-serif;padding:24px">'
                     '<p>Learn-from-edits browser check (local page, nothing is sent anywhere).</p>'
                     '<textarea id="t" autofocus rows="6" cols="70"></textarea>'
                     '<script>document.getElementById("t").focus()</script></body>')
        subprocess.run(["open", "-a", name, LOCAL_PAGE], check=True)
        pid = d.wait_for(f"{name} running", lambda: pid_for(bundle, name), deadline=10.0)
        if not pid:
            raise d.Aborted(f"{app}: did not start")
        activate_app(pid)
        if not wait_frontmost(bundle):
            raise d.Aborted(f"{app}: never became frontmost")
        time.sleep(2.0)  # settle: the local page loads and autofocuses its textarea; a file:// load has no observable ack from here
        return pid, None
    if app == "gmail":
        subprocess.run(["open", "-a", name, GMAIL_COMPOSE], check=True)
        pid = d.wait_for(f"{name} running", lambda: pid_for(bundle, name), deadline=10.0)
        if not pid:
            raise d.Aborted("gmail: Chrome did not start")
        activate_app(pid)
        if not wait_frontmost(bundle):
            raise d.Aborted("gmail: Chrome never became frontmost")
        app_el = get_ax_app(pid)
        # The compose opens with the To field focused; the body is the one
        # multi-line text area of the page. Nothing here presses Return or
        # Cmd+Return (send).
        # Measured 2026-09-20: the body is the `AXTextArea` described "Message
        # Body" at depth 28; the page also carries a "Describe your message"
        # text area (the AI prompt) that a role-only search can find first.
        body = d.wait_for("the Gmail message body", lambda: (lambda win: find_element(win, role="AXTextArea", description="Message Body", max_depth=40) if win is not None else None)(get_attr(app_el, "AXFocusedWindow")), deadline=45.0)
        if body is None:
            raise d.Aborted("gmail: no message body in the compose page (signed out, or the page did not load)")
        click_into(body, "gmail body", bundle)
        return pid, None
    if app == "word":
        osa('tell application "Microsoft Word" to activate')
        pid = d.wait_for("Word running", lambda: pid_for(bundle, name), deadline=20.0)
        activate_app(pid)
        if not wait_frontmost(bundle, deadline=15.0):
            raise d.Aborted("word: never became frontmost")
        time.sleep(1.5)  # settle: Word's start gallery may be up; Cmd+N works from it and from a document
        press("n", bundle, cmd=True)
        time.sleep(2.5)  # settle: the blank document opens with its body focused; Word exposes no ack
        return pid, None
    if app == "excel":
        osa('tell application "Microsoft Excel" to activate')
        pid = d.wait_for("Excel running", lambda: pid_for(bundle, name), deadline=20.0)
        activate_app(pid)
        if not wait_frontmost(bundle, deadline=15.0):
            raise d.Aborted("excel: never became frontmost")
        time.sleep(1.5)  # settle: Excel's start gallery may be up; Cmd+N works from it and from a workbook
        press("n", bundle, cmd=True)
        time.sleep(2.5)  # settle: the blank workbook opens with A1 selected; Excel exposes no ack
        return pid, None
    if app == "notes":
        osa('tell application "Notes" to activate')
        pid = d.wait_for("Notes running", lambda: pid_for(bundle, name), deadline=10.0)
        if not wait_frontmost(bundle):
            raise d.Aborted("notes: never became frontmost")
        press("n", bundle, cmd=True)
        time.sleep(1.5)  # settle: the new note opens with its body focused; Notes exposes no ack for the new document
        return pid, None
    if app == "mail":
        osa('tell application "Mail" to activate')
        pid = d.wait_for("Mail running", lambda: pid_for(bundle, name), deadline=10.0)
        osa('tell application "Mail" to make new outgoing message with properties {subject:"EnviousWispr learn-from-edits check (discard me)", visible:true}')
        activate_app(pid)
        if not wait_frontmost(bundle):
            raise d.Aborted("mail: never became frontmost")
        app_el = get_ax_app(pid)
        def compose_body():
            # The compose window is not always the focused one right after the
            # AppleScript returns; look through every Mail window for the one
            # titled like our draft and take its text area.
            for win in (get_attr(app_el, "AXWindows") or []):
                if "learn-from-edits check" in str(get_attr(win, "AXTitle") or ""):
                    # Mail's body is a web view (`AXWebArea` described "message
                    # body"), not an `AXTextArea`; measured 2026-09-20.
                    area = find_element(win, role="AXWebArea", description="message body", max_depth=25)
                    if area is not None:
                        perform_action(win, "AXRaise")
                        return area
            return None
        body = d.wait_for("the compose body", compose_body, deadline=12.0)
        if body is None:
            raise d.Aborted("mail: no body text area in the compose window")
        dismiss_mail_alerts(app_el)
        click_into(body, "mail body", bundle)
        return pid, None
    if app in ("slack", "discord", "whatsapp", "obsidian", "vscode"):
        osa(f'tell application "{name}" to activate')
        pid = d.wait_for(f"{name} running", lambda: pid_for(bundle, name), deadline=15.0)
        activate_app(pid)
        if not wait_frontmost(bundle, deadline=15.0):
            raise d.Aborted(f"{app}: never became frontmost")
        app_el = get_ax_app(pid)
        # Ask the host to expose its tree, as the feature itself does.
        set_attr(app_el, "AXManualAccessibility", True)
        time.sleep(0.6)  # settle: the Electron tree appears after the opt-in; no ack
        if app == "vscode":
            press("n", bundle, cmd=True)
            time.sleep(1.2)  # settle: the untitled editor opens and takes focus; no ack
        elif app == "obsidian":
            press("n", bundle, cmd=True)
            time.sleep(1.2)  # settle: the new note opens with its title focused; no ack
            press("down", bundle)  # into the body
            time.sleep(0.3)  # settle: caret moves into the body; no ack
        else:
            # Chat compose box, by its label, then CLICKED into (the founder saw
            # the drill land in Discord's search box and miss WhatsApp's box
            # entirely when it took the first text area and set AXFocused):
            # Discord "Message #channel", Slack "Message to …", WhatsApp "Type a
            # message". With no labelled box the LAST text area in the window is
            # the composer (search boxes come first in the tree). Electron
            # trees materialise lazily, so the search is retried for a few
            # seconds. Nothing here presses Return.
            box = d.wait_for("the chat compose box", lambda: compose_box(get_attr(app_el, "AXFocusedWindow")), deadline=8.0)
            if box is None:
                raise d.Aborted(f"{app}: no compose box in the front window; open a conversation")
            click_into(box, f"{app} compose box", bundle)
        return pid, None
    if app == "ghostty":
        osa('tell application "Ghostty" to activate')
        pid = d.wait_for("Ghostty running", lambda: pid_for(bundle, name), deadline=10.0)
        activate_app(pid)
        if not wait_frontmost(bundle):
            raise d.Aborted("ghostty: never became frontmost")
        # A FRESH window with a fresh shell, never the frontmost existing one:
        # the founder's live sessions (Claude Code, servers) run in this app,
        # and the 2026-09-20 run typed into one of them.
        press("n", bundle, cmd=True)
        time.sleep(1.5)  # settle: the new window opens with its shell prompt; no ack
        require_frontmost(bundle)
        press("u", bundle, ctrl=True)  # clear any partial line; never Return
        return pid, None
    raise d.Aborted(f"no staging for {app}")


def cleanup(app, pid, doc):
    bundle, name, kind = APPS[app]
    try:
        if app == "textedit":
            d.close_doc(doc)
            return
        activate_app(pid)
        if not wait_frontmost(bundle):
            raise d.Aborted(f"cleanup: {app} never became frontmost; its field may still hold the test text")
        if app == "ghostty":
            press("u", bundle, ctrl=True)
            press("w", bundle, cmd=True)  # close the window this run opened
            return
        press("a", bundle, cmd=True)
        press("backspace", bundle)
        if app == "mail":
            if not discard_mail_drafts(get_ax_app(pid)):
                raise d.Aborted("cleanup: a Mail draft window is still open")
        elif app == "notes":
            press("w", bundle, cmd=True)  # an empty note is dropped by Notes
        elif app in ("vscode", "obsidian"):
            press("w", bundle, cmd=True)
            time.sleep(0.6)  # settle: a "don't save" sheet may follow; no ack
            press("d", bundle, cmd=True)  # VS Code: Don't Save (Obsidian has no sheet; Cmd+D is harmless there)
        elif app == "safari":
            press("w", bundle, cmd=True)
        elif app == "gmail":
            # Closing a compose tab with a draft fires Chrome's "Leave site?"
            # dialog, which then blocks every later stage (founder, 2026-09-20).
            # Discard the draft through the page's own button first (its label
            # starts "Discard draft"; the Send button sits beside it and is
            # never touched), then close the tab; a stray dialog is answered
            # with Leave.
            app_el = get_ax_app(pid)

            def discard_button():
                window = get_attr(app_el, "AXFocusedWindow")
                return find_button_by_prefix(window, "Discard draft", max_depth=40) if window is not None else None

            discard = d.wait_for("Gmail's Discard draft button", discard_button, deadline=5.0)
            if discard is None:
                raise d.Aborted("cleanup: Gmail's Discard draft button was not found; a draft may remain")
            # A real click: Gmail's toolbar buttons ignore the accessibility
            # press (measured 2026-09-20, the compose stayed open). In the
            # stand-alone compose page (`view=cm`) the discard empties the body
            # and Gmail then tries to close the window, which Chrome turns into
            # an OK/Cancel confirm ("mail.google.com says"); OK is the answer
            # that leaves nothing behind. Done when the body reads empty.
            click_into(discard, "Gmail Discard draft", bundle)

            def body_empty():
                window = get_attr(app_el, "AXFocusedWindow")
                ok = find_element(window, role="AXButton", title="OK", max_depth=8) if window is not None else None
                if ok is not None:
                    # Chrome's dialog buttons ignore the accessibility press too.
                    click_into(ok, "Chrome confirm OK", bundle)
                    return None
                area = find_element(window, role="AXTextArea", description="Message Body", max_depth=40) if window is not None else None
                if area is None:
                    return True
                return str(get_attr(area, "AXValue") or "").strip() == "" or None

            if not d.wait_for("the Gmail draft to be discarded", body_empty, deadline=10.0):
                raise d.Aborted("cleanup: the Gmail body still holds text after Discard draft")
            # Gmail may have closed its own tab on OK; Cmd+W only while the
            # compose tab is still the front one, never on the founder's tabs.
            window = get_attr(app_el, "AXFocusedWindow")
            front_title = str(get_attr(window, "AXTitle") or "") if window is not None else ""
            if "Compose Mail" not in front_title:
                return
            press("w", bundle, cmd=True)
            time.sleep(0.8)  # settle: a "Leave site?" dialog may appear; no ack
            win = get_attr(app_el, "AXFocusedWindow")
            leave = find_element(win, role="AXButton", title="Leave", max_depth=12) if win is not None else None
            if leave is not None:
                perform_action(leave, "AXPress")
        elif app in ("word", "excel"):
            press("w", bundle, cmd=True)
            app_el = get_ax_app(pid)
            btn = d.wait_for("the Don't Save button", lambda: (lambda win: find_element(win, role="AXButton", title="Don't Save", max_depth=10) if win is not None else None)(get_attr(app_el, "AXFocusedWindow")), deadline=5.0)
            if btn is not None:
                perform_action(btn, "AXPress")
    except d.Aborted:
        raise


# ---------------------------------------------------------------- the arm --

def run_app(app, args):
    bundle, name, kind = APPS[app]
    row = {"app": app, "bundle": bundle, "kind": kind}
    pid, doc = stage(app)
    row["pid"] = pid
    require_frontmost(bundle)
    mark = d.log_mark()
    clip = w.tts(PARAGRAPH if args.paragraph else SENTENCE, engine="say")
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        w.test_recording(audio=clip, expect=EXPECT, timeout=45.0)
    cascade = d.wait_for("the paste cascade line", lambda: re.search(r"Paste cascade: tier=([^,\s]+), app=([^,\s]+)", d.log_since(mark)), deadline=20.0)
    if not cascade:
        row["outcome"] = "INSTRUMENT: no paste cascade line"
        return row, pid, doc
    row["paste_tier"], row["paste_app"] = cascade.group(1), cascade.group(2)
    if cascade.group(2).lower() != bundle.lower():
        row["outcome"] = f"INSTRUMENT: paste went to {cascade.group(2)}"
        return row, pid, doc
    time.sleep(1.2)  # settle: the paste lands and the watcher captures; the capture itself logs nothing on success
    logged = final_text_from_log(mark)
    read_back = focused_value(pid)
    row["delivered_log"] = logged
    row["delivered_ax"] = read_back
    # The fix is measured on the text the APP delivered (the log), never on the
    # host's read-back: a contenteditable (Gmail) appends its own no-break
    # space for the caret, which is not a character a person deletes; counting
    # it made the drill eat the space before the word ("to SORAT" ->
    # "toSaurabh", which the judge rightly refused, 2026-09-20). The read-back
    # only confirms the paste landed.
    text = logged or read_back
    if not text:
        row["outcome"] = "INSTRUMENT: delivered text unknown"
        return row, pid, doc
    if args.paragraph:
        # The misheard word sits between two anchors in the middle of the text.
        m = re.search(re.escape(PARAGRAPH_BEFORE) + r"\s+(\S+?)([.!?]*)(\s+)" + re.escape(PARAGRAPH_AFTER), text)
        if not m:
            row["outcome"] = "INSTRUMENT: the paragraph anchors were not found in the delivered text"
            return row, pid, doc
    else:
        m = re.search(r"(\S+?)([.!?]*)(\s*)$", text)
    heard, punct, trail = m.group(1), m.group(2), m.group(3)
    # The word and its punctuation come from the log; the TRAILING whitespace a
    # person has to delete is whatever the host kept: Slack drops the pasted
    # trailing space, Gmail keeps it as a phantom no-break space that is not a
    # deletable character. Plain spaces and newlines at the end of the host's
    # read-back are the count; with no read-back the log's own trail stands.
    if read_back and read_back.rstrip("\u00a0 \t\n\r").endswith(heard + punct):
        host_trail = re.search(r"([ \t\n\r\u00a0]*)$", read_back).group(1)
        if any(character not in (" ", "\u00a0") for character in host_trail):
            raise d.Aborted("the host appended control whitespace after the text; refusing to type Return or Tab")
        trail = host_trail.replace("\u00a0", "")
    if any(character not in " " for character in trail):
        raise d.Aborted("the delivered text ends in control whitespace; refusing to type Return or Tab")
    row["heard"] = heard
    skipped = re.search(r"learn_skipped reason=(\w+)", d.log_since(mark))
    if skipped:
        row["outcome"] = f"not_watched: learn_skipped reason={skipped.group(1)}"
        return row, pid, doc
    if heard.lower() == CORRECT.lower():
        row["outcome"] = "already_right"
        return row, pid, doc
    # The fix, typed: backspace over "<heard><punct><trail>", type "<Saurabh><punct><trail>".
    fix_mark = d.log_mark()
    activate_app(pid)
    if not wait_frontmost(bundle):
        raise d.Aborted(f"{app}: lost frontmost before the fix")
    if app == "excel":
        press("u", bundle, ctrl=True)  # enter cell edit mode with the caret at the end (Excel for Mac)
        time.sleep(0.4)  # settle: the cell switches to edit mode; no ack
    if args.paragraph:
        # Caret right after "<heard><punct>" as the HOST holds the text (its
        # read-back), then the same backspace-and-type a person does; the
        # trailing space between the sentences is left alone.
        host = focused_value(pid) or ""
        hm = re.search(re.escape(PARAGRAPH_BEFORE) + r"\s+" + re.escape(heard + punct), host)
        if not hm:
            row["outcome"] = "INSTRUMENT: the misheard word was not found in the host's text"
            return row, pid, doc
        if not place_caret(pid, len(host[: hm.end()].encode("utf-16-le")) // 2, bundle):
            row["outcome"] = "INSTRUMENT: the host refused to move the caret"
            return row, pid, doc
        trail = ""
    for _ in range(len(heard) + len(punct) + len(trail)):
        press("backspace", bundle)
    type_text(CORRECT + punct + trail, bundle)
    row["typed_fix"] = True
    if args.paragraph:
        time.sleep(0.5)  # settle: the host applies the keystrokes; no ack
        after = focused_value(pid) or ""
        row["fixed_ax"] = after[:400]
        if not re.search(re.escape(PARAGRAPH_BEFORE) + r"\s+" + re.escape(CORRECT + punct) + r"\s+" + re.escape(PARAGRAPH_AFTER), after):
            row["outcome"] = "INSTRUMENT: the fix did not land at the anchor"
            return row, pid, doc
    if args.send_fast:
        # The chat-app path: the person fixes the word and sends at once, well
        # inside the 1.5 s quiet interval. Return is never pressed here; the
        # box is emptied the way a send empties it (select all, delete), which
        # ends the watch with `textbox_emptied` and must flush the pending fix.
        time.sleep(args.send_fast / 1000.0)  # settle: the founder-chosen gap between the last keystroke and the send
        require_frontmost(bundle)
        press("a", bundle, cmd=True)
        press("backspace", bundle)
        row["sent_after_ms"] = args.send_fast
    judged = d.wait_for("learn_judged", lambda: re.search(r"learn_judged arm=\w+ outcome=\w+ candidates=\d+ accepted=\d+", d.log_since(fix_mark)), deadline=12.0)
    if not judged:
        # The capture grace can end in a skip AFTER the fix was typed; read it
        # again here rather than report it as "not judged".
        skipped = re.search(r"learn_skipped reason=(\w+)", d.log_since(mark))
        if skipped:
            row["outcome"] = f"not_watched: learn_skipped reason={skipped.group(1)}"
            return row, pid, doc
        ended = d.wait_for("observation end", lambda: re.search(r"learn_observation_ended reason=\w+ settled_bursts=\d+ app_class=\w+", d.log_since(mark)), deadline=8.0)
        row["outcome"] = "not_judged: " + (ended.group(0) if ended else "no observation end within 8 s (watch still open or capture never started)")
        row["learn_lines"] = [l.split("[LearnFromEdits]")[1].strip()[:160] for l in w.log_entries_since(mark) if "[LearnFromEdits]" in l]
        return row, pid, doc
    row["judged"] = judged.group(0)
    verdict = d.parse_judged(judged.group(0))
    if verdict["outcome"] != "verdict":
        row["outcome"] = f"judge_bypassed: {verdict['outcome']}"
        return row, pid, doc
    if verdict["accepted"] == 0:
        row["outcome"] = "judge_refused"
        return row, pid, doc
    shown = d.wait_for("learn_card_shown", lambda: d.has(fix_mark, "learn_card_shown"), deadline=8.0)
    if not shown:
        row["outcome"] = "proposed_but_card_declined" if d.has(fix_mark, "learn_proposed") else "judged_but_not_proposed"
        return row, pid, doc
    d.screenshot(f"card-{app}.png")
    button = d.wait_for("the card's Accept button", lambda: d.card_button("accept", CORRECT), deadline=6.0)
    if button is None:
        row["outcome"] = "card_shown_but_no_accept_button"
        return row, pid, doc
    perform_action(button, "AXPress")
    resolved = d.wait_for("the accept to resolve", lambda: re.search(r"learn_resolved decision=accepted surface=card \S+ outcome=\w+", d.log_since(fix_mark)), deadline=10.0)
    landed = d.wait_for("the alias in custom-words.json", lambda: (lambda entry: bool(entry) and heard.lower() in [a.lower() for a in (entry.get("aliases") or [])])(d.word_named(CORRECT)), deadline=5.0)
    ended = re.search(r"learn_observation_ended reason=\w+ settled_bursts=\d+ app_class=\w+", d.log_since(mark))
    row["observation"] = ended.group(0) if ended else None
    row["outcome"] = "learned" if (resolved and landed) else f"accept_failed: resolved={bool(resolved)} landed={bool(landed)}"
    return row, pid, doc


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--export", required=True)
    parser.add_argument("--paragraph", action="store_true",
                        help="dictate a three-sentence paragraph with the mishearing in the middle sentence")
    parser.add_argument("--send-fast", type=int, default=0, metavar="MS",
                        help="empty the field MS milliseconds after the fix (a send inside the settle window); 0 = wait for the settle")
    parser.add_argument("--apps", default="slack,discord,whatsapp,gmail,word,excel,notes,mail,safari,vscode,ghostty,obsidian,textedit")
    args = parser.parse_args()
    d.run_dir = os.path.abspath(args.run_dir)
    os.makedirs(d.run_dir, exist_ok=True)
    apps = [a.strip() for a in args.apps.split(",") if a.strip()]
    unknown = [a for a in apps if a not in APPS]
    if unknown:
        raise d.Aborted(f"unknown apps: {unknown}")

    if d.screen_is_locked():
        raise d.Aborted("the screen is locked; unlock it and hands off the Mac")
    others = [p for p in d.running_instances().values() if p != d.APP_BIN]
    if others:
        raise d.Aborted(f"another EnviousWispr instance is running: {others}; refusing to choose")
    initially_running = d.app_pid() is not None
    snaps = {"words": d.file_snapshot(d.WORDS), "ledger": d.file_snapshot(d.LEDGER),
             "defaults": d.defaults_snapshot(), "launchctl": d.launchctl_get()}
    rows = []
    exit_code = 0
    route = None
    app_stopped = False
    audio_restored = True
    try:
        if d.app_pid() is None:
            d.launchctl_set(args.export)
            d.start_app()
        route = d.audio_route()
        route.apply()
        d.stop_app()
        d.file_restore(d.WORDS, d.empty_words_like(snaps["words"]))
        d.file_restore(d.LEDGER, d.EMPTY_LEDGER)
        d.defaults_write_bool(True)
        d.launchctl_set(args.export)
        d.start_app()
        for app in apps:
            print(f"\n=== {app} ===", flush=True)
            d.park_pointer()
            pid = doc = None
            try:
                row, pid, doc = run_app(app, args)
            except d.Aborted as error:
                row = {"app": app, "outcome": f"INSTRUMENT: {error}"}
            rows.append(row)
            print(f"  {row.get('outcome')}  heard={row.get('heard')!r} tier={row.get('paste_tier')}", flush=True)
            d.save("rows.json", rows)
            time.sleep(1.0)  # settle: a result card's 3 s morph is harmless; a live offer must not be under the cleanup keys; no ack
            if pid is not None:
                try:
                    cleanup(app, pid, doc)
                except d.Aborted as error:
                    # Text or a draft may be left in a real app: the row says so
                    # and the run's exit code carries it; the next app still runs.
                    row["cleanup"] = f"INSTRUMENT: {error}"
                    print(f"  cleanup :: {row['cleanup']}", flush=True)
                    d.save("rows.json", rows)
            # Each app starts from the same state: the word is forgotten again.
            d.stop_app()
            d.file_restore(d.WORDS, d.empty_words_like(snaps["words"]))
            d.file_restore(d.LEDGER, d.EMPTY_LEDGER)
            d.start_app()
    except d.Aborted as error:
        rows.append({"outcome": f"INSTRUMENT: {error}"})
        exit_code = 2
    finally:
        try:
            if route is not None:
                route.restore()
        except Exception as error:
            audio_restored = False
            print(f"    (audio restore failed: {error})")
        try:
            d.stop_app()
            app_stopped = True
        except d.Aborted as error:
            print(f"    (app stop failed: {error})")
        restored, receipt = d.finish_restore(snaps, initially_running, app_stopped, audio_restored)
        print(f"\n  {'PASS' if restored else 'FAIL'}  restore :: {receipt}")
        if not restored:
            exit_code = 3
        elif any(str(r.get("outcome", "")).startswith("INSTRUMENT") or "cleanup" in r for r in rows):
            exit_code = max(exit_code, 2)
        d.save("summary.json", {"exit_code": exit_code, "rows": rows, "restored": restored, "receipt": receipt})
    print(f"\nEXIT {exit_code}")
    return exit_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except d.Aborted as error:
        print(f"INSTRUMENT: {error}")
        sys.exit(2)
