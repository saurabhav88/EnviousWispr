#!/usr/bin/env python3
"""Pinned text normalizer for the EG-1 English replay inventory."""

from __future__ import annotations

import re
import unicodedata


NORMALIZER_VERSION = "eg1-replay-normalizer-v1"


def normalize_text(value: str) -> str:
    """Return the punctuation-insensitive comparison form used by the audit."""

    folded = unicodedata.normalize("NFKC", value).casefold()
    return " ".join(re.findall(r"[^\W_]+", folded, flags=re.UNICODE))


def normalize_full_symbol_text(value: str) -> str:
    """Preserve symbols when word normalization would otherwise be empty."""

    folded = unicodedata.normalize("NFKC", value).casefold()
    return " ".join(folded.split())


def normalize_identity(value: str) -> tuple[str, str]:
    """Return a domain-tagged identity, or ``invalid`` for empty content."""

    word_value = normalize_text(value)
    if word_value:
        return ("word", word_value)
    full_value = normalize_full_symbol_text(value)
    if full_value:
        return ("full_symbol_fallback", full_value)
    return ("invalid", "")
