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
import sys
import tempfile
from pathlib import Path

# Receipts live in the MAIN checkout: `runs/` is gitignored, so a worktree has
# none and a relative path here would silently rebuild an empty registry.
RUNS = Path(os.environ.get("EW_EVAL_RUNS")
            or "/Users/m4pro_sv/Developer/EnviousLabs/EnviousWispr/scripts/eval/runs")
OUT = Path(__file__).parent / "model-registry.json"

# Each row carries its OWN immutable id. The candidate numbers were originally
# assigned from the ledger's order (arm version numbers, NOT measured timestamps —
# do not read c007 as "trained seventh on the calendar"), but they are PINNED here
# rather than recomputed: deriving an immutable identifier from list POSITION means
# inserting a forgotten arm silently renames every later candidate in that release,
# including the shipped winner, which is exactly what the convention forbids.
ARMS = [
    # --- 1.0: the original EG-1, the only artifact of its line that we still have
    ("eg1-1.0-c001", "1.0", "eg1-v1-monolith", ["eg1_sealed.jsonl", "eg1_shipped.jsonl",
                                "arm_eg1_candidates.jsonl", "eg1_gold150_candidates.jsonl",
                                "candidates_eg1_native_1890.jsonl",
                                "eg1_shipped_holdout900.jsonl",
                                "eg1_shipped_trained1690.jsonl",
                                "eg1_promptprobe_sealed.jsonl",
                                "eg1_probe_v3_sealed.jsonl",
                                "arm_eg1_candidates_v3.jsonl"],
     "superseded", "Replaced by 1.1. The monolith is retired and deleted on upgrade."),

    # --- 1.1: the campaign that produced the shipped model
    ("eg1-1.1-c001", "1.1", "v6capped", ["arm_v6capped_candidates.jsonl"], "rejected",
     "No-op rate trimmed. +0.1pp, p=0.90 — null."),
    ("eg1-1.1-c002", "1.1", "v6prod", ["arm_v6prod_candidates.jsonl"], "rejected",
     "All non-production inputs reshaped. -2.0pp, p=0.015 — WORSE."),
    ("eg1-1.1-c003", "1.1", "v7drills", ["arm_v7drills_candidates.jsonl"], "rejected",
     "Drills reshaped to production shape. +0.5pp, p=0.55 — null."),
    ("eg1-1.1-c004", "1.1", "v8", ["arm_v8_candidates.jsonl"], "rejected",
     "+3,437 synthetic SFT drills. -2.0pp, p=0.021 — WORSE."),
    ("eg1-1.1-c005", "1.1", "dpo1", ["dpo1_sealed.jsonl"], "rejected",
     "Preference pairs at 5e-6 x1. 99% of outputs byte-identical to the base — null."),
    ("eg1-1.1-c006", "1.1", "dpo2", [], "rejected",
     "Preference pairs at 3e-5 x2. Over-optimised: formatted 100% of wanted cases AND "
     "39.9% of flat ones, restraint 85% -> 49%. Killed before a sealed run, so it has "
     "no evaluation receipt."),
    ("eg1-1.1-c007", "1.1", "dpo3", ["dpo3_sealed.jsonl", "dpo3_speechpath.jsonl"], "rejected",
     "Preference pairs at 1.2e-5 x1. Beaten by dpo4 on the same corpus."),
    ("eg1-1.1-c008", "1.1", "dpo4", ["dpo4_sealed.jsonl", "dpo4_speechpath.jsonl"], "rejected",
     "Meaning-weighted pairs, 30% structure. The only arm of its line to improve every "
     "dimension at once, and still not the arm that shipped."),
    ("eg1-1.1-c009", "1.1", "v13", ["v13_sealed.jsonl"], "rejected",
     "SFT list drills. Lists solved, self_correction fell 71.2 -> 65.3."),
    ("eg1-1.1-c010", "1.1", "v14", ["v14_sealed.jsonl", "v14_promptprobe_sealed.jsonl",
                    "v14_fluidprompt_sealed.jsonl"], "rejected",
     "SFT hinge gate. Superseded within the same line."),
    ("eg1-1.1-c011", "1.1", "v15", ["v15_sealed.jsonl"], "rejected",
     "SFT marker classes. Superseded within the same line."),
    ("eg1-1.1-c012", "1.1", "v15align", ["v15align_sealed.jsonl"], "rejected",
     "v15 corpus trained ON a fuller prompt. p=1.00 — in SFT the system prompt is a "
     "constant prefix and carries no gradient."),
    ("eg1-1.1-c013", "1.1", "v17", ["v17_sealed.jsonl"], "rejected",
     "Marker prior rebalanced. First arm ever to beat EG-1 1.0 on self_correction."),
    ("eg1-1.1-c014", "1.1", "v18", ["v18_sealed.jsonl", "v18_speechpath.jsonl"], "rejected",
     "+ list-trigger prior rebalanced. Beat cloud +120/-89, p=0.038."),
    ("eg1-1.1-c015", "1.1", "v19", ["v19_sealed.jsonl"], "rejected",
     "Superseded by v20 within the same line."),
    ("eg1-1.1-c016", "1.1", "v20", ["v20_sealed.jsonl", "v20_speechpath.jsonl",
                    "eg1_v2_installed_sealed.jsonl"], "shipped",
     "SHIPPED as EG-1 1.1, delivery revision v3-eg2, shards eg-1-v2-*. Lineage evidence: "
     "branch feat/eg2-v20-model, docs/eg2-campaign/build_v20_manifest.py and shard_v20.sh, "
     "and the commit 'point the shipped manifests at model revision v3-eg2' on that branch."),

    # --- 1.2: the email-structure campaign
    ("eg1-1.2-c001", "1.2", "v21email", ["sealed_v21.jsonl", "typeb_v21.jsonl", "tail_v21.jsonl"],
     "rejected", "Round 1. 4 genuine stable critical regressions against shipped 1.1."),
    ("eg1-1.2-c002", "1.2", "v22round2", ["sealed_v22.jsonl", "email_v22.jsonl", "tail_v22.jsonl"],
     "rejected", "Round 2. Made meaning WORSE (5 genuine regressions): a drill gate forced "
     "every one of 263 rows shorter, so the model learned to delete."),
    ("eg1-1.2-c003", "1.2", "v23round3", ["sealed_v23.jsonl", "email_v23.jsonl", "typeb_v23.jsonl",
                          "tail_v23.jsonl"],
     "selected", "Round 3. Zero genuine stable critical regressions, email held at +75. "
     "Won but NOT yet shipped: the shards are not uploaded, and two founder decisions are "
     "open (the absolute S4 waiver, and two verbatim_passthrough refusals)."),

    # --- #4473: the three sizes on the EnviousDecode engine. Their ids were given before
    # they were chosen and are kept as they are (model_registry.KEPT_CANDIDATE_IDS). They
    # have no score receipt in this harness yet, so they carry no candidate file; their
    # qualification is plan #4473 P6. Their status is "candidate", so none of them sets a floor.
    ("eg1-1.3-intl-1c-20261109", "1.3", "eg13-1c", [], "candidate",
     "The full size (Qwen3.5-4B, round 1c). Chosen for PACKAGING as the EnviousDecode "
     "full size in plan #4473 P4; an export is recorded. Not qualified for release here: "
     "the delivered exam is plan #4473 P6."),
    ("eg1-mini-1.0-g3onestage", "1.0", "mini-g3onestage", [], "candidate",
     "EG-1 Mini (Qwen3.5-2B, one-stage). Chosen for PACKAGING in plan #4473 P4; an export "
     "is recorded. Not qualified for release here: the delivered exam is plan #4473 P6. "
     "A size of its own: it is not a candidate against the 1.0 full-size line."),
    ("eg1-micro-1.0-g3d", "1.0", "micro-g3d", [], "candidate",
     "EG-1 Micro (Qwen3.5-0.8B, g3d). Chosen for PACKAGING in plan #4473 P4; an export is "
     "recorded. Not qualified for release here: the delivered exam is plan #4473 P6. "
     "A size of its own: it is not a candidate against the 1.0 full-size line."),
]
# Packaged forms (exports) of the artifacts above, hand-authored from the packaging inventory
# of plan #4473 P4 (run folder 20261109-223321-eg1-family-app-integration-9cd4, p4-c1/inventory.json).
# An export id starts with its artifact id and is never an artifact id. packageSHA256 is the
# SHA-256 of the lines "path<TAB>bytes<TAB>sha256" of the package's files, sorted by path.
EXPORTS = json.loads(r"""{
    "eg1-1.3-intl-1c-20261109": [
        {
            "exportId": "eg1-1.3-intl-1c-20261109-mlx-q6-e001",
            "variant": "mlx-q6",
            "runtimeABI": "enviousdecode-v1",
            "packageSHA256": "a22ed7b2dd1c93931fe2d3815a5abb21e9e2358634d73860bdccc99c0d93bfe9",
            "files": 21,
            "totalBytes": 4707411269,
            "chatTemplateSHA256": "64f85b198065d0fba2a81f37e10ed68161ce2c19a754c7100e67e0ca2ee9c326",
            "tokenizerSHA256": "a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f",
            "stopTokenIds": [
                248046,
                248044
            ],
            "draftWeightsSHA256": [
                "064a2e53bd7bbeb48c9169857499b4636fba98b1a3e8679bfafb1646ea3275d0",
                "6ba7f5420e692710aaa72b67193a8e0ed5640733feb09917ab0684833ed59dfc",
                "826a277ca43d55666ff7021c398a95f33223fbe8586ecfac605e2a814a07b0c1"
            ],
            "checker": {
                "packageSHA256": "e844ae6a6c517f99e50e38f05880a7d918b9233df7af96e625677814834279b0",
                "adapterSHA256": "670a9015e2b938043bc3adf6560487e6904d140377dda0b60783b3c09fef4881",
                "adapterConfigSHA256": "5f119770b33c2c301cdb0dcfa3c2fd2e0098ae4b79284bac59f6e5391779f47e",
                "variant": "mlx-f32",
                "qualifiedThreshold": "0.1824255410790286"
            }
        }
    ],
    "eg1-mini-1.0-g3onestage": [
        {
            "exportId": "eg1-mini-1.0-g3onestage-mlx-q6-e001",
            "variant": "mlx-q6",
            "runtimeABI": "enviousdecode-v1",
            "packageSHA256": "b50be3c0a6a247710bfebb662b3ef3cc534697473b3a15f7ae9339988cba4552",
            "files": 16,
            "totalBytes": 2074163194,
            "chatTemplateSHA256": "64f85b198065d0fba2a81f37e10ed68161ce2c19a754c7100e67e0ca2ee9c326",
            "tokenizerSHA256": "a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f",
            "stopTokenIds": [
                248046,
                248044
            ],
            "draftWeightsSHA256": [
                "c81505f8b1077dedf26fffb12c1bcc179ecae243aa71c59dd22abce2f1e945cf",
                "947293ec7f70bc50582d74a0f31ee90a48790b51081c1b281b7d5ed9467f7fcf"
            ],
            "checker": {
                "packageSHA256": "dec2ff00883f7124f290d779add871269b039db0b186b8573edde4923f39089a",
                "adapterSHA256": "94d090aa8ccdc3ac1ec0e8e76020da2c471f1d463aad0e04bb8f54ded147d831",
                "adapterConfigSHA256": "d0e64161799a4fa222663035ca778de76bea3a41eda8fc81408dfde1f78fb6e5",
                "variant": "mlx-f32",
                "qualifiedThreshold": "0.20181324011109297"
            }
        }
    ],
    "eg1-micro-1.0-g3d": [
        {
            "exportId": "eg1-micro-1.0-g3d-mlx-q6-e001",
            "variant": "mlx-q6",
            "runtimeABI": "enviousdecode-v1",
            "packageSHA256": "19e3aa3e67b62d8c8ebcfdf0d2e53ea49b4d5da626be448f853d1ba205d7deda",
            "files": 12,
            "totalBytes": 805133748,
            "chatTemplateSHA256": "64f85b198065d0fba2a81f37e10ed68161ce2c19a754c7100e67e0ca2ee9c326",
            "tokenizerSHA256": "a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f",
            "stopTokenIds": [
                248046,
                248044
            ],
            "draftWeightsSHA256": [
                "4c69854f078a44fa52bb19332620cf2f4e77589019fe8bdb2e37acd933397f9a"
            ],
            "checker": {
                "packageSHA256": "d62b33576a6bdc4747aba414af337ea582f7b794ee076d207f929b14fbfa9a66",
                "adapterSHA256": "7247de615fb5f33c5fc6b4d3bf392e9c5c76a35a945935078ce82eae220f1a3a",
                "adapterConfigSHA256": "d0e64161799a4fa222663035ca778de76bea3a41eda8fc81408dfde1f78fb6e5",
                "variant": "mlx-f32",
                "qualifiedThreshold": "0.20181324142004287"
            }
        }
    ]
}""")


def read_receipts() -> dict:
    """Every scored run, keyed by the candidate file it graded.

    REFUSES when the receipt directory is absent or holds nothing. `runs/` is
    gitignored and the default path names one user's checkout, so on a fresh clone
    or any other machine `rglob` finds nothing, returns cleanly, and this script
    would overwrite the tracked registry with zero evaluations — destroying the
    record of which model won while exiting 0. That is the failure that matters
    here, because it is silent and it is the normal state of every other machine.
    """
    if not RUNS.is_dir():
        raise SystemExit(
            f"REFUSED: no receipt directory at {RUNS}. Set EW_EVAL_RUNS to the "
            f"checkout that holds scripts/eval/runs. Rebuilding from nothing would "
            f"erase every evaluation in the tracked registry.")
    out = {}
    for f in sorted(RUNS.rglob("summary.json")):
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            # RAISE, never skip. A `continue` here drops real history and the script
            # still exits 0 over a tracked file, so the loss is invisible exactly
            # when it matters.
            raise SystemExit(f"REFUSED: cannot read receipt {f} ({exc})")
        o, m = d.get("overall") or {}, d.get("meta") or {}
        cand = m.get("candidates_file")
        # A summary with no candidate file or no score is not a receipt for any
        # artifact — a partial write, or an aggregate. Skipping THOSE is correct;
        # skipping an unreadable file is not, which is why they are separate.
        if not cand or o.get("total_scored") is None:
            continue
        # WHICH PROMPT the run used, relative to the artifact's OWN training prompt.
        # A prompt probe is an experiment ON an artifact, so it attaches to that
        # artifact — but its score describes a configuration that was never selected
        # or shipped, and merging it with the artifact's own runs reports the probe as
        # the headline. Measured: v14, v14_promptprobe and v14_fluidprompt collapsed
        # into one group and the fluid-prompt result was shown as v14's score.
        # The receipts do not record prompt identity, so it is assigned here from the
        # candidate filename, which is the only place the distinction survives.
        probe = next((tag for tag in ("promptprobe", "fluidprompt", "probe_v3")
                      if tag in cand), None)
        out.setdefault(cand, []).append({
            "promptVariant": probe or "own",
            "corpus": ",".join(m.get("corpus_files") or []) or None,
            # A pinned identity where we have one; otherwise the coarse judge NAME,
            # PREFIXED so the two can never be mistaken for each other. An Azure
            # deployment can be repointed in place, so `azure/gpt-5-6-luna` alone can
            # name two different models — a bare fallback would silently let those
            # compare as one judge, which is the failure this field exists to prevent.
            "judgeIdentity": (m.get("judge_identity")
                              or (f"name-only:{m['judge']}" if m.get("judge") else None)),
            "rubricIdentity": m.get("rubric_identity"),
            # TWO MORE COMPARABILITY AXES, both enumerated from the receipt rather
            # than from a review finding. `system` is the whole grading scheme —
            # an "old" 5-axis run and a "new" behavior-aware one produce numbers on
            # different scales. `judgeBlind` is measured non-comparable in
            # behavior_judge.py: showing the judge the key moved 122 of 472 verdicts,
            # and report_ollama_bench.py already refuses to rank the modes together.
            # Ranking across either is the mistake this file exists to prevent.
            "system": m.get("system"),
            "judgeBlind": d.get("judge_blind"),
            # ADJUDICATION POLICY, and it is directional rather than merely different:
            # `_worse_new_score` keeps the harsher of the two looks, so a run that
            # skipped adjudication can only score BETTER than the same model
            # adjudicated. Comparing it to an adjudicated floor is a free pass.
            # `meta.adjudicate` exists only on receipts written after 2026-09-01; for
            # older ones it is inferred from whether anything was SELECTED or
            # RE-JUDGED, and left null when both are zero, because "nothing needed
            # adjudicating" and "adjudication was off" are indistinguishable there.
            # Null is excluded from every floor, exactly like unknown blinding.
            "adjudication": _adjudication_policy(m, d),
            # "none" rather than null: NO baseline is a real, distinct setup, not a
            # gap in the record. Null would mean "the receipt cannot say", which for
            # this field never happens — `production_file` is written on every run.
            "productionBaseline": m.get("production_file") or "none",
            "runComplete": d.get("run_complete"),
            "passRatePct": o.get("pass_rate_pct"),
            "s4Count": o.get("critical_fail_count"),
            "casesScored": o.get("total_scored"),
            "verdict": (d.get("release_gate") or {}).get("verdict"),
            "summaryPath": str(f.relative_to(RUNS.parent.parent.parent)),
        })
    return out


def _adjudication_policy(meta: dict, doc: dict) -> str | None:
    """`"<pct>:<min>"`, `"none"`, or None when the receipt cannot say."""
    enabled = meta.get("adjudicate")
    if enabled is None:
        adj = doc.get("adjudication") or {}
        if (adj.get("adjudicated_n") or 0) or (adj.get("rejudged_n") or 0):
            enabled = True
        else:
            return None
    if not enabled:
        return "none"
    return f"{meta.get('adjudicate_pct')}:{meta.get('adjudicate_min')}"


def main() -> int:
    receipts = read_receipts()
    if not receipts:
        raise SystemExit(
            f"REFUSED: {RUNS} holds no readable score receipts. Refusing to write a "
            f"registry with no evaluations over one that has them.")

    # Every candidate file this table DECLARES must have a receipt. Without this the
    # script happily writes an artifact with zero evaluations when a run directory has
    # been moved or deleted, and the row then reads as "never scored" rather than
    # "its receipt is gone".
    missing = sorted({cf for row in ARMS for cf in row[3] if cf not in receipts})
    if missing:
        raise SystemExit(
            "REFUSED: these declared candidate files have no receipt under "
            f"{RUNS}:\n  " + "\n  ".join(missing) +
            "\nEither the receipts moved, or the table names a file that never existed.")
    sys.path.insert(0, str(Path(__file__).parent))
    from model_registry import KEPT_CANDIDATE_IDS
    exports = EXPORTS
    records, seen = [], set()
    for artifact_id, release, legacy, cand_files, status, reason in ARMS:
        if artifact_id in seen:
            raise SystemExit(f"REFUSED: {artifact_id} appears twice in ARMS")
        if artifact_id in KEPT_CANDIDATE_IDS:
            if KEPT_CANDIDATE_IDS[artifact_id] != release:
                raise SystemExit(f"REFUSED: {artifact_id} does not belong to release {release}")
        elif not artifact_id.startswith(f"eg1-{release}-"):
            raise SystemExit(f"REFUSED: {artifact_id} does not match release {release}")
        seen.add(artifact_id)
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
        if artifact_id in exports:
            records[-1]["exports"] = exports[artifact_id]

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
        # NAMES THE OWNER, does not list the axes. The previous version enumerated
        # three of them and went stale the day a fourth was added — a description of a
        # set is a claim about that set, and nothing links the two edits. Nine rubrics
        # and 38 corpora appear across this history; ranking across them is the mistake
        # this file exists to prevent.
        "_comparability": "model_registry.comparable() is the ONLY authority on whether "
                          "two evaluations may be ranked together. Read that function "
                          "rather than any prose, here or elsewhere: it states every "
                          "axis it compares and argues each field it deliberately "
                          "excludes. Ranking across incomparable evaluations is the "
                          "mistake this file exists to prevent.",
        "artifacts": records,
    }
    # VALIDATE BEFORE REPLACING, and refuse a rebuild that LOSES history.
    #
    # Writing first and validating afterwards means a malformed receipt overwrites a
    # good registry and the damage is on disk by the time anything objects. And the
    # earlier "every declared candidate file has a receipt" check is SET-based: a
    # candidate whose four summaries became one still passes it, because the KEY is
    # present. Comparing per-artifact evaluation COUNTS against the file being
    # replaced catches that, which the key check cannot.
    #
    # And the count check has a blind spot of its own: it walks the REBUILT records,
    # so an artifact that is not in them is never examined. Delete an ARMS row, or
    # rename its immutable id, and the artifact and every evaluation on it fall out
    # of the registry while the staged file still validates and the script exits 0
    # (#2581). A floor-setting winner can vanish that way. So the WHOLE id set of
    # the file being replaced is compared first: an id that was registered and is
    # absent from the rebuild is a refusal, before any per-artifact count is read.
    sys.path.insert(0, str(Path(__file__).parent))
    import model_registry

    if OUT.exists():
        try:
            previous = json.loads(OUT.read_text(encoding="utf-8"))
        except ValueError as exc:
            raise SystemExit(f"REFUSED: the registry being replaced is unreadable ({exc})")
        was = {a["artifactId"]: len(a.get("evaluations") or [])
               for a in previous.get("artifacts", [])}
        # CARRY THE RUBRIC EQUIVALENCE FORWARD. It is not derivable from receipts —
        # it records a proven-score-neutral refactor of the scorer — so this template
        # would silently DELETE it, and the ratchet would lose its floor on the next
        # run with nothing said. Same class of loss the evaluation-count check below
        # exists to refuse, arriving through the template rather than the data.
        for key in ("_rubricEquivalence", "_rubricEquivalenceContract"):
            if key in previous:
                doc[key] = previous[key]

        # SETS, not lengths: a row added beside a row dropped nets out to the same
        # count, and an id is immutable, so a rename IS a drop plus an add.
        gone = sorted(set(was) - {r["artifactId"] for r in records})
        if gone:
            raise SystemExit(
                "REFUSED: this rebuild would DROP registered artifacts:\n  " +
                "\n  ".join(f"{aid}: {was[aid]} eval(s) on record" for aid in gone) +
                "\nAn artifact id is immutable and its history is not rebuilt from "
                "receipts. Restore the row under its original id, or say why the "
                "artifact leaves the record.")

        lost = [(r["artifactId"], was[r["artifactId"]], len(r["evaluations"]))
                for r in records
                if r["artifactId"] in was and len(r["evaluations"]) < was[r["artifactId"]]]
        if lost:
            raise SystemExit(
                "REFUSED: this rebuild would LOSE evaluations:\n  " +
                "\n  ".join(f"{aid}: {b} -> {a}" for aid, b, a in lost) +
                "\nSome receipts are missing. Restore them, or say why history shrinks.")

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False,
                                     encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
        staged = Path(fh.name)
    try:
        model_registry.load(staged)
    except model_registry.RegistryError as exc:
        staged.unlink()
        raise SystemExit(f"REFUSED: the registry this would write is invalid ({exc}). "
                         f"The existing file is untouched.")
    staged.replace(OUT)

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
