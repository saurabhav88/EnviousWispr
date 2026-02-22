import Cocoa
import Carbon.HIToolbox

/// Manages global hotkey registration for dictation recording control.
///
/// Uses Carbon RegisterEventHotKey for system-wide hotkeys without
/// requiring Accessibility permission.
@MainActor
@Observable
final class HotkeyService {
    // MARK: - Hotkey IDs

    private enum HotkeyID: UInt32 {
        case toggle = 1
        case ptt = 2
        case cancel = 3
    }

    // MARK: - Carbon State

    private var eventHandlerRef: EventHandlerRef?
    private var toggleHotkeyRef: EventHotKeyRef?
    private var pttHotkeyRef: EventHotKeyRef?
    private var cancelHotkeyRef: EventHotKeyRef?

    private(set) var isEnabled = false
    private(set) var isModifierHeld = false

    // MARK: - Callbacks (wired by AppState)

    var onToggleRecording: (@MainActor () async -> Void)?
    var onStartRecording: (@MainActor () async -> Void)?
    var onStopRecording: (@MainActor () async -> Void)?
    var onCancelRecording: (@MainActor () async -> Void)?

    // MARK: - Configuration

    var recordingMode: RecordingMode = .toggle

    /// Toggle-mode hotkey key code (default: Space = 49).
    var toggleKeyCode: UInt16 = 49

    /// Toggle-mode required modifiers (default: Control).
    var toggleModifiers: NSEvent.ModifierFlags = [.control]

    /// Push-to-talk key code (default: Space = 49).
    var pushToTalkKeyCode: UInt16 = 49

    /// Push-to-talk modifiers (default: Option).
    var pushToTalkModifiers: NSEvent.ModifierFlags = [.option]

    /// Key code for the cancel hotkey. Default: Escape (53).
    var cancelKeyCode: UInt16 = 53

    /// Required modifiers for cancel hotkey. Default: none (bare Escape).
    var cancelModifiers: NSEvent.ModifierFlags = []

    // MARK: - Lifecycle

    func start() {
        guard !isEnabled else { return }
        installCarbonEventHandler()
        registerToggleHotkey()
        registerPTTHotkey()
        // Cancel hotkey is NOT registered here — only during recording
        isEnabled = true
    }

    func stop() {
        unregisterCancelHotkey()
        unregisterToggleHotkey()
        unregisterPTTHotkey()
        removeCarbonEventHandler()
        isEnabled = false
        isModifierHeld = false
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

    private func removeCarbonEventHandler() {
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    // MARK: - Registration Helpers

    private func registerToggleHotkey() {
        unregisterToggleHotkey()
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

    private func registerPTTHotkey() {
        unregisterPTTHotkey()
        pttHotkeyRef = registerHotkey(
            id: HotkeyID.ptt.rawValue,
            keyCode: pushToTalkKeyCode,
            modifiers: carbonModifiers(from: pushToTalkModifiers)
        )
    }

    private func unregisterPTTHotkey() {
        if let ref = pttHotkeyRef {
            UnregisterEventHotKey(ref)
            pttHotkeyRef = nil
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

    /// Called from the Carbon event handler on the main thread.
    func handleCarbonHotkey(id: UInt32, isRelease: Bool) {
        switch id {
        case HotkeyID.toggle.rawValue:
            guard !isRelease, recordingMode == .toggle else { return }
            Task { await onToggleRecording?() }

        case HotkeyID.ptt.rawValue:
            guard recordingMode == .pushToTalk else { return }
            if !isRelease && !isModifierHeld {
                isModifierHeld = true
                Task { await onStartRecording?() }
            } else if isRelease && isModifierHeld {
                isModifierHeld = false
                Task { await onStopRecording?() }
            }

        case HotkeyID.cancel.rawValue:
            guard !isRelease else { return }
            Task { await onCancelRecording?() }

        default:
            break
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
        if recordingMode == .pushToTalk {
            return "Hold \(KeySymbols.format(keyCode: pushToTalkKeyCode, modifiers: pushToTalkModifiers))"
        } else {
            return KeySymbols.format(keyCode: toggleKeyCode, modifiers: toggleModifiers)
        }
    }

    var cancelHotkeyDescription: String {
        KeySymbols.format(keyCode: cancelKeyCode, modifiers: cancelModifiers)
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
private func carbonHotkeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event = event, let userData = userData else {
        return OSStatus(eventNotHandledErr)
    }

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

    let eventKind = GetEventKind(event)
    let isRelease = eventKind == UInt32(kEventHotKeyReleased)

    let hotkeyIDValue = hotkeyID.id
    let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
    // Carbon events arrive on the main thread (application event loop)
    MainActor.assumeIsolated {
        service.handleCarbonHotkey(id: hotkeyIDValue, isRelease: isRelease)
    }

    return noErr
}
