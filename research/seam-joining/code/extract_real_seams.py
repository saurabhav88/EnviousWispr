"""Pull REAL consecutive-recording pairs out of the founder's dictation log.

Everything the model has been judged on so far is synthetic: real sentences cut
at real boundaries, then damaged to imitate what the transcriber does. The
coverage round's strongest finding is that this proves nothing about production,
where the two halves come from two separate recordings with two separate
transcription passes, real polish artifacts, and a real human pause in between.

The log already holds those pairs. Each dictation records its final text and a
timestamp, so a pair of dictations close together in time IS a real seam: the
user stopped talking, thought, and started again.

What this does NOT do is label them. A real seam has no ground truth attached,
so labelling is a separate step; this only builds the population.

The output contains the founder's own dictation. It is gitignored and must
never be committed.
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime

STAMP = re.compile(r"^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2})\]")
STEP = re.compile(r"CORRECTION_DEBUG \[([^\]]+)\](?: OUT:)?\s?(.*)$", re.DOTALL)

# Later steps win: the last one to report real text is what reached the clipboard.
ORDER = ["RAW ASR", "Word Correction", "Filler Removal", "Emoji Formatter",
         "Inverse Text Normalization", "LLM Polish", "Emoji Restore"]


def parse_log(path):
    """Yield (timestamp, final_text) per dictation.

    A step's text can run over several lines, so a line without its own
    timestamp continues the previous step rather than starting a new one.
    """
    dictations = []
    current = {}
    pending_step = None
    for raw in open(path, encoding="utf-8", errors="replace"):
        stamp = STAMP.match(raw)
        if not stamp:
            if pending_step and current:
                # Keep the newline. Appending bare made a transcript
                # containing a line break come out as "helloworld",
                # silently corrupting the very recordings the corpus is
                # built from. Found by cloud review on PR #1793.
                current[pending_step] += "\n" + raw.rstrip("\n")
            continue
        match = STEP.search(raw)
        if not match:
            pending_step = None
            continue
        step, text = match.group(1), match.group(2).rstrip("\n")
        if step == "RAW ASR":
            if current:
                dictations.append(current)
            current = {"_time": stamp.group(1)}
        if not current:
            continue
        if text and text != "no change":
            current[step] = text
            pending_step = step
        else:
            pending_step = None
    if current:
        dictations.append(current)

    out = []
    for entry in dictations:
        final = None
        for step in ORDER:
            if entry.get(step):
                final = entry[step]
        if final and entry.get("_time"):
            out.append((datetime.fromisoformat(entry["_time"]), final.strip()))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--gap", type=float, default=45.0,
                    help="seconds between recordings to still count as one thought")
    ap.add_argument("--min-words", type=int, default=4)
    ap.add_argument("--out", default=None)
    ap.add_argument("logs", nargs="*",
                    default=[os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")])
    args = ap.parse_args()

    entries = []
    for path in args.logs:
        if os.path.exists(path):
            found = parse_log(path)
            print(f"{os.path.basename(path)}: {len(found)} dictations", file=sys.stderr)
            entries.extend(found)
    entries.sort(key=lambda e: e[0])
    print(f"total dictations: {len(entries)}", file=sys.stderr)

    pairs = []
    for (t1, first), (t2, second) in zip(entries, entries[1:]):
        gap = (t2 - t1).total_seconds()
        if gap <= 0 or gap > args.gap:
            continue
        if len(first.split()) < args.min_words or len(second.split()) < args.min_words:
            continue
        if first == second:  # a repeated test utterance, not a seam
            continue
        pairs.append({"rec1": first, "rec2": second, "gap_seconds": round(gap, 1),
                      "source": "founder_log", "language": "English"})

    print(f"real consecutive pairs within {args.gap:.0f}s: {len(pairs)}", file=sys.stderr)
    buckets = {"<10s": 0, "10-20s": 0, "20-45s": 0}
    for p in pairs:
        g = p["gap_seconds"]
        buckets["<10s" if g < 10 else "10-20s" if g < 20 else "20-45s"] += 1
    print(f"  by gap: {buckets}", file=sys.stderr)

    starts_capital = sum(1 for p in pairs if p["rec2"][:1].isupper())
    ends_terminal = sum(1 for p in pairs if p["rec1"].rstrip().endswith((".", "!", "?")))
    print(f"  second half starts with a capital : {starts_capital}/{len(pairs)} "
          f"({100*starts_capital/max(len(pairs),1):.1f}%)", file=sys.stderr)
    print(f"  first half ends with a terminator : {ends_terminal}/{len(pairs)} "
          f"({100*ends_terminal/max(len(pairs),1):.1f}%)", file=sys.stderr)

    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            for pair in pairs:
                handle.write(json.dumps(pair, ensure_ascii=False) + "\n")
        print(f"wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
