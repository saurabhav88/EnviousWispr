import CryptoKit
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
  /// AWAITED, not fire-and-forget (#2135 cloud review P2). Emitting this from
  /// an unstructured `Task` leaves it unordered against the continuation the
  /// controller is awaiting here, so a fast backup or a cancel could publish a
  /// TERMINAL event first — and a cancel that bumps the generation first makes
  /// the controller's own guard drop the failover entirely. Awaiting makes the
  /// notification part of the fetch path, which is where it already belonged:
  /// this is the slow branch by construction, since it runs only when a mirror
  /// has already failed and another is about to be tried.
  let onSourceFailover:
    @Sendable (_ reason: DeliveryFailureClass, _ fromSourceID: String, _ toSourceID: String)
      async -> Void

  /// Phase 2 (#1405): the inter-attempt backoff sleep, injectable so tests
  /// advance it without wall-clock waits (`swift-patterns` timing-seam-shapes;
  /// `swift-testing-patterns` signal-based-test-waits). Throwing + cancellable —
  /// a cancel landing here unwinds as `.cancelled`, never a retry/failover.
  /// `var` (not `let`) so the synthesized memberwise init exposes it as a
  /// defaulted parameter for injection; never mutated after construction.
  var backoffSleep: @Sendable (_ seconds: TimeInterval) async throws -> Void = { seconds in
    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
  }
  /// Phase 2 (#1405): full-jitter fraction in [0, 1]; injectable for
  /// deterministic backoff-bound tests. `var` for the same memberwise-init
  /// reason as `backoffSleep`.
  var jitterFraction: @Sendable () -> Double = { Double.random(in: 0...1) }
  /// #3546: the assembly write, injectable so tests can produce a disk-full
  /// error or a cancellation at the real assembly step. `var` for the same
  /// memberwise-init reason as `backoffSleep`.
  var assemblyWrite: @Sendable (_ handle: FileHandle, _ chunk: Data) async throws -> Void = {
    try $0.write(contentsOf: $1)
  }

  /// EG-1's shipped transport dials (`EGOneModelStore.swift:398,465`) — idle
  /// transport timeouts with shipped precedent, not new wall-clock deadlines.
  private static let requestTimeout: TimeInterval = 60
  private static let headTimeout: TimeInterval = 30

  // MARK: - Phase 2 (#1405) same-source retry dials

  /// Industry consensus (`download-resilience-standards.md` §1, HF-Hub-analog):
  /// N=4 attempts per source = 1 initial + `maxNetworkRetries`.
  private static let maxNetworkRetries = 3
  private static let backoffBaseSeconds: TimeInterval = 1
  private static let backoffCapSeconds: TimeInterval = 8
  /// Honor `Retry-After` only up to a bounded cap; a longer server-directed
  /// delay fails over to backup rather than parking the download on a broken or
  /// hostile server. (Transfer-stall itself is owned by the request idle
  /// timeout `requestTimeout`, not this cap — #1405.)
  private static let retryAfterCapSeconds: TimeInterval = 10

  /// Full-jitter exponential backoff: `random(0, min(cap, base·2^attempt))`.
  static func backoffDelay(attempt: Int, jitter: Double) -> TimeInterval {
    let window = min(backoffCapSeconds, backoffBaseSeconds * pow(2, Double(attempt)))
    return jitter * window
  }

  /// URLError codes that are transient-unreachable and worth a same-source
  /// retry — connection lost / cannot-connect / cannot-find-host / DNS. NOT
  /// `.notConnectedToInternet` (-1009, genuinely offline: retry is futile).
  private static let transientUnreachableCodes: Set<Int> = [
    URLError.Code.networkConnectionLost.rawValue,
    URLError.Code.cannotConnectToHost.rawValue,
    URLError.Code.cannotFindHost.rawValue,
    URLError.Code.dnsLookupFailed.rawValue,
  ]

  /// Parse a `Retry-After` header (RFC 9110 §10.2.3): delay-seconds integer or
  /// an HTTP-date. Returns seconds-to-wait (≥ 0), or nil if absent/unparseable.
  static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
    guard
      let raw = response.value(forHTTPHeaderField: "Retry-After")?
        .trimmingCharacters(in: .whitespaces), !raw.isEmpty
    else { return nil }
    if let seconds = TimeInterval(raw) { return max(0, seconds) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    if let date = formatter.date(from: raw) { return max(0, date.timeIntervalSinceNow) }
    return nil
  }

  /// Build a non-success-HTTP `DeliveryFailure`, stamping retryability +
  /// `Retry-After` in one place for BOTH the GET and HEAD non-success sites
  /// (#1405 Codex r1/r2). 429/5xx are transient-retryable; 4xx are not.
  static func httpStatusFailure(
    status: Int, detail: String, response: HTTPURLResponse, sourceID: String?
  ) -> DeliveryFailure {
    let cls = classifyHTTPStatus(status)
    let retryable = cls == .source5xx
    return DeliveryFailure(
      reason: cls, detail: detail, failingSourceID: sourceID,
      retryableTransient: retryable,
      retryAfter: retryable ? retryAfterSeconds(from: response) : nil)
  }

  /// State one attempt carries ACROSS files: the progress numerator, the
  /// downloaded-bytes counter, and the sticky failover position (D3).
  private struct AttemptState {
    var completedBytes: Int64
    var bytesDownloaded: Int64 = 0
    var sourceIndex = 0
    var sourcesUsed = 1
    var sawHTMLInterception = false
  }

  func run() async throws -> Outcome {
    let fm = FileManager.default
    try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

    let fetchFiles = manifest.files.filter { componentsToFetch.contains($0.component) }
    // #3546: the §4d transport root must never be a component, or promotion
    // could carry parts into the install directory. Bundled manifests cannot
    // collide today; refuse rather than assume.
    // Compared case-insensitively: on the default Mac volume `.EW-TRANSPORT`
    // IS the transport directory.
    guard
      !(manifest.files + manifest.optionalFiles).contains(where: {
        $0.component.lowercased() == TransportLayout.rootName
      })
    else {
      throw DeliveryFailure(reason: .cacheRepairFailed, detail: "transport_root_collision")
    }
    var state = AttemptState(completedBytes: verifiedInPlaceBytes)

    for file in fetchFiles {
      try Task.checkCancellation()
      // Stage under the RESOLVED INSTALL path (contract §4b), not the fetch
      // path, so staging↔promotion stay symmetric when the two names differ.
      let stagedURL = stagingDirectory.appendingPathComponent(file.resolvedInstallPath)
      try fm.createDirectory(
        at: stagedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try await fetchVerified(file, to: stagedURL, state: &state)
    }

    // #3546: every file verified, so nothing in the transport area is needed.
    // Transport residue must be removed before promotion; a cleanup failure
    // ends the attempt without admission.
    try removeTransportItem(at: TransportLayout.root(in: stagingDirectory))

    return Outcome(
      sourcesUsed: state.sourcesUsed,
      finalSourceID: sources[state.sourceIndex].id,
      bytesDownloaded: state.bytesDownloaded)
  }

  /// One file to a verified staged copy: skip when already staged and
  /// verified, else fetch with local/network retry and ordered failover,
  /// hash-gating before the file counts (invariant 1).
  private func fetchVerified(
    _ file: DeliveryManifest.File, to stagedURL: URL, state: inout AttemptState
  ) async throws {
    // Already fully staged + verified (resumed attempt): skip.
    if CacheAdmission.sizeMatches(url: stagedURL, expected: file.sizeBytes),
      await CacheAdmission.streamingSHA256(of: stagedURL) == file.sha256
    {
      discardResumeIdentity(at: stagedURL)
      state.completedBytes += file.sizeBytes
      onProgress(state.completedBytes, manifest.totalBytes)
      return
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
    // Phase 2 (#1405): per-file network-retry budget, independent of the
    // local-byte retry above (a 416-local retry never consumes it).
    var networkRetriesUsed = 0
    while !fetched {
      let source = sources[state.sourceIndex]
      do {
        if source.deliversParts(of: file), let parts = file.parts {
          // Contract §4d: this source serves the file as verified parts that
          // are assembled into the staged install file; local-byte retries
          // are per part inside, and any failure that blames the source
          // lands in the shared catch below (retry, then whole-file failover).
          try await fetchParts(
            file, parts, from: source, assembleInto: stagedURL,
            progressBase: state.completedBytes, bytesDownloaded: &state.bytesDownloaded)
        } else {
          let result = try await fetchOneFile(
            locator: file.path, sizeBytes: file.sizeBytes, from: source, to: stagedURL,
            progressBase: state.completedBytes)
          // Accepted P3 (code-diff review): on the transient-retry-then-resume
          // path a FAILED attempt's partial bytes are staged but not added here
          // (only the successful tail's `bytesReceived` counts), so
          // `attemptCompleted(bytesDownloadedBucket:)` can under-count on a
          // mid-file recovery. This is coarse telemetry only (4 buckets spanning
          // 50MB–600MB+); a lost mid-file partial almost never crosses a bucket
          // boundary on the ~470MB model, and it never affects the download
          // itself. Not worth per-attempt byte plumbing on the hot fetch path.
          state.bytesDownloaded += result.bytesReceived

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
        }
        fetched = true
        // The resume identity's job ends when the file verifies — clearing
        // it here keeps sidecars out of the promoted cache (the manifest
        // stays the exhaustive truth for the install dir).
        discardResumeIdentity(at: stagedURL)
        state.completedBytes += file.sizeBytes
        onProgress(state.completedBytes, manifest.totalBytes)
      } catch let failure as DeliveryFailure where failure.reason != .cancelled {
        // #3546: a LOCAL failure (disk full, no permission, staging that cannot
        // be kept clean) is not the source's fault and another source cannot
        // fix it; failing over would only replace the true reason with the
        // backup's answer.
        switch failure.reason {
        case .insufficientDisk, .permissionDenied, .cacheRepairFailed:
          throw failure
        default:
          break
        }
        if failure.detail == "http_416_local", !localRetryUsed {
          // Stale-range 416: the partial is already discarded; one clean
          // same-source retry from byte zero (exhaustive r7 finding 2).
          localRetryUsed = true
          continue
        }
        if failure.detail?.hasPrefix("length_mismatch_html") == true {
          state.sawHTMLInterception = true
        }
        // Phase 2 (#1405): bounded same-source retry for transient network/
        // HTTP failures BEFORE advancing the source — keep the staged partial
        // so `fetchOneFile` resumes via Range (same source ⇒ same ETag ⇒
        // valid). Honor `Retry-After` up to a bounded cap so a broken/hostile
        // server-directed delay cannot park the download indefinitely; a
        // longer delay falls through to failover instead.
        let retryAfterTooLong = (failure.retryAfter ?? 0) > Self.retryAfterCapSeconds
        if failure.retryableTransient, networkRetriesUsed < Self.maxNetworkRetries,
          !retryAfterTooLong
        {
          let delay =
            failure.retryAfter
            ?? Self.backoffDelay(attempt: networkRetriesUsed, jitter: jitterFraction())
          networkRetriesUsed += 1
          do {
            try await backoffSleep(delay)
          } catch is CancellationError {
            // A cancel during backoff unwinds as .cancelled — never a retry
            // or failover (cooperative cancel, invariant 5).
            throw DeliveryFailure(reason: .cancelled, failingSourceID: source.id)
          }
          continue
        }
        guard state.sourceIndex + 1 < sources.count else {
          // All sources exhausted: terminal. The captive-portal signature
          // (both sources length/hash-failed with HTML observed) gets the
          // intercepted_network detail hint (grounded r1 revision 6).
          if failure.reason == .integrityMismatch, state.sawHTMLInterception {
            throw DeliveryFailure(
              reason: .integrityMismatch, detail: "intercepted_network",
              failingSourceID: failure.failingSourceID)
          }
          throw failure
        }
        let fromSourceID = sources[state.sourceIndex].id
        state.sourceIndex += 1
        state.sourcesUsed = 2
        // Retry budget is PER SOURCE (#1405 §6): the backup gets its own N
        // transient retries, so reset the counter on failover (Codex r1 P2).
        networkRetriesUsed = 0
        // In bounds: the guard above returns unless `sourceIndex + 1` is a
        // valid index, so reading AFTER the increment is safe (#2135).
        await onSourceFailover(failure.reason, fromSourceID, sources[state.sourceIndex].id)
      }
    }
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

  /// One transport object (a whole file, or one §4d part) from `locator` on
  /// `source` into `stagedURL`, resuming any partial there.
  private func fetchOneFile(
    locator: String, sizeBytes: Int64, from source: DeliveryManifest.Source, to stagedURL: URL,
    progressBase: Int64, transportObject: Bool = false
  ) async throws -> FileFetchResult {
    let fm = FileManager.default
    let fileURL = source.baseURL.appendingPathComponent(locator)
    let identityURL = resumeIdentityURL(for: stagedURL)
    if transportObject {
      try checkTransportDestination(stagedURL)
      try checkTransportDestination(identityURL)
    }
    var existingBytes =
      ((try? fm.attributesOfItem(atPath: stagedURL.path)[.size] as? Int64) ?? nil) ?? 0

    // A COMPLETE partial goes straight back to the caller's verify — a
    // `bytes=<size>-` request answers 416 and would strand retries (EG-1
    // Codex r1 P2; the checksum is the authority for a complete file).
    if existingBytes == sizeBytes {
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
        existingBytes: existingBytes, expectedSize: sizeBytes)
      {
        discardPartial(at: stagedURL)
        existingBytes = 0
      }
    }

    // Re-checked after the awaited HEAD: the transport area may have changed.
    if transportObject {
      try checkTransportDestination(stagedURL)
      try checkTransportDestination(identityURL)
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

    let expectedSize = sizeBytes
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
      throw Self.httpStatusFailure(
        status: status, detail: "http_\(status)", response: outcome.response,
        sourceID: source.id)
    }

    return FileFetchResult(bytesReceived: outcome.bytesReceived, usedLocalBytes: existingBytes > 0)
  }

  // MARK: - Parts (contract §4d)

  /// Fetches every part of `file` from a parts-serving `source` into the
  /// transport area, verifying each before it counts, then assembles them into
  /// `stagedURL`. Progress is reported in the file's logical bytes, so parts and
  /// the assembled output are never counted twice.
  private func fetchParts(
    _ file: DeliveryManifest.File, _ parts: [DeliveryManifest.Part],
    from source: DeliveryManifest.Source, assembleInto stagedURL: URL,
    progressBase: Int64, bytesDownloaded: inout Int64
  ) async throws {
    // A whole-file partial from an earlier source would sit on disk beside the
    // parts and the assembly output for the whole transfer, beyond what the
    // preflight budgets; the parts path never resumes it, so it goes first.
    discardPartial(at: stagedURL)
    let transportRoot = TransportLayout.root(in: stagingDirectory)
    try checkTransportDestination(transportRoot)
    try FileManager.default.createDirectory(at: transportRoot, withIntermediateDirectories: true)
    try checkTransportDestination(transportRoot)
    var partBase = progressBase
    for (index, part) in parts.enumerated() {
      try Task.checkCancellation()
      let partURL = TransportLayout.partURL(in: stagingDirectory, file: file, index: index)
      try checkTransportDestination(partURL)
      try checkTransportDestination(resumeIdentityURL(for: partURL))
      var localRetryUsed = false
      // Each part gets the ordinary per-object network budget (contract §4d);
      // one part's transient trouble never spends another part's retries.
      var networkRetriesUsed = 0
      var verified = await Self.isVerified(
        partURL, sizeBytes: part.sizeBytes, sha256: part.sha256)
      while !verified {
        let result: FileFetchResult
        do {
          result = try await fetchOneFile(
            locator: part.path, sizeBytes: part.sizeBytes, from: source, to: partURL,
            progressBase: partBase, transportObject: true)
        } catch let failure as DeliveryFailure
          where failure.detail == "http_416_local" && !localRetryUsed
        {
          // Same stale-range rule as a whole file: one clean retry from zero.
          localRetryUsed = true
          continue
        } catch let failure as DeliveryFailure
          where failure.reason != .cancelled && failure.retryableTransient
        {
          let retryAfterTooLong = (failure.retryAfter ?? 0) > Self.retryAfterCapSeconds
          guard networkRetriesUsed < Self.maxNetworkRetries, !retryAfterTooLong else {
            // This part's budget is spent: abandon the source. Rethrown as
            // non-transient so the file-level loop fails over instead of
            // retrying the same source a second time.
            throw DeliveryFailure(
              reason: failure.reason, detail: failure.detail,
              failingSourceID: failure.failingSourceID)
          }
          let delay =
            failure.retryAfter
            ?? Self.backoffDelay(attempt: networkRetriesUsed, jitter: jitterFraction())
          networkRetriesUsed += 1
          do {
            try await backoffSleep(delay)
          } catch is CancellationError {
            throw DeliveryFailure(reason: .cancelled, failingSourceID: source.id)
          }
          continue
        }
        bytesDownloaded += result.bytesReceived
        try Task.checkCancellation()
        if await CacheAdmission.streamingSHA256(of: partURL) != part.sha256 {
          discardPartial(at: partURL)
          if result.usedLocalBytes, !localRetryUsed {
            localRetryUsed = true
            continue
          }
          throw DeliveryFailure(
            reason: .integrityMismatch, detail: "sha256:\(file.component):part\(index + 1)",
            failingSourceID: source.id)
        }
        verified = true
      }
      discardResumeIdentity(at: partURL)
      partBase += part.sizeBytes
      onProgress(partBase, manifest.totalBytes)
    }
    try await assemble(file, parts, into: stagedURL, sourceID: source.id)
  }

  /// Concatenates verified parts, in declared order, into a freshly truncated
  /// temporary output; only an output of the exact size and whole-file SHA-256
  /// replaces the staged install file. An interrupted assembly therefore never
  /// leaves a suffix behind: the next attempt truncates and starts at byte zero,
  /// reusing the parts that already verified.
  private func assemble(
    _ file: DeliveryManifest.File, _ parts: [DeliveryManifest.Part], into stagedURL: URL,
    sourceID: String
  ) async throws {
    let fm = FileManager.default
    let output = TransportLayout.assemblyURL(in: stagingDirectory, file: file)
    do {
      try checkTransportDestination(output)
      try removeTransportItem(at: output)
      // `write` (not `createFile`) so a quota or permission failure keeps its
      // real error for classification.
      try Data().write(to: output)
      let writer = try FileHandle(forWritingTo: output)
      defer { try? writer.close() }
      for index in parts.indices {
        let reader = try FileHandle(
          forReadingFrom: TransportLayout.partURL(in: stagingDirectory, file: file, index: index))
        defer { try? reader.close() }
        while true {
          try Task.checkCancellation()
          guard let chunk = try reader.read(upToCount: Self.assemblyChunkBytes), !chunk.isEmpty
          else { break }
          try await assemblyWrite(writer, chunk)
        }
      }
    } catch is CancellationError {
      try? fm.removeItem(at: output)
      throw DeliveryFailure(reason: .cancelled, failingSourceID: sourceID)
    } catch let failure as DeliveryFailure {
      try? fm.removeItem(at: output)
      throw failure
    } catch {
      try? fm.removeItem(at: output)
      throw Self.classifyTransportError(error, sourceID: sourceID)
    }
    guard await Self.isVerified(output, sizeBytes: file.sizeBytes, sha256: file.sha256) else {
      // Every part verified yet the whole does not: none of these bytes can be
      // trusted together, so the output, the parts and their sidecars all go.
      try removeTransportItem(at: output)
      for index in parts.indices {
        let partURL = TransportLayout.partURL(in: stagingDirectory, file: file, index: index)
        try removeTransportItem(at: partURL)
        try removeTransportItem(at: resumeIdentityURL(for: partURL))
      }
      throw DeliveryFailure(
        reason: .integrityMismatch, detail: "sha256:\(file.component):assembled",
        failingSourceID: sourceID)
    }
    do {
      discardPartial(at: stagedURL)
      try fm.moveItem(at: output, to: stagedURL)
    } catch {
      try? fm.removeItem(at: output)
      throw Self.classifyTransportError(error, sourceID: sourceID)
    }
    for index in parts.indices {
      discardPartial(at: TransportLayout.partURL(in: stagingDirectory, file: file, index: index))
    }
  }

  private static func isVerified(_ url: URL, sizeBytes: Int64, sha256: String) async -> Bool {
    guard CacheAdmission.sizeMatches(url: url, expected: sizeBytes) else { return false }
    return await CacheAdmission.streamingSHA256(of: url) == sha256
  }

  /// Copy granularity for assembly: bounded memory, with a cancellation check
  /// between chunks.
  static let assemblyChunkBytes = 4 * 1024 * 1024

  /// Contract §4d transport layout: the ONE authority for where a file's parts,
  /// their resume sidecars and its assembly output live, read by the fetcher
  /// and by the controller's disk accounting. Everything sits under one root
  /// that is never a manifest component; promotion moves component roots only,
  /// so transport bytes can never reach the install directory.
  enum TransportLayout {
    static let rootName = ".ew-transport"

    static func root(in staging: URL) -> URL {
      staging.appendingPathComponent(rootName, isDirectory: true)
    }

    /// Keyed by a digest of the file's resolved install path (unique per
    /// manifest, contract §4b) plus the part index, so no two parts of any
    /// files can share a name.
    static func partURL(in staging: URL, file: DeliveryManifest.File, index: Int) -> URL {
      root(in: staging).appendingPathComponent("\(key(file)).part\(index + 1)")
    }

    static func assemblyURL(in staging: URL, file: DeliveryManifest.File) -> URL {
      root(in: staging).appendingPathComponent("\(key(file)).assembling")
    }

    private static func key(_ file: DeliveryManifest.File) -> String {
      SHA256.hash(data: Data(file.resolvedInstallPath.utf8)).map { String(format: "%02x", $0) }
        .joined()
    }
  }

  /// Disk accounting for one file across every source this attempt may use
  /// (contract §4d), read by the controller's preflight. `logicalStaged` is what
  /// progress will report as already present on the FIRST source's path;
  /// `diskNeeded` is the worst case over the representations the permitted
  /// sources can serve (a parts source needs the remaining parts PLUS a whole
  /// assembly output; a whole-file source needs only the remaining file);
  /// `assemblyFloor` is the assembly output a parts-capable file can still
  /// allocate after its network bytes land.
  ///
  /// Whole-file-only sources retain their existing size-based accounting.
  /// For a parts-capable file, full-size staging skips allocation only after
  /// its whole-file hash verifies; corrupt staging still needs a parts budget.
  static func stagedAccounting(
    of file: DeliveryManifest.File, sources: [DeliveryManifest.Source], in staging: URL
  ) async -> (logicalStaged: Int64, diskNeeded: Int64, assemblyFloor: Int64) {
    // Staged files live under the resolved install path (contract §4b).
    let wholeURL = staging.appendingPathComponent(file.resolvedInstallPath)
    let whole = min(stagedSize(wholeURL), file.sizeBytes)
    guard let parts = file.parts, sources.contains(where: { $0.deliversParts(of: file) }) else {
      return (whole, file.sizeBytes - whole, 0)
    }
    if whole == file.sizeBytes,
      await isVerified(wholeURL, sizeBytes: file.sizeBytes, sha256: file.sha256)
    {
      return (whole, 0, 0)
    }
    let wholeStaged = whole == file.sizeBytes ? 0 : whole
    let wholeNeed = file.sizeBytes - wholeStaged
    let partStaged = parts.indices.reduce(Int64(0)) { sum, index in
      sum
        + min(
          stagedSize(TransportLayout.partURL(in: staging, file: file, index: index)),
          parts[index].sizeBytes)
    }
    let partsNeed = (file.sizeBytes - partStaged) + file.sizeBytes
    let startsWithParts = sources.first?.deliversParts(of: file) == true
    return (
      startsWithParts ? partStaged : wholeStaged, max(wholeNeed, partsNeed), file.sizeBytes
    )
  }

  private static func stagedSize(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil) ?? 0
  }

  // MARK: - Helpers

  /// The transport area must resolve inside this attempt's staging directory
  /// (the controller already proved staging itself safe): a symlink planted at
  /// `.ew-transport` must not redirect part writes or cleanup deletes.
  /// Every transport write and delete destination passes through here: the
  /// root, each part, each part's resume sidecar and the assembly output. An
  /// item that exists must resolve (a dangling symlink is refused, because
  /// `fileExists` would call it absent and a write would follow it), and it
  /// must resolve inside staging.
  private func checkTransportDestination(_ url: URL) throws {
    switch PathSafety.reachability(of: url) {
    case .absent?:
      break
    case nil:
      guard PathSafety.resolvedPath(url) != nil else {
        throw DeliveryFailure(reason: .cacheRepairFailed, detail: "unsafe_transport")
      }
    case .unreadable?, .indeterminate?:
      throw DeliveryFailure(reason: .cacheRepairFailed, detail: "unsafe_transport")
    }
    guard PathSafety.resolvesInside(url, root: stagingDirectory) else {
      throw DeliveryFailure(reason: .cacheRepairFailed, detail: "unsafe_transport")
    }
  }

  /// Removes a transport-area item; an item that is already gone is not a
  /// failure, any other error is (contract §4d: residue never reaches promotion).
  private func removeTransportItem(at url: URL) throws {
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      let ns = error as NSError
      if ns.domain == NSCocoaErrorDomain,
        ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError
      {
        return
      }
      throw DeliveryFailure(
        reason: .cacheRepairFailed, detail: "transport_cleanup:\(url.lastPathComponent)")
    }
  }

  private func resumeIdentityURL(for stagedURL: URL) -> URL {
    // Key the resume sidecar off the resolved install path so it sits beside
    // the staged file (which stages under resolvedInstallPath, contract §4b).
    // `discardResumeIdentity(at: stagedURL)` below is already stagedURL-relative
    // and needs no change.
    // #3546: keyed off the staged URL itself, which for a whole file IS
    // `stagingDirectory/resolvedInstallPath` (the same sidecar path as before)
    // and for a §4d part is its transport file, so a part's sidecar sits beside
    // the part, outside every promotable component root.
    URL(fileURLWithPath: stagedURL.path + ".resume.json")
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
      throw Self.httpStatusFailure(
        status: http.statusCode, detail: "head_\(http.statusCode)", response: http,
        sourceID: sourceID)
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
          reason: .sourceTimeout, detail: "urlerror_\(ns.code)", failingSourceID: sourceID,
          retryableTransient: true)
      case .cancelled:
        return DeliveryFailure(reason: .cancelled, failingSourceID: sourceID)
      default:
        // Transient-unreachable codes (conn lost / cannot-connect / no-host /
        // DNS) retry; genuine-offline (-1009) and other codes fail over (#1405).
        return DeliveryFailure(
          reason: .sourceUnreachable, detail: "urlerror_\(ns.code)", failingSourceID: sourceID,
          retryableTransient: Self.transientUnreachableCodes.contains(ns.code))
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
