import EnviousWisprCore
import Foundation

/// The one owner of the talker rules on this Mac (#4013 D3, chunk 5). It answers with the best
/// validated rules it has: the higher revision of the bundled copy and the last good download,
/// or empty rules when neither is valid. At most once a day it downloads
/// `https://enviouswispr.com/meet/talker-rules.json` with one bare GET; any failure keeps the
/// rules it already had.
///
/// The request carries no body, no cookies and no identifiers; it reveals only ordinary
/// connection data (#4013 R8). Only a validated document is cached, by atomic replacement, so a
/// failed write cannot damage the previous good copy.
package actor TalkerRulesStore {
  package static let endpoint = URL(string: "https://enviouswispr.com/meet/talker-rules.json")!
  package static let refreshInterval: TimeInterval = 24 * 60 * 60
  /// The approved whole-transfer timeout (#4013 R7).
  package static let timeoutSeconds: TimeInterval = 5

  static let cacheFileName = "talker-rules.json"
  static let attemptFileName = "talker-rules-attempt.json"

  /// Sends one request and returns the response with at most `TalkerRules.maximumBytes + 1`
  /// body bytes: the live transport stops reading past the cap. Injected so tests never reach
  /// the network.
  package typealias Transport =
    @Sendable (URLRequest) async throws -> (response: HTTPURLResponse, body: Data)

  private let directory: URL
  private let bundledData: @Sendable () -> Data?
  private let transport: Transport
  private let now: @Sendable () -> Date
  /// Called, synchronously, when a caller joins a download already in flight. Tests wait on it
  /// to know a second caller is parked; the app passes nothing.
  private let onJoinedRefresh: (@Sendable () -> Void)?

  private var snapshot: TalkerRulesSnapshot?
  private var lastAttempt: Date?
  private var attemptLoaded = false
  private var inFlight: Task<TalkerRulesSnapshot, Never>?

  package init(
    directory: URL, bundledData: @escaping @Sendable () -> Data?, transport: @escaping Transport,
    now: @escaping @Sendable () -> Date, onJoinedRefresh: (@Sendable () -> Void)? = nil
  ) {
    self.directory = directory
    self.bundledData = bundledData
    self.transport = transport
    self.now = now
    self.onJoinedRefresh = onJoinedRefresh
  }

  /// The app's store: cache under `<data directory>/TalkerRules/`, the bundled resource, the
  /// live HTTPS transport and the wall clock.
  package static let live = TalkerRulesStore(
    directory: StorageRoot.live.dataDirectory.appendingPathComponent(
      "TalkerRules", isDirectory: true),
    bundledData: { bundledURL.flatMap { try? Data(contentsOf: $0) } },
    transport: TalkerRulesHTTP.live, now: { Date() })

  /// The packaged `talker-rules.json`, or `nil` if the resource bundle did not ship. The same
  /// lookup `live` uses, so a test can prove the shipped resource resolves and validates.
  package static var bundledURL: URL? {
    Bundle.module.url(forResource: "talker-rules", withExtension: "json")
  }

  /// The rules in force now, without the network. Freeze this at recording start.
  package func current() -> TalkerRulesSnapshot {
    if let snapshot { return snapshot }
    let bundled = bundledData().flatMap {
      try? TalkerRulesSnapshot(validating: $0, origin: .bundled)
    }
    let cached = readCache()
    let best: TalkerRulesSnapshot
    switch (bundled, cached) {
    case let (bundled?, cached?):
      best = cached.rules.revision > bundled.rules.revision ? cached : bundled
    case let (bundled?, nil): best = bundled
    case let (nil, cached?): best = cached
    case (nil, nil): best = .empty
    }
    snapshot = best
    return best
  }

  /// Downloads newer rules when a day has passed since the last attempt, then answers like
  /// `current()`. Concurrent callers share one download. The attempt is recorded before the
  /// request, so a failure or a relaunch does not retry until the next day.
  package func refreshIfDue() async -> TalkerRulesSnapshot {
    if let inFlight {
      onJoinedRefresh?()
      return await inFlight.value
    }
    let base = current()
    guard isDue() else { return base }
    recordAttempt()
    let task = Task { await self.download(over: base) }
    inFlight = task
    let result = await task.value
    inFlight = nil
    return result
  }

  private func download(over base: TalkerRulesSnapshot) async -> TalkerRulesSnapshot {
    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "GET"
    request.timeoutInterval = Self.timeoutSeconds
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
    guard let reply = try? await transport(request) else { return base }
    guard reply.response.statusCode == 200, Self.isEndpoint(reply.response.url),
      let fresh = try? TalkerRulesSnapshot(validating: reply.body, origin: .downloaded),
      fresh.rules.revision > base.rules.revision
    else { return base }
    writeCache(reply.body)
    snapshot = fresh
    return fresh
  }

  /// The answer must come from the one address asked, not a redirect or another host.
  static func isEndpoint(_ url: URL?) -> Bool {
    guard let url else { return false }
    return url.scheme == endpoint.scheme && url.host == endpoint.host && url.path == endpoint.path
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
    return current < lastAttempt || current.timeIntervalSince(lastAttempt) >= Self.refreshInterval
  }

  private func recordAttempt() {
    let attempt = now()
    lastAttempt = attempt
    // A failed write leaves this run's limit in memory; the next launch may try once more.
    try? write(
      Data(String(attempt.timeIntervalSince1970).utf8), named: Self.attemptFileName)
  }

  private func readAttempt() -> Date? {
    guard let data = try? Data(contentsOf: fileURL(Self.attemptFileName)),
      let text = String(data: data, encoding: .utf8), let seconds = Double(text),
      seconds.isFinite
    else { return nil }
    return Date(timeIntervalSince1970: seconds)
  }

  // MARK: - Last good copy

  private func readCache() -> TalkerRulesSnapshot? {
    guard let handle = try? FileHandle(forReadingFrom: fileURL(Self.cacheFileName)) else {
      return nil
    }
    defer { try? handle.close() }
    // Bound the read: an oversized file is refused without loading it.
    guard let data = try? handle.read(upToCount: TalkerRules.maximumBytes + 1) else { return nil }
    return try? TalkerRulesSnapshot(validating: data, origin: .cached)
  }

  private func writeCache(_ data: Data) {
    // A failed write keeps the previous file; this run still uses the download.
    try? write(data, named: Self.cacheFileName)
  }

  private func write(_ data: Data, named name: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: fileURL(name), options: .atomic)
  }

  private func fileURL(_ name: String) -> URL {
    directory.appendingPathComponent(name, isDirectory: false)
  }
}

enum TalkerRulesHTTP {
  /// Cookies, caches and redirects are off and the whole transfer is capped at five seconds. The
  /// body is read only up to one byte past the size cap, so an oversized reply is never buffered.
  static let live: TalkerRulesStore.Transport = { request in
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    var body = Data()
    for try await byte in bytes {
      body.append(byte)
      if body.count > TalkerRules.maximumBytes { break }
    }
    return (http, body)
  }

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = TalkerRulesStore.timeoutSeconds
    configuration.timeoutIntervalForResource = TalkerRulesStore.timeoutSeconds
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
