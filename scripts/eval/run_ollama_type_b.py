#!/usr/bin/env python3
"""Generate Type B candidates from a LOCAL Ollama model, mirroring the shipped
`OllamaConnector.makeRequestBody` request shape exactly, with the ONE variable
under test exposed as a flag: the `think` key (#1914).

This is the A/B generator for the #1914 polish-quality gate. The two arms are:

  --think none   pre-#1914 runtime: the `think` key is ABSENT entirely, so
                 Ollama applies the model's own default thinking depth.
  --think low    post-#1914 runtime: top-level `think: "low"` for a model whose
                 `/api/tags` row reports the `thinking` capability.

Everything else is identical between arms, which is what makes the comparison
attributable. `think: false` is NEVER sent on either arm — it is honoured by
some models and silently ignored by others (#272), so it is not a control.

PROMPT FIDELITY. The system/user messages are NOT rebuilt here. They are read
from a JSONL produced by `prompt_render` (`--provider ollama --model <m>`),
which drives the shipped `DefaultPromptPlanner`, so the prompt is the real one
including the per-case inline/message/structured mode. Ollama takes the
`polish(envelope:)` path in `LLMPolishStep`, so the connector's weak-model
system-prompt override does NOT apply and is correctly absent here.

BUDGET FIDELITY. `num_predict` mirrors `LLMPolishStep.outputTokenPolicy`:
`max(textCount / 3 + 100, floor)`, floor 2048 for a thinking model
(`LLMConstants.ollamaThinkingMaxTokens`) and 256 otherwise
(`ollamaMaxTokens`). Both #1914 arms use the same floor for the same model, so
the budget is held constant and only `think` varies.

SCORING IS NAKED. The candidate is the raw `message.content`, trimmed, with no
`strippingLLMPreamble()` and no deterministic post-steps. Both arms are treated
identically, and leaving the text naked is the conservative choice: if an arm
leaks reasoning or a wrapper into the content, that is a real user-visible
difference the gate should see rather than launder.

SINGLE-STREAM per `ollama-operations.md`
RULE: benchmark-ollama-must-match-production — concurrency adds latency and
heat and would corrupt the latency half of the receipt.

ERROR ACCOUNTING. A pair is candidate-identical only when both records have no
`error` and their candidates are byte-identical. A baseline error followed by
a successful low-level response enters the judge set. A successful baseline
followed by a low-level error is a regression. Errors in both arms are unchanged
failures, never evidence of unchanged output quality.

THE PRODUCTION DEADLINE IS ENFORCED AT ANALYSIS TIME, NOT AS A SOCKET TIMEOUT.
The shipped pipeline gives the whole polish step 15s, so a slower response is
one the user would never receive. This runner still waits, and records the true
`latencyMs`, because a hard socket timeout destroys the measurement that decides
the question: an aborted request reports no duration, so a 16s response and a
120s response become the same unusable record. `compare_ab.py` applies the 15s
rule uniformly to every arm. Keeping the network bound generous also keeps arms
comparable when the rule changes, which a mid-run timeout edit would not.

Usage:
  python3 scripts/eval/run_ollama_type_b.py \\
    --model qwen3:0.6b --think low \\
    --corpus scripts/eval/corpus/type_b_parakeet.jsonl \\
    --prompts scripts/eval/runs/ollama-1914-ab/prompts-qwen3-0-6b.jsonl \\
    --out scripts/eval/runs/ollama-1914-ab/qwen3-0-6b-low.jsonl
"""
import argparse
import json
import sys
import time
from pathlib import Path

import requests

OLLAMA_URL = "http://localhost:11434/api/chat"
OLLAMA_TAGS_URL = "http://localhost:11434/api/tags"
PIPELINE_DEADLINE_SECONDS = 15.0
# Mirrors LLMConstants.ollamaMaxTokens / ollamaThinkingMaxTokens.
OLLAMA_MAX_TOKENS = 256
OLLAMA_THINKING_MAX_TOKENS = 2048
# Mirrors LLMProviderConfig(temperature: 0) at the LLMPolishStep call site.
TEMPERATURE = 0.0


def load_corpus(path: Path) -> dict[str, str]:
    cases: dict[str, str] = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            text = d.get("asr_input") or d.get("input")
            if not text:
                raise ValueError(f"case {d.get('id')} has no asr_input/input")
            cases[d["id"]] = text
    return cases


def load_prompts(path: Path) -> dict[str, dict]:
    prompts: dict[str, dict] = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            prompts[d["id"]] = d
    return prompts


def canonical_model_name(name: str) -> str:
    return name[:-7] if name.endswith(":latest") else name


def require_thinking_model(model: str, allow_hosted: bool) -> None:
    """Guards the gate against being run on the wrong model.

    Hosted is refused BY DEFAULT and needs an explicit `--allow-hosted`, because
    a hosted run consumes the founder's Ollama allowance and that is a decision,
    never an accident. The thinking-capability requirement is not waivable: on a
    model that does not report `thinking`, both arms send the same request and
    the A/B is vacuous by construction.
    """
    resp = requests.get(OLLAMA_TAGS_URL, timeout=5)
    resp.raise_for_status()
    rows = resp.json().get("models")
    if not isinstance(rows, list):
        raise RuntimeError("/api/tags returned no models array")

    target = canonical_model_name(model)
    matched = next(
        (
            row
            for row in rows
            if isinstance(row.get("name"), str)
            and canonical_model_name(row["name"]) == target
        ),
        None,
    )
    if matched is None:
        raise RuntimeError(f"{model} is absent from /api/tags")

    is_hosted = matched.get("remote_host") not in (None, "")
    if is_hosted and not allow_hosted:
        raise RuntimeError(f"{model} is hosted, not local; pass --allow-hosted to run it deliberately")

    capabilities = matched.get("capabilities")
    if not isinstance(capabilities, list) or "thinking" not in capabilities:
        raise RuntimeError(f"{model} does not report the thinking capability")


def output_token_policy(text_count: int, thinks: bool) -> int:
    """Mirrors LLMPolishStep.outputTokenPolicy for `.ollama`."""
    floor = OLLAMA_THINKING_MAX_TOKENS if thinks else OLLAMA_MAX_TOKENS
    return max(text_count // 3 + 100, floor)


def make_body(model: str, system: str, user: str, max_tokens: int, think: str | None) -> dict:
    """Mirrors OllamaConnector.makeRequestBody. `think` is a TOP-LEVEL key on
    /api/chat, never an `options` entry, and is omitted entirely when None."""
    messages = [{"role": "system", "content": system}]
    if user:
        messages.append({"role": "user", "content": user})
    body: dict = {
        "model": model,
        "messages": messages,
        "stream": False,
        "keep_alive": "60m",
        "options": {
            "num_predict": max_tokens,
            "temperature": TEMPERATURE,
        },
    }
    if think is not None:
        body["think"] = think
    return body


def call_once(body: dict) -> tuple[str, str, int]:
    """Returns (content, done_reason, thinking_chars). Raises on a shape the
    shipped connector would reject."""
    resp = requests.post(OLLAMA_URL, json=body, timeout=180)
    if resp.status_code != 200:
        raise RuntimeError(f"HTTP {resp.status_code}: {resp.text[:300]}")
    data = resp.json()
    message = data.get("message")
    if not isinstance(message, dict):
        raise RuntimeError("no message object in response")
    content = message.get("content")
    if not isinstance(content, str) or not content:
        # Mirrors the connector's `!content.isEmpty` guard -> LLMError.emptyResponse.
        raise RuntimeError(f"empty response (done_reason={data.get('done_reason')})")
    thinking_chars = len(message.get("thinking") or "")
    return content.strip(), str(data.get("done_reason")), thinking_chars


def polish_case(model: str, case_id: str, text: str, prompt: dict, think: str | None) -> dict:
    max_tokens = output_token_policy(len(text), thinks=True)
    body = make_body(model, prompt["system"], prompt["user"], max_tokens, think)
    start = time.monotonic()
    try:
        content, done_reason, thinking_chars = call_once(body)
        return {
            "id": case_id,
            "candidate": content,
            "latencyMs": int((time.monotonic() - start) * 1000),
            "doneReason": done_reason,
            "thinkingChars": thinking_chars,
            "numPredict": max_tokens,
            "mode": prompt.get("mode"),
        }
    except Exception as e:  # noqa: BLE001 - the error text is the receipt
        return {
            "id": case_id,
            "candidate": "",
            "error": str(e),
            "latencyMs": int((time.monotonic() - start) * 1000),
            "numPredict": max_tokens,
            "mode": prompt.get("mode"),
        }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help="Ollama model tag, e.g. qwen3:0.6b")
    ap.add_argument(
        "--think",
        required=True,
        choices=["none", "low"],
        help="none = pre-#1914 (key absent); low = post-#1914",
    )
    ap.add_argument("--corpus", required=True, type=Path)
    ap.add_argument("--prompts", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--limit", type=int, default=0, help="first N cases only (subset smoke)")
    ap.add_argument(
        "--allow-hosted",
        action="store_true",
        help="permit a model that runs on Ollama's servers; consumes the account allowance",
    )
    args = ap.parse_args()

    think = None if args.think == "none" else "low"

    try:
        require_thinking_model(args.model, allow_hosted=args.allow_hosted)
    except Exception as error:  # noqa: BLE001
        print(f"FAIL: invalid gate model: {error}", file=sys.stderr)
        return 2

    cases = load_corpus(args.corpus)
    prompts = load_prompts(args.prompts)
    missing = [cid for cid in cases if cid not in prompts]
    if missing:
        print(
            f"ERROR: {len(missing)} corpus cases have no rendered prompt "
            f"(first: {missing[:3]}). Re-run prompt_render for this model.",
            file=sys.stderr,
        )
        return 2

    ids = list(cases)
    if args.limit:
        ids = ids[: args.limit]

    # Warm the model before measuring, per RULE: benchmark-ollama-must-match-production.
    warm = make_body(args.model, "You are a helpful assistant.", "hi", 1, think)
    try:
        requests.post(OLLAMA_URL, json=warm, timeout=300)
    except Exception as e:  # noqa: BLE001
        print(f"WARNING: warm-up failed: {e}", file=sys.stderr)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    errors = 0
    t0 = time.monotonic()
    with open(args.out, "w") as f:
        for n, cid in enumerate(ids, 1):
            rec = polish_case(args.model, cid, cases[cid], prompts[cid], think)
            if rec.get("error"):
                errors += 1
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            f.flush()
            if n % 50 == 0 or n == len(ids):
                rate = n / max(time.monotonic() - t0, 1e-9)
                print(
                    f"{n}/{len(ids)}  errors={errors}  {rate:.2f} case/s  "
                    f"eta={(len(ids) - n) / max(rate, 1e-9) / 60:.1f}min",
                    file=sys.stderr,
                    flush=True,
                )

    print(
        f"wrote {len(ids)} records to {args.out} "
        f"(model={args.model} think={args.think} errors={errors})",
        file=sys.stderr,
    )
    if errors:
        print(
            f"FAIL: {errors} records contain no candidate",
            file=sys.stderr,
        )
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
