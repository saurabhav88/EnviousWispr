"""Convert the seam classifier to Core ML and measure what that costs.

This is the plan's central premise, so it is measured rather than asserted: the
model currently exists only in training format, which cannot ship in a Mac app
at all. Core ML is the route the speech model already takes.

Three things are measured, each INDEPENDENTLY so one failure cannot discard the
others (the earlier quantisation script printed everything at the end, so the
int8 failure took the fp32 and fp16 numbers with it):

  agreement   does the converted model predict what the original predicted?
              Measured against BOTH test sets, and reported as accuracy and as
              wrong merges - the number that decides shippability.
  size        the .mlpackage on disk. This decides bundle-vs-download.
  latency     single item, on this Mac. Batched numbers flatter the result and
              do not reflect one dictation ending.

Variants, cheapest reduction first:
  fp16        Core ML's default weight precision. Halves the file.
  int8        8-bit linear weight quantisation - the same setting the shipped
              speech model uses, so it is a proven-shippable precision here.
  palettized  4-bit lookup-table weights. Roughly quarters it. Genuinely can
              cost accuracy, so it is measured, never assumed cheap.
"""

import json
import os
import shutil
import statistics
import sys
import time

import numpy as np
import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch.ops import _get_inputs
from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op


# The current library builds its attention mask with `new_ones`, which the
# converter does not know. Pinning older library versions was tried first and
# turned into a version fight (the tokenizer, then the config, then the dtype),
# so the op is taught directly instead: one shim, no version roulette.
@register_torch_op(override=True)
def new_ones(context, node):
    inputs = _get_inputs(context, node)
    result = mb.fill(shape=inputs[1], value=1.0, name=node.name)
    context.add(result)


LABELS = ["KEEP", "MERGE_SPACE", "MERGE_COMMA"]
SEAM = "<seam>"
MAX_LEN = 96
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "model", "seam-fp16")
OUT = os.path.join(ROOT, "model")


class LogitsOnly(torch.nn.Module):
    """Core ML wants tensors in and tensors out, not a HuggingFace output object."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids, attention_mask):
        return self.model(input_ids=input_ids, attention_mask=attention_mask).logits


def prepare_legacy_dir():
    """Present the trained model to an older library without copying 547 MB.

    Four conversion attempts all failed inside the CURRENT library's attention
    and masking code, in four different places: an op the converter lacks, a
    vectorised higher-order op, a training-dialect program, and a boolean mask
    combine. That is one class, not four bugs, so the fix is to stop patching
    ops and stop using that code path. The older library's plain forward has
    been convertible for years.

    It cannot read the newer save format directly - the config records the
    weight precision under a key it mis-parses, and the tokenizer records the
    added seam token as a list where it expects a mapping. Both are metadata,
    not weights, so a shim directory with corrected metadata and a symlink to
    the untouched weights is enough. The shipped artifact is never mutated.
    """
    legacy = os.path.join(OUT, "seam-legacy-view")
    os.makedirs(legacy, exist_ok=True)
    for name in os.listdir(SRC):
        target = os.path.join(legacy, name)
        if name.endswith(".safetensors") or name.endswith(".bin"):
            if not os.path.exists(target):
                os.symlink(os.path.join(SRC, name), target)
        elif name not in ("config.json", "tokenizer_config.json"):
            shutil.copy2(os.path.join(SRC, name), target)

    config = json.load(open(os.path.join(SRC, "config.json")))
    if "dtype" in config:
        config["torch_dtype"] = config.pop("dtype")
    json.dump(config, open(os.path.join(legacy, "config.json"), "w"), indent=2)

    tconfig = json.load(open(os.path.join(SRC, "tokenizer_config.json")))
    tconfig.pop("extra_special_tokens", None)
    tconfig["additional_special_tokens"] = [SEAM]
    json.dump(tconfig, open(os.path.join(legacy, "tokenizer_config.json"), "w"), indent=2)
    return legacy


def load_rows():
    def read(name):
        path = os.path.join(ROOT, "data", name)
        return [json.loads(l) for l in open(path, encoding="utf-8")] if os.path.exists(path) else []

    return read("seam_test.jsonl"), read("seam_zeroshot.jsonl")


def window(row):
    left = " ".join(row["rec1"].split()[-18:])
    right = " ".join(row["rec2"].split()[:14])
    return f"{left} {SEAM} {right}"


def encode(tok, rows):
    """One fixed-shape encoding, reused by every variant so the comparison is
    like-for-like and tokenisation cost never lands in a latency number."""
    enc = tok([window(r) for r in rows], truncation=True, max_length=MAX_LEN,
              padding="max_length", return_tensors="np")
    return (enc["input_ids"].astype(np.int32), enc["attention_mask"].astype(np.int32))


def torch_predictions(model, ids, mask, batch=32):
    out = []
    with torch.no_grad():
        for i in range(0, len(ids), batch):
            logits = model(input_ids=torch.from_numpy(ids[i : i + batch]).long(),
                           attention_mask=torch.from_numpy(mask[i : i + batch]).long()).logits
            out.extend(logits.argmax(-1).tolist())
    return out


def coreml_predictions(mlmodel, ids, mask, out_name):
    out = []
    for i in range(len(ids)):
        result = mlmodel.predict({"input_ids": ids[i : i + 1].astype(np.float32),
                                  "attention_mask": mask[i : i + 1].astype(np.float32)})
        out.append(int(np.argmax(result[out_name][0])))
    return out


def score(preds, rows):
    """Accuracy, and wrong merges: a KEEP row the model chose to merge. A wrong
    merge welds two of the user's sentences together and is invisible until they
    reread, which is why it is reported separately from accuracy."""
    correct = sum(int(LABELS[p] == r["label"]) for p, r in zip(preds, rows))
    wrong_merge = sum(1 for p, r in zip(preds, rows)
                      if r["label"] == "KEEP" and LABELS[p] != "KEEP")
    return correct / max(len(rows), 1), wrong_merge


def latency(mlmodel, ids, mask, out_name, n=60):
    samples = []
    for i in range(min(n, len(ids))):
        t0 = time.perf_counter()
        mlmodel.predict({"input_ids": ids[i : i + 1].astype(np.float32),
                         "attention_mask": mask[i : i + 1].astype(np.float32)})
        samples.append((time.perf_counter() - t0) * 1000)
    samples.sort()
    return statistics.median(samples), samples[int(0.95 * (len(samples) - 1))]


def dir_size_mb(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            total += os.path.getsize(os.path.join(root, f))
    return total / 1e6


def main():
    trained_rows, unseen_rows = load_rows()
    if not trained_rows:
        print("no test data found", file=sys.stderr)
        return 1

    source = prepare_legacy_dir()
    tok = AutoTokenizer.from_pretrained(source)
    torch_model = AutoModelForSequenceClassification.from_pretrained(
        source, torch_dtype=torch.float32)
    torch_model.eval()

    t_ids, t_mask = encode(tok, trained_rows)
    z_ids, z_mask = encode(tok, unseen_rows) if unseen_rows else (None, None)

    # The reference the converted model must agree with.
    base_t = torch_predictions(torch_model, t_ids, t_mask)
    acc, wm = score(base_t, trained_rows)
    print(f"\nreference (PyTorch, fixed {MAX_LEN}-token shape)")
    print(f"  trained languages : {100*acc:.1f}% accuracy, {wm} wrong merges, {len(trained_rows)} rows")
    base_z = None
    if unseen_rows:
        base_z = torch_predictions(torch_model, z_ids, z_mask)
        acc_z, wm_z = score(base_z, unseen_rows)
        print(f"  unseen languages  : {100*acc_z:.1f}% accuracy, {wm_z} wrong merges, {len(unseen_rows)} rows")

    # Two routes into the converter, tried in order, because they fail in
    # different places and the working combination depends on library versions:
    #   export  the documented modern route; needs a torch whose exported
    #           dialect this converter understands
    #   trace   the older route; the current library's mask construction lowers
    #           to `new_ones`, taught above
    # Whichever succeeds is reported, so the plan can record the real route
    # rather than an assumed one.
    example = (torch.from_numpy(t_ids[:1]).long(), torch.from_numpy(t_mask[:1]).long())
    wrapper = LogitsOnly(torch_model).eval()
    # The trace route needs the input signature stated; the export route
    # carries its own and rejects one.
    traced_inputs = [ct.TensorType(name="input_ids", shape=(1, MAX_LEN), dtype=np.int32),
                     ct.TensorType(name="attention_mask", shape=(1, MAX_LEN), dtype=np.int32)]
    routes = []
    try:
        # `run_decompositions` lowers the exported program from the TRAINING
        # dialect the converter refuses to the ATEN dialect it accepts.
        routes.append(("export", torch.export.export(wrapper, example).run_decompositions({}), None))
    except Exception as exc:
        print(f"  export route unavailable: {type(exc).__name__}: {str(exc)[:70]}")
    try:
        routes.append(("trace", torch.jit.trace(wrapper, example, strict=False), traced_inputs))
    except Exception as exc:
        print(f"  trace route unavailable: {type(exc).__name__}: {str(exc)[:70]}")

    print(f"\n{'variant':14}{'size':>9}{'trained acc':>13}{'wrong':>7}"
          f"{'unseen acc':>12}{'wrong':>7}{'agree':>8}{'median ms':>11}{'p95 ms':>9}", flush=True)
    print("-" * 90, flush=True)

    base_model = {}

    def measure(name, build):
        try:
            mlmodel, path = build()
            out_name = list(mlmodel.output_description)[0]
            preds = coreml_predictions(mlmodel, t_ids, t_mask, out_name)
            acc, wm = score(preds, trained_rows)
            agree = sum(int(a == b) for a, b in zip(preds, base_t)) / len(base_t)
            if unseen_rows:
                pz = coreml_predictions(mlmodel, z_ids, z_mask, out_name)
                acc_z, wm_z = score(pz, unseen_rows)
                agree = (agree * len(base_t) + sum(int(a == b) for a, b in zip(pz, base_z))) / (
                    len(base_t) + len(base_z))
            else:
                acc_z, wm_z = float("nan"), 0
            med, p95 = latency(mlmodel, t_ids, t_mask, out_name)
            print(f"{name:14}{dir_size_mb(path):>7.0f}MB{100*acc:>12.1f}%{wm:>7}"
                  f"{100*acc_z:>11.1f}%{wm_z:>7}{100*agree:>7.1f}%{med:>10.1f}{p95:>9.1f}",
                  flush=True)
        except Exception as exc:
            print(f"{name:14}  FAILED: {type(exc).__name__}: {str(exc)[:60]}", flush=True)

    def fp16():
        path = os.path.join(OUT, "seam-coreml-fp16.mlpackage")
        if os.path.exists(path):
            shutil.rmtree(path)
        errors = []
        for route, program, route_inputs in routes:
            try:
                kwargs = {"inputs": route_inputs} if route_inputs else {}
                m = ct.convert(program, convert_to="mlprogram",
                               compute_precision=ct.precision.FLOAT16,
                               minimum_deployment_target=ct.target.macOS14,
                               **kwargs)
                print(f"  converted via the {route} route", flush=True)
                m.save(path)
                base_model["m"] = m
                return m, path
            except Exception as exc:
                errors.append(f"{route}: {type(exc).__name__}: {exc}")
        for line in errors:
            print(f"  ROUTE FAILED {line[:400]}", flush=True)
        raise RuntimeError("no conversion route succeeded")

    def int8():
        from coremltools.optimize.coreml import (OpLinearQuantizerConfig,
                                                 OptimizationConfig,
                                                 linear_quantize_weights)
        path = os.path.join(OUT, "seam-coreml-int8.mlpackage")
        if os.path.exists(path):
            shutil.rmtree(path)
        cfg = OptimizationConfig(
            global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"))
        m = linear_quantize_weights(base_model["m"], config=cfg)
        m.save(path)
        return m, path

    def palettized():
        from coremltools.optimize.coreml import (OpPalettizerConfig,
                                                 OptimizationConfig,
                                                 palettize_weights)
        path = os.path.join(OUT, "seam-coreml-4bit.mlpackage")
        if os.path.exists(path):
            shutil.rmtree(path)
        cfg = OptimizationConfig(
            global_config=OpPalettizerConfig(mode="kmeans", nbits=4))
        m = palettize_weights(base_model["m"], config=cfg)
        m.save(path)
        return m, path

    measure("fp16", fp16)
    if "m" in base_model:
        measure("int8", int8)
        measure("4-bit palette", palettized)
    else:
        print("fp16 conversion failed, so nothing to quantise from", flush=True)

    print("\nLatency is single item on this Mac, which is what a user waits.")
    print("Agreement is against the PyTorch reference on the same fixed shape.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
