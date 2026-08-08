from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


EVAL_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = EVAL_DIR / "unblind_eg1_english_list_semantic_review.py"
SPEC = importlib.util.spec_from_file_location(
    "unblind_eg1_english_list_semantic_review", MODULE_PATH
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class UnblindSemanticReviewTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        required_bindings = MODULE.load_contract.__globals__["REQUIRED_BINDINGS"]
        self.bindings = {
            key: ("a" * 40 if key == "code_anchor_git_sha1" else "0" * 64)
            for key in required_bindings
        }
        for key, path in MODULE.BOUND_HASH_PATHS.items():
            self.bindings[key] = sha(path)
        self.contract_sha = sha(MODULE.CANONICAL_DECISION_CONTRACT)
        self.execution_head = "b" * 40
        self.load_contract_patcher = mock.patch.object(
            MODULE,
            "load_contract",
            return_value=(
                MODULE.CANONICAL_DECISION_CONTRACT.read_bytes(),
                self.contract_sha,
                self.bindings,
            ),
        )
        self.binding_commit_patcher = mock.patch.object(
            MODULE, "validate_binding_commit", return_value=self.execution_head
        )
        self.load_contract_patcher.start()
        self.binding_commit_patcher.start()
        self.addCleanup(self.load_contract_patcher.stop)
        self.addCleanup(self.binding_commit_patcher.stop)
        self.packet = self.root / "packet"
        self.mapping = self.root / "mapping"
        self.packet.mkdir()
        self.mapping.mkdir()
        packet_rows = [
            {"case_id": "c1", "raw_transcript": "raw one", "output_1": "x", "output_2": "y"},
            {"case_id": "c2", "raw_transcript": "raw two", "output_1": "x", "output_2": "y"},
        ]
        mapping_rows = [
            {"case_id": "c1", "output_1_arm": "baseline", "output_2_arm": "candidate"},
            {"case_id": "c2", "output_1_arm": "candidate", "output_2_arm": "baseline"},
        ]
        self._write_jsonl(self.packet / "packet.jsonl", packet_rows)
        self._write_jsonl(self.mapping / "mapping.jsonl", mapping_rows)
        contract_record = {
            "sha256": self.contract_sha,
            "bindings": self.bindings,
            "execution_git_head": self.execution_head,
        }
        mapping_receipt = {
            "status": "sealed_arm_mapping_ready_for_post_review_unblind",
            "case_count": 2,
            "explicit_arm_names": ["baseline", "candidate"],
            "packet_sha256": sha(self.packet / "packet.jsonl"),
            "ab_receipt_sha256": "a" * 64,
            "decision_contract": contract_record,
            "mapping": {"path": "mapping.jsonl", "sha256": sha(self.mapping / "mapping.jsonl")},
        }
        (self.mapping / "receipt.json").write_text(
            json.dumps(mapping_receipt) + "\n", encoding="utf-8"
        )
        packet_receipt = {
            "status": "arm_blind_semantic_packet_ready",
            "case_count": 2,
            "packet": {"path": "packet.jsonl", "sha256": sha(self.packet / "packet.jsonl")},
            "mapping_receipt_sha256": sha(self.mapping / "receipt.json"),
            "mapping_sha256": sha(self.mapping / "mapping.jsonl"),
            "ab_receipt_sha256": "a" * 64,
            "decision_contract": contract_record,
        }
        (self.packet / "receipt.json").write_text(
            json.dumps(packet_receipt) + "\n", encoding="utf-8"
        )
        self.judgments = self.root / "judgments.jsonl"
        self.out = self.root / "report.json"

    def tearDown(self) -> None:
        self.temp.cleanup()

    @staticmethod
    def _write_jsonl(path: Path, rows: list[dict[str, object]]) -> None:
        path.write_text(
            "".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8"
        )

    @staticmethod
    def judgment(case_id: str, label: str, severity: str) -> dict[str, object]:
        return {
            "case_id": case_id,
            "label": label,
            "meaning_damage": severity in {"S2", "S3", "S4"},
            "severity": severity,
            "tags": [] if severity in {"S0", "S1"} else ["scope"],
            "note": "independent judgment",
        }

    def arguments(self) -> list[str]:
        return [
            str(MODULE_PATH),
            "--packet-bundle",
            str(self.packet),
            "--mapping-bundle",
            str(self.mapping),
            "--judgments",
            str(self.judgments),
            "--expected-packet-receipt-sha256",
            sha(self.packet / "receipt.json"),
            "--expected-mapping-receipt-sha256",
            sha(self.mapping / "receipt.json"),
            "--out",
            str(self.out),
        ]

    def test_validates_complete_coverage_and_detects_candidate_only_damage(self) -> None:
        self._write_jsonl(
            self.judgments,
            [
                self.judgment("c1", "output_1", "S0"),
                self.judgment("c1", "output_2", "S3"),
                self.judgment("c2", "output_1", "S0"),
                self.judgment("c2", "output_2", "S0"),
            ],
        )
        with mock.patch.object(sys, "argv", self.arguments()):
            self.assertEqual(MODULE.main(), 0)
        report = json.loads(self.out.read_text(encoding="utf-8"))
        self.assertTrue(report["coverage_complete"])
        self.assertEqual(report["candidate_only_meaning_damage_ids"], ["c1"])
        self.assertEqual(report["candidate_worse_severity_ids"], ["c1"])
        self.assertFalse(report["semantic_advancement_condition_pass"])

    def test_missing_judgment_fails_before_unblinding_output(self) -> None:
        self._write_jsonl(
            self.judgments,
            [
                self.judgment("c1", "output_1", "S0"),
                self.judgment("c1", "output_2", "S0"),
                self.judgment("c2", "output_1", "S0"),
            ],
        )
        arguments = self.arguments()
        original_read_bytes = Path.read_bytes

        def reject_mapping_read(path: Path) -> bytes:
            if path == self.mapping / "receipt.json" or path == self.mapping / "mapping.jsonl":
                raise AssertionError("mapping was read before judgment validation completed")
            return original_read_bytes(path)

        with (
            mock.patch.object(sys, "argv", arguments),
            mock.patch.object(Path, "read_bytes", new=reject_mapping_read),
        ):
            with self.assertRaisesRegex(ValueError, "coverage mismatch"):
                MODULE.main()
        self.assertFalse(self.out.exists())

    def test_duplicate_judgment_fails(self) -> None:
        row = self.judgment("c1", "output_1", "S0")
        self._write_jsonl(self.judgments, [row, row])
        with mock.patch.object(sys, "argv", self.arguments()):
            with self.assertRaisesRegex(ValueError, "duplicate judgment"):
                MODULE.main()

    def test_malformed_judgment_fails_before_mapping_read(self) -> None:
        rows = [
            self.judgment("c1", "output_1", "S0"),
            self.judgment("c1", "output_2", "S0"),
            self.judgment("c2", "output_1", "S0"),
            self.judgment("c2", "output_2", "S0"),
        ]
        rows[0]["severity"] = []
        self._write_jsonl(self.judgments, rows)
        arguments = self.arguments()
        original_read_bytes = Path.read_bytes

        def reject_mapping_read(path: Path) -> bytes:
            if path == self.mapping / "receipt.json" or path == self.mapping / "mapping.jsonl":
                raise AssertionError("mapping was read before judgment validation completed")
            return original_read_bytes(path)

        with (
            mock.patch.object(sys, "argv", arguments),
            mock.patch.object(Path, "read_bytes", new=reject_mapping_read),
        ):
            with self.assertRaisesRegex(ValueError, "damage/severity is invalid"):
                MODULE.main()
        self.assertFalse(self.out.exists())

    def test_candidate_worse_requires_candidate_damage_and_higher_severity(self) -> None:
        self._write_jsonl(
            self.judgments,
            [
                self.judgment("c1", "output_1", "S0"),
                self.judgment("c1", "output_2", "S1"),
                self.judgment("c2", "output_1", "S3"),
                self.judgment("c2", "output_2", "S2"),
            ],
        )
        with mock.patch.object(sys, "argv", self.arguments()):
            self.assertEqual(MODULE.main(), 0)
        report = json.loads(self.out.read_text(encoding="utf-8"))
        self.assertEqual(report["candidate_worse_severity_ids"], ["c2"])
        self.assertNotIn("c1", report["candidate_worse_severity_ids"])
        self.assertFalse(report["semantic_advancement_condition_pass"])

    def test_harmless_candidate_severity_increase_does_not_fail_semantic_gate(self) -> None:
        self._write_jsonl(
            self.judgments,
            [
                self.judgment("c1", "output_1", "S0"),
                self.judgment("c1", "output_2", "S1"),
                self.judgment("c2", "output_1", "S0"),
                self.judgment("c2", "output_2", "S0"),
            ],
        )
        with mock.patch.object(sys, "argv", self.arguments()):
            self.assertEqual(MODULE.main(), 0)
        report = json.loads(self.out.read_text(encoding="utf-8"))
        self.assertEqual(report["candidate_worse_severity_ids"], [])
        self.assertTrue(report["semantic_advancement_condition_pass"])

    def test_atomic_publication_failure_leaves_no_report_or_temporary_file(self) -> None:
        self._write_jsonl(
            self.judgments,
            [
                self.judgment("c1", "output_1", "S0"),
                self.judgment("c1", "output_2", "S0"),
                self.judgment("c2", "output_1", "S0"),
                self.judgment("c2", "output_2", "S0"),
            ],
        )
        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.object(MODULE.os, "link", side_effect=OSError("injected link failure")),
        ):
            with self.assertRaisesRegex(OSError, "injected link failure"):
                MODULE.main()
        self.assertFalse(self.out.exists())
        self.assertEqual(list(self.root.glob(f".{self.out.name}.*.tmp")), [])


if __name__ == "__main__":
    unittest.main()
