#!/bin/bash
#
# Check every `OllamaSetupService.modelCatalog` id against the live Ollama
# registry: does the id EXIST, and is the `downloadSize` literal still true?
#
# Why this is a script and not a test: it needs the network and a third-party
# registry, so it cannot run in CI without making an unrelated outage fail the
# build. It is a manual instrument. Run it when touching the catalog, and
# whenever a size is about to be quoted to a user.
#
# #1951: `phi-2` shipped as a catalog id that has never existed in the registry,
# so its Download button returned HTTP 500 every time for the life of the row.
# The same run found six of the ten other rows quoting a stale size.
#
# FAILS CLOSED. Any non-200, absent manifest, or jq failure prints the reason and
# exits nonzero, because a probe that half-worked and still printed a number is
# indistinguishable from a real result
# (validation-discipline.md RULE: measure-with-the-real-tool-never-a-simulation).
#
# Usage:  scripts/check-ollama-catalog-sizes.sh
# Exit:   0 = every id resolves and every size is within tolerance
#         1 = at least one id is missing or at least one size has drifted
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$REPO_ROOT/Sources/EnviousWisprLLM/OllamaSetupService.swift"
REGISTRY="https://registry.ollama.ai/v2/library"
# A size literal is "still true" within this fraction. Catalog strings are
# deliberately approximate ("~4.4 GB"), so an exact compare would be noise —
# but the tolerance must stay BELOW one rounding step of the stated precision or
# it swallows real drift. Measured on the pre-fix table: at 0.08 both `phi3`
# (~2.3 vs 2.17, 5.6%) and `qwen2.5:7b` (~4.4 vs 4.68, 6.4%) passed as ok while
# genuinely stale. At 0.05 both are caught and every correctly-rounded row still
# passes, the widest being `gemma2` at 1.1%.
TOLERANCE="0.05"

command -v jq >/dev/null || { echo "FAIL: jq not installed"; exit 1; }
command -v bc >/dev/null || { echo "FAIL: bc not installed"; exit 1; }
[ -r "$CATALOG" ] || { echo "FAIL: cannot read $CATALOG"; exit 1; }

# Pull `name:` / `downloadSize:` pairs straight out of the shipped source, so the
# script can never drift from the table it is checking. Only the `modelCatalog`
# block is read: `curatedPrivateCatalog` below it is deliberately NOT publicly
# pullable, so a 404 there is correct and must not be reported as a failure.
BLOCK="$(awk '/static let modelCatalog/,/^  \]/' "$CATALOG")"
[ -n "$BLOCK" ] || { echo "FAIL: could not locate modelCatalog in $CATALOG"; exit 1; }

# Entries wrap across lines, so read the two fields as separate ordered lists and
# pair them by index. A single flattened regex was tried first and is NOT used:
# `.*?` is not lazy in POSIX ERE, so one match swallowed several entries and the
# pairing silently came out wrong. The index check below is what catches that.
NAMES="$(printf '%s' "$BLOCK" | grep -oE 'name: "[^"]+"' | sed 's/name: "//; s/"//')"
SIZES="$(printf '%s' "$BLOCK" | grep -oE 'downloadSize: "[^"]+"' | sed 's/downloadSize: "//; s/"//')"

N_NAMES=$(printf '%s\n' "$NAMES" | grep -c . || true)
N_SIZES=$(printf '%s\n' "$SIZES" | grep -c . || true)
if [ "$N_NAMES" -eq 0 ] || [ "$N_NAMES" != "$N_SIZES" ]; then
  echo "FAIL: parsed $N_NAMES names and $N_SIZES sizes from modelCatalog — refusing to guess"
  exit 1
fi
echo "Parsed $N_NAMES catalog rows from $(basename "$CATALOG")"
echo

# Catalog literals are decimal ("~638 MB" == 637,699,655 bytes), not binary.
to_bytes() {
  local n unit
  n=$(printf '%s' "$1" | sed 's/^~//' | awk '{print $1}')
  unit=$(printf '%s' "$1" | awk '{print $2}')
  case "$unit" in
    GB) echo "scale=0; $n * 1000000000 / 1" | bc ;;
    MB) echo "scale=0; $n * 1000000 / 1" | bc ;;
    *)  echo "" ;;
  esac
}

RC=0
i=0
while IFS= read -r ref; do
  i=$((i + 1))
  claimed=$(printf '%s\n' "$SIZES" | sed -n "${i}p")

  name="${ref%%:*}"
  tag="${ref#*:}"
  [ "$tag" = "$ref" ] && tag="latest"

  resp=$(curl -sS -w '\n%{http_code}' --max-time 30 \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "$REGISTRY/$name/manifests/$tag" 2>/dev/null)
  code=$(printf '%s' "$resp" | tail -1)
  body=$(printf '%s' "$resp" | sed '$d')

  if [ "$code" != "200" ]; then
    printf 'MISSING  %-16s HTTP %s — this row ships a Download button that cannot succeed\n' \
      "$ref" "$code"
    RC=1
    continue
  fi

  actual=$(printf '%s' "$body" | jq -e '[.layers[].size] | add' 2>/dev/null)
  if [ -z "$actual" ] || [ "$actual" = "null" ]; then
    printf 'FAIL     %-16s manifest had no readable layer sizes\n' "$ref"
    RC=1
    continue
  fi

  want=$(to_bytes "$claimed")
  if [ -z "$want" ]; then
    printf 'FAIL     %-16s unparseable size literal "%s"\n' "$ref" "$claimed"
    RC=1
    continue
  fi

  drift=$(echo "scale=4; d = ($actual - $want) / $want; if (d < 0) -d else d" | bc)
  live=$(echo "scale=2; $actual / 1000000000" | bc)
  if [ "$(echo "$drift > $TOLERANCE" | bc)" = "1" ]; then
    printf 'DRIFT    %-16s catalog says %-10s registry says %s GB\n' "$ref" "$claimed" "$live"
    RC=1
  else
    printf 'ok       %-16s %-10s (registry %s GB)\n' "$ref" "$claimed" "$live"
  fi
done <<< "$NAMES"

echo
if [ "$RC" -eq 0 ]; then
  echo "CLEAR: every catalog id resolves and every size is within ${TOLERANCE} of the registry."
else
  echo "ACTION NEEDED: update Sources/EnviousWisprLLM/OllamaSetupService.swift and"
  echo ".claude/knowledge/ollama-operations.md FACT: shipped catalog together."
fi
exit $RC
