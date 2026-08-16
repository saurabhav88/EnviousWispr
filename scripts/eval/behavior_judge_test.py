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

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import traceback
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "eval"))

import behavior_judge as bj  # noqa: E402

SHELL = ROOT / "scripts" / "eval" / "judge_ollama_bench.sh"
REPORT = ROOT / "scripts" / "eval" / "report_ollama_bench.py"
RECEIPT_STATE = ROOT / "scripts" / "eval" / "receipt_state.py"


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

# The shell IMPORTS this module to resolve the default judge, so the module body must
# survive an import with no argv. Before the judge became part of the resume stamp the
# stub was only ever executed, and a stub that raises on import made the script exit 2
# at startup while every shell test still passed — they assert what a receipt or stamp
# does NOT contain, which is trivially true of a script that never ran.
import os
# Honours EW_JUDGE exactly as the real module does, so a test can change the judge the
# script resolves without editing the stub.
DEFAULT_JUDGE = os.environ.get("EW_JUDGE", "azure/stub-judge")

# Models the production `--print-judge-identity` contract, including its REFUSAL. A stub
# that answered for every id would make the shell's pre-loop validation untestable: the
# case proving a bad judge cannot delete receipts needs this to exit 2, exactly as the real
# module does for an id with no funded route.
if "--print-judge-identity" in sys.argv:
    if not (DEFAULT_JUDGE.startswith("azure/") or DEFAULT_JUDGE.startswith(("claude", "sonnet"))):
        print(f"judge {{DEFAULT_JUDGE!r}} is unusable: no approved funded grading route",
              file=sys.stderr)
        sys.exit(2)
    suffix = "@stubdigest" if DEFAULT_JUDGE.startswith("azure/") else ""
    print(DEFAULT_JUDGE)
    print(DEFAULT_JUDGE + suffix)
    sys.exit(0)

# Guarded so an IMPORT is side-effect free and exit-free. `sys.exit` at module level
# would raise SystemExit through the import and leave the caller with no value, which
# looks identical to a stub that crashed.
if __name__ == "__main__":
    a = sys.argv
    # Models `refuse_paid_key_judge` running BEFORE any output is written. Without this the
    # stub is more permissive than production and hides a real defect: the pre-fix script
    # deleted a receipt on a stamp mismatch, and only production's refusal-before-write made
    # that deletion permanent. A stub that always writes a receipt silently repairs it.
    if "--judge" in a:
        j = a[a.index("--judge") + 1]
        if not (j.startswith("azure/") or j.startswith(("claude", "sonnet"))):
            print(f"REFUSED: --judge {{j}} has no approved funded grading route", file=sys.stderr)
            sys.exit(2)
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
    # The script derives ROOT from its own location and now DELEGATES refusal
    # classification to `receipt_state.py`, so the temp ROOT needs a real copy.
    # Without it `python3 <missing>` exits 2, which collides with the UNREADABLE
    # state and would make every refusal read "unreadable" — a fixture omission
    # that produces plausible wrong messages rather than an obvious error.
    (t / "scripts" / "eval" / "receipt_state.py").write_bytes(RECEIPT_STATE.read_bytes())
    (t / "scripts" / "eval" / "behavior_judge.py").write_text(STUB_JUDGE.format(mode=mode))
    (t / "cand" / "modelA.jsonl").write_text('{"id":"A","candidate":"x"}\n')
    (t / "corpus.jsonl").write_text('{"id":"A"}\n')
    return t


def run_shell(t, env=None):
    p = subprocess.run(
        ["bash", str(t / "scripts" / "eval" / "judge_ollama_bench.sh"),
         str(t / "corpus.jsonl"), str(t / "cand"), str(t / "judged")],
        capture_output=True, text=True, env=env)
    out = p.stdout + p.stderr
    # COMPLETED-THE-SUBJECT GUARD. Several shell cases assert that something is absent —
    # no stamp, no second invocation, a particular refusal wording — and each of those is
    # also true of a script that died before doing any work. So an early death must be an
    # error here rather than a silent pass in each case. This fired for real: adding the
    # judge to the stamp made the script resolve it by importing the module, the stub
    # raised on import, and the whole suite stayed green while judging nothing.
    #
    # Asserts the script reached one of its two TERMINAL outcomes rather than the absence
    # of one known error string. A guard written the second way only catches the failure
    # its author already met — a syntax error, a missing command, or the next unforeseen
    # early exit would sail through it, which is the same fail-open shape as a denylist.
    # Reads the LAST non-empty stderr line, not any line anywhere. Scanning all output
    # would let a nested program's own "FAIL:" satisfy the shell's terminal condition —
    # no current fixture does that, but the guard would be asserting the wrong thing.
    #
    # NORMAL completion of the model loop ends in one of two lines: a FAIL: block then
    # `exit 1`, or the success line. Setup failures exit before either (missing
    # arguments, an unresolvable judge) and so does any other early death, which is
    # precisely what this guard is here to reject. Once one of the two IS present, it is
    # the last non-empty line and it is the shell's verdict.
    terminal = next((ln for ln in reversed(p.stderr.splitlines()) if ln.strip()), "")
    completed = terminal.startswith("judged all models into ")
    reported_failure = terminal.startswith("FAIL: ")
    assert completed or reported_failure, (
        f"the script never reached a terminal outcome, so this case tested nothing:\n{out}")
    return p.returncode, out


def invocations(t):
    f = t / "judged" / "_invocations"
    return len(f.read_text().splitlines()) if f.exists() else 0


def stamped(t):
    return (t / "judged" / "modelA" / ".inputs-sha256").exists()


def forge_stamp(t, judge=None):
    """Write a stamp that genuinely MATCHES, so the resume fast path is entered
    and only the cacheability check can stop the skip. Computed exactly as the
    script does — over the same absolute argv paths, since the hash covers
    filenames, and now over the JUDGE, which is part of the inputs. Without it the
    stamp is absent, the fast path is never reached, and a case would pass while
    testing the stale-inputs branch instead.

    `judge` defaults to the stub's DEFAULT_JUDGE, i.e. what the script itself will
    resolve. Pass a different value to forge a stamp from a DIFFERENT judge, which is
    what makes "a judge change invalidates the stamp" testable."""
    # The script stamps the IDENTITY, not the bare label, so a fixture forging a matching
    # stamp has to use the same value. The stub appends @stubdigest for azure routes.
    judge = judge if judge is not None else "azure/stub-judge@stubdigest"
    forged = subprocess.run(
        ["bash", "-c",
         'if command -v shasum >/dev/null 2>&1; then H="shasum -a 256"; else H=sha256sum; fi; '
         f'{{ printf "judge=%s\\n" "{judge}"; '
         f'$H "{t / "cand" / "modelA.jsonl"}" "{t / "corpus.jsonl"}" '
         f'"{t / "scripts" / "eval" / "behavior_judge.py"}"; }} | $H | cut -d" " -f1'],
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


def test_both_layers_give_the_same_diagnosis_for_the_same_receipt():
    """The alignment that two review rounds found broken, now asserted.

    The shell and the report each have to explain a refused receipt, and they must
    agree — an operator who sees "predates the cacheable field" from one and
    "corrupt or hand-edited" from the other cannot tell which to believe. Two
    copies in two languages diverged twice in one PR (verdict classification, then
    metadata validation), so classification moved into `receipt_state.py` and this
    test is what stops it drifting apart again.

    Drives the SHELL's real resume path and the REPORT's real entry point over the
    same receipt bodies, rather than comparing either against a reimplementation.
    """
    cases = [
        # receipt body, shell phrase, report phrase
        ({"release_gate": {"verdict": "BLOCK"}, "cacheable": False},
         "receipt is not cacheable", "is not cacheable"),
        ({"release_gate": {"verdict": "BLOCK"}},
         "predates the cacheable field", "predates the `cacheable` field"),
        ({"release_gate": {"verdict": "WEIRD"}},
         "verdict this gate cannot produce", "cannot produce"),
        ({"release_gate": {"verdict": "BLOCK"}, "skipped": "not a list"},
         "malformed metadata", "malformed"),
        ({"release_gate": ["bad"]},
         "verdict this gate cannot produce", "cannot produce"),
    ]

    t = shell_tree("false")
    run_shell(t)
    d = t / "judged" / "modelA"
    d.mkdir(parents=True, exist_ok=True)

    for receipt, shell_phrase, report_phrase in cases:
        forge_stamp(t)
        (d / "summary.json").write_text(json.dumps(receipt))
        before = invocations(t)
        _, log = run_shell(t)
        assert invocations(t) > before, f"{receipt} must re-judge: {log}"
        assert shell_phrase in log, f"shell said the wrong thing for {receipt}: {log}"

        rt = report_tree(receipt)
        rc, out = run_report(rt)
        assert rc == 2, f"{receipt} -> rc={rc}: {out}"
        assert report_phrase in out, f"report said the wrong thing for {receipt}: {out}"
        assert "Traceback" not in out, f"{receipt} raised: {out}"


def test_a_receipt_from_a_different_judge_is_re_judged():
    # THE finding this guards: the stamp used to cover only candidates + corpus, so a
    # cacheable receipt graded by one judge was skipped after the default changed. On
    # 2026-08-11 that was 15 stamped Sonnet arms, and the sweep would have produced a
    # scoreboard silently mixing two judges.
    t = shell_tree("true")
    d = t / "judged" / "modelA"
    d.mkdir(parents=True, exist_ok=True)
    (d / "summary.json").write_text(json.dumps(
        {"cacheable": True, "release_gate": {"verdict": "CLEAR"},
         "skipped": [], "missing_scores": []}))

    # A stamp that is valid in every respect EXCEPT the judge.
    forge_stamp(t, judge="claude-sonnet-5")
    before = invocations(t)
    _, log = run_shell(t)
    assert invocations(t) > before, (
        f"a receipt from another judge was skipped instead of re-judged:\n{log}")


def test_a_receipt_from_the_same_judge_is_still_skipped():
    # TWO-WAY CONTROL. Without this, a stamp that never matches would pass the test
    # above while re-grading every arm on every sweep — which is the expensive failure,
    # and the one that looks like nothing is wrong.
    t = shell_tree("true")
    d = t / "judged" / "modelA"
    d.mkdir(parents=True, exist_ok=True)
    (d / "summary.json").write_text(json.dumps(
        {"cacheable": True, "release_gate": {"verdict": "CLEAR"},
         "skipped": [], "missing_scores": []}))

    forge_stamp(t)  # the judge the script will actually resolve
    before = invocations(t)
    _, log = run_shell(t)
    assert invocations(t) == before, f"a matching receipt was re-judged anyway:\n{log}"
    assert "skipped (already judged)" in log, log





def test_imported_verdicts_carry_no_rubric_identity():
    """`--verdicts` imports judgments this scorer did not produce, so the receipt
    records None — exactly as `judge_identity` is empty for a run started outside
    the sweep. Unknown provenance groups with unknown provenance rather than
    claiming an identity it never resolved.

    Five review rounds reached this, and every invented alternative was worse: the
    local digest CLAIMED a rubric the import never ran under; a constant sentinel
    made two different external rubrics compare equal; hashing the verdicts file
    made two arms under the SAME rubric compare different, because verdict files
    differ by candidate outcome — which broke multi-arm external grading.

    ACCEPTED LIMIT, pinned here so it cannot be forgotten: two imports under
    genuinely different external rubrics both report None and will rank together.
    Closing it needs a rubric identifier the verdicts file does not carry.

    TWO-WAY: a normal run must still record the real digest, or a fix that always
    returned None would pass while disabling the guard entirely.
    """
    src = (Path(__file__).parent / "behavior_judge.py").read_text()
    i = src.index('"rubric_identity":')
    expr = src[i:src.index("\n", i)]
    assert "external_verdicts is None" in expr, expr
    assert expr.rstrip().endswith("else None,"), expr
    assert "_rubric_identity()" in expr, expr

    a = bj._rubric_identity()
    assert a is not None and len(a) == 12 and a == bj._rubric_identity(), a


def test_a_mixed_rubric_is_refused_like_a_mixed_judge():
    """Two arms graded under DIFFERENT rubrics must not be ranked together.

    `judge_identity` answers who graded it; `rubric_identity` answers against what
    bar. Both change what a score MEANS. The resume stamp cannot cover this: an
    interrupted sweep leaves some arms re-graded and some not, and this report
    compares receipts and never reads that sidecar (cloud review P1 on #2055).

    TWO-WAY. Without the matching half, a guard that refused EVERY run would pass
    the refusal case while making the report permanently unusable.
    """
    def tree_with_two(rubric_a, rubric_b):
        t = report_tree(healthy_receipt(meta={
            "judge": "azure/j", "judge_identity": "azure/j@aaa",
            "judge_model_version": "v1", "rubric_identity": rubric_a}))
        b = t / "judged" / "modelB"
        b.mkdir(parents=True)
        (b / "summary.json").write_text(json.dumps(healthy_receipt(meta={
            "judge": "azure/j", "judge_identity": "azure/j@aaa",
            "judge_model_version": "v1", "rubric_identity": rubric_b})))
        (b / "per_case.jsonl").write_text(
            (t / "judged" / "modelA" / "per_case.jsonl").read_text())
        run = json.loads((t / "run-summary.json").read_text())
        m = dict(run["models"][0]); m["model"] = "modelB"
        m["candidates"] = str(t / "cand" / "modelB.jsonl")
        run["models"].append(m)
        (t / "run-summary.json").write_text(json.dumps(run))
        return t

    rc, log = run_report(tree_with_two("RUBRIC_ONE", "RUBRIC_TWO"))
    assert "mixes judges or rubrics" in log, f"a mixed rubric was ranked anyway:\n{log}"
    assert rc != 0, log

    rc, log = run_report(tree_with_two("RUBRIC_ONE", "RUBRIC_ONE"))
    assert "mixes judges or rubrics" not in log, f"one rubric was refused:\n{log}"

def test_the_stamp_the_script_writes_depends_on_the_judge():
    # Reads the stamp the REAL script wrote, not one this file computed: a fixture-only
    # comparison would verify forge_stamp and pass even with the script's stamp
    # unchanged, which is precisely how a mutation slips through.
    # ONE tree for both runs. The stamp hashes absolute filenames, so two temp trees
    # produce different stamps whatever the judge is — a version of this test using a
    # fresh tree per run passed with the judge stripped back out of the stamp, i.e. it
    # measured the temp path and not the thing under test.
    t = shell_tree("true")
    stamp_file = t / "judged" / "modelA" / ".inputs-sha256"

    def stamp_under(judge):
        _, log = run_shell(t, env=dict(os.environ, EW_JUDGE=judge))
        assert f"judge: {judge}" in log, f"script did not resolve {judge}: {log}"
        assert stamp_file.exists(), f"no stamp written for {judge}: {log}"
        return stamp_file.read_text().strip()

    a = stamp_under("claude-sonnet-5")
    b = stamp_under("azure/gpt-5-6-luna")
    assert a and b and a != b, f"the script's stamp ignores the judge: {a} == {b}"


def test_a_refused_judge_cannot_delete_a_single_cached_receipt():
    """THE regression test for the P1 cloud review found on PR #2026.

    Putting the judge into the stamp created a destructive path: a refused or mistyped
    EW_JUDGE mismatches EVERY arm's stamp, the loop `rm -rf`s each receipt on a mismatch, and
    the judge then exits before writing a replacement — so the whole cached set is destroyed
    and the log blames "candidates or corpus changed". The fix validates the judge before the
    loop can touch anything, so this asserts the receipt is STILL THERE afterwards.
    """
    t = shell_tree("true")
    d = t / "judged" / "modelA"
    d.mkdir(parents=True, exist_ok=True)
    receipt = d / "summary.json"
    receipt.write_text(json.dumps(
        {"cacheable": True, "release_gate": {"verdict": "CLEAR"},
         "skipped": [], "missing_scores": []}))
    forge_stamp(t)
    before = receipt.read_text()

    p = subprocess.run(
        ["bash", str(t / "scripts" / "eval" / "judge_ollama_bench.sh"),
         str(t / "corpus.jsonl"), str(t / "cand"), str(t / "judged")],
        capture_output=True, text=True, env=dict(os.environ, EW_JUDGE="gpt-4o"))
    out = p.stdout + p.stderr

    assert p.returncode == 2, f"expected refusal exit 2, got {p.returncode}:\n{out}"
    assert receipt.exists(), f"the cached receipt was DELETED by a refused judge:\n{out}"
    assert receipt.read_text() == before, "the cached receipt was modified"
    assert (d / ".inputs-sha256").exists(), "the stamp was deleted"
    assert invocations(t) == 0, f"the judge was invoked despite being refused:\n{out}"
    assert "Nothing has been touched" in out, out


def test_a_routed_but_unusable_judge_still_cannot_delete_a_receipt():
    """The SECOND round of the same P1 (cloud review, #2026), and the reason the fix is
    structural rather than a better check.

    `claude-sonet-5` is a typo that ROUTES: it starts with `claude`, so it has a funded route
    and passes the pre-loop validation. Its stamp still mismatches every arm, so the loop
    still re-judges, and the CLI only rejects the model name once the judge actually runs.
    Under the delete-first design that destroyed the receipt. Under staged-then-swapped the
    receipt survives, and it survives for ANY reason the judge fails to produce one — a
    capacity error, an expired key, a dropped network — none of which a probe could predict.
    """
    t = shell_tree("noreceipt")          # the judge runs and writes nothing
    d = t / "judged" / "modelA"
    d.mkdir(parents=True, exist_ok=True)
    receipt = d / "summary.json"
    receipt.write_text(json.dumps(
        {"cacheable": True, "release_gate": {"verdict": "CLEAR"},
         "skipped": [], "missing_scores": []}))
    original_stamp = forge_stamp(t, judge="azure/stub-judge@stubdigest")
    before = receipt.read_text()

    _, log = run_shell(t, env=dict(os.environ, EW_JUDGE="claude-sonet-5"))

    assert "=== re-judging modelA" in log, f"expected a re-judge attempt:\n{log}"
    assert not (t / "judged" / "modelA.rejudge").exists(), "staging directory was left behind"

    # THREE separate P1s met here, one per review round, and they only reconcile as quarantine.
    #
    # 1. The bytes must SURVIVE — deleting them was the original defect, where one typo wiped
    #    the whole cached set.
    quarantined = t / "judged" / "modelA.stale" / "summary.json"
    assert quarantined.exists(), f"the previous receipt was destroyed:\n{log}"
    assert quarantined.read_text() == before, "the quarantined receipt was modified"

    # 2. They must NOT sit at the canonical path, because `report_ollama_bench.py` reads that
    #    path and checks cacheability but never the stamp — so a valid receipt from the previous
    #    judge would be ranked beside newly judged arms and corrupt the comparison silently.
    assert not receipt.exists(), (
        f"the previous judge's receipt is still where the report will rank it:\n{log}")

    # 3. Surviving must not mean ADOPTED. Nothing may carry this judge's stamp, or a later run
    #    would skip the arm and report the previous judge's scores as this judge's.
    assert not (t / "judged" / "modelA" / ".inputs-sha256").exists(), "canonical stamp survived"
    stale_stamp = t / "judged" / "modelA.stale" / ".inputs-sha256"
    assert stale_stamp.read_text().strip() == original_stamp, (
        "the quarantined receipt was re-stamped with the NEW judge's identity")
    assert "quarantined at" in log, log



def test_a_partial_staged_receipt_does_not_evict_a_complete_one():
    """Cloud review round 3, the sibling P1. A judge that fails AFTER scoring starts still
    writes a summary with `cacheable: false`, so a presence-only promotion check replaced a
    good receipt with the failure. Promotion now requires the staged receipt to be cacheable.
    """
    t = shell_tree("false")              # judge writes a receipt with cacheable: false
    d = t / "judged" / "modelA"
    d.mkdir(parents=True, exist_ok=True)
    receipt = d / "summary.json"
    receipt.write_text(json.dumps(
        {"cacheable": True, "release_gate": {"verdict": "CLEAR"},
         "skipped": [], "missing_scores": [], "marker": "the good one"}))
    original_stamp = forge_stamp(t, judge="claude-sonnet-5")   # forces a re-judge
    _, log = run_shell(t)

    # The complete receipt is preserved, and preserved OUT of the report's path.
    stale = json.loads((t / "judged" / "modelA.stale" / "summary.json").read_text())
    assert stale.get("marker") == "the good one", (
        f"the complete receipt was not preserved:\n{log}")
    assert (t / "judged" / "modelA.stale" / ".inputs-sha256").read_text().strip() \
        == original_stamp, "the quarantined receipt lost or changed its own stamp"

    # What sits at the canonical path is what THIS judge produced, and it is not cacheable, so
    # the report rejects it loudly instead of ranking either receipt.
    now = json.loads(receipt.read_text())
    assert now.get("marker") is None, f"the old receipt is still at the ranked path:\n{log}"
    assert now.get("cacheable") is False, now
    assert not (d / ".inputs-sha256").exists(), "a non-cacheable receipt must never be stamped"
    assert "quarantined at" in log, log


def test_a_partial_receipt_is_still_promoted_when_there_is_nothing_to_lose():
    """Two-way control on the clause above. If promotion required cacheable UNCONDITIONALLY, a
    first-ever run that produced a partial receipt would leave no evidence at all — and the
    pre-existing behaviour of keeping it for diagnosis, unstamped, would be lost."""
    t = shell_tree("false")
    _, log = run_shell(t)
    d = t / "judged" / "modelA"
    assert (d / "summary.json").exists(), f"a first partial receipt must be kept:\n{log}"
    assert not stamped(t), "a non-cacheable receipt must never be stamped"
    assert "not cacheable" in log, log


def test_a_destination_with_no_summary_does_not_swallow_the_staged_receipt():
    """Cloud review round 6. An earlier run interrupted after creating $dest but before writing
    summary.json leaves a directory with no receipt. A summary-only "is there a previous?" test
    called that no-previous, so quarantine skipped it and `mv` moved the staged directory INSIDE
    it: no canonical summary for the report, and no error anywhere.
    """
    t = shell_tree("true")
    d = t / "judged" / "modelA"
    d.mkdir(parents=True, exist_ok=True)
    (d / "per_case.jsonl").write_text('{"id":"A"}\n')   # partial write, no summary.json
    _, log = run_shell(t)

    assert (d / "summary.json").exists(), (
        f"the staged receipt was not promoted to the canonical path:\n{log}")
    assert not (d / "modelA.rejudge").exists(), (
        f"the staged directory was nested inside the destination:\n{log}")
    assert not list(d.glob("*.rejudge")), f"nested staging directory found: {list(d.iterdir())}"
    assert stamped(t), f"a promoted cacheable receipt must be stamped:\n{log}"


def test_the_swap_quarantines_before_it_promotes():
    """Cloud review round 6, the interruption-safety half. The old order was `rm -rf $dest` then
    `mv`, so an interruption between them destroyed the old receipt while the new one was still
    under .rejudge — and the next run clears staging, losing both.

    Asserts the ORDER structurally, by its observable effect: after a successful swap the
    previous receipt must still exist in the quarantine slot. Under `rm -rf` first it is gone.
    """
    t = shell_tree("true")
    d = t / "judged" / "modelA"
    d.mkdir(parents=True, exist_ok=True)
    (d / "summary.json").write_text(json.dumps(
        {"cacheable": True, "release_gate": {"verdict": "CLEAR"},
         "skipped": [], "missing_scores": [], "marker": "the previous one"}))
    forge_stamp(t, judge="claude-sonnet-5")      # different judge, so it re-judges
    _, log = run_shell(t)

    fresh = json.loads((d / "summary.json").read_text())
    assert fresh.get("marker") is None, f"the new receipt was not promoted:\n{log}"
    assert fresh.get("cacheable") is True, fresh

    preserved = json.loads((t / "judged" / "modelA.stale" / "summary.json").read_text())
    assert preserved.get("marker") == "the previous one", (
        f"the previous receipt was deleted rather than quarantined, so an interruption "
        f"mid-swap would lose it:\n{log}")


def test_repeated_failures_keep_the_complete_receipt():
    """Cloud review round 5, and the reason the quarantine slot has a rule rather than being a
    plain overwrite. Failure one moves the complete receipt into the slot and promotes a partial;
    failure two must NOT then displace that complete receipt with the partial."""
    t = shell_tree("false")            # every attempt writes cacheable: false
    d = t / "judged" / "modelA"
    d.mkdir(parents=True, exist_ok=True)
    (d / "summary.json").write_text(json.dumps(
        {"cacheable": True, "release_gate": {"verdict": "CLEAR"},
         "skipped": [], "missing_scores": [], "marker": "the only complete one"}))
    forge_stamp(t, judge="claude-sonnet-5")

    run_shell(t)                        # attempt 1: complete -> slot, partial -> canonical
    _, log = run_shell(t)               # attempt 2: must not overwrite the slot

    slot = json.loads((t / "judged" / "modelA.stale" / "summary.json").read_text())
    assert slot.get("marker") == "the only complete one", (
        f"a second failure ground the quarantine down to a partial receipt:\n{log}")
    assert "COMPLETE quarantine" in log, log


def test_a_failed_quarantine_aborts_the_arm_instead_of_mis_stamping():
    """Cloud review round 13. This script runs without `errexit`, so a permission or filesystem
    error left `quarantine_previous` returning success (its final `echo` succeeded). The caller
    then moved the staged receipt INSIDE the still-existing destination and the stamp landed on
    the OLD receipt while the arm reported success — the nest-and-mis-stamp failure arriving
    through an error path rather than a logic one.

    Made to fail by removing write permission from the judged directory, so the rename genuinely
    cannot happen. The arm must report FAILED and nothing may be stamped.
    """
    t = shell_tree("true")
    d = t / "judged" / "modelA"
    d.mkdir(parents=True, exist_ok=True)
    (d / "summary.json").write_text(json.dumps(
        {"cacheable": True, "release_gate": {"verdict": "CLEAR"},
         "skipped": [], "missing_scores": [], "marker": "the previous one"}))
    forge_stamp(t, judge="claude-sonnet-5")          # forces a re-judge
    judged = t / "judged"
    mode = judged.stat().st_mode
    os.chmod(judged, 0o500)                          # readable, not writable: rename fails
    try:
        rc, log = run_shell(t)
    finally:
        os.chmod(judged, mode)

    assert "FAILED modelA" in log, f"a failed quarantine was not reported as a failure:\n{log}"
    assert rc != 0, f"the sweep exited successfully despite a failed arm:\n{log}"
    kept = json.loads((d / "summary.json").read_text())
    assert kept.get("marker") == "the previous one", (
        f"the old receipt was replaced or nested into:\n{log}")
    assert not list(d.glob("*.rejudge")), f"the staged receipt was nested inside: {list(d.iterdir())}"

    # WHY THIS CASE CANNOT ISOLATE THE HELPER, stated rather than implied: both renames happen
    # inside the same parent directory, so any permission failure trips the promote guard as well
    # as the quarantine guard. Swallowing the helper's failure therefore still ends in a reported
    # FAILED arm, and a mutation test over this case passes either way. It verifies the OUTCOME,
    # which is the property that matters, and the source assertion below covers the mechanism the
    # reviewer actually flagged.
    src = SHELL.read_text()
    body = src.split("quarantine_previous() {")[1].split("\n}")[0]
    assert 'mv "$dest" "$dest.stale" || return 1' in body, (
        "the quarantine rename does not propagate failure; without `|| return 1` the helper "
        "returns success because its final echo does, and the caller promotes into a still-"
        "occupied destination")
    for call in ("if ! quarantine_previous; then",):
        assert src.count(call) >= 3, (
            f"expected every quarantine call site to check the result, found "
            f"{src.count(call)} of them")


def test_a_successful_rejudge_does_replace_the_old_receipt():
    """Two-way control. A staging swap that never promoted anything would pass the case above
    while making every re-judge a no-op, which is the expensive failure and looks like nothing
    is wrong. The stub writes a cacheable receipt, so the arm must end up stamped."""
    t = shell_tree("true")
    d = t / "judged" / "modelA"
    d.mkdir(parents=True, exist_ok=True)
    (d / "summary.json").write_text(json.dumps({"cacheable": False, "stale": "marker"}))
    forge_stamp(t, judge="claude-sonnet-5")   # a different judge, so it must re-judge

    _, log = run_shell(t)

    fresh = json.loads((d / "summary.json").read_text())
    assert "stale" not in fresh, f"the old receipt was not replaced:\n{log}"
    assert fresh.get("cacheable") is True, fresh
    assert stamped(t), f"a successful re-judge must earn a stamp:\n{log}"
    assert not (t / "judged" / "modelA.rejudge").exists(), "staging directory was left behind"


def test_the_refusal_happens_before_any_arm_is_examined():
    """Two-way control on the guard's PLACEMENT, not just its existence. A check that ran
    inside the loop would refuse on the first arm and could still have deleted its receipt
    before doing so; this asserts the script never reached the per-model work at all."""
    t = shell_tree("true")
    p = subprocess.run(
        ["bash", str(t / "scripts" / "eval" / "judge_ollama_bench.sh"),
         str(t / "corpus.jsonl"), str(t / "cand"), str(t / "judged")],
        capture_output=True, text=True, env=dict(os.environ, EW_JUDGE="mistral-large"))
    out = p.stdout + p.stderr
    assert p.returncode == 2, out
    assert "=== judging" not in out, f"an arm was entered before the judge was validated:\n{out}"
    assert "=== judge:" not in out, f"the judge was announced as usable:\n{out}"


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
    # This tuple is in effect a declaration of every external command the script depends on:
    # anything missing from it is hidden from the script under the shim. `mv` joined the list
    # when the re-judge became staged-then-swapped, and this case is what caught the omission.
    for cmd in ("python3", "grep", "basename", "dirname", "cat", "mkdir", "rm", "mv",
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

def _two_arm_report_tree(meta_a, meta_b):
    """A report fixture with TWO arms, each carrying its own receipt metadata.

    Built by extending `report_tree`, deliberately, rather than writing a second fixture from
    scratch: the report refuses a corpus with no international cases, and a hand-rolled corpus
    that omitted one failed before reaching the check under test. Reusing the working fixture's
    shape is what keeps the case pointed at its subject.

    One arm can never show a mixed-judge ranking, which is why two are needed.
    """
    healthy = {
        "cacheable": True,
        "release_gate": {"verdict": "CLEAR", "checks": []},
        "overall": {"pass_rate_pct": 50.0, "critical_fail_count": 0, "total_scored": 2,
                    "infra_skipped": 0, "failure_type_counts": {}},
        "skipped": [], "missing_scores": [],
        "judge_reconciliation": {"requested": [], "accepted": [], "missing": [],
                                 "unexpected": []},
        "adjudication": {"adjudicated_n": 0, "disagreements": 0},
    }
    t = report_tree({**healthy, "meta": meta_a})

    # Second arm, mirroring the first arm's on-disk shape exactly.
    (t / "judged" / "modelB").mkdir(parents=True)
    (t / "judged" / "modelB" / "summary.json").write_text(
        json.dumps({**healthy, "meta": meta_b}))
    (t / "judged" / "modelB" / "per_case.jsonl").write_text(
        (t / "judged" / "modelA" / "per_case.jsonl").read_text())

    run = json.loads((t / "run-summary.json").read_text())
    second = dict(run["models"][0])
    second["model"] = "modelB"
    second["candidates"] = str(t / "cand" / "modelB.jsonl")
    run["models"].append(second)
    (t / "run-summary.json").write_text(json.dumps(run))
    return t


def test_the_report_refuses_to_rank_two_different_judges():
    """Cloud review pointed at this root cause three times before I fixed it here rather than in
    the sweep. A partial sweep, an interrupted sweep, a hand-copied receipt or a repointed
    deployment all leave some arms graded by one judge and some by another. The sweep cannot close
    every route; the layer that COMBINES arms can. Validating a receipt by whether it parses and
    never by who produced it is what let all of them through.
    """
    t = _two_arm_report_tree(
        {"judge": "claude-sonnet-5", "judge_model_version": None},
        {"judge": "azure/gpt-5-6-luna", "judge_model_version": "gpt-5.6-luna-2026-07-09"})
    rc, out = run_report(t)
    assert rc == 2, out
    assert "mixes judges" in out, out
    assert "claude-sonnet-5" in out and "azure/gpt-5-6-luna" in out, out


def test_the_report_refuses_two_versions_of_the_same_judge():
    """The id alone is not identity. An Azure deployment repointed in place leaves two receipts
    sharing `judge` while holding scores from different models — the one mixing route a
    judge-name check cannot see."""
    t = _two_arm_report_tree(
        {"judge": "azure/gpt-5-6-luna", "judge_model_version": "gpt-5.6-luna-2026-07-09"},
        {"judge": "azure/gpt-5-6-luna", "judge_model_version": "gpt-5.6-luna-2026-11-01"})
    rc, out = run_report(t)
    assert rc == 2, out
    assert "mixes judges" in out, out
    assert "2026-11-01" in out, out


def test_the_report_ranks_a_uniform_field():
    """Two-way control, and the important one: a check that refused any multi-arm run would pass
    both cases above while making the report useless for its only real job."""
    meta = {"judge": "azure/gpt-5-6-luna", "judge_model_version": "gpt-5.6-luna-2026-07-09"}
    rc, out = run_report(_two_arm_report_tree(dict(meta), dict(meta)))
    assert rc == 0, out
    assert "mixes judges" not in out, out


def test_legacy_receipts_without_a_version_rank_together():
    """A receipt written before `judge_model_version` existed reports None. Those must group with
    each other rather than each becoming its own judge, or every historical run turns unrankable."""
    meta = {"judge": "claude-sonnet-5"}
    rc, out = run_report(_two_arm_report_tree(dict(meta), dict(meta)))
    assert rc == 0, out
    assert "mixes judges" not in out, out


def test_an_unmeasurable_arm_does_not_count_as_its_own_judge():
    """Cloud review round 10. An arm where every case errored has NO receipt, so the row carries
    no judge. Skipping only rows marked `skipped_reason` left it counted as a separate judge, and
    any benchmark containing one fully failing or paywalled model became falsely unreportable —
    a false positive in a guard, which is the direction that destroys trust in it."""
    meta = {"judge": "azure/gpt-5-6-luna", "judge_identity": "azure/gpt-5-6-luna@abc123",
            "judge_model_version": "gpt-5.6-luna-2026-07-09"}
    t = _two_arm_report_tree(dict(meta), dict(meta))
    # Turn modelB into an every-case-errored arm: no receipt, and the run summary says so.
    shutil.rmtree(t / "judged" / "modelB")
    run = json.loads((t / "run-summary.json").read_text())
    for m in run["models"]:
        if m["model"] == "modelB":
            m["errors"], m["cases"] = 2, 2
    (t / "run-summary.json").write_text(json.dumps(run))

    rc, out = run_report(t)
    assert "mixes judges" not in out, f"an unmeasurable arm was counted as a judge:\n{out}"
    assert rc == 0, out


def test_the_report_separates_two_azure_resources_serving_the_same_model():
    """The (judge, version) pair could not see the endpoint. Two different Azure resources serving
    the same model string compared equal, even though the resume stamp always distinguished them,
    so an interrupted re-grade across resources could be ranked as one field."""
    t = _two_arm_report_tree(
        {"judge": "azure/gpt-5-6-luna", "judge_identity": "azure/gpt-5-6-luna@resourceA",
         "judge_model_version": "gpt-5.6-luna-2026-07-09"},
        {"judge": "azure/gpt-5-6-luna", "judge_identity": "azure/gpt-5-6-luna@resourceB",
         "judge_model_version": "gpt-5.6-luna-2026-07-09"})
    rc, out = run_report(t)
    assert rc == 2, out
    assert "mixes judges" in out, out
    assert "resourceA" in out and "resourceB" in out, out


def test_a_malformed_meta_is_named_rather_than_crashing_the_report():
    """A truncated or hand-edited `"meta": [...]` is TRUTHY, so `or {}` leaves a list and the
    following `.get()` raises AttributeError — aborting the whole report with a traceback instead
    of naming the one bad receipt, which is what the per-model handling exists to do."""
    t = report_tree({**healthy_receipt(), "meta": ["not", "an", "object"]})
    rc, out = run_report(t)
    assert rc == 2, out
    assert "Traceback" not in out, out
    assert "not an object" in out, out


def test_an_absent_meta_still_ranks():
    """Two-way control. Absent and malformed are different states: a receipt predating `meta`
    ranks fine, and a first version of this check rejected every one of them."""
    receipt = healthy_receipt()
    receipt.pop("meta", None)
    rc, out = run_report(report_tree(receipt))
    assert rc == 0, out
    assert "not an object" not in out, out


def test_a_malformed_nested_identity_field_is_named_rather_than_crashing():
    """Cloud review round 12. A hand-edited `"judge_identity": []` inside an otherwise
    well-formed `meta` makes the grouping tuple unhashable, so `setdefault` aborts the whole
    report with a TypeError — the same failure the outer `meta` shape check prevents, one level
    in. Shape-checking a container and then trusting its contents is half a check."""
    t = report_tree({**healthy_receipt(),
                     "meta": {"judge": "azure/gpt-5-6-luna", "judge_identity": [],
                              "judge_model_version": "v1"}})
    rc, out = run_report(t)
    assert rc == 2, out
    assert "Traceback" not in out, out
    assert "not a string" in out, out


def test_a_direct_run_records_the_identity_it_resolved_itself():
    """Cloud review round 12 P1. A run started directly rather than through the sweep resolves a
    perfectly good identity in preflight, and reading only the sweep's environment variable threw
    it away — so two direct receipts from different Azure resources recorded the same empty
    provenance and the report could not tell them apart.

    Asserts the wiring at the source: the meta field falls back to the resolved identity rather
    than to None.
    """
    src = Path(bj.__file__).read_text()
    line = next(ln for ln in src.splitlines() if '"judge_identity":' in ln and "meta" not in ln)
    assert "_resolved_judge_identity" in line, line
    # And the claude route sets it, or a direct claude run would record nothing while a sweep run
    # records the model id — the two would then refuse to rank together, a false positive.
    claude_branch = src.split("def preflight_judge(")[1].split("def ")[0]
    assert "_resolved_judge_identity = model" in claude_branch, claude_branch


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

    # THREE GROUPS, because type-validity and value-degeneracy are different axes
    # and my first table conflated them — it asserted "malformed" for a perfectly
    # well-formed `rep_coverage: [20]`, which is valid and simply means no
    # adjudication pass ran. Blanket-asserting one expectation over a table is how
    # a row ends up testing the wrong thing.
    malformed_shapes = [
        # Cloud rounds 7 and 8: the axis was TYPE, and it needed to be type AND
        # range AND relationship. A negative count passes `_is_int` and prints
        # "-1 adjudication-dropped"; a coverage exceeding the selected count is
        # impossible and the derivation's `max(0, ...)` clamped it to zero and
        # claimed no gap. Both erase corruption instead of naming it.
        {"adjudication": {"adjudication_missing_n": -1}},
        {"adjudication": {"adjudicated_n": -5}},
        {"adjudication": no_count, "wobble": {"rep_coverage": [20, -3]}},
        {"adjudication": {"adjudicated_n": 1}, "wobble": {"rep_coverage": [20, 5]}},
        # Round 9: a pass RAN (two coverage entries) but `adjudicated_n` is
        # absent, so the number dropped is unknowable — and it was coerced to
        # zero and reported as "no gaps". Unknowable is not zero.
        {"adjudication": {}, "wobble": {"rep_coverage": [20, 0]}},
        # Round 10, the mirror of round 9: `adjudicated_n > 0` guarantees two
        # coverage entries (behavior_judge.py:787), so one entry means the pass
        # ran and its result is missing — unknowable, not zero.
        {"adjudication": no_count, "wobble": {"rep_coverage": [20]}},
        {"adjudication": {"adjudicated_n": 1}, "wobble": {"rep_coverage": []}},

        {"adjudication": no_count, "wobble": ["bad"]},
        {"adjudication": no_count, "wobble": "bad"},
        {"adjudication": no_count, "wobble": 7},
        {"adjudication": no_count, "wobble": {"rep_coverage": "not a list"}},
        {"adjudication": no_count, "wobble": {"rep_coverage": [20, "seventeen"]}},
        {"adjudication": ["bad"]},
        {"adjudication": "bad"},
        {"adjudication": {"adjudicated_n": "twenty"}},
        {"adjudication": {"adjudication_missing_n": "seven"}},
        {"adjudication": {"adjudication_missing_n": True}},
        {"skipped": "not a list"},
        {"missing_scores": {"not": "a list"}},
    ]
    for shape in malformed_shapes:
        r = healthy_receipt(**shape)
        del r["cacheable"]
        t = report_tree(r)
        rc, out = run_report(t)
        assert rc == 2, f"{shape} -> rc={rc}: {out}"
        assert "Traceback" not in out, f"{shape} raised: {out}"
        # Cloud review round 5 found what a "did not crash" assertion allows: the
        # message claimed the receipt "records no gaps of its own", a false claim
        # built by coercing a corrupt field to empty. Name it, never erase it.
        assert "malformed" in out, f"{shape} was coerced instead of refused: {out}"
        assert "no gaps of its own" not in out, \
            f"{shape} claimed no gaps from unusable metadata: {out}"

    # Well-formed but degenerate: valid types, nothing to compare. These must
    # reach the ordinary legacy message, NOT the malformed one — the guard has to
    # fire on bad types without also rejecting honest empty evidence.
    # THIRD time I misclassified a row in this table, so the rule is written out:
    # a degenerate-but-valid receipt needs `adjudicated_n` to be 0 or absent. With
    # selected > 0 and fewer than two coverage entries it is inconsistent, not
    # degenerate, which is what round 10 found — my earlier "valid, just
    # degenerate" reading of `no_count` + `[20]` was simply wrong.
    for shape in ({"adjudication": {"adjudicated_n": 0}, "wobble": {"rep_coverage": [20]}},
                  {"adjudication": {}, "wobble": {"rep_coverage": []}},
                  # Two coverage entries but a VALID explicit count, which wins:
                  # the derivation is never needed, so nothing is unknowable.
                  {"wobble": {"rep_coverage": [20, 0]}}):
        r = healthy_receipt(**shape)
        del r["cacheable"]
        t = report_tree(r)
        rc, out = run_report(t)
        assert rc == 2, f"{shape} -> rc={rc}: {out}"
        assert "Traceback" not in out, f"{shape} raised: {out}"
        assert "malformed" not in out, f"{shape} wrongly called malformed: {out}"
        assert "predates the `cacheable` field" in out, f"{shape}: {out}"

    # A non-object `release_gate` is caught EARLIER, by the verdict check, because
    # its verdict reads as None. Asserting "malformed" here would have been wrong
    # about which branch owns it.
    r = healthy_receipt(release_gate=["bad"])
    del r["cacheable"]
    rc, out = run_report(report_tree(r))
    assert rc == 2, out
    assert "cannot produce" in out, out
    assert "Traceback" not in out, out


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
# judge billing gate                                                          #
# --------------------------------------------------------------------------- #

def _routed_transport(model):
    """Which transport `dispatch_judge` actually reaches for `model`, with both stubbed
    so nothing touches a network or a CLI. Returns None when the call is refused.

    Drives the REAL dispatcher rather than restating its rules, so this cannot agree
    with a router that has changed underneath it."""
    originals = {n: getattr(bj, f"call_{n}") for n in ("azure", "claude")}
    for n in originals:
        setattr(bj, f"call_{n}", (lambda x: lambda *a, **k: x)(n))
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            return bj.dispatch_judge(model, "sys", "usr")
    except SystemExit:
        return None
    finally:
        for n, fn in originals.items():
            setattr(bj, f"call_{n}", fn)


# `gpt-5-6-luna` is the important trap: it is the Azure DEPLOYMENT name, so without the
# `azure/` prefix it reads as an OpenAI model id and no funded route accepts it.
BILLING_IDS = [
    "azure/gpt-5-6-luna", "azure/anything",
    "claude-sonnet-5", "claude-opus-5", "sonnet",
    "gpt-4o", "gpt-5-6-luna", "gemini-3-pro",
    "mistral-large", "llama-3", "claude/foo", "AZURE/gpt-5-6-luna", "",
]


def test_billing_gate_agrees_with_the_router_on_every_id():
    # Both answers are DERIVED from JUDGE_ROUTES, so this is a consistency check on the
    # table rather than on two hand-written lists: a refused id must reach no transport,
    # and a permitted id must reach one.
    for model in BILLING_IDS:
        transport = _routed_transport(model)
        unfunded = bj.judge_lacks_funded_route(model)
        assert unfunded == (transport is None), (
            f"{model!r} reached transport {transport!r} but the gate says "
            f"lacks_funded_route={unfunded}")


def test_every_funded_route_has_a_transport_branch():
    # A route added to the table with no branch in dispatch_judge would raise. Exhaustive
    # over the table itself, so it covers rows added after this test was written — which
    # a fixed id list cannot do.
    for prefix, transport in bj.JUDGE_ROUTES:
        assert _routed_transport(f"{prefix}probe") == transport, (
            f"route {prefix!r} does not reach transport {transport!r}")


def test_an_unrecognised_judge_id_reaches_no_transport_at_all():
    # The original defect: a denylist of gpt/gemini prefixes let an unknown id through
    # and dispatch billed it to the personal Gemini key. Now there is no such transport
    # to reach, and the dispatcher refuses before looking for one.
    for model in ("mistral-large", "gpt-4o", "gemini-3-pro", ""):
        assert _routed_transport(model) is None, model
        assert bj.judge_lacks_funded_route(model), model


def test_the_personal_key_transports_do_not_exist():
    # Deleted rather than unrouted: a refusal is a promise, an absent function is a fact.
    # This is the check that notices a well-meaning restore.
    for gone in ("call_openai", "call_gemini"):
        assert not hasattr(bj, gone), (
            f"{gone} is back. Grading may not bill a personal key; restoring a paid "
            f"transport here needs a founder decision.")


def test_dispatch_refuses_without_help_from_main():
    # The gate must hold for a caller that never goes through main(), which is what
    # `score_new`/`run_judge`/a future sibling script would do.
    with contextlib.redirect_stderr(io.StringIO()) as err:
        try:
            bj.dispatch_judge("gpt-4o", "sys", "usr")
        except SystemExit as e:
            assert e.code == 2
        else:
            raise AssertionError("dispatch_judge did not refuse a personal-key id")
    assert "REFUSED" in err.getvalue()


def test_the_azure_deployment_name_without_its_prefix_is_refused():
    # `gpt-5-6-luna` is what our Azure resource calls the deployment. Bare, it reads as
    # an OpenAI id, and it is refused so it cannot be mistaken for one that is funded.
    assert bj.judge_lacks_funded_route("gpt-5-6-luna")
    assert not bj.judge_lacks_funded_route("azure/gpt-5-6-luna")


def test_refusal_exits_two_and_names_the_funded_alternative():
    for model in ("gpt-4o", "gemini-3-pro", "mistral-large"):
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                bj.refuse_paid_key_judge(model)
        except SystemExit as e:
            assert e.code == 2, (model, e.code)
        else:
            raise AssertionError(f"{model} was not refused")
        assert "azure/gpt-5-6-luna" in err.getvalue(), err.getvalue()


def test_the_two_funded_judges_are_not_refused():
    # Two-way control: without this, a gate that refuses EVERY id passes the tests
    # above while making the harness unusable.
    for model in ("azure/gpt-5-6-luna", "claude-sonnet-5"):
        with contextlib.redirect_stderr(io.StringIO()):
            bj.refuse_paid_key_judge(model)     # must not raise SystemExit


@contextlib.contextmanager
def _azure_reply(payload):
    """Run call_azure against a canned response body, with the secrets stubbed so this
    works on a runner that has no Azure credentials at all.

    The stub endpoint is a REAL-shaped Azure host, because `_validated_azure_endpoint`
    now refuses anything else — a placeholder like `https://stub.invalid` would make
    every transport test fail for the wrong reason and hide whatever it was checking."""
    class _Resp:
        def read(self): return json.dumps(payload).encode()
        def __enter__(self): return self
        def __exit__(self, *a): return False

    class _Opener:
        def open(self, *a, **k): return _Resp()

    real_key, real_opener = bj._key, bj._no_redirect_opener
    bj._key = (lambda name: "https://stub-test.openai.azure.com"
               if "endpoint" in name else "stub-key")
    bj._no_redirect_opener = lambda: _Opener()
    try:
        yield
    finally:
        bj._key, bj._no_redirect_opener = real_key, real_opener


def _azure_error(payload):
    with _azure_reply(payload):
        try:
            bj.call_azure("gpt-5-6-luna", "s", "u")
        except RuntimeError as e:
            return str(e)
    raise AssertionError(f"call_azure accepted {payload!r}")


def test_azure_returns_the_assistant_text_on_a_good_reply():
    with _azure_reply({"choices": [{"message": {"content": "  [] "},
                                   "finish_reason": "stop"}]}):
        assert bj.call_azure("gpt-5-6-luna", "s", "u") == "[]"


def test_azure_names_the_token_cap_when_the_budget_ran_out():
    # Measured shape: this deployment reasons, so exhausting the budget yields
    # finish_reason='length' with EMPTY content, not a half-written array. The operator
    # action is a cap or chunk-size change, so the message has to say so.
    msg = _azure_error({"choices": [{"message": {"content": ""},
                                     "finish_reason": "length"}]})
    assert "max_completion_tokens" in msg and "chunk-size" in msg, msg


def test_azure_distinguishes_a_dropped_reply_from_a_token_cap():
    # Same empty body, different finish_reason: a dropped chunk is the #1950 failure and
    # raising the cap would not help, so it must not borrow the cap's advice.
    msg = _azure_error({"choices": [{"message": {"content": ""},
                                     "finish_reason": "stop"}]})
    assert "max_completion_tokens" not in msg, msg
    assert "empty content" in msg, msg


def test_azure_refuses_a_reply_with_no_choices():
    assert "no choices" in _azure_error({"choices": []})


@contextlib.contextmanager
def _endpoint(value):
    """Point the endpoint lookup at `value` without touching the real environment."""
    real = bj._key
    bj._key = lambda name: value if "endpoint" in name else "stub-key"
    try:
        yield
    finally:
        bj._key = real


def test_a_non_azure_endpoint_is_refused_before_the_key_is_read():
    # The risk: `_key` reads the environment first, so an inherited or mistyped
    # AZURE_OPENAI_ENDPOINT would send our api-key header to somebody else's host.
    for bad in ("https://evil.example.com", "http://x.openai.azure.com",
                "https://x.openai.azure.com/steal", "https://x.openai.azure.com?q=1",
                "https://openai.azure.com.evil.test", ""):
        try:
            with _endpoint(bad):
                bj._validated_azure_endpoint()
        except RuntimeError as e:
            assert "refusing to send the Azure key" in str(e), (bad, str(e))
        else:
            raise AssertionError(f"accepted endpoint {bad!r}")


def test_a_real_azure_endpoint_is_accepted():
    # Two-way control: a validator that refuses everything would pass the test above
    # while making the judge unusable. Both suffixes ACCEPTED FOR THIS ROUTE must pass.
    # Deliberately not "every hostname Azure issues": Foundry exposes more FQDN families
    # than these two, and not all of them serve this legacy chat-completions route, so
    # this list is our accepted set rather than a claim about Azure's naming.
    for good in ("https://x.openai.azure.com", "https://x.openai.azure.com/",
                 "https://y.cognitiveservices.azure.com"):
        with _endpoint(good):
            assert bj._validated_azure_endpoint() == good.rstrip("/")


def test_a_redirect_is_refused_rather_than_followed():
    # A validated host can still 3xx to an arbitrary one, and urllib replays the headers
    # we set on the Request, so the endpoint check alone does not contain the key.
    handler = bj._no_redirect_opener().handlers
    redirect = [h for h in handler if hasattr(h, "redirect_request")]
    assert redirect, "no redirect handler installed"
    try:
        redirect[0].redirect_request(None, None, 302, "Found", {},
                                     "https://evil.example.com/x")
    except RuntimeError as e:
        assert "refusing to follow" in str(e), str(e)
    else:
        raise AssertionError("redirect_request did not refuse")


@contextlib.contextmanager
def _azure_serving(model_field, host="stub-test.openai.azure.com"):
    """Run judge_identity against a deployment that reports `model_field` as its served model."""
    class _Resp:
        def read(self):
            return json.dumps({"model": model_field,
                               "choices": [{"message": {"content": "x"},
                                            "finish_reason": "stop"}]}).encode()
        def __enter__(self): return self
        def __exit__(self, *a): return False

    class _Opener:
        def open(self, *a, **k): return _Resp()

    real_key, real_opener = bj._key, bj._no_redirect_opener
    bj._key = lambda name: (f"https://{host}" if "endpoint" in name else "stub-key")
    bj._no_redirect_opener = lambda: _Opener()
    try:
        yield
    finally:
        bj._key, bj._no_redirect_opener = real_key, real_opener


def test_the_identity_changes_when_the_deployment_is_repointed():
    # Cloud review round 6 P1. Azure can upgrade a deployment IN PLACE: hostname, deployment
    # name and API version all stay identical while the model underneath changes. An identity
    # built from configuration alone keeps matching receipts graded by the previous model, so a
    # resumed sweep skips them and combines two models' scores.
    with _azure_serving("gpt-5.6-luna-2026-07-09"):
        before = bj.judge_identity("azure/gpt-5-6-luna")
    with _azure_serving("gpt-5.6-luna-2026-11-01"):
        after = bj.judge_identity("azure/gpt-5-6-luna")
    assert before != after, (
        f"the identity survived a deployment repoint, so old receipts would be reused: {before}")


def test_the_identity_is_stable_while_the_deployment_is_not_repointed():
    # Two-way control. An identity that changed every call would invalidate every stamp on every
    # sweep and re-grade the whole field forever — the expensive failure, and it looks like
    # nothing is wrong.
    with _azure_serving("gpt-5.6-luna-2026-07-09"):
        a = bj.judge_identity("azure/gpt-5-6-luna")
        b = bj.judge_identity("azure/gpt-5-6-luna")
    assert a == b, f"identity is not stable across calls: {a} != {b}"


def test_the_served_model_is_never_absent_from_the_identity():
    # Fail rather than fall back to a version-blind identity: blind reuse across a model change
    # is worse than refusing to start, and this is the only axis the client cannot see from its
    # own configuration.
    for bad in (None, "", "   "):
        try:
            with _azure_serving(bad):
                bj.judge_identity("azure/gpt-5-6-luna")
        except RuntimeError as e:
            assert "did not report which model" in str(e), str(e)
        else:
            raise AssertionError(f"accepted a served-model field of {bad!r}")


def test_the_identity_probe_goes_through_the_no_redirect_opener():
    # The probe sends the api-key, so it must not be able to follow a redirect off the validated
    # host any more than the grading calls can. Asserted by construction: with the opener stubbed
    # the probe succeeds, and `_azure_served_model` has no other transport.
    src = Path(bj.__file__).read_text()
    body = src.split("def _azure_served_model(")[1].split("\ndef ")[0]
    assert "_no_redirect_opener()" in body, "the probe bypasses the no-redirect opener"
    assert "urllib.request.urlopen" not in body, "the probe uses a raw opener"


@contextlib.contextmanager
def _azure_pin(value):
    """Pin the process to a model version, and restore it afterwards."""
    real = bj._azure_pinned_model
    bj._azure_pinned_model = value
    try:
        yield
    finally:
        bj._azure_pinned_model = real


def test_a_grading_response_from_a_different_model_is_refused():
    # Cloud review round 7. The identity probe is a time-of-CHECK; each grading call is a
    # time-of-USE. A repoint between them would stamp post-change scores with the pre-change
    # identity, so one scoreboard would silently hold two judge versions.
    with _azure_pin("gpt-5.6-luna-2026-07-09"):
        with _azure_reply({"model": "gpt-5.6-luna-2026-11-01",
                           "choices": [{"message": {"content": "[]"},
                                        "finish_reason": "stop"}]}):
            try:
                bj.call_azure("gpt-5-6-luna", "s", "u")
            except RuntimeError as e:
                assert "repointed mid-run" in str(e), str(e)
            else:
                raise AssertionError("a response from a different model was accepted")


def test_a_response_that_names_no_model_is_refused_when_pinned():
    # Cloud review round 9, a fail-open in the round-7 check. It required a differing NONEMPTY
    # STRING to refuse, so a response omitting `model`, or returning it blank or non-string,
    # skipped the comparison and had its scores accepted and stamped with the pinned identity.
    # The question that finds this class: what input makes the condition match NOTHING, and does
    # it then allow or refuse?
    for bad in (None, "", "   ", 42, ["gpt"]):
        with _azure_pin("gpt-5.6-luna-2026-07-09"):
            with _azure_reply({"model": bad,
                               "choices": [{"message": {"content": "[]"},
                                            "finish_reason": "stop"}]}):
                try:
                    bj.call_azure("gpt-5-6-luna", "s", "u")
                except RuntimeError as e:
                    assert "did not say which model" in str(e), (bad, str(e))
                else:
                    raise AssertionError(f"accepted scores with model={bad!r} while pinned")


def test_a_missing_model_field_is_tolerated_when_NOT_pinned():
    # Two-way control on the direction of that strictness. An unpinned process has no version to
    # verify against and no stamp to corrupt, so requiring the field there would break the
    # direct-call path for no benefit.
    with _azure_pin(None):
        with _azure_reply({"choices": [{"message": {"content": "[]"},
                                        "finish_reason": "stop"}]}):
            assert bj.call_azure("gpt-5-6-luna", "s", "u") == "[]"


def test_a_grading_response_from_the_pinned_model_is_accepted():
    # Two-way control. A check that refused everything would pass the case above while making
    # every grading call fail — the loud failure, but it would look like Azure was broken.
    with _azure_pin("gpt-5.6-luna-2026-07-09"):
        with _azure_reply({"model": "gpt-5.6-luna-2026-07-09",
                           "choices": [{"message": {"content": "[]"},
                                        "finish_reason": "stop"}]}):
            assert bj.call_azure("gpt-5-6-luna", "s", "u") == "[]"


def test_an_unpinned_process_still_grades():
    # The pin is set by preflight, so an unpinned process means nothing probed first. Grading
    # must still work rather than refusing: this is the path a direct call takes, and there is no
    # stamp comparison happening for it to corrupt.
    with _azure_pin(None):
        with _azure_reply({"model": "anything-at-all",
                           "choices": [{"message": {"content": "[]"},
                                        "finish_reason": "stop"}]}):
            assert bj.call_azure("gpt-5-6-luna", "s", "u") == "[]"


def test_preflight_pins_the_model_for_an_azure_judge():
    # Pinned in preflight rather than left to the caller, so a run started directly still gets
    # the time-of-use check. Without this, `_azure_pinned_model` stays None for any run that did
    # not go through the shell, and the check above silently does nothing.
    with _azure_pin(None):
        with _azure_serving("gpt-5.6-luna-2026-07-09"):
            bj.preflight_judge("azure/gpt-5-6-luna")
            assert bj._azure_pinned_model == "gpt-5.6-luna-2026-07-09", bj._azure_pinned_model


def test_an_inherited_pin_is_adopted_instead_of_reprobed():
    # Cloud review round 8. Each arm is a separate process. If each probes for itself it pins
    # whatever is CURRENT, so a deployment repointed between arms leaves that process
    # self-consistent while the sweep still stamps every arm with the first model's identity —
    # two model versions under one stamp. Adopting the sweep's pin makes such an arm fail on its
    # first grading response instead.
    with _azure_pin(None):
        os.environ["EW_AZURE_PINNED_MODEL"] = "gpt-5.6-luna-2026-07-09"
        try:
            # No serving stub: adopting the inherited pin must not require a probe at all, which
            # is also what saves one request per arm.
            bj.preflight_judge("azure/gpt-5-6-luna")
            assert bj._azure_pinned_model == "gpt-5.6-luna-2026-07-09", bj._azure_pinned_model
        finally:
            del os.environ["EW_AZURE_PINNED_MODEL"]


def test_an_arm_refuses_when_the_deployment_moved_since_the_sweep_probed():
    # The consequence that makes the propagation worth it: the arm is pinned to the SWEEP's model,
    # so a deployment now serving something else fails loudly rather than scoring under the
    # sweep's stamp.
    with _azure_pin(None):
        os.environ["EW_AZURE_PINNED_MODEL"] = "gpt-5.6-luna-2026-07-09"
        try:
            bj.preflight_judge("azure/gpt-5-6-luna")
            with _azure_reply({"model": "gpt-5.6-luna-2026-11-01",
                               "choices": [{"message": {"content": "[]"},
                                            "finish_reason": "stop"}]}):
                try:
                    bj.call_azure("gpt-5-6-luna", "s", "u")
                except RuntimeError as e:
                    assert "repointed mid-run" in str(e), str(e)
                else:
                    raise AssertionError("the arm graded under the wrong model version")
        finally:
            del os.environ["EW_AZURE_PINNED_MODEL"]


def test_the_identity_probe_reports_the_served_model_as_its_third_line():
    # The sweep parses line 3 to build the pin it exports. A probe that printed two lines would
    # export an empty pin, and every per-response check would then silently do nothing.
    src = Path(bj.__file__).read_text()
    block = src.split('if "--print-judge-identity" in sys.argv:')[1].split("return 0")[0]
    # Counts STDOUT lines only: the error path in the same block prints to stderr, and a naive
    # count of "print(" includes it — which is how the first version of this assertion failed
    # against correct code.
    stdout_prints = [ln.strip() for ln in block.splitlines()
                     if "print(" in ln and "file=sys.stderr" not in ln]
    assert len(stdout_prints) == 3, f"expected three stdout lines, got {stdout_prints}"
    assert "DEFAULT_JUDGE" in stdout_prints[0], stdout_prints
    assert "identity" in stdout_prints[1], stdout_prints
    assert "_azure_pinned_model" in stdout_prints[2], stdout_prints


def test_the_billing_check_runs_before_the_availability_check():
    # Refusing to spend the founder's own money must not depend on whether some CLI
    # happens to be logged in, so the order in main() is load-bearing.
    src = Path(bj.__file__).read_text()
    body = src.split("def main(")[1]
    assert body.index("refuse_paid_key_judge(args.judge)") \
        < body.index("preflight_judge(args.judge)"), \
        "refuse_paid_key_judge must be called before preflight_judge in main()"


def test_every_corpus_behavior_resolves_to_a_variant_table_entry():
    # The lookup fails SILENTLY on a spelling mismatch: no error, just a bucket graded
    # without the variant written for it. On Speechpath r2 the table said `topic_shift`
    # and the corpus said `topic_segmentation`, so that category scored 7.5% pass while
    # its neighbours held 46-92%, and 41 of 99 failures were byte-identical to the key
    # once whitespace was normalised.
    #
    # Asserting the alias map alone would not catch the next drift, so this walks the
    # LIVE corpus if it is present and requires every behaviour it actually contains to
    # resolve. A corpus that is absent (gitignored artifact) skips rather than passes
    # vacuously — an unconditional pass here would be the exact defect it guards.
    # Corpus-INDEPENDENT first, and deliberately above the early return below. The
    # corpus is a gitignored artifact, so on CI it does not exist — a test whose only
    # assertions sit past that return is green on the one machine that gates merges
    # while checking nothing. That is the defect this very test exists to catch,
    # one level up.
    assert "blank lines" in " ".join(bj.allowed_variants_for("topic_segmentation")), \
        "topic_segmentation must resolve to the topic_shift separator variant"
    assert "blank lines" not in " ".join(bj.allowed_variants_for("list_structure")), \
        "the alias must be targeted, not a blanket that hands every behaviour every variant"

    corpus = Path(bj.__file__).parent / "corpus" / "speechpath_1861.jsonl"
    if not corpus.exists():
        return
    behaviors = set()
    with corpus.open() as f:
        for line in f:
            if line.strip():
                behaviors.add(bj.behavior_key(json.loads(line)))
    assert behaviors, "corpus present but no behaviours parsed — the walk is vacuous"
    unresolved = [
        b for b in behaviors
        if b not in bj.BEHAVIOR_ALLOWED_VARIANTS
        and bj.BEHAVIOR_ALIASES.get(b) not in bj.BEHAVIOR_ALLOWED_VARIANTS
        and b in {"topic_segmentation", "topic_shift", "speech_grammar", "grammar_fix"}
    ]
    assert not unresolved, (
        f"these behaviours carry a variant table entry under another spelling and will "
        f"be graded without it: {sorted(unresolved)}")

def test_the_s4_entity_rule_and_the_variant_licence_do_not_contradict():
    # Cloud review P1 on PR #2056. The variant list said a term repair is permitted
    # while NEW_JUDGE_SYSTEM's automatic-S4 list still said "changed a ... product ...
    # or other named entity" with no carve-out — so the same output was licensed by
    # one half of the prompt and an automatic critical failure by the other, and the
    # stronger instruction would have won. The variant was inert at best.
    #
    # This is the failure mode the whole file keeps hitting: two rules naming
    # different sets, each correct read alone. Only a test that reads them TOGETHER
    # catches it, which is why it exists rather than a second assertion on either.
    sysmsg = bj.NEW_JUDGE_SYSTEM.lower()
    variants = " ".join(bj.allowed_variants_for("verbatim_preservation")).lower()

    assert "envious" in variants, "precondition: the term repair is licensed"
    assert "to a\n  different one" in sysmsg or "to a different one" in sysmsg, \
        "the S4 entity rule must fire on a DIFFERENT entity, not on any change"
    assert "normalising a mis-transcribed rendering of the same entity" in sysmsg, \
        "the S4 rule must exempt normalising the same entity, or it overrides the variant"
    # Personal names: both halves must split on the SAME axis, which since 2026-08-14 is
    # whether the rendering matches `spoken_truth` -- not whether it differs from
    # raw_transcript. If one half judged against the truth and the other against the
    # transcript, a correctly-heard name would be licensed by one and an automatic S4 by
    # the other, and the stronger instruction would win. That is the original defect
    # this test exists for, moved to a new axis.
    assert "judged against `spoken_truth`" in sysmsg, \
        "the S4 rule must judge a personal name against what was actually said"
    assert "matches neither" in sysmsg, \
        "the S4 rule must fire only when the name matches NEITHER source"
    assert "matches spoken_truth is correct" in variants, \
        "the variant must license a name that matches what was actually said"
    assert "neither spoken_truth nor raw_transcript" in variants, \
        "both halves must agree a name matching neither source is the defect"
    # Two-way: the licence must NOT have widened into permitting any name rewrite.
    assert "is a real \nentity_mutation defect" in variants.replace("  ", " ") \
        or "real entity_mutation defect" in " ".join(variants.split()), \
        "substituting a different person must still be named a defect"


def test_vocabulary_repair_is_a_variant_but_name_repair_is_not():
    # Founder ruling 2026-08-13: repairing a mis-transcribed TERM is bonus credit, so
    # neither doing it nor skipping it may decide a verdict.
    #
    # Personal names were originally excluded outright, on the reasoning that no closed
    # set of names exists to be confident against. True for a shipping app; false for a
    # graded benchmark, where `spoken_truth` records the name actually said. Corrected
    # 2026-08-14 after the Wispr Flow bake-off measured 22 cases where a system was
    # marked down for hearing the name CORRECTLY (Rajesh, Nadia, Hassan, Noor, Tomas):
    # our keys were authored from OUR transcript, so they enshrined our recogniser's
    # mis-hearings and penalised anyone who got them right.
    #
    # The line now falls between a name that matches what was SAID and one that matches
    # nothing, which is a property of the output rather than of whose transcript it
    # resembles.
    #
    # Two-way on purpose. Asserting only the licence would pass a rubric that licensed
    # every name rewrite, which is the failure this could decay into.
    text = " ".join(bj.allowed_variants_for("verbatim_preservation")).lower()
    assert "envious" in text and "postgres" in text, \
        "term repair must be licensed as a variant"
    assert "not the behavior under test" in text, \
        "the licence must say the repair is not what is being graded"
    # Assert the two halves of the SPLIT, not merely that names are mentioned. A first
    # version of this checked that "personal names" appeared anywhere in the rubric —
    # which stays true if the clause is inverted, so the mutation control passed a
    # rubric saying the opposite. The phrases that carry the meaning are the two
    # directions.
    assert "matches spoken_truth is correct" in text, \
        "a name matching what was actually said must be licensed, not penalised"
    assert "neither spoken_truth nor raw_transcript" in text, \
        "the defect must be defined as matching NEITHER source"
    assert "real \nentity_mutation defect" in text or "real entity_mutation defect" in \
        " ".join(text.split()), "substituting a different person must remain a defect"
    assert "alaina" in text or "fatima" in text, \
        "the defect side needs its concrete example to stay legible"
    # The fallback matters: a corpus with no spoken source must not silently license
    # every name rewrite just because the truth is unavailable.
    assert "where spoken_truth is empty" in text, \
        "absence of spoken_truth must fall back to treating a rewrite as a defect"


# --------------------------------------------------------------------------- #
# transport retry classification                                              #
# --------------------------------------------------------------------------- #

def test_only_the_network_call_produces_a_retryable_error():
    """The retry predicate must key on WHERE the failure came from, not its class.

    Every one of the bare exceptions below is an OSError, and an earlier version
    of this predicate accepted all of them. Cloud review then found three places
    where that was wrong -- a local WAV write, a subprocess spawn for a missing
    CLI, and a credential file read -- each of which would have been answered
    with another PAID request. So the bare forms must now be REFUSED, and only
    `TransientTransportError`, which `_http_json` raises at the socket, accepted.

    Both directions are asserted together because the failure mode is symmetric:
    too narrow drops 8 cases per blip, too broad re-bills a permanent local fault.
    """
    import http.client
    import socket
    import ssl

    transport = [
        ("ConnectionResetError", ConnectionResetError(54, "Connection reset by peer")),
        ("RemoteDisconnected", http.client.RemoteDisconnected("closed")),
        ("IncompleteRead", http.client.IncompleteRead(b"", 10)),
        ("BrokenPipeError", BrokenPipeError(32, "Broken pipe")),
        ("SSLEOFError", ssl.SSLEOFError("eof")),
        ("socket.gaierror", socket.gaierror(8, "nodename nor servname")),
        ("URLError", urllib.error.URLError("unreachable")),
        ("TimeoutError", TimeoutError("timed out")),
    ]
    for name, exc in transport:
        wrapped = bj.TransientTransportError(exc)
        assert bj._retryable_http_error(wrapped), \
            f"{name} raised BY the network call must be retried"
        assert not bj._retryable_http_error(exc), \
            f"a BARE {name} must NOT be retried — it could be a file write, a " \
            f"credential read, or a subprocess spawn in the same try block"

    for name, exc in [("HTTP 429", urllib.error.HTTPError("u", 429, "rate", {}, None)),
                      ("HTTP 500", urllib.error.HTTPError("u", 500, "ise", {}, None)),
                      ("HTTP 503", urllib.error.HTTPError("u", 503, "un", {}, None))]:
        assert bj._retryable_http_error(exc), f"{name} must be retried"
    for name, exc in [("HTTP 400", urllib.error.HTTPError("u", 400, "bad", {}, None)),
                      ("HTTP 401", urllib.error.HTTPError("u", 401, "auth", {}, None)),
                      ("HTTP 404", urllib.error.HTTPError("u", 404, "nf", {}, None)),
                      ("ValueError", ValueError("not transport")),
                      ("PermissionError", PermissionError(13, "key file unreadable")),
                      ("FileNotFoundError", FileNotFoundError(2, "no claude binary"))]:
        assert not bj._retryable_http_error(exc), f"{name} must NOT be retried"


def test_http_json_converts_transport_but_not_status_or_parse_errors():
    """The conversion has to happen AT the socket, or the structural guarantee is
    just a comment. Drives the real `_http_json` with a fake opener."""
    class FakeResp:
        def __init__(self, body): self.body = body
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self): return self.body

    class Opener:
        def __init__(self, behaviour): self.behaviour = behaviour
        def open(self, req, timeout=None):
            if isinstance(self.behaviour, Exception):
                raise self.behaviour
            return FakeResp(self.behaviour)

    # transport failure -> converted
    raised = None
    try:
        bj._http_json(Opener(ConnectionResetError(54, "reset")), object(), 1)
    except BaseException as e:  # noqa: BLE001
        raised = e
    assert isinstance(raised, bj.TransientTransportError), \
        f"a socket reset must become TransientTransportError, got {type(raised).__name__}"
    assert isinstance(raised.cause, ConnectionResetError), "the cause must be preserved"

    # HTTPError -> untouched, so the caller can read its status code
    raised = None
    try:
        bj._http_json(Opener(urllib.error.HTTPError("u", 429, "rate", {}, None)), object(), 1)
    except BaseException as e:  # noqa: BLE001
        raised = e
    assert isinstance(raised, urllib.error.HTTPError) and raised.code == 429, \
        "HTTPError must pass through with its status intact"

    # a 200 with an unparsable body -> JSONDecodeError, not a transport error
    raised = None
    try:
        bj._http_json(Opener(b"not json"), object(), 1)
    except BaseException as e:  # noqa: BLE001
        raised = e
    assert isinstance(raised, json.JSONDecodeError), \
        f"a bad body is the server's answer, not transport (got {type(raised).__name__})"

    # happy path
    assert bj._http_json(Opener(b'{"ok": 1}'), object(), 1) == {"ok": 1}


def test_judge_chunk_retries_a_reset_and_returns_the_full_chunk():
    """Drive the REAL `judge_chunk` through a transport failure and assert it
    recovers. The attempt COUNT is asserted too: without it, one successful call
    satisfies the test exactly as well as a retry does."""
    calls = {"n": 0}

    def flaky_dispatch(model, system, user):
        calls["n"] += 1
        if calls["n"] < 3:
            raise bj.TransientTransportError(
                ConnectionResetError(54, "Connection reset by peer"))
        return json.dumps([{"id": "A1", "verdict": "pass"},
                           {"id": "A2", "verdict": "pass"}])

    real_dispatch, real_sleep = bj.dispatch_judge, bj.time.sleep
    bj.dispatch_judge = flaky_dispatch
    bj.time.sleep = lambda _s: None
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            out = bj.judge_chunk("azure/x", "sys", [{"id": "A1"}, {"id": "A2"}])
    finally:
        bj.dispatch_judge, bj.time.sleep = real_dispatch, real_sleep

    assert calls["n"] == 3, \
        f"expected 2 transport failures then a success = 3 attempts, saw {calls['n']}"
    assert [r["id"] for r in out] == ["A1", "A2"], \
        f"the chunk must come back whole after a transient reset, got {out!r}"


def test_judge_chunk_gives_up_on_a_client_error_without_burning_retries():
    """The other direction: a 400 is answered once and not retried.

    Without this, widening the predicate to catch resets could silently turn every
    malformed request into five paid attempts against the deployment.
    """
    calls = {"n": 0}

    def always_400(model, system, user):
        calls["n"] += 1
        raise urllib.error.HTTPError("u", 400, "bad request", {}, None)

    real_dispatch, real_sleep = bj.dispatch_judge, bj.time.sleep
    bj.dispatch_judge = always_400
    bj.time.sleep = lambda _s: None
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            out = bj.judge_chunk("azure/x", "sys", [{"id": "A1"}])
    finally:
        bj.dispatch_judge, bj.time.sleep = real_dispatch, real_sleep

    assert calls["n"] == 1, f"a 400 must be attempted exactly once, saw {calls['n']}"
    assert out == [], "a chunk that never scored must return empty so reconciliation counts it"


def test_a_missing_judge_cli_is_not_retried():
    """A spawn failure is permanent, so it must not consume the retry budget.

    This is the trap the broadened predicate creates: `FileNotFoundError` from a
    missing `claude` binary IS an OSError, and every OSError reaching an HTTP
    call site means transport. Here it means the judge does not exist, and five
    attempts with backoff per chunk across a whole corpus is pure wall clock.
    Cloud review found the same shape in tts_corpus.py, where a full disk was
    being answered with another paid TTS request.
    """
    calls = {"n": 0}

    def missing_cli(model, system, user):
        calls["n"] += 1
        raise bj.JudgeUnavailableError("claude judge: cannot start the CLI")

    real_dispatch, real_sleep = bj.dispatch_judge, bj.time.sleep
    bj.dispatch_judge = missing_cli
    bj.time.sleep = lambda _s: None
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            out = bj.judge_chunk("claude-sonnet-5", "sys", [{"id": "A1"}])
    finally:
        bj.dispatch_judge, bj.time.sleep = real_dispatch, real_sleep

    assert calls["n"] == 1, \
        f"a permanently unavailable judge must be attempted exactly once, " \
        f"saw {calls['n']} — the retry budget is being spent on a missing binary"
    assert out == [], "the chunk must return empty so reconciliation counts it"


def test_call_claude_converts_a_spawn_failure_into_the_permanent_error():
    """The conversion happens at the transport, not at the call site.

    Asserting only judge_chunk's behaviour would pass even if `call_claude` let a
    bare FileNotFoundError escape, because the test above injects the already-
    converted type. This drives the real `call_claude`.
    """
    real_run = bj.subprocess.run

    def no_binary(*a, **kw):
        raise FileNotFoundError(2, "No such file or directory: 'claude'")

    bj.subprocess.run = no_binary
    try:
        raised = None
        try:
            bj.call_claude("claude-sonnet-5", "sys", "user")
        except BaseException as e:  # noqa: BLE001
            raised = e
    finally:
        bj.subprocess.run = real_run

    assert isinstance(raised, bj.JudgeUnavailableError), \
        f"a missing CLI must surface as JudgeUnavailableError, got {type(raised).__name__}: {raised}"
    assert not bj._retryable_http_error(raised), \
        "JudgeUnavailableError must not satisfy the transport predicate"


def test_spoken_truth_reads_both_corpus_schemas():
    """The personal-name rule is only as good as the field it reads.

    Two corpora carry "what was said" under different names, and reading only
    Speechpath's `voice_text` made the rule INERT on the older parakeet corpus --
    present, shipped, and silently doing nothing, which a receipt cannot show.
    Real shapes from both files, plus the degenerate ones, because this runs on
    a grading path and must never raise.
    """
    # Speechpath: top-level voice_text.
    assert bj._spoken_truth({"voice_text": "Tell Aoife it is ready"}) == "Tell Aoife it is ready"
    # type_b_parakeet: nested under input_source.
    assert bj._spoken_truth(
        {"input_source": {"original_input": "set aside four plates make that five"}}
    ) == "set aside four plates make that five"
    # voice_text wins when both are present.
    assert bj._spoken_truth(
        {"voice_text": "top", "input_source": {"original_input": "nested"}}) == "top"
    # Degenerate shapes all fall back to the conservative empty-truth branch.
    for case in ({}, {"voice_text": ""}, {"voice_text": "   "},
                 {"input_source": None}, {"input_source": "a string, not a dict"},
                 {"input_source": {}}, {"input_source": {"original_input": None}},
                 {"input_source": {"original_input": "  "}}):
        assert bj._spoken_truth(case) == "", f"{case!r} must yield empty, not raise"


def test_a_blind_arm_and_a_sighted_arm_are_refused_like_a_mixed_judge():
    """Blinding changes what a score MEANS, so it belongs in the identity.

    Showing the judge the answer key moved 122 of 472 verdicts. That is larger
    than any arm difference this report exists to rank, so ranking a blind arm
    against a sighted one is not a comparison. `judge_blind` sits at the TOP
    LEVEL of the receipt rather than under `meta`, which is exactly why the
    original identity tuple — built only from `meta` fields — could not see it.

    THREE-WAY, because `judge_blind` has three legal states. `None` means the
    verdicts were imported and this scorer did no judging, which is an UNKNOWN
    rather than a "no": folding it into "sighted" would assert something nobody
    observed, the same absent-vs-false collapse that shipped wrong twice on
    `cacheable`.
    """
    def tree_with_two(blind_a, blind_b):
        meta = {"judge": "azure/j", "judge_identity": "azure/j@aaa",
                "judge_model_version": "v1", "rubric_identity": "RUBRIC_ONE"}
        t = report_tree(healthy_receipt(meta=meta, judge_blind=blind_a))
        b = t / "judged" / "modelB"
        b.mkdir(parents=True)
        (b / "summary.json").write_text(
            json.dumps(healthy_receipt(meta=meta, judge_blind=blind_b)))
        (b / "per_case.jsonl").write_text(
            (t / "judged" / "modelA" / "per_case.jsonl").read_text())
        run = json.loads((t / "run-summary.json").read_text())
        m = dict(run["models"][0]); m["model"] = "modelB"
        m["candidates"] = str(t / "cand" / "modelB.jsonl")
        run["models"].append(m)
        (t / "run-summary.json").write_text(json.dumps(run))
        return t

    # Refuses: one arm saw the key, the other did not.
    rc, log = run_report(tree_with_two(True, False))
    assert "mixes judges or rubrics" in log, f"blind and sighted were ranked together:\n{log}"
    assert rc != 0, log
    # And the refusal must SAY it was the blinding, or it reads as a bug in the
    # guard: every other identity field is identical between these two arms.
    assert "no answer key shown" in log and "answer key shown" in log, log

    # Refuses: a known mode against an imported-verdict receipt of unknown mode.
    rc, log = run_report(tree_with_two(False, None))
    assert "mixes judges or rubrics" in log, f"unknown blinding ranked as sighted:\n{log}"
    assert "blinding unknown" in log, log

    # Accepts: both blind, and both sighted. Without this half a guard that
    # refused every run would pass the refusal cases while making the report
    # permanently unusable.
    for same in (True, False, None):
        rc, log = run_report(tree_with_two(same, same))
        assert "mixes judges or rubrics" not in log, f"one blinding mode was refused:\n{log}"


def test_imported_verdicts_cannot_claim_a_blinding_mode():
    """--verdicts sends no payload and no system prompt, so this process did not
    decide whether the judge saw the answer key and must not record that it did.

    The local --blind flag describes THIS run. Stamping it onto imported verdicts
    asserts a fact about someone else's judging that was never observed, and the
    external verdict format carries no such field to check it against.
    """
    norm = {"c1": bj.normalize_case(
        {"id": "c1", "asr_input": "um hello there", "expected_output": "Hello there."})}
    cands = {"c1": {"candidate": "Hello there."}}
    verdicts = {"c1": {"id": "c1", "verdict": "pass", "severity": "S0",
                       "behavior_correct": True, "meaning_preserved": True,
                       "restraint_correct": True, "clean_output": True,
                       "failure_types": [], "changed_or_missing_content": [],
                       "rationale": ""}}

    # Both local flags must land on "unknown", not on their own value.
    for local_flag in (True, False):
        rep = bj.score_new(norm, cands, None, "unused-judge", 8,
                           external_verdicts=verdicts, adjudicate=False,
                           blind=local_flag)
        assert rep["judge_blind"] is None, (
            f"--blind={local_flag} was stamped onto imported verdicts as "
            f"{rep['judge_blind']!r}; nobody observed how they were graded")

    # Control: when this process DOES judge, the flag is recorded faithfully.
    # Without this half the fix could be "always None", which loses the field.
    captured = {}

    def fake_run_judge(judge, system, payloads, chunk):
        captured["saw_key"] = "reference_output" in (payloads[0] if payloads else {})
        return bj.reconcile_judge_batch(verdicts, [p["id"] for p in payloads])

    real = bj.run_judge
    bj.run_judge = fake_run_judge
    try:
        for flag in (True, False):
            rep = bj.score_new(norm, cands, None, "unused-judge", 8,
                               external_verdicts=None, adjudicate=False, blind=flag)
            assert rep["judge_blind"] is flag, rep["judge_blind"]
            assert captured["saw_key"] is (not flag), (
                "the recorded flag must match what the judge was actually sent")
    finally:
        bj.run_judge = real


def test_list_format_requirement_fires_only_where_a_list_is_actually_wanted():
    """The layout requirement must be armed by the case, not by the judge's mood.

    This exists because the requirement was previously armed by NOTHING.
    `behavior_key` reads subset/category/gold_behavior and never `shape`, so
    every sealed case arrived as `unknown` and layout was graded by no rule at
    all. Measured 2026-08-15: all 114 sealed `spoken_list` keys demand a list,
    EG-1 produced one on 1 of them, and 103 of its inline answers were judged
    PASS. A pass rate built that way carries no information about list building.

    Both conditions are load-bearing and the second is not redundant. Shape says
    the case is ABOUT lists; the authored key says the right answer for THIS
    case IS one. A `spoken_list` case deliberately authored to stay prose is a
    trap, and a trap must not inherit a requirement from its shape.
    """
    bulleted = "Do these:\n- alpha\n- beta"
    numbered = "Do these:\n1. alpha\n2. beta"

    # Armed: the shape is about lists and the key really is one.
    assert bj.list_format_required({"shape": "spoken_list", "expected_output": bulleted})
    assert bj.list_format_required({"shape": "spoken_list", "expected_output": numbered})

    # Disarmed by the key: a list-shaped case whose correct answer stays prose.
    assert not bj.list_format_required(
        {"shape": "spoken_list", "expected_output": "Do these: alpha and beta."})

    # Disarmed by the shape: every other shape, even when its key happens to be
    # a list. Nothing may acquire a layout requirement it was not authored with.
    for shape in ("clean", "inline_enumeration", "connected_prose", "self_correction",
                  "fillers_only", "unfinished", "topic_shift", "voice_at_risk",
                  "numbers_dates", "quoted_instruction"):
        assert not bj.list_format_required({"shape": shape, "expected_output": bulleted}), shape

    # Legacy corpora carry no `shape`. They were authored without a layout
    # requirement and must not gain one retroactively.
    assert not bj.list_format_required({"expected_output": bulleted})

    # A marker only counts when it OPENS a line, or ordinary prose arms the rule.
    assert not bj.list_format_required(
        {"shape": "spoken_list", "expected_output": "meet at the drop-off point at 2. 0"})

    # Degenerate shapes must return False, never raise: this runs on a grading path.
    for case in ({}, {"shape": None}, {"shape": "spoken_list"},
                 {"shape": "spoken_list", "expected_output": None},
                 {"shape": "spoken_list", "expected_output": ""}):
        assert bj.list_format_required(case) is False, f"{case!r} must be False, not raise"


def test_list_requirement_reaches_the_judge_and_survives_blinding():
    """A criterion the judge never receives is not a criterion.

    The flag travels separately from `reference_output` on purpose. Blinding
    strips the answer key, and the layout requirement must outlive that: the
    flag says THAT a list is required and never what the list should say, so it
    is safe to keep and useless as an anchor.
    """
    case = {"id": "L1", "shape": "spoken_list", "subset": "spoken_list",
            "asr_input": "Here's the plan. First, alpha. Second, beta.",
            "expected_output": "Here's the plan:\n- alpha\n- beta"}
    payload = bj.build_new_payload(bj.normalize_case(case), {"candidate": "x"}, None)
    assert payload["list_format_required"] is True

    blinded = bj.blind_payload(payload)
    assert "reference_output" not in blinded, "blinding must still drop the answer key"
    assert blinded["list_format_required"] is True, "the requirement must survive blinding"

    # And the rule itself has to be in BOTH prompts, or blind runs grade layout
    # by nothing — which is the exact defect this change exists to fix.
    assert "LIST-FORMAT REQUIREMENT" in bj.NEW_JUDGE_SYSTEM
    assert "LIST-FORMAT REQUIREMENT" in bj.BLIND_JUDGE_SYSTEM

    # A case with no layout requirement must carry the flag as False rather than
    # omit it: the prompt branches on the field, and an absent field is unread.
    prose = bj.build_new_payload(
        bj.normalize_case({"id": "P1", "shape": "connected_prose", "asr_input": "a",
                           "expected_output": "a"}), {"candidate": "x"}, None)
    assert prose["list_format_required"] is False


# --------------------------------------------------------------------------- #
# runner                                                                      #
# --------------------------------------------------------------------------- #

# An exact count, because this file's runner returns 0 when it discovers ZERO
# tests — so "green" would carry no information at all. (The runner was
# originally borrowed from cleanup_metrics_test.py, deleted 2026-08-15 with the
# rest of the deterministic polish grading; the zero-test trap it guards is
# unchanged.)
EXPECTED_TESTS = 135


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
