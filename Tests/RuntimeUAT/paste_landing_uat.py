#!/usr/bin/env python3
"""Live UAT for the paste landing check (#3106 step 1), driven synthetically and silently.

    python3 Tests/RuntimeUAT/paste_landing_uat.py            # all three phases
    python3 Tests/RuntimeUAT/paste_landing_uat.py focused    # one phase

Run with the screen UNLOCKED and THIS worktree's Debug build running with Debug Mode on
(`PASTE_LANDING` is a DEBUG `app.log` line).

WHY CHROME AND NOT TEXTEDIT
---------------------------
The check observes only the three key-paste tiers (cgevent, applescript, menu_paste). TextEdit is
usually delivered by a direct accessibility write (288 of 291 TextEdit takes in `app.log` used
`tier=ax_direct`, 2026-09-23), so it rarely produces a landing line; it stays here as the
REGRESSION control (lands once, clipboard back, no pill). Chrome takes the cgevent tier, and the
key-paste phases require the log to SAY cgevent, or they have not exercised the feature. The page
is a local file, the same recipe `learn_from_edits_apps_uat.py` uses; nothing is sent anywhere.

WHAT EACH VERDICT READS
-----------------------
- The paste tier: `Paste cascade: tier=<t>, app=com.google.Chrome` in `app.log`.
- The verdict: the one `PASTE_LANDING` line written after this phase's take.
- Arrival (focused phase): the page's text box value, read through accessibility, compared by word
  overlap with the spoken sentence (the recogniser may mishear one word; `last_dictation_uat.py`).
- Clipboard: a sentinel is put on the board before the take; with the founder's restore setting on,
  it must be back afterwards. The landing check must not change that either way.
- Tier, not pill: the take's tier is not `clipboard_only`, the only tier that shows the notice. The
  pill itself is not observed here; "no pill appeared" stays a manual Phase 3 check.

The takes add dictations to the real History (the dev build shares the shipped app's store). The
clipboard, audio devices and Chrome tabs are restored; each phase runs under the beep meter.
"""
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import last_dictation_uat as u  # noqa: E402  (helpers: log, clipboard, takes, beep meter)
import wispr_eyes as w  # noqa: E402
from escape_recovery_uat import screen_is_locked  # noqa: E402

CHROME = "com.google.Chrome"
SENTENCE = u.SENTENCE
LANDING = re.compile(
    r"PASTE_LANDING tier=(\w+) observed=(\w+) reason=(\w+) app=(\S+) host_exposed_focus=(\w+) "
    r"manual_ax=(\w+) target_window=(\w+) before_ms=(\d+) resolve_ms=(\d+)")
CASCADE = re.compile(r"Paste cascade: tier=(\w+), app=([^,]+)")
PAGES = {
    "focused": ('<textarea id="t" autofocus rows="6" cols="70"></textarea>'
                '<script>document.getElementById("t").focus()</script>'),
    # Nothing focusable, and whatever had focus is blurred: the #2705 shape, a key paste into a
    # window with no text field.
    "nofocus": '<p>Nothing on this page takes text.</p><script>document.activeElement.blur()</script>',
}


OPENED = set()  # the pages THIS run opened; cleanup touches Chrome only when non-empty


def page_path(name):
    return f"/tmp/ew-uat-3106-landing-{name}-{u.RUN_ID}.html"


def open_page(name):
    path = page_path(name)
    with open(path, "w") as fh:
        fh.write('<!doctype html><meta charset="utf-8"><title>ew landing '
                 f'{name}</title><body style="font:18px sans-serif;padding:24px">'
                 '<p>Paste landing check (local page, nothing is sent anywhere).</p>'
                 + PAGES[name] + '</body>')
    subprocess.run(["open", "-a", "Google Chrome", path], check=True)
    OPENED.add(name)
    u.require_front(CHROME, f"{name}: page open")
    if not u.wait_for(f"{name}: Chrome's active tab is this run's page",
                      lambda: active_tab_url().endswith(os.path.basename(path)), deadline=10.0):
        raise u.Aborted(f"{name}: the page did not load in the active tab "
                        f"(active tab: {active_tab_url()!r})")
    if name == "focused" and not u.wait_for(
            "the page's text box focused", lambda: focused_role() == "AXTextArea", deadline=5.0):
        raise u.Aborted(f"focused: the text box is not focused (focused role {focused_role()!r})")
    return path


def active_tab_url():
    r = subprocess.run(["osascript", "-e", 'tell application "Google Chrome" to get URL of '
                        'active tab of front window'], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def focused_role():
    from ui_helpers import find_app_pid, get_attr, get_ax_app
    pid = find_app_pid("Google Chrome")
    focused = get_attr(get_ax_app(pid), "AXFocusedUIElement") if pid else None
    return get_attr(focused, "AXRole") if focused is not None else None


def close_run_pages():
    """Close the Chrome tabs this run opened (their URLs carry RUN_ID) and delete the files.
    Verified: no tab with this run's id remains and no file is left. A run that opened no page never
    talks to Chrome, so a `textedit`-only run cannot launch it."""
    if not OPENED:
        return True
    tag = f"-{u.RUN_ID}.html"
    script = f'''
tell application "Google Chrome"
  repeat with w in windows
    repeat with i from (count tabs of w) to 1 by -1
      if URL of tab i of w contains "ew-uat-3106-landing-" and URL of tab i of w ends with "{tag}" then close tab i of w
    end repeat
  end repeat
  set n to 0
  repeat with w in windows
    repeat with t in tabs of w
      if URL of t ends with "{tag}" then set n to n + 1
    end repeat
  end repeat
  return n
end tell'''
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    for name in PAGES:
        if os.path.exists(page_path(name)):
            os.remove(page_path(name))
    left = [n for n in PAGES if os.path.exists(page_path(n))]
    return r.returncode == 0 and r.stdout.strip() == "0" and not left


def textbox_value():
    """The focused text box's value in Chrome, through accessibility, or None."""
    from ui_helpers import find_app_pid, get_attr, get_ax_app
    pid = find_app_pid("Google Chrome")
    if not pid:
        return None
    focused = get_attr(get_ax_app(pid), "AXFocusedUIElement")
    return get_attr(focused, "AXValue") if focused is not None else None


def take(label, base):
    """One silent push-to-talk take into whatever Chrome has focused. Returns the landing match."""
    from silent_audio import AudioRoute, take_was_virtual
    route = AudioRoute()
    route.install_restore_handlers()
    try:
        route.apply()
        u.require_front(CHROME, f"{label}: before the take")
        w.record_tts(SENTENCE)
        time.sleep(2.0)  # settle: a second, unrequested take would start inside this window (#3107)
        virtual, transports = take_was_virtual(base)
        starts = u.log_since(base).count("Recording started")
        u.check(f"{label}: exactly one take", starts == 1, f"{starts} takes started")
        u.check(f"{label}: the take captured through the virtual device", virtual, str(transports))
    finally:
        try:
            stopped = u.stop_any_live_take(base_offset=None)
        except Exception as exc:
            print(f"    (stopping the take raised {exc!r})")
            stopped = False
        u.end_take_then_restore(route, label, stopped)
    # The check resolves up to 1.5 s after the paste; the take itself takes a few seconds more.
    u.wait_for("a PASTE_LANDING line", lambda: LANDING.search(u.log_since(base)), deadline=25.0)
    text = u.log_since(base)
    return LANDING.findall(text), CASCADE.findall(text)


def phase(name):
    print(f"\n== {name}: one dictation into a Chrome page ({'box focused' if name == 'focused' else 'nothing focused'})")
    open_page(name)
    sentinel = f"ew-uat-sentinel-landing-{name}"
    u.set_clipboard_text(sentinel)
    base = u.log_size()
    lines, cascades = take(name, base)
    chrome_tiers = [t for t, app in cascades if app.strip() == CHROME]
    u.check(f"{name}: one paste into Chrome, by the cgevent tier (the feature path)",
            chrome_tiers == ["cgevent"], str(cascades))
    u.check(f"{name}: exactly one PASTE_LANDING line", len(lines) == 1, str(lines))
    if len(lines) != 1:
        return
    tier, observed, reason, app, hef, manual, window, before_ms, resolve_ms = lines[0]
    u.check(f"{name}: the line names Chrome and the delivered tier",
            app == CHROME and [tier] == chrome_tiers, f"app={app} tier={tier}")
    print(f"    PASTE_LANDING tier={tier} observed={observed} reason={reason} "
          f"host_exposed_focus={hef} manual_ax={manual} target_window={window} "
          f"before_ms={before_ms} resolve_ms={resolve_ms}")
    u.check(f"{name}: preparation stayed inside its 500 ms budget", int(before_ms) <= 500,
            f"before_ms={before_ms}")
    if name == "focused":
        value = textbox_value() or ""
        u.check(f"{name}: the words landed in the box (5+ of 7 words)",
                u.sentence_overlap(value) >= 5, repr(value[:80]))
        u.check(f"{name}: observed=changed", observed == "changed", f"{observed}/{reason}")
    else:
        # Chrome reports the page's web area as focused here (measured 2026-09-23: AXWebArea,
        # value ''), so `field_identical` is as true an answer as `no_focus`: the paste went
        # nowhere and the field did not change. Only `changed` would be a false observation.
        u.check(f"{name}: observed is unchanged or unknown, never changed",
                observed in ("unchanged", "unknown"), f"{observed}/{reason}")
    restore_on = u.defaults_value("restoreClipboardAfterPaste") in (None, "1")
    if restore_on:
        u.check(f"{name}: the previous clipboard is back (restore on)",
                u.wait_for("the clipboard restore", lambda: u.clipboard_text() == sentinel,
                           deadline=5.0), repr(u.clipboard_text()))
    else:
        u.skip(f"{name}: clipboard restore", "the founder's restore setting is off")
    u.check(f"{name}: the tier is not clipboard_only (the only tier that shows the notice)",
            "clipboard_only" not in [t for t, _ in cascades], str(cascades))


def phase_textedit():
    """The regression control: an ordinary dictation into TextEdit still lands exactly once, the
    previous clipboard comes back, and no clipboard-only notice is shown. No landing line is
    required when the take uses `ax_direct`; one is recorded if it appears."""
    print("\n== textedit: regression control, one dictation into an empty document")
    sentinel = "ew-uat-sentinel-landing-textedit"
    u.set_clipboard_text(sentinel)
    base = u.log_size()
    delivered = u.phase_dictate()  # the plan 1 driver's own take: new document, silent, one take
    text = u.log_since(base)
    tiers = [t for t, app in CASCADE.findall(text) if app.strip() == "com.apple.TextEdit"]
    u.check("textedit: one paste into TextEdit, not clipboard-only",
            len(tiers) == 1 and tiers[0] != "clipboard_only", str(tiers))
    # Independent of any one recognised word: a doubled paste roughly doubles the text, so the
    # fresh document must hold the sentence's words and be well under twice its length.
    u.check("textedit: the fresh document holds one copy of the dictation",
            u.sentence_overlap(delivered) >= 5 and len(delivered) < 1.5 * len(SENTENCE),
            f"{u.sentence_overlap(delivered)}/7 len={len(delivered)} {delivered[:80]!r}")
    restore_on = u.defaults_value("restoreClipboardAfterPaste") in (None, "1")
    if restore_on:
        u.check("textedit: the previous clipboard is back (restore on)",
                u.wait_for("the clipboard restore", lambda: u.clipboard_text() == sentinel,
                           deadline=5.0), repr(u.clipboard_text()))
    else:
        u.skip("textedit: clipboard restore", "the founder's restore setting is off")
    lines = LANDING.findall(text)
    print(f"    tier={tiers} PASTE_LANDING lines={lines}")
    if tiers == ["ax_direct"]:
        u.check("textedit: no landing check on the ax_direct tier", lines == [], str(lines))


PHASES = ["focused", "nofocus", "textedit"]


def main():
    if screen_is_locked():
        print("ABORT: the screen is locked")
        return 2
    from silent_audio import AlertSink
    w._INPUT_WARN = False
    w.connect()
    try:
        snapshot = u.pasteboard_snapshot()
    except u.Aborted as e:
        print(f"ABORT: {e}")
        return 2
    wanted = sys.argv[1:] or PHASES
    unknown = [a for a in wanted if a not in PHASES]
    if unknown:
        print(f"unknown phase(s) {unknown}; choose from {', '.join(PHASES)}")
        return 2
    sink = AlertSink()
    if not sink.apply():
        print(f"ABORT: alert and output devices did not switch to BlackHole (restored: {sink.restore()})")
        return 2
    try:
        u.run_metered("control", lambda: None)
        for name in wanted:
            if name == "textedit":
                u.run_metered(name, phase_textedit)
            else:
                u.run_metered(name, phase, name)
    except u.Aborted as e:
        u.record("run", "ABORT", str(e))
    finally:
        for label, step in [
            ("clipboard restored byte for byte", lambda: u.pasteboard_restore(snapshot)),
            ("modifier flags cleared", u.modifiers_cleared),
            ("run pages closed", close_run_pages),
            ("run documents closed", u.close_run_documents),
        ]:
            try:
                u.check(label, bool(step()))
            except Exception as exc:
                u.check(label, False, repr(exc))
        try:
            u.check("devices restored", sink.restore())
        except Exception as exc:
            u.check("devices restored", False, repr(exc))
    passed = sum(1 for _, s, _ in u.results if s == "PASS")
    failed = [r for r in u.results if r[1] in ("FAIL", "ABORT")]
    skipped = sum(1 for _, s, _ in u.results if s == "SKIP")
    print(f"\n{passed} passed, {len(failed)} failed, {skipped} skipped")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
