#!/bin/bash
# Self-test for check-weak-linked-symbols.sh.
#
# Exists because a guard that cannot fail is indistinguishable from a guard that passes, and
# this repo has repeatedly found guards that had quietly stopped inspecting anything. Every
# case below drives the real script against a real binary and asserts the EXIT CODE, including
# the cases where the script must refuse to answer.
#
# Usage: check-weak-linked-symbols-test.sh <path-to-macho-binary>

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/check-weak-linked-symbols.sh"
BIN="${1:-}"

[ -n "$BIN" ] || { echo "usage: $0 <path-to-macho-binary>" >&2; exit 2; }
[ -f "$BIN" ] || { echo "FAIL: binary not found: $BIN" >&2; exit 2; }
[ -x "$SUT" ] || { echo "FAIL: subject not executable: $SUT" >&2; exit 2; }

# A mutant that does not RUN exits 126/127 and reads as failure everywhere, which would hide
# that the defence was never exercised. Parse-check first.
bash -n "$SUT" || { echo "FAIL: subject does not parse" >&2; exit 2; }

pass=0
fail=0

expect() {
  local want="$1" name="$2"; shift 2
  local out; out=$("$@" 2>&1); local got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  ok   [$got] $name"
    pass=$((pass + 1))
  else
    echo "  FAIL [got $got, want $want] $name" >&2
    printf '%s\n' "$out" | sed 's/^/       /' >&2
    fail=$((fail + 1))
  fi
}

# Asserts on a MESSAGE rather than an exit code, for checks whose failure another check would
# also produce. A non-zero exit is required too: a matching message on a passing run would mean
# the text appeared somewhere harmless.
expect_output() {
  local want="$1" name="$2"; shift 2
  local out; out=$("$@" 2>&1); local code=$?
  # **Counted, not `grep -q`** — the same pipefail trap this suite's subject already carries a
  # comment about, sitting in the harness that verifies it. `grep -q` exits on its first match,
  # `printf` takes SIGPIPE, and under `set -o pipefail` the condition reads false: a correctly
  # rejected mutant would fail the self-test and block the required gate, and only once output
  # grew past the pipe buffer. Latent today, hostile later.
  local hits; hits=$(printf '%s' "$out" | /usr/bin/grep -c "$want")
  if [ "$code" -ne 0 ] && [ "$hits" -gt 0 ]; then
    echo "  ok   [$code, matched] $name"
    pass=$((pass + 1))
  else
    echo "  FAIL [exit $code; wanted nonzero AND '$want'] $name" >&2
    printf '%s\n' "$out" | sed 's/^/       /' >&2
    fail=$((fail + 1))
  fi
}

# Variants are generated from the real script so they cannot drift away from it.
#
# **A substitution that changes nothing is refused.** Renaming a variable in the subject used to
# leave these variants byte-identical to it, so the cases that must FAIL quietly passed and the
# suite still reported green on the ones that could not drift. A mutation that does not mutate is
# a test of nothing.
variant() {
  local path="$1" from="$2" to="$3"
  sed "s/^$from/$to/" "$SUT" > "$path" || return 1
  if cmp -s "$SUT" "$path"; then
    echo "  FAIL [variant is identical to the subject] pattern never matched: $from" >&2
    fail=$((fail + 1))
    return 1
  fi
  chmod +x "$path"
}

# Variants live in $TMP, where `$0/../..` is not the repo. Give them the real manifest so the
# deployment-target assertion resolves for every case that is not about the manifest itself.
export EW_PROJECT_MANIFEST="$HERE/../../Project.swift"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> self-test: $SUT"

# The real binary must pass. Without this the suite could go green with everything broken.
expect 0 "the shipped binary passes" "$SUT" "$BIN"

# The assertion fires. AppKit is linked normally, so guarding it MUST report strong symbols
# AND a strong LC_LOAD_DYLIB. This one variant covers both failure kinds, which is why the
# next case exists: to prove the load-command check can fail on its own.
variant "$TMP/strong.sh" 'ABSENT_AT_BASELINE_FRAMEWORKS="FoundationModels"' 'ABSENT_AT_BASELINE_FRAMEWORKS="AppKit"'
expect 1 "a strongly-bound framework is rejected" "$TMP/strong.sh" "$BIN"

# The load-command check must be shown to FIRE, not merely to be present. Exit code alone
# cannot show it: a strongly-loaded framework usually has strong symbols too, so the symbol
# check would explain the failure by itself. Asserting the message attributes the failure.
variant "$TMP/load.sh" 'ABSENT_AT_BASELINE_FRAMEWORKS="FoundationModels"' 'ABSENT_AT_BASELINE_FRAMEWORKS="AVFoundation"'
expect_output "must be LC_LOAD_WEAK_DYLIB" "a strongly-LOADED framework is named as such" "$TMP/load.sh" "$BIN"

# The instrument's own control. If it cannot tell weak from strong, it must refuse to answer
# rather than report the pass it would otherwise print.
#
# **The stand-in must be a framework that is guaranteed to stay fully weak.** `Speech` was the
# obvious pick and was wrong: the production guard deliberately ALLOWS baseline-era Speech APIs,
# so adding something like `SFSpeechRecognizer` would legitimately give Speech strong symbols,
# this mutant would stop refusing, and the self-test would block a change the guard permits.
# `FoundationModels` cannot drift that way, because the guard itself requires it to be fully
# weak — if it ever were not, the real check would fail before this control could mislead.
variant "$TMP/badctl.sh" 'CONTROL_FRAMEWORK="AppKit"' 'CONTROL_FRAMEWORK="FoundationModels"'
expect 2 "a control that reports weak refuses to give a verdict" "$TMP/badctl.sh" "$BIN"

variant "$TMP/noctl.sh" 'CONTROL_FRAMEWORK="AppKit"' 'CONTROL_FRAMEWORK="NoSuchFrameworkXYZ"'
expect 2 "an absent control refuses to give a verdict" "$TMP/noctl.sh" "$BIN"

# A guard list matching nothing is a guard checking nothing, and must not pass.
variant "$TMP/nofw.sh" 'NEWER_SYMBOL_PATTERNS="SpeechAnalyzer DictationTranscriber AssetInventory"' 'NEWER_SYMBOL_PATTERNS="NoSuchTypeXYZ"'
expect 2 "a symbol-pattern list matching nothing refuses to pass" "$TMP/nofw.sh" "$BIN"

# **The regression that made this whole check vacuous for one type.** Matching against RAW nm
# output finds nothing for `SpeechAnalyzer`, because Swift mangles it as `0A8Analyzer` — the
# module prefix is substituted away. The guard read that as "type unused" and passed. Every
# pattern is now required to match, so reverting to raw symbols must fail, not shrug.
# Caught by the demangler control, which fires BEFORE the pattern loop: raw mangled output
# contains no readable Swift signature, so the guard refuses to give a verdict at all rather
# than reaching the patterns and reporting a type as unused. Asserting the refusal (exit 2) is
# asserting the real behaviour; an earlier draft of this case expected the later message and
# failed, which is the defence-in-depth working, not a bug.
# shellcheck disable=SC2016  # deliberate: these are sed patterns, the $ must stay literal
variant "$TMP/raw.sh" 'SYMS_READABLE=\$(printf .%s\\n. "\$SYMS" | xcrun swift-demangle 2>\/dev\/null)' 'SYMS_READABLE="$SYMS"'
expect 2 "matching raw mangled symbols refuses to give a verdict" "$TMP/raw.sh" "$BIN"

# **A raised deployment target must be rejected, not merely printed.** This is the failure that
# would leave every check below immaculate and the product unlaunchable for supported users:
# every weak-linkage verdict is RELATIVE to the target, so raising it keeps them all green.
#
# Driven by pointing the real script at a manifest declaring a different floor, rather than by
# editing the script. Editing it was the first approach and it was wrong twice over: the sed
# pattern contained slashes, and a copy in a temp dir resolves its repo root elsewhere, which
# broke every OTHER case instead of testing this one.
printf 'let deploymentTargets: DeploymentTargets = .macOS("99.0")\n' > "$TMP/Fake.swift"
out=$(EW_PROJECT_MANIFEST="$TMP/Fake.swift" "$SUT" "$BIN" 2>&1); code=$?
floor_hits=$(printf '%s' "$out" | /usr/bin/grep -c "Reconcile the two deliberately")
if [ "$code" -ne 0 ] && [ "$floor_hits" -gt 0 ]; then
  echo "  ok   [$code, matched] a binary whose target disagrees with the declared floor is rejected"
  pass=$((pass + 1))
else
  echo "  FAIL [exit $code; wanted nonzero AND the reconcile message] declared-floor mismatch" >&2
  printf '%s\n' "$out" | sed 's/^/       /' >&2
  fail=$((fail + 1))
fi

# An unreadable manifest must refuse, not fall back to trusting the binary.
out=$(EW_PROJECT_MANIFEST="$TMP/does-not-exist.swift" "$SUT" "$BIN" 2>&1); code=$?
if [ "$code" -eq 2 ]; then
  echo "  ok   [2] an unreadable manifest refuses to certify the deployment target"
  pass=$((pass + 1))
else
  echo "  FAIL [got $code, want 2] unreadable manifest" >&2
  fail=$((fail + 1))
fi

# Fails closed on every input it cannot measure.
expect 2 "missing file" "$SUT" "$TMP/does-not-exist"
expect 2 "not a Mach-O binary" "$SUT" "$SUT"
expect 2 "no argument" "$SUT"

# ---------------------------------------------------------------------------------------------
# BUNDLE MODE.
#
# Everything above drives a plain Mach-O, which exercises the main-executable path only. The
# EMBEDDED path had no coverage at all, and that is where the reads used to fail open: `lipo`,
# `otool` and `nm` had their exit statuses discarded, so a binary the script could not read
# produced empty output, and empty output is spelled the same as "inspected and clean".
#
# The bundle is assembled from the real subject binary so the main-executable checks pass and
# the embedded behaviour is what is under test.
BUNDLE="$TMP/Probe.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Frameworks"
cp "$BIN" "$BUNDLE/Contents/MacOS/Probe"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Probe</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST

# Read the declared floor the same way the subject does, so these cases assert against the real
# value rather than a second hardcoded copy of it that could drift away from Project.swift.
DECLARED_FLOOR=$(/usr/bin/grep -oE 'DeploymentTargets = \.macOS\("[0-9]+\.[0-9]+"\)' "$EW_PROJECT_MANIFEST" | /usr/bin/grep -oE '[0-9]+\.[0-9]+' | head -1)
if [ -z "$DECLARED_FLOOR" ]; then
  echo "  FAIL [fixture] could not read the declared floor from $EW_PROJECT_MANIFEST" >&2
  fail=$((fail + 1))
  DECLARED_FLOOR="14.0"
fi
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $DECLARED_FLOOR" "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1

# A truncated Mach-O: `file` still classifies it, so the enumeration picks it up, while `lipo`
# and `nm` refuse it. Before the exit statuses were checked this printed "no arm64 slice ()" —
# the same sentence as a legitimate skip, differing only by an empty parenthesis — and passed.
head -c 512 "$BIN" > "$BUNDLE/Contents/Frameworks/Truncated.dylib"
if [ "$(file "$BUNDLE/Contents/Frameworks/Truncated.dylib" | grep -c 'Mach-O')" -eq 0 ]; then
  echo "  FAIL [fixture] the truncated file is not classified as Mach-O, so the enumeration would skip it and this case would test nothing" >&2
  fail=$((fail + 1))
else
  expect_output "refusing to certify a binary this script cannot inspect" \
    "an embedded Mach-O the tools cannot read fails the gate instead of passing quietly" \
    "$SUT" "$BUNDLE"
fi

# Control for the case above: the SAME bundle with a readable embedded Mach-O must pass. Without
# this, "the bundle case fails" would be indistinguishable from "bundle mode is broken".
#
# **The control binary must carry an arm64 slice, or it proves nothing.** A first draft used
# `/usr/lib/dyld`, which is `x86_64 arm64e` — no plain arm64 — so the script skipped it and the
# case passed without inspecting anything, which is the very failure this section exists to
# catch. The subject binary is arm64 by definition, so it is the honest control.
cp "$BIN" "$BUNDLE/Contents/Frameworks/Embedded.dylib"
rm -f "$BUNDLE/Contents/Frameworks/Truncated.dylib"
ctl_out=$("$SUT" "$BUNDLE" 2>&1); ctl_code=$?
ctl_scanned=$(printf '%s' "$ctl_out" | /usr/bin/grep -c "of which arm64 and inspected: 1")
ctl_skipped=$(printf '%s' "$ctl_out" | /usr/bin/grep -c "no arm64 slice")
if [ "$ctl_code" -eq 0 ] && [ "$ctl_scanned" -gt 0 ] && [ "$ctl_skipped" -eq 0 ]; then
  echo "  ok   [0] the same bundle with a readable arm64 embedded Mach-O passes, having actually inspected it"
  pass=$((pass + 1))
else
  echo "  FAIL [exit $ctl_code; scanned=$ctl_scanned skipped=$ctl_skipped] readable embedded control" >&2
  printf '%s\n' "$ctl_out" | sed 's/^/       /' >&2
  fail=$((fail + 1))
fi

# **An embedded binary whose deployment target cannot be read must not be certified.** The
# assertion used to be written `[ -n "$extra_minos" ] && [ ... ]`, so a binary that did not say
# what it required was waved through — a macOS 15 dependency certified for 14 by silence.
#
# Driven by a mutant rather than a fixture, because no supported linker will emit a Mach-O with
# no version load command: `ld` rejects `-no_version_load_command`, and all 9 arm64 Mach-O files
# in the real bundle carry LC_BUILD_VERSION. Blanking the primary parse leaves the legacy
# LC_VERSION_MIN_MACOSX fallback to find nothing either, which is exactly the state under test.
variant "$TMP/nominos.sh" '    extra_minos=.*' '    extra_minos=""'
expect_output "records no deployment target" \
  "an embedded binary with no readable deployment target is refused, not certified" \
  "$TMP/nominos.sh" "$BUNDLE"

# Same shape for the load-command list: an empty parse used to make every framework check below
# skip without a word. Measured on the real bundle, its embedded binaries report 1 to 63 load
# commands, so empty means the parser broke.
variant "$TMP/noloads.sh" '    extra_loads=.*' '    extra_loads=""'
expect_output "no dynamic library load commands were parsed" \
  "an embedded binary whose load commands cannot be parsed is refused, not certified" \
  "$TMP/noloads.sh" "$BUNDLE"

# **Launch Services minimum.** This value is a hardcoded literal in checked-in plists, derived
# from nothing, and Launch Services reads it instead of the Mach-O load command — so raising it
# locks macOS 14 users out of an app whose binary checks are all green. The launch probe cannot
# see it either, because invoking the executable directly bypasses Launch Services.
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 99.0" "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1
expect_output "Launch Services would refuse to start the app" \
  "an app plist demanding a newer macOS than the declared floor is rejected" \
  "$SUT" "$BUNDLE"

# A BUNDLED plist may legitimately declare an OLDER minimum — Sparkle says 10.13, PostHog 10.15 —
# so the rule for those is "may not exceed", not "must equal". Without this case the check could
# be tightened to equality and fail on honest dependencies.
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $DECLARED_FLOOR" "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1
mkdir -p "$BUNDLE/Contents/Frameworks/Old.framework"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>LSMinimumSystemVersion</key><string>10.13</string></dict></plist>\n' \
  > "$BUNDLE/Contents/Frameworks/Old.framework/Info.plist"
expect 0 "a bundled plist declaring an OLDER minimum is accepted" "$SUT" "$BUNDLE"

# ...but one declaring a NEWER minimum is not.
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 99.0" "$BUNDLE/Contents/Frameworks/Old.framework/Info.plist" >/dev/null 2>&1
expect_output "above the declared floor" \
  "a bundled plist demanding a newer macOS than the declared floor is rejected" \
  "$SUT" "$BUNDLE"
rm -rf "$BUNDLE/Contents/Frameworks/Old.framework"

# An app plist that declares no minimum at all has asserted nothing about whether it can start.
/usr/libexec/PlistBuddy -c "Delete :LSMinimumSystemVersion" "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1
expect 2 "an app plist with no minimum at all refuses to certify the bundle" "$SUT" "$BUNDLE"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string $DECLARED_FLOOR" "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1

# **A bundle whose embedded Mach-O files are all the wrong architecture inspected nothing.**
#
# The count used to increment BEFORE the architecture skip, so a file that was found and then
# skipped still satisfied the "something was inspected" assertion. `/usr/lib/dyld` is the honest
# fixture for this: it is `x86_64 arm64e`, with no plain arm64 slice, which is exactly why it
# made an earlier version of the control case above pass without inspecting anything.
rm -f "$BUNDLE/Contents/Frameworks/Embedded.dylib"
if [ -f /usr/lib/dyld ] && [ "$(lipo -archs /usr/lib/dyld 2>/dev/null | /usr/bin/grep -cE '(^| )arm64( |$)')" -eq 0 ]; then
  cp /usr/lib/dyld "$BUNDLE/Contents/Frameworks/WrongArch.dylib"
  expect_output "no embedded arm64 Mach-O file was inspected" \
    "a bundle whose embedded binaries are all the wrong architecture is refused, not certified" \
    "$SUT" "$BUNDLE"
  rm -f "$BUNDLE/Contents/Frameworks/WrongArch.dylib"
else
  echo "  FAIL [fixture] /usr/lib/dyld now reports a plain arm64 slice, so it no longer tests the architecture skip" >&2
  fail=$((fail + 1))
fi

# A bundle that yields no embedded Mach-O at all means the enumeration broke. It used to print
# "scanned: 0" and pass.
expect_output "found 0 Mach-O in total" \
  "a bundle with nothing embedded at all is refused, not certified" \
  "$SUT" "$BUNDLE"

echo "==> $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
