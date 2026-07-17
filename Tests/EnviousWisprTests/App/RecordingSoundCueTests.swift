import AVFoundation
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #1342 — resource validation plus the exact-once lifecycle behavior of
/// `RecordingSoundCue`. All lifecycle tests inject a spy via
/// `RecordingSoundCue.init(playback:)`; none play real audio.
@MainActor
@Suite("Recording sound cue")
struct RecordingSoundCueTests {

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
    }

    cue.handle(.recording, backend: .whisperKit, enabled: false, selectedPairing: .airGlint)
    cue.handle(.transcribing, backend: .whisperKit, enabled: true, selectedPairing: .velvetTap)

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
    }

    cue.handle(.loadingModel, backend: backend, enabled: true, selectedPairing: .airGlint)
    cue.handle(.recording, backend: backend, enabled: true, selectedPairing: .airGlint)
    cue.handle(.transcribing, backend: backend, enabled: true, selectedPairing: .velvetTap)

    #expect(events.map(\.self) == ["airGlint:start", "airGlint:stop"])
  }

  @Test(
    "a fast cancel immediately followed by a new recording produces two matched pairs",
    arguments: RecordingSoundCue.Backend.allCases
  )
  func rapidStartCancelStartProducesTwoMatchedPairs(backend: RecordingSoundCue.Backend) {
    var events: [String] = []
    var cue = RecordingSoundCue { pairing, moment in
      events.append("\(pairing.rawValue):\(moment.rawValue)")
    }

    cue.handle(.recording, backend: backend, enabled: true, selectedPairing: .airGlint)
    cue.handle(.idle, backend: backend, enabled: true, selectedPairing: .velvetTap)
    cue.handle(.loadingModel, backend: backend, enabled: true, selectedPairing: .velvetTap)
    cue.handle(.recording, backend: backend, enabled: true, selectedPairing: .velvetTap)
    cue.handle(.transcribing, backend: backend, enabled: true, selectedPairing: .cloudPop)

    #expect(
      events == ["airGlint:start", "airGlint:stop", "velvetTap:start", "velvetTap:stop"])
  }
}
