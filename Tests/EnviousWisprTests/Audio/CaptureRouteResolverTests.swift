import CoreAudio
import Testing

@testable import EnviousWisprAudio

@MainActor
@Suite("CaptureRouteResolver — #1378")
struct CaptureRouteResolverTests {
  private func resolver(btOutputActive: Bool) -> CaptureRouteResolver {
    var resolver = CaptureRouteResolver()
    resolver.defaultOutputDeviceID = { 1 }
    resolver.isBluetoothOutputDevice = { _ in btOutputActive }
    return resolver
  }

  @Test("non-BT output keeps Auto on AVAudioEngine")
  func nonBTOutputAutoUsesEngine() {
    let decision = resolver(btOutputActive: false).resolve(
      preferredInputDeviceUID: "", noiseSuppression: false)

    #expect(decision.sourceType == .audioEngine)
    #expect(decision.reason == .noBTAutoInput)
    #expect(decision.effectiveDeviceUID == nil)
  }

  @Test("non-BT output keeps explicit picks on AVAudioEngine")
  func nonBTOutputExplicitUsesEngine() {
    let decision = resolver(btOutputActive: false).resolve(
      preferredInputDeviceUID: "usb-mic", noiseSuppression: false)

    #expect(decision.sourceType == .audioEngine)
    #expect(decision.reason == .noBTUserSelectedDevice)
    #expect(decision.effectiveDeviceUID == nil)
  }

  @Test("BT output Auto uses HAL device input with nil target")
  func btOutputAutoUsesHALWithSystemDefaultTarget() {
    let decision = resolver(btOutputActive: true).resolve(
      preferredInputDeviceUID: "", noiseSuppression: false)

    #expect(decision.sourceType == .halDeviceInput)
    #expect(decision.reason == .btOutputAutoInput)
    #expect(decision.effectiveDeviceUID == nil)
    #expect(decision.fallbackAllowed == false)
  }

  @Test("BT output explicit pick uses HAL device input and carries UID")
  func btOutputExplicitUsesHALWithTarget() {
    let decision = resolver(btOutputActive: true).resolve(
      preferredInputDeviceUID: "airpods-input", noiseSuppression: false)

    #expect(decision.sourceType == .halDeviceInput)
    #expect(decision.reason == .btOutputUserSelectedDevice)
    #expect(decision.effectiveDeviceUID == "airpods-input")
    #expect(decision.fallbackAllowed == false)
  }
}
