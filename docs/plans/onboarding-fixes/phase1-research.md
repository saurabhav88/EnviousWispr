# Phase 1 Onboarding Fixes — Research Report

Date: 2026-03-02
Researcher: Research Agent (coordinator dispatch)
Status: Pre-vet (awaiting Gemini feedback)

---

## Files Analyzed

- `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Views/Onboarding/OnboardingView.swift` (1,258 lines)
- `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Services/PermissionsService.swift` (79 lines)
- `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/LLM/KeychainManager.swift` (119 lines)
- `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/LLM/LLMProtocol.swift` (128 lines)
- `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Models/LLMResult.swift` (103 lines)
- `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/App/AppState.swift` (relevant sections)
- `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Views/Settings/AIPolishSettingsView.swift` (relevant sections)
- `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/LLM/OpenAIConnector.swift` (156 lines)
- `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/LLM/LLMModelDiscovery.swift` (relevant sections)

---

## Issue #1: Mic Permission Button Doesn't Trigger System Dialog

### Current Code Analysis

**Location:** `OnboardingView.swift`, lines 424–429 (WelcomeStepView), lines 151–160 (OnboardingViewModel)

**The button:**
```swift
// Line 425–427
Button("Grant Microphone Access") {
    Task { await viewModel.requestMicPermission() }
}
```

**The method it calls:**
```swift
// Lines 151–160 in OnboardingViewModel
func requestMicPermission() async {
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    micPermissionGranted = granted
    micPermissionDenied = !granted
    if granted {
        // Brief pause so user sees the checkmark before auto-advancing
        try? await Task.sleep(nanoseconds: 500_000_000)
        advanceToNextStep()
    }
}
```

**Auto-check on step appear:**
```swift
// Lines 238–245 in OnboardingView.task
case .welcome:
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .authorized {
        viewModel.micPermissionGranted = true
        try? await Task.sleep(nanoseconds: 300_000_000)
        viewModel.advanceToNextStep()
    }
```

### Root Cause Analysis

The code itself is **correct** — `AVCaptureDevice.requestAccess(for: .audio)` is the proper API to trigger the macOS system dialog. The issue is almost certainly a **TCC state problem**, not a code bug.

**The key insight:** `AVCaptureDevice.requestAccess(for:)` ONLY triggers the system dialog when status is `.notDetermined`. If the status is `.denied` or `.authorized`, it returns immediately without showing any dialog.

**The bug scenario:**
1. App previously asked for mic permission (or another app asked on behalf)
2. Status is now `.denied` (user said "Don't Allow" at some point)
3. Button is pressed → `requestAccess` is called → returns `false` immediately (no dialog)
4. `micPermissionDenied = true` → The denied UI shows (correct)
5. BUT the user might have expected a dialog to appear — the UI transition from "neutral button" to "denied state" could be confusing

**However, there's a more subtle bug:** The button is conditionally shown as:
```swift
} else if !viewModel.micPermissionGranted {
    Button("Grant Microphone Access") { ... }
}
```
This shows the button when `micPermissionGranted = false AND micPermissionDenied = false`. When status is `.denied` on app launch, `micPermissionDenied` starts as `false` (it's only set by calling the button). So the "Grant Microphone Access" button appears even in a denied state — and pressing it silently fails with no dialog.

**The fix needed:** Check TCC status on the `.welcome` step appearance. If already `.denied`, immediately show the denied UI. Currently the `.task` only checks `.authorized` — it doesn't handle `.denied`.

### Proposed Fix for Issue #1

**In `OnboardingView.swift`, modify the `.task` for `.welcome` step** (lines 238–245):

```swift
case .welcome:
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    switch status {
    case .authorized:
        viewModel.micPermissionGranted = true
        try? await Task.sleep(nanoseconds: 300_000_000)
        viewModel.advanceToNextStep()
    case .denied, .restricted:
        // Already denied — show the denied UI immediately, no dialog possible
        viewModel.micPermissionDenied = true
    case .notDetermined:
        break // Button will trigger requestAccess
    @unknown default:
        break
    }
```

**Also update `requestMicPermission()` in `OnboardingViewModel`** to check status before calling:
```swift
func requestMicPermission() async {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .denied || status == .restricted {
        // Can't request — direct to Settings
        micPermissionDenied = true
        return
    }
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    micPermissionGranted = granted
    micPermissionDenied = !granted
    if granted {
        try? await Task.sleep(nanoseconds: 500_000_000)
        advanceToNextStep()
    }
}
```

### Edge Cases and Risks

- **Edge case:** User revokes mic permission after granting, then re-opens onboarding. The `.task` fires on re-entry and will now correctly show denied state.
- **Edge case:** `.restricted` status (parental controls / MDM). Should also show denied UI since requestAccess won't work.
- **Risk:** None — this is purely defensive, the happy path (`.notDetermined`) is unchanged.
- **Dependency:** `AVCaptureDevice.authorizationStatus` is synchronous and safe on MainActor.

---

## Issue #4: API Key TextField Has No Placeholder Text

### Current Code Analysis

**Location:** `OnboardingView.swift`, lines 778–788 (AIPolishStepView)

```swift
// Line 778
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
```

### Root Cause Analysis

**The code already has `"sk-..."` as placeholder.** This placeholder string is passed to the first argument of `TextField("sk-...", text: $apiKey)`.

HOWEVER — in SwiftUI with `.textFieldStyle(.plain)`, placeholders are rendered differently depending on the macOS version and whether the field has focus. **The visual bug is likely that the placeholder is not visible** because:

1. `.textFieldStyle(.plain)` strips the default NSTextField styling and the placeholder text may not render properly without custom placeholder handling.
2. On macOS, `TextField("placeholder", text: $binding)` with `.textFieldStyle(.plain)` often shows the placeholder but it can be washed out or invisible against the background (`Color.obCardBg` = white).
3. The placeholder "sk-..." is OpenAI-specific. When `selectedProvider == .gemini`, the placeholder "sk-..." is misleading (Gemini keys look like "AIza...").

### Proposed Fix for Issue #4

**Change 1: Provider-aware placeholder**

The `TextField` is inside `AIPolishStepView` which has `@State private var selectedProvider: BYOKProvider`. Use a computed property:

```swift
// Add this computed property to AIPolishStepView
private var apiKeyPlaceholder: String {
    switch selectedProvider {
    case .openai: return "sk-..."
    case .gemini: return "AIza..."
    }
}
```

Then use it:
```swift
TextField(apiKeyPlaceholder, text: $apiKey)
```

**Change 2: Ensure placeholder is visible**

Add `.foregroundStyle(Color.obTextTertiary)` for better contrast, and consider adding an explicit placeholder overlay if `.textFieldStyle(.plain)` causes issues:

Actually, the simpler fix is to keep `TextField(apiKeyPlaceholder, text: $apiKey)` and add a `prompt` parameter for clearer macOS rendering:
```swift
TextField("", text: $apiKey, prompt: Text(apiKeyPlaceholder)
    .foregroundColor(Color.obTextTertiary)
    .font(.system(size: 12, weight: .regular, design: .monospaced))
)
```

**Change 3: Clear the apiKey field when switching providers**

Add `.onChange(of: selectedProvider)` to reset apiKey when switching:
```swift
.onChange(of: selectedProvider) { _, _ in apiKey = "" }
```

### Edge Cases and Risks

- **Risk:** Low. The `prompt:` version of TextField init is available since macOS 12. The project targets macOS 14+, so this is safe.
- **Edge case:** User switches provider with a key typed in — clearing on switch is user-friendly.

---

## Issue #5: Missing Instructions for Where to Find API Keys

### Current Code Analysis

**Location:** `OnboardingView.swift`, lines 757–792 (AIPolishStepView BYOK section)

The BYOK section shows provider selection (OpenAI / Gemini) and the TextField, but NO link or text indicating where to obtain keys.

The `Settings/AIPolishSettingsView.swift` has a "Get an API key →" button pattern (confirmed via grep of the full file showing similar functionality exists in Settings).

### Provider URLs

- **OpenAI:** `https://platform.openai.com/api-keys`
- **Gemini:** `https://aistudio.google.com/app/apikey`

### Proposed Fix for Issue #5

Add a helper row below the TextField in the BYOK section. This fits naturally after the TextField container closes (line 792):

```swift
// Add after the TextField VStack, before .padding(.bottom, 14)
HStack(spacing: 4) {
    Text("Don't have a key?")
        .font(.system(size: 11, weight: .regular))
        .foregroundStyle(Color.obTextTertiary)

    Button("Get one here →") {
        let urlString: String
        switch selectedProvider {
        case .openai: urlString = "https://platform.openai.com/api-keys"
        case .gemini: urlString = "https://aistudio.google.com/app/apikey"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(Color.obAccent)
    .buttonStyle(.plain)
}
.frame(maxWidth: 360, alignment: .leading)
```

### Edge Cases and Risks

- **Risk:** None. Opens Safari with a well-known URL.
- **Edge case:** URL might change over time — both are stable official platform pages.

---

## Issue #6+7: No API Key Validation, Need Submit Button with Keychain Save

### Current Code Analysis

**Problem 1: No validation in onboarding.**
Lines 803–818 of AIPolishStepView:
```swift
Button("Continue") {
    applyPolishChoice()
    viewModel.advanceToNextStep()
}

Button("Skip for now →") {
    viewModel.advanceToNextStep()
}
```

`applyPolishChoice()` (lines 822–829):
```swift
private func applyPolishChoice() {
    switch selectedOption {
    case .onDevice:
        appState.settings.llmProvider = .none
    case .byok:
        break // user configures in Settings  ← KEY OBSERVATION
    }
```

**Critical finding:** When BYOK is selected, `applyPolishChoice()` does `break` — it does NOTHING. The API key in `@State private var apiKey: String = ""` is never saved. The user can enter a key, click Continue, and it's discarded silently.

**Problem 2: The provider is also not set when BYOK.**
When `.byok` is selected, `appState.settings.llmProvider` is never updated. The settings remain at whatever the previous value was.

**Problem 3: The flow should have a "Save Key" action, not just "Continue".**
The Settings screen (AIPolishSettingsView) has explicit "Save Key" buttons that:
1. Call `try appState.keychainManager.store(key: keychainId, value: key)` to save to file
2. Call `appState.validateKeyAndDiscoverModels(provider:)` to validate asynchronously

### How KeychainManager Works

From `LLM/KeychainManager.swift`:
- File-based storage in `~/.enviouswispr-keys/`
- `store(key:value:)` — writes file with 0600 permissions
- `retrieve(key:)` — reads from file (throws `KeychainError.retrieveFailed` if not found)
- `delete(key:)` — removes file
- Key IDs: `KeychainManager.openAIKeyID = "openai-api-key"`, `KeychainManager.geminiKeyID = "gemini-api-key"`

### How Validation Works

From `AppState.validateKeyAndDiscoverModels(provider:)` (AppState.swift ~line 550):
1. Reads key from KeychainManager
2. Calls `LLMModelDiscovery().discoverModels(provider:apiKey:)` which hits the provider API
3. Sets `keyValidationState` to `.valid`, `.invalid(String)`, or `.validating`
4. Also auto-selects the first available model in `settings.llmModel`

This is the **right validation path** — it actually calls the provider's model listing endpoint (which requires a valid key) rather than a dedicated validate endpoint.

### Proposed Fix for Issues #6+7

**Design decision:** The onboarding should have a "Save & Validate" flow for BYOK, showing inline feedback, then enabling Continue only when valid (or allowing skip).

**Changes needed in `AIPolishStepView`:**

**1. Add validation state to OnboardingViewModel:**
```swift
// Add to OnboardingViewModel
var byokSaveState: BYOKSaveState = .idle

enum BYOKSaveState {
    case idle
    case saving
    case valid
    case invalid(String)
}

func saveAndValidateBYOKKey(
    provider: BYOKProvider,
    apiKey: String,
    appState: AppState
) async {
    byokSaveState = .saving

    let keychainId: String
    let llmProvider: LLMProvider
    switch provider {
    case .openai:
        keychainId = KeychainManager.openAIKeyID
        llmProvider = .openAI
    case .gemini:
        keychainId = KeychainManager.geminiKeyID
        llmProvider = .gemini
    }

    // Save to keychain
    do {
        try appState.keychainManager.store(key: keychainId, value: apiKey)
    } catch {
        byokSaveState = .invalid("Failed to save key: \(error.localizedDescription)")
        return
    }

    // Set provider in settings
    appState.settings.llmProvider = llmProvider

    // Validate via model discovery
    await appState.validateKeyAndDiscoverModels(provider: llmProvider)

    switch appState.keyValidationState {
    case .valid:
        byokSaveState = .valid
    case .invalid(let msg):
        byokSaveState = .invalid(msg)
    default:
        byokSaveState = .idle
    }
}
```

**2. Update `applyPolishChoice()` in AIPolishStepView:**
```swift
private func applyPolishChoice() {
    switch selectedOption {
    case .onDevice:
        appState.settings.llmProvider = .none
    case .byok:
        // Key already saved and provider set by saveAndValidateBYOKKey — no-op here
        break
    }
}
```

**3. Update the button row in AIPolishStepView:**

Replace lines 802–818 with:
```swift
VStack(spacing: 8) {
    // Show "Save Key" button only when BYOK is selected and key entered
    if selectedOption == .byok && !apiKey.isEmpty {
        Button {
            Task {
                await viewModel.saveAndValidateBYOKKey(
                    provider: selectedProvider,
                    apiKey: apiKey,
                    appState: appState
                )
            }
        } label: {
            HStack(spacing: 6) {
                if case .saving = viewModel.byokSaveState {
                    ProgressView().controlSize(.small).tint(.white)
                }
                Text(saveBtnLabel)
            }
        }
        .buttonStyle(OnboardingAccentButtonStyle())
        .disabled(viewModel.byokSaveState == .saving)
    }

    // Validation feedback
    byokFeedback

    // Continue button (enabled when onDevice, or BYOK valid, or BYOK with saved valid key)
    Button("Continue") {
        applyPolishChoice()
        viewModel.advanceToNextStep()
    }
    .buttonStyle(OnboardingPrimaryButtonStyle())
    .keyboardShortcut(.defaultAction)
    .disabled(selectedOption == .byok && viewModel.byokSaveState != .valid && apiKey.isEmpty == false)

    Button("Skip for now →") {
        viewModel.advanceToNextStep()
    }
    .font(.system(size: 12, weight: .medium))
    .foregroundStyle(Color.obTextTertiary)
    .buttonStyle(.plain)
}
```

**4. Add `byokFeedback` view helper:**
```swift
@ViewBuilder
private var byokFeedback: some View {
    switch viewModel.byokSaveState {
    case .idle:
        EmptyView()
    case .saving:
        Text("Validating key...")
            .font(.system(size: 12))
            .foregroundStyle(Color.obTextTertiary)
    case .valid:
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
            Text("Key saved and validated")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.obSuccessText)
    case .invalid(let msg):
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle.fill")
            Text(msg)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.obError)
    }
}

private var saveBtnLabel: String {
    switch viewModel.byokSaveState {
    case .saving: return "Validating..."
    case .valid: return "Key Saved ✓"
    default: return "Save & Validate Key"
    }
}
```

**5. Reset `byokSaveState` on provider switch:**
```swift
.onChange(of: selectedProvider) { _, _ in
    apiKey = ""
    viewModel.byokSaveState = .idle
}
.onChange(of: selectedOption) { _, newOption in
    if newOption == .onDevice {
        viewModel.byokSaveState = .idle
    }
}
```

**6. Handle the "Continue" button logic correctly:**

The proposed Continue button logic should allow proceeding when:
- `selectedOption == .onDevice` → always allow
- `selectedOption == .byok && byokSaveState == .valid` → key was saved and validated
- The "Skip for now →" always works regardless (BYOK without a key → user configures in Settings later)

This means the disabled condition for Continue should be:
```swift
.disabled(selectedOption == .byok && viewModel.byokSaveState != .valid && !apiKey.isEmpty)
```
Translation: If BYOK is selected AND they typed something but haven't validated → block Continue. If they typed nothing → allow Continue (they can skip). This prevents partial/unvalidated state while still allowing full skip.

### Edge Cases and Risks

- **Edge case:** User types key, validation fails (invalid key), then deletes key. `byokSaveState` stays `.invalid`. Should reset to `.idle` when key field becomes empty.
  - **Fix:** `.onChange(of: apiKey) { _, new in if new.isEmpty { viewModel.byokSaveState = .idle } }`

- **Edge case:** Network unavailable during validation. `LLMModelDiscovery` will throw a network error → `keyValidationState = .invalid("...")`. The `byokSaveState` would show `.invalid("network error")`. User can still "Skip for now →".

- **Risk:** The key IS saved to disk even if validation fails (we save first, then validate). This is intentional — if the user's internet is down, we don't want to lose their typed key. They can re-open Settings and it'll be there. This matches the behavior of the existing Settings "Save Key" button.

- **Risk:** `saveAndValidateBYOKKey` calls `appState.validateKeyAndDiscoverModels` which sets `appState.keyValidationState`. This is a shared AppState property that AIPolishSettingsView also reads. During onboarding, Settings isn't open, so this is safe. But we should read `appState.keyValidationState` back into `viewModel.byokSaveState` to keep the state local to onboarding UI.

- **Risk:** Swift 6 concurrency — `saveAndValidateBYOKKey` calls `@MainActor` methods on `AppState`. Since `OnboardingViewModel` is `@MainActor`, and `saveAndValidateBYOKKey` is called via `Task { await ... }` from a button action (on MainActor), this is safe.

- **Dependency note:** `OnboardingViewModel` needs access to `AppState` (which it currently gets via `@Environment(AppState.self)` in the View). The ViewModel function needs to accept `appState` as a parameter since ViewModel doesn't store environment. This matches the existing pattern where `startModelDownload(asrManager:settings:)` takes parameters rather than storing them.

---

## Dependencies Between Fixes

1. **Issue #1** is independent — only touches `.welcome` step logic in ViewModel and task modifier.
2. **Issue #4** is independent — only changes the TextField placeholder and adds provider-awareness.
3. **Issue #5** is independent — only adds a help link below the TextField.
4. **Issues #6+7** depend on the BYOK provider selection state (which Issue #4 touches). If #4 adds `apiKeyPlaceholder` computed property, #6+7 can reuse it. The `onChange(of: selectedProvider)` for key clearing (#4 suggestion) MUST be coordinated with the one for `byokSaveState` reset (#6+7).
   - **Combined handler:**
     ```swift
     .onChange(of: selectedProvider) { _, _ in
         apiKey = ""
         viewModel.byokSaveState = .idle
     }
     ```

---

## Summary Table

| Issue | Root Cause | Fix Complexity | Risk |
|-------|-----------|----------------|------|
| #1 Mic button no dialog | TCC `.denied` not checked on step entry; button still shows | Low — add `switch` in `.task` and guard in `requestMicPermission()` | None |
| #4 No placeholder | Placeholder IS "sk-..." but not provider-aware; possibly invisible with `.plain` style | Low — use `prompt:` init + computed property | None |
| #5 No API key instructions | Simply missing — never implemented | Low — add link row below TextField | None |
| #6+7 No validation/save | `applyPolishChoice()` does `break` for BYOK; key never saved | Medium — add BYOKSaveState to ViewModel, validation flow, conditional button states | Low (key saved first then validated, matches Settings pattern) |

---

## Gemini Buddy Feedback (session: phase1-review)

### Issue #1 Critique

**Confirmed:** Root cause analysis is correct.

**New findings from Gemini:**

1. **`.restricted` needs different UI.** `.denied` = user can fix in System Settings. `.restricted` = MDM/parental controls, user CANNOT change it. Must show different message and NOT offer "Open System Settings" button.
   - Use `MicPermissionState` enum: `.notDetermined`, `.granted`, `.denied(canBeFixed: Bool)`.
   - `.denied` → `denied(canBeFixed: true)`, `.restricted` → `.denied(canBeFixed: false)`.

2. **Missing edge case: In-app permission revocation.** The `.task` only fires once. If user revokes mic access from System Settings while the onboarding window is open, the UI won't update. Fix: observe `AVCaptureDevice.authorizationStatusDidChangeNotification` in the view or ViewModel.

3. **`Task.sleep` is a code smell.** Should use proper state (`enum PermissionState`) and let state drive the UI advancement, not hardcoded sleeps. However, given the existing `.sleep` pattern throughout the ViewModel (Steps 2 also uses it), this is a lower-priority refactor that can be deferred.

**Revised approach for Issue #1:**
- Move to `MicPermissionState` enum with `canBeFixed` flag
- Register `AVCaptureDevice.authorizationStatusDidChangeNotification` observer
- `denied(canBeFixed: false)` → "Permission Restricted by Organization" with no action button

### Issue #4 Critique

**Confirmed:** `TextField("", text:, prompt:)` is correct for macOS 14+. The `prompt:` parameter IS designed to solve `.textFieldStyle(.plain)` placeholder invisibility.

**Additional suggestion:** Move URL generation out of the view. Add a `var apiKeyURL: URL` property to the `BYOKProvider` enum (which should be moved to ViewModel).

### Issue #5 Critique

**Confirmed:** Approach is correct. Move URL generation to `BYOKProvider.apiKeyURL` property on the enum.

**Confirmed:** `NSWorkspace.shared.open()` from a Button action is safe — executes on MainActor.

### Issues #6+7 Critique

**Security flaw identified:** Save-then-validate is wrong. **Never persist an unvalidated credential.** Correct order: validate first, save only on success.

**Simpler UX design:** Replace the conditional Continue button logic with:
- A dedicated "Verify" button next to the TextField
- `ProgressView` when `byokSaveState == .saving`
- Continue only enabled when `selectedOption == .onDevice` OR `byokSaveState == .valid`
- "Skip for now →" remains as an escape hatch

**`BYOKSaveState` Equatable:** Can be auto-synthesized (String is Equatable). No manual impl needed.

**`BYOKProvider` enum location:** Must move to `OnboardingViewModel`, not nested in View.

**`validateKeyAndDiscoverModels` safety:** Gemini confirms safe to call during onboarding since onboarding is modal (no concurrent transcription possible).

**Revised `validateAndSaveKey` logic:**
```swift
func validateAndSaveKey(provider: BYOKProvider, apiKey: String, appState: AppState) async {
    guard !apiKey.isEmpty else {
        byokSaveState = .invalid("API key cannot be empty.")
        return
    }
    byokSaveState = .saving

    // 1. Validate FIRST (via LLMModelDiscovery / discoverModels which hits real API)
    // Use a lightweight validation: attempt to list models with the key
    let keychainId = provider == .openai ? KeychainManager.openAIKeyID : KeychainManager.geminiKeyID
    let llmProvider: LLMProvider = provider == .openai ? .openAI : .gemini

    // Temporarily store in memory (not keychain) to call validateKeyAndDiscoverModels
    // OR: call a direct model-listing function without saving to keychain first
    // NOTE: validateKeyAndDiscoverModels reads from KeychainManager — need to refactor
    // to accept key directly, OR save/validate/delete-on-failure pattern

    // 2. On success: save to keychain, set provider
    do {
        try appState.keychainManager.store(key: keychainId, value: apiKey)
        appState.settings.llmProvider = llmProvider
        byokSaveState = .valid
    } catch {
        byokSaveState = .invalid("Failed to save key.")
    }
}
```

**Implementation note on validation-first:** `AppState.validateKeyAndDiscoverModels()` reads the key from KeychainManager — it cannot accept a raw key. Two options:
- **Option A:** Save to keychain, validate, delete if invalid (save-validate-rollback pattern)
- **Option B:** Call `LLMModelDiscovery().discoverModels(provider:apiKey:)` directly with the raw key string, bypassing KeychainManager. This is the cleaner approach since `LLMModelDiscovery.discoverModels(provider:apiKey:)` accepts the key as a parameter directly (confirmed from AppState.swift line 569).

**Option B is recommended** — it avoids disk I/O for invalid keys and doesn't require rollback logic:
```swift
func validateAndSaveKey(provider: BYOKProvider, apiKey: String, appState: AppState) async {
    byokSaveState = .saving
    let keychainId = provider == .openai ? KeychainManager.openAIKeyID : KeychainManager.geminiKeyID
    let llmProvider: LLMProvider = provider == .openai ? .openAI : .gemini

    do {
        // Validate FIRST — directly calls provider API, no keychain needed
        let discovery = LLMModelDiscovery()
        _ = try await discovery.discoverModels(provider: llmProvider, apiKey: apiKey)

        // Valid — now save
        try appState.keychainManager.store(key: keychainId, value: apiKey)
        appState.settings.llmProvider = llmProvider

        // Trigger full discovery to populate model list
        Task { await appState.validateKeyAndDiscoverModels(provider: llmProvider) }

        byokSaveState = .valid
    } catch let error as LLMError where error == .invalidAPIKey {
        byokSaveState = .invalid("Invalid API key. Check it's correct and active.")
    } catch {
        byokSaveState = .invalid("Could not reach \(provider == .openai ? "OpenAI" : "Gemini"). Check your connection.")
    }
}
```

---

## Questions for Gemini Vet Review

1. For Issue #1: Should we also handle the `.restricted` case explicitly (MDM-controlled devices)? Should the denied UI show a different message for restricted vs denied?

2. For Issue #4: Is using `TextField("", text: $binding, prompt: Text(...))` correct for macOS SwiftUI with `.textFieldStyle(.plain)`? Or is there a better way to ensure placeholder visibility?

3. For Issue #6+7: The proposed design saves the key FIRST then validates. Is there any security concern with saving an invalid/untrusted key to disk at `~/.enviouswispr-keys/`? (The file has 0600 permissions.)

4. For Issue #6+7: The Continue button disabled logic is `selectedOption == .byok && byokSaveState != .valid && !apiKey.isEmpty`. Is this the right UX? Should we instead disable Continue entirely when BYOK is selected without a valid key, forcing users to either validate or explicitly skip?

5. Is there an alternative simpler flow where Step 3 BYOK just saves the key without live validation during onboarding, with validation deferred to first use? This would simplify the onboarding flow significantly at the cost of discovering bad keys later.

6. Any concern about `validateKeyAndDiscoverModels` being called from onboarding (which touches `appState.discoveredModels`, a shared property)? Should we use a dedicated minimal validation call instead?
