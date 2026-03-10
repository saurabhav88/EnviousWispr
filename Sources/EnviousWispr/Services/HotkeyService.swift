import Cocoa
import Carbon.HIToolbox

/// Modifier key codes that can act as standalone hotkeys.
/// These are the physical key codes reported by NSEvent / Carbon for each modifier key.
enum ModifierKeyCodes {
    static let leftCommand: UInt16  = 55
    static let rightCommand: UInt16 = 54
    static let leftOption: UInt16   = 58
    static let rightOption: UInt16  = 61
    static let leftShift: UInt16    = 56
    static let rightShift: UInt16   = 60
    static let leftControl: UInt16  = 59
    static let rightControl: UInt16 = 62

    static let all: Set<UInt16> = [
        leftCommand, rightCommand,
        leftOption, rightOption,
        leftShift, rightShift,
        leftControl, rightControl
    ]

    /// Returns true if the given key code is a standalone modifier key.
    static func isModifierOnly(_ keyCode: UInt16) -> Bool {
        all.contains(keyCode)
    }

}

/// Manages global hotkey registration for dictation recording control.
///
/// Uses Carbon RegisterEventHotKey for system-wide hotkeys without
/// requiring Accessibility permission.
///
/// For modifier-only hotkeys (e.g., bare Option key), NSEvent global and local
/// monitors for .flagsChanged are used so events fire even when the app is in
/// the background.
@MainActor
@Observable
final class HotkeyService {
    // MARK: - Hotkey IDs

    private enum HotkeyID: UInt32 {
        case toggle = 1
        case cancel = 3
    }

    // MARK: - Carbon State

    private var eventHandlerRef: EventHandlerRef?
    private var toggleHotkeyRef: EventHotKeyRef?
    private var cancelHotkeyRef: EventHotKeyRef?

    // MARK: - NSEvent Modifier Monitors

    private var globalModifierMonitor: Any?
    private var localModifierMonitor: Any?

    private(set) var isEnabled = false
    private(set) var isModifierHeld = false

    /// Tracks the in-flight recording Task so we can cancel zombie Tasks from
    /// previous press/release events before starting new ones. This serializes
    /// recording commands — only one start or stop operation runs at a time.
    private var recordingTask: Task<Void, Never>?

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

    /// Timestamp when hands-free lock was activated. Used as a cooldown guard:
    /// presses within 500ms of locking are ignored to prevent accidental
    /// finger-bounce from immediately stopping the locked recording.
    private var lockTime: Date? = nil

    // MARK: - Callbacks (wired by AppState)

    var onToggleRecording: (@MainActor () async -> Void)?
    var onStartRecording: (@MainActor () async -> Void)?
    var onStopRecording: (@MainActor () async -> Void)?
    var onCancelRecording: (@MainActor () async -> Void)?

    /// Called when recording transitions to hands-free (locked) mode via double-press.
    var onLocked: (@MainActor () async -> Void)?

    /// Returns true if the pipeline is in a processing state (transcribing, polishing, etc.).
    /// Used by the processing state gate to block new recordings during processing.
    var onIsProcessing: (@MainActor () -> Bool)?

    // MARK: - Configuration

    var recordingMode: RecordingMode = .toggle

    /// Toggle-mode hotkey key code (default: Space = 49).
    var toggleKeyCode: UInt16 = 49

    /// Toggle-mode required modifiers (default: Control).
    var toggleModifiers: NSEvent.ModifierFlags = [.control]

    /// Key code for the cancel hotkey. Default: Escape (53).
    var cancelKeyCode: UInt16 = 53

    /// Required modifiers for cancel hotkey. Default: none (bare Escape).
    var cancelModifiers: NSEvent.ModifierFlags = []

    // MARK: - Lifecycle

    private(set) var isSuspended = false

    func start() {
        guard !isEnabled else { return }
        installCarbonEventHandler()
        registerToggleHotkey()
        installModifierMonitors()
        // Cancel hotkey is NOT registered here — only during recording
        isEnabled = true
    }

    func stop() {
        unregisterCancelHotkey()
        unregisterToggleHotkey()
        removeCarbonEventHandler()
        removeModifierMonitors()
        isEnabled = false
        isModifierHeld = false
        performCleanup()
    }

    /// Temporarily unregister all hotkeys so the recorder can capture key combos.
    func suspend() {
        guard isEnabled, !isSuspended else { return }
        unregisterCancelHotkey()
        unregisterToggleHotkey()
        removeModifierMonitors()
        isSuspended = true
    }

    /// Re-register hotkeys after the recorder is done.
    func resume() {
        guard isEnabled, isSuspended else { return }
        isModifierHeld = false
        performCleanup()
        registerToggleHotkey()
        installModifierMonitors()
        isSuspended = false
    }

    /// Register the cancel hotkey. Call on `.recording` entry.
    func registerCancelHotkey() {
        guard cancelHotkeyRef == nil else { return }
        cancelHotkeyRef = registerHotkey(
            id: HotkeyID.cancel.rawValue,
            keyCode: cancelKeyCode,
            modifiers: carbonModifiers(from: cancelModifiers)
        )
    }

    /// Remove the cancel hotkey. Call whenever recording ends.
    func unregisterCancelHotkey() {
        if let ref = cancelHotkeyRef {
            UnregisterEventHotKey(ref)
            cancelHotkeyRef = nil
        }
    }

    /// Reset all hands-free state. Called before every stop/cancel callback
    /// and on service stop/resume.
    private func performCleanup() {
        isRecordingLocked = false
        recordingStartTime = nil
        lockTime = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - Hands-Free State Machine

    /// Unified PTT + hands-free state machine.
    /// Called by both `handleCarbonHotkey` and `handleFlagsChanged` for
    /// push-to-talk mode press/release events.
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
            // Not recording → start fresh
            isRecordingLocked = false
            recordingStartTime = Date()
            debounceTask?.cancel()
            debounceTask = nil
            recordingTask?.cancel()
            recordingTask = Task { await onStartRecording?() }
        } else if let startTime = recordingStartTime,
                  Date().timeIntervalSince(startTime) <= Double(TimingConstants.handsFreeDebounceDelayMs) / 1000.0 {
            // Within 500ms window
            if isRecordingLocked {
                // Triple press → cancel
                Task { await AppLogger.shared.log(
                    "Triple press — cancelling hands-free recording",
                    level: .info, category: "HotkeyService"
                ) }
                performCleanup()
                isModifierHeld = false
                recordingTask?.cancel()
                recordingTask = Task { await onCancelRecording?() }
            } else {
                // Double press → lock into hands-free
                Task { await AppLogger.shared.log(
                    "Double press — locking into hands-free mode",
                    level: .info, category: "HotkeyService"
                ) }
                debounceTask?.cancel()
                debounceTask = nil
                isRecordingLocked = true
                lockTime = Date()
                // DO NOT cancel recordingTask here — the pipeline startup must
                // continue running. Cancelling it aborts preWarm/toggleRecording,
                // leaving the UI locked but no actual recording happening.
                Task { await onLocked?() }
            }
        } else if isRecordingLocked {
            // Lock cooldown: ignore presses within 500ms of locking.
            // Prevents accidental finger-bounce on modifier keys from
            // immediately stopping a just-locked recording.
            if let lt = lockTime,
               Date().timeIntervalSince(lt) <= Double(TimingConstants.handsFreeDebounceDelayMs) / 1000.0 {
                Task { await AppLogger.shared.log(
                    "Press ignored — lock cooldown (\(Int(Date().timeIntervalSince(lt) * 1000))ms since lock)",
                    level: .info, category: "HotkeyService"
                ) }
                isModifierHeld = false
                return
            }
            // Single press while locked (after cooldown) → stop
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

        // Not recording → ignore
        guard isRecording else { return }

        // Locked → suppress release entirely
        if isRecordingLocked { return }

        // Quick release (within 500ms) → debounce, wait for double-press
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
            // Normal PTT release (held > 500ms) → stop immediately
            performCleanup()
            recordingTask?.cancel()
            recordingTask = Task { await onStopRecording?() }
        }
    }

    // MARK: - Carbon Event Handler

    private func installCarbonEventHandler() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                         eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                         eventKind: UInt32(kEventHotKeyReleased))
        ]

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyHandler,
            eventTypes.count,
            &eventTypes,
            selfPtr,
            &eventHandlerRef
        )
    }

    // MARK: - NSEvent Modifier Monitors

    private func installModifierMonitors() {
        removeModifierMonitors()

        // Only install if the hotkey is modifier-only
        guard ModifierKeyCodes.isModifierOnly(toggleKeyCode) else { return }

        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // NSEvent global monitor callbacks arrive on the main thread
            MainActor.assumeIsolated {
                self?.handleFlagsChanged(event)
            }
        }

        localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleFlagsChanged(event)
            }
            return event  // pass the event through
        }
    }

    private func removeModifierMonitors() {
        if let monitor = globalModifierMonitor {
            NSEvent.removeMonitor(monitor)
            globalModifierMonitor = nil
        }
        if let monitor = localModifierMonitor {
            NSEvent.removeMonitor(monitor)
            localModifierMonitor = nil
        }
    }

    private func removeCarbonEventHandler() {
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    // MARK: - Registration Helpers

    private func registerToggleHotkey() {
        unregisterToggleHotkey()
        // Modifier-only hotkeys are handled via NSEvent flagsChanged monitors —
        // Carbon RegisterEventHotKey cannot register a bare modifier key.
        guard !ModifierKeyCodes.isModifierOnly(toggleKeyCode) else { return }
        toggleHotkeyRef = registerHotkey(
            id: HotkeyID.toggle.rawValue,
            keyCode: toggleKeyCode,
            modifiers: carbonModifiers(from: toggleModifiers)
        )
    }

    private func unregisterToggleHotkey() {
        if let ref = toggleHotkeyRef {
            UnregisterEventHotKey(ref)
            toggleHotkeyRef = nil
        }
    }

    private func registerHotkey(id: UInt32, keyCode: UInt16, modifiers: UInt32) -> EventHotKeyRef? {
        let hotkeyID = EventHotKeyID(signature: hotkeySignature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        return status == noErr ? ref : nil
    }

    // MARK: - Event Dispatch

    /// Called from the Carbon event handler on the main thread for RegisterEventHotKey events.
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

    /// Called from the NSEvent flagsChanged monitors for modifier-only hotkeys.
    ///
    /// NSEvent gives us the exact keyCode that changed, so we know precisely which
    /// modifier was pressed or released without needing to diff against a previous state.
    private func handleFlagsChanged(_ event: NSEvent) {
        guard !isSuspended else { return }

        let currentFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode

        // Only process known modifier key codes
        guard ModifierKeyCodes.isModifierOnly(keyCode) else { return }

        // Determine press vs. release by checking whether the flag is present
        let flag = flagForKeyCode(keyCode)
        let isPress = currentFlags.contains(flag)

        // Extract values before async dispatch (NSEvent is not Sendable)
        let capturedKeyCode = keyCode

        // Unified shortcut — both modes use toggleKeyCode
        guard capturedKeyCode == toggleKeyCode else { return }

        if recordingMode == .toggle {
            guard isPress else { return }
            Task { await AppLogger.shared.log(
                "Modifier-only toggle: keyCode=\(capturedKeyCode)", level: .info, category: "HotkeyService"
            ) }
            Task { await onToggleRecording?() }
        } else {
            // Push-to-talk mode with hands-free support
            handleRecordAction(isPress: isPress)
        }
    }

    private func flagForKeyCode(_ keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 55, 54: return .command
        case 58, 61: return .option
        case 59, 62: return .control
        case 56, 60: return .shift
        default:     return []
        }
    }

    // MARK: - Modifier Conversion

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        return carbon
    }

    // MARK: - Display

    /// Human-readable description of the current hotkey.
    var hotkeyDescription: String {
        let formatted = KeySymbols.formatHotkey(keyCode: toggleKeyCode, modifiers: toggleModifiers)
        return recordingMode == .pushToTalk ? "Hold \(formatted)" : formatted
    }

    var cancelHotkeyDescription: String {
        KeySymbols.formatHotkey(keyCode: cancelKeyCode, modifiers: cancelModifiers)
    }
}

// MARK: - Carbon Helpers

/// Four-char-code signature for EnviousWispr hotkeys.
private let hotkeySignature: OSType = {
    var result: OSType = 0
    for char in "EWSP".utf8.prefix(4) {
        result = (result << 8) | OSType(char)
    }
    return result
}()

/// C-function callback for Carbon event handler.
///
/// Handles kEventHotKeyPressed/Released for key+modifier combos registered
/// via RegisterEventHotKey. Modifier-only hotkeys are handled separately via
/// NSEvent flagsChanged monitors, which work globally regardless of app focus.
private func carbonHotkeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event, let userData = userData else {
        return OSStatus(eventNotHandledErr)
    }

    let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
    let eventKind = GetEventKind(event)

    // --- kEventHotKeyPressed / kEventHotKeyReleased ---
    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )
    guard status == noErr else {
        return OSStatus(eventNotHandledErr)
    }

    let isRelease = eventKind == UInt32(kEventHotKeyReleased)
    let hotkeyIDValue = hotkeyID.id

    MainActor.assumeIsolated {
        service.handleCarbonHotkey(id: hotkeyIDValue, isRelease: isRelease)
    }

    return noErr
}
