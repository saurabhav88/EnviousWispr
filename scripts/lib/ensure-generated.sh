#!/usr/bin/env bash
# scripts/lib/ensure-generated.sh — regenerate the Xcode project ONLY when a
# generation input actually changed. Sourced by `scripts/build-dev-app.sh` and
# `scripts/xcode-test.sh` (#2157 chunk C).
#
# WHY THIS EXISTS
# `tuist generate` took a measured 6.7 s on every invocation of both scripts and
# produced a BYTE-IDENTICAL `project.pbxproj` (md5 unchanged before and after,
# M5 Max / Xcode 26.6, 2026-08-18). That is pure overhead on a warm tree.
#
# WHY THE KEY HASHES A FILE **LIST** AND NOT FILE CONTENTS
# Tuist captures `sources:` globs AT GENERATION TIME (`Project.swift`), so the
# generated project goes stale when a `.swift` file is ADDED, DELETED or RENAMED,
# and does NOT go stale when a file's CONTENTS change. Hashing contents would
# regenerate on every ordinary edit — exactly the cost this removes. Hashing the
# list regenerates on precisely the changes that matter.
# Owner of that fact: `.claude/knowledge/xcode-build-tooling.md`
# FACT: deleting-a-source-file-needs-a-regenerate.
#
# WHY ONE SHARED OWNER RATHER THAN A COPY IN EACH SCRIPT
# Two copies drift, and the failure is silent in the worst direction: one script
# regenerates always (slow but correct) while the other never does (fast and
# wrong), and no single test can see the divergence. The plan's §11.3 requires
# either both entry points tested or one shared tested owner; this is that owner.
#
# CONTRACT
#   ew_generation_key <project_root>      -> prints a sha256 over the inputs
#   ew_ensure_generated <project_root>    -> generates iff needed; prints why
# Both are safe under `set -euo pipefail`: every conditional is an `if` block,
# never a `[ ... ] && VAR=1` trailing an loop body, which would abort the caller.

# The Tuist version is PINNED and the pin is part of the key: a different Tuist
# emits a different project from identical inputs. Never invoke a bare `tuist` —
# one is on PATH via `.local/share/mise/installs/tuist/latest` and would silently
# be a different version.
EW_TUIST_PIN="${EW_TUIST_PIN:-tuist@4.195.11}"

# Files whose CONTENTS change what Tuist generates.
EW_GENERATION_MANIFESTS=(
  Project.swift
  Tuist.swift
  Package.swift
  Package.resolved
  Workspace.swift
)

# Trees whose FILE SET changes what Tuist generates.
EW_GENERATION_TREES=(Sources Tests Tuist)

ew_generation_key() {
  local root="$1"
  local f d
  {
    printf '%s\n' "$EW_TUIST_PIN"
    for f in "${EW_GENERATION_MANIFESTS[@]}"; do
      if [ -f "$root/$f" ]; then
        shasum -a 256 "$root/$f"
      fi
    done
    for d in "${EW_GENERATION_TREES[@]}"; do
      if [ -d "$root/$d" ]; then
        # -print, not -exec: we want the NAME SET, not the contents.
        find "$root/$d" -type f -print
      fi
    done
  } | LC_ALL=C sort | shasum -a 256 | awk '{print $1}'
}

ew_ensure_generated() {
  local root="$1"
  local project_file="$root/EnviousWispr.xcodeproj/project.pbxproj"
  local stamp="$root/.derivedData/tuist-generation-inputs.sha256"
  local current previous=""

  current="$(ew_generation_key "$root")"
  if [ -z "$current" ]; then
    # A measurement authority fails CLOSED: an unreadable key must regenerate,
    # never silently reuse a project we cannot vouch for.
    echo "==> Generating Xcode project (could not compute input key)"
    ew_run_tuist_generate "$root"
    return
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
    return
  fi

  ew_run_tuist_generate "$root"
  mkdir -p "$(dirname "$stamp")"
  printf '%s\n' "$current" > "$stamp"
}

ew_run_tuist_generate() {
  local root="$1"
  # `EW_TUIST_GENERATE_CMD` exists SOLELY so the self-test can count invocations
  # without running Tuist. It is never set in normal operation, and the default
  # keeps the version pin inline where a reader can see it.
  if [ -n "${EW_TUIST_GENERATE_CMD:-}" ]; then
    ( cd "$root" && eval "$EW_TUIST_GENERATE_CMD" )
  else
    ( cd "$root" && mise x "$EW_TUIST_PIN" -- tuist generate --no-open )
  fi
}
