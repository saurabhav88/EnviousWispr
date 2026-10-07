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
MV="mv"

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
  staging="$(mktemp -d "${TMPDIR:-/tmp}/settings-map-export.XXXXXX")" || die 2 "cannot create a staging folder"
  # Paths are quoted with %q, so a folder name with a quote cannot break the handler.
  local cleanup
  printf -v cleanup 'rm -rf -- %q' "$staging"
  # shellcheck disable=SC2064
  trap "$cleanup" EXIT

  if [ -n "$from" ]; then
    [ -s "$from" ] || die 2 "no export at $from (did the export test run?)"
    cp "$from" "$staging/settings-map.json" || die 2 "cannot read $from"
  else
    echo "export.sh: extracting from the compiled Settings Map (log: $staging/extract.log)"
    local status=0
    "$EXTRACT_FN" "$staging/export.json" "$staging/extract.log" || status=$?
    if [ "$status" -ne 0 ] || [ ! -s "$staging/export.json" ]; then
      grep -A1 'recorded an issue' "$staging/extract.log" >&2 || true
      local kept
      if kept="$(mktemp "${TMPDIR:-/tmp}/settings-map-extract-failed.XXXXXX")" &&
        cp "$staging/extract.log" "$kept"; then
        die 2 "extraction failed (status $status); log kept at $kept"
      fi
      die 2 "extraction failed (status $status); the log could not be kept"
    fi
    mv "$staging/export.json" "$staging/settings-map.json" || die 2 "cannot stage the export"
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

  mkdir -p "$REFERENCE" || die 2 "cannot create reference/"
  # One writer at a time, so two exports cannot pair one run's JSON with another's Markdown.
  # Every step below checks its own status: run may be called where errexit does not apply.
  mkdir "$REFERENCE/.export.lock" 2>/dev/null || die 2 "another export is writing reference/ (remove reference/.export.lock if none is)"
  local json_tmp="" md_tmp=""
  # From here on, any exit releases the lock and removes this run's temporaries.
  # The temporary names expand when the handler runs, after they are set.
  # shellcheck disable=SC2016
  printf -v cleanup 'rm -rf -- %q; rm -f -- "${json_tmp:-}" "${md_tmp:-}"; rmdir -- %q 2>/dev/null || true' \
    "$staging" "$REFERENCE/.export.lock"
  # shellcheck disable=SC2064
  trap "$cleanup" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  json_tmp="$(mktemp "$REFERENCE/.settings-map.json.XXXXXX")" || die 2 "cannot create a temporary file in reference/"
  md_tmp="$(mktemp "$REFERENCE/.settings-map.md.XXXXXX")" || die 2 "cannot create a temporary file in reference/"
  cp "$staging/settings-map.json" "$json_tmp" || die 2 "cannot copy settings-map.json"
  cp "$staging/settings-map.md" "$md_tmp" || die 2 "cannot copy settings-map.md"
  chmod 644 "$json_tmp" "$md_tmp" || die 2 "cannot set file modes"
  "$MV" "$json_tmp" "$REFERENCE/settings-map.json" || die 2 "could not install settings-map.json"
  json_tmp=""
  "$MV" "$md_tmp" "$REFERENCE/settings-map.md" || die 2 "could not install settings-map.md; reference/settings-map.json is new, rerun the export"
  md_tmp=""
  rmdir "$REFERENCE/.export.lock" || die 2 "could not release reference/.export.lock"
  echo "export.sh: wrote reference/settings-map.json and reference/settings-map.md"
}

# ---- self-test: stubbed extractor, private reference folder; no build ---------
self_test() {
  local scratch passed=0 failed=0
  # The quote in the name checks that every cleanup handler quotes its paths.
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/settings-map-export-selftest's.XXXXXX")"
  export TMPDIR="$scratch"
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
  mkdir "$REFERENCE/.export.lock"
  check "a held lock refuses a second writer" 2 "$(status run --from "$good")"
  check "the refused writer left the files" "$written" "$(hash)"
  rmdir "$REFERENCE/.export.lock"
  check "no temporary files left in reference/" "" "$(find "$REFERENCE" -name '.settings-map.*' | head -1)"
  MV=false
  check "a failed install fails the run" 2 "$(status run --from "$good")"
  check "a failed install releases the lock" no "$([ -d "$REFERENCE/.export.lock" ] && echo yes || echo no)"
  check "a failed install leaves no temporaries" "" "$(find "$REFERENCE" -name '.settings-map.*' | head -1)"
  check "a failed install left the files" "$written" "$(hash)"
  MV="mv"

  rm -rf "$scratch"
  echo "self-test: $passed passed, $failed failed"
  [ "$failed" -eq 0 ] && [ "$passed" -gt 0 ]
}

case "${1:-}" in
  --self-test) self_test ;;
  -h | --help) sed -n '2,8p' "$0" ;;
  *) run "$@" ;;
esac
