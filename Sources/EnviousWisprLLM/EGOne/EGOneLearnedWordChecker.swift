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

/// The EG-1 learned-word LoRA runs on the resident polish server. The endpoint
/// lookup also refuses a request after another local model takes that server.
public struct EGOneLearnedWordChecker: LearnedWordChecking {
  public let armName = "eg1_lora"
  public let scoresAreComparable = true

  public static let systemPrompt =
    "[Task: check] A word from the user's dictionary may have been misheard in a dictated sentence. A is the sentence as transcribed. B writes the dictionary word at one spot. Answer B only if the speaker meant the dictionary word there; otherwise answer A. Answer with one letter."

  private let threshold: Double
  private let endpoint: @Sendable () async -> EGOneEndpoint?

  public init(threshold: Double, endpoint: @escaping @Sendable () async -> EGOneEndpoint?) {
    precondition(threshold.isFinite && (0...1).contains(threshold))
    self.threshold = threshold
    self.endpoint = endpoint
  }

  public static func prompt(for question: LearnedWordCheckQuestion) -> String {
    "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
      + "<|im_start|>user\nDictionary word: \(question.word)\n"
      + "A: \(question.contextText)\nB: \(question.contextRewritten)<|im_end|>\n"
      + "<|im_start|>assistant\n"
  }

  static func makeRequestBody(_ question: LearnedWordCheckQuestion, index: Int) -> [String: Any] {
    [
      "prompt": Self.prompt(for: question),
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
    let availableEndpoint = await endpoint()
    try Task.checkCancellation()
    guard let endpoint = availableEndpoint, endpoint.hasLearnedWordAdapter else {
      throw CheckerError.adapterUnavailable
    }
    let threshold = self.threshold
    var indexed: [(Int, LearnedWordCheckDecision)] = []
    // Finish a wave before reusing a slot: two requests must never target the
    // same checker slot at once, even when all 16 candidates are flagged.
    for start in stride(from: 0, to: questions.count, by: EGOneSlots.checkerCount) {
      let end = min(start + EGOneSlots.checkerCount, questions.count)
      let wave = try await withThrowingTaskGroup(of: (Int, LearnedWordCheckDecision).self) {
        group in
        for index in start..<end {
          let question = questions[index]
          group.addTask {
            try Task.checkCancellation()
            let body = Self.makeRequestBody(question, index: index)
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
