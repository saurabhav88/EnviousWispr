import Testing

@testable import EnviousWisprAppKit

/// When this fails, a selected or stopped microphone can falsely say it is in use.
@Suite("Microphone capture presentation (#3385)", .tags(.productOutcome))
struct MicrophoneCapturePresentationTests {
  @Test("only active capture on the displayed UID is in use")
  func actualUseRequiresActiveMatchingBind() {
    #expect(MicrophoneCapturePresentation(isCapturing: true, boundDeviceUID: "usb")
      .isInUse(displayedUID: "usb") == true)
    #expect(MicrophoneCapturePresentation(isCapturing: true, boundDeviceUID: "built-in")
      .isInUse(displayedUID: "usb") == false)
    // The diagnostic bind is deliberately retained after a real stop.
    #expect(MicrophoneCapturePresentation(isCapturing: false, boundDeviceUID: "usb")
      .isInUse(displayedUID: "usb") == false)
  }

  @Test("unknown identity never establishes use", arguments: [nil, ""] as [String?])
  func unknownIdentityHidesCue(_ uid: String?) {
    #expect(MicrophoneCapturePresentation(isCapturing: true, boundDeviceUID: uid)
      .isInUse(displayedUID: "usb") == false)
    #expect(MicrophoneCapturePresentation(isCapturing: true, boundDeviceUID: "usb")
      .isInUse(displayedUID: uid) == false)
    #expect(MicrophoneCapturePresentation(isCapturing: true, boundDeviceUID: uid)
      .isInUse(displayedUID: uid) == false)
    #expect(MicrophoneCapturePresentation.unknown.isInUse(displayedUID: "usb") == false)
  }
}
