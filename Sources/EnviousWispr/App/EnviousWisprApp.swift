import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

@main
struct EnviousWisprApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  // PR-A of #763: SwiftUI App struct is the composition root. App-owned homes
  // live here as `@State` and are injected into views via `.environment(...)`.
  // AppDelegate is a temporary AppKit adapter holding weak refs to a subset
  // (appState, navigationCoordinator, updateCoordinatorHolder) so its
  // NSApplicationDelegate callbacks can read them. PR-B shrinks AppDelegate
  // further; PR11 deletes AppState.
  @State private var appState: AppState
  @State private var navigationCoordinator: NavigationCoordinator
  @State private var diagnosticsCoordinator: DiagnosticsCoordinator
  @State private var languageSuggestionPresenter: LanguageSuggestionPresenter
  @State private var updateCoordinatorHolder: UpdateCoordinatorHolder
  // PR6 of #763: TranscriptWorkflowCoordinator owns re-polish workflow.
  // Holds references to AppState's TranscriptCoordinator + TranscriptPolishService
  // (Shape 4 cascade: those references' storage stays on AppState until
  // PR9/PR11 absorb their pipeline/PSS/custom-words callers).
  @State private var transcriptWorkflowCoordinator: TranscriptWorkflowCoordinator

  @State private var isOnboardingPresented: Bool =
    !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")

  init() {
    // Construct App-owned homes in dependency order. Closure-capture targets
    // (overlay) must exist before the closures are built; AppState's chip
    // handlers must be wired exactly once.
    let appState = AppState()
    let navigationCoordinator = NavigationCoordinator()
    let diagnosticsCoordinator = DiagnosticsCoordinator()

    // PR4 of #763 construction-order constraint preserved: LanguageSuggestionPresenter
    // captures `appState.recordingOverlay` through narrow closures. Build
    // overlay reference first, then presenter, then attach to AppState.
    let overlay = appState.recordingOverlay
    let languageSuggestionPresenter = LanguageSuggestionPresenter(
      showOverlay: { [weak overlay] intent in overlay?.show(intent: intent) },
      readCurrentIntent: { [weak overlay] in overlay?.currentIntent ?? .hidden },
      // Silent hide for chip dismissal — bypasses the .hidden case's
      // "Recording complete" AX announcement (PR4 Codex code-diff r5 [P3]).
      hideOverlay: { [weak overlay] in overlay?.hide() }
    )
    // Setter injection: appState now holds a reference to the presenter for
    // dispatching from its chip-handler closure and pipeline state-change closures.
    appState.attachLanguageSuggestionPresenter(languageSuggestionPresenter)
    // Wire RecordingOverlayPanel chip handler closures into the presenter.
    // PR9/PR10 absorb these along with the rest of AppState's chip dispatching.
    appState.recordingOverlay.setPassiveChipHandlers(
      onLock: { [weak appState, presenter = languageSuggestionPresenter] in
        if let lang = presenter.accept(), let appState = appState {
          // Capture prior mode for telemetry before mutating settings.
          let priorMode = appState.settings.languageMode
          let fromLang: String
          switch priorMode {
          case .auto: fromLang = "auto"
          case .locked(let prev): fromLang = prev
          }
          appState.settings.languageMode = .locked(lang)
          // PR4 Codex code-diff r6 [P2]: chip-driven locks must emit the same
          // language.manual_lock_used event as Settings-driven locks so the
          // chip CTA is visible in analytics. "after_bad_detect" is the
          // reserved reason for this surface (TelemetryService.swift:483).
          TelemetryService.shared.trackManualLockUsed(
            fromLang: fromLang, toLang: lang, reason: "after_bad_detect")
        }
        // presenter.accept() already hid the overlay; no extra hide needed.
      },
      onDismiss: { [presenter = languageSuggestionPresenter] in
        presenter.dismissExplicit()
      },
      onAutoDismiss: { [presenter = languageSuggestionPresenter] generation in
        presenter.autoDismiss(generation: generation)
      }
    )

    let updateCoordinatorHolder = UpdateCoordinatorHolder()

    // PR6 of #763. Build TWC after appState so it can read appState's
    // transcriptCoordinator + polishService refs. Shape 4: TWC holds the
    // references, AppState retains storage through PR6 (cascades out
    // PR9/PR11).
    let transcriptWorkflowCoordinator = TranscriptWorkflowCoordinator(
      transcriptCoordinator: appState.transcriptCoordinator,
      polishService: appState.polishService
    )

    _appState = State(initialValue: appState)
    _navigationCoordinator = State(initialValue: navigationCoordinator)
    _diagnosticsCoordinator = State(initialValue: diagnosticsCoordinator)
    _languageSuggestionPresenter = State(initialValue: languageSuggestionPresenter)
    _updateCoordinatorHolder = State(initialValue: updateCoordinatorHolder)
    _transcriptWorkflowCoordinator = State(initialValue: transcriptWorkflowCoordinator)

    // PR-A: push App-owned homes into AppDelegate before any
    // NSApplicationDelegate callback fires. `@NSApplicationDelegateAdaptor`
    // exposes the delegate synchronously here; NSApplication.run() (which
    // dispatches delegate callbacks) starts only after App.init() returns.
    appDelegate.attach(
      appState: appState,
      navigationCoordinator: navigationCoordinator,
      updateCoordinatorHolder: updateCoordinatorHolder
    )

    // Initialize observability (PostHog + Sentry) unconditionally at launch —
    // captures install/open/update lifecycle events, startup crashes, and the
    // full onboarding funnel. Anonymous from first launch.
    ObservabilityBootstrap.initialize()
  }

  var body: some Scene {
    Window(AppConstants.appName, id: "main") {
      UnifiedWindowView()
        .frame(minWidth: 580, minHeight: 400)
        .environment(appState)
        .environment(navigationCoordinator)
        .environment(diagnosticsCoordinator)
        .environment(languageSuggestionPresenter)
        .environment(updateCoordinatorHolder)
        .environment(transcriptWorkflowCoordinator)
        .background(
          ActionWirer(
            appDelegate: appDelegate,
            appState: appState,
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
      .environment(appState)
      .environment(navigationCoordinator)
      .environment(languageSuggestionPresenter)
    }
    .windowResizability(.contentSize)
    .defaultSize(width: 500, height: 550)
  }
}

/// Hidden view that wires SwiftUI environment actions to the AppDelegate.
/// Must live inside a SwiftUI view hierarchy to access @Environment.
private struct ActionWirer: View {
  let appDelegate: AppDelegate
  /// PR-A: App-owned AppState passed in directly. AppDelegate no longer
  /// exposes `appState`; reading it through the delegate would have to go
  /// through its weak ref and risk a stale read during teardown.
  let appState: AppState
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
        if appState.settings.onboardingState != .completed {
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
