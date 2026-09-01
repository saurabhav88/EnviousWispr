#!/usr/bin/env python3
"""The EG-1 release gate: does this run clear the bar to ship.

WHY THIS IS ITS OWN MODULE, and it is not tidiness. `behavior_judge._rubric_identity()`
hashes `behavior_judge.py` IN ITS ENTIRETY, deliberately over-identifying so that any edit
which could change a SCORE mints a new rubric and forces a re-grade. The gate does not
score anything — it READS scores and decides. While it lived in that file, editing the bar
invalidated every stored score, so the bar could not be changed without discarding the
history it needs to read. Measured on 2026-08-31: the ratchet was built, minted rubric
`ce234dcb8cac`, and left the new gate with no comparable evaluation to draw a floor from,
which would have blocked every future run permanently. Codex caught it and it was reverted.

So the gate lives here, where it can change freely, and the scorer's identity covers only
scoring. The one-time identity change caused by removing this code from that file is
proven score-neutral by replaying every stored receipt through both versions — see
`docs/eval-policy/` and the replay harness; the judge's saved per-case verdicts make that
a measurement rather than a claim, at zero judge cost.

THE BAR IS A RATCHET, NOT AN ABSOLUTE (founder, 2026-08-31): *"the target is always to be
better than what the last ship's best score was... anything now moving forward should be
at 31 or lower."* Absolute zero was never met by anything we have released, so it blocked
every candidate identically and carried no information.
"""

from __future__ import annotations

import model_registry

REP_PASSRATE_DELTA_MAX = 5.0  # pp; wobble above this flags the run unreliable

# The bar we are ratcheting TOWARD. Reported, never enforced: enforcing it is what
# made the old gate uninformative, and deleting it would lose the target.
ASPIRATION_S4 = 0

# A ratchet with no floor yet cannot judge quality, and the first draft of this
# module let that N/A mean "not blocking" — so a run scoring S4 on EVERY case
# reported INCOMPLETE rather than BLOCK. The harness's own suite caught it
# (`test_quality_fail_plus_gap_blocks_and_is_not_cacheable`). That is the exact
# mirror of the defect this module exists to fix: the first ratchet failed CLOSED
# forever, this one failed OPEN. Neither is acceptable, so the catastrophe bar is
# always armed and is independent of the floor.
#
# 25% is not a taste: across all 71 evaluations on record the WORST S4 rate ever
# measured is 13.7% (eg1-1.2-c001 on tail_corpus.jsonl, 16/117), the median is
# 4.4% and the best is 0.4%. 25% is comfortably above every real run — including
# every REJECTED one — so it cannot block ordinary work, and it is far below the
# 100% the suite's catastrophe case produces. Re-derive it from the registry
# rather than adjusting it by feel:
#   python3 scripts/eval/model_registry.py list
CATASTROPHE_S4_RATE_PCT = 25.0


def s4_floor(ratchet_ctx: dict | None) -> tuple[int | None, str, bool]:
    """The S4 count this run must not exceed, where it came from, and whether the
    ABSENCE of a floor is an ordinary state or a broken instrument.

    THREE-VALUED, because collapsing the third value is the defect cloud review
    found on PR #2576. "No comparable evaluation yet" and "the registry could not
    be read" both produce no floor, and the first version reported both as N/A.
    A run with 32 S4 against a recorded floor of 31 then read CLEAR — over the bar,
    under the 25% catastrophe ceiling, and passed — because a malformed registry
    silently disarmed the only check that would have caught it.

    So: no comparable evaluation is N/A and never blocks, since a gate that blocks
    for want of a comparator blocks forever (the defect that got the first ratchet
    reverted). A registry that cannot be READ is a broken instrument and BLOCKS,
    because an instrument failure must never be reported as a passing quality check.
    """
    if not ratchet_ctx:
        return None, "no ratchet context supplied by the caller", False
    if ratchet_ctx.get("blind") is None:
        return None, ("the run did not report whether the judge was blinded, and blind "
                      "and sighted grading are not comparable (122 of 472 verdicts "
                      "moved when the judge saw the key)"), False
    missing = [k for k in ("corpus", "rubric", "judge", "cases", "system",
                          "adjudication")
               if ratchet_ctx.get(k) in (None, "")]
    if missing:
        # A run scored from external verdicts has no rubric identity by design,
        # so this is an ordinary state, not an error.
        return None, f"run lacks {', '.join(missing)}, so no comparable set exists", False
    try:
        count, source = model_registry.floor(
            ratchet_ctx["corpus"], ratchet_ctx["rubric"],
            ratchet_ctx["judge"], ratchet_ctx["cases"],
            system=ratchet_ctx["system"],
            # `blind` is a BOOLEAN, so it must never join the `missing` check above:
            # False is a legitimate value and `in (None, "")` would be fine, but an
            # absent key and an explicit False must not be conflated either. Default
            # to the SIGHTED reading only when the caller says so; a caller that does
            # not know passes None and gets no floor rather than a wrong one.
            blind=bool(ratchet_ctx.get("blind")),
            adjudication=ratchet_ctx.get("adjudication"))
        return count, source, False
    except Exception as exc:  # noqa: BLE001 - any registry failure is an INSTRUMENT failure
        return None, f"registry unreadable: {type(exc).__name__}: {exc}", True


def evaluate_new_gate(overall, smoke, traps, wobble, pairwise, has_production,
                      missing_count=0, skipped_count=0,
                      adjudication_missing_count=0, ratchet_ctx=None,
                      cases_scored=None) -> dict:
    """Apply the release gate. Three-valued verdict:
      BLOCK      — a quality check FAILED (S4 / wobble / pairwise).
      INCOMPLETE — quality clean but the run did not cover every case (engine
                   skips or judge-dropped scores); re-run the gaps, do not ship.
      CLEAR      — quality clean AND full coverage.
    Conditions needing a production baseline are reported N/A, never silently
    passed. Completeness is tracked separately from quality so the founder can
    tell 'just re-run the missing cases' from 'real quality failure'."""
    quality_checks = []

    def add(name, ok, detail):
        quality_checks.append({"check": name, "status": "PASS" if ok else "FAIL", "detail": detail})

    def na(name, detail):
        quality_checks.append({"check": name, "status": "N/A", "detail": detail})

    add("critical_smoke_no_s4", smoke["s4_count"] == 0,
        f"{smoke['s4_count']} S4 in {smoke['n']} critical-smoke cases (limit 0)")

    observed = overall["critical_fail_count"]
    floor, source, broken = s4_floor(ratchet_ctx)
    if broken:
        # FAIL, not N/A. The bar may well be exceeded and we cannot tell; reporting
        # that as a passing check is how a regression ships on a filesystem error.
        add("full_corpus_s4_ratchet", False,
            f"{observed} S4 across full corpus, but the floor could not be read, so this "
            f"run CANNOT be cleared on quality — {source}")
    elif floor is None:
        na("full_corpus_s4_ratchet",
           f"{observed} S4 across full corpus; no floor to compare against — {source}")
    else:
        add("full_corpus_s4_ratchet", observed <= floor,
            f"{observed} S4 across full corpus (must be <= {floor}, our best on record, "
            f"from {source})")
    # ALWAYS armed, floor or no floor. Without it an absent floor means no S4 check
    # of any kind, which is how a total failure reads as merely INCOMPLETE.
    denom = cases_scored if cases_scored else (ratchet_ctx or {}).get("cases")
    if denom:
        rate = 100.0 * observed / denom
        add("full_corpus_s4_catastrophe", rate <= CATASTROPHE_S4_RATE_PCT,
            f"{observed}/{denom} = {rate:.1f}% S4 (hard ceiling {CATASTROPHE_S4_RATE_PCT}%, "
            f"set above the worst 13.7% ever recorded)")
    else:
        na("full_corpus_s4_catastrophe",
           f"{observed} S4 but the case count was not supplied, so no rate exists")

    # Reported so the target stays visible without blocking on it. Deliberately
    # outside `quality_checks`: it has never once been met, so a FAIL here would
    # make every verdict BLOCK and the gate would carry no information at all.
    aspiration = {"check": "full_corpus_no_s4_aspiration",
                  "status": "MET" if observed <= ASPIRATION_S4 else "NOT_MET",
                  "detail": f"{observed} S4 against the standing goal of {ASPIRATION_S4}; "
                            f"informational, never blocking"}

    if wobble.get("unreliable") is not None:
        add("judge_stable", not wobble["unreliable"],
            f"rep pass-rate delta {wobble.get('delta_pp')}pp (limit {REP_PASSRATE_DELTA_MAX}pp)")
    if has_production:
        add("critical_smoke_no_critical_loss", smoke["critical_loss_count"] == 0,
            f"{smoke['critical_loss_count']} critical_loss in critical-smoke (limit 0)")
        add("pairwise_net_positive", pairwise.get("net_wins", 0) > 0,
            f"net wins {pairwise.get('net_wins')} (must be > 0)")
    else:
        quality_checks.append({"check": "pairwise_vs_production", "status": "N/A",
                               "detail": "no --production baseline supplied"})

    # An adjudication drop is a COVERAGE gap, not a quality failure: routing it
    # into `quality_checks` would report BLOCK and tell the reader a transient
    # judge omission was a quality regression. This gate's own contract keeps the
    # two separate so "re-run the gaps" is distinguishable from "real failure".
    complete = (missing_count == 0 and skipped_count == 0
                and adjudication_missing_count == 0)
    completeness = {"check": "run_complete", "status": "PASS" if complete else "INCOMPLETE",
                    "detail": f"{skipped_count} engine-skipped, {missing_count} judge-dropped, "
                              f"{adjudication_missing_count} adjudication-dropped "
                              f"(all must be 0 to ship; re-run the gaps)"}

    blocking = [c for c in quality_checks if c["status"] == "FAIL"]
    if blocking:
        verdict = "BLOCK"
    elif not complete:
        verdict = "INCOMPLETE"
    else:
        verdict = "CLEAR"
    return {
        "verdict": verdict,
        "run_complete": complete,
        "checks": quality_checks + [aspiration, completeness],
        "s4_floor": floor,
        "s4_floor_source": source,
        "s4_floor_unreadable": broken,
        "note": ("Behavior-regression, trap-regression and mixed-regression checks "
                 "require a prior run to diff against; run two builds to enable them."),
    }
