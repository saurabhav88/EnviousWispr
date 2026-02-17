import SwiftUI

/// Menu bar dropdown content.
struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 8) {
            // Status
            Label(appState.pipelineState.statusText, systemImage: appState.pipelineState.menuBarIconName)
                .font(.headline)

            Divider()

            // Backend indicator
            Text("Backend: \(appState.selectedBackend == .parakeet ? "Parakeet v3" : "WhisperKit")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // Actions
            Button("Open VibeWhisper") {
                openMainWindow()
            }
            .keyboardShortcut("o")

            Button("Settings...") {
                openSettings()
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit VibeWhisper") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
    }

    private func openMainWindow() {
        if let window = NSApplication.shared.windows.first(where: {
            $0.identifier?.rawValue == "main"
        }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func openSettings() {
        NSApplication.shared.sendAction(
            Selector(("showSettingsWindow:")),
            to: nil,
            from: nil
        )
    }
}
