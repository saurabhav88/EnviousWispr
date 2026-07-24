#!/usr/bin/env bash
set -euo pipefail

tag="gemma4e4b_multilingual_listv2_aligned_v1"
output_dir="$HOME/tuning/out/$tag"

if [[ -e "$output_dir" ]]; then
  echo "Refusing to overwrite existing output: $output_dir" >&2
  exit 2
fi

"$HOME/tuning/venv/bin/python" \
  /mnt/c/Users/saura/eg1-overnight/train_eg1_multilingual_qlora.py \
  --base "$HOME/tuning/models/gemma-4-E4B-it" \
  --data /mnt/c/Users/saura/eg1-overnight/eg1_multilingual_smoke_v1.jsonl \
  --prompt /mnt/c/Users/saura/eg1-overnight/eg1-list-aware-v2.txt \
  --tag "$tag"
