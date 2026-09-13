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
import unicodedata
from dataclasses import dataclass

# A tag the model must echo. Lowercase `s` + digits; nothing else is a tag.
_TAG = re.compile(r"</?s(\d+)>")
# Escaping adds ONE backslash before the `s` of any tag-shaped run, including a run that
# already carries backslashes, and unescaping removes exactly one, so `<\s2>` in a speaker's
# own words survives the round trip as `<\s2>` (Codex r1: a single-level escape turned it
# into `<s2>`). The boundary grammar can therefore never be forged by content.
_LITERAL = re.compile(r"<(/?)(\\*)s(\d+)>")
_ESCAPED = re.compile(r"<(/?)(\\+)s(\d+)>")


def escape_section(text: str) -> str:
    return _LITERAL.sub(lambda m: "<" + m[1] + "\\" + m[2] + "s" + m[3] + ">", text)


def unescape_section(text: str) -> str:
    return _ESCAPED.sub(lambda m: "<" + m[1] + m[2][1:] + "s" + m[3] + ">", text)


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
    # String compare, not int: `<s01>` is not `<s1>` (Codex r1).
    if [m[1] for m in found] != [str(i) for i in range(1, expected + 1)]:
        return None
    # Nothing but whitespace may sit outside the matched sections; a stray open or close
    # tag with no partner is non-whitespace and fails here too.
    if _SECTION.sub("", text).strip():
        return None
    # A tag INSIDE a matched section (`<s1>a<s2>b</s1><s2>c</s2>` matches twice and would
    # otherwise pass) is a miscount, not content: content tags arrive escaped.
    if any(_TAG.search(m[2]) for m in found):
        return None
    return [unescape_section(m[2]).strip() for m in found]


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


def _trim_punctuation(word: str) -> str:
    """Swift `trimmingCharacters(in: .punctuationCharacters)`: every Unicode `P*` category,
    so a dash after a filler ("um—") is trimmed like a comma (Codex r1)."""
    while word and unicodedata.category(word[0]).startswith("P"):
        word = word[1:]
    while word and unicodedata.category(word[-1]).startswith("P"):
        word = word[:-1]
    return word


def _characters(text: str) -> int:
    """Swift `String.count` counts grapheme clusters; the stdlib has no segmenter, so this
    counts code points after NFC normalisation. Known gap, stated: a combining sequence NFC
    cannot compose (e.g. a base letter with several marks) counts more here than in Swift,
    which can only make the expansion guard STRICTER on such text. Adding the `regex`
    package would close it, but the CI step runs the eval tests under bare stdlib python3
    (pr-check.yml, the eval-tests step), so the gap is documented rather than closed."""
    return len(unicodedata.normalize("NFC", text))


def looks_like_question(text: str) -> bool:
    """Mirror of `LLMPolishStep.looksLikeQuestion` (:1139-1184). `str.split()` splits on
    Unicode whitespace like Swift's `isWhitespace`."""
    if "?" in text:
        return True
    words = text.lower().strip().split()
    while words and _trim_punctuation(words[0]) in _FILLERS:
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
    if _characters(candidate) > max(_characters(original) * 3, 200):
        return SectionVerdict("rejectedExpansion", candidate)
    original_words = len(original.split())
    polished_words = len(candidate.split())
    drop_threshold = (original_words * 2 + 5 - 1) // 5
    if original_words >= 10 and polished_words < drop_threshold:
        return SectionVerdict("rejectedContentDrop", candidate)
    if looks_like_question(original) and not looks_like_question(candidate):
        return SectionVerdict("rejectedQuestionAnswer", candidate)
    return SectionVerdict("accepted", candidate)
