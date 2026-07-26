"""Last sanity check before declaring the merge system dead: can EG-1 do it?

Apple Intelligence scored 3/11 with the shipped prompt and 2/11 with a narrow
one, and its failures were not near misses — it replied to the dictation like a
chatbot and deleted whole sentences. Founder call, 2026-07-25: if EG-1 fails too
the approach is genuinely dead; if EG-1 has a pulse, the merge can ship as an
option for EG-1 and cloud polish only.

Same eleven cases as the Apple Intelligence run, so the three engines are
directly comparable. Greedy sampling, so a rerun gives the same answer.

EG-1's prompt is a training contract, not a free choice: the model was tuned on
one exact system prompt and one exact <TRANSCRIPT> wrapper
(`EGOnePromptBuilder.swift`, "DO NOT EDIT without retraining"). Both are read
from the Swift source at run time so this cannot drift from what ships. Two
configurations are tried:

  trained + join   the training prompt with the joining instruction appended
  narrow           the joining instruction alone, off the training distribution

The second is expected to be worse for a fine-tuned model, but it is cheap and
it is the configuration that would matter if the first one nearly works.
"""

import argparse
import os
import re
import sys

import urllib.request
import json

SWIFT_EG1 = "Sources/EnviousWisprLLM/Prompting/EGOnePromptBuilder.swift"

CASES = [
    ("It now passes ten.", "Dictated chunks in a row, cleanly.", "join"),
    ("I was thinking about the release.", "And how we should stage it.", "join"),
    ("The tests are still red.", "So we cannot ship today.", "join"),
    ("Can you take a look.", "When you get a chance.", "join"),
    ("I will send you the notes.", "After the meeting ends.", "join"),
    ("We should probably tell the team.", "Before anyone else finds out.", "join"),
    ("I finished the report.", "But I have not sent it yet.", "join"),
    ("I was thinking about the release and how we should stage it.",
     "The tests are still red.", "leave"),
    ("Can you take a look when you get a chance?", "It is not urgent.", "leave"),
    ("The meeting went well.", "I'll send notes tomorrow.", "leave"),
    ("I pushed the fix.", "Thanks for catching that.", "leave"),
]

JOIN_NOTE = (
    " The transcript is a PREVIOUS sentence followed by a NEW recording the "
    "speaker dictated moments later, after a pause. If they are one thought "
    "split by that pause, join them into a single sentence. If they are two "
    "separate thoughts, leave them as two sentences. Never drop a word, never "
    "replace a word with a different word, and never reinterpret what was said."
)

NARROW = (
    "You are given two pieces of dictated text. The FIRST is already in the "
    "user's document. The SECOND was just spoken, after a pause. Decide one "
    "thing: are these one thought that a pause split in half, or two separate "
    "thoughts? If ONE thought, return them as a single sentence, changing only "
    "the punctuation and capitalisation at the join. If TWO thoughts, return "
    "both pieces exactly as given. Do not fix, improve, rephrase or reinterpret "
    "anything. Every word given to you appears in your answer. Output only the "
    "cleaned text."
)


def trained_prompt(repo):
    """EG-1's exact training system prompt, read from the Swift source."""
    body = open(os.path.join(repo, SWIFT_EG1), encoding="utf-8").read()
    match = re.search(r"static let systemPrompt =\s*\n(.*?)\n\n", body, re.DOTALL)
    if not match:
        raise SystemExit("could not read EG-1's system prompt")
    pieces = re.findall(r'"((?:[^"\\]|\\.)*)"', match.group(1))
    return "".join(pieces)


def ask(endpoint, system, transcript):
    payload = {
        "messages": [
            {"role": "system", "content": system},
            # The training-faithful wrapper. EG-1 saw this exact shape and
            # nothing else; a bare transcript is off-distribution.
            {"role": "user", "content": f"<TRANSCRIPT>\n{transcript}\n</TRANSCRIPT>"},
        ],
        "temperature": 0, "top_k": 1, "max_tokens": 400, "stream": False,
    }
    request = urllib.request.Request(
        f"{endpoint}/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=120) as response:
        body = json.load(response)
    return body["choices"][0]["message"]["content"].strip()


def words(text):
    return [w.lower().replace("'", "") for w in re.findall(r"[A-Za-z']+", text)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default="http://127.0.0.1:8899")
    args = parser.parse_args()

    repo = os.path.expanduser("~/Developer/EnviousLabs/EnviousWispr")
    trained = trained_prompt(repo)

    configurations = [
        ("trained prompt + join instruction", trained + JOIN_NOTE),
        ("narrow prompt only", NARROW),
    ]

    for label, system in configurations:
        print(f"\n=== {label}  ({len(system)} characters)")
        correct = 0
        for first, second, want in CASES:
            source = f"{first} {second}"
            try:
                out = ask(args.endpoint, system, source)
            except Exception as exc:
                print(f"  ERROR      {type(exc).__name__}: {exc}")
                continue

            lost = [w for w in words(source) if w not in words(out)]
            # Did the BOUNDARY go? Both halves arrive terminated, so the
            # input always holds two sentence-final marks. One left means
            # they were welded; two means they were not, however much else
            # was edited. Scoring on 'anything changed' counted a casing or
            # punctuation tweak as a successful join. Found by cloud review
            # on PR #1793.
            joined = sum(out.count(c) for c in '.!?') < 2
            if len(lost) > 2:
                verdict = f"DESTROYED  lost {lost}"
            elif want == "join" and not joined:
                verdict = "MISSED     left it as two"
            elif want == "leave" and joined:
                verdict = "OVERMERGED joined two separate thoughts"
            else:
                verdict = "ok"
                correct += 1
            print(f"  {verdict}")
            print(f"      in : {source}")
            print(f"      out: {out}")
        print(f"  --> {correct}/{len(CASES)} correct")
    return 0


if __name__ == "__main__":
    sys.exit(main())
