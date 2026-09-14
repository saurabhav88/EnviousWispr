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
import hashlib
import io
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/eval"))

from section_envelope import (  # noqa: E402
    accept_section, pack_addendum, unwrap_sections, wrap_sections,
)
from acceptance_gate import (  # noqa: E402
    CLOUD_FIXED_SYSTEM,
    _key,
    _selftest_mirrors,
    _strip_llm_preamble_python,
    build_cloud_fixed_system,
)

# Bedrock is reached through boto3 rather than urllib because the request must be
# SigV4-signed. Imported lazily inside _bedrock_client() so the other three
# providers keep working on a machine with no AWS SDK installed.
# None means "let boto3 resolve it" -- AWS_DEFAULT_REGION or the active profile's
# config. NOT AWS_REGION: botocore's Session does not consult it. Measured, with
# the config files neutralised so an ambient ~/.aws/config could not answer for
# it: AWS_REGION alone -> None; AWS_DEFAULT_REGION alone -> resolves; both set ->
# AWS_DEFAULT_REGION wins. The two names read as synonyms and are not.
#
# A hardcoded default here would silently OVERRIDE a profile pointing somewhere
# else, and Bedrock access is region-specific -- so the override would surface as
# a model-access problem rather than as a wrong-region problem. Set
# EW_BEDROCK_REGION only to override deliberately.
BEDROCK_REGION = os.environ.get("EW_BEDROCK_REGION") or None
_bedrock_local = threading.local()


def _bedrock_client():
    """One SESSION and one client per worker thread.

    Caching the client per thread is not sufficient on its own: bare
    `boto3.client()` builds it from Boto3's shared DEFAULT session, so N workers
    reaching their first call together all mutate that one session concurrently.
    Boto3 documents the constraint on the object, not on the call --
    "Session objects, like Resource objects, are not thread-safe and should not
    be shared across threads or processes ... create a new Session object for
    each thread" (docs/source/guide/session.rst). So the session is what has to
    be thread-local; the client merely follows it.

    Sharing an already-built client across threads is fine -- Boto3's own
    multithreading example hands one client to a ThreadPoolExecutor -- so this
    is about construction, not use.
    """
    client = getattr(_bedrock_local, "client", None)
    if client is None:
        import boto3.session  # noqa: PLC0415 - optional dependency, see comment above
        from botocore.config import Config  # noqa: PLC0415

        session = boto3.session.Session()
        client = session.client(
            "bedrock-runtime",
            region_name=BEDROCK_REGION,
            # Timeouts stated rather than inherited, so this provider is bounded
            # like the other three (which pass explicit urllib timeouts) instead
            # of by whatever botocore defaults to.
            #
            # total_max_attempts=1 disables botocore's OWN retries so polish_case
            # is the single retry authority. Left at the default, a throttled
            # case would be retried inside each of our 4 attempts, with two
            # independent backoff schedules interleaved -- slower to fail and
            # impossible to read off the logs. The lever for throttling is
            # --workers (the 16-worker Haiku arm lost 168/1462 cases to 429s;
            # 6 workers is the fix), not a second hidden retry layer.
            #
            # It must be total_max_attempts, NOT max_attempts. botocore resolves
            # `max_attempts: N` to `total_max_attempts: N + 1` (args.py:620),
            # counting retries AFTER the initial request -- so max_attempts=1,
            # which reads like "one attempt", actually permits two. Verified on a
            # live client: max_attempts=1 -> {'total_max_attempts': 2},
            # total_max_attempts=1 -> {'total_max_attempts': 1}.
            config=Config(
                retries={"total_max_attempts": 1},
                connect_timeout=15,
                read_timeout=120,
            ),
        )
        _bedrock_local.session = session
        _bedrock_local.client = client
    return client


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
        # .effort("low") — the single shipped value since #1831 removed the
        # Deep-reasoning toggle. It is what the pair's fast side always sent.
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
    # 3.7 Flash accepts low/medium/high and REJECTS minimal with a 400 -- verified
    # live 2026-08-16 and confirmed against Google's per-model table at
    # ai.google.dev. It is therefore the first Flash-tier id that cannot reach
    # zero thinking; `low` is its floor, not its off-state. Omitting the row would
    # be worse than wrong: an absent id sends NO thinking field, and the Gemini 3
    # default is now medium, so the arm would silently benchmark a MORE expensive
    # setting than either the floor or what any other Flash row uses.
    "gemini-3.7-flash": ("thinkingLevel", "low"),
    "gemini-3.1-pro-preview": ("thinkingLevel", "low"),
    "gemini-3.1-pro-preview-customtools": ("thinkingLevel", "low"),
    "gemini-2.5-flash": ("thinkingBudget", 0),
    "gemini-2.5-flash-lite": ("thinkingBudget", 0),
    # 2.5 Pro rejects budget 0 ("This model only works in thinking mode"); 128 is
    # the documented minimum and is what production sends. Omitting it here would
    # silently benchmark the model at Google's default dynamic thinking instead.
    "gemini-2.5-pro": ("thinkingBudget", 128),
}

# Levels the `thinkingLevel` dialect accepts. `minimal` is NOT universal: the two
# 3.1 Pro ids reject it and floor at `low` (#1770), which is why the table above
# gives them a different fast value.
#
# Thinking is DYNAMIC and decided per request, so a small --limit probe cannot tell
# you whether a level takes (measured 2026-08-12, #1832). `gemini-3.5-flash-lite` at
# `medium` returned no thinking on a 3-case probe and thinking on 119 of 338 real
# cases; `gemini-3.6-flash` at `low` thinks on 259 of 338. A probe is for "does the
# API accept this and does the request shape work", never for "does the level engage".
# The one measured level that genuinely does nothing is flash-lite at `low`: zero
# thinking on 338 of 338, which is what a truly inert setting looks like.
GEMINI_THINKING_LEVELS = ("minimal", "low", "medium", "high")

# The value that means "do not think", per dialect. One home, because the alternative
# is a literal `in ("minimal", 0)` membership test at the point of use — a set of values
# standing in for the concept, which silently misreads any future off-value (a `"none"`
# or `"off"` level) as thinking-ON and then demands reasoning tokens that cannot arrive.
GEMINI_THINKING_OFF = {"thinkingLevel": "minimal", "thinkingBudget": 0}


def is_thinking_off(thinking: tuple[str, object] | None) -> bool:
    """True only when the config explicitly asks for NO thinking.

    `None` (no field sent) is deliberately not "off": the provider's own default
    decides, and measured here that default DOES think.
    """
    if thinking is None:
        return False
    dialect, value = thinking
    return dialect in GEMINI_THINKING_OFF and value == GEMINI_THINKING_OFF[dialect]


def resolve_gemini_thinking(model: str, override: str = "") -> tuple[str, object] | None:
    """The single source of the thinking config, so the printed receipt and the
    request body cannot disagree — they are two readers of one value, never two
    lookups of one table.

    Raises ValueError rather than falling back, because every fallback here
    silently benchmarks a configuration nobody asked for.
    """
    shipped = GEMINI_THINKING_FAST.get(model.lower())
    if not override:
        return shipped
    if shipped is None:
        raise ValueError(
            f"--thinking-level given for {model!r}, which is absent from the "
            "capability table. Production sends NO thinking field for such an id, "
            "so there is no shipped configuration to vary."
        )
    dialect = shipped[0]
    if dialect != "thinkingLevel":
        raise ValueError(
            f"{model!r} takes {dialect}, a token BUDGET. A level does not map to a "
            "budget, and inventing a number would benchmark a configuration the "
            "app never sends. Vary the budget in GEMINI_THINKING_FAST instead."
        )
    # An id whose SHIPPED fast level is already `low` is one that cannot go lower: the
    # table gives it `low` precisely because the provider rejects `minimal` (#1770).
    # Read the floor off the table rather than keeping a second list of Pro ids, which
    # would be one more thing to update when a model is added.
    #
    # Measured rather than taken from the note: gemini-3.1-pro-preview with
    # thinkingLevel `minimal` returns HTTP 400 "Thinking level MINIMAL is not supported
    # for this model" (2026-08-12). Refused here, before the run, because the request
    # otherwise fails per case and a full corpus is spent discovering it.
    if override == "minimal" and shipped[1] == "low":
        raise ValueError(
            f"{model!r} floors at 'low': the provider rejects thinkingLevel 'minimal' "
            "with HTTP 400, and this id's shipped fast level is 'low' for that reason. "
            "Use --thinking-level low as its off-equivalent."
        )
    return (dialect, override)


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


def gemini_body(model: str, system: str, user: str,
                thinking: tuple[str, object] | None) -> dict:
    generation_config: dict = {"temperature": 0}
    if thinking is not None:
        generation_config["thinkingConfig"] = {thinking[0]: thinking[1]}
    return {
        "systemInstruction": {"parts": [{"text": system}]},
        # Production sends no `role` on the content part (GeminiConnector).
        "contents": [{"parts": [{"text": user}]}],
        "generationConfig": generation_config,
        "store": False,
    }


def bedrock_body(model: str, system: str, user: str) -> dict:
    """The exact `converse` keyword payload the live bedrock path sends; one builder so the
    dry run and the call cannot drift (local Codex round 4 on PR #2902)."""
    return {
        "modelId": model,
        "system": [{"text": system}],
        "messages": [{"role": "user", "content": [{"text": user}]}],
        # temperature OMITTED to match claude_body / the shipped ClaudeConnector, which
        # sends no temperature at all.
        "inferenceConfig": {"maxTokens": CLAUDE_MAX_OUTPUT_TOKENS},
        # State it rather than inherit it. claude_body sends thinking:{"type":"disabled"}
        # explicitly and describe_shape() prints "thinking disabled" for this provider
        # too, so omitting the field made that line a claim about the MODEL'S DEFAULT
        # rather than about our request. Haiku 4.5 happens to default to no thinking
        # (probed 2026-08-16: no reasoningContent block even on a prompt built to tempt
        # one), so the arm generated before this line is still valid -- but a model that
        # defaults the other way would have been benchmarked with thinking ON under a
        # header saying OFF, and nothing would have caught it.
        "additionalModelRequestFields": {"thinking": {"type": "disabled"}},
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


def describe_shape(provider: str, model: str,
                   thinking: tuple[str, object] | None = None) -> str:
    if provider == "bedrock":
        # Report the region actually in force, not the override variable -- which
        # is normally unset, and printing "region=None" would hide the value that
        # decides whether a model is even reachable.
        region = BEDROCK_REGION or _bedrock_client().meta.region_name
        return (
            f"converse | maxTokens={CLAUDE_MAX_OUTPUT_TOKENS} | temperature OMITTED "
            f"| thinking disabled | region={region}"
        )
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
              azure_endpoint: str = "",
              thinking: tuple[str, object] | None = None) -> tuple[str, dict]:
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
    elif provider == "bedrock":
        # Same Claude models, reached through AWS credits rather than a paid
        # Anthropic key. Fidelity caveat, mirroring the Azure one above: our
        # users call api.anthropic.com directly, so a Bedrock-hosted model is a
        # different service instance of the same model. Converse is Bedrock's
        # provider-neutral shape, so `system` and `content` are lists of typed
        # blocks rather than Anthropic's bare strings.
        from botocore.exceptions import (  # noqa: PLC0415
            BotoCoreError,
            ClientError,
            ConnectionError as BotoConnectionError,
            HTTPClientError,
        )

        try:
            data = _bedrock_client().converse(**bedrock_body(model, system, user))
        except ClientError as e:
            # Re-raise as HTTPError so the retry loop's existing RETRYABLE set
            # classifies throttling and 5xx exactly as it does for every other
            # provider. The status code is Bedrock's own, not a guess at one.
            status = (e.response.get("ResponseMetadata") or {}).get("HTTPStatusCode", 400)
            body = json.dumps(e.response.get("Error") or {}).encode()
            raise urllib.error.HTTPError(
                f"bedrock://{model}", status,
                (e.response.get("Error") or {}).get("Code", "ClientError"),
                {}, io.BytesIO(body),
            ) from e
        except (BotoConnectionError, HTTPClientError) as e:
            # RETRYABLE half. botocore's transport failures are BotoCoreError
            # subclasses of bare Exception -- NOT ClientError, NOT OSError, NOT
            # urllib -- so uncaught, one blip escapes polish_case entirely and
            # kills the whole 1,462-case run at fut.result() instead of costing
            # one case. URLError is the loop's existing retryable-transport
            # channel, so this reuses that policy rather than adding a second.
            #
            # These two base classes ARE the transport subtree: enumerated from
            # botocore, they cover ConnectTimeoutError, ConnectionClosedError,
            # EndpointConnectionError, ProxyConnectionError, ReadTimeoutError,
            # ResponseStreamingError and SSLError, and nothing else.
            raise urllib.error.URLError(f"{type(e).__name__}: {e}") from e
        except BotoCoreError as e:
            # NON-RETRYABLE half, and it must still be caught. The other ~80
            # BotoCoreError subclasses are deterministic -- ParamValidationError,
            # InvalidRegionError, NoRegionError, NoCredentialsError,
            # UnknownServiceError. Retrying those burns four attempts with
            # backoff to reach the identical failure. Catching the BASE class as
            # retryable (the previous shape here) was the mirror image of not
            # catching it at all: the first mistake killed the run, the second
            # made every config error look like a flaky network.
            # RuntimeError is the loop's non-retryable channel, so the case fails
            # once, records why, and the run continues.
            raise RuntimeError(f"non-retryable botocore error: {type(e).__name__}: {e}") from e

        stop = data.get("stopReason")
        if stop == "max_tokens":
            # Truncation classifies BEFORE emptiness, mirroring the connector.
            raise RuntimeError("truncated response rejected (stopReason=max_tokens)")
        if stop == "content_filtered":
            raise RuntimeError("model refused (stopReason=content_filtered)")
        blocks = (data.get("output", {}).get("message", {}) or {}).get("content", []) or []
        # Having asked for thinking to be off, verify it was. The run header
        # prints "reasoning MUST be 0 for a thinking-off run" -- with a hardcoded
        # 0 that line restated a constant written here and could never have
        # reported the failure it screens for. Bedrock reports no separate
        # reasoning token count, so the observable is the block itself.
        if any("reasoningContent" in b for b in blocks):
            raise RuntimeError(
                "model returned reasoningContent despite thinking:disabled -- "
                "this arm is not a thinking-off measurement"
            )
        text = "".join(b.get("text", "") for b in blocks if "text" in b).strip()
        usage = data.get("usage", {}) or {}
        meta = {
            "inTok": usage.get("inputTokens"),
            "outTok": usage.get("outputTokens"),
            "reasoningTok": 0,  # now an assertion above, not an assumption
        }
    else:
        data = _post(
            GEMINI_URL.format(model=model, key=api_key),
            gemini_body(model, system, user, thinking),
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


BARE_PROMPT = (ROOT / "scripts/eval/prompts/cloud-fixed-polish-prompt-v7.txt").read_text().strip()


def polish_case(
    provider: str, model: str, api_key: str, case: dict,
    prompt_mode: str = "production", azure_endpoint: str = "",
    prompt_body: str | None = None,
    thinking: tuple[str, object] | None = None,
    validate: bool = False,
) -> dict:
    transcript = case["text"]
    word_count = len(transcript.split())
    if prompt_mode == "bare":
        system = BARE_PROMPT
    else:
        system = build_cloud_fixed_system(word_count, body=prompt_body)
    user = f"Transcript to clean:\n\n{transcript}"

    start = time.monotonic()
    last_err = None
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            raw, meta = call_once(provider, model, api_key, system, user, azure_endpoint,
                                  thinking)
            # Production strips the LLM preamble before pasting; judge the same
            # text the user would get. Cloud keeps literal <transcript> tags.
            candidate = _strip_llm_preamble_python(raw, strip_transcript_tags=False)
            row = {
                "id": case["id"],
                "candidate": candidate,
                "latencyMs": int((time.monotonic() - start) * 1000),
                "attempts": attempt,
                **{k: v for k, v in meta.items() if v is not None},
            }
            if validate:
                # `--validate`: the ISOLATED arm of the #2851 packing measurement carries
                # the same production fallback the packed arm carries (a rejected answer
                # becomes the original, `section_status` says why), so the paired judge
                # scores both arms on what a user would get. Off by default: every arm
                # graded before this flag existed judged the raw model answer, and a
                # historical number must stay reproducible (cloud review of PR #2902,
                # round 2).
                verdict = accept_section(transcript, candidate)
                row["candidate"] = verdict.candidate if verdict.status == "accepted" else transcript
                row["section_status"] = verdict.status
            return row
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
    failed = {
        "id": case["id"],
        "candidate": "",
        "error": last_err,
        "latencyMs": int((time.monotonic() - start) * 1000),
        "attempts": attempt,
    }
    if validate:
        # The packed arm's failed pack writes every section's original words with status
        # `error` and no `error` key (`_fallback_rows`); the validated isolated arm gets the
        # same row, so a provider failure costs both arms the same graded row.
        # `behavior_judge.partition_candidates` skips any row whose `error` is truthy, so
        # the message moves to `fallback_error`: the row is graded on the original words,
        # as production would deliver them, and the reason stays on the row (cloud review
        # of PR #2902, rounds 5 and 6).
        failed["candidate"] = transcript
        failed["section_status"] = "error"
        failed["fallback_error"] = failed.pop("error")
    return failed


# --- #2851 phase 2: pack mode -------------------------------------------------------
#
# Several speaker sections in ONE call, wrapped by `section_envelope.wrap_sections`, the
# v7 system prompt plus `pack_addendum`, and the answer cut back per section by
# `unwrap_sections` with `accept_section` applied to each. The corpus is
# `docs/feature-requests/2851-cloud-packing-corpus/` (sections.jsonl + packs-*.jsonl),
# consumed unchanged. Output keeps one ROW PER SECTION (id = the section id) so
# `behavior_judge.py` scores a packed arm exactly like an isolated one, plus a pack
# summary file beside it. `--dry-run` writes the exact request bodies and calls nobody.


def load_packs(path: Path) -> list[dict]:
    packs = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            d = json.loads(line)
            if not d.get("section_ids"):
                raise ValueError(f"pack {d.get('file')}:{d.get('pack_index')} has no section_ids")
            packs.append(d)
    if not packs:
        raise ValueError(f"packs file {path} is empty")
    return packs


def build_pack_request(
    provider: str, model: str, sections: list[str], prompt_body: str | None = None,
    thinking: tuple[str, object] | None = None, prompt_mode: str = "production",
) -> tuple[str, str, dict]:
    """(system, user, body) for one pack: the system prompt `polish_case` would send under
    the same `prompt_mode` (production = the v7 composition sized by the pack's word count;
    bare = the v7 file alone, the same control `--system-prompt bare` gives an isolated
    arm), the addendum, and the wrapped sections as the transcript. The body is the
    provider's real request shape, which is what `--dry-run` writes: `openai_body`,
    `gemini_body`, `claude_body`, and for bedrock the exact `converse` keyword payload
    `call_once` sends (cloud review of PR #2902: the Messages body is not what Bedrock
    receives)."""
    word_count = sum(len(s.split()) for s in sections)
    if prompt_mode == "bare":
        system = BARE_PROMPT
    else:
        system = build_cloud_fixed_system(word_count, body=prompt_body)
    system += pack_addendum(len(sections))
    user = f"Transcript to clean:\n\n{wrap_sections(sections)}"
    if provider == "openai":
        body = openai_body(model, system, user)
    elif provider == "gemini":
        body = gemini_body(model, system, user, thinking)
    elif provider == "claude":
        body = claude_body(model, system, user)
    elif provider == "bedrock":
        body = bedrock_body(model, system, user)
    else:
        raise ValueError(f"unknown provider {provider}")
    return system, user, body


def _is_truncation(message: str) -> bool:
    """`call_once` raises on the provider's own stop reason: "truncated response rejected
    (finish_reason=length)" for OpenAI, "non-STOP finishReason=MAX_TOKENS" for Gemini, and
    the Claude/Bedrock max_tokens message. All three are the truncation the plan's
    split-in-half answers (cloud review of PR #2902: Gemini's was landing as `error`)."""
    return "truncated" in message or "MAX_TOKENS" in message or "max_tokens" in message


def polish_pack(
    provider: str, model: str, api_key: str, pack: dict, texts: dict[str, str],
    azure_endpoint: str = "", prompt_body: str | None = None,
    thinking: tuple[str, object] | None = None, prompt_mode: str = "production",
) -> tuple[dict, list[dict]]:
    """One pack through the provider. Returns (pack summary, per-section rows).

    A pack the provider truncates (`_is_truncation`) or that comes back with the wrong tag
    count/order is `truncated` / `miscount`; the measurement records the event rather than
    splitting. EVERY row carries the text a user would get: production's
    `validatePolishOutput` returns the ORIGINAL on a rejection and the floor on a failed
    pack, so a rejected, miscounted, truncated or errored section carries its original
    words as `candidate` with the reason in `section_status`. An empty candidate would be
    dropped by `behavior_judge.partition_candidates` as an infra skip and the packed arm
    would be scored on fewer sections than the isolated one (cloud review of PR #2902)."""
    ids = pack["section_ids"]
    sections = [texts[i] for i in ids]
    system, user, _ = build_pack_request(
        provider, model, sections, prompt_body, thinking, prompt_mode)
    start = time.monotonic()
    summary = {
        "file": pack.get("file"), "pack_index": pack.get("pack_index"),
        "sections": len(ids), "words": sum(len(s.split()) for s in sections),
    }
    last_err = None
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            raw, meta = call_once(provider, model, api_key, system, user, azure_endpoint, thinking)
            break
        except RuntimeError as e:
            if _is_truncation(str(e)):
                summary.update(outcome="truncated", error=str(e), attempts=attempt,
                               latencyMs=int((time.monotonic() - start) * 1000))
                return summary, _fallback_rows(pack, ids, sections, "truncated")
            last_err, retryable = str(e), False
        except urllib.error.HTTPError as e:
            last_err = f"HTTP {e.code}: {e.read().decode(errors='replace')[:300]}"
            retryable = e.code in RETRYABLE
        except (urllib.error.URLError, OSError, http.client.HTTPException) as e:
            last_err, retryable = f"{type(e).__name__}: {e}", True
        except (KeyError, json.JSONDecodeError) as e:
            last_err, retryable = str(e), False
        if attempt < MAX_ATTEMPTS and retryable:
            time.sleep(min(2 ** attempt, 16))
            continue
        summary.update(outcome="error", error=last_err, attempts=attempt,
                       latencyMs=int((time.monotonic() - start) * 1000))
        return summary, _fallback_rows(pack, ids, sections, "error")
    summary.update(attempts=attempt, latencyMs=int((time.monotonic() - start) * 1000),
                   **{k: v for k, v in meta.items() if v is not None})
    # The preamble strip runs on the WHOLE answer before unwrap (an assistant wrapper line
    # before `<s1>` would otherwise fail the count), never per section, where it could
    # remove a speaker's own words (Codex r1).
    raw = _strip_llm_preamble_python(raw, strip_transcript_tags=False)
    parts = unwrap_sections(raw, len(ids))
    if parts is None:
        summary["outcome"] = "miscount"
        return summary, _fallback_rows(pack, ids, sections, "miscount")
    rows = []
    statuses: dict[str, int] = {}
    for section_id, original, candidate in zip(ids, sections, parts):
        verdict = accept_section(original, candidate)
        statuses[verdict.status] = statuses.get(verdict.status, 0) + 1
        rows.append({
            "id": section_id,
            # Production returns the ORIGINAL on a rejection; so does this row.
            "candidate": verdict.candidate if verdict.status == "accepted" else original,
            "section_status": verdict.status,
            "pack_index": pack.get("pack_index"), "pack_file": pack.get("file"),
        })
    summary["outcome"] = "unwrapped"
    summary["section_statuses"] = statuses
    return summary, rows


def _fallback_rows(pack: dict, ids: list[str], sections: list[str], status: str) -> list[dict]:
    """One row per section carrying its ORIGINAL words (the production fallback) and why."""
    return [{"id": i, "candidate": original, "section_status": status,
             "pack_index": pack.get("pack_index"), "pack_file": pack.get("file")}
            for i, original in zip(ids, sections)]


def prompt_sha256(prompt_mode: str, prompt_body: str | None) -> str:
    """Identity of the prompt BODY an arm ran with: the bare v7 prompt, the shipped v6 body,
    or the `--system-prompt-file` text. Two arms with different custom bodies otherwise
    print identical receipts (cloud review of PR #2902, round 5)."""
    if prompt_mode == "bare":
        body = BARE_PROMPT
    elif prompt_body is not None:
        body = prompt_body.strip()
    else:
        body = CLOUD_FIXED_SYSTEM
    return hashlib.sha256(body.encode()).hexdigest()


def run_receipt(args, thinking: tuple[str, object] | None, prompt_body: str | None) -> dict:
    """Provenance every candidate row of a run carries: what was run, on which route, with
    which prompt, validated or not, packed or isolated. `compare_arms_paired.py
    --packing-report` prints the two arms' receipts side by side for the operator to read;
    it does not certify that two arms are the same experiment (PR #2902)."""
    return {
        "provider": args.provider, "model": args.model,
        "prompt_mode": args.system_prompt,
        "prompt_sha256": prompt_sha256(args.system_prompt, prompt_body),
        "thinking": list(thinking) if thinking else None,
        "validated": True if args.pack is not None else bool(getattr(args, "validate", False)),
        "mode": "packed" if args.pack is not None else "isolated",
        "pack_file": args.pack.name if args.pack is not None else None,
    }


def thinking_off_refusal(thinking: tuple[str, object] | None, reason_tok: int) -> str | None:
    """The one hard refusal both paths share: an arm that ASKED for thinking off and got
    reasoning tokens anyway must not be graded (the field did not reach the API, or the
    vendor changed the level). `None` when there is nothing to refuse. The isolated path's
    softer inert-level warning stays there; the pack path has no per-case count to judge it
    by (cloud review of PR #2902: the pack early return bypassed this guard)."""
    if thinking is None or not is_thinking_off(thinking) or not reason_tok:
        return None
    if thinking[0] == "thinkingBudget":
        cause = ("a zero token budget cannot produce reasoning, so the field did not "
                 "reach the API")
    else:
        cause = ("either the field did not reach the API, or the vendor changed what "
                 "'minimal' does — 0 of 6,084 measured cases produced reasoning at "
                 "this level, so check which before re-running")
    return (f"FAIL: {reason_tok} reasoning tokens with {thinking[0]}={thinking[1]!r} — "
            f"{cause}. Do not grade these candidates.")


def run_pack_mode(args, api_key: str, azure_endpoint: str, prompt_body: str | None,
                  thinking: tuple[str, object] | None) -> int:
    cases = load_corpus(args.corpus)
    texts = {c["id"]: c["text"] for c in cases}
    packs = load_packs(args.pack)
    missing = [i for p in packs for i in p["section_ids"] if i not in texts]
    if missing:
        print(f"{len(missing)} section ids in {args.pack.name} are not in {args.corpus.name}: "
              f"{missing[:5]}", file=sys.stderr)
        return 2
    if args.limit:
        packs = packs[: args.limit]
    print(f"packs    : {args.pack.name} ({len(packs)} packs, "
          f"{sum(len(p['section_ids']) for p in packs)} sections)", file=sys.stderr)
    print("validate : every section carries production's fallback on a rejection; run the "
          "isolated arm with --validate and read both arms through "
          "`compare_arms_paired.py --packing-report`, which refuses a plain arm and prints "
          "both run receipts for you to hold to the same experiment", file=sys.stderr)

    if args.dry_run is not None:
        # The dry-run file's own parent, and nothing else: `--out`'s directory is created
        # only by the live path (local review round 1).
        args.dry_run.parent.mkdir(parents=True, exist_ok=True)
        with open(args.dry_run, "w") as f:
            for p in packs:
                sections = [texts[i] for i in p["section_ids"]]
                system, user, body = build_pack_request(
                    args.provider, args.model, sections, prompt_body, thinking,
                    args.system_prompt)
                f.write(json.dumps({
                    "provider": args.provider, "model": args.model,
                    "file": p.get("file"), "pack_index": p.get("pack_index"),
                    "section_ids": p["section_ids"], "words": sum(len(s.split()) for s in sections),
                    "system_chars": len(system), "user_chars": len(user), "body": body,
                }) + "\n")
        print(f"dry-run  : {len(packs)} request bodies written to {args.dry_run}; nothing called",
              file=sys.stderr)
        return 0

    args.out.parent.mkdir(parents=True, exist_ok=True)
    receipt = run_receipt(args, thinking, prompt_body)
    summaries: list[dict] = []
    rows_by_id: dict[str, dict] = {}
    t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {
            pool.submit(polish_pack, args.provider, args.model, api_key, p, texts,
                        azure_endpoint, prompt_body, thinking, args.system_prompt): p
            for p in packs
        }
        for n, fut in enumerate(as_completed(futures), start=1):
            summary, rows = fut.result()
            summaries.append(summary)
            for r in rows:
                r["run"] = receipt
                rows_by_id[r["id"]] = r
            if summary["outcome"] != "unwrapped":
                print(f"[{n}/{len(packs)}] {summary['outcome'].upper()} "
                      f"{summary['file']}:{summary['pack_index']} {summary.get('error', '')}",
                      file=sys.stderr)
    with open(args.out, "w") as f:
        for p in packs:
            for i in p["section_ids"]:
                f.write(json.dumps(rows_by_id[i]) + "\n")
    packs_out = args.out.with_suffix(args.out.suffix + ".packs.jsonl")
    with open(packs_out, "w") as f:
        for s in sorted(summaries, key=lambda s: (str(s["file"]), s["pack_index"] or 0)):
            f.write(json.dumps(s) + "\n")
    outcomes: dict[str, int] = {}
    for s in summaries:
        outcomes[s["outcome"]] = outcomes.get(s["outcome"], 0) + 1
    statuses: dict[str, int] = {}
    for r in rows_by_id.values():
        statuses[r["section_status"]] = statuses.get(r["section_status"], 0) + 1
    reason_tok = sum(s.get("reasoningTok") or 0 for s in summaries)
    print(f"packs    : {outcomes}  sections: {statuses}  reasoning={reason_tok}  "
          f"{int(time.monotonic() - t0)}s", file=sys.stderr)
    print(f"wrote    : {args.out} and {packs_out}", file=sys.stderr)
    if (refusal := thinking_off_refusal(thinking, reason_tok)) is not None:
        print(refusal, file=sys.stderr)
        return 2
    # Original text is graded either way; the exit status says the run was INCOMPLETE, the
    # same contract the isolated path keeps (`return 0 if errors == 0 else 1`).
    return 1 if any(s["outcome"] in {"error", "truncated"} for s in summaries) else 0


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
    ap.add_argument("--provider", required=True,
                    choices=["openai", "gemini", "claude", "bedrock"])
    ap.add_argument("--model", required=True)
    ap.add_argument("--corpus", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--limit", type=int, default=0, help="first N cases only (smoke)")
    ap.add_argument(
        "--pack", type=Path, default=None,
        help="#2851 phase 2: a packs-*.jsonl beside --corpus (sections.jsonl); several "
             "sections per call, one output row per section, plus <out>.packs.jsonl",
    )
    ap.add_argument(
        "--validate", action="store_true",
        help="#2851 phase 2, the ISOLATED arm: apply production's output validator to each "
             "answer (a rejected answer becomes the original, section_status says why), the "
             "treatment pack mode always applies. Required on the isolated arm of a "
             "packed-vs-isolated comparison; off by default so earlier arms stay reproducible.",
    )
    ap.add_argument(
        "--dry-run", type=Path, default=None,
        help="with --pack: write every request body to this path and call no provider "
             "(no key needed; GR-NO-CLOUD-SPEND)",
    )
    ap.add_argument(
        "--system-prompt", choices=["production", "bare"], default="production",
        help="production = the full CloudFixedPromptBuilder composition the app "
             "sends (default). bare = the v6 prompt file alone, which is what "
             "run_claude_type_b.py and the retired #1199 generator used. Provided "
             "ONLY so a past bare-prompt number can be reproduced as a control; "
             "never report a bare-prompt score as the shipped product's quality.",
    )
    ap.add_argument(
        "--system-prompt-file", type=Path, default=None,
        help="bakeoff arm: substitute THIS file for the shipped v6 body inside the "
             "otherwise byte-identical production composition, so the arm differs from "
             "the shipped arm in exactly one thing. Incompatible with "
             "--system-prompt bare. A score produced this way is an unshipped prompt's "
             "score and must be reported as such.",
    )
    ap.add_argument(
        "--thinking-level", choices=GEMINI_THINKING_LEVELS, default="",
        help="Gemini only. Override the shipped thinking level for this arm, so the "
             "quality cost of the hard-coded fast value can be MEASURED rather than "
             "assumed (#1832). Omit to send exactly what production sends. Refused "
             "for a token-budget id or an id absent from the capability table, "
             "because both would benchmark a configuration the app never sends.",
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

    prompt_body = None
    if args.system_prompt_file is not None:
        if args.system_prompt == "bare":
            print("--system-prompt-file is incompatible with --system-prompt bare",
                  file=sys.stderr)
            return 2
        prompt_body = args.system_prompt_file.read_text()
        if not prompt_body.strip():
            print(f"{args.system_prompt_file} is empty", file=sys.stderr)
            return 2

    if args.thinking_level and args.provider != "gemini":
        print(
            f"--thinking-level applies to --provider gemini only; {args.provider} "
            "carries its own reasoning field from the capability table",
            file=sys.stderr,
        )
        return 2
    try:
        thinking = resolve_gemini_thinking(args.model, args.thinking_level) \
            if args.provider == "gemini" else None
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 2

    if args.provider == "openai" and not openai_capabilities(args.model)["supports_chat_completions"]:
        print(f"{args.model} is Responses-API-only; the shipped connector cannot call it", file=sys.stderr)
        return 2

    if args.dry_run is not None and args.pack is None:
        print("--dry-run needs --pack", file=sys.stderr)
        return 2
    if args.azure and args.provider != "openai":
        # The same refusal the live path makes below, BEFORE the dry-run return: a pre-spend
        # approval must never bless a configuration the real run would refuse (cloud review
        # of PR #2902, round 3).
        print("--azure applies to --provider openai only", file=sys.stderr)
        return 2
    if args.pack is not None and args.dry_run is not None:
        # No key, no endpoint, no call: the bodies are written from the same builders the
        # live path uses, so what the founder approves for a real run is exactly what is
        # on disk (GR-NO-CLOUD-SPEND).
        return run_pack_mode(args, api_key="", azure_endpoint="", prompt_body=prompt_body,
                             thinking=thinking)

    azure_endpoint = ""
    if args.provider == "bedrock":
        # boto3 reads the credential chain itself; there is no key to pass down.
        # Checked here so a 1,462-case run fails in a second rather than as 1,462
        # identical AccessDenied retries. Ask boto3 whether it can resolve
        # credentials rather than testing for two env vars: the env pair is only
        # one entry in the chain, and a guard that names it refuses AWS_PROFILE,
        # IAM Identity Center, and instance roles -- all of which would have
        # worked. Check the capability, never a proxy for it.
        try:
            import boto3  # noqa: PLC0415

            probe = boto3.Session()
            if probe.get_credentials() is None:
                raise RuntimeError("no credentials in the boto3 provider chain")
            # Region resolves the same way and fails the same way, so check it in
            # the same breath. Without this, an unset region surfaces as 1,462
            # identical NoRegionError cases instead of one line at startup.
            if not (BEDROCK_REGION or probe.region_name):
                raise RuntimeError(
                    "no region resolved -- set EW_BEDROCK_REGION or "
                    "AWS_DEFAULT_REGION, or use a profile with a configured "
                    "region. NOT AWS_REGION: botocore's Session ignores it"
                )
        except Exception as e:  # noqa: BLE001 - any resolution failure is fatal here
            # The recovery command must actually recover. It carries the region
            # because the credit-account credentials come from get-key and bring
            # none with them, so advice that set only the keys would loop a stuck
            # user straight back to this same message.
            print(f"bedrock cannot start: {type(e).__name__}: {e}\n"
                  "For the credit-funded account, use:\n"
                  "  EW_BEDROCK_REGION=us-west-2 \\\n"
                  "  ~/.claude/bin/get-key launch aws-bedrock-access-key-id "
                  "AWS_ACCESS_KEY_ID -- \\\n"
                  "  ~/.claude/bin/get-key launch aws-bedrock-secret-access-key "
                  "AWS_SECRET_ACCESS_KEY -- <cmd>", file=sys.stderr)
            return 2
        api_key = ""
    elif args.azure:
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

    if args.pack is not None:
        return run_pack_mode(args, api_key, azure_endpoint, prompt_body, thinking)

    cases = load_corpus(args.corpus)
    corpus_total = len(cases)
    if args.limit:
        cases = cases[: args.limit]
    # Whether this run is a PROBE is a property of what it covered, not of which flag
    # was typed: `--limit 400` on a 338-case corpus runs every case and must be judged
    # as a full run. But a genuinely tiny --corpus is no more representative than a
    # tiny --limit of a big one, so BOTH make this a probe.
    #
    # 100 is derived from the weakest whole-corpus engagement measured (flash-lite at
    # `medium` thinks on 119 of 338 cases, 35%). P(no case thinks by chance) = 0.65^n:
    # 27% at n=3, 1.3% at n=10, 1e-19 at n=100. So 100 puts a false "inert" verdict far
    # out of reach while sitting below the smallest canonical corpus (338), where it can
    # never affect a real arm.
    #
    # A TRUNCATED run stays a probe at ANY size, and case count cannot rescue it. The
    # corpora are ordered by bucket — `head -100` of type_b_parakeet.jsonl is 100%
    # `self_correction` — and engagement is strongly bucket-dependent: measured on
    # flash-lite at `medium`, 5% on `emoji_retention` against 75% on `self_correction`,
    # a 15x spread. So 100 truncated cases can be 100 cases of the one bucket this model
    # rarely thinks about, where P(none think) is ~0.6% rather than 1e-19. Raising the
    # count does not fix a sample that is one category by construction.
    MIN_CASES_FOR_INERT_VERDICT = 100
    is_truncated = len(cases) < corpus_total
    is_probe = is_truncated or len(cases) < MIN_CASES_FOR_INERT_VERDICT
    args.out.parent.mkdir(parents=True, exist_ok=True)

    print(f"model    : {args.model} ({args.provider})", file=sys.stderr)
    print(f"shape    : {describe_shape(args.provider, args.model, thinking)}", file=sys.stderr)
    # The label is a claim about the RESOLVED config, not about which flags were typed.
    # `--thinking-level minimal` on gemini-3.6-flash resolves to the shipped value, so
    # calling it "NOT the shipped configuration" mislabels a control arm as a variant —
    # and the arm most likely to be run this way is exactly the control.
    if args.thinking_level:
        shipped = GEMINI_THINKING_FAST.get(args.model.lower())
        if thinking == shipped:
            print(
                f"OVERRIDE : --thinking-level {args.thinking_level!r} equals this model's "
                "shipped value, so this arm IS the shipped configuration",
                file=sys.stderr,
            )
        else:
            shipped_desc = f"{shipped[0]}={shipped[1]!r}" if shipped else "no thinking field"
            print(
                f"OVERRIDE : thinking level forced to {args.thinking_level!r} (shipped is "
                f"{shipped_desc}) — this arm is NOT the shipped configuration",
                file=sys.stderr,
            )
    if prompt_body is None:
        print(f"prompt   : {args.system_prompt}", file=sys.stderr)
    else:
        # Name AND hash the arm: two variants of one prompt have the same filename
        # in every log line that matters, and the hash is what distinguishes them.
        digest = hashlib.sha256(prompt_body.strip().encode()).hexdigest()[:12]
        print(f"prompt   : {args.system_prompt} body<-{args.system_prompt_file} "
              f"sha256={digest} ({len(prompt_body.strip())} chars) UNSHIPPED",
              file=sys.stderr)
    print(f"corpus   : {args.corpus.name} ({len(cases)} cases, {args.workers} workers)", file=sys.stderr)

    results: dict[str, dict] = {}
    receipt = run_receipt(args, thinking, prompt_body)
    errors = 0
    done = 0
    t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [
            pool.submit(polish_case, args.provider, args.model, api_key, c,
                        args.system_prompt, azure_endpoint, prompt_body, thinking,
                        args.validate)
            for c in cases
        ]
        for fut in as_completed(futures):
            row = fut.result()
            row["run"] = receipt
            results[row["id"]] = row
            done += 1
            err = row.get("error") or row.get("fallback_error")
            if err:
                errors += 1
                print(f"[{done}/{len(cases)}] ERROR {row['id']}: {err}", file=sys.stderr)
            elif done % 200 == 0:
                el = int(time.monotonic() - t0)
                print(f"[{done}/{len(cases)}] ok ({errors} errors, {el}s)", file=sys.stderr)

    with open(args.out, "w") as f:
        for case in cases:
            f.write(json.dumps(results[case["id"]]) + "\n")

    lat = sorted(r["latencyMs"] for r in results.values()
                 if not (r.get("error") or r.get("fallback_error")))
    in_tok = sum(r.get("inTok") or 0 for r in results.values())
    out_tok = sum(r.get("outTok") or 0 for r in results.values())
    reason_tok = sum(r.get("reasoningTok") or 0 for r in results.values())
    if lat:
        print(
            f"latency ms: median={lat[len(lat)//2]} p90={lat[int(len(lat)*0.9)]} max={lat[-1]}",
            file=sys.stderr,
        )
    # Only ONE direction of this is a real discriminator, and a mutation control is
    # what established which (2026-08-12, #1832). Deleting the thinking field
    # entirely and asking for `high` still returned 150 reasoning tokens, because
    # this model's provider-side DEFAULT is dynamic thinking — so "reasoning > 0"
    # is satisfied by a dropped override and proves nothing about a thinking-ON arm.
    # The off direction does discriminate: the same probe returns exactly 0 with
    # `minimal` and non-zero without the field, so a non-zero on an off arm is proof
    # the field did not take. Whether an ON arm ran the level it claims is answered
    # by comparing per-case `reasoningTok` ACROSS arms, not from inside one run.
    if thinking is None:
        expectation = "no thinking field sent; the provider default decides, nothing asserted"
        asked_off = False
    elif is_thinking_off(thinking):
        expectation = f"reasoning MUST be 0 at {thinking[0]}={thinking[1]!r}"
        asked_off = True
    else:
        expectation = (
            f"reasoning > 0 expected at {thinking[0]}={thinking[1]!r}; necessary, NOT "
            "sufficient — compare reasoningTok across arms to prove the level took"
        )
        asked_off = False
    print(
        f"tokens: in={in_tok} out={out_tok} reasoning={reason_tok} ({expectation})",
        file=sys.stderr,
    )
    if (refusal := thinking_off_refusal(thinking, reason_tok)) is not None:
        # The two off-values are NOT equally binding, and the refusal says which it is.
        # `thinkingBudget: 0` is a contract — a budget of zero tokens. `thinkingLevel:
        # minimal` is a LEVEL NAME, so zero is an observation rather than a guarantee:
        # measured 0 reasoning tokens across 6,084 cases (three models, both phases of
        # #1832), which is a strong base and still not a promise the vendor made.
        #
        # It stays a hard refusal in both cases because of the failure DIRECTION. A
        # false reject is loud and costs a re-run; a missed drop grades an arm labelled
        # `minimal` that actually ran the provider's default thinking, and silently
        # corrupts every comparison it appears in. The mutation control that set this
        # guard's scope depends on exactly this branch: with the field deleted, a
        # `minimal` request returned 130 reasoning tokens. The message and the cause
        # live in `thinking_off_refusal`, shared with pack mode.
        print(refusal, file=sys.stderr)
        return 2
    if not asked_off and thinking is not None and not reason_tok:
        # A zero here means "no case chose to think", which is only EVIDENCE of an
        # inert level over a whole corpus. Under --limit it is an ordinary outcome:
        # thinking is per-request, and flash-lite at `medium` returned zero on a
        # 3-case probe and thought on 119 of 338 real cases. Hard-failing a probe
        # would break the very --limit smoke this file tells operators to run, so
        # the severity follows what the run IS, not what the number is.
        if is_probe:
            why = (
                f"this run is TRUNCATED ({len(cases)} of {corpus_total}), and these "
                "corpora are ordered by bucket, so a slice is one category rather than "
                "a sample — engagement varies 5%-75% across buckets, so no case count "
                "makes a truncated run safe for this verdict"
                if is_truncated
                else f"the corpus itself holds only {corpus_total} cases; an inert "
                     f"verdict needs {MIN_CASES_FOR_INERT_VERDICT}"
            )
            print(
                f"WARNING: zero reasoning tokens across {len(cases)} cases at "
                f"{thinking[0]}={thinking[1]!r}, but {why}. Thinking is decided per "
                "request, so this cannot distinguish an inert level from cases that "
                "declined to think. Not a verdict; run the FULL corpus to find out.",
                file=sys.stderr,
            )
        elif errors:
            # "No case thought" only supports "the level is inert" if the cases
            # actually RAN. reason_tok sums successful rows only, so 337 HTTP errors
            # plus one success that happened not to think looks identical to a whole
            # corpus declining — and would convict the model of a fault that is ours.
            # An incomplete arm is reported as incomplete; the errors path already
            # exits non-zero below.
            print(
                f"WARNING: zero reasoning tokens, but {errors} of {len(cases)} cases "
                f"failed, so only {len(cases) - errors} actually ran at "
                f"{thinking[0]}={thinking[1]!r}. That is not enough to call the level "
                "inert — fix the errors and re-run before concluding anything.",
                file=sys.stderr,
            )
        elif thinking == GEMINI_THINKING_FAST.get(args.model.lower()):
            # Ordered AFTER the errors branch on purpose: an incomplete run establishes
            # nothing about production either.
            #
            # The refusal exists to catch an OVERRIDE that did not take. A shipped
            # control makes no such claim — it ran production's exact request shape, so
            # if that configuration is inert, that is a fact ABOUT PRODUCTION, and the
            # arm is still the baseline every other arm is measured against. Failing it
            # would discard the control: `gemini-3.1-pro-preview` ships `low` rather
            # than `minimal`, so a shipped run of it would exit 2 on any corpus where
            # the model happened never to think.
            print(
                f"WARNING: zero reasoning tokens across all {len(cases)} cases at "
                f"{thinking[0]}={thinking[1]!r} — but this is the SHIPPED configuration, "
                "so the arm is a valid production control and the finding is that "
                "production is inert on this corpus, not that the arm is broken.",
                file=sys.stderr,
            )
        else:
            print(
                f"FAIL: zero reasoning tokens across all {len(cases)} cases at "
                f"{thinking[0]}={thinking[1]!r}, every one of which succeeded, and this "
                "is NOT the shipped configuration — the override did not take, so the "
                "arm is indistinguishable from thinking-off; do not grade it",
                file=sys.stderr,
            )
            return 2
    print(
        f"DONE {len(cases) - errors}/{len(cases)} in {int(time.monotonic() - t0)}s | errors={errors} -> {args.out}",
        file=sys.stderr,
    )
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
