import SwiftUI

@main
struct EnviousWisprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(AppConstants.appName, id: "main") {
            UnifiedWindowView()
                .frame(minWidth: 580, minHeight: 400)
                .environment(appDelegate.appState)
                .background(ActionWirer(appDelegate: appDelegate))
        }
        .defaultSize(width: 820, height: 600)

        // Onboarding window — non-resizable, centered, auto-opens on first launch.
        Window("Setup", id: "onboarding") {
            OnboardingView(onComplete: {
                appDelegate.closeOnboardingWindow()
            })
            .environment(appDelegate.appState)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 500, height: 550)
    }
}

/// Hidden view that wires SwiftUI environment actions to the AppDelegate.
/// Must live inside a SwiftUI view hierarchy to access @Environment.
private struct ActionWirer: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                appDelegate.openMainWindowAction = { [openWindow] in
                    openWindow(id: "main")
                }
                appDelegate.openOnboardingWindowAction = { [openWindow] in
                    openWindow(id: "onboarding")
                }
                appDelegate.dismissOnboardingWindowAction = { [dismissWindow] in
                    dismissWindow(id: "onboarding")
                }
                // Auto-open onboarding if needed (first launch).
                // ActionWirer runs inside the main Window scene which is always created,
                // so the callbacks are wired before we attempt to open the onboarding window.
                if appDelegate.appState.settings.onboardingState != .completed {
                    appDelegate.openOnboardingWindow()
                }
            }
    }
}
