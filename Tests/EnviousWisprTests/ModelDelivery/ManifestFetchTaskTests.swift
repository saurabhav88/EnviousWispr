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
    var error: (any Error)?
    /// Phase 2 (#1371): after sending the response + body, leave the request
    /// in-flight (never finish) so an in-flight-download cancel can be exercised.
    var hangAfterBody: Bool

    init(
      status: Int, headers: [String: String], body: Data, error: (any Error)? = nil,
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
  /// #3546: every request as "METHOD absoluteURL", in arrival order, so a test
  /// can prove which source and which representation (part or whole) was asked for.
  nonisolated(unsafe) static var seenRequests: [String] = []
  static let lock = NSLock()

  static func reset() {
    lock.lock()
    stubs = [:]
    seenRangeHeaders = []
    seenRequests = []
    lock.unlock()
  }

  static var requests: [String] {
    lock.lock()
    defer { lock.unlock() }
    return seenRequests
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
    Self.seenRequests.append("\(request.httpMethod ?? "GET") \(request.url!.absoluteString)")
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
@Suite(.serialized, .tags(.productOutcome)) struct ManifestFetchTaskTests {
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
    onFailover: @escaping @Sendable (DeliveryFailureClass, String, String) -> Void = {
      _, _, _ in
    }
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

  @Test func checkerCancelDuringRetryThenAdmitsOnRetry() async throws {
    let bytes = Data("adapter".utf8)
    let manifest = try LearnedWordCheckerDeliveryTests.tinyChecker(bytes)
    let staging = try makeStaging()
    let install = staging.deletingLastPathComponent().appendingPathComponent(
      "checker-install-\(UUID().uuidString)")
    let metadata = staging.deletingLastPathComponent().appendingPathComponent(
      "checker-metadata-\(UUID().uuidString)")
    try await withStubs {
      let url = manifest.sources[0].baseURL
        .appendingPathComponent(manifest.files[0].path).absoluteString
      DeliveryStubProtocol.enqueue(
        url: url, .init(status: 200, headers: [:], body: Data(), error: URLError(.timedOut)))

      let (signal, announced) = AsyncStream<Void>.makeStream()
      let first = Task {
        try await task(
          manifest: manifest, staging: staging,
          backoffSleep: { _ in
            announced.yield(())
            try await Task.sleep(nanoseconds: .max)  // deadline-fallback: cancellation is the signal
          }
        ).run()
      }
      let reachedBackoff = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
          for await _ in signal { return true }
          return false
        }
        group.addTask {
          try? await Task.sleep(for: .seconds(5))  // deadline-fallback: bounded signal wait
          return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        announced.finish()
        return result
      }
      if !reachedBackoff {
        first.cancel()
        _ = try? await first.value
        Issue.record("checker never reached retry backoff")
        return
      }
      first.cancel()
      do {
        _ = try await first.value
        Issue.record("cancelled checker fetch unexpectedly completed")
      } catch let failure as DeliveryFailure {
        #expect(failure.reason == .cancelled)
      } catch is CancellationError {
        // Task cancellation is also a valid unwind from the injected sleep.
      }

      DeliveryStubProtocol.enqueue(
        url: url,
        .init(status: 200, headers: ["Content-Length": String(bytes.count)], body: bytes))
      let outcome = try await task(manifest: manifest, staging: staging).run()
      #expect(outcome.bytesDownloaded == Int64(bytes.count))
      let gate = CacheAdmission(
        manifest: manifest, installDirectory: install, metadataDirectory: metadata)
      let component = try #require(manifest.files.first?.component)
      try gate.promoteAndAdmit(
        stagedComponents: [component], stagingDirectory: staging, untouchedComponents: [])
      #expect(gate.isAdmitted())
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
      /// Records the whole failover, not just its reason (#2135). The source
      /// transition is the diagnostic — "a failover happened" cannot say which
      /// mirror fell over — and a value no test reads is a value that can be
      /// wrong without anything noticing.
      final class FailoverLog: @unchecked Sendable {
        struct Entry: Equatable {
          let reason: DeliveryFailureClass
          let from: String
          let to: String
        }
        private let lock = NSLock()
        private var entries: [Entry] = []
        func record(_ reason: DeliveryFailureClass, _ from: String, _ to: String) {
          lock.withLock { entries.append(Entry(reason: reason, from: from, to: to)) }
        }
        var all: [Entry] { lock.withLock { entries } }
        var reasons: [DeliveryFailureClass] { all.map(\.reason) }
      }
      let failovers = FailoverLog()
      let fetchTask = ManifestFetchTask(
        manifest: manifest, stagingDirectory: staging, sources: manifest.sources,
        componentsToFetch: Set(manifest.files.map(\.component)), verifiedInPlaceBytes: 0,
        onProgress: { _, _ in },
        onSourceFailover: { failovers.record($0, $1, $2) })
      let outcome = try await fetchTask.run()
      #expect(outcome.sourcesUsed == 2)
      #expect(outcome.finalSourceID == "backup")
      #expect(failovers.reasons == [.source4xx])
      #expect(
        failovers.all == [
          FailoverLog.Entry(reason: .source4xx, from: "our_copy", to: "backup")
        ],
        "the failover must name the mirror it left and the one it moved to")
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
      onProgress: { _, _ in }, onSourceFailover: { _, _, _ in })
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
        manifest: manifest, staging: staging, onFailover: { failovers.record($0, $1, $2) }
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
        manifest: manifest, staging: staging, onFailover: { failovers.record($0, $1, $2) }
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
        manifest: manifest, staging: staging, onFailover: { failovers.record($0, $1, $2) }
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
        manifest: manifest, staging: staging, onFailover: { failovers.record($0, $1, $2) }
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
        manifest: manifest, staging: staging, onFailover: { failovers.record($0, $1, $2) }
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
        onFailover: { _, _, _ in }
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
      defaults: TestDefaults.suite(suite)!, availableDiskBytes: { _ in .max })
    let handle = ParakeetDeliveryHandle(
      controller: controller, registration: registration,
      defaults: TestDefaults.suite(suite)!)
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
  /// `all` stays the REASON list so the assertions written against it keep their
  /// exact meaning; the transition is recorded alongside it for the cases that
  /// care which mirror was left (#2135).
  struct Entry: Equatable {
    let reason: DeliveryFailureClass
    let from: String
    let to: String
  }
  private let lock = NSLock()
  private var entries: [Entry] = []
  func record(_ reason: DeliveryFailureClass, _ from: String, _ to: String) {
    lock.withLock { entries.append(Entry(reason: reason, from: from, to: to)) }
  }
  var all: [DeliveryFailureClass] { lock.withLock { entries.map(\.reason) } }
  var transitions: [Entry] { lock.withLock { entries } }
}

/// Records the backoff delays the retry loop asked the (injected) sleep for.
private final class DelayBox: @unchecked Sendable {
  private let lock = NSLock()
  private var delays: [TimeInterval] = []
  func record(_ delay: TimeInterval) { lock.withLock { delays.append(delay) } }
  var all: [TimeInterval] { lock.withLock { delays } }
}

// MARK: - Contract §4d parts delivery (#3546)

extension ManifestFetchTaskTests {
  /// One 10-byte file. `our_copy` serves it as two 5-byte parts; `backup`
  /// serves it whole. Expected bytes and hashes are literal, independent of
  /// the fetcher.
  fileprivate static let partsContent = Data("0123456789".utf8)
  fileprivate static let partsFile = "weights.bin"
  fileprivate static let mirrorBase = "https://mirror.invalid.example/base/"
  fileprivate static let backupBase = "https://upstream.invalid.example/base/"

  fileprivate static func partsManifest(
    parts: [Data] = [Data("01234".utf8), Data("56789".utf8)],
    fileContent: Data = partsContent, withBackup: Bool = true, family: String = "parakeet",
    name: String = "fixture-model"
  ) throws -> DeliveryManifest {
    var sources = [["id": "our_copy", "baseURL": mirrorBase]]
    if withBackup { sources.append(["id": "backup", "baseURL": backupBase]) }
    return try DeliveryManifest.load(
      from: ManifestFixture.manifestJSON(
        files: [(partsFile, fileContent, partsFile)], sources: sources, family: family
      ) { object in
        var identity = object["identity"] as! [String: Any]
        identity["name"] = name
        object["identity"] = identity
        var files = object["files"] as! [[String: Any]]
        files[0]["parts"] = parts.enumerated().map {
          [
            "path": "\(partsFile).part-\($0.offset + 1)", "sizeBytes": $0.element.count,
            "sha256": ManifestFixture.sha256($0.element),
          ] as [String: Any]
        }
        object["files"] = files
        var list = object["sources"] as! [[String: Any]]
        list[0]["servesParts"] = true
        object["sources"] = list
      })
  }

  private func servePart(_ index: Int, _ body: Data, hang: Bool = false) {
    DeliveryStubProtocol.enqueue(
      url: "\(Self.mirrorBase)\(Self.partsFile).part-\(index)",
      .init(
        status: 200, headers: ["Content-Length": String(body.count), "ETag": "\"p\(index)\""],
        body: body, hangAfterBody: hang))
  }

  private func stagePart(_ manifest: DeliveryManifest, staging: URL, index: Int, _ body: Data)
    throws -> URL
  {
    let url = ManifestFetchTask.TransportLayout.partURL(
      in: staging, file: manifest.files[0], index: index)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try body.write(to: url)
    return url
  }

  private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func append(_ value: Int64) {
      lock.lock()
      values.append(value)
      lock.unlock()
    }
    var all: [Int64] {
      lock.lock()
      defer { lock.unlock() }
      return values
    }
  }

  private func partsTask(
    manifest: DeliveryManifest, staging: URL, progress: ProgressLog? = nil,
    assemblyWrite: (@Sendable (FileHandle, Data) async throws -> Void)? = nil
  ) -> ManifestFetchTask {
    var fetch = ManifestFetchTask(
      manifest: manifest, stagingDirectory: staging, sources: manifest.sources,
      componentsToFetch: Set(manifest.files.map(\.component)), verifiedInPlaceBytes: 0,
      onProgress: { bytes, _ in progress?.append(bytes) }, onSourceFailover: { _, _, _ in },
      backoffSleep: { _ in }, jitterFraction: { 1.0 })
    if let assemblyWrite { fetch.assemblyWrite = assemblyWrite }
    return fetch
  }

  private func stagedFile(_ staging: URL) -> URL {
    staging.appendingPathComponent(Self.partsFile)
  }

  private func transportRoot(_ staging: URL) -> URL {
    ManifestFetchTask.TransportLayout.root(in: staging)
  }

  @Test func partsAreFetchedVerifiedAssembledAndLeaveNoResidueAfterPromotion() async throws {
    let manifest = try Self.partsManifest()
    let staging = try makeStaging()
    let progress = ProgressLog()
    try await withStubs {
      servePart(1, Data("01234".utf8))
      servePart(2, Data("56789".utf8))
      let outcome = try await partsTask(manifest: manifest, staging: staging, progress: progress)
        .run()
      #expect(outcome.finalSourceID == "our_copy")
      #expect(outcome.sourcesUsed == 1)
      #expect(outcome.bytesDownloaded == 10)
      #expect(try Data(contentsOf: stagedFile(staging)) == Self.partsContent)
      #expect(
        DeliveryStubProtocol.requests == [
          "GET https://mirror.invalid.example/base/weights.bin.part-1",
          "GET https://mirror.invalid.example/base/weights.bin.part-2",
        ])
      #expect(FileManager.default.fileExists(atPath: transportRoot(staging).path) == false)
      // Logical progress: never above the file's size, and ends exactly on it.
      #expect(progress.all.allSatisfy { $0 <= 10 })
      #expect(progress.all.last == 10)

      let install = staging.deletingLastPathComponent().appendingPathComponent(
        "parts-install-\(UUID().uuidString)")
      let metadata = staging.deletingLastPathComponent().appendingPathComponent(
        "parts-metadata-\(UUID().uuidString)")
      let gate = CacheAdmission(
        manifest: manifest, installDirectory: install, metadataDirectory: metadata)
      try gate.promoteAndAdmit(
        stagedComponents: [Self.partsFile], stagingDirectory: staging, untouchedComponents: [])
      #expect(gate.isAdmitted())
      #expect(try FileManager.default.contentsOfDirectory(atPath: install.path) == [Self.partsFile])
      #expect(
        try Data(contentsOf: install.appendingPathComponent(Self.partsFile)) == Self.partsContent)
    }
  }

  @Test func aFailingPartsSourceFailsOverToTheWholeFileOnBackup() async throws {
    let manifest = try Self.partsManifest()
    let staging = try makeStaging()
    let progress = ProgressLog()
    try await withStubs {
      DeliveryStubProtocol.enqueue(
        url: "\(Self.mirrorBase)\(Self.partsFile).part-1",
        .init(status: 404, headers: [:], body: Data()))
      DeliveryStubProtocol.enqueue(
        url: "\(Self.backupBase)\(Self.partsFile)",
        .init(status: 200, headers: ["Content-Length": "10"], body: Self.partsContent))
      let outcome = try await partsTask(manifest: manifest, staging: staging, progress: progress)
        .run()
      #expect(outcome.sourcesUsed == 2)
      #expect(outcome.finalSourceID == "backup")
      #expect(
        DeliveryStubProtocol.requests == [
          "GET https://mirror.invalid.example/base/weights.bin.part-1",
          "GET https://upstream.invalid.example/base/weights.bin",
        ])
      #expect(try Data(contentsOf: stagedFile(staging)) == Self.partsContent)
      #expect(progress.all.allSatisfy { $0 <= 10 })
      #expect(progress.all.last == 10)
    }
  }

  @Test func aCorruptPartIsNeverAssembled() async throws {
    let manifest = try Self.partsManifest(withBackup: false)
    let staging = try makeStaging()
    try await withStubs {
      servePart(1, Data("01234".utf8))
      servePart(2, Data("5678X".utf8))
      do {
        _ = try await partsTask(manifest: manifest, staging: staging).run()
        Issue.record("a corrupt part completed the fetch")
      } catch let failure as DeliveryFailure {
        #expect(failure.reason == .integrityMismatch)
        #expect(failure.detail == "sha256:weights.bin:part2")
      }
      #expect(FileManager.default.fileExists(atPath: stagedFile(staging).path) == false)
    }
  }

  @Test func anAssemblyThatDoesNotMatchTheWholeFileIsNeverStaged() async throws {
    // Each part matches its own hash, but together they are not the file the
    // manifest names: the whole-file check must refuse the result.
    let manifest = try Self.partsManifest(
      parts: [Data("01234".utf8), Data("5678X".utf8)], withBackup: false)
    let staging = try makeStaging()
    try await withStubs {
      servePart(1, Data("01234".utf8))
      servePart(2, Data("5678X".utf8))
      do {
        _ = try await partsTask(manifest: manifest, staging: staging).run()
        Issue.record("a mismatched assembly completed the fetch")
      } catch let failure as DeliveryFailure {
        #expect(failure.reason == .integrityMismatch)
        #expect(failure.detail == "sha256:weights.bin:assembled")
      }
      #expect(FileManager.default.fileExists(atPath: stagedFile(staging).path) == false)
      let assembling = ManifestFetchTask.TransportLayout.assemblyURL(
        in: staging, file: manifest.files[0])
      #expect(FileManager.default.fileExists(atPath: assembling.path) == false)
      // Parts that cannot be trusted together are not kept for a later attempt.
      for index in 0..<2 {
        let part = ManifestFetchTask.TransportLayout.partURL(
          in: staging, file: manifest.files[0], index: index)
        #expect(FileManager.default.fileExists(atPath: part.path) == false)
      }
    }
  }

  @Test func aTransportCleanupFailureEndsTheAttemptWithoutSuccess() async throws {
    let manifest = try Self.partsManifest()
    let staging = try makeStaging()
    try await withStubs {
      _ = try stagePart(manifest, staging: staging, index: 0, Data("01234".utf8))
      _ = try stagePart(manifest, staging: staging, index: 1, Data("56789".utf8))
      // An undeletable item in the transport area makes its removal fail.
      let stuck = transportRoot(staging).appendingPathComponent("stuck")
      try Data("x".utf8).write(to: stuck)
      try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: stuck.path)
      defer {
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: stuck.path)
      }
      do {
        _ = try await partsTask(manifest: manifest, staging: staging).run()
        Issue.record("a failed transport cleanup reported success")
      } catch let failure as DeliveryFailure {
        #expect(failure.reason == .cacheRepairFailed)
        #expect(failure.detail == "transport_cleanup:.ew-transport")
      }
    }
  }

  @Test func accountingBudgetsEveryPermittedRepresentation() async throws {
    // Literal expectations for a 10-byte file served as 5 + 5 by our_copy.
    let manifest = try Self.partsManifest()
    let file = manifest.files[0]
    let ourCopy = manifest.sources[0]
    let backup = manifest.sources[1]
    let staging = try makeStaging()
    // Backup first, 4 whole bytes staged: progress starts at 4, but a failover
    // to parts could still need 10 parts + 10 assembly.
    try Data("0123".utf8).write(to: stagedFile(staging))
    let backupFirst = await ManifestFetchTask.stagedAccounting(
      of: file, sources: [backup, ourCopy], in: staging)
    #expect(backupFirst.logicalStaged == 4)
    #expect(backupFirst.diskNeeded == 20)
    #expect(backupFirst.assemblyFloor == 10)
    // Backup only: the whole file is the only representation.
    let backupOnly = await ManifestFetchTask.stagedAccounting(
      of: file, sources: [backup], in: staging)
    #expect(backupOnly.logicalStaged == 4)
    #expect(backupOnly.diskNeeded == 6)
    #expect(backupOnly.assemblyFloor == 0)
    // Parts first with both parts staged: only the assembly output is left.
    try FileManager.default.removeItem(at: stagedFile(staging))
    _ = try stagePart(manifest, staging: staging, index: 0, Data("01234".utf8))
    _ = try stagePart(manifest, staging: staging, index: 1, Data("56789".utf8))
    let partsFirst = await ManifestFetchTask.stagedAccounting(
      of: file, sources: [ourCopy, backup], in: staging)
    #expect(partsFirst.logicalStaged == 10)
    #expect(partsFirst.diskNeeded == 10)
    #expect(partsFirst.assemblyFloor == 10)
  }

  @Test func fullSizePartsStagingSkipsBudgetOnlyWhenVerified() async throws {
    let manifest = try Self.partsManifest()
    let file = manifest.files[0]
    let staging = try makeStaging()

    try Data("XXXXXXXXXX".utf8).write(to: stagedFile(staging))
    let corrupt = await ManifestFetchTask.stagedAccounting(
      of: file, sources: manifest.sources, in: staging)
    #expect(corrupt.logicalStaged == 0)
    #expect(corrupt.diskNeeded == 20)
    #expect(corrupt.assemblyFloor == 10)

    try Self.partsContent.write(to: stagedFile(staging))
    let verified = await ManifestFetchTask.stagedAccounting(
      of: file, sources: manifest.sources, in: staging)
    #expect(verified.logicalStaged == 10)
    #expect(verified.diskNeeded == 0)
    #expect(verified.assemblyFloor == 0)
  }

  @Test func eachPartHasItsOwnNetworkRetryBudget() async throws {
    // Two transient failures per part: within each part's own budget of three,
    // but over a single shared budget. No failover may happen.
    let manifest = try Self.partsManifest()
    let staging = try makeStaging()
    try await withStubs {
      for index in 1...2 {
        let url = "\(Self.mirrorBase)\(Self.partsFile).part-\(index)"
        for _ in 0..<2 {
          DeliveryStubProtocol.enqueue(
            url: url, .init(status: 200, headers: [:], body: Data(), error: URLError(.timedOut)))
        }
      }
      servePart(1, Data("01234".utf8))
      servePart(2, Data("56789".utf8))
      let outcome = try await partsTask(manifest: manifest, staging: staging).run()
      #expect(outcome.sourcesUsed == 1)
      #expect(outcome.finalSourceID == "our_copy")
      #expect(try Data(contentsOf: stagedFile(staging)) == Self.partsContent)
    }
  }

  @Test func aWholeFilePartialIsDiscardedBeforePartsAreFetched() async throws {
    let manifest = try Self.partsManifest()
    let staging = try makeStaging()
    try await withStubs {
      try Data("0123".utf8).write(to: stagedFile(staging))
      servePart(1, Data("01234".utf8))
      servePart(2, Data("56789".utf8))
      let staged = stagedFile(staging)
      let observed = ProgressLog()
      let assemblyDone = ProgressLog()
      // Observed while transport bytes land AND during assembly. The file's
      // own completion report (after assembly put the new file in place) is
      // not an observation of the stale partial, so it is excluded.
      let fetch = ManifestFetchTask(
        manifest: manifest, stagingDirectory: staging, sources: manifest.sources,
        componentsToFetch: Set(manifest.files.map(\.component)), verifiedInPlaceBytes: 0,
        onProgress: { _, _ in
          guard assemblyDone.all.isEmpty else { return }
          observed.append(FileManager.default.fileExists(atPath: staged.path) ? 1 : 0)
        },
        onSourceFailover: { _, _, _ in }, backoffSleep: { _ in },
        assemblyWrite: { handle, chunk in
          observed.append(FileManager.default.fileExists(atPath: staged.path) ? 1 : 0)
          try handle.write(contentsOf: chunk)
          assemblyDone.append(1)
        })
      _ = try await fetch.run()
      #expect(observed.all.count >= 3, "both part reports and the assembly step were observed")
      #expect(observed.all.allSatisfy { $0 == 0 }, "the stale partial was still on disk")
      #expect(try Data(contentsOf: staged) == Self.partsContent)
    }
  }

  @Test func aTransportAreaThatResolvesOutsideStagingIsRefused() async throws {
    let manifest = try Self.partsManifest()
    let staging = try makeStaging()
    let elsewhere = try makeStaging()
    try await withStubs {
      try FileManager.default.createSymbolicLink(
        at: transportRoot(staging), withDestinationURL: elsewhere)
      do {
        _ = try await partsTask(manifest: manifest, staging: staging).run()
        Issue.record("a redirected transport area was used")
      } catch let failure as DeliveryFailure {
        #expect(failure.reason == .cacheRepairFailed)
        #expect(failure.detail == "unsafe_transport")
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
      #expect(DeliveryStubProtocol.requests.isEmpty)
    }
  }

  @Test(
    "a part or sidecar that leads outside staging is refused before any request",
    arguments: [("part, existing target", true, false), ("sidecar, dangling target", false, true)])
  func transportLeavesThatLeaveStagingAreRefused(
    label: String, redirectPart: Bool, dangling: Bool
  ) async throws {
    let manifest = try Self.partsManifest()
    let staging = try makeStaging()
    let outside = try makeStaging()
    let outsideFile = outside.appendingPathComponent("victim.bin")
    try Data("UNTOUCHED".utf8).write(to: outsideFile)
    try await withStubs {
      let partURL = ManifestFetchTask.TransportLayout.partURL(
        in: staging, file: manifest.files[0], index: 0)
      try FileManager.default.createDirectory(
        at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let leaf = redirectPart ? partURL : URL(fileURLWithPath: partURL.path + ".resume.json")
      let target = dangling ? outside.appendingPathComponent("missing.json") : outsideFile
      try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target)
      do {
        _ = try await partsTask(manifest: manifest, staging: staging).run()
        Issue.record("\(label): a redirected transport leaf was used")
      } catch let failure as DeliveryFailure {
        #expect(failure.reason == .cacheRepairFailed, "\(label)")
        #expect(failure.detail == "unsafe_transport", "\(label)")
      }
      #expect(DeliveryStubProtocol.requests.isEmpty, "\(label)")
      #expect(try Data(contentsOf: outsideFile) == Data("UNTOUCHED".utf8), "\(label)")
      #expect(
        FileManager.default.fileExists(atPath: outside.appendingPathComponent("missing.json").path)
          == false, "\(label)")
    }
  }

  @Test func aWholeFileDiskFailureDoesNotTryBackup() async throws {
    let manifest = try ManifestFixture.manifest(
      files: [("weights.bin", Self.partsContent, "weights.bin")])
    let staging = try makeStaging()
    let failovers = FailoverBox()
    try await withStubs {
      DeliveryStubProtocol.enqueue(
        url: "\(Self.mirrorBase)weights.bin",
        .init(
          status: 200, headers: [:], body: Data(),
          error: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
      DeliveryStubProtocol.enqueue(
        url: "\(Self.backupBase)weights.bin", .init(status: 404, headers: [:], body: Data()))
      do {
        _ = try await task(
          manifest: manifest, staging: staging, onFailover: { failovers.record($0, $1, $2) }
        ).run()
        Issue.record("a whole-file disk failure completed the fetch")
      } catch let failure as DeliveryFailure {
        #expect(failure.reason == .insufficientDisk)
      }
      #expect(failovers.all.isEmpty)
      #expect(
        DeliveryStubProtocol.requests == ["GET https://mirror.invalid.example/base/weights.bin"])
    }
  }

  @Test func aPartResumesMidwayWithARangeRequest() async throws {
    let manifest = try Self.partsManifest()
    let staging = try makeStaging()
    try await withStubs {
      _ = try stagePart(manifest, staging: staging, index: 0, Data("01234".utf8))
      let partial = try stagePart(manifest, staging: staging, index: 1, Data("56".utf8))
      let identity = ["etag": "\"p2\"", "contentLength": 5] as [String: Any]
      try JSONSerialization.data(withJSONObject: identity)
        .write(to: URL(fileURLWithPath: partial.path + ".resume.json"))
      let url = "\(Self.mirrorBase)\(Self.partsFile).part-2"
      DeliveryStubProtocol.enqueue(
        url: url,
        .init(status: 200, headers: ["Content-Length": "5", "ETag": "\"p2\""], body: Data()))
      DeliveryStubProtocol.enqueue(
        url: url, .init(status: 206, headers: ["Content-Length": "3"], body: Data("789".utf8)))
      let outcome = try await partsTask(manifest: manifest, staging: staging).run()
      #expect(outcome.bytesDownloaded == 3)
      #expect(DeliveryStubProtocol.seenRangeHeaders == ["bytes=2-"])
      #expect(try Data(contentsOf: stagedFile(staging)) == Self.partsContent)
    }
  }

  @Test func anInterruptedAssemblyRestartsFromZeroAndReusesVerifiedParts() async throws {
    let manifest = try Self.partsManifest()
    let staging = try makeStaging()
    try await withStubs {
      _ = try stagePart(manifest, staging: staging, index: 0, Data("01234".utf8))
      _ = try stagePart(manifest, staging: staging, index: 1, Data("56789".utf8))
      // A previous assembly died after writing more than the whole file.
      let assembling = ManifestFetchTask.TransportLayout.assemblyURL(
        in: staging, file: manifest.files[0])
      try Data("STALE-STALE-STALE".utf8).write(to: assembling)
      let outcome = try await partsTask(manifest: manifest, staging: staging).run()
      #expect(outcome.bytesDownloaded == 0)
      #expect(DeliveryStubProtocol.requests.isEmpty)
      #expect(try Data(contentsOf: stagedFile(staging)) == Self.partsContent)
      #expect(FileManager.default.fileExists(atPath: transportRoot(staging).path) == false)
    }
  }

  @Test func cancellingDuringAssemblyStopsWithoutFailoverOrStagedFile() async throws {
    let manifest = try Self.partsManifest()
    let staging = try makeStaging()
    try await withStubs {
      _ = try stagePart(manifest, staging: staging, index: 0, Data("01234".utf8))
      _ = try stagePart(manifest, staging: staging, index: 1, Data("56789".utf8))
      let fetch = partsTask(
        manifest: manifest, staging: staging,
        assemblyWrite: { handle, chunk in
          // Cancel at the real assembly step, then let the write land: the
          // next cooperative check must stop the assembly.
          withUnsafeCurrentTask { $0?.cancel() }
          try handle.write(contentsOf: chunk)
        })
      do {
        _ = try await Task { try await fetch.run() }.value
        Issue.record("a cancelled assembly completed the fetch")
      } catch let failure as DeliveryFailure {
        #expect(failure.reason == .cancelled)
      }
      #expect(DeliveryStubProtocol.requests.isEmpty, "cancellation must not reach the backup")
      #expect(FileManager.default.fileExists(atPath: stagedFile(staging).path) == false)
      let assembling = ManifestFetchTask.TransportLayout.assemblyURL(
        in: staging, file: manifest.files[0])
      #expect(FileManager.default.fileExists(atPath: assembling.path) == false)
    }
  }

  @Test func aFullDiskDuringAssemblyIsReportedAsInsufficientDisk() async throws {
    // Backup kept and answering 404: a local failure must stay local, with no
    // failover that would replace it with the backup's answer.
    let manifest = try Self.partsManifest(withBackup: true)
    let staging = try makeStaging()
    try await withStubs {
      _ = try stagePart(manifest, staging: staging, index: 0, Data("01234".utf8))
      _ = try stagePart(manifest, staging: staging, index: 1, Data("56789".utf8))
      DeliveryStubProtocol.enqueue(
        url: "\(Self.backupBase)\(Self.partsFile)", .init(status: 404, headers: [:], body: Data()))
      let fetch = partsTask(
        manifest: manifest, staging: staging,
        assemblyWrite: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) })
      do {
        _ = try await fetch.run()
        Issue.record("a full disk completed the fetch")
      } catch let failure as DeliveryFailure {
        #expect(failure.reason == .insufficientDisk)
      }
      #expect(DeliveryStubProtocol.requests.isEmpty)
      #expect(FileManager.default.fileExists(atPath: stagedFile(staging).path) == false)
    }
  }

  @Test func aVerifiedStagedWholeFileSkipsTransportAndAssembly() async throws {
    let manifest = try Self.partsManifest()
    let staging = try makeStaging()
    try await withStubs {
      try Self.partsContent.write(to: stagedFile(staging))
      let outcome = try await partsTask(manifest: manifest, staging: staging).run()
      #expect(outcome.bytesDownloaded == 0)
      #expect(DeliveryStubProtocol.requests.isEmpty)
      #expect(FileManager.default.fileExists(atPath: transportRoot(staging).path) == false)
    }
  }

  // MARK: Controller accounting for parts

  private func partsRegistration(
    _ manifest: DeliveryManifest
  ) throws -> DeliveryRegistration {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("parts-controller-\(UUID().uuidString)", isDirectory: true)
    let install = root.appendingPathComponent("install", isDirectory: true)
    let metadata = root.appendingPathComponent("metadata", isDirectory: true)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    return DeliveryRegistration(
      manifest: manifest, installDirectory: install, metadataDirectory: metadata)
  }

  private func freshDefaults() -> UserDefaults {
    let suite = "test.parts.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  @Test(
    "preflight counts the missing parts plus the whole assembly output",
    arguments: [(Int64(32), true), (Int64(33), false)])
  func preflightCountsPartsAndAssembly(available: Int64, refused: Bool) async throws {
    // 10-byte file, part 1 (5 bytes) already staged: (10 - 5) parts + 10
    // assembly = 15 bytes, x 2.2 headroom = 33. Literal, not derived.
    let manifest = try Self.partsManifest()
    let registration = try partsRegistration(manifest)
    let staging = ModelDeliveryController.stagingDirectoryURL(for: registration)
    try await withStubs {
      _ = try stagePart(manifest, staging: staging, index: 0, Data("01234".utf8))
      // Past preflight, both sources answer 404 at once (no retry backoff).
      DeliveryStubProtocol.enqueue(
        url: "\(Self.mirrorBase)\(Self.partsFile).part-2",
        .init(status: 404, headers: [:], body: Data()))
      DeliveryStubProtocol.enqueue(
        url: "\(Self.backupBase)\(Self.partsFile)", .init(status: 404, headers: [:], body: Data()))
      let controller = ModelDeliveryController(
        defaults: freshDefaults(), availableDiskBytes: { _ in available })
      let outcome = await controller.ensureModelAvailable(registration)
      guard case .failed(let failure) = outcome else {
        Issue.record("expected a failure (no stubs are served), got \(outcome)")
        return
      }
      if refused {
        #expect(failure.reason == .insufficientDisk)
        #expect(failure.detail == "preflight:33")
      } else {
        #expect(failure.reason == .source4xx, "accepted by preflight, then failed on the 404s")
      }
    }
  }

  @Test(arguments: [false, true])
  func theAssemblyReservationOutlivesNetworkProgress(wholeFirst: Bool) async throws {
    // A: 10-byte parts file. When its network bytes reach the total, assembly
    // is still owed: 10 x 2.2 = 22 stays reserved. B: a 20-byte whole file needs
    // 44. Disk 60: B fits only if A's reservation dropped to zero.
    // Parts-first retains assembly space in the disk base.
    // Whole-first with verified parts already staged needs only the assembly
    // output; after failover, logical progress would erase that reservation
    // without the explicit floor. B needs 44 bytes; A must retain 22.
    let manifestA = try Self.partsManifest()
    let regA = try partsRegistration(manifestA)
    let manifestB = try DeliveryManifest.load(
      from: ManifestFixture.manifestJSON(
        files: [("other-model.bin", Data(repeating: 7, count: 20), "other-model.bin")],
        sources: [["id": "our_copy", "baseURL": "https://other.invalid.example/b/"]]
      ) { object in
        var identity = object["identity"] as! [String: Any]
        identity["family"] = "eg_one"
        identity["name"] = "fixture-b"
        object["identity"] = identity
      })
    let regB = try partsRegistration(manifestB)
    try await withStubs {
      let defaults = freshDefaults()
      if wholeFirst {
        defaults.set(
          "backup,our_copy", forKey: DeliveryFlags.key("sourceOrder", family: .parakeet))
        let staging = ModelDeliveryController.stagingDirectoryURL(for: regA)
        _ = try stagePart(manifestA, staging: staging, index: 0, Data("01234".utf8))
        _ = try stagePart(manifestA, staging: staging, index: 1, Data("56789".utf8))
        DeliveryStubProtocol.enqueue(
          url: "\(Self.backupBase)\(Self.partsFile)",
          .init(status: 404, headers: [:], body: Data()))
      } else {
        servePart(1, Data("01234".utf8))
        servePart(2, Data("56789".utf8))
      }
      let controller = ModelDeliveryController(defaults: defaults, availableDiskBytes: { _ in 60 })
      // Hold A inside assembly, after its network bytes landed, until B has
      // preflighted. The gate is the subject's own assembly step.
      let (gate, open) = AsyncStream<Void>.makeStream()
      await controller.setAssemblyWriteForTesting { handle, chunk in
        for await _ in gate { break }
        try handle.write(contentsOf: chunk)
      }
      let (networkDone, signal) = AsyncStream<Void>.makeStream()
      await controller.addStateObserver { identity, state in
        if identity == manifestA.identity, case .downloading(_, let written, let total) = state,
          written == total
        {
          signal.yield(())
        }
      }
      let a = Task { await controller.ensureModelAvailable(regA) }
      let reached = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
          for await _ in networkDone { return true }
          return false
        }
        group.addTask {
          try? await Task.sleep(for: .seconds(5))  // deadline-fallback: bounded signal wait
          return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        signal.finish()
        return result
      }
      guard reached else {
        open.finish()
        _ = await controller.cancel(manifestA.identity)
        _ = await a.value
        Issue.record("A never reported its network bytes complete")
        return
      }
      let b = await controller.ensureModelAvailable(regB)
      open.yield(())
      open.finish()
      let outcomeA = await a.value
      #expect(outcomeA == .admitted, "A finishes its assembly once released")
      guard case .failed(let failure) = b else {
        Issue.record("B got past preflight while A still owed its assembly: \(b)")
        return
      }
      #expect(failure.reason == .insufficientDisk)
      #expect(failure.detail == "preflight:44")
    }
  }
}
