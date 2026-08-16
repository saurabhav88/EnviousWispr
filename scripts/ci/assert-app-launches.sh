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
# Exit: 0 the app was alive after the wait; 1 it died (the reason is classified in the
# output); 2 the check could not be performed.

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
# `EnviousWisprASRService`, the transcription helper. Its failure to start is NONFATAL to the
# host, so the app would survive the full wait and report PASS while the component this probe
# most needs to exercise never ran. Restored by CONTENT so a future nested executable is covered
# without naming its directory.
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

LOG=$(mktemp)
"$BIN" >"$LOG" 2>&1 &
PID=$!
echo "==> launched pid $PID; waiting ${SURVIVE_FOR}s"

# Poll rather than one long sleep, so a fast dyld abort is reported immediately.
elapsed=0
while [ "$elapsed" -lt "$SURVIVE_FOR" ]; do
  if ! kill -0 "$PID" 2>/dev/null; then break; fi
  sleep 1
  elapsed=$((elapsed + 1))
done

if kill -0 "$PID" 2>/dev/null; then
  echo "==> PASS: still running after ${elapsed}s on macOS $(sw_vers -productVersion)"

  # **Did the transcription service actually start?**
  #
  # "The host survived" is a weak claim, and three review rounds in a row found ways this probe
  # passed while `EnviousWisprASRService` never ran: first it was not scanned, then it arrived
  # non-executable, then it could be rejected as unsigned. Each fix removed one precondition
  # without ever asserting the outcome. This asserts the outcome: the service is started as a
  # startup warm-up and appears as its own process, so its absence is evidence, not noise.
  #
  # Scoped to THIS bundle's path so a stray instance from elsewhere on the machine cannot vouch
  # for it. Reported, not fatal, on a headless runner where a GUI-driven warm-up may legitimately
  # not fire — but the count is printed either way, so "never exercised" can never again look
  # identical to "exercised and fine".
  XPC_DIR="$APP/Contents/XPCServices"
  if [ -d "$XPC_DIR" ]; then
    helper_running=$(pgrep -f "$XPC_DIR" 2>/dev/null | /usr/bin/grep -c .)
    if [ "$helper_running" -gt 0 ]; then
      echo "==> bundled XPC services running: $helper_running (the transcription helper started)"
    else
      echo "==> NOTE: no bundled XPC service process was observed."
      echo "    The host survived, but this run did NOT exercise the transcription helper's own"
      echo "    startup. Treat this PASS as covering the host process only."
    fi
  fi
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
