import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLocalPolish
import Foundation

/// The learned-word check of an EG-1 size on the EnviousDecode helper (#4473 P3).
///
/// The helper holds the size's adapter beside the polish model and answers
/// `POST /v1/wordcheck` with the two answer probabilities of each question. This checker asks
/// in requests of up to eight questions, one request at a time (the helper serves one request
/// at a time, and scores a request's questions in one pass), and decides each question by the
/// same rule as the llama checker: the score is `pB / (pA + pB)` and a question is approved
/// when the score reaches the qualified threshold.
///
/// It keeps a lease on the resident helper through the whole check, so an adapter change or
/// Remove Model waits for the check instead of stopping the helper in the middle of it. The
/// time limits are the caller's (`LearnedWordCheckStep`); a cancelled check sends nothing more
/// and gives no decisions.
///
/// It imports no llama module, and the llama engine imports nothing from here.
public struct EnviousDecodeWordChecker: LearnedWordChecking {
  /// A lease on the resident helper and the endpoint read under it.
  public struct Hold: Sendable {
    public let endpoint: LocalPolishEndpoint
    public let release: @Sendable () async -> Void

    public init(endpoint: LocalPolishEndpoint, release: @escaping @Sendable () async -> Void) {
      self.endpoint = endpoint
      self.release = release
    }
  }

  public enum CheckerError: Error, Equatable {
    /// No helper is resident, or the resident one has no adapter loaded.
    case adapterUnavailable
    /// The helper's answer is not the complete, usable answer to the questions sent.
    case invalidResponse
  }

  /// The most questions one request carries; the helper refuses more.
  static let questionsPerRequest = 8

  public let armName = "eg1_lora"
  public let scoresAreComparable = true

  private let threshold: Double
  private let hold: @Sendable () async -> Hold?
  private let perform: LocalPolishHelperExchange.Perform

  public init(threshold: Double, hold: @escaping @Sendable () async -> Hold?) {
    self.init(threshold: threshold, hold: hold, perform: LocalPolishHelperExchange.perform)
  }

  /// The same checker with its one outside effect supplied, so a test reads the requests and
  /// scripts the answers without a helper process.
  init(
    threshold: Double, hold: @escaping @Sendable () async -> Hold?,
    perform: @escaping LocalPolishHelperExchange.Perform
  ) {
    precondition(threshold.isFinite && (0...1).contains(threshold))
    self.threshold = threshold
    self.hold = hold
    self.perform = perform
  }

  /// The same admission the polish step takes, held for the whole check.
  public static func hold(on server: any EGOneLeaseProviding & Sendable) async -> Hold? {
    guard case .granted(let lease) = await server.acquireLocalServerLease() else { return nil }
    guard let endpoint = await server.activeEndpoint() else {
      await server.releaseLocalServerLease(lease)
      return nil
    }
    return Hold(endpoint: endpoint) { await server.releaseLocalServerLease(lease) }
  }

  public func decide(_ questions: [LearnedWordCheckQuestion]) async throws
    -> [LearnedWordCheckDecision]
  {
    guard !questions.isEmpty else { return [] }
    try Task.checkCancellation()
    guard let hold = await hold() else { throw CheckerError.adapterUnavailable }
    let decisions: [LearnedWordCheckDecision]
    do {
      decisions = try await decide(questions, endpoint: hold.endpoint)
    } catch {
      await hold.release()
      throw error
    }
    // Giving the helper back can wait for a launch that was held off by this check. A check
    // cancelled during that wait gives no decisions either.
    await hold.release()
    try Task.checkCancellation()
    return decisions
  }

  private func decide(_ questions: [LearnedWordCheckQuestion], endpoint: LocalPolishEndpoint)
    async throws -> [LearnedWordCheckDecision]
  {
    guard endpoint.hasLearnedWordAdapter else { throw CheckerError.adapterUnavailable }
    var decisions: [LearnedWordCheckDecision] = []
    for start in stride(from: 0, to: questions.count, by: Self.questionsPerRequest) {
      try Task.checkCancellation()
      let batch = Array(questions[start..<min(start + Self.questionsPerRequest, questions.count)])
      // No limit of its own: 60 s, the value this request had implicitly as a `URLRequest`.
      // The caller's (`LearnedWordCheckStep`) limits are the real ones.
      let request = LocalPolishHelperRequest(
        method: .post, path: "/v1/wordcheck", body: try Self.makeRequestBody(batch),
        timeout: .seconds(60))
      let response = try await perform(request, endpoint)
      // A check whose asker left while the helper worked gives no decisions.
      try Task.checkCancellation()
      guard response.status == 200 else {
        throw CheckerError.invalidResponse
      }
      decisions += try Self.parseDecisions(
        data: response.body, questions: batch, threshold: threshold)
    }
    return decisions
  }

  /// The request for up to eight questions: the model's wire name and, for each question, its
  /// id, the dictionary word, the text as transcribed and the text with the word written in.
  static func makeRequestBody(_ questions: [LearnedWordCheckQuestion]) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "model": LLMProvider.egOneModelName,
        "questions": questions.map {
          [
            "id": $0.id, "word": $0.word, "context": $0.contextText,
            "rewritten": $0.contextRewritten,
          ] as [String: Any]
        },
      ] as [String: Any], options: [.sortedKeys])
  }

  /// Decisions for one request's questions, or `invalidResponse` when the answer is not one
  /// score for each question, in the order asked, with two usable probabilities.
  static func parseDecisions(
    data: Data, questions: [LearnedWordCheckQuestion], threshold: Double
  ) throws -> [LearnedWordCheckDecision] {
    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let scores = object["scores"] as? [[String: Any]], scores.count == questions.count
    else { throw CheckerError.invalidResponse }
    // A JSON `true` or `false` reads as the number 1 or 0 through a plain cast; it is not a
    // number here.
    func isNumber(_ value: Any?) -> Bool {
      guard let number = value as? NSNumber else { return false }
      return CFGetTypeID(number) != CFBooleanGetTypeID()
    }
    return try zip(questions, scores).map { question, entry in
      guard isNumber(entry["id"]), let id = entry["id"] as? Int, id == question.id,
        isNumber(entry["pA"]), isNumber(entry["pB"]),
        let a = entry["pA"] as? Double, let b = entry["pB"] as? Double,
        a.isFinite, b.isFinite, a >= 0, b >= 0, a <= 1, b <= 1, a + b > 0
      else { throw CheckerError.invalidResponse }
      let score = b / (a + b)
      return LearnedWordCheckDecision(
        questionID: question.id, approved: score >= threshold, score: score)
    }
  }
}
