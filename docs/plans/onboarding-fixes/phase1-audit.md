# Phase 1 Audit — Bug Fixes (Gemini Review)

## Bug 1: Done button — STRONGLY recommend Option A

### Key audit findings:
1. **Option B (simple fix) is a trap** — doesn't handle user clicking red close button on title bar. Would need `.onDisappear` handler too, adding complexity.
2. **Option A (state-driven)** handles close button for free — `Window(isPresented:)` binding auto-sets false.
3. **ActionWirer can be removed entirely** — simplifies codebase.

### Edge cases to handle:
- User closing window via red button (Option A handles this)
- App lifecycle: does app quit if main window closed but onboarding open?
- Window ordering/focus when `isOnboardingPresented` becomes true

### Decision: **Option A — state-driven Window(isPresented:)**

---

## Bug 2: Toggle/PTT — USE SINGLE HOTKEY ID

### Critical audit insight:
**Do NOT use unregister/re-register approach.** Race condition: user changes mode while key is held → keyUp event lost → recording stuck.

### Recommended fix: Single hotkey, single handler
1. Register ONE Carbon hotkey (id=1) on `start()`
2. Handler reads current `recordingMode` at event time
3. Branch on keyDown vs keyUp based on mode:
   - Toggle: keyDown toggles, keyUp ignored
   - PTT: keyDown starts, keyUp stops
4. No unregister/re-register needed — hotkey stays registered
5. Mode switching is instant — just changes handler behavior

### Benefits:
- Eliminates race condition
- Simpler code (no registration churn)
- `suspend()`/`resume()` only manages one ID
- Mode change during key-hold works correctly

### Test matrix:
1. Press/release in PTT → start/stop
2. Press/release in Toggle → start, then start/stop on second press
3. Press in PTT → change mode → release in Toggle → recording should stop
4. Press in Toggle → change mode → release in PTT → no stuck state
