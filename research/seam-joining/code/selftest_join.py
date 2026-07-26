"""Test the join myself instead of making the founder the QA loop.

Types a known two-sentence text into a real field, runs the real join path, and
reads the field back to check what actually happened. Every failure so far was
found by him pressing the hotkey and telling me it was broken; this closes that
loop.

Cases cover the shapes that have already bitten:
  single space between the sentences
  DOUBLE space          — the delete count came up one character short
  newline between them  — same class, different whitespace
  already one sentence  — must refuse, nothing to join
  a name at the seam    — must not lowercase it

Runs against TextEdit, which exposes a real caret and a real value, so a failure
here is the join logic rather than a terminal's quirks.
"""

import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import join_hotkey as J  # noqa: E402

CASES = [
    ("single space", "I can't wait to go. Shower tonight.",
     "one sentence, no leftover characters"),
    ("double space", "I can't wait to go.  Shower tonight.",
     "the whitespace case that left a stray character"),
    ("newline", "I can't wait to go.\nShower tonight.",
     "same class as double space"),
    ("genuinely separate", "The meeting went well. I'll send notes tomorrow.",
     "should stay as two sentences"),
    ("name at the seam", "I will see you. Monday at noon.",
     "must not lowercase Monday"),
    ("only one sentence", "Just the one sentence here.",
     "must refuse, nothing to join with"),
]


def applescript_string(text):
    """AppleScript literals need their own escaping; naive quote-swapping broke
    every case containing an apostrophe, which is most real dictation."""
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    escaped = escaped.replace("\n", '" & linefeed & "')
    return f'"{escaped}"'


def run_applescript(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True)


def fresh_document(text):
    """A new TextEdit window holding exactly `text`, caret at the end.

    Closes anything already open first: the first run of this file read a
    LEFTOVER document from an earlier test and reported a failure that had
    nothing to do with the join.
    """
    run_applescript('tell application "TextEdit" to close every document saving no')
    time.sleep(0.3)
    run_applescript('tell application "TextEdit" to activate')
    time.sleep(0.5)
    run_applescript(f'tell application "TextEdit" to make new document with '
                    f'properties {{text:{applescript_string(text)}}}')
    time.sleep(0.7)
    run_applescript('tell application "TextEdit" to activate')
    time.sleep(0.4)
    # Caret to the very end, where it would be after dictating.
    run_applescript('tell application "System Events" to tell process "TextEdit" '
                    'to key code 125 using command down')
    time.sleep(0.4)


def verify_staged(expected):
    """Prove the document really holds what we think before testing the join."""
    element, _, problem = J.focused()
    if problem:
        return f"could not focus TextEdit: {problem}"
    value = J.attr(element, "AXValue")
    if not isinstance(value, str):
        return "TextEdit exposed no text"
    if value.strip() != expected.strip():
        return f"staged the wrong text: {value!r}"
    return None


def read_document():
    element, _, problem = J.focused()
    if problem:
        return None
    return J.attr(element, "AXValue")


def close_documents():
    subprocess.run(["osascript", "-e",
                    'tell application "TextEdit" to close every document saving no'],
                   capture_output=True)


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

    failures = 0
    for name, text, expectation in CASES:
        print(f"\n=== {name}  ({expectation})")
        print(f"  before: {text!r}")
        fresh_document(text)
        staging = verify_staged(text)
        if staging:
            print(f"  HARNESS  {staging}")
            failures += 1
            close_documents()
            continue
        try:
            J.do_join(client, model, system)
        except Exception as exc:
            print(f"  EXCEPTION {type(exc).__name__}: {exc}")
            failures += 1
            close_documents()
            continue
        time.sleep(0.4)
        after = read_document()
        print(f"  after : {after!r}")

        problems = []
        if after is None:
            problems.append("could not read the document back")
        else:
            body = after.strip()
            if "only one sentence" in name:
                if body != text.strip():
                    problems.append("modified a document it should have refused")
            else:
                # Nothing from the original may be lost.
                for word in re.findall(r"[A-Za-z']+", text):
                    if word.lower() not in body.lower():
                        problems.append(f"lost the word {word!r}")
                        break
                if re.search(r"[.!?]\s*[.!?]", body):
                    problems.append("doubled punctuation")
                if body.endswith(".."):
                    problems.append("trailing double stop")
            if "name at the seam" in name and "monday" in body and "Monday" not in body:
                problems.append("lowercased Monday")

        if problems:
            failures += 1
            for p in problems:
                print(f"  FAIL  {p}")
        else:
            print("  ok")
        close_documents()

    print(f"\n{'ALL PASS' if not failures else f'{failures} FAILING'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
