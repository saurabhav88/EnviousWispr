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
find "$APP/Contents/MacOS" -type f -exec chmod +x {} \; 2>/dev/null
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "note: ad-hoc re-sign failed; continuing, since an unsigned binary still exercises dyld"

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
