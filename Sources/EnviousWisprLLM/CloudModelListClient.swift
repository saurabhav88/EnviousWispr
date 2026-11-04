import Foundation

/// #4353 D6: the ONLY place the app fetches `https://enviouswispr.com/cloud-models.json`.
///
/// Fetch safety (host allowlist, https-and-same-host redirect rule, total-transfer timeout,
/// bounded streaming read, no cookies) is owned by `OllamaCloudCatalogClient.liveTransport` and
/// reused here; this client differs from the Ollama library feed only by URL and parser. The
/// answer is trusted only after `CloudModelList.validated(from:)` accepts the whole document.
package struct CloudModelListClient: Sendable {
  package static let allowedHost = "enviouswispr.com"
  package static let endpoint = "https://enviouswispr.com/cloud-models.json"

  /// Why a fetch produced no list. Every case is a failure: nothing here ever becomes an empty
  /// list, so an unreachable network is never mistaken for "no models".
  package enum FetchError: Error, Equatable, Sendable {
    case transport(String)
    case httpStatus(Int)
    case notHTTP
    case invalid(CloudModelList.ValidationError)
  }

  private let transport: OllamaCloudCatalogClient.Transport

  // An overload pair, not a default argument: see `OllamaCloudCatalogClient.init()`.
  package init() {
    self.transport = OllamaCloudCatalogClient.liveTransport(allowedHost: Self.allowedHost)
  }

  package init(transport: @escaping OllamaCloudCatalogClient.Transport) {
    self.transport = transport
  }

  /// One bare GET. No body, no query, no header carrying a key, an identifier or a model
  /// choice: the request says nothing about the user (CLAUDE.md § Privacy).
  package static func request() throws -> URLRequest {
    guard let url = URL(string: endpoint) else { throw FetchError.notHTTP }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 5
    return request
  }

  /// Cancellation propagates as `CancellationError`; every other failure is a `FetchError`.
  package func fetch() async throws -> CloudModelList {
    let request = try Self.request()
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport(request, CloudModelList.maxDocumentBytes)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      throw FetchError.transport(String(describing: error))
    }
    guard let http = response as? HTTPURLResponse else { throw FetchError.notHTTP }
    guard http.statusCode == 200 else { throw FetchError.httpStatus(http.statusCode) }
    switch CloudModelList.validated(from: data) {
    case .success(let list): return list
    case .failure(let error): throw FetchError.invalid(error)
    }
  }
}
