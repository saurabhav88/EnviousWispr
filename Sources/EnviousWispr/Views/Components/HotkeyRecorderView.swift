import SwiftUI
import AppKit

/// A reusable view for recording keyboard shortcuts.
/// Click to start recording, press a key combo to set, click again or press Escape to cancel.
struct HotkeyRecorderView: View {
    @Binding var keyCode: UInt16
    @Binding var modifiers: NSEvent.ModifierFlags

    let defaultKeyCode: UInt16
    let defaultModifiers: NSEvent.ModifierFlags
    let label: String

    @State private var isRecording = false
    @State private var localMonitor: Any?
    @State private var globalMonitor: Any?

    var body: some View {
        HStack {
            Text(label)
            Spacer()

            Button(action: toggleRecording) {
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
            }
            .buttonStyle(.plain)

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

        // Local monitor for when app is focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyEvent(event)
            return nil  // Consume the event
        }

        // Global monitor for when app is not focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            handleKeyEvent(event)
        }
    }

    private func stopRecording() {
        isRecording = false

        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        // Escape cancels recording
        if event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            Task { @MainActor in
                stopRecording()
            }
            return
        }

        let newKeyCode = event.keyCode
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

/// A simplified view for recording modifier-only shortcuts (like push-to-talk).
struct ModifierRecorderView: View {
    @Binding var modifier: NSEvent.ModifierFlags

    let defaultModifier: NSEvent.ModifierFlags
    let label: String

    @State private var isRecording = false
    @State private var localMonitor: Any?
    @State private var globalMonitor: Any?

    var body: some View {
        HStack {
            Text(label)
            Spacer()

            Button(action: toggleRecording) {
                HStack(spacing: 4) {
                    if isRecording {
                        Text("Press modifier...")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(KeySymbols.formatModifierOnly(modifier))
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
            }
            .buttonStyle(.plain)

            // Reset button
            if modifier != defaultModifier {
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

        // Monitor for modifier key presses
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlagsEvent(event)
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlagsEvent(event)
        }
    }

    private func stopRecording() {
        isRecording = false

        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    private func handleFlagsEvent(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Only capture single modifiers
        let validModifiers: [NSEvent.ModifierFlags] = [.option, .command, .control, .shift]

        for mod in validModifiers {
            if flags == mod {
                Task { @MainActor in
                    modifier = mod
                    stopRecording()
                }
                return
            }
        }
    }

    private func resetToDefault() {
        modifier = defaultModifier
    }
}
