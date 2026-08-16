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

BIN="${1:-}"

# Frameworks whose APIs we use above the deployment target. Adding an API from a new framework
# means adding it here; the self-test below fails loudly if this list stops matching reality.
GUARDED_FRAMEWORKS="Speech FoundationModels"

# A framework we link normally. Its symbols MUST come back strong. This is the instrument's
# own control: if it ever reports weak, `nm` output has changed shape and every "0 strong
# symbols" result above is meaningless rather than reassuring.
CONTROL_FRAMEWORK="AppKit"

die() { echo "FAIL: $1" >&2; exit "${2:-1}"; }

[ -n "$BIN" ] || die "usage: $0 <path-to-macho-binary>" 2
[ -f "$BIN" ] || die "binary not found: $BIN" 2
command -v nm >/dev/null 2>&1 || die "nm not available" 2
command -v otool >/dev/null 2>&1 || die "otool not available" 2

SYMS=$(nm -m -u "$BIN" 2>/dev/null)
[ -n "$SYMS" ] || die "nm produced no undefined symbols for $BIN — wrong file type, or a stripped or thin binary" 2

# Report the deployment target so a reader can see WHY this check matters for this build.
MINOS=$(otool -l "$BIN" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
echo "==> binary:            $BIN"
echo "==> deployment target: ${MINOS:-unknown}"

count_for() { printf '%s\n' "$SYMS" | /usr/bin/grep -c "(from $1)"; }
count_strong_for() {
  printf '%s\n' "$SYMS" | /usr/bin/grep "(from $1)" | /usr/bin/grep -vc 'weak external'
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

# --- The actual assertion ------------------------------------------------------------------
status=0
checked=0
for fw in $GUARDED_FRAMEWORKS; do
  total=$(count_for "$fw")
  if [ "$total" -eq 0 ]; then
    # Not an error on its own: a framework can legitimately go unused. Say so, so that a
    # silently-dropped dependency is visible rather than passing as "nothing strong found".
    echo "    $fw: no symbols in this binary (framework unused here)"
    continue
  fi
  checked=$((checked + 1))
  strong=$(count_strong_for "$fw")
  if [ "$strong" -ne 0 ]; then
    echo "    $fw: $strong of $total symbols are STRONGLY bound" >&2
    printf '%s\n' "$SYMS" | /usr/bin/grep "(from $fw)" | /usr/bin/grep -v 'weak external' | sed 's/^/      /' >&2
    status=1
  else
    echo "    $fw: all $total symbols weak ✓"
  fi
done

if [ "$checked" -eq 0 ]; then
  die "none of the guarded frameworks ($GUARDED_FRAMEWORKS) appear in this binary. Either the wrong binary was passed, or the app stopped using them and this guard is now checking nothing" 2
fi

if [ "$status" -ne 0 ]; then
  echo >&2
  echo "A strongly-bound symbol from a framework we only use above the deployment target means" >&2
  echo "dyld aborts at launch on older macOS. Annotate the offending code with @available and" >&2
  echo "guard its uses with #available, which makes Swift emit a weak binding." >&2
  exit 1
fi

echo "==> PASS: every guarded framework is fully weak-bound; the app can start below macOS 26."
