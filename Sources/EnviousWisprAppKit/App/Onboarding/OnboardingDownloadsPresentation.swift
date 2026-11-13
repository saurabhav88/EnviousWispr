import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// What Downloads and Getting ready show, as plain values (#4528 D4a, plan M83). Built by one
/// pure mapping from the existing owners' facts; nothing here decides, schedules or stores.
/// Read inside a view body, the live sources it comes from (the observable coordinator and
/// runtime, and the delivery and local polish owners' own published state) redraw the screen
/// when any of them changes, including progress-only and slow-network changes.
struct OnboardingDownloadsPresentation: Equatable, Sendable {
  /// Where the picked AI polish stands for these screens.
  enum PolishPreparation: Equatable, Sendable {
    /// No polish choice yet.
    case none
    /// Explicitly turned off (Skip AI polish, or Continue without AI polish).
    case off
    /// Apple Intelligence: nothing to download; `available` is the current live answer.
    case appleIntelligence(available: Bool)
    /// A cloud provider: nothing to download; `passed` is the current key check for the picked
    /// provider and model (stored keys or old answers never pass).
    case cloud(passed: Bool)
    /// A local model waiting for the speech download to finish first.
    case queued
    /// A local model not on this Mac and not transferring (owner not answered, not started).
    case waiting
    /// A local model transferring or verifying.
    case downloading
    /// A local model whose download stopped (paused, failed or unavailable): `phase` says which.
    case downloadStopped
    /// Installed, its helper not ready yet and not failing.
    case loading
    /// Installed and loaded for the current pick.
    case ready
    /// Installed, and its owner reports a failed load (Try again or continue without polish).
    case failed
  }

  var speech: ASRBackendType?
  var speechPhase: OnboardingDownloadPhase?
  var polish: String?
  /// Nil for a pick that downloads nothing.
  var polishPhase: OnboardingDownloadPhase?
  var polishPreparation: PolishPreparation
  /// The coordinator's preflight or refusal block (disk short carries the measured need).
  var block: OnboardingDownloadBlock?
  var engineWarm: Bool
  var warmFailed: Bool
  var microphoneGranted: Bool
  var accessibilityGranted: Bool
  /// Every required download for the current picks is on this Mac.
  var downloadsFinished: Bool
  var isNetworkSlow: Bool
  /// The runtime is counting down to move on ("Taking you to the next step").
  var isCountingDown: Bool

  static func make(
    state: OnboardingFlowState, block: OnboardingDownloadBlock?, warmFailed: Bool,
    queuedPolish: String?, isNetworkSlow: Bool, isCountingDown: Bool,
    speechPhase: (ASRBackendType) -> OnboardingDownloadPhase,
    polishPhase: (String) -> OnboardingDownloadPhase?, downloadsFinished: Bool,
    speechStartPending: Bool = false,
    polishStartRequested: (String) -> Bool = { _ in false }
  ) -> OnboardingDownloadsPresentation {
    let choices = state.choices
    let readiness = state.readiness
    let speech = choices.speech
    let polish = choices.polish
    let localPhase = polish.flatMap(polishPhase)
    let ownerSpeechPhase = speech.map(speechPhase)
    // A missing model can be idle after a cancelled or synthetic attempt. Only the
    // coordinator knows whether a start is still pending while the owner reads notStarted.
    let presentedSpeechPhase: OnboardingDownloadPhase? =
      ownerSpeechPhase == .notStarted && !speechStartPending ? .paused : ownerSpeechPhase
    return OnboardingDownloadsPresentation(
      speech: speech, speechPhase: presentedSpeechPhase, polish: polish,
      polishPhase: localPhase,
      polishPreparation: preparation(
        polish: polish, readiness: readiness, phase: localPhase, queued: queuedPolish,
        startRequested: polish.map(polishStartRequested) ?? false),
      block: block,
      engineWarm: speech != nil && readiness.speech == speech && readiness.engineWarm,
      warmFailed: warmFailed, microphoneGranted: readiness.microphoneGranted,
      accessibilityGranted: readiness.accessibilityGranted, downloadsFinished: downloadsFinished,
      isNetworkSlow: isNetworkSlow, isCountingDown: isCountingDown)
  }

  /// One mapping, in priority order: an owner-reported failure, then readiness for the CURRENT
  /// pick, then the transfer phase. Readiness for another pick never counts.
  static func preparation(
    polish: String?, readiness: OnboardingReadiness, phase: OnboardingDownloadPhase?,
    queued: String?, startRequested: Bool = false
  ) -> PolishPreparation {
    guard let polish else { return .none }
    if polish == OnboardingChoices.polishOff { return .off }
    let current = readiness.polish == polish
    if polish == OnboardingChoices.polishCloud {
      return .cloud(passed: current && readiness.polishReady)
    }
    guard let phase else {
      // Not a local model: Apple Intelligence (the only other registered pick).
      return .appleIntelligence(available: current && readiness.polishReady)
    }
    if current, readiness.polishFailed { return .failed }
    if current, readiness.polishReady { return .ready }
    switch phase {
    case .installed: return .loading
    case .downloading, .verifying: return .downloading
    case .paused, .failed, .unavailable: return .downloadStopped
    case .unknown: return queued == polish ? .queued : .waiting
    // Missing and idle: queued behind speech, just requested this visit (the owner has not
    // published its phase yet), or idle for real (a relaunch after a disk refusal, a cancel),
    // which must show the stopped card's Resume, Change and Continue without actions (D6).
    case .notStarted:
      if queued == polish { return .queued }
      return startRequested ? .waiting : .downloadStopped
    }
  }
}
