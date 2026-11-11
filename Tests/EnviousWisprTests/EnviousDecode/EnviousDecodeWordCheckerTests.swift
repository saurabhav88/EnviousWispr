import EnviousWisprCore
import EnviousWisprLocalPolish
import Foundation
import Testing

@testable import EnviousWisprEG1Engine

/// #4473 P3: the app's learned-word checker for an EG-1 size on the EnviousDecode helper.
///
/// When this fails, the user's dictionary learns wrong words or stops learning: a question
/// gets another question's score because an answer was read out of order, a short or broken
/// answer is taken as a decision, more than eight questions go out in one request and the
/// helper refuses them all, or the helper is stopped in the middle of a check because the
/// checker did not hold it. None of it shows on screen. Encounter: every correction the app
/// asks about on an EG-1 size. Owner: plan #4473 P3. Rigs: the checker with its one outside
/// effect scripted (requests read, answers given), and the engine's launch on the lifecycle
/// fixture's fake server under a real coordinator.
@Suite(
  "The EG-1 word checker asks the helper in requests of eight, decides by its own rule and holds the helper (#4473)",
  .serialized, .tags(.productOutcome))
struct EnviousDecodeWordCheckerTests {
  typealias Checker = EnviousDecodeWordChecker
  typealias Fixture = EGOneAdapterLifecycleTests.Fixture
  typealias Engine = EnviousDecodeEngineTests

  /// A question about one word of a short sentence. Its context is the whole sentence.
  static func question(_ id: Int, _ sentence: String, heard: String, word: String) throws
    -> LearnedWordCheckQuestion
  {
    let range = try #require(sentence.range(of: heard))
    return LearnedWordCheckQuestion(
      id: id, sentence: sentence, range: range,
      contextRange: sentence.startIndex..<sentence.endIndex, word: word)
  }

  static func questions(_ count: Int) throws -> [LearnedWordCheckQuestion] {
    try (0..<count).map {
      try question(100 + $0, "Open Twist \($0) now.", heard: "Twist", word: "Tuist")
    }
  }

  /// What the scripted helper saw and what the checker did with its hold.
  final class Record: @unchecked Sendable {
    private let lock = NSLock()
    private var requestList: [URLRequest] = []
    private var acquiredCount = 0
    private var releasedCount = 0
    private var releasedDuringRequest = false

    var requests: [URLRequest] { lock.withLock { requestList } }
    var acquired: Int { lock.withLock { acquiredCount } }
    var released: Int { lock.withLock { releasedCount } }
    var wasReleasedDuringARequest: Bool { lock.withLock { releasedDuringRequest } }

    func add(_ request: URLRequest) {
      lock.withLock {
        requestList.append(request)
        if releasedCount > 0 { releasedDuringRequest = true }
      }
    }
    func acquire() { lock.withLock { acquiredCount += 1 } }
    func release() { lock.withLock { releasedCount += 1 } }
  }

  static let endpoint = LocalPolishEndpoint(
    port: 49_152, authToken: "bearer-1", contextTokens: 8192, hasLearnedWordAdapter: true)

  static func hold(_ record: Record, endpoint: LocalPolishEndpoint? = endpoint)
    -> @Sendable () async -> Checker.Hold?
  {
    {
      guard let endpoint else { return nil }
      record.acquire()
      return Checker.Hold(endpoint: endpoint) { record.release() }
    }
  }

  static func response(_ status: Int = 200) -> URLResponse {
    HTTPURLResponse(
      url: URL(string: "http://127.0.0.1:49152/v1/wordcheck")!, statusCode: status,
      httpVersion: "HTTP/1.1", headerFields: nil)!
  }

  static func ids(in request: URLRequest) throws -> [Int] {
    let bytes = try #require(request.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    return try #require(body["questions"] as? [[String: Any]]).compactMap { $0["id"] as? Int }
  }

  static func scores(_ entries: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["scores": entries])
  }

  /// The lease seam `LocalPolishRuntime` provides, over a bare coordinator.
  @MainActor
  private final class CoordinatorServer: EGOneLeaseProviding {
    let coordinator: LocalPolishServerCoordinator
    init(_ coordinator: LocalPolishServerCoordinator) { self.coordinator = coordinator }
    func activeEndpoint() async -> LocalPolishEndpoint? { await coordinator.endpoint(for: .egOne) }
    func acquireLocalServerLease() async -> LocalPolishLeaseAdmission {
      await coordinator.acquireLease(for: .egOne, purpose: .inference)
    }
    func releaseLocalServerLease(_ lease: LocalPolishServerLease) async {
      await coordinator.releaseLease(lease)
    }
    func beginPolishAttempt(takeID: String?) async -> LocalPolishAttempt {
      let (admission, availability) = await coordinator.admitPolish(for: .egOne, takeID: takeID)
      return LocalPolishAttempt(
        admission: admission, endpoint: availability.endpoint, missedOutsideStop: nil,
        recoveryOutsideStop: nil)
    }
  }

  // MARK: - 1. Scoring

  @Test(
    "nineteen questions go out as requests of eight, eight and three, each question is decided by its own score at the threshold, and the helper is held until the last answer"
  )
  func questionsAreAskedInEightsAndDecidedByTheirOwnScores() async throws {
    let record = Record()
    let questions = try Self.questions(19)
    // The scripted helper gives question `id` the pair (pA, pB) = (1 - p, p) / 2 with
    // p = (id - 100) / 20: half the total probability, so the ratio must be taken.
    let checker = Checker(threshold: 0.5, hold: Self.hold(record)) { request in
      record.add(request)
      let entries = try Self.ids(in: request).map { id -> [String: Any] in
        let p = Double(id - 100) / 20
        return ["id": id, "pA": (1 - p) / 2, "pB": p / 2]
      }
      return (try Self.scores(entries), Self.response())
    }
    let decisions = try await checker.decide(questions)

    // Requests: eight, eight, three, in order, one after the other.
    let requests = record.requests
    #expect(
      try requests.map { try Self.ids(in: $0) } == [
        Array(100...107), Array(108...115), Array(116...118),
      ])
    let first = try #require(requests.first)
    #expect(first.url?.absoluteString == "http://127.0.0.1:49152/v1/wordcheck")
    #expect(first.httpMethod == "POST")
    #expect(first.value(forHTTPHeaderField: "Authorization") == "Bearer bearer-1")
    #expect(first.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let firstBytes = try #require(first.httpBody)
    let body = try #require(try JSONSerialization.jsonObject(with: firstBytes) as? [String: Any])
    #expect(Set(body.keys) == ["model", "questions"] && body["model"] as? String == "eg-1")
    let sent = try #require((body["questions"] as? [[String: Any]])?.first)
    #expect(Set(sent.keys) == ["id", "word", "context", "rewritten"])
    #expect(sent["id"] as? Int == 100 && sent["word"] as? String == "Tuist")
    #expect(sent["context"] as? String == "Open Twist 0 now.")
    #expect(sent["rewritten"] as? String == "Open Tuist 0 now.")

    // Decisions: one for each question, in the order asked, score = pB / (pA + pB).
    #expect(decisions.map(\.questionID) == Array(100...118))
    for (index, decision) in decisions.enumerated() {
      let expected = Double(index) / 20
      let score = try #require(decision.score)
      #expect(abs(score - expected) < 1e-12, "question \(index)")
      // The threshold itself approves: question 10 scores exactly 0.5.
      #expect(decision.approved == (index >= 10), "question \(index)")
    }
    #expect(checker.armName == "eg1_lora" && checker.scoresAreComparable)

    // The helper was held once, through all three requests, and released once.
    #expect(record.acquired == 1 && record.released == 1)
    #expect(!record.wasReleasedDuringARequest)
    // No questions: no hold and no request.
    #expect(try await checker.decide([]).isEmpty)
    #expect(record.acquired == 1 && record.requests.count == 3)
  }

  // MARK: - 2. The lease and the failures

  /// About 2 seconds: two real launches of the lifecycle fixture's fake server.
  @MainActor
  @Test(
    "a check holds the resident helper so an adapter change waits for it, and a missing helper, a helper without an adapter, a refused, short, reordered or unusable answer and a cancelled check give no decisions and release the helper"
  )
  func theHelperIsHeldAndABadAnswerGivesNoDecisions() async throws {
    // The hold, on a real coordinator with the engine's own launch.
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let draft = fixture.root.appendingPathComponent("draft", isDirectory: true)
    try FileManager.default.createDirectory(at: draft, withIntermediateDirectories: true)
    let engine = EnviousDecodeEngine(
      draftModelURL: draft, draftArtifactIdentity: Engine.identity("draft", "d1"),
      cacheLimitBytes: Engine.cacheLimit)
    func target(adapter: URL?) -> LocalPolishTarget {
      var configuration = engine.makeLaunchConfiguration(
        .singleModel(for: .egOne), Engine.identity("model", "m1"), fixture.binary, fixture.model,
        4096, adapter)
      configuration.readinessBudgetSeconds = 4
      return LocalPolishTarget(configuration: configuration)
    }
    let coordinator = LocalPolishServerCoordinator()
    let server = CoordinatorServer(coordinator)
    #expect(await Checker.hold(on: server) == nil)  // nothing is resident
    await coordinator.transition(
      to: .run(target(adapter: fixture.adapter)), intent: coordinator.claimIntent())
    let hold = try #require(await Checker.hold(on: server))
    #expect(hold.endpoint.hasLearnedWordAdapter)
    #expect(
      try fixture.launches().last?.suffix(2) == [
        "--word-check-adapter", fixture.adapter.deletingLastPathComponent().path,
      ])
    // A launch without the adapter is asked for while the check holds the helper: it waits.
    await coordinator.transition(
      to: .run(target(adapter: nil)), intent: coordinator.claimIntent())
    #expect(await coordinator.endpoint(for: .egOne) == hold.endpoint)
    #expect(try fixture.launches().count == 1)
    // A real request to a process that is not the helper (it answers like a chat reply): the
    // answer is not a complete set of scores, so there is no decision, and the hold is given
    // back, which lets the waiting launch run.
    let real = Checker(threshold: 0.5) { hold }
    let one = try Self.questions(1)
    await #expect(throws: Checker.CheckerError.invalidResponse) { try await real.decide(one) }
    #expect(await coordinator.endpoint(for: .egOne)?.hasLearnedWordAdapter == false)
    #expect(try fixture.launches().count == 2)
    #expect(try fixture.launches().last?.contains("--word-check-adapter") == false)
    await coordinator.transition(to: .idle(.egOne), intent: coordinator.claimIntent())

    // No helper, and a helper with no adapter: no request is sent.
    let nine = try Self.questions(9)
    func failure(
      endpoint: LocalPolishEndpoint? = Self.endpoint, questions: [LearnedWordCheckQuestion] = nine,
      _ answer: @escaping @Sendable (URLRequest, Int) throws -> (Data, URLResponse)
    ) async -> (error: (any Error)?, record: Record) {
      let record = Record()
      let checker = Checker(threshold: 0.5, hold: Self.hold(record, endpoint: endpoint)) {
        request in
        record.add(request)
        return try answer(request, record.requests.count)
      }
      do {
        _ = try await checker.decide(questions)
        return (nil, record)
      } catch {
        return (error, record)
      }
    }
    @Sendable func good(_ request: URLRequest) throws -> [[String: Any]] {
      try Self.ids(in: request).map { ["id": $0, "pA": 0.25, "pB": 0.5] }
    }
    let absent = await failure(endpoint: nil) { _, _ in (Data(), Self.response()) }
    #expect(absent.error as? Checker.CheckerError == .adapterUnavailable)
    #expect(absent.record.requests.isEmpty && absent.record.acquired == 0)
    let bare = await failure(
      endpoint: LocalPolishEndpoint(port: 49_152, authToken: "t", contextTokens: 8192)
    ) { _, _ in (Data(), Self.response()) }
    #expect(bare.error as? Checker.CheckerError == .adapterUnavailable)
    #expect(bare.record.requests.isEmpty && bare.record.released == 1)

    // Answers that are not the complete, usable answer. Each is the SECOND request's answer:
    // the first eight good scores are not returned as a partial result.
    let broken: [(String, @Sendable (URLRequest) throws -> (Data, URLResponse))] = [
      (
        "refused",
        { _ in (Data(#"{"error":{"type":"word_check_unavailable"}}"#.utf8), Self.response(503)) }
      ),
      ("not JSON", { _ in (Data("scores".utf8), Self.response()) }),
      ("no score", { _ in (try Self.scores([]), Self.response()) }),
      (
        "an extra score",
        { (try Self.scores(try good($0) + [["id": 1, "pA": 0.5, "pB": 0.5]]), Self.response()) }
      ),
      (
        "another id",
        { _ in (try Self.scores([["id": 107, "pA": 0.5, "pB": 0.5]]), Self.response()) }
      ),
      (
        "no pB",
        { (try Self.scores(try Self.ids(in: $0).map { ["id": $0, "pA": 0.5] }), Self.response()) }
      ),
      (
        "text for a number",
        {
          (
            try Self.scores(try Self.ids(in: $0).map { ["id": $0, "pA": "0.5", "pB": 0.5] }),
            Self.response()
          )
        }
      ),
      (
        "both zero",
        {
          (
            try Self.scores(try Self.ids(in: $0).map { ["id": $0, "pA": 0, "pB": 0] }),
            Self.response()
          )
        }
      ),
      (
        "above one",
        {
          (
            try Self.scores(try Self.ids(in: $0).map { ["id": $0, "pA": 0.5, "pB": 1.5] }),
            Self.response()
          )
        }
      ),
      (
        "below zero",
        {
          (
            try Self.scores(try Self.ids(in: $0).map { ["id": $0, "pA": -0.1, "pB": 0.5] }),
            Self.response()
          )
        }
      ),
    ]
    for (name, answer) in broken {
      let result = await failure { request, number in
        number == 1 ? (try Self.scores(try good(request)), Self.response()) : try answer(request)
      }
      #expect(result.error as? Checker.CheckerError == .invalidResponse, "\(name)")
      #expect(result.record.requests.count == 2 && result.record.released == 1, "\(name)")
    }
    // Eight scores in another order than the questions.
    let reordered = await failure { request, _ in
      (try Self.scores(Array(try good(request).reversed())), Self.response())
    }
    #expect(reordered.error as? Checker.CheckerError == .invalidResponse)
    #expect(reordered.record.requests.count == 1 && reordered.record.released == 1)
    // Control: the same rig with good answers gives nine decisions.
    let fine = await failure { request, _ in (try Self.scores(try good(request)), Self.response()) }
    #expect(fine.error == nil && fine.record.requests.count == 2 && fine.record.released == 1)

    // A cancelled request is a cancellation, not a failure of the helper, and the next
    // request is not sent.
    let cancelled = await failure { _, _ in throw URLError(.cancelled) }
    #expect(cancelled.error is CancellationError)
    #expect(cancelled.record.requests.count == 1 && cancelled.record.released == 1)
    // A check that is already cancelled takes no hold and sends nothing.
    let record = Record()
    let checker = Checker(threshold: 0.5, hold: Self.hold(record)) { request in
      record.add(request)
      return (Data(), Self.response())
    }
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await checker.decide(nine)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(record.acquired == 0 && record.requests.isEmpty)
  }
}
