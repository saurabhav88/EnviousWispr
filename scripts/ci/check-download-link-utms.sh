#!/usr/bin/env bash
# Design-time guard for the /download attribution doorway.
# Plan: docs/feature-requests/plan-2026-06-29-download-attribution.md (§3a, §6).
#
# Two rules, enforced at PR + deploy time so download-link drift is caught before
# it ships (not discovered weeks later as a hole in attribution):
#
#   (a) OFF-SITE download links (README) MUST be the canonical tagged doorway:
#       https://enviouswispr.com/download?source=github_readme&utm_source=...&
#       utm_medium=...&utm_campaign=...  — and NEVER a raw GitHub .dmg.
#
#   (b) ON-SITE blog prose download links MUST point at the on-site /#download
#       section, NEVER a raw GitHub .dmg / releases URL (those fire no event and
#       leak an unattributed download path), and NEVER the off-site /download
#       doorway (that would self-refer + double-count). The repo root
#       https://github.com/saurabhav88/EnviousWispr is allowed for source /
#       transparency links; it is not a download path.
#
# Rule (a) validates the doorway link by PARSING its query string the same way the
# Cloudflare resolver does (website/functions/download.js: the FIRST value of a
# repeated key wins — URLSearchParams.get — and ?source is lowercased). Parsing,
# not regex matching, is deliberate: query SEMANTICS (which value wins, ordering,
# duplicate keys, near-miss values, utm_source masquerade, empty values, case)
# are a finite enumerable space the parser handles in one pass, where a substring
# regex leaks one new shape per review round.
#
# On-site download BUTTONS in Astro (Nav/Footer/hero/compare CTAs) deliberately
# keep their raw .dmg href + data-download-source attribute; the page JS fires
# download_clicked on click. They are out of scope here by design (plan §2.1).
#
# Usage:
#   scripts/ci/check-download-link-utms.sh            # lint the working tree
#   scripts/ci/check-download-link-utms.sh --self-test  # verify the linter logic
set -euo pipefail

# Any raw GitHub release .dmg asset URL: the rolling /releases/latest/download/...
# shape AND pinned /releases/download/<tag>/... assets, regardless of filename
# (release assets are versioned, e.g. EnviousWispr-2.2.0.dmg). The doorway anchor
# text "[EnviousWispr.dmg](https://enviouswispr.com/download?...)" is NOT matched:
# its URL is enviouswispr.com, not a github releases asset path.
DMG_RE='github\.com/saurabhav88/EnviousWispr/releases/[^)"[:space:]]*\.dmg'
RELEASES_RE='github\.com/saurabhav88/EnviousWispr/releases'
# Off-site /download doorway used as a link TARGET in on-site blog prose, across
# every link form: inline markdown ](.../download, reference def ]: /download,
# raw HTML href=".../download, or any absolute enviouswispr.com/download. Each
# pattern requires a literal "/download" (slash-download), so the on-site
# "/#download" section anchor (slash-hash-download) never matches.
DOORWAY_MISUSE_RES=(
  'enviouswispr\.com/download'
  '\]\([^)]*/download'
  '\]:[[:space:]]*[^[:space:]]*/download'
  'href=[^>]*/download'
)

REQUIRED_README_SOURCE="github_readme"

# Parse a /download URL's query the way the resolver does and validate it as a
# correctly-tagged README doorway link. Echoes a problem summary and returns 1 if
# not valid; returns 0 if valid. First value of a repeated key wins; ?source is
# lowercased (mirrors download.js resolveSourceBucket / URLSearchParams.get).
validate_readme_doorway_link() {
  local url="$1"
  local query=""
  case "$url" in *\?*) query="${url#*\?}" ;; esac

  local source="" usrc="" umed="" ucamp=""
  local have_source=0 have_usrc=0 have_umed=0 have_ucamp=0
  local kv k v old_ifs="$IFS"
  IFS='&'
  for kv in $query; do
    k="${kv%%=*}"
    case "$kv" in *=*) v="${kv#*=}" ;; *) v="" ;; esac
    case "$k" in
      source)       if [ "$have_source" = 0 ]; then source="$v"; have_source=1; fi ;;
      utm_source)   if [ "$have_usrc"   = 0 ]; then usrc="$v";   have_usrc=1;   fi ;;
      utm_medium)   if [ "$have_umed"   = 0 ]; then umed="$v";   have_umed=1;   fi ;;
      utm_campaign) if [ "$have_ucamp"  = 0 ]; then ucamp="$v";  have_ucamp=1;  fi ;;
    esac
  done
  IFS="$old_ifs"

  source="$(printf '%s' "$source" | tr '[:upper:]' '[:lower:]')"

  local problems=""
  [ "$source" = "$REQUIRED_README_SOURCE" ] || problems="${problems} resolved source='${source:-<none>}' (must be ${REQUIRED_README_SOURCE});"
  [ -n "$usrc" ]  || problems="${problems} utm_source missing/empty;"
  [ -n "$umed" ]  || problems="${problems} utm_medium missing/empty;"
  [ -n "$ucamp" ] || problems="${problems} utm_campaign missing/empty;"

  if [ -n "$problems" ]; then
    printf '%s' "${problems# }"
    return 1
  fi
  return 0
}

# Lint a given root directory. Echoes violations, returns non-zero if any found.
lint_root() {
  local root="$1"
  local readme="$root/README.md"
  local blog="$root/website/src/content/blog"
  local fail=0
  local hit

  if [ -f "$readme" ]; then
    # (a) no raw .dmg download links in README
    if hit=$(grep -nE "$DMG_RE" "$readme"); then
      echo "::error::README.md has a raw GitHub .dmg download link; use the tagged doorway https://enviouswispr.com/download?source=github_readme&utm_source=...&utm_medium=...&utm_campaign=..." >&2
      echo "$hit" >&2
      fail=1
    fi
    # (a) every enviouswispr.com/download link in README must be a correctly-tagged
    #     doorway, validated by parsing its query (see validate_readme_doorway_link).
    local link why
    while IFS= read -r link; do
      [ -z "$link" ] && continue
      if why=$(validate_readme_doorway_link "$link"); then
        :
      else
        echo "::error::README.md /download link is not a correctly-tagged doorway ($why): $link" >&2
        fail=1
      fi
    done < <(grep -oE 'enviouswispr\.com/download[^)"[:space:]]*' "$readme" || true)
  fi

  if [ -d "$blog" ]; then
    # (b) no raw .dmg in blog prose
    if hit=$(grep -rnE "$DMG_RE" "$blog"); then
      echo "::error::blog prose has a raw GitHub .dmg link; on-site download links must point at the on-site /#download section." >&2
      echo "$hit" >&2
      fail=1
    fi
    # (b) no GitHub releases URL in blog prose (repo root is allowed for source links)
    if hit=$(grep -rnE "$RELEASES_RE" "$blog"); then
      echo "::error::blog prose has a GitHub releases URL; use /#download for downloads, or the repo root https://github.com/saurabhav88/EnviousWispr for source/transparency links." >&2
      echo "$hit" >&2
      fail=1
    fi
    # (b) no off-site /download doorway link in on-site blog prose (every link form)
    local re
    for re in "${DOORWAY_MISUSE_RES[@]}"; do
      if hit=$(grep -rnE "$re" "$blog"); then
        echo "::error::blog prose links the off-site /download doorway; on-site prose must use /#download (the doorway is for OFF-SITE owned links only)." >&2
        echo "$hit" >&2
        fail=1
      fi
    done
  fi

  return "$fail"
}

self_test() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp:-}"' EXIT
  mkdir -p "$tmp/website/src/content/blog"

  # ---- README doorway-link matrix (parser unit tests; the whole query-shape space) ----
  # GOOD: must validate. Covers canonical, order-independence, and case (resolver lowercases).
  local D='https://enviouswispr.com/download'
  local good=(
    "$D?source=github_readme&utm_source=github&utm_medium=referral&utm_campaign=x"
    "$D?utm_source=github&utm_medium=referral&utm_campaign=x&source=github_readme"
    "$D?source=GitHub_Readme&utm_source=github&utm_medium=referral&utm_campaign=x"
  )
  # BAD: must be rejected. Each row is one cell of the failure space.
  local bad=(
    "$D?utm_source=github&utm_medium=referral&utm_campaign=x"                                   # no source param
    "$D?source=reddit&utm_source=github&utm_medium=referral&utm_campaign=x"                     # foreign source
    "$D?source=github_readme_old&utm_source=github&utm_medium=referral&utm_campaign=x"          # near-miss value
    "$D?utm_source=github_readme&utm_medium=referral&utm_campaign=x"                            # utm_source masquerade, no real source
    "$D?source=reddit&utm_source=github&utm_medium=referral&utm_campaign=x&source=github_readme" # duplicate, foreign first wins
    "$D?source=&utm_source=github&utm_medium=referral&utm_campaign=x&source=github_readme"      # duplicate, empty first wins
    "$D?source=github_readme&utm_source=github&utm_campaign=x"                                  # missing utm_medium
    "$D?source=github_readme&utm_source=&utm_medium=referral&utm_campaign=x"                    # empty utm value
    "$D"                                                                                        # bare, no query
  )
  local u
  for u in "${good[@]}"; do
    if ! validate_readme_doorway_link "$u" >/dev/null; then
      echo "SELF-TEST FAIL: good doorway link rejected: $u" >&2; return 1
    fi
  done
  for u in "${bad[@]}"; do
    if validate_readme_doorway_link "$u" >/dev/null; then
      echo "SELF-TEST FAIL: bad doorway link accepted: $u" >&2; return 1
    fi
  done

  # ---- README raw-.dmg matrix (lint_root integration) ----
  local dmg=(
    'https://github.com/saurabhav88/EnviousWispr/releases/latest/download/EnviousWispr.dmg'   # rolling
    'https://github.com/saurabhav88/EnviousWispr/releases/download/v1.2.3/EnviousWispr.dmg'   # pinned
    'https://github.com/saurabhav88/EnviousWispr/releases/download/v2.2.0/EnviousWispr-2.2.0.dmg' # versioned filename
  )
  for u in "${dmg[@]}"; do
    echo "[dl]($u)" > "$tmp/README.md"
    if lint_root "$tmp" >/dev/null 2>&1; then echo "SELF-TEST FAIL: README raw .dmg accepted: $u" >&2; return 1; fi
  done

  # restore a good README so blog-only fixtures are isolated
  echo "[Download DMG]($D?source=github_readme&utm_source=github&utm_medium=referral&utm_campaign=enviouswispr-evergreen-readme)" > "$tmp/README.md"
  printf '%s\n' '[Download EnviousWispr free](/#download) or browse the source [on GitHub](https://github.com/saurabhav88/EnviousWispr).' > "$tmp/website/src/content/blog/good.md"
  if ! lint_root "$tmp" >/dev/null 2>&1; then echo "SELF-TEST FAIL: clean fixture rejected" >&2; return 1; fi

  # ---- blog matrix: every (link form x target) cell ----
  local blogbad=(
    '[dl](https://github.com/saurabhav88/EnviousWispr/releases/latest/download/EnviousWispr.dmg)' # raw .dmg
    '[dl](https://github.com/saurabhav88/EnviousWispr/releases/download/v2.2.0/EnviousWispr-2.2.0.dmg)' # raw versioned .dmg
    '[grab it](https://github.com/saurabhav88/EnviousWispr/releases)'                            # releases page
    '[get it](/download?source=blog)'                                                            # inline doorway
    '<a href="/download?source=blog">get it</a>'                                                 # html href doorway
    '[get it](https://enviouswispr.com/download?source=blog)'                                    # absolute doorway
  )
  for line in "${blogbad[@]}"; do
    echo "$line" > "$tmp/website/src/content/blog/bad.md"
    if lint_root "$tmp" >/dev/null 2>&1; then echo "SELF-TEST FAIL: blog bad link accepted: $line" >&2; return 1; fi
  done
  # reference-style doorway misuse (two-line form)
  printf '%s\n\n%s\n' '[get it][dl]' '[dl]: /download?source=blog' > "$tmp/website/src/content/blog/bad.md"
  if lint_root "$tmp" >/dev/null 2>&1; then echo "SELF-TEST FAIL: blog reference-style doorway accepted" >&2; return 1; fi
  rm "$tmp/website/src/content/blog/bad.md"

  # GOOD: on-site /#download in every link form must NOT trip the doorway check
  printf '%s\n\n%s\n' '[dl](/#download) and [ref][r] and <a href="/#download">x</a>' '[r]: /#download' > "$tmp/website/src/content/blog/good2.md"
  if ! lint_root "$tmp" >/dev/null 2>&1; then echo "SELF-TEST FAIL: on-site /#download wrongly rejected" >&2; return 1; fi
  rm "$tmp/website/src/content/blog/good2.md"

  echo "download-link lint self-test passed."
}

main() {
  if [ "${1:-}" = "--self-test" ]; then
    self_test
    return
  fi
  local root
  root="$(cd "$(dirname "$0")/../.." && pwd)"
  if lint_root "$root"; then
    echo "download-link lint passed: README doorway tagged; blog prose uses /#download."
  else
    echo "download-link lint FAILED; see ::error:: lines above." >&2
    exit 1
  fi
}

main "$@"
