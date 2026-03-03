# Email Feedback Implementation Plan

> Generated 2026-03-02 from audit of 34 GitHub bot emails.
> Reviewed by: Claude (gap analysis) + Gemini (plan polish via buddies)

---

## Audit Summary

| Metric | Value |
|--------|-------|
| Emails scanned | 34 |
| Actionable findings | 10 |
| Already fixed | 5 |
| Moot (bot was wrong) | 2 |
| **Still open** | **3** |

---

## Phase 1: Unblock the Release Pipeline

**Finding**: [P0] Self-copy bug in `release.yml` — blocks every release
**Complexity**: Low (trivial code change, validation is key)
**File**: `.github/workflows/release.yml`

### Problem

Line 175: `cp "$GITHUB_WORKSPACE/appcast.xml" appcast.xml` runs after `git checkout main`. Since `$GITHUB_WORKSPACE` IS the working directory, source and destination are the same file. Under GitHub Actions' implicit `-e` mode, `cp` either errors or silently no-ops — the updated appcast never gets committed to main.

### Fix

```yaml
# BEFORE (broken):
git fetch origin main
git checkout main
cp "$GITHUB_WORKSPACE/appcast.xml" appcast.xml
git add appcast.xml

# AFTER (fixed):
git fetch origin main
git checkout main
git add -f appcast.xml
```

The `-f` flag ensures staging even if `appcast.xml` is in `.gitignore`.

### Validation

1. Apply fix, merge to `main`
2. Next release workflow should complete successfully
3. Verify the commit on `main` contains the updated `appcast.xml`

---

## Phase 2: Correct Onboarding UX Flaw

**Finding**: [P2] Onboarding abort (red X) doesn't restore `.accessory` mode
**Complexity**: Low
**File**: `Sources/EnviousWispr/App/AppDelegate.swift` ~line 152

### Problem

When a user closes the onboarding window via the red X button, `onboardingCloseObserver` calls `self.updateIcon()` but never restores `.accessory` activation policy. The Done button path (`closeOnboardingWindow()`) correctly calls `NSApp.setActivationPolicy(.accessory)`. Result: app stays visible in Dock after aborting onboarding — bad UX for a menu-bar utility.

### Fix

```swift
// BEFORE:
if self.appState.settings.onboardingState != .completed {
    self.updateIcon()
}

// AFTER:
if self.appState.settings.onboardingState != .completed {
    NSApp.setActivationPolicy(.accessory)
    self.updateIcon()
}
```

### Recommended Improvement (optional)

Refactor into a shared function to prevent future divergence between exit paths:

```swift
private func finalizeOnboarding() {
    NSApp.setActivationPolicy(.accessory)
    self.updateIcon()
}
```

Both `closeOnboardingWindow()` and `onboardingCloseObserver` would call this.

### Validation

1. Launch app to trigger onboarding (clear settings or first-run)
2. Confirm app icon appears in Dock
3. Click the red X to close onboarding window
4. **Expected**: App icon disappears from Dock immediately
5. Relaunch, complete onboarding via Done button — verify that path still works

---

## Phase 3: Update Sparkle Dependency

**Finding**: [DEP] Sparkle 2.8.1 → 2.9.0 available (Dependabot PR #2)
**Complexity**: Low (code) / Medium (testing)
**File**: `Package.resolved`

### Problem

Sparkle 2.8.1 is pinned in `Package.resolved`. Version 2.9.0 is available with significant benefits:

- **Swift concurrency annotations** — critical for our Swift 6 strict mode
- **Markdown release notes** — macOS 12+ (we target 14+)
- **Signed/verified appcast feeds** — security improvement
- **In-memory temp file downloads** — reduces disk I/O
- **Impatient update check interval** — better auto-update UX

### Fix

```bash
swift package update sparkle
swift build  # verify no breaking changes
```

Alternatively, merge Dependabot PR #2.

### Risks

Sparkle is fundamental to app delivery. A regression here blocks all future updates for shipped users.

### Validation

1. Build compiles cleanly with 2.9.0
2. Check `@preconcurrency import Sparkle` still compiles (may become unnecessary with new concurrency annotations)
3. Full end-to-end auto-update test:
   - Build v1 with old Sparkle, v2 with new Sparkle
   - Point v1 at local appcast serving v2
   - Trigger "Check for Updates" — verify download, install, relaunch
   - In v2, verify "Check for Updates" reports up-to-date

---

## Items Already Resolved (No Action Needed)

| # | Finding | Status | Why |
|---|---------|--------|-----|
| 2 | Missing CodeQL permissions | N/A | CodeQL workflow was never merged |
| 3 | Sparkle feed URL mismatch | FIXED | All 3 sources (release.yml, build-dmg.sh, Info.plist) now agree on GitHub Pages URL |
| 4/5 | AppConstants.appName mismatch | FIXED | Both SwiftUI window and AppDelegate now use `AppConstants.appName` dynamically |
| 7/8 | TCC docs .dev bundle ID | MOOT | `.dev` bundle ID exists in Info.plist — bot's premise was wrong |
| 9 | Non-retryable branch names | FIXED | Branch-based PR approach replaced with direct push to main |

---

## Execution Order

```
Phase 1 (P0) → Phase 2 (P2) → Phase 3 (DEP)
```

Phase 1 is a release blocker and should be done first. Phase 2 is a quick UX fix. Phase 3 requires the most testing but carries the most long-term value.

**Estimated total effort**: ~2-3 hours including testing.
