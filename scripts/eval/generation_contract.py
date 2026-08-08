#!/usr/bin/env python3
"""Small model-generation contract helpers with no ML runtime dependency."""

from __future__ import annotations

from typing import Any


def resolve_eos_token_id(generation_config: Any, tokenizer_eos_token_id: Any) -> Any:
    """Preserve a publisher EOS value/list, falling back only when absent."""

    configured = getattr(generation_config, "eos_token_id", None)
    return configured if configured is not None else tokenizer_eos_token_id
