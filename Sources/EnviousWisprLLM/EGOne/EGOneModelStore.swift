import CryptoKit
import EnviousWisprCore
import Foundation

/// Downloads, verifies, and stores first-party polish model artifacts (#1271).
///
/// Single authority for model DISTRIBUTION (manifest → download → verify →
/// atomic install → remove). Server runtime is `EGOneServerManager`'s
/// concern — the two evolve independently (a new host changes this file
/// only; a llama.cpp upgrade changes the manager only).
///
/// Verification is BLOCKING by design: a GGUF that does not hash to the
/// manifest's SHA-256 is deleted and never served (a corrupt LLM produces
/// plausible-looking wrong output, unlike a corrupt ASR model — stricter
/// than `ModelDownloadManager.verifyChecksum()`'s advisory check).
public actor EGOneModelStore {
  public enum InstallState: Sendable, Equatable {
    case notInstalled
    case downloading(fractionCompleted: Double)
    case verifying
    case installed(version: String)
    case failed(EGOneDownloadFailure)
  }

  public enum EGOneDownloadFailure: String, Error, Sendable, Equatable {
    case network = "network"
    case checksum = "checksum"
    case disk = "disk"
    case cancelled = "cancelled"
    case rangeUnsupported = "range_unsupported"
    case http = "http"
    case stubURL = "stub_url"
  }

  /// Recorded at download start; a changed remote object invalidates resume.
  private struct ResumeIdentity: Codable {
    let etag: String?
    let contentLength: Int64?
  }

  private let manifest: EGOneManifest
  private let directory: URL
  private var downloadTask: Task<Void, Never>?
  /// Monotonic download token (#1271 Codex r6): cancel / remove / a fresh
  /// start bump it, so a cancelled task that finishes LATE can neither
  /// publish its terminal state over a retry's live state nor clear the
  /// retry's task handle.
  private var downloadGeneration = 0
  private(set) var state: InstallState = .notInstalled
  /// Progress callback for the UI facade (set once by `EGOneRuntime`).
  private var onStateChange: (@Sendable (InstallState) -> Void)?

  public init(manifest: EGOneManifest, directory: URL? = nil) {
    self.manifest = manifest
    self.directory =
      directory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("EnviousWispr/PolishModels", isDirectory: true)
  }

  public func setStateObserver(_ observer: @escaping @Sendable (InstallState) -> Void) {
    onStateChange = observer
    observer(state)
  }

  private func transition(to newState: InstallState) {
    state = newState
    onStateChange?(newState)
  }

  // MARK: - Paths

  public var installedArtifactURL: URL {
    directory.appendingPathComponent(manifest.artifactFileName)
  }
  private var installedManifestURL: URL {
    directory.appendingPathComponent("installed-manifest.json")
  }
  private var tempArtifactURL: URL {
    // Same volume as the destination so the final move is an atomic rename.
    directory.appendingPathComponent("\(manifest.artifactFileName).partial")
  }
  private var resumeIdentityURL: URL {
    directory.appendingPathComponent("\(manifest.artifactFileName).resume.json")
  }

  // MARK: - Install state

  /// A model counts as installed ONLY when the artifact exists AND the
  /// installed-manifest sha matches the active manifest (file present but
  /// sha mismatch = NOT installed, never served).
  public func refreshInstalledState() {
    purgeStaleArtifacts()
    guard FileManager.default.fileExists(atPath: installedArtifactURL.path),
      let data = try? Data(contentsOf: installedManifestURL),
      let installed = try? JSONDecoder().decode(EGOneManifest.self, from: data),
      installed.sha256 == manifest.sha256
    else {
      if case .downloading = state { return }
      if case .verifying = state { return }
      // A visible failure must not evaporate on a reactive refresh (settings
      // open, activation) before the user reads it — retry (`startDownload`)
      // and `removeModel` own the exits from `.failed` (#1271 seam review).
      if case .failed = state { return }
      transition(to: .notInstalled)
      return
    }
    transition(to: .installed(version: installed.version))
  }

  /// Remove the installed model + bookkeeping and return to `.notInstalled`.
  /// The caller (runtime facade) owns reverting the provider setting.
  public func removeModel() throws {
    downloadGeneration += 1
    downloadTask?.cancel()
    downloadTask = nil
    let fm = FileManager.default
    for url in [installedArtifactURL, installedManifestURL, tempArtifactURL, resumeIdentityURL] {
      if fm.fileExists(atPath: url.path) {
        try fm.removeItem(at: url)
      }
    }
    transition(to: .notInstalled)
  }

  // MARK: - Download

  /// Begin (or resume) downloading. Single-flight: a second call while a
  /// download is live is a no-op. Returns whether a download actually
  /// STARTED — the caller's funnel telemetry keys off acceptance, not off
  /// the request (#1271 enumeration pass).
  @discardableResult
  public func startDownload() -> Bool {
    guard downloadTask == nil else { return false }
    if case .installed = state { return false }
    // The stub-URL ship guard test makes this unreachable in a release,
    // but fail closed anyway: never download from a non-HTTPS or
    // placeholder host.
    guard manifest.downloadURL.scheme == "https",
      let host = manifest.downloadURL.host,
      !host.contains("invalid")
    else {
      // `let host` matters: a hostless URL previously slipped past the old
      // optional-chained check (`nil != true`) (#1271 seam review).
      transition(to: .failed(.stubURL))
      return false
    }
    downloadGeneration += 1
    let generation = downloadGeneration
    downloadTask = Task { [weak self] in
      await self?.runDownload(generation: generation)
      await self?.clearTask(generation: generation)
    }
    return true
  }

  public func cancelDownload() {
    downloadGeneration += 1
    downloadTask?.cancel()
    downloadTask = nil
    // `.verifying` is INCLUDED (#1271 matrix gap 2): the cancelled task's
    // own `.failed(.cancelled)` transition is generation-suppressed, so
    // without this the UI would stick on "verifying" forever.
    switch state {
    case .downloading, .verifying:
      transition(to: .failed(.cancelled))
    case .notInstalled, .installed, .failed:
      break
    }
  }

  private func clearTask(generation: Int) {
    guard generation == downloadGeneration else { return }
    downloadTask = nil
  }

  /// State publication gate for download-task transitions: a stale task
  /// (cancelled, superseded by a retry) may not publish.
  private func transition(to newState: InstallState, ifGeneration generation: Int) {
    guard generation == downloadGeneration else { return }
    transition(to: newState)
  }

  /// Progress callbacks hop back onto this actor as INDEPENDENT tasks, so a
  /// delayed one can land after `.verifying`/`.installed`/`.failed` (state
  /// regression, #1271 Codex r5) or after a cancel-then-retry (stale
  /// fraction, r6). Only the CURRENT download, while still `.downloading`,
  /// may report progress. `internal` for the ordering test.
  func applyDownloadProgress(_ fraction: Double, generation: Int) {
    guard generation == downloadGeneration else { return }
    guard case .downloading = state else { return }
    transition(to: .downloading(fractionCompleted: fraction))
  }

  private func runDownload(generation: Int) async {
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      // A COMPLETE partial needs no download headroom — it only needs the
      // verify + rename, and the bytes are already on disk. Preflighting it
      // would strand an already-downloaded model as `.disk` when free space
      // shrank below 2.2x AFTER the download (Codex r2). An INCOMPLETE
      // partial's bytes count toward the budget either way — they resume
      // (already-downloaded bytes) or get discarded (freed) — so a big
      // stale partial cannot wedge Try Again on `.disk` forever (r13).
      if existingPartialBytes() != manifest.sizeBytes {
        try preflightDiskSpace(reclaimableBytes: existingPartialBytes())
      }
      transition(to: .downloading(fractionCompleted: existingFraction()), ifGeneration: generation)
      try await fetchArtifact(generation: generation)
      transition(to: .verifying, ifGeneration: generation)
      try await verifyAndInstall()
      transition(to: .installed(version: manifest.version), ifGeneration: generation)
      await AppLogger.shared.log(
        "EG-1 model installed: \(manifest.artifactFileName)", level: .info, category: "LLM")
    } catch is CancellationError {
      transition(to: .failed(.cancelled), ifGeneration: generation)
    } catch let urlError as URLError where urlError.code == .cancelled {
      // `cancelDownload()` tears the URLSession down via `invalidateAndCancel`,
      // which surfaces as `URLError.cancelled` (not `CancellationError`) — a
      // deliberate cancel must not be reported as a network failure
      // (#1271 Codex r4).
      transition(to: .failed(.cancelled), ifGeneration: generation)
    } catch let failure as EGOneDownloadFailure {
      // 416 is the ONE failure a retry can never heal: the identical Range
      // request re-fails forever. Discard the partial so Try Again starts
      // clean, matching the checksum path's cleanup (#1271 seam review).
      if failure == .rangeUnsupported { discardPartialArtifacts() }
      transition(to: .failed(failure), ifGeneration: generation)
      await AppLogger.shared.log(
        "EG-1 model download failed: \(failure.rawValue)", level: .info, category: "LLM")
    } catch {
      // File-write failures ride the download path (delegate appends,
      // directory creation, handle open) — telling that user to check the
      // download host instead of freeing disk misdirects them, and
      // telemetry misclassifies (#1271 confirm round).
      let failure: EGOneDownloadFailure = Self.isDiskWriteError(error) ? .disk : .network
      transition(to: .failed(failure), ifGeneration: generation)
      await AppLogger.shared.log(
        "EG-1 model download failed (\(failure.rawValue)): \(error.localizedDescription)",
        level: .info, category: "LLM")
    }
  }

  /// Pure classifier (`internal` for tests): does this error mean "your
  /// disk, not your network"? Cocoa file-WRITE family (512...642 spans
  /// unknown/no-permission/out-of-space/volume-read-only) plus POSIX
  /// out-of-space/quota.
  static func isDiskWriteError(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain {
      return (NSFileWriteUnknownError...NSFileWriteVolumeReadOnlyError).contains(ns.code)
    }
    if ns.domain == NSPOSIXErrorDomain {
      return ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT)
    }
    return false
  }

  /// Worst case is temp + final coexisting during the install move, plus
  /// filesystem slack — require 2.2× the artifact size free. Bytes already
  /// held by our own partial offset the requirement (see call site).
  private func preflightDiskSpace(reclaimableBytes: Int64 = 0) throws {
    let values = try? directory.deletingLastPathComponent()
      .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    if let available = values?.volumeAvailableCapacityForImportantUsage,
      available + reclaimableBytes < Int64(Double(manifest.sizeBytes) * 2.2)
    {
      throw EGOneDownloadFailure.disk
    }
  }

  /// True iff an interrupted download left partial bytes to resume from —
  /// the runtime reads this for honest `downloadStarted(resumed:)` telemetry.
  var hasPartialDownload: Bool { existingPartialBytes() > 0 }

  /// Drop the partial + resume identity. `internal` for the 416-cleanup test.
  func discardPartialArtifacts() {
    try? FileManager.default.removeItem(at: tempArtifactURL)
    try? FileManager.default.removeItem(at: resumeIdentityURL)
  }

  /// Delete artifacts belonging to a PREVIOUS manifest (#1271 r11). The
  /// hot-swap contract changes `artifactFileName` per version (EG-1 v2,
  /// EG-2, ...), so an update strands the old multi-GB file forever —
  /// Remove Model only knows the CURRENT name. Extension-scoped so nothing
  /// outside this store's file family is ever touched.
  private func purgeStaleArtifacts() {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
    let current = manifest.artifactFileName
    for name in entries {
      guard !name.hasPrefix(current), name != "installed-manifest.json" else { continue }
      guard name.hasSuffix(".gguf") || name.hasSuffix(".partial") || name.hasSuffix(".resume.json")
      else { continue }
      try? fm.removeItem(at: directory.appendingPathComponent(name))
    }
  }

  private func existingPartialBytes() -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: tempArtifactURL.path)[.size] as? Int64)
      .flatMap { $0 } ?? 0
  }

  private func existingFraction() -> Double {
    guard
      let size = try? FileManager.default.attributesOfItem(
        atPath: tempArtifactURL.path)[.size] as? Int64
    else { return 0 }
    return Double(size) / Double(manifest.sizeBytes)
  }

  /// Byte-range resume download. `URLSession` download-task resume data is
  /// brittle across relaunches; an explicit Range request against a
  /// validated (etag, length) identity is simpler and testable.
  private func fetchArtifact(generation: Int) async throws {
    let fm = FileManager.default
    var existingBytes: Int64 = 0
    if let size = try? fm.attributesOfItem(atPath: tempArtifactURL.path)[.size] as? Int64 {
      existingBytes = size
    }

    // A COMPLETE partial (app quit between fetch and verify) must go
    // straight to verification — a `Range: bytes=<size>-` request answers
    // 416 and would strand every retry as range_unsupported (Codex r1 P2).
    // BEFORE the identity HEAD: the checksum is the authority for a
    // complete file (pass → install, fail → deleted + fresh download), so
    // no network round-trip is needed or wanted here — proven by the
    // no-network regression test.
    if existingBytes == manifest.sizeBytes {
      return
    }

    // Validate resume identity: if the remote object changed under the
    // URL, the partial file is garbage — discard and restart.
    if existingBytes > 0 {
      let head = try await headIdentity()
      let recorded = try? JSONDecoder().decode(
        ResumeIdentity.self, from: Data(contentsOf: resumeIdentityURL))
      if Self.shouldDiscardPartial(
        recordedETag: recorded?.etag, recordedLength: recorded?.contentLength,
        headETag: head.etag, headLength: head.contentLength,
        existingBytes: existingBytes, expectedSize: manifest.sizeBytes)
      {
        try? fm.removeItem(at: tempArtifactURL)
        try? fm.removeItem(at: resumeIdentityURL)
        existingBytes = 0
      }
    }

    var request = URLRequest(url: manifest.downloadURL)
    if existingBytes > 0 {
      request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
    }
    request.timeoutInterval = 60

    // Delegate-based data task (NOT `URLSession.bytes`): AsyncBytes iterates
    // ONE BYTE per actor-isolated loop turn — billions of iterations for a
    // 2.7 GB artifact made installs CPU-bound (Codex r1 P2). The delegate
    // receives multi-KB chunks and appends them straight to the partial
    // file, preserving mid-download resume granularity.
    if !fm.fileExists(atPath: tempArtifactURL.path) {
      fm.createFile(atPath: tempArtifactURL.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: tempArtifactURL)
    defer { try? handle.close() }
    try handle.seekToEnd()

    let expectedTotal = manifest.sizeBytes
    let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
      Task { [weak self] in
        await self?.applyDownloadProgress(fraction, generation: generation)
      }
    }
    // Record the resume identity AS SOON AS HEADERS ARRIVE, before any body
    // byte streams (Codex r2): an interrupted FIRST download must leave a
    // resumable (identity + partial) pair, or the next launch discards the
    // partial as identity-less and restarts a 2.7 GB transfer from zero.
    let identityURL = resumeIdentityURL
    let expectedSize = manifest.sizeBytes
    let onValidatedResponse: @Sendable (HTTPURLResponse) -> Void = { http in
      let identity = ResumeIdentity(
        etag: http.value(forHTTPHeaderField: "ETag"),
        contentLength: expectedSize)
      try? JSONEncoder().encode(identity).write(to: identityURL)
    }
    let delegate = ChunkAppendDelegate(
      handle: handle, startingBytes: existingBytes, expectedTotal: expectedTotal,
      onProgress: onProgress, onValidatedResponse: onValidatedResponse)
    let http = try await delegate.run(request: request)

    switch http.statusCode {
    case 200:
      // Server ignored the Range header; the delegate detected this and
      // truncated the partial to zero before writing (see ChunkAppendDelegate).
      break
    case 206:
      break
    case 416:
      throw EGOneDownloadFailure.rangeUnsupported
    default:
      throw EGOneDownloadFailure.http
    }
  }

  /// Pure resume-validity decision (`internal` for tests): discard the
  /// partial when no identity was recorded, the remote identity changed,
  /// or the partial is impossibly large.
  static func shouldDiscardPartial(
    recordedETag: String??, recordedLength: Int64??,
    headETag: String?, headLength: Int64?,
    existingBytes: Int64, expectedSize: Int64
  ) -> Bool {
    guard let etag = recordedETag, let length = recordedLength else { return true }
    if etag != headETag || length != headLength { return true }
    return existingBytes > expectedSize
  }

  private func headIdentity() async throws -> (etag: String?, contentLength: Int64?) {
    var request = URLRequest(url: manifest.downloadURL)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 30
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw EGOneDownloadFailure.network
    }
    // A non-success HEAD (transient 5xx, proxy interstitial, HEAD-blocked)
    // carries an error page's headers, NOT the artifact's identity —
    // treating it as identity reads as "remote object changed" and deletes
    // a resumable multi-GB partial (Codex r15). Throw instead: the partial
    // survives and the retry re-validates.
    guard (200...299).contains(http.statusCode) else {
      throw EGOneDownloadFailure.network
    }
    let length = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
    return (http.value(forHTTPHeaderField: "ETag"), length)
  }

  /// Streaming SHA-256 (constant memory) off the caller's actor, then
  /// atomic rename + installed-manifest write. One automatic re-download
  /// is the caller's policy; this reports the failure. `internal` (not
  /// private) so checksum pass/fail/partial tests drive it directly with
  /// seeded temp files — the network fetch is the only untested seam.
  func verifyAndInstall() async throws {
    // Cancellation gates at entry AND after hashing (#1271 matrix gap 2):
    // the detached hash below does not inherit cancellation, so without the
    // second check a cancel that landed during the seconds-long hash would
    // still atomically install the model.
    try Task.checkCancellation()
    let tempURL = tempArtifactURL
    let expected = manifest.sha256.lowercased()
    let digest: String = try await Task.detached(priority: .utility) {
      // Task.detached: hashing 2.7 GB is seconds of pure CPU + IO that must
      // not hold the store actor (progress/UI reads) — @concurrent needs the
      // enclosing fn nonisolated; a detached utility task is the house shape.
      let handle = try FileHandle(forReadingFrom: tempURL)
      defer { try? handle.close() }
      var hasher = SHA256()
      while autoreleasepool(invoking: {
        guard let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty else {
          return false
        }
        hasher.update(data: chunk)
        return true
      }) {}
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }.value

    try Task.checkCancellation()
    guard digest == expected else {
      try? FileManager.default.removeItem(at: tempArtifactURL)
      try? FileManager.default.removeItem(at: resumeIdentityURL)
      throw EGOneDownloadFailure.checksum
    }

    let fm = FileManager.default
    if fm.fileExists(atPath: installedArtifactURL.path) {
      try fm.removeItem(at: installedArtifactURL)
    }
    try fm.moveItem(at: tempArtifactURL, to: installedArtifactURL)
    try JSONEncoder().encode(manifest).write(to: installedManifestURL)
    try? fm.removeItem(at: resumeIdentityURL)
  }
}

/// Streaming download delegate for the EG-1 artifact (#1271 Codex r1 P2):
/// receives multi-KB chunks from URLSession's serial delegate queue and
/// appends them synchronously to the partial file — constant memory, no
/// per-byte iteration, and mid-download interruption keeps every appended
/// byte for the next resume.
///
/// `@unchecked Sendable`: all mutable state is touched ONLY on URLSession's
/// serial delegate queue (single-touch by construction) plus the one-shot
/// continuation handoff guarded by `didResume`.
final class ChunkAppendDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let handle: FileHandle
  private let startingBytes: Int64
  private let expectedTotal: Int64
  private let onProgress: @Sendable (Double) -> Void
  /// Fired once when a 200/206 response is accepted, BEFORE body bytes
  /// stream — the store persists the resume identity here so an interrupted
  /// first download still leaves a resumable pair (Codex r2).
  private let onValidatedResponse: @Sendable (HTTPURLResponse) -> Void

  private var written: Int64
  private var lastReported: Int64
  private var response: HTTPURLResponse?
  private var writeError: Error?
  /// True only for OUR deliberate cancel on a non-success status — the one
  /// completion "error" that must still surface the response so the caller
  /// can map the status code (Codex r3: a REAL mid-body network error must
  /// throw instead, or a truncated partial gets checksum-deleted).
  private var cancelledForStatus = false
  private var continuation: CheckedContinuation<HTTPURLResponse, Error>?

  init(
    handle: FileHandle, startingBytes: Int64, expectedTotal: Int64,
    onProgress: @escaping @Sendable (Double) -> Void,
    onValidatedResponse: @escaping @Sendable (HTTPURLResponse) -> Void = { _ in }
  ) {
    self.handle = handle
    self.startingBytes = startingBytes
    self.expectedTotal = expectedTotal
    self.onProgress = onProgress
    self.onValidatedResponse = onValidatedResponse
    self.written = startingBytes
    self.lastReported = startingBytes
  }

  func run(request: URLRequest) async throws -> HTTPURLResponse {
    // delegateQueue nil → URLSession creates its own SERIAL queue. The
    // delegate's single-touch state and in-order FileHandle appends depend
    // on serial delivery; a default `OperationQueue()` is concurrent and
    // can interleave `didReceive data` callbacks (#1271 Codex r5 P1).
    let session = URLSession(
      configuration: .default, delegate: self, delegateQueue: nil)
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
    // Server ignored the Range header (200 on a resumed request): the body
    // is the WHOLE object, so the already-written prefix must go.
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
      cancelledForStatus = true
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
      // Report every ~16 MB to keep the UI live without churn.
      if written - lastReported >= (16 << 20) {
        lastReported = written
        onProgress(Double(written) / Double(expectedTotal))
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
    // resume point, and returning "success" here would route it into
    // checksum verification, which deletes it (Codex r3). Only OUR
    // deliberate non-success-status cancel returns the response.
    if let error, !cancelledForStatus {
      cont.resume(throwing: error)
      return
    }
    if let response {
      cont.resume(returning: response)
      return
    }
    cont.resume(throwing: error ?? URLError(.unknown))
  }
}
