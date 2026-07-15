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
MODULE_PATH = EVAL_DIR / "build_eg1_type_b_v2_manifest.py"
SPEC = importlib.util.spec_from_file_location("build_eg1_type_b_v2_manifest", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BuildTypeBV2ManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        self.expected_head = "a" * 40
        self.real_validate_git_state = MODULE.validate_git_state
        self.git_state_patcher = mock.patch.object(
            MODULE, "validate_git_state", return_value=self.expected_head
        )
        self.validate_git_state = self.git_state_patcher.start()

    def tearDown(self) -> None:
        self.git_state_patcher.stop()
        self.temp.cleanup()

    def arguments(self) -> list[str]:
        return [
            str(MODULE_PATH),
            "--out-bundle",
            str(self.bundle),
            "--seed",
            "1265",
            "--expected-git-head",
            self.expected_head,
        ]

    def test_builds_exact_balanced_1890_slot_manifest(self) -> None:
        with mock.patch.object(sys, "argv", self.arguments()):
            self.assertEqual(MODULE.main(), 0)
        receipt = json.loads((self.bundle / "receipt.json").read_text(encoding="utf-8"))
        manifest_bytes = (self.bundle / "manifest.jsonl").read_bytes()
        reserve_bytes = (self.bundle / "replacement_reserves.jsonl").read_bytes()
        rows = [
            json.loads(line)
            for line in manifest_bytes.decode("utf-8").splitlines()
        ]
        reserves = [
            json.loads(line)
            for line in reserve_bytes.decode("utf-8").splitlines()
        ]
        self.assertEqual(len(rows), 1890)
        self.assertEqual(len(reserves), 23)
        self.assertEqual(receipt["fresh_required"], 1867)
        self.assertEqual(receipt["provisional_retained"], 23)
        self.assertEqual(receipt["replacement_reserves"], 23)
        self.assertEqual(receipt["fresh_authorship_total"], 1890)
        self.assertEqual(receipt["all_slot_records"], 1913)
        self.assertEqual(receipt["execution_git_head"], self.expected_head)
        self.assertEqual(self.validate_git_state.call_count, 2)
        self.assertEqual(
            receipt["manifest"]["distributions"]["category"],
            {
                "anti_hallucination": 100,
                "emoji_retention": 100,
                "filler_removal": 100,
                "filler_removal_trap": 100,
                "grammar_fix": 100,
                "list_format": 100,
                "list_format_trap": 100,
                "minimal_edit": 98,
                "multi_behavior": 292,
                "named_entity_preserve": 100,
                "onset_marker": 100,
                "phonetic_homophone": 100,
                "punctuation_caps": 100,
                "self_correction": 100,
                "self_correction_trap": 100,
                "topic_shift": 100,
                "verbatim_passthrough": 100,
            },
        )
        self.assertEqual(receipt["manifest"]["distributions"]["trap"], {"false": 1590, "true": 300})
        self.assertEqual(
            receipt["manifest"]["distributions"]["length_bucket"],
            {"1": 480, "2": 482, "3": 468, "4": 460},
        )
        self.assertEqual(
            receipt["manifest"]["distributions"]["tier"],
            {"harness_A": 900, "mixed": 292, "single": 698},
        )
        self.assertEqual(
            {
                source["path"]: (source["sha256"], source["expected_sha256"])
                for source in receipt["sources"]
            },
            {
                "scripts/eval/corpus/type_b_all_v1.jsonl": (
                    "eb83421b84cd728f8aac96054b4d3518661a40e0c0a33961e3d14b07b118da4d",
                    "eb83421b84cd728f8aac96054b4d3518661a40e0c0a33961e3d14b07b118da4d",
                ),
                "scripts/eval/corpus/type_b_approved_1890.jsonl": (
                    "27993adc574242e6bf2aef7430dbc2c6776ebbb6dd547d61f561d4e693d22a6b",
                    "27993adc574242e6bf2aef7430dbc2c6776ebbb6dd547d61f561d4e693d22a6b",
                ),
                "scripts/eval/corpus/type_b_overflow_900.jsonl": (
                    "1267e5c8ccf84ea745bd2b1bcdcac9d912b8dadb8c14ef76515eee24139759fa",
                    "1267e5c8ccf84ea745bd2b1bcdcac9d912b8dadb8c14ef76515eee24139759fa",
                ),
                "scripts/eval/runs/bakeoff-1265/train_sft_v2.jsonl": (
                    "5afc6b9435c7bef08df17ba3c4edcb889b8329cd7c1520c49d681999a666f568",
                    "5afc6b9435c7bef08df17ba3c4edcb889b8329cd7c1520c49d681999a666f568",
                ),
            },
        )
        self.assertEqual(
            receipt["manifest"]["sha256"], hashlib.sha256(manifest_bytes).hexdigest()
        )
        self.assertEqual(
            receipt["replacement_reserve_manifest"]["sha256"],
            hashlib.sha256(reserve_bytes).hexdigest(),
        )
        self.assertEqual(
            receipt["allocation_contract"]["sha256"],
            hashlib.sha256(MODULE.ALLOCATION_CONTRACT.read_bytes()).hexdigest(),
        )
        self.assertEqual(
            receipt["builder"]["sha256"], hashlib.sha256(MODULE_PATH.read_bytes()).hexdigest()
        )
        self.assertEqual(
            receipt["joint_cells"]["provisional_legacy"],
            receipt["joint_cells"]["replacement_reserve"],
        )
        self.assertEqual(
            receipt["trap_counts"],
            {
                "final_benchmark": 300,
                "fresh_primary": 298,
                "provisional_legacy": 2,
                "replacement_reserve": 2,
            },
        )
        self.assertEqual(len({row["semantic_family_id"] for row in rows}), 1890)
        self.assertEqual(
            len({row["semantic_family_id"] for row in [*rows, *reserves]}), 1913
        )
        self.assertTrue(all(row["candidate_model_output_seen"] is False for row in rows))
        self.assertTrue(
            all(row["candidate_model_output_seen"] is False for row in reserves)
        )
        self.assertTrue(all(row["training_eligible"] is False for row in rows))
        self.assertTrue(all(row["training_eligible"] is False for row in reserves))

    def test_is_byte_deterministic_for_the_sealed_seed(self) -> None:
        with mock.patch.object(sys, "argv", self.arguments()):
            self.assertEqual(MODULE.main(), 0)
        second = self.root / "second"
        arguments = [
            str(MODULE_PATH),
            "--out-bundle",
            str(second),
            "--seed",
            "1265",
            "--expected-git-head",
            self.expected_head,
        ]
        with mock.patch.object(sys, "argv", arguments):
            self.assertEqual(MODULE.main(), 0)
        for name in ("manifest.jsonl", "replacement_reserves.jsonl", "receipt.json"):
            self.assertEqual((self.bundle / name).read_bytes(), (second / name).read_bytes())

    def test_rejects_seed_drift_from_allocation_contract(self) -> None:
        arguments = [
            str(MODULE_PATH),
            "--out-bundle",
            str(self.bundle),
            "--seed",
            "1266",
            "--expected-git-head",
            self.expected_head,
        ]
        with mock.patch.object(sys, "argv", arguments):
            with self.assertRaisesRegex(ValueError, "seed differs"):
                MODULE.main()
        self.assertFalse(self.bundle.exists())

    def test_git_binding_rejects_dirty_tracked_state(self) -> None:
        with mock.patch.object(
            MODULE,
            "git_output",
            side_effect=[
                (self.expected_head + "\n").encode(),
                b" M scripts/eval/build_eg1_type_b_v2_manifest.py\n",
            ],
        ):
            with self.assertRaisesRegex(ValueError, "tracked worktree must be clean"):
                self.real_validate_git_state(self.expected_head)

    def test_git_binding_rejects_live_bytes_not_in_commit(self) -> None:
        with mock.patch.object(
            MODULE,
            "git_output",
            side_effect=[
                (self.expected_head + "\n").encode(),
                b"",
                b"different committed builder bytes",
            ],
        ):
            with self.assertRaisesRegex(ValueError, "committed bytes differ"):
                self.real_validate_git_state(self.expected_head)

    def test_git_binding_rejects_malformed_expected_head(self) -> None:
        with self.assertRaisesRegex(ValueError, "lowercase 40-character SHA-1"):
            self.real_validate_git_state("HEAD")

    def test_rejects_source_drift_before_publication(self) -> None:
        original_read = MODULE.read_once

        def drift(path: Path) -> tuple[bytes, str]:
            value, digest = original_read(path)
            if path == MODULE.APPROVED:
                value += b"\n"
                digest = hashlib.sha256(value).hexdigest()
            return value, digest

        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.object(MODULE, "read_once", side_effect=drift),
        ):
            with self.assertRaisesRegex(ValueError, "source changed"):
                MODULE.main()
        self.assertFalse(self.bundle.exists())

    def test_rejects_allocation_contract_drift(self) -> None:
        original_read = MODULE.read_once

        def drift(path: Path) -> tuple[bytes, str]:
            value, digest = original_read(path)
            if path == MODULE.ALLOCATION_CONTRACT:
                contract = json.loads(value)
                contract["counts"]["fresh_primary"] = 1866
                value = (json.dumps(contract) + "\n").encode()
                digest = hashlib.sha256(value).hexdigest()
            return value, digest

        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.object(MODULE, "read_once", side_effect=drift),
        ):
            with self.assertRaisesRegex(ValueError, "contract counts changed"):
                MODULE.main()
        self.assertFalse(self.bundle.exists())

    def test_receipt_write_failure_removes_partial_bundle(self) -> None:
        original_write = MODULE.write_exclusive

        def fail_receipt(path: Path, value: bytes) -> None:
            if path.name == "receipt.json":
                raise OSError("synthetic receipt write failure")
            original_write(path, value)

        with (
            mock.patch.object(sys, "argv", self.arguments()),
            mock.patch.object(MODULE, "write_exclusive", side_effect=fail_receipt),
        ):
            with self.assertRaisesRegex(OSError, "synthetic receipt write failure"):
                MODULE.main()
        self.assertFalse(self.bundle.exists())

    def test_refuses_existing_bundle_without_touching_it(self) -> None:
        self.bundle.mkdir()
        marker = self.bundle / "keep"
        marker.write_text("keep", encoding="utf-8")
        with mock.patch.object(sys, "argv", self.arguments()):
            with self.assertRaises(SystemExit):
                MODULE.main()
        self.assertEqual(marker.read_text(encoding="utf-8"), "keep")


if __name__ == "__main__":
    unittest.main()
