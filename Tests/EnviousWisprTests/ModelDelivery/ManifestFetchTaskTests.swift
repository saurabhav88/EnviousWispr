import EnviousWisprASR
import Foundation
import Testing

@testable import EnviousWisprModelDelivery
@testable import EnviousWisprPipeline

// MARK: - URLProtocol stub (transport-semantics tests)

/// Scripted responses keyed by URL absoluteString. Each entry consumes once
/// (FIFO per URL) so resume/retry sequences can be scripted.
final class DeliveryStubProtocol: URLProtocol {
  struct Stub {
    let status: Int
    let headers: [String: String]
    let body: Data
    /// Phase 2 (#1405): script a transport-level failure (e.g. a timeout) so
    /// same-source retry can be exercised. When set, the stub fails instead of
    /// responding.
    var error: URLError?
    /// Phase 2 (#1371): after sending the response + body, leave the request
    /// in-flight (never finish) so an in-flight-download cancel can be exercised.
    var hangAfterBody: Bool

    init(
      status: Int, headers: [String: String], body: Data, error: URLError? = nil,
      hangAfterBody: Bool = false
    ) {
      self.status = status
      self.headers = headers
      self.body = body
      self.error = error
      self.hangAfterBody = hangAfterBody
    }
  }

  nonisolated(unsafe) static var stubs: [String: [Stub]] = [:]
  nonisolated(unsafe) static var seenRangeHeaders: [String] = []
  static let lock = NSLock()

  static func reset() {
    lock.lock()
    stubs = [:]
    seenRangeHeaders = []
    lock.unlock()
  }

  /// Keyed by URL PATH (host-agnostic and immune to encoding drift).
  static func enqueue(url: String, _ stub: Stub) {
    let key = URL(string: url)!.path
    lock.lock()
    stubs[key, default: []].append(stub)
    lock.unlock()
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  /// Guards against a double-completion when `stopLoading()` fires on an
  /// already-completed request (normal finish or scripted failure).
  private var didComplete = false

  override func startLoading() {
    Self.lock.lock()
    if let range = request.value(forHTTPHeaderField: "Range") {
      Self.seenRangeHeaders.append(range)
    }
    let key = request.url!.path
    let stub = Self.stubs[key]?.isEmpty == false ? Self.stubs[key]!.removeFirst() : nil
    Self.lock.unlock()
    guard let stub else {
      didComplete = true
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    if let error = stub.error {
      didComplete = true
      client?.urlProtocol(self, didFailWithError: error)
      return
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
      headerFields: stub.headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !stub.body.isEmpty {
      client?.urlProtocol(self, didLoad: stub.body)
    }
    if stub.hangAfterBody {
      return  // leave the request in-flight; stopLoading() completes it on cancel
    }
    didComplete = true
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    // A hung request that is now being cancelled must complete, or the caller's
    // cancel drain barrier waits forever (#1371 test).
    if !didComplete {
      didComplete = true
      client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
  }
}

/// Transport semantics of the generalized delegate + per-file fetch loop:
/// the EG-1-inherited behaviors (200-ignores-Range truncate, 416 discard,
/// non-success stop) plus the Phase 2 length gate. Signal-based — the stub
/// responds immediately; no clock waits (test-timing rule).
@Suite(.serialized) struct ManifestFetchTaskTests {
  private func makeStaging() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("fetch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func withStubs<T>(_ body: () async throws -> T) async rethrows -> T {
    // Installed for the whole test process (never cleared): a concurrent
    // suite's fetch mid-flight must not fall back to real DNS. Only delivery
    // tests construct sessions through this seam.
    DeliveryStubProtocol.reset()
    ChunkAppendDelegate.protocolClassesForTesting = [DeliveryStubProtocol.self]
    return try await body()
  }

  private func task(
    manifest: DeliveryManifest, staging: URL, components: Set<String>? = nil,
    backoffSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in },
    jitter: @escaping @Sendable () -> Double = { 1.0 },
    onFailover: @escaping @Sendable (DeliveryFailureClass) -> Void = { _ in }
  ) -> ManifestFetchTask {
    ManifestFetchTask(
      manifest: manifest, stagingDirectory: staging, sources: manifest.sources,
      componentsToFetch: components ?? Set(manifest.files.map(\.component)),
      verifiedInPlaceBytes: 0, onProgress: { _, _ in }, onSourceFailover: onFailover,
      backoffSleep: backoffSleep, jitterFraction: jitter)
  }

  @Test func happyPathFetchesVerifiesAllFiles() async throws {
    let files = ManifestFixture.smallFiles
    let manifest = try ManifestFixture.manifest(files: files)
    let staging = try makeStaging()
    try await withStubs {
      for f in files {
        DeliveryStubProtocol.enqueue(
          url: "https://mirror.invalid.example/base/\(f.path)",
          .init(
            status: 200, headers: ["Content-Length": String(f.content.count), "ETag": "\"e\""],
            body: f.content))
      }
      let outcome = try await task(manifest: manifest, staging: staging).run()
      #expect(outcome.sourcesUsed == 1)
      #expect(outcome.finalSourceID == "our_copy")
      #expect(outcome.bytesDownloaded == manifest.totalBytes)
      // Verified files must not leave resume sidecars behind — promotion
      // renames staged component dirs wholesale, so a surviving sidecar
      // would pollute the install dir (drill 12 follow-up, 2026-07-06).
      let leftovers = ((try? FileManager.default.subpathsOfDirectory(atPath: staging.path)) ?? [])
        .filter { $0.hasSuffix(".resume.json") }
      #expect(leftovers.isEmpty, "no resume sidecars after verified completion")
    }
  }

  @Test func perFileFailoverToBackupIsSticky() async throws {
    let files = ManifestFixture.smallFiles
    let manifest = try ManifestFixture.manifest(files: files)
    let staging = try makeStaging()
    try await withStubs {
      // Mirror 404s the FIRST file; backup serves everything. After the
      // failover, remaining files go straight to backup (sticky).
      DeliveryStubProtocol.enqueue(
        url: "https://mirror.invalid.example/base/\(files[0].path)",
        .init(status: 404, headers: [:], body: Data()))
      for f in files {
        DeliveryStubProtocol.enqueue(
          url: "https://upstream.invalid.example/base/\(f.path)",
          .init(
            status: 200, headers: ["Content-Length": String(f.content.count)], body: f.content))
      }
      final class FailoverLog: @unchecked Sendable {
        private let lock = NSLock()
        private var reasons: [DeliveryFailureClass] = []
        func record(_ reason: DeliveryFailureClass) {
          lock.withLock { reasons.append(reason) }
        }
        var all: [DeliveryFailureClass] { lock.withLock { reasons } }
      }
      let failovers = FailoverLog()
      let fetchTask = ManifestFetchTask(
        manifest: manifest, stagingDirectory: staging, sources: manifest.sources,
        componentsToFetch: Set(manifest.files.map(\.component)), verifiedInPlaceBytes: 0,
        onProgress: { _, _ in },
        onSourceFailover: { failovers.record($0) })
      let outcome = try await fetchTask.run()
      #expect(outcome.sourcesUsed == 2)
      #expect(outcome.finalSourceID == "backup")
      #expect(failovers.all == [.source4xx])
    }
  }

  @Test func hashMismatchFailsOverThenTerminalWhenBothBad() async throws {
    let files = [ManifestFixture.smallFiles[2]]
    let manifest = try ManifestFixture.manifest(files: files)
    let staging = try makeStaging()
    await withStubs {
      let wrong = Data("WRONG!!".utf8)  // same length as vocab content, wrong bytes
      for host in ["mirror", "upstream"] {
        DeliveryStubProtocol.enqueue(
          url: "https://\(host).invalid.example/base/vocab.json",
          .init(status: 200, headers: ["Content-Length": String(wrong.count)], body: wrong))
      }
      do {
        _ = try await task(manifest: manifest, staging: staging).run()
        Issue.record("expected integrity failure")
      } catch let failure as DeliveryFailure {
        #expect(failure.reason == .integrityMismatch)
        // Never admitted, and the corrupt bytes never left staging.
      } catch {
        Issue.record("unexpected error type: \(error)")
      }
    }
  }

  @Test func lengthMismatchFailsFastAsCaptivePortalSignature() async throws {
    let files = [ManifestFixture.smallFiles[2]]
    let manifest = try ManifestFixture.manifest(files: files)
    let staging = try makeStaging()
    await withStubs {
      let portal = Data("<html>sign in to hotel wifi</html>".utf8)
      for host in ["mirror", "upstream"] {
        DeliveryStubProtocol.enqueue(
          url: "https://\(host).invalid.example/base/vocab.json",
          .init(
            status: 200,
            headers: [
              "Content-Length": String(portal.count), "Content-Type": "text/html",
            ], body: portal))
      }
      do {
        _ = try await task(manifest: manifest, staging: staging).run()
        Issue.record("expected interception failure")
      } catch let failure as DeliveryFailure {
        #expect(failure.reason == .integrityMismatch)
        #expect(failure.detail == "intercepted_network")
      } catch {
        Issue.record("unexpected error type: \(error)")
      }
    }
  }

  @Test func resumeSendsRangeAndCompletesFromPartial() async throws {
    let files = [ManifestFixture.smallFiles[0]]  // "encoder-bytes" (13 bytes)
    let manifest = try ManifestFixture.manifest(files: files)
    let staging = try makeStaging()
    try await withStubs {
      // Seed a 7-byte partial + matching resume identity.
      let full = files[0].content
      let partial = full.prefix(7)
      let stagedURL = staging.appendingPathComponent(files[0].path)
      try FileManager.default.createDirectory(
        at: stagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try partial.write(to: stagedURL)
      let identity = ["etag": "\"e\"", "contentLength": files[0].content.count] as [String: Any]
      try JSONSerialization.data(withJSONObject: identity)
        .write(to: URL(fileURLWithPath: stagedURL.path + ".resume.json"))

      let url = "https://mirror.invalid.example/base/\(files[0].path)"
      // HEAD identity check answers 200 with matching identity...
      DeliveryStubProtocol.enqueue(
        url: url,
        .init(
          status: 200, headers: ["Content-Length": String(full.count), "ETag": "\"e\""],
          body: Data()))
      // ...then the ranged GET answers 206 with the tail.
      DeliveryStubProtocol.enqueue(
        url: url,
        .init(
          status: 206, headers: ["Content-Length": String(full.count - 7)],
          body: full.suffix(from: 7)))
      let outcome = try await task(manifest: manifest, staging: staging).run()
      #expect(outcome.bytesDownloaded == Int64(full.count - 7))
      #expect(DeliveryStubProtocol.seenRangeHeaders.contains("bytes=7-"))
    }
  }

  @Test func serverIgnoringRangeTruncatesAndRestarts() async throws {
    // 200 on a resumed request = whole object; the already-written prefix
    // must go (EG-1 semantics, inherited verbatim).
    let files = [ManifestFixture.smallFiles[0]]
    let manifest = try ManifestFixture.manifest(files: files)
    let staging = try makeStaging()
    try await withStubs {
      let full = files[0].content
      let stagedURL = staging.appendingPathComponent(files[0].path)
      try FileManager.default.createDirectory(
        at: stagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("garbage".utf8).write(to: stagedURL)
      let identity = ["etag": "\"e\"", "contentLength": full.count] as [String: Any]
      try JSONSerialization.data(withJSONObject: identity)
        .write(to: URL(fileURLWithPath: stagedURL.path + ".resume.json"))

      let url = "https://mirror.invalid.example/base/\(files[0].path)"
      DeliveryStubProtocol.enqueue(
        url: url,
        .init(
          status: 200, headers: ["Content-Length": String(full.count), "ETag": "\"e\""],
          body: Data()))
      DeliveryStubProtocol.enqueue(
        url: url,
        .init(status: 200, headers: ["Content-Length": String(full.count)], body: full))
      let outcome = try await task(manifest: manifest, staging: staging).run()
      #expect(outcome.bytesDownloaded >= Int64(full.count))
      let staged = try Data(contentsOf: stagedURL)
      #expect(staged == full, "prefix must be truncated when the server ignores Range")
    }
  }

  @Test func corruptFullSizeStagedFileSelfHealsFromSameSource() async throws {
    // A stale complete-size-but-corrupt staged file is a LOCAL problem: it
    // must be discarded and refetched from the SAME source, not blamed on
    // the source as integrity_mismatch (code-diff r6 P2).
    let files = [ManifestFixture.smallFiles[2]]
    let manifest = try ManifestFixture.manifest(files: files)
    let staging = try makeStaging()
    try await withStubs {
      let full = files[0].content
      let stagedURL = staging.appendingPathComponent(files[0].path)
      try FileManager.default.createDirectory(
        at: stagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("bad&&&&".utf8).write(to: stagedURL)  // full size, wrong bytes

      DeliveryStubProtocol.enqueue(
        url: "https://mirror.invalid.example/base/vocab.json",
        .init(status: 200, headers: ["Content-Length": String(full.count)], body: full))
      let outcome = try await task(manifest: manifest, staging: staging).run()
      #expect(outcome.sourcesUsed == 1, "self-heal must not fail over")
      #expect(outcome.finalSourceID == "our_copy")
      #expect(outcome.bytesDownloaded == Int64(full.count))
    }
  }

  // MARK: Pure decision tables

  @Test func resumeIdentityDiscardMatrix() throws {
    let manifest = try ManifestFixture.manifest(files: ManifestFixture.smallFiles)
    let fetchTask = ManifestFetchTask(
      manifest: manifest, stagingDirectory: FileManager.default.temporaryDirectory,
      sources: manifest.sources, componentsToFetch: [], verifiedInPlaceBytes: 0,
      onProgress: { _, _ in }, onSourceFailover: { _ in })
    // (recordedETag, recordedLength, headETag, headLength, existing, expected) -> discard?
    let cases: [(String??, Int64??, String?, Int64?, Int64, Int64, Bool, String)] = [
      (nil, nil, "\"e\"", 10, 5, 10, true, "no identity recorded"),
      ("\"e\"", 10, "\"e\"", 10, 5, 10, false, "matching identity resumes"),
      ("\"e\"", 10, "\"f\"", 10, 5, 10, true, "etag changed"),
      ("\"e\"", 10, "\"e\"", 12, 5, 10, true, "length changed"),
      ("\"e\"", 10, "\"e\"", 10, 11, 10, true, "impossibly large partial"),
      ("\"e\"", 10, nil, 10, 5, 10, true, "remote lost its etag"),
    ]
    for (rE, rL, hE, hL, existing, expected, discard, label) in cases {
      #expect(
        fetchTask.shouldDiscardPartial(
          recordedETag: rE, recordedLength: rL, headETag: hE, headLength: hL,
          existingBytes: existing, expectedSize: expected) == discard, "case: \(label)")
    }
  }

  /// Adversarial classification table (matcher-set rule): every class probed
  /// with a value from a NON-intended reading.
  @Test func transportErrorClassification() {
    func classify(_ error: Error) -> DeliveryFailureClass {
      ManifestFetchTask.classifyTransportError(error, sourceID: nil).reason
    }
    #expect(classify(URLError(.timedOut)) == .sourceTimeout)
    #expect(classify(URLError(.notConnectedToInternet)) == .sourceUnreachable)
    #expect(classify(URLError(.cannotFindHost)) == .sourceUnreachable)
    #expect(classify(URLError(.networkConnectionLost)) == .sourceUnreachable)
    #expect(classify(URLError(.cancelled)) == .cancelled)
    // Disk-write family must NOT read as network.
    #expect(
      classify(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
        == .insufficientDisk)
    #expect(
      classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == .insufficientDisk)
    #expect(
      classify(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        == .permissionDenied)
    // A read error is NOT a write error and must not claim disk.
    #expect(
      classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)) == .unknown)
    #expect(classify(NSError(domain: "Custom", code: 1)) == .unknown)
  }

  /// Phase 2 (#1405) retry-gate truth table (adversarial matcher-set rule): the
  /// retryable partition must retry every transient code and NOT retry
  /// genuine-offline / disk / permission / unknown.
  @Test func transportRetryablePartition() {
    func retryable(_ error: Error) -> Bool {
      ManifestFetchTask.classifyTransportError(error, sourceID: nil).retryableTransient
    }
    // Retryable: timeout + transient-unreachable family.
    #expect(retryable(URLError(.timedOut)) == true)
    #expect(retryable(URLError(.networkConnectionLost)) == true)
    #expect(retryable(URLError(.cannotConnectToHost)) == true)
    #expect(retryable(URLError(.cannotFindHost)) == true)
    #expect(retryable(URLError(.dnsLookupFailed)) == true)
    // NOT retryable: genuinely offline (the critical boundary), disk, perm.
    #expect(retryable(URLError(.notConnectedToInternet)) == false)
    #expect(
      retryable(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) == false)
    #expect(retryable(NSError(domain: "Custom", code: 1)) == false)
  }

  @Test func httpStatusClassification() {
    #expect(ManifestFetchTask.classifyHTTPStatus(429) == .source5xx)  // throttle = retryable-ish
    #expect(ManifestFetchTask.classifyHTTPStatus(500) == .source5xx)
    #expect(ManifestFetchTask.classifyHTTPStatus(503) == .source5xx)
    #expect(ManifestFetchTask.classifyHTTPStatus(404) == .source4xx)
    #expect(ManifestFetchTask.classifyHTTPStatus(416) == .source4xx)
    #expect(ManifestFetchTask.classifyHTTPStatus(301) == .unknown)  // redirects are transport-level
  }

  /// Phase 2 (#1405): HTTP-status failures stamp retryability + `Retry-After`.
  @Test func httpStatusRetryabilityAndRetryAfter() {
    func failure(_ status: Int, retryAfter: String? = nil) -> DeliveryFailure {
      var headers: [String: String] = [:]
      if let retryAfter { headers["Retry-After"] = retryAfter }
      let response = HTTPURLResponse(
        url: URL(string: "https://x.invalid")!, statusCode: status, httpVersion: nil,
        headerFields: headers)!
      return ManifestFetchTask.httpStatusFailure(
        status: status, detail: "http_\(status)", response: response, sourceID: nil)
    }
    #expect(failure(503).retryableTransient == true)
    #expect(failure(429).retryableTransient == true)
    #expect(failure(500).retryableTransient == true)
    #expect(failure(404).retryableTransient == false)
    // 4xx never carries a Retry-After even if the header is present.
    #expect(failure(404, retryAfter: "5").retryAfter == nil)
    #expect(failure(503, retryAfter: "5").retryAfter == 5)
  }

  /// Phase 2 (#1405): `Retry-After` parsing — BOTH the delay-seconds and the
  /// HTTP-date forms (RFC 9110 §10.2.3).
  @Test func retryAfterParsesBothForms() {
    func parse(_ value: String) -> TimeInterval? {
      let response = HTTPURLResponse(
        url: URL(string: "https://x.invalid")!, statusCode: 503, httpVersion: nil,
        headerFields: ["Retry-After": value])!
      return ManifestFetchTask.retryAfterSeconds(from: response)
    }
    #expect(parse("5") == 5)
    #expect(parse("0") == 0)
    #expect(parse("garbage") == nil)
    #expect(parse("") == nil)
    // HTTP-date ~100 s in the future parses to a positive, bounded delay.
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    let dateForm = parse(formatter.string(from: Date().addingTimeInterval(100)))
    #expect(dateForm != nil)
    if let dateForm { #expect(dateForm > 90 && dateForm <= 100) }
  }

  // MARK: Phase 2 (#1405) same-source retry — integration

  private typealias FileSpec = (path: String, content: Data, component: String)

  private func single() throws -> (DeliveryManifest, FileSpec, URL) {
    let file = ManifestFixture.smallFiles[0]
    return (try ManifestFixture.manifest(files: [file]), file, try makeStaging())
  }
  private func mirrorURL(_ file: FileSpec) -> String {
    "https://mirror.invalid.example/base/\(file.path)"
  }
  private func backupURL(_ file: FileSpec) -> String {
    "https://upstream.invalid.example/base/\(file.path)"
  }
  private func timeoutStub() -> DeliveryStubProtocol.Stub {
    .init(status: 200, headers: [:], body: Data(), error: URLError(.timedOut))
  }
  private func okStub(_ file: FileSpec, status: Int = 200)
    -> DeliveryStubProtocol.Stub
  {
    .init(
      status: status, headers: ["Content-Length": String(file.content.count)], body: file.content)
  }

  /// (a) A transient timeout retries the SAME source (resume) and completes —
  /// no failover.
  @Test func retryThenSucceedsSameSourceNoFailover() async throws {
    let (manifest, file, staging) = try single()
    try await withStubs {
      DeliveryStubProtocol.enqueue(url: mirrorURL(file), timeoutStub())
      DeliveryStubProtocol.enqueue(url: mirrorURL(file), okStub(file))
      let failovers = FailoverBox()
      let outcome = try await task(
        manifest: manifest, staging: staging, onFailover: { failovers.record($0) }
      ).run()
      #expect(outcome.sourcesUsed == 1)
      #expect(outcome.finalSourceID == "our_copy")
      #expect(failovers.all.isEmpty, "a transient timeout retries same-source, never fails over")
    }
  }

  /// (b) N=4 attempts (1 + 3 retries) exhausted → fail over to backup once.
  @Test func retriesExhaustedThenFailover() async throws {
    let (manifest, file, staging) = try single()
    try await withStubs {
      for _ in 0..<4 { DeliveryStubProtocol.enqueue(url: mirrorURL(file), timeoutStub()) }
      DeliveryStubProtocol.enqueue(url: backupURL(file), okStub(file))
      let failovers = FailoverBox()
      let outcome = try await task(
        manifest: manifest, staging: staging, onFailover: { failovers.record($0) }
      ).run()
      #expect(outcome.sourcesUsed == 2)
      #expect(outcome.finalSourceID == "backup")
      #expect(failovers.all == [.sourceTimeout])
    }
  }

  /// (b2) The retry budget is PER SOURCE: after the mirror exhausts its budget
  /// and fails over, the backup gets its OWN retries (Codex r1 P2 regression).
  @Test func backupGetsItsOwnRetryBudgetAfterFailover() async throws {
    let (manifest, file, staging) = try single()
    try await withStubs {
      for _ in 0..<4 { DeliveryStubProtocol.enqueue(url: mirrorURL(file), timeoutStub()) }
      // Backup times out ONCE then succeeds — only possible if its budget reset.
      DeliveryStubProtocol.enqueue(url: backupURL(file), timeoutStub())
      DeliveryStubProtocol.enqueue(url: backupURL(file), okStub(file))
      let failovers = FailoverBox()
      let outcome = try await task(
        manifest: manifest, staging: staging, onFailover: { failovers.record($0) }
      ).run()
      #expect(outcome.sourcesUsed == 2)
      #expect(outcome.finalSourceID == "backup")
      #expect(
        failovers.all == [.sourceTimeout], "one failover; the backup then retried on its own budget"
      )
    }
  }

  /// (c) A genuinely-offline error (-1009) fails over IMMEDIATELY — it must not
  /// consume a same-source retry (the mirror's second stub stays untouched).
  @Test func offlineFailsOverWithoutSameSourceRetry() async throws {
    let (manifest, file, staging) = try single()
    try await withStubs {
      DeliveryStubProtocol.enqueue(
        url: mirrorURL(file),
        .init(status: 200, headers: [:], body: Data(), error: URLError(.notConnectedToInternet)))
      // If offline WRONGLY retried, this success would be consumed on the mirror.
      DeliveryStubProtocol.enqueue(url: mirrorURL(file), okStub(file))
      DeliveryStubProtocol.enqueue(url: backupURL(file), okStub(file))
      let failovers = FailoverBox()
      let outcome = try await task(
        manifest: manifest, staging: staging, onFailover: { failovers.record($0) }
      ).run()
      #expect(outcome.sourcesUsed == 2, "offline must fail over, not retry the mirror")
      #expect(outcome.finalSourceID == "backup")
      #expect(failovers.all == [.sourceUnreachable])
    }
  }

  /// (e) Backoff is bounded by the full-jitter window `min(8, 2^n)`; jitter=1.0
  /// yields exactly [1, 2, 4] for the three retries.
  @Test func retryBackoffBoundedByFullJitterWindow() async throws {
    let (manifest, file, staging) = try single()
    try await withStubs {
      for _ in 0..<3 { DeliveryStubProtocol.enqueue(url: mirrorURL(file), timeoutStub()) }
      DeliveryStubProtocol.enqueue(url: mirrorURL(file), okStub(file))
      let delays = DelayBox()
      let outcome = try await task(
        manifest: manifest, staging: staging,
        backoffSleep: { delays.record($0) }, jitter: { 1.0 }
      ).run()
      #expect(delays.all == [1, 2, 4])
      #expect(outcome.sourcesUsed == 1)
    }
  }

  /// (f) A cancel landing during the backoff sleep unwinds as `.cancelled` —
  /// never a retry or failover.
  @Test func cancelDuringBackoffUnwindsAsCancelled() async throws {
    let (manifest, file, staging) = try single()
    try await withStubs {
      DeliveryStubProtocol.enqueue(url: mirrorURL(file), timeoutStub())
      let entered = TestSignal()
      let sleepSeam: @Sendable (TimeInterval) async throws -> Void = { _ in
        await entered.fire()
        try await Task.sleep(nanoseconds: .max)  // settle: suspends until the run task is cancelled (cancel is the signal)
      }
      let fetch = task(manifest: manifest, staging: staging, backoffSleep: sleepSeam)
      let runTask = Task { try await fetch.run() }
      await entered.wait()
      runTask.cancel()
      do {
        _ = try await runTask.value
        Issue.record("expected cancellation to propagate")
      } catch let failure as DeliveryFailure {
        #expect(failure.reason == .cancelled)
      } catch is CancellationError {
        // Also an acceptable cancelled unwind.
      }
    }
  }

  /// (g) `Retry-After` (≤ cap) is honored OVER the computed backoff.
  @Test func retryAfterHonoredOverComputedBackoff() async throws {
    let (manifest, file, staging) = try single()
    try await withStubs {
      DeliveryStubProtocol.enqueue(
        url: mirrorURL(file),
        .init(status: 503, headers: ["Retry-After": "5"], body: Data()))
      DeliveryStubProtocol.enqueue(url: mirrorURL(file), okStub(file))
      let delays = DelayBox()
      let outcome = try await task(
        manifest: manifest, staging: staging,
        backoffSleep: { delays.record($0) }, jitter: { 1.0 }
      ).run()
      #expect(delays.all == [5], "server Retry-After overrides backoff(0)=1")
      #expect(outcome.sourcesUsed == 1)
    }
  }

  /// (h) The local-byte (416) retry and the network retry use INDEPENDENT
  /// budgets: a 416-local retry plus a full network-retry budget (3) all resolve
  /// on the SAME source. Shared budgets would fail over on the 3rd timeout.
  @Test func localAndNetworkRetryBudgetsAreIndependent() async throws {
    let (manifest, file, staging) = try single()
    try await withStubs {
      // Seed a partial + matching identity so the first attempt resumes.
      let stagedURL = staging.appendingPathComponent(file.path)
      try FileManager.default.createDirectory(
        at: stagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try file.content.prefix(7).write(to: stagedURL)
      let identity = ["etag": "\"e\"", "contentLength": file.content.count] as [String: Any]
      try JSONSerialization.data(withJSONObject: identity)
        .write(to: URL(fileURLWithPath: stagedURL.path + ".resume.json"))

      let url = mirrorURL(file)
      // HEAD identity (200) → ranged GET 416 (local retry) → 3 timeouts (network
      // retries) → success. All on the mirror.
      DeliveryStubProtocol.enqueue(
        url: url,
        .init(
          status: 200, headers: ["Content-Length": String(file.content.count), "ETag": "\"e\""],
          body: Data()))
      DeliveryStubProtocol.enqueue(url: url, .init(status: 416, headers: [:], body: Data()))
      for _ in 0..<3 { DeliveryStubProtocol.enqueue(url: url, timeoutStub()) }
      DeliveryStubProtocol.enqueue(url: url, okStub(file))
      let failovers = FailoverBox()
      let outcome = try await task(
        manifest: manifest, staging: staging, onFailover: { failovers.record($0) }
      ).run()
      #expect(outcome.sourcesUsed == 1, "independent budgets keep it on one source")
      #expect(failovers.all.isEmpty)
    }
  }

  /// (i) A `Retry-After` LONGER than the wedge-floor cap fails over instead of
  /// sitting in a silent wait (that would trip the stall guard).
  @Test func longRetryAfterFailsOverInsteadOfWaiting() async throws {
    let (manifest, file, staging) = try single()
    try await withStubs {
      DeliveryStubProtocol.enqueue(
        url: mirrorURL(file),
        .init(status: 503, headers: ["Retry-After": "60"], body: Data()))
      DeliveryStubProtocol.enqueue(url: backupURL(file), okStub(file))
      let delays = DelayBox()
      let outcome = try await task(
        manifest: manifest, staging: staging, backoffSleep: { delays.record($0) },
        onFailover: { _ in }
      ).run()
      #expect(delays.all.isEmpty, "a long Retry-After must not wait")
      #expect(outcome.sourcesUsed == 2)
      #expect(outcome.finalSourceID == "backup")
    }
  }

  /// #1405: a MODEL-LOAD wedge recovery must NOT cancel an in-flight delivery
  /// download — the download owns its own stall detection (the fetcher's request
  /// idle timeout) and the wedge guard stays parked during the download phase.
  /// This is the inverse of the reverted #1371 behavior: `recoverFromWedge()`
  /// leaves a running download untouched. Lives in THIS serialized suite (not
  /// the adapter's) so it does not race the shared `DeliveryStubProtocol` global.
  @MainActor
  @Test func recoverFromWedgeLeavesInFlightDeliveryRunning() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("wedge-\(UUID().uuidString)", isDirectory: true)
    let install = root.appendingPathComponent("install", isDirectory: true)
    let metadata = root.appendingPathComponent("metadata", isDirectory: true)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    let host = "https://wedge.invalid.example/\(UUID().uuidString)/"
    let files = ManifestFixture.smallFiles
    let manifest = try DeliveryManifest.load(
      from: ManifestFixture.manifestJSON(
        files: files,
        sources: [["id": "our_copy", "baseURL": host], ["id": "backup", "baseURL": host]]))
    let registration = DeliveryRegistration(
      manifest: manifest, installDirectory: install, metadataDirectory: metadata)
    let suite = "test.wedge.\(UUID().uuidString)"
    let controller = ModelDeliveryController(
      defaults: UserDefaults(suiteName: suite)!, availableDiskBytes: { _ in .max })
    let handle = ParakeetDeliveryHandle(
      controller: controller, registration: registration,
      defaults: UserDefaults(suiteName: suite)!)
    let adapter = ParakeetEngineAdapter(asrManager: StubParakeetASRManager(), delivery: handle)

    DeliveryStubProtocol.reset()
    ChunkAppendDelegate.protocolClassesForTesting = [DeliveryStubProtocol.self]
    let firstURL = URL(string: host)!.appendingPathComponent(files[0].path).absoluteString
    // Real Content-Length + a PARTIAL body so the length gate ALLOWS the
    // response and the transfer stays genuinely in-flight (a mismatched length
    // would fast-fail before any hang, leaving the cancel to race retry churn
    // instead of a real hung download — code-diff r1 P2).
    DeliveryStubProtocol.enqueue(
      url: firstURL,
      .init(
        status: 200, headers: ["Content-Length": String(files[0].content.count)],
        body: Data([1, 2, 3]), hangAfterBody: true))

    let inflight = WedgeSignal()
    await controller.addStateObserver { _, state in
      if case .downloading = state { Task { await inflight.fire() } }
    }
    let warm = Task { @MainActor in try? await adapter.warmUp() }
    await inflight.wait()

    // A model-LOAD wedge recovery must leave the in-flight download alone.
    await adapter.recoverFromWedge()
    let state = await controller.state(of: registration.manifest.identity)
    guard case .downloading = state else {
      let detail =
        "recoverFromWedge must leave the in-flight download running "
        + "(delivery owns its own stall detection), got \(state)"
      Issue.record(Comment(rawValue: detail))
      _ = await controller.cancel(registration.manifest.identity)
      _ = await warm.value
      return
    }

    // Cleanup: the stub hangs forever, so cancel explicitly to unblock warmUp.
    _ = await controller.cancel(registration.manifest.identity)
    _ = await warm.value
  }
}

/// Minimal async signal for the #1371 in-flight-cancel test.
private actor WedgeSignal {
  private var fired = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func fire() {
    fired = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
  func wait() async {
    if fired { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

/// Minimal async signal for the cancel-during-backoff test.
private actor TestSignal {
  private var fired = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func fire() {
    fired = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
  func wait() async {
    if fired { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

/// Records source-failover reasons across the concurrent fetch.
private final class FailoverBox: @unchecked Sendable {
  private let lock = NSLock()
  private var reasons: [DeliveryFailureClass] = []
  func record(_ reason: DeliveryFailureClass) { lock.withLock { reasons.append(reason) } }
  var all: [DeliveryFailureClass] { lock.withLock { reasons } }
}

/// Records the backoff delays the retry loop asked the (injected) sleep for.
private final class DelayBox: @unchecked Sendable {
  private let lock = NSLock()
  private var delays: [TimeInterval] = []
  func record(_ delay: TimeInterval) { lock.withLock { delays.append(delay) } }
  var all: [TimeInterval] { lock.withLock { delays } }
}
