#!/bin/bash
# Assert that every symbol we import from a newer-than-deployment-target framework is
# WEAKLY bound, so the app starts on the oldest macOS we support.
#
# The failure this prevents: the app is built against the macOS 26 SDK but ships with a
# macOS 14 deployment target. A reference to a macOS 26 symbol that is bound STRONGLY makes
# dyld abort at launch on macOS 14/15 — before any `#available` check in our code can run, so
# the app never opens and no in-app "needs a newer macOS" message is ever reached. Swift emits
# weak bindings automatically for correctly `@available`-annotated code; the regression is
# therefore silent on the machine that builds it, which is always a macOS 26 runner.
#
# Usage: check-weak-linked-symbols.sh <path-to-macho-binary>
#
# Exit: 0 all guarded frameworks fully weak; 1 a strong binding was found; 2 the check could
# not be performed (fails closed — a check that cannot measure must never report success).

set -uo pipefail

TARGET="${1:-}"

# **Two different rules, because two different things can be missing.** Collapsing them into one
# list produced a false positive that would have failed honest work: review round 4 pointed out
# that `SFSpeechRecognizer` has existed since macOS 10.15, so adding it would legitimately emit a
# strong symbol and flip Speech to LC_LOAD_DYLIB — and the guard would have called that a
# compatibility defect. A guard that fires on safe code is how guards get bypassed.
#
# Verified with `swiftc -target arm64-apple-macos14.0 -typecheck` on 2026-08-16:
#   SFSpeechRecognizer     compiles clean       -> Speech itself is present at the baseline
#   SystemLanguageModel    "only available in macOS 26.0 or newer"

# (1) Frameworks that do not EXIST at the deployment target. A strong load of one of these kills
#     the process before any symbol is resolved, so both the load command and every symbol must
#     be weak. Add a framework here only if the framework itself is absent on macOS 14.
ABSENT_AT_BASELINE_FRAMEWORKS="FoundationModels"

# (2) Types that are newer than the deployment target inside a framework that IS present. Only
#     these symbols must be weak; the framework's load command and its baseline-era symbols are
#     none of this guard's business. Matched against the mangled name, which carries the type.
NEWER_SYMBOL_PATTERNS="SpeechAnalyzer DictationTranscriber AssetInventory"

# A framework we link normally. Its symbols MUST come back strong. This is the instrument's
# own control: if it ever reports weak, `nm` output has changed shape and every "0 strong
# symbols" result above is meaningless rather than reassuring.
CONTROL_FRAMEWORK="AppKit"

die() { echo "FAIL: $1" >&2; exit "${2:-1}"; }

[ -n "$TARGET" ] || die "usage: $0 <path-to-.app-or-macho-binary>" 2
command -v nm >/dev/null 2>&1 || die "nm not available" 2
command -v otool >/dev/null 2>&1 || die "otool not available" 2

# **A bundle is more than its main executable.**
#
# dyld loads embedded frameworks at startup, so a strong post-baseline import inside one of them
# aborts the process just as surely — and none of it appears in the main executable's own
# symbols. This bundle embeds Sparkle (five Mach-O files today), so a dependency bump could
# introduce exactly that without the required gate noticing. Given a .app, every startup-loaded
# Mach-O is inspected; given a plain file, only that file, which keeps the self-test's contract.
EMBEDDED=""
IS_BUNDLE=0
case "$TARGET" in
  *.app)
    IS_BUNDLE=1
    [ -d "$TARGET" ] || die "bundle not found: $TARGET" 2
    MAIN_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$TARGET/Contents/Info.plist" 2>/dev/null)
    [ -n "$MAIN_NAME" ] || die "no CFBundleExecutable in $TARGET/Contents/Info.plist; cannot identify the main binary" 2
    BIN="$TARGET/Contents/MacOS/$MAIN_NAME"
    [ -f "$BIN" ] || die "main executable not found: $BIN" 2
    # **The WHOLE bundle, not a list of directories someone remembered.**
    #
    # Scanning `Contents/Frameworks` alone missed `Contents/XPCServices` — which holds
    # `EnviousWisprASRService.xpc`, the service that performs transcription. That one is the worst
    # possible miss: the launch probe would still pass, because the main process survives, and the
    # app would open on macOS 14 and simply fail to transcribe. CLAUDE.md's core promise is that
    # dictation works across the whole supported range, so a gate that certifies a bundle whose
    # ASR service cannot load is certifying the wrong thing.
    #
    # This bundle also carries a Mach-O under `Contents/Resources`, which a
    # Frameworks-plus-XPCServices list would have missed in turn. Enumerating every Mach-O under
    # Contents is exhaustive by construction, so no future directory can be forgotten.
    # Identified by CONTENT, never by the executable bit: a mode-0644 dylib is still loadable by
    # dyld, so `-perm +111` would skip one silently. 136 files here, 0.08s to classify them all.
    # **`find`'s exit status is checked.** A permission or I/O error partway through leaves it
    # printing the files it did reach and exiting non-zero, so a PARTIAL scan would certify the
    # bundle on the strength of whatever happened to be listed before the error. The count
    # assertions further down prove something was inspected; only this proves the list was whole.
    if ! MACHO_CANDIDATES=$(find "$TARGET/Contents" -type f 2>/dev/null); then
      die "find could not enumerate $TARGET/Contents completely; a partial list cannot certify the bundle" 2
    fi
    EMBEDDED=$(printf '%s\n' "$MACHO_CANDIDATES" | while read -r f; do
      [ "$f" = "$BIN" ] && continue
      # Substring test via parameter expansion: no `grep -q` (pipefail/EPIPE) and no `case`
      # pattern, whose closing paren bash mis-parses inside a $( ) command substitution.
      # A `file` that FAILS means this path could not be classified, which is not the same as
      # "not a Mach-O". Included rather than dropped, so an unreadable file surfaces downstream
      # as a binary the tools cannot inspect instead of vanishing from the enumeration.
      desc=$(file "$f" 2>/dev/null) || desc="Mach-O unclassifiable"
      [ "${desc#*Mach-O}" != "$desc" ] && echo "$f"
    done)
    ;;
  *)
    BIN="$TARGET"
    [ -f "$BIN" ] || die "binary not found: $BIN" 2
    ;;
esac

SYMS=$(nm -m -u "$BIN" 2>/dev/null)
[ -n "$SYMS" ] || die "nm produced no undefined symbols for $BIN — wrong file type, or a stripped or thin binary" 2

# **Match type names against DEMANGLED symbols, never the raw mangled ones.**
#
# Swift mangling substitutes a repeated module prefix, so `Speech.SpeechAnalyzer` is spelled
# `_$s6Speech0A8AnalyzerC…` in the binary and the literal string "SpeechAnalyzer" appears
# nowhere. The previous version matched raw output, found zero, and printed "type unused here,
# or renamed" over 15 real imports — evidence printed and misread, which is worse than no check.
# Demangling removes the guesswork: the readable name is what the pattern list already names.
SYMS_READABLE=$(printf '%s\n' "$SYMS" | xcrun swift-demangle 2>/dev/null)
if [ -z "$SYMS_READABLE" ]; then
  # No silent fallback to raw symbols: that is precisely the state that produced a false pass.
  die "swift-demangle produced nothing; type-name patterns cannot be matched against mangled symbols without silently missing them" 2
fi
# Control for the demangler itself: a readable Swift name must appear, or it did not demangle.
#
# Counted, NOT `grep -q`. Under `set -o pipefail`, `grep -q` exits on its first match, `printf`
# then dies of EPIPE, and the pipeline reports failure — so this control fired against 1502
# genuine matches and killed a correct run. A guard whose success path looks like its failure
# path is worse than no guard, and this is the second pipefail trap in this file's history.
READABLE_SIGNATURES=$(printf '%s\n' "$SYMS_READABLE" | /usr/bin/grep -cE '\.getter|\.setter| -> |\.init\(')
if [ "$READABLE_SIGNATURES" -eq 0 ]; then
  die "swift-demangle output contains no recognisably demangled Swift signature; every type-name verdict below would be vacuous. If this is a DEBUG bundle, its Contents/MacOS/<name> is a thin launcher and the code lives in <name>.debug.dylib — pass that file directly. CI passes the Release .app, whose main executable carries the code." 2
fi

MINOS=$(otool -l "$BIN" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
echo "==> binary:            $BIN"
echo "==> deployment target: ${MINOS:-unknown}"

# **The deployment target is ASSERTED against the declared support floor, not merely printed.**
#
# Everything below is relative: raise the target to 15.0 and macOS 26 symbols are still weak
# relative to it, so every check here still passes — while the app has become unlaunchable for
# every macOS 14 user we claim to support. The linkage would be immaculate and the product
# broken for a whole population, which is a worse outcome than the defect this script was
# written for. Read from `Project.swift` so there is one source of truth; a mismatch means
# either an accidental bump or a deliberate one that has not updated the floor here.
[ -n "$MINOS" ] || die "could not read the deployment target from $BIN; every relative check below would be meaningless" 2

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# Overridable so the self-test can point at a manifest declaring a DIFFERENT floor and prove this
# assertion rejects it. Without the override the test would have to edit this script, and a copy
# placed elsewhere resolves `$0/../..` to the wrong root — which is how the first draft of that
# test broke every other case rather than testing this one.
MANIFEST="${EW_PROJECT_MANIFEST:-$REPO_ROOT/Project.swift}"
[ -f "$MANIFEST" ] || die "cannot find $MANIFEST to read the declared support floor; refusing to certify a deployment target against nothing" 2
DECLARED=$(/usr/bin/grep -oE 'DeploymentTargets = \.macOS\("[0-9]+\.[0-9]+"\)' "$MANIFEST" | /usr/bin/grep -oE '[0-9]+\.[0-9]+' | head -1)
[ -n "$DECLARED" ] || die "could not parse the declared macOS floor from $MANIFEST; the pattern has drifted and this assertion would silently stop running" 2

if [ "$MINOS" != "$DECLARED" ]; then
  die "binary targets macOS $MINOS but $MANIFEST declares $DECLARED. A raised target ships an app that will not launch for supported users, and every weak-linkage check below is relative to the target so it would still pass. Reconcile the two deliberately." 1
fi
echo "==> floor asserted:    binary $MINOS matches Project.swift $DECLARED"

count_for() { printf '%s\n' "$SYMS" | /usr/bin/grep -c "(from $1)"; }
count_strong_for() {
  printf '%s\n' "$SYMS" | /usr/bin/grep "(from $1)" | /usr/bin/grep -vc 'weak external'
}

# **The load command matters independently of the symbols.**
#
# **Any dylib command except the library's own ID counts as a dependency, and only
# LC_LOAD_WEAK_DYLIB counts as weak.** Matching just LC_LOAD_DYLIB and LC_LOAD_WEAK_DYLIB ignored
# LC_REEXPORT_DYLIB entirely — a strong requirement dyld still enforces, so a framework built with
# `-reexport_framework FoundationModels` would have passed with no direct symbols of its own.
# Written as "everything except LC_ID_DYLIB" rather than a list of strong forms, so a command type
# nobody here has seen is treated as strong instead of ignored. LC_ID_DYLIB is excluded because it
# is the library's OWN install name, not something it depends on; matching it would fail every
# framework against itself. Forms present in this bundle today: LC_ID_DYLIB, LC_LOAD_DYLIB,
# LC_LOAD_WEAK_DYLIB.
#
# A framework recorded as LC_LOAD_DYLIB is loaded STRONGLY: if it is absent on the running OS,
# dyld aborts before it resolves a single symbol, so every symbol being weak buys nothing.
# FoundationModels does not exist at all below macOS 26, which makes this the more severe of
# the two failures — and it is invisible to `nm`, since symbol annotations and load commands
# are set independently (manual linker flags, or a post-link edit, can move one without the
# other). Review round 3 found this gap; the earlier version checked only symbols.
# One parser, used for the main binary and for every embedded one. It was duplicated verbatim,
# which is how the two halves of this script drifted apart in the first place: a rule tightened
# in one copy and not the other reads as a rule that applies everywhere.
#
# Emits "<load-command> <path>" per linked dylib. LC_ID_DYLIB is excluded because it is the
# library's own install name, not a dependency; LC_REEXPORT_DYLIB is deliberately included,
# since re-exporting is as strong a load as any.
dylib_loads_from() {
  printf '%s\n' "$1" |
    awk '/^ *cmd LC_[A-Z_]*DYLIB/ && $2 != "LC_ID_DYLIB" {c=$2} /^ *name /{if(c!=""){print c, $2; c=""}}'
}

LOADS=$(dylib_loads_from "$(otool -l "$BIN" 2>/dev/null)")

load_command_for() {
  printf '%s\n' "$LOADS" | awk -v fw="/$1.framework/" 'index($2, fw) {print $1; exit}'
}

# --- Instrument control, BEFORE any verdict -----------------------------------------------
# Runs first so a broken detector can never produce a green run.
CONTROL_TOTAL=$(count_for "$CONTROL_FRAMEWORK")
CONTROL_STRONG=$(count_strong_for "$CONTROL_FRAMEWORK")
if [ "$CONTROL_TOTAL" -eq 0 ]; then
  die "control framework $CONTROL_FRAMEWORK contributed no symbols; this binary is not the app, or nm output changed" 2
fi
if [ "$CONTROL_STRONG" -eq 0 ]; then
  die "control framework $CONTROL_FRAMEWORK reported ZERO strong symbols. A normally-linked framework must be strong, so this detector cannot tell weak from strong and its results below are meaningless" 2
fi
echo "==> control ok:        $CONTROL_FRAMEWORK has $CONTROL_STRONG strong of $CONTROL_TOTAL (detector distinguishes weak from strong)"

# The load-command reader needs its own control, for the same reason: a parser that returns
# nothing would make every "weakly loaded" verdict below vacuous.
[ -n "$LOADS" ] || die "could not read any dylib load commands from $BIN; the load-command check below would be vacuous" 2
CONTROL_LOAD=$(load_command_for "$CONTROL_FRAMEWORK")
if [ "$CONTROL_LOAD" != "LC_LOAD_DYLIB" ]; then
  die "control framework $CONTROL_FRAMEWORK reports load command '${CONTROL_LOAD:-none}', expected LC_LOAD_DYLIB. A normally-linked framework must load strongly, so this parser cannot tell a weak load from a strong one" 2
fi
echo "==> control ok:        $CONTROL_FRAMEWORK loads as LC_LOAD_DYLIB (parser distinguishes weak from strong loads)"

# --- The actual assertion ------------------------------------------------------------------
status=0
checked=0
# (1) Frameworks absent at the baseline: both the load command and every symbol must be weak.
for fw in $ABSENT_AT_BASELINE_FRAMEWORKS; do
  total=$(count_for "$fw")
  load=$(load_command_for "$fw")

  # **The load command is checked FIRST, and whether or not the framework contributed symbols.**
  # An earlier version skipped a framework with no symbols, which would have waved through the
  # worst case available: one reached only through the ObjC runtime, strongly loaded, absent on
  # the older OS. Zero symbols is when the load command matters MOST, not least.
  if [ -n "$load" ]; then
    checked=$((checked + 1))
    if [ "$load" != "LC_LOAD_WEAK_DYLIB" ]; then
      echo "    $fw: loaded as $load, must be LC_LOAD_WEAK_DYLIB (framework absent below the baseline)" >&2
      status=1
    fi
  fi

  if [ "$total" -eq 0 ]; then
    if [ -n "$load" ]; then
      echo "    $fw: no symbols in this binary, loaded as $load"
    else
      echo "    $fw: not linked into this binary at all"
    fi
    continue
  fi

  checked=$((checked + 1))
  strong=$(count_strong_for "$fw")
  if [ "$strong" -ne 0 ]; then
    echo "    $fw: $strong of $total symbols are STRONGLY bound" >&2
    printf '%s\n' "$SYMS" | /usr/bin/grep "(from $fw)" | /usr/bin/grep -v 'weak external' | sed 's/^/      /' >&2
    status=1
  elif [ "$load" = "LC_LOAD_WEAK_DYLIB" ]; then
    echo "    $fw: all $total symbols weak, loaded weakly ✓"
  fi
done

# (2) Newer types inside frameworks that DO exist at the baseline. Only these symbols are
#     constrained; the framework's load command and its baseline-era symbols are left alone, so
#     adding an API that macOS 14 already has does not trip this guard.
# **Every configured pattern must match.** Tolerating a zero-match pattern is what let a
# mangling mismatch read as "unused": the other two patterns still matched, the run passed, and
# a strong SpeechAnalyzer import would have sailed through. A type that genuinely stops being
# used should be REMOVED from the list by a person, which is a deliberate act that gets reviewed.
unmatched=""
for pattern in $NEWER_SYMBOL_PATTERNS; do
  hits=$(printf '%s\n' "$SYMS_READABLE" | /usr/bin/grep -c "$pattern")
  if [ "$hits" -eq 0 ]; then
    echo "    $pattern: NO SYMBOLS — renamed, or no longer used" >&2
    unmatched="$unmatched $pattern"
    continue
  fi
  checked=$((checked + 1))
  strong=$(printf '%s\n' "$SYMS_READABLE" | /usr/bin/grep "$pattern" | /usr/bin/grep -vc 'weak external')
  if [ "$strong" -ne 0 ]; then
    echo "    $pattern: $strong of $hits symbols are STRONGLY bound" >&2
    printf '%s\n' "$SYMS_READABLE" | /usr/bin/grep "$pattern" | /usr/bin/grep -v 'weak external' | sed 's/^/      /' >&2
    status=1
  else
    echo "    $pattern: all $hits symbols weak ✓"
  fi
done

if [ -n "$unmatched" ]; then
  die "these newer-symbol patterns matched nothing:$unmatched. Either the type was renamed (the guard has stopped watching it) or the app no longer uses it (remove it from NEWER_SYMBOL_PATTERNS deliberately). A pattern that inspects nothing must not contribute to a pass" 2
fi

if [ "$checked" -eq 0 ]; then
  die "nothing was inspected: neither the absent-at-baseline frameworks ($ABSENT_AT_BASELINE_FRAMEWORKS) nor the newer-symbol patterns appear in this binary" 2
fi

# (2b) `LSMinimumSystemVersion`, which decides whether the app launches AT ALL.
#
# This value is a hardcoded literal in checked-in Info.plist files and is derived from nothing:
# raising it to 15.0 while the deployment target stays at 14.0 leaves the Mach-O checks above
# entirely green, because the binary is unchanged. Launch Services reads the plist, not the load
# command, so Finder and `open` would refuse to start the app for every macOS 14 user while both
# compatibility checks report success. The launch probe cannot catch it either: it invokes the
# executable directly, which bypasses Launch Services by construction.
#
# The rule mirrors the binary rule exactly, and for the same reasons. The app's OWN plist must
# EQUAL the declared floor: above it locks out supported users, below it advertises support the
# build does not provide. Every other plist may only not EXCEED the floor, because a bundled
# dependency legitimately supports older systems than we ship to. Measured on the real bundle:
# 14 Info.plist files, ours declaring 14.0 and Sparkle's and PostHog's declaring 10.13 and 10.15,
# so an equality rule applied to all of them would fail on honest dependencies.
#
# **TWO keys govern this, not one.** `LSMinimumSystemVersionByArchitecture` carries a per-arch
# override, so a plist can keep the generic key at the floor and raise the `arm64` entry, which
# is the only architecture we ship. Checking one key and not the other is how a sweep of a SET
# misses a member. Neither key's arm64 entry appears anywhere in this repo or in any of the 14
# plists in the built bundle today, so this is a guard against a future edit rather than a live
# defect — and whether Launch Services honours an arm64 entry is NOT established here, only that
# covering it costs one more read.
assert_ls_min() { # <label> <value> <is-main:0|1>; returns 1 if the value is unacceptable
  local label="$1" value="$2" is_main="$3"
  if [ "$is_main" -eq 1 ]; then
    if [ "$value" != "$DECLARED" ]; then
      echo "    $label is $value but the declared floor is $DECLARED. Launch Services would refuse to start the app for supported users, or advertise support this build does not provide" >&2
      return 1
    fi
  elif [ "$value" != "$DECLARED" ] &&
       [ "$(printf '%s\n%s\n' "$value" "$DECLARED" | sort -V | tail -1)" = "$value" ]; then
    echo "    $label is $value, above the declared floor $DECLARED" >&2
    return 1
  fi
  return 0
}

if [ "$IS_BUNDLE" -eq 1 ]; then
  # Same reasoning as the Mach-O enumeration: a partial plist list must not certify the bundle.
  if ! PLIST_LIST=$(find "$TARGET" -name "Info.plist" 2>/dev/null); then
    die "find could not enumerate the Info.plist files in $TARGET completely; a partial list cannot certify the bundle" 2
  fi
  main_plist_seen=0
  while IFS= read -r plist; do
    [ -n "$plist" ] || continue
    rel="${plist#"$TARGET"/}"
    is_main=0
    [ "$plist" = "$TARGET/Contents/Info.plist" ] && is_main=1

    lsmin=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$plist" 2>/dev/null)
    if [ -n "$lsmin" ]; then
      [ "$is_main" -eq 1 ] && main_plist_seen=1
      assert_ls_min "$rel: LSMinimumSystemVersion" "$lsmin" "$is_main" || status=1
    fi

    lsarm=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersionByArchitecture:arm64" "$plist" 2>/dev/null)
    if [ -n "$lsarm" ]; then
      assert_ls_min "$rel: LSMinimumSystemVersionByArchitecture:arm64" "$lsarm" "$is_main" || status=1
    fi
  done <<EOF
$PLIST_LIST
EOF
  # The app's own plist declaring nothing is not a pass: it is the one Launch Services consults,
  # and a check that never found it has asserted nothing about whether the app can start.
  if [ "$main_plist_seen" -eq 0 ]; then
    die "no LSMinimumSystemVersion in $TARGET/Contents/Info.plist. That is the value Launch Services uses to decide whether this app runs, and an absent one cannot be reconciled with the declared floor $DECLARED" 2
  fi
  echo "==> LSMinimumSystemVersion: app declares $DECLARED, no bundled plist exceeds it"
fi

# (3) Embedded Mach-O files. Only the baseline-absent frameworks are checked here, and only IF
#     referenced: an embedded framework has no obligation to use them, so requiring a match would
#     fail every honest dependency. The main executable above is what carries the
#     something-was-inspected requirement.
embedded_count=0
embedded_arm64_count=0
if [ -n "$EMBEDDED" ]; then
  while IFS= read -r extra; do
    [ -n "$extra" ] || continue
    embedded_count=$((embedded_count + 1))
    # **The arm64 slice specifically.** Every Sparkle binary here is universal, and an
    # unqualified otool/nm reports every slice at once: `awk ... exit` then takes whichever load
    # command appears first, which may be the x86_64 one. We ship arm64 only, so an x86_64 slice
    # targeting macOS 11 must never vouch for an arm64 slice targeting 15. Measured on this
    # bundle: Sparkle's x86_64 slice carries no LC_BUILD_VERSION at all, so the unqualified read
    # landed on arm64 by luck rather than by design.
    # **Every read here FAILS CLOSED, the way the main binary's reads already do.**
    #
    # This loop used to swallow the exit status of `lipo`, `otool` and `nm` and keep whatever
    # they left behind, which was the empty string. Empty output then passes every test below:
    # no architectures reads as "no arm64 slice, skip", no load commands reads as "does not
    # reference the framework, skip", and no symbols makes every `grep -c` return zero, which
    # is spelled exactly like "inspected and clean". So a binary this script could not read at
    # all contributed a silent PASS to a REQUIRED gate.
    #
    # The main-executable path above already dies on each of these. The asymmetry was the bug:
    # the same failure was fatal for one file and invisible for the next one along.
    if ! extra_archs=$(lipo -archs "$extra" 2>&1); then
      echo "    $(basename "$extra"): lipo could not read its architectures ($extra_archs); refusing to certify a binary this script cannot inspect" >&2
      status=1
      continue
    fi
    case " $extra_archs " in *" arm64 "*) ;; *)
      echo "    $(basename "$extra"): no arm64 slice ($extra_archs); not checked"
      continue ;;
    esac
    # Counted AFTER the architecture skip, because the file counted above may never be inspected.
    # `embedded_count` alone was satisfied by a file this loop then skipped, so a bundle whose
    # embedded binaries were all x86_64-only would satisfy the assertion below having inspected
    # nothing for the architecture we actually ship.
    embedded_arm64_count=$((embedded_arm64_count + 1))

    # Read the load commands ONCE and derive both answers from that single output, so the load
    # list and the deployment target can never come from two different reads of the same file.
    if ! extra_otool=$(otool -arch arm64 -l "$extra" 2>&1); then
      echo "    $(basename "$extra"): otool could not read its load commands ($extra_otool); refusing to certify a binary this script cannot inspect" >&2
      status=1
      continue
    fi
    extra_loads=$(dylib_loads_from "$extra_otool")
    # A Mach-O that links nothing would make every framework check below skip silently. Measured:
    # all 9 arm64 embedded Mach-O files in the real bundle report between 1 and 63 load commands,
    # so an empty list means the parse stopped working, not that the binary is self-contained.
    if [ -z "$extra_loads" ]; then
      echo "    $(basename "$extra"): no dynamic library load commands were parsed, so the framework checks below would inspect nothing" >&2
      status=1
    fi
    if ! extra_syms=$(nm -arch arm64 -m -u "$extra" 2>&1); then
      echo "    $(basename "$extra"): nm could not read its undefined symbols ($extra_syms); every symbol verdict below would be vacuously clean" >&2
      status=1
      continue
    fi

    # **Its own deployment target, which the main executable's says nothing about.** A dependency
    # rebuilt for macOS 15 refuses to load on 14 and takes the app down with it. NOT required to
    # EQUAL the floor the way the main binary is: an embedded framework may legitimately target
    # something older. It may only not exceed it.
    #
    # **An unreadable target is not a passing target.** `[ -n "$extra_minos" ] && ...` skipped the
    # whole assertion whenever the version could not be read, so a binary requiring macOS 15 got
    # certified for 14 by virtue of not saying what it required — the same fail-open shape as the
    # reads above, one level in.
    extra_minos=$(printf '%s\n' "$extra_otool" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
    if [ -z "$extra_minos" ]; then
      # Binaries predating LC_BUILD_VERSION record the floor as LC_VERSION_MIN_MACOSX instead.
      # Measured on the real bundle: all 9 arm64 embedded Mach-O files use LC_BUILD_VERSION and
      # none uses the legacy command, so this is future-proofing rather than a live path — which
      # is also why failing closed below costs nothing today.
      extra_minos=$(printf '%s\n' "$extra_otool" | awk '/LC_VERSION_MIN_MACOSX/{f=1} f&&/^ *version /{print $2; exit}')
    fi
    if [ -z "$extra_minos" ]; then
      echo "    $(basename "$extra"): records no deployment target (neither LC_BUILD_VERSION nor LC_VERSION_MIN_MACOSX), so it cannot be certified to load on macOS $DECLARED" >&2
      status=1
    elif [ "$extra_minos" != "$DECLARED" ]; then
      if [ "$(printf '%s\n%s\n' "$extra_minos" "$DECLARED" | sort -V | tail -1)" = "$extra_minos" ]; then
        echo "    $(basename "$extra"): targets macOS $extra_minos, above the declared floor $DECLARED — it will not load for supported users" >&2
        status=1
      fi
    fi

    # **The newer-symbol patterns apply here too.** Checking embedded files only against the
    # absent-at-baseline frameworks left the other half unguarded: an embedded framework that
    # strongly imports SpeechAnalyzer aborts dyld on macOS 14 while the main executable passes.
    # Demangled, for the reason the main binary is: `Speech.SpeechAnalyzer` is spelled
    # `_$s6Speech0A8AnalyzerC…`, so a literal pattern matches nothing against raw symbols.
    # The old silent fallback to raw output here reproduced, for embedded files, exactly the
    # false pass the main path now dies on.
    if [ -n "$extra_syms" ]; then
      extra_readable=$(printf '%s\n' "$extra_syms" | xcrun swift-demangle 2>/dev/null)
      if [ -z "$extra_readable" ]; then
        echo "    $(basename "$extra"): swift-demangle produced nothing from its symbols; type-name patterns would silently miss every match" >&2
        status=1
        continue
      fi
    else
      # nm succeeded and reported nothing. Legitimate for a binary that imports nothing, but it
      # makes every symbol verdict below vacuous, so it is stated rather than left to look like
      # a clean inspection.
      echo "    $(basename "$extra"): no undefined symbols; the symbol checks below inspect nothing for this file"
      extra_readable=""
    fi
    for pattern in $NEWER_SYMBOL_PATTERNS; do
      extra_hits=$(printf '%s\n' "$extra_readable" | /usr/bin/grep -c "$pattern")
      [ "$extra_hits" -eq 0 ] && continue
      extra_pattern_strong=$(printf '%s\n' "$extra_readable" | /usr/bin/grep "$pattern" | /usr/bin/grep -vc 'weak external')
      if [ "$extra_pattern_strong" -ne 0 ]; then
        echo "    $(basename "$extra"): $extra_pattern_strong strong $pattern symbols" >&2
        status=1
      fi
    done

    for fw in $ABSENT_AT_BASELINE_FRAMEWORKS; do
      extra_load=$(printf '%s\n' "$extra_loads" | awk -v f="/$fw.framework/" 'index($2, f) {print $1; exit}')
      [ -n "$extra_load" ] || continue
      if [ "$extra_load" != "LC_LOAD_WEAK_DYLIB" ]; then
        echo "    $(basename "$extra"): loads $fw as $extra_load, must be LC_LOAD_WEAK_DYLIB" >&2
        status=1
      fi
      extra_strong=$(printf '%s\n' "$extra_syms" | /usr/bin/grep "(from $fw)" | /usr/bin/grep -vc 'weak external')
      if [ "$extra_strong" -ne 0 ]; then
        echo "    $(basename "$extra"): $extra_strong strong $fw symbols" >&2
        status=1
      fi
    done
  done <<EOF
$EMBEDDED
EOF
  echo "    embedded Mach-O files found: $embedded_count, of which arm64 and inspected: $embedded_arm64_count"
fi

# **A bundle that yielded no embedded Mach-O is a broken enumeration, not a clean bundle.**
#
# The count above was printed and never asserted, so `find` or `file` failing — or the layout
# moving under a future Xcode — would report "scanned: 0" and pass. This bundle ships
# `Contents/Frameworks` and `Contents/XPCServices/EnviousWisprASRService.xpc`, both of which
# contain Mach-O, so zero cannot be an honest answer for this product. Bundle mode only; a
# plain file legitimately has nothing embedded, which is the self-test's contract.
if [ "$IS_BUNDLE" -eq 1 ] && [ "$embedded_arm64_count" -eq 0 ]; then
  die "no embedded arm64 Mach-O file was inspected in $TARGET (found $embedded_count Mach-O in total). This app ships arm64 frameworks and an arm64 XPC service, so nothing inspected means the scan broke or the bundle is built for the wrong architecture, not that it is clean" 2
fi

if [ "$status" -ne 0 ]; then
  echo >&2
  echo "Either failure means dyld aborts at LAUNCH on older macOS, before any #available check" >&2
  echo "of ours runs:" >&2
  echo "  - a strongly BOUND symbol: annotate the offending code with @available and guard its" >&2
  echo "    uses with #available, which makes Swift emit a weak binding." >&2
  echo "  - a strongly LOADED framework: link it weakly (Xcode 'Optional' / -weak_framework)." >&2
  echo "    A framework absent on the older OS aborts the process before symbols are consulted," >&2
  echo "    so weak symbols do not save it." >&2
  exit 1
fi

echo "==> PASS: baseline-absent frameworks load weakly, and every newer-than-baseline symbol is weak."
