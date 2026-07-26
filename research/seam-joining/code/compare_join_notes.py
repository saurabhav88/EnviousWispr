"""The polisher rewrote the founder's sentence into something he never said.

Live, 2026-07-25, on his own dictation:

    in   It now passes ten. Dictated chunks in a row, cleanly.
    out  It is now past ten.

It read "passes ten" as a time of day and discarded the rest — ten words in,
five out. The word-loss guard refused it and his text survived, but a guard
catching a destructive rewrite is the last line, not the fix. This is the real
risk in re-polishing at the seam, and it is far more dangerous than merging two
sentences that should have stayed apart.

So: does a stricter instruction stop it, WITHOUT breaking the joins that already
work? Both halves matter. An instruction that never destroys anything and also
never joins anything is worthless.

Run over the pairs verified clean in `selftest_chunks.py` plus the failure. Any
candidate must fix the failure and keep every good join.
"""

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import join_hotkey as J  # noqa: E402

# (first chunk, second chunk, what should happen)
CASES = [
    ("It now passes ten.", "Dictated chunks in a row, cleanly.", "join"),
    ("I was thinking about the release.", "And how we should stage it.", "join"),
    ("The tests are still red.", "So we cannot ship today.", "join"),
    ("Can you take a look.", "When you get a chance.", "join"),
    ("I will send you the notes.", "After the meeting ends.", "join"),
    ("We should probably tell the team.", "Before anyone else finds out.", "join"),
    ("I was thinking about the release and how we should stage it.",
     "The tests are still red.", "leave"),
    ("Can you take a look when you get a chance?", "It is not urgent.", "leave"),
    ("The meeting went well.", "I'll send notes tomorrow.", "leave"),
]

# A candidate is a whole system prompt. Until now every one of them was the
# shipped polish prompt with a joining instruction bolted on, and that prompt
# actively works against the task: it tells the model to break run-on speech
# into SEPARATE sentences while the appendix asks it to JOIN them, and it
# explicitly licenses "obvious speech-to-text slips fixed when the intended word
# is clear from context" — which is precisely the clause that rewrote the
# founder's "It now passes ten" as "It is now past ten". The narrow prompt has
# never been tried, and it is the one most likely to survive a small on-device
# model, which will follow a page of editing instructions if given a page.
NARROW = """\
You are given two pieces of dictated text. The FIRST was spoken a moment ago \
and is already in the user's document. The SECOND was just spoken, after a pause.

Decide one thing: are these one thought that a pause split in half, or two \
separate thoughts?

If ONE thought, return them as a single sentence. You may only remove the full \
stop between them, lowercase the first word of the second half, and drop a \
connecting word that joining has made redundant.

If TWO thoughts, return both pieces exactly as they were given to you, \
unchanged.

You are not an editor. Do not fix, improve, rephrase, shorten, or reinterpret \
anything. Do not correct a word that looks like a mishearing. Every word given \
to you appears in your answer. Return only the text, with no comment."""


def with_shipped(note):
    return ("shipped-polish", note)


CANDIDATES = {
    "shipped polish + loose join": ("shipped", J.JOIN_NOTE.replace(
        " Never drop a word, never replace a word with a different word, and "
        "never reinterpret what was said. Every word of the transcript must "
        "appear in your answer unless joining the two halves makes a "
        "connecting word redundant.", "")),
    "shipped polish + strict join": ("shipped", J.JOIN_NOTE),
    "narrow prompt, no polish": ("narrow", NARROW),
}


def words(text):
    return [w.lower() for w in re.findall(r"[A-Za-z']+", text)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="us.anthropic.claude-haiku-4-5-20251001-v1:0")
    args = parser.parse_args()

    from anthropic import AnthropicBedrock
    client = AnthropicBedrock(
        aws_access_key=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        aws_region="us-east-1")

    repo = os.path.expanduser("~/Developer/EnviousLabs/EnviousWispr")
    swift = os.path.join(repo,
                         "Sources/EnviousWisprLLM/Prompting/CloudFixedPromptBuilder.swift")
    base = re.search(r'cloudFixedSystemPrompt = """\n(.*?)\n\s*"""',
                     open(swift, encoding="utf-8").read(), re.DOTALL).group(1)

    for name, note in CANDIDATES.items():
        print(f"\n=== {name}")
        wrong = 0
        for first, second, want in CASES:
            source = f"{first} {second}"
            try:
                response = client.messages.create(
                    model=args.model, max_tokens=600, temperature=0,
                    system=base + note,
                    messages=[{"role": "user",
                               "content": f"Transcript to clean:\n\n{source}"}])
                out = response.content[0].text.strip()
            except Exception as exc:
                print(f"  [{type(exc).__name__}] {source}")
                wrong += 1
                continue

            lost = [w for w in words(source) if w not in words(out)]
            joined = out.strip() != source.strip()
            # A dropped connecting word is legitimate when joining; losing a
            # third of the sentence is the failure this exists to catch.
            destroyed = len(lost) > 2

            if destroyed:
                verdict = f"DESTROYED  lost {lost}"
            elif want == "join" and not joined:
                verdict = "MISSED     left it as two"
            elif want == "leave" and joined:
                verdict = "OVERMERGED joined two separate thoughts"
            else:
                verdict = "ok"

            if verdict != "ok":
                wrong += 1
            print(f"  {verdict:34} {out}")
        print(f"  --> {len(CASES) - wrong}/{len(CASES)} correct")
    return 0


if __name__ == "__main__":
    sys.exit(main())
