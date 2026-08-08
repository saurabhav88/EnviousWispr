#!/usr/bin/env bash
set -euo pipefail

root="$HOME/tuning"
llama_cpp="$root/llama.cpp"
python="$root/venv/bin/python"
base="$root/models/Qwen3-4B-Instruct-2507"
adapter="$root/out/qwen4b_v2/ckpt/checkpoint-708"
multilingual_adapter="$root/out/qwen4b_multilingual_smoke_v1r2/adapter"
output="$root/out/qwen4b_lora_fallback"
base_f16="$output/qwen3-4b-instruct-2507-base-f16.gguf"
base_q5="$output/qwen3-4b-instruct-2507-base-q5_k_m.gguf"
adapter_gguf="$output/eg1-current-r16-f16-lora.gguf"
multilingual_adapter_gguf="$output/eg1-qwen-multilingual-smoke-r16-f16-lora.gguf"

for required in \
  "$llama_cpp/convert_hf_to_gguf.py" \
  "$llama_cpp/convert_lora_to_gguf.py" \
  "$llama_cpp/build/bin/llama-quantize" \
  "$base/config.json" \
  "$adapter/adapter_model.safetensors" \
  "$adapter/adapter_config.json" \
  "$multilingual_adapter/adapter_model.safetensors" \
  "$multilingual_adapter/adapter_config.json"; do
  if [[ ! -e "$required" ]]; then
    echo "Missing required input: $required" >&2
    exit 2
  fi
done

mkdir -p "$output"
for artifact in "$base_f16" "$base_q5" "$adapter_gguf" "$multilingual_adapter_gguf"; do
  if [[ -e "$artifact" ]]; then
    echo "Refusing to overwrite existing artifact: $artifact" >&2
    exit 2
  fi
done

"$python" "$llama_cpp/convert_hf_to_gguf.py" \
  "$base" \
  --outfile "$base_f16" \
  --outtype f16

"$llama_cpp/build/bin/llama-quantize" \
  "$base_f16" \
  "$base_q5" \
  Q5_K_M

"$python" "$llama_cpp/convert_lora_to_gguf.py" \
  --base "$base" \
  --outfile "$adapter_gguf" \
  --outtype f16 \
  "$adapter"

"$python" "$llama_cpp/convert_lora_to_gguf.py" \
  --base "$base" \
  --outfile "$multilingual_adapter_gguf" \
  --outtype f16 \
  "$multilingual_adapter"

sha256sum "$base_f16" "$base_q5" "$adapter_gguf" "$multilingual_adapter_gguf"
du -b "$base_f16" "$base_q5" "$adapter_gguf" "$multilingual_adapter_gguf"
