#!/usr/bin/env python3
"""Self-tests for the judge-receipt completeness contract (#2007, #2008).

WHAT THIS LOCKS. A judge run that dropped work must never read as a complete
receipt. Three layers have to agree on that: `behavior_judge.py` must detect the
gap and say so in the receipt, `judge_ollama_bench.sh` must refuse to cache a
partial receipt, and `report_ollama_bench.py` must refuse to rank one.

Pure stdlib, no pytest, no network, no judge calls. Run:
    python3 scripts/eval/behavior_judge_test.py

TWO STUB LAYERS, BOTH CHOSEN SO THE TEST REACHES ITS SUBJECT.

  * Python cases patch `judge_chunk`, NOT `run_judge`. Reconciliation lives
    INSIDE `run_judge`, so a stub there would bypass the boundary under test and
    the case would pass having executed none of the code it names. Patching one
    layer down keeps the real `run_judge`, its threading, and its reconciliation
    in the path. Verified: the lower stub reproduces every pre-fix defect
    identically with the real `run_judge` running.

  * Every score case then calls the real `write_outputs`, because `cacheable` is
    set by `finalize_new_report` from inside it — `score_new` never sets that
    key, so asserting it off `score_new`'s return would assert a key that does
    not exist.

  * Shell cases `cp` the real `judge_ollama_bench.sh` into a temp tree rather
    than reimplementing it; the script derives ROOT from its own location, which
    is what lets a stub judge be substituted. The stub logs every invocation so
    "was it re-judged" is a COUNT — a marker file alone lets a second run pass
    without invoking anything.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "eval"))

import behavior_judge as bj  # noqa: E402

SHELL = ROOT / "scripts" / "eval" / "judge_ollama_bench.sh"
REPORT = ROOT / "scripts" / "eval" / "report_ollama_bench.py"


# --------------------------------------------------------------------------- #
# fixtures                                                                    #
# --------------------------------------------------------------------------- #

def corpus(n=12):
    norm, cands = {}, {}
    for i in range(n):
        cid = f"C{i:02d}"
        norm[cid] = bj.normalize_case({
            "id": cid, "behavior": "grammar_fix",
            "asr_input": f"this is case {i} what a test",
            "expected_output": f"This is case {i}. What a test."})
        cands[cid] = {"candidate": f"This is case {i}. What a test.", "latencyMs": 10}
    return norm, cands


def score(cid, verdict="pass", sev="S0"):
    return {"id": cid, "verdict": verdict, "severity": sev, "behavior_correct": True,
            "clean_output": True, "meaning_preserved": True, "failure_types": [],
            "changed_or_missing_content": [], "pairwise_vs_production": "not_available"}


def run_score_new(primary_items=None, adj_items=None, n=12, **kw):
    """Real `score_new` + real `write_outputs`, with `judge_chunk` stubbed.

    Returns the receipt AS WRITTEN, not the in-memory report: `write_outputs`
    mutates it (pops `per_case`, fills `infra_skipped`), so asserting on the dict
    afterwards would assert on a different object than a consumer reads.
    """
    norm, cands = corpus(n)
    passes = {"n": 0}
    real = bj.judge_chunk

    def stub(model, system, payload_cases, attempt=1):
        ids = [str(c["id"]) for c in payload_cases]
        passes["n"] += 1
        if passes["n"] == 1:
            return [score(c) for c in ids] if primary_items is None else primary_items(ids)
        return [] if adj_items is None else adj_items(ids)

    bj.judge_chunk = stub
    try:
        report = bj.score_new(norm, cands, None, "stub-judge", 50, None, **kw)
    finally:
        bj.judge_chunk = real

    with tempfile.TemporaryDirectory() as td:
        bj.write_outputs(report, Path(td), "new")
        return json.loads((Path(td) / "summary.json").read_text())


def checks_of(receipt):
    return {c["check"]: c["status"] for c in receipt["release_gate"]["checks"]}


STUB_JUDGE = '''\
import sys, json, pathlib
a = sys.argv
out = a[a.index("--out") + 1]
d = pathlib.Path(out); d.mkdir(parents=True, exist_ok=True)
(d.parent / "_invocations").open("a").write("call\\n")
mode = {mode!r}
if mode == "noreceipt":
    sys.exit(1)
if mode == "nonobject":
    (d / "summary.json").write_text("[1,2,3]")
    sys.exit(1)
if mode == "badjson":
    (d / "summary.json").write_text("{{not json")
    sys.exit(1)
r = {{"release_gate": {{"verdict": "BLOCK"}}, "skipped": [], "missing_scores": []}}
if mode == "true":
    r["cacheable"] = True
elif mode == "false":
    r["cacheable"] = False
json.dump(r, open(d / "summary.json", "w"))
sys.exit(0 if mode == "true" else 1)
'''


def shell_tree(mode):
    """A temp ROOT holding a byte copy of the real script plus a stub judge."""
    t = Path(tempfile.mkdtemp())
    (t / "scripts" / "eval").mkdir(parents=True)
    (t / "cand").mkdir()
    (t / "judged").mkdir()
    (t / "scripts" / "eval" / "judge_ollama_bench.sh").write_bytes(SHELL.read_bytes())
    (t / "scripts" / "eval" / "behavior_judge.py").write_text(STUB_JUDGE.format(mode=mode))
    (t / "cand" / "modelA.jsonl").write_text('{"id":"A","candidate":"x"}\n')
    (t / "corpus.jsonl").write_text('{"id":"A"}\n')
    return t


def run_shell(t, env=None):
    p = subprocess.run(
        ["bash", str(t / "scripts" / "eval" / "judge_ollama_bench.sh"),
         str(t / "corpus.jsonl"), str(t / "cand"), str(t / "judged")],
        capture_output=True, text=True, env=env)
    return p.returncode, p.stdout + p.stderr


def invocations(t):
    f = t / "judged" / "_invocations"
    return len(f.read_text().splitlines()) if f.exists() else 0


def stamped(t):
    return (t / "judged" / "modelA" / ".inputs-sha256").exists()


def forge_stamp(t):
    """Write a stamp that genuinely MATCHES, so the resume fast path is entered
    and only the cacheability check can stop the skip. Computed exactly as the
    script does — over the same absolute argv paths, since the hash covers
    filenames. Without it the stamp is absent, the fast path is never reached,
    and a case would pass while testing the stale-inputs branch instead."""
    forged = subprocess.run(
        ["bash", "-c",
         'if command -v shasum >/dev/null 2>&1; then H="shasum -a 256"; else H=sha256sum; fi; '
         f'$H "{t / "cand" / "modelA.jsonl"}" "{t / "corpus.jsonl"}" | $H | cut -d" " -f1'],
        capture_output=True, text=True).stdout.strip()
    assert forged, "could not compute a stamp"
    (t / "judged" / "modelA" / ".inputs-sha256").write_text(forged + "\n")
    return forged


def report_tree(receipt, per_case_rows=None):
    """Fixtures for report_ollama_bench.py with a caller-chosen receipt."""
    t = Path(tempfile.mkdtemp())
    (t / "judged" / "modelA").mkdir(parents=True)
    (t / "corpus.jsonl").write_text(
        '{"id":"EN-1","input_source":"generated","asr_input":"a","expected_output":"A."}\n'
        '{"id":"INT-1","input_source":"hand_written_international","asr_input":"b","expected_output":"B."}\n')
    (t / "run-summary.json").write_text(json.dumps({"corpus": "corpus.jsonl", "models": [{
        "model": "modelA", "candidates": str(t / "cand" / "modelA.jsonl"), "isRemote": False,
        "thinks": False, "thinkSent": False, "parameterSize": "4B", "quantization": "Q4",
        "errors": 0, "cases": 2, "latencyMsMedian": 100, "latencyMsMean": 100,
        "latencyMsMax": 100, "overDeadline": 0, "warm": ""}]}))
    (t / "judged" / "modelA" / "summary.json").write_text(json.dumps(receipt))
    rows = per_case_rows if per_case_rows is not None else [
        {"id": "EN-1", "verdict": "pass", "severity": "S0", "behavior": "grammar_fix", "failure_types": []},
        {"id": "INT-1", "verdict": "pass", "severity": "S0", "behavior": "language_preservation", "failure_types": []}]
    (t / "judged" / "modelA" / "per_case.jsonl").write_text(
        "".join(json.dumps(r) + "\n" for r in rows))
    return t


def healthy_receipt(**over):
    r = {"release_gate": {"verdict": "CLEAR", "checks": []}, "cacheable": True,
         "run_complete": True, "skipped": [], "missing_scores": [],
         "adjudication": {"adjudication_missing_n": 0},
         "overall": {"total_scored": 2, "infra_skipped": 0, "pass_rate_pct": 100.0,
                     "critical_fail_count": 0, "severity_breakdown": {"S0": 2},
                     "failure_type_counts": {}}}
    r.update(over)
    return r


def run_report(t):
    p = subprocess.run(
        [sys.executable, str(REPORT), "--run-summaries", str(t / "run-summary.json"),
         "--judged", str(t / "judged"), "--corpus", str(t / "corpus.jsonl"),
         "--out", str(t / "report.md")],
        capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


# --------------------------------------------------------------------------- #
# the reconciliation boundary                                                 #
# --------------------------------------------------------------------------- #

def test_reconcile_accepted_follows_requested_order():
    b = bj.reconcile_judge_batch({"B": {"id": "B"}, "A": {"id": "A"}}, ["A", "B"])
    assert list(b.accepted) == ["A", "B"], b.accepted


def test_reconcile_reports_missing():
    b = bj.reconcile_judge_batch({"A": {"id": "A"}}, ["A", "B", "C"])
    assert b.missing == ["B", "C"], b.missing


def test_reconcile_reports_unexpected():
    b = bj.reconcile_judge_batch({"A": {"id": "A"}, "Z": {"id": "Z"}}, ["A"])
    assert b.unexpected == ["Z"], b.unexpected
    assert "Z" not in b.accepted


def test_reconcile_dedupes_requested():
    b = bj.reconcile_judge_batch({"A": {"id": "A"}}, ["A", "A", "B", "B"])
    assert list(b.accepted) == ["A"] and b.missing == ["B"], (b.accepted, b.missing)


# --------------------------------------------------------------------------- #
# an adjudication gap makes the run incomplete                                #
# --------------------------------------------------------------------------- #

def test_empty_adjudication_is_incomplete():
    r = run_score_new(adj_items=lambda ids: [])
    assert r["release_gate"]["verdict"] == "INCOMPLETE", r["release_gate"]["verdict"]
    assert r["run_complete"] is False


def test_empty_adjudication_is_not_cacheable():
    assert run_score_new(adj_items=lambda ids: [])["cacheable"] is False


def test_empty_adjudication_omits_judge_stable():
    # The defect: delta 0.0 over zero compared cases was reported as PASS.
    # Absent is correct — completeness is what refuses the run, not quality.
    r = run_score_new(adj_items=lambda ids: [])
    assert "judge_stable" not in checks_of(r), checks_of(r)
    assert r["wobble"]["common_n"] == 0


def test_empty_adjudication_counts_every_selected_case_as_dropped():
    a = run_score_new(adj_items=lambda ids: [])["adjudication"]
    assert a["rejudged_n"] == 0
    assert a["adjudication_missing_n"] == a["adjudicated_n"] > 0, a


def test_partial_adjudication_is_incomplete():
    r = run_score_new(adj_items=lambda ids: [score(c) for c in ids[: len(ids) // 2]])
    assert r["release_gate"]["verdict"] == "INCOMPLETE"
    assert r["cacheable"] is False


def test_partial_adjudication_compares_only_returned_cases():
    r = run_score_new(adj_items=lambda ids: [score(c) for c in ids[: len(ids) // 2]])
    a = r["adjudication"]
    assert r["wobble"]["common_n"] == a["rejudged_n"] < a["adjudicated_n"], (r["wobble"], a)


# --------------------------------------------------------------------------- #
# two-way controls: a COMPLETE run must still behave                          #
# --------------------------------------------------------------------------- #

def test_full_agreeing_adjudication_is_clear_and_cacheable():
    # Without this, an implementation that marks EVERYTHING incomplete passes
    # every case above.
    r = run_score_new(adj_items=lambda ids: [score(c) for c in ids])
    assert r["release_gate"]["verdict"] == "CLEAR", r["release_gate"]["verdict"]
    assert r["cacheable"] is True and r["run_complete"] is True


def test_full_agreeing_adjudication_judge_stable_passes():
    r = run_score_new(adj_items=lambda ids: [score(c) for c in ids])
    assert checks_of(r).get("judge_stable") == "PASS", checks_of(r)
    assert r["wobble"]["delta_pp"] == 0.0


def test_full_agreeing_adjudication_rejudged_equals_selected():
    a = run_score_new(adj_items=lambda ids: [score(c) for c in ids])["adjudication"]
    assert a["rejudged_n"] == a["adjudicated_n"] and a["adjudication_missing_n"] == 0, a


# --------------------------------------------------------------------------- #
# the wobble comparison must see real disagreement                            #
# --------------------------------------------------------------------------- #

def test_total_disagreement_fails_judge_stable():
    # Pre-fix this reported delta_pp 0.0 and judge_stable PASS, because rep1 was
    # the POST-merge primary and the merge had already adopted adjudication's
    # worse score — so the two reps were identical by construction.
    r = run_score_new(adj_items=lambda ids: [score(c, "major_fail", "S3") for c in ids])
    assert checks_of(r).get("judge_stable") == "FAIL", checks_of(r)
    assert r["wobble"]["delta_pp"] > 0.0, r["wobble"]


def test_total_disagreement_blocks_but_stays_cacheable():
    # A failing quality check blocks; coverage was still COMPLETE, so the receipt
    # is a finished answer and must remain cacheable. Re-judging a BLOCK forever
    # is #2008 inverted.
    r = run_score_new(adj_items=lambda ids: [score(c, "major_fail", "S3") for c in ids])
    assert r["release_gate"]["verdict"] == "BLOCK", r["release_gate"]["verdict"]
    assert r["run_complete"] is True and r["cacheable"] is True


def test_disagreement_resolves_to_the_worse_score():
    r = run_score_new(adj_items=lambda ids: [score(c, "major_fail", "S3") for c in ids])
    assert r["overall"]["verdict_breakdown"] == {"major_fail": 12}, r["overall"]
    assert r["adjudication"]["disagreement_n"] == 12


# --------------------------------------------------------------------------- #
# stray ids, primary drops, and the modes that have no adjudication           #
# --------------------------------------------------------------------------- #

def test_stray_adjudication_id_is_excluded_and_counted():
    def adj(ids):
        return [score(c) for c in ids] + [score("NOT-A-REAL-ID")]
    a = run_score_new(adj_items=adj)["adjudication"]
    assert a["unexpected_n"] == 1, a
    assert a["rejudged_n"] == a["adjudicated_n"], a


def test_primary_drop_is_still_reported():
    r = run_score_new(primary_items=lambda ids: [score(c) for c in ids[:-2]],
                      adj_items=lambda ids: [score(c) for c in ids])
    assert len(r["missing_scores"]) == 2, r["missing_scores"]
    assert r["release_gate"]["verdict"] == "INCOMPLETE"
    assert r["cacheable"] is False


def test_engine_errors_are_incomplete_but_still_cacheable():
    """An engine error is terminal, so its receipt is a FINISHED answer.

    Whole-diff review P2: making a receipt non-cacheable on engine skips put the
    benchmark in an endless re-judge loop — judging cannot repair a model that
    produced nothing to grade — and made `report_ollama_bench.py`'s deliberate
    "a partial failure IS evidence" ranking unreachable. Only DROPPED JUDGE WORK
    makes a receipt provisional.
    """
    norm, cands = corpus(6)
    cands["C00"] = {"error": "connection refused", "candidate": ""}   # engine failure
    real = bj.judge_chunk
    bj.judge_chunk = lambda m, s, cs, attempt=1: [score(str(c["id"])) for c in cs]
    try:
        report = bj.score_new(norm, cands, None, "stub", 50, None)
    finally:
        bj.judge_chunk = real
    with tempfile.TemporaryDirectory() as td:
        bj.write_outputs(report, Path(td), "new")
        r = json.loads((Path(td) / "summary.json").read_text())

    assert len(r["skipped"]) == 1, r["skipped"]
    assert r["run_complete"] is False, "coverage genuinely is incomplete"
    assert r["release_gate"]["verdict"] == "INCOMPLETE", r["release_gate"]["verdict"]
    assert r["cacheable"] is True, \
        "an engine error is terminal — re-judging cannot fix it, so the receipt must cache"


def test_report_accepts_an_incomplete_but_cacheable_receipt():
    """The other half of the P2: `INCOMPLETE` must not be refused outright.

    Scope, stated precisely rather than overclaimed: this proves the receipt
    reaches ranking at all. It does NOT assert the tier, because that is decided
    from the RUN summary's own error count, not from this receipt — asserting
    "Not recommended" here would need a fixture satisfying the report's separate
    scored/skipped reconciliation, which is a different contract.
    """
    # The fixture must carry `error` and a matching run error count, because that
    # is what the runner really writes. An earlier version of this fixture omitted
    # `error` — thinner than production — and the per-entry attribution check
    # correctly refused it. Fix the fixture, never the check.
    t = _errors_tree(healthy_receipt(cacheable=True, run_complete=False,
                                     release_gate={"verdict": "INCOMPLETE", "checks": []}),
                     cases=3, errors=1, scored=2, infra_skipped=1,
                     skipped_reason="engine error")
    rc, out = run_report(t)
    assert rc == 0, out
    # And the complement: a judge-dropped receipt is still refused, so admitting
    # INCOMPLETE did not open a hole.
    t2 = report_tree(healthy_receipt(
        cacheable=False, run_complete=False,
        release_gate={"verdict": "INCOMPLETE", "checks": []},
        missing_scores=["C1", "C2"]))
    rc2, out2 = run_report(t2)
    assert rc2 == 2, out2


def test_no_adjudicate_invents_no_gap():
    r = run_score_new(adj_items=lambda ids: [], adjudicate=False)
    assert r["release_gate"]["verdict"] == "CLEAR", r["release_gate"]["verdict"]
    assert r["cacheable"] is True
    a = r["adjudication"]
    assert a["adjudicated_n"] == a["rejudged_n"] == a["adjudication_missing_n"] == 0, a


def test_external_verdicts_invent_no_gap():
    norm, cands = corpus(6)
    ext = {cid: score(cid) for cid in norm}
    report = bj.score_new(norm, cands, None, "unused", 50, ext)
    with tempfile.TemporaryDirectory() as td:
        bj.write_outputs(report, Path(td), "new")
        r = json.loads((Path(td) / "summary.json").read_text())
    assert r["release_gate"]["verdict"] == "CLEAR", r["release_gate"]["verdict"]
    assert r["cacheable"] is True
    assert r["judge_reconciliation"]["adjudication"]["requested_n"] == 0


# --------------------------------------------------------------------------- #
# the gate term, in isolation                                                 #
# --------------------------------------------------------------------------- #

def _gate(**kw):
    overall = {"critical_fail_count": 0}
    smoke = {"s4_count": 0, "n": 0, "critical_loss_count": 0}
    return bj.evaluate_new_gate(overall, smoke, {}, {"status": "single"}, {},
                                False, **kw)


def test_gate_adjudication_gap_alone_flips_clear_to_incomplete():
    assert _gate()["verdict"] == "CLEAR"
    assert _gate(adjudication_missing_count=1)["verdict"] == "INCOMPLETE"


def test_gate_adjudication_gap_never_blocks():
    g = _gate(adjudication_missing_count=5)
    assert g["verdict"] != "BLOCK", g
    assert g["run_complete"] is False
    assert [c for c in g["checks"] if c["check"] == "run_complete"][0]["status"] == "INCOMPLETE"


def test_gate_reports_all_three_gap_kinds_in_its_detail():
    detail = [c for c in _gate(missing_count=1, skipped_count=2,
                               adjudication_missing_count=3)["checks"]
              if c["check"] == "run_complete"][0]["detail"]
    for want in ("2 engine-skipped", "1 judge-dropped", "3 adjudication-dropped"):
        assert want in detail, (want, detail)


def test_quality_fail_plus_gap_blocks_and_is_not_cacheable():
    # BLOCK outranks INCOMPLETE, which is exactly why cacheability cannot be
    # inferred from the verdict. This is the case the first fix would have
    # stamped as a complete gate-failure.
    r = run_score_new(primary_items=lambda ids: [score(c, "critical_fail", "S4") for c in ids],
                      adj_items=lambda ids: [])
    assert r["release_gate"]["verdict"] == "BLOCK", r["release_gate"]["verdict"]
    assert r["run_complete"] is False and r["cacheable"] is False


# --------------------------------------------------------------------------- #
# the finalizer                                                               #
# --------------------------------------------------------------------------- #

def test_finalizer_rejects_a_rowcount_mismatch_without_touching_the_verdict():
    norm, cands = corpus(6)
    real = bj.judge_chunk
    bj.judge_chunk = lambda m, s, cs, attempt=1: [score(str(c["id"])) for c in cs]
    try:
        report = bj.score_new(norm, cands, None, "stub", 50, None, adjudicate=False)
    finally:
        bj.judge_chunk = real
    report["per_case"] = report["per_case"][:-1]          # truncate the detail rows
    before = report["release_gate"]["verdict"]
    bj.finalize_new_report(report)
    assert report["cacheable"] is False
    assert report["release_gate"]["verdict"] == before, "the finalizer must not rewrite the verdict"


def test_finalizer_fails_closed_on_missing_required_fields():
    for field in ("skipped", "per_case", "judge_reconciliation", "adjudication", "overall"):
        norm, cands = corpus(4)
        real = bj.judge_chunk
        bj.judge_chunk = lambda m, s, cs, attempt=1: [score(str(c["id"])) for c in cs]
        try:
            report = bj.score_new(norm, cands, None, "stub", 50, None, adjudicate=False)
        finally:
            bj.judge_chunk = real
        report.pop(field)
        bj.finalize_new_report(report)
        assert report["cacheable"] is False, f"absent {field} must fail closed, not default to empty"


# --------------------------------------------------------------------------- #
# the old system is unchanged                                                 #
# --------------------------------------------------------------------------- #

def test_score_old_still_drops_unreturned_ids_the_same_way():
    norm, cands = corpus(6)
    real = bj.judge_chunk

    def stub(model, system, payload_cases, attempt=1):
        ids = [str(c["id"]) for c in payload_cases]
        return [{"id": c, "accuracy": 3, "conciseness": 3, "fluency": 3,
                 "format": 3, "regression": 2} for c in ids[:-1]]

    bj.judge_chunk = stub
    try:
        report = bj.score_old(norm, cands, "stub", 1, 50)
    finally:
        bj.judge_chunk = real
    assert len(report["missing_scores"]) == 1, report["missing_scores"]
    assert report["overall"]["total_scored"] == 5, report["overall"]


# --------------------------------------------------------------------------- #
# the exit code                                                               #
# --------------------------------------------------------------------------- #

def _run_main(force_cacheable):
    """Drive the real `main()` end to end, forcing only the finalizer's answer.

    Behavioural, not a source grep: the point is what the PROCESS returns. A
    CLEAR verdict whose finalization failed must not exit 0, because every caller
    of this script reads that status.
    """
    t = Path(tempfile.mkdtemp())
    rows = [{"id": f"C{i}", "behavior": "grammar_fix", "asr_input": f"case {i} here",
             "expected_output": f"Case {i} here."} for i in range(4)]
    (t / "corpus.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
    (t / "cand.jsonl").write_text("".join(
        json.dumps({"id": r["id"], "candidate": r["expected_output"], "latencyMs": 5}) + "\n"
        for r in rows))

    real_chunk, real_final, real_argv = bj.judge_chunk, bj.finalize_new_report, sys.argv
    real_preflight = bj.preflight_judge

    def forced(report):
        real_final(report)
        report["cacheable"] = force_cacheable

    bj.judge_chunk = lambda m, s, cs, attempt=1: [score(str(c["id"])) for c in cs]
    bj.finalize_new_report = forced
    # `main()` runs `preflight_judge` BEFORE any scoring, and that calls the real
    # `call_claude` — stubbing `judge_chunk` does not prevent it. On a machine with
    # the Claude CLI logged in it silently succeeds; in CI there is no CLI, so it
    # does `sys.exit(2)` and takes the whole suite down. This test is about the
    # exit code, not about judge availability.
    bj.preflight_judge = lambda model: None
    sys.argv = ["behavior_judge.py", "--system", "new", "--corpus", str(t / "corpus.jsonl"),
                "--candidates", str(t / "cand.jsonl"), "--out", str(t / "out"),
                "--no-adjudicate"]
    try:
        rc = bj.main()
    finally:
        bj.judge_chunk, bj.finalize_new_report, sys.argv = real_chunk, real_final, real_argv
        bj.preflight_judge = real_preflight
    verdict = json.loads((t / "out" / "summary.json").read_text())["release_gate"]["verdict"]
    return rc, verdict


def test_main_does_not_require_a_judge_cli_to_be_installed():
    """CI has no Claude CLI, and `main()` preflights one before scoring.

    `preflight_judge` calls the real `call_claude` and does `sys.exit(2)` when it
    fails, so stubbing `judge_chunk` is not enough — and `SystemExit` is not an
    `Exception`, so an unstubbed preflight killed the whole suite mid-run with no
    summary. The `build-check` job caught this; no local run could, because this
    machine has the CLI logged in. This case locks the stub so the two exit-code
    tests keep working on a runner without it.
    """
    import inspect
    src = inspect.getsource(_run_main)
    assert "bj.preflight_judge = lambda" in src, \
        "main()-driving tests must stub preflight_judge or they exit 2 on a runner with no Claude CLI"
    assert "real_preflight" in src, "and must restore it afterwards"


def test_exit_zero_on_a_clear_and_cacheable_run():
    rc, verdict = _run_main(force_cacheable=True)
    assert verdict == "CLEAR" and rc == 0, (verdict, rc)


def test_exit_nonzero_when_clear_but_not_cacheable():
    rc, verdict = _run_main(force_cacheable=False)
    assert verdict == "CLEAR", f"the control needs a CLEAR verdict to be meaningful, got {verdict}"
    assert rc != 0, "a CLEAR run that finalization invalidated must not exit 0"


# --------------------------------------------------------------------------- #
# judge_ollama_bench.sh                                                       #
# --------------------------------------------------------------------------- #

def test_shell_refuses_to_stamp_a_not_cacheable_receipt():
    t = shell_tree("false")
    rc, out = run_shell(t)
    assert rc != 0, out
    assert not stamped(t), "a partial receipt must not be cached"
    assert "INCOMPLETE modelA" in out, out


def test_shell_resume_path_rejudges_a_stamped_not_cacheable_arm():
    # The already-poisoned-arm recovery case. The resume fast path used to
    # `continue` on a matching stamp without ever reading completeness, so every
    # arm this bug had already stamped stayed skipped forever.
    t = shell_tree("false")
    run_shell(t)
    d = t / "judged" / "modelA"
    d.mkdir(parents=True, exist_ok=True)
    receipt = d / "summary.json"
    if not receipt.exists():
        receipt.write_text(json.dumps({"cacheable": False, "release_gate": {"verdict": "BLOCK"}}))

    forge_stamp(t)

    # Control: prove the forged stamp really would have caused a skip. Flip the
    # receipt to cacheable and confirm the arm IS skipped.
    receipt.write_text(json.dumps({"cacheable": True, "release_gate": {"verdict": "BLOCK"}}))
    baseline = invocations(t)
    _, skip_log = run_shell(t)
    assert invocations(t) == baseline, \
        f"the forged stamp does not match, so this case proves nothing: {skip_log}"

    # Now the real assertion: same matching stamp, not-cacheable receipt.
    receipt.write_text(json.dumps({"cacheable": False, "release_gate": {"verdict": "BLOCK"}}))
    before = invocations(t)
    rc, log = run_shell(t)
    assert invocations(t) > before, f"the arm must be re-judged, not skipped: {log}"
    assert "not cacheable" in log, log


def test_shell_resume_names_a_pre_cacheable_receipt_separately():
    """Both cases are re-judged, so the CACHING behaviour is identical and only
    the reader is affected — which is the point. A stamped receipt written before
    #2007 has no acceptance field at all; calling that "not cacheable" sends the
    reader looking for gaps that were never recorded. Every arm of the shipped
    #1950 sweep is in exactly this state, so it is the message people will meet."""
    t = shell_tree("false")
    run_shell(t)
    d = t / "judged" / "modelA"
    d.mkdir(parents=True, exist_ok=True)
    forge_stamp(t)

    # Control: with the field present and false, the wording stays the old one.
    (d / "summary.json").write_text(json.dumps(
        {"cacheable": False, "release_gate": {"verdict": "BLOCK"}}))
    before = invocations(t)
    _, log_false = run_shell(t)
    assert invocations(t) > before, f"must re-judge: {log_false}"
    assert "not cacheable" in log_false, log_false
    assert "predates" not in log_false, log_false

    # The case under test: same matching stamp, field absent entirely.
    forge_stamp(t)
    (d / "summary.json").write_text(json.dumps({"release_gate": {"verdict": "BLOCK"}}))
    before = invocations(t)
    rc, log_absent = run_shell(t)
    assert invocations(t) > before, f"must re-judge: {log_absent}"
    assert "predates the cacheable field" in log_absent, log_absent


def test_shell_resume_does_not_call_a_corrupt_receipt_a_legacy_one():
    """Review r1 P2. A two-way "does it carry the field" test answers false for
    an unreadable file too, so a corrupt receipt was announced as "predates the
    cacheable field" — a message asserting a cause it never observed, which is
    the exact defect this pass exists to remove. Both still re-judge; only the
    diagnostic differs, and hiding corruption behind "this file is just old" is
    what sends the reader after the wrong thing."""
    t = shell_tree("false")
    run_shell(t)
    d = t / "judged" / "modelA"
    d.mkdir(parents=True, exist_ok=True)

    for label, body in (("malformed", b"{not json"), ("non-object", b"[1,2,3]"),
                        # Invalid UTF-8: raises UnicodeDecodeError, not
                        # JSONDecodeError, and an escaped exception exits 1 —
                        # which this caller maps to the LEGACY branch, so an
                        # undecodable file was announced as merely old.
                        ("undecodable", b'{"cacheable": "\xff\xfe"}')):
        forge_stamp(t)
        (d / "summary.json").write_bytes(body)
        before = invocations(t)
        _, log = run_shell(t)
        assert invocations(t) > before, f"{label} must re-judge: {log}"
        assert "unreadable or is not a JSON object" in log, f"{label}: {log}"
        assert "predates" not in log, f"{label} was mislabelled as legacy: {log}"


def test_shell_resume_names_an_unsupported_verdict_not_legacy():
    """Cloud review round 4. The shell classified only field-presence, so a
    hand-edited receipt with no `cacheable` was announced as "predates the
    cacheable field" — the same defect the report had, one layer over. The two
    layers must agree on precedence, or they describe the same file differently.

    Includes a non-object `release_gate`, because a bare `.get` there would raise
    instead of classifying, and a hand-edited file is where that shape lives."""
    t = shell_tree("false")
    run_shell(t)
    d = t / "judged" / "modelA"
    d.mkdir(parents=True, exist_ok=True)

    for label, receipt in (
        ("unsupported verdict", {"release_gate": {"verdict": "WEIRD"}}),
        ("absent verdict", {"release_gate": {}}),
        ("absent release_gate", {"foo": "bar"}),
        ("non-object release_gate", {"release_gate": ["bad"]}),
    ):
        forge_stamp(t)
        (d / "summary.json").write_text(json.dumps(receipt))
        before = invocations(t)
        _, log = run_shell(t)
        assert invocations(t) > before, f"{label} must re-judge: {log}"
        assert "verdict this gate cannot produce" in log, f"{label}: {log}"
        assert "predates" not in log, f"{label} mislabelled as legacy: {log}"


def test_shell_absent_cacheable_field_is_not_stamped():
    # Every receipt written before #2007 lacks the field.
    t = shell_tree("absent")
    rc, out = run_shell(t)
    assert not stamped(t), out
    assert rc != 0, out


def test_shell_stamps_a_complete_block_receipt_and_then_skips_it():
    # The two-way control. A graded-but-failed run IS complete; refusing to cache
    # it would re-judge every weak model forever.
    t = shell_tree("true")
    rc, out = run_shell(t)
    assert rc == 0, out
    assert stamped(t), out
    first = invocations(t)
    run_shell(t)
    assert invocations(t) == first, "a cacheable arm must not be re-judged"


def test_shell_malformed_receipts_all_fail_closed():
    for mode, want in (("nonobject", "not stamped"), ("badjson", "not stamped"),
                       ("noreceipt", "FAILED")):
        t = shell_tree(mode)
        rc, out = run_shell(t)
        assert rc != 0, (mode, out)
        assert not stamped(t), (mode, out)
        assert "Traceback" not in out, (mode, "a malformed receipt must not print a traceback")
        if want == "FAILED":
            assert "FAILED modelA" in out, (mode, out)


def test_shell_sha256_shim_produces_an_identical_stamp():
    # Both arms MUST run in the SAME tree: the hash covers `hash  filename`, so
    # two temp dirs differ for a reason unrelated to the shim.
    t = shell_tree("true")
    run_shell(t)
    with_shasum = (t / "judged" / "modelA" / ".inputs-sha256").read_text()
    subprocess.run(["rm", "-rf", str(t / "judged" / "modelA")], check=True)

    shim = Path(tempfile.mkdtemp())
    for cmd in ("python3", "grep", "basename", "dirname", "cat", "mkdir", "rm",
                "printf", "cut", "sha256sum", "bash", "sed", "ls", "env"):
        found = subprocess.run(["bash", "-c", f"command -v {cmd}"],
                               capture_output=True, text=True).stdout.strip()
        if found:
            os.symlink(found, shim / cmd)
    if not (shim / "sha256sum").exists():
        return  # no coreutils name available here; the shim's other arm is what ships
    env = dict(os.environ, PATH=str(shim))
    assert subprocess.run(["bash", "-c", "command -v shasum"], env=env,
                          capture_output=True).returncode != 0, "the shim must really hide shasum"
    run_shell(t, env=env)
    without = (t / "judged" / "modelA" / ".inputs-sha256").read_text()
    assert with_shasum == without, (with_shasum, without)


# --------------------------------------------------------------------------- #
# report_ollama_bench.py                                                      #
# --------------------------------------------------------------------------- #

def test_report_refuses_an_unknown_verdict():
    # Pre-fix this was ranked #1 and labelled "Recommended", exit 0.
    t = report_tree(healthy_receipt(release_gate={"verdict": "WEIRD_UNKNOWN", "checks": []}))
    rc, out = run_report(t)
    assert rc == 2, out
    # The receipt IS cacheable and its gap counts are all zero, so the generic
    # "not cacheable — 0, 0, 0" sentence described none of what is wrong. The
    # refusal now names the actual reason: this gate cannot emit that verdict.
    assert "cannot produce" in out, out
    assert "0 engine-skipped" not in out, out


def test_report_refuses_clear_but_not_cacheable():
    t = report_tree(healthy_receipt(cacheable=False))
    rc, out = run_report(t)
    assert rc == 2, out
    assert "not cacheable" in out, out


def test_report_refuses_an_unreadable_receipt_by_name():
    """#2019, folded in rather than deferred: shipping "a refusal names its own
    reason" while one input shape still produces a traceback would make that
    claim false. Pre-fix both corrupt shapes exit 1 through an unhandled
    exception, so the exit-code assertion alone fails without the guard."""
    t = report_tree(healthy_receipt())
    (t / "judged" / "modelA" / "summary.json").write_text("{not json")
    rc, out = run_report(t)
    assert rc == 2, out
    assert "judge receipt is unreadable" in out, out
    assert "modelA" in out, out
    assert "Traceback" not in out, out


def test_report_refuses_an_undecodable_receipt():
    """Cloud review P2, round 2: invalid UTF-8 raises UnicodeDecodeError, which a
    `json.JSONDecodeError`-only tuple misses entirely. Both are ValueError
    subclasses, so the guard catches the BASE rather than a list of names that
    can miss the next member — the axis I under-enumerated was exception TYPE,
    having already enumerated corrupt SHAPE."""
    t = report_tree(healthy_receipt())
    (t / "judged" / "modelA" / "summary.json").write_bytes(b'{"cacheable": "\xff\xfe"}')
    rc, out = run_report(t)
    assert rc == 2, out
    assert "judge receipt is unreadable" in out, out
    assert "UnicodeDecodeError" in out, out
    assert "Traceback" not in out, out


def test_report_refuses_an_undecodable_per_case_file():
    t = report_tree(healthy_receipt())
    (t / "judged" / "modelA" / "per_case.jsonl").write_bytes(b'{"id": "\xff\xfe"}\n')
    rc, out = run_report(t)
    assert rc == 2, out
    assert "per_case.jsonl is unreadable" in out, out
    assert "Traceback" not in out, out


def test_report_refuses_a_non_object_receipt_by_name():
    t = report_tree(healthy_receipt())
    (t / "judged" / "modelA" / "summary.json").write_text("[1,2,3]")
    rc, out = run_report(t)
    assert rc == 2, out
    assert "not an object" in out, out
    assert "Traceback" not in out, out


def test_report_refuses_an_unreadable_per_case_file():
    """Checked rather than assumed: a malformed per_case.jsonl crashed the same
    way, so it is the same class and belongs in the same change."""
    t = report_tree(healthy_receipt())
    (t / "judged" / "modelA" / "per_case.jsonl").write_text("{not json")
    rc, out = run_report(t)
    assert rc == 2, out
    assert "per_case.jsonl is unreadable" in out, out
    assert "Traceback" not in out, out


def test_report_refuses_a_non_object_per_case_row():
    """The guard is reachable: a `[1,2]` row parses fine and would reach the
    `.get`-calling split predicates, so this is a real path, not a formality."""
    t = report_tree(healthy_receipt(), per_case_rows=[{"id": "EN-1", "verdict": "pass",
                                                      "severity": "S0",
                                                      "behavior": "grammar_fix",
                                                      "failure_types": []}])
    p = t / "judged" / "modelA" / "per_case.jsonl"
    p.write_text(p.read_text() + "[1,2]\n")
    rc, out = run_report(t)
    assert rc == 2, out
    assert "row that is not an object" in out, out
    assert "Traceback" not in out, out


def test_report_survives_every_malformed_legacy_metadata_shape():
    """Cloud review round 4, and the point at which patching one cell per round
    stopped being the right move. `{"wobble": ["bad"]}` made a `.get` raise
    AttributeError, so the refusal path CRASHED while explaining why a receipt
    was untrusted — a refusal treating its own input as well-formed.

    Every one of these carries a VALID verdict, so precedence cannot save them;
    only the type-safe accessors can. Table-driven because the axis is "any JSON
    value in any legacy field", not a list of remembered examples."""
    # EVERY wobble row must also make `adjudication_missing_n` unusable, or the
    # `rep_coverage` read is never reached and the row proves nothing. My first
    # version of this table did not, and the mutation control caught it: reverting
    # the accessors to bare `.get` left all 66 tests green, because
    # `healthy_receipt` supplies a valid `adjudication_missing_n: 0` that
    # short-circuits the derivation. A table whose rows cannot enter the branch is
    # zero coverage wearing a passing badge.
    no_count = {"adjudicated_n": 20}  # deliberately omits adjudication_missing_n
    shapes = [
        {"adjudication": no_count, "wobble": ["bad"]},
        {"adjudication": no_count, "wobble": "bad"},
        {"adjudication": no_count, "wobble": 7},
        {"adjudication": no_count, "wobble": {"rep_coverage": "not a list"}},
        {"adjudication": no_count, "wobble": {"rep_coverage": [20, "seventeen"]}},
        {"adjudication": no_count, "wobble": {"rep_coverage": [20]}},
        {"adjudication": no_count, "wobble": {"rep_coverage": []}},
        {"adjudication": ["bad"], "wobble": {"rep_coverage": [20, 17]}},
        {"adjudication": "bad", "wobble": {"rep_coverage": [20, 17]}},
        {"adjudication": {"adjudicated_n": "twenty"}, "wobble": {"rep_coverage": [20, 17]}},
        {"adjudication": {"adjudication_missing_n": "seven"}},
        {"adjudication": {"adjudication_missing_n": True}},
        {"skipped": "not a list"},
        {"missing_scores": {"not": "a list"}},
        {"release_gate": ["bad"]},
    ]
    for shape in shapes:
        r = healthy_receipt(**shape)
        del r["cacheable"]
        t = report_tree(r)
        rc, out = run_report(t)
        assert rc == 2, f"{shape} -> rc={rc}: {out}"
        assert "Traceback" not in out, f"{shape} raised: {out}"
        assert "modelA" in out, f"{shape} did not name the model: {out}"


def test_report_classifies_a_hand_edited_receipt_before_reading_its_metadata():
    """The reviewer's exact example: an unsupported verdict AND malformed legacy
    metadata together. Classifying the verdict first means the crash-prone reads
    never run for the receipts most likely to break them."""
    r = healthy_receipt(release_gate={"verdict": "WEIRD"},
                        adjudication={"adjudicated_n": 1}, wobble=["bad"])
    del r["cacheable"]
    t = report_tree(r)
    rc, out = run_report(t)
    assert rc == 2, out
    assert "cannot produce" in out, out
    assert "Traceback" not in out, out


def test_report_recovers_a_legacy_adjudication_drop():
    """Review r2 P2, and an incomplete port of my own fix: I read a legacy
    receipt's `skipped` and `missing_scores` but let `adjudication_missing_n`
    default to zero, so a receipt whose own fields PROVE an adjudication drop was
    reported as recording no gaps. `rep_scores[1]` is the adjudication pass, so
    `rep_coverage[1]` is what it returned against `adjudicated_n` selected.

    The 16 shipped #1950 receipts all compute 0 here, so this case is the only
    thing standing between the recovery and a silent regression."""
    r = healthy_receipt(adjudication={"adjudicated_n": 20},
                        wobble={"common_n": 17, "rep_coverage": [20, 17]})
    del r["cacheable"]
    t = report_tree(r)
    rc, out = run_report(t)
    assert rc == 2, out
    assert "3 adjudication-dropped" in out, out
    assert "no gaps of its own" not in out, out


def test_report_claims_no_adjudication_drop_when_none_ran():
    """Two-way control for the recovery above. With no adjudication pass,
    `rep_coverage` has a single entry, so the difference is not computable and
    must read as zero rather than as `adjudicated_n` dropped."""
    r = healthy_receipt(adjudication={"adjudicated_n": 0},
                        wobble={"common_n": 0, "rep_coverage": [20]})
    del r["cacheable"]
    t = report_tree(r)
    rc, out = run_report(t)
    assert rc == 2, out
    assert "records no gaps of its own" in out, out


def test_report_prefers_the_verdict_problem_over_the_legacy_one():
    """Cloud review P2. A receipt can be BOTH legacy AND carry a verdict this
    gate cannot emit; checking field-absence first called it merely old and
    suppressed the stronger signal — and the advice differs, since "re-judge
    once" is wrong for a file that is not one of ours.

    Safe by measurement: all 16 shipped #1950 arms carry `BLOCK`, so no genuine
    legacy receipt is mislabelled by this precedence."""
    r = healthy_receipt(release_gate={"verdict": "WEIRD_UNKNOWN_VALUE", "checks": []})
    del r["cacheable"]
    t = report_tree(r)
    rc, out = run_report(t)
    assert rc == 2, out
    assert "cannot produce" in out, out
    assert "predates" not in out, out


def test_report_names_a_pre_cacheable_receipt_as_such():
    """Every one of the 16 real #1950 arms hits this branch, because no receipt
    written before #2007 carries the field. The old message printed three zero
    counts and refused anyway, which reads as "nothing is wrong, yet rejected"."""
    r = healthy_receipt()
    del r["cacheable"]
    t = report_tree(r)
    rc, out = run_report(t)
    assert rc == 2, out
    assert "predates the `cacheable` field" in out, out
    assert "records no gaps of its own" in out, out
    # The three-count string is the OTHER branch's sentence and must not appear:
    # printing "0 engine-skipped, 0 primary judge-dropped" here is the defect.
    assert "engine-skipped" not in out, out


def test_report_still_names_the_gaps_a_pre_cacheable_receipt_records():
    """A pre-field receipt lacks the ACCEPTANCE answer, not its gap record. Real
    data: llama3.2's #1950 receipt has no `cacheable` and four dropped
    international scores, so an unconditional "no gap is implied" would be false."""
    r = healthy_receipt(missing_scores=["INT-1", "INT-2", "INT-3", "INT-4"])
    del r["cacheable"]
    t = report_tree(r)
    rc, out = run_report(t)
    assert rc == 2, out
    assert "predates the `cacheable` field" in out, out
    assert "4 primary judge-dropped" in out, out
    assert "no gaps of its own" not in out, out


def test_report_names_the_adjudication_gap():
    t = report_tree(healthy_receipt(
        cacheable=False, run_complete=False,
        release_gate={"verdict": "INCOMPLETE", "checks": []},
        adjudication={"adjudication_missing_n": 7}))
    rc, out = run_report(t)
    assert rc == 2, out
    assert "7 adjudication-dropped" in out, out


def test_report_accepts_a_healthy_receipt():
    t = report_tree(healthy_receipt())
    rc, out = run_report(t)
    assert rc == 0, out


def _errors_tree(receipt, cases, errors, scored, infra_skipped, skipped_reason):
    """A report fixture where the RUN's counts and the RECEIPT's counts are set
    independently, which is the whole point: the two disagreeing is the defect."""
    t = report_tree(receipt)
    run = json.loads((t / "run-summary.json").read_text())
    run["models"][0]["cases"] = cases
    run["models"][0]["errors"] = errors
    (t / "run-summary.json").write_text(json.dumps(run))
    s = json.loads((t / "judged" / "modelA" / "summary.json").read_text())
    s["overall"]["total_scored"] = scored
    s["overall"]["infra_skipped"] = infra_skipped
    # `error` is what the report attributes a skip by, so the fixture must carry it
    # exactly as the runner would: set for a genuine engine error, ABSENT for an
    # empty-but-successful call.
    is_engine_error = skipped_reason == "engine error"
    s["skipped"] = [{"id": f"S{i}", "reason": skipped_reason,
                     **({"error": "connection refused"} if is_engine_error else {})}
                    for i in range(infra_skipped)]
    (t / "judged" / "modelA" / "summary.json").write_text(json.dumps(s))
    rows = [{"id": f"R{i}", "verdict": "pass", "severity": "S0",
             "behavior": "grammar_fix", "failure_types": []} for i in range(scored)]
    (t / "judged" / "modelA" / "per_case.jsonl").write_text(
        "".join(json.dumps(r) + "\n" for r in rows))
    return t


def test_report_accepts_a_run_with_engine_errors():
    """Round-2 P2: `scored + infra_skipped` was compared against `cases - errors`.

    20 cases with 1 engine error gives `19 + 1` vs `19` — a run that can NEVER
    reconcile. Unreachable while INCOMPLETE was refused outright; exposed the
    moment engine-error receipts became rankable.
    """
    t = _errors_tree(healthy_receipt(cacheable=True, run_complete=False,
                                     release_gate={"verdict": "INCOMPLETE", "checks": []}),
                     cases=20, errors=1, scored=19, infra_skipped=1,
                     skipped_reason="engine error")
    rc, out = run_report(t)
    assert rc == 0, out


def test_report_refuses_empty_output_that_the_run_called_a_success():
    """Round-2 P1: the cause the run's error count cannot see.

    `run_ollama_bench.py` increments `errors` only inside `except`, so a 200
    returning an empty string is skipped by the judge and counted as a success by
    the runner. Reconciliation passed and `tier()` could then label the model
    Recommended on the 19 cases that did produce text.
    """
    t = _errors_tree(healthy_receipt(cacheable=True, run_complete=False,
                                     release_gate={"verdict": "INCOMPLETE", "checks": []}),
                     cases=20, errors=0, scored=19, infra_skipped=1,
                     skipped_reason="empty candidate on a successful call (no error reported)")
    rc, out = run_report(t)
    assert rc == 2, out
    assert "successful call" in out, out
    assert "Recommended" not in out, "it must not be ranked at all"


def test_report_refuses_a_skip_that_does_not_correspond_to_the_error():
    """Cloud review P2: a COUNT match is not an identity check.

    `errors=1` with one skip that is an empty-but-successful candidate satisfies
    `1 == 1` while the skip does not correspond to the error at all — so the model
    would be ranked on a mismatched subset. Attribution is checked per entry.
    """
    t = _errors_tree(healthy_receipt(cacheable=True, run_complete=False,
                                     release_gate={"verdict": "INCOMPLETE", "checks": []}),
                     cases=20, errors=1, scored=19, infra_skipped=1,
                     skipped_reason="empty candidate on a successful call (no error reported)")
    rc, out = run_report(t)
    assert rc == 2, out
    assert "carry no engine error" in out, out


def test_report_refuses_more_error_skips_than_the_run_recorded():
    """The count half of the attribution check, which per-entry attribution alone
    cannot cover: every skip carries an engine error, but there are MORE of them
    than the run recorded. That means the candidates file and the run summary
    disagree about how many requests failed."""
    t = _errors_tree(healthy_receipt(cacheable=True, run_complete=False,
                                     release_gate={"verdict": "INCOMPLETE", "checks": []}),
                     cases=20, errors=1, scored=18, infra_skipped=2,
                     skipped_reason="engine error")
    rc, out = run_report(t)
    assert rc == 2, out
    assert "2 judge skip(s) against 1 run error(s)" in out, out


def test_report_reconciles_a_clean_run():
    # Two-way control: without it, "refuse whenever anything is skipped" passes
    # both cases above.
    t = _errors_tree(healthy_receipt(), cases=20, errors=0, scored=20,
                     infra_skipped=0, skipped_reason="n/a")
    rc, out = run_report(t)
    assert rc == 0, out


def test_report_refuses_counts_that_do_not_add_up():
    t = _errors_tree(healthy_receipt(), cases=20, errors=0, scored=18,
                     infra_skipped=1, skipped_reason="engine error")
    rc, out = run_report(t)
    assert rc == 2, out
    assert "attempted cases" in out, out


def test_skip_reasons_name_the_three_causes_separately():
    norm, cands = corpus(4)
    cands["C00"] = {"error": "connection refused", "candidate": ""}
    cands["C01"] = {"candidate": "   "}          # empty on a successful call
    del cands["C02"]                             # absent from the candidates file
    _, skipped = bj.partition_candidates(norm, cands)
    by_id = {s["id"]: s["reason"] for s in skipped}
    assert by_id["C00"] == "engine error", by_id
    assert "successful call" in by_id["C01"], by_id
    assert by_id["C02"] == "absent from the candidates file", by_id
    assert "C03" not in by_id, "the one good case must still be judged"


def test_report_refuses_a_truncated_detail_file():
    t = report_tree(healthy_receipt(), per_case_rows=[
        {"id": "EN-1", "verdict": "pass", "severity": "S0", "behavior": "grammar_fix",
         "failure_types": []}])
    rc, out = run_report(t)
    assert rc == 2, out
    assert "truncated or mismatched" in out, out


# --------------------------------------------------------------------------- #
# runner                                                                      #
# --------------------------------------------------------------------------- #

# An exact count, because the borrowed runner in cleanup_metrics_test.py returns
# 0 when it discovers ZERO tests — so "green" would carry no information at all.
EXPECTED_TESTS = 66


def _run() -> int:
    tests = [v for k, v in sorted(globals().items())
             if k.startswith("test_") and callable(v)]
    if len(tests) != EXPECTED_TESTS:
        print(f"FAIL: discovered {len(tests)} tests, expected {EXPECTED_TESTS}. "
              f"A suite that silently shrinks still exits 0 without this check.")
        return 1
    passed = failed = 0
    for t in tests:
        try:
            t()
            passed += 1
            print(f"  PASS {t.__name__}")
        # BaseException, not Exception: a test that drives `main()` can reach
        # `sys.exit()` (preflight_judge does exactly that when the Claude CLI is
        # absent), and `SystemExit` does NOT derive from Exception. Catching only
        # Exception let that kill the process mid-suite with no summary line and no
        # count assertion — a truncated run that reported nothing about the tests
        # it never reached. KeyboardInterrupt is re-raised so Ctrl-C still works.
        except KeyboardInterrupt:
            raise
        except BaseException:
            failed += 1
            print(f"  FAIL {t.__name__}")
            traceback.print_exc()
    print(f"\n{passed} passed, {failed} failed ({len(tests)} total)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(_run())
