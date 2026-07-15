from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


EVAL_DIR = Path(__file__).resolve().parents[1]
if str(EVAL_DIR) not in sys.path:
    sys.path.insert(0, str(EVAL_DIR))
MODULE_PATH = EVAL_DIR / "score_eg1_english_list_ab.py"
SPEC = importlib.util.spec_from_file_location("score_eg1_english_list_ab", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ScoreEnglishListABTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.positive = self.root / "positive.jsonl"
        self.restraint = self.root / "restraint.jsonl"
        self.positive.write_text('{"id":"p"}\n', encoding="utf-8")
        self.restraint.write_text('{"id":"r"}\n', encoding="utf-8")
        self.contract = self.root / "contract.md"
        self._write_contract()
        self.render_receipt = self.root / "render-receipt.json"
        self.render_receipt.write_text(
            json.dumps(
                {
                    "sources": {
                        "positive_corpus": {
                            "path": str(self.positive),
                            "sha256": sha(self.positive),
                        },
                        "restraint_corpus": {
                            "path": str(self.restraint),
                            "sha256": sha(self.restraint),
                        },
                    },
                    "provenance": {"bindings": self.bindings},
                }
            )
            + "\n",
            encoding="utf-8",
        )
        self.bundle = self.root / "ab"
        self.bundle.mkdir()
        self._write_output(self.bundle / "baseline.jsonl", "baseline")
        self._write_output(self.bundle / "candidate.jsonl", "candidate")
        self._write_ab_receipt()

    def tearDown(self) -> None:
        self.temp.cleanup()

    @staticmethod
    def _write_output(path: Path, prefix: str) -> None:
        path.write_text(
            "".join(
                json.dumps({"id": f"case-{index:03d}", "candidate": f"{prefix} {index}"})
                + "\n"
                for index in range(150)
            ),
            encoding="utf-8",
        )

    def _write_contract(self) -> None:
        required = MODULE.load_contract.__globals__["REQUIRED_BINDINGS"]
        bindings = {key: "0" * 64 for key in required}
        bindings["code_anchor_git_sha1"] = "a" * 40
        bindings.update(
            {
                "contract_verifier_sha256": sha(MODULE.CONTRACT_VERIFIER),
                "deterministic_scorer_sha256": sha(MODULE.DETERMINISTIC_SCORER),
                "ab_scorer_sha256": sha(MODULE.SCRIPT_PATH),
            }
        )
        self.bindings = bindings
        self.contract.write_text(
            "contract\n<!-- EG1_LIST_V2_BINDINGS_BEGIN -->\n```json\n"
            + json.dumps(bindings, indent=2)
            + "\n```\n<!-- EG1_LIST_V2_BINDINGS_END -->\n",
            encoding="utf-8",
        )

    def _load(self) -> tuple[dict[str, object], Path, Path, Path, str]:
        with (
            mock.patch.object(MODULE, "CANONICAL_DECISION_CONTRACT", self.contract),
            mock.patch.object(
                MODULE, "validate_binding_commit", return_value="b" * 40
            ),
        ):
            return MODULE.load_bound_inputs(
                self.positive,
                self.restraint,
                self.bundle,
                sha(self.bundle / "receipt.json"),
            )

    def _write_ab_receipt(self) -> None:
        receipt = {
            "status": "connector_wire_exact_ab_complete_semantic_review_pending",
            "scope": {
                "arm_order": ["baseline", "candidate"],
                "same_server_identity_before_and_after_each_arm": True,
                "both_arms_zero_errors_and_empty_outputs": True,
                "connector_wire_exact": True,
                "paste_equivalent": False,
            },
            "provenance": {
                "git_head": "b" * 40,
                "bindings": self.bindings,
                "render_receipt": {
                    "path": str(self.render_receipt),
                    "sha256": sha(self.render_receipt),
                },
                "sources": {
                    "decision_contract": {
                        "path": str(self.contract),
                        "sha256": sha(self.contract),
                    }
                },
            },
            "arms": {
                arm: {
                    "path": f"{arm}.jsonl",
                    "sha256": sha(self.bundle / f"{arm}.jsonl"),
                    "row_count": 150,
                    "inference_error_count": 0,
                    "empty_output_count": 0,
                    "runner_returncode": 0,
                    "rendered_prompts_sha256": arm[0] * 64,
                }
                for arm in ("baseline", "candidate")
            },
        }
        (self.bundle / "receipt.json").write_text(
            json.dumps(receipt) + "\n", encoding="utf-8"
        )

    def test_load_bound_inputs_preserves_explicit_arm_direction(self) -> None:
        ab, baseline, candidate, render, receipt_sha = self._load()
        self.assertEqual(ab["scope"]["arm_order"], ["baseline", "candidate"])
        self.assertEqual(baseline.name, "baseline.jsonl")
        self.assertEqual(candidate.name, "candidate.jsonl")
        self.assertEqual(render, self.render_receipt)
        self.assertEqual(receipt_sha, sha(self.bundle / "receipt.json"))

    def test_load_bound_inputs_rejects_filename_arm_override(self) -> None:
        with (self.bundle / "candidate.jsonl").open("w", encoding="utf-8") as handle:
            handle.write(
                json.dumps(
                    {"id": "case-000", "candidate": "x", "model_id": "baseline"}
                )
                + "\n"
            )
        self._write_ab_receipt()
        with self.assertRaisesRegex(ValueError, "may not override"):
            self._load()

    def test_load_bound_inputs_rejects_altered_contract_binding(self) -> None:
        receipt_path = self.bundle / "receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["provenance"]["bindings"]["ab_scorer_sha256"] = "f" * 64
        receipt_path.write_text(json.dumps(receipt) + "\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "bindings differ"):
            self._load()

    def test_atomic_publish_failure_leaves_no_final_file(self) -> None:
        destination = self.root / "report.json"

        class FailingHandle:
            def __init__(self, fd: int) -> None:
                self.fd = fd

            def __enter__(self) -> "FailingHandle":
                return self

            def __exit__(self, *_: object) -> None:
                os.close(self.fd)

            def write(self, value: bytes) -> None:
                os.write(self.fd, value[:1])
                raise OSError("injected short write")

            def flush(self) -> None:
                return None

            def fileno(self) -> int:
                return self.fd

        with (
            mock.patch.object(
                MODULE.os, "fdopen", side_effect=lambda fd, _mode: FailingHandle(fd)
            ),
            self.assertRaisesRegex(OSError, "injected short write"),
        ):
            MODULE.publish_exclusive(destination, b"complete report")
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.root.glob(".report.json.*")), [])

    def test_prelink_source_failure_leaves_no_final_file(self) -> None:
        destination = self.root / "report.json"

        def fail_source_check() -> None:
            raise RuntimeError("source changed before link")

        with self.assertRaisesRegex(RuntimeError, "source changed before link"):
            MODULE.publish_exclusive(
                destination,
                b"complete report",
                before_link=fail_source_check,
            )
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.root.glob(".report.json.*")), [])

    @staticmethod
    def _case(case_id: str, role: str, *, strict: bool, false_list: bool = False) -> dict[str, object]:
        return {
            "id": case_id,
            "role": role,
            "strict": strict,
            "false_list": false_list,
            "inference_ok": True,
            "items_preserved": True,
            "scope_preserved": True,
        }

    def _mechanical_report(self, candidate_false_list: bool = False) -> dict[str, object]:
        baseline_rows = [
            self._case("p", "positive_list", strict=False),
            self._case("r", "prose_restraint", strict=True),
        ]
        candidate_rows = [
            self._case("p", "positive_list", strict=True),
            self._case(
                "r",
                "prose_restraint",
                strict=not candidate_false_list,
                false_list=candidate_false_list,
            ),
        ]
        metric = lambda value: {"successes": value}
        return {
            "models": {
                "baseline": {
                    "case_results": baseline_rows,
                    "inference_failure_count": 0,
                    "restraint": {"false_list": metric(0)},
                },
                "candidate": {
                    "case_results": candidate_rows,
                    "inference_failure_count": 0,
                    "restraint": {"false_list": metric(int(candidate_false_list))},
                },
            },
            "paired_comparisons": [
                {
                    "left_model": "baseline",
                    "right_model": "candidate",
                    "positive_strict": {
                        "left_only": 0,
                        "right_only": 8,
                        "exact_mcnemar_p_two_sided": 0.0078125,
                    },
                }
            ],
        }

    def test_mechanical_gate_passes_but_keeps_semantic_pending(self) -> None:
        gate = MODULE.mechanical_gate(self._mechanical_report())
        self.assertTrue(gate["mechanical_pass"])
        self.assertFalse(gate["candidate_advances"])
        self.assertEqual(gate["semantic_condition"], "pending_arm_blind_review")

    def test_candidate_only_false_list_fails_gate(self) -> None:
        gate = MODULE.mechanical_gate(self._mechanical_report(candidate_false_list=True))
        condition = gate["mechanical_conditions"][
            "zero_candidate_only_restraint_false_lists"
        ]
        self.assertFalse(condition["pass"])
        self.assertEqual(condition["ids"], ["r"])
        self.assertFalse(gate["mechanical_pass"])

    def test_exact_p_point_zero_five_fails_gate(self) -> None:
        report = self._mechanical_report()
        report["paired_comparisons"][0]["positive_strict"][
            "exact_mcnemar_p_two_sided"
        ] = 0.05
        gate = MODULE.mechanical_gate(report)
        self.assertFalse(
            gate["mechanical_conditions"]["positive_mcnemar_p_below_0_05"]["pass"]
        )
        self.assertFalse(gate["mechanical_pass"])

    def test_seven_net_wins_fails_gate(self) -> None:
        report = self._mechanical_report()
        report["paired_comparisons"][0]["positive_strict"]["right_only"] = 7
        gate = MODULE.mechanical_gate(report)
        self.assertFalse(
            gate["mechanical_conditions"]["positive_net_gain_at_least_8"]["pass"]
        )
        self.assertFalse(gate["mechanical_pass"])

    def test_candidate_only_item_loss_fails_gate(self) -> None:
        report = self._mechanical_report()
        report["models"]["candidate"]["case_results"][0]["items_preserved"] = False
        gate = MODULE.mechanical_gate(report)
        condition = gate["mechanical_conditions"][
            "item_and_scope_loss_not_increased_per_lane"
        ]
        self.assertFalse(condition["pass"])
        self.assertFalse(gate["mechanical_pass"])


if __name__ == "__main__":
    unittest.main()
