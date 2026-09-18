#!/usr/bin/env python3
"""Train and calibrate a three-class cross-encoder edit judge offline (#996 chunk 2c).

One predeclared experiment per run: backbone revision, tokenizer digests,
seed, class order, encoding contract, optimizer, stopping rule and the
calibration objective are fixed BEFORE the first optimizer step and written
into the run's `experiment.json`. The frozen report rows are never read for
scores: every partition is checked against the frozen manifest by content
hash and alias family before training, and the trainer refuses on overlap.

Classes (index order is part of the execution identity):
  0 notCorrection        -> (vocabulary_correction false, safe_alias false)
  1 correctionButUnsafe  -> (true, false)
  2 correctionAndSafe    -> (true, true)

Decision rule (predeclared, `DECISION_RULE`):
  vocabulary_correction := p[1] + p[2] > p[0]
  safe_alias            := vocabulary_correction and p[2] >= safe_threshold
`safe_threshold` is chosen on the DEV partition as the smallest grid value
whose one-sided 95% Wilson lower bound of alias precision is >= 0.95 (the
plan's bar), breaking ties by alias recall; the locked value is then
reported on the untouched CALIBRATION partition. No qualifying threshold is
an explicit outcome, never a pass.

Outputs, under `<artifacts>/runs/<run id>/`:
  experiment.json      the locked experiment (before training)
  checkpoint/          backbone + head weights (safetensors) + tokenizer files
  training-manifest.json   `edit_judge_data` training manifest with execution identity
  metrics.json         per-epoch dev metrics, calibration sweep, locked results

Toolchain: the pinned probe venv (`edit-judge-requirements.txt`).
Run from the worktree:
  <main>/artifacts/issue-996-edit-judge/.venv/bin/python scripts/eval/train_edit_judge.py \\
      --artifacts <main>/artifacts/issue-996-edit-judge --candidate xenc-xlmr-base
Add `--smoke` for the pipeline smoke (a few steps on a few rows; never a result).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import random
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).parent))
import edit_judge_data as data  # noqa: E402
import edit_judge_gate as gate  # noqa: E402
import probe_edit_judge_compatibility as probe  # noqa: E402

CLASS_ORDER = ("notCorrection", "correctionButUnsafe", "correctionAndSafe")
DECISION_RULE = "vocabulary_correction := p[1]+p[2] > p[0]; safe_alias := vocabulary_correction and p[2] >= safe_threshold"
SAFE_THRESHOLD_GRID = [round(0.50 + 0.01 * i, 2) for i in range(50)]  # 0.50 .. 0.99
ALIAS_PRECISION_LB_MIN = 0.95
WILSON_Z_ONE_SIDED_95 = 1.6448536269514722


# --- Pure helpers (tested) ---


def wilson_lower_bound(successes: int, trials: int, z: float = WILSON_Z_ONE_SIDED_95) -> float | None:
    """One-sided 95% Wilson lower bound of a proportion; None when trials == 0."""
    if trials <= 0:
        return None
    p = successes / trials
    denom = 1 + z * z / trials
    centre = p + z * z / (2 * trials)
    margin = z * math.sqrt(p * (1 - p) / trials + z * z / (4 * trials * trials))
    return (centre - margin) / denom


def decide(probs: list[float], safe_threshold: float) -> tuple[bool, bool]:
    """The predeclared decision rule on one probability triple."""
    if len(probs) != 3 or not all(math.isfinite(x) for x in probs):
        raise ValueError("expected three finite probabilities")
    vc = probs[1] + probs[2] > probs[0]
    sa = vc and probs[2] >= safe_threshold
    return vc, sa


def score_decisions(rows: list[dict], probs: list[list[float]], safe_threshold: float) -> dict:
    """Recall / false-add / alias precision with denominators and the Wilson
    lower bound for alias precision, on labelled rows."""
    if len(rows) != len(probs):
        raise ValueError("rows and probabilities differ in length")
    positives = true_positives = negatives = false_positives = 0
    predicted_safe = correct_safe = 0
    per_language: dict[str, dict] = {}
    for row, p in zip(rows, probs):
        vc, sa = decide(p, safe_threshold)
        lang = per_language.setdefault(row["language"], {"rows": 0, "positives": 0, "true_positives": 0, "negatives": 0, "false_positives": 0, "predicted_safe": 0, "correct_safe": 0})
        lang["rows"] += 1
        if row["correction"]:
            positives += 1
            lang["positives"] += 1
            if vc:
                true_positives += 1
                lang["true_positives"] += 1
        else:
            negatives += 1
            lang["negatives"] += 1
            if vc:
                false_positives += 1
                lang["false_positives"] += 1
        if vc and sa:
            predicted_safe += 1
            lang["predicted_safe"] += 1
            if row["safe_alias"]:
                correct_safe += 1
                lang["correct_safe"] += 1
    alias_precision = None if predicted_safe == 0 else correct_safe / predicted_safe
    return {
        "safe_threshold": safe_threshold,
        "correction_recall": {"value": None if positives == 0 else true_positives / positives, "num": true_positives, "den": positives},
        "false_add_rate": {"value": None if negatives == 0 else false_positives / negatives, "num": false_positives, "den": negatives},
        "alias_precision": {"value": alias_precision, "num": correct_safe, "den": predicted_safe, "wilson_lb_95": wilson_lower_bound(correct_safe, predicted_safe)},
        "alias_recall": {"value": None if sum(1 for r in rows if r["safe_alias"]) == 0 else correct_safe / sum(1 for r in rows if r["safe_alias"]), "num": correct_safe, "den": sum(1 for r in rows if r["safe_alias"])},
        "per_language": per_language,
    }


def select_safe_threshold(rows: list[dict], probs: list[list[float]], grid: list[float] = SAFE_THRESHOLD_GRID, lb_min: float = ALIAS_PRECISION_LB_MIN) -> dict:
    """Smallest grid value whose Wilson lower bound of alias precision meets
    `lb_min`, ties broken by alias recall; `qualifying: False` when none does."""
    best = None
    sweep = []
    for t in grid:
        s = score_decisions(rows, probs, t)
        lb = s["alias_precision"]["wilson_lb_95"]
        recall = s["alias_recall"]["value"]
        sweep.append({"safe_threshold": t, "alias_precision": s["alias_precision"], "alias_recall": s["alias_recall"]})
        if lb is not None and lb >= lb_min:
            if best is None or (recall is not None and recall > best["alias_recall"]):
                best = {"safe_threshold": t, "alias_recall": recall if recall is not None else -1.0, "wilson_lb_95": lb}
    return {"qualifying": best is not None, "selected": best, "lb_min": lb_min, "grid": [grid[0], grid[-1], len(grid)], "sweep": sweep}


def config_digest(payload: dict) -> str:
    return hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).hexdigest()


def tree_digest(folder: Path) -> str:
    h = hashlib.sha256()
    for f in sorted(p for p in folder.rglob("*") if p.is_file()):
        h.update(f.relative_to(folder).as_posix().encode("utf-8"))
        h.update(f.read_bytes())
    return h.hexdigest()


# --- Data ---


def load_partition(dev_dir: Path, name: str, manifest: dict) -> list[dict]:
    """The rows of one partition, verified against the split manifest: file
    digest, row count, content-hash set AND family set (a manifest that lies
    about its families cannot pass), plus the row-level review and language
    requirements."""
    if manifest.get("hash_version") != data.HASH_VERSION:
        raise RuntimeError("split manifest uses an unsupported hash version")
    part = manifest["partitions"][name]
    path = dev_dir / part["path"]
    if data.sha256_file(path) != part["file_sha256"]:
        raise RuntimeError(f"{name}: file digest differs from split-manifest.json")
    rows = data.read_jsonl(path)
    problems = gate.validate_rows(rows, name)
    if problems:
        raise RuntimeError(f"{name}: " + "; ".join(problems[:3]))
    for r in rows:
        if r.get("review_status") != "template-reviewed" or r.get("language") in (None, "", "und"):
            raise RuntimeError(f"{name}: row {r.get('id')} is not reviewed labelled data with a language")
    if part.get("rows") != len(rows):
        raise RuntimeError(f"{name}: row count differs from consumed rows")
    if sorted(data.content_hash(r) for r in rows) != sorted(part["hashes"]):
        raise RuntimeError(f"{name}: content hashes differ from split-manifest.json")
    if sorted({data.family_key(r) for r in rows}) != sorted(part["families"]):
        raise RuntimeError(f"{name}: families differ from consumed rows")
    return rows


def refuse_frozen_overlap(partitions: dict[str, list[dict]], frozen: dict) -> None:
    """Leakage and cross-partition checks derived from the CONSUMED rows,
    never from a manifest's declarations."""
    derived = {n: data.partition_manifest(rows) for n, rows in partitions.items()}
    tm = data.TrainingManifest(
        judge="trainer-check", kind="trained", checkpoint="-", tokenizer="-", thresholds={},
        partitions=derived, provenance="trainer input check", hash_version=data.HASH_VERSION,
        execution_identity={"checkpoint_sha256": "0" * 64, "tokenizer_sha256": "0" * 64, "config_sha256": "0" * 64})
    problems = data.leakage_problems(tm, frozen)
    crossing = []
    seen_h: set[str] = set()
    seen_f: set[str] = set()
    for n, p in derived.items():
        if seen_h & set(p["hashes"]):
            crossing.append(f"{n} shares rows with another partition")
        if seen_f & set(p["families"]):
            crossing.append(f"{n} shares families with another partition")
        seen_h |= set(p["hashes"])
        seen_f |= set(p["families"])
    if problems or crossing:
        raise RuntimeError("; ".join(problems + crossing))


def load_compat_receipt(path: Path, candidate: str) -> dict:
    """The retained compatibility receipt that clears `candidate` for
    training: the upstream tokenizer at exact parity, a successful
    conversion and all four placements ok. Returns its entry (revision,
    tokenizer digests, toolchain) or raises."""
    doc = json.loads(path.read_text(encoding="utf-8"))
    entry = next((c for c in doc.get("candidates", []) if c.get("name") == candidate), None)
    if entry is None:
        raise RuntimeError(f"{path}: no entry for {candidate}")
    up = entry.get("upstream", {})
    if not (up.get("loaded") and up.get("compared", 0) > 0 and up.get("matched") == up.get("compared")):
        raise RuntimeError(f"{candidate}: upstream tokenizer parity is not proven in {path}")
    if not entry.get("conversion", {}).get("ok"):
        raise RuntimeError(f"{candidate}: conversion did not succeed in {path}")
    placement = entry.get("placement", {})
    if set(placement) != {"cpuOnly", "cpuAndGPU", "cpuAndNeuralEngine", "all"} or not all(v.get("ok") for v in placement.values()):
        raise RuntimeError(f"{candidate}: not all four placements ok in {path}")
    if doc.get("toolchain", {}).get("transformers") != probe.EXPECTED_TOOLCHAIN["transformers"] or doc.get("toolchain", {}).get("coremltools") != probe.EXPECTED_TOOLCHAIN["coremltools"]:
        raise RuntimeError(f"{path}: toolchain differs from the pinned one")
    if not entry.get("revision"):
        raise RuntimeError(f"{candidate}: receipt carries no revision")
    return {"revision": entry["revision"], "tokenizer_files_sha256": entry.get("tokenizer_files_sha256", {}), "toolchain": doc["toolchain"], "receipt": str(path), "receipt_sha256": data.sha256_file(path)}


def encode_rows(rows: list[dict], contract: dict, encode) -> list[dict]:
    """Pair-encode every row with the Python mirror of the shipped adapter:
    input = `Edit: original → replacement`, output = `Sentence: pasted`."""
    out = []
    for r in rows:
        enc = probe.mirror_pair_encoding(contract, encode, f"{r['original']} → {r['replacement']}", r["pasted"])
        out.append(enc)
    return out


def verify_upstream_parity(tokenizer_dir: Path, texts: list[str], runner: Path, workdir: Path) -> dict:
    """The exact segments the trainer tokenizes, through the runner's
    upstream stack; every id list must match the reference tokenizer."""
    from transformers import AutoTokenizer

    tok = AutoTokenizer.from_pretrained(tokenizer_dir)
    req = workdir / "parity-request.json"
    out = workdir / "parity-response.json"
    req.write_text(json.dumps({"tokenizer_folder": str(tokenizer_dir), "texts": texts}, ensure_ascii=False), encoding="utf-8")
    proc = subprocess.run([str(runner), "tokenize", "--request", str(req), "--out", str(out), "--stack", "upstream"], capture_output=True, text=True)
    if proc.returncode != 0:
        return {"ok": False, "error": f"runner exit {proc.returncode}: {proc.stderr[:200]}"}
    resp = json.loads(out.read_text(encoding="utf-8"))
    if not resp.get("loaded"):
        return {"ok": False, "error": resp.get("error")}
    got = {e["text"]: e["ids"] for e in resp["texts"]}
    if set(got) != set(texts):
        return {"ok": False, "error": "runner returned a different text set"}
    mismatches = [t for t in texts if got[t] != tok(t, add_special_tokens=False)["input_ids"]]
    return {"ok": not mismatches, "compared": len(texts), "matched": len(texts) - len(mismatches), "stack": resp.get("stack")}


# --- Training ---


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--artifacts", type=Path, required=True)
    p.add_argument("--candidate", choices=list(probe.CANDIDATES), default="xenc-xlmr-base")
    p.add_argument("--dev-dir", type=Path, help="default <artifacts>/dev")
    p.add_argument("--seed", type=int, default=996)
    p.add_argument("--epochs", type=int, default=3)
    p.add_argument("--lr", type=float, default=2e-5)
    p.add_argument("--batch-size", type=int, default=16)
    p.add_argument("--smoke", action="store_true", help="a few steps on a few rows; a pipeline check, never a result")
    p.add_argument("--compat-receipt", type=Path, required=True, help="retained compatibility report.json that clears the candidate (revision is taken from it)")
    args = p.parse_args()
    if args.candidate != "xenc-xlmr-base":
        print("INFRA-ERROR: only XLM-R is cleared for training; other candidates require reviewed conversion and placement evidence", file=sys.stderr)
        return 2

    import numpy as np
    import torch
    import transformers
    from transformers import AutoModel, AutoTokenizer

    actual = {"transformers": transformers.__version__}
    if actual["transformers"] != probe.EXPECTED_TOOLCHAIN["transformers"]:
        print(f"INFRA-ERROR: transformers {actual['transformers']} is not the pinned {probe.EXPECTED_TOOLCHAIN['transformers']}", file=sys.stderr)
        return 2
    if not probe.RUNNER_BIN.exists():
        print(f"INFRA-ERROR: runner missing at {probe.RUNNER_BIN}", file=sys.stderr)
        return 2

    dev_dir = args.dev_dir or (args.artifacts / "dev")
    split_manifest = json.loads((dev_dir / "split-manifest.json").read_text(encoding="utf-8"))
    frozen, _, problems = gate.load_frozen()
    if problems:
        print("INFRA-ERROR: frozen partitions are not intact: " + "; ".join(problems), file=sys.stderr)
        return 2
    try:
        compat = load_compat_receipt(args.compat_receipt, args.candidate)
        train_rows = load_partition(dev_dir, "train", split_manifest)
        dev_rows = load_partition(dev_dir, "dev", split_manifest)
        cal_rows = load_partition(dev_dir, "calibration", split_manifest)
        refuse_frozen_overlap({"train": train_rows, "dev": dev_rows, "calibration": cal_rows}, frozen)
    except RuntimeError as exc:
        print(f"INFRA-ERROR: {exc}", file=sys.stderr)
        return 2
    if args.smoke:
        random.Random(args.seed).shuffle(train_rows)
        train_rows, dev_rows, cal_rows = train_rows[:48], dev_rows[:24], cal_rows[:24]

    spec = probe.CANDIDATES[args.candidate]
    revision = compat["revision"]
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid4().hex[:8] + ("-smoke" if args.smoke else "")
    run_dir = args.artifacts / "runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=False)
    ckpt_dir = run_dir / "checkpoint"
    ckpt_dir.mkdir()
    tok_dir = ckpt_dir / "tokenizer"
    tok_dir.mkdir()
    model_dir = ckpt_dir / "model"
    model_dir.mkdir()

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    tok = AutoTokenizer.from_pretrained(spec["hf"], revision=revision)
    tok.save_pretrained(tok_dir)
    tokenizer_digest = tree_digest(tok_dir)
    tokenizer_inventory = {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(tok_dir.iterdir()) if f.is_file()}
    specials = {"pad": tok.pad_token_id, "cls": tok.cls_token_id, "sep": tok.sep_token_id, "bos": tok.bos_token_id if tok.bos_token_id is not None else tok.cls_token_id, "eos": tok.eos_token_id if tok.eos_token_id is not None else tok.sep_token_id}
    if any(v is None for v in specials.values()):
        print(f"INFRA-ERROR: tokenizer specials incomplete: {specials}", file=sys.stderr)
        return 2
    contract = probe.build_contract(args.candidate, spec, specials)
    (run_dir / "tokenizer-contract.json").write_text(json.dumps(contract, indent=2), encoding="utf-8")
    encode = lambda text: tok(text, add_special_tokens=False)["input_ids"]  # noqa: E731

    # Exact tokenization of the training prefixes and segments through the
    # runner's upstream stack, before anything is fitted.
    sample = random.Random(args.seed).sample(train_rows, min(40, len(train_rows)))
    parity_texts = list(dict.fromkeys(
        [contract["inputPrefix"] + f"{r['original']} → {r['replacement']}" for r in sample]
        + [contract["outputPrefix"] + r["pasted"] for r in sample]
        + [contract["inputPrefix"], contract["outputPrefix"]]))
    parity = verify_upstream_parity(tok_dir, parity_texts, probe.RUNNER_BIN, run_dir)
    if not parity.get("ok"):
        print(f"INFRA-ERROR: upstream tokenizer parity failed on training segments: {parity}", file=sys.stderr)
        return 2

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    needs_types = spec["token_types"] == "bert_segments"
    counts = [sum(1 for r in train_rows if data.three_class(r["correction"], r["safe_alias"]) == c) for c in CLASS_ORDER]
    total = sum(counts)
    class_weights = [total / (len(CLASS_ORDER) * max(1, c)) for c in counts]
    experiment = {
        "run_id": run_id,
        "smoke": args.smoke,
        "candidate": args.candidate,
        "hf": spec["hf"],
        "revision": revision,
        "compat_receipt": compat,
        "tokenizer_sha256": tokenizer_digest,
        "tokenizer_inventory": tokenizer_inventory,
        "toolchain": {"torch": torch.__version__, "transformers": transformers.__version__, "python": sys.version.split()[0], "platform": platform.platform(), "device": device},
        "runner_sha256": hashlib.sha256(probe.RUNNER_BIN.read_bytes()).hexdigest(),
        "upstream_parity": parity,
        "seed": args.seed,
        "class_order": list(CLASS_ORDER),
        "decision_rule": DECISION_RULE,
        "safe_threshold_grid": [SAFE_THRESHOLD_GRID[0], SAFE_THRESHOLD_GRID[-1], len(SAFE_THRESHOLD_GRID)],
        "alias_precision_lb_min": ALIAS_PRECISION_LB_MIN,
        "encoding": {"contract": "tokenizer-contract.json", "input": "Edit: {original} → {replacement}", "output": "Sentence: {pasted}", "max_length": contract["maxLength"], "pooling": "CLS"},
        "optimizer": {"name": "AdamW", "lr": args.lr, "weight_decay": 0.01, "batch_size": args.batch_size, "epochs": args.epochs, "class_weights": class_weights, "loss": "cross-entropy"},
        "stopping_rule": "keep the epoch with the best dev macro-F1 over the three classes; no early stop below epochs",
        "calibration_objective": "smallest grid safe_threshold whose one-sided 95% Wilson lower bound of alias precision on dev >= 0.95, ties by alias recall; locked value reported on calibration",
        "partitions": {n: {"rows": len(rs), "file_sha256": split_manifest["partitions"][n]["file_sha256"]} for n, rs in (("train", train_rows), ("dev", dev_rows), ("calibration", cal_rows))},
        "split_manifest_sha256": data.sha256_file(dev_dir / "split-manifest.json"),
        "locked_at": datetime.now(timezone.utc).isoformat(),
    }
    (run_dir / "experiment.json").write_text(json.dumps(experiment, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    kwargs = {"attn_implementation": "eager"} if spec["hf"].startswith("jhu-clsp/mmBERT") else {}
    backbone = AutoModel.from_pretrained(spec["hf"], revision=revision, **kwargs)
    hidden = backbone.config.hidden_size

    class Judge(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.backbone = backbone
            self.head = torch.nn.Linear(hidden, len(CLASS_ORDER))

        def forward(self, input_ids, attention_mask, token_type_ids=None):
            if needs_types and token_type_ids is not None:
                out = self.backbone(input_ids=input_ids, attention_mask=attention_mask, token_type_ids=token_type_ids)
            else:
                out = self.backbone(input_ids=input_ids, attention_mask=attention_mask)
            return self.head(out.last_hidden_state[:, 0, :])

    model = Judge().to(device)

    def tensors(rows):
        enc = encode_rows(rows, contract, encode)
        ids = torch.tensor([e["input_ids"] for e in enc], dtype=torch.long)
        mask = torch.tensor([e["attention_mask"] for e in enc], dtype=torch.long)
        types = torch.tensor([e["token_type_ids"] for e in enc], dtype=torch.long)
        labels = torch.tensor([CLASS_ORDER.index(data.three_class(r["correction"], r["safe_alias"])) for r in rows], dtype=torch.long)
        return ids, mask, types, labels

    train_t = tensors(train_rows)
    dev_t = tensors(dev_rows)
    cal_t = tensors(cal_rows)

    def predict(t) -> list[list[float]]:
        model.eval()
        probs = []
        with torch.no_grad():
            for i in range(0, len(t[0]), 64):
                ids, mask, types = (x[i : i + 64].to(device) for x in t[:3])
                logits = model(ids, mask, types if needs_types else None).float()
                if not torch.isfinite(logits).all():
                    raise RuntimeError("non-finite logits during evaluation")
                probs.extend(torch.softmax(logits, dim=-1).cpu().tolist())
        return probs

    def macro_f1(rows, probs) -> float:
        f1s = []
        for c in range(len(CLASS_ORDER)):
            tp = fp = fn = 0
            for r, pr in zip(rows, probs):
                truth = CLASS_ORDER.index(data.three_class(r["correction"], r["safe_alias"]))
                pred = max(range(3), key=lambda k: pr[k])
                if pred == c and truth == c:
                    tp += 1
                elif pred == c:
                    fp += 1
                elif truth == c:
                    fn += 1
            f1s.append(0.0 if tp == 0 else 2 * tp / (2 * tp + fp + fn))
        return sum(f1s) / len(f1s)

    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)
    loss_fn = torch.nn.CrossEntropyLoss(weight=torch.tensor(class_weights, dtype=torch.float32).to(device))
    steps_total = 0
    epochs_log = []
    best = {"macro_f1": -1.0, "epoch": None}
    best_state = None
    max_steps = 3 if args.smoke else None
    t_start = time.time()
    for epoch in range(1, args.epochs + 1):
        model.train()
        order = list(range(len(train_t[0])))
        random.Random(args.seed + epoch).shuffle(order)
        losses = []
        for i in range(0, len(order), args.batch_size):
            batch = order[i : i + args.batch_size]
            ids, mask, types, labels = (x[batch].to(device) for x in train_t)
            logits = model(ids, mask, types if needs_types else None)
            loss = loss_fn(logits.float(), labels)
            if not torch.isfinite(loss):
                print("INFRA-ERROR: non-finite loss", file=sys.stderr)
                return 2
            optimizer.zero_grad()
            loss.backward()
            grad_norm = torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            if not torch.isfinite(grad_norm):
                print("INFRA-ERROR: non-finite gradient norm", file=sys.stderr)
                return 2
            optimizer.step()
            losses.append(loss.item())
            steps_total += 1
            if max_steps and steps_total >= max_steps:
                break
        dev_probs = predict(dev_t)
        f1 = macro_f1(dev_rows, dev_probs)
        epochs_log.append({"epoch": epoch, "steps": steps_total, "train_loss_mean": sum(losses) / max(1, len(losses)), "dev_macro_f1": f1, "elapsed_s": round(time.time() - t_start, 1)})
        print(json.dumps(epochs_log[-1]))
        if f1 > best["macro_f1"]:
            best = {"macro_f1": f1, "epoch": epoch}
            best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
        if max_steps and steps_total >= max_steps:
            break
    if best_state is None or steps_total == 0:
        print("INFRA-ERROR: no optimizer step ran", file=sys.stderr)
        return 2
    model.load_state_dict(best_state)

    # Calibration on dev, locked value checked on calibration.
    dev_probs = predict(dev_t)
    selection = select_safe_threshold(dev_rows, dev_probs)
    cal_probs = predict(cal_t)
    locked = selection["selected"]["safe_threshold"] if selection["qualifying"] else None
    results = {
        "best_epoch": best,
        "epochs": epochs_log,
        "steps_total": steps_total,
        "dev_selection": {k: v for k, v in selection.items() if k != "sweep"},
        "dev_sweep": selection["sweep"],
        "dev_at_locked": score_decisions(dev_rows, dev_probs, locked) if locked is not None else None,
        "calibration_at_locked": score_decisions(cal_rows, cal_probs, locked) if locked is not None else None,
        "calibration_argmax_reference": score_decisions(cal_rows, cal_probs, 0.5),
        "not_acceptance_evidence": "development and calibration partitions only; the frozen report rows were never scored",
    }

    # Save the checkpoint and bind the artifact.
    model.backbone.save_pretrained(model_dir, safe_serialization=True)
    from safetensors.torch import save_file

    save_file({k: v.detach().cpu().contiguous() for k, v in model.head.state_dict().items()}, str(model_dir / "head.safetensors"))
    checkpoint_digest = tree_digest(model_dir)
    decision_config = {
        "class_order": list(CLASS_ORDER),
        "decision_rule": DECISION_RULE,
        "safe_threshold": locked,
        "encoding": experiment["encoding"],
        "contract_sha256": data.sha256_file(run_dir / "tokenizer-contract.json"),
        "precision_variant": "fp32-pytorch",
        "package_sha256": None,
    }
    execution_identity = {"checkpoint_sha256": checkpoint_digest, "tokenizer_sha256": tokenizer_digest, "config_sha256": config_digest(decision_config)}
    training_manifest = {
        "judge": args.candidate,
        "kind": "trained",
        "checkpoint": str(model_dir),
        "tokenizer": str(tok_dir),
        "tokenizer_inventory": tokenizer_inventory,
        "thresholds": {"safe_threshold": locked, "qualifying": selection["qualifying"]},
        "provenance": f"train_edit_judge.py run {run_id}; templates {split_manifest['templates_version']} sha {split_manifest['templates_sha256'][:12]}; revision {revision}",
        "hash_version": data.HASH_VERSION,
        "execution_identity": execution_identity,
        "decision_config": decision_config,
        "partitions": {n: {"hashes": split_manifest["partitions"][n]["hashes"], "families": split_manifest["partitions"][n]["families"]} for n in ("train", "dev", "calibration")},
    }
    (run_dir / "training-manifest.json").write_text(json.dumps(training_manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    loaded = data.load_training_manifest(run_dir / "training-manifest.json")
    results["training_manifest_problems"] = loaded.problems + data.leakage_problems(loaded, frozen)
    results["execution_identity"] = execution_identity
    (run_dir / "metrics.json").write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    summary = {
        "run": str(run_dir),
        "steps": steps_total,
        "best_epoch": best,
        "qualifying_threshold": locked,
        "dev_at_locked": {k: results["dev_at_locked"][k] for k in ("correction_recall", "false_add_rate", "alias_precision")} if locked is not None else None,
        "calibration_at_locked": {k: results["calibration_at_locked"][k] for k in ("correction_recall", "false_add_rate", "alias_precision")} if locked is not None else None,
        "manifest_problems": results["training_manifest_problems"],
    }
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0 if not results["training_manifest_problems"] else 1


if __name__ == "__main__":
    sys.exit(main())
