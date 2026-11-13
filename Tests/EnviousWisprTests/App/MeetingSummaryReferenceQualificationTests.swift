import EnviousWisprAppKitTestSupport
import EnviousWisprLocalPolish
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprEG1Engine
@testable import EnviousWisprLLM

/// #3147 PR4A (D5): the qualification run for summary references on the local summary routes
/// the app ships (Apple Intelligence, Ollama on this Mac, EG-1). It writes real summaries of
/// three made-up meetings with the reference prompt and records, per meeting, the raw answer,
/// the Markdown the reader gets and the links the production validator accepts.
///
/// When this fails, a route marked qualified shows tags as text, loses the summary's shape, or
/// cites lines it never read. It decides `MeetingSummaryReferences.isQualified`; a route that
/// fails stays unqualified (plain summary, no links).
///
/// Real models, so it runs only in the real-world run, and only for the route it is given:
/// `TEST_RUNNER_EW_SUMMARY_REFS_ROUTE=apple|ollama:<model>|eg1:<full|mini|micro>`
/// `TEST_RUNNER_EW_SUMMARY_REFS_OUT=<file for the results JSON>` (outside the checkout)
/// `scripts/xcode-test.sh --real-boundary --filter EnviousWisprTests/MeetingSummaryReferenceQualificationTests`
/// No hosted route is ever called here.
@Suite(
  "Summary references qualify on a real local summary route (#3147 D5)",
  .serialized, .tags(.productOutcome, .realBoundary), .realBoundaryRun)
struct MeetingSummaryReferenceQualificationTests {
  static var route: String? {
    let value = ProcessInfo.processInfo.environment["EW_SUMMARY_REFS_ROUTE"] ?? ""
    return value.isEmpty ? nil : value
  }
  static var outFile: String? {
    let value = ProcessInfo.processInfo.environment["EW_SUMMARY_REFS_OUT"] ?? ""
    return value.isEmpty ? nil : value
  }
  static var canRun: Bool { route != nil && outFile != nil }

  // MARK: - Made-up meetings

  struct Meeting {
    let name: String
    let sources: MeetingSummaryReferenceSources
  }

  static func turns(_ lines: [(String, String)]) -> [MeetingSummaryTurnSource] {
    lines.enumerated().map { index, line in
      MeetingSummaryTurnSource(id: "turn-\(index + 1)", speaker: line.0, text: line.1)
    }
  }

  static let launch = Meeting(
    name: "launch",
    sources: .init(
      turns: turns([
        ("Priya", "Thanks for joining. Today we decide the launch date for the mobile app."),
        ("You", "Engineering is ready. The last crash fix merged yesterday."),
        ("Marco", "Marketing needs one more week for the store screenshots."),
        ("Priya", "Then we launch on March 14."),
        ("You", "I will send the release notes to Marco by Friday."),
        ("Marco", "I will book the press briefing for March 13."),
        ("Priya", "Pricing stays at four dollars a month."),
        ("You", "Support should get the help articles before launch."),
        ("Priya", "Lena will write the help articles next week."),
        ("Marco", "Great, that covers everything on my side."),
      ]),
      notes: [
        .init(
          blockID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
          text: "Check the Android build size"),
        .init(
          blockID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
          text: "Ask Lena about screenshots in German"),
      ]))

  static let hiring = Meeting(
    name: "hiring",
    sources: .init(
      turns: turns([
        ("Speaker 1", "We have three candidates left for the data engineer role."),
        ("You", "Ana did best in the system design interview."),
        ("Speaker 1", "Her salary ask is above our band by ten percent."),
        ("You", "We can offer the top of the band plus a signing bonus."),
        ("Speaker 1", "Agreed. I will call Ana tomorrow with the offer."),
        ("You", "If she declines, we interview the backup candidate next Tuesday."),
        ("Speaker 1", "The team lunch with her is still on for Thursday."),
      ]),
      notes: []))

  /// Long enough that a small window writes it in parts.
  static let planning: Meeting = {
    var lines: [(String, String)] = []
    let topics = [
      "the billing migration", "the new onboarding flow", "the reporting dashboard",
      "the search latency work", "the partner integration", "the accessibility audit",
    ]
    for (index, topic) in topics.enumerated() {
      lines += [
        ("Owner \(index + 1)", "Status on \(topic): we finished the design review last week."),
        ("You", "What is blocking \(topic) right now?"),
        (
          "Owner \(index + 1)",
          "We are waiting on two answers from the platform team about \(topic)."
        ),
        ("You", "I will ask the platform team for those answers today."),
        ("Owner \(index + 1)", "Then \(topic) can ship before the end of the quarter."),
        ("You", "Let us keep \(topic) on the roadmap for this quarter."),
      ]
      for filler in 0..<40 {
        lines.append(
          (
            "Owner \(index + 1)",
            "Detail \(filler + 1) about \(topic): we checked the numbers again and the estimates still hold, with the usual risk around testing time and reviews."
          ))
      }
    }
    return Meeting(name: "planning", sources: .init(turns: turns(lines), notes: []))
  }()

  static let meetings = [launch, hiring, planning]

  static let inputs = SummaryInputs(
    transcriptSHA256: "qualification", notesRevision: 0, speakerNamesSHA256: "",
    promptVersion: MeetingSummaryReferences.promptVersion, providerID: "qualification",
    configurationSHA256: "qualification")

  // MARK: - Routes

  struct Route: Sendable {
    let window: MeetingSummary.Window
    let complete: MeetingSummary.Complete
    let stop: @Sendable () -> Void
  }

  static func prepare(_ route: String) async throws -> Route {
    if route == "apple" {
      let prepared = try await MeetingSummaryProviders.prepare(
        provider: .appleIntelligence, model: "", cloudModelList: nil, keychain: KeychainManager()
      ).get()
      return Route(window: prepared.window, complete: prepared.complete, stop: {})
    }
    if route.hasPrefix("ollama:") {
      let model = String(route.dropFirst("ollama:".count))
      // Local models only: a cloud model would be cloud spend.
      try #require(!model.hasSuffix("cloud"), "a local Ollama model only")
      let prepared = try await MeetingSummaryProviders.prepare(
        provider: .ollama, model: model, cloudModelList: nil, keychain: KeychainManager()
      ).get()
      try #require(prepared.execution == .local, "the Ollama model runs on this Mac")
      return Route(window: prepared.window, complete: prepared.complete, stop: {})
    }
    if route.hasPrefix("eg1:") {
      let size = String(route.dropFirst("eg1:".count))
      let folder = size == "full" ? "eg-1" : "eg-1-\(size)"
      let model = URL.applicationSupportDirectory
        .appendingPathComponent("EnviousWispr/Models/\(folder)").path
      let context = size == "micro" ? 8_192 : 16_384
      let helper = try EnviousDecodeHelperIntegrationTests.Helper(
        model: model, draft: model + "/helper", contextTokens: context)
      try await helper.untilReady()
      let endpoint = helper.endpoint
      return Route(
        window: .init(contextTokens: context, outputReserveTokens: MeetingSummary.outputTokens),
        complete: { instructions, prompt in
          try await EGOneSummaryCall.complete(
            endpoint: endpoint, instructions: instructions, prompt: prompt,
            timeoutSeconds: 300)
        },
        stop: { helper.stop() })
    }
    throw CancellationError()
  }

  // MARK: - The run

  final class Answers: @unchecked Sendable {
    // Written by the summary's sequential calls only.
    var last = ""
    var calls = 0
  }

  struct Result: Codable {
    let route: String
    let meeting: String
    let inParts: Bool
    let calls: Int
    let rawFinalAnswer: String
    let readerMarkdown: String
    let leftoverTagText: Bool
    let hasSection: Bool
    let items: Int
    let itemsWithResolvableTag: Int
    let tagsInFinalAnswer: Int
    let inventedTags: Int
    let linkedItems: [String]
    let error: String?
  }

  /// Any bracketed or bare tag-like text left for the reader.
  static func hasTagText(_ text: String) -> Bool {
    text.range(of: #"\[\s*[TN]\d+|\b[TN]\d{1,4}\b"#, options: .regularExpression) != nil
  }

  static func tags(in text: String) -> [MeetingSummaryReferences.Tag] {
    text.components(separatedBy: "\n").flatMap { MeetingSummaryReferences.strip($0).tags }
  }

  @Test("each made-up meeting: no tag text for the reader, its shape kept, real tags only")
  func qualify() async throws {
    let route = try #require(Self.route)
    let outFile = try #require(Self.outFile)
    let prepared = try await Self.prepare(route)
    defer { prepared.stop() }
    var results: [Result] = []
    for meeting in Self.meetings {
      let answers = Answers()
      let complete: MeetingSummary.Complete = { instructions, prompt in
        let answer = try await prepared.complete(instructions, prompt)
        answers.last = answer
        answers.calls += 1
        return answer
      }
      do {
        let written = try await MeetingSummary.write(
          transcript: meeting.sources.taggedTranscript,
          notes: meeting.sources.notes.isEmpty ? "" : meeting.sources.taggedNotes, facts: "",
          window: prepared.window, callTimeoutSeconds: 300,
          references: .init(sources: meeting.sources, inputs: Self.inputs), admit: {},
          complete: complete)
        let reader = MeetingSummary.splitTitle(written.text).summary
        let items = written.document?.sections.flatMap(\.items) ?? []
        let finalTags = Self.tags(in: answers.last)
        let invented = finalTags.filter {
          switch $0 {
          case .turn(let n): n > meeting.sources.turns.count
          case .note(let n): n > meeting.sources.notes.count
          }
        }
        let linked = items.filter {
          !MeetingSummaryReferenceValidator.supportingSources(of: $0, in: meeting.sources).isEmpty
        }
        results.append(
          Result(
            route: route, meeting: meeting.name, inParts: written.inParts, calls: answers.calls,
            rawFinalAnswer: answers.last, readerMarkdown: reader,
            leftoverTagText: Self.hasTagText(reader), hasSection: reader.contains("## "),
            items: items.count,
            itemsWithResolvableTag: items.filter { !$0.citations.isEmpty }.count,
            tagsInFinalAnswer: finalTags.count, inventedTags: invented.count,
            linkedItems: linked.map(\.text), error: nil))
      } catch {
        results.append(
          Result(
            route: route, meeting: meeting.name, inParts: false, calls: answers.calls,
            rawFinalAnswer: answers.last, readerMarkdown: "", leftoverTagText: false,
            hasSection: false, items: 0, itemsWithResolvableTag: 0, tagsInFinalAnswer: 0,
            inventedTags: 0, linkedItems: [], error: String(describing: error)))
      }
    }
    // Control: the long meeting with the plain prompt, so a failure there can be told apart
    // from one the reference prompt causes. Recorded only, never part of the bar.
    if ProcessInfo.processInfo.environment["EW_SUMMARY_REFS_PLAIN_CONTROL"] == "1" {
      let answers = Answers()
      var outcome = "written"
      do {
        _ = try await MeetingSummary.write(
          transcript: Self.planning.sources.plainTranscript, notes: "", facts: "",
          window: prepared.window, callTimeoutSeconds: 300, admit: {},
          complete: { instructions, prompt in
            let answer = try await prepared.complete(instructions, prompt)
            answers.calls += 1
            return answer
          })
      } catch { outcome = String(describing: error) }
      results.append(
        Result(
          route: route, meeting: "planning-plain-control", inParts: false, calls: answers.calls,
          rawFinalAnswer: "", readerMarkdown: "", leftoverTagText: false, hasSection: false,
          items: 0, itemsWithResolvableTag: 0, tagsInFinalAnswer: 0, inventedTags: 0,
          linkedItems: [], error: outcome))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(results).write(to: URL(fileURLWithPath: outFile))

    // The qualification bar, per meeting.
    for result in results where result.meeting != "planning-plain-control" {
      #expect(result.error == nil, "\(result.meeting): \(result.error ?? "")")
      #expect(result.leftoverTagText == false, "\(result.meeting): tag text left for the reader")
      #expect(result.hasSection, "\(result.meeting): no section heading")
      #expect(result.items > 0, "\(result.meeting): no items")
      if result.meeting == "planning" {
        #expect(result.inParts, "planning: the long meeting was not written in parts")
      }
      #expect(
        result.itemsWithResolvableTag * 10 >= result.items * 8,
        "\(result.meeting): fewer than 80% of items carry a real tag")
      #expect(
        result.inventedTags * 10 <= result.tagsInFinalAnswer,
        "\(result.meeting): more than 10% of tags name no line")
    }
  }
}
