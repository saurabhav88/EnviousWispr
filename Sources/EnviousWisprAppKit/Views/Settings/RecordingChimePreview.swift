import EnviousWisprCore
import Foundation

/// One Chimes preview: the clicked card's start cue, the gap, then its stop cue (#3385).
///
/// Stateless on purpose. The page keeps the ONE stored task
/// (`RecordingSoundsSettingsView.activePreviewTask`); this cancels the task it is handed,
/// builds the replacement and returns it to that field. Playback, the wait and the live
/// dictation-activity read are parameters so a test can drive every branch without sound
/// or a real 550ms wait.
@MainActor
enum RecordingChimePreview {
  /// The pause between the start and stop halves, unchanged from the single Preview button.
  static let gap: Duration = .milliseconds(550)

  /// Cancels `previous`, then returns a task that plays `pairing`'s start cue, waits `gap`
  /// and plays the SAME pairing's stop cue. The pairing is captured here and never reread:
  /// a card's Preview plays that card, not whatever is selected when the stop half runs.
  static func start(
    pairing: RecordingSoundPairing,
    replacing previous: Task<Void, Never>?,
    isDictationActive: @escaping @MainActor () -> Bool,
    play: @escaping RecordingSoundCue.Playback = { pairing, moment in
      RecordingSoundCue.play(pairing: pairing, moment: moment)
    },
    wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) -> Task<Void, Never> {
    previous?.cancel()
    return Task { @MainActor in
      // `.cancel()` only sets a flag; it does not stop this closure from
      // starting. Dictation can start (or the page can disappear) in the gap
      // between task creation and this first line running, so without this
      // check the start cue could still play into a just-started real
      // recording (Codex code-diff review r12, #1618).
      guard !Task.isCancelled, !isDictationActive() else { return }
      guard play(pairing, .start) else { return }
      do {
        try await wait(gap)
      } catch {
        return  // cancelled mid-wait; do not play a stop half for a start that may be stale
      }
      // Re-check immediately before firing stop, belt-and-suspenders
      // alongside the .onChange cancellation above: a real recording may
      // have started during the 550ms wait (the global hotkey works while
      // Settings is open). Firing the preview's stop cue into a live
      // recording would falsely signal that real dictation just stopped
      // (council finding, 2026-07-17; both GPT-5.6 and Gemini-3.1
      // independently caught this race). Reads the LIVE environment value
      // here, not a render-time snapshot.
      //
      // Codex code-diff review r9 additionally flagged that SwiftUI can
      // coalesce a real recording that starts AND fully finishes within this
      // same wait, so neither guard above observes it, and the stop cue
      // plays a moment after a real (already-finished) recording rather than
      // during one. Explicitly NOT defended further (rejected a 25ms poll
      // loop that would have run for the life of every preview): the
      // consequence is one extra soft click after a recording that already
      // ended cleanly, on an optional, off-by-default limb — founder called
      // this disproportionate machinery for the residual risk, 2026-07-17.
      //
      // #3385: moved here verbatim with both guards. "Above" is now
      // `RecordingSoundsSettingsView`'s `.onChange` cancellation, and the
      // live value is the `isDictationActive` closure the page passes in.
      // "Off-by-default" is history: the default is now ON
      // (`SettingsDefaultValues.playRecordingSounds`); the accepted residual
      // race is unchanged.
      guard !Task.isCancelled, !isDictationActive() else { return }
      _ = play(pairing, .stop)
    }
  }
}
