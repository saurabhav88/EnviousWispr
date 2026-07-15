#!/usr/bin/env python3
"""Reproducible multilingual EG-1 adapter training on AlienSV.

The historical Gemma/older-Qwen path remains QLoRA. Qwen3.5 deliberately uses
BF16 LoRA because Unsloth warns against Qwen3.5 4-bit training.
"""

from __future__ import annotations

import argparse
import hashlib
import inspect
import json
import os
import platform
import time
from importlib.metadata import version as distribution_version
from pathlib import Path
from typing import Any


QWEN35_FAMILY = "qwen3.5"
QLORA_MODE = "qlora"
BF16_LORA_MODE = "bf16-lora"
PREFLIGHT_EVIDENCE_CLASS = "compatibility_preflight_not_quality_evidence"
PREFLIGHT_ROW_PROVENANCE = "private_synthetic_non_benchmark_qwen35_compatibility_v1"
QWEN35_RESPONSE_MARKER = "<|im_start|>assistant\n"
GEMMA_RESPONSE_MARKER = "<|turn>model\n"
QWEN35_EXPECTED_TARGET_SUFFIX_COUNTS = {
    "down_proj": 32,
    "gate_proj": 32,
    "in_proj_a": 24,
    "in_proj_b": 24,
    "in_proj_qkv": 24,
    "in_proj_z": 24,
    "k_proj": 8,
    "o_proj": 8,
    "out_proj": 24,
    "q_proj": 8,
    "up_proj": 32,
    "v_proj": 8,
}
QWEN35_R16_TRAINABLE_PARAMETERS = 32_464_896
QWEN35_PREFLIGHT_CONTRACT: dict[str, Any] = {
    "schema_version": "qwen35_compatibility_preflight_v1",
    "base_revision": "851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a",
    "data_sha256": "0584d6d796ad2fe0e1f551c20fb175487e13a2440effdb71bae0acd69e057bb3",
    "row_provenance": PREFLIGHT_ROW_PROVENANCE,
    "artifact_sha256": {
        "chat_template.jinja": "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715",
        "config.json": "ddc63e1c717afa86c865bb5e01313d89d72bb53b97ad4a8a03ba8510c0621670",
        "model.safetensors-00001-of-00002.safetensors": (
            "26a93f066e1916adb13453dae5a0c707c0fbc71299ed98779571a907b8e74c61"
        ),
        "model.safetensors-00002-of-00002.safetensors": (
            "cb544bd9bfae93dc59b0f22b292f5933573854a7f9b97835c67060d7d910e188"
        ),
        "model.safetensors.index.json": (
            "cf3f798ee02ba45f9622aa8892a47369ab667d0afbf154ee7c2212de42e6302d"
        ),
        "tokenizer.json": "5f9e4d4901a92b997e463c1f46055088b6cca5ca61a6522d1b9f64c4bb81cb42",
        "tokenizer_config.json": "316230d6a809701f4db5ea8f8fc862bc3a6f3229c937c174e674ff3ca0a64ac8",
    },
    "weight_shards": [
        "model.safetensors-00001-of-00002.safetensors",
        "model.safetensors-00002-of-00002.safetensors",
    ],
    "target_suffix_counts": QWEN35_EXPECTED_TARGET_SUFFIX_COUNTS,
    "rank_16_trainable_parameters": QWEN35_R16_TRAINABLE_PARAMETERS,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--data", required=True)
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--output-root", default="~/tuning/out")
    parser.add_argument("--lr", type=float, default=5e-5)
    parser.add_argument("--epochs", type=float, default=2.0)
    parser.add_argument("--rank", type=int, default=16)
    parser.add_argument("--alpha", type=int, default=32)
    parser.add_argument("--micro-batch", type=int, default=4)
    parser.add_argument("--gradient-accumulation", type=int, default=4)
    parser.add_argument("--max-seq", type=int, default=512)
    parser.add_argument("--seed", type=int, default=1265)
    parser.add_argument(
        "--training-mode",
        choices=("auto", QLORA_MODE, BF16_LORA_MODE),
        default="auto",
        help="auto keeps historical bases on QLoRA and routes Qwen3.5 to BF16 LoRA",
    )
    parser.add_argument(
        "--preflight-only",
        action="store_true",
        help="run exactly one compatibility step; this is never model-quality evidence",
    )
    parser.add_argument("--skip-merge", action="store_true")
    return parser.parse_args()


def model_family(config: dict[str, Any]) -> str:
    model_type = str(config.get("model_type", "")).casefold().replace("_", "")
    architectures = " ".join(str(item) for item in config.get("architectures", []))
    if "qwen35" in model_type or "qwen3_5" in architectures.casefold():
        return QWEN35_FAMILY
    if "gemma" in model_type or "gemma" in architectures.casefold():
        return "gemma"
    return "other"


def resolve_training_mode(family: str, requested: str) -> str:
    resolved = BF16_LORA_MODE if family == QWEN35_FAMILY else QLORA_MODE
    if requested != "auto":
        resolved = requested
    if family == QWEN35_FAMILY and resolved == QLORA_MODE:
        raise ValueError(
            "Refusing Qwen3.5 QLoRA: Unsloth recommends BF16 LoRA because its "
            "4-bit quantization differences are higher than normal"
        )
    if family != QWEN35_FAMILY and resolved == BF16_LORA_MODE:
        raise ValueError("BF16 LoRA is currently implemented only for Qwen3.5")
    return resolved


def validate_preflight_request(
    *,
    family: str,
    enabled: bool,
    rows: list[dict[str, Any]],
    skip_merge: bool,
    data_sha256: str,
    rank: int,
) -> None:
    if family == QWEN35_FAMILY and not enabled:
        raise ValueError(
            "Qwen3.5 full training is not authorized; --preflight-only is currently required"
        )
    if not enabled:
        return
    if family != QWEN35_FAMILY:
        raise ValueError("--preflight-only is currently authorized only for Qwen3.5")
    if len(rows) not in range(2, 5):
        raise ValueError("--preflight-only requires exactly 2 to 4 private synthetic rows")
    if not skip_merge:
        raise ValueError("--preflight-only requires --skip-merge")
    if rank != 16:
        raise ValueError("--preflight-only requires the script-owned rank-16 contract")
    expected_data_sha256 = str(QWEN35_PREFLIGHT_CONTRACT["data_sha256"])
    if data_sha256 != expected_data_sha256:
        raise ValueError(
            f"Preflight data SHA-256 mismatch: expected {expected_data_sha256}, got {data_sha256}"
        )
    allowed_keys = {"input", "output", "preflight_provenance"}
    for index, row in enumerate(rows):
        if set(row) != allowed_keys:
            raise ValueError(
                f"Preflight row {index} must contain only {sorted(allowed_keys)}; "
                "benchmark/D1 metadata is forbidden"
            )
        if row["preflight_provenance"] != QWEN35_PREFLIGHT_CONTRACT["row_provenance"]:
            raise ValueError(
                f"Preflight row {index} lacks the exact private synthetic provenance marker"
            )
        if not row["input"].strip() or not row["output"].strip():
            raise ValueError(f"Preflight row {index} has an empty input or output")
    inputs = [row["input"].strip().casefold() for row in rows]
    outputs = [row["output"].strip().casefold() for row in rows]
    if len(set(inputs)) != len(inputs) or len(set(outputs)) != len(outputs):
        raise ValueError("Preflight rows must have unique inputs and outputs")


def local_hugging_face_revision(base_path: Path, artifact_name: str) -> str | None:
    metadata_path = base_path / ".cache/huggingface/download" / f"{artifact_name}.metadata"
    if not metadata_path.is_file():
        return None
    return next(
        (
            line.strip()
            for line in metadata_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ),
        None,
    )


def validate_qwen35_base_artifacts(base_path: Path) -> dict[str, Any]:
    expected_revision = str(QWEN35_PREFLIGHT_CONTRACT["base_revision"])
    expected_hashes = dict(QWEN35_PREFLIGHT_CONTRACT["artifact_sha256"])
    artifact_receipt: dict[str, Any] = {}
    for artifact_name, expected_sha256 in sorted(expected_hashes.items()):
        artifact_path = base_path / artifact_name
        if not artifact_path.is_file():
            raise ValueError(f"Pinned Qwen3.5 artifact is missing: {artifact_path}")
        actual_sha256 = sha256(artifact_path)
        if actual_sha256 != expected_sha256:
            raise ValueError(
                f"Pinned Qwen3.5 artifact hash mismatch for {artifact_name}: "
                f"expected {expected_sha256}, got {actual_sha256}"
            )
        actual_revision = local_hugging_face_revision(base_path, artifact_name)
        if actual_revision != expected_revision:
            raise ValueError(
                f"Pinned Qwen3.5 artifact revision mismatch for {artifact_name}: "
                f"expected {expected_revision}, got {actual_revision or 'no metadata'}"
            )
        artifact_receipt[artifact_name] = {
            "sha256": actual_sha256,
            "revision": actual_revision,
        }

    index_path = base_path / "model.safetensors.index.json"
    index = json.loads(index_path.read_text(encoding="utf-8"))
    actual_shards = sorted(set(index.get("weight_map", {}).values()))
    expected_shards = sorted(QWEN35_PREFLIGHT_CONTRACT["weight_shards"])
    if actual_shards != expected_shards:
        raise ValueError(
            f"Pinned Qwen3.5 index shard list mismatch: expected {expected_shards}, "
            f"got {actual_shards}"
        )
    return {
        "schema_version": QWEN35_PREFLIGHT_CONTRACT["schema_version"],
        "revision": expected_revision,
        "artifacts": artifact_receipt,
        "index_weight_shards": actual_shards,
    }


def response_marker_for_family(family: str) -> str:
    return GEMMA_RESPONSE_MARKER if family == "gemma" else QWEN35_RESPONSE_MARKER


def validate_response_markers(rendered_texts: list[str], family: str) -> tuple[str, list[int]]:
    marker = response_marker_for_family(family)
    counts = [text.count(marker) for text in rendered_texts]
    if any(count != 1 for count in counts):
        raise ValueError(f"Expected one response marker per rendered row, got {counts}")
    return marker, counts


def qwen35_target_suffix_counts(module_names: list[str]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for name in module_names:
        suffix = name.rsplit(".", 1)[-1]
        counts[suffix] = counts.get(suffix, 0) + 1
    return dict(sorted(counts.items()))


def qwen35_forbidden_target_names(module_names: list[str]) -> list[str]:
    forbidden: list[str] = []
    for name in module_names:
        components = name.casefold().split(".")
        if any(
            component == "visual"
            or component.startswith("vision_")
            or component in {"multi_modal_projector", "multimodal_projector"}
            or component == "mtp"
            or component.startswith("mtp_")
            for component in components
        ):
            forbidden.append(name)
    return forbidden


def expected_qwen35_trainable_parameters(rank: int) -> int:
    if rank <= 0:
        raise ValueError("LoRA rank must be positive")
    rank_16_parameters = int(QWEN35_PREFLIGHT_CONTRACT["rank_16_trainable_parameters"])
    return rank_16_parameters * rank // 16


def validate_qwen35_adapter_receipt(
    module_names: list[str], trainable_parameters: int, rank: int
) -> None:
    suffix_counts = qwen35_target_suffix_counts(module_names)
    expected_suffix_counts = dict(QWEN35_PREFLIGHT_CONTRACT["target_suffix_counts"])
    if suffix_counts != expected_suffix_counts:
        raise RuntimeError(
            "Qwen3.5 LoRA target coverage drifted: "
            f"expected {expected_suffix_counts}, got {suffix_counts}"
        )
    forbidden = qwen35_forbidden_target_names(module_names)
    if forbidden:
        raise RuntimeError(f"Qwen3.5 LoRA unexpectedly targeted vision/MTP modules: {forbidden}")
    expected_trainable = expected_qwen35_trainable_parameters(rank)
    if trainable_parameters != expected_trainable:
        raise RuntimeError(
            "Qwen3.5 trainable parameter count drifted: "
            f"expected {expected_trainable}, got {trainable_parameters}"
        )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_prompt(path: Path) -> str:
    lines = [
        line
        for line in path.read_text(encoding="utf-8").splitlines()
        if not line.startswith("#")
    ]
    prompt = "\n".join(lines).strip()
    if not prompt:
        raise ValueError("Prompt is empty after provenance comments are removed")
    return prompt


def read_rows(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            row = json.loads(line)
            if not isinstance(row.get("input"), str) or not isinstance(row.get("output"), str):
                raise ValueError(f"{path}:{line_number}: missing string input/output")
            rows.append(row)
    if not rows:
        raise ValueError("Training dataset is empty")
    return rows


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def sft_config(SFTConfig: Any, **kwargs: Any) -> Any:
    parameters = set(inspect.signature(SFTConfig.__init__).parameters)
    if "max_seq_length" in kwargs and "max_seq_length" not in parameters:
        kwargs["max_length"] = kwargs.pop("max_seq_length")
    return SFTConfig(**{key: value for key, value in kwargs.items() if key in parameters})


def main() -> None:
    args = parse_args()
    base_path = Path(os.path.expanduser(args.base)).resolve()
    data_path = Path(os.path.expanduser(args.data)).resolve()
    prompt_path = Path(os.path.expanduser(args.prompt)).resolve()
    output_dir = Path(os.path.expanduser(args.output_root)).resolve() / args.tag
    config_path = base_path / "config.json"
    if not config_path.is_file():
        raise SystemExit(f"Base model config is missing: {config_path}")
    config = json.loads(config_path.read_text(encoding="utf-8"))
    family = model_family(config)
    try:
        training_mode = resolve_training_mode(family, args.training_mode)
    except ValueError as error:
        raise SystemExit(str(error)) from error

    if output_dir.exists():
        raise SystemExit(f"Refusing to reuse existing output directory: {output_dir}")

    rows = read_rows(data_path)
    data_sha256 = sha256(data_path)
    try:
        validate_preflight_request(
            family=family,
            enabled=args.preflight_only,
            rows=rows,
            skip_merge=args.skip_merge,
            data_sha256=data_sha256,
            rank=args.rank,
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error

    base_artifact_receipt: dict[str, Any] | None = None
    if family == QWEN35_FAMILY:
        try:
            base_artifact_receipt = validate_qwen35_base_artifacts(base_path)
        except ValueError as error:
            raise SystemExit(str(error)) from error
        base_revision = str(base_artifact_receipt["revision"])
    else:
        base_revision = local_hugging_face_revision(base_path, "config.json")
    if family == QWEN35_FAMILY and os.environ.get("UNSLOTH_ENABLE_FULL_FINETUNING") == "1":
        raise SystemExit("Refusing Qwen3.5 run with UNSLOTH_ENABLE_FULL_FINETUNING=1")

    system_prompt = read_prompt(prompt_path)
    lora_dropout = 0 if family == QWEN35_FAMILY else 0.05
    output_dir.mkdir(parents=True)
    manifest: dict[str, Any] = {
        "status": "starting",
        "evidence_class": (
            PREFLIGHT_EVIDENCE_CLASS if args.preflight_only else "training_experiment"
        ),
        "quality_evidence": False if args.preflight_only else None,
        "tag": args.tag,
        "host": platform.node(),
        "platform": platform.platform(),
        "base_path": str(base_path),
        "base_family": family,
        "base_revision": base_revision,
        "preflight_contract": QWEN35_PREFLIGHT_CONTRACT if args.preflight_only else None,
        "base_artifact_receipt": base_artifact_receipt,
        "base_config_sha256": sha256(config_path),
        "data_path": str(data_path),
        "data_sha256": data_sha256,
        "row_count": len(rows),
        "prompt_path": str(prompt_path),
        "prompt_sha256": sha256(prompt_path),
        "system_prompt": system_prompt,
        "hyperparameters": {
            "learning_rate": args.lr,
            "epochs": args.epochs,
            "rank": args.rank,
            "alpha": args.alpha,
            "lora_dropout": lora_dropout,
            "micro_batch": args.micro_batch,
            "gradient_accumulation": args.gradient_accumulation,
            "effective_batch": args.micro_batch * args.gradient_accumulation,
            "max_seq": args.max_seq,
            "seed": args.seed,
            "training_mode": training_mode,
            "preflight_only": args.preflight_only,
            "max_steps": 1 if args.preflight_only else None,
            "optimizer": "adamw_8bit",
            "scheduler": "cosine",
            "warmup_ratio": 0.05,
            "weight_decay": 0.01,
            "response_only_loss": True,
            "bf16": True,
            "load_in_4bit": training_mode == QLORA_MODE,
            "load_in_16bit": training_mode == BF16_LORA_MODE,
        },
        "started_at_epoch": time.time(),
    }
    write_json(output_dir / "training-manifest.json", manifest)

    manifest["package_versions"] = {
        package: distribution_version(package)
        for package in (
            "accelerate",
            "bitsandbytes",
            "datasets",
            "peft",
            "transformers",
            "trl",
            "unsloth",
        )
    }
    if family == QWEN35_FAMILY and int(
        manifest["package_versions"]["transformers"].split(".", 1)[0]
    ) < 5:
        raise RuntimeError("Qwen3.5 requires Transformers v5 or newer")
    write_json(output_dir / "training-manifest.json", manifest)

    from unsloth import FastLanguageModel
    from unsloth.chat_templates import train_on_responses_only
    import torch
    from datasets import Dataset
    from trl import SFTConfig, SFTTrainer

    torch.manual_seed(args.seed)
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is required for this AlienSV trainer")
    if training_mode == BF16_LORA_MODE and not torch.cuda.is_bf16_supported():
        raise RuntimeError("Selected GPU does not support BF16 LoRA")
    manifest["torch_version"] = torch.__version__
    manifest["cuda_device"] = torch.cuda.get_device_name(0)
    manifest["cuda_bf16_supported"] = torch.cuda.is_bf16_supported()

    if family == QWEN35_FAMILY:
        from unsloth import FastModel

        model, tokenizer = FastModel.from_pretrained(
            model_name=str(base_path),
            max_seq_length=args.max_seq,
            load_in_4bit=False,
            load_in_8bit=False,
            load_in_16bit=True,
            full_finetuning=False,
            use_gradient_checkpointing="unsloth",
            text_only=True,
        )
        model = FastModel.get_peft_model(
            model,
            r=args.rank,
            lora_alpha=args.alpha,
            lora_dropout=0,
            bias="none",
            target_modules=None,
            finetune_vision_layers=False,
            finetune_language_layers=True,
            finetune_attention_modules=True,
            finetune_mlp_modules=True,
            use_gradient_checkpointing="unsloth",
            random_state=args.seed,
        )
    else:
        # Preserve the original Gemma/older-Qwen QLoRA behavior byte-for-byte in
        # its model-loader and adapter configuration.
        model, tokenizer = FastLanguageModel.from_pretrained(
            model_name=str(base_path),
            max_seq_length=args.max_seq,
            load_in_4bit=True,
        )
        model = FastLanguageModel.get_peft_model(
            model,
            r=args.rank,
            lora_alpha=args.alpha,
            lora_dropout=0.05,
            bias="none",
            target_modules=[
                "q_proj",
                "k_proj",
                "v_proj",
                "o_proj",
                "gate_proj",
                "up_proj",
                "down_proj",
            ],
            use_gradient_checkpointing="unsloth",
            random_state=args.seed,
        )

    lora_module_names = sorted(
        name for name, module in model.named_modules() if hasattr(module, "lora_A")
    )
    trainable_parameters = sum(
        parameter.numel() for parameter in model.parameters() if parameter.requires_grad
    )
    manifest["adapter_receipt"] = {
        "matched_module_count": len(lora_module_names),
        "matched_module_names": lora_module_names,
        "target_suffix_counts": qwen35_target_suffix_counts(lora_module_names),
        "forbidden_vision_mtp_matches": qwen35_forbidden_target_names(lora_module_names),
        "trainable_parameter_count": trainable_parameters,
        "total_parameter_count": sum(parameter.numel() for parameter in model.parameters()),
    }
    if family == QWEN35_FAMILY:
        validate_qwen35_adapter_receipt(lora_module_names, trainable_parameters, args.rank)
    write_json(output_dir / "training-manifest.json", manifest)

    def to_text(row: dict[str, Any]) -> dict[str, str]:
        messages = [
            {"role": "system", "content": system_prompt},
            {
                "role": "user",
                "content": f"<TRANSCRIPT>\n{row['input']}\n</TRANSCRIPT>",
            },
            {"role": "assistant", "content": row["output"]},
        ]
        return {
            "text": tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=False,
                enable_thinking=False,
            )
        }

    rendered_rows = [to_text(row) for row in rows]
    response_marker = response_marker_for_family(family)
    response_marker_counts = [row["text"].count(response_marker) for row in rendered_rows]
    if args.preflight_only:
        try:
            response_marker, response_marker_counts = validate_response_markers(
                [row["text"] for row in rendered_rows], family
            )
        except ValueError as error:
            raise RuntimeError(str(error)) from error
    manifest["response_mask_receipt"] = {
        "marker": response_marker,
        "rendered_marker_counts": response_marker_counts,
    }
    dataset = Dataset.from_list(rendered_rows).shuffle(seed=args.seed)
    trainer_kwargs: dict[str, Any] = {
        "model": model,
        "train_dataset": dataset,
        "args": sft_config(
            SFTConfig,
            dataset_text_field="text",
            per_device_train_batch_size=args.micro_batch,
            gradient_accumulation_steps=args.gradient_accumulation,
            num_train_epochs=args.epochs,
            max_steps=1 if args.preflight_only else -1,
            learning_rate=args.lr,
            warmup_ratio=0.05,
            lr_scheduler_type="cosine",
            logging_steps=1 if args.preflight_only else 10,
            optim="adamw_8bit",
            weight_decay=0.01,
            bf16=True,
            max_seq_length=args.max_seq,
            output_dir=str(output_dir / "checkpoints"),
            report_to="none",
            seed=args.seed,
            save_strategy="no" if args.preflight_only else "epoch",
        ),
    }
    trainer_parameters = set(inspect.signature(SFTTrainer.__init__).parameters)
    if "tokenizer" in trainer_parameters:
        trainer_kwargs["tokenizer"] = tokenizer
    elif "processing_class" in trainer_parameters:
        trainer_kwargs["processing_class"] = tokenizer
    else:
        raise RuntimeError("SFTTrainer accepts neither tokenizer nor processing_class")
    trainer = SFTTrainer(**trainer_kwargs)

    if family == "gemma":
        trainer = train_on_responses_only(
            trainer,
            instruction_part="<|turn>user\n",
            response_part="<|turn>model\n",
        )
    else:
        trainer = train_on_responses_only(
            trainer,
            instruction_part="<|im_start|>user\n",
            response_part="<|im_start|>assistant\n",
        )

    if args.preflight_only:
        labeled_token_counts: list[int] = []
        for sample_index in range(len(trainer.train_dataset)):
            sample = trainer.train_dataset[sample_index]
            if "labels" not in sample:
                raise RuntimeError(
                    f"Response-only loss mask produced no labels for sample {sample_index}"
                )
            labeled_tokens = sum(token != -100 for token in sample["labels"])
            if labeled_tokens <= 0:
                raise RuntimeError(
                    f"Response-only loss mask removed every token in sample {sample_index}"
                )
            labeled_token_counts.append(labeled_tokens)
        manifest["sample_0_labeled_tokens"] = labeled_token_counts[0]
        manifest["response_mask_receipt"]["labeled_token_counts"] = labeled_token_counts
    else:
        # Historical behavior: normal Gemma/older-Qwen runs only sample row 0.
        sample = trainer.train_dataset[0]
        if "labels" in sample:
            labeled_tokens = sum(token != -100 for token in sample["labels"])
            if labeled_tokens <= 0:
                raise RuntimeError("Response-only loss mask removed every token in sample 0")
            manifest["sample_0_labeled_tokens"] = labeled_tokens
    write_json(output_dir / "training-manifest.json", manifest)

    torch.cuda.reset_peak_memory_stats()
    training_started = time.perf_counter()
    statistics = trainer.train()
    manifest["training_elapsed_seconds"] = round(time.perf_counter() - training_started, 3)
    manifest["training_metrics"] = statistics.metrics
    manifest["completed_steps"] = int(trainer.state.global_step)
    manifest["peak_cuda_memory_allocated_bytes"] = torch.cuda.max_memory_allocated()
    manifest["peak_cuda_memory_reserved_bytes"] = torch.cuda.max_memory_reserved()
    if args.preflight_only and manifest["completed_steps"] != 1:
        raise RuntimeError(
            f"Preflight must complete exactly one step, got {manifest['completed_steps']}"
        )

    adapter_dir = output_dir / "adapter"
    model.save_pretrained(adapter_dir)
    tokenizer.save_pretrained(adapter_dir)
    manifest["adapter_path"] = str(adapter_dir)

    if not args.skip_merge:
        merged_dir = output_dir / "merged16"
        model.save_pretrained_merged(str(merged_dir), tokenizer, save_method="merged_16bit")
        manifest["merged_path"] = str(merged_dir)

    manifest["status"] = "complete"
    manifest["completed_at_epoch"] = time.time()
    write_json(output_dir / "training-manifest.json", manifest)
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
