"""Founder's idea, 2026-07-25: skip the classifier, re-polish the seam instead.

Instead of a model DECIDING whether two recordings join, hand the polisher the
last sentence already sitting in the document plus the new recording, and let it
produce clean joined text. Delete that last sentence, paste the result.

It is a better idea than the classifier if it works, because it deletes the
entire measurement problem: nothing to label, nothing to grade, no bias, no
279 MB artifact. It also fixes things the classifier structurally cannot, like
a second recording that opens on "But".

The question is purely empirical and he asked it exactly right: what does the
polisher actually DO with that input? Does it join? Restructure? Move the full
stops? Rewrite words it should not touch?

So this runs our REAL shipped polish prompt over real consecutive recordings and
prints the before and after, side by side, for a human to read. It scores
nothing. Reading the outputs is the point.

Uses the labelled real pairs so both cases are covered: pairs a grader called
one thought, and pairs it called two. The second group is the dangerous one — a
polisher that helpfully welds separate sentences is worse than the classifier.
"""

import argparse
import json
import os
import random
import re
import sys

# The exact shipped cloud prompt, read from the Swift source so this can never
# drift from what users get (validation-discipline.md
# RULE: measure-with-the-real-tool-never-a-simulation).
SWIFT = ("Sources/EnviousWisprLLM/Prompting/CloudFixedPromptBuilder.swift")


def shipped_prompt(repo):
    path = os.path.join(repo, SWIFT)
    body = open(path, encoding="utf-8").read()
    match = re.search(r'cloudFixedSystemPrompt = """\n(.*?)\n\s*"""', body, re.DOTALL)
    if not match:
        raise SystemExit(f"could not read the shipped prompt from {path}")
    return match.group(1)


def last_sentence(text):
    parts = re.split(r"(?<=[.!?])\s+", text.strip())
    return parts[-1] if parts else text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=12)
    ap.add_argument("--model", default="us.anthropic.claude-haiku-4-5-20251001-v1:0")
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    repo = os.path.expanduser("~/Developer/EnviousLabs/EnviousWispr")
    system = shipped_prompt(repo)

    rows = [json.loads(l) for l in
            open(os.path.join(root, "data", "seam_real_train.jsonl"), encoding="utf-8")]
    joins = [r for r in rows if r["label"] != "KEEP"]
    keeps = [r for r in rows if r["label"] == "KEEP"]
    rng = random.Random(1790)
    rng.shuffle(joins); rng.shuffle(keeps)
    half = args.n // 2
    sample = [("should join", r) for r in joins[:half]] + \
             [("should stay apart", r) for r in keeps[:args.n - half]]
    rng.shuffle(sample)

    from anthropic import AnthropicBedrock
    client = AnthropicBedrock(
        aws_access_key=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        aws_region="us-east-1")

    print(f"Re-polishing {len(sample)} real seams with the SHIPPED cloud prompt.\n"
          f"Input is the last sentence already in the document + the new recording.\n")

    for i, (expected, row) in enumerate(sample, 1):
        tail = last_sentence(row["rec1"])
        combined = f"{tail} {row['rec2'].strip()}"
        try:
            response = client.messages.create(
                model=args.model, max_tokens=600, temperature=0,
                system=system,
                messages=[{"role": "user",
                           "content": f"Transcript to clean:\n\n{combined}"}])
            out = response.content[0].text.strip()
        except Exception as exc:
            out = f"[FAILED: {type(exc).__name__}]"

        changed = out.strip() != combined.strip()
        print(f"--- {i}  ({expected})")
        print(f"  IN : {combined}")
        print(f"  OUT: {out}")
        print(f"  {'CHANGED' if changed else 'unchanged'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
