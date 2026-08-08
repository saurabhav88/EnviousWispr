from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
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

REAL_REPO_ROOT = MODULE.REPO_ROOT


class BuildTypeBV2ManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle"
        self.expected_head = "a" * 40
        self.real_validate_git_state = MODULE.validate_git_state
        self._create_synthetic_repository()
        for patcher in (
            mock.patch.object(MODULE, "REPO_ROOT", self.synthetic_repo),
            mock.patch.object(MODULE, "SCRIPT_PATH", self.synthetic_builder),
            mock.patch.object(
                MODULE, "ALLOCATION_CONTRACT", self.synthetic_allocation
            ),
            mock.patch.object(MODULE, "APPROVED", self.synthetic_sources[0]),
            mock.patch.object(MODULE, "OVERFLOW", self.synthetic_sources[1]),
            mock.patch.object(MODULE, "ALL_TYPE_B", self.synthetic_sources[2]),
            mock.patch.object(MODULE, "TRAINING", self.synthetic_sources[3]),
            mock.patch.object(MODULE, "SOURCE_PATHS", self.synthetic_sources),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.git_state_patcher = mock.patch.object(
            MODULE, "validate_git_state", return_value=self.expected_head
        )
        self.validate_git_state = self.git_state_patcher.start()
        self.addCleanup(self.git_state_patcher.stop)

    def _create_synthetic_repository(self) -> None:
        self.synthetic_repo = self.root / "synthetic-repo"
        self.synthetic_repo.mkdir()
        self.synthetic_builder = (
            self.synthetic_repo / "scripts/eval/build_eg1_type_b_v2_manifest.py"
        )
        self.synthetic_allocation = self.synthetic_repo / Path(
            "scripts/eval/contracts/eg1_type_b_v2_allocation_v1.json"
        )
        self.synthetic_sources = tuple(
            self.synthetic_repo / relative
            for relative in (
                "scripts/eval/corpus/type_b_approved_1890.jsonl",
                "scripts/eval/corpus/type_b_overflow_900.jsonl",
                "scripts/eval/corpus/type_b_all_v1.jsonl",
                "scripts/eval/runs/bakeoff-1265/train_sft_v2.jsonl",
            )
        )
        self.synthetic_builder.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(MODULE_PATH, self.synthetic_builder)
        approved = [
            {
                "id": f"SYN-APP-{index:03d}",
                "category": "list_format_trap" if index <= 300 else "grammar_fix",
                "length_bucket": 1 if index <= 300 else 2,
                "tier": "single",
                "subset": "synthetic",
            }
            for index in range(1, 1891)
        ]
        overflow = [
            {
                "id": f"SYN-OVER-{index:03d}",
                "category": "grammar_fix",
                "length_bucket": 2,
                "tier": "single",
                "subset": "synthetic",
            }
            for index in range(1, 901)
        ]
        all_type_b = [{"id": "SYN-ALL-001", "value": "invented all-source row"}]
        training = [
            {
                "id": "synthetic-training-001",
                "input": "invented training input",
                "output": "invented training output",
            }
        ]
        source_rows = (approved, overflow, all_type_b, training)
        source_hashes: dict[str, str] = {}
        for path, rows in zip(self.synthetic_sources, source_rows, strict=True):
            path.parent.mkdir(parents=True, exist_ok=True)
            value = MODULE.encode_jsonl(rows)
            path.write_bytes(value)
            source_hashes[str(path.relative_to(self.synthetic_repo))] = (
                hashlib.sha256(value).hexdigest()
            )
        provisional_rows = [approved[0], approved[1], *approved[300:321]]
        contract = {
            "schema_version": MODULE.SCHEMA_VERSION,
            "seed": 1265,
            "counts": {
                "final_benchmark": 1890,
                "provisional_legacy": 23,
                "fresh_primary": 1867,
                "replacement_reserve": 23,
                "fresh_authorship_total": 1890,
                "all_slot_records": 1913,
            },
            "trap_counts": {
                "final_benchmark": 300,
                "provisional_legacy": 2,
                "fresh_primary": 298,
                "replacement_reserve": 2,
            },
            "source_sha256": source_hashes,
            "provisional_case_ids": [row["id"] for row in provisional_rows],
            "final_joint_cells": MODULE.joint_cells(approved),
            "provisional_joint_cells": MODULE.joint_cells(provisional_rows),
        }
        self.synthetic_allocation.parent.mkdir(parents=True, exist_ok=True)
        self.synthetic_allocation.write_text(
            json.dumps(contract, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        self.synthetic_source_hashes = source_hashes

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

    def test_builds_balanced_portable_synthetic_slot_manifest(self) -> None:
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
                "grammar_fix": 1590,
                "list_format_trap": 300,
            },
        )
        self.assertEqual(
            receipt["manifest"]["distributions"]["trap"],
            {"false": 1590, "true": 300},
        )
        self.assertEqual(
            receipt["manifest"]["distributions"]["length_bucket"],
            {"1": 300, "2": 1590},
        )
        self.assertEqual(
            receipt["manifest"]["distributions"]["tier"],
            {"single": 1890},
        )
        self.assertEqual(
            {
                source["path"]: (source["sha256"], source["expected_sha256"])
                for source in receipt["sources"]
            },
            {
                path: (digest, digest)
                for path, digest in self.synthetic_source_hashes.items()
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
            receipt["builder"]["sha256"],
            hashlib.sha256(self.synthetic_builder.read_bytes()).hexdigest(),
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
