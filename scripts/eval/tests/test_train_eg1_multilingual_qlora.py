#!/usr/bin/env python3
"""Focused safety tests for the EG-1 multilingual adapter trainer."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


EVAL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EVAL_DIR))

import train_eg1_multilingual_qlora as trainer  # noqa: E402


def qwen35_language_target_fixture() -> list[str]:
    names: list[str] = []
    for layer in range(32):
        prefix = f"base_model.model.model.layers.{layer}"
        names.extend(
            f"{prefix}.mlp.{suffix}" for suffix in ("gate_proj", "up_proj", "down_proj")
        )
    for layer in range(24):
        prefix = f"base_model.model.model.layers.{layer}.linear_attn"
        names.extend(
            f"{prefix}.{suffix}"
            for suffix in ("in_proj_a", "in_proj_b", "in_proj_qkv", "in_proj_z", "out_proj")
        )
    for layer in range(8):
        prefix = f"base_model.model.model.layers.{layer}.self_attn"
        names.extend(
            f"{prefix}.{suffix}" for suffix in ("q_proj", "k_proj", "v_proj", "o_proj")
        )
    return sorted(names)


def private_preflight_rows(count: int = 4) -> list[dict[str, str]]:
    return [
        {
            "input": f"synthetic private input {index}",
            "output": f"Synthetic private output {index}.",
            "preflight_provenance": trainer.QWEN35_PREFLIGHT_CONTRACT["row_provenance"],
        }
        for index in range(count)
    ]


class TrainingModeTests(unittest.TestCase):
    def test_model_family_uses_config_not_directory_name(self) -> None:
        self.assertEqual(
            trainer.model_family(
                {
                    "model_type": "qwen3_5",
                    "architectures": ["Qwen3_5ForConditionalGeneration"],
                }
            ),
            trainer.QWEN35_FAMILY,
        )
        self.assertEqual(
            trainer.model_family(
                {"model_type": "gemma4", "architectures": ["Gemma4ForConditionalGeneration"]}
            ),
            "gemma",
        )

    def test_auto_mode_keeps_gemma_qlora_and_routes_qwen35_to_bf16(self) -> None:
        self.assertEqual(trainer.resolve_training_mode("gemma", "auto"), trainer.QLORA_MODE)
        self.assertEqual(
            trainer.resolve_training_mode(trainer.QWEN35_FAMILY, "auto"),
            trainer.BF16_LORA_MODE,
        )

    def test_qwen35_qlora_and_non_qwen_bf16_are_refused(self) -> None:
        with self.assertRaisesRegex(ValueError, "Refusing Qwen3.5 QLoRA"):
            trainer.resolve_training_mode(trainer.QWEN35_FAMILY, trainer.QLORA_MODE)
        with self.assertRaisesRegex(ValueError, "only for Qwen3.5"):
            trainer.resolve_training_mode("gemma", trainer.BF16_LORA_MODE)


class Qwen35TargetTests(unittest.TestCase):
    def test_verified_hybrid_target_coverage_and_trainable_count(self) -> None:
        names = qwen35_language_target_fixture()

        self.assertEqual(len(names), 248)
        self.assertEqual(
            trainer.qwen35_target_suffix_counts(names),
            trainer.QWEN35_PREFLIGHT_CONTRACT["target_suffix_counts"],
        )
        trainer.validate_qwen35_adapter_receipt(
            names,
            trainer.QWEN35_PREFLIGHT_CONTRACT["rank_16_trainable_parameters"],
            rank=16,
        )

    def test_vision_and_mtp_targets_are_refused_even_with_same_suffix_counts(self) -> None:
        names = qwen35_language_target_fixture()
        q_proj_index = next(index for index, name in enumerate(names) if name.endswith("q_proj"))

        for forbidden_name in (
            "base_model.model.visual.blocks.0.attn.q_proj",
            "base_model.model.multi_modal_projector.layers.0.q_proj",
            "base_model.model.mtp.layers.0.self_attn.q_proj",
        ):
            mutated = list(names)
            mutated[q_proj_index] = forbidden_name
            with self.assertRaisesRegex(RuntimeError, "vision/MTP"):
                trainer.validate_qwen35_adapter_receipt(
                    mutated,
                    trainer.QWEN35_PREFLIGHT_CONTRACT["rank_16_trainable_parameters"],
                    rank=16,
                )


class Qwen35ArtifactContractTests(unittest.TestCase):
    def make_base(self, root: Path, *, shards: list[str] | None = None) -> Path:
        base_path = root / "Qwen3.5-4B"
        metadata_path = base_path / ".cache" / "huggingface" / "download"
        metadata_path.mkdir(parents=True)
        expected_shards = list(trainer.QWEN35_PREFLIGHT_CONTRACT["weight_shards"])
        index_shards = shards if shards is not None else expected_shards
        for artifact_name in trainer.QWEN35_PREFLIGHT_CONTRACT["artifact_sha256"]:
            artifact_path = base_path / artifact_name
            if artifact_name == "model.safetensors.index.json":
                artifact_path.write_text(
                    json.dumps(
                        {
                            "weight_map": {
                                f"model.layers.{index}.weight": shard
                                for index, shard in enumerate(index_shards)
                            }
                        }
                    ),
                    encoding="utf-8",
                )
            else:
                artifact_path.write_bytes(b"synthetic unit-test placeholder")
            (metadata_path / f"{artifact_name}.metadata").write_text(
                f"{trainer.QWEN35_PREFLIGHT_CONTRACT['base_revision']}\n",
                encoding="utf-8",
            )
        return base_path

    def expected_hash(self, path: Path) -> str:
        return str(trainer.QWEN35_PREFLIGHT_CONTRACT["artifact_sha256"][path.name])

    def test_complete_artifact_contract_records_every_hash_and_revision(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            trainer, "sha256", side_effect=self.expected_hash
        ):
            receipt = trainer.validate_qwen35_base_artifacts(self.make_base(Path(tmp)))

        self.assertEqual(
            sorted(receipt["artifacts"]),
            sorted(trainer.QWEN35_PREFLIGHT_CONTRACT["artifact_sha256"]),
        )
        self.assertEqual(
            receipt["index_weight_shards"],
            trainer.QWEN35_PREFLIGHT_CONTRACT["weight_shards"],
        )

    def test_artifact_contract_rejects_hash_and_index_shard_drift(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base_path = self.make_base(Path(tmp))
            with mock.patch.object(trainer, "sha256", return_value="0" * 64):
                with self.assertRaisesRegex(ValueError, "artifact hash mismatch"):
                    trainer.validate_qwen35_base_artifacts(base_path)

        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            trainer, "sha256", side_effect=self.expected_hash
        ):
            base_path = self.make_base(Path(tmp), shards=["unexpected.safetensors"])
            with self.assertRaisesRegex(ValueError, "index shard list mismatch"):
                trainer.validate_qwen35_base_artifacts(base_path)

        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(
            trainer, "sha256", side_effect=self.expected_hash
        ):
            base_path = self.make_base(Path(tmp))
            metadata = (
                base_path
                / ".cache"
                / "huggingface"
                / "download"
                / "config.json.metadata"
            )
            metadata.write_text("wrong-revision\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "artifact revision mismatch"):
                trainer.validate_qwen35_base_artifacts(base_path)


class ResponseMaskTests(unittest.TestCase):
    def test_qwen35_empty_think_wrapper_uses_assistant_marker(self) -> None:
        rendered = (
            "<|im_start|>user\nSynthetic request<|im_end|>\n"
            "<|im_start|>assistant\n<think>\n\n</think>\n\nSynthetic answer<|im_end|>\n"
        )

        marker, counts = trainer.validate_response_markers(
            [rendered], trainer.QWEN35_FAMILY
        )

        self.assertEqual(marker, "<|im_start|>assistant\n")
        self.assertEqual(counts, [1])

    def test_missing_response_marker_is_refused(self) -> None:
        with self.assertRaisesRegex(ValueError, "one response marker"):
            trainer.validate_response_markers(
                ["<|im_start|>assistant Synthetic answer"], trainer.QWEN35_FAMILY
            )


class PreflightSafetyTests(unittest.TestCase):
    def test_preflight_accepts_only_bounded_private_shape(self) -> None:
        trainer.validate_preflight_request(
            family=trainer.QWEN35_FAMILY,
            enabled=True,
            rows=private_preflight_rows(),
            skip_merge=True,
            data_sha256=trainer.QWEN35_PREFLIGHT_CONTRACT["data_sha256"],
            rank=16,
        )

    def test_preflight_refuses_unsafe_flags(self) -> None:
        cases = (
            {"enabled": False},
            {"family": "gemma"},
            {"rows": private_preflight_rows(1)},
            {"skip_merge": False},
            {"data_sha256": "c" * 64},
            {"rank": 8},
        )
        defaults = {
            "family": trainer.QWEN35_FAMILY,
            "enabled": True,
            "rows": private_preflight_rows(),
            "skip_merge": True,
            "data_sha256": trainer.QWEN35_PREFLIGHT_CONTRACT["data_sha256"],
            "rank": 16,
        }
        for case in cases:
            with self.subTest(case=case), self.assertRaises(ValueError):
                trainer.validate_preflight_request(**(defaults | case))

    def test_preflight_rejects_benchmark_schema_and_missing_provenance(self) -> None:
        for mutation in (
            {"id": "benchmark-case"},
            {"preflight_provenance": "benchmark_slice"},
        ):
            rows = private_preflight_rows()
            rows[0].update(mutation)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                trainer.validate_preflight_request(
                    family=trainer.QWEN35_FAMILY,
                    enabled=True,
                    rows=rows,
                    skip_merge=True,
                    data_sha256=trainer.QWEN35_PREFLIGHT_CONTRACT["data_sha256"],
                    rank=16,
                )


if __name__ == "__main__":
    unittest.main()
