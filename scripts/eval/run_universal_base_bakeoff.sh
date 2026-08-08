#!/usr/bin/env bash
set -euo pipefail

root=/mnt/c/Users/saura/eg1-overnight
runner="$root/eg1_multilingual_runner.py"
strict_prompt="$root/eg1-multilingual-strict-v1.txt"
list_prompt="$root/eg1-list-aware-v2.txt"
output_root="$root/universal-base-bakeoff"

mkdir -p "$output_root"

run_suite() {
  local model_id="$1"
  local model="$2"
  local tokenizer="$3"
  local suite="$4"
  local corpus="$5"
  local prompt="$6"
  local split="$7"
  local output="$output_root/${model_id}_${suite}.jsonl"

  if [[ -e "$output" || -e "$output.manifest.json" ]]; then
    echo "Refusing to overwrite existing result: $output" >&2
    exit 2
  fi

  "$HOME/tuning/venv/bin/python" "$runner" \
    --model "$model" \
    --tokenizer "$tokenizer" \
    --model-id "$model_id" \
    --corpus "$corpus" \
    --prompt "$prompt" \
    --output "$output" \
    --run-id "base-bakeoff-${model_id}-${suite}" \
    --split "$split"
}

run_model() {
  local model_id="$1"
  local model="$2"
  local tokenizer="$3"

  run_suite "$model_id" "$model" "$tokenizer" \
    ml56 "$root/multilingual_cases.jsonl" "$strict_prompt" all
  run_suite "$model_id" "$model" "$tokenizer" \
    twoitem_v1a "$root/eg1_two_item_list_en_dev_v1a.jsonl" "$list_prompt" dev
  run_suite "$model_id" "$model" "$tokenizer" \
    twoitem_v1b "$root/eg1_two_item_list_en_dev_v1b.jsonl" "$list_prompt" dev
  run_suite "$model_id" "$model" "$tokenizer" \
    listpos_overflow100 "$root/list_format_overflow_v1.jsonl" "$list_prompt" all
  run_suite "$model_id" "$model" "$tokenizer" \
    listtrap_overflow100 "$root/list_format_trap_overflow_v1.jsonl" "$list_prompt" all
}

run_model qwen3_4b_base \
  "$HOME/tuning/models/Qwen3-4B-Instruct-2507" \
  "$HOME/tuning/models/Qwen3-4B-Instruct-2507"

run_model qwen35_4b_base \
  "$HOME/tuning/models/Qwen3.5-4B" \
  "$HOME/tuning/models/Qwen3.5-4B"

run_model gemma4_e4b_base \
  "$HOME/tuning/models/gemma-4-E4B-it" \
  "$HOME/tuning/models/gemma-4-E4B-it"
