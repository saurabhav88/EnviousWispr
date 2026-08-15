#!/usr/bin/env python3
"""Generate Type B candidates from OpenAI / Gemini using the EXACT shipped
production request shape. Sibling of `run_claude_type_b.py` (Anthropic).

Why this exists: `acceptance_gate.py`'s `call_openai`/`call_gemini` are the
gpt-4o-mini-era shape — they send `temperature: 0` with no thinking field. That
is NOT what production sends to a reasoning-shape OpenAI id (which omits
temperature and carries `reasoning_effort`) nor to a Gemini 3.x id (which
carries `thinkingLevel`). Scoring a model through the wrong shape measures a
configuration we do not ship. The one-off generator that produced the #1199
gemini35flash / gpt54mini runs was gitignored and is gone, so this is its
faithful, auditable replacement.

Mirrored authorities (verified 2026-08-01, cite before changing):
  - System prompt composition ....... acceptance_gate.build_cloud_fixed_system
                                      (itself the mirror of
                                      CloudFixedPromptBuilder.build, with a
                                      `--mode selftest` drift guard)
  - User message ................... CloudFixedPromptBuilder.swift:66
                                     "Transcript to clean:\\n\\n<transcript>"
  - OpenAI body .................... OpenAIConnector.makeRequestBody
                                     (model/messages/store:false;
                                     max_completion_tokens omitted because
                                     LLMPolishStep.outputTokenPolicy returns
                                     .providerDefault for .openAI;
                                     temperature omitted for reasoning ids;
                                     reasoning_effort from thinkingControl)
  - Gemini body .................... GeminiConnector.makeGenerationConfig +
                                     makeRequestBody (systemInstruction /
                                     contents without a role / temperature 0 /
                                     thinkingConfig dialect per model)
  - Capability resolution .......... LLMModelCapabilities.modelCapabilities
                                     + geminiThinkingControl (EXACT ids, never
                                     prefixes — an unlisted id sends NO
                                     thinking field, same as Swift)
  - Output post-processing ......... acceptance_gate._strip_llm_preamble_python
                                     with strip_transcript_tags=False (cloud is
                                     the no-sandwich fixed-prompt path)

The resolved request shape is PRINTED as a receipt before any spend, so the
configuration under test is auditable rather than assumed.

Usage:
  ~/.claude/bin/get-key launch openai-api-key OPENAI_API_KEY -- \\
    python3 scripts/eval/run_cloud_type_b.py \\
      --provider openai --model gpt-5.6-luna \\
      --corpus scripts/eval/corpus/type_b_parakeet.jsonl \\
      --out scripts/eval/runs/type-b-luna/candidates.jsonl

Score the result with the SAME judge every other arm of the comparison used. That is
the harness default (`azure/gpt-5-6-luna` since 2026-08-11), unless you are extending
an older Sonnet-graded set, in which case pass `--judge claude-sonnet-5` and re-grade
the whole set rather than mixing:
  python3 scripts/eval/behavior_judge.py --system new \\
    --corpus scripts/eval/corpus/type_b_parakeet.jsonl \\
    --candidates <out> --out <run-dir>/scores
"""
from __future__ import annotations

import argparse
import http.client
import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/eval"))

from acceptance_gate import (  # noqa: E402
    _key,
    _selftest_mirrors,
    _strip_llm_preamble_python,
    build_cloud_fixed_system,
)

OPENAI_URL = "https://api.openai.com/v1/chat/completions"
GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={key}"
ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
ANTHROPIC_VERSION = "2023-06-01"
# Mirrors LLMConstants.claudeMaxOutputTokens (#1710): the Anthropic API
# requires max_tokens, and the app sends this fixed generous value.
CLAUDE_MAX_OUTPUT_TOKENS = 8192
RETRYABLE = {408, 429, 500, 502, 503, 504, 529}
MAX_ATTEMPTS = 4


# --- Capability mirror (LLMModelCapabilities.swift) -------------------------

def openai_capabilities(model: str) -> dict:
    """Mirror of LLMProvider.openAI.modelCapabilities. Returns the two facts
    that shape the body: whether temperature is sent, and the reasoning_effort
    value for the Deep-reasoning toggle in its default OFF position."""
    mid = model.lower()
    is_chat_variant = "-chat" in mid
    is_reasoning = (
        mid.startswith("o1")
        or mid.startswith("o3")
        or mid.startswith("o4")
        or (mid.startswith("gpt-5") and not is_chat_variant)
    )
    is_responses_only = "codex" in mid or "-pro" in mid
    return {
        # .effort(fast: "low", deep: "medium") — fast is the shipped default.
        "reasoning_effort": "low" if is_reasoning else None,
        "send_temperature": not is_reasoning,
        "supports_chat_completions": not is_responses_only,
    }


# EXACT ids, never prefixes — mirrors geminiThinkingControl's deliberate design.
# An id absent from this table sends NO thinking field, exactly as Swift does.
GEMINI_THINKING_FAST = {
    "gemini-3.6-flash": ("thinkingLevel", "minimal"),
    "gemini-3.5-flash": ("thinkingLevel", "minimal"),
    "gemini-3.5-flash-lite": ("thinkingLevel", "minimal"),
    "gemini-3.1-flash-lite": ("thinkingLevel", "minimal"),
    "gemini-3.1-flash-lite-preview": ("thinkingLevel", "minimal"),
    "gemini-3-flash-preview": ("thinkingLevel", "minimal"),
    "gemini-3.1-pro-preview": ("thinkingLevel", "low"),
    "gemini-3.1-pro-preview-customtools": ("thinkingLevel", "low"),
    "gemini-2.5-flash": ("thinkingBudget", 0),
    "gemini-2.5-flash-lite": ("thinkingBudget", 0),
    # 2.5 Pro rejects budget 0 ("This model only works in thinking mode"); 128 is
    # the documented minimum and is what production sends. Omitting it here would
    # silently benchmark the model at Google's default dynamic thinking instead.
    "gemini-2.5-pro": ("thinkingBudget", 128),
}


# --- Request construction ---------------------------------------------------

def openai_body(model: str, system: str, user: str) -> dict:
    caps = openai_capabilities(model)
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "store": False,
    }
    # outputTokenPolicy -> .providerDefault for .openAI: no cap field at all.
    if caps["send_temperature"]:
        body["temperature"] = 0
    if caps["reasoning_effort"] is not None:
        body["reasoning_effort"] = caps["reasoning_effort"]
    return body


def gemini_body(model: str, system: str, user: str) -> dict:
    generation_config: dict = {"temperature": 0}
    thinking = GEMINI_THINKING_FAST.get(model.lower())
    if thinking is not None:
        generation_config["thinkingConfig"] = {thinking[0]: thinking[1]}
    return {
        "systemInstruction": {"parts": [{"text": system}]},
        # Production sends no `role` on the content part (GeminiConnector).
        "contents": [{"parts": [{"text": user}]}],
        "generationConfig": generation_config,
        "store": False,
    }


def claude_body(model: str, system: str, user: str) -> dict:
    # Mirrors ClaudeConnector.makeRequestBody: fixed max_tokens, thinking
    # disabled unconditionally, and NO temperature (temperaturePolicy .omit —
    # post-Opus-4.6 generations reject even temperature 0).
    return {
        "model": model,
        "max_tokens": CLAUDE_MAX_OUTPUT_TOKENS,
        "messages": [{"role": "user", "content": user}],
        "thinking": {"type": "disabled"},
        "system": system,
    }


def describe_shape(provider: str, model: str) -> str:
    if provider == "claude":
        return (
            f"messages | max_tokens={CLAUDE_MAX_OUTPUT_TOKENS} | temperature OMITTED "
            "| thinking disabled"
        )
    if provider == "openai":
        caps = openai_capabilities(model)
        if not caps["supports_chat_completions"]:
            return "UNSUPPORTED: Responses-API-only id; the shipped connector refuses it"
        temp = "temperature=0" if caps["send_temperature"] else "temperature OMITTED"
        eff = (
            f"reasoning_effort={caps['reasoning_effort']!r}"
            if caps["reasoning_effort"]
            else "no reasoning_effort"
        )
        return f"chat/completions | store=false | {temp} | {eff} | no max_completion_tokens"
    thinking = GEMINI_THINKING_FAST.get(model.lower())
    tdesc = f"{thinking[0]}={thinking[1]!r}" if thinking else "NO thinking field (id not in table)"
    return f"generateContent | temperature=0 | {tdesc} | no maxOutputTokens"


# --- Transport --------------------------------------------------------------

def _post(url: str, body: dict, headers: dict, timeout: int) -> dict:
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers=headers, method="POST"
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def call_once(provider: str, model: str, api_key: str, system: str, user: str,
              azure_endpoint: str = "") -> tuple[str, dict]:
    if provider == "openai":
        # Azure hosts the same OpenAI models on Founders Hub credits. Same
        # Chat Completions body; only the URL and the auth header differ, and
        # `model` is a DEPLOYMENT name (hyphens: gpt-5-6-luna) not a model id.
        # Fidelity caveat, stated once and accepted by the founder: our users
        # call api.openai.com directly, so an Azure-hosted deployment is a
        # different service instance of the same model.
        if azure_endpoint:
            data = _post(
                f"{azure_endpoint.rstrip('/')}/openai/deployments/{model}"
                "/chat/completions?api-version=2024-10-21",
                openai_body(model, system, user),
                {"api-key": api_key, "Content-Type": "application/json"},
                timeout=180,
            )
        else:
            data = _post(
                OPENAI_URL,
                openai_body(model, system, user),
                {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
                timeout=120,
            )
        choice = data["choices"][0]
        finish = choice.get("finish_reason")
        if finish == "length":
            # Mirrors the shipped connector's truncation rejection (#1271 cloud
            # review): a truncated polish must never be treated as an answer.
            raise RuntimeError("truncated response rejected (finish_reason=length)")
        text = (choice["message"].get("content") or "").strip()
        usage = data.get("usage", {}) or {}
        meta = {
            "inTok": usage.get("prompt_tokens"),
            "outTok": usage.get("completion_tokens"),
            "reasoningTok": (usage.get("completion_tokens_details") or {}).get("reasoning_tokens"),
        }
    elif provider == "claude":
        data = _post(
            ANTHROPIC_URL,
            claude_body(model, system, user),
            {
                "x-api-key": api_key,
                "anthropic-version": ANTHROPIC_VERSION,
                "content-type": "application/json",
            },
            timeout=120,
        )
        stop = data.get("stop_reason")
        if stop == "refusal":
            raise RuntimeError("model refused (stop_reason=refusal)")
        blocks = [b.get("text", "") for b in data.get("content", []) if b.get("type") == "text"]
        text = "".join(blocks).strip()
        if stop == "max_tokens":
            # Truncation classifies BEFORE emptiness, mirroring the connector.
            raise RuntimeError("truncated response rejected (stop_reason=max_tokens)")
        usage = data.get("usage", {}) or {}
        meta = {
            "inTok": usage.get("input_tokens"),
            "outTok": usage.get("output_tokens"),
            "reasoningTok": 0,
        }
    else:
        data = _post(
            GEMINI_URL.format(model=model, key=api_key),
            gemini_body(model, system, user),
            {"Content-Type": "application/json"},
            timeout=120,
        )
        cands = data.get("candidates") or []
        if not cands:
            raise RuntimeError(f"no candidates (promptFeedback={data.get('promptFeedback')})")
        cand = cands[0]
        if cand.get("finishReason") not in (None, "STOP"):
            raise RuntimeError(f"non-STOP finishReason={cand.get('finishReason')}")
        parts = (cand.get("content") or {}).get("parts") or []
        # Drop internal-reasoning parts exactly as GeminiConnector.swift does
        # (`.filter { $0["thought"] as? Bool != true }`). Without this a thinking
        # -capable model's chain of thought is concatenated into the candidate and
        # then scored as if the model had said it.
        text = "".join(p.get("text", "") for p in parts
                       if p.get("thought") is not True).strip()
        usage = data.get("usageMetadata", {}) or {}
        meta = {
            "inTok": usage.get("promptTokenCount"),
            "outTok": usage.get("candidatesTokenCount"),
            "reasoningTok": usage.get("thoughtsTokenCount"),
        }
    if not text:
        raise RuntimeError("empty text in response")
    return text, meta


BARE_PROMPT = (ROOT / "scripts/eval/prompts/cloud-fixed-polish-prompt-v6.txt").read_text().strip()


def polish_case(
    provider: str, model: str, api_key: str, case: dict,
    prompt_mode: str = "production", azure_endpoint: str = ""
) -> dict:
    transcript = case["text"]
    word_count = len(transcript.split())
    system = (
        BARE_PROMPT if prompt_mode == "bare" else build_cloud_fixed_system(word_count)
    )
    user = f"Transcript to clean:\n\n{transcript}"

    start = time.monotonic()
    last_err = None
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            raw, meta = call_once(provider, model, api_key, system, user, azure_endpoint)
            # Production strips the LLM preamble before pasting; judge the same
            # text the user would get. Cloud keeps literal <transcript> tags.
            candidate = _strip_llm_preamble_python(raw, strip_transcript_tags=False)
            return {
                "id": case["id"],
                "candidate": candidate,
                "latencyMs": int((time.monotonic() - start) * 1000),
                "attempts": attempt,
                **{k: v for k, v in meta.items() if v is not None},
            }
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:300]
            last_err = f"HTTP {e.code}: {detail}"
            retryable = e.code in RETRYABLE
        except urllib.error.URLError as e:
            last_err = f"URLError: {e.reason}"
            retryable = True
        except (OSError, http.client.HTTPException) as e:
            # A reset arriving while the RESPONSE BODY is read is a bare
            # ConnectionResetError, not a URLError, so before this clause it
            # escaped the retry loop entirely and killed the whole case. Ordered
            # after the two urllib clauses because HTTPError subclasses URLError
            # subclasses OSError, and a 4xx must keep its non-retryable verdict.
            #
            # A BROAD OSError catch is safe HERE and is not elsewhere, so the
            # check is recorded rather than left to the next reader: the only
            # things in this `try` are `call_once` (urlopen) and
            # `_strip_llm_preamble_python` (pure string work). `api_key` is read
            # by `_key()` ONCE at module level, outside the loop, so no
            # credential read can land in this scope. behavior_judge.py and
            # acceptance_gate.py could not make that claim -- they retry a
            # credential read and a subprocess spawn respectively -- which is why
            # they convert at the socket with TransientTransportError instead.
            last_err = f"{type(e).__name__}: {e}"
            retryable = True
        except (RuntimeError, KeyError, json.JSONDecodeError) as e:
            last_err = str(e)
            retryable = False
        if attempt < MAX_ATTEMPTS and retryable:
            time.sleep(min(2 ** attempt, 16))
            continue
        break
    return {
        "id": case["id"],
        "candidate": "",
        "error": last_err,
        "latencyMs": int((time.monotonic() - start) * 1000),
        "attempts": attempt,
    }


def load_corpus(path: Path) -> list[dict]:
    cases = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            text = d.get("asr_input") or d.get("input")
            if not text:
                raise ValueError(f"case {d.get('id')} has no asr_input/input")
            cases.append({"id": d["id"], "text": text})
    if not cases:
        raise ValueError(f"corpus {path} is empty")
    return cases


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--provider", required=True, choices=["openai", "gemini", "claude"])
    ap.add_argument("--model", required=True)
    ap.add_argument("--corpus", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--limit", type=int, default=0, help="first N cases only (smoke)")
    ap.add_argument(
        "--system-prompt", choices=["production", "bare"], default="production",
        help="production = the full CloudFixedPromptBuilder composition the app "
             "sends (default). bare = the v6 prompt file alone, which is what "
             "run_claude_type_b.py and the retired #1199 generator used. Provided "
             "ONLY so a past bare-prompt number can be reproduced as a control; "
             "never report a bare-prompt score as the shipped product's quality.",
    )
    ap.add_argument(
        "--azure", action="store_true",
        help="route --provider openai through the Azure deployment on Founders Hub "
             "credits instead of the direct key. --model then takes the DEPLOYMENT "
             "name (gpt-5-6-luna), not the model id (gpt-5.6-luna).",
    )
    args = ap.parse_args()

    # Fail fast on prompt drift BEFORE spending anything.
    _selftest_mirrors()

    if args.provider == "openai" and not openai_capabilities(args.model)["supports_chat_completions"]:
        print(f"{args.model} is Responses-API-only; the shipped connector cannot call it", file=sys.stderr)
        return 2

    azure_endpoint = ""
    if args.azure:
        if args.provider != "openai":
            print("--azure applies to --provider openai only", file=sys.stderr)
            return 2
        # Founders Hub credits instead of the direct key (founder 2026-08-01).
        api_key = _key("azure-openai-key")
        azure_endpoint = _key("azure-openai-endpoint")
    else:
        api_key = _key(
            {
                "openai": "openai-api-key",
                "gemini": "gemini-api-key",
                "claude": "anthropic-api-key",
            }[args.provider]
        )

    cases = load_corpus(args.corpus)
    if args.limit:
        cases = cases[: args.limit]
    args.out.parent.mkdir(parents=True, exist_ok=True)

    print(f"model    : {args.model} ({args.provider})", file=sys.stderr)
    print(f"shape    : {describe_shape(args.provider, args.model)}", file=sys.stderr)
    print(f"prompt   : {args.system_prompt}", file=sys.stderr)
    print(f"corpus   : {args.corpus.name} ({len(cases)} cases, {args.workers} workers)", file=sys.stderr)

    results: dict[str, dict] = {}
    errors = 0
    done = 0
    t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [
            pool.submit(polish_case, args.provider, args.model, api_key, c,
                        args.system_prompt, azure_endpoint)
            for c in cases
        ]
        for fut in as_completed(futures):
            row = fut.result()
            results[row["id"]] = row
            done += 1
            if row.get("error"):
                errors += 1
                print(f"[{done}/{len(cases)}] ERROR {row['id']}: {row['error']}", file=sys.stderr)
            elif done % 200 == 0:
                el = int(time.monotonic() - t0)
                print(f"[{done}/{len(cases)}] ok ({errors} errors, {el}s)", file=sys.stderr)

    with open(args.out, "w") as f:
        for case in cases:
            f.write(json.dumps(results[case["id"]]) + "\n")

    lat = sorted(r["latencyMs"] for r in results.values() if not r.get("error"))
    in_tok = sum(r.get("inTok") or 0 for r in results.values())
    out_tok = sum(r.get("outTok") or 0 for r in results.values())
    reason_tok = sum(r.get("reasoningTok") or 0 for r in results.values())
    if lat:
        print(
            f"latency ms: median={lat[len(lat)//2]} p90={lat[int(len(lat)*0.9)]} max={lat[-1]}",
            file=sys.stderr,
        )
    print(
        f"tokens: in={in_tok} out={out_tok} reasoning={reason_tok} "
        f"(reasoning MUST be 0 for a thinking-off run)",
        file=sys.stderr,
    )
    print(
        f"DONE {len(cases) - errors}/{len(cases)} in {int(time.monotonic() - t0)}s | errors={errors} -> {args.out}",
        file=sys.stderr,
    )
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
