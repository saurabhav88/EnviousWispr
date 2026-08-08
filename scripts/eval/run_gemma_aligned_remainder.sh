#!/usr/bin/env bash
set -euo pipefail

root=/mnt/c/Users/saura/eg1-overnight
runner="$root/eg1_multilingual_runner.py"
model="$HOME/tuning/out/gemma4e4b_multilingual_listv2_aligned_v1/merged16"
tokenizer="$HOME/tuning/models/gemma-4-E4B-it"
prompt="$root/eg1-list-aware-v2.txt"
output_root="$root/aligned-runs"
model_id=gemma4e4b_multilingual_listv2_aligned_v1

if [[ ! -d "$model" ]]; then
  echo "Aligned merged model is missing: $model" >&2
  exit 2
fi

mkdir -p "$output_root"

"$HOME/tuning/venv/bin/python" "$runner" \
  --model "$model" --tokenizer "$tokenizer" --model-id "$model_id" \
  --corpus "$root/list_format_v1.jsonl" --prompt "$prompt" \
  --output "$output_root/${model_id}_listpos100.jsonl" \
  --run-id aligned-listv2-listpos100 --split all

"$HOME/tuning/venv/bin/python" "$runner" \
  --model "$model" --tokenizer "$tokenizer" --model-id "$model_id" \
  --corpus "$root/list_format_trap_v1.jsonl" --prompt "$prompt" \
  --output "$output_root/${model_id}_listtrap100.jsonl" \
  --run-id aligned-listv2-listtrap100 --split all

"$HOME/tuning/venv/bin/python" "$runner" \
  --model "$model" --tokenizer "$tokenizer" --model-id "$model_id" \
  --corpus "$root/multilingual_cases.jsonl" --prompt "$prompt" \
  --output "$output_root/${model_id}_ml56.jsonl" \
  --run-id aligned-listv2-ml56 --split all
