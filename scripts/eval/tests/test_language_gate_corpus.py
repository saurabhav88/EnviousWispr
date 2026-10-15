#!/usr/bin/env python3
"""Offline tests for the Whisper (transcribe.cpp) arm of `language_gate_corpus.py` (#3735).

No engine runs here: the run directory holds placeholder WAVs (only their hashes matter) and a
hand-written Whisper output, so these rows check the provenance, completeness and fixture rules
and the argument dispatch, never transcription quality.

Run from repo root:
  python3 scripts/eval/tests/test_language_gate_corpus.py
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import language_gate_corpus as lg  # noqa: E402

SCRIPT = Path(lg.__file__).resolve()
EXPECTED_TESTS = 9
_failures = 0
_ran = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global _failures, _ran
    _ran += 1
    if cond:
        print(f"  PASS  {name}")
    else:
        _failures += 1
        print(f"  FAIL  {name} {detail}")


def make_run(root: Path) -> Path:
    run = root / "run"
    (run / "wav").mkdir(parents=True)
    for r in lg.cases():
        (run / "wav" / f"{r['id']}.wav").write_bytes(f"RIFF placeholder {r['id']}".encode())
    return run


def write_whisper(run: Path, *, drop: str | None = None, error: str | None = None,
                  sha: str | None = None) -> None:
    model = sha or lg._whisper_manifest()[1]
    rows = []
    for r in lg.cases():
        if r["id"] == drop:
            continue
        if r["id"] == error:
            rows.append({"id": r["id"], "error": "boom"})
        else:
            rows.append({"id": r["id"], "model_sha256": model, "text": f"text {r['id']}",
                         "detected_lang": r["lang"]})
    lg.whisper_out(run).write_text("".join(json.dumps(x) + "\n" for x in rows))
    lg.whisper_out(run).with_suffix(".provenance.json").write_text(
        json.dumps(lg._whisper_context(run), sort_keys=True) + "\n")


def raises(fn) -> bool:
    try:
        fn()
    except (ValueError, SystemExit):
        return True
    return False


def cli(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True)


def main() -> int:
    n = len(lg.cases())
    with tempfile.TemporaryDirectory() as tmp:
        run = make_run(Path(tmp))
        write_whisper(run)
        rows = lg._verified_whisper(run)
        check("a complete verified run has one row per case", len(rows) == n, f"{len(rows)} != {n}")

        dest = Path(tmp) / "fixture.jsonl"
        lg.whisper_fixture(run, dest)
        lines = [json.loads(l) for l in dest.read_text().splitlines()]
        body = lines[1:]
        check("the fixture header names the pinned model",
              lines[0]["_meta"]["whisper_model_sha256"] == lg._whisper_manifest()[1]
              and lines[0]["_meta"]["rows"] == n)
        check("every fixture row is a whisper row with its language and audio hash",
              len(body) == n and all(b["engine"] == "whisper" and b["engine_language"] == b["lang"]
                                     and len(b["audio_sha256"]) == 64 for b in body))

        first = lg.cases()[0]["id"]
        (run / "wav" / f"{first}.wav").write_bytes(b"RIFF changed")
        check("a changed WAV invalidates the output", raises(lambda: lg._verified_whisper(run)))

    with tempfile.TemporaryDirectory() as tmp:
        run = make_run(Path(tmp))
        write_whisper(run, drop=lg.cases()[3]["id"])
        check("a missing row is refused", raises(lambda: lg._verified_whisper(run)))
        write_whisper(run, error=lg.cases()[4]["id"])
        check("an error row is refused", raises(lambda: lg._verified_whisper(run)))
        write_whisper(run, sha="0" * 64)
        check("a row from another model is refused", raises(lambda: lg._verified_whisper(run)))

        gguf = Path(tmp) / "not-the-model.gguf"
        gguf.write_bytes(b"GGUF placeholder")
        lg.whisper_out(run).unlink()
        check("a GGUF the manifest does not pin is refused before any run",
              raises(lambda: lg.transcribe_whisper(run, gguf))
              and not lg.whisper_out(run).exists())

        only_whisper = cli("--run", str(run), "--transcribe", "--whisper-gguf", str(gguf))
        neither = cli("--run", str(run), "--transcribe")
        check("--transcribe runs the Whisper arm alone; with no arm it asks for Parakeet",
              "is not the GGUF" in only_whisper.stderr
              and "--parakeet-model is required" in neither.stderr,
              f"{only_whisper.stderr[-200:]!r} / {neither.stderr[-200:]!r}")

    if _ran != EXPECTED_TESTS:
        print(f"FAIL: ran {_ran} checks, expected {EXPECTED_TESTS}")
        return 1
    print(f"{_ran - _failures} passed, {_failures} failed")
    return 1 if _failures else 0


if __name__ == "__main__":
    sys.exit(main())
