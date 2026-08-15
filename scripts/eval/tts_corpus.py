#!/usr/bin/env python3
"""Synthesize a corpus to per-case WAV files and emit a ParakeetRunner manifest.

DEFAULT ENGINE = AZURE (founder decision 2026-08-01, after A/B listening across
five voices): `en-US-AvaNeural` on the `envious-research-speech` F0 resource.
Runs on Microsoft Founders Hub credits instead of the direct OpenAI key, and the
F0 allowance (0.5M neural chars/month) covers a full 1,890-case corpus (~182K)
at zero cost. The founder picked the STANDARD neural tier over Dragon HD on
quality — the cheap tier won, so there is no cost/quality trade to make here.

`--engine openai` keeps the previous path (`tts-1-hd`, voice `echo`, the default
in `Tests/RuntimeUAT/wispr_eyes.py`, tools-and-apps.md RULE: tts-openai-echo-default)
for comparability with pre-2026-08-01 audio. It bills the direct key; prefer
Azure unless you are deliberately reproducing an older run.

That UAT helper writes ONE fixed path per call and returns MP3; this is the
batch form: per-case paths, WAV, concurrency, and resume.

WAV (not MP3) because ParakeetRunner reads via `AudioConverter().resampleAudioFile`,
the same helper the FluidAudio CLI uses; handing it lossy audio would add a
compression artifact that is not part of what we are measuring.

Resumable: an existing non-empty WAV is skipped, so a rate-limit abort costs only
the unfinished cases.

Usage:
  ~/.claude/bin/get-key launch openai-api-key OPENAI_API_KEY -- \\
    python3 scripts/eval/tts_corpus.py \\
      --corpus scripts/eval/corpus/type_b_parakeet.jsonl \\
      --wav-dir scripts/eval/runs/<run>/wav \\
      --manifest scripts/eval/runs/<run>/manifest.jsonl
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import html
import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

OPENAI_URL = "https://api.openai.com/v1/audio/speech"
RETRYABLE = {408, 429, 500, 502, 503, 504}
MAX_ATTEMPTS = 5
# List prices verified 2026-08-01, for a pre-spend estimate only, never a
# billing record. Azure is the S0 neural rate (the resource was upgraded off F0
# the day it was created, so the F0 free allowance no longer applies) and is
# funded by Founders Hub credits, not a card.
USD_PER_1M_CHARS = {"openai": 30.0, "azure": 15.0}


def _openai_request(text: str, model: str, voice: str, api_key: str) -> urllib.request.Request:
    body = {"model": model, "input": text, "voice": voice, "response_format": "wav"}
    return urllib.request.Request(
        OPENAI_URL,
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        method="POST",
    )


def _azure_request(text: str, voice: str, api_key: str, region: str) -> urllib.request.Request:
    # SSML, not JSON: Azure's TTS REST endpoint takes an SSML document. Escape
    # the transcript — corpus text contains &, <, > and quotes, and an unescaped
    # one makes the whole document invalid, which returns a 400 that reads like
    # a voice-name problem.
    ssml = (
        f'<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" '
        f'xml:lang="en-US"><voice name="{voice}">{html.escape(text)}</voice></speak>'
    )
    return urllib.request.Request(
        f"https://{region}.tts.speech.microsoft.com/cognitiveservices/v1",
        data=ssml.encode("utf-8"),
        headers={
            "Ocp-Apim-Subscription-Key": api_key,
            "Content-Type": "application/ssml+xml",
            # 16 kHz mono is what Parakeet consumes; asking for it here avoids a
            # resample step and matches the eval pipeline's expected input.
            "X-Microsoft-OutputFormat": "riff-16khz-16bit-mono-pcm",
            "User-Agent": "EnviousWispr-eval",
        },
        method="POST",
    )


def synth(text: str, out: Path, engine: str, model: str, voice: str,
          api_key: str, region: str) -> None:
    for attempt in range(1, MAX_ATTEMPTS + 1):
        req = (
            _azure_request(text, voice, api_key, region) if engine == "azure"
            else _openai_request(text, model, voice, api_key)
        )
        # ONLY the network call is inside the retry scope. The file writes used to
        # sit here too, and a broad OSError catch then misclassified a full or
        # read-only --wav-dir as a transient transport failure and re-billed the
        # TTS request up to MAX_ATTEMPTS times per case. A retry handler's scope is
        # whatever happens to be above it, so it has to be drawn deliberately.
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = resp.read()
        except urllib.error.HTTPError as e:
            if e.code in RETRYABLE and attempt < MAX_ATTEMPTS:
                time.sleep(min(2 ** attempt, 30))
                continue
            raise RuntimeError(f"HTTP {e.code}: {e.read().decode(errors='replace')[:200]}") from None
        except urllib.error.URLError:
            if attempt < MAX_ATTEMPTS:
                time.sleep(min(2 ** attempt, 30))
                continue
            raise
        except (OSError, http.client.HTTPException):
            # A reset during the RESPONSE BODY read is a bare ConnectionResetError,
            # not a URLError, so before this clause it escaped the retry loop and
            # aborted a whole TTS sweep. Ordered last of the three because
            # HTTPError subclasses URLError subclasses OSError.
            if attempt < MAX_ATTEMPTS:
                time.sleep(min(2 ** attempt, 30))
                continue
            raise

        # An empty body IS worth another network attempt, so it stays in the loop
        # — but as an explicit branch rather than an exception caught above.
        if not data:
            if attempt < MAX_ATTEMPTS:
                time.sleep(min(2 ** attempt, 30))
                continue
            raise RuntimeError("empty audio body after all attempts")

        # Local disk failures propagate immediately: retrying a full or read-only
        # directory cannot succeed and each retry costs another paid request.
        tmp = out.with_suffix(".part")
        tmp.write_bytes(data)
        tmp.replace(out)  # atomic: a killed run never leaves a half WAV
        return


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True, type=Path)
    ap.add_argument("--wav-dir", required=True, type=Path)
    ap.add_argument("--manifest", required=True, type=Path)
    ap.add_argument("--engine", choices=["azure", "openai"], default="azure")
    ap.add_argument("--model", default="tts-1-hd", help="openai engine only")
    ap.add_argument("--voice", default="", help="default: en-US-AvaNeural (azure) / echo (openai)")
    ap.add_argument("--workers", type=int, default=0, help="default: 12 azure / 8 openai")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--yes", action="store_true", help="skip the cost confirmation")
    args = ap.parse_args()

    voice = args.voice or ("en-US-AvaNeural" if args.engine == "azure" else "echo")
    # S0 allows 30 transactions/sec (F0 allowed 20 per MINUTE, which is why this
    # was 4 before the 2026-08-01 upgrade). 12 stays well inside the ceiling —
    # Azure's own guidance is to ramp gradually rather than spike, since a sharp
    # jump can draw 429s while their autoscaler catches up.
    workers = args.workers or (12 if args.engine == "azure" else 8)
    region = ""
    if args.engine == "azure":
        api_key = os.environ.get("AZURE_SPEECH_KEY", "").strip()
        region = os.environ.get("AZURE_SPEECH_REGION", "").strip()
        if not api_key or not region:
            print("AZURE_SPEECH_KEY / AZURE_SPEECH_REGION not set — run via `get-key launch`",
                  file=sys.stderr)
            return 2
    else:
        api_key = os.environ.get("OPENAI_API_KEY", "").strip()
        if not api_key:
            print("OPENAI_API_KEY not set — run via `get-key launch`", file=sys.stderr)
            return 2

    cases = []
    for line in open(args.corpus):
        line = line.strip()
        if not line:
            continue
        d = json.loads(line)
        text = (d.get("asr_input") or d.get("input") or "").replace("\n", " ").strip()
        if not text:
            print(f"case {d.get('id')} has no input text", file=sys.stderr)
            return 2
        cases.append((d["id"], text))
    if args.limit:
        cases = cases[: args.limit]

    args.wav_dir.mkdir(parents=True, exist_ok=True)
    args.manifest.parent.mkdir(parents=True, exist_ok=True)

    # Resume is keyed on WHAT PRODUCED the audio, not on the file existing. A
    # refreshed corpus deliberately keeps case IDs while changing their text, so
    # reusing a --wav-dir would silently serve the old sentence's audio under the
    # new case and put it in the manifest as if it were current. Engine, model
    # and voice are folded in for the same reason: they change the audio.
    stamp_path = args.wav_dir / ".synthesis.json"
    try:
        stamps = json.loads(stamp_path.read_text())
    except (OSError, json.JSONDecodeError):
        stamps = {}

    def stamp_of(text: str) -> str:
        h = hashlib.sha256()
        for part in (text, args.engine, args.model, voice):
            h.update(part.encode())
            h.update(b"\x00")
        return h.hexdigest()

    todo = []
    for cid, text in cases:
        p = args.wav_dir / f"{cid}.wav"
        if p.exists() and p.stat().st_size > 0 and stamps.get(cid) == stamp_of(text):
            continue
        todo.append((cid, text))

    chars = sum(len(t) for _, t in todo)
    est = chars / 1_000_000 * USD_PER_1M_CHARS[args.engine]
    print(
        f"corpus  : {len(cases)} cases, {len(todo)} to synthesize "
        f"({len(cases) - len(todo)} already present)",
        file=sys.stderr,
    )
    engine_desc = (
        f"azure {voice}" if args.engine == "azure" else f"openai {args.model} voice={voice}"
    )
    print(f"engine  : {engine_desc} -> WAV, {workers} workers", file=sys.stderr)
    print(f"estimate: {chars:,} chars ~= ${est:.2f} (credit-funded on azure)", file=sys.stderr)
    if todo and not args.yes:
        print("re-run with --yes to spend", file=sys.stderr)
        return 3

    errors = 0
    done = 0
    t0 = time.monotonic()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futs = {
            pool.submit(synth, text, args.wav_dir / f"{cid}.wav", args.engine,
                        args.model, voice, api_key, region): cid
            for cid, text in todo
        }
        texts = dict(todo)
        for fut in as_completed(futs):
            cid = futs[fut]
            done += 1
            try:
                fut.result()
                # Stamped only on success, so a failed case is retried next run
                # instead of being treated as current audio.
                stamps[cid] = stamp_of(texts[cid])
            except Exception as e:  # noqa: BLE001 — report and continue; resume handles retries
                errors += 1
                print(f"ERROR {cid}: {e}", file=sys.stderr)
            if done % 100 == 0:
                print(f"  {done}/{len(todo)} ({errors} errors, {int(time.monotonic()-t0)}s)",
                      file=sys.stderr)

    stamp_path.write_text(json.dumps(stamps, ensure_ascii=False, indent=0))

    # Manifest lists only cases whose audio actually exists AND was produced from
    # the current text, so a stale WAV left by an earlier corpus cannot enter the
    # run under a reused case ID.
    written = 0
    missing = []
    with open(args.manifest, "w") as m:
        for cid, text in cases:
            p = args.wav_dir / f"{cid}.wav"
            if p.exists() and p.stat().st_size > 0 and stamps.get(cid) == stamp_of(text):
                m.write(json.dumps({"id": cid, "wav": str(p.resolve())}) + "\n")
                written += 1
            else:
                missing.append(cid)

    print(f"\nsynth errors : {errors}", file=sys.stderr)
    print(f"manifest     : {written}/{len(cases)} cases -> {args.manifest}", file=sys.stderr)
    if missing:
        print(f"MISSING audio: {len(missing)} -> {missing[:10]}{' ...' if len(missing) > 10 else ''}",
              file=sys.stderr)
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
