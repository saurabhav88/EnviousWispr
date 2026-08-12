#!/usr/bin/env python3
"""Regenerate corpus `asr_input` as REAL Parakeet output via a TTS round-trip.

Why: measured 2026-08-01, 0/1890 Type B corpus inputs are both capitalized and
terminally punctuated, while 32/32 real dictations in the founder's app log are
(100% terminal punctuation, 94% both; backend=parakeet). Every cloud polish
score we hold was therefore measured on an input form the shipped ASR does not
produce. This rebuilds the inputs through the ASR we actually ship.

Engine fidelity: drives `fluidaudiocli tts-asr-verify` from the PINNED FluidAudio
checkout (`.build/checkouts/FluidAudio`, revision bf9fe27f per Package.resolved),
NOT `~/Developer/EnviousLabs/FluidAudio*` — a local checkout's HEAD floats, so
it can silently measure a different engine; the pinned checkout cannot.

Two hard limitations, both stated in the report rather than hidden:

1. A TTS voice is not a person. This fixes the punctuation/casing mismatch we
   proved; it does NOT make the corpus real human dictation (no noise, no
   accent, no hesitation timing).
2. The round-trip mangles proper nouns. "loop in jamal actually priya wait no
   loop in alina" came back "Loop in JAML, actually pre-await no loop and a
   lina". A case whose words changed no longer matches its `expected_output`,
   so it is BROKEN, not improved. Cases above --max-wer are REJECTED and keep
   their original input; the report names every one.

The upstream tool aborts the whole run and writes NO json if any single phrase
fails TTS (seen on the 814-char cases: Kokoro `postAlbert` shape-deduction
crash). So batches are isolated here, and a failed batch is retried per-line to
salvage everything except the genuinely bad phrase.

Usage:
  python3 scripts/eval/build_parakeet_corpus.py \
    --corpus scripts/eval/corpus/type_b_approved_1890-raw.jsonl \
    --out-dir scripts/eval/corpus/parakeet-roundtrip
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / ".build/checkouts/FluidAudio/.build/arm64-apple-macosx/release/fluidaudiocli"
PIN = "bf9fe27f837c86ee786a3f0ddb9966eeeeb4915d"


def check_engine() -> None:
    if not CLI.exists():
        sys.exit(
            f"fluidaudiocli not built at {CLI}\n"
            f"Build it:  cd {CLI.parents[3]} && swift build -c release --product fluidaudiocli"
        )
    rev = subprocess.run(
        ["git", "-C", str(CLI.parents[3]), "rev-parse", "HEAD"],
        capture_output=True, text=True,
    ).stdout.strip()
    if rev != PIN:
        sys.exit(
            f"checkout is {rev}, expected pinned {PIN}. Refusing to measure a "
            "different engine than the app ships."
        )
    print(f"engine   : pinned FluidAudio {PIN[:8]} (matches Package.resolved)", file=sys.stderr)


def wer(ref: str, hyp: str) -> float:
    """Word error rate, the same metric the CLI reports. Case/punctuation are
    NORMALISED AWAY here on purpose: adding capitals and periods is the whole
    point of this exercise, so counting them as errors would reject every case."""
    import re

    def norm(s: str) -> list[str]:
        return re.sub(r"[^\w\s']", " ", s.lower()).split()

    r, h = norm(ref), norm(hyp)
    if not r:
        return 0.0 if not h else 1.0
    d = [[0] * (len(h) + 1) for _ in range(len(r) + 1)]
    for i in range(len(r) + 1):
        d[i][0] = i
    for j in range(len(h) + 1):
        d[0][j] = j
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            cost = 0 if r[i - 1] == h[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
    return d[len(r)][len(h)] / len(r)


def run_batch(texts: list[str], voice: str) -> list[str] | None:
    """Synthesize+transcribe a batch. Returns hypotheses in order, or None if
    the batch aborted (caller then retries line by line)."""
    with tempfile.TemporaryDirectory() as td:
        tf = Path(td) / "phrases.txt"
        of = Path(td) / "out.json"
        # '#' starts a comment in the tool's phrases file; no corpus line begins
        # with one (checked at load), so nothing is silently dropped.
        tf.write_text("\n".join(texts) + "\n")
        proc = subprocess.run(
            [str(CLI), "tts-asr-verify", "--texts-file", str(tf),
             "--voice", voice, "--output-json", str(of)],
            capture_output=True, text=True,
        )
        if proc.returncode != 0 or not of.exists():
            return None
        data = json.loads(of.read_text())
        phrases = sorted(data["phrases"], key=lambda p: p["index"])
        if len(phrases) != len(texts):
            return None
        return [p["hypothesis"].strip() for p in phrases]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True, type=Path)
    ap.add_argument("--out-dir", required=True, type=Path)
    ap.add_argument("--voice", default="af_heart")
    ap.add_argument("--batch-size", type=int, default=40)
    ap.add_argument("--max-wer", type=float, default=0.0,
                    help="keep the round-trip input only when word error is at "
                         "or below this (default 0.0: the words must be "
                         "IDENTICAL, only casing/punctuation may differ)")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    check_engine()
    cases = []
    for line in open(args.corpus):
        line = line.strip()
        if not line:
            continue
        d = json.loads(line)
        key = "asr_input" if "asr_input" in d else "input"
        text = d[key].replace("\n", " ").replace("\r", " ").strip()
        if text.startswith("#"):
            sys.exit(f"case {d['id']} starts with '#', which the TTS tool treats as a comment")
        cases.append((d, key, text))
    if args.limit:
        cases = cases[: args.limit]

    args.out_dir.mkdir(parents=True, exist_ok=True)
    print(f"corpus   : {args.corpus.name} ({len(cases)} cases), voice={args.voice}", file=sys.stderr)

    hyps: dict[str, str | None] = {}
    for start in range(0, len(cases), args.batch_size):
        chunk = cases[start : start + args.batch_size]
        got = run_batch([t for _, _, t in chunk], args.voice)
        if got is None:
            # Isolate: one bad phrase must not cost us the other 39.
            print(f"  batch @{start} aborted, retrying per-line", file=sys.stderr)
            got = []
            for d, _, t in chunk:
                one = run_batch([t], args.voice)
                if one is None:
                    print(f"    TTS FAILED {d['id']} (len={len(t)})", file=sys.stderr)
                    got.append(None)
                else:
                    got.append(one[0])
        for (d, _, _), h in zip(chunk, got):
            hyps[d["id"]] = h
        print(f"  {min(start + args.batch_size, len(cases))}/{len(cases)}", file=sys.stderr)

    kept, rejected, failed = [], [], []
    out_path = args.out_dir / args.corpus.name
    with open(out_path, "w") as out:
        for d, key, text in cases:
            h = hyps.get(d["id"])
            if h is None:
                failed.append((d["id"], text, ""))
                out.write(json.dumps(d) + "\n")
                continue
            w = wer(text, h)
            if w <= args.max_wer:
                nd = dict(d)
                nd[key] = h
                nd["asr_roundtrip"] = {"source": "parakeet-tts-roundtrip",
                                       "engine_pin": PIN, "voice": args.voice, "wer": round(w, 4)}
                out.write(json.dumps(nd) + "\n")
                kept.append((d["id"], text, h))
            else:
                rejected.append((d["id"], text, h, round(w, 4)))
                out.write(json.dumps(d) + "\n")

    report = {
        "engine_pin": PIN, "voice": args.voice, "max_wer": args.max_wer,
        "total": len(cases), "kept": len(kept),
        "rejected_wer": len(rejected), "tts_failed": len(failed),
        "rejected": [{"id": i, "orig": o, "parakeet": h, "wer": w} for i, o, h, w in rejected],
        "tts_failed_ids": [i for i, _, _ in failed],
    }
    (args.out_dir / "roundtrip_report.json").write_text(json.dumps(report, indent=2))

    n = len(cases)
    print(f"\nkept (words identical)  : {len(kept)}/{n} ({100*len(kept)/n:.1f}%)", file=sys.stderr)
    print(f"rejected (words changed): {len(rejected)}/{n} ({100*len(rejected)/n:.1f}%)", file=sys.stderr)
    print(f"TTS failed              : {len(failed)}/{n}", file=sys.stderr)
    print(f"\n-> {out_path}\n-> {args.out_dir / 'roundtrip_report.json'}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
