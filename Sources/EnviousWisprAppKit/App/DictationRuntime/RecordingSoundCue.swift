import AppKit
import EnviousWisprCore
import Foundation

/// Which half of a pair is playing.
enum RecordingSoundMoment: String, CaseIterable {
  case start
  case stop
}

/// Exact-once, per-backend start/stop sound cue (#1342). Tracks which pairing
/// was active when a recording STARTED so the stop cue always matches, even
/// if the user changes the toggle or pairing mid-recording. A pure function
/// cannot do this — the FSM notifications this reads from can repeat or chain
/// (`.transcribing` then later `.complete`), so exact-once needs a snapshot,
/// not a stateless read at each call site.
@MainActor
struct RecordingSoundCue {
  enum Backend: CaseIterable, Hashable {
    case parakeet
    case whisperKit
  }

  typealias Playback = @MainActor (
    _ pairing: RecordingSoundPairing,
    _ moment: RecordingSoundMoment
  ) -> Void

  private var activePairingByBackend: [Backend: RecordingSoundPairing] = [:]
  private let playback: Playback

  init() {
    playback = { pairing, moment in _ = Self.play(pairing: pairing, moment: moment) }
  }

  /// Test seam — inject a spy instead of real `NSSound` playback.
  init(playback: @escaping Playback) {
    self.playback = playback
  }

  /// Call on every `PipelineState` transition for one backend. Fires start
  /// exactly once on entry to `.recording` (state-gated: refuses if this
  /// backend already has an active pairing, rather than re-checking after the
  /// fact). Fires stop exactly once on the FIRST transition away from
  /// `.recording`, to whichever state arrives first — normal stop, direct
  /// cancel, capture stall, or dead-mic all land here identically. Cold-start
  /// `.loadingModel` reachable BEFORE `.recording` is a safe no-op: nothing is
  /// in the dictionary yet to consume.
  mutating func handle(
    _ state: PipelineState,
    backend: Backend,
    enabled: Bool,
    selectedPairing: RecordingSoundPairing
  ) {
    switch state {
    case .recording:
      guard activePairingByBackend[backend] == nil, enabled else { return }
      activePairingByBackend[backend] = selectedPairing
      playback(selectedPairing, .start)
    case .idle, .loadingModel, .transcribing, .polishing, .complete, .error:
      guard let pairing = activePairingByBackend.removeValue(forKey: backend) else { return }
      playback(pairing, .stop)
    }
  }

  /// Direct, ungated playback for Settings-page preview — deliberately does
  /// NOT go through `handle`/the enabled guard/the snapshot, since preview
  /// must work even while the master toggle is off and previews a SPECIFIC
  /// card, not necessarily the persisted selection.
  @discardableResult
  static func play(pairing: RecordingSoundPairing, moment: RecordingSoundMoment) -> Bool {
    let name = "\(pairing.rawValue)_\(moment.rawValue)"
    guard
      let url = Bundle.module.url(forResource: name, withExtension: "wav"),
      let sound = NSSound(contentsOf: url, byReference: true)
    else { return false }
    return sound.play()
  }
}
