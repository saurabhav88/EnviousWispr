#!/usr/bin/env python3
"""The alias veto stage of the edit judge, Python side (#996 chunk 3, veto portion).

Deterministic policy applied AFTER the classifier and BEFORE a `safeAlias`
decision is granted (plan §3.1 step 7). It never touches
`vocabularyCorrection`; it can only demote `correctionAndSafe` to
`correctionButUnsafe`.

  veto(original, language) ->
    covered=False           the row's language has no list, or its list was
                            never measured to carry that language's common
                            given names (`policy.alias_languages`): ABSTAIN,
                            and the judge grants no alias for that row while
                            the corrected spelling is still learned
    vetoed=True, reason     a single-token original that is a listed word
                            (row language or English, Zipf >= the single
                            floor), or a multi-token original whose tokens
                            JOINED are a word (Zipf >= the joined floor, so
                            `pine cone`, `blue tooth`, `low key` are caught),
                            or either form found in the English dictionary,
                            or a multi-token original whose EVERY token is a
                            word people use (Zipf >= the all-tokens floor:
                            `head scale`, `wire guard`, `pie hole`; this also
                            refuses `post hog` and `key cloak`, real-word
                            mishears the labels call safe, and `cuber
                            netties` stays with the classifier), or a
                            dictated letter or number sequence (policy v7:
                            two or more English letter names such as
                            `scylla dee bee`, `fresh are ess ess`, or any
                            single Latin letter, all-digit or vowelless
                            2-3 letter token such as `silla db`, `weave 8`,
                            `mini o`; adjudicated UNSAFE on the v8 set)
    vetoed=False            the veto has nothing to say; the classifier's
                            `safeAlias` stands

Policy history: the joined-form rule was added after the v4
policy-development set showed lexicalised compounds slipping through
(resource v2); edge-only punctuation stripping with combining marks kept
replaced the earlier normalisation (v3); alias languages (v4, v5); the
all-tokens floor and the single floor at 2.0 came from the v6 set, where
six two-word phrases (`head scale`, `pie hole`, `tan door`, `wire guard`,
`next cloud`, `health checks`) and `guacamole` (Zipf 2.91) were granted
(resource `edit-judge-veto-v6`, the current one). A qualifying report needs a calibration set never seen
during that development. The Swift port (chunk 2d) must prove parity
against this file; the resource manifest digest, policy and this file's
digest are part of the judge's execution identity, so a different list,
policy or implementation is a different judge.
"""
from __future__ import annotations

import hashlib
import json
import unicodedata
from dataclasses import dataclass
from pathlib import Path

def normalise_token(token: str) -> str:
    """NFC, casefold, then strip PUNCTUATION from both edges only. Combining
    marks and vowel signs (Devanagari, Arabic, decomposed accents) are part
    of the word and are kept; the resource builder uses this same function,
    so a listed word and a runtime lookup agree (Codex 3a finding 2)."""
    value = unicodedata.normalize("NFC", token.casefold().strip())
    start, end = 0, len(value)
    while start < end and unicodedata.category(value[start]).startswith("P"):
        start += 1
    while end > start and unicodedata.category(value[end - 1]).startswith("P"):
        end -= 1
    return value[start:end].strip()


def casing_only(original: str, replacement: str) -> bool:
    """True when the edit changes only letter case (NFC, casefold): formatting,
    never a vocabulary correction. Casefold also folds `heisst`/`heißt`, which
    the frozen row EC-NON_ENGLISH-003 labels notCorrection. One authority for
    the eval; the runtime alignment (`EditAlignment`) must agree with it
    (parity proven in 2d)."""
    return unicodedata.normalize("NFC", original).casefold() == unicodedata.normalize("NFC", replacement).casefold()


@dataclass
class VetoDecision:
    covered: bool
    vetoed: bool
    reason: str


class AliasVeto:
    def __init__(self, resource_dir: Path):
        self.resource_dir = resource_dir
        self.manifest = json.loads((resource_dir / "manifest.json").read_text(encoding="utf-8"))
        self.version = self.manifest["version"]
        self.manifest_sha256 = hashlib.sha256((resource_dir / "manifest.json").read_bytes()).hexdigest()
        self._zipf: dict[str, dict[str, float]] = {}
        self._dictionary: set[str] = set()
        for key, entry in self.manifest["files"].items():
            path = resource_dir / entry["path"]
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            if actual != entry["sha256"]:
                raise RuntimeError(f"veto resource {entry['path']} digest differs from its manifest")
            if key == "en-dictionary":
                self._dictionary = set(path.read_text(encoding="utf-8").split("\n")) - {""}
            else:
                table: dict[str, float] = {}
                for line in path.read_text(encoding="utf-8").split("\n"):
                    if line:
                        w, z = line.split("\t")
                        table[w] = float(z)
                self._zipf[key] = table
        self.languages = set(self.manifest["languages"])
        self.policy = self.manifest["policy"]
        # Frequency-list AVAILABILITY, not validated alias-safety coverage:
        # every advertised language must have a non-empty table, English
        # (checked for every row) must be among them, and no table may be
        # advertised without a file (Codex 3a finding 3).
        if self.languages != set(self._zipf):
            raise RuntimeError("veto resource: advertised languages differ from loaded tables")
        if "en" not in self.languages or any(not table for table in self._zipf.values()):
            raise RuntimeError("veto resource has missing or empty required coverage")
        # Alias grants are limited to languages whose NAME coverage was
        # measured (founder decision 2026-09-18); the list must be explicit,
        # non-empty and a subset of the loaded tables.
        alias = self.policy.get("alias_languages")
        evidence = self.policy.get("alias_languages_evidence")
        if (
            not isinstance(alias, list)
            or not alias
            or not all(isinstance(x, str) and x.strip() for x in alias)
            or not set(alias) <= self.languages
            or not isinstance(evidence, str)
            or not evidence.strip()
        ):
            raise RuntimeError("veto resource: policy.alias_languages requires loaded tables and non-empty string alias_languages_evidence")
        self.alias_languages = set(alias)
        names = self.policy.get("letter_names")
        if not isinstance(names, list) or not names or not all(isinstance(x, str) and x.strip() for x in names) or not isinstance(self.policy.get("spelled_sequence_min"), int):
            raise RuntimeError("veto resource: policy.letter_names must be a non-empty list of strings with an integer spelled_sequence_min")
        self._letter_names = {normalise_token(x) for x in names}

    def has_frequency_list(self, language: str) -> bool:
        """True when the row's language has a frequency list. This is list
        availability only; it does not say the list carries that language's
        common given names (wordfreq lists words, not names, and zh/ko name
        misses were measured)."""
        return language.split("-")[0].casefold() in self.languages

    def covers(self, language: str) -> bool:
        """True only when the language may grant an alias: it has a list AND
        its name coverage was measured (`policy.alias_languages`)."""
        lang = language.split("-")[0].casefold()
        return self.has_frequency_list(lang) and lang in self.alias_languages

    def veto(self, original: str, language: str) -> VetoDecision:
        lang = language.split("-")[0].casefold()
        if not self.has_frequency_list(lang):
            return VetoDecision(covered=False, vetoed=False, reason=f"language {lang!r} has no list in {self.version}: abstain, no alias")
        if not self.covers(lang):
            return VetoDecision(covered=False, vetoed=False, reason=f"language {lang!r} name coverage unproven in {self.version}: abstain, no alias")
        tokens = [normalise_token(t) for t in original.split()]
        tokens = [t for t in tokens if t]
        if not tokens:
            return VetoDecision(covered=True, vetoed=False, reason="empty original: the classifier decides")
        if len(tokens) == 1:
            token, floor, what = tokens[0], self.policy["zipf_single_min"], "single-token original"
        else:
            token, floor, what = "".join(tokens), self.policy["zipf_joined_min"], "multi-token original joined"
        for check_lang in dict.fromkeys([lang, "en"]):
            z = self._zipf.get(check_lang, {}).get(token)
            if z is not None and z >= floor:
                return VetoDecision(covered=True, vetoed=True, reason=f"{what} {token!r} is a word in {check_lang} (zipf {z:.2f} >= {floor})")
        if len(token) >= self.policy["dictionary_min_letters"] and token in self._dictionary:
            return VetoDecision(covered=True, vetoed=True, reason=f"{what} {token!r} is an English dictionary word")
        if len(tokens) >= 2:
            all_floor = self.policy["zipf_all_tokens_min"]
            best = [max(self._zipf.get(l, {}).get(t, 0.0) for l in dict.fromkeys([lang, "en"])) for t in tokens]
            if all(z >= all_floor for z in best):
                return VetoDecision(covered=True, vetoed=True, reason=f"multi-token original: every token is a word people use (zipf {', '.join(f'{z:.2f}' for z in best)} >= {all_floor}), a plausible phrase")
        spelled = self.spelled(tokens)
        if spelled:
            return VetoDecision(covered=True, vetoed=True, reason=f"original is a dictated letter or number sequence ({spelled})")
        return VetoDecision(covered=True, vetoed=False, reason=f"{what}: not a listed word, the classifier decides")

    def spelled(self, tokens: list[str]) -> str:
        """Policy v7: the reason string when the tokens read as a dictated
        letter or number sequence, else ''. At least `spelled_sequence_min`
        English letter names (`dee bee`), or any token that is one Latin
        letter, all digits, or two to three Latin letters with no vowel
        (`db`, `rss`, `ngx`, `8`).
        This is a conservative PATTERN detector, not a reading of meaning
        (Codex 3c r4): it sees `blarg cee pee` and not `blarg see pee`,
        `blarg api` or `blarg q4`; homophone spellings of letter names are
        deliberately absent because they are ordinary words (`see`, `tea`,
        `you`). Do not extend the table to imply completeness; the
        classifier decides what this branch does not see, and the exam
        measures the result. Lost safe aliases under this branch:
        `et cee dee -> etcd`, `paperless en gee ex`, `no co dee bee`."""
        names = self._letter_names
        letter_count = sum(1 for t in tokens if t in names)
        if letter_count >= self.policy["spelled_sequence_min"]:
            return f"{letter_count} letter names"
        for t in tokens:
            if t.isdigit():
                return f"digit token {t!r}"
            if t.isascii() and t.isalpha() and (len(t) == 1 or (len(t) <= 3 and not any(ch in "aeiouy" for ch in t))):
                return f"spelled token {t!r}"
        return ""

    def apply(self, probs: list[float], original: str, language: str, replacement: str | None = None) -> list[float]:
        """Probability triple after stage one. A casing-only edit
        (`replacement` given and equal to `original` after NFC casefold) is
        `notCorrection` outright: an evaluation override equivalent to the
        runtime alignment drop before the judge (plan §3.1 step 5; frozen
        convention EC-BRAND-006). The eval still computes the classifier
        first; the runtime skip and its latency are 2d obligations.
        Otherwise the safe mass moves to the
        unsafe class when vetoed or uncovered, so the downstream decision
        rule sees `correctionButUnsafe`; else unchanged."""
        if replacement is not None and casing_only(original, replacement):
            return [1.0, 0.0, 0.0]
        d = self.veto(original, language)
        if d.vetoed or not d.covered:
            return [probs[0], probs[1] + probs[2], 0.0]
        return list(probs)

    def identity(self) -> dict:
        """Resource bytes, policy AND implementation: normalisation, joining
        and demotion live in this file, so its digest is part of the judge's
        identity (a later Swift port must prove parity against it)."""
        return {
            "veto_version": self.version,
            "veto_manifest_sha256": self.manifest_sha256,
            "veto_policy": self.manifest["policy"],
            "veto_implementation_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        }
