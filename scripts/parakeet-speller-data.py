#!/usr/bin/env python3
"""Deterministic data for the Parakeet phrase speller (#3338 PR-2, chunk 5).

Two subcommands, both reading NVIDIA's own tokenizer.json for
`nvidia/parakeet-tdt-0.6b-v3` at revision 541d1f99c6b0c3cd0b11a95167540bb8edefd82b
(https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/blob/541d1f99c6b0c3cd0b11a95167540bb8edefd82b/tokenizer.json):

  resource <tokenizer.json> <out.json>
      Writes the speller resource: BPE vocab, merges in file order, unk token and
      added tokens, plus provenance. No normalizer table (the speller uses NFC;
      #2610 measured the precompiled map changes nothing on its word set).
      Byte-identical on rerun (sorted keys, fixed separators).

  oracle <tokenizer.json> <recovered-421.json> <supplement-inputs.json> <out.json>
      Expected ids from the Hugging Face `tokenizers` library (an implementation
      independent of the speller under test). Replays the 421 recovered pairs and
      reports any disagreement; never rewrites them. Labels the 22 supplement
      cases "supplement, regenerated 2026-10-02". A supplement input whose ids
      contain the unknown id 0 is recorded as an expected refusal.

Run with a Python that has `tokenizers` (version recorded in the oracle).
"""
import hashlib
import json
import sys
from pathlib import Path

REVISION = "541d1f99c6b0c3cd0b11a95167540bb8edefd82b"
SOURCE = f"https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/blob/{REVISION}/tokenizer.json"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def dump(obj, out):
    Path(out).write_text(json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")


def resource(tok_path, out):
    tok = json.loads(Path(tok_path).read_text())
    model = tok["model"]
    assert model["type"] == "BPE"
    merges = [m if isinstance(m, list) else m.split(" ", 1) for m in model["merges"]]
    dump({
        "provenance": {
            "source": SOURCE, "revision": REVISION, "source_sha256": sha(tok_path),
            "license": "CC-BY-4.0 (NVIDIA parakeet-tdt-0.6b-v3 model card)",
            "generator": "scripts/parakeet-speller-data.py resource",
        },
        "model": {"type": "BPE", "vocab": model["vocab"], "merges": merges, "unk_token": model["unk_token"]},
        "added_tokens": [{"content": a["content"], "id": a["id"]} for a in tok["added_tokens"]],
    }, out)
    print(f"resource {out} sha256 {sha(out)}")


def oracle(tok_path, recovered_path, inputs_path, out):
    import tokenizers
    tok = tokenizers.Tokenizer.from_file(tok_path)
    recovered = json.loads(Path(recovered_path).read_text())
    disagreements = []
    for row in recovered:
        ids = tok.encode(row["text"], add_special_tokens=False).ids
        if ids != row["ids"]:
            disagreements.append({"text": row["text"], "recovered": row["ids"], "official": ids})
    supplement = []
    for case in json.loads(Path(inputs_path).read_text())["cases"]:
        ids = tok.encode(case["text"], add_special_tokens=False).ids
        supplement.append({
            "text": case["text"], "class": case["class"], "ids": ids,
            "expected": "refusal" if 0 in ids else "spelled",
        })
    dump({
        "label": "supplement, regenerated 2026-10-02",
        "provenance": {
            "tokenizer_source": SOURCE, "tokenizer_sha256": sha(tok_path),
            "tokenizers_version": tokenizers.__version__,
            "recovered_421": {"path": "docs/audits/2610-harness/results/phrases-all.json", "sha256": sha(recovered_path)},
            "inputs_sha256": sha(inputs_path),
            "command": "scripts/parakeet-speller-data.py oracle <tokenizer.json> <phrases-all.json> <supplement-inputs.json> <out>",
        },
        "recovered_replay": {"rows": len(recovered), "disagreements": disagreements},
        "supplement": supplement,
    }, out)
    print(f"oracle {out}: recovered {len(recovered)} replay disagreements {len(disagreements)}; "
          f"supplement {len(supplement)} ({sum(s['expected'] == 'refusal' for s in supplement)} expected refusals)")


if __name__ == "__main__":
    cmd, *rest = sys.argv[1:]
    {"resource": resource, "oracle": oracle}[cmd](*rest)
