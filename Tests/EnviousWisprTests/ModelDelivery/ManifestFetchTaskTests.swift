import Foundation
import Testing

@testable import EnviousWisprModelDelivery

// MARK: - URLProtocol stub (transport-semantics tests)

/// Scripted responses keyed by URL absoluteString. Each entry consumes once
/// (FIFO per URL) so resume/retry sequences can be scripted.
final class DeliveryStubProtocol: URLProtocol {
  struct Stub {
    let status: Int
    let headers: [String: String]
    let body: Data
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

  override func startLoading() {
    Self.lock.lock()
    if let range = request.value(forHTTPHeaderField: "Range") {
      Self.seenRangeHeaders.append(range)
    }
    let key = request.url!.path
    let stub = Self.stubs[key]?.isEmpty == false ? Self.stubs[key]!.removeFirst() : nil
    Self.lock.unlock()
    guard let stub else {
      client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
      return
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
      headerFields: stub.headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !stub.body.isEmpty {
      client?.urlProtocol(self, didLoad: stub.body)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
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
    manifest: DeliveryManifest, staging: URL, components: Set<String>? = nil
  ) -> ManifestFetchTask {
    ManifestFetchTask(
      manifest: manifest, stagingDirectory: staging, sources: manifest.sources,
      componentsToFetch: components ?? Set(manifest.files.map(\.component)),
      verifiedInPlaceBytes: 0, onProgress: { _, _ in }, onSourceFailover: { _ in })
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

  @Test func httpStatusClassification() {
    #expect(ManifestFetchTask.classifyHTTPStatus(429) == .source5xx)  // throttle = retryable-ish
    #expect(ManifestFetchTask.classifyHTTPStatus(500) == .source5xx)
    #expect(ManifestFetchTask.classifyHTTPStatus(503) == .source5xx)
    #expect(ManifestFetchTask.classifyHTTPStatus(404) == .source4xx)
    #expect(ManifestFetchTask.classifyHTTPStatus(416) == .source4xx)
    #expect(ManifestFetchTask.classifyHTTPStatus(301) == .unknown)  // redirects are transport-level
  }
}
