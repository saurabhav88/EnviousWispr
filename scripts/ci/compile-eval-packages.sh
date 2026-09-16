#!/usr/bin/env bash
# scripts/ci/compile-eval-packages.sh — compile the three standalone eval
# packages against the checkout's EnviousWisprCore (#1836, moved out of
# pr-check.yml's inline step in #3019 so the loop is spelled once and can run
# in the background beside the test step).
#
# scripts/eval/{apple_runner,alias_runner,prompt_render} are STANDALONE SwiftPM
# packages that path-depend on EnviousWisprCore. Nothing else compiles them —
# not scripts/xcode-test.sh, not any Xcode scheme — so a public Core signature
# change broke them with a fully green local suite AND a green PR (#1770 left
# apple_runner uncompilable; 4,374 local tests passed and only a human reading
# the call site caught it). Compile-only: no run, no corpus, no model download.
#
# `swift build` is correct here and does NOT contravene the project's
# Xcode-build-engine policy: that policy governs the app, XPC, release and
# repo-test gates; these packages are invisible to Tuist/Xcode, so SwiftPM is
# the only thing that can build them. RELEASE because that is the only
# configuration this tooling ever runs in (both READMEs say `swift build -c
# release`, and the eval gates execute `.build/release/` binaries:
# acceptance_gate.py, alias_suggestion_gate.py); a debug compile would miss a
# break behind `#if DEBUG`, a real class since Core carries DEBUG-only members.
#
# Each package's build dir is its own. A shared `--scratch-path` was measured
# 2026-09-16 to silently skip building the second and third root packages
# (`Build complete! (0.17s)`, no executable): never share one.
#
# Usage: compile-eval-packages.sh   (run from the repository root)
set -euo pipefail

[ -f Package.resolved ] || { echo "compile-eval-packages: run from the repository root (no Package.resolved here)" >&2; exit 2; }

for pkg in scripts/eval/apple_runner scripts/eval/alias_runner scripts/eval/prompt_render; do
  # Seed each package's resolution from the app's TRACKED pins. Every eval
  # Package.resolved is gitignored, so a fresh runner has none and SwiftPM
  # would resolve the whole graph fresh, floating ahead of what the app ships
  # (measured 2026-07-29: PostHog 3.68.4 / Sentry 9.24.0 / swift-argument-parser
  # 1.8.2 against the app's then-pinned 3.62.4 / 9.19.0 / 1.7.1). Root
  # Package.resolved is the one source of pin truth; SwiftPM prunes the entries
  # this graph does not need and holds every shared one.
  cp Package.resolved "$pkg/Package.resolved"
  # --only-use-versions-from-resolved-file makes the seeding a GUARANTEE: an
  # out-of-date lockfile FAILS the step instead of being silently re-resolved.
  # Verified both directions locally.
  echo "==> swift build -c release --package-path $pkg (locked to root pins)"
  swift build -c release --package-path "$pkg" --only-use-versions-from-resolved-file
done
echo "==> All three standalone eval packages compile against current Core"
