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
# Defaults to the local dev build.
set -euo pipefail

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

[ "$VARIANT" = "openai_whisper-small_216MB" ] \
  || fail "preview manifest names variant '$VARIANT', expected openai_whisper-small_216MB"

echo "OK: preview engine resources present in $(basename "$APP") (variant $VARIANT)"
