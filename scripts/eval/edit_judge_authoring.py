#!/usr/bin/env python3
"""Authoring pipeline for edit-judge development rows (#996, chunk 4a-ii).

Rows are written by models (or mined from real Parakeet output) in TEMPLATE
form, screened, labelled blind by other models and joined on unanimity.
The library functions are pure and tested; the CLI wires them to files.

Pipeline (each step writes a receipt next to its output):
  extract-block  a subagent transcript (JSONL) -> the last fenced block
  screen         template rows -> full labelled rows, validated with the gate,
                 hash AND family disjoint from every frozen exam, every named
                 split directory and every named jsonl (earlier waves, probes)
  label-prepare  screened rows -> blind prompts (rows only: no kind, label,
                 frame or provenance), batched
  label-collect  answers -> one labels jsonl per labeller
  join           rows + labels -> rows every labeller agrees with the author
                 (`review_status: blind-labelled-unanimous`), the rest dropped
                 with both votes recorded

Template row contract (what an author writes): id, kind, language, template
(exactly one `{X}` marker), original, replacement, frame, label_source. The
kind resolves stratum and label through the exam-v2 taxonomy; rows whose kind
is absent from the taxonomy are rejected. Two systematic author slips are
repaired and COUNTED, never silent: a marker written `{X` (missing brace) and
a doubled marker `{{X}}`. Any other brace in the template rejects the row.

Provenance: `label_source` must say who wrote the row ("authored by <model>
<date> for <purpose>" or "mined by ..."); the join appends the labellers.
"""
from __future__ import annotations

import argparse
import collections
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import edit_judge_data as data  # noqa: E402
import edit_judge_gate as gate  # noqa: E402

BLIND_LABEL_STATUS = "blind-labelled-unanimous"
FENCE = re.compile(r"```[a-zA-Z]*\n(.*?)```", re.S)

RUBRIC = """You label edits for a dictation app's judge exam. The app pasted what the user said; the user then edited ONE run of words in place. Decide for each row whether the edit is a VOCABULARY CORRECTION: the user fixed a name, brand, product, acronym, place, domain term or spelling that the speech recogniser misheard or misspelled (the replacement is a specific vocabulary item the recogniser could not know, and the original is what it produced instead: a sound-alike, a split, a wrong real word, a missing accent). Everything else is NOT a vocabulary correction: rewording or synonyms, tense, agreement, articles, prepositions, contractions and apostrophes, hyphenation, capitalisation-only, punctuation-only, plurals, homophone fixes between common words (their/there), number or date formatting, tone changes, word order, insertions of words, instruction-like text, placeholders, code or markdown.

Three hard cases: (a) the original is a real word or a real name that SOUNDS LIKE the replacement, and the context shows the replacement was meant ("Sarah" -> "Saira" for a colleague, "sequel" -> "SQL"): that IS a correction, because a recogniser plausibly produced the original when the user said the replacement; (b) a grammatical accent change on a common word ("tu" -> "tú", "esta" -> "está") is NOT a correction, while restoring the accents of a name or term ("Mueller" -> "Müller", "Jimenez" -> "Jiménez") IS; (c) swapping one real product, term, place, day or person for a DIFFERENT one that does not sound like it ("Postgres" -> "MySQL", "Tuesday" -> "Wednesday", "aspirin" -> "ibuprofen") is NOT a correction: no recogniser turns "MySQL" into "Postgres"; the user changed what they meant, and remembering that pair would be wrong. Ask: could a speech recogniser have produced the original when the user SAID the replacement? If not, it is not a correction.

You see only the rows. Do not guess any pattern in how they were made. Judge each row on its own. Answer ONLY with one fenced block tagged jsonl, one object per input row, in the same order: {"id": "...", "correction": true|false, "confidence": 1-5, "note": "<= 12 words"}.
"""


# --- pure helpers (tested) -------------------------------------------------

def parse_block(text: str) -> tuple[list[dict], int]:
    """JSON objects from the LAST fenced block of `text` (or the whole text
    when there is no fence). Returns (rows, unparseable_line_count)."""
    blocks = FENCE.findall(text)
    block = blocks[-1] if blocks else text
    rows, bad = [], 0
    for line in block.strip().split("\n"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            bad += 1
    return rows, bad


def last_block_from_transcript(path: Path) -> str | None:
    """The last fenced block an assistant wrote in a subagent transcript
    (JSONL of messages), in a text part or in a SendMessage tool input."""
    blocks: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            m = json.loads(line)
        except json.JSONDecodeError:
            continue
        msg = m.get("message") or {}
        if m.get("type") != "assistant" and msg.get("role") != "assistant":
            continue
        content = msg.get("content")
        text = ""
        if isinstance(content, list):
            for c in content:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "text":
                    text += c.get("text", "")
                elif c.get("type") == "tool_use" and isinstance(c.get("input"), dict) and isinstance(c["input"].get("message"), str):
                    text += "\n" + c["input"]["message"]
        elif isinstance(content, str):
            text = content
        blocks += FENCE.findall(text)
    return blocks[-1] if blocks else None


def repair_marker(template: str) -> tuple[str, str | None]:
    """Repair the two counted author slips; return (template, repair_name)."""
    if "{X}" not in template and template.count("{X") == 1:
        return re.sub(r"\{X(?!\})", "{X}", template), "repaired_marker"
    if template.count("{{X}}") == 1 and template.count("{X}") == 1:
        return template.replace("{{X}}", "{X}"), "repaired_double_marker"
    return template, None


def assemble(row: dict, kind_spec: dict) -> tuple[dict | None, str | None, str | None]:
    """Template row -> full labelled row. Returns (row, reject_reason, repair)."""
    t, o, rp = row.get("template"), row.get("original"), row.get("replacement")
    if not all(isinstance(x, str) for x in (t, o, rp)):
        return None, "template_fields_missing", None
    t, repair = repair_marker(t)
    rest = t.replace("{X}", "")
    if t.count("{X}") != 1:
        return None, "template_marker_count", repair
    if "{" in rest or "}" in rest:
        return None, "stray_brace", repair
    if o == rp:
        return None, "original_equals_replacement", repair
    if o in rest or rp in rest:
        return None, "run_repeated_in_template", repair
    full = {
        "id": row.get("id"), "stratum": kind_spec["stratum"], "language": row.get("language"),
        "pasted": t.replace("{X}", o), "edited": t.replace("{X}", rp), "original": o, "replacement": rp,
        "correction": kind_spec["correction"], "safe_alias": False,
        "label_source": row.get("label_source", ""), "kind": kind_spec["kind"], "frame": row.get("frame", ""),
    }
    for key in ("review_status", "mined_canonical", "mined_alias"):
        if isinstance(row.get(key), str):
            full[key] = row[key]
    return full, None, repair


class Exclusion:
    """Content hashes and alias families a new row may not share."""

    def __init__(self) -> None:
        self.hashes: set[str] = set()
        self.families: set[str] = set()
        self.sources: dict[str, tuple[int, int]] = {}
        self.digests: dict[str, str] = {}

    def add_rows(self, name: str, rows: list[dict]) -> None:
        h = {data.content_hash(r) for r in rows if all(isinstance(r.get(k), str) for k in ("language", "pasted", "edited", "original", "replacement"))}
        f = {data.family_key(r) for r in rows if isinstance(r.get("replacement"), str)}
        self.hashes |= h
        self.families |= f
        self.sources[name] = (len(h), len(f))

    def add_frozen_exams(self) -> None:
        """Every registered frozen exam (legacy and v2), by manifest digests."""
        for m in gate.frozen_manifests_present():
            h, f = set(data.frozen_hashes(m)), set(data.frozen_families(m))
            self.hashes |= h
            self.families |= f
            self.sources[f"frozen:{m.get('exam_id', m.get('frozen_at', '?'))}"] = (len(h), len(f))

    def add_split(self, split_dir: Path) -> None:
        """A training split: its manifest and all three partition files must
        exist and match the manifest's digests, so a mistyped directory can
        never index nothing (Codex 4a-ii round 4 F2)."""
        manifest_path = split_dir / "split-manifest.json"
        if not manifest_path.is_file():
            raise FileNotFoundError(f"exclusion split {split_dir} has no split-manifest.json")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        for part in ("train", "dev", "calibration"):
            spec = manifest.get("partitions", {}).get(part)
            path = split_dir / (spec or {}).get("path", f"{part}.jsonl")
            if spec is None or not path.is_file():
                raise FileNotFoundError(f"exclusion split {split_dir} is missing partition {part}")
            if data.sha256_file(path) != spec.get("file_sha256"):
                raise ValueError(f"exclusion split {split_dir}: {part} does not match split-manifest.json's digest")
            rows = data.read_jsonl(path)
            self.add_rows(f"{split_dir}/{part}", rows)
            self.digests[f"{split_dir}/{part}"] = spec["file_sha256"]

    def add_jsonl(self, path: Path) -> None:
        if not path.is_file():
            raise FileNotFoundError(f"exclusion file {path} does not exist")
        self.add_rows(str(path), data.read_jsonl(path))
        self.digests[str(path)] = data.sha256_file(path)

    def excludes(self, row: dict) -> bool:
        return data.content_hash(row) in self.hashes or data.family_key(row) in self.families


def screen(rows: list[dict], kinds: dict[str, dict], excl: Exclusion, probe_families: set[str] = frozenset()) -> tuple[list[dict], collections.Counter, list[dict]]:
    """Template rows -> validated, screened full rows. Every rejection is
    counted and listed with its reason; nothing is padded."""
    kept, c, rejects = [], collections.Counter(), []
    for r in rows:
        c["parsed"] += 1
        k = kinds.get(r.get("kind"))
        if k is None:
            c["unknown_kind"] += 1
            rejects.append({"id": r.get("id"), "reason": "unknown_kind", "kind": r.get("kind")})
            continue
        full, why, repair = assemble(r, k)
        if repair:
            c[repair] += 1
        if full is None:
            c["template_invalid"] += 1
            rejects.append({"id": r.get("id"), "reason": why, "template": r.get("template")})
            continue
        core = {key: full[key] for key in gate.REQUIRED_ROW_KEYS}
        problems = gate.validate_rows([core], "dev") if isinstance(full["id"], str) else ["id is not a string"]
        if problems:
            c["invalid"] += 1
            rejects.append({"id": r.get("id"), "reason": "invalid", "problems": problems[:2]})
            continue
        if excl.excludes(full):
            c["excluded_overlap"] += 1
            rejects.append({"id": r.get("id"), "reason": "overlap", "original": full["original"], "replacement": full["replacement"]})
            continue
        if data.family_key(full) in probe_families:
            c["excluded_probe"] += 1
            rejects.append({"id": r.get("id"), "reason": "probe", "original": full["original"], "replacement": full["replacement"]})
            continue
        kept.append(full)
        c["kept"] += 1
    return kept, c, rejects


def dedupe(rows: list[dict]) -> tuple[list[dict], list[dict]]:
    """Collapse identical cases only when their labels agree; a case that
    arrived with two labels is quarantined whole, with every member and its
    source, never resolved by arrival order (Codex 4a-ii round 4 F5). Also
    refuses duplicate row ids across the kept rows."""
    groups: dict[str, list[dict]] = collections.OrderedDict()
    for r in rows:
        groups.setdefault(data.content_hash(r), []).append(r)
    kept, quarantined = [], []
    for h, members in groups.items():
        if len({m["correction"] for m in members}) > 1:
            quarantined.append({"content_hash": h, "members": [{"id": m["id"], "kind": m["kind"], "correction": m["correction"], "label_source": m["label_source"]} for m in members]})
        else:
            kept.append(members[0])
    ids = [r["id"] for r in kept]
    dupes = sorted({i for i in ids if ids.count(i) > 1})
    if dupes:
        raise ValueError(f"duplicate row ids across batches: {dupes[:5]}")
    return kept, quarantined


def review_ids(rows: list[dict], seed: int) -> dict[str, str]:
    """Opaque, shuffled review ids (`R-0001`...) for the blind prompt, so an
    author id such as `XS-G-001` cannot hint at the batch, kind or label
    (Codex 4a-ii round 4 F4). Returns original id -> review id; the mapping is
    persisted beside the prompts and reversed at collection."""
    import random
    ids = [r["id"] for r in rows]
    if len(set(ids)) != len(ids):
        raise ValueError("rows carry duplicate ids")
    order = list(range(len(ids)))
    random.Random(seed).shuffle(order)
    return {ids[i]: f"R-{n + 1:04d}" for n, i in enumerate(order)}


def blind_prompt(rows: list[dict], id_map: dict[str, str], rubric: str = RUBRIC) -> str:
    """Rows only: an opaque review id, language and the four strings. No
    author id, kind, label, frame or provenance reaches the labeller."""
    lines = [json.dumps({"id": id_map[r["id"]], "language": r["language"], "pasted": r["pasted"], "edited": r["edited"], "original": r["original"], "replacement": r["replacement"]}, ensure_ascii=False) for r in rows]
    return rubric + "\n## Rows\n```jsonl\n" + "\n".join(lines) + "\n```\n"


def parse_labels(text: str, known_ids: set[str]) -> tuple[dict[str, dict], int]:
    """Labels keyed by the id the labeller saw. A boolean `correction` on a
    known id is a vote; anything else is counted bad. The same id voted twice
    is refused: a labeller must not be able to overwrite its own vote."""
    objs, bad = parse_block(text)
    labels = {}
    for o in objs:
        if o.get("id") in known_ids and isinstance(o.get("correction"), bool):
            if o["id"] in labels:
                raise ValueError(f"label id {o['id']} appears twice in one answer")
            labels[o["id"]] = {"correction": o["correction"], "confidence": o.get("confidence"), "note": o.get("note", "")}
        else:
            bad += 1
    return labels, bad


MIN_BLIND_LABELLERS = 2


def join_unanimous(rows: list[dict], labels: dict[str, dict[str, dict]]) -> tuple[list[dict], list[dict], dict]:
    """Keep a row only when EVERY labeller's label equals the author label.
    `blind-labelled-unanimous` is minted only from at least two distinct
    labellers (Codex 4a-ii round 4 F3); rows without a vote from each stay
    unlabelled and are dropped with the missing names recorded."""
    if len(labels) < MIN_BLIND_LABELLERS:
        raise ValueError(f"unanimity needs at least {MIN_BLIND_LABELLERS} distinct labellers, got {sorted(labels)}")
    ids = [r["id"] for r in rows]
    if len(set(ids)) != len(ids):
        raise ValueError("rows carry duplicate ids")
    for name, votes in labels.items():
        bad = [i for i, v in votes.items() if not isinstance(v.get("correction"), bool)]
        if bad:
            raise ValueError(f"labeller {name} has non-boolean votes: {bad[:3]}")
    kept, dropped = [], []
    by_kind: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for r in rows:
        votes = {n: labels[n].get(r["id"]) for n in labels}
        missing = [n for n, v in votes.items() if v is None]
        if missing:
            by_kind[r["kind"]]["unlabelled"] += 1
            dropped.append({"id": r["id"], "reason": "unlabelled", "missing": missing})
            continue
        if all(v["correction"] == r["correction"] for v in votes.values()):
            row = dict(r, review_status=BLIND_LABEL_STATUS, label_source=r["label_source"] + "; blind labels agree: " + ", ".join(sorted(labels)))
            kept.append(row)
            by_kind[r["kind"]]["kept"] += 1
        else:
            by_kind[r["kind"]]["disagree"] += 1
            dropped.append({"id": r["id"], "reason": "disagree", "author": r["correction"], "votes": {n: v["correction"] for n, v in votes.items()}, "notes": {n: v.get("note") for n, v in votes.items()}, "original": r["original"], "replacement": r["replacement"], "pasted": r["pasted"]})
    return kept, dropped, {k: dict(v) for k, v in sorted(by_kind.items())}


# --- real Parakeet mishearings from the #685 mined pool -----------------------
# `mined-names`: canonical -> real Parakeet outputs (TTS round trip, pass-2
# filtered, docs/research/685/mineable-final-v4.parquet) restricted to real
# US names (public first-name list + Census surname counts) because the pool
# has no source provenance on this Mac and its long tail is noise. One alias
# per canonical, alphabetic, 3+ letters, difflib ratio >= RATIO_MIN so the
# pair is a garble of the word rather than an unrelated token. Rows come out
# in template form with a random natural carrier, both runs capitalised.
MINED_RATIO_MIN = 0.45
MINED_REVIEW_STATUS = "mined-heuristic-labelled"
MINED_ZIPF_MAX = 3.0
MINED_SURNAME_MIN_COUNT = 300
MINED_CARRIERS = [
 "Can you ask {X} to review the draft before the client call tomorrow?", "I had lunch with {X} and we talked through the hiring plan.", "{X} sent the updated numbers late last night, please take a look.",
 "Please add {X} to the invite for Thursday's planning session.", "The handover notes from {X} are in the shared folder now.", "Remind {X} that the expense report is due on Friday.",
 "We are meeting {X} at the station around six this evening.", "Let's loop in {X} before we send the proposal to legal.", "The invoice from {X} still has the old billing address on it.",
 "Please compare the pricing of {X} with what we pay today.", "Order the replacement cable from {X} before the trip.", "My cousin just started a new job at {X} in the city.",
 "The doctor mentioned {X} during the appointment yesterday.", "Ask the clinic if {X} is covered by the plan.", "The referral letter mentions {X} twice.",
 "The contract names {X} in the second clause.", "Please flag every mention of {X} in the draft agreement.", "Add a definition of {X} to the glossary section.",
 "Run the numbers on {X} before we commit to the new market.", "Add a test for the {X} path before merging.", "Our docs barely mention {X} and new hires keep asking.",
 "We booked a table at {X} for Saturday night.", "The package from {X} arrived a day early.", "I read about {X} in the newsletter this morning.",
 "Did you see the email about {X} from the finance team?", "Put {X} on the agenda for the Monday sync.", "The kids want to visit {X} during the school break.",
 "Grandma keeps asking about {X} every time she calls.", "Book the flight through {X} if the price is still the same.", "The recipe calls for {X} but the shop was out of it.",
 "The landlord said {X} would come by to look at the boiler.", "The mechanic recommended {X} for the brake pads.", "The insurance form asks about {X} on the second page.",
 "The pharmacist suggested {X} instead of the usual brand.", "I saw {X} listed as a speaker at the conference in October.", "The neighbours are heading to {X} for the long weekend.",
 "Our team switched to {X} for time tracking last month.", "Send the signed form to {X} by the end of the week.", "The quarterly review with {X} moved to Wednesday.",
 "The train to {X} leaves from platform four.", "The coach wants {X} back in the starting lineup.", "The article quoted {X} on the housing numbers.",
 "The new hire from {X} starts on the first of the month.", "Please pay the {X} invoice before the late fee kicks in.", "The vet said {X} might help with the itching.",
 "Ask {X} whether the venue has parking.", "The recruiter from {X} wants a call on Tuesday.", "The lab results mention {X} in the notes.",
 "I left the keys with {X} at the front desk.", "The kids' school is doing a unit on {X} this term.", "We should invite {X} to the launch party.",
 "The quote from {X} came in lower than expected.", "Tell {X} the meeting room changed to the third floor.", "The playlist has three songs by {X} in a row.",
 "Try the {X} at the new place on the corner.", "The professor assigned a chapter on {X} for next week.", "The tour guide kept mentioning {X} during the walk.",
 "The dentist wants to schedule {X} for early next month.", "My manager asked {X} to shadow me this week.", "The plumber said the {X} needs replacing soon.",
]


def mined_name_rows(pool: list[dict], names: set[str], carriers: list[str], n: int, seed: int, ratio_min: float = MINED_RATIO_MIN) -> list[dict]:
    import difflib
    import random
    rng = random.Random(seed)
    alpha = re.compile(r"^[a-z]+$")
    from wordfreq import zipf_frequency
    # Filter to names, shuffle, then apply the per-word rules in draw order:
    # the order the dev-v10 rows were produced with (2026-09-19), so the same
    # seed reproduces `authored/parakeet-mined-v1.jsonl` exactly. A name that
    # is also a common English word (zipf >= MINED_ZIPF_MAX) is skipped.
    picked = [r for r in pool if r["canonical"] in names]
    rng.shuffle(picked)
    rows = []
    for rec in picked:
        if len(rows) >= n:
            break
        w = rec["canonical"]
        if not (5 <= len(w) <= 14 and alpha.match(w)) or zipf_frequency(w, "en") >= MINED_ZIPF_MAX:
            continue
        cands = [a for a in rec["shipped_aliases"] if len(a) >= 3 and alpha.match(a) and a != w and difflib.SequenceMatcher(None, a, w).ratio() >= ratio_min]
        if not cands:
            continue
        a = rng.choice(cands)
        t = rng.choice(carriers)
        if w in t.lower() or a in t.lower():
            continue
        rows.append({"id": f"XQ-M-{len(rows) + 1:04d}", "kind": "phonetic_person_name", "language": "en", "template": t, "original": a.capitalize(), "replacement": w.capitalize(),
                     "frame": f"mined carrier {carriers.index(t)}",
                     "label_source": "authored by parakeet-tts-roundtrip (#685 mined pool, mineable-final-v4, US surname/first-name lists) 2026-05; carrier sentence by claude 2026-09-19; label by construction (canonical vs its recorded Parakeet output), name-list and similarity screening only, no row-level review",
                     "review_status": MINED_REVIEW_STATUS, "mined_canonical": w, "mined_alias": a})
    return rows


def cmd_mined_names(args: argparse.Namespace) -> int:
    import pyarrow.parquet as pq
    surnames = {l.split(",")[0].lower() for l in args.surnames.read_text(encoding="utf-8").splitlines()[1:] if l and int(l.split(",")[2] or 0) >= MINED_SURNAME_MIN_COUNT}
    firsts = {l.strip().lower() for l in args.first_names.read_text(encoding="utf-8").splitlines() if l.strip()}
    names = surnames | firsts
    pool = pq.read_table(args.pool).to_pylist()
    rows = mined_name_rows(pool, names, MINED_CARRIERS, args.n, args.seed)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("```jsonl\n" + "\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n```\n", encoding="utf-8")
    import wordfreq
    receipt = {"pool": str(args.pool), "pool_sha256": data.sha256_file(args.pool), "surnames": str(args.surnames), "surnames_sha256": data.sha256_file(args.surnames), "first_names": str(args.first_names), "first_names_sha256": data.sha256_file(args.first_names),
               "n": args.n, "seed": args.seed, "ratio_min": MINED_RATIO_MIN, "zipf_max": MINED_ZIPF_MAX, "surname_min_count": MINED_SURNAME_MIN_COUNT, "carriers_sha256": __import__("hashlib").sha256("\n".join(MINED_CARRIERS).encode()).hexdigest(),
               "wordfreq_version": getattr(wordfreq, "__version__", "?"), "review_status": MINED_REVIEW_STATUS, "rows": len(rows), "name_like_canonicals_in_pool": sum(1 for r in pool if r["canonical"] in names)}
    Path(str(args.out) + ".receipt.json").write_text(json.dumps(receipt, indent=1), encoding="utf-8")
    print(f"name-like canonicals in pool {receipt['name_like_canonicals_in_pool']}; rows {len(rows)} -> {args.out}")
    return 0


# --- CLI -------------------------------------------------------------------

def _kinds(taxonomy: Path) -> dict[str, dict]:
    spec = json.loads(taxonomy.read_text(encoding="utf-8"))
    return {k["kind"]: k for k in spec["kinds"]}


def cmd_extract_block(args: argparse.Namespace) -> int:
    block = last_block_from_transcript(args.transcript)
    if block is None:
        print(f"no fenced block found in {args.transcript}", file=sys.stderr)
        return 1
    args.out.write_text("```jsonl\n" + block.rstrip("\n") + "\n```\n", encoding="utf-8")
    rows, bad = parse_block(block)
    print(f"{args.out} rows {len(rows)} unparseable {bad}")
    return 0


def cmd_screen(args: argparse.Namespace) -> int:
    kinds = _kinds(args.taxonomy)
    excl = Exclusion()
    excl.add_frozen_exams()
    for d in args.exclude_split or []:
        excl.add_split(d)
    for p in args.exclude_jsonl or []:
        excl.add_jsonl(p)
    probe = set()
    for p in args.probe_jsonl or []:
        if not p.is_file():
            print(f"INFRA-ERROR: probe file {p} does not exist", file=sys.stderr)
            return 2
        probe |= {data.family_key(r) for r in data.read_jsonl(p)}
        excl.digests[str(p)] = data.sha256_file(p)
    frozen, _, problems = gate.load_frozen()
    if problems:
        print("INFRA-ERROR: " + "; ".join(problems), file=sys.stderr)
        return 2
    out, report = [], {}
    for f in sorted(args.answers.glob("*-answer.md")):
        rows, bad = parse_block(f.read_text(encoding="utf-8"))
        kept, c, rejects = screen(rows, kinds, excl, probe)
        c["unparseable"] = bad
        report[f.name] = {"counts": dict(c), "rejects": rejects}
        out += kept
    uniq, quarantined = dedupe(out)
    gate.require_clean_dev(uniq, frozen)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    data.write_jsonl(args.out, uniq)
    pos = sum(1 for r in uniq if r["correction"])
    receipt = {"unique_rows": len(uniq), "positives": pos, "negatives": len(uniq) - pos,
               "by_kind": dict(collections.Counter(r["kind"] for r in uniq)), "families": len({data.family_key(r) for r in uniq}),
               "label_conflicts_quarantined": quarantined, "exclusion_sources": excl.sources, "exclusion_digests": excl.digests, "probe_files": [str(p) for p in args.probe_jsonl or []], "batches": report}
    Path(str(args.out) + ".receipt.json").write_text(json.dumps(receipt, indent=1, ensure_ascii=False), encoding="utf-8")
    for name, rep in report.items():
        print(name, {k: v for k, v in rep["counts"].items()})
    print(f"unique {len(uniq)} pos {pos} neg {len(uniq) - pos}")
    return 0


def _sha_text(text: str) -> str:
    import hashlib
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def cmd_label_prepare(args: argparse.Namespace) -> int:
    """One labelling SESSION per labeller directory: created exclusively (an
    existing directory is refused, never overwritten or reused), with a
    session manifest binding the rows file, the rubric, the id map and every
    prompt file by digest (Codex 4a-ii round 5)."""
    rows = data.read_jsonl(args.rows)
    d = args.out / args.labeler
    try:
        d.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        print(f"INFRA-ERROR: labelling session {d} already exists; prepare into a new directory, never over an old session", file=sys.stderr)
        return 2
    id_map = review_ids(rows, args.seed)
    map_text = json.dumps({"rows_sha256": data.sha256_file(args.rows), "seed": args.seed, "map": id_map}, indent=1)
    (d / "id-map.json").write_text(map_text, encoding="utf-8")
    order = sorted(rows, key=lambda r: id_map[r["id"]])  # prompts in review-id order, not author order
    prompt_files = {}
    for i in range(0, len(order), args.batch_size):
        name = f"batch-{i // args.batch_size:03d}-prompt.md"
        text = blind_prompt(order[i:i + args.batch_size], id_map)
        (d / name).write_text(text, encoding="utf-8")
        prompt_files[name] = _sha_text(text)
    session = {"labeler": args.labeler, "rows": str(args.rows), "rows_sha256": data.sha256_file(args.rows), "rubric_sha256": _sha_text(RUBRIC), "id_map_sha256": _sha_text(map_text), "seed": args.seed, "prompt_files": prompt_files}
    (d / "session.json").write_text(json.dumps(session, indent=1), encoding="utf-8")
    print(f"{args.labeler} batches {len(prompt_files)} rows {len(rows)} (opaque review ids, seed {args.seed}, session {d})")
    return 0


def _load_session(d: Path, rows_path: Path) -> tuple[dict, dict] | None:
    """The session manifest and id map, verified against the rows file, the
    map and every prompt file on disk; None (with the reason printed) when
    anything drifted."""
    session_path, map_path = d / "session.json", d / "id-map.json"
    if not session_path.is_file() or not map_path.is_file():
        print(f"INFRA-ERROR: {d} is not a labelling session (session.json or id-map.json missing)", file=sys.stderr)
        return None
    session = json.loads(session_path.read_text(encoding="utf-8"))
    if session["rows_sha256"] != data.sha256_file(rows_path):
        print("INFRA-ERROR: the rows file changed since the prompts were prepared", file=sys.stderr)
        return None
    map_text = map_path.read_text(encoding="utf-8")
    if session["id_map_sha256"] != _sha_text(map_text) or session["rubric_sha256"] != _sha_text(RUBRIC):
        print("INFRA-ERROR: the id map or the rubric changed since the prompts were prepared", file=sys.stderr)
        return None
    for name, digest in session["prompt_files"].items():
        if not (d / name).is_file() or _sha_text((d / name).read_text(encoding="utf-8")) != digest:
            print(f"INFRA-ERROR: prompt {name} is missing or changed since preparation", file=sys.stderr)
            return None
    return session, json.loads(map_text)


def cmd_label_collect(args: argparse.Namespace) -> int:
    """Answers -> labels jsonl plus a vote receipt binding the labels file to
    this session and its rows file. Only answers whose prompt belongs to the
    session are read."""
    rows = data.read_jsonl(args.rows)
    d = args.out / args.labeler
    loaded = _load_session(d, args.rows)
    if loaded is None:
        return 2
    session, id_map_doc = loaded
    reverse = {v: k for k, v in id_map_doc["map"].items()}
    labels, bad = {}, 0
    for f in sorted(d.glob("batch-*-answer.md")):
        if f.name.replace("-answer.md", "-prompt.md") not in session["prompt_files"]:
            print(f"INFRA-ERROR: {f.name} has no prompt in this session", file=sys.stderr)
            return 2
        got, b = parse_labels(f.read_text(encoding="utf-8"), set(reverse))
        for rid, v in got.items():
            orig = reverse[rid]
            if orig in labels:
                print(f"INFRA-ERROR: {orig} labelled in two answer files", file=sys.stderr)
                return 2
            labels[orig] = v
        bad += b
    labels_path = args.out / f"{args.labeler}-labels.jsonl"
    with labels_path.open("w", encoding="utf-8") as fh:
        for rid, v in labels.items():
            fh.write(json.dumps({"id": rid, **v}, ensure_ascii=False) + "\n")
    receipt = {"labeler": args.labeler, "session_sha256": _sha_text((d / "session.json").read_text(encoding="utf-8")), "rows_sha256": session["rows_sha256"], "labels_sha256": data.sha256_file(labels_path), "labels": len(labels), "unparseable": bad}
    Path(str(labels_path) + ".receipt.json").write_text(json.dumps(receipt, indent=1), encoding="utf-8")
    by_id = {r["id"]: r for r in rows}
    agree = sum(1 for rid, v in labels.items() if v["correction"] == by_id[rid]["correction"])
    print(f"{args.labeler} labels {len(labels)} of {len(rows)} unparseable {bad} agree_with_author {agree}")
    return 0 if len(labels) == len(rows) else 1


def cmd_join(args: argparse.Namespace) -> int:
    rows = data.read_jsonl(args.rows)
    if len(set(args.labeler)) != len(args.labeler):
        print("INFRA-ERROR: the same labeller named twice", file=sys.stderr)
        return 2
    labels = {}
    rows_sha = data.sha256_file(args.rows)
    for name in args.labeler:
        labels_path = args.labels / f"{name}-labels.jsonl"
        receipt_path = Path(str(labels_path) + ".receipt.json")
        if not receipt_path.is_file():
            print(f"INFRA-ERROR: {labels_path} has no vote receipt; collect it with label-collect", file=sys.stderr)
            return 2
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        if receipt.get("rows_sha256") != rows_sha:
            print(f"INFRA-ERROR: {name}'s votes were collected against a different rows file", file=sys.stderr)
            return 2
        if receipt.get("labels_sha256") != data.sha256_file(labels_path):
            print(f"INFRA-ERROR: {labels_path} does not match its vote receipt", file=sys.stderr)
            return 2
        votes = {}
        for o in data.read_jsonl(labels_path):
            if o["id"] in votes:
                print(f"INFRA-ERROR: {name} labels {o['id']} twice", file=sys.stderr)
                return 2
            votes[o["id"]] = o
        labels[name] = votes
    kept, dropped, by_kind = join_unanimous(rows, labels)
    data.write_jsonl(args.out, kept)
    pos = sum(1 for r in kept if r["correction"])
    Path(str(args.out) + ".receipt.json").write_text(json.dumps({"candidates": len(rows), "kept": len(kept), "positives": pos, "negatives": len(kept) - pos, "labelers": list(args.labeler), "by_kind": by_kind, "dropped": dropped}, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"kept {len(kept)} pos {pos} neg {len(kept) - pos} dropped {len(dropped)}")
    for k, v in by_kind.items():
        print(f"  {k:28s} {v}")
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("extract-block", help="last fenced block of a subagent transcript -> answer file")
    s.add_argument("transcript", type=Path)
    s.add_argument("out", type=Path)
    s.set_defaults(fn=cmd_extract_block)
    s = sub.add_parser("screen", help="template answers -> screened full rows")
    s.add_argument("--taxonomy", type=Path, required=True, help="exam-v2 taxonomy.json (kind -> stratum, correction)")
    s.add_argument("--answers", type=Path, required=True, help="directory of *-answer.md files")
    s.add_argument("--exclude-split", type=Path, action="append", help="split directory (train/dev/calibration.jsonl) whose rows and families are excluded; repeatable")
    s.add_argument("--exclude-jsonl", type=Path, action="append", help="jsonl whose rows and families are excluded (earlier waves); repeatable")
    s.add_argument("--probe-jsonl", type=Path, action="append", help="jsonl whose FAMILIES are excluded (inspected probes); repeatable")
    s.add_argument("--out", type=Path, required=True)
    s.set_defaults(fn=cmd_screen)
    s = sub.add_parser("label-prepare", help="screened rows -> blind label prompts")
    s.add_argument("rows", type=Path)
    s.add_argument("out", type=Path)
    s.add_argument("labeler")
    s.add_argument("--batch-size", type=int, default=100)
    s.add_argument("--seed", type=int, default=996, help="shuffle seed for the opaque review ids")
    s.set_defaults(fn=cmd_label_prepare)
    s = sub.add_parser("label-collect", help="blind label answers -> labels jsonl")
    s.add_argument("rows", type=Path)
    s.add_argument("out", type=Path)
    s.add_argument("labeler")
    s.set_defaults(fn=cmd_label_collect)
    s = sub.add_parser("join", help="rows + labels -> unanimous rows")
    s.add_argument("rows", type=Path)
    s.add_argument("labels", type=Path, help="directory holding <labeler>-labels.jsonl files")
    s.add_argument("out", type=Path)
    s.add_argument("labeler", nargs="+", help="at least two distinct labellers")
    s.set_defaults(fn=cmd_join)
    s = sub.add_parser("mined-names", help="real Parakeet mishearings of US names from the #685 mined pool -> template answer file")
    s.add_argument("--pool", type=Path, required=True, help="mineable-final-v4.parquet")
    s.add_argument("--surnames", type=Path, required=True, help="Census surname csv (name,rank,count,...)")
    s.add_argument("--first-names", type=Path, required=True, help="one first name per line")
    s.add_argument("--n", type=int, default=2400)
    s.add_argument("--seed", type=int, default=996)
    s.add_argument("--out", type=Path, required=True)
    s.set_defaults(fn=cmd_mined_names)
    args = p.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    raise SystemExit(main())
