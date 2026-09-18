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
    vetoed=True, reason     a single-token original that is a word people
                            use (row language or English, Zipf >= the single
                            floor), or a multi-token original whose tokens
                            JOINED are a word (Zipf >= the joined floor, so
                            `pine cone`, `blue tooth`, `low key` are caught
                            while `post hog` and `cuber netties` are not),
                            or either form found in the English dictionary
    vetoed=False            the veto has nothing to say; the classifier's
                            `safeAlias` stands

Policy history: the joined-form rule was added after the v4
policy-development set showed lexicalised compounds slipping through
(resource v2); edge-only punctuation stripping with combining marks kept
replaced the earlier normalisation (resource `edit-judge-veto-v3`, the
current one). A qualifying report needs a calibration set never seen
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
        return VetoDecision(covered=True, vetoed=False, reason=f"{what}: not a listed word, the classifier decides")

    def apply(self, probs: list[float], original: str, language: str) -> list[float]:
        """Probability triple after the veto: the safe mass moves to the
        unsafe class when vetoed or uncovered, so the downstream decision
        rule sees `correctionButUnsafe`; otherwise unchanged."""
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
