# Phase 1 Brainstorm — Bug Fixes (Gemini)

## Bug 1: Done button doesn't close onboarding

### Root Cause
Race condition: `dismissOnboardingWindowAction` is wired in `ActionWirer` (inside main Window scene `.task`). If user clicks Done before main window's ActionWirer runs, the closure is nil.

### Recommended Fix
Use SwiftUI state-driven window presentation instead of imperative dismissal:
- Add `@State private var isOnboardingPresented: Bool` to EnviousWisprApp
- Use `Window("Setup", id: "onboarding", isPresented: $isOnboardingPresented)` (if available in macOS 14+)
- OR: Move dismissWindow environment capture into the onboarding Window scene itself
- Simplify AppDelegate.closeOnboardingWindow() — remove nil-able closure dependency

### Alternative Fix (simpler)
Instead of full refactor, ensure ActionWirer runs before onboarding can complete:
- Move `dismissOnboardingWindowAction` wiring into the onboarding Window scene directly
- Add a `@Environment(\.dismissWindow)` inside OnboardingView and pass it down

### Risk Assessment
- Low risk for the simpler fix (just moves where dismissWindow is captured)
- Medium risk for full refactor (touches app lifecycle)

### Testing
1. Fresh install → complete onboarding → Done should close window
2. Existing user → no onboarding shown
3. Fast-click through onboarding → Done still works

---

## Bug 2: Toggle/PTT dual-mode regression

### Root Cause
`HotkeyService.start()` registers BOTH toggle (id=1) AND PTT (id=2) hotkeys with SAME key combo. Carbon fires 2 events per keypress.

### Recommended Fix
Register only ONE hotkey based on `recordingMode`:
- Remove `registerToggleHotkey()` + `registerPTTHotkey()` as separate methods
- Add single `registerPrimaryHotkey()` that registers ONE hotkey
- Use the appropriate ID based on recordingMode
- On mode change, unregister old → register new

### Risk Assessment
- Medium risk — touches Carbon hotkey system
- Must handle mode switching while app is running
- Must not leak hotkey registrations

### Testing
1. Toggle mode: press+release → recording stays on, press+release again → stops
2. PTT mode: hold → recording, release → stops
3. Dynamic switch: change mode in settings → verify correct behavior
4. Hold key in toggle mode → should NOT behave as PTT
