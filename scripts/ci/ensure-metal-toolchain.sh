#!/usr/bin/env bash
# ensure-metal-toolchain.sh — make `xcrun metal` runnable on a hosted macOS runner (#3242, #3344).
#
# MLX (the word check) compiles Metal shaders, and hosted images do not always carry Xcode's
# separate Metal toolchain component (actions/runner-images#13014, #14013). Called by
# .github/actions/xcode-ci-setup and release.yml's build job; one owner for both.
#
# An image that already has the toolchain pays one probe and nothing else.
#
# **Why the cache is killed after the download.** main-post-merge run 36773416278 (xcode-27,
# 27A266a): the download printed "Done downloading: Metal Toolchain 27A266a" and the verify call,
# under a second later, still said "missing Metal Toolchain". The failed probe BEFORE the download
# is itself an `xcrun` lookup, and xcrun caches lookups; Apple's Xcode 26 release notes list a stale
# xcrun cache after this download (154682120). `xcrun --kill-cache` removes that answer. The bounded
# re-probe covers a component that registers a moment after the download returns; it is a
# measured-nothing guess, so every failed attempt prints why and the whole wait is capped.
#
# Not used: `-exportPath` + `-importComponent`. Measured on 27A266a: the export is an
# `.exportedBundle`, and importing it where the download already installed the asset fails with
# "Asset is already installed", which is the failing runner's state.
set -euo pipefail

probe() { xcrun -sdk macosx metal -v >/dev/null 2>&1; }

if probe; then
  echo "Metal toolchain present"
  exit 0
fi

echo "==> Metal toolchain missing; downloading"
xcodebuild -downloadComponent MetalToolchain
xcrun --kill-cache

attempts=6
for i in $(seq 1 "$attempts"); do
  if out=$(xcrun -sdk macosx metal -v 2>&1); then
    echo "$out"
    echo "==> Metal toolchain usable after download (attempt $i of $attempts)"
    exit 0
  fi
  echo "attempt $i of $attempts: xcrun metal still fails: $out" >&2
  if [ "$i" -lt "$attempts" ]; then
    sleep 10
    xcrun --kill-cache
  fi
done

echo "::error::Metal toolchain downloaded but not runnable after $attempts attempts over ~50 s; component state follows" >&2
xcodebuild -showComponent MetalToolchain >&2 || true
exit 1
