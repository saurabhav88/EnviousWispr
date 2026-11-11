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
/// #4473: the transport now carries BYTES in and BYTES out. The connector builds and
/// serializes its request, and parses the answer it gets back, so this type names no prompt,
/// connector, result or `LLMError` and can live with the code that owns the local process.
///
/// Extracted from `EGOneConnector` as a semantic no-op: the body below is that
/// connector's `send`, moved with its comments, and EG-1's suite is the parity
/// check.
public enum LocalPolishTransport {

  /// Sends one prepared chat-completions request and returns the response bytes.
  ///
  /// The body goes out exactly as given: it is never decoded, re-serialized or normalized
  /// here. There is no parser argument and so no default one, deliberately: a
  /// default would let a new caller inherit a disposition it never chose, and
  /// choosing what an empty answer means is the entire reason this seam exists.
  ///
  /// Every transport failure is the one neutral `LocalPolishTransportError.unavailable`; a
  /// cancelled request is `CancellationError`.
  public static func send(endpoint: LocalPolishEndpoint, body: Data) async throws -> Data {
    try await send(
      endpoint: endpoint, body: body, perform: LocalPolishHelperExchange.perform,
      retryPause: { try await Task.sleep(for: .milliseconds(750)) })
  }

  /// The same send with its two outside effects supplied (the request and the wait before the
  /// second attempt), so a test counts attempts and pauses without a network or a real wait.
  /// The app always enters through the two-argument form above.
  static func send(
    endpoint: LocalPolishEndpoint, body: Data,
    perform: LocalPolishHelperExchange.Perform,
    retryPause: @Sendable () async throws -> Void
  ) async throws -> Data {
    // The pipeline's 15 s budget is the real cap; this transport timeout
    // only stops a zombie socket from outliving the step.
    let request = LocalPolishHelperRequest(
      method: .post, path: "/v1/chat/completions", body: body, timeout: .seconds(20))

    // One internal retry on connection-refused/reset: covers the
    // restart-once window after a server crash (plan §4). This is the
    // EXPLICIT retry decision for the local server — `LLMRetryPolicy`
    // deliberately treats the bypass error below as non-retryable so outer
    // machinery never stacks retries on top. (#4473: the connectors map
    // `unavailable` to that bypass error.)
    for attempt in 0...1 {
      if attempt > 0 {
        try await retryPause()
      }
      do {
        let response = try await perform(request, endpoint)
        guard response.status == 200 else {
          Task {
            await AppLogger.shared.log(
              "local polish server HTTP \(response.status)", level: .verbose, category: "LLM")
          }
          throw LocalPolishTransportError.unavailable
        }
        return response.body
      } catch let error as LocalPolishHelperClientError {
        switch error {
        case .notConnectable, .connectionLost:
          continue
        case .timedOut, .failed:
          throw LocalPolishTransportError.unavailable
        }
      }
    }
    throw LocalPolishTransportError.unavailable
  }
}
