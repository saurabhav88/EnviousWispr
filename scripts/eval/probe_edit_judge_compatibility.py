#!/usr/bin/env python3
"""Edit-judge compatibility probe — issue #996 chunk 2b.

Before any cross-encoder is trained, answer three questions per candidate
with the SHIPPED stack, not a Python approximation:

  1. Tokenizer parity: does the vendored Argmax tokenizer (loaded strictly, the
     way `CoreMLOutputClassifier` loads it) produce the same ids as the
     reference Hugging Face tokenizer, on texts across scripts, and does the
     shipped pair encoder (`PairEncodingAdapter`, driven by a per-candidate
     contract) assemble the same input_ids / attention_mask / token_type_ids
     as this file's mirror of it (padding and truncation included)?
  2. Conversion: does a fixed-length three-class prototype (backbone plus a
     deterministic linear head, no training) convert to Core ML at FLOAT32
     compute with coremltools, and how large is it?
  3. Placement: do CPU-only, CPU+GPU, CPU+Neural Engine and all-units
     predictions agree with PyTorch on discriminating synthetic inputs? Any
     non-finite or constant output, class flip or drift is reported as such.

Nothing here is an accuracy result, a winner or a frozen-report run; the
frozen rows are never read. Everything the probe downloads or exports lives
under the gitignored main-checkout tree `artifacts/issue-996-edit-judge/`.

Run from the worktree, with the runner built (`swift build -c release` in
`scripts/eval/alias_runner`) and the probe venv created
(`artifacts/issue-996-edit-judge/.venv`, torch + transformers 4.50.0 +
coremltools 9.0):

  <main>/artifacts/issue-996-edit-judge/.venv/bin/python \\
      scripts/eval/probe_edit_judge_compatibility.py --artifacts <main>/artifacts/issue-996-edit-judge

Pure helpers (`mirror_pair_encoding`, `compare_ids`, `placement_verdict`) are
tested in `scripts/eval/tests/test_probe_edit_judge_compatibility.py`.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from uuid import uuid4

ROOT = Path(__file__).parent.parent.parent.resolve()
RUNNER_BIN = ROOT / "scripts/eval/alias_runner/.build/release/AliasRunner"

# Toolchain the probe's numbers are valid for. Anything else is refused
# before conversion, never silently accepted (the shipped converter pins the
# same way: `scripts/convert-output-classifier.py`).
# The pinned subset every entrypoint (probe, trainer, converter) refuses to
# run without; the rest of `toolchain_report()` is recorded, not enforced.
# Source of the pins: scripts/eval/edit-judge-requirements.txt.
EXPECTED_TOOLCHAIN = {"transformers": "4.50.0", "coremltools": "9.0", "numpy": "2.3.5"}


def toolchain_report() -> dict:
    """Every version a receipt must carry to be reproducible. Imports are
    local so the gate and data modules stay importable without torch."""
    import coremltools
    import numpy
    import safetensors
    import tokenizers
    import torch
    import transformers

    return {
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "numpy": numpy.__version__,
        "torch": torch.__version__,
        "transformers": transformers.__version__,
        "tokenizers": tokenizers.__version__,
        "safetensors": safetensors.__version__,
        "coremltools": coremltools.__version__,
    }


def toolchain_problems(report: dict) -> list[str]:
    """Empty when the pinned subset matches EXPECTED_TOOLCHAIN exactly; a
    missing key is a problem, never a pass."""
    return [
        f"{key} {report.get(key)!r} is not the pinned {want!r}"
        for key, want in EXPECTED_TOOLCHAIN.items()
        if report.get(key) != want
    ]

# --- Candidates (plan §2.2, revised 2026-09-18) ---

CANDIDATES = {
    "xenc-mmbert-small": {
        "hf": "jhu-clsp/mmBERT-small",
        "family": "gemma_bpe",
        "template": "bert_pair",  # [CLS] a [SEP] b [SEP]
        "token_types": "none",
    },
    "xenc-mdeberta-v3-base": {
        "hf": "microsoft/mdeberta-v3-base",
        "family": "sentencepiece_unigram",
        "template": "bert_pair",
        "token_types": "bert_segments",
    },
    "xenc-xlmr-base": {
        "hf": "FacebookAI/xlm-roberta-base",
        "family": "sentencepiece_unigram",
        "template": "roberta_pair",  # <s> a </s></s> b </s>
        "token_types": "none",
    },
}

# Non-frozen fixtures: at least four languages, non-Latin scripts, padding
# (short) and truncation (long) cases. None of these sentences is a frozen
# row (the frozen rows are never read here; the family/hash disjointness is
# asserted by the test file against the shipped manifest).
TEXT_FIXTURES = [
    ("en", "deploy it to tail scale tonight"),
    ("en", "the quarterly numbers look fine, ship it"),
    ("de", "wir treffen uns am Dienstag im Büro"),
    ("es", "llama a Marisol mañana por la tarde"),
    ("fr", "envoie le rapport à Émilie avant midi"),
    ("hi", "कृपया रिपोर्ट कल भेजें"),
    ("ar", "أرسل التقرير إلى سارة غدا"),
    ("zh", "请明天把报告发给王伟"),
    ("ja", "明日レポートを田中さんに送ってください"),
    ("ru", "отправь отчёт Алине завтра утром"),
    ("ko", "내일 보고서를 민준에게 보내 주세요"),
    ("el", "στείλε την αναφορά στη Μαρία αύριο"),
    ("en", "x"),
    ("mixed", "Kubernetes ↔ cuber netties, PostHog → post hog; 12,345 tokens"),
]

PAIR_FIXTURES = [
    ("tail scale → Tailscale", "deploy it to tail scale tonight"),
    ("Marisa → Marisol", "send it to Marisa today"),
    ("you mommy → Umami", "open the you mommy dashboard"),
    ("Dienstag → Montag", "wir treffen uns am Dienstag im Büro"),
    ("Jorje → Jorge", "llama a Jorje mañana"),
    ("सारा → सरा", "कृपया रिपोर्ट सारा को भेजें"),
    ("王伟 → 王维", "请明天把报告发给王伟"),
    # Truncation: a long context forces the output-side budget.
    ("fast → quickly", " ".join(["please reply fast because the release train leaves"] * 20)),
    # Truncation on the input side: a very long edit string.
    (" ".join(["tail scale"] * 80) + " → Tailscale", "deploy it tonight"),
]

MAX_LENGTH = 128


# --- Pure helpers (tested) ---


def compare_ids(expected: list[int], actual: list[int]) -> Optional[str]:
    """None when identical; otherwise a short description of the first
    divergence (never the text)."""
    if expected == actual:
        return None
    n = min(len(expected), len(actual))
    for i in range(n):
        if expected[i] != actual[i]:
            return f"first divergence at index {i}: expected {expected[i]}, got {actual[i]} (lengths {len(expected)} vs {len(actual)})"
    return f"length differs: expected {len(expected)}, got {len(actual)}"


def build_contract(name: str, spec: dict, specials: dict[str, int]) -> dict:
    """A candidate contract in the shipped `TokenizerContract` shape. Pad,
    cls/sep (or bos/eos) ids come from the tokenizer."""
    if spec["template"] == "bert_pair":
        sequence = ["cls", "input", "sep", "output", "sep"]
        special_ids = {"pad": specials["pad"], "cls": specials["cls"], "sep": specials["sep"]}
        budget = 3
    else:
        sequence = ["bos", "input", "eos", "eos", "output", "eos"]
        special_ids = {"pad": specials["pad"], "bos": specials["bos"], "eos": specials["eos"]}
        budget = 4
    token_types = (
        {"kind": "bert_segments", "needsSegmentIds": True, "segmentVocabSize": 2, "inputSegmentId": 0, "outputSegmentId": 1, "padSegmentId": 0}
        if spec["token_types"] == "bert_segments"
        else {"kind": "none", "needsSegmentIds": False, "segmentVocabSize": 1, "inputSegmentId": 0, "outputSegmentId": 0, "padSegmentId": 0}
    )
    return {
        "contractVersion": 1,
        "modelName": name,
        "family": spec["family"],
        "inputPrefix": "Edit: ",
        "outputPrefix": "Sentence: ",
        "pairTemplate": {"kind": spec["template"], "sequence": sequence},
        "specialTokenIds": special_ids,
        "specialsBudget": budget,
        "maxLength": MAX_LENGTH,
        "minOutputTokens": 32,
        "inputTruncationPolicy": {"kind": "head_tail", "headTokens": 48, "tailTokens": 16},
        "outputTruncationPolicy": {"kind": "head_tail", "headTokens": 40, "tailTokens": 24},
        "tokenTypePolicy": token_types,
        "contractHash": None,
    }


def _head_tail(ids: list[int], cap: int, head_tokens: int, tail_tokens: int) -> list[int]:
    if len(ids) <= cap:
        return ids
    head = min(head_tokens, cap - tail_tokens)
    tail = cap - head
    if head <= 0 or tail <= 0:
        return ids[:cap]
    return ids[:head] + ids[-tail:]


def mirror_pair_encoding(contract: dict, encode, input_text: str, output_text: str) -> dict:
    """Python mirror of `PairEncodingAdapter.encodePair`, step for step. The
    Swift adapter is the shipped authority; this mirror exists so the probe
    can say "Swift assembled what the training pipeline will assemble"."""
    in_ids = encode(contract["inputPrefix"] + input_text)
    out_ids = encode(contract["outputPrefix"] + output_text)
    max_len = contract["maxLength"]
    specials = contract["specialsBudget"]
    min_out = contract["minOutputTokens"]
    itp, otp = contract["inputTruncationPolicy"], contract["outputTruncationPolicy"]
    max_input = max(1, max_len - specials - min_out)
    in_ids = _head_tail(in_ids, max_input, itp["headTokens"], itp["tailTokens"])
    budget = max(min_out, max_len - len(in_ids) - specials)
    if len(out_ids) > budget:
        if otp["kind"] == "tail":
            out_ids = out_ids[:budget]
        else:
            out_ids = _head_tail(out_ids, budget, otp["headTokens"], otp["tailTokens"])
    special_ids = contract["specialTokenIds"]
    ids: list[int] = []
    for token in contract["pairTemplate"]["sequence"]:
        if token == "input":
            ids.extend(in_ids)
        elif token == "output":
            ids.extend(out_ids)
        elif token in special_ids:
            ids.append(special_ids[token])
    policy = contract["tokenTypePolicy"]
    in_seg, out_seg, pad_seg = policy.get("inputSegmentId", 0), policy.get("outputSegmentId", 1), policy.get("padSegmentId", 0)
    if policy["kind"] == "none" or not policy["needsSegmentIds"]:
        segments = [pad_seg] * len(ids)
    else:
        segments = []
        current = in_seg
        for token in contract["pairTemplate"]["sequence"]:
            if token == "input":
                segments.extend([current] * len(in_ids))
            elif token == "output":
                current = out_seg
                segments.extend([current] * len(out_ids))
            elif token in special_ids:
                segments.append(current)
    ids, segments = ids[:max_len], segments[:max_len]
    mask = [1] * len(ids)
    pad = max_len - len(ids)
    if pad > 0:
        ids += [special_ids["pad"]] * pad
        mask += [0] * pad
        segments += [pad_seg] * pad
    return {"input_ids": ids, "attention_mask": mask, "token_type_ids": segments}


def placement_verdict(reference: list[list[float]], observed: list[list[float]], tolerance: float = 1e-3, classes: int = 3) -> dict:
    """Compare one compute unit's logits against PyTorch: non-finite,
    constant (every row identical), argmax flips and max abs drift. The
    batches must be complete (same row count, `classes` logits per row: three
    for the alias objective, two for detection; at least two rows) and the
    reference itself finite and discriminating, otherwise the verdict is a
    refusal, never `ok`."""
    import math

    shape_ok = (
        len(reference) >= 2
        and len(observed) == len(reference)
        and all(len(row) == classes for row in reference)
        and all(len(row) == classes for row in observed)
    )
    if not shape_ok:
        return {"ok": False, "error": f"expected matching nonempty batches of {classes}-class logits", "reference_rows": len(reference), "observed_rows": len(observed)}
    if not all(math.isfinite(x) for row in reference for x in row):
        return {"ok": False, "error": "reference logits are nonfinite"}
    if all(row == reference[0] for row in reference):
        return {"ok": False, "error": "reference fixtures are not discriminating"}

    flat = [x for row in observed for x in row]
    nonfinite = sum(1 for x in flat if not math.isfinite(x))
    constant = len(observed) > 1 and all(row == observed[0] for row in observed)
    flips = 0
    drift = 0.0
    for r, o in zip(reference, observed):
        if r.index(max(r)) != o.index(max(o)):
            flips += 1
        drift = max(drift, max(abs(a - b) for a, b in zip(r, o)))
    ok = nonfinite == 0 and not constant and flips == 0 and drift <= tolerance
    return {"ok": ok, "nonfinite": nonfinite, "constant_output": constant, "argmax_flips": flips, "max_abs_drift": drift, "tolerance": tolerance}


# --- Runner bridge ---


def swift_tokenize(tokenizer_dir: Path, texts: list[str], contract_path: Optional[Path], pairs: Optional[list[tuple[str, str]]], workdir: Path, stack: str = "vendored") -> dict:
    """`stack` is `vendored` (the shipped Argmax stack through the LLM
    benchmark door) or `upstream` (the pinned Hugging Face swift-transformers
    tokenizer the runner alone links, #996 2b-ii experiment; texts only)."""
    request = {"tokenizer_folder": str(tokenizer_dir), "texts": texts}
    if contract_path is not None and pairs is not None:
        # Both stacks assemble pairs through the shipped PairEncodingAdapter;
        # only the encode function differs (#996 chunk 4a-ii for upstream).
        request["contract"] = str(contract_path)
        request["pairs"] = [{"input": a, "output": b} for a, b in pairs]
    req = workdir / f"tokenize-request-{stack}.json"
    out = workdir / f"tokenize-response-{stack}.json"
    req.write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")
    proc = subprocess.run([str(RUNNER_BIN), "tokenize", "--request", str(req), "--out", str(out), "--stack", stack], capture_output=True, text=True)
    if proc.returncode != 0:
        return {"loaded": False, "error": f"runner exit {proc.returncode}: {proc.stderr.strip()[:300]}"}
    return json.loads(out.read_text(encoding="utf-8"))


# --- Per-candidate probe ---


@dataclass
class CandidateReport:
    name: str
    hf: str
    revision: str = ""
    tokenizer_class: str = ""
    tokenizer_files_sha256: dict = field(default_factory=dict)
    tokenizer_loaded_in_swift: bool = False
    tokenizer_error: Optional[str] = None
    text_parity: dict = field(default_factory=dict)
    upstream: dict = field(default_factory=dict)
    pair_parity: dict = field(default_factory=dict)
    conversion: dict = field(default_factory=dict)
    placement: dict = field(default_factory=dict)
    upstream_text_parity_ok: bool = False
    upstream_pair_parity_ok: bool = False
    verdict: str = "not-run"
    notes: list = field(default_factory=list)


def resolve_revision(repo: str) -> str:
    """The immutable commit sha of the Hub snapshot every download in this
    run uses, resolved once and recorded; never a guessed value."""
    from huggingface_hub import HfApi

    info = HfApi().model_info(repo)
    if not info.sha:
        raise RuntimeError(f"could not resolve a revision for {repo}")
    return info.sha


def file_digests(folder: Path) -> dict[str, str]:
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(folder.iterdir()) if p.is_file()}


def probe_tokenizer(name: str, spec: dict, models_dir: Path, workdir: Path, report: CandidateReport) -> None:
    from transformers import AutoTokenizer

    tok = AutoTokenizer.from_pretrained(spec["hf"], revision=spec["revision"])
    tok_dir = models_dir / name / "tokenizer"
    tok_dir.mkdir(parents=True, exist_ok=True)
    tok.save_pretrained(tok_dir)
    report.tokenizer_class = type(tok).__name__
    report.tokenizer_files_sha256 = file_digests(tok_dir)
    texts = [t for _, t in TEXT_FIXTURES]
    expected = {t: tok(t, add_special_tokens=False)["input_ids"] for t in texts}

    specials = {
        "pad": tok.pad_token_id,
        "cls": tok.cls_token_id,
        "sep": tok.sep_token_id,
        "bos": tok.bos_token_id if tok.bos_token_id is not None else tok.cls_token_id,
        "eos": tok.eos_token_id if tok.eos_token_id is not None else tok.sep_token_id,
    }
    missing = sorted(k for k, v in specials.items() if v is None)
    if missing:
        report.tokenizer_error = f"tokenizer has no id for required specials {missing}"
        report.text_parity = {"compared": 0, "matched": 0, "mismatches": []}
        report.pair_parity = {"compared": 0, "matched": 0, "mismatches": []}
        return
    contract = build_contract(name, spec, specials)
    contract_path = workdir / f"{name}-contract.json"
    contract_path.write_text(json.dumps(contract, indent=2), encoding="utf-8")

    # The upstream stack is measured for every candidate, whatever the
    # vendored stack does with it: texts AND contract-assembled pairs.
    encode = lambda text: tok(text, add_special_tokens=False)["input_ids"]  # noqa: E731
    report.upstream = upstream_text_parity(tok_dir, texts, expected, workdir, contract, contract_path, PAIR_FIXTURES, encode)
    swift = swift_tokenize(tok_dir, texts, contract_path, PAIR_FIXTURES, workdir)
    report.tokenizer_loaded_in_swift = bool(swift.get("loaded"))
    if not swift.get("loaded"):
        report.tokenizer_error = swift.get("error")
        report.text_parity = {"compared": 0, "matched": 0, "mismatches": []}
        report.pair_parity = {"compared": 0, "matched": 0, "mismatches": []}
        return
    got_texts = [e.get("text") for e in swift.get("texts") or []]
    if sorted(got_texts) != sorted(texts) or len(set(got_texts)) != len(texts):
        report.tokenizer_error = f"runner returned {len(got_texts)} text entries for {len(texts)} fixtures, or texts differ"
        report.text_parity = {"compared": 0, "matched": 0, "mismatches": []}
        report.pair_parity = {"compared": 0, "matched": 0, "mismatches": []}
        return
    mismatches = []
    matched = 0
    for entry in swift["texts"]:
        problem = compare_ids(expected[entry["text"]], entry["ids"])
        if problem is None:
            matched += 1
        else:
            lang = next(l for l, t in TEXT_FIXTURES if t == entry["text"])
            mismatches.append({"language": lang, "problem": problem})
    report.text_parity = {"compared": len(texts), "matched": matched, "mismatches": mismatches, "languages": sorted({l for l, _ in TEXT_FIXTURES})}

    if swift.get("contract_error"):
        report.pair_parity = {"compared": 0, "matched": 0, "mismatches": [], "contract_error": swift["contract_error"]}
        return
    report.pair_parity = dict(pair_parity(contract, encode, PAIR_FIXTURES, swift.get("pairs") or []), contract=str(contract_path))


def pair_parity(contract: dict, encode, pairs: list[tuple[str, str]], got_pairs: list[dict]) -> dict:
    """Contract-assembled pairs from the runner against the Python mirror:
    ids, mask and segment ids must all match, padded and truncated rows
    included (the fixtures carry both)."""
    if len(got_pairs) != len(pairs):
        return {"compared": 0, "matched": 0, "mismatches": [], "contract_error": f"runner returned {len(got_pairs)} pairs for {len(pairs)} fixtures"}
    matched = 0
    mismatches = []
    padded = truncated = 0
    for i, ((a, b), got) in enumerate(zip(pairs, got_pairs)):
        want = mirror_pair_encoding(contract, encode, a, b)
        if want["attention_mask"][-1] == 1:
            truncated += 1
        else:
            padded += 1
        problems = {k: compare_ids(want[k], got[k]) for k in ("input_ids", "attention_mask", "token_type_ids")}
        problems = {k: v for k, v in problems.items() if v}
        if problems:
            mismatches.append({"pair": i, "problems": problems})
        else:
            matched += 1
    return {"compared": len(pairs), "matched": matched, "mismatches": mismatches, "padded": padded, "truncated": truncated}


def upstream_text_parity(tok_dir: Path, texts: list[str], expected: dict[str, list[int]], workdir: Path, contract: Optional[dict] = None, contract_path: Optional[Path] = None, pairs: Optional[list[tuple[str, str]]] = None, encode=None) -> dict:
    """Text parity, and pair parity when a contract is given, through the
    pinned upstream tokenizer (runner only)."""
    swift = swift_tokenize(tok_dir, texts, contract_path, pairs, workdir, stack="upstream")
    if not swift.get("loaded"):
        return {"stack": swift.get("stack", "upstream"), "loaded": False, "error": swift.get("error"), "compared": 0, "matched": 0, "mismatches": []}
    got_texts = [e.get("text") for e in swift.get("texts") or []]
    if sorted(got_texts) != sorted(texts) or len(set(got_texts)) != len(texts):
        return {"stack": swift.get("stack"), "loaded": True, "error": "runner returned a different text set", "compared": 0, "matched": 0, "mismatches": []}
    matched = 0
    mismatches = []
    for entry in swift["texts"]:
        problem = compare_ids(expected[entry["text"]], entry["ids"])
        if problem is None:
            matched += 1
        else:
            lang = next(l for l, t in TEXT_FIXTURES if t == entry["text"])
            mismatches.append({"language": lang, "problem": problem})
    result = {"stack": swift.get("stack"), "loaded": True, "compared": len(texts), "matched": matched, "mismatches": mismatches, "special_tokens": swift.get("special_tokens")}
    if contract is not None and pairs is not None:
        if swift.get("contract_error"):
            result["pairs"] = {"compared": 0, "matched": 0, "mismatches": [], "contract_error": swift["contract_error"]}
        else:
            result["pairs"] = pair_parity(contract, encode, pairs, swift.get("pairs") or [])
    return result


def probe_conversion(name: str, spec: dict, models_dir: Path, workdir: Path, report: CandidateReport, n_inputs: int) -> None:
    import numpy as np
    import torch
    import coremltools as ct
    from transformers import AutoModel, AutoTokenizer

    torch.manual_seed(996)
    tok = AutoTokenizer.from_pretrained(spec["hf"], revision=spec["revision"])
    kwargs = {}
    if spec["hf"].startswith("jhu-clsp/mmBERT"):
        kwargs["attn_implementation"] = "eager"
    backbone = AutoModel.from_pretrained(spec["hf"], revision=spec["revision"], torchscript=False, **kwargs).eval()
    hidden = backbone.config.hidden_size
    needs_types = spec["token_types"] == "bert_segments"

    class Prototype(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.backbone = backbone
            self.head = torch.nn.Linear(hidden, 3)

        def forward(self, input_ids, attention_mask, token_type_ids=None):
            if token_type_ids is not None and needs_types:
                out = self.backbone(input_ids=input_ids, attention_mask=attention_mask, token_type_ids=token_type_ids)
            else:
                out = self.backbone(input_ids=input_ids, attention_mask=attention_mask)
            cls = out.last_hidden_state[:, 0, :]
            return self.head(cls)

    model = Prototype().eval()
    # Discriminating synthetic inputs: real sentences from the fixtures so
    # the logits differ per row (a constant output is a defect signal).
    texts = [t for _, t in TEXT_FIXTURES][:n_inputs]
    enc = tok(texts, padding="max_length", truncation=True, max_length=MAX_LENGTH, return_tensors="pt")
    ids = enc["input_ids"].to(torch.int32)
    mask = enc["attention_mask"].to(torch.int32)
    types = enc["token_type_ids"].to(torch.int32) if ("token_type_ids" in enc and needs_types) else None
    with torch.no_grad():
        ref = model(ids, mask, types) if types is not None else model(ids, mask)
    reference = ref.float().tolist()

    example = (ids[:1], mask[:1], types[:1]) if types is not None else (ids[:1], mask[:1])
    inputs = [
        ct.TensorType(name="input_ids", shape=(1, MAX_LENGTH), dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=(1, MAX_LENGTH), dtype=np.int32),
    ]
    if types is not None:
        inputs.append(ct.TensorType(name="token_type_ids", shape=(1, MAX_LENGTH), dtype=np.int32))
    t0 = time.time()
    try:
        with torch.no_grad():
            traced = torch.jit.trace(model, example, strict=False)
        mlmodel = ct.convert(
            traced,
            inputs=inputs,
            outputs=[ct.TensorType(name="logits")],
            convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT32,
            minimum_deployment_target=ct.target.macOS14,
        )
    except Exception as exc:  # the probe's job is to report this, not to hide it
        report.conversion = {"ok": False, "error": f"{type(exc).__name__}: {str(exc)[:400]}", "seconds": round(time.time() - t0, 1)}
        return
    out_dir = workdir
    package = out_dir / f"{name}-prototype-fp32.mlpackage"
    if package.exists():
        import shutil

        shutil.rmtree(package)
    mlmodel.save(str(package))
    size = sum(p.stat().st_size for p in package.rglob("*") if p.is_file())
    package_digest = hashlib.sha256()
    for f in sorted(p for p in package.rglob("*") if p.is_file()):
        package_digest.update(f.relative_to(package).as_posix().encode()); package_digest.update(f.read_bytes())
    report.conversion = {
        "ok": True,
        "prototype_sha256": package_digest.hexdigest(),
        "head_seed": 996,
        "seconds": round(time.time() - t0, 1),
        "mlpackage": str(package),
        "size_bytes": size,
        "size_mb": round(size / 1e6, 1),
        "compute_precision": "FLOAT32",
        "minimum_deployment_target": "macOS14",
        "params": sum(p.numel() for p in model.parameters()),
    }

    # Placement: four compute policies, same inputs, compared to PyTorch.
    units = {
        "cpuOnly": ct.ComputeUnit.CPU_ONLY,
        "cpuAndGPU": ct.ComputeUnit.CPU_AND_GPU,
        "cpuAndNeuralEngine": ct.ComputeUnit.CPU_AND_NE,
        "all": ct.ComputeUnit.ALL,
    }
    placement: dict = {}
    for label, unit in units.items():
        try:
            t_load = time.time()
            loaded = ct.models.MLModel(str(package), compute_units=unit)
            load_s = time.time() - t_load
            observed = []
            latencies = []
            for i in range(len(texts)):
                feed = {"input_ids": ids[i : i + 1].numpy(), "attention_mask": mask[i : i + 1].numpy()}
                if types is not None:
                    feed["token_type_ids"] = types[i : i + 1].numpy()
                loaded.predict(feed)  # warm
                t1 = time.time()
                pred = loaded.predict(feed)
                latencies.append((time.time() - t1) * 1000)
                observed.append([float(x) for x in np.asarray(pred["logits"]).reshape(-1)])
            verdict = placement_verdict(reference, observed)
            verdict.update({"load_seconds": round(load_s, 2), "warm_latency_ms_p50": round(sorted(latencies)[len(latencies) // 2], 1), "warm_latency_ms_max": round(max(latencies), 1), "requested_compute_units": label, "note": "requested policy; physical placement is not observable"})
            placement[label] = verdict
        except Exception as exc:
            placement[label] = {"ok": False, "error": f"{type(exc).__name__}: {str(exc)[:300]}"}
    report.placement = placement


def probe_candidate(name: str, spec: dict, artifacts: Path, run_root: Path, n_inputs: int, skip_conversion: bool) -> CandidateReport:
    report = CandidateReport(name=name, hf=spec["hf"])
    models_dir = artifacts / "models"
    workdir = run_root / name
    workdir.mkdir(parents=True, exist_ok=True)
    try:
        spec = dict(spec, revision=resolve_revision(spec["hf"]))
        report.revision = spec["revision"]
        probe_tokenizer(name, spec, models_dir, workdir, report)
    except Exception as exc:
        report.tokenizer_error = f"{type(exc).__name__}: {str(exc)[:300]}"
    if not skip_conversion:
        try:
            probe_conversion(name, spec, models_dir, workdir, report, n_inputs)
        except Exception as exc:
            report.conversion = {"ok": False, "error": f"{type(exc).__name__}: {str(exc)[:400]}"}
    tokenizer_ok = report.tokenizer_loaded_in_swift and report.text_parity.get("matched") == report.text_parity.get("compared") and report.pair_parity.get("matched") == report.pair_parity.get("compared") and report.pair_parity.get("compared", 0) > 0
    report.upstream_text_parity_ok = bool(report.upstream.get("loaded")) and report.upstream.get("matched") == report.upstream.get("compared") and report.upstream.get("compared", 0) > 0
    up_pairs = report.upstream.get("pairs") or {}
    report.upstream_pair_parity_ok = up_pairs.get("matched") == up_pairs.get("compared") and up_pairs.get("compared", 0) > 0 and up_pairs.get("padded", 0) > 0 and up_pairs.get("truncated", 0) > 0
    conversion_ok = bool(report.conversion.get("ok"))
    placement_ok = bool(report.placement) and all(v.get("ok") for v in report.placement.values())
    if skip_conversion:
        report.verdict = "tokenizer-compatible" if tokenizer_ok else "tokenizer-incompatible"
    elif tokenizer_ok and conversion_ok and placement_ok:
        report.verdict = "compatible"
    elif not tokenizer_ok:
        report.verdict = "tokenizer-incompatible"
    elif not conversion_ok:
        report.verdict = "conversion-failed"
    else:
        report.verdict = "placement-failed"
    return report


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--artifacts", type=Path, required=True, help="main-checkout artifacts/issue-996-edit-judge")
    p.add_argument("--candidates", nargs="*", default=list(CANDIDATES), choices=list(CANDIDATES))
    p.add_argument("--inputs", type=int, default=8, help="synthetic inputs per placement check")
    p.add_argument("--skip-conversion", action="store_true", help="tokenizer half only; the report says so")
    args = p.parse_args()
    if not RUNNER_BIN.exists():
        print(f"INFRA-ERROR: runner missing at {RUNNER_BIN}; build with swift build -c release", file=sys.stderr)
        return 2
    import torch
    import transformers
    import coremltools as ct

    toolchain = toolchain_report()
    problems = toolchain_problems(toolchain)
    if problems:
        print("INFRA-ERROR: toolchain is not the pinned one: " + "; ".join(problems), file=sys.stderr)
        return 2
    # One directory per run; earlier receipts are never overwritten.
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run_root = args.artifacts / "compat-runs" / f"{run_id}-{uuid4().hex[:8]}"
    run_root.mkdir(parents=True, exist_ok=False)
    fixture_digest = hashlib.sha256(json.dumps({"texts": TEXT_FIXTURES, "pairs": PAIR_FIXTURES, "max_length": MAX_LENGTH, "inputs": args.inputs}, ensure_ascii=False, sort_keys=True).encode()).hexdigest()

    reports = [probe_candidate(name, CANDIDATES[name], args.artifacts, run_root, args.inputs, args.skip_conversion) for name in args.candidates]
    doc = {
        "run_id": run_root.name,
        "fixture_sha256": fixture_digest,
        "conversion_skipped": args.skip_conversion,
        "probe": "edit-judge compatibility (#996 chunk 2b)",
        "not_acceptance_evidence": "compatibility only; no accuracy, no winner, frozen rows never read",
        "machine": {"platform": platform.platform(), "machine": platform.machine(), "python": sys.version.split()[0]},
        "toolchain": toolchain,
        "runner_sha256": hashlib.sha256(RUNNER_BIN.read_bytes()).hexdigest(),
        "fixtures": {"texts": len(TEXT_FIXTURES), "languages": sorted({l for l, _ in TEXT_FIXTURES}), "pairs": len(PAIR_FIXTURES)},
        "candidates": [r.__dict__ for r in reports],
    }
    out = run_root / "report.json"
    out.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    for r in reports:
        print(f"{r.name}: {r.verdict}; vendored tokenizer {r.tokenizer_class} loaded={r.tokenizer_loaded_in_swift} texts {r.text_parity.get('matched')}/{r.text_parity.get('compared')} pairs {r.pair_parity.get('matched')}/{r.pair_parity.get('compared')}; upstream texts {r.upstream.get('matched')}/{r.upstream.get('compared')} pairs {(r.upstream.get('pairs') or {}).get('matched')}/{(r.upstream.get('pairs') or {}).get('compared')} loaded={r.upstream.get('loaded')}; conversion {r.conversion.get('ok')} {r.conversion.get('size_mb', '')}MB; placement {{{', '.join(f'{k}:{v.get('ok')}' for k, v in r.placement.items())}}}")
        if r.upstream.get("error"):
            print(f"  upstream tokenizer error: {r.upstream['error']}")
        if r.tokenizer_error:
            print(f"  tokenizer error: {r.tokenizer_error}")
        if r.conversion.get("error"):
            print(f"  conversion error: {r.conversion['error']}")
    print(f"report: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
