from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


EVAL_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = EVAL_DIR / "calibrate_eg1_leakage_thresholds.py"
SPEC = importlib.util.spec_from_file_location("calibrate_eg1_leakage_thresholds", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
GENERATOR_PATH = EVAL_DIR / "generate_eg1_leakage_calibration_scores.py"
GENERATOR_SPEC = importlib.util.spec_from_file_location("eg1_score_generator", GENERATOR_PATH)
assert GENERATOR_SPEC and GENERATOR_SPEC.loader
GENERATOR = importlib.util.module_from_spec(GENERATOR_SPEC)
GENERATOR_SPEC.loader.exec_module(GENERATOR)
CONTRACT_BYTES = MODULE.DEFAULT_CONTRACT.read_bytes()
CONTRACT = MODULE.validate_contract(json.loads(CONTRACT_BYTES))


def score_rows(
    split: str,
    family_count: int,
    *,
    positive: float,
    negative: float,
    family_prefix: str,
    wave_prefix: str,
) -> bytes:
    rows = []
    for language in CONTRACT["languages"]:
        for family_index in range(family_count):
            family_id = f"{family_prefix}-{language}-{family_index:03d}"
            length = CONTRACT["length_strata"][family_index % len(CONTRACT["length_strata"])]
            behavior = CONTRACT["behaviors"][family_index % len(CONTRACT["behaviors"])]
            wave = f"{wave_prefix}-{family_index % 2}"
            for axis in CONTRACT["axes"]:
                for label, value in (
                    ("related_positive", positive),
                    ("hard_negative", negative),
                ):
                    rows.append(
                        {
                            "schema_version": MODULE.SCORE_SCHEMA,
                            "row_id": f"row-{split}-{language}-{family_index:03d}-{axis}-{label}",
                            "family_component_id": family_id,
                            "source_wave_id": wave,
                            "split": split,
                            "language": language,
                            "axis": axis,
                            "length_stratum": length,
                            "behavior": behavior,
                            "label": label,
                            "is_max_neighbor": label == "hard_negative",
                            "reference_family_count": 500,
                            "scores": {method: value for method in CONTRACT["methods"]},
                        }
                    )
    return b"".join(MODULE.canonical_json(row) for row in rows)


class LeakageCalibrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.git_patchers = []
        try:
            subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=MODULE.REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except subprocess.CalledProcessError:
            fixture_head = "a" * 40

            def archive_git_output(arguments):
                if arguments == ["rev-parse", "HEAD"]:
                    return fixture_head.encode()
                if arguments == ["show", f"{fixture_head}:{MODULE.TOOL_REPO_PATH}"]:
                    return MODULE.SCRIPT_PATH.read_bytes()
                if arguments == ["show", f"{fixture_head}:{MODULE.CONTRACT_REPO_PATH}"]:
                    return CONTRACT_BYTES
                raise AssertionError(f"unexpected archive git command: {arguments}")

            def archive_validate_provenance(receipt):
                expected = {
                    "producing_git_head": fixture_head,
                    "tool_path": MODULE.TOOL_REPO_PATH,
                    "tool_sha256": hashlib.sha256(MODULE.SCRIPT_PATH.read_bytes()).hexdigest(),
                    "contract_path": MODULE.CONTRACT_REPO_PATH,
                    "contract_sha256": hashlib.sha256(CONTRACT_BYTES).hexdigest(),
                }
                for field, value in expected.items():
                    if receipt.get(field) != value:
                        raise ValueError("threshold freeze archive provenance is invalid")

            cls.git_patchers = [
                mock.patch.object(MODULE, "current_git_head", return_value=fixture_head),
                mock.patch.object(MODULE, "git_output", side_effect=archive_git_output),
                mock.patch.object(
                    MODULE, "validate_provenance", side_effect=archive_validate_provenance
                ),
            ]
            for patcher in cls.git_patchers:
                patcher.start()
        cls.calibration_bytes = score_rows(
            "calibration",
            180,
            positive=0.9,
            negative=0.2,
            family_prefix="cal-family",
            wave_prefix="cal-wave",
        )
        cls.freeze = MODULE.build_freeze_receipt(CONTRACT_BYTES, cls.calibration_bytes)
        cls.freeze_bytes = MODULE.canonical_json(cls.freeze)

    @classmethod
    def tearDownClass(cls) -> None:
        for patcher in reversed(cls.git_patchers):
            patcher.stop()

    def test_release_calibration_freezes_before_validation_with_10k_bootstrap(self) -> None:
        self.assertEqual(self.freeze["status"], "operator_attested_noncertifying_calibration")
        self.assertFalse(self.freeze["quality_evidence"])
        self.assertFalse(self.freeze["production_thresholds_approved"])
        self.assertFalse(self.freeze["validation_data_seen"])
        self.assertEqual(self.freeze["bootstrap"]["bootstrap_replicates"], 10000)
        self.assertEqual(len(self.freeze["calibration_family_component_hashes"]), 900)
        for method in CONTRACT["methods"]:
            result = self.freeze["thresholds"][method]
            self.assertEqual(result["review_cutoff"], 0.9)
            self.assertEqual(result["auto_block_cutoff"], 0.9)
            self.assertEqual(result["calibration_simultaneous_sensitivity_lower"], 1.0)

    def test_validation_uses_frozen_thresholds_without_retuning(self) -> None:
        validation = score_rows(
            "validation",
            120,
            positive=0.91,
            negative=0.3,
            family_prefix="val-family",
            wave_prefix="val-wave",
        )
        freeze_sha = hashlib.sha256(self.freeze_bytes).hexdigest()
        receipt = MODULE.build_validation_receipt(
            CONTRACT_BYTES, validation, self.freeze_bytes, freeze_sha,
            self.calibration_bytes, hashlib.sha256(self.calibration_bytes).hexdigest()
        )
        self.assertEqual(receipt["status"], "operator_attested_noncertifying_validation_passed_statistics")
        self.assertFalse(receipt["quality_evidence"])
        self.assertFalse(receipt["production_thresholds_approved"])
        self.assertTrue(receipt["statistics_gate_passed"])
        self.assertTrue(receipt["thresholds_frozen_before_validation"])
        for result in receipt["method_results"].values():
            self.assertEqual(result["frozen_review_cutoff"], 0.9)
            self.assertFalse(result["threshold_changed_after_freeze"])

    def test_validation_failure_does_not_select_a_friendlier_threshold(self) -> None:
        validation = score_rows(
            "validation",
            120,
            positive=0.89,
            negative=0.3,
            family_prefix="weak-val-family",
            wave_prefix="weak-val-wave",
        )
        receipt = MODULE.build_validation_receipt(
            CONTRACT_BYTES,
            validation,
            self.freeze_bytes,
            hashlib.sha256(self.freeze_bytes).hexdigest(),
            self.calibration_bytes,
            hashlib.sha256(self.calibration_bytes).hexdigest(),
        )
        self.assertEqual(receipt["status"], "operator_attested_noncertifying_validation_failed_statistics")
        self.assertFalse(receipt["statistics_gate_passed"])
        self.assertTrue(
            all(result["frozen_review_cutoff"] == 0.9 for result in receipt["method_results"].values())
        )

    def test_overlapping_bands_disable_auto_cutoff(self) -> None:
        overlapping = score_rows(
            "calibration",
            180,
            positive=0.9,
            negative=0.95,
            family_prefix="overlap-family",
            wave_prefix="overlap-wave",
        )
        receipt = MODULE.build_freeze_receipt(CONTRACT_BYTES, overlapping)
        for result in receipt["thresholds"].values():
            self.assertTrue(result["bands_overlap"])
            self.assertIsNone(result["auto_block_cutoff"])
            self.assertIn("manual_review", result["decision_policy"])

    def test_scores_are_quantized_before_boundary_and_overlap_decisions(self) -> None:
        boundary = score_rows(
            "calibration", 180, positive=0.900000004, negative=0.900000003,
            family_prefix="boundary-family", wave_prefix="boundary-wave",
        )
        receipt = MODULE.build_freeze_receipt(CONTRACT_BYTES, boundary)
        for result in receipt["thresholds"].values():
            self.assertEqual(result["review_cutoff"], 0.9)
            self.assertTrue(result["bands_overlap"])
            self.assertIsNone(result["auto_block_cutoff"])

    def test_float64_preserves_adjacent_deployment_scores_at_one_e_minus_eight(self) -> None:
        adjacent = score_rows(
            "calibration", 180, positive=0.90000001, negative=0.9,
            family_prefix="adjacent-family", wave_prefix="adjacent-wave",
        )
        receipt = MODULE.build_freeze_receipt(CONTRACT_BYTES, adjacent)
        for result in receipt["thresholds"].values():
            self.assertEqual(result["review_cutoff"], 0.90000001)
            self.assertFalse(result["bands_overlap"])
            self.assertEqual(result["auto_block_cutoff"], 0.90000001)

    def test_release_profile_rejects_missing_family(self) -> None:
        rows = MODULE.read_score_rows(self.calibration_bytes, CONTRACT)
        broken = [
            row
            for row in rows
            if not (
                row["language"] == "de"
                and row["family_component_id"] == "cal-family-de-179"
            )
        ]
        with self.assertRaisesRegex(ValueError, "de has 179 families"):
            MODULE.validate_release_profile(broken, "calibration", CONTRACT)

    def test_family_component_may_not_cross_split(self) -> None:
        pilot = score_rows(
            "calibration",
            1,
            positive=0.8,
            negative=0.2,
            family_prefix="pilot-family",
            wave_prefix="pilot-wave",
        )
        rows = MODULE.read_score_rows(pilot, CONTRACT)
        duplicate = dict(rows[0])
        duplicate["row_id"] = "validation-duplicate"
        duplicate["split"] = "validation"
        with self.assertRaisesRegex(ValueError, "may not cross"):
            MODULE.validate_family_structure([*rows, duplicate])

    def test_pilot_is_explicitly_noncertifying_and_metadata_only(self) -> None:
        pilot = score_rows(
            "calibration",
            1,
            positive=0.8,
            negative=0.2,
            family_prefix="private-family-name",
            wave_prefix="pilot-wave",
        )
        receipt = MODULE.build_pilot_receipt(CONTRACT_BYTES, pilot)
        encoded = MODULE.canonical_json(receipt)
        self.assertEqual(receipt["status"], "pilot_noncertifying")
        self.assertFalse(receipt["quality_evidence"])
        self.assertFalse(receipt["release_profile_met"])
        self.assertNotIn(b"private-family-name", encoded)

    def test_hard_negative_must_be_max_neighbor(self) -> None:
        value = json.loads(
            score_rows(
                "calibration",
                1,
                positive=0.8,
                negative=0.2,
                family_prefix="pilot-family",
                wave_prefix="pilot-wave",
            ).splitlines()[1]
        )
        value["is_max_neighbor"] = False
        with self.assertRaisesRegex(ValueError, "maximum-neighbor"):
            MODULE.read_score_rows(MODULE.canonical_json(value), CONTRACT)

    def test_freeze_sha_and_family_overlap_are_rejected(self) -> None:
        validation = score_rows(
            "validation",
            120,
            positive=0.91,
            negative=0.3,
            family_prefix="cal-family",
            wave_prefix="val-wave",
        )
        with self.assertRaisesRegex(ValueError, "sealed SHA-256"):
            MODULE.build_validation_receipt(
                CONTRACT_BYTES, validation, self.freeze_bytes, "0" * 64,
                self.calibration_bytes, hashlib.sha256(self.calibration_bytes).hexdigest()
            )
        with self.assertRaisesRegex(ValueError, "reuses a calibration family"):
            MODULE.build_validation_receipt(
                CONTRACT_BYTES,
                validation,
                self.freeze_bytes,
                hashlib.sha256(self.freeze_bytes).hexdigest(),
                self.calibration_bytes,
                hashlib.sha256(self.calibration_bytes).hexdigest(),
            )

    def test_validation_recomputes_freeze_from_sealed_calibration_scores(self) -> None:
        validation = score_rows(
            "validation", 120, positive=0.91, negative=0.3,
            family_prefix="custody-val-family", wave_prefix="custody-val-wave",
        )
        forged = json.loads(self.freeze_bytes)
        forged["thresholds"]["embedding_cosine"]["review_cutoff"] = 0.89
        forged["thresholds"]["embedding_cosine"]["auto_block_cutoff"] = 0.89
        forged_bytes = MODULE.canonical_json(forged)
        with self.assertRaisesRegex(ValueError, "exactly recompute"):
            MODULE.build_validation_receipt(
                CONTRACT_BYTES, validation, forged_bytes,
                hashlib.sha256(forged_bytes).hexdigest(), self.calibration_bytes,
                hashlib.sha256(self.calibration_bytes).hexdigest(),
            )

    def test_calibration_fails_when_no_threshold_meets_sensitivity_floor(self) -> None:
        weak = score_rows(
            "calibration", 180, positive=0.0, negative=0.0,
            family_prefix="weak-cal-family", wave_prefix="weak-cal-wave",
        )
        original = MODULE.simultaneous_sensitivity_lower
        MODULE.simultaneous_sensitivity_lower = lambda *args, **kwargs: (0.94, {})
        try:
            with self.assertRaisesRegex(ValueError, "no token_ngram_jaccard threshold"):
                MODULE.build_freeze_receipt(CONTRACT_BYTES, weak)
        finally:
            MODULE.simultaneous_sensitivity_lower = original

    def test_freeze_receipt_rejects_forged_threshold_claim(self) -> None:
        forged = json.loads(self.freeze_bytes)
        forged["thresholds"]["embedding_cosine"][
            "calibration_simultaneous_sensitivity_lower"
        ] = 0.94
        with self.assertRaisesRegex(ValueError, "result is invalid"):
            MODULE.validate_freeze_receipt(
                forged, hashlib.sha256(CONTRACT_BYTES).hexdigest()
            )

    def test_receipt_is_published_last_and_exclusively(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "bundle"
            MODULE.publish_receipt(bundle, {"status": "pilot_noncertifying"})
            self.assertEqual([path.name for path in bundle.iterdir()], ["receipt.json"])
            with self.assertRaisesRegex(ValueError, "already exists"):
                MODULE.publish_receipt(bundle, {})

    def test_publication_race_does_not_delete_unowned_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "bundle"
            bundle.mkdir()
            marker = bundle / "other-owner"
            marker.write_text("keep")
            with self.assertRaisesRegex(ValueError, "already exists"):
                MODULE.publish_receipt(bundle, {})
            self.assertEqual(marker.read_text(), "keep")

    def test_short_write_cleans_only_reserved_bundle(self) -> None:
        class ShortWriter:
            def __enter__(self): return self
            def __exit__(self, *args): return False
            def write(self, value): return 0
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "bundle"
            with mock.patch.object(Path, "open", return_value=ShortWriter()):
                with self.assertRaisesRegex(OSError, "short receipt write"):
                    MODULE.publish_receipt(bundle, {})
            self.assertFalse(bundle.exists())

    def test_committed_artifact_accepts_real_descendant_history(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True)
            marker = repo / "generator.py"
            marker.write_text("# generator\n")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "producer"], cwd=repo, check=True)
            producer = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, check=True, text=True, stdout=subprocess.PIPE).stdout.strip()
            artifact = repo / "evidence.json"
            artifact.write_bytes(MODULE.canonical_json({"producing_git_head": producer}))
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "seal evidence"], cwd=repo, check=True)
            (repo / "later.txt").write_text("descendant\n")
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "descendant"], cwd=repo, check=True)
            head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, check=True, text=True, stdout=subprocess.PIPE).stdout.strip()
            raw, parsed, sealing = MODULE.committed_artifact_bytes(artifact, head, repo)
            self.assertEqual(parsed["producing_git_head"], producer)
            self.assertEqual(raw, artifact.read_bytes())
            self.assertNotEqual(sealing, head)
            MODULE.require_strict_commit_ancestor(sealing, head, "custody", repo)
            with self.assertRaisesRegex(ValueError, "later descendant"):
                MODULE.require_strict_commit_ancestor(head, sealing, "custody", repo)
            nested = repo / "scanner-receipt.json"
            nested.write_bytes(MODULE.canonical_json({
                "scanner_provenance": {"producing_git_head": producer}
            }))
            subprocess.run(["git", "add", "."], cwd=repo, check=True)
            subprocess.run(["git", "commit", "-qm", "seal nested scanner receipt"], cwd=repo, check=True)
            nested_head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, check=True, text=True, stdout=subprocess.PIPE).stdout.strip()
            _, nested_value, _ = MODULE.committed_artifact_bytes(nested, nested_head, repo)
            self.assertEqual(nested_value["scanner_provenance"]["producing_git_head"], producer)

    def test_canonical_generator_accepts_only_post_recompute_calibration_stop(self) -> None:
        class Scanner:
            def __init__(self): self.called = False
            def verify_receipt(self, **kwargs):
                self.called = True
                raise ValueError("leakage receipt is non-certifying: calibration_required_noncertifying")
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "receipt.json"
            receipt.write_text(json.dumps({
                "backend": "production",
                "status": "calibration_required_noncertifying",
            }))
            scanner = Scanner()
            value = GENERATOR.verify_calibration_required_scanner_evidence(
                scanner, {"receipt_path": receipt}
            )
            self.assertTrue(scanner.called)
            self.assertEqual(value["backend"], "production")

    def test_score_generator_publishes_receipt_last_without_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "scores"
            GENERATOR.publish_bundle(bundle, b'{"score":1}\n', {"status": "sealed"})
            self.assertEqual(sorted(path.name for path in bundle.iterdir()), ["receipt.json", "scores.jsonl"])
            with self.assertRaisesRegex(ValueError, "new child"):
                GENERATOR.publish_bundle(bundle, b"", {})

    def test_generator_uses_decimal_half_up_at_eight_decimal_tie(self) -> None:
        self.assertEqual(GENERATOR.quantize_score(0.123456785), 0.12345679)
        self.assertEqual(GENERATOR.quantize_score(0.123456784), 0.12345678)

    def test_duplicated_caller_pool_cannot_create_approval(self) -> None:
        class Scanner:
            @staticmethod
            def validate_contract(value):
                return {"embedding": {}, "token_ngram_width": 2, "character_ngram_width": 3}
            class LocalSentenceTransformerBackend:
                def __init__(self, *args): pass
        pair = {
            "row_id": "row-1", "family_component_id": "family-1",
            "source_wave_id": "wave-1", "split": "calibration", "language": "en",
            "axis": "input_input", "length_stratum": "1_7", "behavior": "filler_removal",
            "label": "hard_negative", "left_text": "left",
            "right_texts": ["duplicate", "duplicate"],
        }
        with tempfile.TemporaryDirectory() as directory:
            contract = Path(directory) / "contract.json"
            contract.write_text("{}")
            with self.assertRaisesRegex(ValueError, "may not contain duplicates"):
                GENERATOR.build_score_rows(
                    Scanner(), {"contract_path": contract, "model_dir": directory}, [pair]
                )
        self.assertFalse(self.freeze["production_thresholds_approved"])

    def test_production_approval_mode_fails_closed(self) -> None:
        with mock.patch("sys.argv", ["calibrate_eg1_leakage_thresholds.py", "approve"]):
            with self.assertRaisesRegex(ValueError, "authenticated native pair-corpus owner"):
                MODULE.main()


if __name__ == "__main__":
    unittest.main()
