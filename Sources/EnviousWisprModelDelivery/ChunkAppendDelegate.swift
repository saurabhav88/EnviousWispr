import Foundation

/// Streaming download delegate for one manifest file — the generalized copy of
/// EG-1's delegate (#1271 Codex r1 P2 heritage; EG-1's own copy converges here
/// at Phase 3 per the epic plan): receives multi-KB chunks from URLSession's
/// serial delegate queue and appends them synchronously to the partial file —
/// constant memory, no per-byte iteration, and mid-download interruption keeps
/// every appended byte for the next resume.
///
/// Generalizations vs the EG-1 original: byte counts are reported ABSOLUTELY
/// (`onBytesWritten`) so a set-level aggregator can sum across files, and the
/// expected length gate (grounded r1 revision 6) fails a source FAST when a
/// validated response's Content-Length cannot produce the remaining expected
/// bytes — the captive-portal / intercepted-200 signature — instead of
/// streaming hundreds of MB to a guaranteed hash failure.
///
/// `@unchecked Sendable`: all mutable state is touched ONLY on URLSession's
/// serial delegate queue (single-touch by construction) plus the one-shot
/// continuation handoff guarded by `continuation`'s nil-out.
final class ChunkAppendDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  /// Why the delegate deliberately cancelled the task itself (vs a transport
  /// error, which must throw so the partial survives as a resume point).
  enum SelfCancelReason {
    case nonSuccessStatus
    case lengthMismatch(expected: Int64, contentLength: Int64, contentType: String?)
  }

  private let handle: FileHandle
  private let startingBytes: Int64
  private let expectedTotal: Int64
  private let onBytesWritten: @Sendable (Int64) -> Void
  /// Fired once when a 200/206 response is accepted, BEFORE body bytes stream —
  /// the fetcher persists the resume identity here so an interrupted first
  /// download still leaves a resumable pair (EG-1 Codex r2 lesson).
  private let onValidatedResponse: @Sendable (HTTPURLResponse) -> Void

  private var written: Int64
  private var bytesReceived: Int64 = 0
  private var lastReported: Int64
  private var response: HTTPURLResponse?
  private var writeError: Error?
  private var selfCancelReason: SelfCancelReason?
  private var continuation: CheckedContinuation<Outcome, Error>?

  struct Outcome {
    let response: HTTPURLResponse
    let selfCancelReason: SelfCancelReason?
    /// Body bytes actually received THIS run (truncate-aware — a 200 on a
    /// resumed request restarts the count with the restarted body), so the
    /// caller's telemetry byte accounting never undercounts.
    let bytesReceived: Int64
  }

  init(
    handle: FileHandle, startingBytes: Int64, expectedTotal: Int64,
    onBytesWritten: @escaping @Sendable (Int64) -> Void,
    onValidatedResponse: @escaping @Sendable (HTTPURLResponse) -> Void = { _ in }
  ) {
    self.handle = handle
    self.startingBytes = startingBytes
    self.expectedTotal = expectedTotal
    self.onBytesWritten = onBytesWritten
    self.onValidatedResponse = onValidatedResponse
    self.written = startingBytes
    self.lastReported = startingBytes
  }

  func run(request: URLRequest) async throws -> Outcome {
    // delegateQueue nil → URLSession creates its own SERIAL queue. The
    // delegate's single-touch state and in-order FileHandle appends depend on
    // serial delivery (EG-1 Codex r5 P1).
    let session = URLSession(configuration: Self.configuration, delegate: self, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { cont in
        continuation = cont
        session.dataTask(with: request).resume()
      }
    } onCancel: {
      session.invalidateAndCancel()
    }
  }

  /// Constrained/expensive network access is ALLOWED — a deliberate policy
  /// decision (contract §5a / D4 §6), not a default-by-omission: a first-run
  /// user on a hotspot chose to set up now; silently deferring the fetch
  /// strands onboarding, which is the #1339 UX by our own hand.
  static var configuration: URLSessionConfiguration {
    let config = URLSessionConfiguration.default
    config.allowsExpensiveNetworkAccess = true
    config.allowsConstrainedNetworkAccess = true
    if let stubs = protocolClassesForTesting {
      config.protocolClasses = stubs
    }
    return config
  }

  /// Test seam: URLProtocol stubs for the transport-semantics tests
  /// (200-ignores-Range truncate, 416, length-mismatch fast fail). Never set
  /// in production. `nonisolated(unsafe)`: written once before a test's
  /// fetch, read at session construction.
  nonisolated(unsafe) static var protocolClassesForTesting: [AnyClass]?

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      return
    }
    self.response = http
    // Server ignored the Range header (200 on a resumed request): the body is
    // the WHOLE object, so the already-written prefix must go.
    if http.statusCode == 200, startingBytes > 0 {
      do {
        try handle.truncate(atOffset: 0)
        written = 0
        lastReported = 0
      } catch {
        writeError = error
        completionHandler(.cancel)
        return
      }
    }
    // Non-success statuses (416, 5xx) carry no useful body — stop here; the
    // caller maps the recorded status to its failure class.
    if http.statusCode != 200, http.statusCode != 206 {
      selfCancelReason = .nonSuccessStatus
      completionHandler(.cancel)
      return
    }
    // Length gate (grounded r1 revision 6): a validated response whose
    // Content-Length cannot complete the file is a wrong object — captive
    // portal HTML, truncated CDN object — fail this source before streaming.
    let remaining = http.statusCode == 200 ? expectedTotal : expectedTotal - written
    if let lengthHeader = http.value(forHTTPHeaderField: "Content-Length"),
      let contentLength = Int64(lengthHeader), contentLength != remaining
    {
      selfCancelReason = .lengthMismatch(
        expected: remaining, contentLength: contentLength,
        contentType: http.value(forHTTPHeaderField: "Content-Type"))
      completionHandler(.cancel)
      return
    }
    onValidatedResponse(http)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    do {
      try handle.write(contentsOf: data)
      written += Int64(data.count)
      bytesReceived += Int64(data.count)
      // Report every ~16 MB to keep the UI live without churn (EG-1 dial).
      if written - lastReported >= (16 << 20) {
        lastReported = written
        onBytesWritten(written)
      }
    } catch {
      writeError = error
      dataTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    guard let cont = continuation else { return }
    continuation = nil
    if let writeError {
      cont.resume(throwing: writeError)
      return
    }
    // A REAL transport error mid-body must throw — the partial is a valid
    // resume point, and returning "success" here would route it into checksum
    // verification, which deletes it (EG-1 Codex r3). Only OUR deliberate
    // self-cancel returns the response for status/length mapping.
    if let error, selfCancelReason == nil {
      cont.resume(throwing: error)
      return
    }
    if let response {
      onBytesWritten(written)
      cont.resume(
        returning: Outcome(
          response: response, selfCancelReason: selfCancelReason, bytesReceived: bytesReceived))
      return
    }
    cont.resume(throwing: error ?? URLError(.unknown))
  }
}
