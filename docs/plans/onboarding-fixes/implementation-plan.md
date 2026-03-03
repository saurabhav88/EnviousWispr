# Implementation Plan — Onboarding Fixes Round 2

## Phase 1: Bug Fixes (Critical, do first)

### Task 1.1: Fix Done Button — State-Driven Window Dismissal
**Complexity: M | Files: 3**

1. **EnviousWisprApp.swift** — Add `@State private var isOnboardingPresented` initialized from `appDelegate.appState.settings.onboardingState != .completed`
2. **EnviousWisprApp.swift** — Change onboarding Window to use `isPresented: $isOnboardingPresented`
3. **OnboardingView.swift** — `onComplete` closure now just needs to exist (already wired)
4. **EnviousWisprApp.swift** — In onComplete closure: set `isOnboardingPresented = false` + `NSApp.setActivationPolicy(.accessory)`
5. **AppDelegate.swift** — Remove `dismissOnboardingWindowAction` property and `closeOnboardingWindow()` method
6. **ActionWirer** — Remove `dismissOnboardingWindowAction` wiring (keep openWindow actions)
7. **ActionWirer** — Remove auto-open onboarding logic (Window(isPresented:) handles this)

**Verification:** Fresh launch → onboarding appears → complete → Done closes window → relaunch → no onboarding

### Task 1.2: Fix Toggle/PTT — Single Hotkey Registration
**Complexity: M | Files: 1**

1. **HotkeyService.swift** — Remove `pttHotkeyRef` property
2. **HotkeyService.swift:start()** — Remove `registerPTTHotkey()` call (line ~107)
3. **HotkeyService.swift:start()** — Remove PTT key sync lines (103-104) — not needed anymore
4. **HotkeyService.swift:handleCarbonHotkey** — Already handles both modes in single case block. Remove `HotkeyID.ptt` from the case pattern (line 289).
5. **HotkeyService.swift:suspend()** — Remove `unregisterPTTHotkey()` call
6. **HotkeyService.swift:resume()** — Remove `registerPTTHotkey()` call
7. **HotkeyService.swift:stop()** — Remove `unregisterPTTHotkey()` call
8. **HotkeyService.swift** — Delete `registerPTTHotkey()` and `unregisterPTTHotkey()` methods entirely
9. **HotkeyService.swift** — Remove `HotkeyID.ptt` enum case (or keep but unused)

**Verification:** Toggle mode: press/release toggles. PTT mode: hold/release starts/stops. No dual-fire.

---

## Phase 2: UI Polish (Visual, do after Phase 1)

### Task 2.1: API Key Placeholder Text
**Complexity: S | Files: 1**

1. **OnboardingView.swift** — Add `displayName` computed property to OnboardingProvider enum:
   - `.openai` → "OpenAI"
   - `.gemini` → "Gemini"
2. **OnboardingView.swift line 918-924** — Change TextField prompt:
   ```swift
   prompt: Text("Paste your \(selectedProvider.displayName) API key")
   ```
3. **OnboardingView.swift** — Add caption below TextField:
   ```swift
   Text("Your key should start with \"\(selectedProvider.keyPlaceholder)\"")
       .font(.system(size: 11))
       .foregroundStyle(Color(NSColor.secondaryLabelColor))
   ```

**Verification:** Switch providers → placeholder updates dynamically. Caption shows prefix hint.

### Task 2.2: Font & Color Standardization
**Complexity: M (tedious) | Files: 1-2**

1. **OnboardingView.swift** — Add Font extension (top of file or separate extension):
   ```swift
   extension Font {
       static let obDisplay = Font.system(size: 22, weight: .heavy, design: .rounded)
       static let obHeading = Font.system(size: 18, weight: .bold, design: .rounded)
       static let obSubheading = Font.system(size: 14, weight: .semibold)
       static let obBody = Font.system(size: 14, weight: .regular)
       static let obCaption = Font.system(size: 12, weight: .regular)
       static let obMono = Font.system(size: 12, weight: .regular, design: .monospaced)
   }
   ```
   NOTE: Using fixed sizes (not TextStyle) because onboarding is a fixed-size window.
   Dynamic Type scaling would break the carefully designed layout.

2. **OnboardingView.swift** — Replace all 22+ `.font(.system(size:weight:))` calls with `Font.ob*` constants
3. **OnboardingView.swift** — Replace text colors for body text:
   - `Color.obTextPrimary` on body text → `.primary` (but KEEP for headings where brand matters)
   - `Color.obTextTertiary` on placeholder → `Color(NSColor.tertiaryLabelColor)`
   - KEEP all `obAccent`, `obBg`, `obSurface`, `obCardBg` as-is
4. **DO NOT touch** button colors, background colors, or accent colors — brand stays

**Verification:** Visual inspection of all 5 onboarding steps. Fonts consistent. Colors readable.

---

## Execution Order
1. Task 1.1 + Task 1.2 in parallel (independent bugs)
2. Build + smoke test
3. Task 2.1 + Task 2.2 in parallel (independent polish)
4. Build + full UAT
5. Commit
