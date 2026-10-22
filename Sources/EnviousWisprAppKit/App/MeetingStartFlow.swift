import EnviousWisprCore
import Foundation

/// The one route to a meeting Start, shared by the EnviousMeet page and the menu bar (#3972 C5,
/// coverage C5). Nothing changes in onboarding: the first Start that records the call sound
/// first shows EnviousMeet's explainer ("macOS will ask to let EnviousWispr record the sound
/// your Mac plays..."), and only the user's Continue opens the tap that makes macOS ask. A
/// Start without the call sound never waits for it.
///
/// Owns only the explainer step. `MeetingCoordinator` still owns capture and its own refusals
/// (dictation hold, disk, microphone), and its `start` already ignores a second Start while one
/// is starting or recording.
@MainActor
@Observable
final class MeetingStartFlow {
  struct Dependencies {
    /// The user's "Also record the call sound" choice, read when a Start is asked for.
    var captureCallSound: @MainActor () -> Bool
    /// The explainer was already read (`SettingsManager.meetingCallSoundExplained`).
    var isExplained: @MainActor () -> Bool
    var markExplained: @MainActor () -> Void
    /// Whether a Start could begin now (`MeetingCoordinator.phase == .idle`).
    var canStart: @MainActor () -> Bool
    /// Starts the meeting with the call-sound choice this flow admitted it with.
    var start:
      @MainActor (MeetingEntryPoint, _ captureCallSound: Bool) async ->
        MeetingCoordinator.StartOutcome
    /// macOS has never been asked for the microphone (read live).
    var microphoneNeedsAsking: @MainActor () -> Bool
    /// `PermissionsService.requestMicrophoneAccessOrOpenSettings()`: the macOS prompt when never
    /// asked, System Settings when refused. Only ever on the user's own Start or Allow.
    var requestMicrophone: @MainActor () async -> Void
    /// Shows the EnviousMeet page, where the explainer is: a menu Start that needs it.
    var showMeetingPage: @MainActor () -> Void
  }

  /// A Start waiting on the explainer, and where it was asked from: the page shows the
  /// explainer while this is set.
  private(set) var pendingExplainer: MeetingEntryPoint?
  /// The call-sound choice the pending request asked for itself (a DEBUG command), or nil when
  /// it follows the setting.
  private var pendingCallSound: Bool?

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
  }

  /// A Start waiting on the macOS microphone prompt, and where it was asked from. While it is
  /// set, another Start joins it instead of asking again (#3972 C5b review r2).
  private(set) var waitingForMicrophone: MeetingEntryPoint?
  /// Counts reserved Starts and cancellations, so a Start that comes back from the prompt after
  /// it was cancelled or replaced starts nothing.
  private var startGeneration = 0

  private let deps: Dependencies

  init(dependencies: Dependencies) {
    deps = dependencies
  }

  /// A Start from the page or the menu. When the explainer is due, the Start waits for
  /// `continueAfterExplainer()`; the menu also brings the page forward.
  /// `captureCallSound` overrides the setting for this request only (a DEBUG command); nil
  /// follows the setting, as the page and the menu do.
  @discardableResult
  func requestStart(from entryPoint: MeetingEntryPoint, captureCallSound override: Bool? = nil)
    async -> Outcome
  {
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
      }
      if entryPoint == .menu { deps.showMeetingPage() }
      return .waitingForExplainer
    }
    // A Start that needs no explainer (the call sound was switched off, or the explainer was
    // read elsewhere) also ends any request still waiting on it, so a later Continue starts
    // nothing.
    pendingExplainer = nil
    pendingCallSound = nil
    return .started(await deps.start(entryPoint, captureCallSound))
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
    guard let entryPoint = pendingExplainer else { return .cancelled }
    let override = pendingCallSound
    pendingExplainer = nil
    pendingCallSound = nil
    guard deps.canStart() else { return .notIdle }
    let captureCallSound = override ?? deps.captureCallSound()
    if captureCallSound { deps.markExplained() }
    return .started(await deps.start(entryPoint, captureCallSound))
  }

  /// The user closed the explainer without starting, or a Start waiting on the microphone
  /// prompt was called off. Nothing pending may start afterwards; the explainer shows again at
  /// the next Start.
  func cancelExplainer() {
    pendingExplainer = nil
    pendingCallSound = nil
    waitingForMicrophone = nil
    startGeneration += 1
  }
}
