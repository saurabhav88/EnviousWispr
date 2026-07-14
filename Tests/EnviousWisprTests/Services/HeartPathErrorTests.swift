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
      route: "bt", sourceType: "hal_device_input",
      engineStartedSuccessfully: true, tapInstalled: true,
      formatMismatchObserved: false,
      inputDeviceUIDPreferred: nil, inputDeviceUIDSystemDefault: nil,
      failureMode: .noBuffers
    )
    let cases: [HeartPathError] = [
      .audioCaptureStalled(sessionID: 1, ctx: stallCtx),
      .noAudioCaptured(sessionID: 1, durationMs: 2000, wasStreaming: true, route: "bt"),
      .pasteCascadeClipboardFallback(
        tiersAttempted: ["ax1", "cgevent"], focusClassification: "text_field",
        targetBundleID: "com.apple.Terminal"),
      .pasteCGEventCreationFailed(accessibilityTrusted: true),
      .pasteAppleScriptFailed(
        errorCode: 1002, errorMessage: "Not authorized",
        targetBundleID: "com.apple.Terminal"),
      .emptyAfterProcessing(route: "built_in_mic", wasPolishEnabled: true),
      .zombieEngineZeroPeak(sessionID: 7, durationMs: 9000, route: "bt", sampleCount: 145360),
      .audioEngineInterrupted(route: "built_in_mic", durationMs: 3200),
    ]

    for heart in cases {
      let desc = heart.errorDescription ?? ""
      #expect(!desc.isEmpty, "empty description for \(heart)")
    }
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
