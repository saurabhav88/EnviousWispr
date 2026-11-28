import AVFoundation
import EnviousWisprCore
import Foundation
import os

/// Which half of a pair is playing.
enum RecordingSoundMoment: String, CaseIterable, Sendable {
  case start
  case stop
}

/// Exact-once, per-backend start/stop sound cue (#1342). Tracks which pairing
/// was active when a recording STARTED so the stop cue always matches, even
/// if the user changes the toggle or pairing mid-recording. A pure function
/// cannot do this — the FSM notifications this reads from can repeat or chain
/// (`.transcribing` then later `.complete`), so exact-once needs a snapshot,
/// not a stateless read at each call site.
///
/// **Capture-overlap tradeoff (Codex code-diff review r1).** The start cue
/// necessarily plays WHILE capture is active — that is the point, instant
/// confirmation — and the stop cue can play just before
/// `audioCapture.stopCapture()` finishes, since no public `PipelineState`
/// marks capture teardown complete (traced in the #1342 plan's grounded
/// review). Accepted, not overlooked: both cues are short (90-220ms) and
/// quiet relative to speech, matching how other apps' record start/stop
/// chimes behave; kernel-level teardown-complete plumbing to close this
/// window was evaluated and rejected as unneeded for an "instant
/// acknowledgement" cue. Verified empirically, not just asserted, via the
/// Live UAT cue-contamination check (`docs/feature-requests/issue-1342-*.md`
/// §11.1).
@MainActor
struct RecordingSoundCue {
  enum Backend: CaseIterable, Hashable, Sendable {
    case parakeet
    case whisper
  }

  typealias Playback = @MainActor (
    _ pairing: RecordingSoundPairing,
    _ moment: RecordingSoundMoment
  ) -> Bool

  private typealias BackendPlayback = @MainActor (
    _ pairing: RecordingSoundPairing,
    _ moment: RecordingSoundMoment,
    _ backend: Backend
  ) -> Bool

  /// #1413: an upper bound on every `*_start.wav`, bound by
  /// `RecordingSoundCueTests.recordingSoundAssetIsUsable`. The other-audio hold
  /// waits this long after the start cue is INVOKED before lowering the output,
  /// so the cue is not cut; the longest start asset measures 0.20 s.
  static let longestStartCueSeconds: TimeInterval = 0.25

  private var activePairingByBackend: [Backend: RecordingSoundPairing] = [:]
  private let playback: BackendPlayback

  init() {
    self.init(player: .shared)
  }

  /// Inject a dedicated off-main cue player (production uses `.shared`).
  init(player: RecordingSoundCuePlayer) {
    playback = { pairing, moment, backend in
      player.enqueue(pairing: pairing, moment: moment, backend: backend)
    }
  }

  /// Test seam — inject a synchronous `@MainActor` spy instead of real audio playback.
  init(playback: @escaping Playback) {
    self.playback = { pairing, moment, _ in playback(pairing, moment) }
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
      // Only arm the matching stop cue if the start cue actually played — a
      // failed start (e.g. no audio output available) must never leave a
      // "phantom" session that plays an unmatched stop cue later (Codex
      // code-diff review r3). For async `RecordingSoundCuePlayer`, the worker
      // enforces this same `#1342` invariant via `startedBackends`.
      guard playback(selectedPairing, .start, backend) else { return }
      activePairingByBackend[backend] = selectedPairing
    // #1891: an advisory means the recording ended, so it plays the stop cue
    // exactly like every other non-recording state.
    case .idle, .loadingModel, .transcribing, .polishing, .complete, .error,
      .advisory:
      guard let pairing = activePairingByBackend.removeValue(forKey: backend) else { return }
      _ = playback(pairing, .stop, backend)
    }
  }

  /// Direct, ungated playback for Settings-page preview — deliberately does
  /// NOT go through `handle`/the enabled guard/the snapshot, since preview
  /// must work even while the master toggle is off and previews a SPECIFIC
  /// card, not necessarily the persisted selection.
  @discardableResult
  static func play(pairing: RecordingSoundPairing, moment: RecordingSoundMoment) -> Bool {
    RecordingSoundCuePlayer.shared.enqueue(pairing: pairing, moment: moment, backend: nil)
  }
}

protocol RecordingSoundPlayback: AnyObject {
  var isPlaying: Bool { get }
  func play() -> Bool
}

extension AVAudioPlayer: RecordingSoundPlayback {}

/// Runs cue WAV loading and `AVAudioPlayer` playback on one serial worker queue
/// off `@MainActor` (#4773) so macOS `AudioQueuePrime` / `SpatializationManager`
/// / `AudioComponentRegister` XPC waits cannot freeze the UI. Lazily caches
/// bundled WAV bytes in memory to avoid repeat bundle/disk I/O while keeping
/// zero audio hardware open when idle.
final class RecordingSoundCuePlayer: Sendable {
  static let shared = RecordingSoundCuePlayer()

  private struct State {
    var activePlayers: [any RecordingSoundPlayback] = []
    var startedBackends: Set<RecordingSoundCue.Backend> = []
    var cachedData: [String: Data] = [:]
  }

  private let queue = DispatchQueue(
    label: "com.enviouswispr.recording-sound-cue",
    qos: .userInitiated
  )
  private let state = OSAllocatedUnfairLock(uncheckedState: State())
  private let maxCueDelay: Duration
  private let now: @Sendable () -> ContinuousClock.Instant
  private let loadData: @Sendable (RecordingSoundPairing, RecordingSoundMoment) -> Data?
  private let makePlayer: @Sendable (Data) -> (any RecordingSoundPlayback)?

  init(
    maxCueDelay: Duration = .milliseconds(500),
    now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    loadData: @escaping @Sendable (RecordingSoundPairing, RecordingSoundMoment) -> Data? =
      RecordingSoundCuePlayer.loadBundledData,
    makePlayer: @escaping @Sendable (Data) -> (any RecordingSoundPlayback)? =
      RecordingSoundCuePlayer.makeAVPlayer
  ) {
    self.maxCueDelay = maxCueDelay
    self.now = now
    self.loadData = loadData
    self.makePlayer = makePlayer
  }

  @discardableResult
  func enqueue(
    pairing: RecordingSoundPairing,
    moment: RecordingSoundMoment,
    backend: RecordingSoundCue.Backend?
  ) -> Bool {
    let enqueuedAt = now()
    queue.async { [self] in
      let shouldAttempt = state.withLockUnchecked { s -> Bool in
        guard let backend else { return true }
        switch moment {
        case .start:
          s.startedBackends.remove(backend)
          return true
        case .stop:
          return s.startedBackends.remove(backend) != nil
        }
      }
      guard
        shouldAttempt,
        now() - enqueuedAt <= maxCueDelay,
        let data = resolvedData(pairing, moment),
        now() - enqueuedAt <= maxCueDelay,
        let player = makePlayer(data),
        now() - enqueuedAt <= maxCueDelay,
        player.play()
      else { return }
      // `AVAudioPlayer.play()` is asynchronous; a purely local `player` would be
      // deallocated the instant this closure returns, truncating or silently
      // dropping playback (Codex code-diff review r1). Retain it until a later
      // cue prunes finished players — and only once playback has actually started:
      // if `.play()` returns false (e.g. no audio output available), retaining
      // first would leak the instance and arm a phantom stop cue (#1342, Codex
      // code-diff review r2/r3).
      state.withLockUnchecked { s in
        s.activePlayers.removeAll { !$0.isPlaying }
        s.activePlayers.append(player)
        if moment == .start, let backend {
          s.startedBackends.insert(backend)
        }
      }
    }
    return true
  }

  private func resolvedData(
    _ pairing: RecordingSoundPairing,
    _ moment: RecordingSoundMoment
  ) -> Data? {
    let key = "\(pairing.rawValue)_\(moment.rawValue)"
    if let cached = state.withLockUnchecked({ $0.cachedData[key] }) {
      return cached
    }
    guard let loaded = loadData(pairing, moment) else { return nil }
    state.withLockUnchecked { $0.cachedData[key] = loaded }
    return loaded
  }

  private static func loadBundledData(
    pairing: RecordingSoundPairing,
    moment: RecordingSoundMoment
  ) -> Data? {
    let key = "\(pairing.rawValue)_\(moment.rawValue)"
    guard let url = Bundle.module.url(forResource: key, withExtension: "wav") else { return nil }
    return try? Data(contentsOf: url)
  }

  private static func makeAVPlayer(data: Data) -> (any RecordingSoundPlayback)? {
    guard let player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
    else { return nil }
    player.volume = 1.0
    return player
  }

  #if DEBUG
    func drainForTesting(timeout: TimeInterval = 2) -> Bool {
      let drained = DispatchSemaphore(value: 0)
      queue.async { drained.signal() }
      return drained.wait(timeout: .now() + timeout) == .success
    }

    func hasStartedBackendForTesting(_ backend: RecordingSoundCue.Backend) -> Bool {
      state.withLockUnchecked { $0.startedBackends.contains(backend) }
    }
  #endif
}
