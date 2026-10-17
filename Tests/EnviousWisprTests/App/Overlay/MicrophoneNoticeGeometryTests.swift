import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

// MARK: - MicrophoneNoticeGeometryTests (#2549)
//
// The founder caught the shipped `.error` notice pill truncating "Microphone
// access is off." mid-word — a fixed 280×44, single-line box with no room to
// grow. These assert PillCatalog's fix directly, isolated from
// `PillCatalogParityTests`' frozen sixteen-row fixture (which this change
// deliberately does not touch, since only ONE `.error` reason's geometry
// changes and the fixture's own "every row covered" test already proves the
// other fifteen rows are untouched).

@Suite(.tags(.productOutcome))
struct MicrophoneNoticeGeometryTests {

  @Test("permissionDenied gets the wider badge+title+subtitle+button box")
  func permissionDeniedGeometry() throws {
    let entry = PillCatalog.entry(
      for: .error(reason: .permissionDenied), id: PresentationID())
    let definition = try #require(entry.definition)

    #expect(definition.requestedWidth == .fixed(400))
    // #3912: the box keeps its 400 width and takes its height from the text (it was 400 x 64).
    #expect(
      definition.reservesFixedHeight == nil,
      "a fixed height cuts off a longer translation of the title or subtitle")

    guard case .notice(let model) = definition.content else {
      Issue.record("expected a notice, got \(definition.content)")
      return
    }
    #expect(model.isMultiline == true)
    #expect(model.text == "Microphone access needed")
    #expect(model.secondaryText == "Turn it on to start dictating.")
    #expect(
      model.accessibilityLabel == DictationNarrator.copy(for: .permissionDenied),
      "VoiceOver keeps reading the narrator's shared sentence even though the on-screen copy is this pill's own"
    )
    #expect(model.action?.action == .openMicrophoneSettings)
    #expect(model.action?.label == "Open Settings")
  }

  @Test("every other error reason wraps at the message width, no action")
  func otherReasonsUnchanged() throws {
    // A representative sample, not exhaustive — TerminalNoticeReason's full
    // enumeration against the frozen fixture is PillCatalogParityTests' job.
    for reason: TerminalNoticeReason in [.asrFailed, .zeroSignal, .noMicrophoneFound] {
      let entry = PillCatalog.entry(for: .error(reason: reason), id: PresentationID())
      let definition = try #require(entry.definition)

      // #3912: was a fixed 280 x 44 single line; now wraps at the message width.
      #expect(
        definition.requestedWidth == .fixed(PillCatalog.messageWidth), "\(reason) width regressed")
      #expect(definition.reservesFixedHeight == nil, "\(reason) reserves a fixed height")

      guard case .notice(let model) = definition.content else {
        Issue.record("expected a notice, got \(definition.content)")
        continue
      }
      #expect(model.isMultiline == true, "\(reason) no longer wraps")
      #expect(model.action == nil, "\(reason) should not have gained a button")
    }
  }
}
