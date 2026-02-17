import SwiftUI

@main
struct VibeWhisperApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        // Menu bar presence
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Image(systemName: appState.pipelineState.menuBarIconName)
        }

        // Main transcript window
        Window("VibeWhisper", id: "main") {
            MainWindowView()
                .environment(appState)
        }
        .defaultSize(width: 500, height: 600)

        // Settings
        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
