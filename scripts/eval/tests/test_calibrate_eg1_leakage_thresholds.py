from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


EVAL_DIR = Path(__file__).resolve().parents[1]
MODULE_PATH = EVAL_DIR / "calibrate_eg1_leakage_thresholds.py"
SPEC = importlib.util.spec_from_file_location("calibrate_eg1_leakage_thresholds", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
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

    def test_release_calibration_freezes_before_validation_with_10k_bootstrap(self) -> None:
        self.assertEqual(self.freeze["status"], "thresholds_frozen_validation_unseen")
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
            CONTRACT_BYTES, validation, self.freeze_bytes, freeze_sha
        )
        self.assertEqual(receipt["status"], "validation_passed")
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
        )
        self.assertEqual(receipt["status"], "validation_failed_frozen_thresholds_unchanged")
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
                CONTRACT_BYTES, validation, self.freeze_bytes, "0" * 64
            )
        with self.assertRaisesRegex(ValueError, "reuses a calibration family"):
            MODULE.build_validation_receipt(
                CONTRACT_BYTES,
                validation,
                self.freeze_bytes,
                hashlib.sha256(self.freeze_bytes).hexdigest(),
            )

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


if __name__ == "__main__":
    unittest.main()
