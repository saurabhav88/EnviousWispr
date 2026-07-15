from __future__ import annotations

from collections import Counter
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
MODULE_PATH = EVAL_DIR / "build_eg1_replay_inventory.py"
NORMALIZER_PATH = EVAL_DIR / "eg1_replay_normalizer_v1.py"
sys.path.insert(0, str(EVAL_DIR))
SPEC = importlib.util.spec_from_file_location("build_eg1_replay_inventory", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def encode_rows(rows: list[dict[str, object]]) -> bytes:
    return b"".join(MODULE.canonical_json(row) for row in rows)


class BuildEG1ReplayInventoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.expected_head = "a" * 40
        self.builder = self.root / "scripts/eval/build_eg1_replay_inventory.py"
        self.normalizer = self.root / "scripts/eval/eg1_replay_normalizer_v1.py"
        self.contract = self.root / "scripts/eval/contracts/eg1_replay_inventory_v1.json"
        self.bundle = self.root / "scripts/eval/runs/replay-inventory"
        self.builder.parent.mkdir(parents=True)
        self.contract.parent.mkdir(parents=True)
        self.bundle.parent.mkdir(parents=True)
        shutil.copyfile(MODULE_PATH, self.builder)
        shutil.copyfile(NORMALIZER_PATH, self.normalizer)
        self.source_rows = self._write_fixture_sources()
        self._write_contract()
        self.real_validate_git_state = MODULE.validate_git_state
        self.git_patcher = mock.patch.object(
            MODULE, "validate_git_state", return_value=self.expected_head
        )
        self.ignore_patcher = mock.patch.object(MODULE, "require_ignored_output")
        self.validate_git_state = self.git_patcher.start()
        self.require_ignored_output = self.ignore_patcher.start()

    def tearDown(self) -> None:
        self.ignore_patcher.stop()
        self.git_patcher.stop()
        self.temp.cleanup()

    def _source_path(self, role: str) -> Path:
        return self.root / self.source_rows[role][0]

    def _write_fixture_sources(self) -> dict[str, tuple[str, list[dict[str, object]]]]:
        approved = [
            {
                "id": "historical-approved-private-id-sentinel",
                "asr_input": "Historical alpha beta private text sentinel",
                "expected_output": "Historical output one private text sentinel",
            }
        ]
        overflow = [
            {
                "id": "historical-overflow-private-id-sentinel",
                "asr_input": "Historical other private text sentinel",
                "expected_output": "Historical output two private text sentinel",
            }
        ]
        replay = [
            {
                "id": "replay-overlap-input-private-id-sentinel",
                "source": "private-source-sentinel",
                "input": "historical, ALPHA beta private text sentinel!",
                "output": "Replay first output private text sentinel",
            },
            {
                "id": "replay-overlap-output-private-id-sentinel",
                "source": "private-source-sentinel",
                "input": "Replay second input private text sentinel",
                "output": "HISTORICAL OUTPUT TWO PRIVATE TEXT SENTINEL",
            },
            {
                "id": "replay-duplicate-input-a-private-id-sentinel",
                "source": "private-source-sentinel",
                "input": "Shared duplicate private input sentinel",
                "output": "Bridge duplicate private output sentinel",
            },
            {
                "id": "replay-duplicate-both-private-id-sentinel",
                "source": "private-source-sentinel",
                "input": "shared, duplicate PRIVATE input sentinel!",
                "output": "Repeated duplicate private output sentinel",
            },
            {
                "id": "replay-duplicate-output-private-id-sentinel",
                "source": "private-source-sentinel",
                "input": "Fifth unique private input sentinel",
                "output": "repeated duplicate PRIVATE output sentinel!",
            },
            {
                "id": "replay-candidate-six-private-id-sentinel",
                "source": "private-source-sentinel",
                "input": "Sixth unique private input sentinel",
                "output": "Sixth unique private output sentinel",
            },
            {
                "id": "replay-candidate-seven-private-id-sentinel",
                "source": "private-source-sentinel",
                "input": "Seventh unique private input sentinel",
                "output": "Seventh unique private output sentinel",
            },
            {
                "id": "replay-candidate-eight-private-id-sentinel",
                "source": "private-source-sentinel",
                "input": "Eighth unique private input sentinel",
                "output": "Eighth unique private output sentinel",
            },
        ]
        source_rows = {
            "historical_type_b_approved": (
                "scripts/eval/corpus/type_b_approved_1890.jsonl",
                approved,
            ),
            "historical_type_b_overflow": (
                "scripts/eval/corpus/type_b_overflow_900.jsonl",
                overflow,
            ),
            "historical_type_b_all": (
                "scripts/eval/corpus/type_b_all_v1.jsonl",
                [*approved, *overflow],
            ),
            "replay_training_original": (
                "scripts/eval/runs/bakeoff-1265/train_sft_v2.jsonl",
                replay,
            ),
        }
        for relative, rows in source_rows.values():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(encode_rows(rows))
        return source_rows

    def _contract_value(self) -> dict[str, object]:
        replay = self.source_rows["replay_training_original"][1]
        historical = self.source_rows["historical_type_b_all"][1]
        _, expected_counts = MODULE.make_inventory(replay, historical)
        return {
            "schema_version": MODULE.SCHEMA_VERSION,
            "normalizer": {
                "version": "eg1-replay-normalizer-v1",
                "unicode_form": "NFKC",
                "case_mapping": "casefold",
                "token_pattern": r"[^\W_]+",
                "separator": "single_space",
                "empty_word_fallback": "full_string_symbol_preserving",
                "fallback_whitespace": "single_space",
                "identity_domains": ["word", "full_symbol_fallback"],
            },
            "tool_bindings": {
                "builder": {
                    "path": str(self.builder.relative_to(self.root)),
                    "sha256": hashlib.sha256(self.builder.read_bytes()).hexdigest(),
                },
                "normalizer": {
                    "path": str(self.normalizer.relative_to(self.root)),
                    "sha256": hashlib.sha256(self.normalizer.read_bytes()).hexdigest(),
                },
            },
            "sources": {
                role: {
                    "path": relative,
                    "sha256": hashlib.sha256((self.root / relative).read_bytes()).hexdigest(),
                    "row_count": len(rows),
                }
                for role, (relative, rows) in self.source_rows.items()
            },
            "policy": {
                "historical_overlap_fields": ["asr_input", "expected_output"],
                "replay_overlap_fields": ["input", "output"],
                "overlap_comparison": "cross_field_union",
                "duplicate_scope": "all_remaining_rows",
                "duplicate_fields": ["normalized_input", "normalized_output"],
                "duplicate_disposition": "quarantine_entire_group",
                "candidate_disposition": "candidate_only",
                "candidate_training_eligible": False,
            },
            "expected_counts": expected_counts,
        }

    def _write_contract(self, mutate=None) -> None:
        contract = self._contract_value()
        if mutate:
            mutate(contract)
        self.contract.write_bytes(
            json.dumps(contract, indent=2, sort_keys=True).encode("utf-8") + b"\n"
        )

    def _build(self, output: Path | None = None) -> dict[str, object]:
        return MODULE.build_bundle(
            self.contract,
            output or self.bundle,
            self.expected_head,
            repo_root=self.root,
            script_path=self.builder,
            normalizer_path=self.normalizer,
        )

    def test_builds_metadata_only_receipt_last_inventory(self) -> None:
        receipt = self._build()
        rows = [
            json.loads(line)
            for line in (self.bundle / MODULE.INVENTORY_FILENAME)
            .read_text(encoding="utf-8")
            .splitlines()
        ]
        self.assertEqual(
            receipt["observed_counts"],
            {
                "total_replay_rows": 8,
                "historical_type_b_overlap_blocked": 2,
                "post_overlap_rows": 6,
                "invalid_normalization_quarantined": 0,
                "duplicate_group_quarantined": 3,
                "candidate_only": 3,
                "training_eligible": 0,
                "unresolved": 0,
                "duplicate_canonical_replay_rows": 0,
                "fallback_normalized_historical_fields": 0,
                "fallback_normalized_replay_fields": 0,
                "fallback_normalized_replay_rows": 0,
            },
        )
        self.assertEqual(receipt["publication_strategy"], "receipt_last")
        self.assertTrue((self.bundle / MODULE.RECEIPT_FILENAME).is_file())
        self.assertEqual(
            Counter(row["decision"] for row in rows),
            {
                "historical_type_b_overlap_blocked": 2,
                "duplicate_group_quarantined": 3,
                "candidate_only": 3,
            },
        )
        self.assertTrue(all(row["training_eligible"] is False for row in rows))
        self.assertTrue(
            all(
                set(row)
                == {
                    "row_fingerprint_sha256",
                    "decision",
                    "reason_codes",
                    "training_eligible",
                }
                for row in rows
            )
        )
        self.assertEqual(self.validate_git_state.call_count, 2)

    def test_is_byte_deterministic(self) -> None:
        self._build()
        second = self.bundle.parent / "second-inventory"
        self._build(second)
        for name in (MODULE.INVENTORY_FILENAME, MODULE.RECEIPT_FILENAME):
            self.assertEqual((self.bundle / name).read_bytes(), (second / name).read_bytes())

    def test_bundle_does_not_publish_raw_ids_or_text(self) -> None:
        self._build()
        published = b"".join(path.read_bytes() for path in self.bundle.iterdir())
        private_values = [
            str(value).encode("utf-8")
            for _, rows in self.source_rows.values()
            for row in rows
            for value in row.values()
        ]
        for private_value in private_values:
            self.assertNotIn(private_value, published)

    def test_quarantines_every_row_in_both_duplicate_groups(self) -> None:
        inventory, counts = MODULE.make_inventory(
            self.source_rows["replay_training_original"][1],
            self.source_rows["historical_type_b_all"][1],
        )
        quarantined = [
            row for row in inventory if row["decision"] == "duplicate_group_quarantined"
        ]
        self.assertEqual(counts["duplicate_group_quarantined"], 3)
        self.assertEqual(
            Counter(tuple(row["reason_codes"]) for row in quarantined),
            {
                ("remaining_duplicate_normalized_input_group",): 1,
                (
                    "remaining_duplicate_normalized_input_group",
                    "remaining_duplicate_normalized_output_group",
                ): 1,
                ("remaining_duplicate_normalized_output_group",): 1,
            },
        )

    def test_unique_emoji_only_content_uses_fallback_and_stays_candidate_only(self) -> None:
        replay = [{"id": "r", "source": "s", "input": "🙂", "output": "✅"}]
        history = [{"id": "h", "asr_input": "words", "expected_output": "more words"}]
        inventory, counts = MODULE.make_inventory(replay, history)
        self.assertEqual(inventory[0]["decision"], "candidate_only")
        self.assertEqual(counts["fallback_normalized_replay_fields"], 2)
        self.assertEqual(counts["fallback_normalized_replay_rows"], 1)

    def test_duplicate_emoji_only_content_quarantines_whole_group(self) -> None:
        replay = [
            {"id": "a", "source": "s", "input": "🙂", "output": "first"},
            {"id": "b", "source": "s", "input": "🙂", "output": "second"},
        ]
        history = [{"id": "h", "asr_input": "words", "expected_output": "more words"}]
        inventory, counts = MODULE.make_inventory(replay, history)
        self.assertEqual(counts["duplicate_group_quarantined"], 2)
        self.assertTrue(
            all(row["decision"] == "duplicate_group_quarantined" for row in inventory)
        )

    def test_punctuation_only_content_collides_through_fallback(self) -> None:
        replay = [{"id": "r", "source": "s", "input": "!!!", "output": "safe"}]
        history = [{"id": "h", "asr_input": "!!!", "expected_output": "other"}]
        inventory, counts = MODULE.make_inventory(replay, history)
        self.assertEqual(inventory[0]["decision"], "historical_type_b_overlap_blocked")
        self.assertEqual(counts["fallback_normalized_historical_fields"], 1)

    def test_underscore_is_punctuation_for_overlap_and_duplicate_identity(self) -> None:
        history = [
            {"id": "h", "asr_input": "alpha_beta", "expected_output": "history end"}
        ]
        replay = [
            {"id": "a", "source": "s", "input": "alpha beta", "output": "one"},
            {"id": "b", "source": "s", "input": "unique", "output": "value_one"},
            {"id": "c", "source": "s", "input": "other", "output": "value one"},
        ]
        inventory, counts = MODULE.make_inventory(replay, history)
        self.assertEqual(counts["historical_type_b_overlap_blocked"], 1)
        self.assertEqual(counts["duplicate_group_quarantined"], 2)
        self.assertEqual(
            Counter(row["decision"] for row in inventory),
            {
                "historical_type_b_overlap_blocked": 1,
                "duplicate_group_quarantined": 2,
            },
        )

    def test_empty_or_whitespace_content_is_quarantined(self) -> None:
        replay = [
            {"id": "a", "source": "s", "input": "  \t", "output": "safe"},
            {"id": "b", "source": "s", "input": "okay", "output": ""},
        ]
        history = [{"id": "h", "asr_input": "words", "expected_output": "more words"}]
        inventory, counts = MODULE.make_inventory(replay, history)
        self.assertEqual(counts["invalid_normalization_quarantined"], 2)
        self.assertTrue(
            all(row["decision"] == "invalid_normalization_quarantined" for row in inventory)
        )

    def test_rejects_source_hash_drift(self) -> None:
        path = self._source_path("replay_training_original")
        path.write_bytes(path.read_bytes() + b"\n")
        with self.assertRaisesRegex(ValueError, "source hash changed"):
            self._build()
        self.assertFalse(self.bundle.exists())

    def test_rejects_replay_schema_drift_even_when_hash_is_rebound(self) -> None:
        role = "replay_training_original"
        relative, rows = self.source_rows[role]
        rows[0]["unexpected"] = "private schema value"
        self._source_path(role).write_bytes(encode_rows(rows))
        self._write_contract()
        with self.assertRaisesRegex(ValueError, "row schema changed"):
            self._build()
        self.assertFalse(self.bundle.exists())

    def test_rejects_historical_view_drift_even_when_hash_is_rebound(self) -> None:
        role = "historical_type_b_all"
        _, rows = self.source_rows[role]
        rows[0]["expected_output"] = "changed private historical value"
        self._source_path(role).write_bytes(encode_rows(rows))
        self._write_contract()
        with self.assertRaisesRegex(ValueError, "all-view rows differ"):
            self._build()
        self.assertFalse(self.bundle.exists())

    def test_rejects_count_drift(self) -> None:
        self._write_contract(
            lambda value: value["expected_counts"].__setitem__("candidate_only", 4)
        )
        with self.assertRaisesRegex(ValueError, "observed inventory counts differ"):
            self._build()
        self.assertFalse(self.bundle.exists())

    def test_rejects_candidate_training_eligibility(self) -> None:
        self._write_contract(
            lambda value: value["policy"].__setitem__(
                "candidate_training_eligible", True
            )
        )
        with self.assertRaisesRegex(ValueError, "decision policy changed"):
            self._build()

    def test_rejects_tool_hash_drift(self) -> None:
        self.builder.write_bytes(self.builder.read_bytes() + b"\n")
        with self.assertRaisesRegex(ValueError, "builder hash differs"):
            self._build()

    def test_refuses_output_overwrite(self) -> None:
        self.bundle.mkdir()
        with self.assertRaisesRegex(ValueError, "already exists"):
            self._build()

    def test_receipt_failure_removes_partial_bundle(self) -> None:
        real_write = MODULE.write_exclusive

        def fail_receipt(path: Path, value: bytes) -> None:
            if path.name == MODULE.RECEIPT_FILENAME:
                raise OSError("injected receipt failure")
            real_write(path, value)

        with mock.patch.object(MODULE, "write_exclusive", side_effect=fail_receipt):
            with self.assertRaisesRegex(OSError, "injected receipt failure"):
                self._build()
        self.assertFalse(self.bundle.exists())

    def test_git_binding_rejects_dirty_tracked_state(self) -> None:
        with mock.patch.object(
            MODULE,
            "git_output",
            side_effect=[
                (self.expected_head + "\n").encode(),
                b" M scripts/eval/build_eg1_replay_inventory.py\n",
            ],
        ):
            with self.assertRaisesRegex(ValueError, "tracked worktree must be clean"):
                self.real_validate_git_state(
                    self.expected_head,
                    self.root,
                    (self.builder, self.normalizer, self.contract),
                )

    def test_git_binding_rejects_malformed_expected_head(self) -> None:
        with self.assertRaisesRegex(ValueError, "lowercase 40-character SHA-1"):
            self.real_validate_git_state(
                "HEAD", self.root, (self.builder, self.normalizer, self.contract)
            )


if __name__ == "__main__":
    unittest.main()
