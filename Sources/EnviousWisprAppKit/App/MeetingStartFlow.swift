import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// The one route to a meeting Start, shared by the EnviousMeet page and the menu bar (#3972 C5,
/// coverage C5). Nothing changes in onboarding: the first Start that records the call sound
/// first shows EnviousMeet's explainer ("macOS will ask to let EnviousWispr record the sound
/// your Mac plays..."), and only the user's Continue opens the tap that makes macOS ask. A
/// Start without the call sound never waits for it.
///
/// Owns admission and accepted-request provenance. `MeetingCoordinator` still owns capture and its own refusals
/// (dictation hold, disk, microphone), and its `start` already ignores a second Start while one
/// is starting or recording.
@MainActor
@Observable
final class MeetingStartFlow {
  struct Dependencies {
    /// The user finished EnviousMeet's setup (`SettingsManager.meetingOnboardingComplete`,
    /// #4017 O1). Read live at each Start: EnviousMeet records nothing until it is true.
    var isSetUp: @MainActor () -> Bool
    /// Whether to record the call sound (the inverse of "Record only my voice"), read when a Start
    /// is asked for.
    var captureCallSound: @MainActor () -> Bool
    /// The explainer was already read (`SettingsManager.meetingCallSoundExplained`).
    var isExplained: @MainActor () -> Bool
    var markExplained: @MainActor () -> Void
    /// Whether a Start could begin now (`MeetingCoordinator.phase == .idle`).
    var canStart: @MainActor () -> Bool
    /// Starts the meeting with the call-sound choice this flow admitted it with.
    var start:
      @MainActor (MeetingEntryPoint, _ captureCallSound: Bool, _ callApp: CallAppFamily?) async ->
        MeetingCoordinator.StartOutcome
    /// macOS has never been asked for the microphone (read live).
    var microphoneNeedsAsking: @MainActor () -> Bool
    /// `PermissionsService.requestMicrophoneAccessOrOpenSettings()`: the macOS prompt when never
    /// asked, System Settings when refused. Only ever on the user's own Start or Allow.
    var requestMicrophone: @MainActor () async -> Void
    /// Shows the EnviousMeet page, where the explainer is: a menu Start that needs it.
    var showMeetingPage: @MainActor () -> Void
    var acceptedStartNow: @MainActor () -> Date = {
      Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime)
    }
    var acceptedStart: @MainActor (CallDetectionPolicy.AcceptedStart) -> Void = { _ in }
    var settledStart: @MainActor (CallDetectionPolicy.AcceptedStart, UUID?) -> Void = { _, _ in }
  }

  /// A Start waiting on the explainer, and where it was asked from: the page shows the
  /// explainer while this is set.
  private(set) var pendingExplainer: MeetingEntryPoint?
  /// The call-sound choice the pending request asked for itself (a DEBUG command), or nil when
  /// it follows the setting.
  private var pendingCallSound: Bool?
  /// The call app of the Start waiting on the explainer (#4012 r11 F6), so it keeps its name.
  private var pendingCallApp: CallAppFamily?

  /// What one request did.
  enum Outcome: Equatable {
    /// The coordinator was asked to start; its own outcome.
    case started(MeetingCoordinator.StartOutcome)
    /// Waiting on the call-sound explainer's Continue (shown on the page).
    case waitingForExplainer
    /// Another request is waiting on the macOS microphone prompt; this one joined it.
    case joinedMicrophonePrompt
    /// Cancelled or replaced while the microphone prompt was up.
    case cancelled
    /// A meeting is starting, recording or stopping.
    case notIdle
    /// EnviousMeet's setup is not finished (#4017): nothing started, and the EnviousMeet page,
    /// where the setup runs, was shown.
    case setupRequired
    /// A Start for a detected call that would need a macOS prompt or the call-sound explainer
    /// first (#4012 R5): nothing started, nothing was asked, no window opened. The caller
    /// offers "Open EnviousMeet".
    case needsAttention
  }

  /// A Start waiting on the macOS microphone prompt, and where it was asked from. While it is
  /// set, another Start joins it instead of asking again (#3972 C5b review r2).
  private(set) var waitingForMicrophone: MeetingEntryPoint?
  /// Counts reserved Starts and cancellations, so a Start that comes back from the prompt after
  /// it was cancelled or replaced starts nothing.
  private var startGeneration = 0
  @ObservationIgnored private var acceptedRequest: CallDetectionPolicy.AcceptedStart?

  private let deps: Dependencies

  init(dependencies: Dependencies) {
    deps = dependencies
  }

  /// A Start from the page or the menu. When the explainer is due, the Start waits for
  /// `continueAfterExplainer()`; the menu also brings the page forward.
  /// `captureCallSound` overrides the setting for this request only (a DEBUG command); nil
  /// follows the setting, as the page and the menu do.
  @discardableResult
  func requestStart(
    from entryPoint: MeetingEntryPoint, captureCallSound override: Bool? = nil,
    callApp: CallAppFamily? = nil
  ) async -> Outcome
  {
    // Setup first (#4017 R4): before any prompt, pending state or recording.
    guard admitSetup() else { return .setupRequired }
    // A detected call never opens a macOS prompt or the explainer by itself (#4012 R5).
    if entryPoint == .detected {
      guard deps.canStart() else { return .notIdle }
      let wouldExplain = (override ?? deps.captureCallSound()) && !deps.isExplained()
      guard !deps.microphoneNeedsAsking(), !wouldExplain else { return .needsAttention }
    }
    // A Start already waiting on the microphone prompt owns this request: the first entry
    // point is kept and macOS is asked once.
    guard waitingForMicrophone == nil else { return .joinedMicrophonePrompt }
    guard deps.canStart() else { return .notIdle }
    var entryPoint = entryPoint
    // A microphone macOS never asked about is asked about now, on this Start; the Start then
    // goes on only if it is still the current one and nothing else began meanwhile. A refusal
    // is the coordinator's to report.
    if deps.microphoneNeedsAsking() {
      startGeneration += 1
      let generation = startGeneration
      waitingForMicrophone = entryPoint
      await deps.requestMicrophone()
      guard generation == startGeneration, let owner = waitingForMicrophone else {
        return .cancelled
      }
      // Setup may have been reset while macOS asked (a DEBUG command): the same check again.
      guard admitSetup() else { return .setupRequired }
      waitingForMicrophone = nil
      entryPoint = owner
      guard deps.canStart() else { return .notIdle }
    }
    // The call-sound choice is read once: the explainer decision and the recording use it.
    let captureCallSound = override ?? deps.captureCallSound()
    if captureCallSound, !deps.isExplained() {
      // A second request while the explainer shows keeps the first one's entry point.
      if pendingExplainer == nil {
        pendingExplainer = entryPoint
        pendingCallSound = override
        pendingCallApp = callApp
      }
      if entryPoint == .menu { deps.showMeetingPage() }
      return .waitingForExplainer
    }
    // A Start that needs no explainer (the call sound was switched off, or the explainer was
    // read elsewhere) also ends any request still waiting on it, so a later Continue starts
    // nothing.
    pendingExplainer = nil
    pendingCallSound = nil
    pendingCallApp = nil
    return await startAccepted(from: entryPoint, captureCallSound: captureCallSound, callApp: callApp)
  }

  /// #4012: whether a detected Start would stop at `.needsAttention` or `.setupRequired` (setup,
  /// a macOS prompt, or the explainer). A switch to a new call checks this BEFORE it stops the
  /// meeting recording now, so a Yes never leaves nothing recording. Asks and shows nothing.
  func detectedStartIsBlocked() -> Bool {
    !deps.isSetUp() || deps.microphoneNeedsAsking()
      || (deps.captureCallSound() && !deps.isExplained())
  }

  /// The notice's Allow Microphone: the macOS prompt when never asked, else System Settings.
  /// It starts nothing; the user presses Start again.
  func fixMicrophone() async {
    await deps.requestMicrophone()
  }

  /// The user read the explainer and chose to start. The choices are read again now: a meeting
  /// that began elsewhere meanwhile wins, and a call sound switched off meanwhile makes this a
  /// microphone-only Start that has explained nothing.
  @discardableResult
  func continueAfterExplainer() async -> Outcome {
    // The same setup check as `requestStart` (#4017 R4): Continue is the second way in.
    guard admitSetup() else { return .setupRequired }
    guard let entryPoint = pendingExplainer else { return .cancelled }
    let override = pendingCallSound
    let callApp = pendingCallApp
    pendingExplainer = nil
    pendingCallSound = nil
    pendingCallApp = nil
    guard deps.canStart() else { return .notIdle }
    let captureCallSound = override ?? deps.captureCallSound()
    if captureCallSound { deps.markExplained() }
    return await startAccepted(from: entryPoint, captureCallSound: captureCallSound, callApp: callApp)
  }

  /// One producing/settling path for both direct and explainer-Continue starts. Observation
  /// never owns capture: the coordinator's unchanged outcome is still returned to the caller.
  private func startAccepted(
    from route: MeetingEntryPoint, captureCallSound: Bool, callApp: CallAppFamily?
  ) async -> Outcome {
    if let previous = acceptedRequest { settle(previous, recordingID: nil) }
    startGeneration += 1
    let request = CallDetectionPolicy.AcceptedStart(
      generation: startGeneration, route: route, acceptedAt: deps.acceptedStartNow())
    acceptedRequest = request
    deps.acceptedStart(request)
    let result = await deps.start(route, captureCallSound, callApp)
    let recordingID: UUID?
    if case .recording(let id) = result { recordingID = id } else { recordingID = nil }
    settle(request, recordingID: recordingID)
    return .started(result)
  }

  private func settle(_ request: CallDetectionPolicy.AcceptedStart, recordingID: UUID?) {
    guard acceptedRequest == request else { return }
    acceptedRequest = nil
    deps.settledStart(request, recordingID)
  }

  /// The user closed the explainer without starting, or a Start waiting on the microphone
  /// prompt was called off. Nothing pending may start afterwards; the explainer shows again at
  /// the next Start.
  /// True when setup is finished. Otherwise every pending Start is called off (explainer and
  /// microphone wait), the EnviousMeet page is shown, and the caller returns `.setupRequired`.
  private func admitSetup() -> Bool {
    guard deps.isSetUp() else {
      cancelExplainer()
      deps.showMeetingPage()
      return false
    }
    return true
  }

  func cancelExplainer() {
    if let request = acceptedRequest { settle(request, recordingID: nil) }
    pendingExplainer = nil
    pendingCallSound = nil
    pendingCallApp = nil
    waitingForMicrophone = nil
    startGeneration += 1
  }
}
