import EnviousWisprAudio
import EnviousWisprCore

/// #4841: which silent-mic notice the pill should show while recording.
enum MicSilenceLevel: Equatable, Sendable {
  /// No notice: sound is arriving, the run is too short, or warnings are off.
  case none
  /// "We're not hearing anything from your microphone."
  case calm
  /// "Your microphone isn't sending sound. Stop and check it in Settings."
  case strong
}

/// #4841: the pure silent-mic notice policy. One owner for the thresholds; the
/// run length and the since-start test come only from the capture layer's
/// `ExactZeroRun` (drained pre-roll already excluded there). It never ends a take
/// and knows nothing about the recording lifecycle or the overlay.
enum SilentMicNoticePolicy {
  static func level(for run: ExactZeroRun?, warningsEnabled: Bool) -> MicSilenceLevel {
    guard warningsEnabled, let run, run.sampleCount > 0 else { return .none }
    if run.sampleCount >= AudioConstants.silentMicStrongSamples { return .strong }
    let calmThreshold =
      run.sinceTakeStart
      ? AudioConstants.silentMicCalmSinceStartSamples
      : AudioConstants.silentMicCalmMidTakeSamples
    return run.sampleCount >= calmThreshold ? .calm : .none
  }
}

/// #4841: what the tracker needs from the overlay. `OverlayDirector` conforms; tests use
/// a recorder. Every post and clear names the recording presentation it is for.
@MainActor
protocol SilentMicNoticeOverlay: AnyObject {
  var currentRecordingPresentationID: PresentationID? { get }
  var currentInPanelNoticeKind: RecordingNoticeKind? { get }
  @discardableResult
  func showInPanelNotice(
    _ reason: RecordingNoticeReason, dismissAfter: Double?, on presentation: PresentationID
  ) -> PresentationID?
  @discardableResult
  func clearInPanelNotice(_ kind: RecordingNoticeKind, on presentation: PresentationID) -> Bool
}

extension OverlayDirector: SilentMicNoticeOverlay {}

/// #4841: drives the silent-mic notice for ONE running take. Started at actual recording
/// entry with that take's frozen config, bound to the take, its capture session and the
/// recording pill on screen; it polls the capture layer's exact-zero run every 250 ms and
/// posts only on a level change. Any post or clear is fenced by the bound pill, and the
/// binding ends the moment the take's capture session or pill is no longer current.
///
/// Competition: a timed notice (Secure Input, auto-stop unavailable) keeps its full dwell;
/// once it expires the current silence level shows again on the next poll. The persistent
/// 60-minute warning is never replaced. A clear is sent only for this tracker's own notice
/// when sound returns, and only then is the take recorded as "cleared".
@MainActor
final class SilentMicNoticeTracker {
  struct Binding: Equatable {
    let takeID: String
    let captureSessionID: UInt64
    let presentation: PresentationID
    let warningsEnabled: Bool
  }

  private let readRun: @MainActor () -> ExactZeroRun?
  private let currentCaptureSessionID: @MainActor () -> UInt64
  private weak var overlay: (any SilentMicNoticeOverlay)?
  private let recordNotice: @MainActor (_ takeID: String, _ strong: Bool) -> Void
  private let recordCleared: @MainActor (_ takeID: String) -> Void
  private let pause: @Sendable () async -> Void
  /// False only in tests that step `tick()` by hand, so no background poll runs.
  private let startsPolling: Bool

  private(set) var binding: Binding?
  /// The level this tracker last had ACCEPTED on the bound pill.
  private(set) var shownLevel: MicSilenceLevel = .none
  private var pollTask: Task<Void, Never>?

  /// The poll interval. Production passes nothing.
  static let interval: Duration = .milliseconds(250)

  init(
    readRun: @escaping @MainActor () -> ExactZeroRun?,
    currentCaptureSessionID: @escaping @MainActor () -> UInt64,
    overlay: any SilentMicNoticeOverlay,
    recordNotice: @escaping @MainActor (_ takeID: String, _ strong: Bool) -> Void,
    recordCleared: @escaping @MainActor (_ takeID: String) -> Void,
    pause: @escaping @Sendable () async -> Void = {
      try? await Task.sleep(for: SilentMicNoticeTracker.interval)
    },
    startsPolling: Bool = true
  ) {
    self.startsPolling = startsPolling
    self.readRun = readRun
    self.currentCaptureSessionID = currentCaptureSessionID
    self.overlay = overlay
    self.recordNotice = recordNotice
    self.recordCleared = recordCleared
    self.pause = pause
  }

  /// Bind to the take now recording. Re-binding the same take (a repeated `.recording`
  /// state, a hands-free lock) keeps the running poll; a different take replaces it.
  func start(takeID: String, warningsEnabled: Bool) {
    guard binding?.takeID != takeID else { return }
    stop()
    guard warningsEnabled, let presentation = overlay?.currentRecordingPresentationID else {
      return
    }
    binding = Binding(
      takeID: takeID, captureSessionID: currentCaptureSessionID(), presentation: presentation,
      warningsEnabled: warningsEnabled)
    guard startsPolling else { return }
    let pause = self.pause
    // The poll holds the tracker only for one tick, never across the pause, so releasing the
    // coordinator that owns it ends the loop.
    pollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard self?.pollOnce() == true else { return }
        await pause()
      }
    }
  }

  /// End tracking (the take stopped, was cancelled, or capture went away). Never clears a
  /// notice: the pill that carried it is leaving with the take.
  func stop() {
    pollTask?.cancel()
    pollTask = nil
    binding = nil
    shownLevel = .none
  }

  /// One tick; true while still bound.
  private func pollOnce() -> Bool {
    guard binding != nil else { return false }
    tick()
    return binding != nil
  }

  /// One poll. Internal so tests drive it step by step with literal inputs.
  func tick() {
    guard let binding, let overlay else { return }
    // The take's capture session or pill is no longer current: this tracker is stale.
    guard currentCaptureSessionID() == binding.captureSessionID,
      overlay.currentRecordingPresentationID == binding.presentation
    else {
      stop()
      return
    }
    // No reading means capture stopped or was interrupted (device loss) while the IDs still
    // match. That is not sound returning: end tracking and record no clear.
    guard let run = readRun() else {
      stop()
      return
    }
    let level = SilentMicNoticePolicy.level(for: run, warningsEnabled: binding.warningsEnabled)
    let kind = overlay.currentInPanelNoticeKind

    guard level != .none else {
      // Sound returned. Clear only our own notice; if another notice replaced it, ours is
      // already gone and the take is not recorded as cleared.
      if shownLevel != .none, kind == .micSilent,
        overlay.clearInPanelNotice(.micSilent, on: binding.presentation)
      {
        recordCleared(binding.takeID)
      }
      shownLevel = .none
      return
    }

    // Another notice holds the field: the cap warning always wins, and a timed notice keeps
    // its full dwell. Ours shows again on the poll after it leaves.
    if let kind, kind != .micSilent {
      shownLevel = .none
      return
    }
    guard kind != .micSilent || shownLevel != level else { return }
    if overlay.showInPanelNotice(.micSilent(level), dismissAfter: nil, on: binding.presentation)
      != nil
    {
      shownLevel = level
      recordNotice(binding.takeID, level == .strong)
    }
  }
}
