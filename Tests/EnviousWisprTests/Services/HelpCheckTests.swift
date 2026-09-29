import Foundation
import Testing

@testable import EnviousWisprServices

/// #3275: the in-app help check. A fake split, a fake network and a fake clock; nothing here
/// reaches Apple's model or enviouswispr.com. Expected values are literals.
@Suite("In-app help check (#3275)", .tags(.productOutcome))
struct HelpCheckTests {

  // MARK: - Fixtures

  typealias Concern = HelpCheckConcern

  /// Records every request and answers from a script.
  final class FakeTransport: @unchecked Sendable {
    enum Answer {
      case reply(Int, Data)
      case fail(Error)
      /// Never answers and ignores cancellation, like a stuck connection.
      case hang
    }
    private let lock = NSLock()
    private var script: [Answer]
    private var seen: [URLRequest] = []
    init(_ script: [Answer]) { self.script = script }
    var requests: [URLRequest] { lock.withLock { seen } }

    var transport: HelpCheckClient.Transport {
      { [self] request in
        let answer: Answer = lock.withLock {
          seen.append(request)
          return script.isEmpty ? .fail(URLError(.badServerResponse)) : script.removeFirst()
        }
        switch answer {
        case .reply(let status, let body): return (status, body)
        case .fail(let error): throw error
        case .hang:
          await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
          throw URLError(.timedOut)
        }
      }
    }

    func body(_ index: Int = 0) throws -> [String: Any] {
      let data = try #require(requests[index].httpBody)
      return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
  }

  static var versions: [String: Any] {
    [
      "kb_version": "72134d105fb3", "jev_model_version": "jev-1.13.0",
      "decomposition_version": "afm-kit-1", "decision_version": "2026-09-28.1",
      "threshold_version": "g3-0.5-0.5-u0.5-0.5-0.7-0.7-0.8-c0.5", "app_version": "2.6.0",
    ]
  }

  /// Scores that pass the server's g3 gates for a section card and a page link.
  static var sectionScores: [String: Any] {
    [
      "page_p": 0.9, "page_confidence": 0.9, "useful": 0.9, "section_p": 0.9,
      "section_confidence": 0.9, "resolves": 0.9,
    ]
  }
  static var pageScores: [String: Any] {
    [
      "page_p": 0.9, "page_confidence": 0.9, "useful": 0.9, "section_p": 0.3,
      "section_confidence": 0.9, "resolves": 0.9,
    ]
  }

  static func section(
    _ id: String, slug: String = "toggle-mode", anchor: String = "turning-it-on",
    deflection: String = "can_resolve", eligible: Bool = true
  ) -> [String: Any] {
    [
      "id": id, "match_type": "section", "page_slug": slug, "section_id": "\(slug)#\(anchor)",
      "heading": "Turning it on", "text": "Open Settings.",
      "url": "https://enviouswispr.com/help/\(slug)/#\(anchor)", "deflection": deflection,
      "scores": sectionScores, "resolution_eligible": eligible, "requires_send": !eligible,
    ]
  }

  static func page(_ id: String, slug: String = "paste-not-working") -> [String: Any] {
    [
      "id": id, "match_type": "page", "page_slug": slug, "section_id": NSNull(),
      "heading": "Paste Not Working", "text": NSNull(),
      "url": "https://enviouswispr.com/help/\(slug)/", "deflection": "show_but_always_send",
      "scores": pageScores, "resolution_eligible": false, "requires_send": true,
    ]
  }

  static func none(_ id: String) -> [String: Any] {
    [
      "id": id, "match_type": "none", "page_slug": NSNull(), "section_id": NSNull(),
      "heading": NSNull(), "text": NSNull(), "url": NSNull(), "deflection": NSNull(),
      "scores": [:] as [String: Any], "resolution_eligible": false, "requires_send": true,
    ]
  }

  static func reply(
    _ issues: [[String: Any]], suppression: Bool = true, coverage: Double? = 0.9,
    status: String = "ok", reason: String = "matched"
  ) -> Data {
    var body: [String: Any] = [
      "v": 1, "status": status, "reason": reason, "suppression_allowed": suppression,
      "issues": issues, "coverage": coverage.map { $0 as Any } ?? NSNull(),
    ]
    body.merge(versions) { a, _ in a }
    return try! JSONSerialization.data(withJSONObject: body)
  }

  /// A fake clock: a deadline named in `firing` fires at once; any other deadline stays pending
  /// until the check cancels it.
  static func clock(firing: Set<Duration> = []) -> HelpCheck.Sleep {
    { duration in
      if firing.contains(duration) { return }
      try await Task.sleep(for: .seconds(3600))  // test-fixture-timer: a deadline that must not fire in this test; the check cancels it
    }
  }

  static func check(
    _ split: HelpCheckDecomposition, _ transport: FakeTransport, firing: Set<Duration> = []
  ) -> HelpCheck {
    HelpCheck(
      decompose: { _ in split }, decompositionVersion: "afm-kit-1",
      client: HelpCheckClient(transport: transport.transport), appVersion: "2.6.0",
      sleep: clock(firing: firing))
  }

  // MARK: - Preparing the concerns

  @Test("Quotes are placed by UTF-16 range in the untouched message, emoji included")
  func utf16Offsets() {
    let message = "👍🏽 paste fails in Slack"
    #expect(HelpCheckPreparation.utf16Range(of: "paste fails in Slack", in: message) == 5..<25)
    // Capitalised by the model: placed where the message's own text is.
    #expect(HelpCheckPreparation.utf16Range(of: "Paste fails in Slack", in: message) == 5..<25)
    #expect(HelpCheckPreparation.utf16Range(of: "paste fails in Notes", in: message) == nil)
    #expect(HelpCheckPreparation.utf16Range(of: "  ", in: message) == nil)
    // Twice in the message: ambiguous, so not placed.
    #expect(HelpCheckPreparation.utf16Range(of: "it", in: "it fails and it hangs") == nil)
    #expect(HelpCheckPreparation.utf16Range(of: "fails", in: "it fails and it hangs") == 3..<8)
  }

  @Test("Only exact repeats merge; a quote inside another quote is a different concern")
  func coalescing() {
    let message =
      "Can I press once to start and once to stop? The hold key conflicts with my work shortcut."
    let first = Concern(
      summary: "Press once to start and stop",
      evidence: "Can I press once to start and once to stop?",
      kind: .howTo)
    // Containment counterexample: a shorter quote inside another concern's quote.
    let inside = Concern(summary: "Start and stop", evidence: "press once to start", kind: .howTo)
    let conflict = Concern(
      summary: "Key conflicts with a work shortcut",
      evidence: "The hold key conflicts with my work shortcut.", kind: .bug)
    // Padding the macOS 26 model produces: the same concern again, spacing and case aside.
    let repeatOfFirst = Concern(
      summary: "  press ONCE to start and stop ",
      evidence: "Can I press once to start and once to stop?",
      kind: .howTo)
    // Same quote, different summary: kept.
    let sameQuoteOtherSummary = Concern(
      summary: "Toggle mode", evidence: "Can I press once to start and once to stop?", kind: .howTo)
    // Same quote and summary, different kind: kept.
    let otherKind = Concern(
      summary: "Press once to start and stop",
      evidence: "Can I press once to start and once to stop?",
      kind: .featureRequest)

    let prepared = HelpCheckPreparation.prepare(
      [first, inside, repeatOfFirst, conflict, sameQuoteOtherSummary, otherKind], hitCap: false,
      in: message)
    #expect(prepared.issues.map(\.id) == ["i0", "i1", "i2", "i3", "i4"])
    #expect(
      prepared.issues.map(\.summary) == [
        "Press once to start and stop", "Start and stop", "Key conflicts with a work shortcut",
        "Toggle mode", "Press once to start and stop",
      ])
    #expect(prepared.issues[0].startUTF16 == 0)
    #expect(prepared.issues[0].endUTF16 == 43)
    #expect(prepared.overflow == false)
  }

  @Test("Two unplaced quotes are never merged, and a list at the model's cap is marked overflow")
  func unplacedAndOverflow() {
    let message = "banana"
    let invented = Concern(
      summary: "Not working", evidence: "EnviousWispr is not working", kind: .bug)
    let prepared = HelpCheckPreparation.prepare([invented, invented], hitCap: true, in: message)
    #expect(prepared.issues.count == 2)
    #expect(prepared.issues.allSatisfy { $0.startUTF16 == nil && $0.endUTF16 == nil })
    #expect(prepared.overflow == true)
  }

  // MARK: - Reading the reply

  @Test("A well-formed reply decodes in order with its versions")
  func replyDecodes() throws {
    let data = Self.reply(
      [Self.section("i0"), Self.page("i1"), Self.none("i2")], suppression: false)
    let reply = try #require(HelpCheckReply.decode(data, expectedIssues: 3))
    #expect(reply.results.map(\.matchType) == [.section, .page, .none])
    #expect(reply.results[0].deflection == .canResolve)
    #expect(
      reply.results[0].url?.absoluteString
        == "https://enviouswispr.com/help/toggle-mode/#turning-it-on")
    #expect(reply.coverage == 0.9)
    #expect(reply.versions?.kb == "72134d105fb3")
    // A server that does not send page titles still decodes; the card falls back to the heading.
    #expect(reply.results.map(\.pageTitle) == [nil, nil, nil])
  }

  @Test("A page title travels with a match, and a title on an unmatched concern is refused")
  func pageTitle() throws {
    var section = Self.section("i0")
    section["page_title"] = "Toggle Mode"
    var page = Self.page("i1")
    page["page_title"] = "Paste Not Working"
    let reply = try #require(
      HelpCheckReply.decode(Self.reply([section, page], suppression: false), expectedIssues: 2))
    #expect(reply.results.map(\.pageTitle) == ["Toggle Mode", "Paste Not Working"])
    var none = Self.none("i0")
    none["page_title"] = "Toggle Mode"
    #expect(HelpCheckReply.decode(Self.reply([none], suppression: false), expectedIssues: 1) == nil)
  }

  @Test(
    "A malformed or contradictory reply is refused",
    arguments: [
      "wrong order", "wrong count", "never_intervene", "other host", "page marked eligible",
      "show_but_always_send eligible", "eligible but requires send", "send_feedback with issues",
      "coverage out of range", "unknown match", "section without id", "low section confidence",
      "low resolves", "page link below 0.8", "missing score", "score out of range",
      "missing versions", "wrong anchor link", "page link with anchor",
    ])
  func replyRefused(kind: String) {
    var issues: [[String: Any]] = [
      Self.section("i0"), Self.section("i1", slug: "paste-not-working"),
    ]
    var coverage: Double? = 0.9
    var status = "ok"
    var expected = 2
    var dropVersions = false
    switch kind {
    case "wrong order": issues[1]["id"] = "i0"
    case "wrong count": expected = 3
    case "never_intervene": issues[0]["deflection"] = "never_intervene"
    case "other host": issues[0]["url"] = "https://example.com/help/toggle-mode/#turning-it-on"
    case "page marked eligible":
      issues[1] = Self.page("i1")
      issues[1]["resolution_eligible"] = true
    case "show_but_always_send eligible": issues[0]["deflection"] = "show_but_always_send"
    case "eligible but requires send": issues[0]["requires_send"] = true
    case "send_feedback with issues": status = "send_feedback"
    case "coverage out of range": coverage = 1.5
    case "unknown match": issues[0]["match_type"] = "article"
    case "section without id": issues[0]["section_id"] = NSNull()
    case "low section confidence": issues[0]["scores"] = Self.withScore("section_confidence", 0.69)
    case "low resolves": issues[0]["scores"] = Self.withScore("resolves", 0.69)
    case "page link below 0.8":
      var scores = Self.pageScores
      scores["page_p"] = 0.79
      issues[1] = Self.page("i1")
      issues[1]["scores"] = scores
    case "missing score":
      var scores = Self.sectionScores
      scores.removeValue(forKey: "useful")
      issues[0]["scores"] = scores
    case "score out of range": issues[0]["scores"] = Self.withScore("section_p", 1.01)
    case "missing versions": dropVersions = true
    case "wrong anchor link": issues[0]["url"] = "https://enviouswispr.com/help/toggle-mode/#other"
    case "page link with anchor":
      issues[1] = Self.page("i1")
      issues[1]["url"] = "https://enviouswispr.com/help/paste-not-working/#x"
    default: Issue.record("unknown case \(kind)")
    }
    var data = Self.reply(issues, coverage: coverage, status: status)
    if dropVersions {
      var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
      object["kb_version"] = NSNull()
      data = try! JSONSerialization.data(withJSONObject: object)
    }
    #expect(HelpCheckReply.decode(data, expectedIssues: expected) == nil)
  }

  static func withScore(_ key: String, _ value: Double) -> [String: Any] {
    var scores = sectionScores
    scores[key] = value
    return scores
  }

  @Test("Scores exactly at the gates are accepted")
  func scoresAtGates() {
    var scores = Self.sectionScores
    for (key, value) in [
      ("page_p", 0.5), ("page_confidence", 0.5), ("useful", 0.5), ("section_p", 0.5),
      ("section_confidence", 0.7), ("resolves", 0.7),
    ] { scores[key] = value }
    var section = Self.section("i0")
    section["scores"] = scores
    var page = Self.page("i1")
    var pageScores = Self.pageScores
    pageScores["page_p"] = 0.8
    page["scores"] = pageScores
    #expect(HelpCheckReply.decode(Self.reply([section, page], suppression: false), expectedIssues: 2) != nil)
  }

  // MARK: - When "all solved" may end a report

  static func suggestions(
    _ issues: [[String: Any]], suppression: Bool = true, coverage: Double? = 0.9,
    mode: FeedbackHelpOutcome.Mode = .decomposed, overflow: Bool = false, anchored: [Bool]? = nil
  ) -> HelpCheckSuggestions {
    let reply = HelpCheckReply.decode(
      reply(issues, suppression: suppression, coverage: coverage), expectedIssues: issues.count)!
    return HelpCheckSuggestions(
      mode: mode, overflow: overflow, reply: reply,
      anchored: anchored ?? Array(repeating: true, count: issues.count), splitFailure: nil)
  }

  @Test("All solved is offered only when every rule holds; each broken rule alone blocks it")
  func suppressionRule() {
    let two = [Self.section("i0"), Self.section("i1", slug: "paste-not-working", anchor: "fix-it")]
    #expect(Self.suggestions(two).suppressionAllowed == true)
    #expect(Self.suggestions(two, suppression: false).suppressionAllowed == false)
    #expect(Self.suggestions(two, coverage: 0.49).suppressionAllowed == false)
    #expect(Self.suggestions(two, coverage: nil).suppressionAllowed == false)
    #expect(Self.suggestions(two, overflow: true).suppressionAllowed == false)
    #expect(Self.suggestions(two, anchored: [true, false]).suppressionAllowed == false)
    #expect(
      Self.suggestions([Self.section("i0")], mode: .wholeMessageAlwaysSend).suppressionAllowed
        == false)
    #expect(Self.suggestions([Self.section("i0"), Self.page("i1")]).suppressionAllowed == false)
    #expect(Self.suggestions([Self.section("i0"), Self.none("i1")]).suppressionAllowed == false)
    #expect(
      Self.suggestions([Self.section("i0", deflection: "show_but_always_send", eligible: false)])
        .suppressionAllowed == false)
    // A concern beyond the three cards is not shown, so it cannot be confirmed solved.
    let four = (0..<4).map { Self.section("i\($0)", anchor: "a\($0)") }
    #expect(Self.suggestions(four).cards.count == 3)
    #expect(Self.suggestions(four).suppressionAllowed == false)
    // An unanchored quote's card can be shown but never marked solved.
    #expect(Self.suggestions(two, anchored: [true, false]).canMarkSolved("i0") == true)
    #expect(Self.suggestions(two, anchored: [true, false]).canMarkSolved("i1") == false)
  }

  @Test("Concerns that share a help section share one card")
  func cardsGroupByTarget() {
    let s = Self.suggestions([Self.section("i0"), Self.page("i1"), Self.section("i2")])
    #expect(s.cards.count == 2)
    #expect(s.cards[0].issueIDs == ["i0", "i2"])
    #expect(s.cards[1].issueIDs == ["i1"])
  }

  // MARK: - Running the check

  @Test("A split concern list is sent with offsets, no email and the exact endpoint")
  func requestShape() async throws {
    let message = "My keybind stopped working."
    let transport = FakeTransport([.reply(200, Self.reply([Self.section("i0")]))])
    let check = Self.check(
      .concerns(
        [Concern(summary: "Keybind broken", evidence: "keybind stopped working", kind: .bug)],
        hitCap: false),
      transport)
    guard case .suggestions(let s) = await check.run(message) else {
      Issue.record("expected suggestions")
      return
    }
    #expect(s.suppressionAllowed == true)
    #expect(transport.requests.count == 1)
    #expect(
      transport.requests[0].url?.absoluteString == "https://enviouswispr.com/api/app/help-check")
    #expect(transport.requests[0].httpMethod == "POST")
    let body = try transport.body()
    #expect(
      Set(body.keys) == [
        "v", "original_message", "mode", "issues", "overflow", "decomposition_version",
        "app_version",
      ])
    #expect(body["original_message"] as? String == message)
    #expect(body["mode"] as? String == "decomposed")
    let issue = try #require((body["issues"] as? [[String: Any]])?.first)
    #expect(issue["start_utf16"] as? Int == 3)
    #expect(issue["end_utf16"] as? Int == 26)
    #expect(issue["kind"] as? String == "bug")
  }

  @Test("No on-device split: the whole message is checked and can never be suppressed")
  func wholeMessage() async throws {
    let transport = FakeTransport([
      .reply(200, Self.reply([Self.section("i0", eligible: false)], suppression: false))
    ])
    let check = Self.check(.unavailable(.afmUnavailable), transport)
    guard case .suggestions(let s) = await check.run("Paste fails in Slack.") else {
      Issue.record("expected suggestions")
      return
    }
    #expect(s.mode == .wholeMessageAlwaysSend)
    #expect(s.suppressionAllowed == false)
    #expect(s.canMarkSolved("i0") == false)
    let body = try transport.body()
    #expect(body["mode"] as? String == "whole_message_always_send")
    #expect((body["issues"] as? [Any])?.isEmpty == true)
  }

  @Test("A split that passes 4 seconds and ignores cancellation falls back to the whole message")
  func splitTimeout() async throws {
    let transport = FakeTransport([
      .reply(200, Self.reply([Self.section("i0", eligible: false)], suppression: false))
    ])
    let check = HelpCheck(
      decompose: { _ in
        // Never returns, even when cancelled.
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        return .concerns([], hitCap: false)
      }, decompositionVersion: "afm-kit-1", client: HelpCheckClient(transport: transport.transport),
      appVersion: "2.6.0", sleep: Self.clock(firing: [HelpCheck.decompositionDeadline]))
    guard case .suggestions(let s) = await check.run("Paste fails in Slack.") else {
      Issue.record("expected suggestions")
      return
    }
    #expect(s.mode == .wholeMessageAlwaysSend)
    #expect(s.splitFailure == .afmTimeout)
    #expect(try transport.body()["mode"] as? String == "whole_message_always_send")
  }

  @Test("A check that passes 7 seconds sends the report as written, whatever is still running")
  func overallTimeout() async {
    let transport = FakeTransport([.hang])
    let check = Self.check(
      .concerns([Concern(summary: "s", evidence: "Paste", kind: .bug)], hitCap: false), transport,
      firing: [HelpCheck.overallDeadline])
    guard case .send(let outcome, _) = await check.run("Paste fails.") else {
      Issue.record("expected send")
      return
    }
    #expect(outcome.terminalOutcome == .fallbackSent)
    #expect(outcome.failureReason == .timeout)
  }

  @Test(
    "Network and server failures send the report as written with a closed reason",
    arguments: [
      ("500", FeedbackHelpOutcome.FailureReason.httpError),
      ("offline", .network),
      ("timed out", .timeout),
      ("garbage", .badReply),
      ("disabled", .disabled),
      ("http_503", .httpError),
      ("strange", .badReply),
    ])
  func failuresSend(answer: String, reason: FeedbackHelpOutcome.FailureReason) async {
    let script: FakeTransport.Answer
    switch answer {
    case "500": script = .reply(500, Data())
    case "offline": script = .fail(URLError(.notConnectedToInternet))
    case "timed out": script = .fail(URLError(.timedOut))
    case "garbage": script = .reply(200, Data("{".utf8))
    default:
      script = .reply(
        200, Self.reply([], suppression: false, status: "send_feedback", reason: answer))
    }
    let transport = FakeTransport([script])
    let check = Self.check(
      .concerns([Concern(summary: "s", evidence: "Paste", kind: .bug)], hitCap: false), transport)
    guard case .send(let outcome, _) = await check.run("Paste fails.") else {
      Issue.record("expected send for \(answer)")
      return
    }
    #expect(outcome.terminalOutcome == .fallbackSent)
    #expect(outcome.failureReason == reason)
    #expect(transport.requests.count == 1, "one attempt, no retry")
  }

  @Test("A skipped split's reason travels with an immediate send, for counting")
  func splitFailureCarried() async {
    let transport = FakeTransport([.reply(200, Self.reply([Self.none("i0")], suppression: false))])
    let check = Self.check(.unavailable(.afmRefused), transport)
    guard case .send(let outcome, let splitFailure) = await check.run("Paste fails.") else {
      Issue.record("expected send")
      return
    }
    #expect(splitFailure == .afmRefused)
    #expect(outcome.mode == .wholeMessageAlwaysSend)
    let failing = FakeTransport([.fail(URLError(.notConnectedToInternet))])
    guard case .send(_, let reason) = await Self.check(.unavailable(.afmTimeout), failing).run("x y")
    else {
      Issue.record("expected send")
      return
    }
    #expect(reason == .afmTimeout)
  }

  @Test("Nothing to show sends at once, recording the unmatched concerns")
  func nothingToShow() async {
    let transport = FakeTransport([.reply(200, Self.reply([Self.none("i0")], suppression: false))])
    let check = Self.check(
      .concerns([Concern(summary: "s", evidence: "Paste", kind: .bug)], hitCap: false), transport)
    guard case .send(let outcome, _) = await check.run("Paste fails.") else {
      Issue.record("expected send")
      return
    }
    #expect(outcome.terminalOutcome == .stillSent)
    #expect(outcome.issues.map(\.resolution) == [.unmatched])
    #expect(outcome.versions?.kb == "72134d105fb3")
  }

  // MARK: - The shared submission owner

  @MainActor
  final class RecordingSave {
    private(set) var saves: [(draft: FeedbackDraft, help: FeedbackHelpOutcome?)] = []
    func save(_ draft: FeedbackDraft, _: FeedbackDiagnosticsSnapshot?, _ help: FeedbackHelpOutcome?)
      async -> FeedbackReporter.Outcome
    {
      saves.append((draft, help))
      return .saved(offline: false)
    }
  }

  static func makeStore() -> (FeedbackDraftStore, String) {
    let suite = "HelpCheckTests.\(UUID().uuidString)"
    return (FeedbackDraftStore(defaults: { UserDefaults(suiteName: suite)! }), suite)
  }

  @Test("Cards wait for the user; the report saved is the one frozen at Send, with its outcome")
  @MainActor
  func submissionWithCards() async throws {
    let (store, suite) = Self.makeStore()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let recorder = RecordingSave()
    let message = "Keybind broke. Paste fails too."
    let transport = FakeTransport([
      .reply(
        200,
        Self.reply([
          Self.section("i0"), Self.section("i1", slug: "paste-not-working", anchor: "fix-it"),
        ]))
    ])
    let submission = FeedbackSubmission(
      store: store, save: recorder.save,
      helpCheck: Self.check(
        .concerns(
          [
            Concern(summary: "Keybind", evidence: "Keybind broke.", kind: .bug),
            Concern(summary: "Paste", evidence: "Paste fails too.", kind: .bug),
          ], hitCap: false), transport))
    let presentation = UUID()
    store.save(message: message, email: "")
    let draft = try #require(FeedbackDraft(message: message, email: ""))
    let step = await submission.send(
      draft, diagnostics: nil, from: presentation, sent: (message, ""),
      current: { .init(presentation: presentation, message: message, email: "") })
    guard case .suggestions(let s) = step else {
      Issue.record("expected suggestions")
      return
    }
    #expect(s.suppressionAllowed == true)
    #expect(recorder.saves.isEmpty, "nothing is sent while cards are on offer")
    #expect(submission.helpPhase == .suggestions(s))
    // A second Send while cards are on offer does nothing.
    #expect(
      await submission.send(
        draft, diagnostics: nil, from: presentation, sent: (message, ""),
        current: { .init(presentation: presentation, message: message, email: "") }) == .busy)
    // The user edits the draft meanwhile; the report stays the words sent.
    submission.recordEdit(message: "newer words", email: "")

    let generation = try #require(submission.helpGeneration)
    // A press from an older check is ignored.
    #expect(
      await submission.finishSuggestions(
        solved: ["i0"], generation: UUID(), from: presentation,
        current: { .init(presentation: presentation, message: "newer words", email: "") }) == nil)
    #expect(recorder.saves.isEmpty)
    submission.setHelpMark(
      "i0", solved: true, generation: generation, from: presentation,
      current: { .init(presentation: presentation, message: "newer words", email: "") })
    let outcome = await submission.finishSuggestions(
      solved: ["i0"], generation: generation, from: presentation,
      current: { .init(presentation: presentation, message: "newer words", email: "") })
    #expect(outcome == .saved(offline: false))
    #expect(recorder.saves.count == 1)
    #expect(recorder.saves[0].draft.message == message)
    let help = try #require(recorder.saves[0].help)
    #expect(help.terminalOutcome == .partialSent)
    #expect(help.issues.map(\.resolution) == [.solved, .stillHappening])
    #expect(help.shownCardCount == 2)
    #expect(submission.helpPhase == .idle)
    #expect(store.message == "newer words")
  }

  @Test("All solved ends the report without saving; refused where the check does not allow it")
  @MainActor
  func allSolved() async throws {
    for allowed in [true, false] {
      let (store, suite) = Self.makeStore()
      defer { UserDefaults().removePersistentDomain(forName: suite) }
      let recorder = RecordingSave()
      let message = "Keybind broke."
      let transport = FakeTransport([
        .reply(200, Self.reply([Self.section("i0")], suppression: allowed))
      ])
      let submission = FeedbackSubmission(
        store: store, save: recorder.save,
        helpCheck: Self.check(
          .concerns(
            [Concern(summary: "Keybind", evidence: "Keybind broke.", kind: .bug)], hitCap: false),
          transport))
      let presentation = UUID()
      store.save(message: message, email: "")
      let screen: @MainActor @Sendable () -> FeedbackSubmission.FormState = {
        FeedbackSubmission.FormState(presentation: presentation, message: message, email: "")
      }
      _ = await submission.send(
        try #require(FeedbackDraft(message: message, email: "")), diagnostics: nil,
        from: presentation, sent: (message, ""), current: screen)

      let generation = try #require(submission.helpGeneration)
      // Stale check, or not every concern confirmed: refused whatever the check allows.
      #expect(
        !submission.endWithAllSolved(
          confirmed: ["i0"], generation: UUID(), from: presentation, current: screen))
      #expect(
        !submission.endWithAllSolved(
          confirmed: [], generation: generation, from: presentation, current: screen))
      #expect(
        submission.endWithAllSolved(
          confirmed: ["i0"], generation: generation, from: presentation, current: screen)
          == allowed)
      #expect(recorder.saves.isEmpty)
      if allowed {
        #expect(store.message == "", "the draft is settled as if sent")
        #expect(submission.helpPhase == .idle)
        #expect(submission.completions == 1)
      } else {
        #expect(store.message == message)
        #expect(submission.helpPhase != .idle, "the cards stay until the user sends")
      }
    }
  }

  /// A submission with one or two can_resolve cards on offer, for the tests below.
  @MainActor
  static func withCards(
    _ store: FeedbackDraftStore, _ recorder: RecordingSave, message: String, coverage: Double = 0.9,
    presentation: UUID
  ) async throws -> FeedbackSubmission {
    let transport = FakeTransport([.reply(200, Self.reply([Self.section("i0")], coverage: coverage))])
    let submission = FeedbackSubmission(
      store: store, save: recorder.save,
      helpCheck: Self.check(
        .concerns([Concern(summary: "Keybind", evidence: message, kind: .bug)], hitCap: false),
        transport))
    store.save(message: message, email: "")
    _ = await submission.send(
      try #require(FeedbackDraft(message: message, email: "")), diagnostics: nil,
      from: presentation, sent: (message, ""),
      current: { .init(presentation: presentation, message: message, email: "") })
    return submission
  }

  @Test("Closing the cards saves nothing and keeps the draft, edits included")
  @MainActor
  func dismissKeepsDraft() async throws {
    let (store, suite) = Self.makeStore()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let recorder = RecordingSave()
    let a = UUID()
    let submission = try await Self.withCards(store, recorder, message: "Keybind broke.", presentation: a)
    let generation = try #require(submission.helpGeneration)
    submission.recordEdit(message: "Keybind broke. More detail.", email: "")
    let screen: @MainActor @Sendable () -> FeedbackSubmission.FormState = {
      .init(presentation: a, message: "Keybind broke. More detail.", email: "")
    }
    #expect(submission.dismissSuggestions(generation: generation, from: a, current: screen))
    #expect(recorder.saves.isEmpty)
    #expect(submission.helpPhase == .idle)
    #expect(submission.helpGeneration == nil)
    #expect(store.message == "Keybind broke. More detail.")
    // Nothing left to act on.
    #expect(!submission.dismissSuggestions(generation: generation, from: a, current: screen))
    #expect(
      await submission.finishSuggestions(solved: [], generation: generation, from: a, current: screen)
        == nil)
    #expect(recorder.saves.isEmpty)
  }

  @Test("A press from a closed opening is refused; the reopened opening's press is taken")
  @MainActor
  func oldOpeningRefused() async throws {
    let (store, suite) = Self.makeStore()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let recorder = RecordingSave()
    let a = UUID()
    let b = UUID()
    let message = "Keybind broke."
    let submission = try await Self.withCards(store, recorder, message: message, presentation: a)
    let generation = try #require(submission.helpGeneration)
    // Opening A closed; opening B shows the same cards.
    submission.presentationDisappeared(a)
    submission.presentationAppeared(b)
    let onScreenB: @MainActor @Sendable () -> FeedbackSubmission.FormState = {
      .init(presentation: b, message: message, email: "")
    }
    #expect(
      !submission.endWithAllSolved(confirmed: ["i0"], generation: generation, from: a, current: onScreenB))
    #expect(!submission.dismissSuggestions(generation: generation, from: a, current: onScreenB))
    #expect(
      await submission.finishSuggestions(solved: [], generation: generation, from: a, current: onScreenB)
        == nil)
    #expect(recorder.saves.isEmpty)
    #expect(
      submission.endWithAllSolved(confirmed: ["i0"], generation: generation, from: b, current: onScreenB))
    #expect(recorder.saves.isEmpty)
    #expect(store.message == "")
  }

  @Test("Solved marks outlive a closed popover; only the opening on screen may change or use them")
  @MainActor
  func marksResume() async throws {
    let (store, suite) = Self.makeStore()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let recorder = RecordingSave()
    let a = UUID()
    let b = UUID()
    let message = "Keybind broke. Paste fails too."
    let transport = FakeTransport([
      .reply(
        200,
        Self.reply([
          Self.section("i0"), Self.section("i1", slug: "paste-not-working", anchor: "fix-it"),
        ]))
    ])
    let submission = FeedbackSubmission(
      store: store, save: recorder.save,
      helpCheck: Self.check(
        .concerns(
          [
            Concern(summary: "Keybind", evidence: "Keybind broke.", kind: .bug),
            Concern(summary: "Paste", evidence: "Paste fails too.", kind: .bug),
          ], hitCap: false), transport))
    store.save(message: message, email: "")
    let onScreenA: @MainActor @Sendable () -> FeedbackSubmission.FormState = {
      .init(presentation: a, message: message, email: "")
    }
    let onScreenB: @MainActor @Sendable () -> FeedbackSubmission.FormState = {
      .init(presentation: b, message: message, email: "")
    }
    _ = await submission.send(
      try #require(FeedbackDraft(message: message, email: "")), diagnostics: nil, from: a,
      sent: (message, ""), current: onScreenA)
    let generation = try #require(submission.helpGeneration)
    #expect(submission.helpMarks.isEmpty)
    submission.setHelpMark("i0", solved: true, generation: generation, from: a, current: onScreenA)
    submission.setHelpMark("i1", solved: true, generation: generation, from: a, current: onScreenA)
    submission.setHelpMark("i9", solved: true, generation: generation, from: a, current: onScreenA)
    submission.setHelpMark("i0", solved: false, generation: UUID(), from: a, current: onScreenA)
    #expect(submission.helpMarks == ["i0", "i1"], "unknown concerns and older checks change nothing")
    // Opening A closed with the cards up (minimized); B reopened from the bug icon. A stale
    // press from A changes nothing, even when A's closed view pairs its own renewed id with
    // itself; B sees and changes the same marks.
    submission.presentationDisappeared(a)
    let renewedA = UUID()
    let onScreenRenewedA: @MainActor @Sendable () -> FeedbackSubmission.FormState = {
      .init(presentation: renewedA, message: message, email: "")
    }
    submission.presentationAppeared(b)
    submission.setHelpMark("i1", solved: false, generation: generation, from: a, current: onScreenB)
    submission.setHelpMark(
      "i1", solved: false, generation: generation, from: renewedA, current: onScreenRenewedA)
    #expect(submission.helpMarks == ["i0", "i1"])
    #expect(
      !submission.endWithAllSolved(
        confirmed: ["i0", "i1"], generation: generation, from: renewedA, current: onScreenRenewedA))
    #expect(
      !submission.dismissSuggestions(
        generation: generation, from: renewedA, current: onScreenRenewedA))
    #expect(
      await submission.finishSuggestions(
        solved: ["i0", "i1"], generation: generation, from: renewedA, current: onScreenRenewedA)
        == nil)
    #expect(recorder.saves.isEmpty)
    submission.setHelpMark("i1", solved: false, generation: generation, from: b, current: onScreenB)
    #expect(submission.helpMarks == ["i0"])
    // An all-solved or send built from older marks is refused and records nothing.
    #expect(
      !submission.endWithAllSolved(
        confirmed: ["i0", "i1"], generation: generation, from: b, current: onScreenB))
    #expect(
      await submission.finishSuggestions(
        solved: ["i0", "i1"], generation: generation, from: b, current: onScreenB) == nil)
    #expect(recorder.saves.isEmpty)
    #expect(submission.helpPhase != .idle, "the cards stay after a refused press")
    // Marked again, the current marks end the report without sending, and are cleared.
    submission.setHelpMark("i1", solved: true, generation: generation, from: b, current: onScreenB)
    #expect(
      submission.endWithAllSolved(
        confirmed: submission.helpMarks, generation: generation, from: b, current: onScreenB))
    #expect(submission.helpMarks.isEmpty)
    #expect(recorder.saves.isEmpty)
  }

  @Test("Every concern marked solved but the list not confirmed complete: sent, and recorded as solved")
  @MainActor
  func allSolvedButCoverageLow() async throws {
    let (store, suite) = Self.makeStore()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let recorder = RecordingSave()
    let a = UUID()
    let message = "Keybind broke."
    let submission = try await Self.withCards(
      store, recorder, message: message, coverage: 0.3, presentation: a)
    let generation = try #require(submission.helpGeneration)
    let screen: @MainActor @Sendable () -> FeedbackSubmission.FormState = {
      .init(presentation: a, message: message, email: "")
    }
    submission.setHelpMark("i0", solved: true, generation: generation, from: a, current: screen)
    #expect(!submission.endWithAllSolved(confirmed: ["i0"], generation: generation, from: a, current: screen))
    _ = await submission.finishSuggestions(solved: ["i0"], generation: generation, from: a, current: screen)
    #expect(recorder.saves.count == 1)
    let help = try #require(recorder.saves[0].help)
    #expect(help.terminalOutcome == .partialSent)
    #expect(help.issues.map(\.resolution) == [.solved])
    #expect(help.solvedIssueCount == 1)
    #expect(help.coveragePassed == false)
  }

  @MainActor
  final class Terminals {
    private(set) var all: [HelpCheckTerminal] = []
    func record(_ t: HelpCheckTerminal) { all.append(t) }
  }

  @Test("Each ending reports exactly once: helped, still sent, dismissed, not saved")
  @MainActor
  func terminalEvents() async throws {
    let message = "Keybind broke."
    let a = UUID()
    let screen: @MainActor @Sendable () -> FeedbackSubmission.FormState = {
      .init(presentation: a, message: message, email: "")
    }
    for ending in ["helped", "still_sent", "dismissed", "not_saved"] {
      let (store, suite) = Self.makeStore()
      defer { UserDefaults().removePersistentDomain(forName: suite) }
      let terminals = Terminals()
      let transport = FakeTransport([.reply(200, Self.reply([Self.section("i0")]))])
      let refuse = ending == "not_saved"
      var clockValue = Date(timeIntervalSince1970: 1_000)
      let submission = FeedbackSubmission(
        store: store,
        save: { _, _, _ in refuse ? .full : .saved(offline: false) },
        helpCheck: Self.check(
          .concerns([Concern(summary: "Keybind", evidence: message, kind: .bug)], hitCap: false),
          transport),
        clock: {
          defer { clockValue += 2.5 }
          return clockValue
        })
      submission.onHelpTerminal = { terminals.record($0) }
      store.save(message: message, email: "")
      _ = await submission.send(
        try #require(FeedbackDraft(message: message, email: "")), diagnostics: nil, from: a,
        sent: (message, ""), current: screen)
      #expect(terminals.all.isEmpty, "nothing ends while the cards wait")
      let generation = try #require(submission.helpGeneration)
      switch ending {
      case "helped":
        #expect(submission.endWithAllSolved(confirmed: ["i0"], generation: generation, from: a, current: screen))
      case "dismissed":
        #expect(submission.dismissSuggestions(generation: generation, from: a, current: screen))
      default:
        _ = await submission.finishSuggestions(solved: [], generation: generation, from: a, current: screen)
      }
      // A repeated press after the ending changes nothing and reports nothing more.
      _ = submission.dismissSuggestions(generation: generation, from: a, current: screen)
      #expect(terminals.all.count == 1, "\(ending)")
      let t = try #require(terminals.all.first)
      #expect(t.outcome.rawValue == ending)
      #expect(t.issues == 1)
      #expect(t.cards == 1)
      #expect(t.solved == (ending == "helped" ? 1 : 0))
      #expect(t.checkSeconds == 2.5)
      #expect(t.durationBucket == "2_4s")
      #expect(t.versions?.kb == "72134d105fb3")
    }
  }

  @Test("An immediate send reports once, with the split's failure")
  @MainActor
  func terminalOnImmediateSend() async throws {
    let (store, suite) = Self.makeStore()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let terminals = Terminals()
    let recorder = RecordingSave()
    let submission = FeedbackSubmission(
      store: store, save: recorder.save,
      helpCheck: Self.check(.unavailable(.afmTimeout), FakeTransport([.fail(URLError(.notConnectedToInternet))])))
    submission.onHelpTerminal = { terminals.record($0) }
    let a = UUID()
    _ = await submission.send(
      try #require(FeedbackDraft(message: "hi there", email: "")), diagnostics: nil, from: a,
      sent: ("hi there", ""), current: { .init(presentation: a, message: "hi there", email: "") })
    #expect(terminals.all.count == 1)
    #expect(terminals.all.first?.outcome == .stillSent)
    #expect(terminals.all.first?.failure == .network)
    #expect(terminals.all.first?.splitFailure == .afmTimeout)
    #expect(terminals.all.first?.mode == .wholeMessageAlwaysSend)
  }

  @Test("A failed check saves the report at once with its fallback reason")
  @MainActor
  func fallbackSaves() async throws {
    let (store, suite) = Self.makeStore()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let recorder = RecordingSave()
    let transport = FakeTransport([.fail(URLError(.notConnectedToInternet))])
    let submission = FeedbackSubmission(
      store: store, save: recorder.save,
      helpCheck: Self.check(.unavailable(.afmUnavailable), transport))
    let presentation = UUID()
    let step = await submission.send(
      try #require(FeedbackDraft(message: "hi there", email: "")), diagnostics: nil,
      from: presentation, sent: ("hi there", ""),
      current: { .init(presentation: presentation, message: "hi there", email: "") })
    #expect(step == .sent(.saved(offline: false), splitFailure: .afmUnavailable))
    #expect(recorder.saves.count == 1)
    #expect(recorder.saves[0].help?.terminalOutcome == .fallbackSent)
    #expect(recorder.saves[0].help?.failureReason == .network)
    #expect(recorder.saves[0].help?.mode == .wholeMessageAlwaysSend)
  }

  @Test("Without a help check, Send saves directly as before")
  @MainActor
  func noHelpCheck() async throws {
    let (store, suite) = Self.makeStore()
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let recorder = RecordingSave()
    let submission = FeedbackSubmission(store: store, save: recorder.save)
    let presentation = UUID()
    let step = await submission.send(
      try #require(FeedbackDraft(message: "hi there", email: "")), diagnostics: nil,
      from: presentation, sent: ("hi there", ""),
      current: { .init(presentation: presentation, message: "hi there", email: "") })
    #expect(step == .sent(.saved(offline: false)))
    #expect(recorder.saves.count == 1)
    #expect(recorder.saves[0].help == nil)
  }
}
