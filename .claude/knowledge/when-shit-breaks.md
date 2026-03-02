# When Shit Breaks — Incident Response Checklists

Quick-action checklists for the most common crises. No matrices.

---

## Build Fails

```
1. swift package clean
2. swift package resolve
3. swift build 2>&1 | head -60   # read the FIRST error, not the cascade
4. Dispatch build-compile agent with exact error text
```

**Common root causes:**

- **Stale cache**: `swift package clean` almost always fixes mysterious type-not-found or linker errors after a Package.swift change
- **FluidAudio naming collision**: Never use `FluidAudio.X` — use unqualified names. See gotchas.md.
- **@preconcurrency missing**: FluidAudio, WhisperKit, AVFoundation all need `@preconcurrency import`
- **Swift 6 concurrency error**: Send a `nonisolated(unsafe)` or `@Sendable` annotation; dispatch quality-security agent if unclear
- **arm64-only**: `--arch arm64` required for release builds (FluidAudio uses Float16)

**Don't guess. Dispatch build-compile agent with the first compiler error.**

---

## Critical Bug in Production

### Rollback a Release

```bash
# 1. Delete the GitHub Release (keeps the tag but removes assets + release notes)
~/bin/gh release delete v1.0.X --repo saurabhav88/EnviousWispr --yes

# 2. Delete the tag (forces CI to not re-trigger on it)
git push origin :refs/tags/v1.0.X

# 3. Roll back appcast.xml to the last good version
git checkout -b hotfix/rollback-appcast-v1.0.Y
git checkout <last-good-commit> -- appcast.xml
git commit -m "fix(release): roll back appcast.xml to v1.0.Y"
git push -u origin hotfix/rollback-appcast-v1.0.Y
~/bin/gh pr create --base main --title "fix(release): roll back appcast to v1.0.Y" --body "Emergency rollback"
~/bin/gh pr merge --squash --admin  # admin merge to skip review in emergencies

# 4. Verify Sparkle feed points to last-good DMG
curl https://saurabhav88.github.io/EnviousWispr/appcast.xml | grep enclosure
```

**Sparkle clients already running will check the feed on their next update interval. Rolling back appcast.xml stops them from downloading the bad version.**

### Hot-fix Flow

```
1. Create branch: git checkout -b hotfix/v1.0.X+1
2. Apply fix
3. Tag: git tag v1.0.X+1
4. Push tag: git push origin v1.0.X+1  ← triggers CI release
5. CI builds, signs, notarizes, uploads DMG, updates appcast.xml
```

---

## Secret Leaked (API Key, Cert Password, Sparkle Private Key)

**Act in under 15 minutes.**

### Step-by-step

```
1. ROTATE the secret first — make the leaked value useless
   - Ollama: no rotation needed (local only)
   - OpenAI/Gemini: revoke key in provider dashboard, generate new one
   - Apple Developer cert: revoke in developer.apple.com, generate replacement cert
   - Sparkle private key: generate new pair (see below)

2. Update GitHub Secrets (Settings → Secrets and variables → Actions)
   - Replace the affected secret value

3. Update local storage
   - API keys: rm ~/.enviouswispr-keys/<key-file> && re-enter in Settings UI
   - Sparkle private key: overwrite /tmp/sparkle_eddsa_private_key.txt (temp) AND Keychain entry

4. Scan git history for the leaked value
   git log -p | grep -i "<leaked-value>"
   # If found: git-filter-repo to purge, force-push, notify GitHub support

5. Revoke the old value at the source — confirm it no longer works

6. Rebuild + re-release if signing cert was affected
```

### Rotate Sparkle EdDSA Key Pair

```bash
# Generate new pair
.build/artifacts/sparkle/Sparkle/bin/generate_keys

# Update Info.plist with new SUPublicEDKey
# Update GitHub Secret SPARKLE_PRIVATE_KEY with new private key
# Re-sign all existing release DMGs or yank them
```

### KeychainManager Note

`KeychainManager` stores keys at `~/.enviouswispr-keys/` (dir 0700, files 0600). File-based — no macOS Keychain API. To wipe all keys: `rm -rf ~/.enviouswispr-keys/`. Users re-enter keys via Settings UI.

---

## API / LLM Service Down

### Ollama (local)

```
Symptom: Polish silently returns unpolished text or errors with "connection refused"

1. Check server: curl http://localhost:11434/api/tags
2. If down: ollama serve &
3. Check model loaded: ollama list
4. If model missing: ollama pull <model-name>
5. Verify in app: Settings → Polish → Test Connection

OllamaSetupService checks availability on launch. 3-second strict timeout.
If server unavailable, TranscriptionPipeline skips polish and returns raw transcript.
```

### OpenAI / Gemini (remote)

```
Symptom: Polish fails, error logged in Debug Mode

1. Check status page (provider dashboard or status.openai.com)
2. If API key issue: Settings → API Keys → re-enter and save
3. Retry logic: LLMNetworkSession has no built-in retry — user must re-trigger
4. Fallback: TranscriptionPipeline falls through to raw transcript on error

User-facing: show error banner via AppState.showError() — never silently drop output
```

### Auto-retry pattern (for future improvement)

```swift
// Exponential backoff — not yet implemented, tracked in roadmap
// For now: fail fast, surface error, let user retry manually
```

---

## Accessibility / Permission Broken

### After Every Rebuild (Expected Behavior)

```
Every swift build changes the binary hash → macOS invalidates TCC grant → paste stops working.

Fix:
1. Open System Settings → Privacy & Security → Accessibility
2. Find EnviousWispr, toggle off then on
   (or: remove and re-add the app)

DO NOT run: tccutil reset Accessibility  ← wipes ALL apps on the system
DO run:     tccutil reset Accessibility com.enviouswispr.app  ← scoped reset
```

### Ad-hoc vs Developer ID Signing

```
TCC persistence depends on signing:

AD-HOC (local dev):
  - TCC grant tied to binary hash → invalidated on every rebuild
  - Expected: re-grant manually after each build

DEVELOPER ID (release):
  - TCC grant tied to Team ID + bundle ID → persists across updates
  - Sparkle auto-updates keep permissions
  - Rebuild doesn't break Accessibility

To stop re-granting on every build:
  export CODESIGN_IDENTITY="Developer ID Application: <name> (<TEAMID>)"
  ./scripts/build-dmg.sh  ← signs with Developer ID, TCC survives rebuilds
```

### Microphone Permission Reset

```
Symptom: app opens, no audio captured, no error shown

1. System Settings → Privacy & Security → Microphone → verify EnviousWispr is on
2. If missing: scoped reset: tccutil reset Microphone com.enviouswispr.app
3. Relaunch app — macOS will re-prompt on first audio capture attempt
4. Do NOT use blanket reset (no bundle ID arg)
```

### Permission Revoked at Runtime

```
App polls Accessibility every 5 seconds (TimingConstants.accessibilityPollIntervalSec).
On revocation:
  - Warning banner appears in overlay via resetAccessibilityWarningDismissal()
  - Paste silently fails until permission restored
  - No crash — graceful degradation

To re-arm warning after manual grant: app calls refreshAccessibilityStatus() on activate.
```

---

## Sparkle Framework Not Found (App Crashes on Launch)

```
Symptom: dyld: Library not loaded: @rpath/Sparkle.framework/...

Cause: bundle missing Contents/Frameworks/Sparkle.framework, or rpath not set

Fix (scripts/build-dmg.sh does this automatically):
1. cp -R .build/artifacts/sparkle/Sparkle/Sparkle.framework \
       EnviousWispr.app/Contents/Frameworks/
2. install_name_tool -add_rpath @executable_path/../Frameworks \
       EnviousWispr.app/Contents/MacOS/EnviousWispr
3. codesign --force --sign - \
       EnviousWispr.app/Contents/Frameworks/Sparkle.framework
```

---

## CI Release Workflow Fails

```
Trigger: git tag v* push fails in GitHub Actions

1. Check run: ~/bin/gh run list --repo saurabhav88/EnviousWispr
2. View logs: ~/bin/gh run view <run-id> --log-failed
3. Common failures:
   - Missing secret → Settings → Secrets → add the missing one
   - Notarization rejected → check entitlements file, re-sign with --options runtime
   - DMG not uploaded → re-run: ~/bin/gh run rerun <run-id>
   - Wrong runner → release.yml must use macos-15 (Swift 6.0+ required)

Runner requirement: macos-15 (not macos-latest — may map to older runner)
```

---

## Quick Reference

| Symptom | First action |
|---------|-------------|
| Build error | `swift package clean && swift package resolve` |
| Paste not working after rebuild | System Settings → Accessibility → re-grant |
| Ollama polish silent failure | `curl http://localhost:11434/api/tags` |
| App crashes on launch | Check for Sparkle.framework in Contents/Frameworks/ |
| Auto-update broken | Check appcast.xml EdDSA signature matches Info.plist SUPublicEDKey |
| CI release failed | `~/bin/gh run list --repo saurabhav88/EnviousWispr` |
| Secret leaked | Rotate at source → update GitHub Secrets → update local storage |
