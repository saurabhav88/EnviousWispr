#!/usr/bin/env python3
from __future__ import annotations

import copy
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


EVAL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVAL_DIR))

import assemble_eg1_english_list_pilot as assembler  # noqa: E402
import generate_eg1_english_list_benchmark as benchmark  # noqa: E402


SEALED_MANIFEST = (
    assembler.REPO_ROOT
    / "scripts/eval/corpus/eg1_english_list_pilot75_v1.predeclared.manifest.json"
)


def audit_text(
    value: str,
    *,
    field: str = "input",
    role: str | None = None,
    batch: int | None = None,
    kind: str = "sealed_source",
    source_id: str = "source-1",
) -> assembler.AuditText:
    return assembler.make_audit_text(
        "source.jsonl",
        source_id,
        field,
        value,
        source_kind=kind,
        role=role,
        batch=batch,
    )


def minimal_receipt() -> dict:
    pass_value = {
        "pair_comparison_count": 1,
        "field_pair_comparison_counts": {"input->input": 1},
        "relation_comparison_counts": {"sealed_source": 1},
        "axis_maxima": {},
    }
    return {
        "status": "pass",
        "created_at_epoch": 1.0,
        "assembly_parameters": {"batch_id": "test"},
        "selection_manifest": {"path": "scripts/eval/selection.json"},
        "selection_verification": {},
        "portable_replay": {},
        "generator": {"path": "scripts/eval/generator.py"},
        "assembler": {"path": "scripts/eval/assembler.py"},
        "audit_sources": [],
        "checkpoints": {},
        "outputs": {},
        "leakage_validation": {
            "assembly_pass": pass_value,
            "written_bytes_pass": copy.deepcopy(pass_value),
        },
        "publication": {"commit_marker_path": "bundle/receipt.json"},
    }


class SelectionVerificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.manifest = json.loads(SEALED_MANIFEST.read_text(encoding="utf-8"))

    def test_recomputes_canonical_definition_and_first_n(self) -> None:
        verification = assembler.verify_sealed_selection(
            copy.deepcopy(self.manifest), self.manifest["pilot_definition_sha256"]
        )
        self.assertTrue(verification.receipt["regenerated_first_n_matches"])
        self.assertTrue(verification.receipt["definition_hash_matches_expected_and_sealed"])
        self.assertFalse(verification.receipt["live_generator_matches_sealed"])
        self.assertTrue(verification.receipt["sealed_generator_proof_matches"])

    def test_historical_generator_snapshot_matches_sealed_hash(self) -> None:
        historical = (
            assembler.HISTORICAL_GENERATOR_DIR
            / f"generate_eg1_english_list_benchmark.{self.manifest['generator_sha256'][:8]}.py"
        )
        self.assertEqual(
            benchmark.file_sha256(historical),
            self.manifest["generator_sha256"],
        )

    def test_rejects_non_first_n_selection(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["selected_specs"]["positive_list"][0], manifest["selected_specs"][
            "positive_list"
        ][1] = (
            manifest["selected_specs"]["positive_list"][1],
            manifest["selected_specs"]["positive_list"][0],
        )
        with self.assertRaisesRegex(ValueError, "not the regenerated first N"):
            assembler.verify_sealed_selection(
                manifest, self.manifest["pilot_definition_sha256"]
            )

    def test_rejects_wrong_model_blind_flag(self) -> None:
        manifest = copy.deepcopy(self.manifest)
        manifest["model_blind"] = False
        with self.assertRaisesRegex(ValueError, "flags differ"):
            assembler.verify_sealed_selection(
                manifest, self.manifest["pilot_definition_sha256"]
            )

    def test_rejects_wrong_definition_hash(self) -> None:
        with self.assertRaisesRegex(ValueError, "canonical pilot definition SHA mismatch"):
            assembler.verify_sealed_selection(copy.deepcopy(self.manifest), "0" * 64)

    def test_portable_replay_lexically_remaps_old_repo(self) -> None:
        old_root = Path("/old/machine/EnviousWispr")
        sealed = old_root / "scripts/eval/corpus/source.jsonl"
        self.assertEqual(
            assembler.remap_sealed_path(str(sealed), old_root),
            assembler.REPO_ROOT / "scripts/eval/corpus/source.jsonl",
        )


class LeakageTests(unittest.TestCase):
    def test_generated_input_is_screened_against_source_output(self) -> None:
        blocked = [
            audit_text(
                "send the signed contract to legal by Friday afternoon",
                field="expected_output",
            )
        ]
        with self.assertRaisesRegex(
            ValueError, r"candidate-1\.input.*source-1\.expected_output"
        ):
            assembler.screen_candidate_texts(
                "candidate-1",
                "positive_list",
                1,
                {"input": "Send the signed contract to legal by Friday afternoon."},
                blocked,
                assembler.ComparisonStats(),
            )

    def test_each_fuzzy_axis_independently_blocks(self) -> None:
        blocked = [audit_text("unrelated source material")]
        for axis in benchmark.SIMILARITY_THRESHOLDS:
            with self.subTest(axis=axis):
                scores = {name: 0.0 for name in benchmark.SIMILARITY_THRESHOLDS}
                scores[axis] = benchmark.SIMILARITY_THRESHOLDS[axis]
                with patch.object(benchmark, "similarity", return_value=(scores[axis], scores)):
                    with self.assertRaisesRegex(ValueError, axis):
                        assembler.screen_candidate_texts(
                            "candidate-axis",
                            "positive_list",
                            1,
                            {"expected_output": "different candidate material"},
                            blocked,
                            assembler.ComparisonStats(),
                        )

    def test_cross_batch_and_cross_role_comparisons_are_counted(self) -> None:
        blocked = [
            audit_text(
                "archive the deployment notes after launch",
                kind="generated",
                role="positive_list",
                batch=1,
                source_id="positive-1",
            ),
            audit_text(
                "record the garden soil temperature before planting",
                kind="generated",
                role="prose_restraint",
                batch=1,
                source_id="restraint-1",
            ),
        ]
        stats = assembler.ComparisonStats()
        assembler.screen_candidate_texts(
            "candidate-2",
            "positive_list",
            2,
            {"input": "renew the parking permit before the end of August"},
            blocked,
            stats,
        )
        receipt = stats.as_receipt()
        self.assertGreater(receipt["relation_comparison_counts"]["cross_batch_same_role"], 0)
        self.assertGreater(receipt["relation_comparison_counts"]["cross_role"], 0)
        self.assertTrue(receipt["cross_batch_same_role_screened"])
        self.assertTrue(receipt["cross_role_screened"])

    def test_source_snapshot_loads_all_family_aliases_and_output_fields(self) -> None:
        rows = [
            {"id": "a", "family": "family alias", "input": "alpha input", "output": "alpha output"},
            {"id": "b", "origin": "origin alias", "asr_input": "bravo input", "expected_output": "bravo output"},
            {"id": "c", "family_id": "family id alias", "raw": "charlie input", "gold": "charlie output"},
            {"id": "d", "semantic_family_id": "semantic alias", "transcript": "delta input", "polished": "delta output"},
        ]
        test_parent = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(dir=test_parent) as raw_directory:
            directory = Path(raw_directory)
            source = directory / "source.jsonl"
            source.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
            relative = source.resolve().relative_to(assembler.REPO_ROOT)
            old_root = Path("/old/repo")
            manifest = {
                "audit_sources": [
                    {
                        "path": str(old_root / relative),
                        "role": "test",
                        "sha256": benchmark.file_sha256(source),
                    }
                ]
            }
            verification = assembler.SelectionVerification(old_root, [], [], {})
            texts, structural, families, inventories = assembler.snapshot_sources(
                manifest,
                verification,
                directory / "snapshots",
                assembler.REPO_ROOT / "scripts/eval/corpus/test-snapshots",
            )
        self.assertEqual(len(texts), 8)
        self.assertEqual(len(structural), 4)
        self.assertEqual(inventories[0]["text_count"], 8)
        self.assertEqual(len(families), 4)


class SnapshotAndPublicationTests(unittest.TestCase):
    def test_audit_inventory_hashes_the_same_bytes_it_parses(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            path = Path(raw_directory) / "source.jsonl"
            first = b'{"id":"first","input":"first source text"}\n'
            second = b'{"id":"second","input":"replacement source text"}\n'
            path.write_bytes(first)
            with patch.object(Path, "read_bytes", side_effect=[first, second]) as read:
                inputs, inventories, _ = benchmark.load_audit_sources([str(path)])
            self.assertEqual(read.call_count, 1)
            self.assertEqual(inventories[0]["sha256"], benchmark.sha256_bytes(first))
            self.assertEqual(inputs[0].source_id, "first")

    def test_generator_refuses_existing_jsonl_without_changing_it(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            path = Path(raw_directory) / "cases.jsonl"
            path.write_text("keep\n", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                benchmark.write_jsonl(path, [{"id": "new"}])
            self.assertEqual(path.read_text(encoding="utf-8"), "keep\n")

    def test_generator_short_write_leaves_no_final_file(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            path = root / "cases.jsonl"

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
                patch.object(
                    benchmark.os,
                    "fdopen",
                    side_effect=lambda fd, _mode: FailingHandle(fd),
                ),
                self.assertRaisesRegex(OSError, "injected short write"),
            ):
                benchmark.write_jsonl(path, [{"id": "new"}])
            self.assertFalse(path.exists())
            self.assertEqual(list(root.glob(".cases.jsonl.*")), [])

    def test_source_mutation_after_sealing_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            path = Path(raw_directory) / "source.jsonl"
            path.write_text('{"input":"before"}\n', encoding="utf-8")
            expected = benchmark.file_sha256(path)
            path.write_text('{"input":"after"}\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "SHA mismatch"):
                assembler.read_once(path, expected, "audit source")

    def test_existing_bundle_is_never_touched(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            temp_bundle = root / "temp"
            final_bundle = root / "final"
            temp_bundle.mkdir()
            (temp_bundle / "member.txt").write_text("new", encoding="utf-8")
            final_bundle.mkdir()
            sentinel = final_bundle / "sentinel.txt"
            sentinel.write_text("keep", encoding="utf-8")
            with self.assertRaises(FileExistsError):
                assembler.publish_bundle(
                    temp_bundle,
                    final_bundle,
                    b"{}\n",
                    {"member.txt": assembler.sha256_bytes(b"new")},
                )
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep")

    def test_pre_receipt_failure_cleans_only_invocation_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            temp_bundle = root / "temp"
            final_bundle = root / "final"
            unrelated = root / "unrelated.txt"
            temp_bundle.mkdir()
            (temp_bundle / "member.txt").write_text("new", encoding="utf-8")
            unrelated.write_text("keep", encoding="utf-8")

            def fail() -> None:
                self.assertFalse((final_bundle / assembler.RECEIPT_NAME).exists())
                raise RuntimeError("injected pre-receipt failure")

            with self.assertRaisesRegex(RuntimeError, "injected"):
                assembler.publish_bundle(
                    temp_bundle,
                    final_bundle,
                    b"{}\n",
                    {"member.txt": assembler.sha256_bytes(b"new")},
                    before_receipt=fail,
                )
            self.assertFalse(final_bundle.exists())
            self.assertEqual(unrelated.read_text(encoding="utf-8"), "keep")

    def test_receipt_is_written_last_as_commit_marker(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            root = Path(raw_directory)
            temp_bundle = root / "temp"
            final_bundle = root / "final"
            temp_bundle.mkdir()
            (temp_bundle / "member.txt").write_text("new", encoding="utf-8")

            def before_receipt() -> None:
                self.assertTrue((final_bundle / "member.txt").is_file())
                self.assertFalse((final_bundle / assembler.RECEIPT_NAME).exists())

            assembler.publish_bundle(
                temp_bundle,
                final_bundle,
                b"{}\n",
                {"member.txt": assembler.sha256_bytes(b"new")},
                before_receipt=before_receipt,
            )
            self.assertTrue((final_bundle / assembler.RECEIPT_NAME).is_file())


class ReceiptTests(unittest.TestCase):
    def test_required_receipt_fields_pass(self) -> None:
        receipt = minimal_receipt()
        assembler.validate_receipt(receipt)
        self.assertTrue(assembler.receipt_paths_are_relative(receipt))

    def test_missing_batch_id_fails(self) -> None:
        receipt = minimal_receipt()
        receipt["assembly_parameters"].pop("batch_id")
        with self.assertRaisesRegex(ValueError, "batch_id"):
            assembler.validate_receipt(receipt)

    def test_absolute_receipt_path_fails(self) -> None:
        receipt = minimal_receipt()
        receipt["outputs"] = {"positive": {"path": "/absolute/output.jsonl"}}
        with self.assertRaisesRegex(ValueError, "absolute path"):
            assembler.validate_receipt(receipt)


if __name__ == "__main__":
    unittest.main()
