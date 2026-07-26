"""Four-arm experiment harness for the seam-joining problem.

Arms are pluggable so variants are cheap to add. The founder's standing
instruction (2026-07-25): one result is one variation, never a verdict. Add
variants here rather than rewriting the harness.

  arm_today        what the app pastes now: the two recordings, unchanged
  arm_deterministic  closed-class rules only, no model
  arm_gector_full  Grammarly's GECToR over the whole joined text
  arm_gector_seam  GECToR restricted to a window around the seam, so it
                   physically cannot edit text far from the cursor
  arm_classifier   (pending) trained seam classifier - council's proposal

Every arm has the same signature: (rec1, rec2, language) -> final text.
"""

import re

TERMINATORS = (".", "!", "?")

# Closed-class function words that cannot END a finished sentence.
from bench_options import CANNOT_END  # noqa: E402


# ---------------------------------------------------------------- shared edits


def apply_merge(left, right, separator=" "):
    """Join two recordings, changing ONLY the seam.

    Every rule here exists because blind grading caught it failing:
      - MERGE_SPACE means the seam IS a space, so a comma the transcriber added
        at the pause is stripped too, not just a full stop. Keeping it produced
        "Please remember to, lock the door."
      - a comma is never doubled when the left half already ends in one
      - a single capital letter ("A") is not an acronym; "I" is protected by name
      - a word the speaker repeated across the pause is dropped once. The
        recogniser hears the tail of recording 1 again at the head of recording
        2, producing "finish the the report" / "check check whether".
    """
    left = left.strip()
    right = right.strip()
    # Strip whatever punctuation the transcriber stuck on the pause.
    left = re.sub(r"[.!?]+$", "", left).rstrip()
    if separator.startswith(",") or separator.isspace() or separator == "":
        left = left.rstrip(",").rstrip()

    if right and right[0].isupper():
        first = right.split()[0] if right.split() else ""
        bare = first.rstrip(".,!?;:")
        protected = (
            bare == "I" or bare.startswith("I'")
            or (len(bare) > 1 and any(c.isupper() for c in bare[1:]))
            or (len(bare) > 1 and bare.isupper())
        )
        if not protected:
            right = right[0].lower() + right[1:]

    # Drop a word the speaker repeated across the pause.
    lw, rw = left.split(), right.split()
    if lw and rw:
        tail = lw[-1].rstrip(".,!?;:").lower()
        head = rw[0].rstrip(".,!?;:").lower()
        if tail and tail == head:
            rw = rw[1:]
            right = " ".join(rw)
            if right and right[0].isupper() and len(right.split()[0]) == 1:
                pass
    if not right:
        return left
    return f"{left}{separator}{right}"


INTERROGATIVE_OPENERS = {
    # closed set: words that can begin a direct question in English
    "are", "is", "am", "was", "were", "do", "does", "did", "can", "could",
    "should", "would", "will", "shall", "may", "might", "must", "have", "has",
    "had", "what", "where", "when", "why", "who", "whom", "whose", "which",
    "how",
}


def _looks_like_question(text):
    """Does this clause read as a direct question?

    Blind grading round 3 let two of these through: "Are you free after lunch."
    and "Should I call the pharmacy again." Both keep a boundary correctly but
    get a full stop where a question mark belongs, because the code only ever
    supplied ".". The opener set is closed, so this needs no vocabulary.
    """
    words = re.findall(r"[^\W\d_]+", text, flags=re.UNICODE)
    return bool(words) and words[0].lower() in INTERROGATIVE_OPENERS


def apply_keep(left, right):
    """Keep the two thoughts separate - and punctuate the boundary correctly.

    A missing terminator is supplied, a trailing comma is promoted, and a clause
    that reads as a question gets a question mark rather than a full stop.
    """
    left = left.strip()
    right = right.strip()
    had_question = left.rstrip().endswith("?")
    left = re.sub(r"[,;:]+$", "", left).rstrip()
    if left.endswith((".", "!", "?")):
        # An existing full stop on a question is the transcriber's mistake.
        if left.endswith(".") and (had_question or _looks_like_question(left)):
            left = left[:-1] + "?"
    else:
        left += "?" if _looks_like_question(left) else "."
    if right and right[0].islower():
        right = right[0].upper() + right[1:]
    return f"{left} {right}"


# ------------------------------------------------------------------- the arms


def arm_today(rec1, rec2, language=None):
    return f"{rec1.strip()} {rec2.strip()}"


def arm_deterministic(rec1, rec2, language="English"):
    """Merge only when recording 1 is provably unfinished. Two certificates:
    it has no terminal punctuation at all, OR its last word is a closed-class
    function word that cannot end a sentence in that language."""
    stripped = rec1.strip()
    words = re.findall(r"[^\W\d_]+", stripped, flags=re.UNICODE)
    last = words[-1].lower() if words else ""

    # BOTH certificates, not just the second. The docstring has always promised
    # two, and the deterministic arm is the baseline every other arm is measured
    # against, so an arm that silently implements half its stated rule
    # understates the deterministic floor and flatters everything compared to
    # it. "We should release" — no terminator, ordinary final word — was being
    # given a full stop and counted as a KEEP. Found by cloud review on PR #1793.
    no_terminator = not stripped.endswith((".", "!", "?", "…"))
    cannot_end = last in CANNOT_END.get(language, set())
    if no_terminator or cannot_end:
        return apply_merge(stripped, rec2)
    return apply_keep(stripped, rec2)


class GECToRArm:
    """Grammarly's tagger. `window` limits how much text it may see and edit.

    window=None  -> the whole joined text (what off-the-shelf use looks like)
    window=N     -> only N words either side of the seam are passed through the
                    model; the rest is spliced back verbatim, so text far from
                    the cursor is untouchable by construction.
    """

    def __init__(self, model_id="gotutiyan/gector-roberta-base-5k", window=None,
                 keep_confidence=0.0, min_error_prob=0.0, n_iteration=5):
        from gector.modeling import GECToR
        from gector.predict import load_verb_dict
        from transformers import AutoTokenizer

        self.model = GECToR.from_pretrained(model_id)
        self.model.eval()
        self.tok = AutoTokenizer.from_pretrained(model_id)
        self.enc, self.dec = load_verb_dict("verb-form-vocab.txt")
        self.window = window
        self.keep_confidence = keep_confidence
        self.min_error_prob = min_error_prob
        self.n_iteration = n_iteration

    def _run(self, texts):
        from gector.predict import predict

        return predict(
            self.model, self.tok, texts, self.enc, self.dec,
            keep_confidence=self.keep_confidence,
            min_error_prob=self.min_error_prob,
            n_iteration=self.n_iteration,
            batch_size=max(1, min(64, len(texts))),
        )

    def batch(self, pairs):
        """pairs: [(rec1, rec2, language)] -> [final text]"""
        prefixes, probes, suffixes = [], [], []
        for rec1, rec2, _lang in pairs:
            left, right = rec1.strip(), rec2.strip()
            if self.window is None:
                prefixes.append("")
                probes.append(f"{left} {right}")
                suffixes.append("")
                continue
            lw, rw = left.split(), right.split()
            head, tail = lw[: max(0, len(lw) - self.window)], lw[max(0, len(lw) - self.window):]
            r_head, r_tail = rw[: self.window], rw[self.window:]
            prefixes.append(" ".join(head))
            probes.append(" ".join(tail + r_head))
            suffixes.append(" ".join(r_tail))
        corrected = self._run(probes)
        out = []
        for pre, mid, suf in zip(prefixes, corrected, suffixes):
            out.append(" ".join(p for p in (pre.strip(), mid.strip(), suf.strip()) if p))
        return out
