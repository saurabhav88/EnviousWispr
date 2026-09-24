#!/usr/bin/env python3
"""Live UAT for the paste arrival session (#3106 PR A), driven synthetically and silently.

    python3 Tests/RuntimeUAT/paste_landing_uat.py            # all three phases
    python3 Tests/RuntimeUAT/paste_landing_uat.py focused    # one phase
    python3 Tests/RuntimeUAT/paste_landing_uat.py otherwindow closedwindow   # #3121 window phases

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
  it must be back afterwards. The arrival session must not change that either way.
- Tier, not pill: the take's tier is not `clipboard_only`, the only tier that shows the notice. The
  pill itself is not observed here; "no pill appeared" stays a manual Phase 3 check.

The takes add dictations to the real History (the dev build shares the shipped app's store). The
clipboard, audio devices and Chrome tabs are restored; every stretch that plays no speech runs under
the beep meter at the silent ceiling (the takes are not metered: their speech plays into BlackHole).
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
# The arrival session's one line (#3106 PR A): observed is found / absent / no_target /
# cannot_read / inconclusive; late_found_ms appears only on a late hit (empty group otherwise).
LANDING = re.compile(
    r"PASTE_LANDING tier=(\w+) observed=(\w+) reason=(\w+) app=(\S+) app_class=(\w+) "
    r"host_exposed_focus=(\w+) manual_ax=(\w+) target_window=(\w+) before_ms=(\d+) "
    r"resolve_ms=(\d+) late_check=(\w+)(?: late_found_ms=(\d+))?")
CASCADE = re.compile(r"Paste cascade: tier=(\w+), app=([^,]+)")
PAGES = {
    "focused": ('<textarea id="t" autofocus rows="6" cols="70"></textarea>'
                '<script>document.getElementById("t").focus()</script>'),
    # Nothing focusable, and whatever had focus is blurred: the #2705 shape, a key paste into a
    # window with no text field.
    "nofocus": '<p>Nothing on this page takes text.</p><script>document.activeElement.blur()</script>',
    # G6 (#3106 PR B): a focused text area that refuses the paste. It is a text role, so the cascade
    # takes the key-paste tiers (not the menu), and the paste lands nowhere: a genuine miss.
    "readonly": ('<textarea id="t" readonly autofocus rows="6" cols="70"></textarea>'
                 '<script>document.getElementById("t").focus()</script>'),
    # #3121: the page the user switches TO mid-take, in a second window of the same Chrome. Its box
    # is focused, so a paste that follows the front window instead of the dictation lands here.
    "decoy": ('<textarea id="t" autofocus rows="6" cols="70"></textarea>'
              '<script>document.getElementById("t").focus()</script>'),
}


OPENED = set()  # the pages THIS run opened; cleanup touches Chrome only when non-empty


def page_path(name):
    return f"/tmp/ew-uat-3106-landing-{name}-{u.RUN_ID}.html"


def open_page(name):
    path = page_path(name)
    with open(path, "w") as fh:
        fh.write('<!doctype html><meta charset="utf-8"><title>ew landing '
                 f'{name}</title><body style="font:18px sans-serif;padding:24px">'
                 '<p>Paste arrival check (local page, nothing is sent anywhere).</p>'
                 + PAGES[name] + '</body>')
    subprocess.run(["open", "-a", "Google Chrome", path], check=True)
    OPENED.add(name)
    u.require_front(CHROME, f"{name}: page open")
    if not u.wait_for(f"{name}: Chrome's active tab is this run's page",
                      lambda: active_tab_url().endswith(os.path.basename(path)), deadline=10.0):
        raise u.Aborted(f"{name}: the page did not load in the active tab "
                        f"(active tab: {active_tab_url()!r})")
    if name in ("focused", "readonly") and not u.wait_for(
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


def address_bar_value():
    """The front Chrome window's address bar text, or None. Read only to compare; never printed."""
    from ui_helpers import find_app_pid, get_attr, get_ax_app
    pid = find_app_pid("Google Chrome")
    window = get_attr(get_ax_app(pid), "AXFocusedWindow") if pid else None
    found = []

    def walk(element, depth=0):
        if element is None or depth > 30 or found:
            return
        if (get_attr(element, "AXRole") == "AXTextField"
                and "Address" in str(get_attr(element, "AXDescription") or "")):
            value = get_attr(element, "AXValue")
            found.append(None if value is None else str(value))  # a failed read stays None
            return
        for child in get_attr(element, "AXChildren") or []:
            walk(child, depth + 1)

    walk(window)
    return found[0] if found else None


EXPECTED_FOCUS = {"focused": "AXTextArea", "nofocus": "AXWebArea", "readonly": "AXTextArea",
                  "copy-during-wait": "AXWebArea", "new-take": "AXWebArea"}


class LiveTakeNotStopped(u.Aborted):
    """A take that will not stop: no later step may stage another app or restore the microphone."""


# Set BEFORE LiveTakeNotStopped is raised, so the fact survives even if a later cleanup error
# replaces the exception on its way out: callers read this flag, not only the exception.
TAKE_STUCK = {"stuck": False}


def take(label, base, bundle=CHROME, route=None, expected_takes=1, expect_landing=True):
    """One silent push-to-talk take into whatever `bundle` (Chrome unless given) has focused.
    Returns every landing line and paste-cascade line written since `base`.

    `route`: an AudioRoute the CALLER already applied and will restore. Switching the route opens
    and closes EnviousWispr's Settings, and focus does not always return to the app under test
    (measured 2026-09-23: Slack lost the front to our window), so a multi-app run applies it once."""
    from silent_audio import AudioRoute, take_was_virtual
    own = route is None
    hold = {"entered": False, "completed": False}
    if own:
        route = AudioRoute()
        route.install_restore_handlers()
    else:
        # Fail closed: stuck until a stop is CONFIRMED below, so an interrupt anywhere (even while
        # stopping) leaves the flag up, and the caller neither types nor restores the microphone.
        TAKE_STUCK["stuck"] = True
    try:
        if own:
            route.apply()
        u.require_front(bundle, f"{label}: before the take")
        if label in EXPECTED_FOCUS and focused_role() != EXPECTED_FOCUS[label]:
            # Checked immediately before the hold: the paste goes wherever focus is NOW, and an
            # address bar focused here would make a no-focus phase pass on text that landed.
            raise u.Aborted(f"{label}: focus is {focused_role()!r}, not {EXPECTED_FOCUS[label]}")
        hold["entered"] = True
        w.record_tts(SENTENCE)
        hold["completed"] = True
        time.sleep(2.0)  # settle: a second, unrequested take would start inside this window (#3107)
        virtual, transports = take_was_virtual(base)
        starts = u.log_since(base).count("Recording started")
        u.check(f"{label}: exactly {expected_takes} take(s)", starts == expected_takes,
                f"{starts} takes started")
        u.check(f"{label}: the take captured through the virtual device", virtual, str(transports))
    finally:
        try:
            stopped = u.stop_any_live_take(base_offset=base)  # this take's own markers only
        except BaseException as exc:  # an interrupt while stopping is an UNCONFIRMED stop
            print(f"    (stopping the take raised {exc!r})")
            stopped = False
        if stopped and hold["entered"] and not hold["completed"]:
            # Interrupted INSIDE the hold: "no start marker" may only mean the start has not been
            # logged yet. Only a terminal marker since `base` confirms the take ended.
            log = u.log_since(base)
            stopped = (log.count("Recording started") == 1
                       and log.rfind("dictation_terminal") > log.rfind("Recording started"))
        if own:
            u.end_take_then_restore(route, label, stopped)
        elif stopped:
            TAKE_STUCK["stuck"] = False  # cleared only after the stop is confirmed
        else:
            raise LiveTakeNotStopped(f"{label}: a take would not stop; the run stops here and the "
                                     "virtual microphone is left in place until it ends")
    # A potential miss reports after its 1.5 s late-hit shadow; the take itself takes a few
    # seconds more.
    if expect_landing:
        u.wait_for("a PASTE_LANDING line", lambda: LANDING.search(u.log_since(base)), deadline=25.0)
    else:
        # A take refused before any key paste (#3121) writes no landing line: wait for its cascade.
        u.wait_for("a paste cascade line", lambda: CASCADE.search(u.log_since(base)), deadline=25.0)
    text = u.log_since(base)
    return LANDING.findall(text), CASCADE.findall(text)


def quiet(label, fn, *args):
    """Run a stretch that plays NO speech under the beep meter, at the silent ceiling. The take is
    never metered: its speech plays into the same BlackHole device the meter records
    (`BeepMeter`: "never around a step that plays speech"; measured here -30.7 dB)."""
    from silent_audio import BeepMeter
    meter = BeepMeter(f"/tmp/ew-uat-3106-landing-beep-{label.replace(' ', '-')}-{u.RUN_ID}.wav")
    with meter:
        result = fn(*args)
    db = meter.max_db()
    u.check(f"{label}: no alert beep while it ran", db is not None and db < BeepMeter.QUIET_CEILING_DB,
            f"max {db} dB, ceiling {BeepMeter.QUIET_CEILING_DB} (silence -91, alert beep -21)")
    return result


def phase(name):
    print(f"\n== {name}: one dictation into a Chrome page ({'box focused' if name == 'focused' else 'nothing focused'})")
    quiet(f"{name} staging", open_page, name)
    bar_before = address_bar_value()
    restore_on = u.defaults_value("restoreClipboardAfterPaste") in (None, "1")  # before the take
    sentinel = f"ew-uat-sentinel-landing-{name}"
    u.set_clipboard_text(sentinel)
    base = u.log_size()
    PHASE_BASE["offset"] = base
    lines, cascades = take(name, base)  # not metered: speech plays into BlackHole
    quiet(f"{name} checks", verify, name, lines, cascades, bar_before, restore_on, sentinel)


def verify(name, lines, cascades, bar_before, restore_on, sentinel):
    chrome_tiers = [t for t, app in cascades if app.strip() == CHROME]
    # The focused box must take cgevent, the tier this control exists to prove. With no text
    # field, the cascade routes a non-text focus to the Edit menu's Paste (tier 2c, measured
    # 2026-09-23: `menu_paste`), which the check observes too; any of the three proves the path.
    # `EW_UAT_FORCE_TIER2B=1` in the APP's launch environment (G6) turns the key paste into the
    # AppleScript tier; this run is told so by the same variable in its own environment.
    key_tier = "applescript" if os.environ.get("EW_UAT_FORCE_TIER2B") == "1" else "cgevent"
    wanted = [key_tier] if name in ("focused", "readonly") else None
    u.check(f"{name}: one paste into Chrome, by an observed key-paste tier",
            (chrome_tiers == wanted) if wanted else
            (len(chrome_tiers) == 1 and chrome_tiers[0] in ("cgevent", "applescript", "menu_paste")),
            str(cascades))
    u.check(f"{name}: exactly one PASTE_LANDING line", len(lines) == 1, str(lines))
    if len(lines) != 1:
        return
    (tier, observed, reason, app, app_class, hef, manual, window, before_ms, resolve_ms,
     late_check, late_found_ms) = lines[0]
    u.check(f"{name}: the line names Chrome and the delivered tier",
            app == CHROME and [tier] == chrome_tiers, f"app={app} tier={tier}")
    print(f"    PASTE_LANDING tier={tier} observed={observed} reason={reason} app_class={app_class} "
          f"host_exposed_focus={hef} manual_ax={manual} target_window={window} "
          f"before_ms={before_ms} resolve_ms={resolve_ms} late_check={late_check} "
          f"late_found_ms={late_found_ms or '-'}")
    u.check(f"{name}: preparation stayed inside its 500 ms budget", int(before_ms) <= 500,
            f"before_ms={before_ms}")
    bar_after = address_bar_value()
    # Exact, and readable both times: the page is static, so ANY change means something landed
    # there (a one-word paste would pass an overlap test).
    u.check(f"{name}: the address bar is exactly as before the take",
            bar_before is not None and bar_after is not None and bar_after == bar_before,
            f"readable before={bar_before is not None} after={bar_after is not None} "
            f"unchanged={bar_after == bar_before}")
    if name == "focused":
        value = textbox_value() or ""
        u.check(f"{name}: the words landed in the box (5+ of 7 words)",
                u.sentence_overlap(value) >= 5, repr(value[:80]))
        u.check(f"{name}: observed=found", observed == "found", f"{observed}/{reason}")
    else:
        # Chrome reports the page's web area as focused here (measured 2026-09-23: AXWebArea,
        # value ''), so `absent` is as true an answer as `no_target`: the paste went nowhere and
        # the field did not change. PR B (G5): that miss must KEEP the words and show the pill.
        u.check(f"{name}: observed is a miss (absent or no_target)",
                observed in ("absent", "no_target"), f"{observed}/{reason}")
        if name == "readonly":
            # The miss must be REAL: the refusing field is still empty, read independently.
            value = textbox_value()
            u.check(f"{name}: the read-only box is still empty (read, not unreadable)",
                    value == "", repr(value if value is None else value[:80]))
        verify_kept(name)
        return
    if restore_on:
        u.check(f"{name}: the previous clipboard is back (restore on)",
                u.wait_for("the clipboard restore", lambda: u.clipboard_text() == sentinel,
                           deadline=5.0), repr(u.clipboard_text()))
    else:
        u.skip(f"{name}: clipboard restore", "the founder's restore setting is off")
    u.check(f"{name}: the tier is not clipboard_only (the only tier that shows the notice)",
            "clipboard_only" not in [t for t, _ in cascades], str(cascades))


# PR B: the cleanup's verdict and the notice's, both DEBUG `app.log` lines without text.
KEPT = re.compile(r"Clipboard cleanup: op=(keep_dictation|yield|restore|legacy_rewrite), "
                  r"applied=(\w+), delay=\d+ms, tier=(\w+), checked=true")
NOTICE = re.compile(r"RETAINED_NOTICE take=(\S+) shown=(\w+) why=(\w+)")


def verify_kept(name):
    """G5: the words stay on the clipboard, the existing pill shows, and a manual ⌘V into a text
    box pastes them once. Reads the log from this phase's take on (`PHASE_BASE`)."""
    log = lambda: u.log_since(PHASE_BASE["offset"])  # noqa: E731
    u.wait_for("the checked cleanup's line", lambda: KEPT.search(log()), deadline=10.0)
    kept = KEPT.findall(log())
    u.check(f"{name}: the checked cleanup kept the dictation",
            [k[0] for k in kept] == ["keep_dictation"], str(kept))
    u.wait_for("the notice's line", lambda: NOTICE.search(log()), deadline=5.0)
    notices = NOTICE.findall(log())
    u.check(f"{name}: the \"Copied. Press ⌘V to paste\" notice was shown, once",
            len(notices) == 1 and notices[0][1] == "true", str(notices))
    board = u.clipboard_text() or ""
    u.check(f"{name}: the clipboard holds the dictation (5+ of 7 words)",
            u.sentence_overlap(board) >= 5, repr(board[:80]))
    # The user's recovery: click into a text box, press ⌘V.
    quiet(f"{name} recovery staging", open_page, "focused")
    import simulate_input
    simulate_input.press_key("v", cmd=True)
    landed = u.wait_for("the recovered paste", lambda: u.sentence_overlap(textbox_value() or "") >= 5,
                        deadline=5.0)
    value = textbox_value() or ""
    u.check(f"{name}: ⌘V pastes the kept words into the box, once",
            landed and value.lower().count(SENTENCE.split()[0].lower()) == 1, repr(value[:80]))


PHASE_BASE = {"offset": 0}


def phase_new_take_after_miss():
    """§8 (#3106 PR B): a new dictation starts between a missed paste and its notice. The old
    notice must not show; the words stay on the clipboard (the cleanup already kept them). A
    watcher presses the push-to-talk key the moment the cascade logs the first paste, and holds it
    silently (the route is still BlackHole), so the second take has no speech and pastes nothing."""
    import threading
    import simulate_input
    name = "nofocus"
    print("\n== new take after a miss: a second dictation starts before the notice")
    quiet("newtake staging", open_page, name)
    base = u.log_size()
    PHASE_BASE["offset"] = base
    started = {"at": None}

    def second_take_on_paste():
        deadline = time.time() + 60
        while time.time() < deadline:
            if CASCADE.search(u.log_since(base)):
                started["at"] = time.time()
                simulate_input.hold_modifier(61, 1.2)  # right Option: the configured push-to-talk
                return
            time.sleep(0.005)
    watcher = threading.Thread(target=second_take_on_paste, daemon=True)
    watcher.start()
    lines, cascades = take("new-take", base, expected_takes=2)
    watcher.join(timeout=10)
    u.check("newtake: the second take started right after the paste", started["at"] is not None)
    u.check("newtake: the first paste was a miss",
            len(lines) >= 1 and lines[0][1] in ("absent", "no_target"), str(lines))
    u.wait_for("the notice verdict", lambda: NOTICE.search(u.log_since(base)), deadline=10.0)
    notices = NOTICE.findall(u.log_since(base))
    u.check("newtake: the old take's notice was not shown",
            len(notices) == 1 and notices[0][1] == "false", str(notices))
    kept = KEPT.findall(u.log_since(base))
    u.check("newtake: the words were still kept on the clipboard",
            "keep_dictation" in [k[0] for k in kept], str(kept))


def phase_copy_during_wait():
    """§8 (#3106 PR B): the user copies something between the paste and the landing decision. The
    miss must YIELD: their copy stays on the clipboard, nothing is rewritten, no notice shows. A
    watcher thread copies the moment the cascade logs its paste (the decision comes ~300 ms later)."""
    import threading
    name = "nofocus"
    print("\n== copy during the wait: a miss while the user copies something")
    quiet("copy staging", open_page, name)
    base = u.log_size()
    PHASE_BASE["offset"] = base
    user_copy = f"ew-uat-user-copy-{u.RUN_ID}"
    copied = {"at": None}

    def copy_on_paste():
        deadline = time.time() + 60
        while time.time() < deadline:
            if CASCADE.search(u.log_since(base)):
                u.set_clipboard_text(user_copy)
                copied["at"] = time.time()
                return
            time.sleep(0.01)
    watcher = threading.Thread(target=copy_on_paste, daemon=True)
    watcher.start()
    lines, cascades = take("copy-during-wait", base)
    watcher.join(timeout=5)
    u.check("copy: the user's copy was made after the paste", copied["at"] is not None)
    u.check("copy: one landing line, a miss",
            len(lines) == 1 and lines[0][1] in ("absent", "no_target"), str(lines))
    u.wait_for("the checked cleanup's line", lambda: KEPT.search(u.log_since(base)), deadline=10.0)
    kept = KEPT.findall(u.log_since(base))
    u.check("copy: the checked cleanup yielded to the user's copy",
            [k[0] for k in kept] == ["yield"], str(kept))
    u.check("copy: no notice was asked for", NOTICE.findall(u.log_since(base)) == [],
            str(NOTICE.findall(u.log_since(base))))
    u.check("copy: the user's copy is on the clipboard", u.clipboard_text() == user_copy,
            repr(u.clipboard_text()))


def phase_textedit():
    """The regression control: an ordinary dictation into TextEdit still lands exactly once, the
    previous clipboard comes back, and no clipboard-only notice is shown. No landing line is
    required when the take uses `ax_direct`; one is recorded if it appears."""
    print("\n== textedit: regression control, one dictation into an empty document")
    sentinel = "ew-uat-sentinel-landing-textedit"
    restore_on = u.defaults_value("restoreClipboardAfterPaste") in (None, "1")  # before the take
    u.set_clipboard_text(sentinel)
    base = u.log_size()
    delivered = u.phase_dictate()  # the plan 1 driver's own take (speech: not metered)
    quiet("textedit checks", verify_textedit, base, delivered, restore_on, sentinel)


def verify_textedit(base, delivered, restore_on, sentinel):
    text = u.log_since(base)
    tiers = [t for t, app in CASCADE.findall(text) if app.strip() == "com.apple.TextEdit"]
    u.check("textedit: one paste into TextEdit, not clipboard-only",
            len(tiers) == 1 and tiers[0] != "clipboard_only", str(tiers))
    # Independent of any one recognised word: a doubled paste roughly doubles the text, so the
    # fresh document must hold the sentence's words and be well under twice its length.
    u.check("textedit: the fresh document holds one copy of the dictation",
            u.sentence_overlap(delivered) >= 5 and len(delivered) < 1.5 * len(SENTENCE),
            f"{u.sentence_overlap(delivered)}/7 len={len(delivered)} {delivered[:80]!r}")
    if restore_on:
        u.check("textedit: the previous clipboard is back (restore on)",
                u.wait_for("the clipboard restore", lambda: u.clipboard_text() == sentinel,
                           deadline=5.0), repr(u.clipboard_text()))
    else:
        u.skip("textedit: clipboard restore", "the founder's restore setting is off")
    lines = LANDING.findall(text)
    print(f"    tier={tiers} PASTE_LANDING lines={lines}")
    if tiers == ["ax_direct"]:
        u.check("textedit: no landing row on the ax_direct tier", lines == [], str(lines))


# #3121: two windows of ONE Chrome (the shape of two profiles: one process), switched mid-take.
TITLE = "ew landing {}"


def open_page_in_new_window(name):
    """Write the page and open it in a NEW Chrome window, which becomes Chrome's front window."""
    path = page_path(name)
    with open(path, "w") as fh:
        fh.write('<!doctype html><meta charset="utf-8"><title>' + TITLE.format(name)
                 + '</title><body style="font:18px sans-serif;padding:24px">'
                 '<p>Window check (local page, nothing is sent anywhere).</p>'
                 + PAGES[name] + '</body>')
    OPENED.add(name)
    script = ('tell application "Google Chrome"\n  activate\n  make new window\n'
              f'  set URL of active tab of front window to "file://{path}"\nend tell')
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        raise u.Aborted(f"{name}: could not open a new Chrome window: {r.stderr.strip()}")
    if not u.wait_for(f"{name}: its window is front with the box focused",
                      lambda: front_window_title().startswith(TITLE.format(name))
                      and focused_role() == "AXTextArea", deadline=10.0):
        raise u.Aborted(f"{name}: front window {front_window_title()!r}, focus {focused_role()!r}")


def chrome_windows():
    from ui_helpers import find_app_pid, get_attr, get_ax_app
    pid = find_app_pid("Google Chrome")
    return (get_attr(get_ax_app(pid), "AXWindows") or []) if pid else []


def front_window_title():
    from ui_helpers import find_app_pid, get_attr, get_ax_app
    pid = find_app_pid("Google Chrome")
    window = get_attr(get_ax_app(pid), "AXFocusedWindow") if pid else None
    return str(get_attr(window, "AXTitle") or "") if window is not None else ""


def window_box_value(name):
    """The text box value in the window showing page `name`, front or not; None if not found."""
    from ui_helpers import get_attr
    found = []

    def walk(element, depth=0):
        if element is None or depth > 30 or found:
            return
        if get_attr(element, "AXRole") == "AXTextArea":
            found.append(str(get_attr(element, "AXValue") or ""))
            return
        for child in get_attr(element, "AXChildren") or []:
            walk(child, depth + 1)

    for window in chrome_windows():
        if str(get_attr(window, "AXTitle") or "").startswith(TITLE.format(name)):
            walk(window)
            return found[0] if found else None
    return None


def switch_mid_take(base, action, done):
    """Once this take's recording has started, wait a moment, then run `action` in Chrome: bring
    the decoy window front, or close the dictation's window. Runs beside the take."""
    import threading

    def run():
        if u.wait_for("the take to start", lambda: "Recording started" in u.log_since(base),
                      deadline=20.0):
            time.sleep(0.6)
            r = subprocess.run(["osascript", "-e", action], capture_output=True, text=True)
            done["rc"] = r.returncode
            done["err"] = r.stderr.strip()
    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread


def phase_other_window(close_target):
    """#3121. Dictate into window A's box, switch to window B of the same Chrome before the take
    ends (or close A), then check where the words went. B's box is focused, so a paste that follows
    Chrome's front window lands there visibly."""
    name = "closedwindow" if close_target else "otherwindow"
    print(f"\n== {name}: dictate in one Chrome window, "
          f"{'close it' if close_target else 'switch to another Chrome window'} before the take ends")
    quiet(f"{name} staging B", open_page_in_new_window, "decoy")
    quiet(f"{name} staging A", open_page_in_new_window, "focused")
    restore_on = u.defaults_value("restoreClipboardAfterPaste") in (None, "1")
    sentinel = f"ew-uat-sentinel-landing-{name}"
    u.set_clipboard_text(sentinel)
    base = u.log_size()
    PHASE_BASE["offset"] = base
    target = TITLE.format("focused")
    decoy = TITLE.format("decoy")
    if close_target:
        action = (f'tell application "Google Chrome" to close '
                  f'(every window whose title starts with "{target}")')
    else:
        action = (f'tell application "Google Chrome" to set index of '
                  f'(first window whose title starts with "{decoy}") to 1')
    done = {}
    thread = switch_mid_take(base, action, done)
    lines, cascades = take(name, base, expect_landing=not close_target)
    thread.join(timeout=5.0)
    quiet(f"{name} checks", verify_other_window, name, close_target, lines, cascades, done,
          restore_on, sentinel)


def verify_other_window(name, close_target, lines, cascades, done, restore_on, sentinel):
    u.check(f"{name}: the mid-take {'close' if close_target else 'switch'} ran",
            done.get("rc") == 0, str(done))
    log = u.log_since(PHASE_BASE["offset"])
    chrome_tiers = [t for t, app in cascades if app.strip() == CHROME]
    decoy_value = window_box_value("decoy")
    u.check(f"{name}: nothing landed in the window switched to",
            decoy_value == "", repr(None if decoy_value is None else decoy_value[:80]))
    if not close_target:
        value = window_box_value("focused") or ""
        u.check(f"{name}: the words landed in the dictation's own window (5+ of 7 words)",
                u.sentence_overlap(value) >= 5, repr(value[:80]))
        u.check(f"{name}: that window is front again",
                front_window_title().startswith(TITLE.format("focused")), front_window_title())
        u.check(f"{name}: delivered by Cmd+V", chrome_tiers == ["cgevent"], str(cascades))
        u.check(f"{name}: no window refusal", "target_window_not_confirmed" not in log)
        u.check(f"{name}: the landing check saw the same window and the words arrive",
                len(lines) == 1 and lines[0][7] == "same" and lines[0][1] == "found", str(lines))
        if restore_on:
            u.check(f"{name}: the previous clipboard is back (restore on)",
                    u.wait_for("the clipboard restore", lambda: u.clipboard_text() == sentinel,
                               deadline=5.0), repr(u.clipboard_text()))
        return
    u.check(f"{name}: the key paste was refused for the window",
            "target_window_not_confirmed" in log,
            str(re.findall(r"target_window_not_confirmed\([a-z_]+\)", log)))
    u.check(f"{name}: no key paste into Chrome", chrome_tiers == ["clipboard_only"], str(cascades))
    board = u.clipboard_text() or ""
    u.check(f"{name}: the clipboard holds the dictation (5+ of 7 words)",
            u.sentence_overlap(board) >= 5, repr(board[:80]))


PHASES = ["focused", "nofocus", "textedit", "readonly", "copy", "newtake", "otherwindow",
          "closedwindow"]


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
            # Metered inside each phase, around the stretches that play no speech.
            if name == "textedit":
                phase_textedit()
            elif name == "copy":
                phase_copy_during_wait()
            elif name == "newtake":
                phase_new_take_after_miss()
            elif name in ("otherwindow", "closedwindow"):
                phase_other_window(close_target=name == "closedwindow")
            else:
                phase(name)
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
