@testable import EnviousWisprServices
import Foundation
import Testing

@Suite("Settings help telemetry schema", .tags(.observabilityContract))
struct SettingsHelpObservationTests {
  @Test("the wire payload is typed and survives the real privacy boundary without content")
  func payload() throws {
    let id = try #require(UUID(uuidString: "AB123456-1234-4321-ABCD-1234567890AB"))
    let row = SettingsHelpObservation(
      interactionID: id, interaction: .popover, phase: .bindingFalseObserved,
      sequence: 2, elapsedMilliseconds: 123.5, pointerInside: true,
      appActive: true, hasKeyWindow: false, escapeObserved: false)
    let props = ObservabilityBootstrap.sanitizePostHogProperties(row.properties)
    #expect(Set(props.keys) == Set([
      "interaction_id", "interaction", "phase", "sequence", "elapsed_ms", "pointer_inside",
      "app_active", "has_key_window", "escape_observed",
    ]))
    #expect(props["interaction_id"] as? String == id.uuidString)
    #expect(props["phase"] as? String == "binding_false_observed")
    #expect(props["interaction"] as? String == "popover")
    #expect(props["sequence"] as? Int == 2)
    #expect(props["elapsed_ms"] as? Double == 123.5)
    #expect(props["has_key_window"] as? Bool == false)
  }

  @MainActor
  @Test("the SDK projection adds exact OS metadata and preserves typed observations")
  func sdkProjection() throws {
    let row = SettingsHelpObservation(
      interactionID: UUID(), interaction: .hover, phase: .hoverEnded,
      sequence: 1, elapsedMilliseconds: 2_500, pointerInside: false,
      appActive: false, hasKeyWindow: false, escapeObserved: false)
    let props = ObservabilityBootstrap.sanitizePostHogProperties(
      TelemetryService.settingsHelpProperties(row, osVersion: "Version 15.8.1 (Build 24H32)"))
    #expect(Set(props.keys) == Set(row.properties.keys).union(["os_version"]))
    #expect(props["os_version"] as? String == "Version 15.8.1 (Build 24H32)")
    #expect(props["interaction"] as? String == "hover")
    #expect(props["phase"] as? String == "hover_ended")
    #expect(props["elapsed_ms"] as? Double == 2_500)
  }

}
