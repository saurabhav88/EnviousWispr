#!/usr/bin/env python3
"""Benchmark: does batching the judge in chunks of 20 attenuate scores vs chunks of 10?

Usage:  python3 scripts/eval/chunk_size_benchmark.py
Output: benchmark-results/eval/chunk-size/<ts>/report.json + stdout summary.

Polish model: gpt-4o-mini (cheap, standard production polish path).
Judge model:  gemini-3-pro-preview (thinking, cross-family vs the polish).

Reads scripts/eval/corpus/ci_corpus.jsonl.
The polish prompt is a realistic FIXTURE, not a production-faithful render — see the
POLISH_SYSTEM note below for exactly how it differs and why that does not affect what
this benchmark measures.
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime
from statistics import mean

ROOT = Path(__file__).parent.parent.parent.resolve()
CORPUS = ROOT / "scripts/eval/corpus/ci_corpus.jsonl"
OUT_DIR = ROOT / "benchmark-results/eval/chunk-size"
OPENAI_KEY = Path(os.path.expanduser("~/.enviouswispr-keys/openai-api-key")).read_text().strip()
GEMINI_KEY = Path(os.path.expanduser("~/.enviouswispr-keys/gemini-api-key")).read_text().strip()

POLISH_MODEL = "gpt-4o-mini"
JUDGE_MODEL = "gemini-3-pro-preview"

# --- Polish prompt: a realistic FIXTURE, deliberately not a production render ---
#
# #1948 first: this was a hand-copied mirror of `OpenAIPromptBuilder`'s `.inline` prompt,
# deleted with the `.openAIProse` family, so the copy became a mirror of nothing — the
# stale-generated-file trap in `self-review-and-grep-before-codex`.
#
# #1948 second (cloud review, PR #1971): replacing it with the tracked v6 artifact still does
# NOT reproduce `CloudFixedPromptBuilder.build`, and the docstring above used to claim it did.
# Production additionally prepends an unconditional language/script-preservation instruction
# and appends a short-input guard at `wordCount <= 10` — which fires on **71 of the 161**
# `ci_corpus` cases (44%, verified). So the candidates generated here are not byte-identical
# to what a user would get.
#
# Left as a fixture rather than mirrored, on purpose. This benchmark measures JUDGE CHUNK
# SIZE: it scores the SAME candidate set at chunk 10 and chunk 20 and compares the two, so
# the attenuation it reports is a property of the judge, and both arms share whatever prompt
# produced the candidates. Adding a third Python mirror of a Swift prompt would create exactly
# the sync obligation (`polish-eval.md` RULE: manual-swift-python-sync) whose failure produced
# the stale copy above. The honest fix was the CLAIM, not the prompt.
#
# If this file is ever repurposed to judge production polish QUALITY rather than judge
# chunking, that reasoning stops holding: render through `scripts/eval/prompt_render`, which
# drives the shipped `DefaultPromptPlanner`.
POLISH_SYSTEM = (
    (ROOT / "scripts/eval/prompts/cloud-fixed-polish-prompt-v6.txt").read_text().rstrip("\n")
)

# Plain user message, no sandwich: the fixed cloud prompt carries its own anti-instruction
# framing and #1255 removed the wrapper because models echoed the tags into their output.
POLISH_USER_TEMPLATE = """Transcript to clean:

{transcript}"""


# --- Judge prompt (tight, JSON-only output) ---
JUDGE_SYSTEM = """You are a polish evaluation judge. Score each candidate polish on 5 integer axes (0-3).

AXES:
- accuracy: meaning + named entities preserved (3=perfect, 0=lost/hallucinated)
- conciseness: fillers removed, no over/under-editing (3=right amount, 0=way off)
- fluency: grammar + natural flow (3=fluent, 0=broken)
- format: no preamble, clean output only (3=clean, 0=adds "Here's..." or similar)
- regression_vs_baseline: 0=worse than baseline, 1=similar, 2=slightly better, 3=clearly better

OUTPUT: JSON array ONLY. No preamble. No markdown fences. No trailing text.
Each item: {"id":"<case_id>","accuracy":N,"conciseness":N,"fluency":N,"format":N,"regression":N,"reasoning":"<one sentence, 15 words max>"}

RULES:
- Integer 0-3 only. Never 0.5, never 4.
- reasoning: ONE sentence, 15 words max. Never "Let me analyze..." or "First,..."
- Output the JSON array and nothing else."""


def call_openai(model: str, system: str, user: str) -> str:
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": 0,
    }
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={
            "Authorization": f"Bearer {OPENAI_KEY}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.loads(resp.read())
    return data["choices"][0]["message"]["content"].strip()


def call_gemini(model: str, system: str, user: str) -> str:
    body = {
        "systemInstruction": {"parts": [{"text": system}]},
        "contents": [{"role": "user", "parts": [{"text": user}]}],
        "generationConfig": {"temperature": 0, "responseMimeType": "application/json"},
    }
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={GEMINI_KEY}"
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"}, method="POST",
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        data = json.loads(resp.read())
    parts = data["candidates"][0]["content"]["parts"]
    return "".join(p.get("text", "") for p in parts).strip()


def polish_case(case: dict) -> str:
    user = POLISH_USER_TEMPLATE.format(transcript=case["asr_input"])
    return call_openai(POLISH_MODEL, POLISH_SYSTEM, user)


def judge_chunk(cases_with_output: list[dict]) -> list[dict]:
    """cases_with_output: list of {id, asr_input, candidate, baseline}. Returns list of scored items."""
    items = [
        {
            "id": c["id"],
            "asr_input": c["asr_input"],
            "candidate": c["candidate"],
            "baseline": c["baseline"],
        }
        for c in cases_with_output
    ]
    user = "Score these items:\n" + json.dumps(items, ensure_ascii=False)
    raw = call_gemini(JUDGE_MODEL, JUDGE_SYSTEM, user)
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"  WARN: judge returned non-JSON, attempting fence strip", file=sys.stderr)
        raw_clean = raw.strip().lstrip("`").rstrip("`")
        if raw_clean.lower().startswith("json"):
            raw_clean = raw_clean[4:].strip()
        parsed = json.loads(raw_clean)
    if isinstance(parsed, dict):  # sometimes wrapped
        for key in ("items", "scores", "results", "cases"):
            if key in parsed and isinstance(parsed[key], list):
                parsed = parsed[key]
                break
    return parsed


def chunked(seq, size):
    for i in range(0, len(seq), size):
        yield seq[i : i + size]


def main():
    cases = [json.loads(l) for l in CORPUS.read_text().splitlines() if l.strip()]
    print(f"Loaded {len(cases)} cases from {CORPUS}")

    # Stage 1: polish all cases (once, cached for both chunk runs)
    print(f"\n[1/3] Polishing {len(cases)} cases via {POLISH_MODEL}...")
    polish_start = time.time()
    polished = []
    for i, case in enumerate(cases, 1):
        try:
            candidate = polish_case(case)
        except Exception as e:
            print(f"  {i}/{len(cases)}  {case['id']}  POLISH-ERROR: {e}", file=sys.stderr)
            candidate = ""
        polished.append({**case, "candidate": candidate, "baseline": case["expected_output"]})
        if i % 10 == 0:
            print(f"  {i}/{len(cases)} polished  (elapsed {time.time()-polish_start:.1f}s)")
    print(f"Polish done in {time.time()-polish_start:.1f}s")

    # Stage 2: judge at chunk size 10
    print(f"\n[2/3] Judging in chunks of 10 ({len(cases)//10} calls) via {JUDGE_MODEL}...")
    scores_10: dict[str, dict] = {}
    t = time.time()
    for i, chunk in enumerate(chunked(polished, 10), 1):
        try:
            results = judge_chunk(chunk)
            for r in results:
                scores_10[r["id"]] = r
            print(f"  chunk {i}/{len(cases)//10}  scored {len(results)} cases  (elapsed {time.time()-t:.1f}s)")
        except Exception as e:
            print(f"  chunk {i} FAILED: {e}", file=sys.stderr)
    print(f"Chunk-10 done in {time.time()-t:.1f}s")

    # Stage 3: judge at chunk size 20
    print(f"\n[3/3] Judging in chunks of 20 ({len(cases)//20} calls) via {JUDGE_MODEL}...")
    scores_20: dict[str, dict] = {}
    t = time.time()
    for i, chunk in enumerate(chunked(polished, 20), 1):
        try:
            results = judge_chunk(chunk)
            for r in results:
                scores_20[r["id"]] = r
            print(f"  chunk {i}/{len(cases)//20}  scored {len(results)} cases  (elapsed {time.time()-t:.1f}s)")
        except Exception as e:
            print(f"  chunk {i} FAILED: {e}", file=sys.stderr)
    print(f"Chunk-20 done in {time.time()-t:.1f}s")

    # Analysis
    ts = datetime.utcnow().strftime("%Y-%m-%dT%H%M%S")
    out = OUT_DIR / ts
    out.mkdir(parents=True, exist_ok=True)
    (out / "scores_10.json").write_text(json.dumps(scores_10, indent=2))
    (out / "scores_20.json").write_text(json.dumps(scores_20, indent=2))
    (out / "polished.jsonl").write_text("\n".join(json.dumps(p) for p in polished))

    common_ids = set(scores_10) & set(scores_20)
    missing_in_10 = set(scores_20) - set(scores_10)
    missing_in_20 = set(scores_10) - set(scores_20)

    axes = ("accuracy", "conciseness", "fluency", "format", "regression")
    identical, diverged = 0, 0
    diffs: list[dict] = []
    per_axis_deltas = {a: [] for a in axes}
    for cid in common_ids:
        s10 = scores_10[cid]
        s20 = scores_20[cid]
        same = all(s10.get(a) == s20.get(a) for a in axes)
        if same:
            identical += 1
        else:
            diverged += 1
            diffs.append({
                "id": cid,
                "chunk10": {a: s10.get(a) for a in axes},
                "chunk20": {a: s20.get(a) for a in axes},
            })
        for a in axes:
            if s10.get(a) is not None and s20.get(a) is not None:
                per_axis_deltas[a].append(s20[a] - s10[a])

    total = len(common_ids)
    pct_identical = 100 * identical / total if total else 0
    report = {
        "timestamp": ts,
        "polish_model": POLISH_MODEL,
        "judge_model": JUDGE_MODEL,
        "total_cases": len(cases),
        "scored_both": total,
        "missing_in_10": sorted(missing_in_10),
        "missing_in_20": sorted(missing_in_20),
        "identical_scores": identical,
        "diverged_scores": diverged,
        "pct_identical": round(pct_identical, 1),
        "per_axis_mean_delta_20_minus_10": {
            a: round(mean(per_axis_deltas[a]), 3) if per_axis_deltas[a] else None for a in axes
        },
        "diffs": diffs[:20],  # cap for readability
    }
    (out / "report.json").write_text(json.dumps(report, indent=2))

    print("\n=== CHUNK SIZE BENCHMARK ===")
    print(f"Scored in both:  {total}")
    print(f"Identical:       {identical} ({pct_identical:.1f}%)")
    print(f"Diverged:        {diverged}")
    print(f"Missing in 10:   {len(missing_in_10)}  in 20: {len(missing_in_20)}")
    print(f"\nPer-axis mean delta (chunk20 minus chunk10):")
    for a in axes:
        v = report["per_axis_mean_delta_20_minus_10"][a]
        print(f"  {a:<22}  {v if v is not None else 'n/a'}")
    print(f"\nDecision rule: pct_identical >= 95% → use 20; else use 10.")
    print(f"Result:          {'USE 20' if pct_identical >= 95 else 'USE 10'}")
    print(f"\nFull report: {out/'report.json'}")


if __name__ == "__main__":
    main()
