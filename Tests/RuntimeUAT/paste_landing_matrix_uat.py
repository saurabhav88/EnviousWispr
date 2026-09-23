#!/usr/bin/env python3
"""The paste landing check across real destination apps (#3106, the evidence for step 2).

    python3 Tests/RuntimeUAT/paste_landing_matrix_uat.py [--apps slack,notes,...] [--takes 3]

For each app: open a fresh, focused text field (the staging `learn_from_edits_apps_uat.py`
already uses for these apps), take one silent dictation through BlackHole, then pair what
actually happened with the check's verdict:

- landed:  the dictated words are in the destination's focused field (5 or more of the
           sentence's 7 words, read through accessibility). A field that cannot be read makes the
           row an instrument gap, never evidence: what the app produced is not what it received;
- tier:    the `Paste cascade:` line for that app;
- verdict: the one `PASTE_LANDING` line, present only on the three key-paste tiers.

The row that matters for step 2 is a FALSE UNCHANGED: the words landed while the check said
`unchanged`. Step 2 may only act on verdict shapes this matrix never catches false.

Safety is the apps driver's: no Enter or Return is ever pressed; each field is cleared afterwards
and Mail's draft discarded; chat apps get text in their compose box only. Cleanup clears ONLY a
field that is empty or holds this run's sentence, in the app it staged; anything else is refused
and reported, never cleared. Takes add rows to the
real History. The clipboard, audio devices and alert device are restored; the takes themselves are
not metered (their speech plays into BlackHole), everything else runs under the beep meter.
Exit 0 only when every requested row was scored and no check failed; 1 on a false unchanged, an
instrument gap, text left behind or a failed restore; 2 when fewer rows than requested exist.
"""
import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import last_dictation_uat as u  # noqa: E402
import learn_from_edits_apps_uat as apps  # noqa: E402
import paste_landing_uat as p  # noqa: E402
import wispr_eyes as w  # noqa: E402
from escape_recovery_uat import screen_is_locked  # noqa: E402

# Ghostty is not a default: a terminal exposes no readable field, so its row could only ever be an
# instrument gap; terminals stay on the founder's hand-run sheet.
# Mail is not a default either: its drafts share one subject across runs, so cleanup cannot tell
# this run's compose window from an older one. It stays on the hand-run sheet until it can.
# Each refusal measured on 2026-09-23 by staging the app and reading its focused element.
NOT_SAFE_HERE = {"ghostty": "a terminal exposes no readable field",
                 "mail": "its draft title is shared across runs, so cleanup cannot own it",
                 "word": "focus lands on an AXSplitGroup, not the document's text",
                 "excel": "a grid cell exposes no readable value",
                 "vscode": "focus lands on an AXButton, not the editor",
                 "whatsapp": "the composer's value is unreadable (None), so landing cannot be read",
                 "discord": "staging needs a conversation the founder opened",
                 "notes": "an empty new note reads None, and staging cannot prove the focused note "
                          "is the new one (last_dictation_uat.py covers Notes by note id)"}
DEFAULT_APPS = "textedit,safari,gmail,slack,obsidian"
KEY_TIERS = ("cgevent", "applescript", "menu_paste")
ROUTE = {"route": None}  # the run's silent audio route, applied once before any app is staged


def clear_and_verify_modifiers():
    """Post the clearing event once, then poll both state sources until they read clean."""
    w.clear_modifier_flags()

    def clean():
        flags = w.modifier_flags()
        return flags is not None and not any(flags.values())

    return u.wait_for("modifier flags cleared", clean, deadline=2.0)


def focused_element(pid):
    from ui_helpers import get_attr, get_ax_app
    return get_attr(get_ax_app(pid), "AXFocusedUIElement")


def element_value(element):
    from ui_helpers import get_attr
    value = get_attr(element, "AXValue") if element is not None else None
    return None if value is None else str(value)


def same_element(a, b):
    from CoreFoundation import CFEqual
    return a is not None and b is not None and CFEqual(a, b)


def safe_cleanup(app, pid, doc, staged, may_clear):
    """Clear this run's text from the field this run STAGED, and only from it.

    The apps driver's cleanup selects all and deletes in whatever field has focus. So, except for
    TextEdit (a document this run made) and Ghostty (Ctrl+U on the line this run typed into), it
    runs only when `app` is in front, its focused element IS `staged` (compared with CFEqual; if
    focus moved, the staged field is asked to take it back first), and that field is empty or
    holds our sentence. A partial Mail stage (no field yet) discards only drafts carrying this
    run's own title. Anything else is refused and reported, never cleared."""
    bundle = apps.APPS[app][0]
    if pid is None:
        return False, "no process to clean"
    if not may_clear:
        # The staged field held someone's text before the take, so no take ran: nothing of ours
        # is in it, and select-all would delete theirs. Only a titled Mail draft is ours to close.
        if app == "mail":
            from ui_helpers import get_ax_app
            return (apps.discard_mail_drafts(get_ax_app(pid)),
                    "the field was not empty: discarded only this run's titled Mail draft")
        return True, "the field was not empty before the take: left untouched, nothing of ours in it"
    if app == "mail" and staged is None:
        from ui_helpers import get_ax_app
        return (apps.discard_mail_drafts(get_ax_app(pid)),
                "a partial Mail stage: discarded only this run's titled drafts")
    if app not in ("textedit", "ghostty"):
        if staged is None:
            return False, f"{app}: no staged field known; nothing cleared"
        apps.activate_app(pid)
        if not apps.wait_frontmost(bundle):
            return False, f"{app} not frontmost; nothing cleared, the test text may remain"
        if not same_element(focused_element(pid), staged):
            from ui_helpers import set_attr
            set_attr(staged, "AXFocused", True)
            time.sleep(0.3)  # settle: the host moves focus; no ack
            if not same_element(focused_element(pid), staged):
                return False, f"{app}: focus is not on the staged field; refused to clear another one"
        before = element_value(staged)
        if before is None:
            return False, f"{app}: the staged field is unreadable; refused to clear it"
        if before and u.sentence_overlap(before) < 5:
            return False, f"the staged field in {app} holds other text; refused to clear it"
    try:
        apps.cleanup(app, pid, doc)
    except apps.d.Aborted as e:
        return False, str(e)
    if app not in ("textedit", "ghostty"):
        after = element_value(staged)
        if app in ("slack", "discord", "whatsapp") and after is None:
            return False, f"{app}: the staged composer is unreadable after cleanup; cannot confirm it is clear"
        if after and u.sentence_overlap(after) >= 3:
            return False, f"the test text is still in {app}'s staged field after cleanup"
    return True, "cleared"


def one_take(app):
    """Stage `app`, take one dictation, and return its row, or raise Aborted for an instrument
    gap (such a row is never evidence). Cleanup is attempted however staging or the take ends."""
    bundle, name, _kind = apps.APPS[app]
    row = {"app": app}
    # Cleanup is authorised only once a take is properly set up (below): a failed stage never
    # reaches the keyboard cleanup, which acts on whatever has focus.
    pid, doc, staged, may_clear = None, None, None, False
    try:
        pid, doc = p.quiet(f"{app} staging", apps.stage, app)
        # The field this run owns: scored and cleaned by THIS identity, never "whatever is
        # focused later" (a moved focus could read or clear another field).
        staged = focused_element(pid)  # Safari's staging now puts focus in its page's text area
        if staged is None and app != "ghostty":
            raise u.Aborted(f"{app}: no focused field after staging")
        # A landing check resolves up to 1.5 s after its paste; the previous app's cleanup and this
        # staging already take longer, and this settle makes the gap explicit, so the byte offset
        # below cannot catch the previous take's late line.
        time.sleep(2.0)
        if app != "ghostty":
            initial = element_value(staged)
            if initial is None or initial.strip():
                # someone's draft, or unreadable: never select-all it (may_clear stays False)
                raise u.Aborted(f"{app}: the staged field is not empty (or unreadable); refusing the take")
            if not same_element(focused_element(pid), staged):
                raise u.Aborted(f"{app}: focus left the staged field before the take")
        may_clear = True  # staged, empty, still focused: from here on the field holds only our text
        base = u.log_size()
        lines, cascades = p.take(app, base, bundle=bundle, route=ROUTE["route"])
        if app != "ghostty" and not same_element(focused_element(pid), staged):
            # Detects an observed move; it cannot prove focus never left and came back mid-hold.
            raise u.Aborted(f"{app}: focus left the staged field during the take; text may be elsewhere")
        tiers = [t for t, target in cascades if target.strip().lower() == bundle.lower()]
        mine = [line for line in lines if line[3] == bundle and tiers and line[0] == tiers[0]]
        if len(tiers) != 1 or len(lines) != len(mine) or len(mine) != int(tiers[0] in KEY_TIERS):
            raise u.Aborted(f"{app}: incomplete paste evidence: tiers={tiers} "
                            f"cascades={cascades} lines={len(lines)} matching={len(mine)}")
        row["tier"] = tiers[0]
        value = element_value(staged)
        if value is None:
            raise u.Aborted(f"{app}: the staged field could not be read; landing unverified")
        # Landed is read from the STAGED destination field only; what the app produced is not what
        # it received, and another field is not the one the paste was aimed at.
        row["landed"] = "Y" if u.sentence_overlap(value) >= 5 else "N"
        row["read_by"] = "staged field"
        if mine:
            tier, observed, reason, _app, hef, manual, window, before_ms, resolve_ms = mine[0]
            row.update(observed=observed, reason=reason, host_exposed_focus=hef, manual_ax=manual,
                       target_window=window, before_ms=before_ms, lines=1)
        else:
            row.update(observed="-", reason="-", lines=0)  # ax_direct etc.: no verdict, no evidence
        row["false_unchanged"] = row["landed"] == "Y" and row["observed"] == "unchanged"
        u.check(f"{app}: no false unchanged", not row["false_unchanged"],
                f"landed={row['landed']} verdict={row['observed']}/{row['reason']}")
        return row
    finally:
        if p.TAKE_STUCK["stuck"]:
            # A recording may still be live: no keystroke may be posted into any app now.
            u.check(f"{app}: this run's text removed", False,
                    "skipped: a take would not stop, so no keyboard cleanup runs")
        else:
            if pid is None:
                pid = apps.pid_for(bundle, name)  # a partial stage (a Mail draft) is still cleaned
            ok, detail = p.quiet(f"{app} cleanup", safe_cleanup, app, pid, doc, staged, may_clear)
            u.check(f"{app}: this run's text removed", ok, detail)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apps", default=DEFAULT_APPS)
    parser.add_argument("--takes", type=int, default=1)
    args = parser.parse_args()
    requested = [a.strip() for a in args.apps.split(",") if a.strip()]
    if not requested or args.takes < 1:
        parser.error("name at least one app and at least one take")
    unsafe = {a: NOT_SAFE_HERE[a] for a in requested if a in NOT_SAFE_HERE}
    if unsafe:
        parser.error(f"not driven here: {unsafe}")
    unknown = [a for a in requested if a not in apps.APPS]
    if unknown:
        parser.error(f"unknown apps {unknown}; choose from {', '.join(apps.APPS)}")
    if screen_is_locked():
        print("ABORT: the screen is locked")
        return 2
    # Signals first, before ANY device changes: each becomes KeyboardInterrupt, so the `finally`
    # below always runs and decides what is safe to restore. Never the route's own handlers,
    # which restore the microphone unconditionally.
    import signal

    def interrupt(_signum, _frame):
        raise KeyboardInterrupt

    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, interrupt)
    from silent_audio import AlertSink, AudioRoute
    w._INPUT_WARN = False
    w.connect()
    try:
        snapshot = u.pasteboard_snapshot()
    except u.Aborted as e:
        print(f"ABORT: {e}")
        return 2
    rows, unstaged, sink, route = [], [], AlertSink(), None
    try:
        if not sink.apply():
            raise u.Aborted("the alert and output devices did not switch to BlackHole")
        # Once, before any app is staged: switching the microphone opens and closes our Settings,
        # which must not happen between an app's staging and its take.
        route = AudioRoute()
        route.apply()
        ROUTE["route"] = route
        for app in requested:
            for n in range(args.takes):
                print(f"\n== {app}, take {n + 1}")
                try:
                    rows.append(one_take(app))
                except p.LiveTakeNotStopped:
                    raise  # never stage another app over a take that will not stop
                except (u.Aborted, apps.d.Aborted) as e:
                    unstaged.append(app)
                    u.record(f"{app}: a scored row", "ABORT", str(e))  # an instrument gap, never evidence
                    break
    except (u.Aborted, KeyboardInterrupt) as e:
        u.record("run", "ABORT", repr(e))
    finally:
        # Each step is attempted on its own; none can skip the next.
        for label, step in [("clipboard restored byte for byte", lambda: u.pasteboard_restore(snapshot)),
                            ("modifier flags cleared", clear_and_verify_modifiers)]:
            try:
                u.check(label, bool(step()))
            except BaseException as exc:
                u.check(label, False, repr(exc))
        try:
            if route is not None:
                # The flag, not the exception: it survives a later error replacing the exception.
                if u.check("every matrix take stopped", not p.TAKE_STUCK["stuck"]):
                    u.check("microphone and app device restored", route.restore())
                else:
                    print("    the virtual microphone is LEFT in place: quit the dev app, then run "
                          "`python3 Tests/RuntimeUAT/silent_audio.py restore`")
        except BaseException as exc:
            u.check("microphone and app device restored", False, repr(exc))
        try:
            u.check("devices restored", sink.restore())  # outermost: whatever failed before
        except BaseException as exc:
            u.check("devices restored", False, repr(exc))
    print("\n| app | tier | landed | read by | observed | reason | target_window | host_exposed_focus | manual_ax | before_ms | false unchanged |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        print(f"| {r['app']} | {r['tier']} | {r['landed']} | {r['read_by']} | {r['observed']} | {r['reason']} | "
              f"{r.get('target_window', '-')} | {r.get('host_exposed_focus', '-')} | {r.get('manual_ax', '-')} | "
              f"{r.get('before_ms', '-')} | {'YES' if r['false_unchanged'] else 'no'} |")
    if not any(r["tier"] in KEY_TIERS for r in rows):
        u.record("landing verdict coverage", "ABORT",
                 "no key-paste tier produced a PASTE_LANDING verdict")
    failed = [r for r in u.results if r[1] in ("FAIL", "ABORT")]
    print(f"\n{len(rows)} rows; unstaged: {unstaged or 'none'}; "
          f"{sum(1 for r in u.results if r[1] == 'PASS')} checks passed, {len(failed)} failed")
    if any(r["false_unchanged"] for r in rows) or failed:
        return 1
    # A pass needs every requested row: an app that could not be staged or read is not a pass.
    return 0 if len(rows) == len(requested) * args.takes else 2


if __name__ == "__main__":
    sys.exit(main())
