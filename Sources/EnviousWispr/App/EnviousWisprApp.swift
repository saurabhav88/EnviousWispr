import SwiftUI
import EnviousWisprCore
import TelemetryDeck

@main
struct EnviousWisprApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var isOnboardingPresented: Bool =
        !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

    init() {
        // Only initialize TelemetryDeck if the user has completed onboarding.
        // Onboarding says "No account, no tracking" — honour that promise.
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            let config = TelemetryDeck.Config(appID: "30801A60-9339-4313-8ACE-CC294B2A3EEA")
            TelemetryDeck.initialize(config: config)
        }
    }

    var body: some Scene {
        Window(AppConstants.appName, id: "main") {
            UnifiedWindowView()
                .frame(minWidth: 580, minHeight: 400)
                .environment(appDelegate.appState)
                .background(
                    ActionWirer(
                        appDelegate: appDelegate,
                        isOnboardingPresented: $isOnboardingPresented
                    )
                )
        }
        .defaultSize(width: 820, height: 600)

        // Onboarding window — non-resizable, centered, auto-opens on first launch.
        Window(AppConstants.onboardingWindowTitle, id: "onboarding") {
            OnboardingV2View(onComplete: {
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
    @Binding var isOnboardingPresented: Bool
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                appDelegate.openMainWindowAction = { [openWindow] in
                    openWindow(id: "main")
                }
                appDelegate.openOnboardingAction = { [openWindow] in
                    openWindow(id: "onboarding")
                }
                appDelegate.dismissOnboardingAction = { [dismissWindow] in
                    dismissWindow(id: "onboarding")
                }
                // Auto-open onboarding if needed (first launch).
                // ActionWirer runs inside the main Window scene which is always created,
                // so the callbacks are wired before we attempt to open the onboarding window.
                if appDelegate.appState.settings.onboardingState != .completed {
                    appDelegate.openOnboardingWindow()
                }
            }
            .onChange(of: isOnboardingPresented) { _, newValue in
                if !newValue {
                    // State-driven dismissal: binding flipped to false → close window.
                    dismissWindow(id: "onboarding")
                    NSApp.setActivationPolicy(.accessory)
                    appDelegate.updateIcon()
                }
            }
    }
}
