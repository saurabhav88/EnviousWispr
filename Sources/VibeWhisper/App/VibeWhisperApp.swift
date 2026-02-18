import SwiftUI

@main
struct VibeWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Main transcript window
        Window("VibeWhisper", id: "main") {
            MainWindowView()
                .environment(appDelegate.appState)
                .background(ActionWirer(appDelegate: appDelegate))
        }
        .defaultSize(width: 500, height: 600)

        // Settings
        Settings {
            SettingsView()
                .environment(appDelegate.appState)
        }
    }
}

/// Hidden view that wires SwiftUI environment actions to the AppDelegate.
/// Must live inside a SwiftUI view hierarchy to access @Environment.
private struct ActionWirer: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                appDelegate.openMainWindowAction = { [openWindow] in
                    openWindow(id: "main")
                }
                appDelegate.openSettingsAction = { [openSettings] in
                    openSettings()
                }
            }
    }
}
