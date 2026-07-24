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
if str(EVAL_DIR) not in sys.path:
    sys.path.insert(0, str(EVAL_DIR))
MODULE_PATH = EVAL_DIR / "build_eg1_english_list_blind_review.py"
SPEC = importlib.util.spec_from_file_location(
    "build_eg1_english_list_blind_review", MODULE_PATH
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class BuildBlindReviewTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        required_bindings = MODULE.load_contract.__globals__["REQUIRED_BINDINGS"]
        self.bindings = {
            key: ("a" * 40 if key == "code_anchor_git_sha1" else "0" * 64)
            for key in required_bindings
        }
        self.bindings["blind_packet_builder_sha256"] = sha(MODULE_PATH)
        self.bindings["semantic_rubric_sha256"] = sha(MODULE.CANONICAL_RUBRIC)
        self.bindings["semantic_unblinder_sha256"] = sha(MODULE.UNBLINDER_PATH)
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
        self.positive = self.root / "positive.jsonl"
        self.restraint = self.root / "restraint.jsonl"
        self._write_corpus(self.positive, "p")
        self._write_corpus(self.restraint, "r")
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
                    }
                }
            )
            + "\n",
            encoding="utf-8",
        )
        self.ab = self.root / "ab"
        self.ab.mkdir()
        ids = [f"p-{index:03d}" for index in range(75)] + [
            f"r-{index:03d}" for index in range(75)
        ]
        for arm in ("baseline", "candidate"):
            marker = "alpha" if arm == "baseline" else "omega"
            (self.ab / f"{arm}.jsonl").write_text(
                "".join(
                    json.dumps({"id": case_id, "candidate": f"{marker} output {case_id}"})
                    + "\n"
                    for case_id in ids
                ),
                encoding="utf-8",
            )
        self._write_ab_receipt()
        self.packet_parent = self.root / "packet-private"
        self.mapping_parent = self.root / "mapping-private"
        self.packet_parent.mkdir()
        self.mapping_parent.mkdir()
        self.packet = self.packet_parent / "run"
        self.mapping = self.mapping_parent / "run"

    def tearDown(self) -> None:
        self.temp.cleanup()

    @staticmethod
    def _write_corpus(path: Path, prefix: str) -> None:
        path.write_text(
            "".join(
                json.dumps(
                    {
                        "id": f"{prefix}-{index:03d}",
                        "input": f"raw transcript {prefix} {index}",
                        "expected_output": f"private expected answer {prefix} {index}",
                    }
                )
                + "\n"
                for index in range(75)
            ),
            encoding="utf-8",
        )

    def _write_ab_receipt(self) -> None:
        receipt = {
            "status": "connector_wire_exact_ab_complete_semantic_review_pending",
            "scope": {
                "connector_wire_exact": True,
                "certifying_finalist_gate_evidence": False,
                "runtime_binding": (
                    "standalone_noncertifying_discovered_once_for_both_arms"
                ),
                "paste_equivalent": False,
                "model_id": "eg-1",
                "arm_order": ["baseline", "candidate"],
                "same_server_identity_before_and_after_each_arm": True,
                "both_arms_zero_errors_and_empty_outputs": True,
            },
            "runtime": {
                "evaluation_process": {
                    "status": "standalone_noncertifying",
                    "swift": {
                        "launcher_path_sha256": "1" * 64,
                        "launcher_sha256": "2" * 64,
                        "executable_path_sha256": "3" * 64,
                        "executable_sha256": "4" * 64,
                        "environment_sha256": "5" * 64,
                        "developer_dir_sha256": "6" * 64,
                    },
                    "python": {
                        "launcher_path_sha256": "7" * 64,
                        "launcher_sha256": "8" * 64,
                        "executable_path_sha256": "9" * 64,
                        "executable_sha256": "a" * 64,
                    },
                }
            },
            "provenance": {
                "git_head": self.execution_head,
                "expected_git_head": self.execution_head,
                "bindings": self.bindings,
                "render_receipt": {
                    "path": str(self.render_receipt),
                    "sha256": sha(self.render_receipt),
                },
                "sources": {
                    "decision_contract": {
                        "path": str(MODULE.CANONICAL_DECISION_CONTRACT),
                        "sha256": sha(MODULE.CANONICAL_DECISION_CONTRACT),
                    }
                },
            },
            "arms": {
                arm: {
                    "path": f"{arm}.jsonl",
                    "sha256": sha(self.ab / f"{arm}.jsonl"),
                    "row_count": 150,
                    "inference_error_count": 0,
                    "empty_output_count": 0,
                    "runner_returncode": 0,
                    "rendered_prompts_sha256": arm[0] * 64,
                }
                for arm in ("baseline", "candidate")
            },
        }
        (self.ab / "receipt.json").write_text(
            json.dumps(receipt) + "\n", encoding="utf-8"
        )

    def _arguments(self) -> list[str]:
        return [
            str(MODULE_PATH),
            "--positive-corpus",
            str(self.positive),
            "--restraint-corpus",
            str(self.restraint),
            "--ab-bundle",
            str(self.ab),
            "--expected-ab-receipt-sha256",
            sha(self.ab / "receipt.json"),
            "--rubric",
            str(MODULE.CANONICAL_RUBRIC),
            "--expected-rubric-sha256",
            sha(MODULE.CANONICAL_RUBRIC),
            "--packet-bundle",
            str(self.packet),
            "--mapping-bundle",
            str(self.mapping),
            "--seed",
            "1265",
        ]

    def test_builds_gold_free_packet_and_separate_mapping(self) -> None:
        with mock.patch.object(sys, "argv", self._arguments()):
            self.assertEqual(MODULE.main(), 0)
        packet_text = (self.packet / "packet.jsonl").read_text(encoding="utf-8")
        mapping_text = (self.mapping / "mapping.jsonl").read_text(encoding="utf-8")
        packet_rows = [json.loads(line) for line in packet_text.splitlines()]
        mapping_rows = [json.loads(line) for line in mapping_text.splitlines()]
        self.assertEqual(len(packet_rows), 150)
        self.assertEqual(len(mapping_rows), 150)
        self.assertNotIn("private expected answer", packet_text)
        self.assertNotIn("baseline", packet_text)
        self.assertNotIn("candidate", packet_text)
        self.assertEqual(
            set(packet_rows[0]), {"case_id", "raw_transcript", "output_1", "output_2"}
        )
        self.assertEqual(
            {row["output_1_arm"] for row in mapping_rows}, {"baseline", "candidate"}
        )
        packet_receipt = json.loads((self.packet / "receipt.json").read_text())
        mapping_receipt = json.loads((self.mapping / "receipt.json").read_text())
        self.assertFalse(packet_receipt["contains_arm_mapping"])
        self.assertFalse(packet_receipt["contains_expected_answers"])
        self.assertNotIn("seed_hex", packet_receipt)
        self.assertEqual(
            packet_receipt["mapping_receipt_sha256"], sha(self.mapping / "receipt.json")
        )
        self.assertEqual(mapping_receipt["packet_sha256"], sha(self.packet / "packet.jsonl"))
        self.assertEqual(
            mapping_receipt["decision_contract"], packet_receipt["decision_contract"]
        )
        self.assertEqual(
            packet_receipt["decision_contract"]["bindings"], self.bindings
        )
        for lane in ("positive", "restraint"):
            counts = mapping_receipt["lane_assignment_counts"][lane]
            self.assertEqual(counts["baseline_as_output_1"], 38)
            self.assertEqual(counts["candidate_as_output_1"], 37)
        positive_pattern = [row["output_1_arm"] for row in mapping_rows[:75]]
        restraint_pattern = [row["output_1_arm"] for row in mapping_rows[75:]]
        self.assertNotEqual(positive_pattern, restraint_pattern)

    def test_default_seed_is_random_secret_and_public_receipt_is_last(self) -> None:
        arguments = self._arguments()
        del arguments[-2:]
        publication_order: list[Path] = []
        original = MODULE.write_exclusive

        def recording_write(path: Path, value: bytes) -> None:
            publication_order.append(path)
            original(path, value)

        with (
            mock.patch.object(sys, "argv", arguments),
            mock.patch.object(
                MODULE.secrets, "randbits", return_value=(1 << 255) + 17
            ) as random_seed,
            mock.patch.object(MODULE, "write_exclusive", side_effect=recording_write),
        ):
            self.assertEqual(MODULE.main(), 0)
        random_seed.assert_called_once_with(256)
        self.assertEqual(publication_order[-1], self.packet / "receipt.json")
        self.assertLess(
            publication_order.index(self.mapping / "receipt.json"),
            publication_order.index(self.packet / "packet.jsonl"),
        )
        public_receipt = json.loads((self.packet / "receipt.json").read_text())
        private_receipt = json.loads((self.mapping / "receipt.json").read_text())
        self.assertNotIn("seed_hex", public_receipt)
        self.assertEqual(private_receipt["seed_hex"], format((1 << 255) + 17, "064x"))

    def test_source_rehash_failure_cleans_both_transaction_bundles(self) -> None:
        original = MODULE.read_once
        positive_reads = 0

        def changing_source(path: Path, label: str) -> tuple[bytes, str]:
            nonlocal positive_reads
            value, digest = original(path, label)
            if label == "positive corpus":
                positive_reads += 1
                if positive_reads == 2:
                    return value, "f" * 64
            return value, digest

        with (
            mock.patch.object(sys, "argv", self._arguments()),
            mock.patch.object(MODULE, "read_once", side_effect=changing_source),
        ):
            with self.assertRaisesRegex(RuntimeError, "positive corpus changed"):
                MODULE.main()
        self.assertEqual(positive_reads, 2)
        self.assertFalse(self.mapping.exists())
        self.assertFalse(self.packet.exists())

    def test_publication_failure_cleans_private_and_public_bundles(self) -> None:
        original = MODULE.write_exclusive

        def fail_public_receipt(path: Path, value: bytes) -> None:
            if path == self.packet / "receipt.json":
                raise OSError("injected publication failure")
            original(path, value)

        with (
            mock.patch.object(sys, "argv", self._arguments()),
            mock.patch.object(MODULE, "write_exclusive", side_effect=fail_public_receipt),
        ):
            with self.assertRaisesRegex(OSError, "injected publication failure"):
                MODULE.main()
        self.assertFalse(self.mapping.exists())
        self.assertFalse(self.packet.exists())

    def test_rejects_altered_full_contract_binding_in_ab_receipt(self) -> None:
        receipt_path = self.ab / "receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["provenance"]["bindings"]["renderer_sha256"] = "f" * 64
        receipt_path.write_text(json.dumps(receipt) + "\n", encoding="utf-8")
        with mock.patch.object(sys, "argv", self._arguments()):
            with self.assertRaisesRegex(
                ValueError, "bindings differ from the executable decision contract"
            ):
                MODULE.main()
        self.assertFalse(self.mapping.exists())
        self.assertFalse(self.packet.exists())

    def test_rejects_missing_or_tampered_noncertifying_runtime_proof(self) -> None:
        def remove_evaluation_process(receipt: dict[str, object]) -> None:
            del receipt["runtime"]["evaluation_process"]  # type: ignore[index]

        def tamper_python_executable_hash(receipt: dict[str, object]) -> None:
            receipt["runtime"]["evaluation_process"]["python"][  # type: ignore[index]
                "executable_sha256"
            ] = "A" * 64

        for label, mutate in (
            ("missing evaluation process", remove_evaluation_process),
            ("tampered Python executable hash", tamper_python_executable_hash),
        ):
            with self.subTest(label=label):
                self._write_ab_receipt()
                receipt_path = self.ab / "receipt.json"
                receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                mutate(receipt)
                receipt_path.write_text(json.dumps(receipt) + "\n", encoding="utf-8")
                with mock.patch.object(sys, "argv", self._arguments()):
                    with self.assertRaisesRegex(ValueError, "runtime identity is invalid"):
                        MODULE.main()
                self.assertFalse(self.mapping.exists())
                self.assertFalse(self.packet.exists())

    def test_refuses_existing_packet_without_touching_it(self) -> None:
        self.packet.mkdir()
        marker = self.packet / "keep"
        marker.write_text("keep", encoding="utf-8")
        with mock.patch.object(sys, "argv", self._arguments()):
            with self.assertRaises(SystemExit):
                MODULE.main()
        self.assertEqual(marker.read_text(encoding="utf-8"), "keep")
        self.assertFalse(self.mapping.exists())


if __name__ == "__main__":
    unittest.main()
