"""One definition of "were these two sentences joined", used by every harness.

Three harnesses each answered this differently and each was wrong, in a
different way, and each wrong answer changed a number that had already been
reported:

  "the output differs from the input"   a casing or punctuation tweak anywhere
                                        scored as a successful merge
  "fewer than two sentence marks"       an output that drops only its FINAL
                                        full stop — "First sentence. Second
                                        sentence" — scores as joined while the
                                        boundary is plainly still there

Both are proxies. The actual question is narrow and answerable directly: is
there still a sentence boundary BETWEEN the two halves? Everything else the
model does — fixing a comma, contracting "it is", changing the closing
punctuation — is irrelevant to it.

So: find where the first half ends and the second half begins in the output,
and look at the text between them. A sentence terminator in that gap means the
seam survived. No terminator means it was welded.

Kept in one place because the same defect appeared in three copies, which is
how it survived two review rounds.
"""

import re

TERMINATORS = ".!?"


def _words(text):
    return re.findall(r"[A-Za-z0-9']+", text)


def _find_last(haystack_words, needle, start=0):
    """Index of the last occurrence of `needle` in `haystack_words`."""
    found = -1
    for index in range(start, len(haystack_words)):
        if haystack_words[index].lower() == needle.lower():
            found = index
    return found


def was_joined(first, second, output):
    """True when no sentence boundary remains between the two halves.

    Returns None when the halves cannot be located in the output at all, which
    means the model rewrote things so heavily that "joined" is not the right
    question — the caller should treat that as a separate outcome rather than
    silently counting it either way.
    """
    out_words = _words(output)
    first_words, second_words = _words(first), _words(second)
    if not out_words or not first_words or not second_words:
        return None

    # Anchor on the last word of the first half and the first word of the
    # second. Both survive any reasonable edit; the punctuation between them is
    # exactly what the join changes.
    tail_word, head_word = first_words[-1], second_words[0]

    tail_matches = [m for m in re.finditer(rf"\b{re.escape(tail_word)}\b", output,
                                           re.IGNORECASE)]
    if not tail_matches:
        return None
    tail_end = tail_matches[0].end()

    head_match = re.search(rf"\b{re.escape(head_word)}\b", output[tail_end:],
                           re.IGNORECASE)
    if not head_match:
        return None

    gap = output[tail_end:tail_end + head_match.start()]
    return not any(mark in gap for mark in TERMINATORS)
