"""Score the v3 seam joiner against the generated corpus.

Reports, per corruption combination and per split kind:
  * merge DECISION accuracy - did it merge exactly when it should have
  * EXACT MATCH to the original dictation, which is the real bar
  * the proper-noun subset, where gold keeps a capital at the seam

Baseline is today's behaviour: paste the takes with a space and change nothing.

Inference is batched because the corpus is thousands of cases and the model
takes a list.
"""

import json
import re
import statistics
import sys
import time
from collections import defaultdict

from punctuators.models.punc_cap_seg_model import (
    PunctCapSegConfigONNX,
    PunctCapSegModelONNX,
)

MODEL_DIR = (
    "/private/tmp/claude-501/-Users-m4pro-sv-Developer-EnviousLabs-EnviousWispr/"
    "73bf0faa-2e60-4b76-9576-81465f742796/scratchpad/model_47lang"
)
TERMINATORS = (".", "!", "?")
LEAD = "we agreed that"
BATCH = 256


def strip_punct(text):
    return re.sub(r"\s+", " ", re.sub(r"[.,?;!]", " ", text.lower())).strip()


def batched(model, probes):
    out = []
    for i in range(0, len(probes), BATCH):
        out.extend(model.infer(probes[i : i + BATCH]))
    return out


def main():
    limit = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    cases = [json.loads(l) for l in open("seam_corpus.jsonl")]
    if limit:
        # Deterministic stride so the sample spans the whole corpus.
        cases = cases[:: max(1, len(cases) // limit)][:limit]
    print(f"scoring {len(cases)} cases", file=sys.stderr)

    cfg = PunctCapSegConfigONNX(
        directory=MODEL_DIR,
        spe_filename="spe_unigram_64k_lowercase_47lang.model",
        model_filename="punct_cap_seg_47lang.onnx",
        config_filename="config.yaml",
    )
    model = PunctCapSegModelONNX(cfg)
    model.infer(["warmup"])

    start = time.perf_counter()

    # Only takes following a terminated left context need the fragment probe;
    # an unterminated left context is a certain merge and costs no inference.
    needs_probe = [c for c in cases if c["left"].rstrip().endswith(TERMINATORS)]
    stands_alone = {}
    if needs_probe:
        outs = batched(model, [strip_punct(c["right"]) for c in needs_probe])
        for c, o in zip(needs_probe, outs):
            first = o[0].strip() if o else ""
            stands_alone[c["id"]] = bool(first) and first.endswith(TERMINATORS)

    # Mid-sentence casing for every take that might get merged.
    case_outs = batched(model, [f"{LEAD} {strip_punct(c['right'])}" for c in cases])
    lead_n = len(LEAD.split())
    mid_case = {}
    for c, o in zip(cases, case_outs):
        words = " ".join(o).split()
        mid_case[c["id"]] = words[lead_n] if len(words) > lead_n else None

    elapsed = time.perf_counter() - start

    stats = defaultdict(lambda: {"n": 0, "decision": 0, "exact": 0, "base_exact": 0})
    proper = {"n": 0, "kept": 0}

    for c in cases:
        left, right = c["left"], c["right"]
        terminated = left.rstrip().endswith(TERMINATORS)
        merged = True if not terminated else not stands_alone.get(c["id"], True)

        if merged:
            out_left = re.sub(r"\.\s*$", "", left)
            words = right.split()
            cased = mid_case.get(c["id"])
            if words and cased:
                words[0] = (
                    cased if cased[:1].isupper() else words[0][0].lower() + words[0][1:]
                )
                right_out = " ".join(words)
            else:
                right_out = right
            got = f"{out_left} {right_out}"
        else:
            got = f"{left} {right}"

        today = c["today"]
        key = (c["kind"], c["add_period"], c["capitalise"])
        s = stats[key]
        s["n"] += 1
        s["decision"] += int(merged == c["should_merge"])
        s["exact"] += int(got.strip() == c["gold"].strip())
        s["base_exact"] += int(today.strip() == c["gold"].strip())

        # Proper-noun subset: gold keeps a capital at the seam.
        gold_words = c["gold"].split()
        idx = len(c["left"].split())
        if c["should_merge"] and idx < len(gold_words) and gold_words[idx][:1].isupper():
            proper["n"] += 1
            proper["kept"] += int(got.strip() == c["gold"].strip())

    tot = sum(s["n"] for s in stats.values())
    dec = sum(s["decision"] for s in stats.values())
    ex = sum(s["exact"] for s in stats.values())
    base = sum(s["base_exact"] for s in stats.values())

    print(f"\n{'kind':20} {'per':4} {'cap':4} {'n':>6} {'decision':>9} {'exact':>8} {'today':>8}")
    print("-" * 66)
    for key in sorted(stats):
        kind, per, cap = key
        s = stats[key]
        print(
            f"{kind:20} {str(per)[:1]:4} {str(cap)[:1]:4} {s['n']:6} "
            f"{100*s['decision']/s['n']:8.1f}% {100*s['exact']/s['n']:7.1f}% "
            f"{100*s['base_exact']/s['n']:7.1f}%"
        )
    print("-" * 66)
    print(f"{'TOTAL':30} {tot:6} {100*dec/tot:8.1f}% {100*ex/tot:7.1f}% {100*base/tot:7.1f}%")
    if proper["n"]:
        print(
            f"\nproper noun at seam (gold keeps the capital): "
            f"{proper['kept']}/{proper['n']} = {100*proper['kept']/proper['n']:.1f}%"
        )
    print(f"\ninference: {elapsed:.1f}s for {len(cases)} cases "
          f"= {1000*elapsed/len(cases):.1f}ms per case")
    return 0


if __name__ == "__main__":
    sys.exit(main())
