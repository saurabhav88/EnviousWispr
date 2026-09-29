import Foundation

/// One POST to the help check (#3275). The message goes only to enviouswispr.com, which holds the
/// TypeSafe key; never an email, diagnostics or a client secret. One attempt, no retry: any
/// failure means the report is sent as written.
struct HelpCheckClient: Sendable {
  static let endpoint = URL(string: "https://enviouswispr.com/api/app/help-check")!
  /// A reply is a few kilobytes of help-center text; anything larger is refused unread.
  static let maxReplyBytes = 256 * 1024

  enum Failure: Error, Equatable {
    case network, timeout, badReply
    case http(Int)

    var reason: FeedbackHelpOutcome.FailureReason {
      switch self {
      case .network: .network
      case .timeout: .timeout
      case .badReply: .badReply
      case .http: .httpError
      }
    }
  }

  /// Sends one request and returns the status and body. Injected so tests never reach the network.
  typealias Transport = @Sendable (URLRequest) async throws -> (status: Int, body: Data)

  let transport: Transport

  func check(_ request: HelpCheckRequest) async -> Result<HelpCheckReply, Failure> {
    var urlRequest = URLRequest(url: Self.endpoint)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.httpShouldHandleCookies = false
    do {
      urlRequest.httpBody = try JSONEncoder().encode(request)
    } catch {
      return .failure(.badReply)
    }
    let reply: (status: Int, body: Data)
    do {
      reply = try await transport(urlRequest)
    } catch is CancellationError {
      return .failure(.timeout)
    } catch let error as URLError where error.code == .timedOut || error.code == .cancelled {
      return .failure(.timeout)
    } catch {
      return .failure(.network)
    }
    guard (200..<300).contains(reply.status) else { return .failure(.http(reply.status)) }
    guard reply.body.count <= Self.maxReplyBytes,
      let decoded = HelpCheckReply.decode(
        reply.body, expectedIssues: request.mode == .decomposed ? request.issues.count : 1)
    else { return .failure(.badReply) }
    return .success(decoded)
  }
}

extension HelpCheckClient {
  static let live = HelpCheckClient(transport: HelpCheckHTTP.live)
}

enum HelpCheckHTTP {
  /// The whole transfer is capped, not only the gap between bytes; the check's own deadline cancels
  /// it sooner. Cookies, caches and redirects are off: the reply comes from the one host or not at all.
  static let live: HelpCheckClient.Transport = { request in
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, http.url?.host == HelpCheckClient.endpoint.host
    else { throw URLError(.badServerResponse) }
    var body = Data()
    for try await byte in bytes {
      body.append(byte)
      if body.count > HelpCheckClient.maxReplyBytes { break }
    }
    return (http.statusCode, body)
  }

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 7
    configuration.timeoutIntervalForResource = 7
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
  }()

  private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
      nil
    }
  }
}
