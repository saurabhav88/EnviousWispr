#!/usr/bin/env bash
# scripts/ci/compile-eval-packages.sh — compile the three standalone eval
# packages against the checkout's EnviousWisprCore (#1836, moved out of
# pr-check.yml's inline step in #3019 so the loop is spelled once and its
# seconds land on the EW-CI-METRICS line through scripts/lib/ci-phase.sh).
#
# The eval runners (AppleIntelligenceRunner, AliasRunner, PromptRender) are targets
# of ONE SwiftPM package, scripts/eval/Package.swift, that path-depends on the
# root package. No Xcode scheme compiles it, so a public Core signature change
# once broke a runner with a fully green local suite AND a green PR (#1770 left
# apple_runner uncompilable; 4,374 local tests passed and only a human reading
# the call site caught it). Caller: a full unfiltered scripts/xcode-test.sh run,
# after its Debug suite and before its validation receipt (#3729); pr-check.yml
# ran it until #3729 PR-B. Compile-only: no run, no corpus, no model download.
#
# ONE package, not three (#4293): each runner used to be its own package with
# its own `.build`, so this step compiled the app's code three extra times
# (measured 2026-11-01 from cold: 277 s and 12.8 GB). A shared `--scratch-path`
# across separate packages was measured 2026-09-16 to silently skip the second
# and third packages, so the fix is one package graph, and the step proves every
# runner binary exists afterwards instead of trusting `Build complete!`.
#
# `swift build` is correct here and does NOT contravene the project's
# Xcode-build-engine policy: that policy governs the app, XPC, release and
# repo-test gates; this package is invisible to Tuist/Xcode, so SwiftPM is
# the only thing that can build it. RELEASE because that is the only
# configuration this tooling ever runs in (the eval gates execute release
# binaries through scripts/eval/eval_bin.py); a debug compile would miss a
# break behind `#if DEBUG`, a real class since Core carries DEBUG-only members.
#
# Usage: compile-eval-packages.sh   (run from the repository root)
set -euo pipefail

[ -f Package.resolved ] || { echo "compile-eval-packages: run from the repository root (no Package.resolved here)" >&2; exit 2; }

PKG=scripts/eval
# Seed the package's resolution from the app's TRACKED pins. The eval
# Package.resolved is gitignored, so a fresh runner has none and SwiftPM would
# resolve the whole graph fresh, floating ahead of what the app ships (measured
# 2026-07-29: PostHog 3.68.4 / Sentry 9.24.0 / swift-argument-parser 1.8.2
# against the app's then-pinned 3.62.4 / 9.19.0 / 1.7.1). Root Package.resolved
# is the one source of pin truth for shared dependencies. A dependency the app
# does NOT have (#996 chunk 2b-ii: AliasRunner's swift-transformers) is pinned in
# the tracked scripts/eval/Package.runner-only-pins.json and merged in after the
# root pins; an identity present in both is refused
# (scripts/ci/seed-eval-package-pins.py).
python3 scripts/ci/seed-eval-package-pins.py Package.resolved "$PKG"
# --only-use-versions-from-resolved-file makes the seeding a GUARANTEE: an
# out-of-date lockfile FAILS the step instead of being silently re-resolved.
echo "==> swift build -c release --package-path $PKG (locked to root pins)"
swift build -c release --package-path "$PKG" --only-use-versions-from-resolved-file
# Every runner must exist: a green build that produced no binary is the exact
# false pass measured 2026-09-16. The bin path comes from SwiftPM itself; its
# stdout can carry warnings before the path, so take the last line.
BIN_DIR=$(swift build -c release --package-path "$PKG" --show-bin-path 2>/dev/null | tail -1)
for exe in AppleIntelligenceRunner AliasRunner PromptRender; do
  [ -x "$BIN_DIR/$exe" ] || { echo "compile-eval-packages: $exe was not built at $BIN_DIR/$exe" >&2; exit 1; }
done
echo "==> All three eval runners compile against current Core ($BIN_DIR)"
