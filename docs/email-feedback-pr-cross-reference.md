# PR Cross-Reference: Open Findings vs Open PRs

## Summary

| Finding | Severity | Open PR | Addressed in PR? | Evidence |
|---------|----------|---------|-------------------|----------|
| 1 - release.yml self-copy | P0 | PR #13 | NO | PR only removes `pull-requests: write`; the `cp "$GITHUB_WORKSPACE/appcast.xml" appcast.xml` line at line 175 is untouched |
| 6 - onboarding abort | P2 | PR #7 | PARTIAL | `willCloseNotification` handler calls `updateIcon()` in abort path but does NOT call `NSApp.setActivationPolicy(.accessory)` |
| 10 - Sparkle bump | DEP | PR #2 | YES | Package.resolved updated: `2.8.1` → `2.9.0`, revision `5581748c` → `21d8df80` |

---

## Detailed Analysis

### Finding 1 vs PR #13

**Finding:** Line 175 of `.github/workflows/release.yml` contains:
```yaml
cp "$GITHUB_WORKSPACE/appcast.xml" appcast.xml
```
This runs after `git checkout main` inside the appcast-update step, meaning the file is being copied onto itself (same path in workspace). The copy is a no-op at best and a silent data-loss risk if the paths diverge under a different runner working directory.

**What PR #13 actually changes in `release.yml`:**

The diff for `release.yml` in PR #13 is exactly one line:
```diff
 permissions:
   contents: write
-  pull-requests: write
```

That is the entirety of the `release.yml` change. The `pull-requests: write` permission was a leftover from when the appcast update was done via PR (the old flow); PR #13 correctly removes it now that appcast pushes go direct to `main` via `APPCAST_BOT_TOKEN`. However, the self-copy bug at line 175 is **not touched**.

Confirmed by checking the current file on the local `feature/022-onboarding` branch (which shares the main-branch state for this file):
```
line 175: cp "$GITHUB_WORKSPACE/appcast.xml" appcast.xml
```

**Verdict: Finding 1 is NOT addressed by PR #13. It remains fully open.**

---

### Finding 6 vs PR #7

**Finding:** In `AppDelegate.swift`, the `onboardingCloseObserver` (fires when the user clicks the red X to close the onboarding window mid-flow) calls `updateIcon()` but omits `NSApp.setActivationPolicy(.accessory)`. This leaves the app in `.regular` policy after abort — meaning the Dock icon remains visible and the app behaves as a regular app rather than a menu-bar utility.

**What PR #7 introduces:**

The branch adds a `willCloseNotification` observer inside `openOnboardingWindow()`. The abort path (when `onboardingState != .completed` at close time) is:

```swift
// Only treat as abort if onboarding not yet completed.
if self.appState.settings.onboardingState != .completed {
    self.updateIcon()
}
```

`updateIcon()` is called — but `NSApp.setActivationPolicy(.accessory)` is **not** called in this abort branch.

For comparison, the success path (`closeOnboardingWindow()`, called by the Done button) correctly does both:
```swift
func closeOnboardingWindow() {
    dismissOnboardingAction?()
    NSApp.setActivationPolicy(.accessory)  // present
    updateIcon()
}
```

There is also a state-driven dismissal path in `EnviousWisprApp.swift` (the `.onChange(of: isOnboardingPresented)` handler), which does call `NSApp.setActivationPolicy(.accessory)` — but that path fires only when `isOnboardingPresented` is flipped to `false` programmatically. When the user force-closes the window via the red X, the `willCloseNotification` handler fires, not the state-driven path.

**Verdict: Finding 6 is PARTIALLY addressed. The close observer infrastructure is new and correct. However, the abort branch inside `willCloseNotification` still calls only `updateIcon()` and omits `NSApp.setActivationPolicy(.accessory)`. Merging PR #7 will not fully fix Finding 6.**

---

### Finding 10 vs PR #2

**Finding:** Sparkle is pinned to 2.8.1 in `Package.resolved`; 2.9.0 is available.

**What PR #2 changes:**

The diff is exactly the expected dependency bump in `Package.resolved`:
```diff
-        "revision" : "5581748cef2bae787496fe6d61139aebe0a451f6",
-        "version" : "2.8.1"
+        "revision" : "21d8df80440b1ca3b65fa82e40782f1e5a9e6ba2",
+        "version" : "2.9.0"
```

The `originHash` is also updated, confirming this is a legitimate `swift package update` output, not a manual edit. `Package.swift` itself is not changed (the version constraint already accommodates 2.9.0).

**Verdict: Finding 10 is FULLY addressed by PR #2. Merging it closes the finding.**

---

## Revised Status

| Finding | True Status after PR analysis |
|---------|-------------------------------|
| 1 - release.yml self-copy (P0) | **OPEN** — No existing PR fixes it. Must be addressed manually. |
| 6 - onboarding abort (P2) | **OPEN** — PR #7 is the right PR to fix it in, but the fix is incomplete. The abort branch in `willCloseNotification` needs `NSApp.setActivationPolicy(.accessory)` added before `updateIcon()`. |
| 10 - Sparkle bump (DEP) | **WILL CLOSE on PR #2 merge** — Complete and correct. |

---

## Updated Recommendation

### What merging the existing PRs resolves

- **PR #2 merge**: Closes Finding 10 entirely. No further action needed on Sparkle.
- **PR #13 merge**: Does not close any of the three findings. Its `release.yml` change (removing `pull-requests: write`) is correct cleanup but is unrelated to Finding 1.
- **PR #7 merge**: Does not close Finding 6. The onboarding infrastructure is substantially improved, but the one-line omission in the abort path persists.

### What still needs manual work after all PRs are merged

**Finding 1 (P0) — release.yml self-copy: requires a dedicated fix.**

In `.github/workflows/release.yml`, the step that runs after `git checkout main` (around line 175) contains:
```yaml
cp "$GITHUB_WORKSPACE/appcast.xml" appcast.xml
```
After `git checkout main` into a temp directory, `appcast.xml` has already been written to the workspace root by the preceding Python step. The `cp` of the workspace file back onto itself is redundant. The correct fix depends on intent:
- If the intent is to copy the just-generated appcast into the checked-out `main` working tree, verify the destination path is the `main`-checkout directory, not `$GITHUB_WORKSPACE` itself.
- Simplest safe fix: remove the `cp` line if the file is already in the correct location from the Python write step.

**Finding 6 (P2) — onboarding abort missing activation policy: requires a one-line fix inside PR #7.**

In `Sources/EnviousWispr/App/AppDelegate.swift`, inside the `openOnboardingWindow()` method's `willCloseNotification` handler, the abort block:
```swift
if self.appState.settings.onboardingState != .completed {
    self.updateIcon()
}
```
needs to become:
```swift
if self.appState.settings.onboardingState != .completed {
    NSApp.setActivationPolicy(.accessory)
    self.updateIcon()
}
```
This one-line addition aligns the abort path with the success path in `closeOnboardingWindow()`. The fix should be applied to the `feature/022-onboarding` branch before PR #7 is merged.
