# Phase 2 Brainstorm — Dev/Prod Isolation

**Date**: 2026-03-02
**Sources**: Gemini 2.5 Pro (brainstorm), Gemini 2.5 Flash (second opinion), Claude (synthesis)
**Team context**: Solo indie dev + Claude (AI agent). No other devs, no Xcode, SPM-only. Skills are AI-executed instructions, not human-run scripts.

---

## Key Disagreement: Signing Identity Strategy

The two sessions fundamentally disagree on the signing approach:

| | Gemini Pro | Gemini Flash |
|---|-----------|-------------|
| **Recommendation** | Abandon self-signed, switch to Apple Development cert | Keep self-signed, make it stable and auto-managed |
| **Rationale** | Apple-issued certs have stable TCC identity | Apple Dev cert requires Xcode + Apple Developer account, contradicts SPM-only philosophy |
| **TCC fix** | Apple cert = stable identity = TCC persists | Stable self-signed + consistent bundle ID = TCC persists |
| **Friction** | One-time Xcode setup | Zero external dependency |

**Synthesis**: Flash is right for this project. The "no Xcode" constraint is a hard requirement. A stable, programmatically managed self-signed cert with a consistent bundle ID is the correct approach. Apple Developer certs are for the release pipeline (already handled by CI). Dev builds should stay decoupled from Apple's ecosystem.

---

## Key Disagreement: Hardened Runtime on Dev Builds

| | Gemini Pro | Gemini Flash |
|---|-----------|-------------|
| **Recommendation** | Enable `--options runtime` + entitlements | Do NOT enable HRT for standard dev builds |
| **Rationale** | Good practice | HRT restricts dylib injection, debugging tools, profiling. Too restrictive for daily iteration |
| **Entitlements** | `get-task-allow` needed for LLDB | `get-task-allow` only needed IF HRT is enabled. Without HRT, debugging works by default |

**Synthesis**: Flash is right. HRT is for release builds. Dev builds should be unsigned-runtime (just signed, no `--options runtime`). If we need to test HRT behavior, make it a separate opt-in skill.

---

## Item-by-Item Analysis

### 1. Stamp dev bundle ID (`com.enviouswispr.app.dev`)
- **Both agree**: Critical, non-negotiable
- **Implementation**: `plutil -replace CFBundleIdentifier -string "com.enviouswispr.app.dev"` after copying Info.plist
- **Also stamp**: `CFBundleName`, `CFBundleDisplayName` → "EnviousWispr Local" or "EnviousWispr Dev"
- **Add verification step**: Check bundle ID after stamping, fatal error if wrong
- **Status check needed**: Verify whether the current bundle-app skill already does this or just stamps version

### 2. Disable Sparkle in dev builds
- **Both agree**: Blank `SUFeedURL` entirely (not just disable auto-checks)
- **Implementation**: `plutil -replace SUFeedURL -string "" "$DEST_PLIST"`
- **Flash addition**: Consider omitting Sparkle.framework entirely from dev builds (saves bundle size, removes dead code). Only embed when testing update flow
- **Synthesis**: Blank the URL for now (simpler). Omitting the framework would require conditional logic in bundle-app — Phase 3 material

### 3. Signing identity — KEEP SELF-SIGNED (see disagreement above)
- **Decision**: Keep "EnviousWispr Dev" self-signed cert
- **Make it stable**: Create ONCE, reuse forever. The cert must have a consistent Common Name and be stored in login keychain
- **Auto-creation**: If `security find-identity` doesn't find it, programmatically create via openssl + `security import`. This is Phase 2, not Phase 3
- **Preflight**: Already added in Phase 1. Phase 2 upgrades it to auto-create if missing
- **Gemini Pro proposed a new skill `wispr-ensure-dev-cert`** with concrete implementation:
  1. Check: `security find-certificate -c "EnviousWispr Dev" -p`
  2. Create config: openssl req config with CN=EnviousWispr Dev, extendedKeyUsage=codeSigning
  3. Generate: `openssl req -x509 -nodes -newkey rsa:2048 -days 3650`
  4. Import: `security import` cert + key into login keychain with `-T /usr/bin/codesign`
  5. Trust: `sudo security add-trusted-cert -d -r trustRoot` + `security set-key-partition-list`
  6. Cleanup temp files
  - Note: sudo may require human password input — AI must be prepared for that interaction

### 4. Correct TCC guidance
- **Both agree**: Update gotchas.md once signing + bundle ID are stable
- **New guidance**: "TCC persists across dev rebuilds when: (1) bundle ID is `com.enviouswispr.app.dev`, (2) signed with stable 'EnviousWispr Dev' cert"
- **Caveat**: Document that first-time grant after cert creation still requires manual System Settings approval

### 5. Entitlements file — NOT NEEDED FOR DEV
- **Decision**: No entitlements file for standard dev builds (no HRT = no restrictions to opt out of)
- **Future**: If HRT testing is needed, create `EnviousWispr-dev.entitlements` with `get-task-allow` as a separate opt-in
- **Prod entitlements**: Already exist at `Sources/EnviousWispr/Resources/EnviousWispr.entitlements` (used by release pipeline)

### 6. Dev cert auto-creation — PHASE 2, NOT PHASE 3
- **Flash strongly disagrees with Pro's deferral**: "Cert creation is a one-time Xcode action" doesn't apply when there's no Xcode
- **Implementation**: Script cert creation using `security` CLI commands. Create a self-signed cert with fixed Common Name, import into login keychain. Only run if preflight check fails
- **This is the highest-impact TCC fix** and must ship with Phase 2

---

## New Items (from second opinion)

### 7. Dev icon badge
- **Both agree**: Visual "DEV" badge on app icon prevents launching wrong build
- **Implementation**: Create `dev-AppIcon.icns` (badge via ImageMagick or sips), copy in bundle-app based on build type
- **Verdict**: Nice-to-have, include if cheap. Could be as simple as a different-colored icon

### 8. Rich version stamping
- **Flash only**: `0.0.0-local` is too simplistic for bug reports
- **Suggested format**: `1.0.0-dev+abcdef` (base version + git short hash)
- **Implementation**: `plutil -replace CFBundleVersion -string "$(git describe --tags --always)-dev"`
- **Verdict**: Good idea, low effort. Include in Phase 2

### 9. Clean code signature before signing
- **Flash only**: `rm -rf "$BUNDLE/Contents/_CodeSignature"` before codesign
- **Verdict**: The bundle-app skill already does `rm -rf "$BUNDLE"` at the start (fresh bundle every time), so _CodeSignature can't be stale. Not needed

### 10. Dev-specific app configuration
- **Flash only**: Different API endpoints, logging levels, feature flags for dev vs prod
- **Verdict**: Not applicable right now — the app uses the same APIs in dev and prod. UserDefaults are already separated by bundle ID. No action needed

### 11. Sandbox status
- **Flash only**: Asks if app is sandboxed
- **Answer**: No — the app is not sandboxed (non-sandboxed SPM CLI build). Not applicable

---

## Final Phase 2 Scope (6 items)

| # | Item | Effort | Impact |
|---|------|--------|--------|
| 1 | Stamp dev bundle ID + verify | Small | Critical — foundation of isolation |
| 2 | Disable Sparkle in dev builds (blank SUFeedURL) | Small | High — prevents update confusion |
| 3 | Auto-create + persist self-signed dev cert | Medium | Critical — fixes TCC persistence |
| 4 | Rich version stamping (git hash) | Small | Medium — better bug reports |
| 5 | Update TCC guidance in gotchas.md | Small | Medium — accurate documentation |
| 6 | Dev icon badge | Medium | Low — nice-to-have visual distinction |

## Implementation Order

1. Auto-create/persist self-signed cert (#3) — foundational for signing
2. Stamp dev bundle ID + verification (#1) — foundational for isolation
3. Disable Sparkle (#2) — quick win, depends on plist stamping pattern
4. Rich version stamping (#4) — quick win, same stamping pattern
5. Update TCC guidance (#5) — documentation, depends on #1-3 being done
6. Dev icon badge (#6) — polish, independent of everything else

## Decisions Made

- **Signing**: Self-signed "EnviousWispr Dev" cert (NOT Apple Development)
- **Hardened Runtime**: OFF for dev builds (no `--options runtime`)
- **Entitlements**: NOT needed for dev builds
- **Sparkle**: Blank SUFeedURL (keep framework embedded for now)
- **Cert auto-creation**: Phase 2 (not deferred)

## Deferred to Phase 3

- Omit Sparkle.framework entirely from dev builds (conditional embedding)
- Separate "hardened dev" build skill for HRT testing
- Dev-specific configuration mechanism (if needed later)
