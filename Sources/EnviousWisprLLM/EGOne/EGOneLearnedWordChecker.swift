import EnviousWisprCore
import Foundation

enum EGOneSlots {
  static let polish = 0
  static let checkerCount = 8
  static let totalCount = checkerCount + 1

  static func checker(for questionIndex: Int) -> Int {
    1 + questionIndex % checkerCount
  }
}

/// A lease on the resident bundled server and the endpoint read under it. The
/// checker keeps it through every question wave, so an adapter change or Remove
/// Model waits for the check instead of stopping the server mid-question.
public struct EGOneCheckerHold: Sendable {
  public let endpoint: EGOneEndpoint
  public let release: @Sendable () async -> Void

  public init(endpoint: EGOneEndpoint, release: @escaping @Sendable () async -> Void) {
    self.endpoint = endpoint
    self.release = release
  }
}

/// The learned-word LoRA of a bundled engine (EG-1's eg1c, S1-mini's D5) runs on
/// the resident polish server. The lease refuses while the server is changing,
/// and the endpoint lookup refuses after another local model takes that server.
public struct EGOneLearnedWordChecker: LearnedWordChecking {
  /// The question form each adapter was trained on (#3105). Both share the system
  /// text and the user turn; S1-mini's D5 went through the HF chat template with
  /// `enable_thinking=False`, so its answer opens after an empty think block, and
  /// it was scored with the named-language line (+1 to +6 points in the exam).
  public enum PromptStyle: Sendable, Equatable {
    case egOne
    case s1Mini(language: String?)
  }

  /// The exam's closed table (judge2-exam-v2 NAMED-LANGUAGE.md): the only names D5
  /// was measured with. English is never named; other languages get no line.
  static let namedLanguages = [
    "pl": "Polish", "de": "German", "fr": "French", "es": "Spanish", "it": "Italian",
    "pt": "Portuguese", "nl": "Dutch", "ru": "Russian",
  ]

  public let style: PromptStyle
  public var armName: String {
    switch style {
    case .egOne: "eg1_lora"
    case .s1Mini: "s1_lora"
    }
  }
  public let scoresAreComparable = true

  public static let systemPrompt =
    "[Task: check] A word from the user's dictionary may have been misheard in a dictated sentence. A is the sentence as transcribed. B writes the dictionary word at one spot. Answer B only if the speaker meant the dictionary word there; otherwise answer A. Answer with one letter."

  private let threshold: Double
  private let hold: @Sendable () async -> EGOneCheckerHold?

  public init(
    threshold: Double, style: PromptStyle = .egOne,
    hold: @escaping @Sendable () async -> EGOneCheckerHold?
  ) {
    precondition(threshold.isFinite && (0...1).contains(threshold))
    self.threshold = threshold
    self.style = style
    self.hold = hold
  }

  /// The same admission the polish step takes (`LLMPolishStep`), held for the
  /// whole check rather than one request.
  public static func hold(on server: any EGOneLeaseProviding & Sendable) async -> EGOneCheckerHold? {
    guard case .granted(let lease) = await server.acquireLocalServerLease() else { return nil }
    guard let endpoint = await server.activeEndpoint() else {
      await server.releaseLocalServerLease(lease)
      return nil
    }
    return EGOneCheckerHold(endpoint: endpoint) {
      await server.releaseLocalServerLease(lease)
    }
  }

  public static func prompt(
    for question: LearnedWordCheckQuestion, style: PromptStyle = .egOne
  ) -> String {
    var system = systemPrompt
    var answerPrefix = ""
    if case .s1Mini(let language) = style {
      // A regional code ("de-DE", "pt_BR") names the same language as its base.
      if let base = LanguageNormalizer.baseCode(language), let name = namedLanguages[base] {
        system += " The sentence is in \(name)."
      }
      answerPrefix = "<think>\n\n</think>\n\n"
    }
    return "<|im_start|>system\n\(system)<|im_end|>\n"
      + "<|im_start|>user\nDictionary word: \(question.word)\n"
      + "A: \(question.contextText)\nB: \(question.contextRewritten)<|im_end|>\n"
      + "<|im_start|>assistant\n\(answerPrefix)"
  }

  static func makeRequestBody(
    _ question: LearnedWordCheckQuestion, index: Int, style: PromptStyle = .egOne
  ) -> [String: Any] {
    [
      "prompt": Self.prompt(for: question, style: style),
      "id_slot": EGOneSlots.checker(for: index),
      "n_predict": 1,
      "n_probs": 20,
      "temperature": 0,
      "cache_prompt": true,
      "lora": [["id": 0 as Int, "scale": 1.0 as Double] as [String: Any]],
    ]
  }

  public func decide(_ questions: [LearnedWordCheckQuestion]) async throws
    -> [LearnedWordCheckDecision]
  {
    guard !questions.isEmpty else { return [] }
    try Task.checkCancellation()
    guard let hold = await hold() else { throw CheckerError.adapterUnavailable }
    do {
      let decisions = try await decide(questions, endpoint: hold.endpoint)
      await hold.release()
      return decisions
    } catch {
      await hold.release()
      throw error
    }
  }

  private func decide(_ questions: [LearnedWordCheckQuestion], endpoint: EGOneEndpoint)
    async throws -> [LearnedWordCheckDecision]
  {
    try Task.checkCancellation()
    guard endpoint.hasLearnedWordAdapter else { throw CheckerError.adapterUnavailable }
    let threshold = self.threshold
    var indexed: [(Int, LearnedWordCheckDecision)] = []
    // Finish a wave before reusing a slot: two requests must never target the
    // same checker slot at once, even when all 16 candidates are flagged.
    for start in stride(from: 0, to: questions.count, by: EGOneSlots.checkerCount) {
      let end = min(start + EGOneSlots.checkerCount, questions.count)
      let wave = try await withThrowingTaskGroup(of: (Int, LearnedWordCheckDecision).self) {
        group in
        let style = self.style
        for index in start..<end {
          let question = questions[index]
          group.addTask {
            try Task.checkCancellation()
            let body = Self.makeRequestBody(question, index: index, style: style)
            var request = URLRequest(url: endpoint.completionURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(endpoint.authToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            do {
              let (data, response) = try await URLSession.shared.data(for: request)
              try Task.checkCancellation()
              guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw CheckerError.invalidResponse
              }
              let decision = try Self.parseDecision(
                data: data, question: question, threshold: threshold)
              return (index, decision)
            } catch let error as URLError where error.code == .cancelled {
              throw CancellationError()
            }
          }
        }
        var results: [(Int, LearnedWordCheckDecision)] = []
        for try await result in group { results.append(result) }
        return results
      }
      indexed.append(contentsOf: wave)
    }
    try Task.checkCancellation()
    indexed.sort { $0.0 < $1.0 }
    return indexed.map { $0.1 }
  }

  static func parseDecision(
    data: Data, question: LearnedWordCheckQuestion, threshold: Double
  ) throws -> LearnedWordCheckDecision {
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      result["index"] as? Int == 0
    else { throw CheckerError.invalidResponse }
    return try decision(for: question, result: result, threshold: threshold)
  }

  private static func decision(
    for question: LearnedWordCheckQuestion, result: [String: Any], threshold: Double
  ) throws -> LearnedWordCheckDecision {
    guard let first = (result["completion_probabilities"] as? [[String: Any]])?.first,
      let top = first["top_logprobs"] as? [[String: Any]]
    else { throw CheckerError.invalidResponse }
    var a = 0.0
    var b = 0.0
    for entry in top {
      guard let token = entry["token"] as? String,
        let logprob = entry["logprob"] as? Double,
        !logprob.isNaN, logprob <= 0
      else { throw CheckerError.invalidResponse }
      if token == "A" { a += exp(logprob) }
      if token == "B" { b += exp(logprob) }
    }
    guard a + b > 0 else { throw CheckerError.invalidResponse }
    let score = b / (a + b)
    return LearnedWordCheckDecision(
      questionID: question.id, approved: score >= threshold, score: score)
  }

  enum CheckerError: Error {
    case adapterUnavailable
    case invalidResponse
  }
}
