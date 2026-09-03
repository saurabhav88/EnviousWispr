#!/usr/bin/env bash
# scripts/ci/configure-compilation-cache.sh
# Turn on Xcode 26 compilation caching for every xcodebuild in the calling job,
# by writing an xcconfig and exporting XCODE_XCCONFIG_FILE (#2580).
#
# WHY THIS AND NOT MTIME RESTORATION. Xcode decides whether to reuse work by
# comparing each input's size and modification time. That is a PROXY for "did
# the content change", and `actions/checkout` breaks the proxy by stamping every
# tracked file with the checkout time — so a restored cache is discarded on
# arrival despite byte-identical content.
#
# The obvious repair is to put the timestamps back. That was built, reviewed
# three times, and abandoned: every round found the same defect in a new place,
# because committer time is per-second and is not guaranteed to advance, so a
# changed file can be handed the cached object's exact size and mtime. Each
# round produced a better guard under the same leaking assumption.
#
# Compilation caching removes the assumption instead. It is content-addressed:
# the compiler hashes a compile job's actual inputs and looks the result up by
# that hash, so a timestamp cannot make a wrong result reachable. Different
# content is a different key.
#
# MEASURED, one machine, paired arms, same tree (M5 Max, Xcode 26.6):
#   cold, from nothing .......................  84s   2130 SwiftCompile
#   warm, nothing touched (the ceiling) ......   3s      0
#   warm, every mtime freshened = today's CI ..  61s   1343
#   same, with this enabled ..................  20s   1343  (all cache hits)
#   content cache ALONE, Build/ deleted ......  25s   2130  (all cache hits)
#
# OUTPUT EQUIVALENCE, two-way controlled, because "it is content-addressed"
# is a claim about the design and not evidence about our binaries. Two cold
# builds differing ONLY in these flags are byte-identical across every Mach-O
# the build produces — 0 differing instruction lines in the 1.86M-line main
# dylib. An INCREMENTAL build differs from both by 6078 lines in the same
# positions, which is ordinary build non-determinism and not this feature. The
# first comparison run looked damning and was measuring the app's launcher stub,
# 454 instructions for a whole product; see code-validation.md
# FACT: build-artifact-inspection-traps.
#
# COST: a cold build is ~19% slower (84s -> 100s) because it populates the
# cache. Only the first build after a dependency or toolchain change pays it.
#
# Usage:
#   configure-compilation-cache.sh              write the xcconfig, export it
#   configure-compilation-cache.sh --self-test  contract check, no Xcode needed
set -euo pipefail

# COMPILATION_CACHE_ENABLE_CACHING is the umbrella; the two per-compiler
# switches are what Swift and Clang actually read. All three are declared by
# Xcode 26.6's own build-settings specs (CoreBuildSystem, Swift and Clang
# .xcspec), which is where these names were taken from rather than from a blog.
SETTINGS=(
  "COMPILATION_CACHE_ENABLE_CACHING = YES"
  "SWIFT_ENABLE_COMPILE_CACHE = YES"
  "CLANG_ENABLE_COMPILE_CACHE = YES"
)

# XCODE_XCCONFIG_FILE applies on top of every target, so ONE export covers every
# xcodebuild in the job — including invocations added later. The alternative was
# three settings repeated on each of ten command lines, which is the
# hand-mirrored-copies shape #1994 built .github/actions/xcode-ci-setup to stop.
write_config() {
  local dest="${1:-${RUNNER_TEMP:-/tmp}/ew-compilation-cache.xcconfig}"

  printf '// Written by scripts/ci/configure-compilation-cache.sh (#2580). Do not edit.\n' >"$dest"
  printf '%s\n' "${SETTINGS[@]}" >>"$dest"

  if [ -n "${GITHUB_ENV:-}" ]; then
    echo "XCODE_XCCONFIG_FILE=$dest" >>"$GITHUB_ENV"
  else
    echo "==> GITHUB_ENV unset; export it yourself: XCODE_XCCONFIG_FILE=$dest" >&2
  fi

  echo "==> compilation caching armed via $dest"
  sed 's/^/    /' "$dest"
}

# REQUIRED: the expectation, written out as literals on purpose.
#
# The first version of this suite looped over ${SETTINGS[@]} — the same array
# the writer uses — so deleting a setting from SETTINGS made the suite pass with
# two. An expectation built from the mechanism under test cannot fail; both
# sides move together. Caught by mutating SETTINGS and watching the suite stay
# green. validation-discipline.md
# RULE: an-expectation-built-with-the-mechanism-under-test-cannot-fail.
#
# So these three names are duplicated deliberately. Adding a fourth setting
# means adding it in both places, which is the point: the second place is what
# notices when the first one loses one.
REQUIRED=(
  "COMPILATION_CACHE_ENABLE_CACHING = YES"
  "SWIFT_ENABLE_COMPILE_CACHE = YES"
  "CLANG_ENABLE_COMPILE_CACHE = YES"
)

# _verify: 0 if <config> declares every REQUIRED setting and <env-file> points
# at it. One checker, run against the real output and against deliberately
# broken fixtures — a checker only ever run on correct input is a checker nobody
# has seen fail.
_verify() {
  local cfg="$1" envf="$2" s
  for s in "${REQUIRED[@]}"; do
    /usr/bin/grep -qxF "$s" "$cfg" || return 1
  done
  # The export is the half that makes the file do anything. A config nothing
  # points at is a file, not a setting.
  /usr/bin/grep -qxF "XCODE_XCCONFIG_FILE=$cfg" "$envf" || return 1
}

# self_test: the contract this script owns, checkable without Xcode so it runs
# on the ubuntu aggregator beside the other CI self-tests.
#
# It does NOT prove Xcode honours the file. That is a claim about the toolchain
# and it was established separately, by running `xcodebuild -showBuildSettings`
# against the real generated project with and without XCODE_XCCONFIG_FILE set:
# all three absent without it, all three YES with it. Stated rather than
# implied, so nobody reads this suite as covering more than it does.
self_test() {
  local tmp fail=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  GITHUB_ENV="$tmp/env" write_config "$tmp/cfg.xcconfig" >/dev/null
  if _verify "$tmp/cfg.xcconfig" "$tmp/env"; then
    echo "ok   [contract] all ${#REQUIRED[@]} required settings written and exported"
  else
    echo "FAIL [contract] the script did not write every required setting"
    echo "     wanted:"
    printf '       %s\n' "${REQUIRED[@]}"
    echo "     got:"
    sed 's/^/       /' "$tmp/cfg.xcconfig"
    fail=1
  fi

  # Two-way controls, one per way the contract can break. Both feed the checker
  # a fixture this suite wrote, so nothing in the live script gains a knob for
  # the sake of being testable.
  printf '%s\n' "${REQUIRED[0]}" >"$tmp/partial.xcconfig"
  echo "XCODE_XCCONFIG_FILE=$tmp/partial.xcconfig" >"$tmp/env-partial"
  if _verify "$tmp/partial.xcconfig" "$tmp/env-partial"; then
    echo "FAIL [control: missing setting] a config with 1 of ${#REQUIRED[@]} settings passed"
    fail=1
  else
    echo "ok   [control: missing setting] an incomplete config is rejected"
  fi

  printf '%s\n' "${REQUIRED[@]}" >"$tmp/orphan.xcconfig"
  : >"$tmp/env-orphan"
  if _verify "$tmp/orphan.xcconfig" "$tmp/env-orphan"; then
    echo "FAIL [control: no export] a config nothing points at passed"
    fail=1
  else
    echo "ok   [control: no export] a config nothing points at is rejected"
  fi

  if [ "$fail" -ne 0 ]; then
    echo "== configure-compilation-cache self-test FAIL =="
    return 1
  fi
  echo "== configure-compilation-cache self-test PASS =="
}

case "${1:-}" in
  --self-test) self_test ;;
  "") write_config ;;
  *)
    echo "::error::configure-compilation-cache.sh: unknown argument '$1'" >&2
    exit 1
    ;;
esac
