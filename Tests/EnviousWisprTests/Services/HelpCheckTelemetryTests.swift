import Foundation
import Testing

@testable import EnviousWisprServices

// The capture hook exists in Debug builds only.
#if DEBUG

/// #3275: the in-app help check's one terminal usage event carries counts, closed values and
/// version stamps, and never text.
@Suite("Help check terminal event (#3275)", .tags(.observabilityContract))
@MainActor
struct HelpCheckTelemetryTests {

  final class Captured: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CapturedTelemetryEvent] = []
    func add(_ e: CapturedTelemetryEvent) { lock.withLock { events.append(e) } }
    var all: [CapturedTelemetryEvent] { lock.withLock { events } }
  }

  @Test("The terminal event holds only its named keys and closed values")
  func shape() throws {
    let record = try #require(
      FeedbackHelpOutcome(
        terminalOutcome: .partialSent, failureReason: nil, mode: .decomposed, overflow: false,
        coveragePassed: true,
        versions: FeedbackHelpOutcome.Versions(
          kb: "kb1", jevModel: "jev-1.13.0", decomposition: "afm-kit-1",
          decision: "2026-09-28.1", threshold: "g3", app: "2.6.0"),
        shownCardCount: 1,
        issues: [
          FeedbackHelpOutcome.Issue(
            index: 0, matchKind: .section, pageSlug: "toggle-mode", sectionID: "toggle-mode#a",
            deflection: .canResolve, resolution: .solved)!
        ]))
    let terminal = HelpCheckTerminal(
      .stillSent, record: record, splitFailure: nil, checkSeconds: 1.25)
    let captured = Captured()
    TelemetryService.shared.testEventHook = { @Sendable in captured.add($0) }
    defer { TelemetryService.shared.testEventHook = nil }
    TelemetryService.shared.helpCheckTerminal(terminal)

    let event = try #require(captured.all.first { $0.name == "feedback.help_check_terminal" })
    #expect(captured.all.filter { $0.name == "feedback.help_check_terminal" }.count == 1)
    #expect(
      Set(event.stringProps.keys) == [
        "outcome", "mode", "duration_bucket", "os_version", "device_model", "kb_version",
        "jev_version", "decomposition_version", "decision_version", "threshold_version",
      ])
    #expect(event.stringProps["outcome"] == "still_sent")
    #expect(event.stringProps["duration_bucket"] == "1_2s")
    #expect(
      event.intProps == [
        "issue_count": 1, "card_count": 1, "section_count": 1, "page_count": 0,
        "solved_count": 1, "unmatched_count": 0,
      ])
    #expect(event.boolProps == ["overflow": false, "coverage_passed": true])
    #expect(event.doubleProps == ["$value": 1.25])
    // No help-center ids either: a slug names which article a user needed.
    let values = event.stringProps.values.joined(separator: " ")
    #expect(!values.contains("toggle-mode"))
  }
}

#endif
