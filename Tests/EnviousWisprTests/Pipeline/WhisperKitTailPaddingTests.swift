import Foundation
import Testing

@testable import EnviousWisprASR

// MARK: - #1408 premise 2 — an abruptly severed tail decodes like a user stop
//
// Salvaging a dictation whose microphone died mid-sentence hands the decoder a
// buffer that ends abruptly, with no trailing silence. The plan asserted that
// WhisperKit already handles this identically to a normal user stop, and that
// the mitigation predates the case. These tests lock that claim so a future
// "optimization" that makes the pad conditional cannot silently truncate the
// last words of every salvaged recording.
//
// Parakeet is the opposite contract and must stay that way: an RNNT decoder fed
// trailing silence loops and repeats (`gotchas-audio.md` FACT:
// parakeet-tail-truncation). These tests do NOT claim Parakeet is never padded —
// the conditioner's engine-agnostic short-utterance pad is a separate,
// pre-existing path. The claim is narrower: no TRAILING-SILENCE pad.

@Suite("WhisperKit trailing-silence pad (#1408 premise 2)")
struct WhisperKitTailPaddingTests {

  private static let sampleRate = 16000
  private static let expectedPadSamples = Int(0.5 * 16000)

  @Test("the pad appends exactly 500 ms of trailing silence")
  func padAppendsHalfASecondOfSilence() {
    let speech = [Float](repeating: 0.4, count: Self.sampleRate)
    let padded = WhisperKitBackend.padAudioWithSilence(speech)

    #expect(padded.count == speech.count + Self.expectedPadSamples)
    #expect(Array(padded.prefix(speech.count)) == speech, "the speech must be untouched")
    #expect(
      padded.suffix(Self.expectedPadSamples).allSatisfy { $0 == 0 },
      "the tail must be pure silence, not a repeat of the last frame")
  }

  /// The salvage case exactly: audio that stops dead, with no decaying tail.
  /// The pad is what gives the decoder the look-ahead context it needs, and it
  /// does not depend on the buffer's shape, length, or how the recording ended.
  @Test(
    "the pad is unconditional — it does not inspect the buffer",
    arguments: [0, 1, 160, 16000, 480_000])
  func padIsUnconditional(sampleCount: Int) {
    // An abruptly severed tail: full-amplitude right up to the final sample.
    let abrupt = [Float](repeating: 0.9, count: sampleCount)
    let padded = WhisperKitBackend.padAudioWithSilence(abrupt)

    #expect(padded.count == sampleCount + Self.expectedPadSamples)
    #expect(padded.suffix(Self.expectedPadSamples).allSatisfy { $0 == 0 })
  }

  @Test("padding an empty buffer yields silence rather than trapping")
  func padOfEmptyBufferIsSilence() {
    let padded = WhisperKitBackend.padAudioWithSilence([])
    #expect(padded.count == Self.expectedPadSamples)
    #expect(padded.allSatisfy { $0 == 0 })
  }
}
