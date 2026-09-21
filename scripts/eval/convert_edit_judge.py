#!/usr/bin/env python3
"""Convert a trained edit-judge checkpoint to Core ML and verify it (#996 chunk 2c).

Takes a `train_edit_judge.py` run directory, exports the backbone + head at
FLOAT32 compute (mlprogram, macOS 14 target, fixed length 128), then checks
PyTorch/Core ML agreement on NON-frozen pairs under the four compute
policies: logits drift, argmax flips, non-finite or constant output, and,
decisively, that the CALIBRATED DECISIONS (the locked safe threshold) are
identical. Optionally builds a FLOAT16 compute-precision variant (the
precision the Neural Engine actually runs, and the one a shipped package is
examined in, #996 delivery) and an embedding-only 8-bit variant, each
verified the same way as a separately identified artifact.

Every variant gets its own execution identity: the run's checkpoint and
tokenizer digests plus a config digest that now includes the exported
package digest and the precision variant, so a result from the FP32 package
can never be scored as the compressed one or as the PyTorch checkpoint.

Outputs, under `<run>/export/<variant>/`: the `.mlpackage`, `verification.json`
and `training-manifest.json` (the run's manifest rebound to this artifact).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import platform
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).parent))
import edit_judge_data as data  # noqa: E402
import edit_judge_gate as gate  # noqa: E402
import probe_edit_judge_compatibility as probe  # noqa: E402
import train_edit_judge as trainer  # noqa: E402


def package_digest(package: Path) -> str:
    return trainer.tree_digest(package)


# The precision variants this converter can bind a package under. The value
# is the `coremltools.precision` member name for the variants that are a
# whole-graph compute precision; the 8-bit variant is a weight-only
# quantisation of the FP32 graph and carries no compute precision.
VARIANT_PRECISION = {"coreml-fp32": "FLOAT32", "coreml-fp16": "FLOAT16", "coreml-embedding-int8": None}

# The logit-drift bar each variant is verified under, against the PyTorch
# reference on the same rows. FP32 and the weight-only 8-bit variant must
# reproduce the reference to 1e-2. FP16 cannot: half-precision matmul
# accumulation across the 22 ModernBERT layers drifts 0.05 to 0.24 logits on
# every compute unit (measured 2026-09-21 on mmbert-v15, #996 comment
# 5756369021; a mixed-precision export has no third option), so its bar is
# DECISION PARITY: finite, non-constant, zero argmax flips and zero decision
# flips at the locked threshold, with the drift reported in the receipt and
# the exam v2 run on the package itself as the real evidence. Founder
# decision 2026-09-21 (option 2: set the half-size bar and exam the fp16
# package) rather than shipping the 562 MB fp32 package.
VARIANT_LOGIT_TOLERANCE: dict[str, float | None] = {"coreml-fp32": 1e-2, "coreml-fp16": None, "coreml-embedding-int8": 1e-2}


def bind_decision_config(cfg: dict, run_identity: dict, variant: str, digest: str) -> tuple[dict, dict, str]:
    """The decision configuration and execution identity a package is scored
    under: the run's config with the variant and package digest written in,
    the run's checkpoint and tokenizer digests plus that config's digest, and
    the exact canonical bytes the digest was taken over (so a Swift runner can
    re-hash them without re-implementing Python's float formatting). An
    unknown variant is refused so a typo cannot mint an identity nothing else
    recognises."""
    if variant not in VARIANT_PRECISION:
        raise ValueError(f"unknown precision variant {variant!r}; known: {sorted(VARIANT_PRECISION)}")
    decision_config = dict(cfg, precision_variant=variant, package_sha256=digest)
    canonical = json.dumps(decision_config, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    config_sha256 = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    assert config_sha256 == trainer.config_digest(decision_config)
    bound_identity = {"checkpoint_sha256": run_identity["checkpoint_sha256"], "tokenizer_sha256": run_identity["tokenizer_sha256"], "config_sha256": config_sha256}
    return decision_config, bound_identity, canonical


# The additive attention-mask value the FLOAT16 graph is traced with. The
# backbone masks with `torch.finfo(float32).min` (-3.4e38), which a FLOAT16
# graph carries as -inf; a padded query position whose whole local window is
# padding then has an all -inf row, its softmax is NaN, and the NaN reaches
# every position through the next global layer's value matmul. Measured
# 2026-09-21 on mmbert-v15: 71 of 73 verification rows non-finite on
# cpuOnly, the two unpadded rows finite (GPU and ANE clamp the constant to
# -65504 and survive). -1e4 is far below any attention score, exp(-1e4) is 0
# in every precision, and it stays finite in FLOAT16 whatever score is added.
# Known class: an fp16 mask that overflows to -inf, e.g.
# https://github.com/jingyaogong/minimind/pull/863.
FP16_MASK_FLOOR = -1.0e4


def install_fp16_mask_floor(backbone, floor: float = FP16_MASK_FLOOR) -> bool:
    """Clamp the backbone's additive attention masks at `floor` before the
    FLOAT16 trace. Returns False when the backbone does not build its masks
    through `_update_attention_mask` (ModernBERT does): then no FLOAT16
    package is minted for it, because an unpatched trace is known to produce
    NaN on the CPU placement."""
    original = getattr(backbone, "_update_attention_mask", None)
    if original is None:
        return False

    def floored(attention_mask, output_attentions):
        masks = original(attention_mask, output_attentions)
        return tuple(m.clamp(min=floor) for m in masks)

    backbone._update_attention_mask = floored
    return True


# The key each variant's verification lands under in summary.json.
SUMMARY_KEY = {"coreml-fp32": "fp32", "coreml-fp16": "fp16", "coreml-embedding-int8": "embedding_int8"}


def export_plan(fp16: bool, embedding_8bit: bool) -> list[str]:
    """Which variants a conversion run builds, in order. FP32 is always first
    and is the graph every other variant is derived from."""
    plan = ["coreml-fp32"]
    if fp16:
        plan.append("coreml-fp16")
    if embedding_8bit:
        plan.append("coreml-embedding-int8")
    return plan


def decisions_equal(ref: list[list[float]], obs: list[list[float]], threshold: float, objective: "trainer.Objective") -> dict:
    flips = 0
    for r, o in zip(ref, obs):
        if objective.decide(r, threshold) != objective.decide(o, threshold):
            flips += 1
    return {"decision_flips": flips, "rows": len(ref), "ok": flips == 0 and len(ref) == len(obs) and len(ref) > 0}


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--run", type=Path, required=True, help="a train_edit_judge.py run directory")
    p.add_argument("--rows", type=int, default=64, help="non-frozen verification rows (from the run's dev partition)")
    p.add_argument("--dev-dir", type=Path, help="where the run's split directory is on THIS machine when the run was trained elsewhere; its split-manifest digest must equal the run's")
    p.add_argument("--cross-dev", type=Path, help="where the run's cross-author partition is on THIS machine when the run was trained elsewhere; its digest must equal the run's")
    p.add_argument("--fp16", action="store_true", help="also build and verify the FLOAT16 compute-precision variant (what the Neural Engine runs; the precision a shipped package is examined in)")
    p.add_argument("--embedding-8bit", action="store_true", help="also build and verify the embedding-only 8-bit variant")
    args = p.parse_args()
    plan = export_plan(args.fp16, args.embedding_8bit)

    import numpy as np
    import torch
    import coremltools as ct
    from safetensors.torch import load_file
    from transformers import AutoModel, AutoTokenizer

    toolchain = probe.toolchain_report()
    problems = probe.toolchain_problems(toolchain)
    if problems:
        print("INFRA-ERROR: toolchain is not the pinned one: " + "; ".join(problems), file=sys.stderr)
        return 2
    run = args.run
    experiment = json.loads((run / "experiment.json").read_text(encoding="utf-8"))
    manifest = json.loads((run / "training-manifest.json").read_text(encoding="utf-8"))
    contract = json.loads((run / "tokenizer-contract.json").read_text(encoding="utf-8"))
    try:
        model_dir, tok_dir = trainer.run_checkpoint_dirs(run, manifest)
    except RuntimeError as exc:
        print(f"INFRA-ERROR: {exc}", file=sys.stderr)
        return 2
    cfg = manifest["decision_config"]
    objective = trainer.objective_from_config(cfg)
    identity = manifest["execution_identity"]
    # Every bound component is re-verified from the files actually used, so
    # a changed threshold, contract, class order, rule, tokenizer file or
    # weight cannot ride under the old identity.
    checks = [
        (trainer.tree_digest(model_dir) == identity["checkpoint_sha256"], "checkpoint digest differs from the training manifest"),
        (trainer.tree_digest(tok_dir) == identity["tokenizer_sha256"], "tokenizer digest differs from the training manifest"),
        ({f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(tok_dir.iterdir()) if f.is_file()} == manifest.get("tokenizer_inventory"), "tokenizer file inventory differs from the training manifest"),
        (trainer.config_digest(cfg) == identity["config_sha256"], "decision configuration differs from execution identity"),
        (data.sha256_file(run / "tokenizer-contract.json") == cfg["contract_sha256"], "tokenizer contract differs from decision configuration"),
        (cfg["class_order"] == list(objective.class_order), "class order differs from converter implementation"),
        (cfg["decision_rule"] == objective.decision_rule, "decision rule differs from converter implementation"),
        (manifest["thresholds"][objective.threshold_key] == cfg[objective.threshold_key], "threshold differs from decision configuration"),
        (manifest["thresholds"].get("qualifying") is True, "run has no qualifying threshold"),
        (cfg.get("precision_variant") == "fp32-pytorch" and cfg.get("package_sha256") is None, "the run manifest is already bound to an exported package"),
    ]
    for ok, message in checks:
        if not ok:
            print(f"INFRA-ERROR: {message}", file=sys.stderr)
            return 2
    locked = cfg[objective.threshold_key]
    frozen, _, problems = gate.load_frozen()
    if problems:
        print("INFRA-ERROR: frozen partitions are not intact: " + "; ".join(problems), file=sys.stderr)
        return 2

    # Verification rows: the run's dev partition (never frozen), padded and
    # truncated cases included by construction of the mirror.
    try:
        split_manifest_path = trainer.locate_recorded_file(
            str(Path(experiment["dev_dir"]) / "split-manifest.json") if experiment.get("dev_dir") else str(run.parent.parent / "dev" / "split-manifest.json"),
            experiment["split_manifest_sha256"], (args.dev_dir / "split-manifest.json") if args.dev_dir else None, "split manifest")
    except RuntimeError as exc:
        print(f"INFRA-ERROR: {exc}", file=sys.stderr)
        return 2
    split_manifest = json.loads(split_manifest_path.read_text(encoding="utf-8"))
    partitions = {n: trainer.load_partition(split_manifest_path.parent, n, split_manifest) for n in ("train", "dev", "calibration")}
    if experiment.get("cross_dev"):
        # The cross-author population selected the threshold: it must still be
        # the recorded file and still be disjoint from every frozen exam.
        try:
            cross_path = trainer.locate_recorded_file(experiment["cross_dev"]["path"], experiment["cross_dev"]["file_sha256"], args.cross_dev, "cross-author development partition")
        except RuntimeError as exc:
            print(f"INFRA-ERROR: {exc}", file=sys.stderr)
            return 2
        partitions["cross_dev"] = trainer.load_cross_dev(cross_path)
    trainer.refuse_frozen_overlap_all(partitions)
    dev_rows = partitions["dev"]
    rows = dev_rows[: args.rows]
    # Truncation boundaries: the probe's long non-frozen pair fixtures (a long
    # context and a long edit) so the verification batch is not all padding.
    for i, (edit, context) in enumerate(probe.PAIR_FIXTURES):
        original, replacement = edit.split("→")[0].strip(), edit.split("→")[-1].strip()
        rows.append({"id": f"PROBE-PAIR-{i}", "language": "en", "original": original, "replacement": replacement, "pasted": context})
    if len(rows) < 8:
        print("INFRA-ERROR: fewer than 8 verification rows", file=sys.stderr)
        return 2

    tok = AutoTokenizer.from_pretrained(tok_dir)
    encode = lambda text: tok(text, add_special_tokens=False)["input_ids"]  # noqa: E731
    enc = trainer.encode_rows(rows, contract, encode)
    ids = torch.tensor([e["input_ids"] for e in enc], dtype=torch.int32)
    mask = torch.tensor([e["attention_mask"] for e in enc], dtype=torch.int32)
    types = torch.tensor([e["token_type_ids"] for e in enc], dtype=torch.int32)
    needs_types = probe.CANDIDATES[experiment["candidate"]]["token_types"] == "bert_segments"
    truncated = sum(1 for e in enc if e["attention_mask"][-1] == 1)
    padded = len(enc) - truncated

    backbone = AutoModel.from_pretrained(model_dir).eval()
    head_state = load_file(str(model_dir / "head.safetensors"))
    head = torch.nn.Linear(backbone.config.hidden_size, len(objective.class_order))
    head.load_state_dict(head_state)

    class Judge(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.backbone = backbone
            self.head = head

        def forward(self, input_ids, attention_mask, token_type_ids=None):
            if needs_types and token_type_ids is not None:
                out = self.backbone(input_ids=input_ids, attention_mask=attention_mask, token_type_ids=token_type_ids)
            else:
                out = self.backbone(input_ids=input_ids, attention_mask=attention_mask)
            return self.head(out.last_hidden_state[:, 0, :])

    model = Judge().eval()
    with torch.no_grad():
        ref_logits = (model(ids, mask, types) if needs_types else model(ids, mask)).float()
    reference = ref_logits.tolist()
    ref_probs = torch.softmax(ref_logits, dim=-1).tolist()

    example = (ids[:1], mask[:1], types[:1]) if needs_types else (ids[:1], mask[:1])
    inputs = [ct.TensorType(name="input_ids", shape=(1, contract["maxLength"]), dtype=np.int32), ct.TensorType(name="attention_mask", shape=(1, contract["maxLength"]), dtype=np.int32)]
    if needs_types:
        inputs.append(ct.TensorType(name="token_type_ids", shape=(1, contract["maxLength"]), dtype=np.int32))
    # One directory per conversion run, never overwritten.
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    export_root = run / "exports" / f"{stamp}-{uuid4().hex[:8]}"
    export_root.mkdir(parents=True, exist_ok=False)
    verification_inputs_sha256 = hashlib.sha256(json.dumps([[r["original"], r["replacement"], r["pasted"]] for r in rows], ensure_ascii=False).encode("utf-8")).hexdigest()
    source_manifest_sha256 = data.sha256_file(run / "training-manifest.json")
    converter_identity = {**toolchain, "converter": data.sha256_file(Path(__file__))}

    def verify(package: Path, variant: str, extra: Optional[dict] = None) -> dict:
        units = {"cpuOnly": ct.ComputeUnit.CPU_ONLY, "cpuAndGPU": ct.ComputeUnit.CPU_AND_GPU, "cpuAndNeuralEngine": ct.ComputeUnit.CPU_AND_NE, "all": ct.ComputeUnit.ALL}
        placement = {}
        for label, unit in units.items():
            try:
                t0 = time.time()
                loaded = ct.models.MLModel(str(package), compute_units=unit)
                load_s = time.time() - t0
                observed = []
                latencies = []
                for i in range(len(rows)):
                    feed = {"input_ids": ids[i : i + 1].numpy(), "attention_mask": mask[i : i + 1].numpy()}
                    if needs_types:
                        feed["token_type_ids"] = types[i : i + 1].numpy()
                    loaded.predict(feed)
                    t1 = time.time()
                    pred = loaded.predict(feed)
                    latencies.append((time.time() - t1) * 1000)
                    observed.append([float(x) for x in np.asarray(pred["logits"]).reshape(-1)])
                verdict = probe.placement_verdict(reference, observed, tolerance=VARIANT_LOGIT_TOLERANCE[variant], classes=len(objective.class_order))
                obs_probs = torch.softmax(torch.tensor(observed), dim=-1).tolist()
                verdict["decisions"] = decisions_equal(ref_probs, obs_probs, locked, objective)
                verdict["ok"] = bool(verdict.get("ok")) and verdict["decisions"]["ok"]
                verdict.update({"load_seconds": round(load_s, 2), "warm_latency_ms_p50": round(sorted(latencies)[len(latencies) // 2], 1), "warm_latency_ms_max": round(max(latencies), 1), "requested_compute_units": label})
                placement[label] = verdict
            except Exception as exc:
                placement[label] = {"ok": False, "error": f"{type(exc).__name__}: {str(exc)[:300]}"}
        size = sum(f.stat().st_size for f in package.rglob("*") if f.is_file())
        digest = package_digest(package)
        decision_config, bound_identity, canonical = bind_decision_config(cfg, identity, variant, digest)
        # The exported manifest is what the Swift runner loads on THIS machine: rebind the
        # tokenizer and checkpoint to the resolved local run paths (a rig-trained run records
        # the rig's paths, and the runner then digests an empty tree and refuses).
        bound = dict(manifest, tokenizer=str(tok_dir), checkpoint=str(model_dir), execution_identity=bound_identity, decision_config=decision_config, decision_config_canonical=canonical, package=str(package), contract=str(run / "tokenizer-contract.json"), provenance=manifest["provenance"] + f"; exported {variant} package {digest[:12]} from manifest {source_manifest_sha256[:12]}")
        out_dir = package.parent
        (out_dir / "training-manifest.json").write_text(json.dumps(bound, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        # The planned proposal path (stage-1 shape rule, then this judge) is a
        # distinct configuration: same artifact digests, identity extended by
        # the shape policy, `path` declared so the gate passes it to the runner.
        shaped_identity = dict(bound_identity, shape_policy="EditRunShape-v1", path="shape+judge")
        shaped = dict(bound, execution_identity=shaped_identity, path="shape+judge", provenance=bound["provenance"] + "; measured behind the stage-1 shape rule EditRunShape-v1")
        (out_dir / "training-manifest-shaped.json").write_text(json.dumps(shaped, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        loaded_manifest = data.load_training_manifest(out_dir / "training-manifest.json")
        verification = {
            "variant": variant,
            "package": str(package),
            "package_sha256": digest,
            "size_bytes": size,
            "size_mb": round(size / 1e6, 1),
            "verification_rows": len(rows),
            "padded_rows": padded,
            "truncated_rows": truncated,
            objective.threshold_key: locked,
            "objective": objective.name,
            "placement": placement,
            "all_placements_ok": all(v.get("ok") for v in placement.values()),
            "logit_drift_bar": "decision-parity, drift reported" if VARIANT_LOGIT_TOLERANCE[variant] is None else f"max abs drift <= {VARIANT_LOGIT_TOLERANCE[variant]}",
            "execution_identity": bound_identity,
            "identity_differs_from_pytorch_run": bound_identity["config_sha256"] != identity["config_sha256"],
            "source_training_manifest_sha256": source_manifest_sha256,
            "verification_inputs_sha256": verification_inputs_sha256,
            "converter": converter_identity,
            "manifest_problems": loaded_manifest.problems + data.leakage_problems(loaded_manifest, frozen),
            **(extra or {}),
        }
        (out_dir / "verification.json").write_text(json.dumps(verification, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        return verification

    # FP32 first.
    fp32_dir = export_root / "fp32"
    fp32_dir.mkdir(exist_ok=False)
    package = fp32_dir / f"{experiment['candidate']}-fp32.mlpackage"
    t0 = time.time()
    with torch.no_grad():
        traced = torch.jit.trace(model, example, strict=False)
    mlmodel = ct.convert(traced, inputs=inputs, outputs=[ct.TensorType(name="logits")], convert_to="mlprogram", compute_precision=ct.precision.FLOAT32, minimum_deployment_target=ct.target.macOS14)
    mlmodel.save(str(package))
    fp32 = verify(package, "coreml-fp32")
    fp32["convert_seconds"] = round(time.time() - t0, 1)
    print(json.dumps({k: fp32[k] for k in ("variant", "size_mb", "all_placements_ok", "verification_rows", "padded_rows", "truncated_rows", "convert_seconds")}, indent=2))
    for k, v in fp32["placement"].items():
        print(f"  {k}: ok={v.get('ok')} drift={v.get('max_abs_drift')} flips={v.get('argmax_flips')} decision_flips={v.get('decisions', {}).get('decision_flips')} p50={v.get('warm_latency_ms_p50')}ms load={v.get('load_seconds')}s {v.get('error', '')}")

    results = {"fp32": fp32}
    # A requested variant that cannot be built is recorded in summary.json,
    # never silently absent: the FP32 baseline it derives from failed.
    if not fp32["all_placements_ok"]:
        for variant in plan[1:]:
            results[SUMMARY_KEY[variant]] = {"variant": variant, "status": "skipped", "all_placements_ok": False, "error": "FP32 verification failed"}
    if "coreml-fp16" in plan and fp32["all_placements_ok"]:
        # The same weights re-traced with the FLOAT16-safe mask floor and
        # converted at FLOAT16 compute: this is what the Neural Engine runs
        # (an FP32 package is cast at load), so a package meant to ship is
        # exported AND examined in this precision. Verified against the same
        # PyTorch reference (taken above, before the floor), same tolerance,
        # same locked decisions, as its own artifact (#996 delivery).
        if not install_fp16_mask_floor(backbone):
            message = f"{experiment['candidate']} builds its attention mask outside _update_attention_mask; no FLOAT16 mask floor, no FLOAT16 package"
            results["fp16"] = {"variant": "coreml-fp16", "status": "infra-error", "all_placements_ok": False, "error": message}
            for variant in plan[plan.index("coreml-fp16") + 1:]:
                results[SUMMARY_KEY[variant]] = {"variant": variant, "status": "skipped", "all_placements_ok": False, "error": "conversion aborted after coreml-fp16 infrastructure error"}
            (export_root / "summary.json").write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
            print(f"INFRA-ERROR: {message}", file=sys.stderr)
            print(f"exports: {export_root}")
            return 2
        fp16_dir = export_root / "fp16"
        fp16_dir.mkdir(exist_ok=False)
        fp16_package = fp16_dir / f"{experiment['candidate']}-fp16.mlpackage"
        t1 = time.time()
        with torch.no_grad():
            traced_half = torch.jit.trace(model, example, strict=False)
        half = ct.convert(traced_half, inputs=inputs, outputs=[ct.TensorType(name="logits")], convert_to="mlprogram", compute_precision=getattr(ct.precision, VARIANT_PRECISION["coreml-fp16"]), minimum_deployment_target=ct.target.macOS14)
        half.save(str(fp16_package))
        fp16 = verify(fp16_package, "coreml-fp16", extra={"attention_mask_floor": FP16_MASK_FLOOR})
        fp16["convert_seconds"] = round(time.time() - t1, 1)
        results["fp16"] = fp16
        print(json.dumps({k: fp16[k] for k in ("variant", "size_mb", "all_placements_ok", "verification_rows", "padded_rows", "truncated_rows", "convert_seconds")}, indent=2))
        for k, v in fp16["placement"].items():
            print(f"  {k}: ok={v.get('ok')} drift={v.get('max_abs_drift')} flips={v.get('argmax_flips')} decision_flips={v.get('decisions', {}).get('decision_flips')} p50={v.get('warm_latency_ms_p50')}ms load={v.get('load_seconds')}s {v.get('error', '')}")
    if "coreml-embedding-int8" in plan and fp32["all_placements_ok"]:
        import coremltools.optimize.coreml as cto

        q_dir = export_root / "embedding-int8"
        q_dir.mkdir(exist_ok=False)
        q_package = q_dir / f"{experiment['candidate']}-embedding-int8.mlpackage"
        # Weight-only 8-bit for the largest constants (the embedding tables),
        # everything else untouched, computation stays FLOAT32.
        op_config = cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel", weight_threshold=50_000_000)
        config = cto.OptimizationConfig(global_config=op_config)
        quantized = cto.linear_quantize_weights(mlmodel, config=config)
        quantized.save(str(q_package))
        int8 = verify(q_package, "coreml-embedding-int8")
        results["embedding_int8"] = int8
        print(json.dumps({k: int8[k] for k in ("variant", "size_mb", "all_placements_ok")}, indent=2))
        for k, v in int8["placement"].items():
            print(f"  {k}: ok={v.get('ok')} drift={v.get('max_abs_drift')} flips={v.get('argmax_flips')} decision_flips={v.get('decisions', {}).get('decision_flips')} p50={v.get('warm_latency_ms_p50')}ms {v.get('error', '')}")
    (export_root / "summary.json").write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"exports: {export_root}")
    return 0 if all(v.get("all_placements_ok") and not v.get("manifest_problems") for v in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
