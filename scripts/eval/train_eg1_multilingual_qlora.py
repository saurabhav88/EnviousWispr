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
import math
import os
import platform
import tempfile
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
QWEN35_MLP_TARGET_SUFFIXES = ("gate_proj", "up_proj", "down_proj")
QWEN35_FULL_ATTENTION_TARGET_SUFFIXES = ("q_proj", "k_proj", "v_proj", "o_proj")
QWEN35_LINEAR_ATTENTION_TARGET_SUFFIXES = (
    "in_proj_a",
    "in_proj_b",
    "in_proj_qkv",
    "in_proj_z",
    "out_proj",
)
QWEN35_ALLOWED_PEFT_PREFIXES = ("base_model.model.",)
QWEN35_EXACT_INJECTION_METHOD = "unsloth_explicit_full_paths_v1"
QWEN35_AUDITED_STACK_VERSIONS = {
    "peft": "0.19.1",
    "transformers": "5.5.0",
    "unsloth": "2026.6.9",
}
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
    "prompt_sha256": "7ea77511b979a15df1ce28e20536b7920e47df42748d3a6e99adadaa5551bf62",
    "max_steps": 1,
    "scheduler": "cosine",
    "warmup_ratio": 0.0,
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
    "target_module_set_sha256": (
        "707ca9ad5e438a00d45d0625b82467881ba356ef73f1319b21baa5ddcbb9ace3"
    ),
    "adapter_injection_method": QWEN35_EXACT_INJECTION_METHOD,
    "audited_stack_versions": QWEN35_AUDITED_STACK_VERSIONS,
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
    prompt_sha256: str | None,
    rank: int,
    learning_rate: float,
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
    qwen35_preflight_first_step_learning_rate(learning_rate)
    expected_data_sha256 = str(QWEN35_PREFLIGHT_CONTRACT["data_sha256"])
    if data_sha256 != expected_data_sha256:
        raise ValueError(
            f"Preflight data SHA-256 mismatch: expected {expected_data_sha256}, got {data_sha256}"
        )
    expected_prompt_sha256 = str(QWEN35_PREFLIGHT_CONTRACT["prompt_sha256"])
    if prompt_sha256 != expected_prompt_sha256:
        raise ValueError(
            "Preflight prompt SHA-256 mismatch: "
            f"expected {expected_prompt_sha256}, got {prompt_sha256 or 'no prompt hash'}"
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


def effective_warmup_ratio(family: str, preflight_only: bool) -> float:
    if family == QWEN35_FAMILY and preflight_only:
        return float(QWEN35_PREFLIGHT_CONTRACT["warmup_ratio"])
    return 0.05


def qwen35_preflight_first_step_learning_rate(learning_rate: float) -> float:
    max_steps = int(QWEN35_PREFLIGHT_CONTRACT["max_steps"])
    scheduler = str(QWEN35_PREFLIGHT_CONTRACT["scheduler"])
    warmup_ratio = float(QWEN35_PREFLIGHT_CONTRACT["warmup_ratio"])
    warmup_steps = math.ceil(max_steps * warmup_ratio)
    if max_steps != 1 or scheduler != "cosine" or warmup_steps != 0:
        raise ValueError(
            "Qwen3.5 preflight scheduler contract requires one cosine step with zero warmup"
        )
    if not math.isfinite(learning_rate) or learning_rate <= 0:
        raise ValueError("Qwen3.5 preflight learning rate must be finite and positive")
    return learning_rate


def qwen35_training_stack_receipt(
    package_versions: dict[str, str],
) -> dict[str, Any]:
    required = dict(QWEN35_AUDITED_STACK_VERSIONS)
    observed = {
        package: package_versions.get(package, "missing") for package in sorted(required)
    }
    mismatches = {
        package: {"expected": required[package], "observed": observed[package]}
        for package in sorted(required)
        if observed[package] != required[package]
    }
    return {
        "status": "passed" if not mismatches else "failed",
        "required_versions": required,
        "observed_versions": observed,
        "mismatches": mismatches,
    }


def validate_qwen35_training_stack(package_versions: dict[str, str]) -> dict[str, Any]:
    receipt = qwen35_training_stack_receipt(package_versions)
    if receipt["mismatches"]:
        raise RuntimeError(
            "Qwen3.5 audited training stack drifted: "
            f"{sorted(receipt['mismatches'])}"
        )
    return receipt


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


def validate_qwen35_base_artifacts(
    base_path: Path, *, config_bytes: bytes | None = None
) -> dict[str, Any]:
    expected_revision = str(QWEN35_PREFLIGHT_CONTRACT["base_revision"])
    expected_hashes = dict(QWEN35_PREFLIGHT_CONTRACT["artifact_sha256"])
    if config_bytes is None:
        config_bytes, captured_config_sha256 = read_once(
            base_path / "config.json", "pinned Qwen3.5 config"
        )
    else:
        captured_config_sha256 = sha256_bytes(config_bytes)
    index_bytes, captured_index_sha256 = read_once(
        base_path / "model.safetensors.index.json",
        "pinned Qwen3.5 model index",
    )
    captured_small_hashes = {
        "config.json": captured_config_sha256,
        "model.safetensors.index.json": captured_index_sha256,
    }
    captured_config = parse_json_object_bytes(config_bytes, "pinned Qwen3.5 config")
    if model_family(captured_config) != QWEN35_FAMILY:
        raise ValueError("Pinned Qwen3.5 config no longer identifies Qwen3.5")
    index = parse_json_object_bytes(index_bytes, "pinned Qwen3.5 model index")
    artifact_receipt: dict[str, Any] = {}
    for artifact_name, expected_sha256 in sorted(expected_hashes.items()):
        artifact_path = base_path / artifact_name
        if not artifact_path.is_file():
            raise ValueError(f"Pinned Qwen3.5 artifact is missing: {artifact_path}")
        if artifact_name in captured_small_hashes:
            actual_sha256 = captured_small_hashes[artifact_name]
        else:
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


def qwen35_text_layer_types(config: dict[str, Any]) -> list[str]:
    text_config = config.get("text_config")
    if not isinstance(text_config, dict):
        raise RuntimeError("Pinned Qwen3.5 config lacks text_config")
    layer_types = text_config.get("layer_types")
    hidden_layers = text_config.get("num_hidden_layers")
    expected_layers = int(QWEN35_EXPECTED_TARGET_SUFFIX_COUNTS["gate_proj"])
    if hidden_layers != expected_layers or not isinstance(layer_types, list):
        raise RuntimeError(
            "Pinned Qwen3.5 text-layer contract drifted: "
            f"expected {expected_layers} layer_types, got {hidden_layers}"
        )
    normalized = [str(layer_type) for layer_type in layer_types]
    if len(normalized) != expected_layers:
        raise RuntimeError(
            "Pinned Qwen3.5 layer_types length drifted: "
            f"expected {expected_layers}, got {len(normalized)}"
        )
    unknown = sorted(set(normalized) - {"linear_attention", "full_attention"})
    expected_linear = int(QWEN35_EXPECTED_TARGET_SUFFIX_COUNTS["in_proj_a"])
    expected_full = int(QWEN35_EXPECTED_TARGET_SUFFIX_COUNTS["q_proj"])
    if (
        unknown
        or normalized.count("linear_attention") != expected_linear
        or normalized.count("full_attention") != expected_full
    ):
        raise RuntimeError(
            "Pinned Qwen3.5 layer-type distribution drifted: "
            f"unknown={unknown}, linear={normalized.count('linear_attention')}, "
            f"full={normalized.count('full_attention')}"
        )
    return normalized


def qwen35_expected_target_module_names(config: dict[str, Any]) -> list[str]:
    expected: list[str] = []
    for layer_index, layer_type in enumerate(qwen35_text_layer_types(config)):
        layer_prefix = f"model.layers.{layer_index}"
        expected.extend(
            f"{layer_prefix}.mlp.{suffix}" for suffix in QWEN35_MLP_TARGET_SUFFIXES
        )
        if layer_type == "full_attention":
            parent = "self_attn"
            suffixes = QWEN35_FULL_ATTENTION_TARGET_SUFFIXES
        else:
            parent = "linear_attn"
            suffixes = QWEN35_LINEAR_ATTENTION_TARGET_SUFFIXES
        expected.extend(f"{layer_prefix}.{parent}.{suffix}" for suffix in suffixes)
    expected = sorted(expected)
    expected_hash = str(QWEN35_PREFLIGHT_CONTRACT["target_module_set_sha256"])
    actual_hash = qwen35_module_set_sha256(expected)
    if actual_hash != expected_hash:
        raise RuntimeError(
            "Pinned Qwen3.5 target placement hash drifted: "
            f"expected {expected_hash}, got {actual_hash}"
        )
    return expected


def qwen35_module_set_sha256(module_names: list[str]) -> str:
    canonical = "\n".join(sorted(set(module_names))) + "\n"
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def qwen35_duplicate_module_names(module_names: list[str]) -> list[str]:
    counts: dict[str, int] = {}
    for name in module_names:
        counts[name] = counts.get(name, 0) + 1
    return sorted(name for name, count in counts.items() if count > 1)


def qwen35_target_placement_counts(module_names: list[str]) -> dict[str, Any]:
    placements: dict[str, dict[str, Any]] = {}
    unparsed = 0
    for name in module_names:
        components = name.split(".")
        parsed = False
        for index in range(len(components) - 3):
            if components[index] != "layers" or not components[index + 1].isdigit():
                continue
            parent = components[index + 2]
            placement = placements.setdefault(
                parent, {"module_count": 0, "layer_indices": set()}
            )
            placement["module_count"] += 1
            placement["layer_indices"].add(int(components[index + 1]))
            parsed = True
            break
        if not parsed:
            unparsed += 1
    result: dict[str, Any] = {}
    for parent, placement in sorted(placements.items()):
        layer_indices = sorted(placement["layer_indices"])
        result[parent] = {
            "module_count": placement["module_count"],
            "layer_count": len(layer_indices),
            "layer_indices": layer_indices,
        }
    if unparsed:
        result["unparsed"] = {"module_count": unparsed}
    return result


def derive_qwen35_expected_targets_before_peft(
    model: Any, config: dict[str, Any]
) -> list[str]:
    expected = qwen35_expected_target_module_names(config)
    module_names = [name for name, _module in model.named_modules()]
    duplicate_names = qwen35_duplicate_module_names(module_names)
    target_suffixes = set(QWEN35_EXPECTED_TARGET_SUFFIX_COUNTS)
    observed = sorted(
        name
        for name in module_names
        if name.startswith("model.layers.")
        and name.rsplit(".", 1)[-1] in target_suffixes
    )
    if duplicate_names or set(observed) != set(expected):
        missing = sorted(set(expected) - set(observed))
        unexpected = sorted(set(observed) - set(expected))
        raise RuntimeError(
            "Pinned Qwen3.5 base target placement drifted before PEFT injection: "
            f"expected_hash={qwen35_module_set_sha256(expected)}, "
            f"actual_hash={qwen35_module_set_sha256(observed)}, "
            f"missing={len(missing)}, unexpected={len(unexpected)}, "
            f"duplicates={len(duplicate_names)}"
        )
    return expected


def qwen35_normalized_adapter_placement(
    module_names: list[str], expected_module_names: list[str]
) -> dict[str, Any]:
    expected_set = set(expected_module_names)
    normalized: list[str] = []
    unmatched: list[str] = []
    prefixes: list[str] = []
    for name in module_names:
        if name in expected_set:
            normalized.append(name)
            prefixes.append("direct")
            continue
        matched = False
        for prefix in QWEN35_ALLOWED_PEFT_PREFIXES:
            if name.startswith(prefix) and name[len(prefix) :] in expected_set:
                normalized.append(name[len(prefix) :])
                prefixes.append(prefix)
                matched = True
                break
        if not matched:
            unmatched.append(name)
    hash_names = normalized + [f"<unmatched>{name}" for name in unmatched]
    placement_names = normalized + unmatched
    return {
        "expected_target_module_count": len(expected_module_names),
        "actual_target_module_count": len(module_names),
        "expected_target_module_set_sha256": qwen35_module_set_sha256(
            expected_module_names
        ),
        "actual_target_module_set_sha256": qwen35_module_set_sha256(hash_names),
        "expected_target_placement_counts": qwen35_target_placement_counts(
            expected_module_names
        ),
        "actual_target_placement_counts": qwen35_target_placement_counts(
            placement_names
        ),
        "normalized_matched_module_names": sorted(normalized),
        "unmatched_module_names": sorted(unmatched),
        "normalization_prefixes": sorted(set(prefixes)),
        "duplicate_expected_module_names": qwen35_duplicate_module_names(
            expected_module_names
        ),
        "duplicate_module_names": qwen35_duplicate_module_names(module_names),
        "duplicate_normalized_module_names": qwen35_duplicate_module_names(normalized),
    }


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


def qwen35_exact_injection_kwargs(
    *,
    expected_module_names: list[str],
    rank: int,
    alpha: int,
    seed: int,
) -> dict[str, Any]:
    ordered_targets = sorted(expected_module_names)
    duplicates = qwen35_duplicate_module_names(ordered_targets)
    expected_count = sum(QWEN35_EXPECTED_TARGET_SUFFIX_COUNTS.values())
    expected_hash = str(QWEN35_PREFLIGHT_CONTRACT["target_module_set_sha256"])
    actual_hash = qwen35_module_set_sha256(ordered_targets)
    actual_suffix_counts = qwen35_target_suffix_counts(ordered_targets)
    forbidden = qwen35_forbidden_target_names(ordered_targets)
    if (
        len(ordered_targets) != expected_count
        or duplicates
        or actual_hash != expected_hash
        or actual_suffix_counts != QWEN35_EXPECTED_TARGET_SUFFIX_COUNTS
        or forbidden
    ):
        raise RuntimeError(
            "Qwen3.5 exact injection target contract drifted before Unsloth: "
            f"expected_count={expected_count}, actual_count={len(ordered_targets)}, "
            f"expected_hash={expected_hash}, actual_hash={actual_hash}, "
            f"duplicates={len(duplicates)}, forbidden={len(forbidden)}"
        )
    if rank <= 0 or alpha <= 0:
        raise ValueError("Qwen3.5 LoRA rank and alpha must be positive")
    return {
        "r": rank,
        "lora_alpha": alpha,
        "lora_dropout": 0,
        "bias": "none",
        "target_modules": ordered_targets,
        # With any filter set false, Unsloth 2026.6.9 rewrites an explicit
        # list through its regex selector. Keeping all selectors open makes
        # PEFT's explicit full paths the sole placement authority.
        "finetune_vision_layers": True,
        "finetune_language_layers": True,
        "finetune_attention_modules": True,
        "finetune_mlp_modules": True,
        "target_parameters": [],
        "use_gradient_checkpointing": "unsloth",
        "random_state": seed,
    }


def inject_qwen35_exact_adapter_with_receipt(
    *,
    fast_model: Any,
    model: Any,
    expected_module_names: list[str],
    rank: int,
    alpha: int,
    seed: int,
    manifest_path: Path,
    manifest: dict[str, Any],
) -> Any:
    injection_kwargs = qwen35_exact_injection_kwargs(
        expected_module_names=expected_module_names,
        rank=rank,
        alpha=alpha,
        seed=seed,
    )
    target_names = list(injection_kwargs["target_modules"])
    selector_flags = {
        key: injection_kwargs[key]
        for key in (
            "finetune_vision_layers",
            "finetune_language_layers",
            "finetune_attention_modules",
            "finetune_mlp_modules",
        )
    }
    manifest["status"] = "adapter_injection_in_progress_not_validated"
    manifest["adapter_injection_receipt"] = {
        "status": "requested_not_validated",
        "method": QWEN35_EXACT_INJECTION_METHOD,
        "target_module_count": len(target_names),
        "target_module_set_sha256": qwen35_module_set_sha256(target_names),
        "target_suffix_counts": qwen35_target_suffix_counts(target_names),
        "selector_flags": selector_flags,
        "target_parameters": [],
        "requested_at_epoch": time.time(),
    }
    write_json(manifest_path, manifest)

    try:
        injected_model = fast_model.get_peft_model(model, **injection_kwargs)
    except BaseException as error:
        manifest["status"] = "blocked_adapter_injection_failed"
        manifest["adapter_injection_receipt"].update(
            {
                "status": "failed",
                "error_type": type(error).__name__,
                "error_message_sha256": hashlib.sha256(
                    str(error).encode("utf-8")
                ).hexdigest(),
                "failed_at_epoch": time.time(),
            }
        )
        write_json(manifest_path, manifest)
        raise

    manifest["status"] = "adapter_injection_returned_validation_pending"
    manifest["adapter_injection_receipt"].update(
        {
            "status": "returned_pending_exact_validation",
            "returned_at_epoch": time.time(),
        }
    )
    write_json(manifest_path, manifest)
    return injected_model


def expected_qwen35_trainable_parameters(rank: int) -> int:
    if rank <= 0:
        raise ValueError("LoRA rank must be positive")
    rank_16_parameters = int(QWEN35_PREFLIGHT_CONTRACT["rank_16_trainable_parameters"])
    return rank_16_parameters * rank // 16


def validate_qwen35_adapter_receipt(
    module_names: list[str],
    expected_module_names: list[str],
    trainable_parameters: int,
    rank: int,
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
    placement = qwen35_normalized_adapter_placement(
        module_names, expected_module_names
    )
    actual_normalized = placement["normalized_matched_module_names"]
    if (
        placement["unmatched_module_names"]
        or placement["duplicate_expected_module_names"]
        or placement["duplicate_module_names"]
        or placement["duplicate_normalized_module_names"]
        or placement["normalization_prefixes"] not in [["base_model.model."], ["direct"]]
        or set(actual_normalized) != set(expected_module_names)
    ):
        raise RuntimeError(
            "Qwen3.5 LoRA target coverage drifted: exact placement mismatch; "
            f"expected_hash={placement['expected_target_module_set_sha256']}, "
            f"actual_hash={placement['actual_target_module_set_sha256']}, "
            f"unmatched={len(placement['unmatched_module_names'])}, "
            f"duplicates={len(placement['duplicate_module_names'])}"
        )
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


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def canonical_json_sha256(value: Any) -> str:
    encoded = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return sha256_bytes(encoded)


def read_once(path: Path, label: str) -> tuple[bytes, str]:
    try:
        value = path.read_bytes()
    except OSError as error:
        raise ValueError(f"Cannot read {label}: {path}") from error
    return value, sha256_bytes(value)


def parse_json_object_bytes(value: bytes, label: str) -> dict[str, Any]:
    try:
        text = value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"{label} is not valid UTF-8") from error
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as error:
        raise ValueError(f"{label} is invalid JSON") from error
    if not isinstance(parsed, dict):
        raise ValueError(f"{label} must be a JSON object")
    return parsed


def read_prompt_bytes(value: bytes, label: str) -> str:
    try:
        text = value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"{label} is not valid UTF-8") from error
    lines = [
        line
        for line in text.splitlines()
        if not line.startswith("#")
    ]
    prompt = "\n".join(lines).strip()
    if not prompt:
        raise ValueError("Prompt is empty after provenance comments are removed")
    return prompt


def read_rows_bytes(value: bytes, label: str) -> list[dict[str, Any]]:
    try:
        text = value.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"{label} is not valid UTF-8") from error
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"{label}:{line_number}: invalid JSON") from error
        if not isinstance(row, dict):
            raise ValueError(f"{label}:{line_number}: expected a JSON object")
        if not isinstance(row.get("input"), str) or not isinstance(row.get("output"), str):
            raise ValueError(f"{label}:{line_number}: missing string input/output")
        rows.append(row)
    if not rows:
        raise ValueError("Training dataset is empty")
    return rows


def capture_training_inputs(
    data_path: Path, prompt_path: Path
) -> tuple[list[dict[str, Any]], str, str, str]:
    data_bytes, data_sha256 = read_once(data_path, "training dataset")
    prompt_bytes, prompt_sha256 = read_once(prompt_path, "training prompt")
    rows = read_rows_bytes(data_bytes, str(data_path))
    system_prompt = read_prompt_bytes(prompt_bytes, str(prompt_path))
    return rows, system_prompt, data_sha256, prompt_sha256


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def revalidate_qwen35_artifacts_after_model_load(
    *,
    base_path: Path,
    startup_receipt: dict[str, Any],
    manifest_path: Path,
    manifest: dict[str, Any],
) -> None:
    startup_receipt_sha256 = canonical_json_sha256(startup_receipt)
    post_load_receipt_sha256: str | None = None
    try:
        post_load_receipt = validate_qwen35_base_artifacts(base_path)
        post_load_receipt_sha256 = canonical_json_sha256(post_load_receipt)
        if post_load_receipt != startup_receipt:
            raise RuntimeError(
                "Post-load Qwen3.5 artifact receipt differs from the startup receipt"
            )
    except Exception as error:
        manifest["status"] = "blocked_post_load_artifact_revalidation_failed"
        failure_receipt: dict[str, Any] = {
            "status": "failed",
            "phase": "post_model_load_pre_adapter_injection",
            "startup_receipt_sha256": startup_receipt_sha256,
            "error_type": type(error).__name__,
            "error_message_sha256": hashlib.sha256(
                str(error).encode("utf-8")
            ).hexdigest(),
            "failed_at_epoch": time.time(),
        }
        if post_load_receipt_sha256 is not None:
            failure_receipt["post_load_receipt_sha256"] = post_load_receipt_sha256
        manifest["post_load_artifact_revalidation_receipt"] = failure_receipt
        write_json(manifest_path, manifest)
        raise

    manifest["status"] = "base_artifacts_revalidated_after_load_not_injected"
    manifest["post_load_artifact_revalidation_receipt"] = {
        "status": "passed_pre_adapter_injection",
        "phase": "post_model_load_pre_adapter_injection",
        "startup_receipt_sha256": startup_receipt_sha256,
        "post_load_receipt_sha256": post_load_receipt_sha256,
        "revalidated_at_epoch": time.time(),
    }
    write_json(manifest_path, manifest)


def adapter_receipt(
    model: Any, lora_module_names: list[str], trainable_parameters: int
) -> dict[str, Any]:
    return {
        "matched_module_count": len(lora_module_names),
        "matched_module_names": lora_module_names,
        "target_suffix_counts": qwen35_target_suffix_counts(lora_module_names),
        "forbidden_vision_mtp_matches": qwen35_forbidden_target_names(lora_module_names),
        "trainable_parameter_count": trainable_parameters,
        "total_parameter_count": sum(parameter.numel() for parameter in model.parameters()),
    }


def persist_qwen35_adapter_receipt_before_validation(
    *,
    manifest_path: Path,
    manifest: dict[str, Any],
    receipt: dict[str, Any],
    lora_module_names: list[str],
    expected_module_names: list[str],
    trainable_parameters: int,
    rank: int,
) -> None:
    manifest["status"] = "adapter_validation_pending_not_complete"
    receipt["validation_status"] = "pending"
    receipt.update(
        qwen35_normalized_adapter_placement(
            lora_module_names, expected_module_names
        )
    )
    manifest["adapter_receipt"] = receipt
    write_json(manifest_path, manifest)

    try:
        validate_qwen35_adapter_receipt(
            lora_module_names,
            expected_module_names,
            trainable_parameters,
            rank,
        )
    except RuntimeError as error:
        manifest["status"] = "blocked_adapter_validation_failed"
        receipt["validation_status"] = "failed"
        receipt["validation_error_type"] = type(error).__name__
        receipt["validation_error_message_sha256"] = hashlib.sha256(
            str(error).encode("utf-8")
        ).hexdigest()
        injection_receipt = manifest.get("adapter_injection_receipt")
        if isinstance(injection_receipt, dict):
            injection_receipt["status"] = "returned_adapter_validation_failed"
        write_json(manifest_path, manifest)
        raise

    manifest["status"] = "adapter_validation_passed_not_trained"
    receipt["validation_status"] = "passed"
    injection_receipt = manifest.get("adapter_injection_receipt")
    if isinstance(injection_receipt, dict):
        injection_receipt["status"] = "validated_complete_pre_training"
        injection_receipt["validated_at_epoch"] = time.time()
    write_json(manifest_path, manifest)


def observed_global_step(trainer: Any) -> int | None:
    raw_step = getattr(getattr(trainer, "state", None), "global_step", None)
    try:
        return int(raw_step) if raw_step is not None else None
    except (TypeError, ValueError):
        return None


def persist_training_failure(
    *,
    manifest_path: Path,
    manifest: dict[str, Any],
    trainer: Any,
    status: str,
    phase: str,
    error: BaseException,
) -> None:
    step = observed_global_step(trainer)
    error_message = str(error)
    manifest["status"] = status
    manifest["observed_global_step"] = step
    manifest["failure_receipt"] = {
        "phase": phase,
        "error_type": type(error).__name__,
        "error_message_sha256": hashlib.sha256(error_message.encode("utf-8")).hexdigest(),
        "observed_global_step": step,
        "failed_at_epoch": time.time(),
    }
    write_json(manifest_path, manifest)


def run_training_and_save_with_receipts(
    *,
    trainer: Any,
    model: Any,
    tokenizer: Any,
    torch: Any,
    manifest_path: Path,
    manifest: dict[str, Any],
    output_dir: Path,
    preflight_only: bool,
    skip_merge: bool,
) -> None:
    torch.cuda.reset_peak_memory_stats()
    manifest["status"] = "training_in_progress_not_complete"
    manifest["training_started_at_epoch"] = time.time()
    manifest["observed_global_step"] = observed_global_step(trainer)
    write_json(manifest_path, manifest)

    training_started = time.perf_counter()
    try:
        statistics = trainer.train()
    except BaseException as error:
        manifest["training_elapsed_seconds"] = round(
            time.perf_counter() - training_started, 3
        )
        persist_training_failure(
            manifest_path=manifest_path,
            manifest=manifest,
            trainer=trainer,
            status="training_failed_not_complete",
            phase="trainer.train",
            error=error,
        )
        raise

    completed_steps = observed_global_step(trainer)
    manifest["training_elapsed_seconds"] = round(time.perf_counter() - training_started, 3)
    manifest["training_metrics"] = statistics.metrics
    manifest["completed_steps"] = completed_steps
    manifest["observed_global_step"] = completed_steps
    manifest["peak_cuda_memory_allocated_bytes"] = torch.cuda.max_memory_allocated()
    manifest["peak_cuda_memory_reserved_bytes"] = torch.cuda.max_memory_reserved()
    required_steps = int(QWEN35_PREFLIGHT_CONTRACT["max_steps"])
    if preflight_only and completed_steps != required_steps:
        error = RuntimeError(
            f"Preflight must complete exactly {required_steps} step, got {completed_steps}"
        )
        persist_training_failure(
            manifest_path=manifest_path,
            manifest=manifest,
            trainer=trainer,
            status="blocked_completed_step_mismatch",
            phase="completed_step_validation",
            error=error,
        )
        raise error

    adapter_dir = output_dir / "adapter"
    manifest["status"] = "training_complete_save_pending_not_complete"
    manifest["training_completed_at_epoch"] = time.time()
    manifest["adapter_save_receipt"] = {
        "status": "pending",
        "adapter_path": str(adapter_dir),
    }
    write_json(manifest_path, manifest)

    try:
        model.save_pretrained(adapter_dir)
        tokenizer.save_pretrained(adapter_dir)
    except BaseException as error:
        persist_training_failure(
            manifest_path=manifest_path,
            manifest=manifest,
            trainer=trainer,
            status="adapter_save_failed_not_complete",
            phase="adapter_save",
            error=error,
        )
        raise

    manifest["adapter_path"] = str(adapter_dir)
    manifest["adapter_save_receipt"] = {
        "status": "complete",
        "adapter_path": str(adapter_dir),
        "model_saved": True,
        "tokenizer_saved": True,
    }

    if not skip_merge:
        merged_dir = output_dir / "merged16"
        try:
            model.save_pretrained_merged(
                str(merged_dir), tokenizer, save_method="merged_16bit"
            )
        except BaseException as error:
            persist_training_failure(
                manifest_path=manifest_path,
                manifest=manifest,
                trainer=trainer,
                status="merge_failed_not_complete",
                phase="model_merge",
                error=error,
            )
            raise
        manifest["merged_path"] = str(merged_dir)

    manifest["status"] = "complete"
    manifest["completed_at_epoch"] = time.time()
    write_json(manifest_path, manifest)


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
    try:
        config_bytes, config_sha256 = read_once(config_path, "base model config")
        config = parse_json_object_bytes(config_bytes, "base model config")
    except ValueError as error:
        raise SystemExit(str(error)) from error
    family = model_family(config)
    try:
        training_mode = resolve_training_mode(family, args.training_mode)
    except ValueError as error:
        raise SystemExit(str(error)) from error

    if output_dir.exists():
        raise SystemExit(f"Refusing to reuse existing output directory: {output_dir}")

    try:
        rows, system_prompt, data_sha256, prompt_sha256 = capture_training_inputs(
            data_path, prompt_path
        )
        validate_preflight_request(
            family=family,
            enabled=args.preflight_only,
            rows=rows,
            skip_merge=args.skip_merge,
            data_sha256=data_sha256,
            prompt_sha256=prompt_sha256,
            rank=args.rank,
            learning_rate=args.lr,
        )
    except ValueError as error:
        raise SystemExit(str(error)) from error

    base_artifact_receipt: dict[str, Any] | None = None
    if family == QWEN35_FAMILY:
        try:
            base_artifact_receipt = validate_qwen35_base_artifacts(
                base_path, config_bytes=config_bytes
            )
        except ValueError as error:
            raise SystemExit(str(error)) from error
        base_revision = str(base_artifact_receipt["revision"])
    else:
        base_revision = local_hugging_face_revision(base_path, "config.json")
    if family == QWEN35_FAMILY and os.environ.get("UNSLOTH_ENABLE_FULL_FINETUNING") == "1":
        raise SystemExit("Refusing Qwen3.5 run with UNSLOTH_ENABLE_FULL_FINETUNING=1")

    lora_dropout = 0 if family == QWEN35_FAMILY else 0.05
    warmup_ratio = effective_warmup_ratio(family, args.preflight_only)
    scheduler = (
        str(QWEN35_PREFLIGHT_CONTRACT["scheduler"])
        if args.preflight_only
        else "cosine"
    )
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
        "base_config_sha256": config_sha256,
        "data_path": str(data_path),
        "data_sha256": data_sha256,
        "row_count": len(rows),
        "prompt_path": str(prompt_path),
        "prompt_sha256": prompt_sha256,
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
            "max_steps": (
                int(QWEN35_PREFLIGHT_CONTRACT["max_steps"])
                if args.preflight_only
                else None
            ),
            "optimizer": "adamw_8bit",
            "scheduler": scheduler,
            "warmup_ratio": warmup_ratio,
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
            "unsloth_zoo",
        )
    }
    if family == QWEN35_FAMILY:
        stack_receipt = qwen35_training_stack_receipt(manifest["package_versions"])
        manifest["training_stack_receipt"] = stack_receipt
        if stack_receipt["status"] != "passed":
            manifest["status"] = "blocked_audited_training_stack_drift"
            write_json(output_dir / "training-manifest.json", manifest)
            validate_qwen35_training_stack(manifest["package_versions"])
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

    expected_qwen35_target_names: list[str] | None = None
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
        if base_artifact_receipt is None:
            raise RuntimeError("Qwen3.5 base artifact startup receipt is missing")
        revalidate_qwen35_artifacts_after_model_load(
            base_path=base_path,
            startup_receipt=base_artifact_receipt,
            manifest_path=output_dir / "training-manifest.json",
            manifest=manifest,
        )
        try:
            expected_qwen35_target_names = derive_qwen35_expected_targets_before_peft(
                model, config
            )
        except RuntimeError as error:
            manifest["status"] = "blocked_base_target_derivation_failed"
            manifest["base_target_derivation_receipt"] = {
                "validation_status": "failed",
                "error_type": type(error).__name__,
                "error_message_sha256": hashlib.sha256(
                    str(error).encode("utf-8")
                ).hexdigest(),
            }
            write_json(output_dir / "training-manifest.json", manifest)
            raise
        manifest["status"] = "base_target_placement_derived_not_injected"
        manifest["base_target_derivation_receipt"] = {
            "validation_status": "passed_pre_injection",
            "expected_target_module_count": len(expected_qwen35_target_names),
            "expected_target_module_set_sha256": qwen35_module_set_sha256(
                expected_qwen35_target_names
            ),
            "expected_target_placement_counts": qwen35_target_placement_counts(
                expected_qwen35_target_names
            ),
        }
        write_json(output_dir / "training-manifest.json", manifest)
        model = inject_qwen35_exact_adapter_with_receipt(
            fast_model=FastModel,
            model=model,
            expected_module_names=expected_qwen35_target_names,
            rank=args.rank,
            alpha=args.alpha,
            seed=args.seed,
            manifest_path=output_dir / "training-manifest.json",
            manifest=manifest,
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
    receipt = adapter_receipt(model, lora_module_names, trainable_parameters)
    if family == QWEN35_FAMILY:
        if expected_qwen35_target_names is None:
            raise RuntimeError("Qwen3.5 expected target placement was not derived")
        persist_qwen35_adapter_receipt_before_validation(
            manifest_path=output_dir / "training-manifest.json",
            manifest=manifest,
            receipt=receipt,
            lora_module_names=lora_module_names,
            expected_module_names=expected_qwen35_target_names,
            trainable_parameters=trainable_parameters,
            rank=args.rank,
        )
    else:
        manifest["adapter_receipt"] = receipt
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
            max_steps=(
                int(QWEN35_PREFLIGHT_CONTRACT["max_steps"])
                if args.preflight_only
                else -1
            ),
            learning_rate=args.lr,
            warmup_ratio=warmup_ratio,
            lr_scheduler_type=scheduler,
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

    run_training_and_save_with_receipts(
        trainer=trainer,
        model=model,
        tokenizer=tokenizer,
        torch=torch,
        manifest_path=output_dir / "training-manifest.json",
        manifest=manifest,
        output_dir=output_dir,
        preflight_only=args.preflight_only,
        skip_merge=args.skip_merge,
    )
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
