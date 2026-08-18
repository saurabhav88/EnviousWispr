#!/usr/bin/env bash
# scripts/lib/ensure-generated.sh — regenerate the Xcode project ONLY when a
# generation input actually changed. Sourced by `scripts/build-dev-app.sh` and
# `scripts/xcode-test.sh` (#2157 chunk C).
#
# WHY THIS EXISTS
# `tuist generate` ran unconditionally in both entry points and produced a
# BYTE-IDENTICAL `project.pbxproj` on a warm tree — measured 6.7 s per invocation,
# md5 unchanged before and after (M5 Max / Xcode 26.6, 2026-08-18).
#
# WHY THE KEY HASHES A FILE **LIST** AND NOT FILE CONTENTS
# Tuist captures `sources:` globs AT GENERATION TIME, so the generated project
# goes stale when a `.swift` file is ADDED, DELETED or RENAMED, and does NOT go
# stale when a file's CONTENTS change. Hashing contents would regenerate on every
# ordinary edit — exactly the cost this removes.
# Owner: `.claude/knowledge/xcode-build-tooling.md`
# FACT: deleting-a-source-file-needs-a-regenerate.
#
# WHY EACH PATH IS HASHED INDIVIDUALLY RATHER THAN JOINED WITH NEWLINES
# A filename may contain a newline. Joining raw paths makes the sets
# {"A\nTAIL", "B"} and {"A", "B\nTAIL"} produce IDENTICAL sorted text, so a
# rename between those two shapes would reuse a stale project and the build would
# fail later with "Build input file cannot be found" — a silent wrong answer
# wearing a source-tree error's clothes. Hashing each NUL-delimited path first
# makes every entry a fixed-width token, so no collision is reachable.
#
# WHY ONE SHARED OWNER RATHER THAN A COPY IN EACH SCRIPT
# Two copies drift, and the failure is silent in the worst direction: one script
# regenerates always (slow but correct) while the other never does (fast and
# wrong), and no single test can see the divergence.
#
# FAILURE PHILOSOPHY: every unclear path regenerates. A key we cannot compute is
# not a reason to trust the project we have.

# The Tuist version is PINNED and the pin is part of the key: a different Tuist
# emits a different project from identical inputs. Never invoke a bare `tuist` —
# one is on PATH via `.local/share/mise/installs/tuist/latest` and would silently
# be a different version.
EW_TUIST_PIN="${EW_TUIST_PIN:-tuist@4.195.11}"

# Files whose CONTENTS change what Tuist generates.
EW_GENERATION_MANIFESTS=(
  Project.swift
  Tuist.swift
  Workspace.swift
  Package.swift
  Package.resolved
)

# Trees whose FILE SET changes what Tuist generates.
EW_GENERATION_TREES=(Sources Tests)

# CODE TREES ARE HASHED BY CONTENT, AND THEY ARE A DIFFERENT KIND OF INPUT.
# `Tuist/**/*.swift` holds project-description HELPERS: their code decides what
# gets generated, so editing one changes the project while adding or removing no
# source file at all. File-list hashing is right for `Sources`/`Tests`, where
# Tuist captures globs, and WRONG here — it would reuse a stale project after a
# helper edit, and the build would fail later wearing some other error's clothes.
# One rule was being applied to two kinds of input that need different rules.
# CI already draws this line: `.github/actions/xcode-ci-setup/action.yml` hashes
# `Tuist/**/*.swift` CONTENTS in its cache key.
# LATENT TODAY, FIXED ANYWAY: neither `Tuist/` nor `Workspace.swift` exists in
# this repo yet. Both are hypothetical until someone adds one — and the failure
# would be SILENT, which is the case this repo says to write code for.
EW_GENERATION_CODE_TREES=(Tuist)

# Prints a sha256 over every generation input. Fails (non-zero, no output) rather
# than printing a PARTIAL key: a half-computed key that happens to match is worse
# than no key, because it silently skips a needed regeneration.
ew_generation_key() {
  local root="$1"
  # Runs entirely inside a SUBSHELL that sets its own `pipefail`. Correctness must
  # not depend on the caller remembering it: without `pipefail`, a failure of the
  # MIDDLE command in `find | perl | sort` is invisible — `sort` succeeds on empty
  # input, `rows` comes back empty, and the key becomes a STABLE HASH OF NOTHING.
  # That is the silent-wrong direction: a stable wrong key means the inputs never
  # appear to change, so the project is NEVER regenerated and the build fails much
  # later with "Build input file cannot be found".
  # Measured 2026-08-18 with a deliberately missing perl module: with `pipefail`
  # it fails closed; without it, it emitted sha256("\n") as a confident answer.
  # `set -o` inside `( ... )` does not leak to the caller.
  (
    set -o pipefail
    ew_generation_key_impl "$root"
  )
}

ew_generation_key_impl() {
  local root="$1" f d digest rows
  {
    digest="$(printf '%s\0' "$EW_TUIST_PIN" | shasum -a 256)" || exit 1
    printf 'pin:%s\n' "${digest%% *}"
    for f in "${EW_GENERATION_MANIFESTS[@]}"; do
      [ -f "$root/$f" ] || continue
      # Read from STDIN so the CHECKOUT PATH is not part of the hash. `shasum
      # <file>` prints "<hash>  <path>", so hashing that output makes the same
      # manifest produce a different key in a differently-named worktree —
      # harmless for correctness, since the key is only ever compared within one
      # checkout, but it forces a needless regenerate after a move or rename.
      digest="$(shasum -a 256 < "$root/$f")" || exit 1
      printf 'manifest:%s:%s\n' "$f" "${digest%% *}"
    done
    for d in "${EW_GENERATION_TREES[@]}"; do
      [ -d "$root/$d" ] || continue
      # -print0 then hash each path: newline-safe by construction (see header).
      rows="$(find "$root/$d" -type f -print0 |
        perl -0MDigest::SHA=sha256_hex -ne 'chomp; print sha256_hex($_), "\n"' |
        LC_ALL=C sort)" || exit 1
      printf 'tree:%s\n%s\n' "$d" "$rows"
    done
    for d in "${EW_GENERATION_CODE_TREES[@]}"; do
      [ -d "$root/$d" ] || continue
      # Path AND content for each file, so a rename and an edit both move the key.
      # Same NUL-delimited, hash-each-token construction as above: joining raw
      # paths would let a newline in a filename forge a collision.
      rows="$(find "$root/$d" -type f -print0 |
        perl -0MDigest::SHA=sha256_hex -ne '
          chomp;
          open(my $fh, "<:raw", $_) or exit 1;
          local $/; my $body = <$fh>; close $fh;
          print sha256_hex($_), ":", sha256_hex(defined $body ? $body : ""), "\n";
        ' |
        LC_ALL=C sort)" || exit 1
      printf 'codetree:%s\n%s\n' "$d" "$rows"
    done
  } | shasum -a 256 | awk '{print $1}'
}

ew_ensure_generated() {
  local root="$1"
  local project_file="$root/EnviousWispr.xcodeproj/project.pbxproj"
  local stamp="$root/.derivedData/tuist-generation-inputs.sha256"
  local current previous=""

  # Guarded assignment: a bare `current=$(...)` would abort a caller running
  # `set -e` BEFORE reaching the fail-closed branch below, turning a fallback
  # into a build failure.
  if ! current="$(ew_generation_key "$root")"; then
    current=""
  fi

  if [ -z "$current" ]; then
    # A measurement authority fails CLOSED: an unreadable key regenerates rather
    # than reusing a project we cannot vouch for.
    echo "==> Generating Xcode project (could not compute input key)"
    ew_run_tuist_generate "$root" || return $?
    return 0
  fi

  if [ -f "$stamp" ]; then
    previous="$(cat "$stamp" 2>/dev/null || true)"
  fi

  if [ ! -f "$project_file" ]; then
    echo "==> Generating Xcode project (no project.pbxproj)"
  elif [ "$current" != "$previous" ]; then
    echo "==> Generating Xcode project (inputs changed)"
  else
    # Every skip says WHY. A silent fast path is indistinguishable from a broken
    # one, and this one is invisible in the build log otherwise.
    echo "==> Reusing current Xcode project (inputs unchanged)"
    return 0
  fi

  ew_run_tuist_generate "$root" || return $?
  mkdir -p "$(dirname "$stamp")"
  printf '%s\n' "$current" > "$stamp"
}

# The ONLY generation call. Deliberately has no environment-variable override:
# an `eval`-ed command from the environment is an arbitrary-command seam reachable
# in production, and it buys nothing — the self-test overrides this FUNCTION
# directly, which is both safer and a more faithful stub.
ew_run_tuist_generate() {
  local root="$1"
  ( cd "$root" && mise x "$EW_TUIST_PIN" -- tuist generate --no-open )
}
