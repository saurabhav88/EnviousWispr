import EnviousWisprAudio
import EnviousWisprCore
import Testing

@testable import EnviousWisprPipeline

// #1844/#1578: the kernel's PRODUCTION decision-snapshot closure — the one it
// builds when no replacement is injected — must read the frozen
// `BoundInputDevice` the capture layer published, and must fail closed when
// there is none.
//
// Every other zero-signal test in this repo injects a replacement closure (since
// #1578, one returning an eligible snapshot), which is correct for those scenarios
// but means the production default has never been under test. These five cases
// drive it directly by passing nil.
//
// HOW THE CLAIM IS PROVEN, since the closure's returned value cannot carry it: a
// synthetic bind yields `.identityMismatch` and no bind yields
// `.boundDeviceUnavailable`, and neither says whether the bind was actually
// consulted. `FakeAudioCapture` therefore COUNTS reads of
// `zeroSignalDiscriminatorDevice`. The count is what distinguishes "consulted the
// frozen bind" from "refused without looking".
//
// One honest caveat: driving the production default means the production authority
// runs a real CoreAudio UID read. The OUTCOME is machine-invariant — no real device
// carries the synthetic UID below, so the identity guard always refuses — but this is
// not a hardware-free path, and it cannot be, because a hardware-free authority is
// exactly what the injected `package` overload is for (covered by
// `ZeroSignalDeviceIdentityTests`).
@MainActor
@Suite("Kernel production decision snapshot reads the frozen bind — #1844/#1578")
struct KernelFrozenBindGuardTests {

  private let threshold = AudioConstants.minimumTranscriptionSamples  // 16_000

  /// A bind that cannot match any real device, so the identity guard's refusal is
  /// invariant across machines.
  private static let syntheticBind = BoundInputDevice(
    deviceID: 121,
    deviceUID: "synthetic-uid-no-real-device-carries-this",
    transportLabel: "bluetooth",
    resolutionSource: "system_default"
  )

  private struct Context {
    let wrapper: KernelRecordingSession
    let capture: FakeAudioCapture
    let vad: FakeVADSignalSource
  }

  /// Builds a session whose decision-snapshot closure is the KERNEL'S OWN, by passing nil.
  private func makeContext() -> Context {
    let clock = FakeClock()
    let engine = FakeEngine(behavior: .batchSuccess(text: "hello"), clock: clock)
    let capture = FakeAudioCapture()
    let vad = FakeVADSignalSource()
    let wrapper = KernelRecordingSession(
      engine: engine, capture: capture, vad: vad, clock: clock, paste: FakePasteTarget(),
      zeroSignalDecisionSnapshot: nil)  // ← the production default, not a stand-in
    return Context(wrapper: wrapper, capture: capture, vad: vad)
  }

  /// Drives an all-zero capture past the classification threshold and stops.
  private func driveAllZeroCapture(_ ctx: Context) async {
    await ctx.wrapper.apply(.start)
    await ctx.wrapper.drainReadyWork()
    ctx.capture.deliverBuffer(frameCount: threshold, amplitude: 0)
    ctx.vad.evidence = .confirmedNoSpeech
    await ctx.wrapper.drainReadyWork()
    await ctx.wrapper.apply(.stop)
    await ctx.wrapper.drainReadyWork()
  }

  /// A bind built from a device this machine reports as genuinely alive AND unmuted,
  /// using the same liveness and mute readers the authority consults, but not
  /// `classify(bound:)` itself, so the fixture is not chosen by the function under test.
  ///
  /// This is the only case that can force the snapshot's eligibility to `.eligible`,
  /// and therefore the only case that distinguishes "the closure calls the shared
  /// authority" from "the closure manufactures a refusal." Measured on this machine
  /// 2026-07-30: all three input devices classify alive+unmuted, including the
  /// built-in microphone.
  /// `nonisolated` because `.enabled(if:)` is evaluated OUTSIDE actor isolation, the
  /// same macro-discovery rule that forces `nonisolated static let` on
  /// `@Test(arguments:)` fixtures in a `@MainActor` suite
  /// (`swift-testing-patterns.md` RULE: swift-testing-mainactor-arguments-needs-nonisolated).
  /// The CoreAudio classifiers it calls are themselves nonisolated statics.
  nonisolated private static func firstEligibleRealDevice() -> BoundInputDevice? {
    for device in AudioDeviceEnumerator.allInputDevices() {
      guard CoreAudioDeviceLiveness.classify(deviceID: device.id) == .alive,
        CoreAudioDeviceMute.classify(deviceID: device.id) == .unmuted
      else { continue }
      // `AudioInputDevice.uid` is already public, so this needs no `@testable`
      // widening of `AudioDeviceEnumerator.inputDeviceUID(for:)`, which is internal.
      return BoundInputDevice(
        deviceID: device.id, deviceUID: device.uid, transportLabel: nil,
        resolutionSource: "system_default")
    }
    return nil
  }

  /// GATED, not unconditional: the required PR check runs `xcodebuild test` on a
  /// hosted runner (`.github/workflows/pr-check.yml:182`), and hosted macOS runners
  /// expose no audio input device — an unconditional `#require` here would fail
  /// `build-check` on every PR. `.enabled(if:)` SKIPS rather than passes, so CI
  /// reports the case as not-run instead of pretending it verified something.
  ///
  /// On any machine with a microphone — which is every machine a human develops on,
  /// and the only place this repo's tests are meaningfully run — it executes and is
  /// the ONLY case that kills the unconditional-refusal mutant.
  @Test(
    "a REAL eligible device reaches an eligible verdict, so the authority IS consulted",
    .enabled(if: KernelFrozenBindGuardTests.firstEligibleRealDevice() != nil))
  func realEligibleDeviceProducesEligibleVerdict() async throws {
    let real = try #require(
      Self.firstEligibleRealDevice(),
      "requires one alive, unmuted input device on this machine")
    let ctx = makeContext()
    ctx.capture.stubbedZeroSignalDiscriminatorDevice = real

    await driveAllZeroCapture(ctx)

    // Only the shared classifier can produce an ELIGIBLE verdict. A closure that
    // skipped `classify(bound:)` and manufactured a refusal would fail here while
    // still satisfying every other case in this suite.
    #expect(
      ctx.wrapper.testKernel.zeroSignalFailureMode != nil,
      "an eligible real device must reach the zero-signal terminal")
    #expect(
      !ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty,
      "an eligible real device must fire stop-time zero-signal telemetry")
  }

  @Test("the production closure CONSULTS the frozen bind rather than ignoring it")
  func productionClosureReadsFrozenBind() async {
    let ctx = makeContext()
    ctx.capture.stubbedZeroSignalDiscriminatorDevice = Self.syntheticBind

    await driveAllZeroCapture(ctx)

    #expect(
      ctx.capture.zeroSignalDiscriminatorDeviceReadCount >= 1,
      "the kernel's own closure never read the frozen bind")
  }

  @Test("no frozen bind → fails closed, no zero-signal terminal (#1844)")
  func nilFrozenBindFailsClosed() async {
    let ctx = makeContext()
    ctx.capture.stubbedZeroSignalDiscriminatorDevice = nil  // an invalidated attempt

    await driveAllZeroCapture(ctx)

    // The user still gets today's honest no-speech outcome; we never accuse a
    // microphone we cannot identify.
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
    #expect(
      ctx.capture.zeroSignalDiscriminatorDeviceReadCount >= 1,
      "fail-closed must come from reading the bind and finding none")
  }

  @Test("an unidentifiable bind is refused, so no zero-signal terminal (#1844)")
  func unidentifiableBindIsRefused() async {
    let ctx = makeContext()
    ctx.capture.stubbedZeroSignalDiscriminatorDevice = Self.syntheticBind

    await driveAllZeroCapture(ctx)

    // The synthetic UID cannot resolve, so the identity guard refuses — machine
    // invariant, and the same fail-closed posture as `.unverified`.
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
    #expect(ctx.wrapper.stopTimeZeroSignalTelemetryFired.isEmpty)
  }

  @Test("a run already classified reactively short-circuits BEFORE the bind is read")
  func reactivelyClassifiedRunShortCircuitsBeforeReadingBind() async {
    let ctx = makeContext()
    ctx.capture.stubbedZeroSignalDiscriminatorDevice = Self.syntheticBind
    // #1578: the categorical replacement for the old Boolean latch. The reactive
    // producer froze a REASON for this run, and the flag says it did so.
    ctx.capture.stubbedZeroSignalRunWasClassifiedReactively = true
    ctx.capture.stubbedZeroSignalRefusalReason = .deviceMuted

    await driveAllZeroCapture(ctx)

    // Guard ORDER is the contract: a stretch that was genuinely unusable must stay
    // refused even if the device's live state has since become fine, so the frozen
    // reason is taken and the device is never consulted.
    #expect(
      ctx.capture.zeroSignalDiscriminatorDeviceReadCount == 0,
      "the device was consulted despite a run already classified reactively")
    #expect(ctx.wrapper.testKernel.zeroSignalFailureMode == nil)
  }
}
