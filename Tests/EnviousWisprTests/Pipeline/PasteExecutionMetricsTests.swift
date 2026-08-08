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
      // #1980. Distinctive, non-default values, matching the #1921 pattern
      // below: `true`/`137.5` cannot pass by coincidence with an un-set field.
      caretCaptureRetried: true,
      caretCaptureRetryMs: 137.5,
      repairRules: "leading_space,lowercased_first",
      pastePayloadKind: "repaired",
      languageResolutionSource: "document",
      languageConfidenceBucket: "f70to90")
    let decoded = try JSONDecoder().decode(
      ExecutionMetrics.self, from: JSONEncoder().encode(metrics))
    #expect(decoded.smartInsertionEnabled == true)
    #expect(decoded.caretContextOutcome == "read")
    #expect(decoded.caretCaptureRetried == true)
    #expect(decoded.caretCaptureRetryMs == 137.5)
    #expect(decoded.repairRules == "leading_space,lowercased_first")
    #expect(decoded.pastePayloadKind == "repaired")
    // #1921. Distinctive values, not defaults, so a hop that silently dropped
    // them could not pass by coincidence.
    #expect(decoded.languageResolutionSource == "document")
    #expect(decoded.languageConfidenceBucket == "f70to90")
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
    #expect(decoded.caretCaptureRetried == nil)
    #expect(decoded.caretCaptureRetryMs == nil)
    #expect(decoded.repairRules == nil)
    #expect(decoded.pastePayloadKind == nil)
    // #1921. The literal JSON above is deliberately UNCHANGED — it is the real
    // pre-field shape, not something today's encoder produced. Generating it
    // with the current encoder would only prove the new code agrees with
    // itself, which is exactly the failure this case exists to prevent.
    #expect(decoded.languageResolutionSource == nil)
    #expect(decoded.languageConfidenceBucket == nil)
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
    // #1980. Absent, not present-as-nil/false/zero — same discipline as every
    // other optional field on this type.
    #expect(empty.properties["caret_capture_retried"] == nil)
    #expect(empty.properties["caret_capture_retry_ms"] == nil)
    #expect(partial.properties["caret_capture_retried"] == nil)
    #expect(partial.properties["caret_capture_retry_ms"] == nil)
    // #1921. Nil must stay ABSENT rather than becoming "none". "none" is a real
    // upstream category meaning "we measured and found nothing"; absent means
    // the fact was never recorded, which is what an old stored transcript has.
    // Collapsing the two would make a pre-#1921 history entry indistinguishable
    // from a genuine language-stage timeout.
    #expect(empty.properties["language_resolution_source"] == nil)
    #expect(empty.properties["language_confidence_bucket"] == nil)
    #expect(partial.properties["language_resolution_source"] == nil)
    #expect(partial.properties["language_confidence_bucket"] == nil)

    // #1921. The other half, which the omission assertions alone do NOT prove: a
    // REAL "none" must actually be emitted. Without this the suite shows only
    // that nil disappears, and the distinction between "we measured and found
    // nothing" and "nobody ever looked" would be asserted in prose and untested.
    let measuredNothing = TelemetryService.PasteInsertionTelemetry(
      languageResolutionSource: "none", languageConfidenceBucket: "none")
    #expect(measuredNothing.properties["language_resolution_source"] as? String == "none")
    #expect(measuredNothing.properties["language_confidence_bucket"] as? String == "none")

    // #1980. The emission direction for the retry fields — proves the two
    // properties actually appear, typed, when set, not merely that they
    // disappear when nil.
    let retried = TelemetryService.PasteInsertionTelemetry(
      caretCaptureRetried: true, caretCaptureRetryMs: 137.5)
    #expect(retried.properties["caret_capture_retried"] as? Bool == true)
    #expect(retried.properties["caret_capture_retry_ms"] as? Double == 137.5)
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
