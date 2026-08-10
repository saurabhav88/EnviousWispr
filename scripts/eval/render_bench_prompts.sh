#!/bin/bash
# Render the REAL production polish prompt per model for the #1950 benchmark.
#
# Ollama prompt routing is per MODEL NAME (`gemma` -> GemmaPromptBuilder, else
# OpenAIPromptBuilder, plus `isWeakModel` overriding both), so every model needs
# its own render. Reusing one model's file for another silently benchmarks the
# wrong prompt and nothing in the output would say so.
#
# Fail closed: a build failure, a render failure, or an empty/short output file
# aborts the sweep rather than leaving a hole the runner would later blame on a
# missing prompt.
set -euo pipefail

CORPUS="${1:?usage: render_bench_prompts.sh <corpus.jsonl> <outdir> <model>...}"
OUTDIR="${2:?usage: render_bench_prompts.sh <corpus.jsonl> <outdir> <model>...}"
shift 2
MODELS=("$@")
[ ${#MODELS[@]} -gt 0 ] || { echo "FAIL: no models given" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RENDER_PKG="$ROOT/scripts/eval/prompt_render"
EXPECTED=$(grep -c . "$ROOT/$CORPUS" 2>/dev/null || grep -c . "$CORPUS")

mkdir -p "$OUTDIR"
echo "building PromptRender…" >&2
swift build -c release --package-path "$RENDER_PKG" >&2
# `--show-bin-path` prints unhandled-resource WARNINGS on stdout alongside the
# path, so taking the whole output yields a multi-line string and the -x test
# below fails for a reason that looks nothing like its cause. Take the last line.
BIN="$(swift build -c release --package-path "$RENDER_PKG" --show-bin-path 2>/dev/null | tail -1)/PromptRender"
[ -x "$BIN" ] || { echo "FAIL: PromptRender binary not found at $BIN" >&2; exit 2; }

for m in "${MODELS[@]}"; do
  slug="${m//:/-}"; slug="${slug//./-}"; slug="${slug//\//-}"
  out="$OUTDIR/$slug.jsonl"
  "$BIN" --corpus "$CORPUS" --provider ollama --model "$m" --out "$out"
  n=$(grep -c . "$out" || true)
  if [ "$n" -ne "$EXPECTED" ]; then
    echo "FAIL: $m rendered $n prompts, corpus has $EXPECTED" >&2
    exit 2
  fi
  # Record which model this file was rendered FOR. The rendered rows carry only
  # id/mode/system/user, so nothing inside the file identifies its model, and a
  # file that is stale, hand-copied, or renamed to another model's slug would be
  # run under the wrong prompt with every existing check passing — the hazard
  # this script's own header warns about but could not previously enforce.
  # `run_ollama_bench.py` refuses to run a prompt file whose sidecar is missing
  # or disagrees.
  printf '%s\n' "$m" > "$OUTDIR/$slug.model"
  echo "  $m -> $out ($n)" >&2
done
echo "rendered ${#MODELS[@]} prompt files into $OUTDIR" >&2
