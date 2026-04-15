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
      inputDeviceUIDSystemDefault: "BuiltInMicrophoneDevice"
    )
    #expect(ctx.sessionID == 42)
    #expect(ctx.firedAtUptimeNs - ctx.armedAtUptimeNs == 800_000_000)
    #expect(ctx.sourceType == "av_audio_engine")
    #expect(ctx.formatMismatchObserved == false)
  }

  @Test("CaptureSessionInterruptionContext kinds are stable")
  func captureSessionInterruptionKinds() {
    #expect(CaptureSessionInterruptionContext.Kind.wasInterrupted.rawValue == "wasInterrupted")
    #expect(CaptureSessionInterruptionContext.Kind.runtimeError.rawValue == "runtimeError")
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
