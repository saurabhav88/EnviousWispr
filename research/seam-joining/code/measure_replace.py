"""Stage a real field in a real app, run every replacement route, read it back.

The question, from the founder: backspacing forty times is slow to watch and
sometimes drops a keystroke, so is there a faster and more reliable way to swap
one span of text for another. Nobody can answer that from documentation — this
morning an accessibility call returned success in Chrome and changed nothing.

So every route is judged the same way: stage a known sentence, run the route,
read the field back, and require the EXACT expected string. Timing is recorded
alongside, but a fast route that produces the wrong text is not a candidate.

  python measure_replace.py textedit
  python measure_replace.py chrome        (also: chrome-contenteditable)
  python measure_replace.py ghostty
  python measure_replace.py slack
  python measure_replace.py excel
  python measure_replace.py focused       (whatever is focused right now)

Every app is left as it was found: the staged text is cleared at the end and
the result verified, so a failed cleanup is reported rather than left behind.
"""

import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_replace_routes as R  # noqa: E402
import join_hotkey as J  # noqa: E402

import Quartz  # noqa: E402

# The replacement is a DIFFERENT length from the span, so an off-by-one route
# cannot pass by luck. 20 characters out, 23 in.
#
# No apostrophe anywhere: TextEdit's smart quotes rewrote a typed ' into a ’ and
# every route failed staging rather than failing on its own merits.
STAGED = "I will head out now. Shower tonight."
SPAN = "now. Shower tonight."
REPLACEMENT = "now and shower tonight."
EXPECTED = "I will head out now and shower tonight."

# A real seam is two whole dictated sentences, not twenty characters. Backspace
# cost is linear in the span, so a short case flatters it; this is the size the
# mechanism actually has to survive.
LONG_STAGED = ("Here are my notes. I was thinking about the release and how we "
               "should stage it. But the tests are still red.")
LONG_SPAN = ("I was thinking about the release and how we should stage it. "
             "But the tests are still red.")
LONG_REPLACEMENT = ("I was thinking about how we should stage the release, but "
                    "the tests are still red.")
LONG_EXPECTED = "Here are my notes. " + LONG_REPLACEMENT


def use_long_case():
    """Swap the module-level fixture; the probes read these by name."""
    global STAGED, SPAN, REPLACEMENT, EXPECTED
    STAGED, SPAN = LONG_STAGED, LONG_SPAN
    REPLACEMENT, EXPECTED = LONG_REPLACEMENT, LONG_EXPECTED

CLEAR_LINE = 21  # ctrl-U
A_KEY = 0


class Surface:
    """One app, staged and read the way that app actually works."""

    def __init__(self, name, launch=None, terminal=False, note=""):
        self.name, self.launch, self.terminal, self.note = name, launch, terminal, note

    def activate(self):
        if self.launch:
            self.launch()
        time.sleep(1.2)
        _, front = R.frontmost()
        return front

    def element(self):
        element, _ = R.focused_element()
        return element

    def read(self, element):
        value = R.attr(element, "AXValue")
        if not isinstance(value, str):
            return None
        if self.terminal:
            # A terminal hands over the whole scrollback; only the current
            # input line is ours (join_hotkey.py explains why at length).
            return J.terminal_text(value).strip()
        return value.strip()

    def caret(self, element):
        if self.terminal:
            return None  # Ghostty always reports 0, which is not a caret
        selection = R.read_range(element)
        return selection[0] if selection else None

    def clear(self, element):
        """Empty the field and PROVE it emptied.

        ctrl-U silently failed in Ghostty once already, so cases two and three
        ran against leftovers and reported failures the routes did not cause.
        """
        for attempt in range(4):
            current = self.read(element) or ""
            if not current.strip():
                return True
            if self.terminal:
                R.post_key(CLEAR_LINE, Quartz.kCGEventFlagMaskControl)
                time.sleep(0.2)
                if (self.read(element) or "").strip():
                    for _ in range(len(current) + 8):
                        R.post_key(R.DELETE_KEY, settle=0.003)
            else:
                R.post_key(A_KEY, Quartz.kCGEventFlagMaskCommand)
                time.sleep(0.1)
                R.post_key(R.DELETE_KEY)
            time.sleep(0.25)
        return not (self.read(element) or "").strip()

    def stage(self, element):
        if not self.clear(element):
            return "could not clear the field"
        R.type_text(STAGED)
        time.sleep(0.4)
        got = self.read(element)
        if got is None:
            return "cannot read the field back"
        if got.strip() != STAGED.strip():
            return f"staged the wrong text: {got!r}"
        return None


# ── per-app launchers ────────────────────────────────────────────────────────

def applescript(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True)


def launch_textedit():
    applescript('tell application "TextEdit" to close every document saving no')
    time.sleep(0.3)
    applescript('tell application "TextEdit" to activate')
    time.sleep(0.5)
    applescript('tell application "TextEdit" to make new document')
    time.sleep(0.6)
    applescript('tell application "TextEdit" to activate')


def chrome_page(html_body, filename):
    """A local page, because Chrome refuses top-level data: URLs.

    Written under the job's own temp directory so parallel work cannot collide.
    """
    job = os.environ.get("CLAUDE_JOB_DIR")
    directory = os.path.join(job, "tmp") if job else "/tmp"
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, filename)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(html_body)
    subprocess.run(["open", "-a", "Google Chrome", path], capture_output=True)
    time.sleep(2.5)
    applescript('tell application "Google Chrome" to activate')


def launch_chrome_textarea():
    chrome_page(
        "<!doctype html><meta charset=utf-8><title>replace probe</title>"
        "<body style='font:16px system-ui;padding:40px'>"
        "<p>Seam replacement probe. Safe to close.</p>"
        "<textarea autofocus rows=6 cols=60 style='font:16px system-ui'></textarea>",
        "seam_probe_textarea.html")


def launch_chrome_contenteditable():
    chrome_page(
        "<!doctype html><meta charset=utf-8><title>replace probe</title>"
        "<body style='font:16px system-ui;padding:40px'>"
        "<p>Seam replacement probe. Safe to close.</p>"
        "<div id=box contenteditable style='border:1px solid #999;padding:10px;"
        "min-height:80px'></div><script>box.focus()</script>",
        "seam_probe_contenteditable.html")


def launch_ghostty():
    subprocess.run(["open", "-na", "Ghostty"], capture_output=True)


def launch_slack():
    applescript('tell application "Slack" to activate')


def launch_excel():
    applescript('tell application "Microsoft Excel" to activate')
    time.sleep(3.0)
    applescript('tell application "Microsoft Excel" to make new workbook')
    time.sleep(2.5)
    applescript('tell application "Microsoft Excel" to select range "A1" of active sheet')


class ExcelSurface(Surface):
    """A spreadsheet cell is only a text field while it is being edited.

    Outside edit mode Excel exposes an AXLayoutArea with no value, and Cmd+A
    means "select every cell in the sheet" rather than "select this text" — so
    the ordinary clear would have selected the whole workbook. Typing is what
    enters edit mode, and backspace is what leaves the sheet alone.
    """

    def read(self, element):
        element, _ = R.focused_element()
        value = R.attr(element, "AXValue") if element is not None else None
        return value.strip() if isinstance(value, str) else ""

    def element(self):
        element, _ = R.focused_element()
        return element

    def clear(self, element):
        for _ in range(4):
            current = self.read(element)
            if not current:
                return True
            for _ in range(len(current) + 4):
                R.post_key(R.DELETE_KEY, settle=0.003)
            time.sleep(0.3)
        return not self.read(element)


SURFACES = {
    "textedit": Surface("TextEdit", launch_textedit),
    "chrome": Surface("Chrome (textarea)", launch_chrome_textarea),
    "chrome-contenteditable": Surface("Chrome (contenteditable)",
                                      launch_chrome_contenteditable),
    "ghostty": Surface("Ghostty", launch_ghostty, terminal=True),
    "slack": Surface("Slack", launch_slack,
                     note="staged in whatever composer is focused; never sends"),
    "excel": ExcelSurface("Excel", launch_excel,
                          note="a new workbook; cell A1, discarded afterwards"),
    "focused": Surface("whatever is focused", None),
}


# ── the measurement ──────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("surface", choices=sorted(SURFACES))
    parser.add_argument("--repeat", type=int, default=1,
                        help="runs per route, to expose intermittent drops")
    parser.add_argument("--long", action="store_true",
                        help="a real two-sentence seam instead of a short one")
    parser.add_argument("--only", default="",
                        help="prefix letters of the routes to run, e.g. AB")
    args = parser.parse_args()

    if args.long:
        use_long_case()
    surface = SURFACES[args.surface]
    front = surface.activate()
    print(f"\n{surface.name}  (frontmost: {front})")
    if surface.note:
        print(f"  note: {surface.note}")

    element = surface.element()
    if element is None:
        print("  no focused element — nothing to measure")
        return 1
    role = R.attr(element, "AXRole")
    print(f"  focused role: {role}")
    print(f"  replacing {len(SPAN)} characters with {len(REPLACEMENT)}\n")

    results = []
    for label, route in R.ROUTES:
        if args.only and label[0] not in args.only:
            continue
        outcomes, timings = [], []
        for _ in range(args.repeat):
            # Re-fetch every run: a spreadsheet cell is a different element
            # while it is being edited than while it is merely selected.
            element = surface.element()
            problem = surface.stage(element)
            if problem:
                outcomes.append(f"HARNESS: {problem}")
                continue
            caret = surface.caret(element)
            unavailable, elapsed = R.run_route(route, element, len(SPAN),
                                               REPLACEMENT, caret)
            time.sleep(0.25)
            after = surface.read(element)
            if unavailable:
                outcomes.append(f"UNAVAILABLE ({unavailable})")
                continue
            timings.append(elapsed)
            if after is None:
                outcomes.append("could not read back")
            elif after.strip() == EXPECTED:
                outcomes.append("CORRECT")
            elif after.strip() == STAGED:
                outcomes.append("SILENT NO-OP")
            else:
                outcomes.append(f"WRONG -> {after!r}")

        correct = sum(1 for o in outcomes if o == "CORRECT")
        speed = f"{sum(timings)/len(timings):7.0f} ms" if timings else "      -   "
        summary = (f"{correct}/{args.repeat}" if args.repeat > 1
                   else ("ok" if correct else "no"))
        print(f"  {label:28} {speed}  {summary:6} {outcomes[0]}")
        for extra in outcomes[1:]:
            if extra != outcomes[0]:
                print(f"  {'':28} {'':10}  {'':6} {extra}")
        results.append((label, correct, timings))

    if not surface.clear(element):
        print("\n  CLEANUP FAILED — the field still holds probe text")
        return 1
    print("\n  field cleared")

    winners = [(l, sum(t)/len(t)) for l, c, t in results if c == args.repeat and t]
    if winners:
        best = min(winners, key=lambda pair: pair[1])
        print(f"  fastest route that was always correct: {best[0]}  {best[1]:.0f} ms")
    else:
        print("  no route was correct on every run")
    return 0


if __name__ == "__main__":
    sys.exit(main())
