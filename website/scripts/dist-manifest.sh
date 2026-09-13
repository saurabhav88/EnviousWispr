#!/usr/bin/env bash
# Print one sha256 over everything `wrangler pages deploy dist/` ships: every
# file under dist/ AND every file under functions/ (Pages Functions, which
# wrangler picks up from cwd/functions and compiles at deploy time; the
# contact-form API lives there). Paths and contents, sorted, so two builds of
# the same tree hash identically and the deploy workflow can skip an upload
# that would change nothing. A functions-only change must change the hash,
# or a re-run could redeploy old handlers and be recorded as current.
set -euo pipefail
dist="${1:-dist}"
functions="${2:-functions}"
[ -d "$dist" ] || { echo "dist-manifest: $dist missing" >&2; exit 1; }
{
  # deploy-manifest.txt is the hash's own carrier and is excluded from it.
  (cd "$dist" && find . -type f ! -name deploy-manifest.txt | LC_ALL=C sort | while IFS= read -r f; do
    printf 'dist %s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
  done)
  if [ -d "$functions" ]; then
    (cd "$functions" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf 'functions %s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
    done)
  fi
} | shasum -a 256 | cut -d' ' -f1
