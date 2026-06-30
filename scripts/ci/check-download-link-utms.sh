#!/usr/bin/env bash
# Design-time guard for the /download attribution doorway.
# Plan: docs/feature-requests/plan-2026-06-29-download-attribution.md (§3a, §6).
#
# Two rules, enforced at PR + deploy time so download-link drift is caught before
# it ships (not discovered weeks later as a hole in attribution):
#
#   (a) OFF-SITE download links (README) MUST be the canonical tagged doorway:
#       https://enviouswispr.com/download?...utm_source/medium/campaign...
#       and NEVER a raw GitHub .dmg (that bypasses our analytics entirely).
#
#   (b) ON-SITE blog prose download links MUST point at the on-site /#download
#       section, NEVER a raw GitHub .dmg / releases URL (those fire no event and
#       leak an unattributed download path), and NEVER the off-site /download
#       doorway (that would self-refer + double-count). The repo root
#       https://github.com/saurabhav88/EnviousWispr is allowed for source /
#       transparency links; it is not a download path.
#
# On-site download BUTTONS in Astro (Nav/Footer/hero/compare CTAs) deliberately
# keep their raw .dmg href + data-download-source attribute; the page JS fires
# download_clicked on click. They are out of scope here by design (plan §2.1).
#
# Usage:
#   scripts/ci/check-download-link-utms.sh            # lint the working tree
#   scripts/ci/check-download-link-utms.sh --self-test  # verify the linter logic
set -euo pipefail

# Any raw GitHub release asset URL for the .dmg — both the rolling
# /releases/latest/download/... shape AND a pinned /releases/download/<tag>/...
# asset. The doorway anchor text "[EnviousWispr.dmg](https://enviouswispr.com/
# download?...)" is NOT matched: its URL is enviouswispr.com, not a github
# releases asset path.
DMG_RE='github\.com/saurabhav88/EnviousWispr/releases/[^)"[:space:]]*EnviousWispr\.dmg'
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
      echo "::error::README.md has a raw GitHub .dmg download link; use the tagged doorway https://enviouswispr.com/download?source=...&utm_source=...&utm_medium=...&utm_campaign=..." >&2
      echo "$hit" >&2
      fail=1
    fi
    # (a) every enviouswispr.com/download link in README must carry utm_source/medium/campaign
    while IFS= read -r link; do
      [ -z "$link" ] && continue
      if ! { echo "$link" | grep -q 'utm_source=' \
          && echo "$link" | grep -q 'utm_medium=' \
          && echo "$link" | grep -q 'utm_campaign='; }; then
        echo "::error::README.md /download link missing utm_source/medium/campaign: $link" >&2
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

  # GOOD fixture: tagged README doorway + on-site /#download blog + repo-root source link.
  printf '%s\n' \
    '[Download DMG](https://enviouswispr.com/download?source=github_readme&utm_source=github&utm_medium=referral&utm_campaign=enviouswispr-evergreen-readme)' \
    '[full release history](https://github.com/saurabhav88/EnviousWispr/releases)' \
    > "$tmp/README.md"
  printf '%s\n' \
    '[Download EnviousWispr free](/#download) or browse the source [on GitHub](https://github.com/saurabhav88/EnviousWispr).' \
    > "$tmp/website/src/content/blog/good.md"
  if ! lint_root "$tmp" >/dev/null 2>&1; then
    echo "SELF-TEST FAIL: clean fixture was rejected" >&2; return 1
  fi

  # BAD 1: raw .dmg in README (rolling /latest/ shape)
  echo '[dl](https://github.com/saurabhav88/EnviousWispr/releases/latest/download/EnviousWispr.dmg)' > "$tmp/README.md"
  if lint_root "$tmp" >/dev/null 2>&1; then echo "SELF-TEST FAIL: README raw .dmg not caught" >&2; return 1; fi

  # BAD 1b: raw .dmg in README (pinned /releases/download/<tag>/ asset shape)
  echo '[dl](https://github.com/saurabhav88/EnviousWispr/releases/download/v1.2.3/EnviousWispr.dmg)' > "$tmp/README.md"
  if lint_root "$tmp" >/dev/null 2>&1; then echo "SELF-TEST FAIL: README versioned raw .dmg not caught" >&2; return 1; fi

  # BAD 2: README /download link without utm
  echo '[dl](https://enviouswispr.com/download?source=github_readme)' > "$tmp/README.md"
  if lint_root "$tmp" >/dev/null 2>&1; then echo "SELF-TEST FAIL: untagged README doorway not caught" >&2; return 1; fi

  # restore a good README so blog-only failures are isolated
  echo '[Download DMG](https://enviouswispr.com/download?utm_source=github&utm_medium=referral&utm_campaign=enviouswispr-evergreen-readme)' > "$tmp/README.md"

  # BAD 3: raw .dmg in blog
  echo '[dl](https://github.com/saurabhav88/EnviousWispr/releases/latest/download/EnviousWispr.dmg)' > "$tmp/website/src/content/blog/bad.md"
  if lint_root "$tmp" >/dev/null 2>&1; then echo "SELF-TEST FAIL: blog raw .dmg not caught" >&2; return 1; fi
  rm "$tmp/website/src/content/blog/bad.md"

  # BAD 4: releases page link in blog
  echo '[grab it](https://github.com/saurabhav88/EnviousWispr/releases)' > "$tmp/website/src/content/blog/bad.md"
  if lint_root "$tmp" >/dev/null 2>&1; then echo "SELF-TEST FAIL: blog releases URL not caught" >&2; return 1; fi
  rm "$tmp/website/src/content/blog/bad.md"

  # BAD 5: off-site doorway misuse in blog — inline markdown link
  echo '[get it](/download?source=blog)' > "$tmp/website/src/content/blog/bad.md"
  if lint_root "$tmp" >/dev/null 2>&1; then echo "SELF-TEST FAIL: blog inline /download misuse not caught" >&2; return 1; fi

  # BAD 5b: off-site doorway misuse — markdown reference definition
  printf '%s\n\n%s\n' '[get it][dl]' '[dl]: /download?source=blog' > "$tmp/website/src/content/blog/bad.md"
  if lint_root "$tmp" >/dev/null 2>&1; then echo "SELF-TEST FAIL: blog reference-style /download misuse not caught" >&2; return 1; fi

  # BAD 5c: off-site doorway misuse — raw HTML href
  echo '<a href="/download?source=blog">get it</a>' > "$tmp/website/src/content/blog/bad.md"
  if lint_root "$tmp" >/dev/null 2>&1; then echo "SELF-TEST FAIL: blog HTML href /download misuse not caught" >&2; return 1; fi

  # BAD 5d: off-site doorway misuse — absolute doorway URL
  echo '[get it](https://enviouswispr.com/download?source=blog)' > "$tmp/website/src/content/blog/bad.md"
  if lint_root "$tmp" >/dev/null 2>&1; then echo "SELF-TEST FAIL: blog absolute /download misuse not caught" >&2; return 1; fi
  rm "$tmp/website/src/content/blog/bad.md"

  # GOOD: on-site /#download anchor in all forms must NOT trip the doorway check
  printf '%s\n\n%s\n%s\n' '[dl](/#download) and [ref][r] and <a href="/#download">x</a>' '[r]: /#download' '' > "$tmp/website/src/content/blog/good2.md"
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
