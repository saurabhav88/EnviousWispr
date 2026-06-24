import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprServices

@Suite("HeartPathError")
struct HeartPathErrorTests {

  @Test("every case produces a non-empty localizedDescription")
  func localizedDescriptionCoverage() {
    let stallCtx = CaptureStallContext(
      sessionID: 1, armedAtUptimeNs: 0, firedAtUptimeNs: 800_000_000,
      route: "bt", sourceType: "av_capture_session",
      engineStartedSuccessfully: true, tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: nil, inputDeviceUIDSystemDefault: nil
    )
    let sessionCtx = CaptureSessionInterruptionContext(
      kind: .wasInterrupted, reasonCode: 1,
      reasonLabel: "audio_device_in_use_by_another_client",
      errorDomain: nil, errorCode: nil, errorDescription: nil,
      sessionID: 1, isActivelyCapturing: true
    )
    let replyCtx = XPCReplyFailureContext(
      replyStage: "stop_capture", errorDomain: "NSCocoaErrorDomain",
      errorCode: 4097, errorDescription: "invalidated", sessionID: 1
    )

    let cases: [HeartPathError] = [
      .audioCaptureStalled(sessionID: 1, ctx: stallCtx),
      .noAudioCaptured(sessionID: 1, durationMs: 2000, wasStreaming: true, route: "bt"),
      .captureSessionInterrupted(ctx: sessionCtx),
      .pasteCascadeClipboardFallback(
        tiersAttempted: ["ax1", "cgevent"], focusClassification: "text_field",
        targetBundleID: "com.apple.Terminal"),
      .pasteCGEventCreationFailed(accessibilityTrusted: true),
      .pasteAppleScriptFailed(
        errorCode: 1002, errorMessage: "Not authorized",
        targetBundleID: "com.apple.Terminal"),
      .audioXPCInterrupted(handler: .invalidate, wasCapturing: true),
      .xpcReplyFailed(ctx: replyCtx),
      .xpcServerClientProxyNil(sessionID: 1, consecutiveDrops: 5),
      .emptyAfterProcessing(route: "built_in_mic", wasPolishEnabled: true),
      .zombieEngineZeroPeak(sessionID: 7, durationMs: 9000, route: "bt", sampleCount: 145360),
      .audioEngineInterrupted(route: "built_in_mic", durationMs: 3200),
    ]

    for heart in cases {
      let desc = heart.errorDescription ?? ""
      #expect(!desc.isEmpty, "empty description for \(heart)")
    }
  }

  @Test("XPCHandlerKind rawValues are stable")
  func handlerKinds() {
    #expect(XPCHandlerKind.interrupt.rawValue == "interrupt")
    #expect(XPCHandlerKind.invalidate.rawValue == "invalidate")
  }

  @Test("zombieEngineZeroPeak description includes all fields")
  func zombieEngineZeroPeakDescription() {
    let err = HeartPathError.zombieEngineZeroPeak(
      sessionID: 42, durationMs: 9000, route: "bt", sampleCount: 145360
    )
    let desc = err.errorDescription ?? ""
    #expect(desc.contains("42"))
    #expect(desc.contains("9000ms"))
    #expect(desc.contains("bt"))
    #expect(desc.contains("145360"))
  }
}
