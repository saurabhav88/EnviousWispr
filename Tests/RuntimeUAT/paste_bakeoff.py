#!/usr/bin/env python3
"""paste_bakeoff.py — measure which delivery policy is most reliable (#2652).

A reporter's dictation arrived TWICE in Safari page textareas and a WebKit-backed
compose window, proven by exact character counts, and the defect does not reproduce on
this hardware. The founder refused to accept a fix on the strength of a mechanism story
and asked for a measurement instead. This is it.

## What makes a row believable

Three sources, and a row is scored only when all three agree about the same trial:

1. **The bootstrap control record** — which policy the process actually resolved.
   `PASTE_BAKEOFF_CONTROL run_id=… variant=…`, emitted once per launch.
2. **The executor evidence line** — which routes ran and the exact bytes each was
   handed. `PASTE_BAKEOFF_TRIAL … ledger=…`.
3. **The destination oracle** — the target application's own text, read by
   `paste_oracles.ax_oracle` from a different process.

EnviousWispr's own logs never determine whether delivery succeeded. That is the whole
point: the defect IS the app being wrong about its own write.

## Why the app never sees a trial id

An earlier design had the app stamp one. It has no way to obtain it — the variant and
run id arrive in the environment at launch, and a trial is a harness concept that begins
after the process is already running. So the harness brackets each trial with its own
log boundary and requires EXACTLY ONE new evidence line inside it. Zero or two is
`invalid`, which is also the honest answer when a stray dictation lands mid-trial.

## Invalid is not failure

A trial whose precondition sentinel could not be found, whose control line is missing,
or whose oracle could not read the destination is `invalid` with a reason. Scoring it as
a drop would make every variant look like it loses text whenever the harness blinks, and
that error runs in the direction that would pick the wrong winner.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import random
import re
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(pathlib.Path(__file__).parent / "paste_oracles"))

import ax_oracle  # noqa: E402
import wispr_eyes  # noqa: E402

APP_LOG = pathlib.Path.home() / "Library/Logs/EnviousWispr/app.log"

# Derived from THIS FILE's checkout, never a literal path. `build-dev-app.sh` builds into
# `$PROJECT_ROOT/build`, so a hardcoded path would silently measure whichever checkout
# happened to build last — and this repo keeps the root on `main` while feature work
# lives in worktrees, so the wrong answer is the likely one.
CHECKOUT = pathlib.Path(__file__).resolve().parents[2]
DEV_APP = CHECKOUT / "build/EnviousWispr Local.app"

CONTROL_RE = re.compile(r"PASTE_BAKEOFF_CONTROL run_id=(\S+) variant=(\S+)")
REJECT_RE = re.compile(r"PASTE_BAKEOFF_CONTROL rejected: (.+)")
TRIAL_RE = re.compile(
    r"PASTE_BAKEOFF_TRIAL run_id=(?P<run>\S+) variant=(?P<variant>\S+) "
    r"tier=(?P<tier>\S+) app=(?P<app>\S+) attempts=(?P<attempts>\S*) "
    r"ledger=(?P<ledger>\S*) duration=(?P<duration>\d+)ms"
)

VARIANTS = ["V0", "V1", "V2", "V4", "V5"]


# --------------------------------------------------------------------------- log


def log_size() -> int:
    """Byte offset to read from. The boundary that brackets a trial."""
    try:
        return APP_LOG.stat().st_size
    except OSError:
        return 0


def log_since(offset: int) -> str:
    try:
        with APP_LOG.open("rb") as fh:
            fh.seek(offset)
            return fh.read().decode("utf-8", "replace")
    except OSError:
        return ""


# ------------------------------------------------------------------------ app


def running_dev_pids() -> list[int]:
    """PIDs of dev instances, identified by EXECUTABLE PATH.

    Never by name or bundle id: a bare name also matches the production app, and a
    Release-configuration test host carries the production identifier while living under
    a different path.
    """
    out = subprocess.run(
        ["pgrep", "-f", "EnviousWispr Local.app/Contents/MacOS/EnviousWispr"],
        capture_output=True, text=True,
    )
    return [int(p) for p in out.stdout.split() if p.strip().isdigit()]


def stop_dev_app() -> None:
    for pid in running_dev_pids():
        subprocess.run(["kill", "-TERM", str(pid)], capture_output=True)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if not running_dev_pids():
            return
        time.sleep(0.3)  # settle: polling the process table, which exposes no exit signal
    for pid in running_dev_pids():
        subprocess.run(["kill", "-KILL", str(pid)], capture_output=True)


def launch_dev_app(variant: str, run_id: str) -> tuple[bool, str]:
    """Launch the sole dev instance under one variant, and PROVE it took.

    Returns (ok, reason). The proof is the control line: without it the process may have
    fallen back to the baseline while the harness believed otherwise, which would fill a
    scorecard with confident rows about a policy that never ran.
    """
    if not DEV_APP.exists():
        return False, f"dev_app_missing:{DEV_APP}"
    stop_dev_app()
    boundary = log_size()
    # `open` hands off to LaunchServices, which does NOT inherit this process's
    # environment — passing `env=` to subprocess.run sets it for `open` itself and the
    # app would never see it. Measured before the first run rather than discovered as a
    # run of "control_line_never_appeared" that looks like a code fault.
    command = ["open", "-n"]
    if variant != "V0":
        command += ["--env", f"EW_PASTE_BAKEOFF_VARIANT={variant}",
                    "--env", f"EW_PASTE_BAKEOFF_RUN_ID={run_id}"]
    command += ["-a", str(DEV_APP)]
    subprocess.run(command, capture_output=True)

    if variant == "V0":
        # The baseline emits no control line by design, so its proof is that the process
        # came up at all. A V0 row cannot be confused with a forced one: a forced variant
        # without its control line is refused below.
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if running_dev_pids():
                return True, "baseline_launched"
            time.sleep(0.5)  # settle: waiting on the process table
        return False, "baseline_never_started"

    def look_for_control(seconds: float) -> tuple[bool, str] | None:
        """None means "not yet"; a tuple is a settled answer."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            text = log_since(boundary)
            rejection = REJECT_RE.search(text)
            if rejection:
                return False, f"control_rejected:{rejection.group(1)}"
            match = CONTROL_RE.search(text)
            if match:
                if match.group(1) == run_id and match.group(2) == variant:
                    return True, "control_confirmed"
                return False, f"control_mismatch:{match.group(1)}/{match.group(2)}"
            time.sleep(0.5)  # settle: polling the log for the control line, the real signal
        return None

    settled = look_for_control(45)
    if settled is not None:
        return settled

    # The policy resolves when the dictation driver is CONSTRUCTED, and the app builds
    # that lazily. Measured 2026-09-04: the environment variables were confirmed present
    # in the process with `ps -E` while the control line had still not appeared — a
    # perfectly healthy launch that a naive gate reads as a broken control plane.
    #
    # So force construction with one throwaway dictation and require the line after it.
    # The gate is not weakened: a forced variant with no control line is still refused,
    # and this trial's own result is discarded rather than scored.
    try:
        wispr_eyes.test_recording(sentence="warm up the driver", expect=None)
    except Exception as exc:  # noqa: BLE001
        return False, f"warmup_raised:{type(exc).__name__}"
    settled = look_for_control(20)
    if settled is not None:
        return settled
    return False, "control_line_never_appeared_even_after_warmup"


# --------------------------------------------------------------------- targets


class Target:
    """One destination cell: how to put it into a known state and how to read it back."""

    def __init__(self, key: str, bundle_id: str, setup, teardown=None, reader=None):
        self.key = key
        self.bundle_id = bundle_id
        self.setup = setup
        self.teardown = teardown
        # A cell whose destination text Accessibility cannot read supplies its own reader.
        # `None` means the default focused-element read, which is right for every web and
        # chat surface. See `_script_reader` for why the document apps need their own.
        self.reader = reader


def _write_fixture(token: str, pre_image: str, focus_id: str) -> pathlib.Path:
    path = _fixture_path(token)
    body = path.read_text()
    other = "OTHERFIELD"
    if focus_id == "ta":
        body = body.replace("__PRE__", pre_image).replace("__PRE2__", other)
    else:
        body = body.replace("__PRE__", other).replace("__PRE2__", pre_image)
    path.write_text(body.replace("__FOCUS__", focus_id))
    return path


def _fixture_path(token: str) -> pathlib.Path:
    # A NEW path per trial. Rewriting one file in place is how the first smoke run failed:
    # both TextEdit and Safari serve the window/document they already have, so the file on
    # disk changed and the thing being measured did not. The precondition control caught
    # it, which is the whole reason that control is mandatory rather than nice to have.
    # Sweep this harness's own leftovers. A fresh file per trial is deliberate; keeping
    # every one of them is not. One run left 77 in Caches.
    now = time.time()
    for stale in pathlib.Path.home().glob("Library/Caches/EnviousWispr-bakeoff-*"):
        if now - stale.stat().st_mtime > 600:
            stale.unlink(missing_ok=True)

    path = pathlib.Path.home() / f"Library/Caches/EnviousWispr-bakeoff-{token}.html"
    path.write_text(
        "<!doctype html><meta charset='utf-8'><title>EW bake-off</title>"
        "<style>body{font:16px -apple-system;padding:24px}"
        "textarea,div[contenteditable]{width:96%;min-height:110px;font-size:16px;"
        "padding:8px;border:2px solid #6b46ff;border-radius:8px;display:block;"
        "margin-bottom:20px}</style>"
        "<h1>EW bake-off</h1><textarea id='ta'>__PRE__</textarea>"
        "<div id='ce' contenteditable='true'>__PRE2__</div>"
        # The caret goes to the END, which is where a dictation appends. Without it the
        # caret sits at offset 0 in a contenteditable and the insertion lands BEFORE the
        # pre-image — a different case from the one this cell claims to test, and one
        # that would still score `once` while measuring something else.
        "<script>const el=document.getElementById('__FOCUS__');el.focus();"
        "const r=document.createRange();r.selectNodeContents(el);r.collapse(false);"
        "const s=getSelection();s.removeAllRanges();s.addRange(r);"
        "if(el.setSelectionRange)el.setSelectionRange(el.value.length,el.value.length);"
        "</script>"
    )
    return path


def setup_textedit(pre_image: str, file_token: str) -> tuple[bool, str]:
    # Close whatever this harness opened last, so a stale window cannot be measured, then
    # open a fresh document. `close saving no` is safe: every one of these files is ours.
    subprocess.run(
        ["osascript", "-e",
         'tell application "TextEdit" to close (every document whose name contains '
         '"EnviousWispr-bakeoff") saving no'],
        capture_output=True)
    scratch = (pathlib.Path.home()
               / f"Library/Caches/EnviousWispr-bakeoff-{file_token}.txt")
    scratch.write_text(pre_image)
    subprocess.run(["open", "-a", "TextEdit", str(scratch)], capture_output=True)
    ax_oracle.activate("com.apple.TextEdit")
    # Put the caret at the end of the document, which is where a dictation lands.
    subprocess.run(
        ["osascript", "-e",
         'tell application "System Events" to keystroke "a" using command down'],
        capture_output=True)
    subprocess.run(
        ["osascript", "-e", 'tell application "System Events" to key code 124'],
        capture_output=True)
    return ax_oracle.assert_precondition("com.apple.TextEdit", pre_image)


# Tab cleanup DELETED, not fixed.
#
# It existed because the old oracle walked the whole application looking for the right
# field, and forty accumulated tabs blew past its node budget. The oracle now asks the
# system which element has focus, so stray tabs cost nothing at all. The cleanup also
# needed an Automation grant per browser, and an ungranted one raises a modal that blocks
# focus for the whole machine — paying a permission prompt to solve a problem that no
# longer exists.

def _close_bakeoff_tabs(app: str) -> int:
    """Close every bake-off tab this harness left in `app`, one at a time.

    A fresh file per trial is what keeps a stale document from being measured, and the
    cost of that is a new tab per trial: one full run left 30 tabs in Safari and 16 in
    Brave, on top of the operator's own. Closing before opening keeps the count at one.

    One at a time on purpose. Collecting the doomed tabs and closing them in a second
    loop fails with `Invalid index (-1719)` partway through, because closing a tab
    renumbers the ones behind it and the collected references go stale mid-loop. That
    error closed exactly half of them and reported failure, which reads as "cleanup is
    broken" rather than "cleanup half worked".
    """
    script = pathlib.Path.home() / "Library/Caches/ew-bakeoff-close.scpt"
    script.write_text(
        f'tell application "{app}"\n'
        "  repeat with w in windows\n"
        "    repeat with t in (tabs of w)\n"
        '      if (URL of t) contains "EnviousWispr-bakeoff" then\n'
        "        close t\n"
        "        return 1\n"
        "      end if\n"
        "    end repeat\n"
        "  end repeat\n"
        "end tell\n"
        "return 0\n"
    )
    closed = 0
    for _ in range(60):
        out = subprocess.run(["osascript", str(script)], capture_output=True, text=True)
        if out.stdout.strip() != "1":
            break
        closed += 1
    return closed


def _setup_browser(app: str, bundle_id: str, focus_id: str):
    def setup(pre_image: str, file_token: str) -> tuple[bool, str]:
        _close_bakeoff_tabs(app)
        path = _write_fixture(file_token, pre_image, focus_id)
        subprocess.run(["open", "-a", app, str(path)], capture_output=True)
        ax_oracle.activate(bundle_id, handoff=2.0)
        return ax_oracle.assert_precondition(bundle_id, pre_image)
    return setup


def _setup_composer(app_name: str, bundle_id: str):
    """A chat app's message composer.

    **Nothing is ever sent.** The pre-image is typed and Return is never pressed, so the
    worst case is an unsent draft the operator can clear. No teardown clears it
    deliberately: a stray select-all-and-delete aimed at a field that turned out not to be
    the composer is a far worse outcome than a leftover draft, and the composer is only
    ever FOCUSED here, never identified with certainty.

    The composer is whatever holds focus when the app comes forward, which is true of
    Slack, Discord and WhatsApp on open. When it is not, the pre-image lands somewhere the
    oracle cannot find and the precondition marks the trial `invalid` — the honest answer,
    and never a verdict about a variant.
    """

    def setup(pre_image: str, file_token: str) -> tuple[bool, str]:
        if ax_oracle.pid_for_bundle(bundle_id) is None:
            return False, f"{app_name}_not_running"
        if not ax_oracle.activate(bundle_id, handoff=2.0):
            return False, f"{app_name}_would_not_come_forward"

        # CLEAR the composer first, and this is correctness rather than tidiness.
        #
        # A browser cell gets a brand new tab each trial. A chat composer does not: it
        # keeps whatever the last trial left. Measured 2026-09-04 — WhatsApp's composer
        # held `PRE-32EE4C1F The quick brown fox jumps. PRE-ACA6175F The quick brown fox
        # jumps. PRE-3ED5B80E The quick brown fox jumps.` after three trials, and the
        # scorer counted the PREVIOUS trial's sentence and reported a DUPLICATE. Those
        # were the first duplicates this bench had ever produced, in a bench built to
        # count duplicates, and every one of them was manufactured here.
        #
        # Select-all-and-delete is only ever aimed at an element already CONFIRMED to be
        # an editable text field, so it cannot reach a message list or a document.
        focused = ax_oracle.read_focused(bundle_id)
        if not focused.ok or focused.fields[0].role not in EDITABLE_ROLES:
            return False, f"{app_name}_composer_not_focused"
        if focused.fields[0].value.strip():
            subprocess.run(
                ["osascript", "-e",
                 'tell application "System Events" to keystroke "a" using command down'],
                capture_output=True)
            subprocess.run(
                ["osascript", "-e",
                 'tell application "System Events" to key code 51'],
                capture_output=True)

        subprocess.run(
            ["osascript", "-e",
             f'tell application "System Events" to keystroke "{pre_image} "'],
            capture_output=True, timeout=20)
        ok, why = ax_oracle.assert_precondition(bundle_id, pre_image)
        if not ok:
            return ok, why
        return _still_frontmost(app_name, bundle_id)

    return setup


def _still_frontmost(app_name: str, bundle_id: str) -> tuple[bool, str]:
    """The last thing every setup does: prove the target STILL owns focus.

    Delivery goes wherever the caret is when the pipeline finishes, so a target that lost
    focus during setup sends the dictation into a bystander. Measured 2026-09-04 on the
    first Excel trial: setup succeeded, the pre-image was in the sheet, and the app
    reported delivering to `com.mitchellh.ghostty` — the operator's TERMINAL. The trial
    scored `unseen`, which is honest and says nothing about the variant, and the words
    went somewhere real.

    Raising once more is not enough on its own; the point is that a setup which cannot
    hold focus returns INVALID rather than handing the trial a destination it does not own.
    """
    pid = ax_oracle.pid_for_bundle(bundle_id)
    if pid is None:
        return False, f"{app_name}_vanished_during_setup"
    if ax_oracle.is_frontmost(pid):
        return True, "ok"
    if ax_oracle.activate(bundle_id, handoff=1.5) and ax_oracle.is_frontmost(pid):
        return True, "ok"
    return False, f"{app_name}_lost_focus_during_setup"


def _osa(script: str, timeout: float = 30.0) -> tuple[bool, str]:
    """Run one AppleScript. Returns (ok, output-or-error)."""
    out = subprocess.run(["osascript", "-e", script],
                         capture_output=True, text=True, timeout=timeout)
    if out.returncode != 0:
        return False, out.stderr.strip()[:120]
    return True, out.stdout.rstrip("\n")


def _script_reader(script: str, label: str, commit: str | None = None):
    """Read a destination's text through the APPLICATION'S OWN scripting, not through AX.

    **Pages, Numbers and Excel do not expose their document text to Accessibility in any
    form this oracle can find, and the failure is silent.** Measured 2026-09-04: a marker
    typed into a blank Pages document was plainly visible on screen, `read_focused`
    returned `focused_element_has_no_text_value:AXScrollArea`, and a full tree walk visited
    81 nodes and found it in none of them. An unreadable destination scores every trial as
    a DROP, which is the verdict that disqualifies a variant — so a blind oracle here would
    have vetoed whichever variant happened to be measured in these cells.

    The app's own dictionary answers it exactly. This stays an INDEPENDENT oracle in the
    sense that matters: the reading comes from the destination application, never from
    EnviousWispr's account of what it delivered.

    Gates on STABILITY rather than a fixed sleep, for the same reason `settled_focused`
    does: "unchanged across two reads" has no parameter to get wrong.
    """

    def read() -> ax_oracle.Scan:
        if commit is not None:
            subprocess.run(["osascript", "-e", commit], capture_output=True, timeout=15)
            time.sleep(0.5)
        previous = None
        stable = 0
        deadline = time.monotonic() + 8.0
        text = ""
        while time.monotonic() < deadline:
            time.sleep(0.4)
            ok, value = _osa(script)
            if not ok:
                return ax_oracle.Scan(ok=False, why=f"{label}_reader_failed:{value}")
            text = value
            if value == previous:
                stable += 1
                if stable >= 2:
                    break
            else:
                stable = 0
                previous = value
        return ax_oracle.Scan(
            ok=True,
            nodes_visited=1,
            fields=[ax_oracle.Field(role="AXTextArea", depth=0, chars=len(text),
                                    focused=True, value=text)],
        )

    return read


def _setup_document(app_name: str, bundle_id: str, clear: str, reader_script: str):
    """A word processor: empty the document, put the caret in the body, type the pre-image.

    The caret step is not optional and is not tidiness. A freshly raised Word or Pages
    window reports its focused element as an `AXScrollArea` with no text in it, and typing
    is what moves focus into the body. Cmd+End moves the caret to the end of the document
    and changes nothing, so it is safe to run before every trial.
    """

    def setup(pre_image: str, file_token: str) -> tuple[bool, str]:
        if ax_oracle.pid_for_bundle(bundle_id) is None:
            return False, f"{app_name}_not_running"
        if not ax_oracle.activate(bundle_id, handoff=2.0):
            return False, f"{app_name}_would_not_come_forward"
        ok, err = _osa(clear)
        if not ok:
            return False, f"{app_name}_clear_failed:{err}"
        time.sleep(0.5)
        subprocess.run(["osascript", "-e",
                        'tell application "System Events" to key code 119 using command down'],
                       capture_output=True, timeout=15)
        time.sleep(0.4)
        subprocess.run(["osascript", "-e",
                        f'tell application "System Events" to keystroke "{pre_image} "'],
                       capture_output=True, timeout=25)
        time.sleep(0.6)
        ok, value = _osa(reader_script)
        if not ok:
            return False, f"{app_name}_precondition_read_failed:{value}"
        if pre_image not in value:
            return False, f"{app_name}_precondition_sentinel_not_in_document"
        return _still_frontmost(app_name, bundle_id)

    return setup


def _setup_cell(app_name: str, bundle_id: str, clear: str, reader_script: str,
                select_a1: str, edit_key: str):
    """A spreadsheet cell in EDIT mode, which is where a dictation actually lands.

    Two things had to be got right, both found by hand before any trial ran:

    - **Escape first.** Numbers was sitting in an open, empty cell editor left by an
      earlier attempt, and every keystroke sent to it vanished. The typed marker appeared
      nowhere in the sheet and nothing reported an error.
    - **Edit mode, not selection.** A selected-but-not-editing cell REPLACES its contents
      on the next input, which would delete the pre-image the scorer needs to find the
      field by. `edit_key` opens the editor with the caret after the existing text, which
      is the state a person dictating into a cell is in.
    """

    def setup(pre_image: str, file_token: str) -> tuple[bool, str]:
        if ax_oracle.pid_for_bundle(bundle_id) is None:
            return False, f"{app_name}_not_running"
        if not ax_oracle.activate(bundle_id, handoff=2.0):
            return False, f"{app_name}_would_not_come_forward"
        subprocess.run(["osascript", "-e",
                        'tell application "System Events" to key code 53'],
                       capture_output=True, timeout=15)
        time.sleep(0.4)
        ok, err = _osa(clear)
        if not ok:
            return False, f"{app_name}_clear_failed:{err}"
        ok, err = _osa(select_a1)
        if not ok:
            return False, f"{app_name}_select_failed:{err}"
        time.sleep(0.5)
        subprocess.run(["osascript", "-e",
                        f'tell application "System Events" to keystroke "{pre_image} "'],
                       capture_output=True, timeout=25)
        subprocess.run(["osascript", "-e",
                        'tell application "System Events" to key code 36'],
                       capture_output=True, timeout=15)
        time.sleep(0.6)
        ok, err = _osa(select_a1)
        if not ok:
            return False, f"{app_name}_reselect_failed:{err}"
        time.sleep(0.4)
        subprocess.run(["osascript", "-e", edit_key], capture_output=True, timeout=15)
        time.sleep(0.5)
        ok, value = _osa(reader_script)
        if not ok:
            return False, f"{app_name}_precondition_read_failed:{value}"
        if pre_image not in value:
            return False, f"{app_name}_precondition_sentinel_not_in_sheet"
        return _still_frontmost(app_name, bundle_id)

    return setup


WORD_READ = 'tell application "Microsoft Word" to get content of text object of active document'
PAGES_READ = 'tell application "Pages" to get body text of front document'
EXCEL_READ = ('tell application "Microsoft Excel" to get string value of used range '
              'of active sheet')


TARGETS = {
    # The reported defect surface.
    "safari_textarea": Target(
        "safari_textarea", "com.apple.Safari",
        _setup_browser("Safari", "com.apple.Safari", "ta")),
    # A DIFFERENT WebKit editor. A rich contenteditable and a plain textarea are not one
    # cell wearing two names: they take different paths inside WebKit, and collapsing them
    # would let a result about one be reported as a result about web content generally.
    "safari_contenteditable": Target(
        "safari_contenteditable", "com.apple.Safari",
        _setup_browser("Safari", "com.apple.Safari", "ce")),
    # Chromium, whose web area is the population where `no_mutation` is genuinely true —
    # the write really does nothing there. This is the cell that can tell a variant which
    # refuses the fallback (V2) apart from one that merely reroutes it (V1).
    "chrome_textarea": Target(
        "chrome_textarea", "com.google.Chrome",
        _setup_browser("Google Chrome", "com.google.Chrome", "ta")),
    # A THIRD Chromium build, because "Chromium" is not one behaviour: Brave ships its own
    # patches and its own accessibility defaults, and the teardown found it in the same
    # both-outcomes population as Safari.
    "brave_textarea": Target(
        "brave_textarea", "com.brave.Browser",
        _setup_browser("Brave Browser", "com.brave.Browser", "ta")),
    # Chat composers. Founder's list, and the reason it matters: these are Electron and
    # web-view surfaces where the direct write may genuinely do nothing, so they are the
    # cells that separate a variant which reroutes the fallback from one that refuses it.
    "slack": Target("slack", "com.tinyspeck.slackmacgap",
                    _setup_composer("Slack", "com.tinyspeck.slackmacgap")),
    "discord": Target("discord", "com.hnc.Discord",
                      _setup_composer("Discord", "com.hnc.Discord")),
    "whatsapp": Target("whatsapp", "net.whatsapp.WhatsApp",
                       _setup_composer("WhatsApp", "net.whatsapp.WhatsApp")),
    # Pages and Numbers stand in for Word and Excel, and it is not a compromise.
    #
    # `PasteTier.menuPaste` exists for exactly this family — its own comment names
    # "Word/Excel/Numbers/OneNote" — so all four take the SAME route through our cascade:
    # a non-text container where Cmd+V cannot be aimed at a writable element, delivered by
    # driving the app's own Edit > Paste menu item. Word is unlicensed on this Mac
    # ("Subscription Required to Edit and Save"), and buying one to exercise a code path
    # two free preinstalled apps already exercise would be spending money for nothing.
    #
    # Stated so nobody over-reads it: this covers the ROUTE, not Microsoft's apps. A
    # Word-specific defect would not be caught here, and that is written into the plan's
    # uncovered list rather than glossed.
    # Word and Excel, the real ones. The plan previously used Pages and Numbers as
    # stand-ins because Word was unlicensed; the licence was bought on 2026-09-04, so the
    # bench measures Microsoft's apps directly and the stand-in argument is retired.
    #
    # **Word and Excel were expected to exercise `PasteTier.menuPaste` and they DO NOT.**
    # Measured 2026-09-04 across 23 deliveries: every one went out as `cgevent`, plain
    # Cmd+V, and `menu_paste` appears three times in the whole log — none of them in an
    # Office app. The expectation came from `PasteTier.menuPaste`'s own comment, which
    # names "Word/Excel/Numbers/OneNote"; that comment describes what the tier is FOR, not
    # where it is reached, and reading it as coverage was the error.
    #
    # So these cells are worth having for a different and smaller reason than the one they
    # were added for: they are real desktop applications, they are what a user writing a
    # document is actually in, and no browser or chat cell speaks for them. They do not
    # close the menu-paste gap, and that gap stays open and stated.
    "word": Target("word", "com.microsoft.Word",
                   _setup_document(
                       "Word", "com.microsoft.Word",
                       'tell application "Microsoft Word" to set content of text object '
                       'of active document to ""',
                       WORD_READ),
                   reader=_script_reader(WORD_READ, "word")),
    "excel": Target("excel", "com.microsoft.Excel",
                    _setup_cell(
                        "Excel", "com.microsoft.Excel",
                        'tell application "Microsoft Excel" to clear contents of used '
                        'range of active sheet',
                        EXCEL_READ,
                        'tell application "Microsoft Excel" to select range "A1" of '
                        'active sheet',
                        # F2 opens the cell editor with the caret after the existing text.
                        'tell application "System Events" to key code 120'),
                    # COMMIT THE CELL BEFORE READING IT. A spreadsheet's used range holds
                    # only committed values, so text sitting in an open cell editor is
                    # invisible to every reader — the delivery lands correctly and scores
                    # as nothing at all. Return closes the editor and writes the value.
                    reader=_script_reader(EXCEL_READ, "excel",
                                          commit='tell application "System Events" to '
                                                 'key code 36')),
    "pages": Target("pages", "com.apple.iWork.Pages",
                    _setup_document(
                        "Pages", "com.apple.iWork.Pages",
                        'tell application "Pages" to set body text of front document to ""',
                        PAGES_READ),
                    reader=_script_reader(PAGES_READ, "pages")),
    # A terminal. Its own context path in the cascade (`terminal_screen_refused`), and the
    # founder named terminals as coverage that must not regress.
    "ghostty": Target("ghostty", "com.mitchellh.ghostty",
                      _setup_composer("Ghostty", "com.mitchellh.ghostty")),
}


# --------------------------------------------------------------------- scoring


# Roles that can hold a dictation. A browser's address bar is an `AXTextField` too, so
# role alone does not identify the field under test — see `classify`.
EDITABLE_ROLES = {"AXTextArea", "AXTextField"}


def classify(pre_image: str, spoken_marker: str, fields) -> tuple[str, dict]:
    """Turn what the destination holds into a verdict.

    `spoken_marker` is a word from the dictated sentence, so counting its occurrences in
    the field that also holds the pre-image answers the only question that matters:
    once, twice, or not at all.

    **Picking the WRONG field is the failure mode this function had, and it reported a
    plausible verdict rather than an error.** Measured 2026-09-04 on the first real Safari
    trial: the fixture filename contained the pre-image token, so Safari's ADDRESS BAR
    also "carried" the pre-image, was longer than the textarea, and won a
    longest-match tie-break. The text had landed perfectly — `The quick brown fox jumps.
    PRE-CD7735EA`, one copy, right field — and the bench recorded a DROP.
    A drop is the verdict that disqualifies a variant, so this bug could have vetoed the
    winner.

    Two independent fixes, because either alone leaves the class open: the caller no
    longer puts the pre-image in any filename, and selection here prefers the FOCUSED
    editable field over any browser chrome rather than the longest string.
    """
    editable = [f for f in fields if f.role in EDITABLE_ROLES and pre_image in f.value]
    if not editable:
        # No editable field holds the pre-image. Either the pre-image is gone entirely, or
        # only non-editable mirrors carry it — neither is a scoreable state.
        return "invalid", {"why": "pre_image_in_no_editable_field"}
    focused = [f for f in editable if f.focused]
    # The focused editable field IS the field under test: the harness put the caret there
    # and the dictation was aimed at it. Falling back to the longest is a last resort and
    # is recorded, so a row that relied on the guess can be told from one that did not.
    target = focused[0] if focused else max(editable, key=lambda f: len(f.value))
    occurrences = target.value.lower().count(spoken_marker.lower())
    detail = {"chars": target.chars, "role": target.role, "occurrences": occurrences,
              "field_choice": "focused" if focused else "longest_fallback",
              "editable_candidates": len(editable)}
    if occurrences == 0:
        return "drop", detail
    if occurrences == 1:
        return "once", detail
    return "duplicate", detail


def run_trial(variant: str, run_id: str, target: Target, sentence: str, marker: str) -> dict:
    pre_image = f"PRE-{uuid.uuid4().hex[:8].upper()}"
    # A SEPARATE token for filenames. The pre-image must never appear in a path, or the
    # browser's address bar carries it and becomes a candidate for the field under test.
    file_token = uuid.uuid4().hex[:8]
    row = {"variant": variant, "run_id": run_id, "target": target.key,
           "pre_image": pre_image, "sentence": sentence}

    ok, why = target.setup(pre_image, file_token)
    if not ok:
        row.update(verdict="invalid", why=why)
        return row

    # The recording is driven through EnviousWispr's own menu, which activates
    # EnviousWispr. Delivery then targets whatever is frontmost when the pipeline
    # finishes. If that is not our target, the words land somewhere real and the oracle
    # honestly reports nothing in the field under test — a DROP, which is the verdict that
    # disqualifies a variant. Measured 2026-09-04: the baseline dropped 2/5 in TextEdit,
    # which is impossible for today's shipped behaviour and was the tell that the harness,
    # not the app, was being measured.
    frontmost_before = ax_oracle.pid_for_bundle(target.bundle_id)
    boundary = log_size()
    try:
        wispr_eyes.test_recording(sentence=sentence, expect=None)
    except Exception as exc:  # noqa: BLE001 - a harness fault is invalid, never a failure
        row.update(verdict="invalid", why=f"recording_raised:{type(exc).__name__}:{exc}")
        return row

    if ax_oracle.pid_for_bundle(target.bundle_id) != frontmost_before:
        row.update(verdict="invalid", why="target_process_changed_during_trial")
        return row

    scan = (target.reader() if target.reader
            else ax_oracle.settled_focused(target.bundle_id, max_wait=6.0))
    if not scan.ok:
        row.update(verdict="invalid", why=f"oracle:{scan.why}")
        return row

    text = log_since(boundary)
    evidence = TRIAL_RE.findall(text)
    matches = [m for m in TRIAL_RE.finditer(text)]
    if variant != "V0":
        if len(matches) != 1:
            row.update(verdict="invalid", why=f"delivery_lines={len(matches)}")
            return row
        ev = matches[0].groupdict()
        if ev["run"] != run_id or ev["variant"] != variant:
            row.update(verdict="invalid", why=f"evidence_mismatch:{ev['run']}/{ev['variant']}")
            return row
        row.update(tier=ev["tier"], attempts=ev["attempts"], ledger=ev["ledger"],
                   duration_ms=int(ev["duration"]))
    else:
        tiers = re.findall(r"Paste cascade: tier=(\S+?), app=(\S+?),", text)
        if len(tiers) != 1:
            # Zero means the dictation never delivered (a recording fault); more than one
            # means a stray delivery landed inside this trial's window. Neither is a
            # statement about the variant, and scoring either as a drop would put harness
            # noise into the column that disqualifies variants.
            row.update(verdict="invalid", why=f"baseline_delivery_lines={len(tiers)}")
            return row
        row["tier"], row["delivered_to"] = tiers[0]
        row["ledger"] = None
    del evidence

    verdict, detail = classify(pre_image, marker, scan.fields)
    # The app said it delivered and the destination does not have it. That is either a
    # real drop or the delivery went to a window this scan did not read, and the two are
    # not distinguishable from here. Call it what it is rather than guessing: a `drop`
    # verdict must mean "the user lost their words", because that verdict vetoes a
    # variant, and a veto built on an ambiguous row is how a bench picks the wrong winner.
    if verdict == "drop" and row.get("tier") not in (None, "clipboard_only"):
        verdict, detail = "unseen", dict(detail, why=f"app_reported_{row.get('tier')}")
    row.update(verdict=verdict, **detail)
    return row


def decide(scorecard: dict) -> dict:
    """Apply the pre-registered decision rule to a scorecard. No judgement calls.

    The rule is mechanical on purpose. A bench whose winner is argued rather than computed
    is a slower way of having the same opinion, and the whole reason this exists is that
    the opinion was not good enough.

    Order matters, and the vetoes come first because a duplicate improvement may never buy
    back a coverage loss. That ordering is the founder's, stated before any data existed:
    "I don't want to lose our ability to paste reliably into applications."
    """
    rows = scorecard["rows"]
    cells: dict[tuple[str, str], dict] = {}
    for row in rows:
        key = (row.get("variant"), row.get("target"))
        bucket = cells.setdefault(
            key, {"once": 0, "duplicate": 0, "drop": 0, "unseen": 0, "invalid": 0})
        bucket[row.get("verdict", "invalid")] += 1

    targets = sorted({t for _, t in cells if t})
    variants = sorted({v for v, _ in cells if v})
    baseline_ok = {
        t: cells.get(("V0", t), {}).get("once", 0) > 0 for t in targets
    }

    verdicts: dict[str, dict] = {}
    for variant in variants:
        # THREE statuses, not two. A first draft had `eligible` and `disqualified`, so a
        # variant with no scoreable trials came out DISQUALIFIED — which reads as "it
        # failed" when the truth is "we never learned anything about it". The self-test
        # caught it on its first run. Same shape as every other defect in this bench: a
        # three-valued reality read by a two-valued caller, collapsing toward the answer
        # that looks like a finding.
        vetoes: list[str] = []
        reasons: list[str] = []
        valid_total = 0
        duplicates = 0
        for target in targets:
            cell = cells.get((variant, target))
            if cell is None:
                reasons.append(f"{target}: not run")
                continue
            # `unseen` is deliberately NOT valid: the app reported a delivery the oracle
            # could not find, so the row says nothing about the variant either way.
            valid = cell["once"] + cell["duplicate"] + cell["drop"]
            valid_total += valid
            duplicates += cell["duplicate"]
            if valid == 0:
                reasons.append(
                    f"{target}: no scoreable trials "
                    f"({cell['invalid']} invalid, {cell['unseen']} unseen)")
                continue
            # COVERAGE VETO. Only fires where the baseline demonstrably works, so a target
            # nobody can deliver to cannot disqualify a variant for failing there too.
            if cell["drop"] > 0 and baseline_ok.get(target):
                vetoes.append(
                    f"{target}: VETO — dropped {cell['drop']}/{valid} where V0 delivers")
        if variant == "V0":
            status = "baseline"
        elif vetoes:
            status = "disqualified"
        elif valid_total == 0:
            status = "unmeasured"
        else:
            status = "eligible"
        reasons = vetoes + reasons
        verdicts[variant] = {
            "status": status, "reasons": reasons,
            "valid_trials": valid_total, "duplicates": duplicates,
        }

    eligible = [v for v, d in verdicts.items()
                if d["status"] == "eligible" and d["valid_trials"] > 0]
    candidates = [v for v in verdicts if v != "V0"]
    if not candidates:
        # Baseline-only run. Saying "nothing survived the veto" here would be a plausible
        # sentence about a comparison that never happened — the same shape of wrong answer
        # this bench exists to avoid, one level up.
        winner, why = None, "baseline-only run: no candidate variant was measured"
    elif not eligible:
        winner, why = None, "no candidate variant survived the coverage veto"
    else:
        fewest = min(verdicts[v]["duplicates"] for v in eligible)
        tied = [v for v in eligible if verdicts[v]["duplicates"] == fewest]
        if len(tied) > 1:
            winner, why = None, (
                f"tie on duplicates ({fewest}) between {tied} — latency is the tie-break "
                "and this screening run does not measure it")
        else:
            winner, why = tied[0], f"fewest duplicates ({fewest}) among eligible variants"

    return {"cells": {f"{v}/{t}": c for (v, t), c in cells.items()},
            "verdicts": verdicts, "winner": winner, "why": why,
            "baseline_delivers": baseline_ok}


def selftest() -> int:
    """Exercise the scoring logic against the defects it has already had.

    The scorer is the only part of this bench that can turn a correct delivery into a
    verdict that disqualifies a variant, and it has done exactly that once. These rows are
    the regression net for the specific ways it was wrong, built from the real values that
    fooled it rather than from imagined ones.
    """
    from types import SimpleNamespace as F

    failures: list[str] = []

    def check(name: str, got, want):
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    pre = "PRE-CD7735EA"
    marker = "brown fox"

    # 1. The bug that scored a perfect delivery as a DROP. Safari's address bar carried
    #    the pre-image because it was in the filename, and it was LONGER than the real box.
    address_bar = F(role="AXTextField", depth=4, chars=76, focused=False,
                    value=f"file:///Users/x/Library/Caches/EnviousWispr-bakeoff-{pre}.html")
    textarea = F(role="AXTextArea", depth=8, chars=39, focused=True,
                 value=f"The quick brown fox jumps. {pre}")
    verdict, detail = classify(pre, marker, [address_bar, textarea])
    check("focused editable wins over longer chrome", verdict, "once")
    check("and says how it chose", detail["field_choice"], "focused")

    # 2. The AXStaticText mirror. `_dedupe` removes it upstream, but the scorer must not
    #    depend on that: a mirror reaching it must not become a second occurrence.
    mirror = F(role="AXStaticText", depth=9, chars=None, focused=False,
               value=f"The quick brown fox jumps. {pre}")
    verdict, _ = classify(pre, marker, [textarea, mirror])
    check("a non-editable mirror is not a duplicate", verdict, "once")

    # 3. A real duplicate must still read as one.
    doubled = F(role="AXTextArea", depth=8, chars=65, focused=True,
                value=f"The quick brown fox jumps. The quick brown fox jumps. {pre}")
    verdict, _ = classify(pre, marker, [doubled])
    check("a genuine double insertion", verdict, "duplicate")

    # 4. A real drop.
    untouched = F(role="AXTextArea", depth=8, chars=12, focused=True, value=pre)
    verdict, _ = classify(pre, marker, [untouched])
    check("nothing landed", verdict, "drop")

    # 5. The pre-image gone entirely is unscoreable, not a drop.
    verdict, _ = classify(pre, marker, [F(role="AXTextArea", depth=1, chars=3,
                                          focused=True, value="hi")])
    check("pre-image absent is invalid", verdict, "invalid")

    # 6. The decision rule must not read a baseline-only run as a failed comparison.
    card = {"rows": [{"variant": "V0", "target": "t", "verdict": "once"}]}
    result = decide(card)
    check("baseline-only run", result["winner"], None)
    check("and says why honestly", "baseline-only" in result["why"], True)

    # 7. A candidate that drops where the baseline delivers is vetoed; `unseen` is not
    #    evidence either way and must not veto.
    card = {"rows": [
        {"variant": "V0", "target": "t", "verdict": "once"},
        {"variant": "V1", "target": "t", "verdict": "unseen"},
        {"variant": "V4", "target": "t", "verdict": "once"},
        {"variant": "V2", "target": "t", "verdict": "drop"},
    ]}
    result = decide(card)
    check("a real drop vetoes", result["verdicts"]["V2"]["status"], "disqualified")
    check("unseen does not veto", result["verdicts"]["V1"]["status"], "unmeasured")
    check("unseen is not a valid trial", result["verdicts"]["V1"]["valid_trials"], 0)
    check("winner has valid trials", result["winner"], "V4")

    for failure in failures:
        print(f"  FAIL {failure}")
    print(f"selftest: {len(failures)} failure(s)")
    return 1 if failures else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--variants", default="V0,V1,V2", help="comma-separated, in VARIANTS")
    ap.add_argument("--targets", default="textedit,safari_textarea")
    ap.add_argument("--reps", type=int, default=None,
                    help="repetitions per variant/target. Required: a default here would "
                         "be a parameter nobody states and everybody inherits.")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--sentence", default="the quick brown fox jumps")
    ap.add_argument("--marker", default="brown fox")
    ap.add_argument("--out", default=None)
    ap.add_argument("--selftest", action="store_true",
                    help="check the scoring logic against the defects it has already had")
    ap.add_argument("--report", default=None,
                    help="apply the decision rule to an existing scorecard and exit")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    if args.report:
        card = json.loads(pathlib.Path(args.report).read_text())
        result = decide(card)
        print(json.dumps(result, indent=1))
        return 0

    if args.reps is None:
        print("--reps is required for a run: a default here would be a parameter nobody "
              "states and everybody inherits.", file=sys.stderr)
        return 2

    if ax_oracle.screen_is_locked():
        print("REFUSING TO RUN: the Mac is locked. Every trial would be scored against a "
              "screen no app can reach, and the results would look like dropped text "
              "rather than like a locked machine.", file=sys.stderr)
        return 2

    seed = args.seed if args.seed is not None else random.randrange(1 << 30)
    random.seed(seed)
    run_id = uuid.uuid4().hex[:12]
    variants = [v.strip() for v in args.variants.split(",") if v.strip()]
    unknown = [v for v in variants if v not in VARIANTS]
    if unknown:
        print(f"unknown variants: {unknown}", file=sys.stderr)
        return 2
    targets = [TARGETS[t.strip()] for t in args.targets.split(",") if t.strip() in TARGETS]

    out_path = pathlib.Path(
        args.out or (pathlib.Path.home()
                     / "Developer/EnviousLabs/EnviousWispr/.validation"
                     / f"paste-bakeoff-{run_id}.json"))
    out_path.parent.mkdir(parents=True, exist_ok=True)

    rows: list[dict] = []
    # RELAUNCH ONCE PER VARIANT, NOT ONCE PER CELL.
    #
    # The variant is baked into the app's launch environment, so it is the variant — never
    # the destination — that a relaunch exists to change. The old schedule interleaved
    # (variant, target) pairs and relaunched for every one of them, which on a 5-variant,
    # 4-target run meant 20 relaunches to change 5 things.
    #
    # Measured 2026-09-04 mid-run, from delivery timestamps in `app.log`: 12s between
    # dictations inside a cell, 65s between cells. The 65s is TERM, launch, model load and
    # the control line; it is not overhead that can be tuned away, it is a whole app
    # start. Twenty of them is 22 minutes of a 34-minute run spent restarting an app to
    # give it a setting it already had.
    #
    # **The cost of grouping, stated rather than glossed.** Interleaving was there so a
    # drift in the machine's state could not be read as a property of whichever variant
    # ran last. Blocks give that up: every trial of one variant is now adjacent, so a
    # drift during a block lands on that block. Two things bound it. The variant ORDER and
    # the target order within each block are still shuffled, so no variant occupies a
    # fixed position across runs. And the veto this bench turns on is DROPS — a variant
    # losing text where the baseline delivers — which is a coarse, near-binary signal
    # rather than a rate that a slow machine could nudge across a threshold.
    variant_order = list(variants)
    random.shuffle(variant_order)

    for variant in variant_order:
        launched, why = launch_dev_app(variant, run_id)
        block = list(targets)
        random.shuffle(block)
        if not launched:
            for target in block:
                rows.append({"variant": variant, "target": target.key,
                             "verdict": "invalid", "why": f"launch:{why}"})
            print(f"[{variant}] LAUNCH FAILED: {why}", flush=True)
            continue
        print(f"[{variant}] launched ({why}) — "
              f"{len(block)} cells on this launch: {', '.join(t.key for t in block)}",
              flush=True)
        for target in block:
            print(f"  [{variant}/{target.key}]", flush=True)
            for i in range(args.reps):
                row = run_trial(variant, run_id, target, args.sentence, args.marker)
                row["rep"] = i
                rows.append(row)
                print(f"    rep {i}: {row.get('verdict')} tier={row.get('tier')} "
                      f"{row.get('why', '')}", flush=True)

    summary: dict = {}
    for row in rows:
        key = f"{row['variant']}/{row['target']}"
        bucket = summary.setdefault(
            key, {"once": 0, "duplicate": 0, "drop": 0, "unseen": 0, "invalid": 0})
        bucket[row.get("verdict", "invalid")] = bucket.get(row.get("verdict", "invalid"), 0) + 1

    out_path.write_text(json.dumps(
        {"run_id": run_id, "seed": seed, "sentence": args.sentence,
         "summary": summary, "rows": rows}, indent=1))
    print("\n=== summary ===")
    for key, bucket in sorted(summary.items()):
        print(f"  {key}: {bucket}")
    card = json.loads(out_path.read_text())
    decision = decide(card)
    print("\n=== decision (pre-registered rule, applied mechanically) ===")
    for variant, detail in sorted(decision["verdicts"].items()):
        print(f"  {variant}: {detail['status']} "
              f"(valid={detail['valid_trials']}, duplicates={detail['duplicates']})")
        for reason in detail["reasons"]:
            print(f"      {reason}")
    print(f"  WINNER: {decision['winner']} — {decision['why']}")
    card["decision"] = decision
    out_path.write_text(json.dumps(card, indent=1))
    print(f"\nscorecard: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
