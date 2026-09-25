#!/usr/bin/env python3
"""Edit-judge data contract — issue #996 (learn custom words from the user's own edits).

One owner for everything that decides whether a judge was TRAINED ON, TUNED ON
or otherwise EXPOSED TO the rows it is being scored against:

  * content hashes of edit rows (identity by CONTENT, never by row id, so a
    renamed or re-labelled copy of a frozen row is still the same row);
  * alias families (rows that teach the same canonical form), so a split can
    keep every row of a family on one side;
  * the frozen-report manifest for the 209 labelled rows (file digests plus
    the content-hash set), which `edit_judge_gate.py` checks before any run;
  * the training manifest a judge must carry to be scored on the frozen rows
    (what it trained on, what it calibrated on), and the leakage check that
    refuses a judge whose manifest overlaps the frozen set by hash or family;
  * a deterministic family-grouped splitter for generated data;
  * candidate builders that turn the vocabulary packs and the polish corpus
    into UNLABELLED candidate examples. A pack alias is a recogniser mishear,
    not a human judgement that learning it is safe; a polish change is a
    rewording candidate, not a labelled negative. Every candidate leaves here
    with `label: null` and `review_status: "unreviewed"`.

`edit_judge_gate.py` imports the hash and manifest functions; nothing here
reads or writes the gate's thresholds.
"""
from __future__ import annotations

import difflib
import hashlib
import json
import re
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Optional

# --- Hash contract ---

# Bump when the canonical form below changes. Manifests carry it, and the gate
# refuses a manifest whose version is not this one, so an old hash can never
# be compared with a new one and read as "no overlap".
HASH_VERSION = "edit-judge-content-hash-v1"

# Fields that make a row THE SAME EDIT: the language, the run the recogniser
# wrote, the run the user typed, and the sentence it happened in. Labels,
# notes, ids, strata, provenance and probe flags are excluded on purpose: a
# relabelled copy is the same edit.
CONTENT_FIELDS = ("language", "original", "replacement", "pasted")

THREE_CLASSES = ("notCorrection", "correctionButUnsafe", "correctionAndSafe")


# Review statuses a trainer may consume. Template rows are reviewed at the
# table (every entity and sentence frame was read); authored rows are model
# written (gpt-6-astra, 2026-09-19) and only a random sample was read by
# hand, so their status says so and the receipt carries the sample size.
# `blind-labelled-unanimous` rows were written by one model and labelled
# blind (rows only, no kind or author label) by two different models; the
# row is kept only when both blind labels equal the author label (founder
# 2026-09-19: no human review, model quality grading).
# `mined-heuristic-labelled` rows are real Parakeet outputs from the #685 TTS
# round trip: the label is true by construction (canonical versus its
# recorded mishearing) and the row was screened only by name-list membership
# and string similarity; nobody read it. Consumable as training data with
# that meaning, never as review evidence.
# `harvest-jev-labelled` rows (founder 2026-09-19, "1": hybrid review) are real
# human speech through Parakeet (transcript run versus recogniser run, positive by
# construction) whose blind label comes from ONE model labeller, Jev, agreeing
# with the construction label; a random audit sample and every row that lands in
# a dev or calibration partition additionally carry a second independent blind
# labeller and are minted `blind-labelled-unanimous` instead. Consumable as
# TRAINING data with that meaning; never review evidence, never a dev row.
# `unreviewed` rows (mined candidates with label null) are never training data.
REVIEWED_STATUSES = frozenset({"template-reviewed", "authored-sample-reviewed", "blind-labelled-unanimous", "mined-heuristic-labelled", "harvest-jev-labelled", "rule-constructed", "rule-labelled-real"})
# Statuses whose label rests on one model labeller: the corpus builder keeps
# these out of dev and calibration (they may only train).
# #3105 (2026-09-25 night finalist): `rule-constructed` rows (half-typed stops built
# from a real fix) and `rule-labelled-real` rows (real-speech pairs labelled by the
# founder's written rulings, #3105 comments 5826937409 and 5827148399) carry a rule
# label and no human review of each row, so they may only train as well.
TRAIN_ONLY_STATUSES = frozenset({"harvest-jev-labelled", "rule-constructed", "rule-labelled-real"})


def stage_one_shape_drop(original: str, replacement: str) -> bool:
    """Python mirror of the shipped `EditRunShape.isCasingOrPunctuationOnly`
    (plan §3.1 step 5): the two runs differ only in letter case, punctuation
    or symbols with the same word count. Alignment drops such runs before any
    judge; the trainer's development scoring and the eval runner apply the
    same rule so every number describes the shipped path. Parity with the
    Swift rule is pinned by `test_stage_one_shape_drop_matches_the_swift_fixtures`."""
    def words(text: str) -> list[str]:
        out = []
        for w in unicodedata.normalize("NFC", text).split():
            # Swift filters grapheme Characters (a base letter keeps its
            # combining marks); Python sees code points, so marks (category
            # M*) are kept explicitly or Devanagari matras would vanish.
            core = "".join(ch for ch in w if ch.isalnum() or unicodedata.category(ch).startswith("M")).lower()
            if core:
                out.append(core)
        return out
    o, r = words(original), words(replacement)
    if not o or len(o) != len(r):
        return False
    if unicodedata.normalize("NFC", original) == unicodedata.normalize("NFC", replacement):
        return False
    return o == r


def _nfc(text: str) -> str:
    return unicodedata.normalize("NFC", text)


def canonical_content(row: dict) -> list:
    """The exact list that is hashed. Text is NFC-normalised only: casing can
    be the whole edit, so it is never folded. Language is case-folded and
    stripped (`EN ` and `en` are one language)."""
    for key in CONTENT_FIELDS:
        if not isinstance(row.get(key), str):
            raise ValueError(f"row is missing string field {key!r}")
    return [
        HASH_VERSION,
        _nfc(row["language"]).strip().casefold(),
        _nfc(row["original"]),
        _nfc(row["replacement"]),
        _nfc(row["pasted"]),
    ]


def content_hash(row: dict) -> str:
    payload = json.dumps(canonical_content(row), ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


_WS = re.compile(r"\s+")


def family_key(row: dict) -> str:
    """Alias family: every row that teaches the same canonical form. NFC,
    case-folded, whitespace-collapsed `replacement`. A judge trained on
    'Kubernetes' rows must not be scored on a frozen 'kubernetes' row even
    when the sentence differs."""
    if not isinstance(row.get("replacement"), str):
        raise ValueError("row is missing string field 'replacement'")
    return _WS.sub(" ", _nfc(row["replacement"]).casefold().strip())


def three_class(correction: bool, safe_alias: bool) -> str:
    """The judge's three mutually exclusive classes from the two labels.
    (False, True) is not a class: an alias cannot be safe for a word that is
    not a correction, and the corpus validator refuses that row."""
    if type(correction) is not bool or type(safe_alias) is not bool:
        raise ValueError("labels must be bool")
    if not correction:
        if safe_alias:
            raise ValueError("safe_alias=true with correction=false is not a class")
        return "notCorrection"
    return "correctionAndSafe" if safe_alias else "correctionButUnsafe"


def labels_from_class(name: str) -> tuple[bool, bool]:
    if name == "notCorrection":
        return (False, False)
    if name == "correctionButUnsafe":
        return (True, False)
    if name == "correctionAndSafe":
        return (True, True)
    raise ValueError(f"unknown class {name!r}")


# --- Frozen-report manifest ---


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def frozen_partition(name: str, path: Path, rows: list[dict]) -> dict:
    hashes = [content_hash(r) for r in rows]
    return {
        "name": name,
        "path": path.name,
        "file_sha256": sha256_file(path),
        "rows": len(rows),
        "content_hashes": sorted(hashes),
        "families": sorted({family_key(r) for r in rows}),
    }


def build_frozen_manifest(partitions: list[tuple[str, Path, list[dict]]], frozen_at: str, note: str) -> dict:
    parts = [frozen_partition(n, p, rows) for n, p, rows in partitions]
    all_hashes = [h for p in parts for h in p["content_hashes"]]
    if len(all_hashes) != len(set(all_hashes)):
        raise ValueError("frozen partitions share a content hash")
    return {
        "hash_version": HASH_VERSION,
        "content_fields": list(CONTENT_FIELDS),
        "frozen_at": frozen_at,
        "note": note,
        "partitions": parts,
    }


def check_frozen(manifest: dict, partition_paths: dict[str, Path], loaded: dict[str, list[dict]]) -> list[str]:
    """Problems if the files on disk are not the frozen ones. Empty = frozen
    rows unchanged. Checks the file digest AND the content-hash set, so an
    edit that keeps the byte size, a reordering, or a re-labelling that
    changes hashed content are all caught; a label-only change is caught by
    the file digest."""
    problems: list[str] = []
    if manifest.get("hash_version") != HASH_VERSION:
        problems.append(f"frozen manifest hash_version {manifest.get('hash_version')!r} is not {HASH_VERSION}")
        return problems
    parts = {p.get("name"): p for p in manifest.get("partitions", []) if isinstance(p, dict)}
    for name, path in partition_paths.items():
        part = parts.get(name)
        if part is None:
            problems.append(f"frozen manifest has no partition {name}")
            continue
        if part.get("path") != path.name:
            problems.append(f"{name}: manifest path {part.get('path')!r} is not {path.name!r}")
        actual_sha = sha256_file(path)
        if part.get("file_sha256") != actual_sha:
            problems.append(f"{name}: file sha256 {actual_sha[:16]} differs from frozen {str(part.get('file_sha256'))[:16]}")
        rows = loaded[name]
        if part.get("rows") != len(rows):
            problems.append(f"{name}: {len(rows)} rows on disk, frozen {part.get('rows')}")
        actual_hashes = sorted(content_hash(r) for r in rows)
        if part.get("content_hashes") != actual_hashes:
            problems.append(f"{name}: content-hash set differs from the frozen set")
        actual_families = sorted({family_key(r) for r in rows})
        if part.get("families") != actual_families:
            problems.append(f"{name}: families differ from the frozen rows")
    for name in parts:
        if name not in partition_paths:
            problems.append(f"frozen manifest partition {name} has no file on this run")
    return problems


def frozen_hashes(manifest: dict) -> set[str]:
    return {h for p in manifest.get("partitions", []) for h in p.get("content_hashes", [])}


def frozen_families(manifest: dict) -> set[str]:
    return {f for p in manifest.get("partitions", []) for f in p.get("families", [])}


# --- Training manifest ---

TRAINING_KINDS = ("trained", "untrained-arm")
TRAINING_PARTITIONS = ("train", "dev", "calibration")
# Optional declared population: the separately authored cross-author
# development partition that co-selects the threshold (#996 chunk 4a-ii). A
# trained judge need not have one; when it does, it is leakage-checked like
# the three required partitions.
OPTIONAL_TRAINING_PARTITIONS = ("cross_dev",)
# Candidate families that can only be scored as TRAINED judges: a cross-encoder
# with no training data is not a judge, so it cannot file an untrained-arm
# manifest to slip past the leakage check.
TRAINED_ONLY_PREFIXES = ("xenc-",)
_HEX64 = re.compile(r"[0-9a-f]{64}")


# What an execution identity must name, per training kind. A trained judge is
# identified by the digests of what it loads; an untrained arm (rules, AFM) by
# the digest of its rules or prompt plus decision settings and the environment
# it ran in. An identity with only arbitrary keys is not an identity.
IDENTITY_DIGESTS = {"trained": ("checkpoint_sha256", "tokenizer_sha256", "config_sha256"), "untrained-arm": ("config_sha256",)}
IDENTITY_TEXT_FIELDS = {"trained": (), "untrained-arm": ("environment",)}


def execution_identity_problems(identity: object, kind: str) -> list[str]:
    """Problems with an execution identity for a judge of `kind`. Empty means
    the identity names every required digest and field."""
    if not isinstance(identity, dict) or not identity:
        return ["execution_identity must be a non-empty object"]
    if not all(
        isinstance(k, str) and k.strip() and isinstance(v, str) and v.strip() for k, v in identity.items()
    ):
        return ["execution_identity keys and values must be non-empty strings"]
    if kind not in IDENTITY_DIGESTS:
        return ["execution_identity requires a recognised training kind"]
    problems: list[str] = []
    for key in IDENTITY_DIGESTS[kind]:
        if _HEX64.fullmatch(identity.get(key, "")) is None:
            problems.append(f"execution_identity.{key} must be a SHA-256 digest")
    for key in IDENTITY_TEXT_FIELDS[kind]:
        if not identity.get(key, "").strip():
            problems.append(f"execution_identity.{key} is required")
    return problems


@dataclass
class TrainingManifest:
    judge: str
    kind: str
    checkpoint: str
    tokenizer: str
    thresholds: dict
    partitions: dict  # name -> {"hashes": [...], "families": [...]}
    provenance: str
    hash_version: str
    # What actually runs: immutable digests of the checkpoint, tokenizer and
    # decision configuration for a trained judge; the OS/model environment
    # and prompt digest for an AFM arm. Every result record on the frozen
    # partition must carry exactly this object, so a result from checkpoint
    # B can never be scored under checkpoint A's clean training declaration.
    execution_identity: dict = field(default_factory=dict)
    problems: list = field(default_factory=list)

    def all_hashes(self) -> set[str]:
        return {h for p in self.partitions.values() for h in p.get("hashes", [])}

    def all_families(self) -> set[str]:
        return {f for p in self.partitions.values() for f in p.get("families", [])}

    def summary(self) -> dict:
        return {
            "judge": self.judge,
            "kind": self.kind,
            "checkpoint": self.checkpoint,
            "tokenizer": self.tokenizer,
            "thresholds": self.thresholds,
            "partition_sizes": {n: len(p.get("hashes", [])) for n, p in self.partitions.items()},
            "provenance": self.provenance,
            "execution_identity": dict(self.execution_identity),
        }


def load_training_manifest(path: Path) -> TrainingManifest:
    """Fails closed: every required key must be present with the right type.
    An untrained arm (rules, AFM) still files a manifest, with `kind`
    `untrained-arm` and empty partitions, so the declaration is explicit and
    a missing file is never read as 'nothing to declare'."""
    problems: list[str] = []
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return TrainingManifest("", "", "", "", {}, {}, "", "", problems=[f"training manifest unreadable: {exc}"])
    if not isinstance(raw, dict):
        return TrainingManifest("", "", "", "", {}, {}, "", "", problems=["training manifest must be an object"])

    def req_str(key: str) -> str:
        v = raw.get(key)
        if not isinstance(v, str) or not v.strip():
            problems.append(f"training manifest: {key} must be a non-empty string")
            return ""
        return v

    judge = req_str("judge")
    kind = req_str("kind")
    if kind and kind not in TRAINING_KINDS:
        problems.append(f"training manifest: kind {kind!r} not in {TRAINING_KINDS}")
    checkpoint = req_str("checkpoint")
    tokenizer = req_str("tokenizer")
    provenance = req_str("provenance")
    hash_version = req_str("hash_version")
    if hash_version and hash_version != HASH_VERSION:
        problems.append(f"training manifest: hash_version {hash_version!r} is not {HASH_VERSION}")
    thresholds = raw.get("thresholds")
    if not isinstance(thresholds, dict):
        problems.append("training manifest: thresholds must be an object")
        thresholds = {}
    partitions = raw.get("partitions")
    if not isinstance(partitions, dict):
        problems.append("training manifest: partitions must be an object")
        partitions = {}
    for name, part in partitions.items():
        if name not in TRAINING_PARTITIONS + OPTIONAL_TRAINING_PARTITIONS:
            problems.append(f"training manifest: unknown partition {name!r}")
            continue
        if not isinstance(part, dict):
            problems.append(f"training manifest: partition {name} must be an object")
            continue
        for key in ("hashes", "families"):
            v = part.get(key)
            if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
                problems.append(f"training manifest: partition {name}.{key} must be a list of strings")
    if kind == "trained":
        for name in TRAINING_PARTITIONS:
            if name not in partitions:
                problems.append(f"training manifest: trained judge must declare partition {name}")
            elif isinstance(partitions.get(name), dict) and not partitions[name].get("hashes"):
                problems.append(f"training manifest: trained judge partition {name} is empty")
    if kind == "untrained-arm":
        for name, part in partitions.items():
            if isinstance(part, dict) and (part.get("hashes") or part.get("families")):
                problems.append(f"training manifest: untrained arm declares data in partition {name}")
        if judge.startswith(TRAINED_ONLY_PREFIXES):
            problems.append(f"training manifest: {judge} is a cross-encoder candidate and needs a trained manifest")
    identity = raw.get("execution_identity")
    identity_problems = execution_identity_problems(identity, kind)
    if identity_problems:
        problems.extend(f"training manifest: {p}" for p in identity_problems)
        identity = identity if isinstance(identity, dict) else {}
    if not problems:
        # Partition content: well-formed hashes, canonical families, no
        # duplicates, and no row or family shared between two training
        # partitions (a calibration row that was also trained on is not a
        # calibration row).
        seen_hashes: set[str] = set()
        seen_families: set[str] = set()
        for name, part in partitions.items():
            hashes = part["hashes"]
            families = part["families"]
            if any(_HEX64.fullmatch(h) is None for h in hashes):
                problems.append(f"training manifest: partition {name} has an invalid content hash")
            if any(not f or family_key({"replacement": f}) != f for f in families):
                problems.append(f"training manifest: partition {name} has a non-canonical family key")
            if len(hashes) != len(set(hashes)):
                problems.append(f"training manifest: partition {name} has duplicate content hashes")
            if len(families) != len(set(families)):
                problems.append(f"training manifest: partition {name} has duplicate families")
            if kind == "trained" and (not hashes or not families):
                problems.append(f"training manifest: partition {name} needs both hashes and families")
            if seen_hashes.intersection(hashes):
                problems.append(f"training manifest: partition {name} shares content with another training partition")
            if seen_families.intersection(families):
                problems.append(f"training manifest: partition {name} shares a family with another training partition")
            seen_hashes.update(hashes)
            seen_families.update(families)
    return TrainingManifest(
        judge, kind, checkpoint, tokenizer, thresholds, partitions, provenance, hash_version, identity, problems
    )


def leakage_problems(manifest: TrainingManifest, frozen: dict) -> list[str]:
    """Refuse any judge whose training/dev/calibration data overlaps the
    frozen report set, by exact content hash or by alias family. Family
    overlap is reported by family so the offending canonical is visible;
    hash overlap is reported by count plus the first few hashes."""
    problems: list[str] = []
    fh = frozen_hashes(frozen)
    ff = frozen_families(frozen)
    for name, part in manifest.partitions.items():
        hashes = set(part.get("hashes", []))
        overlap = sorted(hashes & fh)
        if overlap:
            problems.append(
                f"frozen leakage: partition {name} shares {len(overlap)} content hash(es) with the frozen set"
                f" (first: {', '.join(h[:12] for h in overlap[:3])})"
            )
        families = set(part.get("families", []))
        fam_overlap = sorted(families & ff)
        if fam_overlap:
            problems.append(
                f"frozen leakage: partition {name} shares {len(fam_overlap)} alias famil(ies) with the frozen set"
                f" (first: {', '.join(repr(f) for f in fam_overlap[:3])})"
            )
    return problems


# --- Family-grouped split ---


def split_by_family(rows: list[dict], seed: str, fractions: tuple[float, float, float] = (0.8, 0.1, 0.1)) -> dict[str, list[dict]]:
    """Deterministic split into train/dev/calibration with every row of a
    family in exactly one partition. Families are ordered by the hash of
    (seed, family) so the order is stable across machines and independent of
    input order; each family goes to the partition furthest below its target
    share, counted in ROWS, so a big family does not starve the small
    partitions."""
    if abs(sum(fractions) - 1.0) > 1e-9 or any(f < 0 for f in fractions):
        raise ValueError("fractions must be non-negative and sum to 1")
    by_family: dict[str, list[dict]] = {}
    for r in rows:
        by_family.setdefault(family_key(r), []).append(r)
    ordered = sorted(
        by_family.items(),
        key=lambda kv: hashlib.sha256(f"{seed}\x00{kv[0]}".encode("utf-8")).hexdigest(),
    )
    names = list(TRAINING_PARTITIONS)
    out: dict[str, list[dict]] = {n: [] for n in names}
    total = len(rows)
    for fam, members in ordered:
        deficits = []
        for n, frac in zip(names, fractions):
            target = frac * total
            deficits.append((target - len(out[n]), frac, n))
        # Largest deficit wins; a zero-fraction partition never wins.
        best = max((d for d in deficits if d[1] > 0), key=lambda d: (d[0], d[2]))
        out[best[2]].extend(members)
    return out


def partition_manifest(rows: list[dict]) -> dict:
    return {
        "hashes": sorted(content_hash(r) for r in rows),
        "families": sorted({family_key(r) for r in rows}),
    }


def cross_partition_families(parts: dict[str, list[dict]]) -> list[str]:
    seen: dict[str, str] = {}
    leaks: list[str] = []
    for name, rows in parts.items():
        for r in rows:
            f = family_key(r)
            if f in seen and seen[f] != name:
                leaks.append(f"family {f!r} in both {seen[f]} and {name}")
            seen.setdefault(f, name)
    return sorted(set(leaks))


# --- Candidate builders (unlabelled) ---

_WORD = re.compile(r"\S+")


def _words(text: str) -> list[str]:
    return _WORD.findall(text)


def pack_candidates(packs_dir: Path) -> list[dict]:
    """One candidate per (alias -> term) pair in the vocabulary packs. The
    pack says the recogniser has written `alias` for `term`; it does NOT say
    a human judged the alias safe to learn, and it gives no sentence, so
    `pasted` is null and the candidate cannot be scored until a reviewer
    supplies a sentence and labels."""
    out: list[dict] = []
    for path in sorted(packs_dir.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError(f"{path}: pack must be an object of term -> aliases")
        for term, aliases in data.items():
            if not isinstance(aliases, list):
                raise ValueError(f"{path}: {term!r} aliases must be a list")
            for alias in aliases:
                out.append(
                    {
                        "id": f"PACK-{path.stem}-{len(out):05d}",
                        "source": "pack",
                        "pack": path.stem,
                        "language": "und",
                        "original": alias,
                        "replacement": term,
                        "pasted": None,
                        "edited": None,
                        "label": None,
                        "review_status": "unreviewed",
                    }
                )
    return out


def mine_polish_spans(rows: Iterable[dict], max_words: int = 4) -> tuple[list[dict], dict]:
    """Rewording candidates from the raw-ASR versus polished corpus: every
    replaced run of 1..max_words words on both sides whose original occurs
    exactly once in the raw text. These are what a polish model changed, not
    what a user corrected; they are candidates for the `notCorrection` class
    only after review. Returns (candidates, skip counts)."""
    out: list[dict] = []
    skipped = {"no_change": 0, "run_too_long": 0, "original_ambiguous": 0, "missing_fields": 0}
    for r in rows:
        raw = r.get("asr_input")
        polished = r.get("expected_output")
        if not isinstance(raw, str) or not isinstance(polished, str):
            skipped["missing_fields"] += 1
            continue
        a, b = _words(raw), _words(polished)
        matcher = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
        found = False
        for tag, i1, i2, j1, j2 in matcher.get_opcodes():
            if tag != "replace":
                continue
            if not (1 <= i2 - i1 <= max_words and 1 <= j2 - j1 <= max_words):
                skipped["run_too_long"] += 1
                continue
            original = " ".join(a[i1:i2])
            replacement = " ".join(b[j1:j2])
            if original == replacement:
                continue
            if raw.count(original) != 1:
                skipped["original_ambiguous"] += 1
                continue
            found = True
            out.append(
                {
                    "id": f"POLISH-{r.get('id', '?')}-{i1}",
                    "source": "polish",
                    "source_id": r.get("id"),
                    "language": "und",
                    "original": original,
                    "replacement": replacement,
                    "pasted": raw,
                    "edited": raw.replace(original, replacement, 1),
                    "label": None,
                    "review_status": "unreviewed",
                }
            )
        if not found and raw == polished:
            skipped["no_change"] += 1
    return out, skipped


def language_coverage(rows: Iterable[dict]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for r in rows:
        lang = r.get("language")
        key = _nfc(lang).strip().casefold() if isinstance(lang, str) and lang.strip() else "(missing)"
        counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items()))


def write_jsonl(path: Path, rows: Iterable[dict]) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    n = 0
    with path.open("w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, ensure_ascii=False) + "\n")
            n += 1
    return n


def read_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    with path.open(encoding="utf-8") as fh:
        for n, line in enumerate(fh, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{n}: not JSON ({exc})") from exc
    return rows
