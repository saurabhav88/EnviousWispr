import Foundation
import Observation

/// #4325: calls `onIdle` each time "a meeting is active" goes from true to false (recording,
/// stopping and the final pass all finished), so a Universal download asked for during the
/// meeting starts by itself. Reads the WHOLE activity expression (`MeetingCoordinator
/// .isMeetingActive`: phase plus final-pass work), never the phase alone, so stopping the
/// recording does not start a download while the transcript is still being written.
///
/// #4355 PR C: `onActive` fires on the opposite edge (false to true), so the speaker labels load
/// check stops when a meeting starts. A model load already running when that check is stopped
/// finishes on the session's own queue and is dropped unused; recording never waits for it.
///
/// The re-arming observation pattern of `EngineCoordinator.observeInstalledState`: track one read,
/// hop to the main actor on change, re-read, act on the transition, re-arm.
@MainActor
final class MeetingIdleObserver {
  private let isActive: @MainActor () -> Bool
  private let onIdle: @MainActor () -> Void
  private let onActive: @MainActor () -> Void
  private var wasActive: Bool
  /// Test seam: called after each re-read, so a test can change the next value only once the
  /// previous one was seen (observation coalesces changes made before the re-read).
  package var onReadForTests: (@MainActor (Bool) -> Void)?

  init(
    isActive: @escaping @MainActor () -> Bool, onIdle: @escaping @MainActor () -> Void,
    onActive: @escaping @MainActor () -> Void = {}
  ) {
    self.isActive = isActive
    self.onIdle = onIdle
    self.onActive = onActive
    self.wasActive = isActive()
    observe()
  }

  private func observe() {
    withObservationTracking {
      _ = isActive()
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        let active = self.isActive()
        if self.wasActive, !active { self.onIdle() }
        if !self.wasActive, active { self.onActive() }
        self.wasActive = active
        self.observe()  // re-arm (one-shot per fire)
        self.onReadForTests?(active)
      }
    }
  }
}
