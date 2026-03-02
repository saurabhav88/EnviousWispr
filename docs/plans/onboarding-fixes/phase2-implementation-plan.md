# Phase 2 Onboarding Fix — Implementation Plan
## EnviousWispr — Inline Hotkey Recorder + Reactivity + Settings Redirect

**Prepared:** 2026-03-02
**Status:** PLANNING ONLY — no source files modified
**Target file:** `Sources/EnviousWispr/Views/Onboarding/OnboardingView.swift`

---

## Issues Being Fixed

| ID | Description |
|----|-------------|
| Issue #2 | `Customize...` button in Step 2 redirects to Settings window during onboarding — replace with inline `HotkeyRecorderView` |
| Issues #3 + #9 | `hotkeyDisplayString` reads `pushToTalkKeyCode/pushToTalkModifiers` in PTT mode, but recorder only writes to `toggleKeyCode/toggleModifiers` — display stays stale; modifier icon in `hotkeyConfigRow` uses same wrong property |
| Issue #8 | `Open Settings for more options` button in Step 5 fires `pendingNavigationSection = .aiPolish` during onboarding — remove it |

---

## Pre-Reading Requirements

Before starting, confirm these invariants hold in the current code:

1. `ModelDownloadStepView` (line 457) is declared `private struct` with:
   - `@Bindable var viewModel: OnboardingViewModel`
   - `@Environment(AppState.self) private var appState`
   - No `@Bindable` for `appState` — environment-injected `@Observable` objects require explicit `@Bindable` declaration to derive bindings.

2. The `hotkeyConfigRow` computed property (lines 651–698) is a `var` property returning `some View` — NOT a function. This matters: Swift does not allow `@Bindable var` declarations inside computed property bodies. A `@Bindable var` can only be declared in a `View.body` property or a `func` that returns `some View`.

3. `HotkeyRecorderView` (HotkeyRecorderView.swift line 88) requires:
   - `@Binding var keyCode: UInt16`
   - `@Binding var modifiers: NSEvent.ModifierFlags`
   - `@Environment(AppState.self)` injected — it internally calls `appState.hotkeyService.suspend()` / `.resume()`
   - `AppState` must already be in the SwiftUI environment at the call site (it is — `ModelDownloadStepView` is rendered inside the main onboarding sheet which injects `AppState` via `.environment(appState)`)

4. `KeySymbols.format(keyCode:modifiers:)` handles modifier-only hotkeys correctly (line 99–110 in KeySymbols.swift).

5. The three `hotkeyDisplayString` occurrences are in three separate `private struct` views:
   - `ModelDownloadStepView` — lines 581–588
   - `TryItNowStepView` — lines 949–956
   - `ReadyStepView` — lines 1155–1162
   Each struct declares its own private computed property. They are independent and must each be changed.

6. `AppState.handleSettingChanged(.toggleKeyCode)` (line 258–261) mirrors the new value to `hotkeyService.pushToTalkKeyCode` and calls `reregisterHotkeys()`. This means writing to `settings.toggleKeyCode` (via the recorder binding) correctly propagates to the Carbon hotkey layer. The `settings.pushToTalkKeyCode` stored property is NOT updated — which is the root cause of Issue #3/#9.

---

## Implementation Order

The four changes are independent at the file level but must be applied in this sequence to avoid confusion and to make each diff reviewable:

1. **Change A** — Fix `hotkeyDisplayString` in `ModelDownloadStepView` (lines 581–588)
2. **Change B** — Fix `hotkeyDisplayString` in `TryItNowStepView` (lines 949–956)
3. **Change C** — Fix `hotkeyDisplayString` in `ReadyStepView` (lines 1155–1162)
4. **Change D** — Fix modifier icon in `hotkeyConfigRow` (line 653)
5. **Change E** — Replace `Customize...` button with inline `HotkeyRecorderView` using extracted private struct (lines 651–698)
6. **Change F** — Remove `Open Settings for more options` button from Step 5 (lines 1215–1228)

Changes A–D are straightforward text substitutions. Change E is the most complex (new type + structural refactor). Change F is a deletion.

Do A–D first so that when Change E is applied, the modifier icon fix (Change D) is already incorporated into what will become the `HotkeyConfigRow` struct's body.

---

## Change A — Fix `hotkeyDisplayString` in `ModelDownloadStepView`

### File
`/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Views/Onboarding/OnboardingView.swift`

### Pre-conditions
- `ModelDownloadStepView` struct already exists with `@Environment(AppState.self) private var appState`
- `KeySymbols.format(keyCode:modifiers:)` is imported (same module)

### Exact change — lines 581–588

**Remove:**
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

**Replace with:**
```swift
private var hotkeyDisplayString: String {
    KeySymbols.format(
        keyCode: appState.settings.toggleKeyCode,
        modifiers: appState.settings.toggleModifiers
    )
}
```

### Rationale
`settings.pushToTalkKeyCode` is never written to when the recorder changes `toggleKeyCode` — only `hotkeyService.pushToTalkKeyCode` is updated at the service layer. The toggle key IS the PTT key (they share the same physical binding). Always reading from `toggleKeyCode`/`toggleModifiers` is correct and reactive.

### Side effects
Also remove (or simplify) `hotkeySymbol` computed property at lines 590–601, which has the same bug. This property is used in `hotkeyCalloutCard` display. Apply the same fix pattern:

**Lines 590–601, remove:**
```swift
private var hotkeySymbol: String {
    let s = appState.settings
    if s.recordingMode == .pushToTalk {
        return KeySymbols.symbolsForModifiers(s.pushToTalkModifiers)
            + (s.pushToTalkModifiers.isEmpty ? "" : " ")
            + KeySymbols.nameForKeyCode(s.pushToTalkKeyCode)
    } else {
        return KeySymbols.symbolsForModifiers(s.toggleModifiers)
            + (s.toggleModifiers.isEmpty ? "" : " ")
            + KeySymbols.nameForKeyCode(s.toggleKeyCode)
    }
}
```

**Replace with:**
```swift
private var hotkeySymbol: String {
    KeySymbols.symbolsForModifiers(appState.settings.toggleModifiers)
        + (appState.settings.toggleModifiers.isEmpty ? "" : " ")
        + KeySymbols.nameForKeyCode(appState.settings.toggleKeyCode)
}
```

Note: verify whether `hotkeySymbol` is actually used in `ModelDownloadStepView`. A grep shows it is NOT used in `hotkeyCalloutCard` (that view uses `hotkeyDisplayString` directly). If `hotkeySymbol` is unused, it should be deleted entirely instead of updated. Verify by searching for `hotkeySymbol` in `ModelDownloadStepView`'s scope before deciding.

### Verification
Build: `swift build` — no new errors expected.
Visual: `hotkeyDisplayString` in the callout card now always reflects `toggleKeyCode`/`toggleModifiers`.

---

## Change B — Fix `hotkeyDisplayString` in `TryItNowStepView`

### File
Same file as above.

### Pre-conditions
`TryItNowStepView` (line 943) has `@Environment(AppState.self) private var appState`.

### Exact change — lines 949–956

**Remove:**
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

**Replace with:**
```swift
private var hotkeyDisplayString: String {
    KeySymbols.format(
        keyCode: appState.settings.toggleKeyCode,
        modifiers: appState.settings.toggleModifiers
    )
}
```

### Verification
Visual: Step 4 hero keycap and instruction text (`"Press and hold **\(hotkeyDisplayString)**..."` at line 970) now reflects a hotkey changed in Step 2.

---

## Change C — Fix `hotkeyDisplayString` in `ReadyStepView`

### File
Same file as above.

### Pre-conditions
`ReadyStepView` (line 1148) has `@Environment(AppState.self) private var appState`.

### Exact change — lines 1155–1162

**Remove:**
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

**Replace with:**
```swift
private var hotkeyDisplayString: String {
    KeySymbols.format(
        keyCode: appState.settings.toggleKeyCode,
        modifiers: appState.settings.toggleModifiers
    )
}
```

### Verification
Visual: Step 5 instruction text (`"Press **\(hotkeyDisplayString)** anytime to dictate."` at line 1176) reflects the user's chosen binding.

---

## Change D — Fix modifier icon in `hotkeyConfigRow` (Step 2)

### File
Same file as above.

### Pre-conditions
`hotkeyConfigRow` is a computed property inside `ModelDownloadStepView`. It renders a modifier symbols `Text` at line 653.

### Exact change — line 653

**Remove:**
```swift
Text(KeySymbols.symbolsForModifiers(appState.settings.pushToTalkModifiers))
```

**Replace with:**
```swift
Text(KeySymbols.symbolsForModifiers(appState.settings.toggleModifiers))
```

### Rationale
Same root cause as Changes A–C: `pushToTalkModifiers` is not updated when the recorder writes to `toggleModifiers`. The modifier icon badge must reflect `toggleModifiers`.

### Verification
Visual: The circular modifier badge (⌃, ⌥, etc.) in the `hotkeyConfigRow` card updates immediately after recording a new hotkey.

---

## Change E — Replace `Customize...` button with inline `HotkeyRecorderView`

This is the largest change. It involves:
1. Extracting a new private struct `HotkeyConfigRow` to work around Swift's `@Bindable` in computed property limitation
2. Embedding `HotkeyRecorderView` with the correct bindings
3. Removing the old `hotkeyConfigRow` computed property
4. Updating the call site in `ModelDownloadStepView.body`

### File
Same file as above.

### Pre-conditions
- Changes A and D are already applied (so that `toggleModifiers` is the correct property used in modifier icon display)
- `HotkeyRecorderView` is importable (same module, same target)
- `AppState` is in the SwiftUI environment at the `ModelDownloadStepView` render site

### Why a new struct is required

The existing `hotkeyConfigRow` is a computed `var` property returning `some View`. Swift does NOT allow `@Bindable var` as a local variable inside a computed property body. The only valid locations for `@Bindable var` as a local binding helper are:
- A `View.body` computed property (special compiler support)
- A `func` returning `some View`

The idiomatic SwiftUI solution is to extract a child `View` struct that takes `@Bindable var appState: AppState` as an init parameter. This gives the struct a proper stored `@Bindable` property, and the `$appState.settings.toggleKeyCode` binding is valid in its `body`.

### New type to add

Insert the following private struct immediately before the closing `}` of `ModelDownloadStepView` (i.e., before line 699) but after the last existing computed property in the struct. Concretely, insert it after the `hotkeyConfigRow` property ends (after line 698) and before the `}` that closes `ModelDownloadStepView` (line 699). However — since we're REPLACING `hotkeyConfigRow`, the new struct replaces the removed computed property block.

**Position:** Replace lines 651–698 entirely (the old `private var hotkeyConfigRow: some View { ... }` block) with the new struct declaration below, placed just outside `ModelDownloadStepView` (since nested `struct` declarations inside a `View` struct body at the stored-property level are not supported in Swift).

**Correct placement:** The new `HotkeyConfigRow` struct is a separate `private struct` at file scope, declared after `ModelDownloadStepView` ends (after line 699). It is `private` (file-private) so it is invisible outside `OnboardingView.swift`.

---

### Step E-1: Add new `HotkeyConfigRow` struct after `ModelDownloadStepView`

Insert after line 699 (the closing `}` of `ModelDownloadStepView`) and before the `// MARK: - Step 3` comment:

```swift
// MARK: - Hotkey Config Row (Step 2 inline recorder)

private struct HotkeyConfigRow: View {
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            // Modifier icon badge — always uses toggleModifiers (single source of truth)
            Text(KeySymbols.symbolsForModifiers(appState.settings.toggleModifiers))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.obAccent)
                .frame(width: 36, height: 36)
                .background(Color.obCardBg, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.obBorderHover, lineWidth: 1)
                )
                .shadow(color: Color.obTextPrimary.opacity(0.04), radius: 1, y: 1)

            VStack(alignment: .leading, spacing: 4) {
                HotkeyRecorderView(
                    keyCode: $appState.settings.toggleKeyCode,
                    modifiers: $appState.settings.toggleModifiers,
                    defaultKeyCode: 49,
                    defaultModifiers: .control,
                    label: "Hotkey"
                )
                .environment(\.accentColor, Color.obAccent)

                Text("Click the shortcut to change it")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.obTextTertiary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: 360)
        .background(Color.obSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.obBorder, lineWidth: 1)
        )
    }
}
```

**Notes on this struct:**
- `@Bindable var appState: AppState` is a stored property — valid for `@Bindable`. Swift generates `$appState` binding projections.
- `$appState.settings.toggleKeyCode` is a valid `Binding<UInt16>` because `AppState` is `@Observable` and `SettingsManager` is `@Observable` — the binding chain is supported by the Swift Observation framework via `@Bindable`.
- `defaultKeyCode: 49` = Space, `defaultModifiers: .control` matches the app's factory default (hardcoded to match `SettingsManager` default values — verify these match `SettingsManager.init()` defaults before shipping).
- `.environment(\.accentColor, Color.obAccent)` overrides the system accent for `HotkeyRecorderView`'s recording highlight. The `HotkeyRecorderView` body uses `Color.accentColor.opacity(0.2)` for the recording background and `Color.accentColor` for the border stroke — both inherit from SwiftUI environment. The `KeyCaptureNSView` (NSViewRepresentable) does not use `Color.accentColor` at all, so there is no NSView inheritance issue.
- The modifier icon `Text` in this new struct is already correct (uses `toggleModifiers`) — no separate Change D needed if this is applied atomically. But since Change D is applied first to the old property, and this struct replaces the old property, the net result is correct either way.

### Step E-2: Remove old `hotkeyConfigRow` computed property

Delete lines 651–698 in their entirety:

```swift
private var hotkeyConfigRow: some View {
    HStack(spacing: 12) {
        Text(KeySymbols.symbolsForModifiers(appState.settings.pushToTalkModifiers))
            // ... (entire block through closing brace)
    }
}
```

This is the 48-line computed property ending at line 698. Delete it completely.

### Step E-3: Update call site in `ModelDownloadStepView.body`

In `ModelDownloadStepView.body`, at lines 559–560:

**Remove:**
```swift
hotkeyConfigRow
```

**Replace with:**
```swift
HotkeyConfigRow(appState: appState)
```

The surrounding `if viewModel.isDownloading || viewModel.downloadComplete { ... }` block (lines 555–560) remains unchanged. Only the `hotkeyConfigRow` reference is replaced.

### Edge cases handled by `HotkeyRecorderView` (no additional code needed)

| Case | Handled by |
|------|-----------|
| Escape to cancel | `handleKeyEvent` checks `keyCode == 53` with no modifiers → calls `stopRecording()` without writing binding |
| Modifier-only hotkey (e.g., bare Option) | `flagsChanged` fires on press direction only; recorded as `keyCode=modifier, modifiers=[]` |
| Click away without pressing key | Pre-existing gap: `isRecording` state not cleared on first-responder loss (no `onDisappear`). Out of scope — same behavior as Settings view. `hotkeyService.resume()` called on view disappear |
| Navigate away while recording | `HotkeyRecorderView.onDisappear` → `stopRecording()` → `hotkeyService.resume()` |
| Dismiss onboarding sheet while recording | Same as above: view disappears → `onDisappear` fires |
| Hotkey conflict (another app owns combo) | Silent failure at Carbon layer. No user-visible error. Same behavior as Settings view — acceptable for V1 |
| `hotkeyService` not started | `hotkeyEnabled` defaults to `true`, service starts in `applicationDidFinishLaunching`. `suspend()`/`resume()` are no-ops if service not running (guarded by `isEnabled` check) |

### Verification

1. `swift build` — must compile cleanly
2. Launch app in onboarding mode (delete `hasCompletedOnboarding` UserDefaults key to re-trigger)
3. Advance to Step 2 (Model Download)
4. Confirm: `Customize...` button is absent; inline recorder widget is visible
5. Click the shortcut display area → verify it enters recording state (shows "Press keys...")
6. Press `Cmd+D` → verify: (a) the `HotkeyRecorderView` shows `⌘ D`, (b) the hero keycap card above updates to `⌘ D`, (c) the modifier badge updates to `⌘`
7. Press Escape during recording → verify: no binding change, recorder returns to idle state
8. Record bare modifier (hold-then-release Option key) → verify it captures and displays correctly
9. Advance to Step 4 → verify hero keycap shows the new binding `⌘ D`
10. Verify `hotkeyService` re-registers: after completing onboarding, pressing `Cmd+D` should toggle recording

---

## Change F — Remove `Open Settings for more options` button from Step 5

### File
Same file as above.

### Pre-conditions
`ReadyStepView.body` contains an enhancement card (lines 1185–1238) with two sections: an auto-paste toggle and an "Open Settings" button, separated by a divider.

### Exact change — lines 1210–1228

**Remove the divider and button block entirely:**

```swift
Rectangle()
    .fill(Color.obSurface)
    .frame(height: 1)
    .padding(.vertical, 12)

Button {
    appState.pendingNavigationSection = .aiPolish
} label: {
    HStack(spacing: 6) {
        Image(systemName: "gearshape")
            .font(.system(size: 14))
        Text("Open Settings for more options")
            .font(.system(size: 13, weight: .medium))
    }
    .foregroundStyle(Color.obAccent)
    .padding(.vertical, 4)
}
.buttonStyle(.plain)
```

These are lines 1210–1228 in the current file. The outer `VStack` at lines 1185–1228 will then only contain the auto-paste `HStack` block, making the divider unnecessary.

**After removal, the enhancement card `VStack` becomes:**
```swift
VStack(spacing: 0) {
    HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 2) {
            Text("Enable Auto-Paste")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.obTextPrimary)
            Text("Automatically paste transcriptions into the active app.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.obTextSecondary)
                .lineSpacing(12 * 0.35)
        }

        Spacer()

        Toggle("", isOn: $autoPasteEnabled)
            .toggleStyle(.switch)
            .tint(Color.obSuccess)
            .onChange(of: autoPasteEnabled) { _, enabled in
                if enabled {
                    _ = appState.permissions.requestAccessibilityAccess()
                }
            }
    }
    .padding(.vertical, 6)
}
.padding(.horizontal, 18)
.padding(.vertical, 16)
// ... (existing background/overlay/shadow unchanged)
```

### Rationale
- The "Done" button (line 1243) dismisses onboarding — the user immediately gains access to the full menu bar and settings window after pressing it.
- Navigating to Settings from within the onboarding sheet creates a confusing layered window state (sheet open, settings window also open behind it).
- The auto-paste toggle already provides the only action that must happen during onboarding (requesting Accessibility permission before the user closes the flow).
- "Open Settings" is redundant and violates the principle of keeping the user focused on completing onboarding.

### Verification
1. `swift build` — no new errors
2. Advance to Step 5 in onboarding
3. Confirm: divider line and "Open Settings for more options" button are absent
4. Confirm: auto-paste toggle still present and functional
5. Confirm: "Done" button still present and dismisses onboarding sheet

---

## New Types / Properties Summary

| Name | Kind | Location | Purpose |
|------|------|----------|---------|
| `HotkeyConfigRow` | `private struct` conforming to `View` | After `ModelDownloadStepView` closing `}`, before `// MARK: - Step 3` | Embeds `HotkeyRecorderView` with `@Bindable` AppState; replaces computed property workaround |

No other new types. No new stored properties added to existing structs. No new imports required.

---

## Files to Modify

| File | Changes |
|------|---------|
| `/Users/m4pro_sv/Desktop/EnviousWispr/Sources/EnviousWispr/Views/Onboarding/OnboardingView.swift` | All 6 changes (A–F) |

No other files are modified. `HotkeyRecorderView.swift`, `AppState.swift`, `KeySymbols.swift` are read-only for this feature.

---

## Default Values Verification Checklist

Before finalizing the `HotkeyRecorderView` init in `HotkeyConfigRow`, verify that `defaultKeyCode: 49, defaultModifiers: .control` match the factory defaults in `SettingsManager.init()`. Search `SettingsManager.swift` for the `toggleKeyCode` and `toggleModifiers` UserDefaults keys to confirm the registered default values. If they differ, update the constants in `HotkeyConfigRow` to match.

The goal: the reset button in `HotkeyRecorderView` appears only when the current value differs from factory default, and pressing it restores the factory default.

---

## Build Verification Sequence

```bash
# 1. Verify no compile errors after all changes
swift build

# 2. If build fails, likely causes:
#    - Binding chain $appState.settings.toggleKeyCode not resolving:
#      AppState must be @Observable, SettingsManager must be @Observable,
#      toggleKeyCode must be a stored var (not computed). Verify in AppState.swift / SettingsManager.swift.
#    - HotkeyRecorderView not found: ensure it's in the same module target.
#    - @Bindable in wrong location: verify HotkeyConfigRow.appState is a stored var, not environment.
```

---

## Manual Test Script

After building and launching:

```
Step 1 → Step 2 (wait for/skip download):
  [ ] hotkeyCalloutCard shows "Your hotkey is ⌃ Space" (or current default)
  [ ] hotkeyConfigRow shows inline HotkeyRecorderView, no "Customize..." button
  [ ] Modifier badge shows "⌃"

Click recorder:
  [ ] Recorder enters recording state ("Press keys...")
  [ ] hotkeyService.isSuspended == true (Carbon hotkeys temporarily unregistered)

Press Cmd+D:
  [ ] Recorder saves "⌘ D" and exits recording state
  [ ] hotkeyCalloutCard hero keycap updates to "⌘ D" immediately
  [ ] Modifier badge updates to "⌘"
  [ ] hotkeyService re-registers with Cmd+D (verify in step after onboarding)

Press Escape during recording:
  [ ] Recording cancelled, binding unchanged

Record bare Option key:
  [ ] Displays "Left ⌥" or "⌥ Option"

Navigate Step 2 → Step 3 while recording:
  [ ] onDisappear fires, hotkeyService.resume() called

Step 4:
  [ ] Hero keycap shows ⌘ D (updated from Step 2)
  [ ] Instruction text says "Press and hold ⌘ D"

Step 5:
  [ ] "Open Settings for more options" button is absent
  [ ] Auto-paste toggle is present
  [ ] Done button present

After Done:
  [ ] Onboarding sheet dismissed
  [ ] Pressing ⌘ D triggers recording (hotkey correctly re-registered)
```

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| `$appState.settings.toggleKeyCode` binding chain breaks at `SettingsManager` boundary | Low | Build fails | `SettingsManager` is confirmed `@Observable`; binding chains through `@Observable` objects are supported in Swift 5.9+ |
| `@Bindable var appState: AppState` in `HotkeyConfigRow` init creates a second `@Bindable` wrapper (parent also binds it) | Low | None — cosmetic | `@Bindable` is lightweight; multiple `@Bindable` wrappers around same `@Observable` object are safe |
| Sheet `makeFirstResponder` race: onboarding sheet animation prevents `KeyCaptureNSView` from becoming first responder | Medium | Recorder click doesn't activate | `KeyCaptureView.updateNSView` defers `makeFirstResponder` via `Task { @MainActor in ... }` — this already handles animation deferral in the existing Settings usage |
| Style mismatch: recorder visuals look mismatched with onboarding palette | Low | Visual only | `.environment(\.accentColor, Color.obAccent)` overrides accent; `.secondary` text in recorder may still show system grey — acceptable for V1 |
| `hotkeySymbol` property in `ModelDownloadStepView` not updated | Medium | Stale display if `hotkeySymbol` is used | Must verify whether `hotkeySymbol` is used in any `hotkeyCalloutCard` or `hotkeyConfigRow` rendering. If unused, delete it; if used, apply same fix as Change A |

---

---

## Gemini Review — Incorporated Feedback (2026-03-02)

**Overall verdict:** Plan is complete, unambiguous, and ready for implementation. All five questions answered definitively.

### Q1: Is the plan complete and unambiguous?
**Yes.** Two micro-decisions the implementer must make inline, already called out by the plan:
- `hotkeySymbol` property: verify usage before deciding to update or delete (plan already flags this)
- Default values `defaultKeyCode: 49, defaultModifiers: .control` in `HotkeyConfigRow`: confirmed correct for Space/Control default, but implementer should verify against `SettingsManager.init()` defaults before shipping

### Q2: Does `@Bindable var appState: AppState` work when parent passes a plain `AppState` from `@Environment`?
**Yes, confirmed.** Passing `HotkeyConfigRow(appState: appState)` where the parent's `appState` is environment-injected is correct and idiomatic. The Swift compiler synthesizes the `Bindable<>` wrapper at the property declaration site in the child struct. The parent does NOT need to pass an explicit `Bindable<AppState>`. This is a core feature of the Swift Observation framework.

### Q3: Swift 6 strict concurrency issues with `@Bindable var appState`?
**None.** `AppState` is `@MainActor`, `View.body` is implicitly `@MainActor`, and all `@Bindable` accesses happen within the same actor isolation domain. No sendability or data race issues.

### Q4: Additional SwiftUI focus/responder issues in sheet context?
**None beyond what the plan already covers.** The existing `Task { @MainActor in makeFirstResponder(...) }` deferral in `KeyCaptureView.updateNSView` handles the animation race correctly.

Two runtime validation checks to add to the manual test script (not implementation changes):
- **Tab key cycling**: Confirm Tab correctly cycles focus between the recorder and other interactive elements in the sheet
- **De-focus/re-focus**: Confirm clicking outside the recorder (but inside the sheet) ends recording; clicking back in restarts it

### Q5: Remove "Open Settings" button vs. "dismiss sheet first" guard?
**Remove it entirely, confirmed.** A dismiss-first guard is an admission the button should not be there. Removing it reduces cognitive load, prevents distraction, and keeps users on the happy path through onboarding.

---

## Updated Manual Test Script (post-Gemini additions)

```
Step 1 → Step 2 (wait for/skip download):
  [ ] hotkeyCalloutCard shows "Your hotkey is ⌃ Space" (or current default)
  [ ] hotkeyConfigRow shows inline HotkeyRecorderView, no "Customize..." button
  [ ] Modifier badge shows "⌃"

Click recorder:
  [ ] Recorder enters recording state ("Press keys...")
  [ ] hotkeyService.isSuspended == true (Carbon hotkeys temporarily unregistered)

Press Cmd+D:
  [ ] Recorder saves "⌘ D" and exits recording state
  [ ] hotkeyCalloutCard hero keycap updates to "⌘ D" immediately
  [ ] Modifier badge updates to "⌘"
  [ ] hotkeyService re-registers with Cmd+D (verify in step after onboarding)

Press Escape during recording:
  [ ] Recording cancelled, binding unchanged

Record bare Option key:
  [ ] Displays "Left ⌥" or "⌥ Option"

Tab key cycling (new — from Gemini):
  [ ] Tab from recorder cycles to next interactive element correctly

Click outside recorder without pressing key (new — from Gemini):
  [ ] Recorder stays in recording state (pre-existing gap, not a regression)
  [ ] hotkeyService.resume() NOT called until view disappears — acceptable V1 behavior

Navigate Step 2 → Step 3 while recording:
  [ ] onDisappear fires, hotkeyService.resume() called

Step 4:
  [ ] Hero keycap shows ⌘ D (updated from Step 2)
  [ ] Instruction text says "Press and hold ⌘ D"

Step 5:
  [ ] "Open Settings for more options" button is absent
  [ ] Divider line above where button was is also absent
  [ ] Auto-paste toggle is present
  [ ] Done button present

After Done:
  [ ] Onboarding sheet dismissed
  [ ] Pressing ⌘ D triggers recording (hotkey correctly re-registered)
```

---

*Plan finalized: 2026-03-02. Gemini review complete. Ready for implementation agent.*
