#!/usr/bin/env bash
# scripts/lib/ensure-generated-test.sh — two-way self-test for the conditional
# project generation in `scripts/lib/ensure-generated.sh` (#2157 chunk C).
#
# WHY TWO-WAY, AND WHY IT IS THE WHOLE POINT
# A generation check has two failure directions and they are NOT symmetric in how
# they announce themselves:
#   - ALWAYS regenerates  -> slow, correct, obvious. Nobody is misled.
#   - NEVER regenerates   -> fast, WRONG, and silent. The build fails later with
#     "Build input file cannot be found", which reads as a broken source tree
#     rather than a stale project (#1539).
# A test asserting only "it regenerates when I change a manifest" passes against
# a function that regenerates unconditionally, which is the useless half. Every
# case below therefore has a twin asserting the OTHER direction.
#
# The generator is STUBBED via `EW_TUIST_GENERATE_CMD` and counted. Nothing here
# runs Tuist, touches a real checkout, or needs a network — it is pure logic.
#
# Run: bash scripts/lib/ensure-generated-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ensure-generated.sh
. "$HERE/ensure-generated.sh"

PASS=0
FAIL=0
FIXTURE=""

cleanup() { [ -n "$FIXTURE" ] && [ -d "$FIXTURE" ] && rm -rf "$FIXTURE"; }
trap cleanup EXIT

# Each fixture is a throwaway tree shaped like a checkout. `COUNT_FILE` is how we
# observe the subject: the stub appends one line per invocation, so the count is
# written BY the subject's own call path, never inferred from a marker beside it.
new_fixture() {
  FIXTURE="$(mktemp -d)"
  mkdir -p "$FIXTURE/Sources/Mod" "$FIXTURE/Tests/ModTests" "$FIXTURE/EnviousWispr.xcodeproj"
  printf 'let x = 1\n' > "$FIXTURE/Sources/Mod/A.swift"
  printf 'let y = 2\n' > "$FIXTURE/Tests/ModTests/ATests.swift"
  printf 'manifest\n' > "$FIXTURE/Project.swift"
  printf 'resolved\n' > "$FIXTURE/Package.resolved"
  printf 'tuistcfg\n' > "$FIXTURE/Tuist.swift"
  printf 'pkg\n' > "$FIXTURE/Package.swift"
  mkdir -p "$FIXTURE/Tuist"
  printf 'helper\n' > "$FIXTURE/Tuist/Helper.swift"
  printf 'pbx\n' > "$FIXTURE/EnviousWispr.xcodeproj/project.pbxproj"
  COUNT_FILE="$FIXTURE/.generate-count"
  : > "$COUNT_FILE"
}

# Override the generation FUNCTION directly. The earlier version used an
# `eval`-ed environment variable, which was an arbitrary-command seam reachable
# in production for no benefit. Overriding the function is both safer and a more
# faithful stub: it replaces exactly the call the subject makes.
ew_run_tuist_generate() { printf 'x\n' >> "$COUNT_FILE"; }

generate_count() { wc -l < "$COUNT_FILE" | tr -d ' '; }

# Bring the fixture to a settled state: generated once, stamp written.
settle() {
  ew_ensure_generated "$FIXTURE" >/dev/null
  : > "$COUNT_FILE"
}

check() { # name expected actual
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  PASS  %s (generated %s)\n' "$1" "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s — expected %s generation(s), got %s\n' "$1" "$2" "$3"
  fi
}

# --- Direction 1: MUST regenerate -------------------------------------------
# Each of these changes what Tuist would emit, so a skip here ships a stale
# project and the build fails later with a misleading error.

new_fixture
check "first run with no stamp regenerates" 1 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

new_fixture; settle
rm -f "$FIXTURE/EnviousWispr.xcodeproj/project.pbxproj"
check "missing project.pbxproj regenerates" 1 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

new_fixture; settle
printf 'let z = 3\n' > "$FIXTURE/Sources/Mod/B.swift"
check "ADDED source file regenerates" 1 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

new_fixture; settle
rm -f "$FIXTURE/Sources/Mod/A.swift"
check "DELETED source file regenerates" 1 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

new_fixture; settle
mv "$FIXTURE/Sources/Mod/A.swift" "$FIXTURE/Sources/Mod/Renamed.swift"
check "RENAMED source file regenerates" 1 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

new_fixture; settle
printf 'let t = 4\n' > "$FIXTURE/Tests/ModTests/BTests.swift"
check "ADDED test file regenerates" 1 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

new_fixture; settle
printf 'manifest changed\n' > "$FIXTURE/Project.swift"
check "changed Project.swift regenerates" 1 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

new_fixture; settle
printf 'resolved changed\n' > "$FIXTURE/Package.resolved"
check "changed Package.resolved regenerates" 1 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

new_fixture; settle
rm -f "$FIXTURE/.derivedData/tuist-generation-inputs.sha256"
check "missing stamp regenerates" 1 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

new_fixture; settle
# SC2034 is a false positive on both assignments: EW_TUIST_PIN is READ by
# ensure-generated.sh, which shellcheck does not follow across the source.
# shellcheck disable=SC2034
EW_TUIST_PIN="tuist@9.9.9"
check "changed Tuist pin regenerates" 1 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"
# shellcheck disable=SC2034
EW_TUIST_PIN="tuist@4.195.11"

new_fixture; settle
printf 'tuistcfg changed\n' > "$FIXTURE/Tuist.swift"
check "changed Tuist.swift regenerates" 1 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

new_fixture; settle
printf 'pkg changed\n' > "$FIXTURE/Package.swift"
check "changed Package.swift regenerates" 1 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

new_fixture; settle
printf 'more\n' > "$FIXTURE/Tuist/Extra.swift"
check "ADDED file under Tuist/ regenerates" 1 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

# THE NEWLINE COLLISION. Joining raw paths with newlines makes the sets
# {"A\nTAIL","B"} and {"A","B\nTAIL"} sort to IDENTICAL text, so a rename between
# those shapes would reuse a stale project — silently, surfacing later as
# "Build input file cannot be found". Hashing each NUL-delimited path first makes
# every entry fixed-width, so the collision is unreachable.
new_fixture
printf 'x\n' > "$FIXTURE/Sources/Mod/$(printf 'A\nTAIL')"
printf 'x\n' > "$FIXTURE/Sources/Mod/B"
settle
rm -f "$FIXTURE/Sources/Mod/$(printf 'A\nTAIL')" "$FIXTURE/Sources/Mod/B"
printf 'x\n' > "$FIXTURE/Sources/Mod/A"
printf 'x\n' > "$FIXTURE/Sources/Mod/$(printf 'B\nTAIL')"
check "newline-collision rename regenerates (key is not raw-joined)" 1 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

# --- Direction 2: MUST NOT regenerate ---------------------------------------
# These are the twins. Without them, a function that always regenerates would
# pass every case above and the check would be worth nothing.

new_fixture; settle
check "no change does NOT regenerate" 0 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

new_fixture; settle
printf 'let x = 99  // edited body\n' > "$FIXTURE/Sources/Mod/A.swift"
check "CONTENT-only source edit does NOT regenerate" 0 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

new_fixture; settle
printf 'let y = 99  // edited body\n' > "$FIXTURE/Tests/ModTests/ATests.swift"
check "CONTENT-only test edit does NOT regenerate" 0 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

new_fixture; settle
touch "$FIXTURE/Sources/Mod/A.swift"
check "TOUCH (mtime only) does NOT regenerate" 0 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

new_fixture; settle
ew_ensure_generated "$FIXTURE" >/dev/null
check "repeated runs do NOT regenerate" 0 "$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"

# --- Fail-closed: a BROKEN key computation must regenerate --------------------
# The key is computed by `find | perl | sort` inside a group piped to shasum. If
# the middle command fails and nothing propagates it, `sort` succeeds on empty
# input and the key becomes a STABLE HASH OF NOTHING — inputs never appear to
# change, so the project is NEVER regenerated. That is the silent-wrong direction.
# Measured 2026-08-18: without `pipefail` it emitted sha256("\n") as a confident
# answer. The implementation now sets `pipefail` in its own subshell so it does
# not depend on the caller, and `ew_ensure_generated` guards on STATUS.
# This case also pins that the caller must check the STATUS and not merely whether
# output is non-empty: a broken run still PRINTS a partial hash.
new_fixture; settle
_real_impl="$(declare -f ew_generation_key_impl)"
eval "$(declare -f ew_generation_key_impl | sed 's/Digest::SHA=sha256_hex/Digest::NOPE=sha256_hex/')"
broken_count="$(ew_ensure_generated "$FIXTURE" >/dev/null 2>&1; generate_count)"
eval "$_real_impl"
check "a BROKEN key computation regenerates (fails closed)" 1 "$broken_count"

# --- Mutation control -------------------------------------------------------
# A suite that cannot fail is indistinguishable from one that was deleted. Break
# the key deliberately and require the no-change twin to go RED. If this control
# passes, the assertions above are not binding and the whole file is theatre.
new_fixture; settle
_real_key="$(declare -f ew_generation_key)"
ew_generation_key() { printf '%s\n' "always-different-$RANDOM$RANDOM"; }
mutant_count="$(ew_ensure_generated "$FIXTURE" >/dev/null; generate_count)"
eval "$_real_key"
if [ "$mutant_count" = "0" ]; then
  FAIL=$((FAIL + 1))
  printf '  FAIL  mutation control — a always-changing key did NOT trigger a regenerate; the assertions are vacuous\n'
else
  PASS=$((PASS + 1))
  printf '  PASS  mutation control (broken key regenerates, so the no-change twin is binding)\n'
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
# Fail closed on an empty run: zero assertions is not a pass.
if [ "$((PASS + FAIL))" -lt 21 ]; then
  printf 'ERROR: expected at least 21 assertions, ran %s — the harness did not run fully\n' "$((PASS + FAIL))"
  exit 1
fi
[ "$FAIL" -eq 0 ] || exit 1
