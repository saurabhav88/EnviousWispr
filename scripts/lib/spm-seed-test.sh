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
make_tree() { # <path>
  mkdir -p "$1/artifacts/sentry-cocoa" "$1/checkouts" "$1/repositories"
  printf '{"object":{}}\n' > "$1/workspace-state.json"
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
if ew_seed_is_complete "$DD3/SourcePackages" && printf '%s' "$out" | grep -q "Seeded packages"; then
  ok "consume clones the snapshot into an absent target"
else
  bad "consume" "target incomplete or unannounced: '$out'"
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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$((PASS + FAIL))" -lt 31 ]; then
  printf 'ERROR: expected at least 31 assertions, ran %s\n' "$((PASS + FAIL))"
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
