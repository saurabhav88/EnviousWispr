import EnviousWisprCore
import Foundation

/// The chat request path shared by every model the bundled server runs (#2649), over the
/// launch's private socket (#4493).
///
/// EG-1 and S1-mini disagree about exactly ONE thing: what an empty answer
/// means. Everything between the request body and the HTTP response is
/// identical — same endpoint shape, same bearer token, same timeout, same
/// single-attempt silent fallback when the helper drops out. Two copies of
/// that would be two places for the transport failure rule to drift.
///
/// So the transport is shared and the PARSE is supplied. A connector says what
/// a response means; it does not re-implement how to get one.
///
/// #4473: the transport now carries BYTES in and BYTES out. The connector builds and
/// serializes its request, and parses the answer it gets back, so this type names no prompt,
/// connector, result or `LLMError` and can live with the code that owns the local process.
///
/// #4496: removed the old 750 ms single retry across the restart-once window. Because a
/// restarted helper always gets a brand-new per-launch private socket and secret
/// (`LocalPolishProcessManager.spawn`), retrying against the caller's captured `endpoint` can
/// never reach the replacement and only stalls fallback by 750 ms. The affected dictation
/// immediately falls back to unpolished text while `LocalPolishProcessManager` restarts the
/// helper cleanly in the background for the next dictation.
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
    try await send(endpoint: endpoint, body: body, perform: LocalPolishHelperExchange.perform)
  }

  /// The same send with its outside request effect supplied, so a test counts attempts and
  /// scripts responses without a network or real helper. The app always enters through the
  /// two-argument form above.
  static func send(
    endpoint: LocalPolishEndpoint, body: Data,
    perform: LocalPolishHelperExchange.Perform
  ) async throws -> Data {
    // The pipeline's 15 s budget is the real cap; this transport timeout
    // only stops a zombie socket from outliving the step.
    let request = LocalPolishHelperRequest(
      method: .post, path: "/v1/chat/completions", body: body, timeout: .seconds(20))

    // Single attempt only (#4496): if the helper crashed or closed the connection, fall back to
    // unpolished text immediately with zero retry delay while `LocalPolishProcessManager` restarts
    // it in the background on a fresh private socket and secret for subsequent dictations.
    // `LLMRetryPolicy` also treats `egOneSkipped` as non-retryable so outer machinery never
    // stacks retries on top.
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
      case .notConnectable, .connectionLost, .timedOut, .failed:
        throw LocalPolishTransportError.unavailable
      }
    }
  }
}
