#!/usr/bin/env bash
# Settings Map export (#3482): reference/settings-map.json and reference/settings-map.md.
#
#   scripts/settings-map/export.sh                  extract afresh, render, replace both files
#   scripts/settings-map/export.sh --check          extract afresh, render, compare; change nothing
#   scripts/settings-map/export.sh --from <json>    render an export another run already made
#   scripts/settings-map/export.sh --from <json> --check
#   scripts/settings-map/export.sh --self-test      offline checks with a stubbed extractor
#
# Extraction is SettingsMapExportTests (the one extraction owner), run through
# scripts/xcode-test.sh with TEST_RUNNER_EW_SETTINGS_MAP_EXPORT. CI reuses the export its own
# Release test run wrote (--from). Nothing here reads ~/.claude, a catalog database or the
# network, or publishes anything: catalog publication is publish-catalog.py, run by hand.
#
# Both files are written to a fresh staging folder first and replace the committed copies only
# after extraction and rendering succeed. --check never writes the committed copies.
# Exit: 0 ok (or in sync) · 1 out of sync · 2 usage or could not run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REFERENCE="$ROOT/reference"
RENDER="$ROOT/scripts/settings-map/render-reference.py"
EXTRACT_FN=extract

die() {
  local code="$1"
  shift
  echo "export.sh: $*" >&2
  exit "$code"
}

# Writes the full export to $1; the log goes to $2.
extract() {
  env -u TEST_RUNNER_EW_SETTINGS_MAP_EXPORT_ID TEST_RUNNER_EW_SETTINGS_MAP_EXPORT="$1" \
    "$ROOT/scripts/xcode-test.sh" --configuration Debug \
    --filter EnviousWisprTests/SettingsMapExportTests >"$2" 2>&1
}

# Renders staging/settings-map.md from staging/settings-map.json.
render() {
  python3 - "$1/settings-map.json" <<'PY' || die 2 "the export is not a complete version 2 document"
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
nodes = document.get("nodes")
ok = (document.get("schema") == "settings-map-export" and document.get("version") == 2
      and isinstance(nodes, list) and nodes and "entries" not in document)
sys.exit(0 if ok else 1)
PY
  python3 "$RENDER" "$1/settings-map.json" "$1/settings-map.md" || die 2 "rendering failed"
}

run() {
  local check=0 from=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check=1 ;;
      --from)
        [ $# -ge 2 ] || die 2 "--from needs a file"
        from="$2"
        shift
        ;;
      *) die 2 "unknown argument: $1" ;;
    esac
    shift
  done

  local staging
  staging="$(mktemp -d "${TMPDIR:-/tmp}/settings-map-export.XXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$staging'" EXIT

  if [ -n "$from" ]; then
    [ -s "$from" ] || die 2 "no export at $from (did the export test run?)"
    cp "$from" "$staging/settings-map.json"
  else
    echo "export.sh: extracting from the compiled Settings Map (log: $staging/extract.log)"
    local status=0
    "$EXTRACT_FN" "$staging/export.json" "$staging/extract.log" || status=$?
    if [ "$status" -ne 0 ] || [ ! -s "$staging/export.json" ]; then
      grep -A1 'recorded an issue' "$staging/extract.log" >&2 || true
      cp "$staging/extract.log" "${TMPDIR:-/tmp}/settings-map-extract-failed.log" 2>/dev/null || true
      die 2 "extraction failed (status $status); log kept at ${TMPDIR:-/tmp}/settings-map-extract-failed.log"
    fi
    mv "$staging/export.json" "$staging/settings-map.json"
  fi
  render "$staging"

  if [ "$check" -eq 1 ]; then
    local stale=0 name
    for name in settings-map.json settings-map.md; do
      if [ ! -f "$REFERENCE/$name" ]; then
        echo "export.sh: reference/$name is missing" >&2
        stale=1
      elif ! cmp -s "$staging/$name" "$REFERENCE/$name"; then
        echo "export.sh: reference/$name is stale; run scripts/settings-map/export.sh and commit it" >&2
        diff -u "$REFERENCE/$name" "$staging/$name" | head -40 >&2 || true
        stale=1
      fi
    done
    [ "$stale" -eq 0 ] || exit 1
    echo "export.sh: reference/settings-map.json and .md match a fresh export"
    return 0
  fi

  mkdir -p "$REFERENCE"
  cp "$staging/settings-map.json" "$REFERENCE/settings-map.json.new"
  cp "$staging/settings-map.md" "$REFERENCE/settings-map.md.new"
  mv "$REFERENCE/settings-map.json.new" "$REFERENCE/settings-map.json"
  mv "$REFERENCE/settings-map.md.new" "$REFERENCE/settings-map.md"
  echo "export.sh: wrote reference/settings-map.json and reference/settings-map.md"
}

# ---- self-test: stubbed extractor, private reference folder; no build ---------
self_test() {
  local scratch passed=0 failed=0
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/settings-map-export-selftest.XXXXXX")"
  REFERENCE="$scratch/reference"
  EXTRACT_FN=stub_extract
  local good="$scratch/good.json"
  python3 - "$good" <<'PY'
import json, sys
node = {"id": "a.b", "structure": "item", "kind": "setting", "searchable": True, "parent": None,
        "context": [], "declaredIn": "S.swift", "visibility": "always",
        "title": {"source": "verbatim", "text": "T", "note": "n"}, "description": None,
        "destination": None, "dictionaryTab": None, "target": "a.b", "fallbacks": [],
        "vocabulary": {"en": {"words": [], "phrases": ["p"]}, "de": {"words": [], "phrases": ["q"]}}}
json.dump({"schema": "settings-map-export", "version": 2, "interfaceLanguages": ["en", "de"],
           "languages": ["en", "de"], "sources": {"map": "M", "titleResolver": "R", "uiCatalog": "C",
           "vocabulary": "V"}, "fingerprints": {"x": "1"},
           "counts": {"nodes": 1, "searchable": 1, "vocabularyBlocks": 2},
           "languageData": [{"language": "en", "stop": ["the"], "markers": ["not"]}],
           "nodes": [node]}, open(sys.argv[1], "w"), sort_keys=True, indent=2)
PY
  STUB_MODE=good
  stub_extract() {
    case "$STUB_MODE" in
      good) cp "$good" "$1" ;;
      fail) echo "✘ Test recorded an issue: de: no catalog entry" >"$2"; return 65 ;;
      empty) : >"$1" ;;
    esac
  }
  check() {
    if [ "$2" = "$3" ]; then passed=$((passed + 1)); else
      failed=$((failed + 1))
      echo "self-test FAIL: $1: want $2, got $3" >&2
    fi
  }
  status() { ("$@") >"$scratch/out.log" 2>&1 && echo 0 || echo $?; }
  hash() { cat "$REFERENCE"/settings-map.* 2>/dev/null | shasum -a 256 | cut -d' ' -f1; }

  check "check with no committed files" 1 "$(status run --check)"
  check "missing file named" 1 "$(grep -c 'settings-map.json is missing' "$scratch/out.log")"
  check "regenerate" 0 "$(status run)"
  check "both files written" yes "$([ -s "$REFERENCE/settings-map.json" ] && [ -s "$REFERENCE/settings-map.md" ] && echo yes || echo no)"
  local written
  written="$(hash)"
  check "check in sync" 0 "$(status run --check)"
  check "regeneration is byte-identical" "$written" "$( (run >/dev/null 2>&1); hash)"
  printf 'edited\n' >>"$REFERENCE/settings-map.md"
  local edited
  edited="$(hash)"
  check "stale markdown fails" 1 "$(status run --check)"
  check "check leaves files untouched" "$edited" "$(hash)"
  run >/dev/null 2>&1
  STUB_MODE=fail
  check "extraction failure stops" 2 "$(status run)"
  check "failure quoted" 1 "$(grep -c 'no catalog entry' "$scratch/out.log")"
  check "failure leaves files untouched" "$written" "$(hash)"
  STUB_MODE=empty
  check "empty export stops" 2 "$(status run --check)"
  check "--from a missing file" 2 "$(status run --from "$scratch/none.json" --check)"
  check "--from a good file" 0 "$(status run --from "$good" --check)"
  printf '{"schema":"settings-map-export","version":2,"entries":[]}' >"$scratch/place.json"
  check "--from a one-place export is refused" 2 "$(status run --from "$scratch/place.json")"
  check "refusal left files untouched" "$written" "$(hash)"
  check "unknown argument" 2 "$(status run --bogus)"

  rm -rf "$scratch"
  echo "self-test: $passed passed, $failed failed"
  [ "$failed" -eq 0 ] && [ "$passed" -gt 0 ]
}

case "${1:-}" in
  --self-test) self_test ;;
  -h | --help) sed -n '2,8p' "$0" ;;
  *) run "$@" ;;
esac
