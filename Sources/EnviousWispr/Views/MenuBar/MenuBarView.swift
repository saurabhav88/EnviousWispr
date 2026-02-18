import SwiftUI

/// Menu bar dropdown content using native menu style for reliable click handling.
struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status (read-only label rendered as disabled button for menu compatibility)
        let statusText = "\(appState.pipelineState.statusText) — \(appState.selectedBackend == .parakeet ? "Parakeet v3" : "WhisperKit")"
        Text(statusText)

        Divider()

        // Record / Stop
        Button(appState.pipelineState == .recording ? "Stop Recording" : "Start Recording") {
            Task { await appState.toggleRecording() }
        }
        .disabled(appState.pipelineState.isActive && appState.pipelineState != .recording)

        Divider()

        // Actions
        Button("Open EnviousWispr") {
            openMainWindow()
        }
        .keyboardShortcut("o")

        Button("Settings...") {
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit EnviousWispr") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func openSettings() {
        NSApplication.shared.sendAction(
            Selector(("showSettingsWindow:")),
            to: nil,
            from: nil
        )
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
