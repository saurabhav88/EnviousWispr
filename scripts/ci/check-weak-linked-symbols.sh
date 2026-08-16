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
case "$TARGET" in
  *.app)
    [ -d "$TARGET" ] || die "bundle not found: $TARGET" 2
    MAIN_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$TARGET/Contents/Info.plist" 2>/dev/null)
    [ -n "$MAIN_NAME" ] || die "no CFBundleExecutable in $TARGET/Contents/Info.plist; cannot identify the main binary" 2
    BIN="$TARGET/Contents/MacOS/$MAIN_NAME"
    [ -f "$BIN" ] || die "main executable not found: $BIN" 2
    if [ -d "$TARGET/Contents/Frameworks" ]; then
      EMBEDDED=$(find "$TARGET/Contents/Frameworks" -type f -perm +111 2>/dev/null | while read -r f; do
        file "$f" 2>/dev/null | /usr/bin/grep -q "Mach-O" && echo "$f"
      done)
    fi
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
# A framework recorded as LC_LOAD_DYLIB is loaded STRONGLY: if it is absent on the running OS,
# dyld aborts before it resolves a single symbol, so every symbol being weak buys nothing.
# FoundationModels does not exist at all below macOS 26, which makes this the more severe of
# the two failures — and it is invisible to `nm`, since symbol annotations and load commands
# are set independently (manual linker flags, or a post-link edit, can move one without the
# other). Review round 3 found this gap; the earlier version checked only symbols.
LOADS=$(otool -l "$BIN" 2>/dev/null |
  awk '/^ *cmd LC_LOAD(_WEAK)?_DYLIB/{c=$2} /^ *name /{if(c!=""){print c, $2; c=""}}')

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

# (3) Embedded Mach-O files. Only the baseline-absent frameworks are checked here, and only IF
#     referenced: an embedded framework has no obligation to use them, so requiring a match would
#     fail every honest dependency. The main executable above is what carries the
#     something-was-inspected requirement.
if [ -n "$EMBEDDED" ]; then
  embedded_count=0
  while IFS= read -r extra; do
    [ -n "$extra" ] || continue
    embedded_count=$((embedded_count + 1))
    extra_loads=$(otool -l "$extra" 2>/dev/null |
      awk '/^ *cmd LC_LOAD(_WEAK)?_DYLIB/{c=$2} /^ *name /{if(c!=""){print c, $2; c=""}}')
    extra_syms=$(nm -m -u "$extra" 2>/dev/null)
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
  echo "    embedded Mach-O files scanned: $embedded_count (none may reference a baseline-absent framework strongly)"
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
