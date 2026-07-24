#!/usr/bin/env python3
"""Fail-closed tests for D1 language authoring packets.

All completed-row strings are disposable validator fixtures written only under
a temporary directory. They are not training examples.
"""

from __future__ import annotations

import copy
import sys
import tempfile
import unittest
from pathlib import Path


EVAL_DIR = Path(__file__).resolve().parents[1]
TESTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(EVAL_DIR))
sys.path.insert(0, str(TESTS_DIR))

import build_eg1_multilingual_d1 as d1  # noqa: E402
from test_build_eg1_multilingual_d1 import (  # noqa: E402
    CONTRACT_PATH,
    make_rows,
    trusted_shared_concept_history,
    write_shared_concept_seal,
    write_launch_bundle,
    write_json,
    write_jsonl,
)


class D1AuthoringPacketTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.contract = d1.read_json(CONTRACT_PATH)
        cls.slots = d1.build_slots(cls.contract)

    def prepare(
        self, root: Path, *, bind_shared_concepts: bool = True
    ) -> tuple[Path, Path | None, dict[str, Path]]:
        if bind_shared_concepts:
            shared_path = write_shared_concept_seal(
                root / "shared-seal", self.slots
            )
        else:
            shared_path = None
        packet_dir = root / "packets"
        with trusted_shared_concept_history():
            d1.write_authoring_packets(
                contract_path=CONTRACT_PATH,
                output_dir=packet_dir,
                shared_registry_path=shared_path,
            )
        if shared_path:
            write_launch_bundle(
                root,
                contract_path=CONTRACT_PATH,
                packet_dir=packet_dir,
                shared_path=shared_path,
            )
        rows = make_rows(self.slots, approved=False)
        completed: dict[str, Path] = {}
        for language in self.contract["languages"]:
            path = root / f"{language}.completed.jsonl"
            write_jsonl(path, [row for row in rows if row["language"] == language])
            completed[language] = path
        return packet_dir, shared_path, completed

    def merge(
        self,
        root: Path,
        packet_dir: Path,
        shared_path: Path | None,
        completed: dict[str, Path],
    ) -> dict[str, object]:
        with trusted_shared_concept_history():
            return d1.merge_authoring_packets(
                contract_path=CONTRACT_PATH,
                packet_receipt_path=packet_dir / "authoring-packet-receipt.json",
                completed_packets=completed,
                shared_registry_path=shared_path,
                launch_assignments_path=root / "authoring-launch" / "assignments.jsonl",
                launch_receipt_path=root / "authoring-launch" / "receipt.json",
                output_path=root / "merged.jsonl",
                merge_receipt_path=root / "merge-receipt.json",
            )

    def test_writes_five_hashed_400_row_packets_and_merges_once(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            packet_dir, shared_path, completed = self.prepare(root)
            receipt = d1.read_json(packet_dir / "authoring-packet-receipt.json")
            self.assertEqual(receipt["schema_version"], d1.PACKET_RECEIPT_SCHEMA)
            self.assertEqual(receipt["total_rows"], 2000)
            self.assertEqual(len(receipt["packets"]), 5)
            self.assertEqual(receipt["shared_concept_authoring"]["status"], "sealed")
            self.assertEqual(
                {path.name for path in packet_dir.iterdir()},
                {
                    "authoring-packet-receipt.json",
                    *(packet["filename"] for packet in receipt["packets"]),
                },
            )
            for packet in receipt["packets"]:
                path = packet_dir / packet["filename"]
                self.assertEqual(len(d1.read_jsonl(path)), 400)
                self.assertEqual(d1.sha256_file(path), packet["packet_sha256"])

            merge_receipt = self.merge(root, packet_dir, shared_path, completed)
            self.assertEqual(merge_receipt["schema_version"], d1.MERGE_RECEIPT_SCHEMA)
            self.assertEqual(merge_receipt["row_count"], 2000)
            self.assertEqual(len(d1.read_jsonl(root / "merged.jsonl")), 2000)

    def test_missing_family_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            packet_dir, shared_path, completed = self.prepare(root)
            language = self.contract["languages"][0]
            rows = d1.read_jsonl(completed[language])
            write_jsonl(completed[language], rows[:-1])
            with self.assertRaisesRegex(d1.ValidationFailure, "expected 400 completed rows"):
                self.merge(root, packet_dir, shared_path, completed)

    def test_duplicate_family_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            packet_dir, shared_path, completed = self.prepare(root)
            language = self.contract["languages"][0]
            rows = d1.read_jsonl(completed[language])
            rows[-1] = copy.deepcopy(rows[0])
            write_jsonl(completed[language], rows)
            with self.assertRaisesRegex(d1.ValidationFailure, "duplicate completed family_id"):
                self.merge(root, packet_dir, shared_path, completed)

    def test_cross_language_row_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            packet_dir, shared_path, completed = self.prepare(root)
            language = self.contract["languages"][0]
            rows = d1.read_jsonl(completed[language])
            rows[0]["language"] = self.contract["languages"][1]
            write_jsonl(completed[language], rows)
            with self.assertRaisesRegex(d1.ValidationFailure, "wrong language packet"):
                self.merge(root, packet_dir, shared_path, completed)

    def test_allocated_slot_tamper_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            packet_dir, shared_path, completed = self.prepare(root)
            language = self.contract["languages"][0]
            rows = d1.read_jsonl(completed[language])
            rows[0]["domain"] = "tampered-domain"
            write_jsonl(completed[language], rows)
            with self.assertRaisesRegex(d1.ValidationFailure, "allocated domain changed"):
                self.merge(root, packet_dir, shared_path, completed)

    def test_packet_receipt_tamper_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            packet_dir, shared_path, completed = self.prepare(root)
            receipt_path = packet_dir / "authoring-packet-receipt.json"
            receipt = d1.read_json(receipt_path)
            receipt["packets"][0]["packet_sha256"] = "0" * 64
            write_json(receipt_path, receipt)
            with self.assertRaisesRegex(
                d1.ValidationFailure, "authoring packet receipt does not match"
            ):
                self.merge(root, packet_dir, shared_path, completed)

    def test_author_or_reviewer_change_from_launch_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            packet_dir, shared_path, completed = self.prepare(root)
            language = self.contract["languages"][0]
            rows = d1.read_jsonl(completed[language])
            rows[0]["source_provenance"]["author_id"] = "fixture-substitute-author"
            rows[1]["native_reviewed"] = True
            rows[1]["native_review"].update(
                {
                    "status": "approved",
                    "reviewer_id": "fixture-substitute-reviewer",
                    "reviewer_type": "human_native",
                    "reviewer_language": language,
                    "reviewed_at": "2026-07-15T05:00:00Z",
                }
            )
            write_jsonl(completed[language], rows)
            with self.assertRaisesRegex(
                d1.ValidationFailure, "differs from launch assignment"
            ):
                self.merge(root, packet_dir, shared_path, completed)

    def test_opaque_shared_id_without_brief_registry_cannot_merge_or_validate(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            packet_dir, shared_path, completed = self.prepare(
                root, bind_shared_concepts=False
            )
            receipt = d1.read_json(packet_dir / "authoring-packet-receipt.json")
            self.assertEqual(receipt["shared_concept_authoring"]["status"], "blocked")
            with self.assertRaisesRegex(
                d1.ValidationFailure, "sealed shared-concept bundle is required"
            ):
                self.merge(root, packet_dir, shared_path, completed)

            rows = make_rows(self.slots, approved=False)
            errors, _, _ = d1.validate_candidate_rows(
                self.contract,
                self.slots,
                rows,
                {
                    "exact_family_ids": [],
                    "family_prefixes": [],
                    "semantic_origin_ids": [],
                    "normalized_input_sha256": [],
                    "normalized_output_sha256": [],
                },
                shared_concept_bindings=None,
            )
            self.assertTrue(
                any(
                    "opaque shared-concept ID has no sealed brief binding" in error
                    for error in errors
                )
            )


if __name__ == "__main__":
    unittest.main()
