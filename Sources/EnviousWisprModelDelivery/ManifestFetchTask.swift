import EnviousWisprCore
import Foundation

/// One delivery attempt: fetch every file of the manifest's fetch list into
/// staging, per-file resume + ordered source failover, streaming SHA-256 per
/// file BEFORE any promotion (contract invariants 1, 5, 6, 7). Runs as the
/// identity's single active task under the controller's one-writer regime
/// (D4 §2); all state here is task-local.
struct ManifestFetchTask {
  struct Outcome {
    let sourcesUsed: Int
    let finalSourceID: String
    let bytesDownloaded: Int64
  }

  /// Recorded at download start per FILE; a changed remote object invalidates
  /// that file's resume (EG-1 `ResumeIdentity`, per-file generalized).
  struct ResumeIdentity: Codable {
    let etag: String?
    let contentLength: Int64?
  }

  let manifest: DeliveryManifest
  let stagingDirectory: URL
  /// Ordered, flag-filtered sources (controller applies D5 sourceOrder /
  /// mirrorDisabled / backupDisabled before constructing the task).
  let sources: [DeliveryManifest.Source]
  /// Components that must be fetched (validation's failed set on repair; the
  /// full component list on a cold cache).
  let componentsToFetch: Set<String>
  /// Bytes already accounted verified (in-place components) — the progress
  /// denominator baseline so the UI fraction covers the WHOLE set honestly.
  let verifiedInPlaceBytes: Int64
  let onProgress: @Sendable (_ bytesWritten: Int64, _ totalBytes: Int64) -> Void
  let onSourceFailover: @Sendable (DeliveryFailureClass) -> Void

  /// EG-1's shipped transport dials (`EGOneModelStore.swift:398,465`) — idle
  /// transport timeouts with shipped precedent, not new wall-clock deadlines.
  private static let requestTimeout: TimeInterval = 60
  private static let headTimeout: TimeInterval = 30

  func run() async throws -> Outcome {
    let fm = FileManager.default
    try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

    let fetchFiles = manifest.files.filter { componentsToFetch.contains($0.component) }
    var completedBytes = verifiedInPlaceBytes
    var bytesDownloaded: Int64 = 0
    var sourceIndex = 0
    var sourcesUsed = 1
    var sawHTMLInterception = false

    for file in fetchFiles {
      try Task.checkCancellation()
      let stagedURL = stagingDirectory.appendingPathComponent(file.path)
      try fm.createDirectory(
        at: stagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)

      // Already fully staged + verified (resumed attempt): skip.
      if CacheAdmission.sizeMatches(url: stagedURL, expected: file.sizeBytes),
        await CacheAdmission.streamingSHA256(of: stagedURL) == file.sha256
      {
        discardResumeIdentity(at: stagedURL)
        completedBytes += file.sizeBytes
        onProgress(completedBytes, manifest.totalBytes)
        continue
      }

      // Per-file fetch with ordered failover. Failover is STICKY: once a
      // source is abandoned the remainder of the attempt stays on the next
      // source (D3: failover is inside one attempt; sources_used 1|2).
      // LOCAL problems never blame the source: any outcome tainted by
      // pre-existing staged bytes (complete-corrupt fast path, resumed-onto-
      // corrupt-prefix hash fail, 416 on a stale range) gets ONE clean
      // same-source retry after discarding the partial (r6 P2 + exhaustive
      // r7 findings 1/2).
      var fetched = false
      var localRetryUsed = false
      while !fetched {
        let source = sources[sourceIndex]
        do {
          let result = try await fetchOneFile(
            file, from: source, to: stagedURL,
            progressBase: completedBytes)
          bytesDownloaded += result.bytesReceived

          // Hash gate BEFORE this file counts (invariant 1).
          try Task.checkCancellation()
          guard await CacheAdmission.streamingSHA256(of: stagedURL) == file.sha256 else {
            discardPartial(at: stagedURL)
            if result.usedLocalBytes, !localRetryUsed {
              localRetryUsed = true
              continue
            }
            throw DeliveryFailure(
              reason: .integrityMismatch, detail: "sha256:\(file.component)",
              failingSourceID: source.id)
          }
          fetched = true
          // The resume identity's job ends when the file verifies — clearing
          // it here keeps sidecars out of the promoted cache (the manifest
          // stays the exhaustive truth for the install dir).
          discardResumeIdentity(at: stagedURL)
          completedBytes += file.sizeBytes
          onProgress(completedBytes, manifest.totalBytes)
        } catch let failure as DeliveryFailure where failure.reason != .cancelled {
          if failure.detail == "http_416_local", !localRetryUsed {
            // Stale-range 416: the partial is already discarded; one clean
            // same-source retry from byte zero (exhaustive r7 finding 2).
            localRetryUsed = true
            continue
          }
          if failure.detail?.hasPrefix("length_mismatch_html") == true {
            sawHTMLInterception = true
          }
          guard sourceIndex + 1 < sources.count else {
            // All sources exhausted: terminal. The captive-portal signature
            // (both sources length/hash-failed with HTML observed) gets the
            // intercepted_network detail hint (grounded r1 revision 6).
            if failure.reason == .integrityMismatch, sawHTMLInterception {
              throw DeliveryFailure(
                reason: .integrityMismatch, detail: "intercepted_network",
                failingSourceID: failure.failingSourceID)
            }
            throw failure
          }
          sourceIndex += 1
          sourcesUsed = 2
          onSourceFailover(failure.reason)
        }
      }
    }

    return Outcome(
      sourcesUsed: sourcesUsed,
      finalSourceID: sources[sourceIndex].id,
      bytesDownloaded: bytesDownloaded)
  }

  // MARK: - One file

  /// What one file-fetch did — the caller's self-heal policy needs to know
  /// whether LOCAL bytes participated (exhaustive r7 findings 1/2: a hash
  /// mismatch on a run that consumed a local partial is retried on the SAME
  /// source after discarding, never blamed on the source first).
  struct FileFetchResult {
    let bytesReceived: Int64
    /// True when pre-existing staged bytes fed the verify (complete-partial
    /// fast path or a ranged resume).
    let usedLocalBytes: Bool
  }

  private func fetchOneFile(
    _ file: DeliveryManifest.File, from source: DeliveryManifest.Source, to stagedURL: URL,
    progressBase: Int64
  ) async throws -> FileFetchResult {
    let fm = FileManager.default
    let fileURL = source.baseURL.appendingPathComponent(file.path)
    let identityURL = resumeIdentityURL(for: file)
    var existingBytes =
      ((try? fm.attributesOfItem(atPath: stagedURL.path)[.size] as? Int64) ?? nil) ?? 0

    // A COMPLETE partial goes straight back to the caller's verify — a
    // `bytes=<size>-` request answers 416 and would strand retries (EG-1
    // Codex r1 P2; the checksum is the authority for a complete file).
    if existingBytes == file.sizeBytes {
      return FileFetchResult(bytesReceived: 0, usedLocalBytes: true)
    }

    // Validate resume identity: if the remote object changed under the URL,
    // the partial is garbage — discard and restart (EG-1 semantics).
    if existingBytes > 0 {
      let head = try await headIdentity(url: fileURL, sourceID: source.id)
      let recorded = try? JSONDecoder().decode(
        ResumeIdentity.self, from: Data(contentsOf: identityURL))
      if shouldDiscardPartial(
        recordedETag: recorded?.etag, recordedLength: recorded?.contentLength,
        headETag: head.etag, headLength: head.contentLength,
        existingBytes: existingBytes, expectedSize: file.sizeBytes)
      {
        discardPartial(at: stagedURL)
        existingBytes = 0
      }
    }

    var request = URLRequest(url: fileURL)
    if existingBytes > 0 {
      request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
    }
    request.timeoutInterval = Self.requestTimeout

    if !fm.fileExists(atPath: stagedURL.path) {
      fm.createFile(atPath: stagedURL.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: stagedURL)
    defer { try? handle.close() }
    try handle.seekToEnd()

    let expectedSize = file.sizeBytes
    let onProgressCallback = onProgress
    let totalBytes = manifest.totalBytes
    let delegate = ChunkAppendDelegate(
      handle: handle, startingBytes: existingBytes, expectedTotal: expectedSize,
      onBytesWritten: { written in
        onProgressCallback(progressBase + written, totalBytes)
      },
      onValidatedResponse: { http in
        // Persist the resume identity AS SOON AS HEADERS ARRIVE, before any
        // body byte streams (EG-1 Codex r2): an interrupted FIRST download
        // must leave a resumable pair.
        let identity = ResumeIdentity(
          etag: http.value(forHTTPHeaderField: "ETag"), contentLength: expectedSize)
        try? JSONEncoder().encode(identity).write(to: identityURL)
      })

    let outcome: ChunkAppendDelegate.Outcome
    do {
      outcome = try await delegate.run(request: request)
    } catch let urlError as URLError where urlError.code == .cancelled {
      // Session teardown from cooperative cancel surfaces as URLError.cancelled
      // (EG-1 Codex r4) — never a network failure.
      throw DeliveryFailure(reason: .cancelled, failingSourceID: source.id)
    } catch is CancellationError {
      throw DeliveryFailure(reason: .cancelled, failingSourceID: source.id)
    } catch {
      throw Self.classifyTransportError(error, sourceID: source.id)
    }

    switch outcome.selfCancelReason {
    case .none:
      break
    case .lengthMismatch(_, _, let contentType):
      let html = contentType?.contains("text/html") == true
      throw DeliveryFailure(
        reason: .integrityMismatch,
        detail: html ? "length_mismatch_html" : "length_mismatch",
        failingSourceID: source.id)
    case .nonSuccessStatus:
      let status = outcome.response.statusCode
      if status == 416 {
        // A 416 on a ranged resume is healed by discarding the partial and
        // retrying the SAME source from byte zero (exhaustive r7 finding 2)
        // — the caller's local-retry policy handles it via usedLocalBytes;
        // discard here so the retry starts clean (EG-1 seam review).
        discardPartial(at: stagedURL)
        throw DeliveryFailure(
          reason: .source4xx, detail: "http_416_local", failingSourceID: source.id)
      }
      throw DeliveryFailure(
        reason: Self.classifyHTTPStatus(status), detail: "http_\(status)",
        failingSourceID: source.id)
    }

    return FileFetchResult(bytesReceived: outcome.bytesReceived, usedLocalBytes: existingBytes > 0)
  }

  // MARK: - Helpers

  private func resumeIdentityURL(for file: DeliveryManifest.File) -> URL {
    stagingDirectory.appendingPathComponent(file.path + ".resume.json")
  }

  private func discardPartial(at stagedURL: URL) {
    try? FileManager.default.removeItem(at: stagedURL)
    discardResumeIdentity(at: stagedURL)
  }

  private func discardResumeIdentity(at stagedURL: URL) {
    try? FileManager.default.removeItem(
      at: URL(fileURLWithPath: stagedURL.path + ".resume.json"))
  }

  /// Pure resume-validity decision — EG-1's `shouldDiscardPartial` verbatim
  /// (internal for tests): discard when no identity was recorded, the remote
  /// identity changed, or the partial is impossibly large.
  func shouldDiscardPartial(
    recordedETag: String??, recordedLength: Int64??,
    headETag: String?, headLength: Int64?,
    existingBytes: Int64, expectedSize: Int64
  ) -> Bool {
    guard let etag = recordedETag, let length = recordedLength else { return true }
    if etag != headETag || length != headLength { return true }
    return existingBytes > expectedSize
  }

  private func headIdentity(url: URL, sourceID: String) async throws -> (
    etag: String?, contentLength: Int64?
  ) {
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.timeoutInterval = Self.headTimeout
    let (_, response): (Data, URLResponse)
    do {
      // Same configuration as the body fetches: constrained-network
      // allowance applies to the HEAD too, and tests stub one seam.
      let session = URLSession(configuration: ChunkAppendDelegate.configuration)
      defer { session.finishTasksAndInvalidate() }
      (_, response) = try await session.data(for: request)
    } catch {
      throw Self.classifyTransportError(error, sourceID: sourceID)
    }
    guard let http = response as? HTTPURLResponse else {
      throw DeliveryFailure(
        reason: .sourceUnreachable, detail: "head_no_http", failingSourceID: sourceID)
    }
    // A non-success HEAD carries an error page's headers, NOT the artifact's
    // identity — treating it as identity deletes a resumable partial (EG-1
    // Codex r15). Throw instead: the partial survives, retry re-validates.
    guard (200...299).contains(http.statusCode) else {
      throw DeliveryFailure(
        reason: Self.classifyHTTPStatus(http.statusCode), detail: "head_\(http.statusCode)",
        failingSourceID: sourceID)
    }
    let length = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
    return (http.value(forHTTPHeaderField: "ETag"), length)
  }

  /// D3 §1 mapping duties, exhaustively unit-tested (adversarial table per
  /// matcher-set rule).
  static func classifyTransportError(_ error: Error, sourceID: String?) -> DeliveryFailure {
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
      switch URLError.Code(rawValue: ns.code) {
      case .timedOut:
        return DeliveryFailure(
          reason: .sourceTimeout, detail: "urlerror_\(ns.code)", failingSourceID: sourceID)
      case .cancelled:
        return DeliveryFailure(reason: .cancelled, failingSourceID: sourceID)
      default:
        return DeliveryFailure(
          reason: .sourceUnreachable, detail: "urlerror_\(ns.code)", failingSourceID: sourceID)
      }
    }
    if Self.isDiskWriteError(ns) {
      return DeliveryFailure(
        reason: .insufficientDisk, detail: "write_\(ns.code)", failingSourceID: sourceID)
    }
    if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError {
      return DeliveryFailure(
        reason: .permissionDenied, detail: "write_perm", failingSourceID: sourceID)
    }
    return DeliveryFailure(
      reason: .unknown, detail: "\(ns.domain)_\(ns.code)", failingSourceID: sourceID)
  }

  static func classifyHTTPStatus(_ status: Int) -> DeliveryFailureClass {
    switch status {
    case 429, 500...599: return .source5xx
    case 400...499: return .source4xx
    default: return .unknown
    }
  }

  /// Cocoa file-WRITE family + POSIX out-of-space/quota — "your disk, not
  /// your network" (EG-1's shipped classifier).
  static func isDiskWriteError(_ ns: NSError) -> Bool {
    if ns.domain == NSCocoaErrorDomain {
      // NSFileWriteNoPermissionError is carved out above as permission_denied.
      return ns.code == NSFileWriteOutOfSpaceError || ns.code == NSFileWriteVolumeReadOnlyError
        || ns.code == NSFileWriteUnknownError
    }
    if ns.domain == NSPOSIXErrorDomain {
      return ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT)
    }
    return false
  }
}
