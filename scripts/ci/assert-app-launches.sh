#!/bin/bash
# Launch a built .app and assert the process is still alive a few seconds later.
#
# The failure this is aimed at: dyld aborting at launch because a symbol from a
# newer-than-deployment-target framework was bound strongly. That kills the app before any
# code of ours runs, so it cannot be caught by any in-app check, and it only reproduces on an
# OS older than the SDK the app was built against.
#
# Usage: assert-app-launches.sh <path-to-.app> [seconds-to-survive]
#
# Exit: 0 every bundled XPC service resolved its image under dyld AND the host survived the
# wait; 1 a bundled service failed its dyld startup, or the host died (the reason is classified
# in the output); 2 the check could not be performed.

set -uo pipefail

APP="${1:-}"
SURVIVE_FOR="${2:-15}"

die() { echo "FAIL: $1" >&2; exit "${2:-1}"; }

[ -n "$APP" ] || die "usage: $0 <path-to-.app> [seconds]" 2
[ -d "$APP" ] || die "app bundle not found: $APP" 2

# Read the executable name from Info.plist rather than inferring it from the bundle name. The
# dev bundle is "EnviousWispr Local.app" but its executable is still "EnviousWispr", so a
# basename guess fails on exactly the bundle a developer would reach for when testing this
# script by hand.
NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist" 2>/dev/null)
if [ -z "$NAME" ]; then
  NAME=$(basename "$APP" .app)
  echo "note: no CFBundleExecutable in Info.plist; falling back to the bundle name '$NAME'"
fi
BIN="$APP/Contents/MacOS/$NAME"
[ -f "$BIN" ] || die "executable not found inside the bundle: $BIN" 2

# **An artifact round-trip drops the executable bit and invalidates the signature.** Without
# these two lines the app fails to start for reasons that have nothing to do with the macOS
# version, which would look exactly like the defect this job exists to catch.
chmod +x "$BIN" || die "could not restore the executable bit" 2

# **Every Mach-O in the bundle, not just Contents/MacOS.** `upload-artifact` normalises uploads
# to mode 0644, which strips the bit from the bundled XPC services too — including
# `EnviousWisprASRService`, the transcription helper. The direct dyld probe below runs that
# binary, so without this the probe would fail on a transport artefact rather than on anything
# about the app — and the host, whose own failure would be nonfatal here, would survive the wait
# either way. Restoring the bit is what makes a helper failure mean the helper, not the upload.
# Restored by CONTENT so a future nested executable is covered without naming its directory.
restored=0
while IFS= read -r macho; do
  [ -n "$macho" ] || continue
  chmod +x "$macho" 2>/dev/null && restored=$((restored + 1))
done <<EOF
$(find "$APP" -type f 2>/dev/null | while read -r f; do
  desc=$(file "$f" 2>/dev/null)
  [ "${desc#*Mach-O}" != "$desc" ] && echo "$f"
done)
EOF
echo "==> restored the executable bit on $restored Mach-O files"
[ "$restored" -gt 0 ] || die "found no Mach-O files to make executable in $APP; the bundle is not what this probe expects" 2
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
# **Signed RECURSIVELY, and a failure is fatal.** The carried bundle is built with
# `CODE_SIGNING_ALLOWED=NO`, so its nested XPC services are unsigned; signing only the outer
# bundle leaves macOS free to reject the helper before its own dyld startup is exercised. The
# host survives regardless, so ignoring a signing failure bought a PASS that proved less. This
# artifact is disposable, so `--deep` is the right tool rather than an inside-out walk.
if ! codesign --force --deep --sign - --timestamp=none "$APP" 2>&1; then
  die "ad-hoc re-sign failed; the nested services would be rejected by macOS and this probe would pass without exercising them" 2
fi

# **The architecture has to match what we ship, or the launch proves nothing about users.**
#
# EnviousWispr is Apple Silicon only. A launch on an x86_64 runner would either fail for a
# reason unrelated to macOS compatibility, or succeed under Rosetta and certify a configuration
# no user runs. The `macos-14` label resolves to `macos-14-arm64` today; asserted rather than
# trusted, because a label remap would silently turn this job into theatre.
RUNNER_ARCH=$(uname -m)
if [ "$RUNNER_ARCH" != "arm64" ]; then
  die "runner architecture is $RUNNER_ARCH, but the app ships arm64 only. A launch here would say nothing about the machines users have." 2
fi

RUNNER_VERSION=$(sw_vers -productVersion)
MINOS=$(otool -l "$BIN" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')
echo "==> runner:     macOS $RUNNER_VERSION on $RUNNER_ARCH"
echo "==> app:        $APP"
echo "==> deployment: ${MINOS:-unknown}"
echo "==> built with: SDK $(otool -l "$BIN" 2>/dev/null | awk '/LC_BUILD_VERSION/{f=1} f&&/sdk /{print $2; exit}')"

# **How far below the baseline this runner actually reaches, stated rather than implied.**
#
# Symbol availability is monotonic, so a launch ABOVE the deployment target cannot prove the
# target itself. A major-version match is NOT enough: the `macos-14` image is 14.8.x while the
# app targets 14.0, so an API introduced in 14.1 through 14.8 resolves here and would still
# abort at launch for a user on 14.0. GitHub publishes no 14.0 image, so this residual range is
# not closable by choosing a different runner and must not be papered over.
#
# What covers it instead is the SWIFT COMPILER, which is the exhaustive defence and is already
# run on every build: using an API newer than the deployment target without an `@available`
# annotation is a compile ERROR, at minor-version precision, for every framework. Measured
# 2026-08-16: `swiftc -target arm64-apple-macos14.0` rejects both a macOS 26 API and a
# hand-annotated `@available(macOS 14.1, *)` call from an unannotated caller.
#
# So the ordering of defences is: compiler (all frameworks, exact versions) > weak-link check
# (the frameworks we knowingly use above baseline, catching the linkage consequence of paths
# that bypass Swift availability) > this launch (corroboration on the oldest image that exists).
[ -n "$MINOS" ] || die "could not read the deployment target from $BIN; without it this job cannot know whether the runner is old enough to prove anything" 2

version_gt() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ] && [ "$1" != "$2" ]; }

RUNNER_MAJOR=${RUNNER_VERSION%%.*}
MINOS_MAJOR=${MINOS%%.*}
if [ "$RUNNER_MAJOR" -gt "$MINOS_MAJOR" ]; then
  die "runner is macOS $RUNNER_VERSION but the app targets $MINOS. A whole major version above the baseline proves nothing about supported users. Run this job on a macOS $MINOS_MAJOR image, or raise the deployment target to match the oldest image still available." 2
fi
if version_gt "$RUNNER_VERSION" "$MINOS"; then
  echo "==> baseline: runner $RUNNER_VERSION, target $MINOS"
  echo "==> RESIDUAL GAP: this run does NOT cover macOS $MINOS through $RUNNER_VERSION."
  echo "    No macOS $MINOS runner image exists, so that range is covered by the compiler's"
  echo "    availability checking (a build error), not by this launch. Do not read this PASS as"
  echo "    proof that a $MINOS machine starts the app."
elif version_gt "$MINOS" "$RUNNER_VERSION"; then
  # The app requires MORE than this runner offers. Previously this fell into the "exactly at the
  # deployment target" branch and said so, which is false in the one case that matters: a target
  # accidentally raised above the baseline makes the app unlaunchable for supported users, and
  # this job would have blamed the launch failure on the environment instead of naming the cause.
  die "the app targets macOS $MINOS but this runner is $RUNNER_VERSION. It cannot launch here by construction, and a target above the support floor means it cannot launch for supported users either." 1
else
  echo "==> baseline ok: runner $RUNNER_VERSION is exactly at the deployment target $MINOS"
fi

# **The bundled services directory has to be there before the probe means anything.**
# `EnviousWisprASRService` is the component this job most needs to exercise, and a bundle
# without an `XPCServices` directory cannot start it. Asserted up front rather than skipped
# quietly further down, because "the directory was not there" and "the helper did not start"
# are different failures and only one of them is about the app.
XPC_DIR="$APP/Contents/XPCServices"
[ -d "$XPC_DIR" ] || die "no Contents/XPCServices in $APP; the transcription helper is not in this bundle, so a launch here cannot exercise it" 2

# **The helper's own dyld startup, proven DIRECTLY rather than inferred from the process table.**
#
# Watching for `EnviousWisprASRService` to appear while the host ran was the wrong instrument in
# both directions, and one review round found each:
#
#   - Absence does not mean broken. The warm-up that contacts the service runs after
#     `delivery.ensureAvailable()`, so on a clean runner with no model cache the helper can
#     legitimately never appear inside the window. Failing on that would redden the job for
#     first-launch behaviour, which is how a check earns a bypass.
#   - Presence does not mean working. A process that appears and then dies inside dyld
#     initialisation still shows up, and its death is nonfatal to the host, so the run passes.
#
# Running the service binary directly settles both. libxpc refuses to host a service started this
# way — but the refusal is issued by the runtime, which means dyld has already loaded and bound
# the entire image by the time it is printed. So "an XPC Service cannot be run directly" is
# positive evidence that this helper's linkage resolves on THIS OS, which is exactly the claim
# this job exists to make, and it needs no model, no network and no XPC connection. A dyld
# failure prints its own error instead and never reaches the refusal.
#
# Measured locally on the real service binary: exit 134 (SIGABRT) with that refusal on stderr.
probe_xpc_dyld() {
  local exe="$1" name plog pid waited code out dyld_hits xpc_hits
  name=$(basename "$exe")
  plog=$(mktemp)
  "$exe" >"$plog" 2>&1 &
  pid=$!
  waited=0
  while [ "$waited" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; waited=$((waited + 1)); done
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null; code=$?
  out=$(cat "$plog"); rm -f "$plog"

  # Counted, never `grep -q`: under `set -o pipefail` a quiet grep exiting early kills `printf`
  # with EPIPE and the condition reads false, which this repo has been bitten by twice.
  dyld_hits=$(printf '%s' "$out" | /usr/bin/grep -cE "Symbol not found|Library not loaded|dyld\[|dyld:")
  xpc_hits=$(printf '%s' "$out" | /usr/bin/grep -c "cannot be run directly")

  if [ "$dyld_hits" -gt 0 ]; then
    echo "FAIL: $name: dyld could not start it on macOS $(sw_vers -productVersion). This is the defect this job exists to catch, in the component that performs transcription." >&2
    printf '%s\n' "$out" | sed 's/^/      /' >&2
    return 1
  fi
  if [ "$xpc_hits" -gt 0 ]; then
    echo "==> $name: dyld resolved its image (libxpc refused a direct start, exit $code) ✓"
    return 0
  fi
  echo "FAIL: $name: neither a dyld error nor libxpc's refusal appeared, so this probe cannot say whether its image resolved. Exit $code, output below." >&2
  printf '%s\n' "$out" | sed 's/^/      /' >&2
  return 1
}

xpc_probed=0
while IFS= read -r xpcexe; do
  [ -n "$xpcexe" ] || continue
  desc=$(file "$xpcexe" 2>/dev/null) || desc="Mach-O unclassifiable"
  [ "${desc#*Mach-O}" != "$desc" ] || continue
  xpc_probed=$((xpc_probed + 1))
  probe_xpc_dyld "$xpcexe" || die "the bundled XPC service failed its own dyld startup" 1
done <<EOF
$(find "$XPC_DIR" -type f 2>/dev/null)
EOF
[ "$xpc_probed" -gt 0 ] || die "no Mach-O found under $XPC_DIR, so the transcription helper's startup was never exercised" 2
echo "==> bundled XPC services whose dyld startup was proven: $xpc_probed"

LOG=$(mktemp)
"$BIN" >"$LOG" 2>&1 &
PID=$!
echo "==> launched pid $PID; waiting ${SURVIVE_FOR}s"

# Poll rather than one long sleep, so a fast dyld abort is reported immediately.
#
# **No process-table watching for the helper here.** An earlier version latched on the helper
# appearing in `pgrep` during this window, and it was unsound in three separate ways: absence
# only means model delivery had not finished, presence does not survive dyld initialisation,
# and `pgrep -f <path>` matches ANY process whose command line merely mentions that path —
# including the shell that copied a file into it, which is how it reported the helper "at 0s"
# in a local run where the helper was never contacted at all. The helper's compatibility is
# proven deterministically above instead, which is a stronger claim obtained more cheaply.
elapsed=0
while [ "$elapsed" -lt "$SURVIVE_FOR" ]; do
  if ! kill -0 "$PID" 2>/dev/null; then break; fi
  sleep 1
  elapsed=$((elapsed + 1))
done

if kill -0 "$PID" 2>/dev/null; then
  echo "==> PASS: still running after ${elapsed}s on macOS $(sw_vers -productVersion)"

  # **Did the transcription service actually start? A no is a FAILURE, not a note.**
  #
  # "The host survived" is a weak claim, and four review rounds in a row found ways this probe
  # passed while `EnviousWisprASRService` never ran: it was not scanned, then it arrived
  # non-executable, then it could be rejected as unsigned, and then its absence was merely
  # printed. Each of the first three fixes removed one precondition without asserting the
  # outcome; the fourth observed the outcome and still exited 0, so a workflow could report
  # success having never started the component that performs transcription.
  #
  # The host process is NOT a proxy for the helper: the warm-up is started asynchronously and
  # its failure is nonfatal to the host, which is exactly why the host outliving a dead helper
  # is the expected shape of the bug rather than an unlikely one.
  #
  # **Basis for making it fatal, stated rather than assumed:** one measured run on this runner
  # image (macOS 14.8.7, arm64, the tarball-transferred bundle) observed the helper running. One
  # observation is enough to say the warm-up DOES fire in this environment, and therefore that
  # its absence is a signal; it is not enough to characterise how reliably it fires. If this
  # starts flapping red on runs where the app is fine, that reopens the question — the answer
  # then is to make the helper start deterministically, not to go back to printing a note.
  kill -TERM "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null
  # Surface early output even on success: a dyld warning that did not kill the process is
  # worth seeing before it becomes an abort on some other machine.
  if [ -s "$LOG" ]; then echo "--- first 40 lines of output ---"; head -40 "$LOG"; fi
  rm -f "$LOG"
  exit 0
fi

wait "$PID" 2>/dev/null
CODE=$?
echo "==> process exited after ${elapsed}s with code $CODE" >&2
echo "--- output ---" >&2
cat "$LOG" >&2

# Classify, so a reader can tell in one line whether this is the defect or the environment.
if /usr/bin/grep -qE "Symbol not found|Library not loaded|dyld\[|dyld:" "$LOG"; then
  echo >&2
  echo "VERDICT: dyld could not resolve a symbol at launch. This is the defect this job exists" >&2
  echo "to catch: a framework used above the deployment target is bound STRONGLY. Annotate the" >&2
  echo "code with @available and guard its uses with #available." >&2
  rm -f "$LOG"
  exit 1
fi

echo >&2
echo "VERDICT: the app did not survive, but no dyld symbol error was found. Read the output" >&2
echo "above before assuming a compatibility break: a headless runner can also fail for" >&2
echo "window-server or permission reasons that would not affect a real user." >&2
rm -f "$LOG"
exit 1
