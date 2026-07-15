#!/usr/bin/env python3
"""Run deterministic EG-1 multilingual prompt experiments on a CUDA host.

This runner intentionally performs inference only. Scoring is separate so the
same raw generations can be rejudged without rerunning the model.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import subprocess
import time
from pathlib import Path
from typing import Any


LANGUAGE_NAMES = {
    "de": "German",
    "en": "English",
    "es": "Spanish",
    "fr": "French",
    "ru": "Russian",
    "zh": "Chinese",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="Local Hugging Face model directory")
    parser.add_argument(
        "--tokenizer",
        default="",
        help="Optional pristine base tokenizer directory for a merged tuned checkpoint.",
    )
    parser.add_argument("--model-id", required=True, help="Stable label written to results")
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--languages", default="", help="Comma-separated language codes")
    parser.add_argument("--split", default="dev")
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--max-new-tokens", type=int, default=256)
    parser.add_argument("--seed", type=int, default=1265)
    parser.add_argument("--include-language-label", action="store_true")
    parser.add_argument(
        "--enable-thinking",
        action="store_true",
        help="Enable a model's reasoning mode. Copy-edit evaluation keeps this off by default.",
    )
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_prompt(path: Path) -> str:
    # The shipped prompt file carries provenance comments. They are not sent to
    # the model at runtime, so omit them here as well.
    lines = [line for line in path.read_text(encoding="utf-8").splitlines() if not line.startswith("#")]
    return "\n".join(lines).strip()


def git_head() -> str | None:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def tokenizer_hashes(path: Path) -> dict[str, str]:
    hashes: dict[str, str] = {}
    for name in ("tokenizer.json", "tokenizer_config.json", "tokenizer.model", "tekken.json"):
        candidate = path / name
        if candidate.is_file():
            hashes[name] = sha256(candidate)
    return hashes


def main() -> None:
    args = parse_args()

    import torch
    from transformers import AutoConfig, AutoModelForCausalLM, AutoTokenizer

    torch.manual_seed(args.seed)
    model_path = Path(os.path.expanduser(args.model)).resolve()
    tokenizer_path = Path(os.path.expanduser(args.tokenizer or args.model)).resolve()
    corpus_path = Path(args.corpus).resolve()
    prompt_path = Path(args.prompt).resolve()
    output_path = Path(args.output).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    selected_languages = {item.strip() for item in args.languages.split(",") if item.strip()}
    rows: list[dict[str, Any]] = []
    with corpus_path.open(encoding="utf-8") as handle:
        for line in handle:
            row = dict(json.loads(line))
            row.setdefault("lang", "en")
            if "input" not in row and isinstance(row.get("asr_input"), str):
                row["input"] = row["asr_input"]
            if args.split != "all" and row.get("split") != args.split:
                continue
            if selected_languages and row.get("lang") not in selected_languages:
                continue
            rows.append(row)
    if args.limit:
        rows = rows[: args.limit]
    if not rows:
        raise SystemExit("No corpus rows matched the requested split/languages")

    system_template = read_prompt(prompt_path)
    # Merged checkpoints can carry mutated tokenizer metadata. A tuned model
    # should use the exact untouched base tokenizer it was trained against.
    model_config = AutoConfig.from_pretrained(model_path)
    is_mistral3 = model_config.model_type == "mistral3"
    if is_mistral3:
        if args.enable_thinking:
            raise SystemExit("--enable-thinking is not supported by the Mistral3 evaluation path")
        from transformers import Mistral3ForConditionalGeneration, MistralCommonBackend

        tokenizer = MistralCommonBackend.from_pretrained(tokenizer_path)
        model = Mistral3ForConditionalGeneration.from_pretrained(
            model_path,
            torch_dtype=torch.bfloat16,
            device_map="cuda",
        )
        model_loader = "Mistral3ForConditionalGeneration"
        tokenizer_loader = "MistralCommonBackend"
    else:
        tokenizer = AutoTokenizer.from_pretrained(tokenizer_path)
        model = AutoModelForCausalLM.from_pretrained(
            model_path,
            torch_dtype=torch.bfloat16,
            device_map="cuda",
        )
        model_loader = "AutoModelForCausalLM"
        tokenizer_loader = "AutoTokenizer"
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token_id = tokenizer.eos_token_id
    tokenizer.padding_side = "left"
    model.eval()

    manifest = {
        "run_id": args.run_id,
        "started_at_epoch": time.time(),
        "host": platform.node(),
        "platform": platform.platform(),
        "git_head": git_head(),
        "model_id": args.model_id,
        "model_path": str(model_path),
        "model_type": model_config.model_type,
        "model_loader": model_loader,
        "tokenizer_path": str(tokenizer_path),
        "tokenizer_loader": tokenizer_loader,
        "tokenizer_hashes": tokenizer_hashes(tokenizer_path),
        "corpus_path": str(corpus_path),
        "corpus_sha256": sha256(corpus_path),
        "prompt_path": str(prompt_path),
        "prompt_sha256": sha256(prompt_path),
        "split": args.split,
        "languages": sorted(selected_languages) if selected_languages else "all",
        "case_count": len(rows),
        "batch_size": args.batch_size,
        "max_new_tokens": args.max_new_tokens,
        "seed": args.seed,
        "include_language_label": args.include_language_label,
        "enable_thinking": args.enable_thinking,
        "torch_version": torch.__version__,
        "cuda_device": torch.cuda.get_device_name(0),
    }

    started = time.perf_counter()
    with output_path.open("w", encoding="utf-8") as output_handle:
        for batch_start in range(0, len(rows), args.batch_size):
            batch = rows[batch_start : batch_start + args.batch_size]
            conversations: list[list[dict[str, str]]] = []
            for row in batch:
                language_name = LANGUAGE_NAMES.get(row["lang"], row["lang"])
                system_prompt = system_template.replace("{{LANGUAGE_NAME}}", language_name)
                language_label = ""
                if args.include_language_label:
                    language_label = (
                        f'<LANGUAGE code="{row["lang"]}">{language_name}</LANGUAGE>\n'
                    )
                conversations.append([
                    {"role": "system", "content": system_prompt},
                    {
                        "role": "user",
                        "content": (
                            f"{language_label}<TRANSCRIPT>\n{row['input']}\n</TRANSCRIPT>"
                        ),
                    },
                ])

            if is_mistral3:
                encoded = tokenizer.apply_chat_template(
                    conversations,
                    tokenize=True,
                    add_generation_prompt=True,
                    padding=True,
                    return_tensors="pt",
                    return_dict=True,
                ).to(model.device)
            else:
                rendered: list[str] = []
                for messages in conversations:
                    rendered.append(
                        tokenizer.apply_chat_template(
                            messages,
                            tokenize=False,
                            add_generation_prompt=True,
                            enable_thinking=args.enable_thinking,
                        )
                    )
                encoded = tokenizer(rendered, return_tensors="pt", padding=True).to(model.device)
            torch.cuda.synchronize()
            batch_started = time.perf_counter()
            with torch.inference_mode():
                generated = model.generate(
                    **encoded,
                    do_sample=False,
                    max_new_tokens=args.max_new_tokens,
                    pad_token_id=tokenizer.pad_token_id,
                    eos_token_id=tokenizer.eos_token_id,
                )
            torch.cuda.synchronize()
            batch_latency_ms = round((time.perf_counter() - batch_started) * 1000, 2)
            input_width = encoded["input_ids"].shape[1]
            decoded = tokenizer.batch_decode(generated[:, input_width:], skip_special_tokens=True)

            for row, response in zip(batch, decoded, strict=True):
                result = dict(row)
                result.update(
                    {
                        "output": response.strip(),
                        "model_id": args.model_id,
                        "run_id": args.run_id,
                        "prompt_sha256": manifest["prompt_sha256"],
                        "batch_latency_ms": batch_latency_ms,
                    }
                )
                output_handle.write(json.dumps(result, ensure_ascii=False) + "\n")
                output_handle.flush()

            completed = min(batch_start + len(batch), len(rows))
            print(f"{completed}/{len(rows)} cases", flush=True)

    manifest["elapsed_seconds"] = round(time.perf_counter() - started, 3)
    manifest["completed_at_epoch"] = time.time()
    manifest_path = output_path.with_suffix(output_path.suffix + ".manifest.json")
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
