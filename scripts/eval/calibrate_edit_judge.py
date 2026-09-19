#!/usr/bin/env python3
"""Calibrate the COMPLETE two-stage edit judge: classifier + alias veto (#996).

Takes a trained run (its weights are not touched), the versioned veto
resource and a FRESH calibration set whose families entered neither
training nor threshold selection. The policy is frozen here, before any
calibration row is scored:

  1. classifier probabilities (three classes) per row;
  2. the alias veto (`edit_judge_veto.AliasVeto.apply`): a vetoed or
     uncovered original loses its safe mass;
  3. the trainer's decision rule and threshold selection
     (`train_edit_judge.select_safe_threshold`) on the run's DEV partition,
     with the veto applied;
  4. the locked threshold reported on the fresh calibration set, with the
     classifier-only numbers beside the combined ones.

Writes `<run>/calibrations/<id>/` with `metrics.json` and a rebound
`training-manifest.json` whose execution identity includes the veto
resource (version, manifest digest, policy) and the new threshold, and
whose partitions add the fresh calibration hashes and families. The
converter takes that manifest with `--manifest`.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).parent))
import edit_judge_data as data  # noqa: E402
import edit_judge_gate as gate  # noqa: E402
import probe_edit_judge_compatibility as probe  # noqa: E402
import train_edit_judge as trainer  # noqa: E402
from edit_judge_veto import AliasVeto, casing_only  # noqa: E402


def prior_exposure(run: Path) -> tuple[set[str], set[str]]:
    """Content hashes and families of every calibration set already scored
    under ANY run beside this one (`<runs root>/*/calibrations/*/
    training-manifest.json`), so an inspected set can never qualify again:
    not under this run, not under a retrain in a new run directory (Codex
    3c r3), whatever `--policy-dev-dir` was passed and however its rows were
    renamed or relabelled."""
    hashes: set[str] = set()
    families: set[str] = set()
    for m in sorted(run.parent.glob("*/calibrations/*/training-manifest.json")):
        doc = json.loads(m.read_text(encoding="utf-8"))
        for part in doc.get("partitions", {}).values():
            hashes.update(part.get("hashes", []))
            families.update(part.get("families", []))
    return hashes, families


def exposed_rows(rows: list[dict], hashes: set[str], families: set[str]) -> list[str]:
    return [r["id"] for r in rows if data.content_hash(r) in hashes or data.family_key(r) in families]


def granted_unsafe_by_family(decisions: list[dict]) -> list[tuple[str, int]]:
    from collections import Counter

    return sorted(Counter(d["family"] for d in decisions if d["safe_alias"] and not d["label_safe"]).items(), key=lambda item: (-item[1], item[0]))


def qualifies(dev_threshold_found: bool, fresh_alias_precision_lb95: float | None, lb_min: float = trainer.ALIAS_PRECISION_LB_MIN) -> bool:
    """The judge qualifies only when a dev threshold exists AND the fresh
    set's alias-precision lower bound meets the bar at that threshold. A
    dev-only threshold, a missing fresh bound (zero predicted-safe rows) or
    a fresh bound below the bar is not qualification."""
    return bool(dev_threshold_found and fresh_alias_precision_lb95 is not None and fresh_alias_precision_lb95 >= lb_min)


def classifier_probs(run: Path, manifest: dict, contract: dict, rows: list[dict]) -> list[list[float]]:
    import torch
    from safetensors.torch import load_file
    from transformers import AutoModel, AutoTokenizer

    tok = AutoTokenizer.from_pretrained(manifest["tokenizer"])
    backbone = AutoModel.from_pretrained(manifest["checkpoint"]).eval()
    head = torch.nn.Linear(backbone.config.hidden_size, len(trainer.CLASS_ORDER))
    head.load_state_dict(load_file(str(Path(manifest["checkpoint"]) / "head.safetensors")))
    encode = lambda t: tok(t, add_special_tokens=False)["input_ids"]  # noqa: E731
    enc = trainer.encode_rows(rows, contract, encode)
    needs_types = probe.CANDIDATES[manifest["judge"]]["token_types"] == "bert_segments"
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    backbone.to(device)
    head.to(device)
    probs: list[list[float]] = []
    with torch.no_grad():
        for i in range(0, len(enc), 64):
            ids = torch.tensor([e["input_ids"] for e in enc[i : i + 64]]).to(device)
            mask = torch.tensor([e["attention_mask"] for e in enc[i : i + 64]]).to(device)
            kwargs = {"token_type_ids": torch.tensor([e["token_type_ids"] for e in enc[i : i + 64]]).to(device)} if needs_types else {}
            logits = head(backbone(input_ids=ids, attention_mask=mask, **kwargs).last_hidden_state[:, 0, :]).float()
            if not torch.isfinite(logits).all():
                raise RuntimeError("non-finite logits")
            probs.extend(torch.softmax(logits, dim=-1).cpu().tolist())
    return probs


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--run", type=Path, required=True)
    p.add_argument("--veto-resource", type=Path, required=True, help="the <version> directory of the veto resource")
    p.add_argument("--calibration-dir", type=Path, required=True, help="a --calibration-fresh output directory")
    p.add_argument("--policy-dev-dir", type=Path, action="append", default=[], help="every calibration set inspected while developing the policy; their rows join the development population and must not overlap the fresh set")
    p.add_argument("--dev-dir", type=Path, help="the split directory this run trained on (default <artifacts>/dev); its manifest digest must equal the run's")
    p.add_argument("--analysis-only", action="store_true", help="re-score an already-inspected set for accounting: never produces a qualifying manifest")
    args = p.parse_args()

    run = args.run
    manifest = json.loads((run / "training-manifest.json").read_text(encoding="utf-8"))
    experiment = json.loads((run / "experiment.json").read_text(encoding="utf-8"))
    contract = json.loads((run / "tokenizer-contract.json").read_text(encoding="utf-8"))
    cfg = manifest["decision_config"]
    identity = manifest["execution_identity"]
    checks = [
        (trainer.tree_digest(Path(manifest["checkpoint"])) == identity["checkpoint_sha256"], "checkpoint digest differs from the training manifest"),
        (trainer.tree_digest(Path(manifest["tokenizer"])) == identity["tokenizer_sha256"], "tokenizer digest differs from the training manifest"),
        (trainer.config_digest(cfg) == identity["config_sha256"], "decision configuration differs from execution identity"),
        (data.sha256_file(run / "tokenizer-contract.json") == cfg["contract_sha256"], "tokenizer contract differs from decision configuration"),
        (cfg["class_order"] == list(trainer.CLASS_ORDER) and cfg["decision_rule"] == trainer.DECISION_RULE, "class order or decision rule differs from the implementation"),
        (cfg.get("veto") is None, "this manifest is already a calibrated two-stage manifest"),
    ]
    for ok, message in checks:
        if not ok:
            print(f"INFRA-ERROR: {message}", file=sys.stderr)
            return 2
    frozen, _, problems = gate.load_frozen()
    if problems:
        print("INFRA-ERROR: frozen partitions are not intact: " + "; ".join(problems), file=sys.stderr)
        return 2
    veto = AliasVeto(args.veto_resource)

    # The run's own split (dev is the selection set) and the fresh calibration set.
    split_path = (args.dev_dir or run.parent.parent / "dev") / "split-manifest.json"
    if data.sha256_file(split_path) != experiment["split_manifest_sha256"]:
        print(f"INFRA-ERROR: {split_path} is not the split this run trained on", file=sys.stderr)
        return 2
    split = json.loads(split_path.read_text(encoding="utf-8"))
    partitions = {n: trainer.load_partition(split_path.parent, n, split) for n in ("train", "dev", "calibration")}
    cal_manifest = json.loads((args.calibration_dir / "split-manifest.json").read_text(encoding="utf-8"))
    if cal_manifest.get("disjoint_from_split_manifest_sha256") != experiment["split_manifest_sha256"]:
        print("INFRA-ERROR: the calibration set was not built disjoint from this run's split", file=sys.stderr)
        return 2
    fresh = trainer.load_partition(args.calibration_dir, "calibration", cal_manifest)
    # Everything the policy was developed on is DEVELOPMENT exposure: the
    # run's dev and original calibration partitions plus every
    # policy-development set. The fresh set must overlap none of it.
    policy_dev_rows: list[dict] = []
    policy_dev_manifests: list[dict] = []
    for d in args.policy_dev_dir:
        m = json.loads((d / "split-manifest.json").read_text(encoding="utf-8"))
        policy_dev_rows.extend(trainer.load_partition(d, "calibration", m))
        policy_dev_manifests.append({"dir": str(d), "sha256": data.sha256_file(d / "split-manifest.json"), "rows": m["partitions"]["calibration"]["rows"]})
    # One development population, deduplicated by content hash: two exposed
    # sets can share rows (the v6 set and its relabelled rebuild), and a
    # manifest partition must not carry a hash twice.
    seen_dev: set[str] = set()
    development_rows = [r for r in partitions["dev"] + partitions["calibration"] + policy_dev_rows if not (data.content_hash(r) in seen_dev or seen_dev.add(data.content_hash(r)))]
    try:
        trainer.refuse_frozen_overlap({"train": partitions["train"], "development": development_rows, "fresh_calibration": fresh}, frozen)
    except RuntimeError as exc:
        print(f"INFRA-ERROR: {exc}", file=sys.stderr)
        return 2
    # A set already scored under any run is exposed, by content and by
    # family; in qualification mode it is refused outright.
    seen_hashes, seen_families = prior_exposure(run)
    already = exposed_rows(fresh, seen_hashes, seen_families)
    if already and not args.analysis_only:
        print(f"INFRA-ERROR: {len(already)} calibration row(s) were already scored under an earlier calibration (first: {already[:3]}); a previously inspected set cannot qualify, use --analysis-only", file=sys.stderr)
        return 2
    uncovered = sorted({r["language"] for r in fresh + partitions["dev"] if not veto.covers(r["language"])})

    dev_rows = partitions["dev"]
    dev_probs = classifier_probs(run, manifest, contract, dev_rows)
    fresh_probs = classifier_probs(run, manifest, contract, fresh)
    dev_vetoed = [veto.apply(p, r["original"], r["language"], r["replacement"]) for r, p in zip(dev_rows, dev_probs)]
    fresh_vetoed = [veto.apply(p, r["original"], r["language"], r["replacement"]) for r, p in zip(fresh, fresh_probs)]
    selection = trainer.select_safe_threshold(dev_rows, dev_vetoed)
    locked = selection["selected"]["safe_threshold"] if selection["qualifying"] else None
    fresh_score = trainer.score_decisions(fresh, fresh_vetoed, locked) if locked is not None else None
    fresh_lb = fresh_score["alias_precision"]["wilson_lb_95"] if fresh_score is not None else None
    # Qualification is the FRESH set meeting the bar at the dev-selected
    # threshold; a dev-only threshold is not qualification (Codex 3a finding 1).
    bar_met = qualifies(selection["qualifying"], fresh_lb)
    qualified = bar_met and not args.analysis_only
    veto_fired = {"dev": sum(1 for r in dev_rows if veto.veto(r["original"], r["language"]).vetoed), "fresh": sum(1 for r in fresh if veto.veto(r["original"], r["language"]).vetoed)}
    veto_cost = {"dev": sum(1 for r in dev_rows if r["safe_alias"] and veto.veto(r["original"], r["language"]).vetoed), "fresh": sum(1 for r in fresh if r["safe_alias"] and veto.veto(r["original"], r["language"]).vetoed)}

    cal_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid4().hex[:8]
    out = run / "calibrations" / cal_id
    out.mkdir(parents=True, exist_ok=False)
    # Row-level decisions on the fresh set, so error accounting is derived
    # from what the judge actually granted, never from labels alone.
    decisions = []
    for r, p_raw, p_v in zip(fresh, fresh_probs, fresh_vetoed):
        vc, sa = trainer.decide(p_v, locked) if locked is not None else (None, None)
        vd = veto.veto(r["original"], r["language"])
        decisions.append({"id": r["id"], "family": data.family_key(r), "language": r["language"], "stratum": r["stratum"], "label_correction": r["correction"], "label_safe": r["safe_alias"], "casing_only": casing_only(r["original"], r["replacement"]), "vetoed": vd.vetoed, "covered": vd.covered, "classifier_probs": [round(x, 4) for x in p_raw], "vocabulary_correction": vc, "safe_alias": sa})
    data.write_jsonl(out / "fresh-decisions.jsonl", decisions)
    granted_unsafe = [d for d in decisions if d["safe_alias"] and not d["label_safe"]]
    metrics = {
        "calibration_id": cal_id,
        "analysis_only": args.analysis_only,
        "previously_exposed_rows": len(already),
        "dev_threshold_found": selection["qualifying"],
        "numerical_bar_met": bar_met,
        "fresh_calibration_passed": qualified,
        "fresh_alias_precision_lb95": fresh_lb,
        "policy_development_sets": policy_dev_manifests,
        "granted_unsafe_by_family": granted_unsafe_by_family(decisions),
        "granted_unsafe_total": len(granted_unsafe),
        # Family-level view: rows of one family share templates, so row counts
        # overstate independent evidence (Codex 3c); the bar stays row-level.
        "families_granted": len({d["family"] for d in decisions if d["safe_alias"]}),
        "families_granted_unsafe": len({d["family"] for d in granted_unsafe}),
        "families_labelled_safe": len({d["family"] for d in decisions if d["label_safe"]}),
        "families_granted_safe": len({d["family"] for d in decisions if d["safe_alias"] and d["label_safe"]}),
        "policy": "classifier + alias veto (edit_judge_veto.AliasVeto.apply), then the trainer's decision rule; threshold selected on the run's dev partition with the veto applied; reported on the fresh calibration set",
        "veto": veto.identity(),
        "uncovered_languages": uncovered,
        "veto_fired": veto_fired,
        "veto_cost_rows_labelled_safe": veto_cost,
        "dev_selection": {k: v for k, v in selection.items() if k != "sweep"},
        "dev_sweep": selection["sweep"],
        "dev_at_locked": {"combined": trainer.score_decisions(dev_rows, dev_vetoed, locked), "classifier_only": trainer.score_decisions(dev_rows, dev_probs, locked)} if locked is not None else None,
        "fresh_calibration_at_locked": {"combined": trainer.score_decisions(fresh, fresh_vetoed, locked), "classifier_only": trainer.score_decisions(fresh, fresh_probs, locked)} if locked is not None else None,
        "fresh_calibration_manifest_sha256": data.sha256_file(args.calibration_dir / "split-manifest.json"),
        "not_acceptance_evidence": "development and fresh calibration data only; the frozen report rows were never scored",
    }
    decision_config = dict(cfg, safe_threshold=locked, veto=veto.identity())
    dev_population = data.partition_manifest(development_rows)
    bound_identity = {"checkpoint_sha256": identity["checkpoint_sha256"], "tokenizer_sha256": identity["tokenizer_sha256"], "config_sha256": trainer.config_digest(decision_config)}
    bound = dict(
        manifest,
        thresholds={"safe_threshold": locked, "qualifying": qualified, "dev_threshold_found": selection["qualifying"]},
        decision_config=decision_config,
        execution_identity=bound_identity,
        provenance=manifest["provenance"] + f"; calibrated with {veto.version} ({veto.manifest_sha256[:12]}) on fresh calibration {metrics['fresh_calibration_manifest_sha256'][:12]}, id {cal_id}",
        partitions=dict(manifest["partitions"], fresh_calibration={"hashes": cal_manifest["partitions"]["calibration"]["hashes"], "families": cal_manifest["partitions"]["calibration"]["families"]}),
    )
    # The gate's manifest schema names three partitions: train = the rows
    # fitted; dev = the COMPLETE development population (dev, the original
    # calibration partition and every policy-development set); calibration =
    # the fresh set. Earlier exposure is never discarded on rebinding.
    bound["partitions"] = {"train": bound["partitions"]["train"], "dev": dev_population, "calibration": bound["partitions"]["fresh_calibration"]}
    (out / "training-manifest.json").write_text(json.dumps(bound, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    loaded = data.load_training_manifest(out / "training-manifest.json")
    metrics["training_manifest_problems"] = loaded.problems + data.leakage_problems(loaded, frozen)
    metrics["execution_identity"] = bound_identity
    (out / "metrics.json").write_text(json.dumps(metrics, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    def brief(s: dict) -> dict:
        return {k: (s[k]["num"], s[k]["den"], round(s[k]["value"], 4) if s[k]["value"] is not None else None) for k in ("correction_recall", "false_add_rate", "alias_precision", "alias_recall")} | {"alias_precision_lb95": round(s["alias_precision"]["wilson_lb_95"], 4) if s["alias_precision"]["wilson_lb_95"] is not None else None}

    summary = {
        "calibration": str(out),
        "analysis_only": args.analysis_only,
        "previously_exposed_rows": len(already),
        "dev_threshold_found": selection["qualifying"],
        "numerical_bar_met": bar_met,
        "fresh_calibration_passed": qualified,
        "fresh_alias_precision_lb95": round(fresh_lb, 4) if fresh_lb is not None else None,
        "granted_unsafe_total": len(granted_unsafe),
        "granted_unsafe_by_family": metrics["granted_unsafe_by_family"][:6],
        "families": {k: metrics[k] for k in ("families_granted", "families_granted_unsafe", "families_labelled_safe", "families_granted_safe")},
        "locked_threshold": locked,
        "uncovered_languages": uncovered,
        "veto_fired": veto_fired,
        "veto_cost_rows_labelled_safe": veto_cost,
        "dev_combined": brief(metrics["dev_at_locked"]["combined"]) if locked is not None else None,
        "fresh_combined": brief(metrics["fresh_calibration_at_locked"]["combined"]) if locked is not None else None,
        "fresh_classifier_only": brief(metrics["fresh_calibration_at_locked"]["classifier_only"]) if locked is not None else None,
        "manifest_problems": metrics["training_manifest_problems"],
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    if args.analysis_only:
        return 0 if not metrics["training_manifest_problems"] else 1
    return 0 if qualified and not metrics["training_manifest_problems"] else 1


if __name__ == "__main__":
    sys.exit(main())
