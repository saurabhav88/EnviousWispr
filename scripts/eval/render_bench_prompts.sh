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

# Which of these models does Ollama actually run REMOTELY? Production routes a
# hosted Ollama model to the `.cloudFixed` prompt family and a local one to
# `.localFixed` (`DefaultPromptPlanner.swift:77`), and `PromptRender` selects
# between them from `--hosted` alone. This wrapper omitted the flag, so every
# hosted model was rendered with the LOCAL prompt and benchmarked against a
# prompt production would never send it — the trap this file's own header warns
# about, walked into by the documented wrapper.
#
# Same authority the runner uses: a non-empty `remote_host` in /api/tags. Asking
# the daemon beats a hand-maintained list of which names end in `-cloud`, which
# is a naming convention, not a fact.
OLLAMA_HOST_URL="${OLLAMA_HOST_URL:-http://localhost:11434}"
TAGS_JSON="$(curl -fsS -m 15 "$OLLAMA_HOST_URL/api/tags")" || {
  echo "FAIL: cannot reach Ollama at $OLLAMA_HOST_URL/api/tags to determine which models are hosted" >&2
  exit 2
}

is_hosted() {
  TAGS_JSON="$TAGS_JSON" python3 -c '
import json, os, sys
want = sys.argv[1]
tags = json.loads(os.environ["TAGS_JSON"])["models"]
for row in tags:
    name = row.get("name", "")
    if name == want or name == f"{want}:latest" or name.split(":")[0] == want:
        print("yes" if row.get("remote_host") not in (None, "") else "no")
        sys.exit(0)
sys.exit(3)
' "$1"
}

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
  if ! hosted="$(is_hosted "$m")"; then
    echo "FAIL: $m is not present in $OLLAMA_HOST_URL/api/tags — pull it before rendering" >&2
    exit 2
  fi
  if [ "$hosted" = "yes" ]; then
    "$BIN" --corpus "$CORPUS" --provider ollama --model "$m" --hosted --out "$out"
  else
    "$BIN" --corpus "$CORPUS" --provider ollama --model "$m" --out "$out"
  fi
  n=$(grep -c . "$out" || true)
  if [ "$n" -ne "$EXPECTED" ]; then
    echo "FAIL: $m rendered $n prompts, corpus has $EXPECTED" >&2
    exit 2
  fi
  # Record which model this file was rendered for AND under which hosting. The
  # rendered rows carry only id/mode/system/user, so nothing inside the file
  # identifies either, and a file that is stale, hand-copied, or renamed to
  # another model's slug would be run under the wrong prompt with every existing
  # check passing — the hazard this script's own header warns about but could
  # not previously enforce.
  #
  # Hosting is recorded as well as the model because the model name alone cannot
  # catch the defect above: a hosted model rendered without `--hosted` carries
  # the RIGHT name and the WRONG prompt family, so a name-only sidecar validates
  # it happily. `run_ollama_bench.py` re-derives hosting from the daemon and
  # refuses a file that disagrees.
  printf '{"model": "%s", "hosted": %s}\n' \
    "$m" "$([ "$hosted" = yes ] && echo true || echo false)" > "$OUTDIR/$slug.model"
  echo "  $m -> $out ($n)" >&2
done
echo "rendered ${#MODELS[@]} prompt files into $OUTDIR" >&2
