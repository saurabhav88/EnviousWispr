import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLocalPolish
import Foundation

/// One EnviousMeet summary call on EG-1's EnviousDecode helper (#4319, #4473).
///
/// Deliberately NOT `LocalPolishTransport`: that path is built for a dictation that must never
/// wait, so it caps a request at 20 seconds and turns every failure into the silent polish skip
/// (`LLMError.egOneSkipped`). A summary call can run for a minute, and its failures must reach
/// `MeetingSummary`'s own policy: a length stop is a cut-off answer (`Failure.truncated`, never
/// saved; no loop guard, founder 2026-11-01), an empty answer is `Failure.empty`, a timeout is
/// `Failure.timedOut`, a dropped connection stays a `URLError` the summary's retry policy
/// already treats as retryable (#4493: the helper exchange reports it in its own terms, and this
/// call gives it back as the `URLError` code the policy keys on), a prompt the server's window cannot hold is
/// `LLMError.classified(.inputTooLong)` (the summary re-plans with its byte count, as for the
/// other engines), and any other HTTP status is a non-retryable request failure.
/// No transcript-tag stripping (the summary prompt wraps nothing in transcript tags) and no
/// preamble removal (the owner already splits the title line).
public enum EGOneSummaryCall {
  /// Sends one request and returns the answer text.
  /// - Parameters:
  ///   - timeoutSeconds: the summary's local call limit; the request waits that plus ten
  ///     seconds, so the summary's own timeout fires first and reports `timedOut`.
  ///   - send: the transport; the app uses the helper exchange, tests a canned answer.
  public static func complete(
    endpoint: LocalPolishEndpoint, instructions: String, prompt: String, timeoutSeconds: Double,
    send: LocalPolishHelperExchange.Perform = LocalPolishHelperExchange.perform
  ) async throws -> String {
    let request = LocalPolishHelperRequest(
      method: .post, path: "/v1/chat/completions",
      body: try JSONSerialization.data(
        withJSONObject: requestBody(instructions: instructions, prompt: prompt)),
      timeout: .seconds(timeoutSeconds + 10))
    let response: LocalPolishHelperResponse
    do {
      response = try await send(request, endpoint)
    } catch LocalPolishHelperClientError.timedOut {
      throw MeetingSummary.Failure.timedOut
    } catch LocalPolishHelperClientError.notConnectable {
      // `LLMRetryPolicy` retries these two `URLError` codes; they are what this call threw
      // when the transport was `URLSession` (plan #4493 §3.3, Q4).
      throw URLError(.cannotConnectToHost)
    } catch LocalPolishHelperClientError.connectionLost {
      throw URLError(.networkConnectionLost)
    }
    let data = response.body
    let status = response.status
    guard status == 200 else {
      // The planning estimate can undercount EG-1's tokenizer; the helper then answers 400
      // with type `exceed_context_size_error`. The type is checked first, so new wording
      // still re-plans.
      if status == 400, isContextOverflow(data) {
        throw LLMError.classified(.inputTooLong)
      }
      throw LLMError.requestFailed("EG-1 summary HTTP \(status)")
    }
    return try parse(data)
  }

  /// The server's own overflow error: its type, else the llama.cpp wording the Ollama path
  /// already recognizes.
  static func isContextOverflow(_ data: Data) -> Bool {
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    if (json?["error"] as? [String: Any])?["type"] as? String == "exceed_context_size_error" {
      return true
    }
    return OllamaConnector.isContextOverflow(String(decoding: data, as: UTF8.self))
  }

  /// The chat-completions body: system and user as given, the fixed EG-1 model name, the
  /// summary's output cap and temperature 0. Exactly the fields the helper serves and no
  /// other (it refuses a field it does not know): the learned-word adapter is a separate model
  /// tree in the helper and never rides a chat request, so nothing switches it off here.
  /// Normalize whitespace at the edges of summary messages, including parts cut at a
  /// token budget. This also satisfies the supported emptyThinkBlock template's
  /// whitespace restriction. Bundled Micro currently uses plainAssistant.
  static func requestBody(instructions: String, prompt: String) -> [String: Any] {
    [
      "model": LLMProvider.egOneModelName,
      "messages": [
        [
          "role": "system", "content": instructions.trimmingCharacters(in: .whitespacesAndNewlines),
        ],
        ["role": "user", "content": prompt.trimmingCharacters(in: .whitespacesAndNewlines)],
      ],
      "max_tokens": MeetingSummary.outputTokens,
      "temperature": 0,
      "stream": false,
    ]
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
