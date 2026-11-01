import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// #4286: what a meeting summary is told about the meeting, and where. When these fail, the
/// summary misnames people or the meeting, reads an invitation as attendance, overflows a small
/// model window because of the facts, or loses the facts on a long meeting.
@Suite("Meeting summary facts block (#4286)", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingSummaryFactsBlockTests {
  typealias Calls = MeetingSummaryTests.Calls
  static let small = MeetingSummaryTests.small
  static let utc = TimeZone(identifier: "UTC") ?? .gmt

  static func person(
    _ name: String?, _ email: String?, status: AttendeeFact.Status = .accepted,
    isSelf: Bool = false, isOrganizer: Bool = false
  ) -> MeetingParticipant {
    MeetingParticipants.resolve(attendees: [
      AttendeeFact(
        name: name, email: email, role: .required, status: status, isSelf: isSelf,
        isOrganizer: isOrganizer)
    ])[0]
  }

  static let acme = MeetingPromptFacts(
    startedAt: Date(timeIntervalSince1970: 1_793_455_200),  // 2026-10-31 14:00 UTC
    recordedDurationMs: 2_700_000, callAppName: "Zoom", calendarTitle: "Acme x Envious: renewal",
    participants: [
      person("Dana Lee", "dana@acme.com", isOrganizer: true),
      person("Li Wu", "li@acme.com", status: .declined),
      person("Sam", "sam@envious.co", isSelf: true),
    ])

  // MARK: - Rendering

  @Test("an ordinary meeting renders every line in order")
  func ordinary() {
    #expect(
      MeetingSummary.factsBlock(Self.acme, timeZone: Self.utc)
        == """
        Meeting facts (from the user's calendar and the app, not from the conversation):
        Started: 2026-10-31 14:00, recorded 45 minutes
        Call app: Zoom
        Calendar event: Acme x Envious: renewal
        Invited: Dana Lee (acme.com, organizer), Li Wu (acme.com, declined), you
        """)
  }

  @Test("without calendar facts only the app's own facts are told; nobody becomes you")
  func noCalendar() {
    let facts = MeetingPromptFacts(
      startedAt: Self.acme.startedAt, recordedDurationMs: 30_000, callAppName: nil,
      calendarTitle: nil, participants: [Self.person("Kim", nil)])
    #expect(
      MeetingSummary.factsBlock(facts, timeZone: Self.utc)
        == """
        Meeting facts (from the user's calendar and the app, not from the conversation):
        Started: 2026-10-31 14:00, recorded 1 minute
        Invited: Kim
        """)
    let bare = MeetingPromptFacts(
      startedAt: Self.acme.startedAt, recordedDurationMs: 0, callAppName: nil,
      calendarTitle: nil, participants: [])
    #expect(
      MeetingSummary.factsBlock(bare, timeZone: Self.utc).hasSuffix("Started: 2026-10-31 14:00"))
  }

  @Test("the start time is the Mac's local time")
  func localTime() throws {
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    #expect(
      MeetingSummary.factsBlock(Self.acme, timeZone: tokyo).contains("Started: 2026-10-31 23:00"))
  }

  @Test("an email-only invitee prints the address alone; no company is inferred")
  func emailOnly() {
    let facts = MeetingPromptFacts(
      startedAt: Self.acme.startedAt, recordedDurationMs: 60_000, callAppName: nil,
      calendarTitle: nil, participants: [Self.person(nil, "ops@acme.com")])
    let block = MeetingSummary.factsBlock(facts, timeZone: Self.utc)
    #expect(block.hasSuffix("Invited: ops@acme.com"))
    #expect(block.contains("Acme") == false)
  }

  @Test("at most 25 people are named; the rest are counted exactly")
  func peopleCap() {
    var facts = Self.acme
    facts.participants = (1...30).map { Self.person("P\($0)", "p\($0)@x.org") }
    let block = MeetingSummary.factsBlock(facts, timeZone: Self.utc)
    #expect(block.contains("P25 (x.org)"))
    #expect(block.contains("P26") == false)
    #expect(block.hasSuffix(", and 5 more"))
  }

  @Test("the block stays within 1,200 characters, dropping people and counting them")
  func characterCap() {
    var facts = Self.acme
    facts.calendarTitle = String(repeating: "Ü", count: 500)
    facts.participants = (1...25).map {
      Self.person(String(repeating: "é", count: 70) + "\($0)", "p\($0)@x.org")
    }
    let block = MeetingSummary.factsBlock(facts, timeZone: Self.utc)
    #expect(block.count <= MeetingSummary.factsMaxCharacters)
    let named = block.components(separatedBy: "(x.org)").count - 1
    #expect(named < 25)
    #expect(block.hasSuffix("and \(25 - named) more"))
    #expect(block.contains("Calendar event: " + String(repeating: "Ü", count: 199) + "…"))
  }

  // MARK: - Requests at Apple Intelligence's 4,096-token window

  static func write(_ calls: Calls, transcript: String, notes: String = "") async throws
    -> MeetingSummary.Written
  {
    try await MeetingSummary.write(
      transcript: transcript, notes: notes, facts: Self.sentBlock, window: Self.small,
      callTimeoutSeconds: 60, admit: {}, complete: calls.complete)
  }

  static var sentBlock: String { MeetingSummary.factsBlock(Self.acme) }

  @Test("a meeting that fits is one call carrying the facts, within the window")
  func singleCall() async throws {
    let calls = Calls()
    _ = try await Self.write(calls, transcript: "You: we ship Friday")
    #expect(calls.prompts.count == 1)
    #expect(calls.prompts[0].contains(Self.sentBlock))
    #expect(calls.prompts[0].contains("Invited: Dana Lee (acme.com, organizer)"))
    #expect(MeetingSummaryTests.fitsInEstimate(calls.prompts[0], Self.small))
    #expect(MeetingSummaryTests.fitsInBytes(calls.prompts[0], Self.small))
  }

  @Test("a long meeting: parts omit the facts, combine and final calls carry them, all fit")
  func partsCombineFinal() async throws {
    let line = "Speaker 1: " + String(repeating: "word ", count: 40)
    let transcript = Array(repeating: line, count: 300).joined(separator: "\n")
    let plan = try MeetingSummary.plan(
      transcript: transcript, notes: "", facts: Self.sentBlock, window: Self.small,
      counting: .estimate)
    let pieces = try #require(plan.pieces).count
    let cap = MeetingSummary.partialCap(plan.budget)
    let calls = Calls()
    // Full-length part answers force at least one combine round.
    calls.answers = Array(
      repeating: .success(MeetingSummaryTests.answer(of: line, withinTokens: cap)), count: pieces)
    _ = try await Self.write(calls, transcript: transcript)
    let maps = calls.prompts.prefix(pieces)
    #expect(
      maps.allSatisfy { $0.hasPrefix("This is part") && $0.contains("Meeting facts") == false })
    let combines = calls.prompts.dropFirst(pieces).dropLast()
    #expect(combines.isEmpty == false, "a combine round ran")
    #expect(combines.allSatisfy { $0.hasPrefix(Self.sentBlock + "\n\nBelow are the key points") })
    #expect(calls.prompts.last?.contains(Self.sentBlock) == true)
    #expect(calls.prompts.allSatisfy { MeetingSummaryTests.fitsInEstimate($0, Self.small) })
    #expect(calls.prompts.count <= plan.worstCaseCalls)
  }

  @Test("a shortening request omits the facts; the final call still carries them")
  func shortening() async throws {
    let line = "Speaker 1: " + String(repeating: "word ", count: 40)
    let transcript = Array(repeating: line, count: 150).joined(separator: "\n")
    let plan = try MeetingSummary.plan(
      transcript: transcript, notes: "", facts: Self.sentBlock, window: Self.small,
      counting: .estimate)
    let cap = MeetingSummary.partialCap(plan.budget)
    let oversized = MeetingSummaryTests.answer(of: "- point xxxxxxxx", withinTokens: cap * 2)
    let calls = Calls()
    calls.answers = [.success(oversized), .success("- short")]
    _ = try await Self.write(calls, transcript: transcript)
    #expect(calls.prompts[1].hasPrefix("Shorten these bullets"))
    #expect(calls.prompts[1].contains("Meeting facts") == false)
    #expect(calls.prompts.last?.contains(Self.sentBlock) == true)
    #expect(calls.prompts.allSatisfy { MeetingSummaryTests.fitsInEstimate($0, Self.small) })
  }

  @Test("after a reported overflow the byte plan carries the same facts text and fits in bytes")
  func byteReplan() async throws {
    let line = "Speaker 1: " + String(repeating: "word ", count: 40)
    let transcript = Array(repeating: line, count: 150).joined(separator: "\n")
    let calls = Calls()
    calls.answers = [.failure(LLMError.classified(.inputTooLong))]
    _ = try await Self.write(calls, transcript: transcript)
    let replanned = calls.prompts.dropFirst()
    #expect(replanned.isEmpty == false)
    #expect(replanned.allSatisfy { MeetingSummaryTests.fitsInBytes($0, Self.small) })
    #expect(replanned.last?.contains(Self.sentBlock) == true, "the same frozen text")
  }

  @Test("long notes and non-ASCII facts still fit, and the facts survive")
  func longNotesNonASCII() async throws {
    var facts = Self.acme
    facts.calendarTitle = "Réunion trimestrielle — 東京オフィス"
    facts.participants = (1...4).map { Self.person("Zoë Ñúñez \($0)", "z\($0)@exämple.de") }
    let block = MeetingSummary.factsBlock(facts)
    let calls = Calls()
    _ = try await MeetingSummary.write(
      transcript: Array(repeating: "Speaker 1: on y va vendredi", count: 400).joined(separator: "\n"),
      notes: String(repeating: "ma note sur le budget\n", count: 300), facts: block,
      window: Self.small, callTimeoutSeconds: 60, admit: {}, complete: calls.complete)
    #expect(calls.prompts.last?.contains(block) == true)
    #expect(calls.prompts.allSatisfy { MeetingSummaryTests.fitsInEstimate($0, Self.small) })
  }

  @Test("a block the byte plan cannot fit with the minimum input is refused, not dropped")
  func tooLongForBytePlan() throws {
    var facts = Self.acme
    facts.participants = (1...25).map { Self.person("Participant Number \($0)", "p\($0)@example.org") }
    let block = MeetingSummary.factsBlock(facts)
    #expect(throws: MeetingSummary.Failure.windowTooSmall) {
      _ = try MeetingSummary.inputBudget(Self.small, .bytes, facts: block)
    }
    #expect(
      try MeetingSummary.inputBudget(Self.small, .estimate, facts: block)
        >= MeetingSummary.minimumInputTokens)
  }
}
