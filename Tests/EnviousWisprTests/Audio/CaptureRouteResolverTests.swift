import CoreAudio
import Testing

@testable import EnviousWisprAudio

@MainActor
@Suite("CaptureRouteResolver — #1378 / #1533 cutover")
struct CaptureRouteResolverTests {
  private func resolver(btOutputActive: Bool) -> CaptureRouteResolver {
    var resolver = CaptureRouteResolver()
    resolver.defaultOutputDeviceID = { 1 }
    resolver.isBluetoothOutputDevice = { _ in btOutputActive }
    return resolver
  }

  // The whole-behavior invariant of the 3b cutover: EVERY automatic context
  // resolves to the single HAL device backend. The reason still distinguishes
  // BT vs no-BT and auto vs explicit for telemetry; the device UID is nil on
  // Auto (follow system default) and the explicit pick otherwise.

  @Test("non-BT output Auto → HAL device input, system default target")
  func nonBTOutputAutoUsesHAL() {
    let decision = resolver(btOutputActive: false).resolve(preferredInputDeviceUID: "")

    #expect(decision.sourceType == .halDeviceInput)
    #expect(decision.reason == .noBTAutoInput)
    #expect(decision.effectiveDeviceUID == nil)
  }

  @Test("non-BT output explicit pick → HAL device input, carries UID")
  func nonBTOutputExplicitUsesHAL() {
    let decision = resolver(btOutputActive: false).resolve(preferredInputDeviceUID: "usb-mic")

    #expect(decision.sourceType == .halDeviceInput)
    #expect(decision.reason == .noBTUserSelectedDevice)
    #expect(decision.effectiveDeviceUID == "usb-mic")
  }

  @Test("BT output Auto → HAL device input with nil target")
  func btOutputAutoUsesHALWithSystemDefaultTarget() {
    let decision = resolver(btOutputActive: true).resolve(preferredInputDeviceUID: "")

    #expect(decision.sourceType == .halDeviceInput)
    #expect(decision.reason == .btOutputAutoInput)
    #expect(decision.effectiveDeviceUID == nil)
  }

  @Test("BT output explicit pick → HAL device input and carries UID")
  func btOutputExplicitUsesHALWithTarget() {
    let decision = resolver(btOutputActive: true).resolve(preferredInputDeviceUID: "airpods-input")

    #expect(decision.sourceType == .halDeviceInput)
    #expect(decision.reason == .btOutputUserSelectedDevice)
    #expect(decision.effectiveDeviceUID == "airpods-input")
  }
}
