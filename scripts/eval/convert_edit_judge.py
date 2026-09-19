#!/usr/bin/env python3
"""Convert a trained edit-judge checkpoint to Core ML and verify it (#996 chunk 2c).

Takes a `train_edit_judge.py` run directory, exports the backbone + head at
FLOAT32 compute (mlprogram, macOS 14 target, fixed length 128), then checks
PyTorch/Core ML agreement on NON-frozen pairs under the four compute
policies: logits drift, argmax flips, non-finite or constant output, and,
decisively, that the CALIBRATED DECISIONS (the locked safe threshold) are
identical. Optionally builds an embedding-only 8-bit variant and verifies it
the same way as a separately identified artifact.

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
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).parent))
import edit_judge_data as data  # noqa: E402
import edit_judge_gate as gate  # noqa: E402
import probe_edit_judge_compatibility as probe  # noqa: E402
import train_edit_judge as trainer  # noqa: E402


def package_digest(package: Path) -> str:
    return trainer.tree_digest(package)


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
    p.add_argument("--embedding-8bit", action="store_true", help="also build and verify the embedding-only 8-bit variant")
    args = p.parse_args()

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
    model_dir = Path(manifest["checkpoint"])
    tok_dir = Path(manifest["tokenizer"])
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
    split_manifest_path = None
    for candidate in (Path(experiment["dev_dir"]) / "split-manifest.json" if experiment.get("dev_dir") else run.parent.parent / "dev" / "split-manifest.json",):
        if candidate.exists() and data.sha256_file(candidate) == experiment["split_manifest_sha256"]:
            split_manifest_path = candidate
    if split_manifest_path is None:
        print("INFRA-ERROR: the split manifest the run trained on is not at the recorded dev directory with the recorded digest", file=sys.stderr)
        return 2
    split_manifest = json.loads(split_manifest_path.read_text(encoding="utf-8"))
    partitions = {n: trainer.load_partition(split_manifest_path.parent, n, split_manifest) for n in ("train", "dev", "calibration")}
    if experiment.get("cross_dev"):
        # The cross-author population selected the threshold: it must still be
        # the recorded file and still be disjoint from every frozen exam.
        cross_path = Path(experiment["cross_dev"]["path"])
        if not cross_path.exists() or data.sha256_file(cross_path) != experiment["cross_dev"]["file_sha256"]:
            print("INFRA-ERROR: the cross-author development partition is not at the recorded path with the recorded digest", file=sys.stderr)
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

    def verify(package: Path, variant: str) -> dict:
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
                verdict = probe.placement_verdict(reference, observed, tolerance=1e-2, classes=len(objective.class_order))
                obs_probs = torch.softmax(torch.tensor(observed), dim=-1).tolist()
                verdict["decisions"] = decisions_equal(ref_probs, obs_probs, locked, objective)
                verdict["ok"] = bool(verdict.get("ok")) and verdict["decisions"]["ok"]
                verdict.update({"load_seconds": round(load_s, 2), "warm_latency_ms_p50": round(sorted(latencies)[len(latencies) // 2], 1), "warm_latency_ms_max": round(max(latencies), 1), "requested_compute_units": label})
                placement[label] = verdict
            except Exception as exc:
                placement[label] = {"ok": False, "error": f"{type(exc).__name__}: {str(exc)[:300]}"}
        size = sum(f.stat().st_size for f in package.rglob("*") if f.is_file())
        digest = package_digest(package)
        decision_config = dict(cfg, precision_variant=variant, package_sha256=digest)
        bound_identity = {"checkpoint_sha256": identity["checkpoint_sha256"], "tokenizer_sha256": identity["tokenizer_sha256"], "config_sha256": trainer.config_digest(decision_config)}
        # The exact bytes the config digest was taken over, so a Swift runner
        # can re-hash them without re-implementing Python's float formatting.
        canonical = json.dumps(decision_config, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
        assert hashlib.sha256(canonical.encode("utf-8")).hexdigest() == bound_identity["config_sha256"]
        bound = dict(manifest, execution_identity=bound_identity, decision_config=decision_config, decision_config_canonical=canonical, package=str(package), contract=str(run / "tokenizer-contract.json"), provenance=manifest["provenance"] + f"; exported {variant} package {digest[:12]} from manifest {source_manifest_sha256[:12]}")
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
            "execution_identity": bound_identity,
            "identity_differs_from_pytorch_run": bound_identity["config_sha256"] != identity["config_sha256"],
            "source_training_manifest_sha256": source_manifest_sha256,
            "verification_inputs_sha256": verification_inputs_sha256,
            "converter": converter_identity,
            "manifest_problems": loaded_manifest.problems + data.leakage_problems(loaded_manifest, frozen),
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
    if args.embedding_8bit and fp32["all_placements_ok"]:
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
