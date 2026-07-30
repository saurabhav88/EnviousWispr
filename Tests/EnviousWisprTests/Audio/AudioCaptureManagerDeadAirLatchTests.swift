import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAudio

// MARK: - #1317 / #1543 — the reactive dead-air "ineligible" latch, ported
// in-process from the former capture proxy.
//
// The manager feeds the authoritative captured samples into a
// `DeadAirStreamingDetector` on the MainActor (via `ingestSamples`). When an
// all-zero run crosses the confidence threshold AND the frozen input device is
// ineligible (muted, or — as in these unit tests — never frozen, so `nil`), the
// manager latches `zeroSignalDiscriminatorSawIneligible`. The latch is scoped to
// the CURRENT trailing zero-run: a non-zero sample that breaks the run clears
// it, so a muted-then-unmuted stretch cannot blind the kernel's STOP-time
// backstop to a later, unrelated genuine failure. The detector's own tile/zero
// math is covered by `DeadAirStreamingDetectorTests`; this pins the manager's
// latch wiring.
@MainActor
@Suite("AudioCaptureManager dead-air ineligible latch (#1317/#1543)")
struct AudioCaptureManagerDeadAirLatchTests {

  /// A manager armed to ingest without real hardware. No `startEnginePhase`, so
  /// the frozen discriminator device is `nil` — the "ineligible" state a real
  /// muted device produces, driving the fail-closed latch path.
  private func armedManager() -> AudioCaptureManager {
    let manager = AudioCaptureManager()
    manager.isCapturing = true  // internal(set): arm ingest without hardware
    return manager
  }

  @Test("an all-zero run with an ineligible device latches saw-ineligible")
  func allZeroLatchesWhenIneligible() {
    let manager = armedManager()
    #expect(!manager.zeroSignalDiscriminatorSawIneligible)

    // Exactly-zero samples past the minimum-transcription threshold ⇒
    // `isAllZeroFromStart`. Device is nil ⇒ ineligible ⇒ latch sets.
    manager.ingestSamples(
      [Float](repeating: 0, count: AudioConstants.minimumTranscriptionSamples), level: 0)
    #expect(manager.zeroSignalDiscriminatorSawIneligible)
  }

  @Test("a non-zero sample breaks the trailing zero-run and clears the latch")
  func nonZeroClearsTheLatch() {
    let manager = armedManager()
    manager.ingestSamples(
      [Float](repeating: 0, count: AudioConstants.minimumTranscriptionSamples), level: 0)
    #expect(manager.zeroSignalDiscriminatorSawIneligible, "precondition: latched")

    // The muted-then-unmuted negative: real audio breaks the trailing zero-run,
    // so the earlier ineligible result must no longer stick.
    manager.ingestSamples([0.5], level: 0.5)
    #expect(!manager.zeroSignalDiscriminatorSawIneligible)
  }

  @Test("meaningful signal from the start never latches saw-ineligible")
  func realSignalNeverLatches() {
    let manager = armedManager()
    manager.ingestSamples(
      [Float](repeating: 0.5, count: AudioConstants.minimumTranscriptionSamples), level: 0.5)
    #expect(!manager.zeroSignalDiscriminatorSawIneligible)
  }

  // MARK: - #1788 — the mid-take all-zero ceiling has ONE owner

  /// The production-critical claim: with no DEBUG override set, the ceiling is
  /// the shipping 1.0s value, so release behaviour is unchanged by the #1788
  /// instrument. This is the assertion that must never regress — if the default
  /// ever drifts, every transport silently changes how long it tolerates silence.
  @Test("no override -> ceiling is the shipping minimumTranscriptionSamples")
  func ceilingDefaultsToShippingValue() {
    UserDefaults.standard.removeObject(forKey: "EWDebugAllZeroCeilingSamples")
    let manager = AudioCaptureManager()
    #expect(manager.allZeroCeilingSamples == AudioConstants.minimumTranscriptionSamples)
    #expect(manager.allZeroCeilingSamples == 16_000)
  }

  /// A non-positive override must be IGNORED rather than producing a zero or
  /// negative ceiling — a 0 ceiling would abort every capture instantly, which is
  /// the worst possible failure for a debug knob to be able to cause by typo.
  @Test("non-positive override is ignored, never applied")
  func nonPositiveOverrideIsIgnored() {
    defer { UserDefaults.standard.removeObject(forKey: "EWDebugAllZeroCeilingSamples") }
    for bad in [0, -1, -160_000] {
      UserDefaults.standard.set(bad, forKey: "EWDebugAllZeroCeilingSamples")
      let manager = AudioCaptureManager()
      #expect(manager.allZeroCeilingSamples == AudioConstants.minimumTranscriptionSamples)
    }
  }

  // The override exists ONLY in DEBUG, so these two tests are mirror images and
  // both must be compiled — asserting the override works where it exists, and
  // asserting it is genuinely ABSENT where it must not exist. A single
  // unconditional test would fail the `scripts/xcode-test.sh --release` lane,
  // which strips `#if DEBUG` and returns the shipping ceiling (Codex review r1).

  #if DEBUG
    /// A positive override is honoured. This is what made the #1788 hardware
    /// measurement possible — without it a slow Bluetooth wake is censored by the
    /// abort rather than observed.
    @Test("positive override is honoured in DEBUG")
    func positiveOverrideIsHonoured() {
      defer { UserDefaults.standard.removeObject(forKey: "EWDebugAllZeroCeilingSamples") }
      UserDefaults.standard.set(160_000, forKey: "EWDebugAllZeroCeilingSamples")
      let manager = AudioCaptureManager()
      #expect(manager.allZeroCeilingSamples == 160_000)
    }
  #else
    /// The release-lane twin, and the more important of the two: it proves the
    /// debug knob cannot influence a shipped build. Setting the key must change
    /// NOTHING — if this ever fails, a diagnostic override has leaked into
    /// production and can alter how long every capture tolerates silence.
    @Test("override key has NO effect in release — the knob cannot ship")
    func overrideIsInertInRelease() {
      defer { UserDefaults.standard.removeObject(forKey: "EWDebugAllZeroCeilingSamples") }
      UserDefaults.standard.set(160_000, forKey: "EWDebugAllZeroCeilingSamples")
      let manager = AudioCaptureManager()
      #expect(manager.allZeroCeilingSamples == AudioConstants.minimumTranscriptionSamples)
    }
  #endif
}

#if DEBUG
  /// The wake instrument's honesty rule (#1788 cloud review r5). Five review rounds
  /// on this one diagnostic all reduced to reading a quantity over an interval it
  /// does not describe, so the rule that decides `exact` vs `floor` is frozen here
  /// as pure logic rather than left inside the emitter where each round found it
  /// again. Both failure modes UNDER-report, so the safe label is always `floor`.
  @Suite("AudioCaptureManager — wake exactness rule (#1788)")
  struct AudioCaptureManagerWakeExactnessTests {

    @Test("a pre-roll latch proves the stream predated the wake")
    func preRollLatchProvesStreamCameFirst() {
      #expect(
        AudioCaptureManager.wakeStreamStartedBeforeWake(
          firstNonZeroRoutedIndex: 9591, routedCountAtActivation: nil))
      // Even index 0 counts: a latch existing at all means route() saw the sample.
      #expect(
        AudioCaptureManager.wakeStreamStartedBeforeWake(
          firstNonZeroRoutedIndex: 0, routedCountAtActivation: 0))
    }

    @Test("samples routed before activation prove it too")
    func routedBeforeActivationProvesStreamCameFirst() {
      #expect(
        AudioCaptureManager.wakeStreamStartedBeforeWake(
          firstNonZeroRoutedIndex: nil, routedCountAtActivation: 8000))
    }

    @Test("nothing routed before activation means the wake is unmeasurable below")
    func noPriorSamplesMeansNotExact() {
      // THE r5 CASE: AUHAL delivers no callback for a while, then its first sample
      // is already nonzero. Index 0 reads as wake_ms=0 and no gap counter moves, so
      // without this the line would claim `exact` over a real link delay.
      #expect(
        !AudioCaptureManager.wakeStreamStartedBeforeWake(
          firstNonZeroRoutedIndex: nil, routedCountAtActivation: 0))
      #expect(
        !AudioCaptureManager.wakeStreamStartedBeforeWake(
          firstNonZeroRoutedIndex: nil, routedCountAtActivation: nil))
    }

    @Test("exact requires a gap-free stream AND a stream that came first")
    func exactRequiresBothConditions() {
      #expect(AudioCaptureManager.wakeIsExact(gapCount: 0, streamStartedFirst: true))
      #expect(!AudioCaptureManager.wakeIsExact(gapCount: 1, streamStartedFirst: true))
      #expect(!AudioCaptureManager.wakeIsExact(gapCount: 0, streamStartedFirst: false))
      #expect(!AudioCaptureManager.wakeIsExact(gapCount: 3, streamStartedFirst: false))
    }

    @Test("an unreadable gap count fails CLOSED, never as zero")
    func unknownGapCountIsNotExact() {
      // A measurement authority that cannot read its own inputs must not print the
      // confident label; nil here means the source had no stop metadata to offer.
      #expect(!AudioCaptureManager.wakeIsExact(gapCount: nil, streamStartedFirst: true))
    }
  }
#endif
