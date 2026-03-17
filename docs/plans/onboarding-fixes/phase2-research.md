# Phase 2 Onboarding Fix Research
## EnviousWispr — Inline Hotkey Recorder + Reactivity + Settings Redirect Audit

---

## 1. Current Hotkey Recording Mechanism

### The existing `HotkeyRecorderView` component
**File:** `Sources/EnviousWispr/Views/Components/HotkeyRecorderView.swift` (209 lines)

This is a fully-implemented, reusable SwiftUI widget for recording keyboard shortcuts. It already exists and is used in `ShortcutsSettingsView`.

**Architecture:**
- `KeyCaptureNSView` — NSView subclass that captures ALL key events before the system:
  - `performKeyEquivalent(with:)` — intercepts system key equivalents (Cmd+Arrow, etc.) — returns `true` to consume
  - `keyDown(with:)` — regular key presses
  - `flagsChanged(with:)` — modifier-only key presses (only on press direction, not release)
- `KeyCaptureView` — SwiftUI `NSViewRepresentable` wrapper around `KeyCaptureNSView`
  - When `isRecording = true`, calls `nsView.window?.makeFirstResponder(nsView)` via deferred Task
- `HotkeyRecorderView` — main public struct with:
  - `@Binding var keyCode: UInt16`
  - `@Binding var modifiers: NSEvent.ModifierFlags`
  - `let defaultKeyCode: UInt16`, `let defaultModifiers: NSEvent.ModifierFlags`, `let label: String`
  - `@Environment(AppState.self) private var appState` — needs AppState in environment
  - Click-to-start-recording; Escape cancels; any key combo or bare modifier saves and auto-stops
  - Calls `appState.hotkeyService.suspend()` on start, `.resume()` on stop
  - Reset button appears when current value differs from default

**How Settings uses it (`ShortcutsSettingsView`):**
```swift
@Bindable var state = appState
HotkeyRecorderView(
    keyCode: $state.settings.toggleKeyCode,
    modifiers: $state.settings.toggleModifiers,
    defaultKeyCode: 49,   // Space
    defaultModifiers: .control,
    label: "Shortcut"
)
```
Direct `@Bindable` bindings to `appState.settings.toggleKeyCode` and `.toggleModifiers`.

### How the recorded value propagates
When `keyCode` or `modifiers` bindings are written:
1. `SettingsManager.toggleKeyCode.didSet` fires → UserDefaults persisted → calls `onChange?(.toggleKeyCode)`
2. `AppState.handleSettingChanged(.toggleKeyCode)` fires → updates `hotkeyService.toggleKeyCode`, `hotkeyService.pushToTalkKeyCode`, then calls `reregisterHotkeys()`
3. Carbon hotkey is re-registered immediately with the new binding

---

## 2. `hotkeyDisplayString` — Reactivity Analysis

### Where it's computed (three locations)

**Location 1: `ModelDownloadStepView` (Step 2) — lines 581–588**
```swift
private var hotkeyDisplayString: String {
    let s = appState.settings
    if s.recordingMode == .pushToTalk {
        return KeySymbols.format(keyCode: s.pushToTalkKeyCode, modifiers: s.pushToTalkModifiers)
    } else {
        return KeySymbols.format(keyCode: s.toggleKeyCode, modifiers: s.toggleModifiers)
    }
}
```

**Location 2: `TryItNowStepView` (Step 4) — lines 949–956**
```swift
private var hotkeyDisplayString: String {
    let s = appState.settings
    if s.recordingMode == .pushToTalk {
        return KeySymbols.format(keyCode: s.pushToTalkKeyCode, modifiers: s.pushToTalkModifiers)
    } else {
        return KeySymbols.format(keyCode: s.toggleKeyCode, modifiers: s.toggleModifiers)
    }
}
```

**Location 3: A third Step view** (line 1155 — in the final step)
Same pattern.

### Reactivity verdict: WORKS CORRECTLY for `@Observable`

`AppState` is `@Observable` (Swift Observation framework). `SettingsManager` is also `@Observable`.

`appState.settings` is a stored property of `AppState`. When `hotkeyDisplayString` accesses `appState.settings.toggleKeyCode`, the Swift Observation tracking automatically registers:
- `appState` as an observed object
- `appState.settings` as a nested observed object
- `appState.settings.toggleKeyCode` as an observed property

Any write to `toggleKeyCode` (e.g., via the inline recorder binding) will invalidate the computed property and trigger a SwiftUI re-render.

**BUT**: There is a subtle issue. `SettingsManager.toggleKeyCode` has a `didSet` that persists to UserDefaults and calls `onChange?`. The `onChange` callback propagates to `hotkeyService`. The `SettingsManager` is itself `@Observable` so the `@Observable` tracking on `settings.toggleKeyCode` will fire correctly.

**However**, `hotkeyConfigRow` in Step 2 reads `appState.settings.pushToTalkModifiers` directly (line 653):
```swift
Text(KeySymbols.symbolsForModifiers(appState.settings.pushToTalkModifiers))
```
This should also update reactively since `appState.settings` is observable. BUT: the modifiers displayed here are `pushToTalkModifiers` while the binding written by the recorder will be to `toggleModifiers`. Since the app mirrors PTT = toggle (lines 160, 264, 272 in AppState), the settings values `pushToTalkModifiers` and `toggleModifiers` are NOT automatically synced at the settings level — only at the hotkeyService level. The `hotkeyConfigRow` icon shows `pushToTalkModifiers` which may not update when `toggleModifiers` is changed via recorder.

### The "wrong binding" display problem

`hotkeyDisplayString` correctly branches on `recordingMode`. If `recordingMode == .pushToTalk`, it reads `s.pushToTalkKeyCode` / `s.pushToTalkModifiers`. But looking at AppState (lines 258–273), when `.toggleKeyCode` changes, `hotkeyService.pushToTalkKeyCode` is updated, but `settings.pushToTalkKeyCode` is NOT written. The settings mirror is intentional but the display in `hotkeyConfigRow` (line 653) uses `settings.pushToTalkModifiers` directly, which was never updated.

**Root cause of display bug:** `hotkeyDisplayString` in Step 2 (and Step 4) reads from `settings.pushToTalkKeyCode/Modifiers` when in PTT mode. But the user can only change `settings.toggleKeyCode/Modifiers`. Since `settings.pushToTalkKeyCode` and `settings.pushToTalkModifiers` are separate stored UserDefaults values that are NOT synced from toggle settings at the `SettingsManager` level (only at `hotkeyService` level), the display can lag.

**Fix**: `hotkeyDisplayString` should ALWAYS read from `settings.toggleKeyCode` / `settings.toggleModifiers` since those are the single source of truth. The `pushToTalk` variants in settings are redundant legacy fields.

---

## 3. Settings Window Redirects During Onboarding — Full Audit

### Redirect #1: `Customize...` button in Step 2 (line 676–678)
**Location:** `ModelDownloadStepView.hotkeyConfigRow` (line 676)
```swift
Button("Customize...") {
    appState.pendingNavigationSection = .shortcuts
}
```
**Effect:** Sets `pendingNavigationSection = .shortcuts` which triggers `UnifiedWindowView.onChange(of: appState.pendingNavigationSection)` → opens the main window and navigates to the Shortcuts tab. This is the primary issue to fix.

**Fix required:** Replace with inline `HotkeyRecorderView` embedded in the `hotkeyConfigRow`.

### Redirect #2: `Open Settings for more options` link in Step 5 / last step (line 1215–1226)
**Location:** Final onboarding completion view (line 1215)
```swift
Button {
    appState.pendingNavigationSection = .aiPolish
} label: {
    HStack(spacing: 6) {
        Image(systemName: "gearshape")
        Text("Open Settings for more options")
    }
}
```
**Effect:** Navigates to AI Polish settings during onboarding.

**Fix decision:** This is the final "Done" step, not mid-flow. The user is about to complete onboarding. A link to settings is arguably acceptable here — OR it should be removed entirely since clicking "Done" will take them to the full settings. Either way, it should at minimum not fire during the onboarding sheet — the sheet should be dismissed first.

### No other redirects found in OnboardingView.swift.

---

## 4. Proposed Inline Recorder Design

### Strategy: Embed existing `HotkeyRecorderView` directly

Since `HotkeyRecorderView` already exists and already handles:
- NSView key capture with `performKeyEquivalent` (intercepts system shortcuts)
- Escape to cancel
- Modifier-only hotkeys
- Carbon hotkey suspend/resume
- Reset to default button
- Visual feedback (recording state styling)

...the fix is to **replace the `Customize...` button with a styled `HotkeyRecorderView`** embedded inline in the onboarding card.

### Design for inline recorder in `hotkeyConfigRow`

The current `hotkeyConfigRow` layout:
```
[modifier icon] [hotkey display] [Spacer] [Customize... button]
```

Proposed replacement:
```
[inline HotkeyRecorderView styled for onboarding palette]
```

The `HotkeyRecorderView` needs bindings to `appState.settings.toggleKeyCode` and `appState.settings.toggleModifiers`. Since the view is inside `ModelDownloadStepView` which already has `@Environment(AppState.self) private var appState`, we can use `@Bindable`:

```swift
// In ModelDownloadStepView.hotkeyConfigRow:
@Bindable var bindableState = appState

HotkeyRecorderView(
    keyCode: $bindableState.settings.toggleKeyCode,
    modifiers: $bindableState.settings.toggleModifiers,
    defaultKeyCode: 49,   // Space
    defaultModifiers: .control,
    label: "Hotkey"
)
```

**Note:** `HotkeyRecorderView` uses `.secondary` color scheme from the settings context. For onboarding, we want the onboarding palette colors. Options:
1. Use it as-is (functional, but slightly mismatched style)
2. Pass a custom `accentColor` environment modifier to tint it to `Color.obAccent`
3. Wrap in a styled container card

The simplest approach that preserves behavior: use `.environment(\.accentColor, Color.obAccent)` on the `HotkeyRecorderView`. The existing recorder uses `Color.accentColor.opacity(0.2)` for its recording background — this will pick up the override.

### Required: `@Bindable` in `ModelDownloadStepView`

`ModelDownloadStepView` currently uses:
```swift
@Bindable var viewModel: OnboardingViewModel
@Environment(AppState.self) private var appState
```

Since `appState` comes from environment (not a `@Bindable` var), you need to declare `@Bindable` to get a binding:

```swift
// Add inside the body property:
@Bindable var bindableState = appState
// Then pass $bindableState.settings.toggleKeyCode
```

This pattern is already used in `ShortcutsSettingsView`:
```swift
var body: some View {
    @Bindable var state = appState
    // ...
    HotkeyRecorderView(keyCode: $state.settings.toggleKeyCode, ...)
}
```

The `@Bindable` var can only be declared in the `body` property scope (or a method), not as a stored property on a SwiftUI `View` struct.

---

## 5. Reactivity Fix for `hotkeyDisplayString`

### Issue A: Wrong property read in PTT mode

Both `hotkeyDisplayString` implementations read `s.pushToTalkKeyCode` in PTT mode:
```swift
if s.recordingMode == .pushToTalk {
    return KeySymbols.format(keyCode: s.pushToTalkKeyCode, modifiers: s.pushToTalkModifiers)
}
```

But the recorder binds to `settings.toggleKeyCode` / `settings.toggleModifiers`. Since `settings.pushToTalkKeyCode` is a *separate* stored property that's never written to when the recorder updates `toggleKeyCode`, the displayed string won't update when the user changes the binding.

**Fix:** Always read `toggleKeyCode` / `toggleModifiers`:
```swift
private var hotkeyDisplayString: String {
    KeySymbols.format(
        keyCode: appState.settings.toggleKeyCode,
        modifiers: appState.settings.toggleModifiers
    )
}
```

The `isPushToTalk` mode affects whether "Hold" is prepended to the label in `HotkeyService.hotkeyDescription`, but the key combo itself is always the toggle key combo (they are unified — PTT and toggle use the same physical key).

### Issue B: `hotkeyConfigRow` modifier icon shows wrong value

Line 653 in Step 2:
```swift
Text(KeySymbols.symbolsForModifiers(appState.settings.pushToTalkModifiers))
```
Should be:
```swift
Text(KeySymbols.symbolsForModifiers(appState.settings.toggleModifiers))
```

### Issue C: Three separate `hotkeyDisplayString` implementations

Having three near-identical computed properties in three different step views is fragile. All three should use the same simplified implementation reading only `toggleKeyCode`/`toggleModifiers`.

---

## 6. Edge Cases for Inline Recorder

### Hotkey conflicts
The existing recorder calls `appState.hotkeyService.suspend()` during recording, which unregisters all Carbon hotkeys. This prevents the current hotkey from firing while the user tries to remap it. No additional conflict detection is implemented — Carbon silently succeeds even if another app has registered the same combo. No system-level conflict check is needed for this fix.

### Modifier-only combos
`KeyCaptureNSView.flagsChanged(with:)` handles modifier-only combos correctly — it fires only on press (using `flagForModifierKeyCode` to check direction). These are stored with `modifiers = []` and `keyCode = <modifier keyCode>`. The `hotkeyDisplayString` via `KeySymbols.format` correctly handles this case (the `ModifierKeyCodes.isModifierOnly` branch). No extra logic needed.

### Escape to cancel
`handleKeyEvent` in `HotkeyRecorderView` checks `keyCode == 53` (Escape) with no modifiers → calls `stopRecording()` without updating keyCode/modifiers. The existing binding is unchanged. Works correctly.

### onDisappear cleanup
`HotkeyRecorderView.onDisappear` calls `stopRecording()` which calls `hotkeyService.resume()`. So if the onboarding step is navigated away from while recording, the hotkey service is correctly resumed. No additional cleanup needed.

### HotkeyService not yet started during onboarding
During onboarding, `hotkeyService.start()` is called from `applicationDidFinishLaunching` if `settings.hotkeyEnabled`. The `isEnabled` flag is `true` by default (forced in SettingsManager: "hotkeyEnabled forced true" per file-index). So the service IS running during onboarding. The `suspend()` / `resume()` calls on the recorder will work correctly.

---

## 7. Summary of All Changes Required

### Change 1: Replace `Customize...` button with inline recorder in `ModelDownloadStepView`
**File:** `Sources/EnviousWispr/Views/Onboarding/OnboardingView.swift`
**Lines:** `hotkeyConfigRow` property (~651–698)

Replace:
```swift
Button("Customize...") {
    appState.pendingNavigationSection = .shortcuts
}
// + styling
```

With:
```swift
// In body, declare: @Bindable var bindableState = appState
HotkeyRecorderView(
    keyCode: $bindableState.settings.toggleKeyCode,
    modifiers: $bindableState.settings.toggleModifiers,
    defaultKeyCode: 49,
    defaultModifiers: .control,
    label: "Hotkey"
)
.environment(\.accentColor, Color.obAccent)
```

Note: The `@Bindable var bindableState = appState` must be declared in `body` (or passed down). The `hotkeyConfigRow` is a computed `var` property not a function — it can't take in-scope `@Bindable` vars directly. Solution: change `hotkeyConfigRow` to a method that accepts a `Bindable<AppState>` parameter, or declare the `@Bindable` at the `body` level and pass it down.

**Recommended approach:** Inline the `hotkeyConfigRow` content into the `body`, or make it a private method accepting the bindable.

### Change 2: Fix `hotkeyDisplayString` to always read `toggleKeyCode`/`toggleModifiers`
**File:** `Sources/EnviousWispr/Views/Onboarding/OnboardingView.swift`
**Three locations:** lines 581–588, 949–956, and ~1155

Old:
```swift
private var hotkeyDisplayString: String {
    let s = appState.settings
    if s.recordingMode == .pushToTalk {
        return KeySymbols.format(keyCode: s.pushToTalkKeyCode, modifiers: s.pushToTalkModifiers)
    } else {
        return KeySymbols.format(keyCode: s.toggleKeyCode, modifiers: s.toggleModifiers)
    }
}
```

New:
```swift
private var hotkeyDisplayString: String {
    KeySymbols.format(
        keyCode: appState.settings.toggleKeyCode,
        modifiers: appState.settings.toggleModifiers
    )
}
```

### Change 3: Fix `hotkeyConfigRow` modifier icon to use `toggleModifiers`
**File:** `Sources/EnviousWispr/Views/Onboarding/OnboardingView.swift`
**Line 653:**

Old:
```swift
Text(KeySymbols.symbolsForModifiers(appState.settings.pushToTalkModifiers))
```

New:
```swift
Text(KeySymbols.symbolsForModifiers(appState.settings.toggleModifiers))
```

### Change 4: Decide on `Open Settings for more options` link in final step (line 1215)
**Options:**
- A: Remove the button entirely (user can access settings after closing onboarding)
- B: Keep but ensure the onboarding sheet is dismissed first before opening settings
- C: Replace with an inline toggle for common settings (autopaste, etc.)

Recommended: **Option A (remove)** — the final step has a "Done" button that closes onboarding and gives access to full settings. The link is redundant and violates the "no settings window during onboarding" principle.

---

## 8. Files to Modify

1. `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Views/Onboarding/OnboardingView.swift`
   - `ModelDownloadStepView.hotkeyConfigRow` — replace Customize button with HotkeyRecorderView
   - Three `hotkeyDisplayString` implementations — simplify to use toggleKeyCode only
   - `hotkeyConfigRow` modifier icon — change pushToTalkModifiers → toggleModifiers
   - Final step "Open Settings for more options" button — remove

No other files need modification — `HotkeyRecorderView` already exists and is reusable as-is.

---

## 9. Risks

1. **`@Bindable` in computed property scope**: Swift requires `@Bindable` to be declared where a local var is valid. Computed `var` properties in a View body are not valid locations. The `hotkeyConfigRow` property needs to be restructured to accept a `Bindable<AppState>` or the recorder needs to be inlined at the `body` level.

2. **HotkeyService.suspend() precondition**: `suspend()` checks `guard isEnabled, !isSuspended`. If called during onboarding before `hotkeyService.start()` has been called (edge case: very fast user on step 2 before app finishes launching), it would be a no-op, which is safe.

3. **Style mismatch**: `HotkeyRecorderView` uses system `.secondary` colors and standard `Color.accentColor`. The override via `.environment(\.accentColor, Color.obAccent)` will work for the accent highlight but not for `.secondary` text colors. The recorder may look slightly out-of-place. Acceptable for V1 — a future design pass can create an onboarding-specific skin.

4. **`hotkeyDisplayString` update during recording**: When the user is actively recording a new hotkey (isRecording=true in HotkeyRecorderView), the display shows "Press keys..." not the binding. Once they press a key, the binding updates, and `hotkeyDisplayString` in the callout card above will update immediately due to @Observable tracking. This is correct behavior.

---

## 10. Gemini Buddy Review — Key Feedback (2026-03-02)

### Confirmations
- Reactivity analysis: **Correct** — `@Observable` on both `AppState` and `SettingsManager` means `hotkeyDisplayString` reading `toggleKeyCode` will update automatically when the binding is written.
- `@Bindable` in `body` pattern: **Correct** — but subview extraction is cleaner.
- Inline recorder in onboarding: **Good UX** (Raycast/Alfred pattern), standard for utility apps.
- Removing "Open Settings for more options" from final step: **Recommended** — keeps user focused on completing onboarding.
- Sheet window for `makeFirstResponder`: **Should work** — sheet becomes key window; only risk is race condition with animation (test carefully).

### Critical Corrections

#### `.environment(\.accentColor, ...)` does NOT propagate through NSViewRepresentable bridge
The recorder's visual styling (`Color.accentColor.opacity(0.2)` for recording background) is in SwiftUI view code in `HotkeyRecorderView.body`, NOT in the `KeyCaptureNSView`. SwiftUI environment colors ARE accessible within SwiftUI view bodies. So `.environment(\.accentColor, Color.obAccent)` WILL affect the SwiftUI-rendered parts of `HotkeyRecorderView` (the `HStack`, `RoundedRectangle`, `Color.accentColor` references). The `KeyCaptureNSView` (NSView subclass) does NOT use `Color.accentColor` — it's a zero-size invisible capture layer, not styled. So the concern about NSViewRepresentable not inheriting environment colors is a non-issue for this specific component because all visual styling is in the SwiftUI body. **The `.environment(\.accentColor, Color.obAccent)` approach IS sufficient here.**

#### Subview extraction is better than `@Bindable` in `body`
Gemini confirms: creating a private `struct HotkeyConfigRow: View` with `@Bindable var appState: AppState` is the idiomatic SwiftUI pattern. It's cleaner than:
- Declaring `@Bindable var bindableState = appState` inside a computed property (not valid in Swift)
- Inlining everything in `body` (makes `body` large and messy)

**Revised implementation plan for Change 1:**
```swift
// Private subview — replaces the computed hotkeyConfigRow property
private struct HotkeyConfigRow: View {
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            // Modifier icon (using toggleModifiers — see Change 3)
            Text(KeySymbols.symbolsForModifiers(appState.settings.toggleModifiers))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.obAccent)
                // ... existing styling

            VStack(alignment: .leading, spacing: 0) {
                HotkeyRecorderView(
                    keyCode: $appState.settings.toggleKeyCode,
                    modifiers: $appState.settings.toggleModifiers,
                    defaultKeyCode: 49,
                    defaultModifiers: .control,
                    label: "Hotkey"
                )
                .environment(\.accentColor, Color.obAccent)

                Text("Click to change")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.obTextTertiary)
            }
            Spacer()
        }
        // ... existing padding/background/overlay/shadow styling
    }
}

// In ModelDownloadStepView.body — replace hotkeyConfigRow reference:
HotkeyConfigRow(appState: appState)
```

### Additional Edge Cases Raised by Gemini

#### Error handling for hotkey conflicts
`RegisterEventHotKey` returns non-`noErr` if the combo is already registered by another app (e.g., Cmd+Space for Spotlight). Currently the `HotkeyRecorderView` does not display any error feedback. The recorder will silently save the combo, but `hotkeyService.start()` will fail to register it. The service logs internally but no UI feedback is shown.

**Recommendation for this fix:** Accept this limitation for now (same behavior as the existing Settings recorder). Log the failure. A future improvement can add conflict detection UI.

#### Cancel/lose-focus path
If the user clicks away from the recorder without pressing a key combo:
- `KeyCaptureNSView` loses first responder
- But `isRecording` state in `HotkeyRecorderView` is NOT cleared automatically on first-responder loss
- `hotkeyService.resume()` would NOT be called

**Existing implementation check:** `HotkeyRecorderView` has `.onDisappear { stopRecording() }` — this covers the case where the step view disappears. But it does NOT handle losing first responder without view disappearance.

This is a pre-existing bug in `HotkeyRecorderView` (also present in Settings). Not a new regression from this fix. Worth noting but out of scope.

#### Onboarding dismissal during active recording
If the user dismisses the entire onboarding sheet while recording a hotkey:
- `HotkeyRecorderView.onDisappear` fires → `stopRecording()` → `hotkeyService.resume()`
- Clean state is restored

This works correctly via the existing `onDisappear` handler.

#### Accessibility / VoiceOver
`HotkeyRecorderView` has no explicit `accessibilityLabel`. The `KeyCaptureNSView` (NSView) would benefit from `setAccessibilityLabel("Hotkey recorder, double-tap to activate")`. This is a pre-existing gap, not introduced by this fix.

---

## 11. Final Implementation Plan

### Priority order:
1. **Change 1** (inline recorder): Extract `HotkeyConfigRow` as private struct, embed `HotkeyRecorderView` with `$appState.settings.toggleKeyCode`/`$appState.settings.toggleModifiers` bindings.
2. **Change 2** (fix hotkeyDisplayString): All three occurrences → read `toggleKeyCode`/`toggleModifiers` unconditionally.
3. **Change 3** (fix modifier icon): `hotkeyConfigRow` modifier symbol text → use `toggleModifiers`.
4. **Change 4** (remove settings redirect): Remove "Open Settings for more options" button from final step.

### Testing checklist:
- [ ] Step 2 shows inline recorder (no "Customize..." button)
- [ ] Click recorder → shows "Press keys..." / isRecording=true visual
- [ ] Press Cmd+D → combo captured, keycap card above updates immediately
- [ ] Escape during recording → cancels, no binding change
- [ ] Modifier-only (bare Option) → captured and displayed correctly
- [ ] Step 4 "Try It Out" keycap card shows new binding
- [ ] Navigate away from Step 2 while recording → hotkeyService.resume() called (onDisappear)
- [ ] Final step has no "Open Settings" button

---

*Document written: 2026-03-02*
*Gemini review incorporated: 2026-03-02*
*Research only — no source files modified*
