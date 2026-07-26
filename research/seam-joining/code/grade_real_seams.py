"""Label the REAL consecutive-recording pairs, cheaply and where it matters.

`extract_real_seams.py` produced 2,563 genuine pairs from the founder's logs.
They have no ground truth attached, and labelling all of them would be wasteful,
because the two directions of error are not equally important:

  wrong merge   two separate thoughts welded together. Silent, the user does not
                notice until they reread, and it is the disqualifying failure.
  missed join   we leave today's behaviour. Annoying, never damaging.

So grading is targeted. The default mode labels only the pairs the model chose
to MERGE, which measures the dangerous direction exactly and completely: every
one of those decisions is either correct or a wrong merge, with nothing in
between. A sample of the KEEP decisions estimates the other direction.

Each pair is graded blind: the grader never sees what the model decided, and the
two halves are presented as a person would have said them.

Routed through Bedrock so it spends existing credits rather than new money.
"""

import argparse
import json
import os
import random
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor

# The prompt is imported, never re-typed. `calibrate_grader.py` measured both
# variants against known labels: the obvious phrasing called 29 of 43 real
# sentence boundaries a join, which would have defined success as agreeing with
# a grader that over-merges two times in three. The strict variant gets that to
# 1 of 41. A copy of the text here would drift from the version that was
# measured, and the measurement is the only reason to trust it.
from calibrate_grader import LINKED as PROMPT  # noqa: E402

LABEL_FROM_WORD = {"SEPARATE": "KEEP", "JOIN": "MERGE_SPACE", "COMMA": "MERGE_COMMA"}


def grade_one(client, model, pair):
    """Return (label, failure). Never a silent None: a dropped answer that still
    counts toward a percentage is a fabricated result."""
    body = PROMPT.format(rec1=pair["rec1"].strip(), rec2=pair["rec2"].strip())
    for attempt in range(5):
        try:
            response = client.messages.create(
                model=model, max_tokens=8, temperature=0,
                messages=[{"role": "user", "content": body}])
        except Exception as exc:
            name = type(exc).__name__
            if "Throttl" in name or "TooManyRequests" in name or "429" in str(exc):
                time.sleep(1.5 * (attempt + 1))
                continue
            return None, f"api:{name}"
        text = response.content[0].text
        word = re.sub(r"[^A-Z]", "", text.upper())
        for key, label in LABEL_FROM_WORD.items():
            if word.startswith(key[:4]):
                return label, None
        return None, f"parse:{text.strip()[:24]!r}"
    return None, "api:throttled-out"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pairs", default=None, help="jsonl of real pairs")
    ap.add_argument("--limit", type=int, default=400)
    ap.add_argument("--predictions", default="",
                    help="model decisions; grade only the MERGE ones")
    ap.add_argument("--max-gap", type=float, default=25.0,
                    help="only pairs closer together than this are plausible seams")
    ap.add_argument("--model", default="us.anthropic.claude-haiku-4-5-20251001-v1:0")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    pairs_path = args.pairs or os.path.join(root, "data", "seam_real_founder.jsonl")
    out_path = args.out or os.path.join(root, "data", "seam_real_labelled.jsonl")

    rows = [json.loads(l) for l in open(pairs_path, encoding="utf-8")]
    rows = [r for r in rows if r["gap_seconds"] <= args.max_gap]

    # Targeting the dangerous direction requires knowing what the model decided,
    # and that only exists in a predictions file. Without one this shuffles and
    # samples, which measures BOTH directions weakly instead of the merge
    # direction completely — so say which one is happening rather than claiming
    # the targeted run and delivering the sample. Found by cloud review on
    # PR #1793.
    if args.predictions:
        decided = {}
        for line in open(args.predictions, encoding="utf-8"):
            row = json.loads(line)
            key = (row.get("rec1", ""), row.get("rec2", ""))
            decided[key] = row.get("prediction") or row.get("label")
        wanted = [r for r in rows
                  if str(decided.get((r.get("rec1", ""), r.get("rec2", "")), ""))
                  .startswith("MERGE")]
        if not wanted:
            print(f"no MERGE decisions found in {args.predictions}", file=sys.stderr)
            return 1
        rows = wanted
        print(f"grading the {len(rows)} pairs the model chose to MERGE "
              f"(the dangerous direction, measured completely)", file=sys.stderr)
    else:
        random.Random(1790).shuffle(rows)
        print(f"NO --predictions given: grading a random sample of "
              f"{min(args.limit, len(rows))} pairs, which measures both "
              f"directions weakly rather than the merge direction completely",
              file=sys.stderr)
    rows = rows[: args.limit]
    print(f"grading {len(rows)} real pairs (gap <= {args.max_gap:.0f}s)", file=sys.stderr)

    from anthropic import AnthropicBedrock

    client = AnthropicBedrock(
        aws_access_key=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        aws_region="us-east-1")

    # Write each answer AS IT ARRIVES, and say how far along it is. Holding
    # everything until the end meant a 20-minute run showed nothing, could not
    # be checked for progress, and would have lost every answer on a crash.
    graded, failures = [], []
    done = 0
    # Write to a SIDECAR and only move it into place once the run has
    # earned it. Opening the destination directly truncated the previous
    # labels the moment the run started, so a throttled or interrupted
    # rerun destroyed a complete label set and left a partial one behind —
    # and the "REFUSING to write" guard below fired far too late to help.
    # Found by cloud review on PR #1793.
    partial_path = out_path + ".partial"
    handle = open(partial_path, "w", encoding="utf-8")
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for pair, (label, failure) in zip(
                rows, pool.map(lambda p: grade_one(client, args.model, p), rows)):
            done += 1
            if failure or not label:
                failures.append(failure or "unknown")
            else:
                row = {**pair, "label": label, "label_source": "haiku_strict_blind"}
                graded.append(row)
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
                handle.flush()
            if done % 100 == 0:
                print(f"  {done}/{len(rows)} graded, {len(failures)} failed",
                      file=sys.stderr, flush=True)
    handle.close()

    if len(graded) < 0.9 * len(rows):
        from collections import Counter as _C
        print(f"REFUSING to write: only {len(graded)}/{len(rows)} answered "
              f"({dict(_C(failures).most_common(3))}); kept the previous "
              f"labels, partial run left at {partial_path}", file=sys.stderr)
        return 1

    # Earned it. Replacing in one step means the destination is either the
    # old complete set or the new complete set, never a half-written mix.
    os.replace(partial_path, out_path)

    from collections import Counter
    print(f"labelled {len(graded)}, failed {len(failures)}", file=sys.stderr)
    if failures:
        print(f"  failures: {dict(Counter(failures).most_common(3))}", file=sys.stderr)
    print(f"  {dict(Counter(r['label'] for r in graded))}", file=sys.stderr)
    print(f"wrote {out_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
