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

    def tearDown(self) -> None:
        self.temp.cleanup()

    def arguments(self) -> list[str]:
        return [str(MODULE_PATH), "--out-bundle", str(self.bundle), "--seed", "1265"]

    def test_builds_exact_balanced_1890_slot_manifest(self) -> None:
        with mock.patch.object(sys, "argv", self.arguments()):
            self.assertEqual(MODULE.main(), 0)
        receipt = json.loads((self.bundle / "receipt.json").read_text(encoding="utf-8"))
        manifest_bytes = (self.bundle / "manifest.jsonl").read_bytes()
        rows = [
            json.loads(line)
            for line in manifest_bytes.decode("utf-8").splitlines()
        ]
        self.assertEqual(len(rows), 1890)
        self.assertEqual(receipt["fresh_required"], 1867)
        self.assertEqual(receipt["provisional_retained"], 23)
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
        self.assertEqual(len({row["semantic_family_id"] for row in rows}), 1890)
        self.assertTrue(all(row["candidate_model_output_seen"] is False for row in rows))
        self.assertTrue(all(row["training_eligible"] is False for row in rows))

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
