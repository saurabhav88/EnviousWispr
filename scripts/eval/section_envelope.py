#!/usr/bin/env python3
"""#2851 phase 2: the section envelope, mirrored in Python for the pack-fidelity measurement.

The plan (`docs/feature-requests/issue-2851-2026-09-13-cloud-packing.md` §3 A, C, D) sends several
speaker sections in ONE cloud call, each wrapped in numbered tags, and cuts the answer back into
sections by the same tags. Nothing here is shipped; this is the eval-side mirror the runner uses so
the measurement exercises the same codec, the same addendum and the same per-section acceptance the
Swift `SectionEnvelope` will carry. When the Swift lands, its tests and this file's tests must agree
row for row (the same discipline as `test_preamble_mirror.py`).

Grammar: `<s1>…</s1>\n<s2>…</s2>…<sN>…</sN>`. A section whose own words contain a literal tag of that
shape is escaped so a speaker cannot forge a boundary. `unwrap_sections` is strict: exactly the tags
1…N, each opened and closed once, ascending, nothing but whitespace outside them, or it returns None
(a miscount, never a partial list).
"""
from __future__ import annotations

import re
from dataclasses import dataclass

# A tag the model must echo. Lowercase `s` + digits; nothing else is a tag.
_TAG = re.compile(r"</?s(\d+)>")
# Escaping: a literal tag inside a section's words becomes `<\s1>` / `</\s1>` on the way in
# and is restored on the way out, so the boundary grammar cannot be forged by content.
_ESCAPED = re.compile(r"<(/?)\\s(\d+)>")


def escape_section(text: str) -> str:
    return _TAG.sub(lambda m: m.group(0).replace("s", "\\s", 1), text)


def unescape_section(text: str) -> str:
    return _ESCAPED.sub(lambda m: f"<{m.group(1)}s{m.group(2)}>", text)


def wrap_sections(sections: list[str]) -> str:
    """`<s1>…</s1>\n<s2>…</s2>`, one line per section, 1-based, content escaped."""
    if not sections:
        raise ValueError("a pack needs at least one section")
    return "\n".join(
        f"<s{i}>{escape_section(text)}</s{i}>" for i, text in enumerate(sections, start=1)
    )


def pack_addendum(section_count: int) -> str:
    """Appended AFTER the unchanged v7 system prompt, only for a pack (plan §3 D). A separate
    literal so the v7 three-way mirror self-test keeps holding."""
    n = section_count
    return (
        f"\n\nThe text contains {n} sections, each between <sK> and </sK> for K from 1 to {n}. "
        "Clean each section on its own. Return all sections, in the same order, with the same "
        "tags, and nothing outside the tags. Never merge, drop, reorder or add a section."
    )


_SECTION = re.compile(r"<s(\d+)>(.*?)</s\1>", re.DOTALL)


def unwrap_sections(text: str, expected: int) -> list[str] | None:
    """The count-and-order validation. Returns the N inner texts (unescaped, stripped of the
    surrounding whitespace the wrapper added) or None for any of: a missing tag, an extra tag,
    a duplicated tag, tags out of order, a tag outside 1…N, an unclosed tag, or non-whitespace
    text outside the tags."""
    if expected < 1:
        return None
    found = list(_SECTION.finditer(text))
    if len(found) != expected:
        return None
    numbers = [int(m.group(1)) for m in found]
    if numbers != list(range(1, expected + 1)):
        return None
    # Nothing but whitespace may sit outside the matched sections.
    outside = _SECTION.sub("", text)
    if outside.strip():
        return None
    # An opening or closing tag that survived outside a matched pair (a stray `<s3>` with no
    # close, or a close with no open) shows up here as a leftover tag in `outside`.
    if _TAG.search(outside):
        return None
    return [unescape_section(m.group(2)).strip() for m in found]


@dataclass(frozen=True)
class SectionVerdict:
    """The per-section acceptance the plan's §3 C.4 applies AFTER a pack unwraps: a mirror of
    `LLMPolishStep.validatePolishOutput` for `.message` (LLMPolishStep.swift:1057-1130):
    expansion over max(len(original) × 3, 200) characters; a word COUNT under
    ceil(original words × 2/5) when the original has at least 10 words; a question turned
    into a non-question; plus non-empty (the connector's own empty-response guard)."""

    status: str  # accepted | empty | rejectedExpansion | rejectedContentDrop | rejectedQuestionAnswer
    candidate: str


_FILLERS = {"um", "uh", "so", "like", "well", "okay", "ok"}
_AUXILIARY = {"should", "can", "do", "does", "did", "is", "are", "could", "would", "has", "have", "will"}
_WH = {"how", "what", "where", "when", "who", "why"}
_INDIRECT = [
    "i was wondering if", "i'm wondering if", "wondering if", "whether we should",
    "do you know if", "is there a", "are we",
]
_PUNCT = ".,;:!?\"'()[]{}"


def looks_like_question(text: str) -> bool:
    """Mirror of `LLMPolishStep.looksLikeQuestion` (:1139-1184)."""
    if "?" in text:
        return True
    words = text.lower().strip().split()
    while words and words[0].strip(_PUNCT) in _FILLERS:
        words.pop(0)
    if not words:
        return False
    first = words[0]
    if first in _AUXILIARY:
        return True
    if first in _WH:
        second = words[1] if len(words) > 1 else ""
        if second in _AUXILIARY or second in {"many", "much", "long", "often"}:
            return True
    joined = " ".join(words[:5])
    return any(joined.startswith(p) for p in _INDIRECT)


def accept_section(original: str, candidate: str) -> SectionVerdict:
    if not candidate.strip():
        return SectionVerdict("empty", "")
    if not original:
        return SectionVerdict("accepted", candidate)
    if len(candidate) > max(len(original) * 3, 200):
        return SectionVerdict("rejectedExpansion", candidate)
    original_words = len(original.split())
    polished_words = len(candidate.split())
    drop_threshold = (original_words * 2 + 5 - 1) // 5
    if original_words >= 10 and polished_words < drop_threshold:
        return SectionVerdict("rejectedContentDrop", candidate)
    if looks_like_question(original) and not looks_like_question(candidate):
        return SectionVerdict("rejectedQuestionAnswer", candidate)
    return SectionVerdict("accepted", candidate)
