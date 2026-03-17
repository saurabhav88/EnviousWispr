# Phase 3 Brainstorm — Streamline & Modernize

**Date**: 2026-03-02
**Sources**: Gemini 2.5 Pro (brainstorm), Claude (synthesis)
**Team context**: Solo indie dev + Claude (AI agent). Skills are AI-executed instructions, not scripts.

---

## Items REJECTED (3 cut)

### #6. `set -eou pipefail` — REJECTED
Irrelevant. Skills are .md instructions read by an AI agent, not shell scripts. The explicit exit code checks added in Phase 1 are more robust and clearer for AI execution.

### #8. Omit Sparkle.framework from dev builds — REJECTED
Technically infeasible. The binary is dynamically linked against Sparkle.framework. Without it in the bundle's Frameworks directory, the app fails to launch with a dyld error. Phase 2 already defangs Sparkle by blanking SUFeedURL — that's sufficient.

### #4. Consolidate bundle-app delegation — REJECTED (keep separate)
Separation of concerns is correct. `rebuild` coordinates, `bundle` does one job well. With configurable variables in place, two small focused skills are easier than one monolithic one. No action needed.

---

## Items KEPT (7 items, priority ranked)

### 1. Evaluate debug vs release for dev (HIGHEST PRIORITY)
- **Why**: Most impactful velocity improvement. If debug builds are <5s vs 15s release, that's transformational
- **Trade-off**: Debug builds don't catch release-only issues (optimizations, stripping). FluidAudio/WhisperKit performance may differ
- **Implementation**: Create new `wispr-rebuild-debug` skill (don't modify the existing one)
  - Uses `swift build -c debug`
  - Skips the manual `.build` artifact deletion (less necessary for debug)
  - Description clearly states: "Use for rapid UI/logic iteration. Does not represent final performance. Use full rebuild before committing."
- **Action**: Benchmark both first, then decide if the new skill is worth it

### 2. Configurable variables + PROJ_ROOT (HIGH PRIORITY)
- **Why**: Single biggest maintainability win. Reduces cognitive load, makes skills readable
- **Implementation**: Configuration block at top of both skills:
  ```
  PROJ_ROOT="/Users/m4pro_sv/Desktop/EnviousWispr"
  DEV_APP_NAME="EnviousWispr Local.app"
  DEV_BUNDLE_ID="com.enviouswispr.app.dev"
  DEV_CERT_NAME="EnviousWispr Dev"
  BUILD_DIR="$PROJ_ROOT/build"
  ```
- Replace all hardcoded paths/strings with variables
- Merges original #5 and deferred #7

### 3. `pkill -f` + `pgrep` polling loop (HIGH PRIORITY)
- **Why**: Eliminates the last race condition in the workflow. `killall` is too broad, `sleep 2` is fragile
- **Implementation**: Replace entire kill/sleep block:
  ```bash
  pkill -f "$BUILD_DIR/$DEV_APP_NAME"
  while pgrep -f "$BUILD_DIR/$DEV_APP_NAME" > /dev/null; do
      sleep 0.1
  done
  ```
- Merges original #3 and deferred #10

### 4. Switch to `open` for launch (MEDIUM PRIORITY)
- **Why**: `open` is the correct macOS tool for launching .app bundles. Handles Launch Services registration (notifications, dock icon, etc.). The "Finder fallback" concern is moot when providing a full path to a valid signed .app bundle
- **Implementation**: Replace `"$BINARY" & disown` with `open "$BUILD_DIR/$DEV_APP_NAME"`
- No `disown` needed — `open` handles process separation

### 5. Separate "hardened dev" build skill (MEDIUM PRIORITY)
- **Why**: Provides a way to test production-like builds (release + HRT + entitlements) without full notarized DMG
- **Implementation**: Create `wispr-rebuild-hardened` — copy of rebuild skill but with `--options runtime --entitlements` in codesign step
- **Deferred detail**: Needs its own entitlements file mirroring production

### 6. Cache-pruning skill (LOW PRIORITY — new from Pro)
- **Why**: SPM build cache can get into weird states. Escape hatch for "weird build issues"
- **Implementation**: `wispr-clean-build-artifacts` skill that runs `rm -rf .build/ && swift package clean`
- Could be invoked by rebuild skill with a `from_scratch` flag
- **Verdict**: Nice-to-have. The human can already say "clean build" and I'll know what to do

---

## Final Phase 3 Scope (5 items — cut #6 cache-pruning as not worth a dedicated skill)

| # | Item | Effort | Impact |
|---|------|--------|--------|
| 1 | Benchmark debug vs release, create `wispr-rebuild-debug` if warranted | Medium | High — velocity |
| 2 | Configurable variables + PROJ_ROOT in both skills | Small | High — maintainability |
| 3 | `pkill -f` + `pgrep` polling loop | Small | Medium — reliability |
| 4 | Switch to `open` for launch | Small | Medium — correctness |
| 5 | Create `wispr-rebuild-hardened` skill | Medium | Low — niche use case |

## Implementation Order

1. Configurable variables (#2) — makes all subsequent edits cleaner
2. `pkill` + `pgrep` loop (#3) — quick reliability win
3. Switch to `open` (#4) — quick correctness win
4. Benchmark debug vs release (#1) — research first, then decide
5. Hardened build skill (#5) — only if needed

---

## Cross-Phase Summary

| Phase | Theme | Items | Status |
|-------|-------|-------|--------|
| 1 | Fix What's Broken | 7 items | Brainstorm complete |
| 2 | Dev/Prod Isolation | 6 items | Brainstorm complete |
| 3 | Streamline & Modernize | 5 items | Brainstorm complete |
| **Total** | | **18 items** | Ready for implementation planning |
