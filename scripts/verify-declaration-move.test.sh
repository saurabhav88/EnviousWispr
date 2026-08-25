#!/usr/bin/env bash
# Two-way control for verify-declaration-move.py.
#
# A verifier that merely stops complaining is indistinguishable from one that was
# deleted. So every arm declares its own expectation in its own name:
#
#   - an arm whose name says the input is CLEAN must exit 0 with empty stderr;
#   - an arm whose name says a defect is CAUGHT must fail for its NAMED reason,
#     asserted on the message, never on the exit status alone. A generic failure
#     would pass a tool that rejects everything.
#
# **This header deliberately does NOT enumerate arm numbers.** It listed them
# twice and went stale both times, once per arm added — a count in prose that has
# to track code decays the moment someone appends. The rule above cannot.
#
# Asserts stderr is empty on every arm that should be silent, because a harness
# that does not read its own stderr reports a green it cannot see.
set -uo pipefail

TOOL="$(cd "$(dirname "$0")" && pwd)/verify-declaration-move.py"
PASS=0; FAIL=0
note() { printf '%s  %s\n' "$1" "$2"; }
ok()   { PASS=$((PASS+1)); note "PASS" "$1"; }
bad()  { FAIL=$((FAIL+1)); note "FAIL" "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

setup() {
  rm -rf "$WORK/repo"; mkdir -p "$WORK/repo/src"; cd "$WORK/repo"
  git init -q .; git config user.email t@t; git config user.name t
  cat > src/Original.swift <<'SWIFT'
import Foundation

/// Alpha does a thing.
struct Alpha: Equatable {
  let a: Int
}

/// Beta does another.
enum Beta {
  case one
}

/// Gamma is third.
struct Gamma {
  let g: String
}
SWIFT
  cat > src/Existing.swift <<'SWIFT'
import Foundation

struct AlreadyHere {
  let x: Int
  let y: String
}
SWIFT
  git add -A; git commit -qm base
  BASE="$(git rev-parse HEAD)"
}

# A correct move: Alpha+Gamma into a NEW file, Beta appended to an EXISTING file.
# Deliberately interleaved and into a non-empty destination — the two shapes the
# concatenation tool cannot handle.
do_clean_move() {
  cat > src/NewHome.swift <<'SWIFT'
import Foundation

/// Alpha does a thing.
struct Alpha: Equatable {
  let a: Int
}

/// Gamma is third.
struct Gamma {
  let g: String
}
SWIFT
  cat >> src/Existing.swift <<'SWIFT'

/// Beta does another.
enum Beta {
  case one
}
SWIFT
  rm src/Original.swift
}

run() { python3 "$TOOL" --base "$BASE" --original src/Original.swift \
          --dest src/NewHome.swift --dest src/Existing.swift 2>"$WORK/err"; }

# --- arm 1: the clean move passes ------------------------------------------
setup; do_clean_move
out="$(run)"; rc=$?
[ $rc -eq 0 ] && grep -q "VERDICT: MOVE-ONLY" <<<"$out" \
  && ok "arm 1 clean interleaved move into a non-empty destination -> MOVE-ONLY" \
  || bad "arm 1 expected MOVE-ONLY, rc=$rc"
[ -s "$WORK/err" ] && bad "arm 1 wrote to stderr: $(head -1 "$WORK/err")" || ok "arm 1 stderr empty"

# --- arm 2: an EDITED line is caught ---------------------------------------
setup; do_clean_move
/usr/bin/sed -i '' 's/let a: Int/let a: Int64/' src/NewHome.swift
out="$(run)"; rc=$?
[ $rc -eq 1 ] && [ ! -s "$WORK/err" ] && grep -q "VERDICT: CONTENT CHANGED" <<<"$out" \
  && ok "arm 2 edited line -> CONTENT CHANGED" || bad "arm 2 expected CONTENT CHANGED, rc=$rc"

# --- arm 3: a DROPPED declaration is caught --------------------------------
setup; do_clean_move
python3 - <<'PY'
import pathlib
p = pathlib.Path("src/NewHome.swift"); t = p.read_text()
p.write_text(t.split("/// Gamma is third.")[0])
PY
out="$(run)"; rc=$?
[ $rc -eq 1 ] && [ ! -s "$WORK/err" ] && grep -q "declarations missing     \['Gamma'\]" <<<"$out" \
  && ok "arm 3 dropped declaration -> named as missing" || bad "arm 3 expected Gamma missing, rc=$rc"

# --- arm 4: a DUPLICATED declaration is caught -----------------------------
setup; do_clean_move
cat >> src/Existing.swift <<'SWIFT'

/// Gamma is third.
struct Gamma {
  let g: String
}
SWIFT
out="$(run)"; rc=$?
[ $rc -eq 1 ] && [ ! -s "$WORK/err" ] && grep -q "declarations duplicated  \['Gamma'\]" <<<"$out" \
  && ok "arm 4 declaration in two destinations -> named as duplicated" || bad "arm 4 rc=$rc"

# --- arm 5: an ADDED line is caught ----------------------------------------
setup; do_clean_move
printf '\n/// smuggled in\n' >> src/NewHome.swift
out="$(run)"; rc=$?
[ $rc -eq 1 ] && [ ! -s "$WORK/err" ] && grep -q "lines only in new files  1" <<<"$out" \
  && ok "arm 5 added comment line -> reported as only in new files" || bad "arm 5 rc=$rc"

# --- arm 6: a SURVIVING original is caught ---------------------------------
setup; do_clean_move
git checkout -q -- src/Original.swift
run >/dev/null 2>"$WORK/err"; rc=$?
[ $rc -eq 2 ] && grep -q "still exists in the working tree" "$WORK/err" \
  && ok "arm 6 original left behind -> refuses (a move that leaves a copy)" || bad "arm 6 rc=$rc"

# --- arm 7: a destination that LOST a pre-existing line is caught -----------
setup; do_clean_move
/usr/bin/sed -i '' '/let x: Int/d' src/Existing.swift
run >/dev/null 2>"$WORK/err"; rc=$?
[ $rc -eq 2 ] && grep -q "LOST 1 pre-existing line" "$WORK/err" \
  && ok "arm 7 destination lost its own content -> refuses" || bad "arm 7 rc=$rc"

# --- arm 8: blank-line churn is DELIBERATELY tolerated ----------------------
setup; do_clean_move
printf '\n\n' >> src/NewHome.swift
out="$(run)"; rc=$?
[ $rc -eq 0 ] && [ ! -s "$WORK/err" ] && grep -q "VERDICT: MOVE-ONLY" <<<"$out" \
  && ok "arm 8 blank lines tolerated -> MOVE-ONLY, stderr empty (stated limit)" \
  || bad "arm 8 blank lines should not fail, rc=$rc"

# --- arm 9: a line that changed OWNER is caught ------------------------------
# The defect review found in #2375 C1a: a section header travelled with the wrong
# neighbour. Every line is still present exactly once, so checks 1 and 2 pass and
# ONLY the per-declaration comparison can see it.
setup; do_clean_move
python3 - <<'PY2'
import pathlib
p = pathlib.Path("src/NewHome.swift"); t = p.read_text()
# move Alpha's doc comment onto Gamma: no line added, none lost, owner changed
t = t.replace("/// Alpha does a thing.\n", "", 1)
t = t.replace("/// Gamma is third.\n", "/// Alpha does a thing.\n/// Gamma is third.\n", 1)
p.write_text(t)
PY2
out="$(run)"; rc=$?
[ $rc -eq 1 ] && [ ! -s "$WORK/err" ] && grep -q "declarations reassigned" <<<"$out" && grep -qE "reassigned  \['(Alpha|Gamma)'" <<<"$out" \
  && ok "arm 9 comment line changed OWNER -> reassigned (multiset alone cannot see this)" \
  || bad "arm 9 expected a reassignment finding, rc=$rc"

# --- arm 10: a pre-existing destination is never silently treated as NEW ------
# `git show base:path or ""` would have called a failed read a new file, which is
# the permissive direction. This arm points a destination at a path that was a
# TREE at base and is a FILE now, and requires a fail-closed refusal.
#
# **Stated limit, because a faked control is worse than a named gap:** `git show`
# on a tree SUCCEEDS and returns a listing, so this arm exercises the
# pre-existing-content branch, NOT the `exists but could not be read` branch. That
# branch guards a corrupt or unreadable object and is not exercised by any arm
# here. It is one line and it fails closed by construction; nothing in this suite
# proves it fires.
rm -rf "$WORK/repo"; mkdir -p "$WORK/repo/src/thing"; cd "$WORK/repo"
git init -q .; git config user.email t@t; git config user.name t
cat > src/Original.swift <<'SWIFT'
import Foundation

/// Alpha does a thing.
struct Alpha {
  let a: Int
}
SWIFT
echo "// placeholder" > src/thing/keep.swift
git add -A; git commit -qm base
BASE="$(git rev-parse HEAD)"
rm -rf src/thing
cat > src/thing <<'SWIFT'
import Foundation

/// Alpha does a thing.
struct Alpha {
  let a: Int
}
SWIFT
rm src/Original.swift
python3 "$TOOL" --base "$BASE" --original src/Original.swift --dest src/thing \
  >/dev/null 2>"$WORK/err"; rc=$?
[ $rc -eq 2 ] && grep -qE "LOST [0-9]+ pre-existing line" "$WORK/err" \
  && ok "arm 10 pre-existing destination refused fail-closed, never treated as new" \
  || bad "arm 10 expected a fail-closed refusal, rc=$rc, err=$(head -1 "$WORK/err")"

# --- arm 11: a REORDER inside a PRE-EXISTING declaration is caught ------------
# Adds nothing and removes nothing, so line conservation, the LOST check and the
# gained-declaration comparison all stay green. Only comparing the pre-existing
# declaration's own ordered lines against base can see it.
setup; do_clean_move
python3 - <<'PY3'
import pathlib
p = pathlib.Path("src/Existing.swift"); t = p.read_text()
t = t.replace("  let x: Int\n  let y: String\n", "  let y: String\n  let x: Int\n", 1)
p.write_text(t)
PY3
run >/dev/null 2>"$WORK/err"; rc=$?
[ $rc -eq 2 ] && grep -q "changed pre-existing declaration(s): AlreadyHere" "$WORK/err" \
  && ok "arm 11 reorder inside a pre-existing declaration -> refuses" \
  || bad "arm 11 expected a pre-existing-declaration refusal, rc=$rc, err=$(head -1 "$WORK/err")"

# --- arms 12-13: --allow-widen, which NO arm exercised until review said so ----
# A file split forces a file-private type to widen to internal, which is the one
# difference this tool is allowed to forgive. Both arms are needed: the permitted
# widening must PASS, and an UNLISTED one must still fail, or "forgive" would mean
# "ignore".
widen_setup() {
  rm -rf "$WORK/repo"; mkdir -p "$WORK/repo/src"; cd "$WORK/repo"
  git init -q .; git config user.email t@t; git config user.name t
  cat > src/Original.swift <<'SWIFT'
import Foundation

private struct Helper {
  let h: Int
}

private actor Worker {
  var n = 0
}
SWIFT
  git add -A; git commit -qm base
  BASE="$(git rev-parse HEAD)"
  cat > src/Moved.swift <<'SWIFT'
import Foundation

struct Helper {
  let h: Int
}

actor Worker {
  var n = 0
}
SWIFT
  rm src/Original.swift
}

widen_setup
python3 "$TOOL" --base "$BASE" --original src/Original.swift --dest src/Moved.swift \
  --allow-widen Helper --allow-widen Worker >"$WORK/out" 2>"$WORK/err"; rc=$?
[ $rc -eq 0 ] && [ ! -s "$WORK/err" ] && grep -q "VERDICT: MOVE-ONLY" "$WORK/out" \
  && ok "arm 12 permitted widening on a struct AND an actor -> MOVE-ONLY, stderr empty" \
  || bad "arm 12 expected MOVE-ONLY, rc=$rc, $(head -1 "$WORK/err")"

widen_setup
python3 "$TOOL" --base "$BASE" --original src/Original.swift --dest src/Moved.swift \
  --allow-widen Helper >"$WORK/out" 2>"$WORK/err"; rc=$?
[ $rc -eq 1 ] && [ ! -s "$WORK/err" ] && grep -q "VERDICT: CONTENT CHANGED" "$WORK/out" \
  && grep -q "only in original:  private actor Worker" "$WORK/out" \
  && grep -q "only in new files: actor Worker" "$WORK/out" \
  && ok "arm 13 UNLISTED actor widening fails NAMING the actor -> forgive is not ignore" \
  || bad "arm 13 expected CONTENT CHANGED, rc=$rc"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
