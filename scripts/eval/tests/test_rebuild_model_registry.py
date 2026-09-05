#!/usr/bin/env python3
"""Regression tests for rebuild-model-registry.py's history-loss guards (#2581).

WHAT THIS LOCKS. A rebuild must never make a registered artifact disappear with
nothing said. The per-artifact evaluation-count guard only examines artifacts that
still appear in the rebuilt `records`, so an ARMS row that is deleted outright, or
whose immutable id is renamed, was never examined at all: the artifact and every
evaluation attached to it were dropped, the staged registry still validated, and
the script exited 0. A floor-setting winner could vanish that way.

Pure stdlib, no pytest, no network. Run from the repo root:
    python3 scripts/eval/tests/test_rebuild_model_registry.py

HOW THE SUBJECT IS REACHED. The script's name carries a hyphen, so it is loaded
through `importlib` rather than imported. Its receipt root, output path and arm
table are module-level names read inside `main()`, so each case points them at a
temp tree and drives the REAL `main()`, including the validation and the
`staged.replace(OUT)` at the end — a stub of any layer would pass without the
replacement under test ever running. The "previous" registry is produced by a
real first rebuild rather than hand-written, so the second rebuild is replacing a
file the script itself considers valid.
"""
from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts" / "eval" / "rebuild-model-registry.py"
sys.path.insert(0, str(SCRIPT.parent))


def _load_subject():
    spec = importlib.util.spec_from_file_location("rebuild_model_registry", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --------------------------------------------------------------------------- #
# fixtures                                                                    #
# --------------------------------------------------------------------------- #

def _receipt(cand: str, s4: int = 3) -> dict:
    """One score receipt of the shape `read_receipts()` reads and `load()` accepts."""
    return {
        "meta": {"candidates_file": cand, "corpus_files": ["sealed_v1.jsonl"],
                 "judge_identity": "judge-a", "rubric_identity": None,
                 "system": "new", "adjudicate": True,
                 "adjudicate_pct": 10, "adjudicate_min": 5,
                 "production_file": "prod.jsonl"},
        "overall": {"total_scored": 100, "pass_rate_pct": 90.0, "critical_fail_count": s4},
        "judge_blind": True, "run_complete": True,
        "release_gate": {"verdict": "PASS"},
    }


REJECTED = ("eg1-1.1-c001", "1.1", "loser", ["loser.jsonl"], "rejected", "Lost.")
WINNER = ("eg1-1.1-c002", "1.1", "winner", ["winner.jsonl"], "shipped", "Shipped.")


class _Harness:
    """A temp checkout: receipts three levels deep (as `summaryPath` requires) and
    a registry file the rebuild replaces in place."""

    def __init__(self, td: str):
        self.mod = _load_subject()
        root = Path(td)
        # `summaryPath` is relative to RUNS.parent.parent.parent, so mirror the
        # real scripts/eval/runs layout rather than a flat directory.
        self.runs = root / "scripts" / "eval" / "runs"
        for cand in ("loser.jsonl", "winner.jsonl"):
            d = self.runs / cand.replace(".jsonl", "")
            d.mkdir(parents=True)
            (d / "summary.json").write_text(json.dumps(_receipt(cand)), encoding="utf-8")
        self.out = root / "model-registry.json"
        self.mod.RUNS = self.runs
        self.mod.OUT = self.out

    def rebuild(self, arms) -> int:
        self.mod.ARMS = list(arms)
        return self.mod.main()

    def ids(self) -> list[str]:
        doc = json.loads(self.out.read_text(encoding="utf-8"))
        return [a["artifactId"] for a in doc["artifacts"]]


def _refused(h: _Harness, arms) -> str:
    """Run a rebuild that must be REFUSED; return the message. Asserts the
    registry on disk is untouched, since a refusal that already replaced the file
    is no refusal at all."""
    before = h.out.read_bytes()
    try:
        h.rebuild(arms)
    except SystemExit as exc:
        msg = str(exc)
    else:
        raise AssertionError("rebuild exited 0 instead of refusing")
    assert msg.startswith("REFUSED"), msg
    assert h.out.read_bytes() == before, "a refused rebuild replaced the registry anyway"
    return msg


# --------------------------------------------------------------------------- #
# cases                                                                       #
# --------------------------------------------------------------------------- #

def test_deleting_a_registered_row_is_refused():
    # THE DEFECT. The shipped winner's row is removed from ARMS. The evaluation-
    # count guard iterates the rebuilt records, so it never looks at c002 and the
    # rebuild used to write a registry without it and exit 0.
    with tempfile.TemporaryDirectory() as td:
        h = _Harness(td)
        assert h.rebuild([REJECTED, WINNER]) == 0
        assert h.ids() == ["eg1-1.1-c001", "eg1-1.1-c002"]

        msg = _refused(h, [REJECTED])
        assert "eg1-1.1-c002" in msg, msg
        assert h.ids() == ["eg1-1.1-c001", "eg1-1.1-c002"]


def test_renaming_a_registered_id_is_refused():
    # An id is immutable. A rename is a delete plus an add, and the delete half
    # was invisible for exactly the reason above: the renamed row appears in the
    # rebuild under its new name, and the old name is absent from `records`.
    with tempfile.TemporaryDirectory() as td:
        h = _Harness(td)
        assert h.rebuild([REJECTED, WINNER]) == 0

        renamed = ("eg1-1.1-c003",) + WINNER[1:]
        msg = _refused(h, [REJECTED, renamed])
        assert "eg1-1.1-c002" in msg, msg
        assert h.ids() == ["eg1-1.1-c001", "eg1-1.1-c002"]


def test_an_unchanged_artifact_set_still_rebuilds():
    # CONTROL. The guard must refuse a loss, not every rebuild: the same table
    # rebuilt over itself is the ordinary case and must exit 0 and rewrite.
    with tempfile.TemporaryDirectory() as td:
        h = _Harness(td)
        assert h.rebuild([REJECTED, WINNER]) == 0
        h.out.write_text(h.out.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        assert h.rebuild([REJECTED, WINNER]) == 0
        assert h.ids() == ["eg1-1.1-c001", "eg1-1.1-c002"]


def test_adding_a_row_still_rebuilds():
    # CONTROL, other direction. Growth is what the rebuild is FOR (a forgotten arm
    # being added); comparing id SETS rather than lengths is what keeps a rebuild
    # that adds one row and drops another from netting out to "unchanged".
    with tempfile.TemporaryDirectory() as td:
        h = _Harness(td)
        assert h.rebuild([REJECTED]) == 0
        assert h.ids() == ["eg1-1.1-c001"]
        assert h.rebuild([REJECTED, WINNER]) == 0
        assert h.ids() == ["eg1-1.1-c001", "eg1-1.1-c002"]

        # Add one, drop one: same length, different set. Must still refuse.
        swapped = ("eg1-1.1-c003", "1.1", "other", ["loser.jsonl"], "rejected", "Lost.")
        msg = _refused(h, [swapped, WINNER])
        assert "eg1-1.1-c001" in msg, msg


EXPECTED_TESTS = 4


def _run() -> int:
    """Discover and run every `test_*`, with an EXACT count and `BaseException`.

    Same shape as `test_alias_scorer.py`, for the same two reasons: a discovery
    runner exits 0 on zero tests, and the subject here raises `SystemExit` by
    design, which is not an `Exception`.
    """
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
