# Phase 1 Brainstorm — Rebuild Skill Overhaul

**Date**: 2026-03-02
**Sources**: Gemini 2.5 Pro (brainstorm session), Gemini 2.5 Flash (second opinion), Claude (synthesis)

---

## Original 5 Items (all confirmed)

### 1. Remove the hash check
- **Status**: Confirmed broken — `install_name_tool` + `codesign` modify the binary, SHA always mismatches
- **Fix**: Delete hash check, replace with `codesign --verify --deep --strict` on final bundle
- **Why codesign verify is better**: Validates binary was copied AND signed correctly in one check. Catches corrupt bundles, post-sign tampering, invalid identity. Complements mtime check (which validates source→build, not build→bundle)

### 2. Fix the mtime staleness check
- **Status**: Confirmed wrong target — compares source against signed bundle binary instead of raw build output
- **Fix**: Compare against `.build/release/EnviousWispr` (raw SPM output)
- **Addition**: Add existence check for destination app before comparing

### 3. Fix sleep comment
- **Status**: Comment says `sleep 1`, code says `sleep 2`
- **Fix**: Update comment to match code

### 4. Make UAT conditional
- **Status**: Mandatory UAT blocks quick "just rebuild" requests
- **Gemini Pro**: Default OFF, only run if user explicitly asks or context implies feature/fix
- **Gemini Flash disagreement**: Default OFF is unsafe — AI agent will always skip. Proposes mandatory quick smoke test (app launches, no crash, menu bar icon) + opt-in full Smart UAT
- **Synthesis**: Flash is right. Quick smoke always, full UAT opt-in. The smoke test is cheap insurance

### 5. Add preflight cert check
- **Status**: `codesign` fails silently if "EnviousWispr Dev" cert doesn't exist
- **Fix**: Add `security find-identity -v -p codesigning | grep -q "EnviousWispr Dev"` to `wispr-bundle-app` (where signing happens)
- **Flash addition**: Consider auto-creating the cert if missing (but may be Phase 2 scope)

---

## 2 Missing Items (both sessions agreed)

### 6. CRITICAL: Exit code checking after `swift build`
- **Status**: Skill says "don't pipe through tail" but doesn't check `$?`. Failed build silently bundles old binary
- **Fix**: Check exit code immediately after `swift build -c release`
- **Priority**: Highest — this is the most fundamental bug

### 7. Eliminate hardcoded absolute paths
- **Status**: All paths hardcoded to `/Users/m4pro_sv/Desktop/EnviousWispr`
- **Gemini Pro**: Add `PROJ_ROOT` variable at top of both skills
- **Flash alternative**: Use `cd` to project root + relative paths (more robust for real scripts)
- **Synthesis**: `PROJ_ROOT` is simpler for skill files (which are AI agent instructions, not real shell scripts). These aren't executed directly — they're read by an AI agent that runs the commands

---

## Additional Items (Flash second opinion)

### 8. Dev cert persistence (TCC friction root cause)
- Even with preflight check, if the self-signed cert is recreated differently, TCC still resets
- The cert should be created ONCE and reused across all rebuilds
- **Verdict**: Important insight but Phase 2 territory (dev/prod isolation theme)

### 9. Over-aggressive `rm -rf EnviousWispr.build/`
- Flash argues `swift build` should handle incremental builds without nuking the build dir
- **Verdict**: Keep it — WMO staleness is a documented, real gotcha. The rm only removes the main target (~11MB), not dependencies (~470MB). Rebuild stays at ~10-15s. Without it, stale .o files get silently reused

### 10. Robust kill/wait loop
- `killall + sleep 2` is a race condition. Suggests `pgrep` polling loop with timeout
- **Gemini Pro**: Phase 3 material
- **Flash**: Phase 1
- **Verdict**: Phase 1 if cheap (replace sleep with a 3-line pgrep loop), Phase 3 if it needs elaborate error handling

### 11. Sparkle.framework source path clarity
- Bundle skill should explicitly document where Sparkle.framework is copied from
- **Verdict**: Already documented in the skill (`.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/...`). No action needed

---

## Final Phase 1 Scope (7 items)

| # | Item | Effort | Risk if skipped |
|---|------|--------|-----------------|
| 1 | Exit code checking after swift build | Small | Critical — silent stale builds |
| 2 | Remove hash check → codesign --verify | Small | Medium — false failures on every build |
| 3 | Fix mtime staleness check target | Small | Medium — false failures |
| 4 | Add preflight cert check (in bundle-app) | Small | Low — confusing error on missing cert |
| 5 | Make UAT conditional (smoke always, full opt-in) | Medium | Low — workflow friction |
| 6 | Add PROJ_ROOT variable | Small | Low — maintenance burden |
| 7 | Fix sleep comment + add pgrep wait loop | Small | Low — race condition |

## Implementation Order

1. Exit code checking (foundational — everything else depends on builds succeeding)
2. PROJ_ROOT variable (makes all subsequent edits cleaner)
3. Fix mtime check + remove hash check + add codesign verify (bundle verification cluster)
4. Preflight cert check (in bundle-app skill)
5. Kill/wait robustness (pgrep loop)
6. UAT conditional (smoke test strategy)
7. Sleep comment fix (trivial, do last)

---

## Deferred to Phase 2

- Dev cert auto-creation and persistence strategy
- Dev bundle ID stamping (`com.enviouswispr.app.dev`)
- Sparkle disable in dev builds
- TCC guidance corrections

## Deferred to Phase 3

- Debug vs release build evaluation
- `open` vs direct binary launch
- `pkill -f` vs `killall`
- Configurable variables beyond PROJ_ROOT
- Bundle-app delegation consolidation
