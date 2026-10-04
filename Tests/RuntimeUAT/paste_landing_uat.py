#!/usr/bin/env python3
"""Live UAT for the paste arrival session (#3106 PR A), driven synthetically and silently.

    python3 Tests/RuntimeUAT/paste_landing_uat.py            # all three phases
    python3 Tests/RuntimeUAT/paste_landing_uat.py focused    # one phase
    python3 Tests/RuntimeUAT/paste_landing_uat.py otherwindow closedwindow   # #3121 window phases
    python3 Tests/RuntimeUAT/paste_landing_uat.py sleepingswitch sleepingclosed sleepingstay  # #3304

Exit status: 0 all passed, 1 anything failed, 3 a required proof was INCONCLUSIVE (a sleeping
phase whose Chrome was not asleep at record start and just before the stop). On the dev Mac a
second Chrome window wakes Chrome's accessibility (measured 2026-09-29), so sleepingswitch and
sleepingclosed report INCONCLUSIVE there; sleepingstay (one window) can prove its case. The
harness's own contract: `python3 Tests/RuntimeUAT/test_paste_landing_harness.py`.

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
TEXTEDIT = "com.apple.TextEdit"
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
    # One tab per pass, restarting the scan: closing a window's last tab closes the window, which
    # invalidates a loop still walking `windows` (#3121 opens run pages in their own windows).
    script = f'''
tell application "Google Chrome"
  repeat
    set found to false
    repeat with w in windows
      repeat with t in tabs of w
        if URL of t contains "ew-uat-3106-landing-" and URL of t ends with "{tag}" then
          close t
          set found to true
          exit repeat
        end if
      end repeat
      if found then exit repeat
    end repeat
    if not found then exit repeat
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
    names = set(PAGES) | OPENED
    for name in names:
        if os.path.exists(page_path(name)):
            os.remove(page_path(name))
    left = [n for n in names if os.path.exists(page_path(n))]
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
                  "reuseafter": "AXWebArea", "clickout": "AXTextArea",
                  "copy-during-wait": "AXWebArea", "new-take": "AXWebArea"}


class LiveTakeNotStopped(u.Aborted):
    """A take that will not stop: no later step may stage another app or restore the microphone."""


# Set BEFORE LiveTakeNotStopped is raised, so the fact survives even if a later cleanup error
# replaces the exception on its way out: callers read this flag, not only the exception.
TAKE_STUCK = {"stuck": False}


def take(label, base, bundle=CHROME, route=None, expected_takes=1, expect_landing=True,
         before_hold=None, before_release=None, sentence=None):
    """One silent push-to-talk take into whatever `bundle` (Chrome unless given) has focused.
    Returns every landing line and paste-cascade line written since `base`.

    `route`: an AudioRoute the CALLER already applied and will restore. Switching the route opens
    and closes EnviousWispr's Settings, and focus does not always return to the app under test
    (measured 2026-09-23: Slack lost the front to our window), so a multi-app run applies it once."""
    from silent_audio import AudioRoute, take_was_virtual
    # One silent route for the whole run (`main`), not one per take: every switch opens Settings
    # and flips the founder's microphone, so a 10-take run used to flip it 20+ times.
    route = route or RUN_ROUTE["route"]
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
        if before_hold is not None:
            before_hold()  # raises Aborted when the phase's own precondition no longer holds
        hold["entered"] = True
        # `before_release` runs while the key is still held, just before the stop (#3304).
        w.record_tts(sentence or SENTENCE, before_release=before_release)
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
    # Step 0 (#3304) first, so no early return can skip it. Destination evidence is raw: any change
    # to the address bar or the box counts as an insertion, and an unreadable one counts too.
    take_text = u.log_since(PHASE_BASE["offset"])
    bar_now = address_bar_value()
    box_now = textbox_value() if name in ("focused", "readonly") else ""
    check_step0(name, take_text, cascades,
                inserted=bar_before is None or bar_now != bar_before or box_now != "")
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
        # An awake Chrome reports the page's web area as focused here (measured 2026-09-23:
        # AXWebArea, value ''), so the paste went nowhere into a readable field: `absent`. PR B (G5):
        # that miss must KEEP the words and show the pill. `no_target` would mean Chrome's
        # accessibility was asleep, which never keeps the words (#3286): a failed precondition.
        u.check(f"{name}: observed is a readable-field miss (absent)",
                observed == "absent", f"{observed}/{reason}")
        box = None
        if name == "readonly":
            # The miss must be REAL: the refusing field is still empty, read independently.
            box = textbox_value()
            u.check(f"{name}: the read-only box is still empty (read, not unreadable)",
                    box == "", repr(box if box is None else box[:80]))
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

# The run's one AudioRoute, applied in `main` before the first phase and restored once at the end.
# `take()` uses it when set; a standalone caller that never sets it still gets a per-take route.
RUN_ROUTE = {"route": None}


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
    bar_before = address_bar_value()
    watcher.start()
    lines, cascades = take("new-take", base, expected_takes=2)
    watcher.join(timeout=10)
    # Step 0 (#3304) over BOTH takes at once, a CONSERVATIVE check. Their events interleave (take
    # 1's late notice lands after take 2 starts), so no boundary can split them. Its PASS proves
    # neither take violated step 0 (no insertion or no shown notice anywhere); its FAIL may come
    # from events of different takes and does not say which take did what.
    check_step0("newtake (both takes)", u.log_since(base), cascades,
                inserted=bar_before is None or address_bar_value() != bar_before)
    u.check("newtake: the second take started right after the paste", started["at"] is not None)
    u.check("newtake: the first paste was a readable-field miss (absent; no_target never keeps, #3286)",
            len(lines) >= 1 and lines[0][1] == "absent", str(lines))
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
    bar_before = address_bar_value()
    watcher.start()
    lines, cascades = take("copy-during-wait", base)
    watcher.join(timeout=5)
    # Step 0 (#3304): the only destination on the no-focus page is the address bar.
    check_step0("copy", u.log_since(base), cascades,
                inserted=bar_before is None or address_bar_value() != bar_before)
    u.check("copy: the user's copy was made after the paste", copied["at"] is not None)
    u.check("copy: one landing line, a readable-field miss (absent; no_target never keeps, #3286)",
            len(lines) == 1 and lines[0][1] == "absent", str(lines))
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
    # The same take as `u.phase_dictate`, but through `take()`: the run's one audio route and its
    # stuck-take guard, never a second route that would overwrite the run's recovery file.
    path = u.new_textedit_doc(f"3106-landing-{u.RUN_ID}")
    u.require_front(TEXTEDIT, "textedit: document open")
    for _ in range(4):  # other windows closed, so the hold's key goes to this document
        if not w.close_window():
            break
    base = u.log_size()
    take("textedit", base, bundle=TEXTEDIT, expect_landing=False)  # speech: not metered
    ok = u.wait_for("the dictation to land in the document",
                    lambda: u.sentence_overlap(u.doc_text(path)) >= 5, deadline=20.0)
    delivered = u.doc_text(path)
    # Step 0 (#3304) before the abort below: ANY text in the fresh document is an insertion.
    step0_text = u.log_since(base)
    check_step0("textedit", step0_text, CASCADE.findall(step0_text), inserted=delivered != "")
    u.check("textedit: the take landed in the document (5+ of the sentence's 7 words)", ok,
            f"{u.sentence_overlap(delivered)}/7 {delivered[:80]!r}")
    if not ok:
        raise u.Aborted("textedit: no dictation landed")
    delivered = delivered[:-1] if delivered.endswith(" ") else delivered
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
def window_title(phase_name, page):
    """Unique per phase AND run, so one phase never reads or closes another phase's window."""
    return f"ew landing {phase_name} {page} {u.RUN_ID}"


def open_page_in_new_window(phase_name, page):
    """Write `page` and open it in a NEW Chrome window, which becomes Chrome's front window."""
    key = f"{phase_name}-{page}"
    path = page_path(key)
    title = window_title(phase_name, page)
    with open(path, "w") as fh:
        fh.write('<!doctype html><meta charset="utf-8"><title>' + title
                 + '</title><body style="font:18px sans-serif;padding:24px">'
                 '<p>Window check (local page, nothing is sent anywhere).</p>'
                 + PAGES[page] + '</body>')
    OPENED.add(key)
    script = ('tell application "Google Chrome"\n  activate\n  make new window\n'
              f'  set URL of active tab of front window to "file://{path}"\nend tell')
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        raise u.Aborted(f"{key}: could not open a new Chrome window: {r.stderr.strip()}")
    require_window_ready(key, title, deadline=10.0)


def require_window_ready(label, title, deadline=2.0):
    if not u.wait_for(f"{label}: its window is front with the box focused",
                      lambda: front_window_title().startswith(title)
                      and focused_role() == "AXTextArea", deadline=deadline):
        raise u.Aborted(f"{label}: front window {front_window_title()!r}, focus {focused_role()!r}")


def chrome_windows():
    from ui_helpers import find_app_pid, get_attr, get_ax_app
    pid = find_app_pid("Google Chrome")
    return (get_attr(get_ax_app(pid), "AXWindows") or []) if pid else []


def front_window_title():
    from ui_helpers import find_app_pid, get_attr, get_ax_app
    pid = find_app_pid("Google Chrome")
    window = get_attr(get_ax_app(pid), "AXFocusedWindow") if pid else None
    return str(get_attr(window, "AXTitle") or "") if window is not None else ""


def window_box_value(title):
    """The text box value in the window titled `title`, front or not; None if not found or
    unreadable."""
    from ui_helpers import get_attr
    found = []

    def walk(element, depth=0):
        if element is None or depth > 30 or found:
            return
        if get_attr(element, "AXRole") == "AXTextArea":
            value = get_attr(element, "AXValue")
            found.append(None if value is None else str(value))  # unreadable is not empty
            return
        for child in get_attr(element, "AXChildren") or []:
            walk(child, depth + 1)

    for window in chrome_windows():
        if str(get_attr(window, "AXTitle") or "").startswith(title):
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
    quiet(f"{name} staging B", open_page_in_new_window, name, "decoy")
    quiet(f"{name} staging A", open_page_in_new_window, name, "focused")
    restore_on = u.defaults_value("restoreClipboardAfterPaste") in (None, "1")
    sentinel = f"ew-uat-sentinel-landing-{name}"
    u.set_clipboard_text(sentinel)
    base = u.log_size()
    PHASE_BASE["offset"] = base
    target = window_title(name, "focused")
    decoy = window_title(name, "decoy")
    if close_target:
        action = (f'tell application "Google Chrome" to close '
                  f'(every window whose title starts with "{target}")')
    else:
        action = (f'tell application "Google Chrome" to set index of '
                  f'(first window whose title starts with "{decoy}") to 1')
    done = {}
    thread = switch_mid_take(base, action, done)
    # Re-checked immediately before the hold: the route switch can move focus after staging.
    lines, cascades = take(name, base, expect_landing=not close_target,
                           before_hold=lambda: require_window_ready(name, target))
    thread.join(timeout=5.0)
    quiet(f"{name} checks", verify_other_window, name, close_target, lines, cascades, done,
          restore_on, sentinel, target, decoy)


# The executor's one local line for a window-gate refusal (#3121); DEBUG `app.log`.
WINDOW_REFUSAL = re.compile(r"WINDOW_GATE refused stage=(\w+) reason=(\S+)")
# The closed-window phase proves the WINDOW guard only through a window reason on Chrome;
# `app_not_front` (another app took focus) would leave the same clipboard and prove nothing here.
CLOSED_WINDOW_REFUSAL = re.compile(
    r"WINDOW_GATE refused stage=\w+ reason=target_window_not_confirmed"
    r"\((?:window_mismatch|window_unreadable_focus_mismatch|focused_window_unreadable)\)"
    r"(?: ms=\d+)? bundle_id=com\.google\.Chrome\b")


def verify_other_window(name, close_target, lines, cascades, done, restore_on, sentinel, target,
                        decoy):
    u.check(f"{name}: the mid-take {'close' if close_target else 'switch'} ran",
            done.get("rc") == 0, str(done))
    log = u.log_since(PHASE_BASE["offset"])
    chrome_tiers = [t for t, app in cascades if app.strip() == CHROME]
    decoy_value = window_box_value(decoy)
    u.check(f"{name}: nothing landed in the window switched to",
            decoy_value == "", repr(None if decoy_value is None else decoy_value[:80]))
    target_raw = "" if close_target else window_box_value(target)
    check_step0(name, log, cascades, inserted=decoy_value != "" or target_raw != "")
    if not close_target:
        value = target_raw or ""
        u.check(f"{name}: the words landed in the dictation's own window (5+ of 7 words)",
                u.sentence_overlap(value) >= 5, repr(value[:80]))
        u.check(f"{name}: that window is front again",
                front_window_title().startswith(target), front_window_title())
        u.check(f"{name}: delivered by Cmd+V", chrome_tiers == ["cgevent"], str(cascades))
        u.check(f"{name}: no window refusal", not WINDOW_REFUSAL.search(log),
                str(WINDOW_REFUSAL.findall(log)))
        u.check(f"{name}: the landing check saw the same window and the words arrive",
                len(lines) == 1 and lines[0][7] == "same" and lines[0][1] == "found", str(lines))
        if restore_on:
            u.check(f"{name}: the previous clipboard is back (restore on)",
                    u.wait_for("the clipboard restore", lambda: u.clipboard_text() == sentinel,
                               deadline=5.0), repr(u.clipboard_text()))
        return
    u.wait_for("the window refusal line",
               lambda: CLOSED_WINDOW_REFUSAL.search(u.log_since(PHASE_BASE["offset"])), deadline=5.0)
    u.check(f"{name}: the key paste was refused for Chrome's window, not for another app",
            bool(CLOSED_WINDOW_REFUSAL.search(u.log_since(PHASE_BASE["offset"]))),
            str(WINDOW_REFUSAL.findall(u.log_since(PHASE_BASE["offset"]))))
    u.check(f"{name}: no key paste into Chrome", chrome_tiers == ["clipboard_only"], str(cascades))
    board = u.clipboard_text() or ""
    u.check(f"{name}: the clipboard holds the dictation (5+ of 7 words)",
            u.sentence_overlap(board) >= 5, repr(board[:80]))


def phase_reuse_right_after():
    """#3135. A key paste into a Chrome page with nothing focused (a checked miss, so the cleanup
    holds the clipboard through the landing decision), then Paste Last (Control+Command+V) the
    moment the cascade logs its tier. Measured on main at ec30ec68: `clipboard_busy`, silently. Now
    the reuse waits for the cleanup and pastes. (A LANDED paste releases the board in ~200 ms, before
    this chord's release arrives, so it passed on main too and proves nothing here.)"""
    import threading
    name = "reuseafter"
    print(f"\n== {name}: Paste Last pressed right after a dictation's key paste")
    quiet(f"{name} staging", open_page, "nofocus")
    sentinel = f"ew-uat-sentinel-landing-{name}"
    u.set_clipboard_text(sentinel)
    base = u.log_size()
    PHASE_BASE["offset"] = base
    pressed = {}

    def press_when_pasted():
        if u.wait_for("the take's key paste", lambda: CASCADE.search(u.log_since(base)),
                      deadline=30.0):
            pressed["at"] = time.monotonic()
            u.chord("v")
    thread = threading.Thread(target=press_when_pasted, daemon=True)
    bar_before = address_bar_value()
    thread.start()
    _, cascades = take(name, base)
    thread.join(timeout=5.0)
    # Step 0 (#3304): the take and its Paste Last both target the no-focus page, whose only
    # destination is the address bar.
    check_step0(name, u.log_since(base), cascades,
                inserted=bar_before is None or address_bar_value() != bar_before)
    u.check(f"{name}: Paste Last was pressed right after the key paste", "at" in pressed)
    u.wait_for("the reuse outcome", lambda: u.reuse_lines(base), deadline=8.0)
    reuses = u.reuse_lines(base)
    if not reuses:
        # The chord is the DEFAULT Paste Last binding (Control+Command+V); a rebound shortcut never
        # reaches the action, and that must read as a setup failure, not as this change failing.
        raise u.Aborted(f"{name}: no Paste Last outcome at all: is Paste Last still bound to the "
                        "default Control+Command+V?")
    u.check(f"{name}: one Paste Last outcome, dispatched (was clipboard_busy before #3135)",
            reuses == [("paste", "chord", "dispatched")], str(reuses))
    # The reuse must have MET a held board; one that arrived after the cleanup released it would
    # pass on the old code too. The app logs the wait only when it found the board held.
    wait_line = r"last dictation reuse: waited for the clipboard ms=(\d+)"
    # Written by its own logging task, so it may land after the outcome line: waited for, not read.
    u.wait_for("the reuse's wait line", lambda: re.search(wait_line, u.log_since(base)), deadline=5.0)
    waited = re.findall(wait_line, u.log_since(base))
    u.check(f"{name}: Paste Last met the clipboard still held, and waited", len(waited) == 1,
            str(waited))
    kept = KEPT.findall(u.log_since(base))
    u.check(f"{name}: the miss was still kept by its cleanup", [k[0] for k in kept] == ["keep_dictation"],
            str(kept))


# The arrival session's count of focus notifications that named the pre-write focus (#3152).
REANNOUNCED = re.compile(r"PASTE_LANDING .* focus_reannounced=(\d+)")


def page_web_area():
    """The focused page's `AXWebArea` in Chrome (the focused element or its nearest ancestor)."""
    from ui_helpers import find_app_pid, get_attr, get_ax_app
    pid = find_app_pid("Google Chrome")
    element = get_attr(get_ax_app(pid), "AXFocusedUIElement") if pid else None
    for _ in range(30):
        if element is None or get_attr(element, "AXRole") == "AXWebArea":
            return element
        element = get_attr(element, "AXParent")
    return None


def page_descendants(area):
    """(role, element) for every descendant of `area`, depth-bounded."""
    from ui_helpers import get_attr
    out = []

    def walk(element, depth=0):
        if element is None or depth > 12:
            return
        for child in get_attr(element, "AXChildren") or []:
            out.append((get_attr(child, "AXRole"), child))
            walk(child, depth + 1)
    walk(area)
    return out


def phase_click_out():
    """#3152. The box is focused when the take starts, then the user clicks out onto the page
    before it ends (staged by focusing the page's web area through accessibility). The paste goes
    nowhere, and Chrome re-announces the unchanged page focus after the Cmd+V: the miss must be
    `absent`, kept, and shown, not voided as `focus_changed`."""
    import threading
    from ApplicationServices import AXUIElementSetAttributeValue
    name = "clickout"
    print(f"\n== {name}: box focused at the start, focus moved to the page before the take ends")
    quiet(f"{name} staging", open_page, "focused")
    area = page_web_area()
    if area is None:
        raise u.Aborted(f"{name}: the page's web area was not found")
    box = [el for role, el in page_descendants(area) if role == "AXTextArea"]
    if len(box) != 1:
        raise u.Aborted(f"{name}: expected one text box on the page, found {len(box)}")
    sentinel = f"ew-uat-sentinel-landing-{name}"
    u.set_clipboard_text(sentinel)
    base = u.log_size()
    PHASE_BASE["offset"] = base
    moved = {}
    stop = threading.Event()  # set on every exit, so no path leaves the worker able to move focus

    def click_out():
        if not u.wait_for("the take to start", lambda: stop.is_set()
                          or "Recording started" in u.log_since(base), deadline=20.0):
            return
        # The user clicks out partway through speaking, after the box was captured at the
        # start (the capture is logged with "Recording started"); the take lasts ~3 s.
        if stop.wait(0.8):  # settle: mid-take user action, not a wait for app state
            return
        moved["rc"] = AXUIElementSetAttributeValue(area, "AXFocused", True)
        moved["moved"] = u.wait_for("focus on the page", lambda: focused_role() == "AXWebArea",
                                    deadline=1.0)
        # The move must precede the paste, or this phase stages a different case.
        moved["before_paste"] = not CASCADE.search(u.log_since(base))
    thread = threading.Thread(target=click_out, daemon=True)
    thread.start()
    try:
        lines, cascades = take(name, base)
    finally:
        stop.set()
        # Once stopped, the worker ends within one wait poll or one bounded AX call.
        thread.join(timeout=5.0)
        moved["worker_finished"] = not thread.is_alive()
    if not moved["worker_finished"]:
        # Never recover or clean up beside a worker that can still move Chrome's focus.
        raise u.Aborted(f"{name}: the mid-take focus worker did not finish")
    quiet(f"{name} checks", verify_click_out, name, lines, cascades, moved, box[0])


def verify_click_out(name, lines, cascades, moved, box):
    from ui_helpers import get_attr
    u.check(f"{name}: focus moved to the page mid-take",
            moved.get("worker_finished") and moved.get("rc") == 0 and moved.get("moved")
            and moved.get("before_paste"), str(moved))
    chrome_tiers = [t for t, app in cascades if app.strip() == CHROME]
    u.check(f"{name}: one Cmd+V into Chrome (the box was captured at the start)",
            chrome_tiers == ["cgevent"], str(cascades))
    # Step 0 (#3304) before any early return: the box's raw value (unreadable counts as text).
    check_step0(name, u.log_since(PHASE_BASE["offset"]), cascades,
                inserted=get_attr(box, "AXValue") != "")
    u.check(f"{name}: exactly one PASTE_LANDING line", len(lines) == 1, str(lines))
    if len(lines) != 1:
        return
    observed, reason = lines[0][1], lines[0][2]
    u.check(f"{name}: observed=absent (was inconclusive/focus_changed before #3152)",
            observed == "absent", f"{observed}/{reason}")
    counts = REANNOUNCED.findall(u.log_since(PHASE_BASE["offset"]))
    # Proves the new branch ran: without a re-announcement this phase would pass on old code too.
    u.check(f"{name}: Chrome re-announced the unchanged focus, and it was ignored",
            len(counts) == 1 and int(counts[0]) >= 1, str(counts))
    value = get_attr(box, "AXValue")
    u.check(f"{name}: the box is still empty (read, not unreadable)", value == "",
            repr(value if value is None else str(value)[:80]))
    verify_kept(name)


# ── #3286: a Chromium host whose accessibility is asleep ─────────────────────────────────────
#
# A Chrome that no assistive client has woken reports NO focused element, with its box focused
# (measured 2026-09-29: `AXFocusedUIElement` -25212 for 12 s of polling on a fresh profile; the
# founder's everyday Chrome is already awake, so it cannot show this). The arrival session then
# reads `no_target`, which must never keep the dictation in place of the user's clipboard.
#
# Each phase runs in its OWN Chrome process (`--user-data-dir` in /tmp) so the founder's Chrome is
# never touched, and nothing reads that process's accessibility tree before the landing verdict is
# written: any AX read could be what wakes it. Only after the verdict does the driver request
# `AXEnhancedUserInterface` (Chromium acts on it about two seconds later) and read the boxes.

class SleepingChrome:
    """One isolated Chrome process, found by its own profile directory."""

    def __init__(self, label):
        import tempfile
        self.label = label
        self.profile = tempfile.mkdtemp(prefix=f"ew-uat-3286-{label}-{u.RUN_ID}-", dir="/tmp")
        self.pid = None

    def open(self, url):
        """Open `url` in this profile: the first call launches the process, later calls add a NEW
        WINDOW to it (Chrome hands a same-profile launch to the running process; without
        `--new-window` it may open a tab in the front window instead)."""
        extra = ["--new-window"] if self.pid is not None else []
        subprocess.run(["open", "-na", "Google Chrome", "--args", f"--user-data-dir={self.profile}",
                        "--no-first-run", "--no-default-browser-check", *extra, url], check=True)
        if self.pid is None:
            if not u.wait_for(f"{self.label}: its Chrome process", self._find_pid, deadline=15.0):
                raise u.Aborted(f"{self.label}: the isolated Chrome did not start")
            self.pid = self._find_pid()

    def _profile_pids(self):
        """Every process whose command line names this run's unique profile directory (Chrome and
        its helpers). `--` ends pgrep's options: the pattern itself starts with dashes."""
        r = subprocess.run(["pgrep", "-f", "--", f"--user-data-dir={self.profile}"],
                           capture_output=True, text=True)
        if r.returncode not in (0, 1):
            raise u.Aborted(f"{self.label}: pgrep failed: {r.stderr.strip()}")
        return [int(x) for x in r.stdout.split()]

    def _find_pid(self):
        for pid in self._profile_pids():
            cmd = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True,
                                 text=True).stdout
            if cmd.startswith("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"):
                return pid
        return None

    def front(self):
        from AppKit import NSRunningApplication
        app = NSRunningApplication.runningApplicationWithProcessIdentifier_(self.pid)
        if app is None:
            raise u.Aborted(f"{self.label}: its Chrome process is gone")
        app.activateWithOptions_(0)
        if not u.wait_for(f"{self.label}: its Chrome frontmost", self.is_front, deadline=5.0):
            raise u.Aborted(f"{self.label}: its Chrome did not come front (pid {frontmost_pid()})")

    def is_front(self):
        return frontmost_pid() == self.pid

    def wake(self):
        """After the verdict only. True once the process exposes a focused element."""
        from ApplicationServices import (AXUIElementCopyAttributeValue,
                                         AXUIElementCreateApplication, AXUIElementSetAttributeValue)
        from CoreFoundation import kCFBooleanTrue
        app = AXUIElementCreateApplication(self.pid)
        # Returns kAXErrorNotImplemented (-25208) on macOS 26+ and Chrome acts on it anyway.
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface", kCFBooleanTrue)
        return u.wait_for(f"{self.label}: its accessibility awake",
                          lambda: AXUIElementCopyAttributeValue(app, "AXFocusedUIElement", None)[0]
                          == 0, deadline=8.0)

    def boxes(self):
        """[(window title, box text)] for every window, after `wake`. A box is the first text area
        (ChatGPT's composer, a local page's textarea); an unreadable one reads None."""
        from ui_helpers import get_attr, get_ax_app
        found = []
        for window in get_attr(get_ax_app(self.pid), "AXWindows") or []:
            hit = []

            def walk(element, depth=0):
                if element is None or depth > 40 or hit:
                    return
                if get_attr(element, "AXRole") == "AXTextArea":
                    value = get_attr(element, "AXValue")
                    hit.append(None if value is None else str(value))
                    return
                for child in get_attr(element, "AXChildren") or []:
                    walk(child, depth + 1)
            walk(window)
            found.append((str(get_attr(window, "AXTitle") or ""), hit[0] if hit else None))
        return found

    def close(self):
        """TERM this profile's Chrome only, then delete its profile: never a mount point, and never
        while ANY process still names the profile (a Chrome found late, or one that did not quit,
        keeps it). Found by the profile path, so it works even when `self.pid` was never set."""
        main = self._find_pid()
        if main is not None:
            os.kill(main, 15)
        if not u.wait_for(f"{self.label}: every process of its profile gone",
                          lambda: not self._profile_pids(), deadline=15.0):
            print(f"    {self.label}: processes {self._profile_pids()} still use {self.profile}; "
                  "profile kept")
            return False
        if os.path.ismount(self.profile):
            return False
        subprocess.run(["find", self.profile, "-xdev", "-delete"], capture_output=True)
        return not os.path.exists(self.profile)


def frontmost_pid():
    from AppKit import NSDate, NSDefaultRunLoopMode, NSRunLoop, NSWorkspace
    NSRunLoop.currentRunLoop().runMode_beforeDate_(
        NSDefaultRunLoopMode, NSDate.dateWithTimeIntervalSinceNow_(0.05))
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    return int(app.processIdentifier()) if app else None


def set_clipboard_image():
    """Put a small PNG on the clipboard, the reporter's screenshot, and return its snapshot."""
    from AppKit import (NSBitmapImageRep, NSCalibratedRGBColorSpace, NSPasteboard,
                        NSPasteboardItem, NSPasteboardTypePNG, NSPNGFileType)
    rep_ = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
        None, 16, 16, 8, 4, True, False, NSCalibratedRGBColorSpace, 0, 0)
    png = rep_.representationUsingType_properties_(NSPNGFileType, {})
    item = NSPasteboardItem.alloc().init()
    item.setData_forType_(png, NSPasteboardTypePNG)
    board = NSPasteboard.generalPasteboard()
    board.clearContents()
    if not board.writeObjects_([item]):
        raise u.Aborted("could not put the test image on the clipboard")
    return u.pasteboard_snapshot()


def same_board(expected):
    """Every item, every type, every byte of the clipboard equals `expected`."""
    got = u.pasteboard_snapshot()
    return len(got) == len(expected) and all(
        set(g) == set(e) and all(bytes(g[k]) == bytes(e[k]) for k in e)
        for g, e in zip(got, expected))


def sleeping_take(label, chrome, before_hold=None, samples=None, expect_landing=True):
    """One take into the isolated Chrome with the image on the clipboard. Returns (lines,
    cascades, image, base) or raises Aborted. Nothing here reads that Chrome's accessibility tree
    beyond the one focus read (`focus_code`) sampled into `samples` before the recording and again
    just before the stop (#3304)."""
    # With restore OFF the cleanup rewrites the board to the dictation by design (legacy_rewrite),
    # so the image-comes-back checks only mean something with restore ON.
    if u.defaults_value("restoreClipboardAfterPaste") not in (None, "1"):
        raise u.Aborted(f"{label}: needs Restore clipboard after paste ON (it is off)")
    image = set_clipboard_image()
    base = u.log_size()
    PHASE_BASE["offset"] = base

    samples = {} if samples is None else samples

    def hold_check():
        if not chrome.is_front():
            raise u.Aborted(f"{label}: the isolated Chrome is not front (pid {frontmost_pid()})")
        samples["before_record"] = focus_code(chrome.pid)
        if before_hold is not None:
            before_hold()

    def stop_check():
        samples["before_stop"] = focus_code(chrome.pid)
    lines, cascades = take(label, base, bundle=CHROME, before_hold=hold_check,
                           before_release=stop_check, expect_landing=expect_landing)
    return lines, cascades, image, base


# #3304: every cleanup line, checked or not. A recorded-window session gets no landing check, so its
# cleanup logs WITHOUT `checked=true`; `KEPT` above stays the checked-only parser for PR B's phases.
CLEANUP = re.compile(r"Clipboard cleanup: op=(keep_dictation|yield|restore|legacy_rewrite), "
                     r"applied=(\w+), delay=\d+ms, tier=(\w+)(, checked=true)?")
# #3304 app.log lines: the record-start window capture, the dispatch gate's decision, a refusal.
CAPTURE = re.compile(r"AXDiag capture: (recorded window \(no field\)|no recorded window "
                     r"reason=\w+) elapsed_ms=(\d+)")
GATE = re.compile(r"WINDOW_GATE dispatch target=(\w+) result=(\w+) take_id=\S+ bundle_id=(\S+)")
REFUSED = re.compile(r"WINDOW_GATE refused stage=(\w+) reason=target_window_not_confirmed\((\w+)\)")
KEY_TIERS = ("cgevent", "applescript", "menu_paste")
# `AXFocusedUIElement` answers kAXErrorNoValue (-25212) while a text box is focused in a Chromium
# host whose accessibility sleeps (accessibility-macos.md FACT: electron-accessibility-switches-on-
# macos-26). Any other answer means awake (0) or a failed read: the sleeping proof is then
# INCONCLUSIVE, never PASS.
SLEEP_CODE = -25212


def focus_code(pid):
    """The raw `AXFocusedUIElement` error of `pid`'s application: one read, no role or tree read."""
    from ApplicationServices import AXUIElementCopyAttributeValue, AXUIElementCreateApplication
    try:
        return int(AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                                 "AXFocusedUIElement", None)[0])
    except Exception:
        return None


def inconclusive(name, detail):
    """Neither PASS nor FAIL: the precondition the proof needs was not there. Counted apart in the
    summary, and a run with one exits 3, never 0."""
    u.record(name, "INCONCLUSIVE", detail)


def asleep_detail(samples):
    return ", ".join(f"{k}={v}" for k, v in samples.items())


def is_asleep(samples):
    return bool(samples) and all(v == SLEEP_CODE for v in samples.values())


def single_insertion(value, times=1):
    """The sentence landed exactly `times` times: 5+ of its words present, and its distinctive
    word ('tomorrow') exactly `times` times, so a doubled paste fails."""
    text = (value or "").lower()
    return u.sentence_overlap(text) >= 5 and len(re.findall(r"\btomorrow\b", text)) == times


def notice_shown(text):
    return any(shown == "true" for _, shown, _ in NOTICE.findall(text))


def any_text(boxes):
    """Step 0 evidence from [(window title, box text)]: ANY text in any box is an insertion (a
    partial or doubled paste is still one), and an unreadable box or no box at all counts too."""
    return not boxes or any(v != "" for _, v in boxes)


def recorded_window_in(text):
    """Whether any take in `text` recorded a window at record start (its capture line says so)."""
    return any(c[0] == "recorded window (no field)" for c in CAPTURE.findall(text))


def check_step0(label, text, cascades, inserted):
    """Plan §11.1 step 0, per take: text OBSERVED in the destination plus a retained-paste Copied
    notice is a FAIL (the 2.5.1 regression). A take whose own log shows a recorded window also
    fails on a key paste followed by a retention or a notice request, whether or not the text was
    seen to land. `inserted` must come from the destination itself, never from the tier."""
    shown = notice_shown(text)
    u.check(f"{label}: step 0: never pasted AND Copied", not (inserted and shown),
            f"inserted={inserted} notice_shown={shown}")
    if recorded_window_in(text):
        dispatched = any(t in KEY_TIERS for t, _ in cascades)
        kept = any(c[0] == "keep_dictation" for c in CLEANUP.findall(text))
        requested = bool(NOTICE.findall(text))
        u.check(f"{label}: step 0: a recorded-window key paste is never kept or noticed",
                not (dispatched and (kept or requested)),
                f"dispatched={dispatched} kept={kept} notice_requested={requested}")


def verify_sleeping_cleanup(label, image, base):
    """The cleanup restored the copied image: exactly one restore line, applied, whether checked or
    not (a recorded-window session has no landing check, #3304), with no keep and no notice."""
    u.wait_for("the cleanup's line", lambda: CLEANUP.search(u.log_since(base)), deadline=10.0)
    text = u.log_since(base)
    lines = CLEANUP.findall(text)
    u.check(f"{label}: the cleanup restored, applied, never kept",
            [(c[0], c[1]) for c in lines] == [("restore", "true")], str(lines))
    u.check(f"{label}: no Copied notice was asked for", NOTICE.findall(text) == [],
            str(NOTICE.findall(text)))
    u.check(f"{label}: the copied image is back on the clipboard, every byte",
            u.wait_for("the image restore", lambda: same_board(image), deadline=5.0),
            f"{len(u.pasteboard_snapshot())} item(s) now")


def verify_recorded_window(label, text, want_gate="pass_same_window"):
    """The take recorded its window at start and, unless `want_gate` is None (a take refused at
    activation never reaches the dispatch gate), the dispatch gate decided on it as expected."""
    captures = CAPTURE.findall(text)
    u.check(f"{label}: record start recorded the window (no field)",
            [c[0] for c in captures] == ["recorded window (no field)"], str(captures))
    if want_gate is None:
        return
    gates = [(t, r) for t, r, app in GATE.findall(text) if app == CHROME]
    u.check(f"{label}: the dispatch gate read {want_gate} on the recorded window",
            bool(gates) and all(g == ("recorded_window", want_gate) for g in gates), str(gates))


def phase_sleeping(attempts=3):
    """#3286 primary: ChatGPT in a Chrome whose accessibility was never woken. The words land in
    ChatGPT's box and the copied image comes back, with no notice. Since #3304 the take records
    the window (no field) and its gate reads the same window. ChatGPT is a third-party page, so its
    box is read after the verdict and judged by the sentence (5+ words, 'tomorrow' once)."""
    print("\n== sleeping: dictate into ChatGPT in a Chrome that no accessibility client has woken")
    for attempt in range(1, attempts + 1):
        label = f"sleeping-{attempt}"
        chrome = SleepingChrome(label)
        try:
            chrome.open("https://chatgpt.com/")
            time.sleep(8)  # settle: ChatGPT loads and focuses its composer; nothing is read
            chrome.front()
            samples = {}
            lines, cascades, image, base = sleeping_take(label, chrome, samples=samples)
            text = u.log_since(base)
            chrome_tiers = [t for t, app in cascades if app.strip() == CHROME]
            observed = lines[0][1] if len(lines) == 1 else None
            print(f"    attempt {attempt}: tiers={chrome_tiers} landing={lines} {asleep_detail(samples)}")
            u.check(f"{label}: its accessibility woke after the verdict", chrome.wake())
            boxes = chrome.boxes()
            landed = [t for t, v in boxes if single_insertion(v)]
            # Step 0 evidence is ANY text in any box (a partial or doubled paste is still one), and
            # a box that cannot be read counts as text, so it can never hide a paste.
            check_step0(label, text, cascades, inserted=any_text(boxes))
            if not is_asleep(samples):
                inconclusive(f"{label}: sleeping proof", f"Chrome was not asleep ({asleep_detail(samples)})")
                continue
            u.check("sleeping: one Cmd+V paste into the isolated Chrome", chrome_tiers == ["cgevent"],
                    str(cascades))
            # #3286: an asleep take must never read as a keepable miss. On this Mac an asleep Chrome
            # reads no_target or inconclusive/focus_changed (both seen on main before #3304,
            # app.log 2026-09-29 13:10-13:11); neither retains. `absent` would be the defect.
            u.check("sleeping: the landing verdict is not a keepable miss (never absent)",
                    observed in ("no_target", "inconclusive"), str(lines))
            verify_recorded_window("sleeping", text)
            verify_sleeping_cleanup("sleeping", image, base)
            u.check("sleeping: the words landed once in ChatGPT's box", len(landed) == 1,
                    str([(t[:40], (v or "")[:60]) for t, v in boxes]))
            return
        finally:
            u.check(f"{label}: its Chrome closed and its profile removed", chrome.close())
    inconclusive("sleeping", f"no attempt of {attempts} kept Chrome asleep")


# Window A: a box focused at load. Window B: nothing focusable, nothing focused (the founder's
# LinkedIn case, #3304; the #3286 version focused a box in B).
#
# Both pages are PASSIVE observers (never focus after load, never preventDefault, never insert) and
# write what they saw into the window title, which stays readable while Chrome's accessibility
# sleeps (a title read does not wake it, measured 2026-09-29): `p` = paste events the page received,
# `len` = A's box length (ANY change is an insertion, right or wrong: step 0's evidence), `ok` = 1
# when A's box holds exactly the concatenation of the texts those pastes carried and none of them
# was empty (so an empty, truncated, doubled or extra insertion reads 0). Each take is checked by
# its own delta. `calibrate_pages()` proves those answers in a real headless Chrome.
SWITCH_PAGE = ('<!doctype html><meta charset="utf-8"><title>{title}</title>'
               '<body style="font:18px sans-serif;padding:24px"><p>{title} (local page).</p>'
               '<textarea id="t" autofocus rows="6" cols="70"></textarea><script>'
               'var t=document.getElementById("t"),got=[];'
               'function up(){{document.title="{title} |p="+got.length+"|len="+t.value.length'
               '+"|ok="+(t.value===got.join("")&&got.every(function(x){{return x.length>0;}})'
               '?1:0)+"|end";}}'
               'document.addEventListener("paste",function(e){{got.push(e.clipboardData.getData('
               '"text/plain"));setTimeout(up,0);}});t.addEventListener("input",up);t.focus();up();'
               '</script></body>')
BLANK_PAGE = ('<!doctype html><meta charset="utf-8"><title>{title}</title>'
              '<body style="font:18px sans-serif;padding:24px"><p>{title} (local page, nothing to '
              'type into).</p><script>var n=0;function up(){{document.title="{title} |p="+n+"|end";}}'
              'document.addEventListener("paste",function(){{n++;up();}});up();</script></body>')
PAGE_STATE = re.compile(r"\|p=(\d+)(?:\|len=(\d+)\|ok=([01]))?\|end")


def page_state(title_text):
    """(pastes, ok, box length) from an instrumented page's window title; ok and length are None
    for page B. None when the title carries no state (not loaded, or not our page)."""
    m = PAGE_STATE.search(title_text or "")
    if not m:
        return None
    if m.group(2) is None:
        return int(m.group(1)), None, None
    return int(m.group(1)), m.group(3) == "1", int(m.group(2))


def changed(before, after):
    """Step 0's insertion evidence from a page: ANY paste event or box change counts, right or
    wrong. An unreadable page counts as changed, so a missing reading can never hide a paste."""
    if before is None or after is None:
        return True
    return after[0] != before[0] or after[2] != before[2]


def exact_take(before, after, times=1):
    """A's state moved by exactly `times` paste events, its box grew, and it holds exactly what
    they carried (none empty)."""
    return (before is not None and after is not None and after[0] - before[0] == times
            and after[1] is True and after[2] > before[2])


def profile_pids(profile):
    """Every process naming `profile` as its user data directory, or raises: a failed probe is
    not "none left"."""
    r = subprocess.run(["pgrep", "-f", "--", f"--user-data-dir={profile}"],
                       capture_output=True, text=True)
    if r.returncode not in (0, 1):
        raise u.Aborted(f"pgrep failed for {profile}: {r.stderr.strip()}")
    return [int(x) for x in r.stdout.split()]


def remove_owned_profile_dir(directory, profile):
    """The isolated-Chrome cleanup policy for a directory this run created: TERM what still names
    its profile, wait (bounded) until nothing does, and only then delete it (never a mount point,
    never through a symlink). Kept, with the reason printed, whenever exit is uncertain."""
    try:
        for pid in profile_pids(profile):  # its own helpers, found by this run's unique path
            try:
                os.kill(pid, 15)
            except ProcessLookupError:
                pass
        gone = u.wait_for("every process of the calibration profile gone",
                          lambda: not profile_pids(profile), deadline=15.0)
    except u.Aborted as exc:
        print(f"    calibration directory kept at {directory}: {exc}")
        return False
    if not gone or os.path.islink(directory) or os.path.ismount(directory):
        print(f"    calibration directory kept at {directory}: processes {profile_pids(profile)}")
        return False
    subprocess.run(["find", directory, "-xdev", "-delete"], capture_output=True)
    return not os.path.exists(directory)


def calibrate_pages():
    """Runs page A's REAL observer in a headless Chrome (no window, no key, no clipboard) against
    synthetic paste events and returns {case: (pastes, ok, length)}: one exact paste, an empty
    payload, a truncated box, a doubled box. The caller compares with the expected answers."""
    cases = {"exact": ("hello", "hello"), "empty": ("", ""), "truncated": ("hello", "hell"),
             "doubled": ("hello", "hellohello")}
    script = ("<script>var R={};function run(k,pay,val){var t=document.getElementById('t');"
              "t.value='';got.length=0;var dt=new DataTransfer();dt.setData('text/plain',pay);"
              "document.dispatchEvent(new ClipboardEvent('paste',{clipboardData:dt}));"
              "t.value=val;up();R[k]=document.title;}"
              + "".join(f"run({k!r},{p!r},{v!r});" for k, (p, v) in cases.items())
              + "document.body.setAttribute('data-r',JSON.stringify(R));</script>")
    page = SWITCH_PAGE.format(title="calibration").replace("</body>", script + "</body>")
    import tempfile
    tmp = tempfile.mkdtemp(prefix="ew-uat-3304-calib-", dir="/tmp")
    profile = os.path.join(tmp, "profile")
    try:
        path = os.path.join(tmp, "a.html")
        with open(path, "w") as fh:
            fh.write(page)
        # Headless Chrome prints the DOM and then lingers (measured 2026-09-29): read until the
        # document is complete, then stop exactly this process (owned Popen pid) and wait for it.
        proc = subprocess.Popen(
            ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "--headless=new",
             f"--user-data-dir={tmp}/profile", "--no-first-run", "--disable-gpu",
             "--dump-dom", f"file://{path}"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True)
        dom = ""
        try:
            for line in proc.stdout:
                dom += line
                if "</html>" in line:
                    break
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=10)
    finally:
        remove_owned_profile_dir(tmp, profile)
    import html
    import json
    m = re.search(r"data-r=\"([^\"]*)\"", dom)
    if not m:
        raise u.Aborted(f"page calibration produced no result: {dom[-300:]}")
    return {k: page_state(v) for k, v in json.loads(html.unescape(m.group(1))).items()}


def untouched(before, after):
    """B's state is unchanged: no paste event reached it."""
    return before is not None and after is not None and after[0] == before[0]


def write_switch_pages(tag):
    titles = {k: f"ew 3304 {tag} {k} {u.RUN_ID}" for k in ("A", "B")}
    paths = {}
    for k, title in titles.items():
        paths[k] = f"/tmp/ew-uat-3304-{tag}-{k}-{u.RUN_ID}.html"
        with open(paths[k], "w") as fh:
            fh.write((SWITCH_PAGE if k == "A" else BLANK_PAGE).format(title=title))
    return titles, paths


def window_named(chrome, title):
    """The AX window of the isolated Chrome whose title starts with `title` (window attributes
    only; never the page's tree)."""
    from ui_helpers import get_attr, get_ax_app
    for window in get_attr(get_ax_app(chrome.pid), "AXWindows") or []:
        if str(get_attr(window, "AXTitle") or "").startswith(title):
            return window
    return None


def state_of(chrome, title):
    """The instrumented page's (pastes, ok) read from its window title, or None."""
    from ui_helpers import get_attr
    window = window_named(chrome, title)
    return page_state(str(get_attr(window, "AXTitle") or "")) if window is not None else None


def run_mid_take(stop, action, done):
    """A worker that runs `action` 0.6 s into the take (a user move), unless the phase is ending."""
    import threading

    def run():
        deadline = time.time() + 20.0
        while "Recording started" not in u.log_since(PHASE_BASE["offset"]):
            if time.time() > deadline or stop.wait(0.05):
                return
        if stop.wait(0.6):  # settle: the move happens 0.6 s into the take
            return
        action()
        done["moved"] = True
    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread


def phase_sleeping_switch():
    """#3304 step 1: dictate in window A of a sleeping Chrome, open window B (nothing focused)
    mid-take, stop. The recorded window A is raised and the words land in A's box exactly once; B
    receives no paste; the copied image comes back; no notice. On a Mac where a second window wakes
    Chrome (the dev Mac, measured 2026-09-29) the sleeping proof is INCONCLUSIVE, and any proven
    failure still counts."""
    print("\n== sleepingswitch: dictate in window A of a sleeping Chrome, open window B mid-take")
    chrome = SleepingChrome("sleeping-switch")
    titles, paths = write_switch_pages("switch")
    import threading
    stop = threading.Event()  # set before cleanup, so the worker can never open a window after it
    thread = None
    try:
        chrome.open(f"file://{paths['A']}")
        time.sleep(4)  # settle: page A loads and focuses its box; nothing is read
        chrome.front()
        a_before = state_of(chrome, titles["A"])
        done = {}
        PHASE_BASE["offset"] = u.log_size()
        thread = run_mid_take(stop, lambda: chrome.open(f"file://{paths['B']}"), done)
        samples = {}
        lines, cascades, image, base = sleeping_take("sleeping-switch", chrome, samples=samples)
        thread.join(timeout=10)
        text = u.log_since(base)
        u.wait_for("page A's state", lambda: state_of(chrome, titles["A"]) != a_before, deadline=3.0)
        a_after = state_of(chrome, titles["A"])
        b_after = state_of(chrome, titles["B"])
        print(f"    page A before={a_before} after={a_after}; page B={b_after} {asleep_detail(samples)}")
        inserted = exact_take(a_before, a_after)
        check_step0("sleeping-switch", text, cascades,
                    inserted=changed(a_before, a_after) or not untouched((0, None, None), b_after))
        u.check("sleeping-switch: window B opened mid-take", done.get("moved") is True and b_after is not None,
                f"moved={done.get('moved')} B={b_after}")
        u.check("sleeping-switch: B received no paste", untouched((0, None, None), b_after), str(b_after))
        refused = REFUSED.findall(text)
        u.check("sleeping-switch: no window refusal (A came back)", refused == [], str(refused))
        if not is_asleep(samples):
            inconclusive("sleeping-switch: sleeping proof (paste-back into A)",
                         f"Chrome was not asleep ({asleep_detail(samples)}); A {a_before}->{a_after}")
            return
        verify_recorded_window("sleeping-switch", text)
        u.check("sleeping-switch: the words landed in window A's box exactly once", inserted,
                f"{a_before}->{a_after}")
        verify_sleeping_cleanup("sleeping-switch", image, base)
        u.check("sleeping-switch: its accessibility woke after the verdict", chrome.wake())
        a_box = next((v for t, v in chrome.boxes() if t.startswith(titles["A"])), None)
        u.check("sleeping-switch: A's box holds the dictated sentence", single_insertion(a_box),
                repr((a_box or "")[:80]))
    finally:
        stop.set()
        if thread is not None:
            thread.join()
        u.check("sleeping-switch: its Chrome closed and its profile removed", chrome.close())
        for path in paths.values():
            if os.path.exists(path):
                os.remove(path)


def phase_sleeping_closed():
    """#3304 step 2: window A of a sleeping Chrome is closed mid-take while window B (nothing
    focused) is front. The gate reads B, a positive mismatch: no key paste, Tier 3 keeps the words
    on the clipboard; B receives no paste. Tier 3's Copied notice writes no app.log line (the
    retained-paste notice's RETAINED_NOTICE is a different path), so it is a visual check by eye,
    as in the #3121 closedwindow phase."""
    print("\n== sleepingclosed: window A of a sleeping Chrome is closed mid-take")
    chrome = SleepingChrome("sleeping-closed")
    titles, paths = write_switch_pages("closed")
    import threading
    stop = threading.Event()
    thread = None
    try:
        chrome.open(f"file://{paths['A']}")
        time.sleep(4)  # settle: page A loads and focuses its box; nothing is read
        chrome.open(f"file://{paths['B']}")
        time.sleep(2)  # settle: window B opens; nothing is read
        window_a = window_named(chrome, titles["A"])
        if window_a is None:
            raise u.Aborted("sleeping-closed: window A not found")
        from ui_helpers import get_attr, perform_action, set_attr
        perform_action(window_a, "AXRaise")  # the dictation starts in A
        set_attr(window_a, "AXMain", True)
        chrome.front()
        b_before = state_of(chrome, titles["B"])
        done = {}

        def close_a():
            close = get_attr(window_a, "AXCloseButton")
            if close is not None:
                perform_action(close, "AXPress")
        PHASE_BASE["offset"] = u.log_size()
        thread = run_mid_take(stop, close_a, done)
        samples = {}
        lines, cascades, image, base = sleeping_take(
            "sleeping-closed", chrome, samples=samples, expect_landing=False)
        thread.join(timeout=10)
        text = u.log_since(base)
        b_after = state_of(chrome, titles["B"])
        u.check("sleeping-closed: window A closed mid-take", done.get("moved") is True
                and window_named(chrome, titles["A"]) is None)
        tiers = [t for t, app in cascades if app.strip() == CHROME]
        refused = REFUSED.findall(text)
        # With a recorded window only a READ different window may refuse (window_mismatch). An
        # awake Chrome captured the field itself, and the #3121 field-window gate reports a closed
        # window as window_unreadable_focus_mismatch (measured 2026-09-29): also a correct refusal.
        allowed = ({"window_mismatch"} if recorded_window_in(text)
                   else {"window_mismatch", "window_unreadable_focus_mismatch"})
        u.check("sleeping-closed: refused because A's window is gone",
                bool(refused) and all(r in allowed for _, r in refused),
                f"{refused} recorded_window={recorded_window_in(text)}")
        u.check("sleeping-closed: no key paste, clipboard only", tiers == ["clipboard_only"],
                str(cascades))
        u.check("sleeping-closed: no PASTE_LANDING line (nothing was pasted)", lines == [], str(lines))
        u.check("sleeping-closed: B received no paste", untouched(b_before, b_after),
                f"{b_before}->{b_after}")
        clip = u.clipboard_text() or ""
        u.check("sleeping-closed: the dictation is kept on the clipboard (5+ of 7 words)",
                u.sentence_overlap(clip) >= 5, repr(clip[:80]))
        inconclusive("sleeping-closed: the Copied notice on screen",
                     "Tier 3's notice writes no app.log line: awaiting manual verification by eye")
        check_step0("sleeping-closed", text, cascades, inserted=not untouched(b_before, b_after))
        if not is_asleep(samples):
            # Awake, the field itself was captured and the #3121 field-window gate refused: the
            # checks above hold, but they do not prove the recorded-window path.
            inconclusive("sleeping-closed: sleeping proof (refusal on the recorded window)",
                         f"Chrome was not asleep ({asleep_detail(samples)})")
            return
        # Refused inside the activation loop, so no dispatch-gate line: the capture is the proof.
        verify_recorded_window("sleeping-closed", text, want_gate=None)
    finally:
        stop.set()
        if thread is not None:
            thread.join()
        u.check("sleeping-closed: its Chrome closed and its profile removed", chrome.close())
        for path in paths.values():
            if os.path.exists(path):
                os.remove(path)


def phase_sleeping_stay(takes=5):
    """#3304 step 3: five takes into window A of a sleeping Chrome, staying in A. Each take, read
    from page A's title right after its verdict: exactly one paste event and a box holding exactly
    what the pastes carried; plus the recorded window, pass_same_window, one Cmd+V, the image back,
    no notice. A take whose Chrome was not asleep is INCONCLUSIVE, and its checks still run."""
    print(f"\n== sleepingstay: {takes} takes into window A of a sleeping Chrome, no switch")
    chrome = SleepingChrome("sleeping-stay")
    titles, paths = write_switch_pages("stay")
    qualifying = 0
    try:
        chrome.open(f"file://{paths['A']}")
        time.sleep(4)  # settle: page A loads and focuses its box; nothing is read
        chrome.front()
        for n in range(1, takes + 1):
            label = f"sleeping-stay-{n}"
            before = state_of(chrome, titles["A"])
            samples = {}
            lines, cascades, image, base = sleeping_take(label, chrome, samples=samples)
            text = u.log_since(base)
            u.wait_for(f"{label}: page A's state", lambda: state_of(chrome, titles["A"]) != before,
                       deadline=3.0)
            after = state_of(chrome, titles["A"])
            inserted = exact_take(before, after)
            tiers = [t for t, app in cascades if app.strip() == CHROME]
            print(f"    {label}: page A {before}->{after} tiers={tiers} {asleep_detail(samples)}")
            check_step0(label, text, cascades, inserted=changed(before, after))
            u.check(f"{label}: exactly one insertion, exactly the pasted text", inserted,
                    f"{before}->{after}")
            u.check(f"{label}: one Cmd+V paste into the isolated Chrome", tiers == ["cgevent"],
                    str(cascades))
            u.check(f"{label}: no window refusal", REFUSED.findall(text) == [], str(REFUSED.findall(text)))
            verify_sleeping_cleanup(label, image, base)
            if not is_asleep(samples):
                inconclusive(f"{label}: sleeping proof", f"Chrome was not asleep ({asleep_detail(samples)})")
                continue
            qualifying += 1
            verify_recorded_window(label, text)
        if qualifying < takes:
            inconclusive("sleeping-stay: five sleeping takes", f"{qualifying} of {takes} kept Chrome asleep")
    finally:
        u.check("sleeping-stay: its Chrome closed and its profile removed", chrome.close())
        for path in paths.values():
            if os.path.exists(path):
                os.remove(path)


# ---------------------------------------------------------------------------------------------
# #3423: a floating launcher panel (Raycast, Alfred) takes the keyboard focus WITHOUT becoming the
# front application. The fixture (`Tests/Fixtures/launcher-panel/`) is that window and nothing else: an
# accessory app whose non-activating panel becomes key over a TextEdit document that stays front.
# Field A accepts Accessibility writes (Tier 1, `ax_direct`); field B silently ignores them, so the
# write verifies as no mutation and the take reaches the key paste (Tier 2, `cgevent`), the route the
# ENVIOUSWISPR-6G report ended on as "Copied". This proves the CLASS on this Mac, never Raycast itself.
LAUNCHER = "com.enviouswispr.uat.launcherpanel"
TARGET_FOCUS = re.compile(r"TARGET_FOCUS state=(\w+) front=(\S+) owner=(\S+)")
ACTIVATION_SKIPPED = "activation skipped: destination owns the keyboard focus (#3423)"
TERMINAL_COMPLETED = re.compile(r"dictation_terminal result=completed")
LEARN_SKIPPED = re.compile(r"learn_skipped reason=(\w+) take=(\S+)")
FIXTURE = {"app": None, "proc": None, "run": None}
# Plan section 11.1: the launcher takes speak these, never the shared `SENTENCE`.
LAUNCHER_SENTENCE = "Please send the quarterly summary to Marcus by Friday afternoon."
LAUNCHER_CONTINUATION = "then ask whether the budget review moved"
# A step's text runs to the next log line's `[time] [LEVEL] [Category]` prefix, so a multi-line
# output (a list, a paragraph break) is read whole.
DEBUG_TEXT = re.compile(
    r"CORRECTION_DEBUG \[([^\]]+)\] (?:OUT: )?"
    r"(.*?)(?=^\[[^\]\n]+\] \[(?:DEBUG|INFO|VERBOSE|WARNING|ERROR)\] \[|\Z)",
    re.M | re.S)
AX_WRITE_SUCCEEDED = re.compile(
    r"step=ax_direct_write started_at=\S+ elapsed_ms=\S+ outcome=succeeded bundle_id=(\S+)")


def build_launcher():
    """The fixture app, built once per run into the worktree's gitignored `build/`."""
    if FIXTURE["app"] is None:
        script = os.path.join(HERE, "..", "Fixtures", "launcher-panel", "build.sh")
        out = subprocess.run([script], capture_output=True, text=True)
        if out.returncode != 0 or not out.stdout.strip():
            raise u.Aborted(f"launcher fixture did not build: {out.stderr.strip()[-400:]}")
        FIXTURE["app"] = out.stdout.strip().splitlines()[-1]
    return FIXTURE["app"]


def panel_state():
    """The fixture's own report (`state.json`), or {} before its first write."""
    import json
    run = FIXTURE["run"]
    if run is None:
        return {}
    try:
        with open(os.path.join(run, "state.json")) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def panel_command(name, text=""):
    """Hands the fixture one command file, written whole (temp then rename)."""
    run = FIXTURE["run"]
    temp = os.path.join(run, f".{name}.tmp")
    with open(temp, "w") as fh:
        fh.write(text)
    os.replace(temp, os.path.join(run, name))


def launch_panel(field):
    """Starts the fixture with `field` focused, by its executable (never `open`, which could
    activate it), and waits for its own report that the panel is key on that field."""
    import tempfile
    if not close_panel():
        raise u.Aborted("previous launcher fixture did not exit; refusing to replace its handle")
    app = build_launcher()
    FIXTURE["run"] = tempfile.mkdtemp(prefix=f"ew-uat-3423-{field}-{u.RUN_ID}-")
    FIXTURE["proc"] = subprocess.Popen(
        [os.path.join(app, "Contents", "MacOS", "LauncherPanel"), FIXTURE["run"], field])
    if not u.wait_for("the launcher panel to be key on its field",
                      lambda: panel_state().get("key") and panel_state().get("focused") == field,
                      deadline=8.0):
        raise u.Aborted(f"launcher fixture never became key on field {field}: {panel_state()}")


def close_panel():
    """Quits THIS run's fixture process (the Popen handle's own pid): the quit command, then
    terminate, then kill, each confirmed by `wait`. Forgets the handle only once the process is
    gone; False (handle kept) when even the kill could not be confirmed."""
    proc = FIXTURE["proc"]
    if proc is None:
        return True
    if proc.poll() is None:
        for stop in (lambda: panel_command("quit"), proc.terminate, proc.kill):
            try:
                stop()
                proc.wait(timeout=5)
                break
            except Exception:
                continue
    if proc.poll() is None:
        return False
    FIXTURE["proc"] = None
    return True


def focus_owner_pid():
    """The pid owning the SYSTEM-WIDE focused element, or None. Needs an `NSApplication` in this
    process: without one every system-wide read fails with -25204 (measured 2026-10-03, #3423)."""
    import AppKit
    from ApplicationServices import (AXUIElementCopyAttributeValue, AXUIElementCreateSystemWide,
                                     AXUIElementGetPid)
    AppKit.NSApplication.sharedApplication()
    err, element = AXUIElementCopyAttributeValue(
        AXUIElementCreateSystemWide(), "AXFocusedUIElement", None)
    if err or element is None:
        return None
    err, pid = AXUIElementGetPid(element, None)
    return None if err else pid


def launcher_precondition(host, field):
    """Checked immediately before the hold: the host is still front, the panel's process owns the
    keyboard focus, and the intended field is focused. Never activates the fixture to pass."""
    def check():
        u.require_front(host, "launcher: host before the take")
        proc = FIXTURE["proc"]
        owner = focus_owner_pid()
        if proc is None or owner != proc.pid:
            raise u.Aborted(f"launcher: the focus owner is {owner}, not the panel ({proc and proc.pid})")
        if panel_state().get("focused") != field:
            raise u.Aborted(f"launcher: field {field} is not focused: {panel_state()}")
    return check


def submitted_text(log_text):
    """The take's final text as the pipeline logged it: the last `OUT:` (or the raw recogniser
    line) in the take's own log window, in log order. Independent of the destination's text, so a
    field holding it exactly proves one whole insertion; a doubled, truncated or partly repeated
    paste does not match. Nil when the window logged no text."""
    texts = [text.strip() for step, text in DEBUG_TEXT.findall(log_text)
             if text.strip() and text.strip() != "no change" and not text.startswith("IN:")]
    return texts[-1] if texts else None


def words_heard(text, sentence):
    """How many of `sentence`'s words the take's text holds: a guard that the take recognised
    what was spoken, never the insertion verdict."""
    want = {w.strip(".,").lower() for w in sentence.split()}
    return len(want & {w.strip(".,").lower() for w in (text or "").split()})


def readable_empty(value):
    """True only for a READ that returned an empty string; an unreadable read (None) is not
    evidence that nothing landed."""
    return isinstance(value, str) and value == ""


def take_id_in(text):
    match = re.search(r"dictation_terminal result=\w+ reason=\S+ take=(\S+)", text)
    return match.group(1) if match else None


def verify_launcher(name, text, field, want_tier, host_doc=None):
    """The checks every launcher take shares; returns the take's text in `field`."""
    focus = TARGET_FOCUS.findall(text)
    u.check(f"{name}: record start targeted the panel (TARGET_FOCUS disagree)",
            len(focus) == 1 and focus[0] == ("disagree", TEXTEDIT, LAUNCHER), str(focus))
    tiers = [t for t, app in CASCADE.findall(text) if app.strip() == LAUNCHER]
    others = [(t, app.strip()) for t, app in CASCADE.findall(text) if app.strip() != LAUNCHER]
    u.check(f"{name}: one paste into the panel's app, tier {want_tier}",
            tiers == [want_tier] and not others, f"panel={tiers} other={others}")
    u.check(f"{name}: the take completed", len(TERMINAL_COMPLETED.findall(text)) == 1,
            str(TERMINAL_COMPLETED.findall(text)))
    fields = panel_state().get("fields", {})
    other = "B" if field == "A" else "A"
    u.check(f"{name}: the other panel field is untouched", fields.get(other) == "",
            repr(fields.get(other)))
    if host_doc is not None:
        host_value = u.field_text(host_doc)
        u.check(f"{name}: nothing landed in the TextEdit document behind the panel",
                readable_empty(host_value), repr(host_value))
    return fields.get(field, "")


def verify_exact(name, field_value, log_text, sentence):
    """The field holds exactly the take's submitted text, once."""
    submitted = submitted_text(log_text)
    u.check(f"{name}: the take recognised the spoken sentence",
            words_heard(submitted, sentence) >= len(sentence.split()) - 3, repr(submitted))
    u.check(f"{name}: the field holds the submitted text exactly once",
            submitted is not None and (field_value or "").strip() == submitted,
            f"field={field_value!r} submitted={submitted!r}")
    return submitted


def launcher_host(name):
    """A fresh TextEdit document in front: the app a launcher panel floats over."""
    # The "3106-" prefix is what `u.close_run_documents` closes at the end of the run.
    path = u.new_textedit_doc(f"3106-3423-{name}-{u.RUN_ID}")
    u.require_front(TEXTEDIT, f"{name}: host document open")
    return path


def phase_launcher_tier1():
    print("\n== launcher_tier1: dictation into a launcher panel field that accepts a direct write")
    host = launcher_host("launcher_tier1")
    launch_panel("A")
    try:
        base = u.log_size()
        take("launcher_tier1", base, bundle=TEXTEDIT, expect_landing=False,
             before_hold=launcher_precondition(TEXTEDIT, "A"), sentence=LAUNCHER_SENTENCE)
        u.wait_for("the dictation in field A",
                   lambda: panel_state().get("fields", {}).get("A", ""), deadline=15.0)
        text = u.log_since(base)
        value = verify_launcher("launcher_tier1", text, "A", "ax_direct", host_doc=host)
        first = verify_exact("launcher_tier1", value, text, LAUNCHER_SENTENCE)
        # The continuation: a second take into the same field, after the first one's sentence. The
        # field must hold both submitted texts joined by exactly one space, once each.
        base2 = u.log_size()
        take("launcher_tier1 continuation", base2, bundle=TEXTEDIT, expect_landing=False,
             before_hold=launcher_precondition(TEXTEDIT, "A"), sentence=LAUNCHER_CONTINUATION)
        text2 = u.log_since(base2)
        second = submitted_text(text2)
        u.wait_for("the continuation in field A", lambda: len(
            panel_state().get("fields", {}).get("A", "")) > len(value), deadline=15.0)
        joined = panel_state().get("fields", {}).get("A", "")
        u.check("launcher_tier1: the continuation joins the first take once, with one space",
                first is not None and second is not None
                and joined.strip() == f"{first} {second}",
                f"field={joined!r} first={first!r} second={second!r}")
        tiers = [t for t, app in CASCADE.findall(text2) if app.strip() == LAUNCHER]
        u.check("launcher_tier1: the continuation also pasted into the panel's app",
                tiers == ["ax_direct"], str(CASCADE.findall(text2)))
    finally:
        close_panel()


def phase_launcher_tier2():
    print("\n== launcher_tier2: a field that ignores direct writes, so the key paste runs")
    host = launcher_host("launcher_tier2")
    launch_panel("B")
    try:
        sentinel = "ew-uat-sentinel-launcher-tier2"
        restore_on = u.defaults_value("restoreClipboardAfterPaste") in (None, "1")
        u.set_clipboard_text(sentinel)
        base = u.log_size()
        lines, _ = take("launcher_tier2", base, bundle=TEXTEDIT, expect_landing=True,
                        before_hold=launcher_precondition(TEXTEDIT, "B"), sentence=LAUNCHER_SENTENCE)
        text = u.log_since(base)
        value = verify_launcher("launcher_tier2", text, "B", "cgevent", host_doc=host)
        verify_exact("launcher_tier2", value, text, LAUNCHER_SENTENCE)
        # Tier 1 really ran and wrote, and the write changed nothing (field B ignores Accessibility
        # writes): the cascade only reaches `cgevent` after a verified no-mutation write, and the
        # field holding the text exactly once rules out the write having landed too.
        u.check("launcher_tier2: Tier 1 wrote to the panel field first, and the key paste followed",
                AX_WRITE_SUCCEEDED.findall(text) == [LAUNCHER], str(AX_WRITE_SUCCEEDED.findall(text)))
        u.check("launcher_tier2: activation was skipped for the panel's app",
                text.count(ACTIVATION_SKIPPED) == 1, str(text.count(ACTIVATION_SKIPPED)))
        landing = [l for l in lines if l[3] == LAUNCHER]
        u.check("launcher_tier2: the landing check found the paste in the panel field",
                len(landing) == 1 and landing[0][0] == "cgevent" and landing[0][1] == "found",
                str(lines))
        if restore_on:
            u.check("launcher_tier2: the previous clipboard is back (restore on)",
                    u.wait_for("the clipboard restore", lambda: u.clipboard_text() == sentinel,
                               deadline=5.0), repr(u.clipboard_text()))
        else:
            u.skip("launcher_tier2: clipboard restore", "the founder's restore setting is off")
        verify_launcher_learning(base, text)
    finally:
        close_panel()


LEARN_JUDGED = re.compile(r"learn_judged arm=(\w+) outcome=(\w+) candidates=(\d+) accepted=(\d+) .*?take=(\S+)")
LEARN_ADDED = re.compile(r"learn_added state=(\w+)")
LEARN_SAVE_FAILED = re.compile(r"learn_save_failed reason=(\w+)")
# The founder's real word file, snapshotted before the first learned correction and restored, with
# this worktree's app stopped, at the end of the run (the `learn_from_edits_uat.py` procedure).
WORDS = {"snap": None}


def verify_launcher_learning(base, text):
    """Self-learning works in the panel: the take is watched (no `destination_mismatch`), a typed
    correction ("Marcus" to "Markus") is judged and SAVED, and the word file holds the new entry.
    The file is restored at the end of the run (`restore_words`)."""
    import learn_from_edits_uat as lf
    if u.defaults_value("learnFromEdits") in ("0", "false"):
        u.record("launcher_tier2: learning proof", "INCONCLUSIVE",
                 "Self-Learning Dictionary is off; required proof was not exercised")
        return
    take_id = take_id_in(text)
    if WORDS["snap"] is None:
        WORDS["snap"] = lf.file_snapshot(lf.WORDS)
    before = lf.file_snapshot(lf.WORDS)
    field = panel_state().get("fields", {}).get("B", "")
    if "Marcus" not in field:
        u.record("launcher_tier2: saved correction", "INCONCLUSIVE",
                 f"the recogniser did not write 'Marcus' to correct: {field!r}")
        return
    u.require_front(TEXTEDIT, "launcher_tier2: host before the edit")
    if focus_owner_pid() != (FIXTURE["proc"] and FIXTURE["proc"].pid):
        raise u.Aborted("launcher_tier2: the panel lost the focus before the edit")
    # The fixture reports Cocoa's UTF-16 offsets; a character before the word that is two UTF-16
    # units (an emoji) would otherwise put Python's index one short.
    start = len(field[:field.index("Marcus")].encode("utf-16-le")) // 2
    panel_command("select", "B Marcus")
    if not u.wait_for("Marcus selected in field B",
                      lambda: panel_state().get("selection") == [start, len("Marcus")], deadline=3.0):
        raise u.Aborted(f"launcher_tier2: the fixture did not select Marcus: {panel_state()}")
    learn_base = u.log_size()
    import simulate_input as si
    si.type_text("Markus")
    def judged_rows():
        return [j for j in LEARN_JUDGED.findall(u.log_since(learn_base)) if j[4] == take_id]
    # `wait_for` answers whether the condition came true, never the value: read the rows again.
    u.wait_for("the correction to be judged", judged_rows, deadline=25.0)
    judged = judged_rows()
    skipped = [r for r, t in LEARN_SKIPPED.findall(u.log_since(base)) if t == take_id]
    u.check("launcher_tier2: learning did not skip the panel as another app",
            take_id is not None and not skipped, f"take={take_id} skips={skipped}")
    if not judged:
        u.check("launcher_tier2: the correction in the panel field was judged", False,
                "no learn_judged line for this take within 25 s")
        return
    arm, outcome, candidates, accepted, _ = judged[0]
    u.check("launcher_tier2: the correction in the panel field was judged", int(candidates) >= 1,
            f"arm={arm} outcome={outcome} candidates={candidates} accepted={accepted}")
    if int(accepted) < 1:
        u.record("launcher_tier2: saved correction", "INCONCLUSIVE",
                 f"the judge ({arm}) declined Marcus -> Markus ({outcome}); nothing to save")
        return
    added = u.wait_for("the save", lambda: LEARN_ADDED.search(u.log_since(learn_base))
                       or LEARN_SAVE_FAILED.search(u.log_since(learn_base)), deadline=10.0)
    after = lf.file_snapshot(lf.WORDS)
    u.check("launcher_tier2: the correction was saved (learn_added)",
            bool(added) and LEARN_ADDED.search(u.log_since(learn_base)) is not None,
            u.log_since(learn_base)[-300:])
    entry_before, entry_after = learned_entry(before), learned_entry(after)
    u.check("launcher_tier2: the word file holds Markus with Marcus as a learned alias",
            entry_after is not None and entry_after != entry_before,
            f"before={entry_before} after={entry_after}")


def learned_entry(snapshot, canonical="Markus", heard="Marcus"):
    """The word-file entry whose canonical is `canonical` and which carries `heard` as a LEARNED
    alias (`aliases` and `learnedAliases`, the sparkle's source), or None. Parsed, never a text
    count: the word may appear elsewhere in the file, and learning may extend an existing entry."""
    import learn_from_edits_uat as lf
    entries = lf.keyed(snapshot.get("parsed") if snapshot.get("exists") else None, "words") or {}
    for entry in entries.values():
        if not isinstance(entry, dict):
            continue
        if str(entry.get("canonical", "")).casefold() != canonical.casefold():
            continue
        aliases = {str(a).casefold() for a in entry.get("aliases") or []}
        learned = {str(a).casefold() for a in entry.get("learnedAliases") or []}
        if heard.casefold() in aliases and heard.casefold() in learned:
            return entry
    return None


def restore_words():
    """Puts the founder's word file back, byte for byte, with this worktree's app stopped (it holds
    the words in memory and would write them back), then starts the app again. True when nothing
    was snapshotted or the restore verified."""
    import learn_from_edits_uat as lf
    snap = WORDS["snap"]
    if snap is None:
        return True
    # Stopped FIRST, even when the bytes already match: a queued save or the in-memory list could
    # still write the learned word back after the restore.
    lf.stop_app()
    lf.file_restore(lf.WORDS, snap)
    ok, detail = lf.verify_restore(lf.WORDS, snap, "words")
    print(f"    word file restore: {detail}")
    relaunched = subprocess.run(["open", "-n", lf.APP], check=False).returncode == 0
    print(f"    dev app relaunched: {relaunched}")
    if ok and relaunched:
        WORDS["snap"] = None
    return ok and relaunched


def phase_launcher_dismissed():
    print("\n== launcher_dismissed: the panel closes during the take; the words stay on the clipboard")
    host = launcher_host("launcher_dismissed")
    launch_panel("B")
    try:
        base = u.log_size()

        def dismiss():
            panel_command("dismiss")
            if not u.wait_for("the panel to close", lambda: panel_state().get("closed"), deadline=3.0):
                raise u.Aborted("launcher_dismissed: the panel did not close")

        take("launcher_dismissed", base, bundle=TEXTEDIT, expect_landing=False,
             before_hold=launcher_precondition(TEXTEDIT, "B"), before_release=dismiss,
             sentence=LAUNCHER_SENTENCE)
        text = u.log_since(base)
        focus = TARGET_FOCUS.findall(text)
        u.check("launcher_dismissed: record start targeted the panel",
                len(focus) == 1 and focus[0][0] == "disagree", str(focus))
        tiers = [t for t, _ in CASCADE.findall(text)]
        u.check("launcher_dismissed: no key paste ran; the take ended clipboard-only",
                tiers == ["clipboard_only"], str(tiers))
        u.check("launcher_dismissed: the take completed",
                len(TERMINAL_COMPLETED.findall(text)) == 1, "")
        fields = panel_state().get("fields", {})
        u.check("launcher_dismissed: nothing landed in the closed panel",
                fields.get("A") == "" and fields.get("B") == "", str(fields))
        host_value = u.field_text(host)
        u.check("launcher_dismissed: nothing landed in the TextEdit document",
                readable_empty(host_value), repr(host_value))
        board = u.clipboard_text() or ""
        submitted = submitted_text(text)
        u.check("launcher_dismissed: the dictation is on the clipboard (the Copied fallback)",
                submitted is not None and board.strip() == submitted,
                f"board={board[:80]!r} submitted={submitted!r}")
    finally:
        close_panel()


def phase_appswap():
    """Dictate into TextEdit document A, switch to Chrome during the take: the words land in A (the
    box saved at record start), not in Chrome's text box. Guards that the owner rule leaves the
    ordinary saved-target behaviour alone."""
    print("\n== appswap: dictate into TextEdit, switch to Chrome mid-take")
    quiet("appswap staging", open_page, "focused")
    doc = u.new_textedit_doc(f"3106-3423-appswap-{u.RUN_ID}")
    u.require_front(TEXTEDIT, "appswap: document open")
    sentinel = "ew-uat-sentinel-appswap"
    restore_on = u.defaults_value("restoreClipboardAfterPaste") in (None, "1")
    u.set_clipboard_text(sentinel)
    base = u.log_size()

    def swap():
        subprocess.run(["open", "-b", CHROME], check=False)
        if not u.wait_for("Chrome front", lambda: u.frontmost_bundle() == CHROME, deadline=5.0):
            raise u.Aborted("appswap: Chrome did not come front")

    take("appswap", base, bundle=TEXTEDIT, expect_landing=False, before_release=swap)
    u.wait_for("the dictation in document A", lambda: u.doc_text(doc), deadline=15.0)
    text = u.log_since(base)
    focus = TARGET_FOCUS.findall(text)
    u.check("appswap: record start agreed (TextEdit front and focus owner)",
            len(focus) == 1 and focus[0][0] == "agree" and focus[0][1] == TEXTEDIT, str(focus))
    tiers = [(t, app.strip()) for t, app in CASCADE.findall(text)]
    u.check("appswap: one paste into TextEdit, not clipboard-only",
            len(tiers) == 1 and tiers[0][1] == TEXTEDIT and tiers[0][0] != "clipboard_only",
            str(tiers))
    verify_exact("appswap", u.field_text(doc), text, SENTENCE)
    decoy = textbox_value()
    u.check("appswap: nothing landed in Chrome's text box", readable_empty(decoy), repr(decoy))
    if restore_on:
        u.check("appswap: the previous clipboard is back (restore on)",
                u.wait_for("the clipboard restore", lambda: u.clipboard_text() == sentinel,
                           deadline=5.0), repr(u.clipboard_text()))
    else:
        u.skip("appswap: clipboard restore", "the founder's restore setting is off")


def focused_value():
    """The system-wide focused element's owner pid, role and value (None for any unread part)."""
    import AppKit
    from ApplicationServices import (AXUIElementCopyAttributeValue, AXUIElementCreateSystemWide,
                                     AXUIElementGetPid)
    AppKit.NSApplication.sharedApplication()
    err, element = AXUIElementCopyAttributeValue(
        AXUIElementCreateSystemWide(), "AXFocusedUIElement", None)
    if err or element is None:
        return None, None, None
    _, pid = AXUIElementGetPid(element, None)
    _, role = AXUIElementCopyAttributeValue(element, "AXRole", None)
    _, value = AXUIElementCopyAttributeValue(element, "AXValue", None)
    return pid, role, value


def phase_savesheet():
    """Observation row (plan section 11.1), never a pass/fail of the product: dictate into the
    file-name field of TextEdit's Save sheet, a field another process may host. Records who owned
    the focus, the record-start state, the tier, and whether the name field changed; the sheet is
    cancelled afterwards."""
    print("\n== savesheet: observation, dictation into TextEdit's Save sheet name field")
    import simulate_input as si
    doc = u.new_textedit_doc(f"3106-3423-savesheet-{u.RUN_ID}")
    u.require_front(TEXTEDIT, "savesheet: document open")
    # Save As (Shift+Option+Cmd+S): the run's document is an existing file, so plain Cmd+S would
    # save it without a sheet.
    si.press_key("s", cmd=True, shift=True, alt=True)
    try:
        if not u.wait_for("the Save sheet's name field",
                          lambda: focused_value()[1] == "AXTextField", deadline=5.0):
            u.record("savesheet: observation", "INCONCLUSIVE",
                     f"no focused text field: {focused_value()}")
            return
        owner, _, before = focused_value()
        si.press_key("a", cmd=True)
        si.press_key("delete")
        base = u.log_size()
        take("savesheet", base, bundle=TEXTEDIT, expect_landing=False)
        time.sleep(1.0)
        owner_after, role, after = focused_value()
        text = u.log_since(base)
        u.record("savesheet: observation", "PASS",
                 f"focus_owner_pid={owner} textedit_front=True target_focus={TARGET_FOCUS.findall(text)} "
                 f"tiers={CASCADE.findall(text)} name_before={before!r} name_after={after!r} "
                 f"role={role} owner_after={owner_after} doc={u.field_text(doc)!r}")
    finally:
        si.press_key("escape")


LAUNCHER_PHASES = {
    "savesheet": phase_savesheet,
    "launcher_tier1": phase_launcher_tier1,
    "launcher_tier2": phase_launcher_tier2,
    "launcher_dismissed": phase_launcher_dismissed,
    "appswap": phase_appswap,
}


PHASES = ["focused", "nofocus", "textedit", "readonly", "copy", "newtake", "otherwindow",
          "closedwindow", "reuseafter", "clickout", "sleeping", "sleepingswitch", "sleepingclosed",
          "sleepingstay", *LAUNCHER_PHASES]


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
    from silent_audio import AudioRoute
    route = None
    try:
        route = AudioRoute()  # inside the try: a failed Settings read must still restore the sink
        route.install_restore_handlers()
        route.apply()
        RUN_ROUTE["route"] = route
        u.run_metered("control", lambda: None)
        for name in wanted:
            # Metered inside each phase, around the stretches that play no speech.
            if name == "textedit":
                phase_textedit()
            elif name == "copy":
                phase_copy_during_wait()
            elif name == "newtake":
                phase_new_take_after_miss()
            elif name == "reuseafter":
                phase_reuse_right_after()
            elif name == "clickout":
                phase_click_out()
            elif name in ("otherwindow", "closedwindow"):
                phase_other_window(close_target=name == "closedwindow")
            elif name == "sleeping":
                phase_sleeping()
            elif name == "sleepingswitch":
                phase_sleeping_switch()
            elif name == "sleepingclosed":
                phase_sleeping_closed()
            elif name == "sleepingstay":
                phase_sleeping_stay()
            elif name in LAUNCHER_PHASES:
                LAUNCHER_PHASES[name]()
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
            ("launcher fixture closed", close_panel),
        ]:
            try:
                u.check(label, bool(step()))
            except Exception as exc:
                u.check(label, False, repr(exc))
        # The microphone goes back once, and only when no take can still be listening: a take whose
        # stop was not confirmed leaves the virtual route in place (`LiveTakeNotStopped`).
        if route is None:
            pass  # never built, so never applied: nothing of the microphone's to put back
        elif TAKE_STUCK["stuck"]:
            u.record("microphone restored", "FAIL", "a take may still be live; the virtual route is "
                     "left in place. Recover: quit the dev app, then "
                     "`python3 Tests/RuntimeUAT/silent_audio.py restore`.")
        else:
            try:
                u.check("microphone restored (once, for the whole run)", route.restore())
            except Exception as exc:
                u.check("microphone restored (once, for the whole run)", False, repr(exc))
        RUN_ROUTE["route"] = None
        try:
            u.check("devices restored", sink.restore())
        except Exception as exc:
            u.check("devices restored", False, repr(exc))
        try:
            u.check("word file restored (Self-Learning Dictionary)", restore_words())
        except Exception as exc:
            u.check("word file restored (Self-Learning Dictionary)", False, repr(exc))
    passed = sum(1 for _, s, _ in u.results if s == "PASS")
    failed = [r for r in u.results if r[1] in ("FAIL", "ABORT")]
    skipped = sum(1 for _, s, _ in u.results if s == "SKIP")
    unsure = [r for r in u.results if r[1] == "INCONCLUSIVE"]
    print(f"\n{passed} passed, {len(failed)} failed, {skipped} skipped, {len(unsure)} inconclusive")
    return exit_status(u.results)


def exit_status(results):
    """1 when anything failed (a proven failure outranks an inconclusive one), 3 when a required
    proof was INCONCLUSIVE, else 0. An inconclusive run is never a pass."""
    if any(status in ("FAIL", "ABORT") for _, status, _ in results):
        return 1
    if any(status == "INCONCLUSIVE" for _, status, _ in results):
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
