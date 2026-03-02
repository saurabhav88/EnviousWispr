# Feature: First-Run Onboarding Experience

**ID:** 022
**Category:** UX / First-Run
**Priority:** Critical
**Status:** Ready for Implementation

## Problem

A fresh install of EnviousWispr provides no guidance. The app launches silently as a menu bar icon with no window, no setup wizard, and no explanation. A new user sees a mystery icon and has no idea what to do. The existing 4-step onboarding sheet only appears when the Settings window is manually opened — which never happens automatically.

Fresh-install audit revealed these gaps:
- No window opens on first launch
- Onboarding steps don't gate progress (user can skip permissions)
- No persistent warning for missing microphone permission
- Silent ~100MB model download on first recording with no progress indicator
- AI Polish feature is invisible — LLM defaults to `.none` silently
- Only Accessibility has a menu bar warning; nothing for mic or LLM

## Proposed Solution

A dedicated 4-step onboarding window that auto-opens on first launch, guides the user to their first successful transcription, and introduces optional enhancements.

### Design Principles
- **Auto-open on first launch** — don't wait for menu bar interaction (Raycast pattern)
- **Hard gate on microphone** — the app is useless without it
- **Soft gate on everything else** — Accessibility and AI Polish are opt-in enhancements
- **Show the hotkey while the model downloads** — turn dead time into learning time
- **Interactive "try it now"** — the user's first transcription happens during onboarding
- **Respect the user's time** — entire flow takes ~60 seconds

### Step 1: Welcome + Microphone Permission (Hard Gate)

**UI:**
- Headline: "Welcome to EnviousWispr"
- Body: "Press a hotkey to transcribe your voice. First, we need microphone access."
- Visual: Simple icon progression (Mic → App → Text)
- Button: "Grant Microphone Access" → triggers system permission dialog

**Gating logic:**
- Button triggers `AVCaptureDevice.requestAccess(for: .audio)`
- "Continue" button is **disabled** until permission is granted
- If user denies: show inline recovery UI with "Open System Settings" button linking to `Privacy & Security > Microphone`
- If user grants: auto-transition to Step 2

**State:** `onboardingState` transitions from `needsMicPermission` → `needsModelDownload`

### Step 2: Model Download + Hotkey Introduction (Combined)

**UI:**
- Headline: "Getting Ready..."
- Indeterminate spinner (FluidAudio doesn't expose download progress)
- Body: "Downloading the on-device transcription model (~100MB). This is a one-time setup that enables fast, private dictation."
- Below spinner: "Your hotkey is **Option + D**. Press and hold it anytime to start dictating."
- Helper text: "Usually takes less than a minute on a standard connection."

**Logic:**
- Model download starts immediately via `ParakeetBackend.prepare()`
- All navigation buttons disabled during download
- On completion: auto-transition to Step 3
- On failure: show retry button + error message

**State:** `onboardingState` transitions from `needsModelDownload` → `completed` (internally; flow continues)

### Step 3: Interactive Tutorial ("Try It Now")

**UI:**
- Headline: "Let's Try It Out"
- Body: "Press and hold **Option + D**, say a few words, then release."
- Visual: Animated keyboard diagram showing the keys
- Live feedback area: `[ Waiting for dictation... ]` → `[ Recording... ]` → `[ "Hello world." ]`
- De-emphasized "Skip" link for users who want to finish without testing

**Logic:**
- Hotkey listener is active; pipeline runs on PTT release
- Transcription result displays in the feedback area
- Green checkmark on success → auto-transition to Step 4 after 1-second delay
- Skip button goes directly to Step 4
- No paste occurs during this step (clipboard only)

**Why this is cheap to build:** The PTT → transcribe pipeline already exists. This step is ~50 lines wiring the existing pipeline to a text view in the onboarding window.

### Step 4: Ready + Optional Enhancements

**UI:**
- Headline: "You're All Set!"
- Body: "EnviousWispr is running in your menu bar. Press **Option + D** anytime to dictate."
- **Enhancement section:**
  - Toggle: "Enable Auto-Paste" — subtitle: "Automatically paste transcriptions into the active app."
  - Info line: "AI Polish available — configure in Settings" (links to AI Polish settings tab)
- Button: "Done" → closes window permanently

**Logic:**
- If user toggles Auto-Paste ON: trigger Accessibility permission dialog immediately
- Whether they grant or deny, don't gate on this — it's optional
- "Done" sets `hasCompletedOnboarding = true` and closes the window
- App recedes into menu bar

**Accessibility framing:** We never say "Accessibility permission" in our UI. We say "Enable Auto-Paste." The system dialog explains the rest. This avoids spooking users with the scariest macOS permission.

## Abort Flow (User Closes Window Early)

If the user closes the onboarding window before completing all steps:

1. **Next launch:** Re-open the onboarding window at the step where they left off (not from scratch)
2. **Menu bar:** Show a small warning badge on the icon
3. **Menu content:** Top item becomes "Setup Required: Continue Setup..." which re-opens onboarding
4. **If mic was granted but model not downloaded:** Model downloads on first recording (existing fallback behavior still works)

## Onboarding State Machine

```
enum OnboardingState: String {
    case needsMicPermission    // Fresh install default
    case needsModelDownload    // Mic granted, model not yet downloaded
    case completed             // All required steps done
}
```

Stored in `UserDefaults` under key `"onboardingState"`. Replaces the current `hasCompletedOnboarding` boolean with a more granular state.

## Post-Onboarding Menu Bar Enhancements

| Condition | Menu Bar Behavior |
|---|---|
| Missing mic permission (revoked post-onboarding) | Error icon + "Microphone Access Required" menu item |
| Missing Accessibility (never granted or revoked) | Warning icon + "Paste disabled — enable Auto-Paste..." menu item |
| No LLM configured | Static menu item: "AI Polish available — configure in Settings" (permanent until configured) |
| All configured | Normal operation, no extra items |

## Window Implementation

Use SwiftUI `.window(id: "onboarding")` scene. Auto-open via `openWindow(id: "onboarding")` in `applicationDidFinishLaunching` when `onboardingState != .completed`. Single, non-resizable window (~420x380pt), centered.

**Not a popover** — onboarding is a linear, required setup process. Popovers are for ephemeral interactions and can be accidentally dismissed.

**Not the Settings scene** — the onboarding window is purpose-built and temporary. It closes permanently after completion.

## Files to Modify

| File | Change |
|------|--------|
| `Sources/EnviousWispr/Views/Onboarding/OnboardingView.swift` | **Rewrite** — replace 4-step sheet with new 4-step window content |
| `Sources/EnviousWispr/App/AppState.swift` | Add `OnboardingState` enum, replace `hasCompletedOnboarding` bool, add model download trigger |
| `Sources/EnviousWispr/App/AppDelegate.swift` | Auto-open onboarding window on first launch in `applicationDidFinishLaunching` |
| `Sources/EnviousWispr/App/EnviousWisprApp.swift` | Add `.window(id: "onboarding")` scene |
| `Sources/EnviousWispr/Settings/SettingsManager.swift` | Replace `hasCompletedOnboarding: Bool` with `onboardingState: OnboardingState` |
| `Sources/EnviousWispr/Views/Settings/SettingsView.swift` | Remove old onboarding sheet trigger from `UnifiedWindowView` |
| `Sources/EnviousWispr/App/AppDelegate.swift` | Add mic-missing and LLM-missing menu items to menu bar |

## New Types

```swift
enum OnboardingState: String, Codable {
    case needsMicPermission
    case needsModelDownload
    case completed
}

// In OnboardingView.swift
@Observable
class OnboardingViewModel {
    var currentStep: OnboardingStep = .welcome
    var micPermissionGranted: Bool = false
    var modelDownloadComplete: Bool = false
    var firstTranscriptionResult: String? = nil
    var isDownloading: Bool = false
    var downloadError: String? = nil

    enum OnboardingStep {
        case welcome       // Step 1: Welcome + mic permission
        case modelDownload // Step 2: Download + hotkey intro
        case tryItNow      // Step 3: Interactive tutorial
        case ready         // Step 4: Enhancements + done
    }
}
```

## Design Phase

Before writing code, produce and approve the following artifacts:

### Visual Mockups
- [ ] Step 1 (Welcome + Mic) — layout, icon placement, button states (default, disabled, error recovery)
- [ ] Step 2 (Model Download) — spinner placement, hotkey callout styling, helper text hierarchy
- [ ] Step 3 (Try It Now) — keyboard visual, live feedback area states (waiting → recording → result → success)
- [ ] Step 4 (Ready + Enhancements) — toggle layout, AI Polish discovery link, "Done" button prominence
- [ ] Abort state — menu bar badge appearance, "Setup Required" menu item styling
- [ ] Window chrome — size (~420x380pt), resizability (none), title bar style, close button behavior

### Copy Review
- [ ] All headlines, body text, and button labels finalized
- [ ] Error states: mic denied, mic revoked, model download failed, network offline
- [ ] Accessibility framing — confirm "Enable Auto-Paste" wording works without mentioning "Accessibility"
- [ ] Spinner helper text — validate "usually takes less than a minute" against real download times

### Interaction Spec
- [ ] Step transition animations (cross-fade, slide, or instant)
- [ ] Auto-advance timing (e.g., 1-second delay after successful transcription in Step 3)
- [ ] Keyboard navigation — can the user Tab through buttons? Enter to confirm?
- [ ] Window behavior — can user move it? Does it float above other windows?

### Design Sign-Off
All mockups reviewed and approved before implementation begins. Use `frontend-designer` agent to produce interactive HTML mockups for rapid iteration.

## QA Phase

### Fresh Install Testing
Each test starts from a completely clean state: no `com.enviouswispr.app` UserDefaults, no `~/.enviouswispr-keys/`, TCC permissions reset for the bundle ID.

**Reset commands:**
```bash
defaults delete com.enviouswispr.app 2>/dev/null
rm -rf ~/.enviouswispr-keys/
tccutil reset Microphone com.enviouswispr.app
tccutil reset Accessibility com.enviouswispr.app
```

### Happy Path Tests
- [ ] **HP-1:** Fresh launch → onboarding window auto-opens → grant mic → model downloads → try hotkey → transcription appears → toggle Auto-Paste → grant Accessibility → Done → app recedes to menu bar
- [ ] **HP-2:** Fresh launch → grant mic → model downloads → skip tutorial → Done → app works normally from menu bar
- [ ] **HP-3:** After onboarding complete → quit and relaunch → onboarding does NOT reappear

### Permission Gate Tests
- [ ] **PG-1:** Deny mic permission → "Open System Settings" button appears → cannot advance past Step 1
- [ ] **PG-2:** Deny mic → grant via System Settings while window is open → window detects grant and auto-advances
- [ ] **PG-3:** Grant mic → revoke mic later via System Settings → menu bar shows "Microphone Access Required" item
- [ ] **PG-4:** Toggle Auto-Paste ON → deny Accessibility in system dialog → toggle stays ON but paste silently fails → menu bar shows paste warning

### Abort / Recovery Tests
- [ ] **AB-1:** Close onboarding window at Step 1 (no mic) → relaunch → onboarding reopens at Step 1
- [ ] **AB-2:** Close at Step 2 (mic granted, model downloading) → relaunch → onboarding reopens at Step 2, download restarts
- [ ] **AB-3:** Close at Step 3 (model ready) → relaunch → onboarding reopens at Step 3
- [ ] **AB-4:** Menu bar shows warning badge + "Setup Required" item when onboarding incomplete → clicking it reopens onboarding

### Model Download Tests
- [ ] **MD-1:** Normal download → spinner shows → completes → auto-advances to Step 3
- [ ] **MD-2:** Network offline during download → error message + retry button shown
- [ ] **MD-3:** Model already cached from previous install → Step 2 completes instantly (no re-download)

### Interactive Tutorial Tests
- [ ] **IT-1:** Press and hold PTT hotkey → "Recording..." feedback → release → transcription appears in feedback area
- [ ] **IT-2:** Press hotkey but say nothing → empty/short result → still shows success and advances
- [ ] **IT-3:** Skip button → advances to Step 4 without recording
- [ ] **IT-4:** Transcription during tutorial does NOT paste into any other app (clipboard only)

### Post-Onboarding Menu Bar Tests
- [ ] **MB-1:** No LLM configured → "AI Polish available — configure in Settings" menu item visible
- [ ] **MB-2:** LLM configured → AI Polish menu item disappears
- [ ] **MB-3:** All permissions granted + LLM configured → no extra menu items, clean menu
- [ ] **MB-4:** Accessibility revoked post-onboarding → warning icon + "Paste disabled" menu item appears

### Edge Cases
- [ ] **EC-1:** User has multiple displays → onboarding window appears on primary display
- [ ] **EC-2:** User immediately tries PTT hotkey before completing onboarding → hotkey works if mic is granted, fails gracefully if not
- [ ] **EC-3:** App update from pre-onboarding version → existing users with `hasCompletedOnboarding = true` are migrated to `onboardingState = .completed` (no re-onboarding)
- [ ] **EC-4:** VoiceOver active → all onboarding steps are accessible with proper labels

## Design References

- **Raycast:** Auto-opens setup window, teaches hotkey interactively, recedes to menu bar
- **CleanShot X:** Permission-gated onboarding, explains each permission's purpose
- **Shottr:** Lightweight, teaches screenshot hotkey during setup

## Out of Scope

- Lottie/animated illustrations (static images or SF Symbols are fine)
- Download progress bar (FluidAudio doesn't expose progress; indeterminate spinner is sufficient)
- Usage-count-based feature discovery (too complex; static menu item is simpler)
- Custom NSWindow chrome (SwiftUI window scene is sufficient)
