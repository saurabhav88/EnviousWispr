import SwiftUI
import AppKit

// MARK: - KeyCaptureNSView

/// Custom NSView subclass that intercepts key events — including system key equivalents
/// (Command+Arrow, Option+Arrow, etc.) — before macOS consumes them.
private final class KeyCaptureNSView: NSView {
    var onKeyEvent: ((NSEvent) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    /// Called BEFORE the system handles key equivalents (e.g. Command+Left, Option+Arrow).
    /// Returning true tells AppKit this view handled the event, preventing system consumption.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEvent?(event)
        return true
    }

    /// Called for regular key presses that are not key equivalents (plain letters, etc.).
    override func keyDown(with event: NSEvent) {
        onKeyEvent?(event)
    }

    /// Intercepts bare modifier key presses (e.g. Option alone, Command alone).
    ///
    /// A flagsChanged event fires on both press and release of a modifier key.
    /// We only forward it when the modifier count goes UP (a new modifier is added)
    /// so that releasing the key does not trigger a second recording action.
    override func flagsChanged(with event: NSEvent) {
        // Determine which device-independent modifier bits changed compared to the
        // previous event. NSEvent does not expose a "previous flags" property, so
        // we rely on the keyCode to identify the specific modifier key that changed
        // and the direction of the transition from the modifier flags themselves.
        let currentFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Map the physical key code to the modifier flag it represents.
        let addedFlag = flagForModifierKeyCode(event.keyCode)
        guard addedFlag != [] else { return }   // not a recognised modifier key

        // Only forward the event when the modifier is being pressed (added), not released.
        if currentFlags.contains(addedFlag) {
            onKeyEvent?(event)
        }
    }

    /// Returns the NSEvent.ModifierFlags bit that corresponds to the given modifier key code.
    private func flagForModifierKeyCode(_ keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 55, 54: return .command
        case 58, 61: return .option
        case 59, 62: return .control
        case 56, 60: return .shift
        default:     return []
        }
    }
}

// MARK: - KeyCaptureView

/// SwiftUI wrapper around `KeyCaptureNSView`. When `isRecording` is true the underlying
/// NSView becomes first responder so it receives all key input ahead of the system.
private struct KeyCaptureView: NSViewRepresentable {
    let isRecording: Bool
    let onKeyEvent: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKeyEvent = onKeyEvent
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKeyEvent = onKeyEvent
        if isRecording {
            // Defer making first responder so the window is ready
            Task { @MainActor in
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

// MARK: - HotkeyRecorderView

/// A reusable view for recording keyboard shortcuts.
/// Click to start recording, press a key combo to set, click again or press Escape to cancel.
struct HotkeyRecorderView: View {
    @Binding var keyCode: UInt16
    @Binding var modifiers: NSEvent.ModifierFlags

    let defaultKeyCode: UInt16
    let defaultModifiers: NSEvent.ModifierFlags
    let label: String

    @Environment(AppState.self) private var appState

    @State private var isRecording = false

    var body: some View {
        HStack {
            Text(label)
            Spacer()

            // Use onTapGesture on a plain view to avoid Button stealing key events
            HStack(spacing: 4) {
                if isRecording {
                    Text("Press keys...")
                        .foregroundStyle(.secondary)
                } else {
                    Text(KeySymbols.format(keyCode: keyCode, modifiers: modifiers))
                }
            }
            .frame(minWidth: 100)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isRecording ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isRecording ? Color.accentColor : Color.clear, lineWidth: 1)
            )
            // Overlay a zero-size KeyCaptureView so it can steal first responder
            // without affecting visual layout.
            .overlay(
                KeyCaptureView(isRecording: isRecording, onKeyEvent: handleKeyEvent)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false),
                alignment: .center
            )
            .contentShape(Rectangle())
            .onTapGesture {
                toggleRecording()
            }

            // Reset button
            if keyCode != defaultKeyCode || modifiers != defaultModifiers {
                Button(action: resetToDefault) {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to default")
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        // Suspend all Carbon hotkeys so they don't swallow key combos during recording
        appState.hotkeyService.suspend()
    }

    private func stopRecording() {
        isRecording = false
        // Resume Carbon hotkeys
        appState.hotkeyService.resume()
    }

    private func handleKeyEvent(_ event: NSEvent) {
        // Escape with no modifiers cancels recording (only from keyDown / performKeyEquivalent)
        if event.type != .flagsChanged
            && event.keyCode == 53
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            Task { @MainActor in
                stopRecording()
            }
            return
        }

        let newKeyCode = event.keyCode

        // Modifier-only hotkey: the keyCode IS the modifier key.
        // Store the key code as-is and clear modifiers — the modifier IS the key,
        // so there is no additional modifier to hold down.
        if event.type == .flagsChanged && ModifierKeyCodes.isModifierOnly(newKeyCode) {
            Task { @MainActor in
                keyCode = newKeyCode
                modifiers = []
                stopRecording()
            }
            return
        }

        let newModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        Task { @MainActor in
            keyCode = newKeyCode
            modifiers = newModifiers
            stopRecording()
        }
    }

    private func resetToDefault() {
        keyCode = defaultKeyCode
        modifiers = defaultModifiers
    }
}
