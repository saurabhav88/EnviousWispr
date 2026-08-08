#!/usr/bin/env bash
set -euo pipefail

root="$HOME/tuning/out/gemma4e4b_multilingual_smoke_v1"
input="$root/gemma4e4b-multilingual-smoke-v1-f16.gguf"
output="$root/gemma4e4b-multilingual-smoke-v1-q6_k.gguf"

if [[ -e "$output" ]]; then
  echo "Refusing to overwrite existing output: $output" >&2
  exit 2
fi

"$HOME/tuning/llama.cpp/build/bin/llama-quantize" "$input" "$output" Q6_K
sha256sum "$output"
stat --format='%s bytes' "$output"
