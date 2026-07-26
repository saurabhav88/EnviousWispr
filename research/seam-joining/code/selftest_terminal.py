"""Test the join in a real terminal, so the founder does not have to.

The terminal path has broken four different ways and each was found by him
pressing the hotkey and reporting it: the whole scrollback read as the document,
no caret position reported, UI chrome counted as prose, and the delete running
to the end of the screen buffer instead of the end of his sentence.

This opens its OWN Ghostty window, types a known two-sentence line at the shell
prompt, runs the real join, and reads the field back. It never sends Return, so
nothing is ever executed, and it clears the line afterwards.
"""

import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import join_hotkey as J  # noqa: E402

import Quartz  # noqa: E402
from AppKit import NSWorkspace  # noqa: E402

CASES = [
    ("mid-clause continuation", "This is me trying. To understand if this will work."),
    ("double space", "I can't wait to go.  Shower tonight."),
    ("genuinely separate", "The meeting went well. I'll send notes tomorrow."),
]

CLEAR_LINE = 21  # ctrl-U


def type_text(text):
    source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    for ch in text:
        for pressed in (True, False):
            event = Quartz.CGEventCreateKeyboardEvent(source, 0, pressed)
            Quartz.CGEventKeyboardSetUnicodeString(event, len(ch), ch)
            Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, event)
        time.sleep(0.012)


def clear_line():
    """Backspace the line away and VERIFY it went.

    ctrl-U alone silently failed here, so cases two and three ran against
    leftover text from case one and reported failures that were the harness's
    fault, not the join's. Never trust a cleanup step that is not checked.
    """
    for _ in range(4):
        current = read_input_line() or ""
        if not current.strip():
            return True
        source = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
        for _ in range(len(current) + 8):
            for pressed in (True, False):
                event = Quartz.CGEventCreateKeyboardEvent(source, 51, pressed)
                Quartz.CGEventPost(Quartz.kCGAnnotatedSessionEventTap, event)
            time.sleep(0.003)
        time.sleep(0.3)
    return not (read_input_line() or "").strip()


def frontmost_name():
    NSWorkspace.sharedWorkspace().runningApplications()
    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    return app.localizedName() if app else None


def read_input_line():
    element, _, problem = J.focused()
    if problem:
        return None
    value = J.attr(element, "AXValue")
    if not isinstance(value, str):
        return None
    return J.terminal_text(value)


def main():
    from anthropic import AnthropicBedrock
    client = AnthropicBedrock(
        aws_access_key=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        aws_region="us-east-1")
    model = "us.anthropic.claude-haiku-4-5-20251001-v1:0"

    repo = os.path.expanduser("~/Developer/EnviousLabs/EnviousWispr")
    swift = os.path.join(repo,
                         "Sources/EnviousWisprLLM/Prompting/CloudFixedPromptBuilder.swift")
    match = re.search(r'cloudFixedSystemPrompt = """\n(.*?)\n\s*"""',
                      open(swift, encoding="utf-8").read(), re.DOTALL)
    system = match.group(1) + J.JOIN_NOTE

    print("opening a dedicated Ghostty window (never touches an existing one)")
    subprocess.run(["open", "-na", "Ghostty"], capture_output=True)
    time.sleep(2.5)
    if frontmost_name() != "Ghostty":
        print(f"frontmost is {frontmost_name()}, not Ghostty — aborting")
        return 1

    failures = 0
    for name, text in CASES:
        print(f"\n=== {name}")
        print(f"  typing : {text!r}")
        if not clear_line():
            print("  HARNESS could not clear the line, skipping")
            failures += 1
            continue
        type_text(text)
        time.sleep(0.5)

        staged = read_input_line()
        if not staged or text.split()[0] not in staged:
            print(f"  HARNESS could not stage the line (read {staged!r})")
            failures += 1
            clear_line()
            continue

        try:
            J.do_join(client, model, system)
        except Exception as exc:
            print(f"  EXCEPTION {type(exc).__name__}: {exc}")
            failures += 1
            clear_line()
            continue

        time.sleep(0.5)
        after = read_input_line()
        print(f"  after  : {after!r}")

        problems = []
        if after is None:
            problems.append("could not read the line back")
        else:
            for word in re.findall(r"[A-Za-z']+", text):
                if word.lower() not in after.lower():
                    problems.append(f"lost the word {word!r}")
                    break
            if re.search(r"[.!?]\s*[.!?]", after):
                problems.append("doubled punctuation")
            leftovers = re.findall(r"[.!?]\s*$", after)
            if after.count(".") > text.count(".") :
                problems.append("gained a full stop")

        if problems:
            failures += 1
            for p in problems:
                print(f"  FAIL  {p}")
        else:
            print("  ok")
        clear_line()

    print(f"\n{'ALL PASS' if not failures else f'{failures} FAILING'}")
    print("leaving the window open so the result can be seen")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
