import AVFoundation
import EnviousWisprCore
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit

/// #1342 — resource validation plus the exact-once lifecycle behavior of
/// `RecordingSoundCue`. All lifecycle tests inject a spy via
/// `RecordingSoundCue.init(playback:)`; none play real audio.
@MainActor
@Suite("Recording sound cue")
struct RecordingSoundCueTests {

  // MARK: - Catalog order

  @Test("catalog declares all twelve pairings in the founder-approved loudest-last order (#1618)")
  func pairingCatalogOrderMatchesApprovedSequence() {
    #expect(
      RecordingSoundPairing.allCases.map(\.rawValue) == [
        "dustMote", "velvetHush", "mutedConfirm", "whisperTick", "roundPebble",
        "paperTap", "softHush", "lowNod", "cloudPop", "velvetTap", "satinShift", "airGlint",
      ])
  }

  // MARK: - Asset validation

  @Test(
    "every bundled recording-sound WAV decodes, is mono/44.1kHz, short, and non-silent",
    arguments: RecordingSoundPairing.allCases, RecordingSoundMoment.allCases
  )
  func recordingSoundAssetIsUsable(
    pairing: RecordingSoundPairing,
    moment: RecordingSoundMoment
  ) throws {
    let name = "\(pairing.rawValue)_\(moment.rawValue)"
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: "wav"),
      "missing bundled resource for \(name)")
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let duration = Double(file.length) / format.sampleRate

    #expect(format.channelCount == 1)
    #expect(format.sampleRate == 44_100)
    #expect((0.05...0.30).contains(duration))
    // #1413: the other-audio hold delays its apply by this constant so the start
    // cue is never cut. A start asset longer than it would be muted mid-cue.
    if moment == .start {
      #expect(duration <= RecordingSoundCue.longestStartCueSeconds)
    }

    let buffer = try #require(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = try #require(buffer.floatChannelData?[0])
    let count = Int(buffer.frameLength)
    var peak: Float = 0
    var sumSquares: Float = 0
    for index in 0..<count {
      let sample = abs(samples[index])
      peak = max(peak, sample)
      sumSquares += sample * sample
    }
    let rms = sqrt(sumSquares / Float(max(count, 1)))

    #expect(rms > 0.001, "\(name) is effectively silent")
    #expect(peak > 0.02, "\(name) has no meaningful signal")
    #expect(peak < 0.98, "\(name) is clipping")
  }

  // MARK: - Lifecycle

  @Test("start fires exactly once per recording, snapshotting the pairing active at that moment")
  func cuesAreExactOnceAndSnapshotThePairing() {
    for backend in RecordingSoundCue.Backend.allCases {
      var events: [String] = []
      var cue = RecordingSoundCue { pairing, moment in
        events.append("\(pairing.rawValue):\(moment.rawValue)")
        return true
      }

      cue.handle(.idle, backend: backend, enabled: true, selectedPairing: .airGlint)
      #expect(events.isEmpty)

      cue.handle(.recording, backend: backend, enabled: true, selectedPairing: .airGlint)
      // A second `.recording` notification (repeat/duplicate) must not re-fire start.
      cue.handle(.recording, backend: backend, enabled: true, selectedPairing: .velvetTap)
      // Live setting change mid-recording must not affect the already-fired start
      // or retroactively change what the stop cue plays.
      cue.handle(.transcribing, backend: backend, enabled: false, selectedPairing: .velvetTap)
      cue.handle(.polishing, backend: backend, enabled: false, selectedPairing: .velvetTap)
      cue.handle(.complete, backend: backend, enabled: false, selectedPairing: .velvetTap)

      #expect(events == ["airGlint:start", "airGlint:stop"])
    }
  }

  @Test(
    "a direct .recording → terminal chain (cancel/capture-stall/dead-mic shape) stops exactly once")
  func directRecordingToTerminalStillStopsOnce() {
    var events: [String] = []
    var cue = RecordingSoundCue { pairing, moment in
      events.append("\(pairing.rawValue):\(moment.rawValue)")
      return true
    }

    cue.handle(.recording, backend: .parakeet, enabled: true, selectedPairing: .cloudPop)
    cue.handle(.idle, backend: .parakeet, enabled: true, selectedPairing: .cloudPop)
    // A later state in the same chain must not re-fire stop.
    cue.handle(.idle, backend: .parakeet, enabled: true, selectedPairing: .cloudPop)

    #expect(events == ["cloudPop:start", "cloudPop:stop"])
  }

  @Test("enabling the setting mid-recording does not retroactively grant an orphaned stop cue")
  func disabledSessionDoesNotGainAStopCueWhenEnabledMidRecording() {
    var events: [String] = []
    var cue = RecordingSoundCue { pairing, moment in
      events.append("\(pairing.rawValue):\(moment.rawValue)")
      return true
    }

    cue.handle(.recording, backend: .whisper, enabled: false, selectedPairing: .airGlint)
    cue.handle(.transcribing, backend: .whisper, enabled: true, selectedPairing: .velvetTap)

    #expect(events.isEmpty)
  }

  @Test(
    "cold-start .loadingModel reachable before any .recording is a safe no-op",
    arguments: RecordingSoundCue.Backend.allCases
  )
  func loadingModelBeforeRecordingDoesNotEmitAStop(backend: RecordingSoundCue.Backend) {
    var events: [String] = []
    var cue = RecordingSoundCue { pairing, moment in
      events.append("\(pairing.rawValue):\(moment.rawValue)")
      return true
    }

    cue.handle(.loadingModel, backend: backend, enabled: true, selectedPairing: .airGlint)
    cue.handle(.recording, backend: backend, enabled: true, selectedPairing: .airGlint)
    cue.handle(.transcribing, backend: backend, enabled: true, selectedPairing: .velvetTap)

    #expect(events.map(\.self) == ["airGlint:start", "airGlint:stop"])
  }

  @Test("a start cue that fails to play never arms an orphaned stop cue")
  func failedStartDoesNotArmAnOrphanedStop() {
    var events: [String] = []
    var cue = RecordingSoundCue { pairing, moment in
      events.append("\(pairing.rawValue):\(moment.rawValue)")
      return false  // simulates no audio output available
    }

    cue.handle(.recording, backend: .parakeet, enabled: true, selectedPairing: .airGlint)
    cue.handle(.transcribing, backend: .parakeet, enabled: true, selectedPairing: .airGlint)

    // The start attempt is observed (it was tried), but since it failed, no
    // stop cue may follow — an unmatched stop is worse than silence.
    #expect(events == ["airGlint:start"])
  }

  @Test(
    "a fast cancel immediately followed by a new recording produces two matched pairs",
    arguments: RecordingSoundCue.Backend.allCases
  )
  func rapidStartCancelStartProducesTwoMatchedPairs(backend: RecordingSoundCue.Backend) {
    var events: [String] = []
    var cue = RecordingSoundCue { pairing, moment in
      events.append("\(pairing.rawValue):\(moment.rawValue)")
      return true
    }

    cue.handle(.recording, backend: backend, enabled: true, selectedPairing: .airGlint)
    cue.handle(.idle, backend: backend, enabled: true, selectedPairing: .velvetTap)
    cue.handle(.loadingModel, backend: backend, enabled: true, selectedPairing: .velvetTap)
    cue.handle(.recording, backend: backend, enabled: true, selectedPairing: .velvetTap)
    cue.handle(.transcribing, backend: backend, enabled: true, selectedPairing: .cloudPop)

    #expect(
      events == ["airGlint:start", "airGlint:stop", "velvetTap:start", "velvetTap:stop"])
  }

  #if DEBUG
    private final class FakeCuePlayer: RecordingSoundPlayback, Sendable {
      let isPlaying = false
      private let ok: Bool
      init(_ ok: Bool) { self.ok = ok }
      func play() -> Bool { ok }
    }

    private func makeGatedPlayer(
      _ state: OSAllocatedUnfairLock<
        (now: ContinuousClock.Instant, loads: Int, calls: Int, ok: Bool, gate: Bool, returned: Bool)
      >,
      _ entered: DispatchSemaphore, _ release: DispatchSemaphore, checkReturned: Bool = false,
      loc: SourceLocation = #_sourceLocation
    ) -> RecordingSoundCuePlayer {
      let load: @Sendable (RecordingSoundPairing, RecordingSoundMoment) -> Data? = { _, _ in
        state.withLock { $0.loads += 1 }
        return Data()
      }
      return RecordingSoundCuePlayer(now: { state.withLock { $0.now } }, loadData: load) { _ in
        let (shouldGate, ok) = state.withLock { s -> (Bool, Bool) in
          s.calls += 1
          defer { s.gate = false }
          return (s.gate, s.ok)
        }
        if shouldGate {
          entered.signal()
          #expect(release.wait(timeout: .now() + .seconds(1)) == .success, sourceLocation: loc)
          if checkReturned { #expect(state.withLock { $0.returned }, sourceLocation: loc) }
        }
        return FakeCuePlayer(ok)
      }
    }

    @Test("off-main cue dispatch returns immediately without blocking the caller")
    func handleDoesNotBlockMainActor() throws {
      let (entered, release) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
      let state = OSAllocatedUnfairLock(
        initialState: (now: ContinuousClock.now, loads: 0, calls: 0, ok: true, gate: true, returned: false))
      let player = makeGatedPlayer(state, entered, release, checkReturned: true)
      var cue = RecordingSoundCue(player: player)
      cue.handle(.recording, backend: .parakeet, enabled: true, selectedPairing: .airGlint)
      state.withLock { $0.returned = true }
      try #require(entered.wait(timeout: .now() + .seconds(1)) == .success)
      #expect(player.drainForTesting(timeout: 0.02) == false)
      release.signal()
      try #require(player.drainForTesting())
    }

    @Test("failed start and stale parked cues clear #1342 markers and reuse cached WAV data")
    func failedStartAndStaleParkedCuesDropCleanly() throws {
      let (entered, release) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))
      let state = OSAllocatedUnfairLock(
        initialState: (now: ContinuousClock.now, loads: 0, calls: 0, ok: false, gate: false, returned: false))
      let player = makeGatedPlayer(state, entered, release)
      var cue = RecordingSoundCue(player: player)
      cue.handle(.recording, backend: .parakeet, enabled: true, selectedPairing: .airGlint)
      cue.handle(.transcribing, backend: .parakeet, enabled: true, selectedPairing: .airGlint)
      try #require(player.drainForTesting())
      #expect(state.withLock { $0.calls } == 1 && player.hasStartedBackendForTesting(.parakeet) == false)
      state.withLock { $0.ok = true }
      cue.handle(.recording, backend: .parakeet, enabled: true, selectedPairing: .airGlint)
      try #require(player.drainForTesting())
      #expect(player.hasStartedBackendForTesting(.parakeet) == true)
      state.withLock { $0.gate = true }
      player.enqueue(pairing: .airGlint, moment: .start, backend: nil)
      try #require(entered.wait(timeout: .now() + .seconds(1)) == .success)
      cue.handle(.idle, backend: .parakeet, enabled: true, selectedPairing: .airGlint)
      cue.handle(.recording, backend: .whisper, enabled: true, selectedPairing: .velvetTap)
      state.withLock { $0.now = $0.now.advanced(by: .milliseconds(600)) }
      release.signal()
      try #require(player.drainForTesting())
      #expect(state.withLock { $0.calls } == 3 && state.withLock { $0.loads } == 1)
      #expect(
        player.hasStartedBackendForTesting(.parakeet) == false
          && player.hasStartedBackendForTesting(.whisper) == false)
      cue.handle(.transcribing, backend: .whisper, enabled: true, selectedPairing: .velvetTap)
      try #require(player.drainForTesting())
      #expect(state.withLock { $0.calls } == 3)
    }
  #endif
}
