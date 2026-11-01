import EnviousWisprCore
import Foundation

/// One EnviousMeet summary call on the bundled EG-1 server (#4319).
///
/// Deliberately NOT `LocalPolishTransport`: that path is built for a dictation that must never
/// wait, so it caps a request at 20 seconds and turns every failure into the silent polish skip
/// (`LLMError.egOneSkipped`). A summary call can run for a minute, and its failures must reach
/// `MeetingSummary`'s own policy: a length stop is a cut-off answer (`Failure.truncated`, never
/// saved; no loop guard, founder 2026-11-01), an empty answer is `Failure.empty`, a timeout is
/// `Failure.timedOut`, a dropped connection stays a `URLError` the summary's retry policy
/// already treats as retryable, and any other HTTP status is a non-retryable request failure.
/// No transcript-tag stripping (the summary prompt wraps nothing in transcript tags) and no
/// preamble removal (the owner already splits the title line).
public enum EGOneSummaryCall {
  /// Sends one request and returns the answer text.
  /// - Parameters:
  ///   - timeoutSeconds: the summary's local call limit; the request waits that plus ten
  ///     seconds, so the summary's own timeout fires first and reports `timedOut`.
  ///   - send: the transport; the app uses `URLSession.shared`, tests a canned answer.
  public static func complete(
    endpoint: EGOneEndpoint, instructions: String, prompt: String, timeoutSeconds: Double,
    send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
      try await URLSession.shared.data(for: $0)
    }
  ) async throws -> String {
    var request = URLRequest(url: endpoint.chatCompletionsURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(endpoint.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = timeoutSeconds + 10
    request.httpBody = try JSONSerialization.data(
      withJSONObject: requestBody(
        instructions: instructions, prompt: prompt,
        hasLearnedWordAdapter: endpoint.hasLearnedWordAdapter))
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await send(request)
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as URLError where error.code == .timedOut {
      throw MeetingSummary.Failure.timedOut
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200 else {
      throw LLMError.requestFailed("EG-1 summary HTTP \(status)")
    }
    return try parse(data)
  }

  /// The chat-completions body: system and user as given, the fixed EG-1 model name, the
  /// summary's output cap and temperature 0, with the learned-word adapter switched off by the
  /// same owner polish uses.
  static func requestBody(
    instructions: String, prompt: String, hasLearnedWordAdapter: Bool
  ) -> [String: Any] {
    let body: [String: Any] = [
      "model": LLMProvider.egOneModelName,
      "messages": [
        ["role": "system", "content": instructions],
        ["role": "user", "content": prompt],
      ],
      "max_tokens": MeetingSummary.outputTokens,
      "temperature": 0,
      "stream": false,
    ]
    return EGOneConnector.withLearnedWordAdapterOff(
      body, hasLearnedWordAdapter: hasLearnedWordAdapter)
  }

  /// The answer, or why there is none. A length stop is checked before the content: the bench
  /// (#4299) saw EG-1 repeat one line until the cap, and that text must never be saved.
  static func parse(_ data: Data) throws -> String {
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    let choice = (json?["choices"] as? [[String: Any]])?.first
    if (choice?["finish_reason"] as? String) == "length" {
      throw MeetingSummary.Failure.truncated
    }
    let content = (choice?["message"] as? [String: Any])?["content"] as? String
    let text = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { throw MeetingSummary.Failure.empty }
    return text
  }
}
