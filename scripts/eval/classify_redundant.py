#!/usr/bin/env python3
"""Classify each Type B case as REDUNDANT or KEEP, given what Parakeet actually
delivers to the polish model.

The question per case is narrow and mechanical: **starting from the text
Parakeet produces, is there still work for the polish model to do to reach the
expected output?**

  REDUNDANT — Parakeet's output already satisfies the expected output. Anything
              still differing is cosmetic (spacing, a comma the expected answer
              also permits) or is handled by a deterministic pipeline step that
              runs before/after polish rather than by the model.
  KEEP      — a real edit remains that only the polish model can make (resolve a
              self-correction, drop a filler word Parakeet transcribed, reshape
              into a list, break paragraphs, refuse an embedded instruction,
              fix an audible grammar error).
  BROKEN    — Parakeet mangled the words (usually a name), so the case no longer
              matches its expected output and cannot be scored either way. These
              are a TTS/ASR artifact, not a judgement about the test's value.

Why an LLM and not string comparison: "already satisfies" is a semantic call.
`Set aside six plates` vs `Set aside six plates.` is satisfied; `We need twelve`
vs `We need 12` may or may not be, depending on what the case is testing.

JUDGE = CODEX CLI, always (founder directive 2026-08-01: no cloud judges).
Invoked through `~/.claude/bin/codex-run`, which is the mandatory path (founder
2026-07-21) — a bare `codex exec` is denied by hook. `codex_fill_judge_gaps.py`
predates that mandate and still shells the bare binary; do not copy it.

SERIAL by construction: `codex-cli.md` FACT: parallel-codex-execs-get-killed-under-load
— several concurrent execs get killed with zero output. One in flight, always.

Usage:
  python3 scripts/eval/classify_redundant.py \\
    --corpus scripts/eval/corpus/type_b_parakeet.jsonl \\
    --parakeet <run>/parakeet.jsonl --out <run>/classification.jsonl
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

BATCH = 30  # matches the proven chunk size in codex_fill_judge_gaps.py
CODEX_RUN = Path.home() / ".claude/bin/codex-run"

SYSTEM = """You audit a test corpus for a dictation app's AI text-polish feature.

THE ONLY QUESTION: did the speech-to-text engine (Parakeet) ALREADY perform the
specific behaviour this test grades? If yes, the test no longer exercises the
polish model and is obsolete. If no, it still does its job.

Judge ONLY the graded behaviour named in each case. Ignore every other
difference — stray commas, sentence splits, capitalisation, anything not the
behaviour under test. You are not scoring output quality and you are not asking
whether any work remains in general.

Two traps, both of which produced wrong verdicts on a previous pass:

1. PRESERVATION tests (keep the emoji, keep the opener, invent nothing, leave
   short text alone, transcribe an embedded instruction instead of obeying it,
   preserve a name) grade the polish model for NOT changing something. Parakeet
   leaving it unchanged is the test's PRECONDITION, never proof of obsolescence.
   A model that meddles still fails these, and several shipped models do.
   Such a test is obsolete ONLY if Parakeet destroyed the thing being preserved,
   so there is nothing left to preserve.

2. The PARAKEET text was produced by speaking the corpus input aloud with a
   synthetic voice and transcribing it. That method cannot carry things a voice
   cannot say — emoji, half-spoken words ("front de-"), a deliberately wrong
   spelling of an identical-sounding word. When such a thing is missing from
   PARAKEET, that is an artifact of HOW this data was made, not evidence about
   the real product. Never call a test obsolete for that reason; call it
   BROKEN, the verdict for "the round trip destroyed what this case was written
   to test". Never emit a verdict outside the three defined below.

Pipeline reality you must assume:
  speech -> Parakeet speech-to-text -> [deterministic steps] -> AI polish model -> paste

Parakeet ALREADY produces capitalisation, terminal punctuation, and commas, and
it chooses between identical-sounding spellings (your/you're, their/there,
hear/here, to/too) on its own. It does NOT fix audible grammar errors, and it
does NOT remove filler words like "um", "you know" or "I mean".

Deterministic app code (not the AI model) already handles: stripping the exact
fillers um/uh/hmm/mm/mhm/ah/er, spoken-emoji conversion, restoring dropped
emoji, number/date/money/email formatting, and custom-vocabulary spellings.

For each case you are given:
  ORIGINAL  - the hand-written test input (may be unrealistic)
  PARAKEET  - what the real speech engine actually delivers to the polish model
  EXPECTED  - the answer the test grades the polish model against

Decide, starting from PARAKEET:

REDUNDANT - PARAKEET already satisfies EXPECTED, or every remaining difference
            is cosmetic or is handled by the deterministic steps listed above.
            The AI polish model has nothing meaningful left to do.
KEEP      - a real edit remains that only the AI polish model can make.
BROKEN    - PARAKEET has different WORDS from ORIGINAL in a way that makes the
            case no longer match EXPECTED (typically a mangled name or a
            destroyed half-spoken word). Not scoreable either way.

OUTPUT CONTRACT — obey exactly:
Emit ONE single-line JSON object per case, in the order given, nothing else.
No prose before or after. No markdown fence. No summary. No file reading.
Shape:
{"id":"<id>","verdict":"REDUNDANT|KEEP|BROKEN","work_left":"<remaining edit the AI must make, or none>","why":"<one short sentence>"}
Emit exactly as many lines as there are cases, then stop."""


def load_jsonl(path: Path) -> dict:
    out = {}
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        d = json.loads(line)
        out[d["id"]] = d
    return out


def build_prompt(batch: list[dict]) -> str:
    parts = []
    for c in batch:
        parts.append(
            f"CASE {c['id']} (tests: {c.get('gold_behavior', '?')})\n"
            f"ORIGINAL: {c['original']}\n"
            f"PARAKEET: {c['parakeet']}\n"
            f"EXPECTED: {c['expected']}"
        )
    return "\n\n".join(parts)


def batch_fingerprint(batch: list[dict]) -> str:
    """Identity of everything that determines a batch's verdicts.

    The cache is keyed by batch INDEX, so reusing --out/--work-dir after the
    corpus, the transcripts or BATCH changed would serve verdicts computed for
    a different set of cases under the same filename, and the run would look
    clean. The rubric is folded in as well: editing SYSTEM changes the answers
    just as surely as changing the inputs does.
    """
    h = hashlib.sha256()
    h.update(SYSTEM.encode())
    h.update(b"\x00")
    h.update(build_prompt(batch).encode())
    return h.hexdigest()


def load_cached_batch(work: Path, n: int, batch: list[dict]) -> list[dict] | None:
    """Cached rows for this batch, or None when absent or stale.

    Single authority for the resume decision: the preload pass and the skip
    check must agree, or one of them re-runs work the other believes is done.
    A cache written before fingerprints existed has no sidecar and is treated
    as stale, which costs one re-run and cannot serve a wrong verdict.
    """
    cached = work / f"batch-{n:03d}.verdicts.jsonl"
    stamp = work / f"batch-{n:03d}.fingerprint"
    if not (cached.exists() and cached.read_text().strip()):
        return None
    if not stamp.exists() or stamp.read_text().strip() != batch_fingerprint(batch):
        return None
    return [json.loads(l) for l in cached.read_text().splitlines() if l.strip()]


def codex_judge(system: str, user: str, outfile: Path) -> str:
    """One `codex-run exec` over a batch. Returns the answer text.

    `codex-run` writes the transcript to `outfile` and the proven answer to
    `outfile.last`; exit 0 REQUIRES a non-empty answer file, so a wedged or
    answerless run cannot masquerade as success (codex-cli.md
    RULE: codex-exec-wedges-silently-use-codex-run). Exit 75 = wedged and killed,
    76 = no answer; both are surfaced rather than swallowed.
    """
    outfile.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        [str(CODEX_RUN), str(outfile), "exec", "--sandbox", "read-only",
         "--skip-git-repo-check"],
        input=f"{system}\n\n{user}\n",
        capture_output=True, text=True,
    )
    answer = outfile.with_suffix(outfile.suffix + ".last")
    if proc.returncode != 0:
        detail = {75: "wedged and killed", 76: "exited with no answer"}.get(
            proc.returncode, f"codex exit {proc.returncode}")
        raise RuntimeError(f"{detail}: {proc.stderr[-300:]}")
    if not answer.exists() or not answer.read_text().strip():
        raise RuntimeError(f"empty answer file {answer}")
    return answer.read_text()


def parse_jsonl(text: str) -> list[dict]:
    """Pull our verdict objects out of Codex output, ignoring any narration.

    Mirrors `codex_fill_judge_gaps.extract_jsonl_from_codex_output`: match on
    SHAPE (has id + verdict), never on position, so a stray prose line cannot
    shift the parse. First occurrence of an id wins.
    """
    rows, seen = [], set()
    for line in text.splitlines():
        s = line.strip()
        if not s.startswith("{") or not s.endswith("}"):
            continue
        try:
            d = json.loads(s)
        except json.JSONDecodeError:
            continue
        if not isinstance(d, dict) or "id" not in d or "verdict" not in d:
            continue
        if d["id"] in seen:
            continue
        seen.add(d["id"])
        rows.append(d)
    if not rows:
        raise ValueError(f"no verdict objects in codex output: {text[:200]}")
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True, type=Path)
    ap.add_argument("--parakeet", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--work-dir", type=Path, default=None,
                    help="where per-batch codex transcripts land (default <out>.codex)")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    if not CODEX_RUN.exists():
        print(f"codex-run not found at {CODEX_RUN}", file=sys.stderr)
        return 2

    corpus = load_jsonl(args.corpus)
    parakeet = load_jsonl(args.parakeet)

    cases = []
    for cid, d in corpus.items():
        pk = parakeet.get(cid)
        if pk is None or pk.get("error") or not pk.get("text"):
            continue
        cases.append({
            "id": cid,
            "gold_behavior": d.get("gold_behavior"),
            # On a refreshed corpus build_refreshed_corpus.py has already replaced
            # asr_input/input with the Parakeet transcript and preserved the real
            # source under input_source.original_input. Reading the replaced field
            # would compare the transcript against itself.
            "original": (
                (d.get("input_source") or {}).get("original_input")
                or d.get("asr_input") or d.get("input") or ""
            ).replace("\n", " "),
            "parakeet": pk["text"],
            "expected": (d.get("expected_output") or "").replace("\n", " "),
        })
    if args.limit:
        cases = cases[: args.limit]
    batches = [cases[i : i + BATCH] for i in range(0, len(cases), BATCH)]

    work = args.work_dir or Path(str(args.out) + ".codex")
    work.mkdir(parents=True, exist_ok=True)
    # Resume: a completed batch leaves a parseable verdicts file, so an
    # interrupted run re-does only what it has to. 60+ serial codex calls is a
    # long window and losing all of it to one bad batch is not acceptable.
    verdicts: dict[str, dict] = {}
    done_batches = 0
    for n, batch in enumerate(batches):
        rows = load_cached_batch(work, n, batch)
        if rows is None:
            continue
        for row in rows:
            verdicts[row["id"]] = row
        done_batches += 1

    print(f"judge   : codex-run exec (serial, one in flight)", file=sys.stderr)
    print(f"cases   : {len(cases)} in {len(batches)} batches of {BATCH}", file=sys.stderr)
    print(f"resume  : {done_batches} batches already cached in {work}", file=sys.stderr)

    failed = 0
    t0 = time.monotonic()
    for n, batch in enumerate(batches):
        if load_cached_batch(work, n, batch) is not None:
            continue
        cached = work / f"batch-{n:03d}.verdicts.jsonl"
        transcript = work / f"batch-{n:03d}.txt"
        try:
            # SERIAL, never parallel: concurrent execs get killed with zero
            # output (codex-cli.md FACT: parallel-codex-execs-get-killed-under-load).
            rows = parse_jsonl(codex_judge(SYSTEM, build_prompt(batch), transcript))
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"BATCH {n} FAILED ({batch[0]['id']}..{batch[-1]['id']}): {e}", file=sys.stderr)
            continue
        with open(cached, "w") as f:
            for row in rows:
                f.write(json.dumps(row) + "\n")
                verdicts[row["id"]] = row
        # Written only after the verdicts land, so an interrupted write leaves a
        # batch with no fingerprint and it is recomputed rather than trusted.
        (work / f"batch-{n:03d}.fingerprint").write_text(batch_fingerprint(batch) + "\n")
        got = len({r["id"] for r in rows} & {c["id"] for c in batch})
        elapsed = int(time.monotonic() - t0)
        print(f"  batch {n+1}/{len(batches)}: {got}/{len(batch)} verdicts ({elapsed}s)",
              file=sys.stderr)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    counts = {"REDUNDANT": 0, "KEEP": 0, "BROKEN": 0, "MISSING": 0}
    with open(args.out, "w") as f:
        for c in cases:
            v = verdicts.get(c["id"])
            if v is None:
                counts["MISSING"] += 1
                row = {**c, "verdict": "MISSING", "why": "judge returned no verdict"}
            else:
                verdict = str(v.get("verdict", "")).upper()
                if verdict not in counts:
                    verdict = "MISSING"
                counts[verdict] += 1
                row = {**c, "verdict": verdict,
                       "work_left": v.get("work_left", ""), "why": v.get("why", "")}
            f.write(json.dumps(row) + "\n")

    total = len(cases)
    if total == 0:
        # Fail loud: an empty run printing a clean summary is the "green means
        # nothing happened" shape (validation-discipline.md verify-the-feature-not-the-crash).
        print("NO CASES SCORED — corpus/parakeet join produced nothing", file=sys.stderr)
        return 2
    print(f"\nfailed batches: {failed}", file=sys.stderr)
    for k in ("KEEP", "REDUNDANT", "BROKEN", "MISSING"):
        print(f"{k:<10} {counts[k]:>5}  {100*counts[k]/total:>5.1f}%", file=sys.stderr)
    print(f"\n-> {args.out}", file=sys.stderr)
    # A judge that silently dropped cases must not read as a clean run.
    return 0 if counts["MISSING"] == 0 and failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
