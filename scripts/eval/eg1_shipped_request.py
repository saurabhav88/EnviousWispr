#!/usr/bin/env python3
"""Pure-Python mirror of the shipped EG-1 request and response contract.

The live connector remains the product authority. These helpers let controlled
evaluation runs send the same JSON fields and fail closed on the same response
shapes without exposing the app's per-launch bearer token.
"""

from __future__ import annotations

import re
from typing import Any


TRANSCRIPT_OPEN = "<TRANSCRIPT>"
TRANSCRIPT_CLOSE = "</TRANSCRIPT>"
MIN_OUTPUT_TOKENS = 256


class EG1ShippedResponseError(ValueError):
    """A response the shipped connector would silently bypass."""


def neutralize_transcript_tags(transcript: str) -> str:
    replacements = (
        ("</TRANSCRIPT>", "<\u200c/TRANSCRIPT>"),
        ("<TRANSCRIPT>", "<\u200cTRANSCRIPT>"),
        ("</transcript>", "<\u200c/transcript>"),
        ("<transcript>", "<\u200ctranscript>"),
    )
    result = transcript
    for old, new in replacements:
        result = result.replace(old, new)
    return result


def build_user_message(transcript: str) -> str:
    safe = neutralize_transcript_tags(transcript)
    return f"{TRANSCRIPT_OPEN}\n{safe}\n{TRANSCRIPT_CLOSE}"


def output_token_budget(transcript: str) -> int:
    # At or below the floor, Python/Swift character-count differences cannot
    # change the wire value. Above it, ASCII is also exact. Longer Unicode must
    # come from the Swift renderer because Python len is not Swift String.count
    # for combining marks, joined emoji, and other grapheme clusters.
    python_count = len(transcript)
    if python_count <= MIN_OUTPUT_TOKENS:
        return MIN_OUTPUT_TOKENS
    if transcript.isascii():
        return python_count
    raise ValueError("long Unicode input requires Swift String.count")


def build_request_body(
    *, model: str, system: str, user: str, max_tokens: int
) -> dict[str, Any]:
    if type(max_tokens) is not int or max_tokens < MIN_OUTPUT_TOKENS:
        raise ValueError(f"max_tokens must be an integer >= {MIN_OUTPUT_TOKENS}")
    return {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "max_tokens": max_tokens,
        "temperature": 0,
    }


def _first_line_looks_like_preamble(text: str) -> bool:
    first_line = text.split("\n", 1)[0]
    if not first_line or len(first_line) >= 100 or not first_line.endswith(":"):
        return False
    lowered = first_line.strip().lower()
    return lowered.startswith(
        (
            "here",
            "below",
            "the corrected",
            "the cleaned",
            "the polished",
            "the rewritten",
            "corrected version",
            "cleaned",
            "polished",
        )
    )


def _first_sentence_is_standalone_reply(text: str) -> bool:
    if not text:
        return False
    first_sentence = ""
    for character in text:
        first_sentence += character
        if character in ".!?\n":
            break
    return len(first_sentence) <= 60 and first_sentence.count(",") <= 1


def strip_llm_preamble(content: str, *, strip_transcript_tags: bool = True) -> str:
    """Mirror String.strippingLLMPreamble v30 for EGOneConnector."""

    result = content.strip()
    acknowledgments = (
        "Certainly!",
        "Sure!",
        "Sure,",
        "Of course!",
        "Got it.",
        "Got it!",
        "Absolutely!",
        "Here you go:",
    )
    for acknowledgment in acknowledgments:
        if result.startswith(acknowledgment):
            after = result[len(acknowledgment) :].strip()
            if _first_line_looks_like_preamble(after) or _first_sentence_is_standalone_reply(
                after
            ):
                result = after
            break

    if _first_line_looks_like_preamble(result):
        result = result.partition("\n")[2].strip()

    if strip_transcript_tags:
        result = re.sub(r"</?transcript>", "", result, flags=re.IGNORECASE).strip()
    return result


def parse_success(payload: Any) -> tuple[str, str | None]:
    """Return cleaned content and finish reason or fail as the connector would."""

    if not isinstance(payload, dict):
        raise EG1ShippedResponseError("malformed_response")
    choices = payload.get("choices")
    if (
        not isinstance(choices, list)
        or not choices
        or any(not isinstance(choice, dict) for choice in choices)
    ):
        raise EG1ShippedResponseError("malformed_response")
    choice = choices[0]
    finish_reason = choice.get("finish_reason")
    if finish_reason == "length":
        raise EG1ShippedResponseError("output_truncated")
    message = choice.get("message")
    if not isinstance(message, dict):
        raise EG1ShippedResponseError("malformed_response")
    content = message.get("content")
    if not isinstance(content, str) or not content:
        raise EG1ShippedResponseError("empty_response")
    cleaned = strip_llm_preamble(content, strip_transcript_tags=True)
    if not cleaned:
        raise EG1ShippedResponseError("empty_after_cleanup")
    return cleaned, finish_reason if isinstance(finish_reason, str) else None
