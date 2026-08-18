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

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$((PASS + FAIL))" -lt 15 ]; then
  printf 'ERROR: expected at least 15 assertions, ran %s\n' "$((PASS + FAIL))"
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
