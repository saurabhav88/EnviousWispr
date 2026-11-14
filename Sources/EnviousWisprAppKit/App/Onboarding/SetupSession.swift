import EnviousWisprServices
import Foundation

/// The app's lazy Setup workflow. Window attachment and visits may end while the flow and its
/// downloads continue. Only the coordinator writes flow choices and checkpoints.
@MainActor
final class SetupSession {
  struct Components {
    let coordinator: OnboardingCoordinator
    let runtime: OnboardingRuntime
    /// Setup telemetry, attached to the runtime and mounted screen model.
    var telemetry: OnboardingTelemetryObserver? = nil
    /// The owners' download phase for the current picks, read for `status` only (I1).
    var downloadPhases: ((OnboardingChoices) -> (
      speech: OnboardingDownloadPhase?, polish: OnboardingDownloadPhase?
    ))? = nil
    /// Live owners used by the Setup screens.
    var screenSources = SetupScreenSources()
    /// Brings the app forward when the Setup screens show (`ApplicationActivating`, the
    /// desktop-effects owner); nil leaves activation alone (tests).
    var activateApp: (@MainActor () -> Void)? = nil
    /// Downloads and Getting ready's typed picture from the live owners (D4a, M83).
    var downloadsPresentation: (@MainActor () -> OnboardingDownloadsPresentation)? = nil
    /// Asks each speech engine's owner, read-only, whether it is installed (the same
    /// `speechInstalled` query Setup's readiness uses), so the catalog can answer Parakeet's
    /// upgrade-aware "installed" with no pick (I1, plan M69). Never selects or downloads.
    var resolveInstalled: (@MainActor () async -> Void)? = nil
  }

  private let makeComponents: (SetupSession) -> Components
  private let progress: OnboardingProgress?
  private let permissions: PermissionsService?
  private let everCompleted: () -> Bool
  private(set) var components: Components?
  private(set) var ownsVisit = false
  let presenter = SetupWindowPresenter()
  var onCompleted: (() -> Void)?
  var onProgrammaticDismissal: (() -> Void)?
  #if DEBUG
    var onDebugEnd: (() -> Void)?
  #endif

  init(
    progress: OnboardingProgress? = nil, permissions: PermissionsService? = nil,
    everCompleted: @escaping () -> Bool = { false },
    makeComponents: @escaping (SetupSession) -> Components
  ) {
    self.progress = progress
    self.permissions = permissions
    self.everCompleted = everCompleted
    self.makeComponents = makeComponents
    presenter.onClose = { [weak self] in self?.endVisit(reason: "window_closed") }
  }

  @discardableResult
  func begin() -> Bool {
    let components = ensureComponents()
    guard components.coordinator.begin() else { return false }
    #if DEBUG
      if onDebugEnd != nil { beginVisit() }
    #endif
    components.runtime.start()
    return true
  }

  func reset() {
    let components = ensureComponents()
    components.screenSources.filmPlayback?.clear()
    components.screenSources.practiceProgress?.reset()
    if components.runtime.isRunning {
      components.runtime.reset()
    } else {
      components.coordinator.reset()
      components.runtime.start()
    }
    #if DEBUG
      if onDebugEnd != nil { beginVisit() }
    #endif
  }

  func present() {
    guard let components, components.coordinator.isActive else { return }
    beginVisit()
    var sources = components.screenSources
    let runtime = components.runtime
    let coordinator = components.coordinator
    sources.recheckAppleIntelligence = { [weak runtime] in runtime?.recheckAppleIntelligence() }
    sources.downloads = components.downloadsPresentation
    sources.closeSetup = { [weak self] in self?.closeWindow() }
    sources.downloadActions = SetupDownloadActions(
      retryDownloads: { [weak coordinator] in coordinator?.retryDownloads() },
      cancelDownloads: { [weak coordinator] in coordinator?.cancelDownloads() },
      retryWarmup: { [weak coordinator] in coordinator?.retryWarmup() },
      retryPolish: { [weak coordinator] in coordinator?.retryPolish() })
    presenter.show(
      coordinator: coordinator, telemetry: components.telemetry, sources: sources,
      activateApp: components.activateApp,
      downloadsVisible: { [weak runtime] in runtime?.setDownloadsScreenVisible($0) })
  }

  private func closeWindow() {
    presenter.dismiss()
    endVisit(reason: "window_closed")
    onProgrammaticDismissal?()
  }

  func stop(reason: String) {
    if let components, components.runtime.isRunning || components.coordinator.isActive {
      components.runtime.quit()
    }
    endVisit(reason: reason)
    let wasVisible = presenter.isVisible
    releasePresentation()
    if wasVisible, reason != "app_quit" { onProgrammaticDismissal?() }
    #if DEBUG
      onDebugEnd?()
    #endif
  }

  func complete() {
    components?.runtime.stop()
    if ownsVisit { progress?.markCompleted() }
    ownsVisit = false
    releasePresentation()
    #if DEBUG
      onDebugEnd?()
    #endif
    onCompleted?()
  }

  private func releasePresentation() {
    presenter.dismiss()
    components?.screenSources.practiceProgress?.reset()
  }

  private func ensureComponents() -> Components {
    if let components { return components }
    let built = makeComponents(self)
    components = built
    return built
  }

  private func beginVisit() {
    guard let progress, !ownsVisit, !progress.isInFlight else { return }
    progress.begin(source: everCompleted() ? "diagnostics_restart" : "first_run")
    ownsVisit = true
  }

  private func endVisit(reason: String) {
    guard ownsVisit else { return }
    components?.telemetry?.visitEnded()
    progress?.emitAbandonIfInFlight(
      reason: reason, micStatus: permissions?.microphoneStatusString ?? "unknown",
      accessibilityStatus: (permissions?.accessibilityGrantedLive ?? false) ? "granted" : "denied")
    ownsVisit = false
  }
}
