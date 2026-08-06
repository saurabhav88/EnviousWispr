import Foundation

/// #1956: errors from the hosted-catalog fetch.
///
/// Deliberately coarse. The caller (`OllamaSetupService`) renders one inline
/// retryable message for every failure, so distinguishing "malformed JSON" from
/// "HTTP 500" would create a vocabulary nothing consumes. `responseTooLarge` is
/// separate only because it is the one case a test must be able to assert
/// precisely.
package enum CloudCatalogError: Error, Equatable {
  case invalidResponse
  case responseTooLarge
}

/// #1956: the ONLY place the `ollama.com` URL and its wire format are understood.
///
/// Why this is a separate type rather than another method on `OllamaSetupService`:
/// every other request that service makes goes to `localhost:11434`
/// (`OllamaSetupService.swift:357,457,491,645,905,957`). This is the app's first
/// call to a public internet host from the Ollama path, and a different trust
/// boundary is a different reason to change. The precedent already in this
/// module is `LLMModelDiscovery`, which owns provider-API discovery rather than
/// folding it into each provider's service.
///
/// The transport is injected so redirects, oversized bodies, non-200 responses,
/// timeouts and cancellation get real tests instead of a hope. Note that the
/// two safety limits are enforced by PRODUCTION code that tests drive directly
/// (`shouldFollowRedirect(to:)` and `accumulate(_:maximumBytes:)`), not by a
/// substitute that re-implements them — a test against a re-implementation
/// proves only that the copy works.
package struct OllamaCloudCatalogClient: Sendable {

  /// Receives the request and the byte ceiling, so an injected transport is held
  /// to the same contract as production rather than a laxer one.
  package typealias Transport = @Sendable (
    _ request: URLRequest, _ maximumBytes: Int
  ) async throws -> (Data, URLResponse)

  /// A public endpoint can return anything, so the body is bounded before it is
  /// parsed. Measured live body for 18 models is ~2 KB, so this is ~500x headroom.
  package static let maximumBytes = 1_048_576

  /// Bounds the RAW `data` array, counted BEFORE validation, trimming or
  /// de-duplication. Bounding the surviving ids instead would let a document of
  /// 1,000 malformed rows plus one good row through: the parsed count is not the
  /// parsed work.
  package static let maximumEntries = 200

  package static let allowedHost = "ollama.com"

  private static let endpoint = "https://ollama.com/v1/models"

  private let transport: Transport

  // An overload pair, NOT a default argument: a `package` declaration cannot
  // expose the `private` live transport through a default argument value
  // (swift-patterns RULE: package-visibility-avoids-cross-module-unknown-default).
  package init() { self.transport = Self.liveTransport }

  package init(transport: @escaping Transport) { self.transport = transport }

  /// One bare GET. No body, no query, no header carrying any identifier — the
  /// request says nothing about the user, which is what keeps this inside the
  /// privacy boundary in CLAUDE.md § Privacy.
  package func fetchIDs() async throws -> [String] {
    guard let url = URL(string: Self.endpoint) else {
      throw CloudCatalogError.invalidResponse
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 5

    // Transport errors (timeout, cancellation, offline) propagate untouched.
    // Converting one into an empty success would make an unreachable network
    // indistinguishable from Ollama offering nothing.
    let (data, response) = try await transport(request, Self.maximumBytes)

    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw CloudCatalogError.invalidResponse
    }
    return try Self.parseCloudCatalog(fromModelsJSON: data)
  }

  // MARK: - Pure policy (production code, driven directly by tests)

  /// The redirect decision, extracted from the delegate so the shipped rule can
  /// be tested without provoking a live redirect.
  ///
  /// Scheme AND host: host alone would permit an https -> http downgrade.
  package nonisolated static func shouldFollowRedirect(
    to url: URL?, allowedHost: String = OllamaCloudCatalogClient.allowedHost
  ) -> Bool {
    guard let url,
      url.scheme?.lowercased() == "https",
      url.host?.caseInsensitiveCompare(allowedHost) == .orderedSame
    else { return false }
    return true
  }

  /// Production byte accumulation with its ceiling, generic over the byte
  /// sequence so a test drives the REAL bound with a synthetic stream instead of
  /// asserting against a fake that throws on command.
  ///
  /// Accepts exactly `maximumBytes` and throws on the next one.
  package nonisolated static func accumulate<S: AsyncSequence>(
    _ bytes: S, maximumBytes: Int
  ) async throws -> Data where S.Element == UInt8 {
    var data = Data()
    data.reserveCapacity(min(maximumBytes, 16_384))
    for try await byte in bytes {
      guard data.count < maximumBytes else { throw CloudCatalogError.responseTooLarge }
      data.append(byte)
    }
    return data
  }

  /// Pure parse. Throws on an invalid DOCUMENT; drops an individual malformed
  /// ROW. Those are different failures: the first means we cannot trust the
  /// answer, the second means one entry of an otherwise good answer is junk.
  package nonisolated static func parseCloudCatalog(
    fromModelsJSON data: Data,
    maximumEntries: Int = OllamaCloudCatalogClient.maximumEntries
  ) throws -> [String] {
    let root = try? JSONSerialization.jsonObject(with: data)
    guard let object = root as? [String: Any],
      let rows = object["data"] as? [Any],
      !rows.isEmpty,
      rows.count <= maximumEntries
    else { throw CloudCatalogError.invalidResponse }

    var seen = Set<String>()
    let ids = rows.compactMap { value -> String? in
      guard let row = value as? [String: Any], let rawID = row["id"] as? String else { return nil }
      let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty, seen.insert(id).inserted else { return nil }
      return id
    }

    guard !ids.isEmpty else { throw CloudCatalogError.invalidResponse }
    return ids
  }

  // MARK: - Live transport

  /// A dedicated session, because `URLRequest.timeoutInterval` is an IDLE
  /// timeout: any newly arrived byte resets it, so a response trickling one byte
  /// at a time never trips it. `timeoutIntervalForResource` is the total-transfer
  /// bound. Same shape as `OllamaConnector.readinessSession`, and separate for
  /// the same reason: this probe's aggressive timeout must never leak into any
  /// other request.
  private static let liveSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    return URLSession(configuration: configuration)
  }()

  private static func liveTransport(
    request: URLRequest, maximumBytes: Int
  ) async throws -> (Data, URLResponse) {
    let delegate = SameHostRedirectDelegate()
    let (bytes, response) = try await liveSession.bytes(for: request, delegate: delegate)
    return (try await accumulate(bytes, maximumBytes: maximumBytes), response)
  }
}

/// `@unchecked Sendable` justification, per swift-concurrency-patterns
/// `no-new-unchecked-sendable`: this type has NO stored properties, therefore no
/// mutable state to race. It exists solely as an Objective-C delegate bridge so
/// `URLSession` can ask a redirect question, and it forwards that question
/// unchanged to a pure static function. The narrow delegate-bridge exception is
/// exactly the case that rule permits.
private final class SameHostRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    OllamaCloudCatalogClient.shouldFollowRedirect(to: request.url) ? request : nil
  }
}
