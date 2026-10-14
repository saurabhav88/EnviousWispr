#!/usr/bin/env bash
# #2123, #3735: prove a BUILT app carries what the universal preview engine needs.
#
# WHY THIS IS NOT A UNIT TEST. A test process's `Bundle.main` is the test runner,
# not the app, so it cannot see app-target resources at all, and the route
# builder reads the registration `ModelDeliveryHome` builds from `Bundle.main`. A
# unit test here would inspect committed SOURCE files and pass while the shipped
# app was missing them, which is worse than no check: it would read as coverage.
#
# WHAT BREAKS WITHOUT IT. Packaging happens in ONE place: Tuist's `Project.swift`
# lists the manifest as an app resource. `Package.swift` does not ship it: the
# manifest lives under the `EnviousWispr` target, which carries
# `exclude: ["Resources"]`.
#
# That single packaging point is the RISK, not a reassurance. A dropped entry
# still compiles, still passes every test, and produces an app whose preview
# engine can never run: the user picks Universal and gets "unavailable in this
# build" with no way to fix it.
#
# #3735: the Universal engine is transcribe.cpp whisper-small. It needs only its
# delivery manifest (the model file is downloaded and admitted at run time); the
# GGUF carries its own vocabulary, so there is no bundled tokenizer any more.
#
# Usage: check-preview-engine-resources.sh [/path/to/Some.app]
#        check-preview-engine-resources.sh --self-test
# Defaults to the local dev build.
set -euo pipefail

MANIFEST_NAME="whisper-preview-delivery-manifest.json"
EXPECTED_NAME="whisper-small-gguf"
EXPECTED_VARIANT="q8_0"
EXPECTED_ENTRYPOINT="whisper-small-Q8_0.gguf"

# --self-test: prove this gate FIRES as well as passes.
#
# A resource check that only ever runs against a good bundle is indistinguishable
# from one that returns 0 unconditionally: the failure this exists to catch is
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

  mkbundle() {  # mkbundle <dir> <name> <variant> <entrypoint>; empty name = no manifest
    local d="$1" name="$2" variant="$3" entry="$4"
    mkdir -p "$d/Contents/Resources"
    printf '<plist/>\n' >"$d/Contents/Info.plist"
    if [ -n "$name" ]; then
      printf '{"identity":{"name":"%s","variant":"%s"},"admission":{"entrypointFile":"%s"}}\n' \
        "$name" "$variant" "$entry" >"$d/Contents/Resources/$MANIFEST_NAME"
    fi
  }

  echo "check-preview-engine-resources.sh --self-test"
  expect "path that does not exist"        1 "$TMP/nope.app"
  mkdir -p "$TMP/notabundle.app"
  expect "directory with no Info.plist"    1 "$TMP/notabundle.app"
  mkbundle "$TMP/nomanifest.app" "" "" ""
  expect "bundle missing the manifest"     1 "$TMP/nomanifest.app"
  mkbundle "$TMP/wrongname.app" "whisper-large-v3-turbo-gguf" "$EXPECTED_VARIANT" "$EXPECTED_ENTRYPOINT"
  expect "manifest naming another model"   1 "$TMP/wrongname.app"
  mkbundle "$TMP/wrongvariant.app" "$EXPECTED_NAME" "f16" "$EXPECTED_ENTRYPOINT"
  expect "manifest naming another variant" 1 "$TMP/wrongvariant.app"
  mkbundle "$TMP/wrongentry.app" "$EXPECTED_NAME" "$EXPECTED_VARIANT" "other.gguf"
  expect "manifest naming another file"    1 "$TMP/wrongentry.app"
  mkdir -p "$TMP/badjson.app/Contents/Resources"
  printf '<plist/>\n' >"$TMP/badjson.app/Contents/Info.plist"
  printf 'not json at all' >"$TMP/badjson.app/Contents/Resources/$MANIFEST_NAME"
  expect "manifest that is not valid JSON" 1 "$TMP/badjson.app"
  mkbundle "$TMP/good.app" "$EXPECTED_NAME" "$EXPECTED_VARIANT" "$EXPECTED_ENTRYPOINT"
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
# app bundle at all: a stale build directory, a renamed product, a typo in a CI
# variable. Without this, "the preview resources are missing" and "I was not
# looking at an app" produce the same red, and the second sends someone editing
# a manifest that was never wrong.
[ -d "$APP" ] || fail "not a directory: $APP (a PATH problem, not a resource problem)"
[ -f "$APP/Contents/Info.plist" ] \
  || fail "no Info.plist under $APP: that path is not an app bundle, so nothing below is meaningful"

# 1. The delivery manifest. Without it there is no registration, so the engine
#    reports unavailable-in-this-build no matter what is on disk.
MANIFEST="$RESOURCES/$MANIFEST_NAME"
[ -f "$MANIFEST" ] || fail "preview delivery manifest missing from the bundle: $MANIFEST"

# 2. The manifest must be readable JSON naming the model, variant and entrypoint this engine
#    loads. A truncated or wrong-model file is present-but-useless, and "the file exists" is
#    exactly the check that cannot tell the difference.
FIELDS=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)
print(m['identity']['name'], m['identity']['variant'], m['admission']['entrypointFile'])
" "$MANIFEST" 2>/dev/null) \
  || fail "preview manifest is not readable JSON with identity.name, identity.variant and admission.entrypointFile: $MANIFEST"
read -r NAME VARIANT ENTRYPOINT <<<"$FIELDS"

[ "$NAME" = "$EXPECTED_NAME" ] || fail "preview manifest names model '$NAME', expected $EXPECTED_NAME"
[ "$VARIANT" = "$EXPECTED_VARIANT" ] \
  || fail "preview manifest names variant '$VARIANT', expected $EXPECTED_VARIANT"
[ "$ENTRYPOINT" = "$EXPECTED_ENTRYPOINT" ] \
  || fail "preview manifest names entrypoint '$ENTRYPOINT', expected $EXPECTED_ENTRYPOINT"

echo "OK: preview engine resources present in $(basename "$APP") ($NAME $VARIANT)"
