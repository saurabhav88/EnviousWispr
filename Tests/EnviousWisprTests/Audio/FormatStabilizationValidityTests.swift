import AVFoundation
import Foundation
import Testing

@testable import EnviousWisprAudio

/// `waitForFormatStabilization` declares the hardware format settled when two
/// consecutive reads agree. Once it polls `inputFormat(forBus:)` (#1353), "agree"
/// is no longer sufficient: during a device transition that accessor can report
/// 0 Hz or 0 channels, and two consecutive *invalid* reads compare equal. Calling
/// that stable hands an unusable format to `AVAudioConverter(from:to:)`, which
/// returns nil and tears down an otherwise recoverable recording.
///
/// The stabilization loop itself needs a live engine and a real device
/// transition, so it is exercised in Live UAT. The validity predicate it gates
/// on is pure, and is tested here directly — not reimplemented.
@Suite struct FormatStabilizationValidityTests {

  @Test func aFullyValidFormatIsUsable() {
    #expect(AVAudioEngineSource.isUsableFormat(sampleRate: 44100, channelCount: 1))
    #expect(AVAudioEngineSource.isUsableFormat(sampleRate: 48000, channelCount: 2))
    #expect(AVAudioEngineSource.isUsableFormat(sampleRate: 16000, channelCount: 1))
  }

  /// The exact transient Codex flagged: a device mid-transition reporting 0 Hz.
  @Test func aZeroSampleRateIsNotUsable() {
    #expect(!AVAudioEngineSource.isUsableFormat(sampleRate: 0, channelCount: 1))
  }

  /// The sibling transient: rate settles before the channel count does.
  @Test func aZeroChannelCountIsNotUsable() {
    #expect(!AVAudioEngineSource.isUsableFormat(sampleRate: 44100, channelCount: 0))
  }

  @Test func bothZeroIsNotUsable() {
    #expect(!AVAudioEngineSource.isUsableFormat(sampleRate: 0, channelCount: 0))
  }

  /// A negative rate is not a rate. Guards against a `!= 0` rewrite.
  @Test func aNegativeSampleRateIsNotUsable() {
    #expect(!AVAudioEngineSource.isUsableFormat(sampleRate: -44100, channelCount: 1))
  }

  /// Boundary: the smallest positive values either side of the threshold.
  @Test func theUsabilityBoundaryIsStrictlyGreaterThanZero() {
    #expect(AVAudioEngineSource.isUsableFormat(sampleRate: 0.001, channelCount: 1))
    #expect(!AVAudioEngineSource.isUsableFormat(sampleRate: 0, channelCount: 1))
  }

  /// Two *invalid* reads agreeing must not read as settled. This is the whole
  /// point: equality alone was the defect.
  @Test func agreementBetweenInvalidReadsIsNotStability() {
    let previous = (rate: 0.0, channels: AVAudioChannelCount(0))
    let current = (rate: 0.0, channels: AVAudioChannelCount(0))
    let agree = previous == current
    let settled =
      agree
      && AVAudioEngineSource.isUsableFormat(
        sampleRate: current.rate, channelCount: current.channels)
    #expect(agree, "Fixture must model two agreeing reads for this test to mean anything.")
    #expect(!settled, "Two agreeing invalid reads were treated as a settled format.")
  }
}
