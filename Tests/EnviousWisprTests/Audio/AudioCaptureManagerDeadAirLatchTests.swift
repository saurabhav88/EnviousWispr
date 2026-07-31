import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAudio

// MARK: - #1317 / #1543 / #1578 — reactive dead-air refusal state
//
// The manager feeds authoritative captured samples into a
// `DeadAirStreamingDetector` on the MainActor through `ingestSamples`. When an
// all-zero run crosses the confidence threshold and the frozen-device
// discriminator returns any non-eligible reason, the manager records that
// categorical reason and attempts one forward for the run. The current-run
// reason and reactive-classification flag clear when a non-zero sample breaks
// the run; rejected contexts remain in the per-session backlog. The detector's
// tile and zero-run math is covered by `DeadAirStreamingDetectorTests`; this
// suite pins the manager's refusal, reset, forwarding, and backlog wiring.
@MainActor
@Suite("AudioCaptureManager dead-air refusal + compatibility view (#1317/#1543/#1578)")
struct AudioCaptureManagerDeadAirLatchTests {

  /// A manager armed to ingest without real hardware. No `startEnginePhase`, so
  /// the frozen discriminator device is `nil` — which the classifier owns as
  /// `.boundDeviceUnavailable`, driving the fail-closed refusal path.
  private func armedManager() -> AudioCaptureManager {
    let manager = AudioCaptureManager()
    manager.isCapturing = true  // internal(set): arm ingest without hardware
    return manager
  }

  @Test("an all-zero run with a non-eligible device sets the compatibility view")
  func allZeroSetsCompatibilityViewWhenRefused() {
    let manager = armedManager()
    #expect(!manager.zeroSignalDiscriminatorSawIneligible)

    // Exactly-zero samples past the minimum-transcription threshold ⇒
    // `isAllZeroFromStart`. No frozen bind ⇒ a refusal reason ⇒ the derived
    // compatibility view reads true.
    manager.ingestSamples(
      [Float](repeating: 0, count: AudioConstants.minimumTranscriptionSamples), level: 0)
    #expect(manager.zeroSignalDiscriminatorSawIneligible)
  }

  @Test("a non-zero sample breaks the trailing zero-run and clears the compatibility view")
  func nonZeroClearsTheCompatibilityView() {
    let manager = armedManager()
    manager.ingestSamples(
      [Float](repeating: 0, count: AudioConstants.minimumTranscriptionSamples), level: 0)
    #expect(manager.zeroSignalDiscriminatorSawIneligible, "precondition: refused")

    // The refused-then-recovered negative: real audio breaks the trailing
    // zero-run, so the earlier refusal must no longer stick.
    manager.ingestSamples([0.5], level: 0.5)
    #expect(!manager.zeroSignalDiscriminatorSawIneligible)
  }

  @Test("meaningful signal from the start never sets the compatibility view")
  func realSignalNeverSetsCompatibilityView() {
    let manager = armedManager()
    manager.ingestSamples(
      [Float](repeating: 0.5, count: AudioConstants.minimumTranscriptionSamples), level: 0.5)
    #expect(!manager.zeroSignalDiscriminatorSawIneligible)
  }

  // MARK: - #1578 — the refusal carries a reason, and is counted exactly once

  private static func zeros(_ n: Int = AudioConstants.minimumTranscriptionSamples) -> [Float] {
    [Float](repeating: 0, count: n)
  }

  /// Enough real signal for `meaningfulSignalSeen` to latch, which is what turns
  /// a following zero run into `.becameZeroMidCapture` rather than
  /// `.allZeroFromStart`.
  private static func loud(_ n: Int = 8_000) -> [Float] {
    [Float](repeating: 0.5, count: n)
  }

  @Test("an ineligible zero run records WHY, not just THAT")
  func refusalRecordsTheReason() {
    let manager = armedManager()
    #expect(manager.zeroSignalRefusalReason == nil)
    #expect(!manager.zeroSignalRunWasClassifiedReactively)

    manager.ingestSamples(Self.zeros(), level: 0)

    // No `startEnginePhase`, so no frozen bind — the classifier owns that
    // outcome, and the manager must report it rather than a generic refusal.
    #expect(manager.zeroSignalRefusalReason == .boundDeviceUnavailable)
    #expect(manager.zeroSignalRunWasClassifiedReactively)
    // The legacy Boolean now derives from the reason; it must not have drifted.
    #expect(manager.zeroSignalDiscriminatorSawIneligible)
  }

  @Test("meaningful signal records no reason, attempts no forward, adds no backlog")
  func healthySignalRecordsNothing() {
    let manager = armedManager()
    var attempts = 0
    manager.onZeroSignalRefused = { _ in
      attempts += 1
      return true
    }

    manager.ingestSamples(Self.loud(AudioConstants.minimumTranscriptionSamples), level: 0.5)

    // The paired negative control for every positive below: without it, a
    // manager that refused unconditionally would satisfy all of them.
    #expect(manager.zeroSignalRefusalReason == nil)
    #expect(!manager.zeroSignalRunWasClassifiedReactively)
    #expect(attempts == 0)
    #expect(manager.takePendingZeroSignalRefusals().isEmpty)
  }

  @Test("a zero run spanning many batches forwards exactly once")
  func multiBatchRunForwardsOnce() {
    let manager = armedManager()
    var attempts = 0
    manager.onZeroSignalRefused = { _ in
      attempts += 1
      return true
    }

    // First batch crosses the candidate threshold; the next three stay inside
    // the SAME uninterrupted zero run and must be silent.
    manager.ingestSamples(Self.zeros(), level: 0)
    manager.ingestSamples(Self.zeros(4_000), level: 0)
    manager.ingestSamples(Self.zeros(4_000), level: 0)
    manager.ingestSamples(Self.zeros(4_000), level: 0)

    #expect(attempts == 1)
    #expect(manager.takePendingZeroSignalRefusals().isEmpty)
  }

  @Test("an accepted forward leaves the backlog empty; a rejected one holds exactly one")
  func acceptedVersusRejectedForward() {
    let accepted = armedManager()
    accepted.onZeroSignalRefused = { _ in true }
    accepted.ingestSamples(Self.zeros(), level: 0)
    #expect(accepted.takePendingZeroSignalRefusals().isEmpty)

    let rejected = armedManager()
    rejected.onZeroSignalRefused = { _ in false }
    rejected.ingestSamples(Self.zeros(), level: 0)
    #expect(rejected.takePendingZeroSignalRefusals().count == 1)

    // No subscriber at all is the same answer as an explicit refusal: not
    // delivered. This is the state production is in until the route is wired.
    let unsubscribed = armedManager()
    unsubscribed.ingestSamples(Self.zeros(), level: 0)
    #expect(unsubscribed.takePendingZeroSignalRefusals().count == 1)
  }

  @Test("both an accepted and a rejected forward mark the run classified")
  func bothOutcomesMarkTheRunClassified() {
    // Forwarding success must never be what suppresses STOP-time
    // reclassification — otherwise a rejected refusal would be emitted from the
    // backlog AND re-emitted by STOP.
    let accepted = armedManager()
    accepted.onZeroSignalRefused = { _ in true }
    accepted.ingestSamples(Self.zeros(), level: 0)
    #expect(accepted.zeroSignalRunWasClassifiedReactively)

    let rejected = armedManager()
    rejected.onZeroSignalRefused = { _ in false }
    rejected.ingestSamples(Self.zeros(), level: 0)
    #expect(rejected.zeroSignalRunWasClassifiedReactively)
  }

  @Test("recovery clears the current run but never the rejected backlog")
  func recoveryClearsRunStateAndKeepsBacklog() {
    let manager = armedManager()
    manager.ingestSamples(Self.zeros(), level: 0)
    #expect(manager.zeroSignalRefusalReason != nil, "precondition: refused")

    manager.ingestSamples(Self.loud(), level: 0.5)

    // Current-run facts are gone, so the next run gets its own forward…
    #expect(manager.zeroSignalRefusalReason == nil)
    #expect(!manager.zeroSignalRunWasClassifiedReactively)
    // …but the refusal that already happened is NOT undone by the microphone
    // coming back. This is the case that produces nothing at all today.
    #expect(manager.takePendingZeroSignalRefusals().count == 1)
  }

  @Test("an accepted refusal that recovers clears run state and leaves no backlog")
  func acceptedRecoveredRunClearsWithoutBacklog() {
    // The fourth cell of accepted/rejected × final/recovered. Without it, a
    // recovery that wrongly re-forwarded an already-delivered refusal would go
    // unnoticed, because the other three cells never re-run the callback.
    let manager = armedManager()
    var attempts = 0
    manager.onZeroSignalRefused = { _ in
      attempts += 1
      return true
    }

    manager.ingestSamples(Self.zeros(), level: 0)
    #expect(attempts == 1)
    #expect(manager.zeroSignalRefusalReason != nil)
    #expect(manager.zeroSignalRunWasClassifiedReactively)

    manager.ingestSamples(Self.loud(), level: 0.5)

    #expect(attempts == 1)
    #expect(manager.zeroSignalRefusalReason == nil)
    #expect(!manager.zeroSignalRunWasClassifiedReactively)
    #expect(manager.takePendingZeroSignalRefusals().isEmpty)
  }

  @Test("two rejected runs in one take keep both contexts, in order, with their own shapes")
  func twoRejectedRunsPreserveOrderAndShape() {
    let manager = armedManager()

    // Run 1: silent from the very first sample.
    manager.ingestSamples(Self.zeros(), level: 0)
    // Recovery: real audio breaks the run and re-arms classification.
    manager.ingestSamples(Self.loud(), level: 0.5)
    // Run 2: silence AFTER real speech — a different failure shape entirely.
    manager.ingestSamples(Self.zeros(), level: 0)

    let pending = manager.takePendingZeroSignalRefusals()
    #expect(pending.count == 2)
    #expect(pending.first?.failureShape == .allZeroFromStart)
    #expect(pending.last?.failureShape == .becameZeroMidCapture)
    // Both describe the same session and the same absent bind.
    #expect(pending.allSatisfy { $0.reason == .boundDeviceUnavailable })
    #expect(pending.allSatisfy { $0.sessionID == manager.currentCaptureSessionID })
  }

  @Test("the context carries session, reason, transport and shape from the shipped authorities")
  func contextPayloadUsesExistingAuthorities() {
    let manager = armedManager()
    var seen: ZeroSignalRefusalContext?
    manager.onZeroSignalRefused = { ctx in
      seen = ctx
      return true
    }

    manager.ingestSamples(Self.zeros(), level: 0)

    #expect(seen?.sessionID == manager.currentCaptureSessionID)
    #expect(seen?.reason == .boundDeviceUnavailable)
    #expect(seen?.failureShape == .allZeroFromStart)
    // No route has resolved on a manager armed without hardware, so the shared
    // low-cardinality fallback applies — the same expression the dead-air stall
    // diagnostic uses, not a second transport source.
    #expect(seen?.transport == "unknown")
  }

  @Test("the atomic take hands over everything once, then reports empty")
  func atomicTakeIsExactlyOnce() {
    let manager = armedManager()
    manager.ingestSamples(Self.zeros(), level: 0)

    let first = manager.takePendingZeroSignalRefusals()
    #expect(first.count == 1)

    // The whole point: a second consumer — a cancel landing while a stop is
    // suspended — must get nothing rather than a duplicate.
    #expect(manager.takePendingZeroSignalRefusals().isEmpty)
  }

  @Test("a refusal does not latch the dead-air detector, so a later run still refuses")
  func refusalDoesNotLatchTheDetector() {
    let manager = armedManager()
    manager.ingestSamples(Self.zeros(), level: 0)
    manager.ingestSamples(Self.loud(), level: 0.5)
    manager.ingestSamples(Self.zeros(), level: 0)

    // Behaviour, not private storage: a second refusal could not have been
    // reached if the first had set `deadAirDetector.fired`, whose guard sits at
    // the top of the reactive path.
    #expect(manager.takePendingZeroSignalRefusals().count == 2)
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
  // #1578: the two claims that cannot be made without driving a real capture
  // session. Both need the manager's existing `#if DEBUG` source-factory seam,
  // so this whole suite is DEBUG-only — the Release lane strips the seam and
  // must not try to compile against it (the trap that turned main red in #1520).
  //
  // The stub source is the one `BoundDeviceAdoptionTests` already maintains for
  // exactly this purpose. A second copy would be a second thing to keep true.
  @MainActor
  @Suite("AudioCaptureManager zero-signal refusal — real session paths (#1578)")
  struct AudioCaptureManagerRefusalSessionTests {

    private static func zeros(_ n: Int = AudioConstants.minimumTranscriptionSamples) -> [Float] {
      [Float](repeating: 0, count: n)
    }

    /// A manager that will build its source from the stub, so `startEnginePhase`
    /// and `beginCapturePhase` run for real without hardware.
    private static func makeManager(_ stub: BoundDeviceAdoptionTests.StubSource)
      -> AudioCaptureManager
    {
      let manager = AudioCaptureManager()
      manager.installSourceFactoryForTesting { stub }
      return manager
    }

    @Test("starting a new session clears the reason, the flag AND the backlog")
    func sessionStartClearsEverythingIncludingBacklog() async throws {
      let stub = BoundDeviceAdoptionTests.StubSource()
      let manager = Self.makeManager(stub)

      // Strand a rejected refusal from a prior take.
      manager.isCapturing = true
      manager.ingestSamples(Self.zeros(), level: 0)
      #expect(manager.zeroSignalRefusalReason != nil, "precondition: refused")
      #expect(manager.zeroSignalRunWasClassifiedReactively, "precondition: classified")

      try await manager.startEnginePhase()
      _ = try await manager.beginCapturePhase()

      // A new session must inherit none of it. Recovery keeps the backlog; a new
      // session is the one place it is dropped without a consumer taking it.
      #expect(manager.zeroSignalRefusalReason == nil)
      #expect(!manager.zeroSignalRunWasClassifiedReactively)
      #expect(manager.takePendingZeroSignalRefusals().isEmpty)
    }

    @Test("a refusal leaves the genuine capture-stall path armed for the same take")
    func refusalDoesNotConsumeTheStallLatch() async throws {
      let stub = BoundDeviceAdoptionTests.StubSource()
      let manager = Self.makeManager(stub)
      var stalls: [CaptureStallContext] = []
      manager.onCaptureStalled = { stalls.append($0) }

      try await manager.startEnginePhase()
      _ = try await manager.beginCapturePhase()

      // The bound stub device cannot pass the identity re-check, so this refuses.
      manager.ingestSamples(Self.zeros(), level: 0)
      #expect(manager.zeroSignalRefusalReason != nil, "precondition: refused")
      #expect(stalls.isEmpty, "a refusal must not itself raise a capture stall")

      // Now the SOURCE reports a genuine stall in the same take. The manager's
      // forwarding is gated on `captureStallReported`, so this arriving at the
      // consumer is the proof that the refusal did not consume that latch.
      stub.onCaptureStalled?(
        CaptureStallContext(
          sessionID: manager.currentCaptureSessionID,
          armedAtUptimeNs: 0,
          firedAtUptimeNs: 1,
          route: "stub",
          sourceType: "stub",
          engineStartedSuccessfully: true,
          tapInstalled: true,
          formatMismatchObserved: false,
          inputDeviceUIDPreferred: nil,
          inputDeviceUIDSystemDefault: nil,
          failureMode: .noBuffers))

      #expect(stalls.count == 1)
    }
  }

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
