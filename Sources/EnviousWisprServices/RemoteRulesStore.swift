import EnviousWisprCore
import Foundation

/// Where a rules document in force came from (#4013 r1 R7).
package enum RemoteRulesOrigin: String, Sendable, Equatable {
  /// The copy inside the app.
  case bundled
  /// The last good download, read from Application Support.
  case cached
  /// Downloaded in this run.
  case downloaded
  /// Neither the bundle nor the cache held a valid document: the document's empty value.
  case empty
}

/// A rules document the app ships and may update from enviouswispr.com (#4013 reading
/// resilience §3.5): the talker rules (`TalkerRulesSnapshot`) and the self-mute rules. Each
/// document names its own address, files and size cap, and validates itself; the store owns
/// everything else.
package protocol RemoteRulesDocument: Sendable, Equatable {
  /// The one address the document is downloaded from; a reply from anywhere else is refused.
  static var endpoint: URL { get }
  /// The last good download and the last attempt's time, inside the store's directory.
  static var cacheFileName: String { get }
  static var attemptFileName: String { get }
  /// The largest document accepted, checked while downloading and before reading the cache.
  static var maximumBytes: Int { get }
  /// The packaged copy, or `nil` if the resource bundle did not ship.
  static var bundledURL: URL? { get }
  /// The value in force when neither the bundle nor the cache holds a valid document.
  static var empty: Self { get }
  /// Validates `data` strictly; throws for anything this build does not accept.
  init(validating data: Data, origin: RemoteRulesOrigin) throws
  /// Orders documents: the store never replaces one with a lower or equal revision.
  var revision: Int { get }
  var origin: RemoteRulesOrigin { get }

  /// A detached signature fetched beside the document, or nil for an unsigned document (#4528).
  /// When set, the store downloads it too and hands both to `init(validating:signature:origin:)`.
  static var signatureEndpoint: URL? { get }
  /// The largest signature accepted.
  static var maximumSignatureBytes: Int { get }
  /// The largest cache file read back. Defaults to `maximumBytes`; a signed document caches a
  /// larger unit (payload and signature together) and raises it.
  static var maximumCacheBytes: Int { get }
  /// Validates a downloaded document together with its detached signature. Unsigned documents
  /// use the default, which ignores the signature.
  init(validating data: Data, signature: Data?, origin: RemoteRulesOrigin) throws
  /// The bytes to cache for a validated download, when they differ from the downloaded document
  /// (a signed document caches payload and signature as one unit). Nil caches the document bytes.
  var cacheData: Data? { get }
}

extension RemoteRulesDocument {
  package static var signatureEndpoint: URL? { nil }
  package static var maximumSignatureBytes: Int { 0 }
  package static var maximumCacheBytes: Int { maximumBytes }
  package init(validating data: Data, signature: Data?, origin: RemoteRulesOrigin) throws {
    try self.init(validating: data, origin: origin)
  }
  package var cacheData: Data? { nil }
}

/// What every rules store shares.
package enum RemoteRules {
  package static let refreshInterval: TimeInterval = 24 * 60 * 60
  /// The approved whole-transfer timeout (#4013 R7).
  package static let timeoutSeconds: TimeInterval = 5

  /// Sends one request and returns the response with at most `maximumBytes + 1` body bytes: the
  /// live transport stops reading past the cap. Injected so tests never reach the network.
  package typealias Transport =
    @Sendable (_ request: URLRequest, _ maximumBytes: Int) async throws -> (
      response: HTTPURLResponse, body: Data
    )

  /// The app's talker rules: cache under `<data directory>/TalkerRules/`, the bundled resource,
  /// the live HTTPS transport and the wall clock.
  package static let talker = RemoteRulesStore<TalkerRulesSnapshot>.live(
    directoryName: "TalkerRules")
  /// The app's self-mute rules (#4248), under `<data directory>/CallMuteRules/`.
  package static let mute = RemoteRulesStore<CallMuteRules>.live(directoryName: "CallMuteRules")
}

/// How the last refresh attempt ended, for later reporting (#4528 B2). Bounded: no URLs, no bodies.
package enum RemoteRulesRefreshOutcome: String, Sendable, Equatable {
  /// Not due: the daily limit had not passed.
  case notDue = "not_due"
  /// The request failed (offline, timeout, transport error).
  case transportFailed = "transport_failed"
  /// The reply was not a 200 from the one address asked, or was too large.
  case badReply = "bad_reply"
  /// A signed document's signature could not be fetched.
  case signatureUnavailable = "signature_unavailable"
  /// The document (or its signature) did not validate.
  case invalid = "invalid"
  /// Valid, but not newer than the rules already trusted.
  case notNewer = "not_newer"
  /// Accepted and cached.
  case accepted = "accepted"
}

/// The one owner of one rules document on this Mac (#4013 D3, chunk 5; generic since reading
/// resilience §3.5). It answers with the best validated document it has: the higher revision of
/// the bundled copy and the last good download (the bundle wins a tie), or the document's empty
/// value when neither is valid. At most once a day it downloads `Document.endpoint` with one bare
/// GET; any failure keeps the document it already had.
///
/// The request carries no body, no cookies and no identifiers; it reveals only ordinary
/// connection data (#4013 R8). Only a validated document is cached, by atomic replacement, so a
/// failed write cannot damage the previous good copy. Each store has its own directory, files
/// and refresh state, so one document's download never delays or replaces another's.
package actor RemoteRulesStore<Document: RemoteRulesDocument> {
  private let directory: URL
  private let bundledData: @Sendable () -> Data?
  private let transport: RemoteRules.Transport
  private let now: @Sendable () -> Date
  /// Called, synchronously, when a caller joins a download already in flight. Tests wait on it
  /// to know a second caller is parked; the app passes nothing.
  private let onJoinedRefresh: (@Sendable () -> Void)?

  private var snapshot: Document?
  private var lastAttempt: Date?
  private var attemptLoaded = false
  private var inFlight: Task<Document, Never>?
  private var lastOutcome: RemoteRulesRefreshOutcome?

  package init(
    directory: URL, bundledData: @escaping @Sendable () -> Data?,
    transport: @escaping RemoteRules.Transport, now: @escaping @Sendable () -> Date,
    onJoinedRefresh: (@Sendable () -> Void)? = nil
  ) {
    self.directory = directory
    self.bundledData = bundledData
    self.transport = transport
    self.now = now
    self.onJoinedRefresh = onJoinedRefresh
  }

  /// The app's store for `Document`: cache under `<data directory>/<directoryName>/`, the
  /// bundled resource, the live HTTPS transport and the wall clock.
  static func live(directoryName: String) -> RemoteRulesStore {
    RemoteRulesStore(
      directory: StorageRoot.live.dataDirectory.appendingPathComponent(
        directoryName, isDirectory: true),
      bundledData: { Document.bundledURL.flatMap { try? Data(contentsOf: $0) } },
      transport: RemoteRulesHTTP.live, now: { Date() })
  }

  /// The document in force now, without the network. Freeze this at recording start.
  package func current() -> Document {
    if let snapshot { return snapshot }
    let bundled = bundledData().flatMap { try? Document(validating: $0, origin: .bundled) }
    let cached = readCache()
    let best: Document
    switch (bundled, cached) {
    case let (bundled?, cached?):
      best = cached.revision > bundled.revision ? cached : bundled
    case let (bundled?, nil): best = bundled
    case let (nil, cached?): best = cached
    case (nil, nil): best = Document.empty
    }
    snapshot = best
    return best
  }

  /// Downloads a newer document when a day has passed since the last attempt, then answers like
  /// `current()`. Concurrent callers share one download. The attempt is recorded before the
  /// request, so a failure or a relaunch does not retry until the next day.
  /// How the last refresh attempt in this run ended, or nil when none was made.
  package func lastRefreshOutcome() -> RemoteRulesRefreshOutcome? { lastOutcome }

  package func refreshIfDue() async -> Document {
    if let inFlight {
      onJoinedRefresh?()
      return await inFlight.value
    }
    let base = current()
    guard isDue() else {
      lastOutcome = .notDue
      return base
    }
    recordAttempt()
    let task = Task { await self.download(over: base) }
    inFlight = task
    let result = await task.value
    inFlight = nil
    return result
  }

  private func download(over base: Document) async -> Document {
    var request = URLRequest(url: Document.endpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = RemoteRules.timeoutSeconds
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
    guard let reply = try? await transport(request, Document.maximumBytes) else {
      lastOutcome = .transportFailed
      return base
    }
    guard reply.response.statusCode == 200, Self.isEndpoint(reply.response.url),
      reply.body.count <= Document.maximumBytes
    else {
      lastOutcome = .badReply
      return base
    }
    // A signed document needs its detached signature, fetched the same way (#4528).
    var signature: Data? = nil
    if let signatureEndpoint = Document.signatureEndpoint {
      var signatureRequest = request
      signatureRequest.url = signatureEndpoint
      guard let signed = try? await transport(signatureRequest, Document.maximumSignatureBytes),
        signed.response.statusCode == 200,
        Self.isEndpoint(signed.response.url, expected: signatureEndpoint),
        signed.body.count <= Document.maximumSignatureBytes
      else {
        lastOutcome = .signatureUnavailable
        return base
      }
      signature = signed.body
    }
    guard let fresh = try? Document(validating: reply.body, signature: signature, origin: .downloaded)
    else {
      lastOutcome = .invalid
      return base
    }
    guard fresh.revision > base.revision else {
      lastOutcome = .notNewer
      return base
    }
    writeCache(fresh.cacheData ?? reply.body)
    snapshot = fresh
    lastOutcome = .accepted
    return fresh
  }

  /// The answer must come from the one address asked, not a redirect or another host.
  static func isEndpoint(_ url: URL?, expected: URL = Document.endpoint) -> Bool {
    guard let url else { return false }
    return url.scheme == expected.scheme && url.host == expected.host && url.path == expected.path
  }

  // MARK: - Daily limit

  private func isDue() -> Bool {
    if !attemptLoaded {
      attemptLoaded = true
      lastAttempt = readAttempt()
    }
    guard let lastAttempt else { return true }
    let current = now()
    // A clock set back before the last attempt counts as due, so a wrong date cannot block
    // refreshes for its whole error.
    return current < lastAttempt
      || current.timeIntervalSince(lastAttempt) >= RemoteRules.refreshInterval
  }

  private func recordAttempt() {
    let attempt = now()
    lastAttempt = attempt
    // A failed write leaves this run's limit in memory; the next launch may try once more.
    try? write(
      Data(String(attempt.timeIntervalSince1970).utf8), named: Document.attemptFileName)
  }

  private func readAttempt() -> Date? {
    guard let data = try? Data(contentsOf: fileURL(Document.attemptFileName)),
      let text = String(data: data, encoding: .utf8), let seconds = Double(text),
      seconds.isFinite
    else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }

  // MARK: - Last good copy

  private func readCache() -> Document? {
    guard let handle = try? FileHandle(forReadingFrom: fileURL(Document.cacheFileName)) else {
      return nil
    }
    defer { try? handle.close() }
    // Bound the read: an oversized file is refused without loading it.
    guard let data = try? handle.read(upToCount: Document.maximumCacheBytes + 1),
      data.count <= Document.maximumCacheBytes
    else { return nil }
    return try? Document(validating: data, origin: .cached)
  }

  private func writeCache(_ data: Data) {
    // A failed write keeps the previous file; this run still uses the download.
    try? write(data, named: Document.cacheFileName)
  }

  private func write(_ data: Data, named name: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: fileURL(name), options: .atomic)
  }

  private func fileURL(_ name: String) -> URL {
    directory.appendingPathComponent(name, isDirectory: false)
  }
}

enum RemoteRulesHTTP {
  /// Cookies, caches and redirects are off and the whole transfer is capped at five seconds. The
  /// body is read only up to one byte past the document's size cap, so an oversized reply is
  /// never buffered.
  static let live: RemoteRules.Transport = { request, maximumBytes in
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    var body = Data()
    for try await byte in bytes {
      body.append(byte)
      if body.count > maximumBytes { break }
    }
    return (http, body)
  }

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = RemoteRules.timeoutSeconds
    configuration.timeoutIntervalForResource = RemoteRules.timeoutSeconds
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return URLSession(
      configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
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
