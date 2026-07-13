import Foundation
import Testing

@testable import EnviousWisprCore

@Suite("HeartPathContexts")
struct HeartPathContextsTests {

  @Test("CaptureStallContext is Sendable and carries all fields")
  func captureStallContextRoundTrip() {
    let ctx = CaptureStallContext(
      sessionID: 42,
      armedAtUptimeNs: 1_000_000_000,
      firedAtUptimeNs: 1_800_000_000,
      route: "built_in_mic",
      sourceType: "av_audio_engine",
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: "BuiltInMicrophoneDevice",
      inputDeviceUIDSystemDefault: "BuiltInMicrophoneDevice",
      failureMode: .noBuffers
    )
    #expect(ctx.sessionID == 42)
    #expect(ctx.firedAtUptimeNs - ctx.armedAtUptimeNs == 800_000_000)
    #expect(ctx.sourceType == "av_audio_engine")
    #expect(ctx.formatMismatchObserved == false)
  }

  @Test("#1523: enrichedWithStabilizationFlags preserves the source-stamped channel count")
  func enrichmentPreservesChannelCount() {
    let source = CaptureStallContext(
      sessionID: 1,
      armedAtUptimeNs: 0,
      firedAtUptimeNs: 1,
      route: "hal_device_input",
      sourceType: "hal_device_input",
      engineStartedSuccessfully: true,
      tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil,
      failureMode: .noBuffers,
      nativeChannelCount: 6
    )
    // The kernel merges its stabilization observations without reconstructing
    // the context from scratch, so the source-stamped channel count must survive.
    let enriched = source.enrichedWithStabilizationFlags(
      formatStabilized: true, captureRebuiltForFormat: false)
    #expect(enriched.nativeChannelCount == 6)
    #expect(enriched.formatStabilized == true)
    // A source that never stamps a count leaves it nil through enrichment.
    #expect(
      source.enrichedWithStabilizationFlags(formatStabilized: nil, captureRebuiltForFormat: nil)
        .nativeChannelCount == 6)
    let unstamped = CaptureStallContext(
      sessionID: 1, armedAtUptimeNs: 0, firedAtUptimeNs: 1, route: "proxy",
      sourceType: "proxy", engineStartedSuccessfully: true, tapInstalled: true,
      formatMismatchObserved: false, inputDeviceUIDPreferred: nil,
      inputDeviceUIDSystemDefault: nil, failureMode: .noBuffers
    )
    #expect(
      unstamped.enrichedWithStabilizationFlags(
        formatStabilized: nil, captureRebuiltForFormat: nil
      ).nativeChannelCount == nil)
  }

  @Test("XPCReplyFailureContext retains replyStage verbatim")
  func xpcReplyFailureContext() {
    let ctx = XPCReplyFailureContext(
      replyStage: "stop_capture",
      errorDomain: "NSCocoaErrorDomain",
      errorCode: 4097,
      errorDescription: "Connection invalidated.",
      sessionID: 7
    )
    #expect(ctx.replyStage == "stop_capture")
    #expect(ctx.errorCode == 4097)
  }

  @Test("XPCErrorKind rawValues match protocol contract")
  func xpcErrorKindRawValues() {
    #expect(XPCErrorKind.interruptCapturing.rawValue == "interruptCapturing")
    #expect(XPCErrorKind.invalidateCapturing.rawValue == "invalidateCapturing")
    #expect(XPCErrorKind.invalidateIdle.rawValue == "invalidateIdle")
  }
}
