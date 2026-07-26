"""Benchmark the candidate options against the founder's 1,000-case multilingual set.

The point is to establish what each option is worth BEFORE building anything, and
to separate the easy half from the hard half so the hard half can be attacked on
its own.

Options measured here:
  0. TODAY          - concatenate the two recordings, change nothing.
  1. RIGHT-SIDE     - merge only when recording 1 does not end in . ! ?
                      (the rule already measured at 96.1% on real dictations)
  2. LEFT-SIDE      - merge when recording 1's last WORD cannot end a sentence,
                      regardless of the punctuation the transcriber appended.
                      Function words are a CLOSED class in every language, so
                      this is a few dozen words per language, not a dictionary of
                      the language.
  3. COMBINED       - 1 or 2.

Scored two ways: the MERGE/KEEP decision, and exact match of the final text
(which additionally requires correct punctuation, casing and spacing).
"""

import csv
import os
import re
import sys
from collections import defaultdict

CSV_PATH = os.path.expanduser("~/Downloads/enviouswispr_smart_casing_spacing_1000.csv")
TERMINATORS = (".", "!", "?")

# Closed-class function words that cannot END a finished sentence. Per language,
# a few dozen: articles, prepositions, conjunctions, infinitive markers,
# auxiliaries. This is a bounded linguistic class, not open vocabulary.
CANNOT_END = {
    "English": {
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "from",
        "by", "about", "into", "onto", "over", "under", "and", "or", "but",
        "nor", "so", "because", "although", "though", "while", "if", "unless",
        "until", "since", "that", "which", "who", "whom", "whose", "as",
        "is", "are", "was", "were", "be", "been", "being", "am", "has", "have",
        "had", "will", "would", "shall", "should", "can", "could", "may",
        "might", "must", "do", "does", "did", "my", "your", "his", "her",
        "its", "our", "their", "some", "any", "every", "each", "this", "these",
        "those", "very", "more", "most", "than", "then", "when", "where",
    },
    "Spanish": {
        "el", "la", "los", "las", "un", "una", "unos", "unas", "de", "del",
        "a", "al", "en", "con", "por", "para", "sin", "sobre", "entre", "hasta",
        "desde", "y", "o", "pero", "porque", "aunque", "si", "que", "cuando",
        "como", "mi", "tu", "su", "nuestro", "es", "son", "era", "ser", "estar",
        "está", "están", "he", "ha", "han", "muy", "más", "menos",
    },
    "French": {
        "le", "la", "les", "un", "une", "des", "de", "du", "au", "aux", "à",
        "en", "dans", "sur", "avec", "pour", "sans", "par", "entre", "chez",
        "et", "ou", "mais", "car", "parce", "que", "si", "quand", "comme",
        "mon", "ton", "son", "notre", "votre", "leur", "est", "sont", "était",
        "être", "avoir", "a", "ai", "ont", "très", "plus", "moins",
    },
    "German": {
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen",
        "einem", "einer", "eines", "und", "oder", "aber", "weil", "obwohl",
        "wenn", "dass", "als", "wie", "in", "an", "auf", "mit", "von", "zu",
        "für", "über", "unter", "bei", "nach", "vor", "durch", "ohne", "um",
        "ist", "sind", "war", "waren", "sein", "haben", "hat", "hatte", "wird",
        "werden", "kann", "können", "muss", "sehr", "mehr",
    },
    "Italian": {
        "il", "lo", "la", "i", "gli", "le", "un", "uno", "una", "di", "del",
        "della", "a", "al", "alla", "in", "nel", "con", "per", "su", "tra",
        "fra", "da", "e", "o", "ma", "perché", "anche", "se", "che", "quando",
        "come", "mio", "tuo", "suo", "nostro", "è", "sono", "era", "essere",
        "avere", "ha", "hanno", "molto", "più",
    },
    "Portuguese": {
        "o", "a", "os", "as", "um", "uma", "uns", "umas", "de", "do", "da",
        "dos", "das", "em", "no", "na", "com", "por", "para", "sem", "sobre",
        "entre", "até", "desde", "e", "ou", "mas", "porque", "embora", "se",
        "que", "quando", "como", "meu", "teu", "seu", "nosso", "é", "são",
        "era", "ser", "estar", "está", "tem", "têm", "muito", "mais",
    },
    "Polish": {
        "i", "oraz", "albo", "lub", "ale", "bo", "że", "aby", "żeby", "jeśli",
        "gdy", "kiedy", "jak", "w", "we", "na", "do", "od", "za", "przez",
        "dla", "o", "z", "ze", "po", "pod", "nad", "przy", "bez", "jest",
        "są", "był", "była", "być", "ma", "mają", "bardzo", "więcej",
    },
    "Dutch": {
        "de", "het", "een", "van", "in", "op", "aan", "met", "voor", "door",
        "over", "onder", "bij", "naar", "uit", "om", "te", "en", "of", "maar",
        "want", "omdat", "hoewel", "als", "dat", "die", "wanneer", "hoe",
        "mijn", "jouw", "zijn", "haar", "onze", "is", "zijn", "was", "waren",
        "heeft", "hebben", "had", "kan", "kunnen", "moet", "zeer", "meer",
    },
}


def last_word(text):
    words = re.findall(r"[^\W\d_]+", text, flags=re.UNICODE)
    return words[-1].lower() if words else ""


def merge_text(r1, r2):
    """Join, dropping recording 1's terminal punctuation and lowering
    recording 2's leading capital. Spacing normalized to a single space."""
    left = r1.strip()
    left = re.sub(r"[.!?]+$", "", left).rstrip()
    right = r2.strip()
    if right and right[0].isupper():
        first = right.split()[0] if right.split() else ""
        bare = first.rstrip(".,!?;:")
        # Leave acronyms and mixed-case tokens alone (CI, OpenAI).
        if not (len(bare) > 1 and any(c.isupper() for c in bare[1:])) and not bare.isupper():
            right = right[0].lower() + right[1:]
    return f"{left} {right}"


def keep_text(r1, r2):
    """Keep the boundary, but normalize it: recording 1 gets a terminal period if
    it has none (or a comma), recording 2 keeps its capital, single space."""
    left = r1.strip()
    left = re.sub(r"[,;:]+$", "", left).rstrip()
    if not left.endswith(TERMINATORS):
        left += "."
    right = r2.strip()
    if right and right[0].islower():
        right = right[0].upper() + right[1:]
    return f"{left} {right}"


def decide(r1, r2, language, mode):
    stripped = r1.strip()
    unterminated = not stripped.endswith(TERMINATORS)
    lw = last_word(stripped)
    cannot_end = lw in CANNOT_END.get(language, set())
    if mode == "right":
        return unterminated
    if mode == "left":
        return cannot_end
    if mode == "combined":
        return unterminated or cannot_end
    raise ValueError(mode)


def main():
    rows = list(csv.DictReader(open(CSV_PATH, encoding="utf-8-sig")))
    modes = ["today", "right", "left", "combined"]
    agg = {m: defaultdict(lambda: {"n": 0, "dec": 0, "exact": 0, "wrong_merge": 0}) for m in modes}

    for r in rows:
        r1, r2 = r["recording_1"], r["recording_2"]
        want_merge = r["expected_action"] == "MERGE"
        gold = r["expected_output"].strip()
        lang, diff = r["language"], r["difficulty"]
        hard_half = r1.strip().endswith(TERMINATORS)

        for mode in modes:
            if mode == "today":
                merged = False
                got = f"{r1.strip()} {r2.strip()}"
            else:
                merged = decide(r1, r2, lang, mode)
                got = merge_text(r1, r2) if merged else keep_text(r1, r2)
            for bucket in ("ALL", lang, f"difficulty:{diff}", "half:hard" if hard_half else "half:easy"):
                s = agg[mode][bucket]
                s["n"] += 1
                s["dec"] += int(merged == want_merge)
                s["exact"] += int(got.strip() == gold)
                if merged and not want_merge:
                    s["wrong_merge"] += 1

    def show(buckets, title):
        print(f"\n{title}")
        print(f"{'bucket':22} " + " ".join(f"{m:>22}" for m in modes))
        print("-" * (22 + 23 * len(modes)))
        for b in buckets:
            cells = []
            for m in modes:
                s = agg[m][b]
                if not s["n"]:
                    cells.append(f"{'-':>22}")
                    continue
                cells.append(
                    f"{100*s['dec']/s['n']:5.1f}%dec {100*s['exact']/s['n']:5.1f}%ex"
                )
            print(f"{b:22} " + " ".join(f"{c:>22}" for c in cells))

    show(["ALL", "half:easy", "half:hard"], "OVERALL and by half (dec = merge/keep decision, ex = exact text)")
    show([f"difficulty:{d}" for d in ("easy", "medium", "hard")], "By difficulty")
    show(sorted({r["language"] for r in rows}), "By language")

    print("\nWRONG MERGES (corrupt correct text) out of 100 KEEP_BOUNDARY cases:")
    for m in modes:
        print(f"  {m:10} {agg[m]['ALL']['wrong_merge']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
