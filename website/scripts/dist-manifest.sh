#!/usr/bin/env bash
# Print one sha256 for the whole build output: every file's path and content,
# in sorted order. Two builds of the same content produce the same hash, so
# the deploy workflow can skip an upload that would change nothing.
set -euo pipefail
dist="${1:-dist}"
[ -d "$dist" ] || { echo "dist-manifest: $dist missing" >&2; exit 1; }
cd "$dist"
find . -type f | LC_ALL=C sort | while IFS= read -r f; do
  printf '%s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
done | shasum -a 256 | cut -d' ' -f1
