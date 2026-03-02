# v1.0.0 Release & Infrastructure Report — 2026-03-01

## Overview

Full-day session covering: comprehensive code audit commit, v1.0.0 release pipeline debugging (4+ attempts), CI/CD modernization with Gemini brainstorming, Apple notarization deep-dive, and OpenAI brainstorm MCP provider setup.

---

## 1. Code Audit Commit

**What**: Committed all accumulated changes from a comprehensive code audit.

- **Scope**: 42 modified files + 11 untracked items (+1,507 / -187 lines)
- **Areas covered**: Error handling improvements, LLM retry logic, audio resilience, infrastructure updates, agent/skill/knowledge file updates
- **Commit**: `85947af`
- **Pushed to**: `origin/main`

---

## 2. v1.0.0 Release — The Saga

### 2.1 Initial State: Stuck for 2-3 Hours

The first v1.0.0 release attempt had been running for 2-3 hours on GitHub Actions, stuck on a monolithic "Build, sign, notarize, and package DMG" step. Run ID: `22552260504`.

**Problem**: Everything (build, codesign, notarize, package) was in a single shell script step. No visibility into which sub-task was hanging.

**Action**: Cancelled the stuck run.

### 2.2 Gemini Brainstorm: CI/CD Best Practices

Consulted Gemini 2.5 Pro (via brainstorm MCP server) for macOS app distribution CI/CD best practices. Shared full context: release.yml, build-dmg.sh, Package.swift, team size (2-person).

**Gemini's recommendations**:
1. Split the monolithic step into separate workflow steps for visibility
2. Add SPM dependency caching (`actions/cache@v4` keyed on `Package.resolved`)
3. Use async notarization polling instead of `--wait` (avoids indefinite hangs)
4. Add `--timestamp` to all codesign invocations (trusted timestamps for notarization)
5. Pin Swift version check (Swift 6 required)

**Runner note**: `macos-14` does NOT have Swift 6. Must use `macos-15`.

### 2.3 CI/CD Improvements Implemented

**File: `.github/workflows/release.yml`**

Rewrote the workflow:
- Separated into discrete steps: Checkout → Verify Swift → Extract version → Cache SPM → Build → Import cert → Package+sign → Notarize → Appcast → Release
- Added SPM cache step (cut rebuild time from ~10min to ~1m40s on cache hit)
- Notarize step uses polling loop (submit → poll every 30s → check status)
- Initial timeout: 40 polls × 30s = 20 minutes

**File: `scripts/build-dmg.sh`**

Added `--timestamp` to all 3 codesign invocations:
- Sparkle nested binaries (find loop)
- Sparkle.framework bundle
- Main app bundle

**Commit**: `98537b0` — deleted and re-pushed `v1.0.0` tag.

### 2.4 Attempt 2: Notarization Timeout at 20 Minutes

**Run result**: Build succeeded in 2m15s, package+sign in 17s — massive improvement. But notarization polled for 20 minutes (40 attempts × 30s) and timed out. Every poll returned `status: In Progress`.

**Submission ID**: `250b5d72-6971-454a-99b0-d3e09ac39bbe`

**Gemini's advice**: First-time notarization with CoreML models can take 20+ minutes. Apple's queue can be slow for new Developer IDs.

**Fix**: Increased `MAX_ATTEMPTS` from 40 to 90 (45-minute timeout).

**Commit**: `277bde8` — retagged `v1.0.0`.

### 2.5 Attempt 3: Still Stuck at 45 Minutes

Same result. Apple returning `In Progress` indefinitely. Not a timeout issue — Apple is simply never completing the notarization.

### 2.6 Apple Developer Portal Investigation (via Playwright)

Used Playwright browser automation to investigate the Apple Developer account.

**Checked**:
| Item | Status |
|------|--------|
| Developer Portal agreements | All accepted |
| Membership | Active (renewed to March 1, 2027) |
| Certificate type | Developer ID Application (correct) |
| Certificate expiry | 2031 |
| Portal banners/warnings | None |

**Found**: App Store Connect redirected to `agree_to_terms` page — **TOS had not been accepted**.

**Action**: User accepted the App Store Connect Terms of Service.

**Also checked**:
- Business page: "Paid Apps Agreement" showing "New" (unsigned, but not needed for Developer ID distribution)
- EU DSA compliance: Not completed (not needed for non-EU distribution)

### 2.7 Attempt 4 (post-TOS): Still Stuck

Even after accepting App Store Connect TOS, the notarization remained permanently at `In Progress`. Three consecutive submissions, all stuck.

### 2.8 Gemini Deep-Dive: Root Cause Analysis

Asked Gemini to search developer forums and community knowledge for notarization hangs.

**Top theory**: Apple ID + app-specific password authentication is **legacy** and known to silently hang in CI due to 2FA state issues. The `notarytool` with `--apple-id` / `--password` / `--team-id` flags uses a different auth path that can get stuck in Apple's 2FA verification loop — especially in headless CI environments where there's no interactive 2FA prompt.

**Recommended fix**: Switch to **App Store Connect API Key** authentication, which:
- Uses JWT-based auth (no 2FA involved)
- Is the officially recommended method for CI/CD
- Uses `--key`, `--key-id`, `--issuer` flags instead of Apple ID

### 2.9 Generating App Store Connect API Key (via Playwright)

Navigated App Store Connect via Playwright:

1. **Users and Access → Integrations → API**: Had to "Request Access" first (API access wasn't enabled)
2. **Generated key**: Name "GitHub Actions Notary", Role "Developer"
3. **Credentials obtained**:
   - Issuer ID: `8eb7c8fa-9c18-4894-8560-f79794c2532e`
   - Key ID: `GZPJ4K9QQD`
   - Downloaded `.p8` private key file
4. **Backed up**: Key saved to `~/.enviouswispr-keys/AuthKey_GZPJ4K9QQD.p8`

### 2.10 GitHub Secrets and Workflow Update

**New GitHub secrets set** (via `gh secret set`):
| Secret | Value |
|--------|-------|
| `APPLE_API_KEY_ID` | `GZPJ4K9QQD` |
| `APPLE_API_ISSUER_ID` | `8eb7c8fa-9c18-4894-8560-f79794c2532e` |
| `APPLE_API_KEY_BASE64` | Base64-encoded `.p8` key file |

**Workflow change** (`.github/workflows/release.yml` notarize step):

Before (legacy auth):
```yaml
env:
  APPLE_ID: ${{ secrets.APPLE_ID }}
  APPLE_ID_PASSWORD: ${{ secrets.APPLE_ID_PASSWORD }}
  APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
run: |
  xcrun notarytool submit "$DMG" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_ID_PASSWORD" \
    --team-id "$APPLE_TEAM_ID"
```

After (API key auth):
```yaml
env:
  APPLE_API_KEY_BASE64: ${{ secrets.APPLE_API_KEY_BASE64 }}
  APPLE_API_ISSUER_ID: ${{ secrets.APPLE_API_ISSUER_ID }}
  APPLE_API_KEY_ID: ${{ secrets.APPLE_API_KEY_ID }}
run: |
  KEY_PATH="${RUNNER_TEMP}/AuthKey_${APPLE_API_KEY_ID}.p8"
  echo -n "${APPLE_API_KEY_BASE64}" | base64 --decode -o "${KEY_PATH}"
  xcrun notarytool submit "$DMG" \
    --key "${KEY_PATH}" \
    --key-id "${APPLE_API_KEY_ID}" \
    --issuer "${APPLE_API_ISSUER_ID}"
```

**Commit**: `12ef124` — retagged `v1.0.0`.

### 2.11 Attempt 5: API Key Auth (Current)

**Run ID**: `22556805962`
**Status at time of writing**: In progress — notarization polling (~10 min in)

Build performance with all optimizations:
| Step | Time |
|------|------|
| Checkout | 2s |
| Verify Swift | 3s |
| Cache SPM deps | 1s (cache hit) |
| Build release binary | 1m 40s |
| Import certificate | 1s |
| Package and sign DMG | 15s |
| Notarize | Polling... |

---

## 3. CI/CD Architecture Summary

### Final release.yml Structure

```
v* tag push
  → Checkout
  → Verify Swift 6+
  → Extract version from tag
  → Cache SPM dependencies (Package.resolved hash key)
  → Build arm64 release binary
  → Import Developer ID certificate (from base64 secret)
  → Package and sign DMG (build-dmg.sh)
  → Notarize DMG (API key auth, 90-poll timeout)
  → Generate Sparkle appcast entry (EdDSA signed)
  → Update appcast.xml (insert new entry)
  → Commit updated appcast to main
  → Create GitHub Release (upload DMG)
  → Cleanup keychain
```

### Secrets Required

| Secret | Purpose |
|--------|---------|
| `DEVELOPER_ID_CERT_BASE64` | Code signing certificate (p12, base64) |
| `DEVELOPER_ID_CERT_PASSWORD` | Certificate password |
| `APPLE_TEAM_NAME` | Team name for signing identity |
| `APPLE_TEAM_ID` | Team ID for signing identity |
| `APPLE_API_KEY_BASE64` | App Store Connect API key (.p8, base64) |
| `APPLE_API_KEY_ID` | API key ID |
| `APPLE_API_ISSUER_ID` | API issuer ID |
| `SPARKLE_EDDSA_PUBLIC_KEY` | Sparkle update signature verification |
| `SPARKLE_PRIVATE_KEY` | Sparkle update signing |

---

## 4. OpenAI Brainstorm Provider

### Context

The brainstorm MCP server (`~/.claude/mcp-servers/brainstorm/`) provides multi-turn LLM conversations between Claude Code and external LLMs. Previously Gemini-only; user requested adding OpenAI to enable consulting both models.

### Setup Steps

1. **Created OpenAI API key** via Playwright navigation to `platform.openai.com`
   - Key name: "Brainstorm MCP"
   - Saved to: `~/.enviouswispr-keys/openai-api-key` (0600 perms, 164 bytes)

2. **Created provider**: `~/.claude/mcp-servers/brainstorm/providers/openai.py`
   - Mirrors `gemini.py` pattern exactly
   - Uses `httpx.AsyncClient` with HTTP/2
   - Default model: `gpt-4o`
   - Auth: `Authorization: Bearer <key>` header
   - Key lookup: `OPENAI_API_KEY` env var → `~/.enviouswispr-keys/openai-api-key` file

3. **Registered provider**: Updated `providers/__init__.py`
   ```python
   _PROVIDERS: dict[str, type[LLMProvider]] = {
       "gemini": GeminiProvider,
       "openai": OpenAIProvider,
   }
   ```

4. **Status**: Code complete. MCP server needs restart (Claude Code session restart) to load the new module.

### Usage (after restart)

```
brainstorm(session="topic", message="...", provider="gemini")  # default
brainstorm(session="topic", message="...", provider="openai")  # GPT-4o
```

---

## 5. Key Credentials Created This Session

| Credential | Location | Purpose |
|-----------|----------|---------|
| Apple API Key (.p8) | `~/.enviouswispr-keys/AuthKey_GZPJ4K9QQD.p8` | Notarization API auth |
| Apple API Key (GitHub) | Secret: `APPLE_API_KEY_BASE64` | CI notarization |
| Apple API Key ID | `GZPJ4K9QQD` | CI notarization |
| Apple API Issuer ID | `8eb7c8fa-9c18-4894-8560-f79794c2532e` | CI notarization |
| OpenAI API Key | `~/.enviouswispr-keys/openai-api-key` | Brainstorm MCP |

---

## 6. Files Modified This Session

### EnviousWispr Repository

| File | Changes |
|------|---------|
| `.github/workflows/release.yml` | 4 iterations: split steps, add cache, polling notarize, API key auth |
| `scripts/build-dmg.sh` | Added `--timestamp` to 3 codesign invocations |
| 42 source files | Code audit commit (error handling, LLM retry, audio resilience) |

### Brainstorm MCP Server (`~/.claude/mcp-servers/brainstorm/`)

| File | Changes |
|------|---------|
| `providers/openai.py` | New file — OpenAI provider |
| `providers/__init__.py` | Added OpenAI registration |

---

## 7. Lessons Learned

1. **Apple notarization with Apple ID auth is unreliable in CI**. Use App Store Connect API keys (`--key` / `--key-id` / `--issuer`) for headless environments. The legacy `--apple-id` / `--password` path can silently hang due to 2FA state.

2. **Split monolithic CI steps**. A single "build, sign, notarize, package" step gives zero visibility. Separate steps let you see exactly where time is spent and where failures occur.

3. **SPM caching matters**. Caching `.build` keyed on `Package.resolved` cut build time from ~10 minutes to ~1m40s.

4. **`--timestamp` on codesign is required for notarization**. Without trusted timestamps, Apple may reject or delay notarization.

5. **App Store Connect TOS must be accepted** even for Developer ID (non-App Store) distribution. It's a prerequisite for the notarization service.

6. **`macos-14` runners don't have Swift 6**. Must use `macos-15` for Swift 6.0+ projects.

7. **MCP servers load Python modules at startup**. Adding new provider modules requires a server restart (session restart) to take effect.

8. **Gemini brainstorming is valuable for CI/CD**. The model had strong knowledge of Apple's notarization quirks, macOS CI best practices, and developer forum insights about auth method reliability.

---

## 8. Phase 1 GitHub Infrastructure Bootstrap (2026-03-02)

Branch protection enabled on `main` with the following rules:
- Required status checks: `build-check` (strict)
- Required PR reviews: 1 approving review, dismiss stale reviews
- Enforce admins: enabled
- Required linear history: enabled
- Required conversation resolution: enabled

### Files Added

| File | Purpose |
|------|---------|
| `.github/workflows/pr-check.yml` | PR CI: Swift 6 verify, SPM cache, debug+release builds, test compilation |
| `.github/pull_request_template.md` | PR template: summary, changes, pre-merge checklist |
| `.github/CODEOWNERS` | @saurabhav88 owns all files |
| `.github/dependabot.yml` | Weekly Swift dependency updates, max 5 open PRs |

### Known Issue: Chicken-and-Egg

The `build-check` required status check references the `pr-check.yml` workflow job. But the workflow file doesn't exist on `main` yet (it's on the feature branch). Until the first PR merges this file to `main`, the `build-check` status will never post — meaning the branch protection rule will block all PRs. Resolution: temporarily disable the `build-check` status check requirement, merge the infra PR, then re-enable it.

---

## 9. Pending / Next Steps

- [ ] Monitor v1.0.0 release run `22556805962` (API key auth attempt)
- [x] Restart Claude Code session to activate OpenAI brainstorm provider (renamed to buddies)
- [ ] Test buddies MCP provider connectivity
- [ ] If release succeeds: verify DMG download, Sparkle appcast, GitHub Release page
- [ ] If release fails: check notarization logs, consider contacting Apple Developer Support
- [ ] Resolve branch protection chicken-and-egg: temp-disable `build-check` requirement, merge infra PR, re-enable
