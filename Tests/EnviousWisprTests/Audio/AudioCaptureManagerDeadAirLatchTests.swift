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

  // MARK: - #1788 — the Bluetooth-only ceiling

  /// The fix: Bluetooth alone waits 3.0s for the link to wake.
  @Test("bluetooth gets the 3.0s ceiling")
  func bluetoothGetsTheLongerCeiling() {
    #expect(
      AudioCaptureManager.allZeroFromStartCeilingSamples(forEffectiveTransport: "bluetooth")
        == AudioConstants.bluetoothAllZeroMidTakeCeilingSamples)
    #expect(
      AudioCaptureManager.allZeroFromStartCeilingSamples(forEffectiveTransport: "bluetooth")
        == 48_000)
  }

  /// THE WIRED-UNCHANGED GUARANTEE, asserted rather than assumed. This is the test
  /// that must be GREEN on both pre-fix and post-fix code — that is what proves the
  /// change is Bluetooth-scoped instead of a universal ceiling raise, which is the
  /// design coverage review rejected. A nil or unreadable transport falls to TODAY's
  /// behaviour, never to the longer one: an unknown route must not silently buy
  /// every user three seconds of tolerated silence.
  @Test("every non-bluetooth transport, including nil and unknown, keeps 1.0s")
  func everyOtherTransportKeepsTheShippingCeiling() {
    for transport in ["built_in", "usb", "unknown", "", "Bluetooth", "BLUETOOTH"] {
      #expect(
        AudioCaptureManager.allZeroFromStartCeilingSamples(forEffectiveTransport: transport)
          == AudioConstants.minimumTranscriptionSamples,
        "\(transport) must keep the shipping ceiling")
    }
    #expect(
      AudioCaptureManager.allZeroFromStartCeilingSamples(forEffectiveTransport: nil)
        == AudioConstants.minimumTranscriptionSamples)
  }

  /// The two ceilings must stay DISTINCT constants. A future maintainer collapsing
  /// them would silently apply 3.0s everywhere (or 1.0s to Bluetooth), which is the
  /// exact regression the transport branch exists to prevent.
  @Test("the two ceilings are separate values, 1.0s and 3.0s")
  func ceilingsAreDistinct() {
    #expect(AudioConstants.minimumTranscriptionSamples == 16_000)
    #expect(AudioConstants.bluetoothAllZeroMidTakeCeilingSamples == 48_000)
    #expect(
      AudioConstants.bluetoothAllZeroMidTakeCeilingSamples
        > AudioConstants.minimumTranscriptionSamples)
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
  /// The wake instrument's honesty rule (#1788, cloud review r5-r7). SEVEN review
  /// rounds on this one diagnostic all reduced to reading a quantity over an interval
  /// it does not describe, so the rule deciding `stream_measured` vs `floor` is
  /// frozen here as pure logic rather than left inside the emitter where each round
  /// found it again. Both failure modes UNDER-report, so the safe label is `floor`.
  ///
  /// Note the label is `stream_measured`, not `exact`: no sample-derived wake can be
  /// exact with respect to press-to-audio, because a callback-free startup is
  /// invisible to a sample clock (r7). These tests pin the delivered-stream claim,
  /// which is the only claim the instrument makes.
  @Suite("AudioCaptureManager — wake measurement basis (#1788)")
  struct AudioCaptureManagerWakeExactnessTests {

    @Test("a measured zero prefix is what makes a wake stream-measured")
    func measuredPrefixMakesItExact() {
      // Samples were routed while the link was still silent, so the interval is
      // observed rather than inferred.
      #expect(AudioCaptureManager.wakeIsStreamMeasured(gapCount: 0, wakeSamples: 9591))
      #expect(AudioCaptureManager.wakeIsStreamMeasured(gapCount: 0, wakeSamples: 1))
    }

    @Test("a zero wake is ALWAYS a floor, never stream-measured")
    func zeroWakeIsNeverExact() {
      // THE r5/r6 CASE. A wake of 0 means the first sample that ever existed was
      // already non-zero, so an already-awake link and one that woke during a
      // callback-free startup are indistinguishable. r6 caught the previous version
      // of this suite ASSERTING THE OPPOSITE for a pre-roll latch at index 0 — the
      // bug was written into its own oracle, which is why the rule is now expressed
      // over the wake itself rather than over a proxy field.
      #expect(!AudioCaptureManager.wakeIsStreamMeasured(gapCount: 0, wakeSamples: 0))
    }

    @Test("gaps and a measured prefix are both required")
    func exactRequiresBothConditions() {
      #expect(AudioCaptureManager.wakeIsStreamMeasured(gapCount: 0, wakeSamples: 8000))
      #expect(!AudioCaptureManager.wakeIsStreamMeasured(gapCount: 1, wakeSamples: 8000))
      #expect(!AudioCaptureManager.wakeIsStreamMeasured(gapCount: 0, wakeSamples: 0))
      #expect(!AudioCaptureManager.wakeIsStreamMeasured(gapCount: 3, wakeSamples: 0))
    }

    @Test("an unreadable gap count or wake fails CLOSED, never as zero")
    func unknownInputsAreNotExact() {
      // A measurement authority that cannot read its own inputs must not print the
      // confident label. nil gaps = the source offered no stop metadata; nil wake =
      // the stream position could not be reconstructed at all.
      #expect(!AudioCaptureManager.wakeIsStreamMeasured(gapCount: nil, wakeSamples: 8000))
      #expect(!AudioCaptureManager.wakeIsStreamMeasured(gapCount: 0, wakeSamples: nil))
      #expect(!AudioCaptureManager.wakeIsStreamMeasured(gapCount: nil, wakeSamples: nil))
    }
  }
#endif
