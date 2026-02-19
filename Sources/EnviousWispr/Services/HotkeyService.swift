import Cocoa

/// Manages global hotkey registration for dictation recording control.
///
/// Uses NSEvent monitors for both toggle mode (keyDown) and push-to-talk (flagsChanged).
/// Requires Accessibility permission for global key monitoring to work.
@MainActor
@Observable
final class HotkeyService {
    private var globalKeyMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localKeyMonitor: Any?
    private var localFlagsMonitor: Any?

    // Cancel hotkey — dynamically registered only during recording
    private var globalCancelMonitor: Any?
    private var localCancelMonitor: Any?

    /// Key code for the cancel hotkey. Default: Escape (53).
    var cancelKeyCode: UInt16 = 53

    /// Required modifiers for cancel hotkey. Default: none (bare Escape).
    var cancelModifiers: NSEvent.ModifierFlags = []

    /// Fired when the cancel hotkey is pressed while recording is active.
    var onCancelRecording: (@MainActor () async -> Void)?

    private(set) var isEnabled = false
    private(set) var isModifierHeld = false

    // Callbacks wired by AppState
    var onToggleRecording: (@MainActor () async -> Void)?
    var onStartRecording: (@MainActor () async -> Void)?
    var onStopRecording: (@MainActor () async -> Void)?

    var recordingMode: RecordingMode = .toggle

    /// Toggle-mode hotkey key code (default: Space = 49).
    var toggleKeyCode: UInt16 = 49

    /// Toggle-mode required modifiers (default: Control).
    var toggleModifiers: NSEvent.ModifierFlags = [.control]

    /// Push-to-talk modifier (default: Option).
    var pushToTalkModifier: NSEvent.ModifierFlags = [.option]

    func start() {
        guard !isEnabled else { return }

        // Global monitors (when app is not focused)
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            Task { @MainActor in self?.handleKeyDown(code: code, flags: flags) }
        }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            Task { @MainActor in self?.handleFlagsChanged(flags: flags) }
        }

        // Local monitors (when app is focused)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            Task { @MainActor in self?.handleKeyDown(code: code, flags: flags) }
            return event
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            Task { @MainActor in self?.handleFlagsChanged(flags: flags) }
            return event
        }

        isEnabled = true
    }

    func stop() {
        unregisterCancelHotkey()  // Clean up cancel monitors first
        for monitor in [globalKeyMonitor, globalFlagsMonitor, localKeyMonitor, localFlagsMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalKeyMonitor = nil
        globalFlagsMonitor = nil
        localKeyMonitor = nil
        localFlagsMonitor = nil
        isEnabled = false
        isModifierHeld = false
    }

    /// Register global + local cancel monitors. Call on `.recording` entry.
    func registerCancelHotkey() {
        guard globalCancelMonitor == nil else { return }

        globalCancelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            Task { @MainActor in self?.handleCancelKeyDown(code: code, flags: flags) }
        }

        localCancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            Task { @MainActor in self?.handleCancelKeyDown(code: code, flags: flags) }
            return event  // Pass event through — do not consume Escape globally
        }
    }

    /// Remove cancel monitors. Call whenever recording ends for any reason.
    func unregisterCancelHotkey() {
        if let monitor = globalCancelMonitor {
            NSEvent.removeMonitor(monitor)
            globalCancelMonitor = nil
        }
        if let monitor = localCancelMonitor {
            NSEvent.removeMonitor(monitor)
            localCancelMonitor = nil
        }
    }

    private func handleKeyDown(code: UInt16, flags: NSEvent.ModifierFlags) {
        guard recordingMode == .toggle else { return }
        let required = toggleModifiers.intersection(.deviceIndependentFlagsMask)
        if code == toggleKeyCode && flags.contains(required) {
            Task { await onToggleRecording?() }
        }
    }

    private func handleFlagsChanged(flags: NSEvent.ModifierFlags) {
        guard recordingMode == .pushToTalk else { return }
        let held = flags.contains(pushToTalkModifier)
        if held && !isModifierHeld {
            isModifierHeld = true
            Task { await onStartRecording?() }
        } else if !held && isModifierHeld {
            isModifierHeld = false
            Task { await onStopRecording?() }
        }
    }

    /// Human-readable description of the current hotkey.
    var hotkeyDescription: String {
        if recordingMode == .pushToTalk {
            return "Hold \(modifierName(pushToTalkModifier))"
        } else {
            return "\(modifierName(toggleModifiers))\(keyCodeName(toggleKeyCode))"
        }
    }

    var cancelHotkeyDescription: String {
        let mods = modifierName(cancelModifiers)
        let key = keyCodeName(cancelKeyCode)
        return mods.isEmpty ? key : "\(mods)\(key)"
    }

    private func handleCancelKeyDown(code: UInt16, flags: NSEvent.ModifierFlags) {
        guard code == cancelKeyCode else { return }
        let required = cancelModifiers.intersection(.deviceIndependentFlagsMask)
        guard required.isEmpty || flags.contains(required) else { return }
        Task { await onCancelRecording?() }
    }

    private func modifierName(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        return parts.joined()
    }

    private func keyCodeName(_ code: UInt16) -> String {
        switch code {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 53: return "Escape"
        default: return "Key(\(code))"
        }
    }
}
