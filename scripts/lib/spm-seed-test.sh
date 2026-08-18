#!/usr/bin/env bash
# scripts/lib/spm-seed-test.sh — two-way test for seed publish/consume
# (#2157 chunk A).
#
# THE CORRUPT-SNAPSHOT CASE IS THE ONE THAT MATTERS, AND IT IS EASY TO FAKE.
# "Resolution succeeded" is NOT evidence the fallback worked — that is exactly
# what happens when the seed is ignored entirely. So every fallback case here
# asserts the OBSERVABLE CONSEQUENCE: the target was removed, or never created,
# and the reason was announced. A case that merely checks "the build would still
# work" would pass against a function whose body was deleted.
#
# Runs entirely against temporary directories with fake SourcePackages trees.
# No xcodebuild, no network, no real cache.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0; TMPROOT=""

cleanup() { [ -n "$TMPROOT" ] && [ -d "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s — %s\n' "$1" "$2"; }

TMPROOT="$(mktemp -d /tmp/ew-seed-XXXXXX)"
export EW_SEED_ROOT="$TMPROOT/spm-seed"
export EW_TUIST_PIN="tuist@4.195.11"
# shellcheck source=scripts/lib/spm-seed.sh
. "$HERE/spm-seed.sh"

ROOT="$TMPROOT/checkout"
mkdir -p "$ROOT"
printf '{"pins":[]}\n' > "$ROOT/Package.resolved"

# A tree shaped like a resolved SourcePackages.
DONOR_PREFIX="/Users/nobody/Developer/DonorTree/.derivedData/Test/SourcePackages"
make_tree() { # <path>
  mkdir -p "$1/artifacts/sentry-cocoa" "$1/checkouts/pkg/.git/objects/info" "$1/repositories"
  # Shaped like a REAL resolved tree: the index plus a git checkout whose object
  # store is an absolute path into the donor. The `.git` half is what the shell's
  # ugrep shim cannot see, and it is the half that breaks a build.
  printf '{"object":{"artifacts":[{"path":"%s/artifacts/sentry-cocoa/Sentry.xcframework"}]}}\n' "$DONOR_PREFIX" > "$1/workspace-state.json"
  printf '%s/repositories/pkg-0000/objects\n' "$DONOR_PREFIX" > "$1/checkouts/pkg/.git/objects/info/alternates"
  printf 'artifact\n' > "$1/artifacts/sentry-cocoa/Sentry.xcframework"
  printf 'checkout\n' > "$1/checkouts/marker"
}

KEY="$(ew_seed_key "$ROOT")"
if [ -n "$KEY" ]; then ok "composite key computes"; else bad "key" "empty"; fi

# The key must change with the LOCKFILE and with the TOOLCHAIN pin. If it did
# not, a stale seed would be served after an upgrade.
printf '{"pins":["x"]}\n' > "$ROOT/Package.resolved"
K2="$(ew_seed_key "$ROOT")"
if [ "$K2" != "$KEY" ]; then ok "key changes when Package.resolved changes"; else bad "key/lockfile" "unchanged"; fi
printf '{"pins":[]}\n' > "$ROOT/Package.resolved"

EW_TUIST_PIN="tuist@9.9.9"
K3="$(ew_seed_key "$ROOT")"
EW_TUIST_PIN="tuist@4.195.11"
if [ "$K3" != "$KEY" ]; then ok "key changes when the Tuist pin changes"; else bad "key/toolchain" "unchanged"; fi
if [ "$(ew_seed_key "$ROOT")" = "$KEY" ]; then ok "key is stable for identical inputs"; else bad "key stability" "differs across calls"; fi

# THE KEY MUST NOT DEPEND ON THE CHECKOUT PATH. Sharing across checkouts IS the
# saving — ten worktrees resolving the same lockfile should hit one snapshot.
# The first implementation used `shasum -a 256 <file>`, whose output embeds the
# PATH, so every checkout produced a different key and the cache never hit.
# The unit tests could not see it: they used one root throughout. Only the
# real-tool run across two checkouts exposed it, which is why this case exists.
ROOT_B="$TMPROOT/checkout-elsewhere/deeper/still"
mkdir -p "$ROOT_B"
cp "$ROOT/Package.resolved" "$ROOT_B/Package.resolved"
if [ "$(ew_seed_key "$ROOT_B")" = "$KEY" ]; then
  ok "key is IDENTICAL for the same lockfile at a different checkout path"
else
  bad "key path-independence" "same lockfile, different path, different key — the cache would never hit"
fi

# THE SDK VERSION MUST BE IN THE KEY. A seed carries toolchain-shaped artifacts,
# so serving one across an SDK change is exactly the stale-cache failure the
# composite key exists to prevent. Named by the chunk gate as a mutation that
# survived all 29 assertions: deleting the SDK line left every test green,
# because nothing varied it. `xcrun` is stubbed rather than the SDK changed.
xcrun() { printf 'stubbed-sdk-99.9\n'; }
K_SDK="$(ew_seed_key "$ROOT")"
unset -f xcrun
if [ "$K_SDK" != "$KEY" ]; then
  ok "key changes when the macOS SDK version changes"
else
  bad "key/SDK" "SDK version is not in the key — a seed would survive an Xcode upgrade"
fi

# Likewise the Xcode version itself.
xcodebuild() { printf 'Xcode 99.9\nBuild version ZZZ\n'; }
K_XC="$(ew_seed_key "$ROOT")"
unset -f xcodebuild
if [ "$K_XC" != "$KEY" ]; then
  ok "key changes when the Xcode version changes"
else
  bad "key/Xcode" "Xcode version is not in the key"
fi

# --- consume with NO snapshot: must not create anything ------------------------
DD1="$TMPROOT/dd1"
out="$(ew_seed_consume "$ROOT" "$DD1" 2>&1)"
if [ ! -e "$DD1/SourcePackages" ] && printf '%s' "$out" | grep -q "no seed snapshot"; then
  ok "no snapshot: creates nothing and SAYS why"
else
  bad "no-snapshot path" "target=$([ -e "$DD1/SourcePackages" ] && echo exists || echo absent) out='$out'"
fi

# --- publish, then consume -----------------------------------------------------
DD2="$TMPROOT/dd2"; mkdir -p "$DD2"; make_tree "$DD2/SourcePackages"
out="$(ew_seed_publish "$ROOT" "$DD2" 2>&1)"
if ew_seed_is_complete "$(ew_seed_dir "$KEY")"; then ok "publish creates a complete snapshot"; else bad "publish" "snapshot incomplete: $out"; fi
staging_found=0
for _s in "$EW_SEED_ROOT/$KEY"/.staging.*; do
  [ -e "$_s" ] && staging_found=1
done
if [ "$staging_found" -eq 0 ]; then
  ok "publish leaves no staging directory behind"
else
  bad "publish staging" "staging survived"
fi

DD3="$TMPROOT/dd3"
out="$(ew_seed_consume "$ROOT" "$DD3" 2>&1)"
# The EXPENSIVE payload must arrive; `ew_seed_is_complete` is deliberately NOT
# the assertion here, because a consumed tree no longer carries the state file
# that check uses as its marker. Assert the content instead.
if [ -d "$DD3/SourcePackages/artifacts" ] && [ -n "$(ls -A "$DD3/SourcePackages/artifacts" 2>/dev/null)" ] \
   && [ -d "$DD3/SourcePackages/checkouts" ] && printf '%s' "$out" | grep -q "Seeded packages"; then
  ok "consume clones the snapshot's payload into an absent target"
else
  bad "consume" "target missing payload or unannounced: '$out'"
fi

# THE #2178 REGRESSION. `workspace-state.json` is an INDEX holding ABSOLUTE paths
# baked to the worktree that produced the snapshot. Cloned verbatim it names
# another tree's directories — or, once that worktree is deleted, directories that
# exist nowhere — and the failure is NOT the slow path this file promises
# everywhere else: the clone succeeds, the resolve succeeds, and `xcodebuild` then
# dies with `There is no XCFramework found at <other worktree>/...`, a hard
# TEST FAILED with zero failing tests, accusing a dependency.
#
# TWO-WAY, because "absent" alone would also pass against a clone that copied
# nothing at all: the donor's file must be PRESENT in the snapshot and ABSENT
# from the consumed tree.
if [ -f "$(ew_seed_dir "$KEY")/workspace-state.json" ]; then
  ok "the snapshot still carries its own state file (its completeness marker)"
else
  bad "snapshot state" "publish dropped workspace-state.json; ew_seed_is_complete can no longer judge a snapshot"
fi
# THE DONOR NEED NOT LIVE UNDER /Users, AND ITS PATH NEED NOT LOOK LIKE
# `.derivedData/<lane>`. Releases build from `/tmp`, and `xcode-test.sh` honours a
# `DERIVED_DATA_PATH` override naming any path at all. A location-shaped
# discovery finds nothing for those, returns 1, and every consumer silently falls
# back to a full resolve — a feature that has stopped working, wearing the face of
# one that works.
ODD="/var/folders/zz/Odd Place/build-out/SourcePackages"
T_ODD="$TMPROOT/odd"; mkdir -p "$T_ODD/artifacts/x" "$T_ODD/checkouts/pkg/.git/objects/info"
printf '{"object":{"artifacts":[{"path":"%s/artifacts/x/A.xcframework"}]}}\n' "$ODD" > "$T_ODD/workspace-state.json"
printf '%s/repositories/pkg-0000/objects\n' "$ODD" > "$T_ODD/checkouts/pkg/.git/objects/info/alternates"
printf 'a\n' > "$T_ODD/artifacts/x/A.xcframework"
if ew_seed_localise "$T_ODD" "/final/here/SourcePackages" \
   && ! /usr/bin/grep -rq "Odd Place" "$T_ODD" 2>/dev/null \
   && /usr/bin/grep -rq "/final/here/SourcePackages" "$T_ODD" 2>/dev/null; then
  ok "a donor outside /Users, with no .derivedData in its path, is still localised"
else
  bad "donor discovery shape" "a donor not shaped like /Users/.../.derivedData/<lane> was not rewritten"
fi

# A REWRITTEN PATH MUST RESOLVE, NOT MERELY STOP NAMING THE DONOR. A string sweep
# passes perfectly against a plausible-but-non-existent directory, and git only
# discovers it the first time it needs an object — the valid-looking-default trap,
# one directory over. An independent verifier ran this against the real fix and it
# is the check neither of us would have written without `alternates` being found.
alt="$T_ODD/checkouts/pkg/.git/objects/info/alternates"
target="$(cat "$alt" 2>/dev/null)"
case "$target" in
  /final/here/SourcePackages/repositories/*) ok "the rewritten object store points where the payload actually lands" ;;
  *) bad "alternates target" "rewritten to '$target', which is not under the receiving tree's repositories/" ;;
esac

# THE TWIN: a tree with nothing to discover must FAIL, not silently pass. Without
# this, the case above would also pass against a localise that returns 0 for
# everything.
T_NONE="$TMPROOT/nodonor"; mkdir -p "$T_NONE"
printf '{"object":{}}\n' > "$T_NONE/workspace-state.json"
if ew_seed_localise "$T_NONE" "/final/here/SourcePackages"; then
  bad "donor discovery twin" "localise returned 0 with no donor to find; a clone would be accepted unrewritten"
else
  ok "an undiscoverable donor FAILS localisation, so the caller drops the clone"
fi

if [ -f "$DD3/SourcePackages/workspace-state.json" ] \
   && ! /usr/bin/grep -rq "$DONOR_PREFIX" "$DD3/SourcePackages" 2>/dev/null \
   && /usr/bin/grep -q "$DD3/SourcePackages" "$DD3/SourcePackages/workspace-state.json" 2>/dev/null; then
  ok "#2178: every donor path is rewritten to the consuming tree"
else
  bad "#2178 donor path leak" "consumed tree still names the donor, or was not rewritten to its own path"
fi

# The REAL clone must leave the provenance marker, naming the key it came from.
# Every other provenance case below fabricates the marker by hand, so without
# this one a mutation deleting the write survives untouched — which is exactly
# what happened on the first mutation run.
if [ "$(cat "$DD3/SourcePackages/$EW_SEED_PROVENANCE_FILE" 2>/dev/null)" = "$KEY" ]; then
  ok "a real clone records its provenance, naming the snapshot key"
else
  bad "provenance write" "marker missing or wrong: '$(cat "$DD3/SourcePackages/$EW_SEED_PROVENANCE_FILE" 2>/dev/null)' vs key '$KEY'"
fi

# --- consume sweeps ITS OWN key's orphaned staging, and only its own -----------
# A SIGKILL leaves a consumer staging copy behind with no handler to remove it,
# and each is a full 3.6 GB. Consume sweeps them under the key's lock. The
# SECOND half of this case is the one that binds: a sweep that removed every
# `.SourcePackages.seed.*` would pass the first assertion while deleting a
# CONCURRENT consumer's in-flight copy for a different key. Only a pair of an
# accepted and a rejected input shows the boundary is real.
DD9="$TMPROOT/dd9"; mkdir -p "$DD9"
SWEEPKEY="$(ew_seed_key "$ROOT")"
mkdir -p "$DD9/.SourcePackages.seed.$SWEEPKEY.orphan" "$DD9/.SourcePackages.seed.otherkey.orphan"
printf 'stale\n' > "$DD9/.SourcePackages.seed.$SWEEPKEY.orphan/marker"
printf 'in-flight\n' > "$DD9/.SourcePackages.seed.otherkey.orphan/marker"
ew_seed_consume "$ROOT" "$DD9" >/dev/null 2>&1
if [ ! -e "$DD9/.SourcePackages.seed.$SWEEPKEY.orphan" ]; then
  ok "consume removes orphaned staging for ITS OWN key"
else
  bad "staging sweep" "same-key orphan survived consume"
fi
if [ -f "$DD9/.SourcePackages.seed.otherkey.orphan/marker" ]; then
  ok "consume leaves ANOTHER key's staging untouched (the twin)"
else
  bad "staging sweep scope" "consume deleted staging belonging to a different key"
fi

# --- consume must NOT overwrite an existing tree -------------------------------
DD4="$TMPROOT/dd4"; mkdir -p "$DD4/SourcePackages"
printf 'MINE\n' > "$DD4/SourcePackages/marker"
ew_seed_consume "$ROOT" "$DD4" >/dev/null 2>&1
if [ "$(cat "$DD4/SourcePackages/marker" 2>/dev/null)" = "MINE" ]; then
  ok "consume never overwrites an existing SourcePackages"
else
  bad "consume overwrite" "clobbered a pre-existing tree"
fi

# --- republish is a no-op ------------------------------------------------------
before="$(ls -la "$(ew_seed_dir "$KEY")/workspace-state.json" 2>/dev/null)"
ew_seed_publish "$ROOT" "$DD2" >/dev/null 2>&1
after="$(ls -la "$(ew_seed_dir "$KEY")/workspace-state.json" 2>/dev/null)"
if [ "$before" = "$after" ]; then ok "publishing again does not rewrite an existing snapshot"; else bad "republish" "snapshot was rewritten"; fi

# --- publish REFUSES an incomplete source --------------------------------------
printf '{"pins":["other"]}\n' > "$ROOT/Package.resolved"
KEY_B="$(ew_seed_key "$ROOT")"
DD5="$TMPROOT/dd5"; mkdir -p "$DD5/SourcePackages/artifacts"
printf '{}\n' > "$DD5/SourcePackages/workspace-state.json"   # artifacts/ EMPTY
ew_seed_publish "$ROOT" "$DD5" >/dev/null 2>&1
if [ ! -d "$(ew_seed_dir "$KEY_B")" ]; then
  ok "publish REFUSES a source whose artifacts/ is empty (half-resolved)"
else
  bad "publish incomplete" "published a half-resolved tree"
fi

# --- consume REFUSES a corrupt snapshot, and removes nothing of ours -----------
# The dangerous case: a snapshot that exists but is not complete must not be
# cloned, and must not leave a partial target behind.
mkdir -p "$(ew_seed_dir "$KEY_B")/artifacts"
printf '{}\n' > "$(ew_seed_dir "$KEY_B")/workspace-state.json"   # artifacts/ empty
DD6="$TMPROOT/dd6"
out="$(ew_seed_consume "$ROOT" "$DD6" 2>&1)"
if [ ! -e "$DD6/SourcePackages" ] && printf '%s' "$out" | grep -q "no seed snapshot"; then
  ok "consume REFUSES a corrupt snapshot and leaves no partial target"
else
  bad "corrupt snapshot" "target=$([ -e "$DD6/SourcePackages" ] && echo exists || echo absent) out='$out'"
fi
printf '{"pins":[]}\n' > "$ROOT/Package.resolved"

# Consume stages then renames, so no `.SourcePackages.seed.*` may survive. A
# direct copy into the final target would let an interrupted run leave a partial
# tree that the next run ACCEPTS — silent corruption.
seed_staging=0
for _s in "$TMPROOT"/dd3/.SourcePackages.seed.*; do
  [ -e "$_s" ] && seed_staging=1
done
if [ "$seed_staging" -eq 0 ]; then
  ok "consume leaves no staging directory behind"
else
  bad "consume staging" "staging survived"
fi

# --- a held lock makes consume a cache MISS, never a failure -------------------
ew_seed_lock_acquire "$KEY" >/dev/null 2>&1
DD7="$TMPROOT/dd7"
out="$(ew_seed_consume "$ROOT" "$DD7" 2>&1)"; rc=$?
ew_seed_lock_release "$KEY"
if [ "$rc" -eq 0 ] && [ ! -e "$DD7/SourcePackages" ] && printf '%s' "$out" | grep -q "seed busy"; then
  ok "a HELD lock is a cache miss (exit 0, nothing created, reason announced)"
else
  bad "lock contention" "rc=$rc target=$([ -e "$DD7/SourcePackages" ] && echo exists || echo absent) out='$out'"
fi

# --- nothing here may ever fail a build ----------------------------------------
DD8="/nonexistent-volume-xyz/dd8"
ew_seed_consume "$ROOT" "$DD8" >/dev/null 2>&1; rc_c=$?
ew_seed_publish "$ROOT" "$DD8" >/dev/null 2>&1; rc_p=$?
if [ "$rc_c" -eq 0 ] && [ "$rc_p" -eq 0 ]; then
  ok "an unwritable destination still returns success (never fails a build)"
else
  bad "never fail a build" "consume=$rc_c publish=$rc_p"
fi

# --- ATOMIC EXCLUSIVE RENAME --------------------------------------------------
# `[ ! -e "$dst" ] && mv` is racy: if $dst appears between the test and the
# rename, `mv` moves $src INSIDE $dst and produces a nested half-valid tree that
# still passes a presence check. RENAME_EXCL refuses at the syscall, so there is
# no window and nothing to undo.
#
# An earlier detect-then-undo version was refused by review and correctly: the
# winner can OBSERVE the nested tree before the undo runs, and if both the
# backout and its fallback fail, the nested directory is left inside the winner's
# tree with nothing reporting it. These cases assert the destination is NEVER
# touched, which is the property undo could not provide.
RACE="$TMPROOT/race"; mkdir -p "$RACE/src" "$RACE/dst"
printf 'staged\n' > "$RACE/src/marker"
printf 'THEIRS\n' > "$RACE/dst/marker"
if ew_seed_rename_exclusive "$RACE/src" "$RACE/dst"; then
  bad "exclusive rename" "reported success against an existing destination"
else
  ok "rename REFUSES an existing destination (no nesting window)"
fi
if [ ! -e "$RACE/dst/src" ] && [ "$(cat "$RACE/dst/marker" 2>/dev/null)" = "THEIRS" ]; then
  ok "the destination is NEVER mutated — nothing nested, winner's data intact"
else
  bad "destination integrity" "destination was modified by a refused rename"
fi
if [ -d "$RACE/src" ] && [ -f "$RACE/src/marker" ]; then
  ok "the source survives a refused rename (caller can clean it up)"
else
  bad "source integrity" "source was consumed by a refused rename"
fi

# The positive twin. Without it, a helper that always returns 1 — including one
# whose python is missing — would pass every case above.
RACE2="$TMPROOT/race2"; mkdir -p "$RACE2/src"
printf 'staged\n' > "$RACE2/src/marker"
if ew_seed_rename_exclusive "$RACE2/src" "$RACE2/dst" && [ -f "$RACE2/dst/marker" ] && [ ! -e "$RACE2/src" ]; then
  ok "rename SUCCEEDS into an absent destination (the twin)"
else
  bad "rename positive case" "failed to move into an absent destination"
fi

# Every helper failure must be a CACHE MISS, never an error. This is the property
# that makes the python dependency acceptable at all.
if ew_seed_rename_exclusive "$TMPROOT/does-not-exist" "$TMPROOT/nowhere"; then
  bad "missing source" "reported success for a source that does not exist"
else
  ok "a missing source returns failure (callers treat it as a cache miss)"
fi


# The helper must return EXACTLY 1 on failure, never the interpreter's own exit
# status. A wrapper or launcher exiting 42 — or a missing interpreter exiting
# 127 — used to propagate straight through, which made the documented contract
# false even though every caller happened to treat any nonzero as a cache miss.
# A comment nobody can rely on is the kind of claim the next reader builds on.
FAKEBIN="$TMPROOT/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\nexit 42\n' > "$FAKEBIN/python3"; chmod +x "$FAKEBIN/python3"
( PATH="$FAKEBIN:$PATH"; ew_seed_rename_exclusive "$TMPROOT/a" "$TMPROOT/b" ); rc_norm=$?
if [ "$rc_norm" -eq 1 ]; then
  ok "an interpreter exiting 42 is normalised to exactly 1"
else
  bad "return contract" "expected 1, got $rc_norm (the interpreter status leaked)"
fi

# --- ATOMICITY UNDER A REAL RACE ----------------------------------------------
# The cases above verify the CONTRACT (refuses existing, succeeds absent, never
# mutates) and CANNOT distinguish an atomic rename from `[ ! -e ] && mv`, because
# a single-threaded test cannot open the window between the check and the move.
# Confirmed by mutation: the racy form passes every case above.
#
# Atomicity is only observable under a real race, so this races N processes into
# ONE destination and asserts exactly one winner and zero nested directories.
# With the racy form, a loser that passes its check before the winner's move
# lands nests inside the destination.
RACE3="$TMPROOT/race3"; mkdir -p "$RACE3"
racers=24
for i in $(seq 1 "$racers"); do
  mkdir -p "$RACE3/src.$i"
  printf 'from %s\n' "$i" > "$RACE3/src.$i/marker"
done
mkdir -p "$RACE3/done"
for i in $(seq 1 "$racers"); do
  (
    if ew_seed_rename_exclusive "$RACE3/src.$i" "$RACE3/dst"; then
      printf '%s\n' "$i" >> "$RACE3/winners"
    fi
    # Written on BOTH paths, AFTER the helper returns. Bare `wait` proves only
    # that the jobs which STARTED have finished — if 23 of the 24 never launch,
    # "exactly one winner and zero nested" is still true and the race never
    # happened. A completion count is the only thing that separates "24 racers,
    # one winner" from "1 racer, one winner", and those are the two readings the
    # assertions below cannot tell apart.
    : > "$RACE3/done/$i"
  ) >/dev/null 2>&1 &
done
wait

completed=0
for _d in "$RACE3/done"/*; do
  [ -e "$_d" ] && completed=$((completed + 1))
done
if [ "$completed" -eq "$racers" ]; then
  ok "all $racers racers actually ran (the race is not vacuous)"
else
  bad "race completion" "expected $racers completions, got $completed"
fi

winner_count="$(wc -l < "$RACE3/winners" 2>/dev/null | tr -d ' ')"
[ -n "$winner_count" ] || winner_count=0
nested_count=0
for _n in "$RACE3/dst"/src.*; do
  [ -e "$_n" ] && nested_count=$((nested_count + 1))
done

if [ "$winner_count" = "1" ]; then
  ok "exactly ONE of $racers concurrent renames wins"
else
  bad "concurrent winners" "expected exactly 1 winner, got $winner_count"
fi
if [ "$nested_count" -eq 0 ]; then
  ok "NO loser nested inside the destination under a real $racers-way race"
else
  bad "concurrent nesting" "$nested_count loser(s) nested inside the destination"
fi
if [ -f "$RACE3/dst/marker" ]; then
  ok "the destination holds exactly the winner's content"
else
  bad "race destination" "destination is not a valid moved tree"
fi

# --- staging is cleaned by the SAME handler as the locks ----------------------
# A TERM that releases the lock but leaves a staging copy has half-cleaned.
STAGE="$TMPROOT/stagecheck"; mkdir -p "$STAGE"
ew_seed_track_temp "$STAGE/.SourcePackages.seed.999"
mkdir -p "$STAGE/.SourcePackages.seed.999"
ew_seed_lock_acquire "stagekey" >/dev/null 2>&1
ew_seed_release_all
if [ ! -e "$STAGE/.SourcePackages.seed.999" ]; then
  ok "release_all removes tracked staging directories, not just locks"
else
  bad "staging cleanup" "staging survived release_all"
fi

# --- a seeded tree that will not resolve is DISCARDED and retried unseeded -----
# The completeness check is shallow on purpose, so something has to catch what it
# misses. Without this, a damaged clone kills the build under `set -e` and STAYS
# in DerivedData, so every later run hits the identical wall.
# The fake resolver records each call and reports whether SourcePackages existed
# at that moment — which is the only way to tell "it retried" from "it retried
# against the same bad tree".
FB="$TMPROOT/fallback"; mkdir -p "$FB"
fake_resolve() {
  if [ -e "$FB/SourcePackages" ]; then printf 'seeded\n' >> "$FB/calls"; else printf 'unseeded\n' >> "$FB/calls"; fi
  [ -e "$FB/fail-while-seeded" ] && [ -e "$FB/SourcePackages" ] && return 1
  return 0
}

mkdir -p "$FB/SourcePackages"; printf 'bad\n' > "$FB/SourcePackages/marker"
: > "$FB/fail-while-seeded"; : > "$FB/calls"
EW_SEED_CONSUMED=1
ew_seed_resolve_or_unseed "$FB" fake_resolve; fb_rc=$?
fb_calls="$(tr '\n' ',' < "$FB/calls")"
if [ "$fb_rc" -eq 0 ] && [ "$fb_calls" = "seeded,unseeded," ] && [ ! -e "$FB/SourcePackages" ]; then
  ok "a seeded tree that fails to resolve is discarded and the retry runs UNSEEDED"
else
  bad "unseed fallback" "rc=$fb_rc calls='$fb_calls' tree_present=$([ -e "$FB/SourcePackages" ] && echo yes || echo no)"
fi

# THE TWIN, and it is the half that binds: a tree this process did NOT seed is
# somebody else's, and a resolve failure against it must propagate untouched. A
# fallback that discarded any failing tree would delete a developer's own
# DerivedData on an ordinary network failure.
rm -rf "$FB/SourcePackages"; mkdir -p "$FB/SourcePackages"; printf 'theirs\n' > "$FB/SourcePackages/marker"
: > "$FB/calls"
EW_SEED_CONSUMED=0
ew_seed_resolve_or_unseed "$FB" fake_resolve; fb_rc=$?
if [ "$fb_rc" -eq 0 ] && [ ! -s "$FB/calls" ] && [ "$(cat "$FB/SourcePackages/marker" 2>/dev/null)" = "theirs" ]; then
  ok "an UNSEEDED tree is never resolved, retried, or deleted by the fallback (the twin)"
else
  bad "unseed fallback scope" "rc=$fb_rc calls='$(tr '\n' ',' < "$FB/calls")' marker=$(cat "$FB/SourcePackages/marker" 2>/dev/null)"
fi

# A seeded tree that resolves FIRST TIME must not be touched, and must cost
# exactly one resolve. A fallback that retried on success would double the
# resolve it exists to save.
rm -f "$FB/fail-while-seeded"; : > "$FB/calls"
EW_SEED_CONSUMED=1
ew_seed_resolve_or_unseed "$FB" fake_resolve; fb_rc=$?
if [ "$fb_rc" -eq 0 ] && [ "$(wc -l < "$FB/calls" | tr -d ' ')" = "1" ] && [ -f "$FB/SourcePackages/marker" ]; then
  ok "a seeded tree that resolves first time is kept, and costs exactly one resolve"
else
  bad "unseed fallback happy path" "rc=$fb_rc calls=$(wc -l < "$FB/calls" | tr -d ' ')"
fi

# A SECOND failure is a real failure and must propagate: at that point the tree is
# already gone, so the problem is not the seed and swallowing it would report a
# successful resolve for a build that cannot link.
rm -rf "$FB/SourcePackages"; mkdir -p "$FB/SourcePackages"
: > "$FB/fail-while-seeded"; : > "$FB/calls"
always_fail() { printf 'call\n' >> "$FB/calls"; return 7; }
EW_SEED_CONSUMED=1
ew_seed_resolve_or_unseed "$FB" always_fail; fb_rc=$?
if [ "$fb_rc" -ne 0 ] && [ "$(wc -l < "$FB/calls" | tr -d ' ')" = "2" ]; then
  ok "a failure that survives the unseeded retry PROPAGATES (exit $fb_rc), after exactly 2 attempts"
else
  bad "unseed fallback propagation" "rc=$fb_rc calls=$(wc -l < "$FB/calls" | tr -d ' ')"
fi
EW_SEED_CONSUMED=0

# --- a clone that was never validated is recognised by a LATER process --------
# `EW_SEED_CONSUMED` is a variable in ONE process and the dangerous window spans
# two: a seeded run interrupted DURING validation leaves the tree behind,
# possibly half-validated, and the next process took consume's early return with
# the fallback disarmed. The tree was then trusted forever and every build failed
# the same way until somebody deleted DerivedData by hand.
PROV="$TMPROOT/prov"; mkdir -p "$PROV"
make_tree "$PROV/SourcePackages"
printf 'somekey\n' > "$PROV/SourcePackages/$EW_SEED_PROVENANCE_FILE"
EW_SEED_CONSUMED=0
# REDIRECT TO A FILE, never `out="$(...)"`. A command substitution runs the
# function in a SUBSHELL, so the variable it sets never reaches the assertion and
# the case fails while the code is correct. Caught on the first run here; the
# same class of harness-alters-the-subject defect produced a vacuous test and a
# wrong measurement earlier in this branch, both times through `eval`. Ask of any
# assertion on a side effect whether the harness put the subject in a subshell.
ew_seed_consume "$ROOT" "$PROV" > "$TMPROOT/prov.out" 2>&1
out="$(cat "$TMPROOT/prov.out")"
if [ "$EW_SEED_CONSUMED" = "1" ] && printf '%s' "$out" | grep -q "earlier run"; then
  ok "an existing tree carrying the marker ARMS the fallback in a later process"
else
  bad "provenance carry-over" "consumed=$EW_SEED_CONSUMED out='$out'"
fi

# THE TWIN, and it is the one that stops this over-firing: a tree WITHOUT the
# marker is somebody else's — xcodebuild's own, or a developer's — and must be
# left completely alone.
PROV2="$TMPROOT/prov2"; mkdir -p "$PROV2"
make_tree "$PROV2/SourcePackages"
EW_SEED_CONSUMED=0
ew_seed_consume "$ROOT" "$PROV2" > "$TMPROOT/prov2.out" 2>&1
out="$(cat "$TMPROOT/prov2.out")"
if [ "$EW_SEED_CONSUMED" = "0" ] && [ -z "$out" ]; then
  ok "an existing tree with NO marker is left alone and does not arm anything (the twin)"
else
  bad "provenance false arm" "consumed=$EW_SEED_CONSUMED out='$out'"
fi
EW_SEED_CONSUMED=0

# A VALIDATED tree stops being the seed's problem, so the marker is cleared.
# Without this the fallback arms on every later run and would discard a good tree
# on the first unrelated package error.
PROV3="$TMPROOT/prov3"; mkdir -p "$PROV3/SourcePackages"
printf 'somekey\n' > "$PROV3/SourcePackages/$EW_SEED_PROVENANCE_FILE"
EW_SEED_CONSUMED=1
ew_seed_resolve_or_unseed "$PROV3" true
if [ ! -e "$PROV3/SourcePackages/$EW_SEED_PROVENANCE_FILE" ]; then
  ok "a successful resolve CLEARS the marker (the tree is xcodebuild's now)"
else
  bad "marker not cleared" "a validated tree still claims seed provenance"
fi
EW_SEED_CONSUMED=0

# --- the shared cache bounds itself, in TRACKED code --------------------------
# Every key publishes its own ~3.6 GB snapshot and keys roll on any dependency
# bump or Xcode upgrade. Cleanup existed only in a gitignored script, which means
# it did not exist on any machine but the one it was written on.
PR="$TMPROOT/prunecache"
export EW_SEED_ROOT="$PR"
mkdir -p "$PR/oldkey" "$PR/freshkey" "$PR/keepkey"
make_tree "$PR/oldkey/SourcePackages"; make_tree "$PR/freshkey/SourcePackages"; make_tree "$PR/keepkey/SourcePackages"
touch -t 202001010000 "$PR/oldkey" "$PR/keepkey"
EW_SEED_MAX_AGE_DAYS=14 ew_seed_prune keepkey >/dev/null 2>&1
if [ ! -e "$PR/oldkey" ]; then
  ok "a snapshot unused past the age bound is pruned"
else
  bad "prune stale" "an idle snapshot survived"
fi
if [ -d "$PR/freshkey/SourcePackages" ]; then
  ok "a RECENTLY USED snapshot is kept (the twin)"
else
  bad "prune fresh" "pruned a snapshot that was in use"
fi
if [ -d "$PR/keepkey/SourcePackages" ]; then
  ok "the key just published is kept even when its directory is old"
else
  bad "prune keep" "pruned the key it was told to keep"
fi

# A malformed bound must prune NOTHING. Reading "" or "abc" as zero would delete
# the whole cache, which is the expensive direction for a housekeeping routine.
mkdir -p "$PR/oldkey2"; make_tree "$PR/oldkey2/SourcePackages"; touch -t 202001010000 "$PR/oldkey2"
EW_SEED_MAX_AGE_DAYS="not-a-number" ew_seed_prune >/dev/null 2>&1
EW_SEED_MAX_AGE_DAYS="" ew_seed_prune >/dev/null 2>&1
EW_SEED_MAX_AGE_DAYS=0 ew_seed_prune >/dev/null 2>&1
if [ -d "$PR/oldkey2/SourcePackages" ]; then
  ok "a malformed or zero age bound prunes NOTHING"
else
  bad "prune malformed bound" "deleted a snapshot on an unusable bound"
fi

# A snapshot whose lock is HELD is in use right now, whatever its age says.
mkdir -p "$PR/busykey"; make_tree "$PR/busykey/SourcePackages"; touch -t 202001010000 "$PR/busykey"
ew_seed_lock_acquire busykey >/dev/null 2>&1
EW_SEED_MAX_AGE_DAYS=14 ew_seed_prune >/dev/null 2>&1
if [ -d "$PR/busykey/SourcePackages" ]; then
  ok "a LOCKED snapshot is never pruned, however old (a consumer may be mid-clone)"
else
  bad "prune locked" "deleted a snapshot while its lock was held"
fi
ew_seed_lock_release busykey

# The lock directory is not a snapshot and must survive. TWO corrections here,
# both found by the mutation control and neither visible from reading:
#   1. AGE IT FIRST. A freshly created .locks fails the age test and is never a
#      candidate, so the case could not reach its subject at all.
#   2. ASSERT ON CONTENTS, NOT EXISTENCE. Pruning any later key calls
#      `ew_seed_lock_acquire`, which does `mkdir -p` on .locks — so a deleted
#      .locks is REBUILT before the assertion runs and `[ -d ]` is true either
#      way. A sentinel inside it is what distinguishes "never touched" from
#      "destroyed and silently recreated empty".
# What protects .locks is the glob: `"$EW_SEED_ROOT"/*` does not match a leading
# dot. This case binds that choice, so replacing the glob with `find` or enabling
# `dotglob` goes red here.
#   3. SENTINEL FIRST, THEN AGE IT. Writing a file INTO a directory updates that
#      directory's own mtime, so ageing it and then dropping the sentinel in made
#      it fresh again — the case could not reach its subject for a third distinct
#      reason. Three vacuity causes in one assertion, each invisible from reading
#      and each found only by the mutant surviving.
printf 'sentinel\n' > "$PR/.locks/.ew-sentinel"
touch -t 202001010000 "$PR/.locks"
EW_SEED_MAX_AGE_DAYS=14 ew_seed_prune >/dev/null 2>&1
if [ -f "$PR/.locks/.ew-sentinel" ]; then
  ok "the lock directory is never a prune candidate (contents intact, not just recreated)"
else
  bad "prune locks dir" "the lock directory was deleted — .locks may have been rebuilt empty by a later acquire"
fi
export EW_SEED_ROOT="$TMPROOT/spm-seed"

# --- the marker is inside the tree BEFORE the rename --------------------------
# Written afterwards, a kill between the rename and the write left a cloned tree
# with NO provenance — which a later run reads as ordinary DerivedData, so the
# recovery never arms and the build stays broken until somebody deletes the tree
# by hand. The rename is what makes tree and marker appear together, so the
# binding observation is whether the marker is present in the STAGING tree at the
# moment the rename is asked for.
#
# The probe replaces `ew_seed_rename_exclusive` with a plain stub and then
# RE-SOURCES the library to restore it. An earlier version saved the original
# with `declare -f` and restored it with `eval`, which works in bash 5 and
# DESTROYS the function in bash 3.2 — `declare -f` there does not round-trip a
# body containing a heredoc, and the real function has one. Four unrelated cases
# went red as a result. That is the fourth time in this branch that a harness
# altered the subject it was measuring, so this case runs LAST and restores by
# re-sourcing rather than by reconstructing anything.
MARKER_PROBE="$TMPROOT/marker-probe"
: > "$MARKER_PROBE"
ew_seed_rename_exclusive() {
  if [ -f "$1/$EW_SEED_PROVENANCE_FILE" ]; then
    printf 'present\n' >> "$MARKER_PROBE"
  else
    printf 'absent\n' >> "$MARKER_PROBE"
  fi
  mv -f -- "$1" "$2" 2>/dev/null
}
DDM="$TMPROOT/ddmarker"; mkdir -p "$DDM"
EW_SEED_CONSUMED=0
ew_seed_consume "$ROOT" "$DDM" >/dev/null 2>&1
# shellcheck source=scripts/lib/spm-seed.sh
. "$HERE/spm-seed.sh"
EW_SEED_CONSUMED=0
if [ "$(cat "$MARKER_PROBE" 2>/dev/null)" = "present" ]; then
  ok "the provenance marker is inside the tree BEFORE it is renamed into place"
else
  bad "marker ordering" "at rename time the marker was '$(cat "$MARKER_PROBE" 2>/dev/null)' — a kill in that window leaves an unrecoverable clone"
fi

# --- a missing Tuist pin FAILS the key, it does not invent a second cache ------
# `${EW_TUIST_PIN:-tuist-unpinned}` looked defensive and was the opposite: an
# unset pin produced a different, perfectly valid-looking key, so the cache split
# into two namespaces and each published its own ~3.6 GB snapshot. Found on
# 2026-08-18 by a real-tool proof that corrupted the WRONG snapshot — it sourced
# this library without its sibling and got a different key, which is exactly the
# production hazard the default was hiding.
# A key that depends on which files a caller happened to source is not a key.
( unset EW_TUIST_PIN; ew_seed_key "$ROOT" >/dev/null 2>&1 ); pin_rc=$?
if [ "$pin_rc" -ne 0 ]; then
  ok "an unset Tuist pin FAILS the key (no second cache namespace)"
else
  bad "unpinned key" "produced a usable key with no pin — the cache can silently split in two"
fi

# THE TWIN: with the pin present the key computes normally. Without it, a version
# that simply always failed would look correct.
if [ -n "$(ew_seed_key "$ROOT")" ]; then
  ok "the key still computes normally when the pin IS set (the twin)"
else
  bad "pinned key" "failed to compute a key with the pin present"
fi

# AND THE CONSEQUENCE, which is the part that matters: a failed key must make
# consume a plain cache MISS rather than an error. Slow and correct beats fast
# and wrong, and nothing here may ever fail a build.
DDP="$TMPROOT/ddpin"; mkdir -p "$DDP"
( unset EW_TUIST_PIN; ew_seed_consume "$ROOT" "$DDP" ) > "$TMPROOT/pin.out" 2>&1; consume_rc=$?
if [ "$consume_rc" -eq 0 ] && [ ! -e "$DDP/SourcePackages" ] \
   && grep -q "could not compute seed key" "$TMPROOT/pin.out"; then
  ok "an unset pin makes consume a plain cache MISS, announced, never a failure"
else
  bad "unpinned consume" "rc=$consume_rc target=$([ -e "$DDP/SourcePackages" ] && echo present || echo absent) out='$(cat "$TMPROOT/pin.out")'"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$((PASS + FAIL))" -lt 49 ]; then
  printf 'ERROR: expected at least 49 assertions, ran %s\n' "$((PASS + FAIL))"
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
