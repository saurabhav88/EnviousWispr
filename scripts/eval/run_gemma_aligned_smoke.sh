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
  --model "$model" \
  --tokenizer "$tokenizer" \
  --model-id "$model_id" \
  --corpus "$root/eg1_two_item_list_en_dev_v1a.jsonl" \
  --prompt "$prompt" \
  --output "$output_root/${model_id}_twoitem_v1a.jsonl" \
  --run-id aligned-listv2-twoitem-v1a \
  --split dev

"$HOME/tuning/venv/bin/python" "$runner" \
  --model "$model" \
  --tokenizer "$tokenizer" \
  --model-id "$model_id" \
  --corpus "$root/eg1_two_item_list_en_dev_v1b.jsonl" \
  --prompt "$prompt" \
  --output "$output_root/${model_id}_twoitem_v1b.jsonl" \
  --run-id aligned-listv2-twoitem-v1b \
  --split dev

"$HOME/tuning/venv/bin/python" "$runner" \
  --model "$model" \
  --tokenizer "$tokenizer" \
  --model-id "$model_id" \
  --corpus "$root/eg1_multilingual_ru_v1.jsonl" \
  --prompt "$prompt" \
  --output "$output_root/${model_id}_ru_dev16.jsonl" \
  --run-id aligned-listv2-ru-dev16 \
  --split dev
