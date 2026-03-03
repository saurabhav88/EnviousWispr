# Phase 1 Onboarding Fixes — Implementation Plan

Date: 2026-03-02
Author: Coordinator (implementation planner)
Status: FINAL (Gemini-vetted 2026-03-02)
Target file: `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Views/Onboarding/OnboardingView.swift`

---

## Summary of Issues

| # | Issue | Severity |
|---|-------|----------|
| 1 | Mic permission button appears even when TCC is `.denied`/`.restricted`; pressing it silently fails | High |
| 4 | API key TextField uses OpenAI-only placeholder regardless of selected provider; placeholder may be invisible under `.textFieldStyle(.plain)` | Medium |
| 5 | No instructions or link for where to obtain API keys | Medium |
| 6+7 | `applyPolishChoice()` does `break` for BYOK — key is never saved; no inline validation | High |

---

## Implementation Order (Dependency Graph)

```
Issue #1  ─── independent ──────────────────────────────► Done
Issue #4  ─── independent ──────────────────────────────► Done
Issue #5  ─── depends on #4 (BYOKProvider.apiKeyURL) ───► Do after #4
Issue #6+7 ── depends on #4 (provider state, onChange) ──► Do after #4
```

**Recommended execution order:** #1 → #4 → #5 → #6+7

Issues #1 and #4 can be done in any order (or in parallel). Issues #5 and #6+7 must come after #4 because they rely on `BYOKProvider.apiKeyURL` and the consolidated `onChange(of: selectedProvider)` handler introduced in #4.

---

## Issue #1 — Mic Permission Button Shows on Denied/Restricted TCC State

### Files to Modify

- `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Views/Onboarding/OnboardingView.swift`

### Pre-Conditions

- `AVCaptureDevice` is already imported via `@preconcurrency import AVFoundation` at line 2.
- `OnboardingViewModel` is `@MainActor @Observable` (lines 115–196). All mutations are safe on MainActor.
- `micPermissionGranted: Bool` and `micPermissionDenied: Bool` are the current state booleans (lines 129–130).

### Problem Statement

The `.task` block for `.welcome` step (lines 238–245) only checks `.authorized`. When TCC status is `.denied` or `.restricted`, the task exits without setting `micPermissionDenied = true`, so the "Grant Microphone Access" button remains visible. The user presses it, `requestAccess` returns `false` immediately without showing a dialog, and `micPermissionDenied` is finally set — but the user has already experienced a confusing silent failure.

Additionally, Gemini feedback identified that `.restricted` (MDM/parental controls) is distinct from `.denied` (user choice): on `.restricted`, the user cannot fix it themselves, so the "Open System Settings" button must NOT be shown and a different message must be displayed.

### Step-by-Step Changes

#### Step 1.1 — Add `MicPermissionStatus` enum to `OnboardingViewModel`

Insert after line 130 (the `micPermissionDenied: Bool = false` property declaration), inside `OnboardingViewModel`:

```swift
// Replace these two Bool state vars:
//   var micPermissionGranted: Bool = false
//   var micPermissionDenied: Bool = false
// With this enum-based state:

enum MicPermissionStatus: Equatable {
    case notDetermined
    case granted
    case denied          // user denied — can fix in System Settings
    case restricted      // MDM/parental controls — user cannot fix
}
var micStatus: MicPermissionStatus = .notDetermined
```

**Note:** Keep the existing `micPermissionGranted` and `micPermissionDenied` computed properties as compatibility shims so the `WelcomeStepView` UI conditions can be migrated incrementally:

```swift
// Compatibility shims (remove after full migration)
var micPermissionGranted: Bool { micStatus == .granted }
var micPermissionDenied: Bool { micStatus == .denied || micStatus == .restricted }
```

Actually — on reflection, given the restricted case needs distinct UI, do NOT use shims. Replace all 4 references in `WelcomeStepView` with `micStatus` directly in Step 1.3 below.

**Revised approach (cleaner, fewer lines):** Remove the two Bool properties and add the enum. Update all 4 references in `WelcomeStepView` at the same time.

#### Step 1.2 — Update `requestMicPermission()` in `OnboardingViewModel` (lines 151–160)

Replace the existing implementation:

```swift
// BEFORE (lines 151–160):
func requestMicPermission() async {
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    micPermissionGranted = granted
    micPermissionDenied = !granted
    if granted {
        try? await Task.sleep(nanoseconds: 500_000_000)
        advanceToNextStep()
    }
}

// AFTER:
func requestMicPermission() async {
    // Guard: if already denied or restricted, don't call requestAccess
    // (it would return false immediately with no dialog, confusing the user).
    let currentStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    switch currentStatus {
    case .denied:
        micStatus = .denied
        return
    case .restricted:
        micStatus = .restricted
        return
    case .authorized:
        micStatus = .granted
        try? await Task.sleep(nanoseconds: 500_000_000)
        advanceToNextStep()
        return
    case .notDetermined:
        break // fall through to requestAccess below
    @unknown default:
        break
    }

    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    if granted {
        micStatus = .granted
        try? await Task.sleep(nanoseconds: 500_000_000)
        advanceToNextStep()
    } else {
        // After notDetermined→requestAccess→denied, check if restricted
        let finalStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        micStatus = (finalStatus == .restricted) ? .restricted : .denied
    }
}
```

#### Step 1.3 — Update `.task` block for `.welcome` case (lines 238–245)

Replace:

```swift
// BEFORE:
case .welcome:
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .authorized {
        viewModel.micPermissionGranted = true
        try? await Task.sleep(nanoseconds: 300_000_000)
        viewModel.advanceToNextStep()
    }

// AFTER:
case .welcome:
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    switch status {
    case .authorized:
        viewModel.micStatus = .granted
        try? await Task.sleep(nanoseconds: 300_000_000)
        viewModel.advanceToNextStep()
    case .denied:
        viewModel.micStatus = .denied
    case .restricted:
        viewModel.micStatus = .restricted
    case .notDetermined:
        break // user must tap the button
    @unknown default:
        break
    }
```

#### Step 1.4 — Update `WelcomeStepView` UI to use `micStatus` (lines 353, 369, 384, 413, 418, 424)

The view currently uses `viewModel.micPermissionGranted` and `viewModel.micPermissionDenied`. Replace all references:

**Line 353** — icon flow visibility condition:
```swift
// BEFORE:
if !viewModel.micPermissionGranted && !viewModel.micPermissionDenied {

// AFTER:
if viewModel.micStatus == .notDetermined {
```

**Line 369** — success alert:
```swift
// BEFORE:
if viewModel.micPermissionGranted {

// AFTER:
if viewModel.micStatus == .granted {
```

**Line 384** — denied alert:
```swift
// BEFORE:
} else if viewModel.micPermissionDenied {

// AFTER:
} else if viewModel.micStatus == .denied || viewModel.micStatus == .restricted {
```

**Lines 385–405** — denied alert body (replace the hardcoded message with a branch):

```swift
// BEFORE (single message for all denied states):
VStack(spacing: 10) {
    HStack(spacing: 8) {
        Text("Microphone access was denied.")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.obError)
    }
    ...
    Text("Open System Settings > Privacy & Security > Microphone and enable EnviousWispr.")
        ...

// AFTER (branch on restricted vs denied):
VStack(spacing: 10) {
    HStack(spacing: 8) {
        Text(viewModel.micStatus == .restricted
             ? "Microphone access is restricted by your organization."
             : "Microphone access was denied.")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.obError)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: 360)
    .background(Color.obErrorSoft, in: RoundedRectangle(cornerRadius: 12))
    .overlay(
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.obError.opacity(0.2), lineWidth: 1)
    )
    if viewModel.micStatus == .restricted {
        Text("This setting is controlled by a device management profile and cannot be changed.")
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(Color.obTextTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
    } else {
        Text("Open System Settings > Privacy & Security > Microphone and enable EnviousWispr.")
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(Color.obTextTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
    }
}
.padding(.bottom, 18)
```

**Lines 413–429** — button row:
```swift
// BEFORE:
if viewModel.micPermissionDenied {
    Button("Open System Settings") { viewModel.openSystemSettingsForMic() }
    .buttonStyle(OnboardingErrorButtonStyle())
} else if viewModel.micPermissionGranted {
    Button("Continue") { viewModel.advanceToNextStep() }
    .buttonStyle(OnboardingPrimaryButtonStyle())
    .keyboardShortcut(.defaultAction)
} else if !viewModel.micPermissionGranted {
    Button("Grant Microphone Access") { Task { await viewModel.requestMicPermission() } }
    .buttonStyle(OnboardingPrimaryButtonStyle())
    .keyboardShortcut(.defaultAction)
}

// AFTER:
switch viewModel.micStatus {
case .denied:
    Button("Open System Settings") { viewModel.openSystemSettingsForMic() }
        .buttonStyle(OnboardingErrorButtonStyle())
case .restricted:
    EmptyView() // Cannot fix — no action button. Message above explains the situation.
case .granted:
    Button("Continue") { viewModel.advanceToNextStep() }
        .buttonStyle(OnboardingPrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
case .notDetermined:
    Button("Grant Microphone Access") { Task { await viewModel.requestMicPermission() } }
        .buttonStyle(OnboardingPrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
}
```

**Line 436–438** — `lipsState` computed property:
```swift
// BEFORE:
private var lipsState: LipsAnimationState {
    if viewModel.micPermissionDenied { return .denied }
    if viewModel.micPermissionGranted { return .happy }
    return .idle
}

// AFTER:
private var lipsState: LipsAnimationState {
    switch viewModel.micStatus {
    case .denied, .restricted: return .denied
    case .granted: return .happy
    case .notDetermined: return .idle
    }
}
```

#### Step 1.5 — Add AVCaptureDevice notification observer for in-session revocation

This handles the Gemini-identified edge case where the user revokes mic permission from System Settings while onboarding is open.

In `WelcomeStepView.body`, add an `.onReceive` modifier after the existing content:

```swift
// Add after the VStack closing brace in WelcomeStepView body,
// alongside the existing modifiers:
.onReceive(
    NotificationCenter.default.publisher(
        for: AVCaptureDevice.authorizationStatusDidChangeNotification
    )
) { _ in
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    switch status {
    case .authorized:   viewModel.micStatus = .granted
    case .denied:       viewModel.micStatus = .denied
    case .restricted:   viewModel.micStatus = .restricted
    case .notDetermined: viewModel.micStatus = .notDetermined
    @unknown default: break
    }
}
```

Note: `AVCaptureDevice.authorizationStatusDidChangeNotification` is available macOS 10.14+. This project targets macOS 14+, so it is safe.

### New Types/Properties

- `enum MicPermissionStatus` nested in `OnboardingViewModel` (4 cases)
- `var micStatus: MicPermissionStatus = .notDetermined` replacing `micPermissionGranted` + `micPermissionDenied`

### Edge Cases to Handle

1. `.restricted` → no action button, different message (handled in Step 1.4)
2. In-session revocation → `AVCaptureDevice.authorizationStatusDidChangeNotification` observer (Step 1.5)
3. Re-entered onboarding after hard gates cleared → `onAppear` in `OnboardingView` sets `viewModel.micStatus = .granted` (line 230 currently sets `viewModel.micPermissionGranted = true` — update this to `viewModel.micStatus = .granted`)

### Verification

1. `swift build` — confirms no compiler errors from the Bool→enum migration.
2. Manual test (fresh TCC): reset TCC with `tccutil reset Microphone com.enviouswispr.app`, launch app, tap "Grant Microphone Access" → system dialog appears.
3. Manual test (denied TCC): `tccutil reset Microphone com.enviouswispr.app && deny via dialog`, relaunch → denied UI with "Open System Settings" shows immediately on step appear, no button interaction required.
4. Manual test (restricted): Cannot easily simulate, but code path is covered.

---

## Issue #4 — API Key TextField Placeholder Not Provider-Aware / Possibly Invisible

### Files to Modify

- `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Views/Onboarding/OnboardingView.swift`

### Pre-Conditions

- `AIPolishStepView` struct starts at line 703.
- `BYOKProvider` enum is currently defined at line 712 as `enum BYOKProvider { case openai, gemini }` — nested inside `AIPolishStepView`.
- `selectedProvider: BYOKProvider` state var is at line 708.
- The `TextField` is at line 778.

### Problem Statement

Two problems:
1. The placeholder `"sk-..."` is shown even when Gemini is selected. Gemini keys start with `"AIza..."`. Misleading.
2. With `.textFieldStyle(.plain)`, macOS may render placeholder text as invisible or very faint. Using the `TextField("", text:, prompt:)` initializer with explicit `.foregroundColor` is the correct fix for this on macOS 14+.

### Step-by-Step Changes

#### Step 4.1 — Move `BYOKProvider` enum out of `AIPolishStepView`, add `apiKeyURL` and `placeholder` properties

The enum is currently private to `AIPolishStepView` (line 712). Move it to module scope (before `AIPolishStepView`, after `ModelDownloadStepView` closing brace at approximately line 700). This enables `OnboardingViewModel` to reference it in Issue #6+7.

Replace:

```swift
// BEFORE (lines 711–712 inside AIPolishStepView):
enum PolishOption { case onDevice, byok }
enum BYOKProvider { case openai, gemini }

// AFTER (move to module-level, before AIPolishStepView, still inside the file):
// Keep PolishOption inside AIPolishStepView (only used there).
// Move BYOKProvider to module level (used by ViewModel in #6+7).
```

New module-level declaration (insert before `// MARK: - Step 3: AI Polish Setup`):

```swift
// MARK: - BYOK Provider

/// Supported Bring-Your-Own-Key providers for AI Polish.
enum BYOKProvider: Equatable {
    case openai
    case gemini

    /// Placeholder text for the API key input field.
    var keyPlaceholder: String {
        switch self {
        case .openai: return "sk-..."
        case .gemini: return "AIza..."
        }
    }

    /// URL for the API key management page.
    var apiKeyURL: URL {
        switch self {
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/app/apikey")!
        }
    }

    /// Corresponding LLMProvider value.
    var llmProvider: LLMProvider {
        switch self {
        case .openai: return .openAI
        case .gemini: return .gemini
        }
    }

    /// Corresponding KeychainManager key ID.
    var keychainID: String {
        switch self {
        case .openai: return KeychainManager.openAIKeyID
        case .gemini: return KeychainManager.geminiKeyID
        }
    }
}
```

Note: `PolishOption` stays inside `AIPolishStepView` since it's only used there.

Remove the old `enum BYOKProvider { case openai, gemini }` line 712 from inside `AIPolishStepView`.

#### Step 4.2 — Replace the TextField at line 778 with the `prompt:` initializer

Replace:

```swift
// BEFORE (lines 778–787):
TextField("sk-...", text: $apiKey)
    .font(.system(size: 12, weight: .regular, design: .monospaced))
    .textFieldStyle(.plain)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.obBorderHover, lineWidth: 1)
    )

// AFTER:
TextField(
    "",
    text: $apiKey,
    prompt: Text(selectedProvider.keyPlaceholder)
        .foregroundColor(Color.obTextTertiary)
        .font(.system(size: 12, weight: .regular, design: .monospaced))
)
.font(.system(size: 12, weight: .regular, design: .monospaced))
.textFieldStyle(.plain)
.padding(.horizontal, 14)
.padding(.vertical, 10)
.background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 10))
.overlay(
    RoundedRectangle(cornerRadius: 10)
        .strokeBorder(Color.obBorderHover, lineWidth: 1)
)
```

#### Step 4.3 — Add `onChange(of: selectedProvider)` to clear apiKey on switch

This resets the key field when the user switches provider, preventing confusion (a Gemini key submitted to OpenAI or vice versa).

Add inside the `if selectedOption == .byok { ... }` VStack, after the TextField container closing brace (after line 788):

```swift
.onChange(of: selectedProvider) { _, _ in
    apiKey = ""
}
```

**Important:** This handler will be extended in Issue #6+7 to also reset `viewModel.byokValidationState`. Do NOT add a second `.onChange(of: selectedProvider)` — the #6+7 step will replace this one with a combined handler.

### New Types/Properties

- `BYOKProvider` enum moved to module scope with 4 added properties: `keyPlaceholder`, `apiKeyURL`, `llmProvider`, `keychainID`

### Edge Cases to Handle

- User switches from OpenAI to Gemini mid-typing → field clears (Step 4.3).
- `prompt:` parameter's `.font()` modifier must match the field font for visual consistency.

### Verification

1. `swift build` — no errors.
2. Launch app → onboarding → Step 3 → select BYOK → check OpenAI shows `sk-...` placeholder.
3. Switch to Gemini → placeholder changes to `AIza...`, field clears.
4. Both placeholders must be visible (not washed out) against `Color.obCardBg` (white).

---

## Issue #5 — No API Key Acquisition Instructions

### Files to Modify

- `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Views/Onboarding/OnboardingView.swift`

### Pre-Conditions

- Issue #4 must be done first (introduces `BYOKProvider.apiKeyURL`).
- The BYOK section VStack is inside `if selectedOption == .byok { ... }` (lines 758–792).
- The TextField container VStack ends at line 789 (closing of `VStack(alignment: .leading, spacing: 6)`).
- After the BYOK VStack, there is `.padding(.bottom, 14)` at line 791.

### Problem Statement

The BYOK section shows provider selection and a TextField but gives no hint about where to get API keys. The Settings screen (`AIPolishSettingsView`) has this — onboarding should too.

### Step-by-Step Changes

#### Step 5.1 — Add help link row below the TextField

Insert after the TextField container VStack (after the closing `}` of `VStack(alignment: .leading, spacing: 6)` at line 788, before the `.frame(maxWidth: 360)` at line 789):

```swift
// Add inside the outer VStack(spacing: 8) in the BYOK section,
// after the TextField VStack and its .frame modifier:

HStack(spacing: 4) {
    Text("Don't have a key?")
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(Color.obTextTertiary)

    Button("Get one here →") {
        NSWorkspace.shared.open(selectedProvider.apiKeyURL)
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(Color.obAccent)
    .buttonStyle(.plain)
}
.frame(maxWidth: 360, alignment: .leading)
```

Place this after:
```swift
    }          // closes VStack(alignment: .leading, spacing: 6)
    .frame(maxWidth: 360)   // existing line 789
    // ← INSERT HERE
```

So the structure becomes:
```swift
VStack(spacing: 8) {  // BYOK section outer VStack
    HStack(spacing: 8) { ... }   // provider selection row
    .frame(maxWidth: 360)

    VStack(alignment: .leading, spacing: 6) {  // TextField container
        TextField("", text: $apiKey, prompt: ...)
            ...
    }
    .frame(maxWidth: 360)

    // NEW: help link
    HStack(spacing: 4) {
        Text("Don't have a key?")
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(Color.obTextTertiary)
        Button("Get one here →") {
            NSWorkspace.shared.open(selectedProvider.apiKeyURL)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.obAccent)
        .buttonStyle(.plain)
    }
    .frame(maxWidth: 360, alignment: .leading)
}
.padding(.bottom, 14)
```

### New Types/Properties

None (uses `BYOKProvider.apiKeyURL` from Issue #4).

### Edge Cases to Handle

- The URL is computed from `selectedProvider`, so switching provider also switches the destination URL without any extra code.
- `NSWorkspace.shared.open()` is safe to call from a SwiftUI Button action (executes on MainActor, opens default browser).

### Verification

1. `swift build` — no errors.
2. Launch → Step 3 → select BYOK → "Don't have a key? Get one here →" row is visible below the TextField.
3. Click "Get one here →" with OpenAI selected → opens `https://platform.openai.com/api-keys` in browser.
4. Switch to Gemini, click again → opens `https://aistudio.google.com/app/apikey`.

---

## Issues #6+7 — BYOK Key Never Saved; No Inline Validation

### Files to Modify

- `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Views/Onboarding/OnboardingView.swift`

### Pre-Conditions

- Issue #4 must be done first (`BYOKProvider` at module scope with `.llmProvider` and `.keychainID` properties).
- `LLMModelDiscovery.discoverModels(provider:apiKey:)` is available at module scope (confirmed: `LLMModelDiscovery.swift` line 26).
- `KeychainManager.store(key:value:)` is the save API (confirmed: `KeychainManager.swift` lines 52–67).
- `appState.keychainManager` is the shared `KeychainManager` instance (confirmed: `AppState.swift`).
- `appState.validateKeyAndDiscoverModels(provider:)` reads from KeychainManager — it cannot be used for in-memory validation. We will use `LLMModelDiscovery().discoverModels(provider:apiKey:)` directly instead (Option B from research).
- `LLMError.invalidAPIKey` is `Equatable` (confirmed: `LLMProtocol.swift` line 113–127).
- `appState.settings.llmProvider` is the property to set on success.
- The validation approach: **validate-first, save-only-on-success** (Gemini security recommendation).
- After saving, call `appState.validateKeyAndDiscoverModels(provider:)` to populate `discoveredModels` and `keyValidationState` in AppState for the Settings screen.

### Problem Statement

`applyPolishChoice()` does `break` for `.byok` — the API key typed by the user is silently discarded. The provider is never set in `appState.settings.llmProvider`. The user completes onboarding believing BYOK is configured, but it is not.

### Step-by-Step Changes

#### Step 6.1 — Add `BYOKValidationState` enum to `OnboardingViewModel`

Insert inside `OnboardingViewModel` class body, after the `TutorialState` enum (approximately after line 144):

```swift
// Step 3 — BYOK validation state
var byokValidationState: BYOKValidationState = .idle

enum BYOKValidationState: Equatable {
    case idle
    case validating
    case valid
    case invalid(String)

    // Equatable: auto-synthesized for .idle, .validating, .valid
    // .invalid(String) needs manual impl since associated value is String (which is Equatable)
    // Swift will auto-synthesize Equatable for all cases since all associated values are Equatable.
}
```

Note: `BYOKValidationState` is structurally identical to `AppState.KeyValidationState`. Keep it separate in `OnboardingViewModel` — it tracks onboarding-local UI state and must not bleed into `AppState.keyValidationState` (which drives the Settings screen).

#### Step 6.2 — Add `validateAndSaveKey(provider:apiKey:appState:)` to `OnboardingViewModel`

Insert after `openSystemSettingsForMic()` (line 195), still inside `OnboardingViewModel`:

```swift
/// Validate an API key by calling the provider's model listing endpoint directly,
/// then save to KeychainManager only if valid.
/// Uses Option B: LLMModelDiscovery.discoverModels() with raw key, bypassing KeychainManager.
/// This prevents writing invalid credentials to disk.
func validateAndSaveKey(
    provider: BYOKProvider,
    apiKey: String,
    appState: AppState
) async {
    guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
        byokValidationState = .invalid("API key cannot be empty.")
        return
    }

    byokValidationState = .validating

    do {
        // Step 1: Validate first — call provider API with raw key string
        // discoverModels throws LLMError.invalidAPIKey on 401/403
        let discovery = LLMModelDiscovery()
        _ = try await discovery.discoverModels(
            provider: provider.llmProvider,
            apiKey: apiKey.trimmingCharacters(in: .whitespaces)
        )

        // Step 2: Valid — persist to KeychainManager
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        try appState.keychainManager.store(key: provider.keychainID, value: trimmedKey)

        // Step 3: Set provider in Settings
        appState.settings.llmProvider = provider.llmProvider

        // Step 4: Trigger full model discovery so AppState.discoveredModels is populated
        // (non-blocking — Settings screen will show models when user gets there)
        Task { await appState.validateKeyAndDiscoverModels(provider: provider.llmProvider) }

        byokValidationState = .valid

    } catch let error as LLMError where error == .invalidAPIKey {
        byokValidationState = .invalid("Invalid API key. Please check it's correct and active.")
    } catch let error as LLMError where error == .requestFailed("") {
        // Network or HTTP error — use a friendly message
        byokValidationState = .invalid("Could not reach \(provider == .openai ? "OpenAI" : "Gemini"). Check your connection.")
    } catch {
        // Any other error (including requestFailed with message)
        byokValidationState = .invalid("Validation failed: \(error.localizedDescription)")
    }
}
```

**Important note on `discoverModels` for validation:** `discoverModels` does model listing + probing (multiple HTTP calls). For onboarding validation, this is acceptable since:
1. It correctly throws `LLMError.invalidAPIKey` on a bad key.
2. The result is discarded (`_ = try await ...`).
3. If it succeeds, the model list is populated by the subsequent `validateKeyAndDiscoverModels` call.

The total time is ~2–5 seconds for OpenAI (model probing). For a faster validation, only the `fetchOpenAIModels`/`fetchGeminiModels` calls are needed — but those are private. Since `discoverModels` is the only public API and it correctly handles auth errors, use it.

#### Step 6.3 — Replace `applyPolishChoice()` in `AIPolishStepView` (lines 822–829)

```swift
// BEFORE:
private func applyPolishChoice() {
    switch selectedOption {
    case .onDevice:
        appState.settings.llmProvider = .none
    case .byok:
        break // user configures in Settings
    }
}

// AFTER:
private func applyPolishChoice() {
    // For .onDevice: set provider to .none
    // For .byok: provider was already set by validateAndSaveKey on validation success.
    //            If we reach here with .byok but validation state != .valid,
    //            the user skipped (empty key → Skip button, or validated then continued).
    switch selectedOption {
    case .onDevice:
        appState.settings.llmProvider = .none
    case .byok:
        break // No-op: provider and key handled by validateAndSaveKey
    }
}
```

#### Step 6.4 — Replace the button row (lines 802–818) with validation-aware buttons

Replace the existing `VStack(spacing: 8) { ... }` button section:

```swift
// BEFORE (lines 803–817):
VStack(spacing: 8) {
    Button("Continue") {
        applyPolishChoice()
        viewModel.advanceToNextStep()
    }
    .buttonStyle(OnboardingPrimaryButtonStyle())
    .keyboardShortcut(.defaultAction)

    Button("Skip for now →") {
        viewModel.advanceToNextStep()
    }
    .font(.system(size: 12, weight: .medium))
    .foregroundStyle(Color.obTextTertiary)
    .buttonStyle(.plain)
}
.padding(.top, 10)

// AFTER:
VStack(spacing: 8) {
    // Show "Verify Key" button when BYOK is selected and there's text in the field
    // and it hasn't been validated yet
    if selectedOption == .byok && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        && viewModel.byokValidationState != .valid {
        Button {
            Task {
                await viewModel.validateAndSaveKey(
                    provider: selectedProvider,
                    apiKey: apiKey,
                    appState: appState
                )
            }
        } label: {
            HStack(spacing: 6) {
                if viewModel.byokValidationState == .validating {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Text(validateBtnLabel)
            }
        }
        .buttonStyle(OnboardingAccentButtonStyle())
        .disabled(viewModel.byokValidationState == .validating)
    }

    // Validation feedback row
    byokFeedbackView

    // Continue button
    // Enabled when: onDevice (always), or byok + valid key
    // Disabled when: byok + key entered but NOT validated
    Button("Continue") {
        applyPolishChoice()
        viewModel.advanceToNextStep()
    }
    .buttonStyle(OnboardingPrimaryButtonStyle())
    .keyboardShortcut(.defaultAction)
    .disabled(
        selectedOption == .byok
        && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        && viewModel.byokValidationState != .valid
    )

    Button("Skip for now →") {
        viewModel.advanceToNextStep()
    }
    .font(.system(size: 12, weight: .medium))
    .foregroundStyle(Color.obTextTertiary)
    .buttonStyle(.plain)
}
.padding(.top, 10)
```

**Continue disable logic explanation:**
- `selectedOption == .byok` AND key is not empty AND not validated → block Continue.
- `selectedOption == .byok` AND key IS empty → allow Continue (user didn't enter anything → implicit skip).
- `selectedOption == .byok` AND `byokValidationState == .valid` → allow Continue.
- `selectedOption == .onDevice` → always allow Continue.

#### Step 6.5 — Add `byokFeedbackView` and `validateBtnLabel` computed properties to `AIPolishStepView`

Add below `applyPolishChoice()`:

```swift
@ViewBuilder
private var byokFeedbackView: some View {
    switch viewModel.byokValidationState {
    case .idle:
        EmptyView()
    case .validating:
        Text("Validating key...")
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(Color.obTextTertiary)
    case .valid:
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
            Text("Key saved and validated")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.obSuccessText)
    case .invalid(let message):
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle.fill")
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.obError)
        .frame(maxWidth: 360, alignment: .leading)
    }
}

private var validateBtnLabel: String {
    switch viewModel.byokValidationState {
    case .validating: return "Validating..."
    case .valid:      return "Key Saved ✓"
    default:          return "Verify Key"
    }
}
```

#### Step 6.6 — Consolidate `onChange` handlers in the BYOK section

The Issue #4 Step 4.3 introduced `.onChange(of: selectedProvider)` for `apiKey = ""`. Now expand it to also reset `byokValidationState`:

Replace the one from Step 4.3:

```swift
// BEFORE (from Issue #4):
.onChange(of: selectedProvider) { _, _ in
    apiKey = ""
}

// AFTER (consolidated):
.onChange(of: selectedProvider) { _, _ in
    apiKey = ""
    viewModel.byokValidationState = .idle
}
```

Also add an `onChange` to reset `byokValidationState` when the key field is cleared:

```swift
.onChange(of: apiKey) { _, newValue in
    // If user deletes the key after a failed validation, reset to idle state
    if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
        viewModel.byokValidationState = .idle
    }
}
```

And when switching from BYOK back to onDevice:

```swift
.onChange(of: selectedOption) { _, newOption in
    if newOption == .onDevice {
        viewModel.byokValidationState = .idle
    }
}
```

**Placement:** All three `.onChange` modifiers go on the body of `AIPolishStepView` or on the outermost VStack. They do NOT need to be nested inside `if selectedOption == .byok`.

#### Step 6.7 — Verify `OnboardingAccentButtonStyle` exists

Check the file for `OnboardingAccentButtonStyle`. If it does not exist, add it alongside the other button styles (before `OnboardingViewModel`, around lines 60–110):

```swift
struct OnboardingAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 11)
            .background(Color.obAccent, in: RoundedRectangle(cornerRadius: 12))
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
    }
}
```

**Note:** The existing styles are `OnboardingPrimaryButtonStyle` (dark background), `OnboardingErrorButtonStyle` (red background). The "Verify Key" button uses `OnboardingAccentButtonStyle` (purple/accent background) to visually distinguish it from the final Continue button.

### New Types/Properties

In `OnboardingViewModel`:
- `enum BYOKValidationState: Equatable` with 4 cases
- `var byokValidationState: BYOKValidationState = .idle`
- `func validateAndSaveKey(provider:apiKey:appState:) async`

In `AIPolishStepView`:
- `@ViewBuilder private var byokFeedbackView: some View`
- `private var validateBtnLabel: String`

New top-level:
- `struct OnboardingAccentButtonStyle: ButtonStyle` (if not already present)
- `enum BYOKProvider` moved to module scope with `keyPlaceholder`, `apiKeyURL`, `llmProvider`, `keychainID` properties

### Edge Cases to Handle

1. **User clears field after invalid result** → `onChange(of: apiKey)` resets to `.idle` (Step 6.6).
2. **Provider switch mid-validation (REQUIRED — Gemini-vetted)** → `onChange(of: selectedProvider)` must cancel the in-flight Task. Without cancellation, a fast provider switch could leave `byokValidationState = .valid` set for the new (unvalidated) provider. Implement as:
   - Add `@State private var validationTask: Task<Void, Never>? = nil` to `AIPolishStepView`.
   - In the Verify button action, replace `Task { await viewModel.validateAndSaveKey(...) }` with `validationTask = Task { await viewModel.validateAndSaveKey(...) }`.
   - In `onChange(of: selectedProvider)`: call `validationTask?.cancel(); validationTask = nil` before resetting `byokValidationState`.
   ```swift
   .onChange(of: selectedProvider) { _, _ in
       apiKey = ""
       validationTask?.cancel()
       validationTask = nil
       viewModel.byokValidationState = .idle
   }
   ```

3. **Network unavailable** → `discoverModels` will throw `LLMError.requestFailed(...)` → shows "Validation failed: ..." message. User can still "Skip for now →".

4. **Very slow network** → `discoverModels` probes all models (5–10s for large model lists). The `ProgressView` spinner in "Validating..." state handles UX. The button is disabled during validation.

5. **User has a valid key but slow probing causes a timeout on a single model probe** → `probeModel` returns `false` for that model (not an error). The overall `discoverModels` call still succeeds. Key is saved. User gets valid state.

6. **User opens Settings after onboarding** → `appState.validateKeyAndDiscoverModels` was called in the background (Step 6.2, Step 4 of validateAndSaveKey). `discoveredModels` is populated. Settings screen shows models correctly.

7. **User validates BYOK key then switches back to On-Device before clicking Continue** → `appState.settings.llmProvider` was already set to the BYOK provider in `validateAndSaveKey`. When user then clicks Continue with `selectedOption == .onDevice`, `applyPolishChoice()` correctly sets it back to `.none`. The saved key remains in the Keychain (harmless — it's `~/.enviouswispr-keys/` with 0600 perms). This is the correct behavior: key is available if user re-enables BYOK in Settings later. No cleanup needed during onboarding.

### Verification

1. `swift build` — no errors.
2. Launch → Step 3 → select BYOK → enter invalid key → click "Verify Key" → spinner → "Invalid API key" message → Continue blocked.
3. Clear the key → validation state resets to idle.
4. Enter valid OpenAI key → "Verify Key" → validates → "Key saved and validated ✓" → Continue enabled → click Continue → Step 4.
5. After onboarding completes, open Settings → AI Polish tab → key should be pre-populated and valid.
6. Launch → Step 3 → select BYOK → enter nothing → click "Skip for now →" → advances to Step 4.
7. Launch → Step 3 → select "On-Device" → click Continue → advances immediately.

---

## Consolidated Change Summary

### Lines Modified in `OnboardingView.swift`

| Change | Approx. Lines Modified | Approx. Lines Added |
|--------|----------------------|---------------------|
| #1: MicPermissionStatus enum + ViewModel | 30 replaced | 25 added |
| #1: WelcomeStepView UI | 30 replaced | 15 added |
| #1: Notification observer | 0 replaced | 12 added |
| #4: BYOKProvider moved to module scope | 2 replaced | 30 added |
| #4: TextField prompt: init | 8 replaced | 10 added |
| #4: onChange provider | 0 added | 4 added |
| #5: Help link row | 0 replaced | 12 added |
| #6+7: BYOKValidationState enum | 0 replaced | 8 added |
| #6+7: validateAndSaveKey function | 0 replaced | 35 added |
| #6+7: Button row replacement | 15 replaced | 40 added |
| #6+7: byokFeedbackView + label | 0 replaced | 25 added |
| #6+7: onChange handlers | 3 replaced | 18 added |
| OnboardingAccentButtonStyle | 0 replaced | 10 added |
| **Total** | ~88 lines modified | ~244 lines added |

### New Files Needed

None. All changes are in `OnboardingView.swift`.

---

## Risks and Mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `discoverModels` probe loop is slow (5–10s) during onboarding | High | Show spinner, keep "Skip for now →" always enabled |
| Task cancellation race on provider switch | Medium | REQUIRED: `validationTask?.cancel()` in onChange handler — see Step 6.6 edge case #2 |
| `@unknown default` in AVCaptureDevice switch — future macOS adds new auth status | Very Low | `@unknown default: break` — safe fallthrough |
| `BYOKProvider` module-level enum name conflicts with another type | Very Low | Check with `swift build`; rename if needed |
| `OnboardingAccentButtonStyle` already exists with different implementation | Low | Search file before adding; skip if found |

---

## Gemini Review Summary (2026-03-02)

The plan was sent to Gemini (session: `phase1-impl-plan`) and rated **A+**. Gemini's findings:

**No bugs found.** All proposed code logic is correct.

**No Swift 6 concurrency violations.** `OnboardingViewModel` being `@MainActor` makes all state mutations safe. The background `Task { await appState.validateKeyAndDiscoverModels(...) }` is correctly isolated.

**Two amendments incorporated:**

1. **Task cancellation made REQUIRED** (was optional): Step 6.6 edge case #2 now explicitly requires `@State private var validationTask` and `validationTask?.cancel()` on provider switch. Rationale: a fast switch during in-flight validation could leave `byokValidationState = .valid` for the new (unvalidated) provider — a correctness bug, not just a UX concern.

2. **Keychain cleanup on On-Device switch is a product decision, not a bug:** If user validates a BYOK key then switches back to On-Device and clicks Continue, the key file stays on disk (0600 perms, harmless). `appState.settings.llmProvider` is correctly reset to `.none` by `applyPolishChoice()`. This is intentional — key is reusable if user re-enables BYOK in Settings later. Added as edge case #7 in Issue #6+7.

**Additional minor suggestions from Gemini (not blocking):**
- Add user-facing label "(This can take a few seconds)" near the validation spinner. Optional UX polish.
- Hardcoded URLs in `BYOKProvider` are low risk — both are stable official platform pages.

**Plan is cleared for execution.**
