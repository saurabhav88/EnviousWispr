import EnviousWisprCore
import Foundation

/// The localhost wire path shared by every model the bundled server runs
/// (#2649).
///
/// EG-1 and S1-mini disagree about exactly ONE thing: what an empty answer
/// means. Everything between the request body and the HTTP response is
/// identical — same endpoint shape, same bearer token, same timeout, same
/// single retry across the restart-once window. Two copies of that would be two
/// places for the retry rule to drift, and the retry rule is the one that
/// covers a crashed server.
///
/// So the transport is shared and the PARSE is supplied. A connector says what
/// a response means; it does not re-implement how to get one.
///
/// Extracted from `EGOneConnector` as a semantic no-op: the body below is that
/// connector's `send`, moved with its comments, and EG-1's suite is the parity
/// check.
enum LocalPolishTransport {

  /// Sends one chat-completions request and hands the raw bytes to `parse`.
  ///
  /// `parse` is REQUIRED rather than defaulted to EG-1's rule, deliberately: a
  /// default would let a new caller inherit a disposition it never chose, and
  /// choosing what an empty answer means is the entire reason this seam exists.
  static func send(
    endpoint: EGOneEndpoint,
    system: String,
    user: String,
    config: LLMProviderConfig,
    parse: (Data) throws -> LLMResult
  ) async throws -> LLMResult {
    let body = try EGOneConnector.makeRequestBody(system: system, user: user, config: config)

    var request = URLRequest(url: endpoint.chatCompletionsURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(endpoint.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    // The pipeline's 15 s budget is the real cap; this transport timeout
    // only stops a zombie socket from outliving the step.
    request.timeoutInterval = 20

    // One internal retry on connection-refused/reset: covers the
    // restart-once window after a server crash (plan §4). This is the
    // EXPLICIT retry decision for the local server — `LLMRetryPolicy`
    // deliberately treats the bypass error below as non-retryable so outer
    // machinery never stacks retries on top.
    var lastConnectionError = false
    for attempt in 0...1 {
      if attempt > 0 {
        try await Task.sleep(for: .milliseconds(750))
      }
      do {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
          throw LLMError.egOneSkipped(.crashed)
        }
        guard http.statusCode == 200 else {
          Task {
            await AppLogger.shared.log(
              "local polish server HTTP \(http.statusCode)", level: .verbose, category: "LLM")
          }
          throw LLMError.egOneSkipped(.crashed)
        }
        return try parse(data)
      } catch let urlError as URLError {
        switch urlError.code {
        case .cannotConnectToHost, .networkConnectionLost:
          lastConnectionError = true
          continue
        case .cancelled:
          throw CancellationError()
        default:
          throw LLMError.egOneSkipped(.crashed)
        }
      }
    }
    _ = lastConnectionError
    throw LLMError.egOneSkipped(.crashed)
  }

  /// The half of a successful parse both models agree on, so neither can lose
  /// it independently.
  ///
  /// `finish_reason == "length"` means generation STOPPED at the cap and the
  /// content is a PARTIAL rewrite. Accepting it pastes a truncated polish.
  /// Measured on the shipped binary (#2649): a 3,133-token prompt that FITS the
  /// window came back HTTP 200 with `finish_reason: length` and 21,583
  /// characters of runaway text, so this is reachable rather than theoretical,
  /// and reading the status alone would paste it as a success.
  static func truncationGuard(_ json: [String: Any]?) throws {
    if let finish = (json?["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String,
      finish == "length"
    {
      throw LLMError.egOneSkipped(.outputTruncated)
    }
  }

  /// Pulls the assistant content out of a chat-completions body, or nil when the
  /// body is malformed. Emptiness is NOT decided here: the two models disagree
  /// about what an empty string means, and this returns the fact rather than
  /// the verdict.
  static func content(from json: [String: Any]?) -> String? {
    guard let choices = json?["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let content = message["content"] as? String
    else { return nil }
    return content
  }
}
