import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

/// #4044: when these fail, a long meeting's Apple Intelligence summary gets no advice, or a
/// meeting that fit one call, a summary another provider wrote, or a user already on a cloud
/// model gets advice that does not apply.
@MainActor
@Suite("Long meeting summary hint (#4044)", .tags(.productOutcome))
struct MeetingSummaryLongMeetingHintTests {
  @Test("advice requires parts and both recorded and current Apple Intelligence")
  func visibility() {
    let cases: [(parts: Bool?, recorded: String?, current: LLMProvider, shows: Bool)] = [
      (true, "appleIntelligence", .appleIntelligence, true),
      (false, "appleIntelligence", .appleIntelligence, false),
      (true, "openAI", .appleIntelligence, false),
      (true, "ollama", .appleIntelligence, false),
      (true, "appleIntelligence", .openAI, false),
      (nil, "appleIntelligence", .appleIntelligence, false),
      (true, nil, .appleIntelligence, false),
      (nil, nil, .appleIntelligence, false),
    ]
    for row in cases {
      #expect(
        MeetingSummaryLongMeetingHint.shows(
          writtenInParts: row.parts, summaryProviderID: row.recorded,
          currentProvider: row.current) == row.shows,
        "parts \(String(describing: row.parts)), recorded \(row.recorded ?? "nil"), current \(row.current.rawValue)"
      )
    }
  }
}
