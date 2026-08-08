#!/usr/bin/env python3
"""Per-model Ollama speed+quality benchmark generator (#1950).

WHAT IS DIFFERENT FROM `run_ollama_type_b.py`, AND WHY IT IS NOT THAT SCRIPT.
That script is the #1914 A/B gate. It hard-refuses a model that does not report
the `thinking` capability, and it hard-codes `thinks=True` in the budget policy,
because both arms had to send the same budget for `think` to be the only
variable. Both are correct there and both are wrong here: this benchmark must
run EVERY model the app offers, thinking or not, each at the budget the shipped
app would actually give it. The request-shaping primitives are IMPORTED from it
rather than re-typed, so there is one implementation of the wire format
(`measure-with-the-real-tool-never-a-simulation`).

SHIPPED CONFIGURATION IS THE DEFAULT ARM. Per model, `/api/tags` decides:
a row listing `thinking` gets `think: "low"` and the 2048 floor; a row without
it gets no `think` key and the 256 floor. That is `LLMPolishStep.outputTokenPolicy`
plus `OllamaConnector.modelFacts` exactly (#1914). `--think-override` exists only
so the #1950 sub-finding — does `think: false` buy the 16x speed-up measured on
`qwen3:0.6b` without the #272 reasoning leak — can be measured as its own arm.
It is never the default, and a run that uses it is labelled in its own output.

PROMPTS ARE THE REAL ONES, PER MODEL. Ollama prompt routing is per model name
(`gemma` -> GemmaPromptBuilder, else OpenAIPromptBuilder, plus a weak-model
override), so prompts are rendered per model by `prompt_render`, which drives the
shipped `DefaultPromptPlanner`. Passing one model's prompts to another silently
measures the wrong prompt, so the prompt file's own model is recorded and
checked.

LANGUAGE IS DELIBERATELY ABSENT FROM THE PROMPT. `PromptBuildInput.language` is
non-nil only when the user has LOCKED a language in settings; on the shipped
default (auto) it is nil and the prompt carries no language hint. The
international cases are therefore run the way a default install runs them, which
is both the common path and the harder one.

WARM BEFORE TIMING, UNLOAD AFTER. The first request to a cold local model pays
its load time, which is a property of the disk, not the model's polish speed;
the shipped app warms models for the same reason. Each model is unloaded when its
run finishes so the next model does not compete for memory with a resident one —
without that, a 9 GB model measured after another 9 GB model measures the swap.

SINGLE-STREAM, per `ollama-operations.md` RULE: benchmark-ollama-must-match-production.

FAIL CLOSED. A model absent from `/api/tags`, a prompt file for the wrong model,
a corpus/prompt id mismatch, or an unreadable path exits nonzero before any
generation. A per-case error is recorded as an error record and counted, never
dropped — an empty response IS the result for models that produce them.

Usage:
  python3 scripts/eval/run_ollama_bench.py \
      --models llama3.2 mistral gemma2 \
      --corpus scripts/eval/corpus/ollama_bench_v1.jsonl \
      --prompts-dir scripts/eval/runs/ollama-bench-1950/prompts \
      --outdir scripts/eval/runs/ollama-bench-1950/candidates
"""
import argparse
import json
import sys
import time
from pathlib import Path

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_ollama_type_b import (  # noqa: E402
    OLLAMA_TAGS_URL,
    canonical_model_name,
    load_corpus,
    load_prompts,
    make_body,
    call_once,
    output_token_policy,
)

OLLAMA_CHAT_URL = "http://localhost:11434/api/chat"
# Mirrors LLMPolishStep.maxDuration: the shipped pipeline gives the whole polish
# step 15s, so a slower response is one the user would never receive. Recorded,
# not enforced as a socket timeout — an aborted request reports no duration, and
# "how slow" is half the question this benchmark answers.
PIPELINE_DEADLINE_MS = 15_000
WARMUP_PROMPT = "Fix the punctuation: hello there"


def model_facts(models: list[str]) -> dict[str, dict]:
    """`/api/tags` facts per model, mirroring `OllamaConnector.modelFacts` (#1914).

    `thinks` is three-state in the shipped connector — reported-true,
    reported-false, or NOT REPORTED — and the not-reported case takes the LARGER
    floor. Reproduced here rather than collapsed to a boolean, because collapsing
    it is the exact defect #1914's cloud review found.
    """
    resp = requests.get(OLLAMA_TAGS_URL, timeout=10)
    resp.raise_for_status()
    rows = resp.json().get("models")
    if not isinstance(rows, list):
        raise RuntimeError("/api/tags returned no models array")

    by_canonical = {}
    for row in rows:
        name = row.get("name")
        if isinstance(name, str):
            by_canonical[canonical_model_name(name)] = row

    facts: dict[str, dict] = {}
    for m in models:
        row = by_canonical.get(canonical_model_name(m))
        if row is None:
            raise RuntimeError(f"{m} is absent from /api/tags — pull it before benchmarking")
        caps = row.get("capabilities")
        thinks = (("thinking" in caps) if isinstance(caps, list) else None)
        details = row.get("details") or {}
        facts[m] = {
            "model": m,
            "isRemote": row.get("remote_host") not in (None, ""),
            "thinks": thinks,
            "sizeBytes": row.get("size"),
            "parameterSize": details.get("parameter_size"),
            "quantization": details.get("quantization_level"),
            "family": details.get("family"),
        }
    return facts


def shipped_think(thinks: bool | None) -> str | None:
    """Mirrors `LLMPolishStep.ollamaThinking`: `"low"` only when the daemon
    REPORTED the thinking capability; absent for reported-false and for
    not-reported alike."""
    return "low" if thinks is True else None


def unload(model: str) -> None:
    """Evict a resident model so the next one is measured on a quiet machine."""
    try:
        requests.post(OLLAMA_CHAT_URL, json={"model": model, "messages": [], "keep_alive": 0},
                      timeout=60)
    except Exception as e:  # noqa: BLE001 - unload failure is worth seeing, never fatal
        print(f"  warn: unload {model} failed: {e}", file=sys.stderr)


def warm(model: str, think, thinks: bool | None) -> str:
    """One untimed request, shaped exactly like the timed ones, so the timed
    cases do not pay model load and the warm request itself proves the model
    answers at all before 20 cases are spent on it."""
    body = make_body(model, WARMUP_PROMPT, "",
                     output_token_policy(len(WARMUP_PROMPT), thinks=(thinks is not False)), think)
    try:
        call_once(body)
        return "ok"
    except Exception as e:  # noqa: BLE001
        return f"warm_failed: {e}"


def run_model(model: str, facts: dict, cases: dict[str, str], prompts: dict[str, dict],
              think_override: str | None, out_path: Path) -> dict:
    thinks = facts["thinks"]
    think = shipped_think(thinks) if think_override is None else (
        None if think_override == "none" else (False if think_override == "false" else think_override))

    print(f"\n=== {model}  remote={facts['isRemote']}  thinks={thinks}  think_sent={think!r} ===",
          file=sys.stderr, flush=True)
    warm_status = warm(model, think, thinks)
    print(f"  warm: {warm_status}", file=sys.stderr, flush=True)

    ids = sorted(cases)
    records = []
    errors = 0
    t0 = time.monotonic()
    with open(out_path, "w") as f:
        for n, cid in enumerate(ids, 1):
            text = cases[cid]
            prompt = prompts[cid]
            # thinks is three-state; only reported-false takes the tight floor.
            max_tokens = output_token_policy(len(text), thinks=(thinks is not False))
            body = make_body(model, prompt["system"], prompt["user"], max_tokens, think)
            start = time.monotonic()
            try:
                content, done_reason, thinking_chars = call_once(body)
                rec = {
                    "id": cid, "model": model, "candidate": content,
                    "latencyMs": int((time.monotonic() - start) * 1000),
                    "doneReason": done_reason, "thinkingChars": thinking_chars,
                    "numPredict": max_tokens, "mode": prompt.get("mode"),
                }
            except Exception as e:  # noqa: BLE001 - the error text is the receipt
                errors += 1
                rec = {
                    "id": cid, "model": model, "candidate": "", "error": str(e),
                    "latencyMs": int((time.monotonic() - start) * 1000),
                    "numPredict": max_tokens, "mode": prompt.get("mode"),
                }
            records.append(rec)
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            f.flush()
            print(f"  {n}/{len(ids)} {cid} {rec['latencyMs']}ms"
                  + ("  ERROR" if rec.get("error") else ""), file=sys.stderr, flush=True)

    unload(model)
    elapsed = time.monotonic() - t0
    lat = sorted(r["latencyMs"] for r in records if not r.get("error"))
    over = sum(1 for x in lat if x > PIPELINE_DEADLINE_MS)
    return {
        **facts,
        "thinkSent": think,
        "thinkOverride": think_override,
        "warm": warm_status,
        "cases": len(ids),
        "errors": errors,
        "wallSeconds": round(elapsed, 1),
        "latencyMsMedian": lat[len(lat) // 2] if lat else None,
        "latencyMsMean": round(sum(lat) / len(lat)) if lat else None,
        "latencyMsMax": lat[-1] if lat else None,
        "overDeadline": over,
        "candidates": str(out_path),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True, nargs="+")
    ap.add_argument("--corpus", required=True, type=Path)
    ap.add_argument("--prompts-dir", required=True, type=Path,
                    help="directory of <model-slug>.jsonl prompt files from prompt_render")
    ap.add_argument("--outdir", required=True, type=Path)
    ap.add_argument("--think-override", choices=["none", "false", "low", "high"], default=None,
                    help="EXPERIMENT ARM ONLY: force a think value for every model, "
                         "overriding the shipped per-capability rule")
    ap.add_argument("--suffix", default="", help="appended to each candidate filename")
    args = ap.parse_args()

    facts = model_facts(args.models)  # raises before any generation on an absent model
    cases = load_corpus(args.corpus)
    args.outdir.mkdir(parents=True, exist_ok=True)

    summaries = []
    for m in args.models:
        slug = m.replace(":", "-").replace(".", "-").replace("/", "-")
        prompt_path = args.prompts_dir / f"{slug}.jsonl"
        if not prompt_path.exists():
            print(f"FAIL: no prompt file for {m} at {prompt_path}", file=sys.stderr)
            return 2
        prompts = load_prompts(prompt_path)
        missing = sorted(set(cases) - set(prompts))
        if missing:
            print(f"FAIL: {m}: prompts missing for {len(missing)} case(s): {missing[:5]}",
                  file=sys.stderr)
            return 2
        out_path = args.outdir / f"{slug}{args.suffix}.jsonl"
        summaries.append(run_model(m, facts[m], cases, prompts, args.think_override, out_path))

    summary_path = args.outdir / f"run-summary{args.suffix}.json"
    with open(summary_path, "w") as f:
        json.dump({"corpus": str(args.corpus), "thinkOverride": args.think_override,
                   "models": summaries}, f, indent=2)
    print(f"\nwrote {len(summaries)} model summaries to {summary_path}", file=sys.stderr)

    total_errors = sum(s["errors"] for s in summaries)
    print(f"total per-case errors: {total_errors}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
