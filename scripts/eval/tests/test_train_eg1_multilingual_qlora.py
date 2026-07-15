#!/usr/bin/env python3
"""Focused safety tests for the EG-1 multilingual adapter trainer."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType, SimpleNamespace
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


def qwen35_partial_target_fixture() -> list[str]:
    gdn_suffixes = {"in_proj_a", "in_proj_b", "in_proj_qkv", "in_proj_z", "out_proj"}
    return [
        name
        for name in qwen35_language_target_fixture()
        if name.rsplit(".", 1)[-1] not in gdn_suffixes
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


class Qwen35AdapterEvidenceTests(unittest.TestCase):
    def test_128_of_248_mismatch_persists_blocked_receipt_before_trainer(self) -> None:
        class FakeModel:
            def __init__(self) -> None:
                self.save_pretrained = mock.Mock(name="save_pretrained")
                self.save_pretrained_merged = mock.Mock(name="save_pretrained_merged")

            def named_modules(self) -> list[tuple[str, SimpleNamespace]]:
                return [
                    (name, SimpleNamespace(lora_A=object()))
                    for name in qwen35_partial_target_fixture()
                ]

            def parameters(self) -> list[SimpleNamespace]:
                return [
                    SimpleNamespace(requires_grad=True, numel=lambda: 123_456),
                    SimpleNamespace(requires_grad=False, numel=lambda: 654_321),
                ]

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base_path = root / "Qwen3.5-4B"
            base_path.mkdir()
            (base_path / "config.json").write_text(
                json.dumps(
                    {
                        "model_type": "qwen3_5",
                        "architectures": ["Qwen3_5ForConditionalGeneration"],
                    }
                ),
                encoding="utf-8",
            )
            data_path = root / "private.jsonl"
            data_path.write_text(
                "".join(json.dumps(row) + "\n" for row in private_preflight_rows()),
                encoding="utf-8",
            )
            prompt_path = root / "prompt.txt"
            prompt_path.write_text("Pinned synthetic preflight prompt.\n", encoding="utf-8")
            output_root = root / "out"
            tag = "synthetic-128-of-248"
            manifest_path = output_root / tag / "training-manifest.json"
            args = SimpleNamespace(
                base=str(base_path),
                data=str(data_path),
                prompt=str(prompt_path),
                tag=tag,
                output_root=str(output_root),
                lr=5e-5,
                epochs=2.0,
                rank=16,
                alpha=32,
                micro_batch=1,
                gradient_accumulation=1,
                max_seq=512,
                seed=1265,
                training_mode="auto",
                preflight_only=True,
                skip_merge=True,
            )

            fake_model = FakeModel()
            fake_tokenizer = SimpleNamespace(save_pretrained=mock.Mock(name="tokenizer_save"))
            fast_model = SimpleNamespace(
                from_pretrained=mock.Mock(return_value=(fake_model, fake_tokenizer)),
                get_peft_model=mock.Mock(return_value=fake_model),
            )
            unsloth = ModuleType("unsloth")
            unsloth.FastLanguageModel = SimpleNamespace()
            unsloth.FastModel = fast_model
            chat_templates = ModuleType("unsloth.chat_templates")
            chat_templates.train_on_responses_only = mock.Mock()
            torch = ModuleType("torch")
            torch.__version__ = "2.10.0+cu128"
            torch.manual_seed = mock.Mock()
            torch.cuda = SimpleNamespace(
                is_available=lambda: True,
                is_bf16_supported=lambda: True,
                get_device_name=lambda _index: "Synthetic RTX 4090",
            )
            datasets = ModuleType("datasets")
            datasets.Dataset = SimpleNamespace()
            trl = ModuleType("trl")
            trl.SFTConfig = SimpleNamespace()
            trl.SFTTrainer = mock.Mock(name="SFTTrainer")

            def fixed_hash(path: Path) -> str:
                if path.name == data_path.name:
                    return str(trainer.QWEN35_PREFLIGHT_CONTRACT["data_sha256"])
                if path.name == prompt_path.name:
                    return str(trainer.QWEN35_PREFLIGHT_CONTRACT["prompt_sha256"])
                if path.name == "config.json":
                    return str(
                        trainer.QWEN35_PREFLIGHT_CONTRACT["artifact_sha256"]["config.json"]
                    )
                raise AssertionError(f"Unexpected hash read: {path}")

            real_write_json = trainer.write_json
            manifest_snapshots: list[dict[str, object]] = []

            def recording_write(path: Path, value: object) -> None:
                manifest_snapshots.append(json.loads(json.dumps(value)))
                real_write_json(path, value)

            with (
                mock.patch.object(trainer, "parse_args", return_value=args),
                mock.patch.object(trainer, "sha256", side_effect=fixed_hash),
                mock.patch.object(
                    trainer,
                    "validate_qwen35_base_artifacts",
                    return_value={"revision": trainer.QWEN35_PREFLIGHT_CONTRACT["base_revision"]},
                ),
                mock.patch.object(trainer, "distribution_version", return_value="5.5.0"),
                mock.patch.object(trainer, "write_json", side_effect=recording_write),
                mock.patch.dict(
                    sys.modules,
                    {
                        "unsloth": unsloth,
                        "unsloth.chat_templates": chat_templates,
                        "torch": torch,
                        "datasets": datasets,
                        "trl": trl,
                    },
                ),
                self.assertRaisesRegex(RuntimeError, "target coverage drifted"),
            ):
                trainer.main()

            pending = next(
                snapshot
                for snapshot in manifest_snapshots
                if snapshot["status"] == "adapter_validation_pending_not_complete"
            )
            pending_receipt = pending["adapter_receipt"]
            self.assertEqual(pending_receipt["matched_module_count"], 128)
            self.assertEqual(
                sum(pending["preflight_contract"]["target_suffix_counts"].values()),
                248,
            )
            self.assertEqual(len(pending_receipt["matched_module_names"]), 128)
            self.assertEqual(
                pending_receipt["target_suffix_counts"],
                {
                    "down_proj": 32,
                    "gate_proj": 32,
                    "k_proj": 8,
                    "o_proj": 8,
                    "q_proj": 8,
                    "up_proj": 32,
                    "v_proj": 8,
                },
            )
            self.assertEqual(pending_receipt["trainable_parameter_count"], 123_456)
            self.assertEqual(pending_receipt["total_parameter_count"], 777_777)
            self.assertEqual(pending_receipt["validation_status"], "pending")

            on_disk = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(on_disk["status"], "blocked_adapter_validation_failed")
            self.assertEqual(
                on_disk["adapter_receipt"]["matched_module_names"],
                pending_receipt["matched_module_names"],
            )
            self.assertEqual(on_disk["adapter_receipt"]["validation_status"], "failed")
            self.assertNotEqual(on_disk["status"], "complete")
            trl.SFTTrainer.assert_not_called()
            fake_model.save_pretrained.assert_not_called()
            fake_model.save_pretrained_merged.assert_not_called()
            fake_tokenizer.save_pretrained.assert_not_called()
            self.assertFalse((output_root / tag / "adapter").exists())
            self.assertFalse((output_root / tag / "merged16").exists())

    def test_adapter_receipt_write_failure_stops_before_validation(self) -> None:
        manifest: dict[str, object] = {"status": "starting"}
        receipt: dict[str, object] = {"matched_module_count": 128}
        with (
            mock.patch.object(trainer, "write_json", side_effect=OSError("synthetic write failure")),
            mock.patch.object(trainer, "validate_qwen35_adapter_receipt") as validator,
            self.assertRaisesRegex(OSError, "synthetic write failure"),
        ):
            trainer.persist_qwen35_adapter_receipt_before_validation(
                manifest_path=Path("unused.json"),
                manifest=manifest,
                receipt=receipt,
                lora_module_names=qwen35_partial_target_fixture(),
                trainable_parameters=123_456,
                rank=16,
            )

        validator.assert_not_called()

    def test_atomic_manifest_write_preserves_previous_receipt_on_replace_failure(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "training-manifest.json"
            path.write_text('{"status":"previous"}\n', encoding="utf-8")

            with (
                mock.patch.object(trainer.os, "replace", side_effect=OSError("replace failed")),
                self.assertRaisesRegex(OSError, "replace failed"),
            ):
                trainer.write_json(path, {"status": "new"})

            self.assertEqual(path.read_text(encoding="utf-8"), '{"status":"previous"}\n')
            self.assertEqual(list(root.glob(f".{path.name}.*")), [])


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
    def test_preflight_accepts_bounded_private_shape_and_pinned_prompt(self) -> None:
        trainer.validate_preflight_request(
            family=trainer.QWEN35_FAMILY,
            enabled=True,
            rows=private_preflight_rows(),
            skip_merge=True,
            data_sha256=trainer.QWEN35_PREFLIGHT_CONTRACT["data_sha256"],
            prompt_sha256=trainer.QWEN35_PREFLIGHT_CONTRACT["prompt_sha256"],
            rank=16,
        )

    def test_preflight_refuses_unsafe_flags(self) -> None:
        cases = (
            {"enabled": False},
            {"family": "gemma"},
            {"rows": private_preflight_rows(1)},
            {"skip_merge": False},
            {"data_sha256": "c" * 64},
            {"prompt_sha256": "d" * 64},
            {"rank": 8},
        )
        defaults = {
            "family": trainer.QWEN35_FAMILY,
            "enabled": True,
            "rows": private_preflight_rows(),
            "skip_merge": True,
            "data_sha256": trainer.QWEN35_PREFLIGHT_CONTRACT["data_sha256"],
            "prompt_sha256": trainer.QWEN35_PREFLIGHT_CONTRACT["prompt_sha256"],
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
                    prompt_sha256=trainer.QWEN35_PREFLIGHT_CONTRACT["prompt_sha256"],
                    rank=16,
                )

    def test_prompt_mismatch_stops_before_base_validation_or_model_load(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base_path = root / "Qwen3.5-4B"
            base_path.mkdir()
            (base_path / "config.json").write_text(
                json.dumps(
                    {
                        "model_type": "qwen3_5",
                        "architectures": ["Qwen3_5ForConditionalGeneration"],
                    }
                ),
                encoding="utf-8",
            )
            data_path = root / "private.jsonl"
            prompt_path = root / "prompt.txt"
            data_path.write_text("placeholder\n", encoding="utf-8")
            prompt_path.write_text("wrong prompt\n", encoding="utf-8")
            args = SimpleNamespace(
                base=str(base_path),
                data=str(data_path),
                prompt=str(prompt_path),
                tag="prompt-mismatch-must-not-load",
                output_root=str(root / "out"),
                training_mode="auto",
                preflight_only=True,
                skip_merge=True,
                rank=16,
            )

            def fixed_hash(path: Path) -> str:
                if path.name == data_path.name:
                    return str(trainer.QWEN35_PREFLIGHT_CONTRACT["data_sha256"])
                if path.name == prompt_path.name:
                    return "d" * 64
                raise AssertionError(f"Unexpected hash read before prompt rejection: {path}")

            with (
                mock.patch.object(trainer, "parse_args", return_value=args),
                mock.patch.object(trainer, "read_rows", return_value=private_preflight_rows()),
                mock.patch.object(trainer, "sha256", side_effect=fixed_hash),
                mock.patch.object(trainer, "validate_qwen35_base_artifacts") as base_validator,
                self.assertRaisesRegex(SystemExit, "prompt SHA-256 mismatch"),
            ):
                trainer.main()

            base_validator.assert_not_called()
            self.assertFalse((root / "out" / args.tag).exists())


if __name__ == "__main__":
    unittest.main()
