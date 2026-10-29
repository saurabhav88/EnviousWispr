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
      interactionID: UUID(), interaction: .popover, phase: .bindingFalseObserved,
      sequence: 1, elapsedMilliseconds: 2_500, pointerInside: false,
      appActive: false, hasKeyWindow: false, escapeObserved: false)
    let props = ObservabilityBootstrap.sanitizePostHogProperties(
      TelemetryService.settingsHelpProperties(row, osVersion: "Version 15.8.1 (Build 24H32)"))
    #expect(Set(props.keys) == Set(row.properties.keys).union(["os_version"]))
    #expect(props["os_version"] as? String == "Version 15.8.1 (Build 24H32)")
    #expect(props["interaction"] as? String == "popover")
    #expect(props["phase"] as? String == "binding_false_observed")
    #expect(props["elapsed_ms"] as? Double == 2_500)
  }


  // Swift Testing instruments value receivers immutably; delegate to the real mutating
  // budget through a reference fixture instead of putting a mutating call inside #expect.
  private final class BudgetFixture {
    private var value = SettingsHelpCaptureBudget()
    func admit(_ row: SettingsHelpObservation, captureAvailable: Bool) -> Bool {
      value.admit(row, captureAvailable: captureAvailable)
    }
  }

  private func observation(_ id: UUID, _ phase: SettingsHelpObservation.Phase)
    -> SettingsHelpObservation
  {
    SettingsHelpObservation(
      interactionID: id, interaction: .popover, phase: phase, sequence: phase == .requested ? 1 : 2,
      elapsedMilliseconds: 0, pointerInside: false, appActive: true,
      hasKeyWindow: true, escapeObserved: false)
  }

  @Test("five opening pairs produce at most ten admissions; the sixth produces none")
  func hardCaptureCeiling() {
    let budget = BudgetFixture()
    var accepted = 0
    for index in 0..<7 {
      let id = UUID()
      let requested = budget.admit(observation(id, .requested), captureAvailable: true)
      let ended = budget.admit(observation(id, .bindingFalseObserved), captureAvailable: true)
      #expect(requested == (index < 5))
      #expect(ended == (index < 5))
      accepted += (requested ? 1 : 0) + (ended ? 1 : 0)
    }
    #expect(accepted == 10)
  }

  @Test("duplicate requests after completion and stray or duplicate endings cannot spend slots")
  func duplicatesAndStrays() {
    let budget = BudgetFixture()
    let id = UUID()
    #expect(budget.admit(observation(id, .requested), captureAvailable: true))
    #expect(budget.admit(observation(id, .requested), captureAvailable: true) == false)
    #expect(budget.admit(observation(UUID(), .bindingFalseObserved), captureAvailable: true) == false)
    #expect(budget.admit(observation(id, .anchorDisappeared), captureAvailable: true))
    #expect(budget.admit(observation(id, .anchorDisappeared), captureAvailable: true) == false)
    #expect(budget.admit(observation(id, .requested), captureAvailable: true) == false)
    for _ in 0..<4 {
      #expect(budget.admit(observation(UUID(), .requested), captureAvailable: true))
    }
    #expect(budget.admit(observation(UUID(), .requested), captureAvailable: true) == false)
  }

  @Test("OFF consumes nothing, SDK off/on does not reset the budget, and the fifth ending is admitted")
  func consentAndDelayedTerminals() {
    let budget = BudgetFixture()
    let ids = (0..<5).map { _ in UUID() }
    #expect(budget.admit(observation(ids[0], .requested), captureAvailable: false) == false)
    for id in ids { #expect(budget.admit(observation(id, .requested), captureAvailable: true)) }
    #expect(budget.admit(observation(ids[0], .bindingFalseObserved), captureAvailable: false) == false)
    #expect(budget.admit(observation(ids[0], .bindingFalseObserved), captureAvailable: true))
    #expect(budget.admit(observation(UUID(), .requested), captureAvailable: true) == false)
    for id in ids.dropFirst() {
      #expect(budget.admit(observation(id, .supersededByRequest), captureAvailable: true))
    }
    #expect(budget.admit(observation(UUID(), .requested), captureAvailable: false) == false)
    #expect(budget.admit(observation(UUID(), .requested), captureAvailable: true) == false)
  }

}
