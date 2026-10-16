#!/usr/bin/env bash
# #3729: the release operator's two commands. The sequence they belong to is owned by
# the release skill (.claude/skills/wispr-release-checklist/SKILL.md, main checkout).
#
#   scripts/release.sh start <MAJOR.MINOR.PATCH>
#       From any checkout of this repo. Refuses a version that is not newer than the last
#       tag, or whose branch, tag or folder already exists. Creates the release worktree
#       ../EnviousWispr-release-v<V> on branch release/v<V> from a fresh origin/main (never
#       /tmp: #3820), sets both Info.plist versions and currentContentVersion, writes the
#       notes and probe skeletons under .github/release-notes/, then prints the open
#       release-action issues and the commits since the last tag (advisory lists only).
#
#   scripts/release.sh prepare
#       Inside the release worktree, after the app notes (WhatsNewContent.swift), the GitHub
#       notes (.github/release-notes/v<V>.md) and the probe list (v<V>.probes) are final.
#       Checks the version spots and that no skeleton is left, renders the app notes, builds
#       the dev app (it takes the shared dev-app lock), syncs the String Catalog from that
#       build, stops if German is missing or unreviewed, exports the settings map,
#       regenerates the help catalog and adds the README "(v<V>)" lines. Safe to re-run.
#       CI's Release catalog check stays the authority (pr-check.yml).
#
#   scripts/release.sh self-test
#       Runs the pure helpers and `start` against a throwaway origin. No network.
set -euo pipefail

SKELETON_MARK='<!-- release-notes: skeleton, replace before prepare -->'
PROBE_MARK='# release-probes: skeleton, replace before prepare'

die() { echo "release: $*" >&2; exit 1; }

valid_version() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }

# Exit 0 when $1 > $2 (both MAJOR.MINOR.PATCH).
version_newer() {
  python3 - "$1" "$2" <<'PY'
import sys
a, b = (tuple(int(x) for x in v.split(".")) for v in sys.argv[1:3])
sys.exit(0 if a > b else 1)
PY
}

# Insert README "Recent improvements" lines for version $2 from rendered notes file $3 into
# README $1. Idempotent: does nothing when a "(v$2)" line is already there.
readme_insert() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
readme, version, notes = sys.argv[1:4]
text = open(readme, encoding="utf-8").read()
tag = f"(v{version})"
if tag in text:
    print(f"README: already has {tag} lines")
    sys.exit(0)
items = [line.rstrip() for line in open(notes, encoding="utf-8") if line.startswith("- **")]
if not items:
    sys.exit("README: the rendered notes have no '- **Title.** text' lines")
head = "## Recent improvements\n"
start = text.find(head)
if start < 0:
    sys.exit("README: no '## Recent improvements' heading")
first = re.compile(r"^- ", re.M).search(text, start + len(head))
if not first:
    sys.exit("README: no list under '## Recent improvements'")
block = "".join(f"{line} {tag}\n" for line in items)
open(readme, "w", encoding="utf-8").write(text[: first.start()] + block + text[first.start():])
print(f"README: added {len(items)} {tag} lines")
PY
}

# Exit 0 when the notes file $1 and probe file $2 are filled in (not skeletons, not empty).
notes_ready() {
  local notes="$1" probes="$2"
  [ -s "$notes" ] || { echo "missing or empty: $notes" >&2; return 1; }
  [ -s "$probes" ] || { echo "missing or empty: $probes" >&2; return 1; }
  if grep -qF "$SKELETON_MARK" "$notes"; then echo "still the skeleton: $notes" >&2; return 1; fi
  if grep -qF "$PROBE_MARK" "$probes"; then echo "still the skeleton: $probes" >&2; return 1; fi
  if ! grep -qv -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$probes"; then
    echo "no probe lines: $probes" >&2; return 1
  fi
}

write_skeletons() {
  local dir="$1" version="$2"
  mkdir -p "$dir"
  cat > "$dir/v$version.md" <<EOF
$SKELETON_MARK
## What's new in v$version

### <Change title> (#<PR>)

- <What changed, for someone reading the GitHub release page>
EOF
  cat > "$dir/v$version.probes" <<EOF
$PROBE_MARK
# One exact on-screen string per line, longer than 15 bytes, that only exists if a new
# feature in this release reached the Release build. release.yml fails the build if one is
# missing (scripts/ci/check-release-probes.sh). Lines starting with # are ignored.
EOF
}

cmd_start() {
  local version="${1:-}" remote="${RELEASE_REMOTE:-origin}"
  valid_version "$version" || die "usage: scripts/release.sh start MAJOR.MINOR.PATCH (got '${version}')"
  local common root parent wt branch="release/v$version" tag="v$version"
  common="$(git rev-parse --path-format=absolute --git-common-dir)"
  root="$(dirname "$common")"
  parent="$(dirname "$root")"
  wt="$parent/$(basename "$root")-release-v$version"
  git -C "$root" fetch --quiet --tags "$remote" || die "could not fetch $remote"
  local last
  last="$(git -C "$root" describe --tags --abbrev=0 --match 'v[0-9]*' "$remote/main" 2>/dev/null || true)"
  if [ -n "$last" ] && ! version_newer "$version" "${last#v}"; then
    die "$version is not newer than the last release tag $last"
  fi
  git -C "$root" rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "tag $tag already exists"
  git -C "$root" rev-parse -q --verify "refs/heads/$branch" >/dev/null && die "branch $branch already exists"
  if git -C "$root" ls-remote --exit-code --heads "$remote" "$branch" >/dev/null 2>&1; then
    die "branch $branch already exists on $remote"
  fi
  [ -e "$wt" ] && die "folder already exists: $wt"
  git -C "$root" worktree add --quiet -b "$branch" "$wt" "$remote/main"
  local plist="$wt/Sources/EnviousWispr/Resources/Info.plist"
  local constants="$wt/Sources/EnviousWisprCore/WhatsNewConstants.swift"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$plist"
  local old
  old="$(sed -n 's/.*currentContentVersion = "\([0-9.]*\)".*/\1/p' "$constants")"
  [ -n "$old" ] || die "no currentContentVersion in $constants"
  if [ "$old" != "$version" ]; then
    sed -i '' "s/currentContentVersion = \"$old\"/currentContentVersion = \"$version\"/" "$constants"
  fi
  write_skeletons "$wt/.github/release-notes" "$version"
  echo "==> Release worktree: $wt (branch $branch from $remote/main)"
  echo "==> Set Info.plist CFBundleShortVersionString and CFBundleVersion to $version; currentContentVersion $old -> $version"
  echo "==> Skeletons: .github/release-notes/v$version.md and v$version.probes"
  if [ -n "$old" ] && [ "$old" != "$version" ]; then
    echo "==> Other places that still say $old (review each; most are history):"
    git -C "$wt" grep -n -F "\"$old\"" -- Sources Tests scripts 2>/dev/null | head -20 || true
  fi
  if [ -z "${RELEASE_OFFLINE:-}" ]; then
    echo "==> Open release-action issues (handle each before merging the release PR):"
    gh issue list --repo saurabhav88/EnviousWispr --label release-action --state open --limit 100 \
      || echo "   (could not ask GitHub; run: gh issue list --label release-action --state open)"
    for key in gemini-api-key azure-openai-key; do
      if [ -x "$HOME/.claude/bin/get-key" ] && ! "$HOME/.claude/bin/get-key" --check "$key" >/dev/null 2>&1; then
        echo "==> WARNING: $key is not reachable; the German review needs it. Log in now:"
        echo "    gcloud --configuration=business auth login --update-adc"
      fi
    done
  fi
  local range="${last:+$last..}$remote/main"
  echo "==> Commits since ${last:-the first commit} (advisory: a filtered subject can still be user-visible):"
  git -C "$root" log --format='%h %s' "$range" \
    | grep -v -E '^[0-9a-f]+ (ci|test|tests|docs|build\(deps\)|chore)(\(|:)' || true
  echo "==> Filtered out as ci/test/docs/deps/chore (skim these too):"
  git -C "$root" log --format='%h %s' "$range" \
    | grep -E '^[0-9a-f]+ (ci|test|tests|docs|build\(deps\)|chore)(\(|:)' | wc -l | tr -d ' '
  echo "==> Next: draft both notes versions, have Codex verify every claim, then the founder edits."
}

cmd_prepare() {
  local top branch version
  top="$(git rev-parse --show-toplevel)"
  cd "$top"
  branch="$(git branch --show-current)"
  [[ "$branch" =~ ^release/v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || die "run inside a release worktree (branch release/vX.Y.Z), not '$branch'"
  version="${BASH_REMATCH[1]}"
  local short build content
  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/EnviousWispr/Resources/Info.plist)"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Sources/EnviousWispr/Resources/Info.plist)"
  content="$(sed -n 's/.*currentContentVersion = "\([0-9.]*\)".*/\1/p' Sources/EnviousWisprCore/WhatsNewConstants.swift)"
  [ "$short" = "$version" ] && [ "$build" = "$version" ] && [ "$content" = "$version" ] \
    || die "version spots disagree with $branch: Info.plist $short/$build, currentContentVersion $content"
  notes_ready ".github/release-notes/v$version.md" ".github/release-notes/v$version.probes" \
    || die "fill in the GitHub notes and probes first"
  echo "==> [1/7] App notes"
  python3 scripts/ci/render-release-notes.py --self-test
  mkdir -p build
  python3 scripts/ci/render-release-notes.py --version "$version" --out build/release-notes-app.md
  cat build/release-notes-app.md
  echo "==> [2/7] Dev build (takes the shared dev-app lock; release it after the gift-menu check)"
  scripts/build-dev-app.sh
  echo "==> [3/7] String Catalog from the Dev build"
  local digest
  digest="$(python3 scripts/lib/l10n-build-receipt.py input-digest --repo "$top" --configuration Dev \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["input_digest"])')"
  bash scripts/lib/l10n-catalog-sync.sh --update --configuration Dev \
    --derived-data "$top/.derivedData/Dev" --expect-inputs "$digest" || true
  echo "==> [4/7] German"
  if ! bash scripts/lib/l10n-catalog-sync.sh --check --configuration Dev \
      --derived-data "$top/.derivedData/Dev" --expect-inputs "$digest"; then
    echo "release: German is missing or unreviewed (list above). Draft it, have the GPT + Gemini council" >&2
    echo "         review it, mark it translated, then run scripts/release.sh prepare again." >&2
    exit 4
  fi
  echo "==> [5/7] Settings map"
  scripts/settings-map/export.sh
  echo "==> [6/7] Help catalog"
  node website/scripts/generate-help-article-catalog.mjs
  echo "==> [7/7] README"
  readme_insert README.md "$version" build/release-notes-app.md
  echo "==> Changed files:"
  git status --short
  echo "==> Still yours: check the gift menu on the dev app, release the dev-app lock, commit,"
  echo "    run scripts/xcode-test.sh once, one local Codex review, then open the release PR."
}

cmd_self_test() {
  local tmp failures=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ew-release-selftest.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN
  check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi; }
  check "valid version" 'valid_version 2.5.5'
  check "rejects v prefix" '! valid_version v2.5.5'
  check "rejects leading zero" '! valid_version 2.05.1'
  check "rejects two parts" '! valid_version 2.5'
  check "newer patch" 'version_newer 2.5.5 2.5.4'
  check "newer minor beats patch" 'version_newer 2.6.0 2.5.9'
  check "same is not newer" '! version_newer 2.5.4 2.5.4'
  check "10 beats 9 numerically" 'version_newer 2.10.0 2.9.0'
  # README insertion
  printf '# X\n\n## Recent improvements\n\nIntro.\n\n- **Old.** Text. (v1.0.0)\n' > "$tmp/README.md"
  printf '## What'"'"'s new in v1.0.1\n\n- **New thing.** Does it.\n- **Second.** Too.\n' > "$tmp/notes.md"
  readme_insert "$tmp/README.md" 1.0.1 "$tmp/notes.md" >/dev/null
  check "README lines inserted above the old list" \
    '[ "$(sed -n 7p "$tmp/README.md")" = "- **New thing.** Does it. (v1.0.1)" ] && [ "$(sed -n 9p "$tmp/README.md")" = "- **Old.** Text. (v1.0.0)" ]'
  readme_insert "$tmp/README.md" 1.0.1 "$tmp/notes.md" >/dev/null
  check "README insertion is idempotent" '[ "$(grep -c "(v1.0.1)" "$tmp/README.md")" = 2 ]'
  # skeleton detection
  write_skeletons "$tmp/notes" 1.0.1
  check "skeleton notes are not ready" '! notes_ready "$tmp/notes/v1.0.1.md" "$tmp/notes/v1.0.1.probes" 2>/dev/null'
  printf '## What is new\n\n- real\n' > "$tmp/notes/v1.0.1.md"
  check "skeleton probes are not ready" '! notes_ready "$tmp/notes/v1.0.1.md" "$tmp/notes/v1.0.1.probes" 2>/dev/null'
  printf '# only a comment\n' > "$tmp/notes/v1.0.1.probes"
  check "comment-only probes are not ready" '! notes_ready "$tmp/notes/v1.0.1.md" "$tmp/notes/v1.0.1.probes" 2>/dev/null'
  printf 'Keep dictations out of clipboard history apps\n' > "$tmp/notes/v1.0.1.probes"
  check "filled notes and probes are ready" 'notes_ready "$tmp/notes/v1.0.1.md" "$tmp/notes/v1.0.1.probes"'
  # start, against a throwaway origin
  local origin="$tmp/origin.git" seed="$tmp/seed" clone="$tmp/w/EnviousWispr"
  git init -q --bare "$origin"
  git init -q -b main "$seed"
  mkdir -p "$seed/Sources/EnviousWispr/Resources" "$seed/Sources/EnviousWisprCore"
  cat > "$seed/Sources/EnviousWispr/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1.0.0</string>
</dict></plist>
PLIST
  printf 'public enum WhatsNewConstants {\n  public static let currentContentVersion = "1.0.0"\n}\n' \
    > "$seed/Sources/EnviousWisprCore/WhatsNewConstants.swift"
  git -C "$seed" add -A && git -C "$seed" -c user.name=t -c user.email=t@t commit -q -m "feat: base"
  git -C "$seed" tag v1.0.0
  git -C "$seed" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "fix(app): something"
  git -C "$seed" push -q "$origin" main --tags
  mkdir -p "$tmp/w" && git clone -q "$origin" "$clone"
  check "start refuses an older version" '! (cd "$clone" && RELEASE_OFFLINE=1 cmd_start 0.9.0) >/dev/null 2>&1'
  check "start refuses the same version" '! (cd "$clone" && RELEASE_OFFLINE=1 cmd_start 1.0.0) >/dev/null 2>&1'
  check "start creates the release" '(cd "$clone" && RELEASE_OFFLINE=1 cmd_start 1.0.1) >"$tmp/start.out" 2>&1'
  local wt="$tmp/w/EnviousWispr-release-v1.0.1"
  check "worktree on its branch" '[ "$(git -C "$wt" branch --show-current)" = release/v1.0.1 ]'
  check "both plist versions set" '[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$wt/Sources/EnviousWispr/Resources/Info.plist")/$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$wt/Sources/EnviousWispr/Resources/Info.plist")" = 1.0.1/1.0.1 ]'
  check "content version set" 'grep -q "currentContentVersion = \"1.0.1\"" "$wt/Sources/EnviousWisprCore/WhatsNewConstants.swift"'
  check "skeletons written" '[ -s "$wt/.github/release-notes/v1.0.1.md" ] && [ -s "$wt/.github/release-notes/v1.0.1.probes" ]'
  check "commit list printed" 'grep -q "fix(app): something" "$tmp/start.out"'
  check "start refuses an existing branch" '! (cd "$clone" && RELEASE_OFFLINE=1 cmd_start 1.0.1) >/dev/null 2>&1'
  git -C "$clone" worktree remove --force "$wt" >/dev/null 2>&1 || true
  echo "release.sh self-test: failures=$failures"
  [ "$failures" -eq 0 ]
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  prepare) shift; cmd_prepare "$@" ;;
  self-test) cmd_self_test ;;
  *) echo "usage: scripts/release.sh start MAJOR.MINOR.PATCH | prepare | self-test" >&2; exit 2 ;;
esac
