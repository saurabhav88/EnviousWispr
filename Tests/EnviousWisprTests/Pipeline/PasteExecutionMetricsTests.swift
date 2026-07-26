import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing
@testable import EnviousWisprServices

// The cursor-aware insertion fields on `ExecutionMetrics` and their projection
// onto `paste.completed` (#1785 Chunk 9).
//
// Two obligations, both of which fail silently if untested: a transcript written
// before this feature must still decode from disk, and the projection must carry
// reasons without carrying a word of what the user dictated.
@Suite("Paste insertion metrics (#1785)")
struct PasteExecutionMetricsTests {

  @Test("The new fields round-trip through Codable")
  func roundTrips() throws {
    let metrics = ExecutionMetrics(
      pasteTier: "ax_direct",
      pasteLatencyMs: 5,
      smartInsertionEnabled: true,
      caretContextOutcome: "read",
      repairRules: "leading_space,lowercased_first",
      pastePayloadKind: "repaired")
    let decoded = try JSONDecoder().decode(
      ExecutionMetrics.self, from: JSONEncoder().encode(metrics))
    #expect(decoded.smartInsertionEnabled == true)
    #expect(decoded.caretContextOutcome == "read")
    #expect(decoded.repairRules == "leading_space,lowercased_first")
    #expect(decoded.pastePayloadKind == "repaired")
  }

  @Test("A transcript stored before this feature still decodes")
  func olderRecordsStillDecode() throws {
    // Exactly the shape on disk today: no cursor-aware keys at all. If these
    // fields were ever made non-optional, every existing history entry would
    // fail to decode and the user's history would appear to vanish.
    let json = """
      {"pasteTier":"cgevent","pasteLatencyMs":260,"coldStart":false,"streamingMode":true}
      """
    let decoded = try JSONDecoder().decode(ExecutionMetrics.self, from: Data(json.utf8))
    #expect(decoded.pasteTier == "cgevent")
    #expect(decoded.smartInsertionEnabled == nil)
    #expect(decoded.caretContextOutcome == nil)
    #expect(decoded.repairRules == nil)
    #expect(decoded.pastePayloadKind == nil)
  }

  @Test("Absent facts are omitted, never sent as a placeholder")
  func absentFactsAreOmitted() {
    let empty = TelemetryService.PasteInsertionTelemetry()
    #expect(empty.properties.isEmpty)

    let partial = TelemetryService.PasteInsertionTelemetry(
      smartInsertionEnabled: false, caretContextOutcome: "setting_off")
    #expect(partial.properties["smart_insertion"] as? Bool == false)
    #expect(partial.properties["caret_context"] as? String == "setting_off")
    #expect(partial.properties["repair_rules"] == nil)
    #expect(partial.properties["payload_kind"] == nil)
  }

  @Test("Every rule name is a closed reason, never the word it applied to")
  func ruleNamesCarryNoUserText() {
    // The whole set, so a rule added later without a name cannot slip through.
    let every: [CursorInsertionRepair.AppliedRule] = [
      .refusedInsideWord, .refusedNoLeftAnchor, .leadingSpace, .lowercasedFirst,
      .droppedDuplicateWord, .droppedTerminalPeriod, .trailingSpace,
      .caseSkipped(.alreadyLower), .caseSkipped(.protectedWord),
      .caseSkipped(.mixedCaseOrAcronym), .caseSkipped(.containsDigit),
      .caseSkipped(.pronounI), .caseSkipped(.alwaysCapitalized),
      .caseSkipped(.notOrdinaryWord), .caseSkipped(.dictionaryUnavailable),
      .caseSkipped(.recognizedName), .caseSkipped(.wordClassUnavailable),
      .caseSkipped(.learnedWord), .caseSkipped(.oracleWarming),
      .caseSkipped(.oracleTimedOut),
      .caseSkipped(.languageNotSupported),
      .caseKept(.lineStart), .caseKept(.nothingLeft), .caseKept(.afterOpener),
      .caseKept(.afterTerminator), .caseKept(.other),
      .trailingSpaceSkipped(.rightIsSpace), .trailingSpaceSkipped(.rightIsPunctuation),
      .trailingSpaceSkipped(.unsegmentedScript),
    ]
    let names = Set(every.map(\.telemetryName))
    #expect(names.count == every.count, "every rule needs a distinct name")
    for name in names {
      #expect(
        name.allSatisfy { $0.isLowercase || $0 == "_" || $0 == ":" },
        "\(name) must be a closed lowercase token, so no user text can hide in it")
    }
  }

  @Test("A protected-word skip reports the reason without the word")
  func protectedWordReasonCarriesNoWord() {
    let payloads = CursorInsertionRepair.repair(
      text: "PostHog is down.",
      context: CursorInsertionRepair.CaretText(left: "I think ", right: ""),
      protectedWords: ["PostHog"],
      language: "en",
      // Any oracle: a protected spelling refuses before word knowledge is
      // consulted at all, which is part of what this case proves.
      oracle: .unavailable(.dictionaryUnavailable))
    let rules = payloads.candidateRules.map(\.telemetryName).joined(separator: ",")
    #expect(rules.contains("case_skipped:protected_word"))
    #expect(rules.localizedCaseInsensitiveContains("posthog") == false)
  }
}
