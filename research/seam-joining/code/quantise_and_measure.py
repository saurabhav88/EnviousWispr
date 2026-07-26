"""Shrink the winning model and measure what it costs in quality and speed.

The winner (XLM-R, square-root balanced sampling) is 1.1 GB, which is the last
blocker to shipping. Two reductions are tested, and BOTH are measured rather
than assumed cheap:

  fp16    half precision. Halves the file. Usually free in quality.
  int8    dynamic quantisation of the linear layers. Roughly quarters it.
          This one genuinely can cost accuracy, so it is measured, not trusted.

Latency is measured HERE, on the Mac, because that is where the product runs.
Every timing so far came from the 4090 and is irrelevant to shipping.
"""

import json
import os
import statistics
import sys
import time

import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

LABELS = ["KEEP", "MERGE_SPACE", "MERGE_COMMA"]
SEAM = "<seam>"
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "seam-sqrt-s22")


def load_rows():
    rows = [json.loads(l) for l in open(os.path.join(HERE, "seam_test.jsonl"), encoding="utf-8")]
    zero = os.path.join(HERE, "seam_zeroshot.jsonl")
    unseen = [json.loads(l) for l in open(zero, encoding="utf-8")] if os.path.exists(zero) else []
    return rows, unseen


def evaluate(model, tok, rows, batch=32):
    correct = wrong_merge = keep_n = 0
    for i in range(0, len(rows), batch):
        chunk = rows[i : i + batch]
        texts = [
            f"{' '.join(r['rec1'].split()[-18:])} {SEAM} {' '.join(r['rec2'].split()[:14])}"
            for r in chunk
        ]
        enc = tok(texts, truncation=True, max_length=96, padding=True, return_tensors="pt")
        with torch.no_grad():
            pred = model(**enc).logits.argmax(-1).tolist()
        for r, p in zip(chunk, pred):
            lab = LABELS[p]
            correct += int(lab == r["label"])
            if r["label"] == "KEEP":
                keep_n += 1
                wrong_merge += int(lab != "KEEP")
    return correct / len(rows), wrong_merge


def latency(model, tok, rows, n=60):
    """Single-item latency, which is what a user actually experiences. Batched
    numbers flatter the result and do not reflect one dictation ending."""
    samples = []
    for r in rows[:n]:
        text = f"{' '.join(r['rec1'].split()[-18:])} {SEAM} {' '.join(r['rec2'].split()[:14])}"
        enc = tok(text, truncation=True, max_length=96, return_tensors="pt")
        t0 = time.perf_counter()
        with torch.no_grad():
            model(**enc)
        samples.append((time.perf_counter() - t0) * 1000)
    samples.sort()
    return statistics.median(samples), samples[int(0.95 * len(samples))]


def dir_size_mb(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            total += os.path.getsize(os.path.join(root, f))
    return total / 1e6


def report(name, size, acc, wm, acc_z, wm_z, med, p95):
    print(f"{name:16}{size:>7.0f}MB{100*acc:>12.1f}%{wm:>7}"
          f"{100*acc_z:>11.1f}%{wm_z:>7}{med:>10.1f}{p95:>9.1f}", flush=True)


def main():
    rows, unseen = load_rows()
    tok = AutoTokenizer.from_pretrained(SRC)

    print(f"\n{'variant':16}{'size':>9}{'trained acc':>13}{'wrong':>7}"
          f"{'unseen acc':>12}{'wrong':>7}{'median ms':>11}{'p95 ms':>9}", flush=True)
    print("-" * 84, flush=True)

    # Each variant is measured and printed independently. A failure in one must
    # not discard the others - the int8 path died on this Mac and took the fp32
    # and fp16 numbers with it, because everything was printed at the end.
    def measure(name, build):
        try:
            model, size = build()
            model.eval()
            acc, wm = evaluate(model, tok, rows)
            acc_z, wm_z = evaluate(model, tok, unseen) if unseen else (float("nan"), 0)
            med, p95 = latency(model, tok, rows)
            report(name, size, acc, wm, acc_z, wm_z, med, p95)
        except Exception as exc:
            print(f"{name:16}  FAILED: {type(exc).__name__}: {str(exc)[:56]}", flush=True)

    def fp32():
        return AutoModelForSequenceClassification.from_pretrained(SRC), dir_size_mb(SRC)

    def fp16():
        half = AutoModelForSequenceClassification.from_pretrained(SRC, dtype=torch.float16)
        out = os.path.join(HERE, "seam-fp16")
        half.save_pretrained(out)
        tok.save_pretrained(out)
        # Reload as fp32 for CPU inference; the weights carry fp16 rounding, which
        # is exactly what shipping fp16 weights means for quality.
        return (AutoModelForSequenceClassification.from_pretrained(out, dtype=torch.float32),
                dir_size_mb(out))

    def int8():
        base = AutoModelForSequenceClassification.from_pretrained(SRC)
        qt = torch.quantization.quantize_dynamic(base, {torch.nn.Linear}, dtype=torch.qint8)
        qdir = os.path.join(HERE, "seam-int8")
        os.makedirs(qdir, exist_ok=True)
        torch.save(qt.state_dict(), os.path.join(qdir, "model_int8.pt"))
        return qt, dir_size_mb(qdir)

    measure("original fp32", fp32)
    measure("fp16 weights", fp16)
    measure("int8 dynamic", int8)

    print("\nLatency measured on this Mac, single item - what a user actually waits.", flush=True)
    print("int8 via torch needs a quantised backend that this arm64 build lacks;", flush=True)
    print("the real shipping path for Apple Silicon is Core ML or ONNX, not this.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
