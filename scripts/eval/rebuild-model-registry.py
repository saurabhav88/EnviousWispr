#!/usr/bin/env python3
"""Relabel every EG-1 model we have ever trained under the new artifact ID.

The ONLY hand-authored part is the table below: which arm belongs to which product
line, in what order, and what happened to it. Every NUMBER is read from the score
receipts, never transcribed — the prose ledger this replaces warns in its own text
that its earlier figures were transcribed rather than read, and two of them were
wrong.

Cloud-prompt arms (v7d, v10-founder, gemini/openai cand, v16-proselists) are NOT
EG-1 models and are deliberately absent. Prompt probes on an existing model
(`eg1_promptprobe`, `eg1_probe_v3`, `v14_promptprobe`, `v14_fluidprompt`) are
experiments ON an artifact, not new artifacts, so they attach as evaluations of
their subject rather than as rows of their own.
"""
import json
import os
from pathlib import Path

# Receipts live in the MAIN checkout: `runs/` is gitignored, so a worktree has
# none and a relative path here would silently rebuild an empty registry.
RUNS = Path(os.environ.get("EW_EVAL_RUNS")
            or "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/scripts/eval/runs")
OUT = Path(__file__).parent / "model-registry.json"

# release -> ordered arms. The candidate number is position in this list, which is
# the ledger's own order (arm version numbers), NOT measured timestamps. Said out
# loud in the file so nobody reads c007 as "trained seventh on the calendar".
ARMS = [
    # --- 1.0: the original EG-1, the only artifact of its line that we still have
    ("1.0", "eg1-v1-monolith", ["eg1_sealed.jsonl", "eg1_shipped.jsonl",
                                "arm_eg1_candidates.jsonl", "eg1_gold150_candidates.jsonl",
                                "candidates_eg1_native_1890.jsonl",
                                "eg1_shipped_holdout900.jsonl",
                                "eg1_shipped_trained1690.jsonl",
                                "eg1_promptprobe_sealed.jsonl",
                                "eg1_probe_v3_sealed.jsonl",
                                "arm_eg1_candidates_v3.jsonl"],
     "superseded", "Replaced by 1.1. The monolith is retired and deleted on upgrade."),

    # --- 1.1: the campaign that produced the shipped model
    ("1.1", "v6capped", ["arm_v6capped_candidates.jsonl"], "rejected",
     "No-op rate trimmed. +0.1pp, p=0.90 — null."),
    ("1.1", "v6prod", ["arm_v6prod_candidates.jsonl"], "rejected",
     "All non-production inputs reshaped. -2.0pp, p=0.015 — WORSE."),
    ("1.1", "v7drills", ["arm_v7drills_candidates.jsonl"], "rejected",
     "Drills reshaped to production shape. +0.5pp, p=0.55 — null."),
    ("1.1", "v8", ["arm_v8_candidates.jsonl"], "rejected",
     "+3,437 synthetic SFT drills. -2.0pp, p=0.021 — WORSE."),
    ("1.1", "dpo1", ["dpo1_sealed.jsonl"], "rejected",
     "Preference pairs at 5e-6 x1. 99% of outputs byte-identical to the base — null."),
    ("1.1", "dpo2", [], "rejected",
     "Preference pairs at 3e-5 x2. Over-optimised: formatted 100% of wanted cases AND "
     "39.9% of flat ones, restraint 85% -> 49%. Killed before a sealed run, so it has "
     "no evaluation receipt."),
    ("1.1", "dpo3", ["dpo3_sealed.jsonl", "dpo3_speechpath.jsonl"], "rejected",
     "Preference pairs at 1.2e-5 x1. Beaten by dpo4 on the same corpus."),
    ("1.1", "dpo4", ["dpo4_sealed.jsonl", "dpo4_speechpath.jsonl"], "rejected",
     "Meaning-weighted pairs, 30% structure. The only arm of its line to improve every "
     "dimension at once, and still not the arm that shipped."),
    ("1.1", "v13", ["v13_sealed.jsonl"], "rejected",
     "SFT list drills. Lists solved, self_correction fell 71.2 -> 65.3."),
    ("1.1", "v14", ["v14_sealed.jsonl", "v14_promptprobe_sealed.jsonl",
                    "v14_fluidprompt_sealed.jsonl"], "rejected",
     "SFT hinge gate. Superseded within the same line."),
    ("1.1", "v15", ["v15_sealed.jsonl"], "rejected",
     "SFT marker classes. Superseded within the same line."),
    ("1.1", "v15align", ["v15align_sealed.jsonl"], "rejected",
     "v15 corpus trained ON a fuller prompt. p=1.00 — in SFT the system prompt is a "
     "constant prefix and carries no gradient."),
    ("1.1", "v17", ["v17_sealed.jsonl"], "rejected",
     "Marker prior rebalanced. First arm ever to beat EG-1 1.0 on self_correction."),
    ("1.1", "v18", ["v18_sealed.jsonl", "v18_speechpath.jsonl"], "rejected",
     "+ list-trigger prior rebalanced. Beat cloud +120/-89, p=0.038."),
    ("1.1", "v19", ["v19_sealed.jsonl"], "rejected",
     "Superseded by v20 within the same line."),
    ("1.1", "v20", ["v20_sealed.jsonl", "v20_speechpath.jsonl",
                    "eg1_v2_installed_sealed.jsonl"], "shipped",
     "SHIPPED as EG-1 1.1, delivery revision v3-eg2, shards eg-1-v2-*. Lineage evidence: "
     "branch feat/eg2-v20-model, docs/eg2-campaign/build_v20_manifest.py and shard_v20.sh, "
     "and the commit 'point the shipped manifests at model revision v3-eg2' on that branch."),

    # --- 1.2: the email-structure campaign
    ("1.2", "v21email", ["sealed_v21.jsonl", "typeb_v21.jsonl", "tail_v21.jsonl"],
     "rejected", "Round 1. 4 genuine stable critical regressions against shipped 1.1."),
    ("1.2", "v22round2", ["sealed_v22.jsonl", "email_v22.jsonl", "tail_v22.jsonl"],
     "rejected", "Round 2. Made meaning WORSE (5 genuine regressions): a drill gate forced "
     "every one of 263 rows shorter, so the model learned to delete."),
    ("1.2", "v23round3", ["sealed_v23.jsonl", "email_v23.jsonl", "typeb_v23.jsonl",
                          "tail_v23.jsonl"],
     "selected", "Round 3. Zero genuine stable critical regressions, email held at +75. "
     "Won but NOT yet shipped: the shards are not uploaded, and two founder decisions are "
     "open (the absolute S4 waiver, and two verbatim_passthrough refusals)."),
]


def read_receipts() -> dict:
    """Every scored run, keyed by the candidate file it graded."""
    out = {}
    for f in sorted(RUNS.rglob("summary.json")):
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        o, m = d.get("overall") or {}, d.get("meta") or {}
        cand = m.get("candidates_file")
        if not cand or o.get("total_scored") is None:
            continue
        out.setdefault(cand, []).append({
            "corpus": ",".join(m.get("corpus_files") or []) or None,
            "judgeIdentity": m.get("judge_identity") or m.get("judge"),
            "rubricIdentity": m.get("rubric_identity"),
            "runComplete": d.get("run_complete"),
            "passRatePct": o.get("pass_rate_pct"),
            "s4Count": o.get("critical_fail_count"),
            "casesScored": o.get("total_scored"),
            "verdict": (d.get("release_gate") or {}).get("verdict"),
            "summaryPath": str(f.relative_to(RUNS.parent.parent.parent)),
        })
    return out


def main() -> int:
    receipts = read_receipts()
    counters, records = {}, []
    for release, legacy, cand_files, status, reason in ARMS:
        counters[release] = counters.get(release, 0) + 1
        artifact_id = f"eg1-{release}-c{counters[release]:03d}"
        evals = []
        for cf in cand_files:
            evals.extend(receipts.get(cf, []))
        evals.sort(key=lambda e: (e["corpus"] or "", e["summaryPath"]))
        records.append({
            "artifactId": artifact_id,
            "release": release,
            "status": status,
            "statusReason": reason,
            "legacyNames": [legacy] + cand_files,
            "legacyExemption": True,
            "evaluations": evals,
        })

    doc = {
        "_comment": "Every EG-1 model we have trained, under the artifact-ID convention. "
                    "The authority for candidate status and evaluation provenance. "
                    "Numbers are read from score receipts, never typed.",
        "_idFormat": "eg1-<release>-c<NNN>. The release is what the candidate was AIMED "
                     "at; the candidate number resets when the release changes. A "
                     "candidate is never renamed, including when it wins.",
        "_candidateOrder": "For rows carrying legacyExemption, the candidate number is "
                           "position in the historical arm ledger (arm version order), "
                           "NOT a measured training timestamp. Do not read c007 as "
                           "'trained seventh by date'.",
        "_comparability": "An evaluation is comparable to another ONLY when corpus, "
                          "rubricIdentity and judgeIdentity all match. Nine rubrics and "
                          "38 corpora appear across this history; ranking across them is "
                          "the mistake this file exists to prevent.",
        "artifacts": records,
    }
    OUT.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print(f"{len(records)} artifacts written to {OUT}")
    for r in records:
        n = len(r["evaluations"])
        print(f"  {r['artifactId']:16s} {r['status']:11s} {n:>2} eval(s)  "
              f"<- {r['legacyNames'][0]}")
    orphans = sum(1 for r in records if not r["evaluations"] and r["status"] != "rejected")
    print(f"\nartifacts with no receipt at all: "
          f"{[r['artifactId'] for r in records if not r['evaluations']]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
