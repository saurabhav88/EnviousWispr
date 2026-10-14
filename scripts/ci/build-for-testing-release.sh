#!/usr/bin/env bash
# scripts/ci/build-for-testing-release.sh — ONE owner for the CI Release
# `xcodebuild build-for-testing` (#3729).
#
# pr-check.yml runs it before the full Release test run; the build-only
# main cache warm runs the same command, so the compiler cache it saves holds
# exactly the products a PR build looks up. Two copies of the flag list would
# drift, and a drifted cache key or flag is a cold PR build nobody notices.
#
# Usage:
#   build-for-testing-release.sh --project <path> --scheme <name> \
#     --derived-data <path> --log <path> --result-bundle <path>
#   build-for-testing-release.sh --self-test
#
# Every path is the caller's; nothing here reads GITHUB_WORKSPACE or a
# workflow env name. The compile runs through `ew_phase` (scripts/lib/ci-phase.sh)
# exactly once, as phase `build_for_testing_release`: the combined output is
# appended to --log and still reaches the job log, the seconds land in the
# EW-CI-METRICS file, and the exit status is xcodebuild's own. A missing,
# empty or unknown argument exits 2 before xcodebuild runs.
#
# #3348: this is the only Release compile in the PR job. It used to follow a
# plain non-testable `xcodebuild build` (324-719 s) whose products fed the
# linkage, catalog and launch checks; ENABLE_TESTABILITY changes flags, so
# nothing was reused. Measured before removing it (Xcode 27.0, one tree,
# separate DerivedData): the testable and non-testable apps had identical
# bundle inventories (180 files), Mach-O sets (8), load commands, rpaths,
# minos, Info.plist and extracted .stringsdata; the testable app imports 146
# extra symbols, all from baseline libraries (libSystem, SwiftUI,
# libswiftCore...), with zero weak/strong or library flips on shared symbols,
# and both pass check-weak-linked-symbols.sh with identical summaries.
#
# XcodeBuildTopologyFreezeTests (arm64OnlyBuildSettings) reads this file and
# fails if the invocation below loses ARCHS=arm64, VALID_ARCHS=arm64 or
# ONLY_ACTIVE_ARCH.
#
# #3729 PR-B: DEBUG_INFORMATION_FORMAT=dwarf skips dSYM generation. Nothing in
# this build's consumers reads a dSYM (pr-check.yml's linkage, catalog, app
# snapshot and launch, the full Release suite, the Settings Map export and the
# FoundationModels probe; cache-warm saves the compiler cache, not products;
# Project.swift has no build-phase scripts). The shipped app is archived by
# scripts/build-release-dmg.sh with its own settings, and its dSYMs are
# untouched by this. A command-line setting applies to every target in this
# invocation, which is the intent here. The --self-test expected arguments
# fail if the flag is lost.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "usage: $0 --project <path> --scheme <name> --derived-data <path> --log <path> --result-bundle <path>" >&2
  echo "       $0 --self-test" >&2
}

run_build() {
  local project="" scheme="" derived="" log="" bundle=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project|--scheme|--derived-data|--log|--result-bundle)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          echo "build-for-testing-release: $1 needs a non-empty value" >&2
          usage
          return 2
        fi
        case "$1" in
          --project) project="$2" ;;
          --scheme) scheme="$2" ;;
          --derived-data) derived="$2" ;;
          --log) log="$2" ;;
          --result-bundle) bundle="$2" ;;
        esac
        shift 2
        ;;
      *)
        echo "build-for-testing-release: unknown argument: $1" >&2
        usage
        return 2
        ;;
    esac
  done
  local name
  for name in project scheme derived log bundle; do
    if [ -z "${!name}" ]; then
      echo "build-for-testing-release: missing required argument (${name})" >&2
      usage
      return 2
    fi
  done

  # shellcheck source=scripts/lib/ci-phase.sh
  . "$HERE/../lib/ci-phase.sh"
  ew_phase build_for_testing_release "$log" -- xcodebuild build-for-testing \
    -project "$project" \
    -scheme "$scheme" \
    -configuration Release \
    -derivedDataPath "$derived" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$bundle" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    VALID_ARCHS=arm64 \
    ENABLE_TESTABILITY=YES \
    DEBUG_INFORMATION_FORMAT=dwarf
}

# Drives the REAL entrypoint (this file, as a new process) with a stub
# `xcodebuild` first on PATH, so no Release build runs. The expected argument
# list is written out literally here, not derived from run_build.
self_test() {
  local tmp pass=0 fail=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ew-bft-release-test.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN
  mkdir "$tmp/bin"
  cat >"$tmp/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
: >"$EW_STUB_ARGS"
for a in "$@"; do printf '%s\n' "$a" >>"$EW_STUB_ARGS"; done
echo "stub xcodebuild output"
exit "${EW_STUB_RC:-0}"
STUB
  chmod +x "$tmp/bin/xcodebuild"

  check() {
    if [ "$1" = "ok" ]; then
      echo "  ok   $2"
      pass=$((pass + 1))
    else
      echo "  FAIL $2" >&2
      fail=$((fail + 1))
    fi
  }

  # $1 = stub exit code, $2 = case dir, rest = arguments to the script.
  invoke() {
    local rc_want="$1" dir="$2"
    shift 2
    mkdir -p "$dir"
    local got=0
    PATH="$tmp/bin:$PATH" EW_STUB_ARGS="$dir/args" EW_STUB_RC="$rc_want" \
      EW_CI_METRICS_FILE="$dir/metrics.env" \
      bash "$HERE/build-for-testing-release.sh" "$@" >"$dir/out" 2>&1 || got=$?
    echo "$got" >"$dir/rc"
  }

  expected_args() {
    printf '%s\n' build-for-testing \
      -project "$1" -scheme "$2" -configuration Release \
      -derivedDataPath "$3" -destination 'platform=macOS,arch=arm64' \
      -resultBundlePath "$4" \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES VALID_ARCHS=arm64 ENABLE_TESTABILITY=YES \
      DEBUG_INFORMATION_FORMAT=dwarf
  }

  # 1. Success: exact argument list, status 0, log and metrics written.
  local d="$tmp/case-ok"
  invoke 0 "$d" --project P.xcodeproj --scheme S --derived-data DD \
    --log "$d/build.log" --result-bundle "$d/r.xcresult"
  if [ "$(cat "$d/rc")" = 0 ] \
    && diff -u <(expected_args P.xcodeproj S DD "$d/r.xcresult") "$d/args" >&2 \
    && /usr/bin/grep -qx "stub xcodebuild output" "$d/build.log" \
    && /usr/bin/grep -qE '^phase_build_for_testing_release_s=[0-9]+$' "$d/metrics.env"; then
    check ok "success: exact arguments, status 0, log and metrics written"
  else
    check fail "success case (rc=$(cat "$d/rc")); output: $(cat "$d/out")"
  fi

  # 2. Paths with spaces and quotes reach xcodebuild as single arguments.
  d="$tmp/case quoting"
  invoke 0 "$d" --project "My Proj/E W.xcodeproj" --scheme "Scheme 'Q'" \
    --derived-data "Derived Data" --log "$d/b l.log" --result-bundle "$d/r b.xcresult"
  if [ "$(cat "$d/rc")" = 0 ] \
    && diff -u <(expected_args "My Proj/E W.xcodeproj" "Scheme 'Q'" "Derived Data" "$d/r b.xcresult") "$d/args" >&2; then
    check ok "quoting: spaced and quoted values arrive intact"
  else
    check fail "quoting case (rc=$(cat "$d/rc")); output: $(cat "$d/out")"
  fi

  # 3. A compiler failure is the script's own status.
  d="$tmp/case-fail"
  invoke 65 "$d" --project P --scheme S --derived-data DD \
    --log "$d/build.log" --result-bundle "$d/r.xcresult"
  if [ "$(cat "$d/rc")" = 65 ] \
    && /usr/bin/grep -qE '^phase_build_for_testing_release_s=[0-9]+$' "$d/metrics.env"; then
    check ok "compiler status 65 propagates, metrics still written"
  else
    check fail "compiler failure case (rc=$(cat "$d/rc")); output: $(cat "$d/out")"
  fi

  # 4-6. Bad arguments exit 2 and xcodebuild never runs.
  local label
  for label in missing empty unknown; do
    d="$tmp/case-$label"
    case "$label" in
      missing) invoke 0 "$d" --project P --scheme S --derived-data DD --log "$d/l" ;;
      empty) invoke 0 "$d" --project "" --scheme S --derived-data DD --log "$d/l" --result-bundle "$d/r" ;;
      unknown) invoke 0 "$d" --project P --scheme S --derived-data DD --log "$d/l" --result-bundle "$d/r" --arch x86_64 ;;
    esac
    if [ "$(cat "$d/rc")" = 2 ] && [ ! -e "$d/args" ]; then
      check ok "$label argument: exit 2 before xcodebuild runs"
    else
      check fail "$label argument case (rc=$(cat "$d/rc"), stub ran: $([ -e "$d/args" ] && echo yes || echo no))"
    fi
  done

  echo "build-for-testing-release self-test: executed=$((pass + fail)) passed=$pass failed=$fail"
  [ "$fail" -eq 0 ] && [ "$pass" -eq 6 ]
}

if [ "${1:-}" = "--self-test" ] && [ "$#" -eq 1 ]; then
  self_test
else
  run_build "$@"
fi
