"""The founder's test, run without the founder: chunk, merge, chunk, merge.

Every terminal bug so far was found by him dictating into his own window and
reporting what he saw. This does that sequence automatically in the SAME window
he uses, because the failures only ever appear in a full-screen text UI and
never in a fresh shell.

It reproduces what the app does when dictating, which matters more than it
sounds: the app pastes each recording followed by a SPACE. Leaving that space
out is precisely what hid the off-by-one for three rounds, so the harness must
type it too or it proves nothing.

For each chunk it types the text, tells the join what the "recording" was, runs
the real join, and reads the box back. It checks two things every round:

  nothing of the user's text is lost      every word must survive
  no character is left behind             the merged text must not have a
                                          stray letter welded to its front

Nothing is ever submitted; no Return is sent. The box is cleared at the end and
the clearing is verified.
"""

import argparse
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import join_hotkey as J  # noqa: E402
import probe_replace_routes as R  # noqa: E402

# A thought deliberately broken across chunks, the way a pause breaks one, plus
# a chunk that genuinely starts something new so a wrong merge would show up.
# Whole thoughts, each split across two chunks the way a pause splits one. The
# lengths matter: the founder asked for six chunks, then eight, then ten,
# because every failure so far has appeared only after several merges have
# already landed on top of each other. A pair that merges is followed by a pair
# that starts something new, so a wrong merge is as visible as a missed one.
PAIRS = [
    ("I was thinking about the release.", "And how we should stage it."),
    ("The tests are still red.", "So we cannot ship today."),
    ("Can you take a look.", "When you get a chance."),
    ("I will send you the notes.", "After the meeting ends."),
    ("We should probably tell the team.", "Before anyone else finds out."),
]

SEQUENCES = [
    ("six chunks", [c for pair in PAIRS[:3] for c in pair]),
    ("eight chunks", [c for pair in PAIRS[:4] for c in pair]),
    ("ten chunks", [c for pair in PAIRS for c in pair]),
]


# Words the polisher may legitimately introduce when it welds two halves into
# one sentence. Anything outside this and the spoken text is corruption.
JOINING_WORDS = {"and", "but", "so", "that", "when", "if", "to", "a", "the",
                 "it", "is", "you", "at", "on", "in", "for", "of"}


def read_box():
    element, _, problem = J.focused()
    if problem:
        return None
    value = J.attr(element, "AXValue")
    if not isinstance(value, str):
        return None
    return J.terminal_text(value)


def clear_box():
    for _ in range(5):
        current = read_box()
        if current is None:
            return False
        if not current.strip():
            return True
        for _ in range(len(current) + 6):
            R.post_key(R.DELETE_KEY, settle=0.005)
        time.sleep(0.3)
    return not (read_box() or "").strip()


def words(text):
    """Tokens with apostrophes removed, so a contraction is comparable.

    The polisher legitimately rewrote "It is not urgent" as "It's not urgent".
    A strict word check called that a lost word AND an invented one — two
    failures for correct behaviour. Comparing on prefixes below lets "its" stand
    in for "it" and "is" without letting real corruption through, because the
    off-by-one produces a word that is a prefix of nothing anyone said.
    """
    return [w.lower().replace("'", "") for w in re.findall(r"[A-Za-z']+", text)]


def unexplained(box_words, said_words):
    return [w for w in box_words
            if w not in said_words and not any(w.startswith(s) for s in said_words)]


def missing(box_words, said_words):
    return [w for w in said_words
            if w not in box_words and not any(b.startswith(w) for b in box_words)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wait", type=float, default=6.0)
    args = parser.parse_args()

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

    print(f"\nClick into the terminal to test. Starting in {args.wait} seconds.")
    print("It types and deletes only. No Return is ever sent.")
    time.sleep(args.wait)
    _, front = R.frontmost()
    if front not in ("Ghostty", "Terminal", "iTerm2", "Warp", "kitty", "WezTerm"):
        print(f"frontmost is {front}, which is not a terminal — aborting")
        return 1

    # The join asks the app what it last pasted. Here the harness is the app.
    spoken = {"text": None}
    J.latest_recording = lambda: spoken["text"]

    failures = 0
    for label, chunks in SEQUENCES:
        print(f"\n=== {label}")
        if not clear_box():
            print("  HARNESS could not clear the box")
            failures += 1
            continue

        said = []
        for chunk in chunks:
            # Exactly what the app does: the text, then a space.
            R.type_text(chunk + " ")
            spoken["text"] = chunk
            said.append(chunk)
            time.sleep(0.5)

            before = read_box()
            print(f"  typed   {chunk!r}")
            try:
                J.do_join(client, model, system)
            except Exception as exc:
                print(f"  EXCEPTION {type(exc).__name__}: {exc}")
                failures += 1
                break
            time.sleep(0.4)
            after = read_box()
            print(f"  box now {after!r}")

            problems = []
            if after is None:
                problems.append("could not read the box back")
            else:
                said_words = set(words(" ".join(said))) | JOINING_WORDS
                box_words = words(after)
                lost = missing(box_words, set(words(" ".join(said))))
                if lost:
                    problems.append(f"lost: {lost}")
                # The off-by-one leaves the first letter of the deleted text
                # welded to the front of the new text: "It" arrives as "TIt".
                # That produces a word nobody said, which is detectable without
                # knowing what the polisher chose to write.
                strangers = unexplained(box_words, said_words)
                if strangers:
                    problems.append(f"words nobody said: {strangers}")
                if before and after and len(after) < len(before) - len(chunk) - 40:
                    problems.append(f"lost too much text ({len(before)} -> {len(after)})")

            for problem in problems:
                print(f"  FAIL    {problem}")
            failures += len(problems)

        if not clear_box():
            print("  HARNESS could not clear the box afterwards")
            failures += 1

    print(f"\n{'ALL PASS' if not failures else f'{failures} FAILING'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
