#!/bin/bash
# Two-way control for scripts/verify-view-split.py.
#
# Every arm asserts a DIFFERENT exit code, because a guard that merely stops firing
# is indistinguishable from one that was deleted. Boundaries are the ones verified
# against the real file, so arm 1 is a genuine clean split rather than a fixture
# built to pass.
set -u

# The repo root is DERIVED from this script's own location, never pinned to one
# workstation. An earlier version hardcoded the author's absolute path, so in every
# other checkout — another Mac, CI, a sibling worktree — it exited 2 before running a
# single control arm. A hardcoded absolute path is not a pin to a repository; it is a
# pin to whatever branch one particular tree happens to be on.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 2
cd "$ROOT" || exit 2

SRC=Sources/EnviousWisprAppKit/App/Overlay/Views/OverlayLegacyViews.swift

# BASE must be a revision where the subject file still EXISTS, and the commit that
# ships this harness is the one that DELETES it. So resolve rather than assume:
# at or before the split, HEAD still has it; at or after, the last commit touching
# that path is the deletion and its parent is the pre-split tree.
if git cat-file -e "HEAD:$SRC" 2>/dev/null; then
  BASE=$(git rev-parse HEAD)
else
  deletion=$(git rev-list -1 HEAD -- "$SRC")
  [ -n "$deletion" ] || { echo "BLOCKED: $SRC is unknown to this history" >&2; exit 2; }
  BASE=$(git rev-parse "${deletion}^")
fi
git cat-file -e "$BASE:$SRC" 2>/dev/null || {
  echo "BLOCKED: resolved BASE $BASE does not contain $SRC" >&2; exit 2; }

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
FAIL=0

# Read the subject from the REVISION, never from the working tree. After the split the
# working-tree path does not exist, so a harness that slices the file on disk cannot run
# on the commit that ships it — which is the one commit where it has to.
ORIG="$T/original.swift"
git show "$BASE:$SRC" > "$ORIG" || exit 2

check() {
  if [ "$2" = "$3" ]; then printf '  PASS  %s\n' "$1"
  else printf '  FAIL  %s: expected exit %s, got %s\n' "$1" "$2" "$3"; FAIL=1; fi
}

# 5-37 is the two observable channels; 38-47 is the file-level narration that is
# DELETED rather than moved; the rest is one range per top-level declaration.
RANGES="5:37 48:144 145:297 298:310 311:429 430:533 534:572 573:968 969:1083 \
1084:1117 1118:1161 1162:1216 1217:1251 1252:1282 1283:1377 1378:1412 1413:1448"

ARGS=()
for r in $RANGES; do
  a=${r%%:*}; b=${r##*:}
  { echo "import AppKit"; echo "import SwiftUI"; echo; sed -n "${a},${b}p" "$ORIG"; } \
    > "$T/p$a.swift"
  ARGS+=(--new "$T/p$a.swift")
done
echo "split into ${#ARGS[@]} half-args ($(( ${#ARGS[@]} / 2 )) files)"

run() {
  python3 scripts/verify-view-split.py --base "$BASE" --original "$SRC" \
    --drop-original-lines 38-47 "$@" >/dev/null 2>&1
  echo $?
}

check "arm 1  a clean split is MOVE-ONLY" 0 "$(run "${ARGS[@]}")"

cp "$T/p48.swift" "$T/p48.bak"
sed -i '' 's/let size: CGFloat$/let size: CGFloat2/' "$T/p48.swift"
check "arm 2  a one-character code edit is CONTENT CHANGED" 1 "$(run "${ARGS[@]}")"

# A COMMENT edit must also be caught: a relocation that drops the reason a view
# exists is the specific failure move-recorded-reasons-before-simplifying names.
mv "$T/p48.bak" "$T/p48.swift"
cp "$T/p430.swift" "$T/p430.bak"
sed -i '' '/#1988: the live-preview pill/d' "$T/p430.swift"
# A DELETED line is BLOCKED rather than merely reported, because losing content is
# the worst case and deserves the loudest exit.
check "arm 3a a DELETED doc comment is BLOCKED" 2 "$(run "${ARGS[@]}")"
mv "$T/p430.bak" "$T/p430.swift"

# The line-count guard cannot see a REWORDING — same line count, different meaning —
# and that is the shape move-recorded-reasons-before-simplifying actually warns about:
# a reason summarised instead of carried.
cp "$T/p430.swift" "$T/p430.bak"
sed -i '' 's|#1988: the live-preview pill|#1988: the preview pill|' "$T/p430.swift"
check "arm 3b a REWORDED doc comment is CONTENT CHANGED" 1 "$(run "${ARGS[@]}")"
mv "$T/p430.bak" "$T/p430.swift"
check "arm 4  restoring both returns to MOVE-ONLY" 0 "$(run "${ARGS[@]}")"

SHORT=(); SKIP=0
for a in "${ARGS[@]}"; do
  if [ "$SKIP" = 1 ]; then SKIP=0; continue; fi
  case "$a" in *p430.swift) SKIP=0; continue;; esac
  case "$a" in --new) NEXT=1;; esac
  SHORT+=("$a")
done
# rebuild without the p430 pair cleanly
SHORT=()
for r in $RANGES; do
  a=${r%%:*}; [ "$a" = 430 ] && continue
  SHORT+=(--new "$T/p$a.swift")
done
check "arm 5  a lost declaration is BLOCKED" 2 "$(run "${SHORT[@]}")"

sed -i '' 's/^private struct OverlayCapsuleBackground/struct OverlayCapsuleBackground/' \
  "$T/p430.swift"
check "arm 6  an UNDECLARED widening is CONTENT CHANGED" 1 "$(run "${ARGS[@]}")"
check "arm 7  the SAME widening, declared, is MOVE-ONLY" 0 \
  "$(run "${ARGS[@]}" --allow-widen OverlayCapsuleBackground)"

check "arm 8  a missing destination file is BLOCKED" 2 \
  "$(run "${ARGS[@]}" --new "$T/nope.swift" --allow-widen OverlayCapsuleBackground)"

# The declared-deletion flag must not become a hole big enough to hide code in.
check "arm 9  a declared deletion covering CODE is BLOCKED" 2 "$(
  python3 scripts/verify-view-split.py --base "$BASE" --original "$SRC" \
    --drop-original-lines 38-60 "${ARGS[@]}" --allow-widen OverlayCapsuleBackground \
    >/dev/null 2>&1; echo $?)"

check "arm 10 a nonexistent base revision is BLOCKED" 2 "$(
  python3 scripts/verify-view-split.py --base deadbeefdeadbeef --original "$SRC" \
    "${ARGS[@]}" >/dev/null 2>&1; echo $?)"

# Arms 11 and 12 are a PAIR, and only the pair is evidence. The docstring claims the
# tool ignores blank lines; a reader can easily widen that in their head to "ignores
# whitespace", which is false and would let a reindent of moved code pass unreported.
# So one arm proves the blindness it claims and the other proves the blindness it does
# NOT claim. p430 is widened from arm 6 onward, so both carry --allow-widen.
cp "$T/p1084.swift" "$T/p1084.bak"
sed -i '' '5i\
' "$T/p1084.swift"
check "arm 11 a BLANK line added to a destination is MOVE-ONLY" 0 \
  "$(run "${ARGS[@]}" --allow-widen OverlayCapsuleBackground)"
mv "$T/p1084.bak" "$T/p1084.swift"

cp "$T/p1084.swift" "$T/p1084.bak"
sed -i '' '5s/^/  /' "$T/p1084.swift"
check "arm 12 INDENTING a non-blank line is CONTENT CHANGED" 1 \
  "$(run "${ARGS[@]}" --allow-widen OverlayCapsuleBackground)"
mv "$T/p1084.bak" "$T/p1084.swift"

echo
if [ "$FAIL" = 0 ]; then echo "ALL ARMS PASSED"; else echo "SOME ARMS FAILED"; fi
exit "$FAIL"
