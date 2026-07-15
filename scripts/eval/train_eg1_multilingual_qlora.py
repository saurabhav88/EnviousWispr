#!/usr/bin/env python3
"""Reproducible multilingual EG-1 QLoRA smoke training on AlienSV."""

from __future__ import annotations

import argparse
import hashlib
import inspect
import json
import os
import platform
import time
from pathlib import Path
from typing import Any


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
    parser.add_argument("--skip-merge", action="store_true")
    return parser.parse_args()


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
    if output_dir.exists():
        raise SystemExit(f"Refusing to reuse existing output directory: {output_dir}")
    output_dir.mkdir(parents=True)

    rows = read_rows(data_path)
    system_prompt = read_prompt(prompt_path)
    config_path = base_path / "config.json"
    manifest: dict[str, Any] = {
        "status": "starting",
        "tag": args.tag,
        "host": platform.node(),
        "platform": platform.platform(),
        "base_path": str(base_path),
        "base_config_sha256": sha256(config_path) if config_path.is_file() else None,
        "data_path": str(data_path),
        "data_sha256": sha256(data_path),
        "row_count": len(rows),
        "prompt_path": str(prompt_path),
        "prompt_sha256": sha256(prompt_path),
        "system_prompt": system_prompt,
        "hyperparameters": {
            "learning_rate": args.lr,
            "epochs": args.epochs,
            "rank": args.rank,
            "alpha": args.alpha,
            "lora_dropout": 0.05,
            "micro_batch": args.micro_batch,
            "gradient_accumulation": args.gradient_accumulation,
            "effective_batch": args.micro_batch * args.gradient_accumulation,
            "max_seq": args.max_seq,
            "seed": args.seed,
            "optimizer": "adamw_8bit",
            "scheduler": "cosine",
            "warmup_ratio": 0.05,
            "weight_decay": 0.01,
            "response_only_loss": True,
            "bf16": True,
        },
        "started_at_epoch": time.time(),
    }
    write_json(output_dir / "training-manifest.json", manifest)

    from unsloth import FastLanguageModel
    from unsloth.chat_templates import train_on_responses_only
    import torch
    from datasets import Dataset
    from trl import SFTConfig, SFTTrainer

    torch.manual_seed(args.seed)
    manifest["torch_version"] = torch.__version__
    manifest["cuda_device"] = torch.cuda.get_device_name(0)

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

    dataset = Dataset.from_list([to_text(row) for row in rows]).shuffle(seed=args.seed)
    trainer_kwargs: dict[str, Any] = {
        "model": model,
        "train_dataset": dataset,
        "args": sft_config(
            SFTConfig,
            dataset_text_field="text",
            per_device_train_batch_size=args.micro_batch,
            gradient_accumulation_steps=args.gradient_accumulation,
            num_train_epochs=args.epochs,
            learning_rate=args.lr,
            warmup_ratio=0.05,
            lr_scheduler_type="cosine",
            logging_steps=10,
            optim="adamw_8bit",
            weight_decay=0.01,
            bf16=True,
            max_seq_length=args.max_seq,
            output_dir=str(output_dir / "checkpoints"),
            report_to="none",
            seed=args.seed,
            save_strategy="epoch",
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

    base_name = base_path.name.casefold()
    if "gemma" in base_name:
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

    sample = trainer.train_dataset[0]
    if "labels" in sample:
        labeled_tokens = sum(token != -100 for token in sample["labels"])
        if labeled_tokens <= 0:
            raise RuntimeError("Response-only loss mask removed every token in sample 0")
        manifest["sample_0_labeled_tokens"] = labeled_tokens

    training_started = time.perf_counter()
    statistics = trainer.train()
    manifest["training_elapsed_seconds"] = round(time.perf_counter() - training_started, 3)
    manifest["training_metrics"] = statistics.metrics

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
