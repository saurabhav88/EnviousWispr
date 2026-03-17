# Hands-Free Recording Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add double-press-to-lock recording so users can switch from push-to-talk to persistent hands-free recording with a quick double-press of the record key.

**Architecture:** All timing/lock state lives in HotkeyService (input layer). AppState exposes `isRecordingLocked` for the overlay. The overlay animates lips to 2x and fades the timer when locked. No protocol or pipeline changes needed.

**Tech Stack:** Swift 6, @MainActor, Carbon/NSEvent hotkeys, SwiftUI overlay animation

**Spec:** `docs/superpowers/specs/2026-03-10-hands-free-recording-design.md`
**Competitive Reference:** `docs/competitors/wisprflow/hands-free-mode-reverse-engineering.md`

---

## Chunk 1: Constants + HotkeyService State Machine

### Task 1: Add timing constant

**Files:**
- Modify: `Sources/EnviousWispr/Utilities/Constants.swift:49-73`

- [ ] **Step 1: Add `handsFreeDebounceDelayMs` to TimingConstants**

In `Sources/EnviousWispr/Utilities/Constants.swift`, add inside `enum TimingConstants` (after line 72, before the closing `}`):

```swift
    /// Double-press detection window for hands-free recording mode (milliseconds).
    /// Release within this window starts a debounce timer; second press within
    /// this window locks recording. Matches Wispr Flow's proven 500ms constant.
    static let handsFreeDebounceDelayMs: UInt64 = 500
```

- [ ] **Step 2: Verify build compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 3: Commit**

```bash
git add Sources/EnviousWispr/Utilities/Constants.swift
git commit -m "feat(hands-free): add handsFreeDebounceDelayMs timing constant"
```

---

### Task 2: Add hands-free state and shared handler to HotkeyService

**Files:**
- Modify: `Sources/EnviousWispr/Services/HotkeyService.swift`

This is the core task. We add new state, a new callback, a cleanup method, and a shared `handleRecordAction(isPress:)` method that both `handleCarbonHotkey` and `handleFlagsChanged` call.

- [ ] **Step 1: Add new state properties and callback**

After line 65 (`private var recordingTask: Task<Void, Never>?`), add:

```swift
    // MARK: - Hands-Free (Double-Press Lock) State

    /// True when recording is locked into hands-free mode.
    /// When locked, key releases are suppressed and recording continues
    /// until the next key press or cancel.
    private(set) var isRecordingLocked: Bool = false

    /// Timestamp of the key-down that started the current recording session.
    /// Used for the 500ms double-press detection window.
    private var recordingStartTime: Date? = nil

    /// Debounce timer: on quick PTT release (< 500ms), waits for a possible
    /// second press before stopping. Cancelled on double-press or new recording.
    private var debounceTask: Task<Void, Never>? = nil
```

After line 72 (`var onCancelRecording: ...`), add:

```swift
    /// Called when recording transitions to hands-free (locked) mode via double-press.
    var onLocked: (@MainActor () async -> Void)?

    /// Returns true if the pipeline is in a processing state (transcribing, polishing, etc.).
    /// Used by the processing state gate to block new recordings during processing.
    var onIsProcessing: (@MainActor () -> Bool)?
```

- [ ] **Step 2: Add `performCleanup()` method**

After the `unregisterCancelHotkey()` method (after line 146), add:

```swift
    /// Reset all hands-free state. Called before every stop/cancel callback
    /// and on service stop/resume.
    private func performCleanup() {
        isRecordingLocked = false
        recordingStartTime = nil
        debounceTask?.cancel()
        debounceTask = nil
    }
```

Also add `performCleanup()` calls to the existing `stop()` and `resume()` methods:
- In `stop()` (line 103-110): add `performCleanup()` after `isModifierHeld = false`
- In `resume()` (line 122-128): add `performCleanup()` after `isModifierHeld = false`

- [ ] **Step 3: Add the shared `handleRecordAction(isPress:)` method**

Add this method after `performCleanup()`. This is the core state machine from the spec, extracted so both Carbon and flagsChanged handlers can call it:

```swift
    /// Unified PTT + hands-free state machine.
    /// Called by both `handleCarbonHotkey` and `handleFlagsChanged` for
    /// push-to-talk mode press/release events.
    ///
    /// State machine (see spec for full documentation):
    /// - Action Down while idle → start recording
    /// - Action Down within 500ms while recording → lock (hands-free)
    /// - Action Down within 500ms while locked → triple-press cancel
    /// - Action Down while locked (after 500ms) → stop recording
    /// - Action Up while locked → ignored (release suppression)
    /// - Action Up within 500ms → start debounce timer
    /// - Action Up after 500ms → normal PTT stop
    private func handleRecordAction(isPress: Bool) {
        if isPress {
            handleRecordPress()
        } else {
            handleRecordRelease()
        }
    }

    private func handleRecordPress() {
        // Guard: if already held (duplicate press event), ignore
        guard !isModifierHeld else { return }
        isModifierHeld = true

        // Anti-spam Layer 1: Block new recordings while pipeline is processing.
        // Check onIsProcessing callback — AppState provides this based on pipeline state.
        if let isProcessing = onIsProcessing, isProcessing() {
            Task { await AppLogger.shared.log(
                "Key press ignored — pipeline is still processing",
                level: .info, category: "HotkeyService"
            ) }
            isModifierHeld = false
            return
        }

        let isRecording = recordingStartTime != nil

        if !isRecording {
            // Step 2: Not recording → start fresh
            isRecordingLocked = false
            recordingStartTime = Date()
            debounceTask?.cancel()
            debounceTask = nil
            recordingTask?.cancel()
            recordingTask = Task { await onStartRecording?() }
        } else if let startTime = recordingStartTime,
                  Date().timeIntervalSince(startTime) <= Double(TimingConstants.handsFreeDebounceDelayMs) / 1000.0 {
            // Step 3: Within 500ms window
            if isRecordingLocked {
                // Step 3a: Triple press → cancel
                Task { await AppLogger.shared.log(
                    "Triple press — cancelling hands-free recording",
                    level: .info, category: "HotkeyService"
                ) }
                performCleanup()
                isModifierHeld = false
                recordingTask?.cancel()
                recordingTask = Task { await onCancelRecording?() }
            } else {
                // Step 3b: Double press → lock into hands-free
                Task { await AppLogger.shared.log(
                    "Double press — locking into hands-free mode",
                    level: .info, category: "HotkeyService"
                ) }
                debounceTask?.cancel()
                debounceTask = nil
                isRecordingLocked = true
                recordingTask?.cancel()
                recordingTask = Task { await onLocked?() }
            }
        } else if isRecordingLocked {
            // Step 4: Single press while locked (after 500ms) → stop
            Task { await AppLogger.shared.log(
                "Single press while locked — stopping hands-free recording",
                level: .info, category: "HotkeyService"
            ) }
            performCleanup()
            isModifierHeld = false
            recordingTask?.cancel()
            recordingTask = Task { await onStopRecording?() }
        }
    }

    private func handleRecordRelease() {
        guard isModifierHeld else { return }
        isModifierHeld = false

        let isRecording = recordingStartTime != nil

        // Step 1: Not recording → ignore
        guard isRecording else { return }

        // Step 2: Locked → suppress release entirely
        if isRecordingLocked { return }

        // Step 3: Quick release (within 500ms) → debounce, wait for double-press
        if let startTime = recordingStartTime,
           Date().timeIntervalSince(startTime) <= Double(TimingConstants.handsFreeDebounceDelayMs) / 1000.0 {
            debounceTask?.cancel()
            debounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(TimingConstants.handsFreeDebounceDelayMs))
                guard !Task.isCancelled, let self else { return }
                // Timer fired — user didn't double-press. Stop as normal PTT.
                guard self.recordingStartTime != nil, !self.isRecordingLocked else { return }
                Task { await AppLogger.shared.log(
                    "Debounce timer fired — stopping PTT (no double-press detected)",
                    level: .info, category: "HotkeyService"
                ) }
                self.performCleanup()
                self.recordingTask?.cancel()
                self.recordingTask = Task { await self.onStopRecording?() }
            }
        } else {
            // Step 4: Normal PTT release (held > 500ms) → stop immediately
            performCleanup()
            recordingTask?.cancel()
            recordingTask = Task { await onStopRecording?() }
        }
    }
```

- [ ] **Step 4: Rewrite `handleCarbonHotkey` to use the shared handler**

Replace the push-to-talk branch inside `handleCarbonHotkey` (lines 260-272, the `else` block after `if recordingMode == .toggle`):

```swift
            } else {
                // Push-to-talk mode with hands-free support
                handleRecordAction(isPress: !isRelease)
            }
```

The full `handleCarbonHotkey` method should now look like:

```swift
    func handleCarbonHotkey(id: UInt32, isRelease: Bool) {
        Task { await AppLogger.shared.log(
            "Carbon hotkey event: id=\(id), isRelease=\(isRelease), mode=\(recordingMode)",
            level: .info, category: "HotkeyService"
        ) }
        switch id {
        case HotkeyID.toggle.rawValue:
            if recordingMode == .toggle {
                guard !isRelease else { return }
                Task { await onToggleRecording?() }
            } else {
                // Push-to-talk mode with hands-free support
                handleRecordAction(isPress: !isRelease)
            }

        case HotkeyID.cancel.rawValue:
            guard !isRelease else { return }
            performCleanup()
            Task { await onCancelRecording?() }

        default:
            break
        }
    }
```

Note: the cancel hotkey also calls `performCleanup()` now to clear lock state on Escape.

- [ ] **Step 5: Rewrite `handleFlagsChanged` to use the shared handler**

Replace the push-to-talk branch inside `handleFlagsChanged` (lines 313-332, the `else` block after `if recordingMode == .toggle`):

```swift
        } else {
            // Push-to-talk mode with hands-free support
            handleRecordAction(isPress: isPress)
        }
```

The full push-to-talk section should now be just that one line delegating to the shared handler.

- [ ] **Step 6: Verify build compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

If there are compiler errors, read them carefully. Common issues:
- `TimingConstants.handsFreeDebounceDelayMs` not found → Task 1 wasn't applied
- Sendable/concurrency errors → check `@MainActor` isolation on `handleRecordAction`
- Use `/wispr-auto-fix-compiler-errors` skill if needed

- [ ] **Step 7: Commit**

```bash
git add Sources/EnviousWispr/Services/HotkeyService.swift
git commit -m "feat(hands-free): add double-press state machine to HotkeyService

Extracts shared handleRecordAction(isPress:) method used by both
Carbon and flagsChanged handlers. Adds isRecordingLocked, debounce
timer, triple-press cancel, and release suppression."
```

---

## Chunk 2: AppState Wiring

### Task 3: Wire hands-free state through AppState

**Files:**
- Modify: `Sources/EnviousWispr/App/AppState.swift`

- [ ] **Step 1: Add `isRecordingLocked` property to AppState**

Find the `@Observable` class declaration of AppState and add a published property near the other recording state:

```swift
    /// True when recording is in hands-free (locked) mode via double-press.
    /// Read by the overlay to switch to the expanded lips visual.
    var isRecordingLocked: Bool = false
```

- [ ] **Step 2: Wire the `onIsProcessing` and `onLocked` callbacks**

In `AppState.init`, after the existing `hotkeyService.onCancelRecording` block (around line 250), add:

```swift
        hotkeyService.onIsProcessing = { [weak self] in
            guard let self else { return false }
            let state = self.activePipeline.state
            // Block during any state that means "still working on the last recording"
            return state == .transcribing || state == .polishing
        }
```

Also add the `onLocked` callback after `onIsProcessing`:

```swift
        hotkeyService.onLocked = { [weak self] in
            guard let self else { return }
            self.isRecordingLocked = true
            Task { await AppLogger.shared.log(
                "Hands-free mode activated — overlay should expand",
                level: .info, category: "AppState"
            ) }
        }
```

- [ ] **Step 3: Update `onStopRecording` to clear lock state**

In the existing `hotkeyService.onStopRecording` callback (around line 238), add `self.isRecordingLocked = false` as the first line inside the closure:

```swift
        hotkeyService.onStopRecording = { [weak self] in
            guard let self else { return }
            self.isRecordingLocked = false  // ← ADD THIS LINE
            await self.activePipeline.handle(event: .requestStop)
            // ... rest of existing code unchanged
        }
```

- [ ] **Step 4: Update `onCancelRecording` to clear lock state**

In the existing `hotkeyService.onCancelRecording` callback (around line 248), add lock clearing:

```swift
        hotkeyService.onCancelRecording = { [weak self] in
            self?.isRecordingLocked = false  // ← ADD THIS LINE
            await self?.cancelRecording()
        }
```

- [ ] **Step 5: Update `cancelRecording()` method to clear lock state**

In the `cancelRecording()` method (around line 630), add `isRecordingLocked = false` at the top:

```swift
    func cancelRecording() async {
        isRecordingLocked = false  // ← ADD THIS LINE
        recordingOverlay.hide()
        // ... rest unchanged
    }
```

- [ ] **Step 6: Clear lock state on pipeline state changes that end recording**

In the pipeline `onStateChange` callbacks (around lines 148-165 and 166-183), add `self.isRecordingLocked = false` in the state transitions that end recording. Find the cases for `.transcribing, .polishing, .error, .idle, .complete` and add lock clearing there:

```swift
            case .transcribing, .polishing, .error, .idle, .complete:
                self.isRecordingLocked = false  // ← ADD THIS LINE
                self.hotkeyService.unregisterCancelHotkey()
```

Do this for BOTH the Parakeet pipeline callback (around line 156) and the WhisperKit pipeline callback (around line 174).

- [ ] **Step 7: Verify build compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

- [ ] **Step 8: Commit**

```bash
git add Sources/EnviousWispr/App/AppState.swift
git commit -m "feat(hands-free): wire isRecordingLocked through AppState

Adds onLocked callback, clears lock state on stop/cancel/state
transitions. Exposes isRecordingLocked for overlay consumption."
```

---

## Chunk 3: Overlay Animation

### Task 4: Animate overlay for hands-free mode

**Files:**
- Modify: `Sources/EnviousWispr/Views/Overlay/RecordingOverlayPanel.swift`

- [ ] **Step 1: Add `isRecordingLocked` parameter to `RecordingOverlayView`**

In `RecordingOverlayView` (line 461), add a new parameter:

```swift
struct RecordingOverlayView: View {
    let audioLevelProvider: () -> Float
    let isRecordingLocked: Bool  // ← ADD THIS LINE
    @State private var audioLevel: Float = 0
    @State private var elapsed: TimeInterval = 0
```

- [ ] **Step 2: Add animation modifiers to the view body**

Replace the `body` property of `RecordingOverlayView` (lines 468-491):

```swift
    var body: some View {
        HStack(spacing: 10) {
            // Rainbow lips icon — audio-reactive during recording
            RainbowLipsIcon(size: 24, audioLevel: audioLevel)
                .scaleEffect(isRecordingLocked ? 2.0 : 1.0)

            // Duration timer — hidden in hands-free mode
            if !isRecordingLocked {
                Text(FormattingConstants.formatDuration(elapsed))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isRecordingLocked)
        // Single container animation prevents animation stacking: N per-element
        // modifiers × update rate creates exponential state transitions (gotchas.md).
        .animation(.easeOut(duration: 0.08), value: audioLevel)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(OverlayCapsuleBackground())
        .task {
            while !Task.isCancelled {
                audioLevel = audioLevelProvider()
                elapsed = Date().timeIntervalSince(startTime)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
```

- [ ] **Step 3: Update `createPanel` to accept and pass `isRecordingLocked`**

Modify the `createPanel` method (line 102):

```swift
    private func createPanel(audioLevelProvider: @escaping () -> Float, isRecordingLocked: Bool = false, y: CGFloat? = nil) {
        guard panel == nil else { return }

        let width: CGFloat = isRecordingLocked ? 120 : 185
        let height: CGFloat = isRecordingLocked ? 64 : 44
        let overlayView = RecordingOverlayView(
            audioLevelProvider: audioLevelProvider,
            isRecordingLocked: isRecordingLocked
        )
        .frame(width: width, height: height)
        showPanel(content: overlayView, width: width, height: height, y: y)
    }
```

- [ ] **Step 4: Update `showPanel` to accept dynamic height**

Modify the `showPanel` method signature (line 171) to accept a `height` parameter:

```swift
    private func showPanel<V: View>(content: V, width: CGFloat, height: CGFloat = 44, y: CGFloat? = nil) {
        guard let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main
                ?? NSScreen.screens.first else { return }

        let size = NSRect(x: 0, y: 0, width: width, height: height)
        // ... rest unchanged
```

- [ ] **Step 5: Update `show(intent:audioLevelProvider:)` to accept `isRecordingLocked`**

Modify the intent-driven API (line 33):

```swift
    func show(intent: OverlayIntent, audioLevelProvider: @escaping () -> Float = { 0 }, isRecordingLocked: Bool = false) {
        guard intent != currentIntent || (intent == .recording && self.isRecordingLocked != isRecordingLocked) else { return }
        self.isRecordingLocked = isRecordingLocked
        currentIntent = intent
        switch intent {
        case .hidden:
            hide()
        case .recording:
            show(audioLevelProvider: audioLevelProvider, isRecordingLocked: isRecordingLocked)
        case .processing(let label):
            showPolishing(label: label)
        }
    }
```

Add the stored property at the top of the class (after line 27):

```swift
    /// Tracks lock state for flicker guard comparison.
    private var isRecordingLocked: Bool = false
```

- [ ] **Step 6: Thread `isRecordingLocked` through `show()` and `transitionToRecording()`**

Update the `show(audioLevelProvider:)` method (line 48) to accept and pass the parameter:

```swift
    func show(audioLevelProvider: @escaping () -> Float, isRecordingLocked: Bool = false) {
        if panel != nil {
            transitionToRecording(audioLevelProvider: audioLevelProvider, isRecordingLocked: isRecordingLocked)
            return
        }
        pendingCreateWork?.cancel()
        pendingCreateWork = nil
        generation &+= 1
        let token = generation

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.pendingCreateWork = nil
            self.createPanel(audioLevelProvider: audioLevelProvider, isRecordingLocked: isRecordingLocked)
        }
        pendingCreateWork = work
        DispatchQueue.main.async(execute: work)
    }
```

Update `transitionToRecording` (line 148) similarly:

```swift
    private func transitionToRecording(audioLevelProvider: @escaping () -> Float, isRecordingLocked: Bool = false) {
        // ... existing teardown code unchanged ...

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.pendingCreateWork = nil
            self.createPanel(audioLevelProvider: audioLevelProvider, isRecordingLocked: isRecordingLocked, y: y)
        }
        pendingCreateWork = work
        DispatchQueue.main.async(execute: work)
    }
```

- [ ] **Step 7: Update AppState overlay calls to pass `isRecordingLocked`**

In `Sources/EnviousWispr/App/AppState.swift`, update both `recordingOverlay.show()` calls (around lines 160 and 178):

```swift
            self.recordingOverlay.show(
                intent: self.pipeline.overlayIntent,
                audioLevelProvider: { [weak self] in self?.audioCapture.audioLevel ?? 0 },
                isRecordingLocked: self.isRecordingLocked
            )
```

Do this for BOTH pipeline callbacks.

- [ ] **Step 8: Clean up `hide()` to reset lock state**

In the `hide()` method (line 205), add lock state reset:

```swift
    func hide() {
        currentIntent = .hidden
        isRecordingLocked = false  // ← ADD THIS LINE
        generation &+= 1
        // ... rest unchanged
```

- [ ] **Step 9: Verify build compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeded

If compile errors, use `/wispr-auto-fix-compiler-errors` skill.

- [ ] **Step 10: Commit**

```bash
git add Sources/EnviousWispr/Views/Overlay/RecordingOverlayPanel.swift Sources/EnviousWispr/App/AppState.swift
git commit -m "feat(hands-free): animate overlay for locked recording mode

Lips scale to 2x, timer fades out, panel resizes to 120x64 when
recording is locked into hands-free mode. Smooth 0.3s easeInOut
transitions."
```

---

## Chunk 4: Build, Launch, and UAT Verification

### Task 5: Rebuild, launch, and verify with wispr-eyes

- [ ] **Step 1: Rebuild and relaunch the app**

Run: `/wispr-rebuild-and-relaunch`

This builds release, bundles, and launches the app with fresh permissions.

- [ ] **Step 2: Verify normal PTT still works**

Use `/wispr-eyes "verify that normal push-to-talk recording works: hold the record key for 2+ seconds, the overlay should show rainbow lips + timer at normal size, releasing should stop and transcribe"`.

- [ ] **Step 3: Verify double-press locks (manual test)**

This requires manual testing by the user. Document the test:
1. Press record key briefly (< 500ms), release, press again quickly
2. Expected: overlay transitions to larger lips, no timer
3. Recording should continue even after releasing the key
4. Press once more to stop

- [ ] **Step 4: Commit any fixes**

If wispr-eyes or manual testing reveals issues, fix and commit.

- [ ] **Step 5: Final commit — push**

```bash
git push
```
