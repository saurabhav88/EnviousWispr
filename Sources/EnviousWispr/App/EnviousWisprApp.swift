import SwiftUI

@main
struct EnviousWisprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("EnviousWispr Local", id: "main") {
            UnifiedWindowView()
                .frame(minWidth: 560, minHeight: 400)
                .environment(appDelegate.appState)
                .background(ActionWirer(appDelegate: appDelegate))
        }
        .defaultSize(width: 820, height: 600)
    }
}

/// Hidden view that wires SwiftUI environment actions to the AppDelegate.
/// Must live inside a SwiftUI view hierarchy to access @Environment.
private struct ActionWirer: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                appDelegate.openMainWindowAction = { [openWindow] in
                    openWindow(id: "main")
                }
            }
    }
}
