import Foundation

/// The one owner of how a request reaches a bundled polish helper (#4493).
///
/// Every operation on a helper (chat, readiness, both word checks, the summary, the DEBUG slot
/// read) builds a `LocalPolishHelperRequest` and hands it here with the endpoint of the launch
/// it means. This owner adds the launch's bearer, sends the request and returns the status and
/// body; a failure that produced no response is one `LocalPolishHelperClientError`, and a
/// cancelled request throws `CancellationError`.
///
/// For now the carrier is still the loopback port: `URLSession` against `127.0.0.1:port`, the
/// code each operation used to run itself, moved here unchanged in effect. The private socket
/// replaces this body in a later chunk of #4493, and no operation changes with it.
public enum LocalPolishHelperExchange {
  /// The exchange as an operation takes it, so a test can answer without a helper.
  public typealias Perform =
    @Sendable (LocalPolishHelperRequest, LocalPolishEndpoint) async throws
    -> LocalPolishHelperResponse

  /// The app's exchange.
  public static let perform: Perform = { request, endpoint in
    try await perform(request, at: endpoint) { try await URLSession.shared.data(for: $0) }
  }

  /// The same exchange with the loopback transport supplied, so a test reads the request this
  /// owner builds and scripts the transport's outcome.
  static func perform(
    _ request: LocalPolishHelperRequest, at endpoint: LocalPolishEndpoint,
    transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
  ) async throws -> LocalPolishHelperResponse {
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport(urlRequest(request, at: endpoint))
    } catch let error as URLError {
      throw clientError(error)
    }
    guard let http = response as? HTTPURLResponse else {
      throw LocalPolishHelperClientError.failed
    }
    return LocalPolishHelperResponse(status: http.statusCode, body: data)
  }

  /// The loopback request: the launch's bearer on every request, a JSON content type exactly
  /// when there is a body, and the request's whole time limit.
  static func urlRequest(_ request: LocalPolishHelperRequest, at endpoint: LocalPolishEndpoint)
    -> URLRequest
  {
    var urlRequest = URLRequest(
      url: URL(string: "http://127.0.0.1:\(endpoint.port)\(request.path)")!)
    urlRequest.httpMethod = request.method.rawValue
    urlRequest.setValue("Bearer \(endpoint.authToken)", forHTTPHeaderField: "Authorization")
    if let body = request.body {
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      urlRequest.httpBody = body
    }
    urlRequest.timeoutInterval = seconds(request.timeout)
    return urlRequest
  }

  /// What the loopback transport's failures mean, in the client's terms (plan #4493 §3.3).
  static func clientError(_ error: URLError) -> any Error {
    switch error.code {
    case .cannotConnectToHost: return LocalPolishHelperClientError.notConnectable
    case .networkConnectionLost: return LocalPolishHelperClientError.connectionLost
    case .timedOut: return LocalPolishHelperClientError.timedOut
    case .cancelled: return CancellationError()
    default: return LocalPolishHelperClientError.failed
    }
  }

  static func seconds(_ duration: Duration) -> TimeInterval {
    let parts = duration.components
    return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
  }
}
