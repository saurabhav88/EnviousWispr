#!/usr/bin/env bash
# Print one sha256 over everything that determines what `wrangler pages
# deploy dist/` puts on the live site:
#   dist/            the built pages and assets
#   functions/       Pages Functions source (the contact-form API); wrangler
#                    compiles these at deploy time from cwd/functions
#   package.json, package-lock.json
#                    the toolchain that compiles them (the wrangler version
#                    and its dependencies are pinned here)
#   the deploy workflow file
#                    the Node version and the deploy command themselves
# Paths and contents, sorted, so two builds of the same tree hash identically
# and the deploy workflow can skip an upload that would change nothing. Any
# input that can change the deployed bytes must be in here, or a re-run of an
# older run could ship a different result under the same hash and be recorded
# as current. dist/deploy-manifest.txt is the hash's own carrier and is
# excluded from it.
set -euo pipefail
dist="${1:-dist}"
functions="${2:-functions}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -d "$dist" ] || { echo "dist-manifest: $dist missing" >&2; exit 1; }
hash_tree() { # label dir
  (cd "$2" && find . -type f ! -name deploy-manifest.txt | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s  %s\n' "$1" "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$f"
  done)
}
hash_file() { # label path
  [ -f "$2" ] && printf '%s %s  %s\n' "$1" "$(shasum -a 256 "$2" | cut -d' ' -f1)" "$(basename "$2")"
  return 0
}
{
  hash_tree dist "$dist"
  [ -d "$functions" ] && hash_tree functions "$functions"
  hash_file toolchain "$here/package.json"
  hash_file toolchain "$here/package-lock.json"
  hash_file workflow "$here/../.github/workflows/deploy-blog.yml"
} | shasum -a 256 | cut -d' ' -f1
