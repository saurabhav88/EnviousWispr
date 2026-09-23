import EnviousWisprCore
import Foundation

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
      + "A: \(question.sentence)\nB: \(question.rewritten)<|im_end|>\n"
      + "<|im_start|>assistant\n"
  }

  static func makeRequestBody(_ questions: [LearnedWordCheckQuestion]) -> [String: Any] {
    [
      "prompt": questions.map(Self.prompt(for:)),
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
    guard let endpoint = await endpoint(), endpoint.hasLearnedWordAdapter else {
      throw CheckerError.adapterUnavailable
    }
    var request = URLRequest(url: endpoint.completionURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(endpoint.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: Self.makeRequestBody(questions))
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      try Task.checkCancellation()
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw CheckerError.invalidResponse
      }
      return try Self.parseDecisions(data: data, questions: questions, threshold: threshold)
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    }
  }

  static func parseDecisions(
    data: Data, questions: [LearnedWordCheckQuestion],
    threshold: Double
  ) throws -> [LearnedWordCheckDecision] {
    // llama-server answers an array prompt with one object per prompt, each carrying the
    // prompt's position as `index`; the reply order is not promised, so match on it. A
    // one-prompt array comes back as a bare object, not a one-element array.
    let json = try JSONSerialization.jsonObject(with: data)
    let results: [[String: Any]]
    if let many = json as? [[String: Any]] {
      results = many
    } else if let one = json as? [String: Any] {
      results = [one]
    } else {
      throw CheckerError.invalidResponse
    }
    guard results.count == questions.count else { throw CheckerError.invalidResponse }
    var byIndex: [Int: [String: Any]] = [:]
    for result in results {
      guard let index = result["index"] as? Int, (0..<questions.count).contains(index),
        byIndex.updateValue(result, forKey: index) == nil
      else { throw CheckerError.invalidResponse }
    }
    return try questions.enumerated().map { position, question in
      guard let result = byIndex[position],
        let first = (result["completion_probabilities"] as? [[String: Any]])?.first,
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
  }

  enum CheckerError: Error {
    case adapterUnavailable
    case invalidResponse
  }
}
