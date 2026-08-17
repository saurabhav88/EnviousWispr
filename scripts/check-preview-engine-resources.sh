#!/usr/bin/env bash
# #2123: prove a BUILT app carries what the universal preview engine needs.
#
# WHY THIS IS NOT A UNIT TEST. A test process's `Bundle.main` is the test runner,
# not the app, so it cannot see app-target resources at all — and the route
# builder hardcodes `Bundle.main`. A unit test here would inspect committed
# SOURCE files and pass while the shipped app was missing them, which is worse
# than no check: it would read as coverage.
#
# WHAT BREAKS WITHOUT IT. Packaging happens in ONE place — Tuist's
# `Project.swift`: a `.folderReference` for the tokenizer and a resource path for
# the manifest. `Package.swift` ships neither, for two DIFFERENT reasons worth
# keeping straight: the manifest lives under the `EnviousWispr` target, which
# carries `exclude: ["Resources"]`; the tokenizer lives under `EnviousWisprASR`,
# which excludes nothing but declares no `resources:` at all, so SwiftPM simply
# never processes it.
#
# That single packaging point is the RISK, not a reassurance. A dropped entry
# still compiles, still passes every test, and produces an app whose preview
# engine can never run: the user picks Universal and gets "unavailable in this
# build" with no way to fix it.
#
# Usage: check-preview-engine-resources.sh [/path/to/Some.app]
#        check-preview-engine-resources.sh --self-test
# Defaults to the local dev build.
set -euo pipefail

EXPECTED_VARIANT="openai_whisper-small_216MB"

# --self-test: prove this gate FIRES as well as passes.
#
# A resource check that only ever runs against a good bundle is indistinguishable
# from one that returns 0 unconditionally — the failure this exists to catch is
# rare by design, so it would sit green for months either way. Each case below
# builds a fixture that is wrong in exactly ONE way and asserts this script
# rejects it, plus a fully-correct fixture it must ACCEPT. Without that last
# case a script hard-coded to `exit 1` would pass every other assertion.
if [ "${1:-}" = "--self-test" ]; then
  SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  pass=0
  fail_count=0

  expect() {  # expect <case> <want-exit 0|1> <app-path>
    local name="$1" want="$2" path="$3" got=0
    "$SELF" "$path" >"$TMP/out.txt" 2>&1 || got=$?
    if [ "$got" -eq 0 ] && [ "$want" -eq 0 ]; then
      echo "  PASS  $name (accepted)"; pass=$((pass + 1))
    elif [ "$got" -ne 0 ] && [ "$want" -ne 0 ]; then
      echo "  PASS  $name (rejected: $(head -1 "$TMP/out.txt" | cut -c1-70))"; pass=$((pass + 1))
    else
      echo "  FAIL  $name (wanted exit $want, got $got)"; fail_count=$((fail_count + 1))
    fi
  }

  mkbundle() {  # mkbundle <dir> <variant-or-empty> <with-tokenizer 0|1>
    local d="$1" variant="$2" tok="$3"
    mkdir -p "$d/Contents/Resources"
    printf '<plist/>\n' >"$d/Contents/Info.plist"
    if [ -n "$variant" ]; then
      printf '{"identity":{"variant":"%s"}}\n' "$variant" \
        >"$d/Contents/Resources/whisperkit-preview-delivery-manifest.json"
    fi
    if [ "$tok" -eq 1 ]; then
      mkdir -p "$d/Contents/Resources/WhisperPreviewTokenizer/models/openai/whisper-small"
      printf '{}\n' \
        >"$d/Contents/Resources/WhisperPreviewTokenizer/models/openai/whisper-small/tokenizer.json"
    fi
  }

  echo "check-preview-engine-resources.sh --self-test"
  expect "path that does not exist"        1 "$TMP/nope.app"
  mkdir -p "$TMP/notabundle.app"
  expect "directory with no Info.plist"    1 "$TMP/notabundle.app"
  mkbundle "$TMP/nomanifest.app" "" 1
  expect "bundle missing the manifest"     1 "$TMP/nomanifest.app"
  mkbundle "$TMP/notokenizer.app" "$EXPECTED_VARIANT" 0
  expect "bundle missing the tokenizer"    1 "$TMP/notokenizer.app"
  mkbundle "$TMP/wrongvariant.app" "some_other_model" 1
  expect "manifest naming another variant" 1 "$TMP/wrongvariant.app"
  mkdir -p "$TMP/badjson.app/Contents/Resources"
  printf '<plist/>\n' >"$TMP/badjson.app/Contents/Info.plist"
  printf 'not json at all' \
    >"$TMP/badjson.app/Contents/Resources/whisperkit-preview-delivery-manifest.json"
  mkdir -p "$TMP/badjson.app/Contents/Resources/WhisperPreviewTokenizer/models/openai/whisper-small"
  printf '{}\n' \
    >"$TMP/badjson.app/Contents/Resources/WhisperPreviewTokenizer/models/openai/whisper-small/tokenizer.json"
  expect "manifest that is not valid JSON" 1 "$TMP/badjson.app"
  mkbundle "$TMP/good.app" "$EXPECTED_VARIANT" 1
  expect "a fully correct bundle"          0 "$TMP/good.app"

  echo "$pass passed, $fail_count failed"
  [ "$fail_count" -eq 0 ] || exit 1
  exit 0
fi

APP="${1:-$(cd "$(dirname "$0")/.." && pwd)/build/EnviousWispr Local.app}"
RESOURCES="$APP/Contents/Resources"

fail() { echo "::error::$*"; exit 1; }

# POSITIVE CONTROL, first and deliberately.
#
# Every check below reports "missing". So does pointing at a path that is not an
# app bundle at all — a stale build directory, a renamed product, a typo in a CI
# variable. Without this, "the preview resources are missing" and "I was not
# looking at an app" produce the same red, and the second sends someone editing
# a manifest that was never wrong.
[ -d "$APP" ] || fail "not a directory: $APP — this is a PATH problem, not a resource problem"
[ -f "$APP/Contents/Info.plist" ] \
  || fail "no Info.plist under $APP — that path is not an app bundle, so nothing below is meaningful"

# 1. The delivery manifest. Without it there is no registration, so the engine
#    reports unavailable-in-this-build no matter what is on disk.
MANIFEST="$RESOURCES/whisperkit-preview-delivery-manifest.json"
[ -f "$MANIFEST" ] || fail "preview delivery manifest missing from the bundle: $MANIFEST"

# 2. The bundled tokenizer. `WhisperPreviewDeliveryWiring.makeRoute` refuses
#    without it — deliberately, because WhisperKit's tokenizer search runs
#    independently of `download: false`, so a nil folder can reach the NETWORK,
#    and the app's other bundled tokenizer is large-v3 and would silently load
#    the wrong vocabulary into the small model. Both measured on #2108.
TOKENIZER="$RESOURCES/WhisperPreviewTokenizer/models/openai/whisper-small/tokenizer.json"
[ -f "$TOKENIZER" ] || fail "preview tokenizer missing from the bundle: $TOKENIZER"

# 3. The manifest must be readable JSON naming the variant this engine expects.
#    A truncated or wrong-variant file is present-but-useless, and "the file
#    exists" is exactly the check that cannot tell the difference.
VARIANT=$(python3 -c "
import json, sys
with open('$MANIFEST') as f:
    print(json.load(f)['identity']['variant'])
" 2>/dev/null) || fail "preview manifest is not readable JSON with an identity.variant: $MANIFEST"

[ "$VARIANT" = "$EXPECTED_VARIANT" ] \
  || fail "preview manifest names variant '$VARIANT', expected $EXPECTED_VARIANT"

echo "OK: preview engine resources present in $(basename "$APP") (variant $VARIANT)"
