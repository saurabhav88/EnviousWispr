import CryptoKit
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// EG-1 model store: checksum gating, install-state truth, remove-model,
/// and the pure resume-validity decision (#1271). The network fetch is the
/// only seam not covered here (real-host validation is a PR-1a obligation).
@Suite("EGOneModelStore (#1271)")
struct EGOneModelStoreTests {

  /// Manifest whose sha256 matches `content` exactly.
  static func makeFixture(content: Data) throws -> (
    store: EGOneModelStore, manifest: EGOneManifest, dir: URL
  ) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("eg1-store-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let digest = EGOneModelStoreTests.sha256Hex(content)
    let manifest = EGOneManifest(
      modelName: "eg-1", version: "v1", sha256: digest, sizeBytes: Int64(content.count),
      contextTokens: 4096, promptTemplateID: "eg1-v1", minAppVersion: "2.3.0",
      downloadURL: URL(string: "https://models.enviouslabs.co/eg1/test.gguf")!)
    return (EGOneModelStore(manifest: manifest, directory: dir), manifest, dir)
  }

  static func sha256Hex(_ data: Data) -> String {
    // CryptoKit one-shot — a SEPARATE call path from production's streaming
    // hash, so a bug in the chunked reader cannot self-confirm here.
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  @Test func checksumPassInstallsAtomically() async throws {
    let content = Data("model-bytes-good".utf8)
    let (store, manifest, dir) = try Self.makeFixture(content: content)
    try content.write(to: dir.appendingPathComponent("\(manifest.artifactFileName).partial"))
    try await store.verifyAndInstall()
    let installed = dir.appendingPathComponent(manifest.artifactFileName)
    #expect(FileManager.default.fileExists(atPath: installed.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("\(manifest.artifactFileName).partial").path))
    await store.refreshInstalledState()
    let state = await store.state
    #expect(state == .installed(version: "v1"))
  }

  @Test func checksumMismatchDeletesPartialAndNeverInstalls() async throws {
    let (store, manifest, dir) = try Self.makeFixture(content: Data("expected".utf8))
    let partial = dir.appendingPathComponent("\(manifest.artifactFileName).partial")
    try Data("corrupted-bytes".utf8).write(to: partial)
    await #expect(throws: EGOneModelStore.EGOneDownloadFailure.checksum) {
      try await store.verifyAndInstall()
    }
    #expect(!FileManager.default.fileExists(atPath: partial.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(manifest.artifactFileName).path))
  }

  @Test func fileWithoutMatchingInstalledManifestIsNotInstalled() async throws {
    let content = Data("model-bytes".utf8)
    let (store, manifest, dir) = try Self.makeFixture(content: content)
    // Artifact present but NO installed-manifest.json → not installed.
    try content.write(to: dir.appendingPathComponent(manifest.artifactFileName))
    await store.refreshInstalledState()
    let state = await store.state
    #expect(state == .notInstalled)
  }

  @Test func installedManifestShaMismatchIsNotInstalled() async throws {
    let content = Data("model-bytes".utf8)
    let (store, manifest, dir) = try Self.makeFixture(content: content)
    try content.write(to: dir.appendingPathComponent(manifest.artifactFileName))
    // Installed-manifest recorded for a DIFFERENT artifact (sha mismatch).
    let other = EGOneManifest(
      modelName: "eg-1", version: "v0", sha256: String(repeating: "0", count: 64),
      sizeBytes: 1, contextTokens: 4096, promptTemplateID: "eg1-v1",
      minAppVersion: "2.3.0", downloadURL: manifest.downloadURL)
    try JSONEncoder().encode(other).write(
      to: dir.appendingPathComponent("installed-manifest.json"))
    await store.refreshInstalledState()
    let state = await store.state
    #expect(state == .notInstalled)
  }

  @Test func removeModelDeletesEverything() async throws {
    let content = Data("model-bytes".utf8)
    let (store, manifest, dir) = try Self.makeFixture(content: content)
    try content.write(to: dir.appendingPathComponent("\(manifest.artifactFileName).partial"))
    try await store.verifyAndInstall()
    try await store.removeModel()
    #expect(
      !FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(manifest.artifactFileName).path))
    #expect(
      !FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("installed-manifest.json").path))
    let state = await store.state
    #expect(state == .notInstalled)
  }

  /// Codex r1 P2 regression lock: a COMPLETE partial (app quit between
  /// fetch and verify) must go straight to verification and install —
  /// never a Range request answered 416 that strands every retry as
  /// range_unsupported. Proof of no-network: the whole download path runs
  /// to `.installed` end-to-end with no server behind the manifest URL.
  @Test func completePartialInstallsWithoutNetwork() async throws {
    let content = Data("complete-partial-bytes".utf8)
    let (store, manifest, dir) = try Self.makeFixture(content: content)
    try content.write(to: dir.appendingPathComponent("\(manifest.artifactFileName).partial"))
    await store.startDownload()
    // Poll the actor state to terminal (download task is fire-and-forget).
    var state = await store.state
    for _ in 0..<100 {
      if case .installed = state { break }
      if case .failed = state { break }
      try await Task.sleep(for: .milliseconds(50))
      state = await store.state
    }
    #expect(state == .installed(version: "v1"))
    #expect(
      FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(manifest.artifactFileName).path))
  }

  // MARK: - Resume-validity decision (pure)

  @Test func resumeDiscardedWhenNoIdentityRecorded() {
    #expect(
      EGOneModelStore.shouldDiscardPartial(
        recordedETag: nil, recordedLength: nil,
        headETag: "abc", headLength: 100, existingBytes: 50, expectedSize: 100))
  }

  @Test func resumeDiscardedWhenRemoteObjectChanged() {
    #expect(
      EGOneModelStore.shouldDiscardPartial(
        recordedETag: .some("old-etag"), recordedLength: .some(100),
        headETag: "new-etag", headLength: 100, existingBytes: 50, expectedSize: 100))
  }

  @Test func resumeDiscardedWhenPartialImpossiblyLarge() {
    #expect(
      EGOneModelStore.shouldDiscardPartial(
        recordedETag: .some("etag"), recordedLength: .some(100),
        headETag: "etag", headLength: 100, existingBytes: 150, expectedSize: 100))
  }

  @Test func resumeKeptWhenIdentityMatches() {
    #expect(
      !EGOneModelStore.shouldDiscardPartial(
        recordedETag: .some("etag"), recordedLength: .some(100),
        headETag: "etag", headLength: 100, existingBytes: 50, expectedSize: 100))
  }

  // MARK: - Cancel during verification (#1271 matrix gap 2)

  /// A cancel that lands during the seconds-long hash must not install the
  /// model afterwards — the detached hash does not inherit cancellation, so
  /// `verifyAndInstall` gates on it explicitly.
  @Test func cancelDuringVerifyDoesNotInstall() async throws {
    let content = Data("model-bytes-cancel-verify".utf8)
    let (store, manifest, dir) = try Self.makeFixture(content: content)
    try content.write(to: dir.appendingPathComponent("\(manifest.artifactFileName).partial"))
    let task = Task { () -> Bool in
      withUnsafeCurrentTask { $0?.cancel() }
      do {
        try await store.verifyAndInstall()
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }
    #expect(await task.value, "expected CancellationError, not install or another error")
    #expect(
      !FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(manifest.artifactFileName).path))
  }

  // MARK: - Hot-swap hygiene: previous-version artifacts purged (#1271 r11)

  /// A manifest bump changes `artifactFileName`; refresh must reclaim the
  /// old multi-GB file family, and must NOT touch the current one.
  @Test func refreshPurgesPreviousManifestArtifacts() async throws {
    let content = Data("model-bytes-current".utf8)
    let (store, manifest, dir) = try Self.makeFixture(content: content)
    try content.write(to: dir.appendingPathComponent("\(manifest.artifactFileName).partial"))
    try await store.verifyAndInstall()

    let staleArtifact = dir.appendingPathComponent("eg-1-v0.gguf")
    let stalePartial = dir.appendingPathComponent("eg-1-v0.gguf.partial")
    let staleIdentity = dir.appendingPathComponent("eg-1-v0.gguf.resume.json")
    let unrelated = dir.appendingPathComponent("notes.txt")
    for url in [staleArtifact, stalePartial, staleIdentity, unrelated] {
      try Data("stale".utf8).write(to: url)
    }

    await store.refreshInstalledState()
    let state = await store.state
    #expect(state == .installed(version: "v1"))
    for url in [staleArtifact, stalePartial, staleIdentity] {
      #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)")
    }
    // Extension-scoped: files outside the store's family are never touched.
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
    #expect(
      FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(manifest.artifactFileName).path))
  }

  // MARK: - startDownload no-ops from non-startable states (#1271 seam review)

  /// A tap while installed (or verifying) must not emit a spurious
  /// downloadStarted event or re-stamp the duration clock.
  @Test @MainActor func startDownloadFromInstalledEmitsNothing() async throws {
    let content = Data("model-bytes-installed-noop".utf8)
    let (seedStore, manifest, dir) = try Self.makeFixture(content: content)
    try content.write(to: dir.appendingPathComponent("\(manifest.artifactFileName).partial"))
    try await seedStore.verifyAndInstall()

    let runtime = EGOneRuntime(manifest: manifest, serverBinaryURL: nil, storeDirectory: dir)
    // Let the init-time refresh land `.installed` before poking it.
    for _ in 0..<50 where runtime.installState == .notInstalled {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(runtime.installState == .installed(version: "v1"))

    nonisolated(unsafe) var events: [EGOneRuntimeEvent] = []
    runtime.onEvent = { event in
      Task { @MainActor in events.append(event) }
    }
    runtime.startDownload()
    try await Task.sleep(for: .milliseconds(200))
    #expect(events.isEmpty)
    #expect(runtime.installState == .installed(version: "v1"))
  }

  // MARK: - Deferred removal cancelled by re-selection (#1271 seam review P1)

  /// Remove Model during a pinned recording defers; the user re-selecting
  /// EG-1 before the recording ends must CANCEL that deferred removal, or
  /// the terminal-state retry deletes the model they just re-picked.
  @Test @MainActor func reselectingEGOneCancelsDeferredRemoval() async throws {
    let content = Data("model-bytes-keep-me".utf8)
    let (seedStore, manifest, dir) = try Self.makeFixture(content: content)
    try content.write(to: dir.appendingPathComponent("\(manifest.artifactFileName).partial"))
    try await seedStore.verifyAndInstall()
    let artifact = dir.appendingPathComponent(manifest.artifactFileName)

    let runtime = EGOneRuntime(manifest: manifest, serverBinaryURL: nil, storeDirectory: dir)
    runtime.isPinnedInFlight = { true }
    runtime.removeModel()  // recording pinned — defers
    runtime.activateAndProbe()  // user re-selects EG-1 — must cancel the pending removal
    runtime.isPinnedInFlight = { false }
    runtime.retryPendingRemoval()  // terminal-state retry must now no-op
    try await Task.sleep(for: .milliseconds(300))
    #expect(FileManager.default.fileExists(atPath: artifact.path))
  }

  // MARK: - 416 cleanup + failure-state stickiness (#1271 seam review)

  /// A 416 (range refused) can never heal by retrying the identical Range
  /// request — cleanup must drop the partial + identity so retry restarts.
  @Test func rangeUnsupportedCleanupDiscardsPartialAndIdentity() async throws {
    let (store, manifest, dir) = try Self.makeFixture(content: Data("x".utf8))
    let partial = dir.appendingPathComponent("\(manifest.artifactFileName).partial")
    let identity = dir.appendingPathComponent("\(manifest.artifactFileName).resume.json")
    try Data("p".utf8).write(to: partial)
    try Data("{}".utf8).write(to: identity)
    await store.discardPartialArtifacts()
    #expect(!FileManager.default.fileExists(atPath: partial.path))
    #expect(!FileManager.default.fileExists(atPath: identity.path))
  }

  /// Hostless manifest URLs fail closed as stub URLs (the old optional-chained
  /// check let them through), and a `.failed` state survives a reactive
  /// refresh so the user can actually read the failure.
  @Test func hostlessURLFailsClosedAndFailureSurvivesRefresh() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("eg1-stub-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let manifest = EGOneManifest(
      modelName: "eg-1", version: "v1", sha256: "00", sizeBytes: 1,
      contextTokens: 4096, promptTemplateID: "eg1-v1", minAppVersion: "2.3.0",
      downloadURL: URL(string: "https:///eg1/test.gguf")!)
    let store = EGOneModelStore(manifest: manifest, directory: dir)
    await store.startDownload()
    #expect(await store.state == .failed(.stubURL))
    await store.refreshInstalledState()
    #expect(await store.state == .failed(.stubURL))
  }

  // MARK: - Disk vs network failure classification (#1271 confirm round)

  @Test func diskWriteErrorsClassifyAsDiskNotNetwork() {
    #expect(
      EGOneModelStore.isDiskWriteError(
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
    #expect(
      EGOneModelStore.isDiskWriteError(
        NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
    // Transport errors stay network.
    #expect(!EGOneModelStore.isDiskWriteError(URLError(.networkConnectionLost)))
    // File-READ errors (missing partial) are not the write family.
    #expect(
      !EGOneModelStore.isDiskWriteError(
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)))
  }

  // MARK: - Resume telemetry truth (#1271 matrix gap 4)

  @Test func hasPartialDownloadReflectsDisk() async throws {
    let content = Data("model-bytes-partial-flag".utf8)
    let (store, manifest, dir) = try Self.makeFixture(content: content)
    #expect(await store.hasPartialDownload == false)
    try Data("some-bytes".utf8).write(
      to: dir.appendingPathComponent("\(manifest.artifactFileName).partial"))
    #expect(await store.hasPartialDownload == true)
  }

  // MARK: - Stale progress ordering (#1271 Codex r5)

  /// Progress callbacks re-enter the actor as independent tasks; one that
  /// lands AFTER a terminal transition must not regress the state to
  /// `.downloading` (stuck UI until the next refresh), and one from a
  /// SUPERSEDED download generation must not publish at all.
  @Test func lateProgressCannotRegressTerminalState() async throws {
    let content = Data("model-bytes-progress".utf8)
    let (store, manifest, dir) = try Self.makeFixture(content: content)

    // Not started yet: progress is a no-op (state gate).
    await store.applyDownloadProgress(0.5, generation: 0)
    var state = await store.state
    #expect(state == .notInstalled)

    // Stale generation: rejected before the state gate is even consulted.
    await store.applyDownloadProgress(0.5, generation: 99)
    state = await store.state
    #expect(state == .notInstalled)

    // Installed: a straggler progress task must not flip it back.
    try content.write(to: dir.appendingPathComponent("\(manifest.artifactFileName).partial"))
    try await store.verifyAndInstall()
    await store.refreshInstalledState()
    await store.applyDownloadProgress(0.9, generation: 0)
    state = await store.state
    #expect(state == .installed(version: "v1"))
  }

  // MARK: - Cancel→retry drain gate (#1287 / #1279)

  /// Poll the actor state to a terminal value (house pattern:
  /// `completePartialInstallsWithoutNetwork`).
  private func awaitTerminalState(
    _ store: EGOneModelStore, sourceLocation: SourceLocation = #_sourceLocation
  ) async throws -> EGOneModelStore.InstallState {
    var state = await store.state
    for _ in 0..<100 {
      if case .installed = state { return state }
      if case .failed = state { return state }
      try await Task.sleep(for: .milliseconds(50))  // settle: poll actor state to terminal
      state = await store.state
    }
    return state
  }

  /// Thread-safe state-sequence recorder for observer-ordering assertions.
  /// `@unchecked Sendable`: all mutation behind the NSLock.
  final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [EGOneModelStore.InstallState] = []
    func add(_ s: EGOneModelStore.InstallState) {
      lock.lock()
      _states.append(s)
      lock.unlock()
    }
    var states: [EGOneModelStore.InstallState] {
      lock.lock()
      defer { lock.unlock() }
      return _states
    }
    var downloadingCount: Int {
      states.reduce(0) { count, s in
        if case .downloading = s { return count + 1 }
        return count
      }
    }
  }

  /// The invariant is EXCLUSION while a cancelled predecessor drains: the
  /// accepted retry publishes `.downloading` once at acceptance (instant
  /// Cancel, no dead Try Again button) and its download body must not run —
  /// observable as the ABSENCE of the body's own `.downloading` re-publish,
  /// which is cheap synchronous actor work and lands within a few yields
  /// whenever the body (incorrectly) starts. Negative-control validated:
  /// removing the drain await flips `downloadingCount` to 2 inside the
  /// yield window.
  @Test func retryWaitsForPriorDrainBeforeTouchingPartial() async throws {
    let content = Data("model-bytes-drain-gate".utf8)
    let (store, manifest, dir) = try Self.makeFixture(content: content)
    let partial = dir.appendingPathComponent("\(manifest.artifactFileName).partial")
    try content.write(to: partial)

    let recorder = StateRecorder()
    await store.setStateObserver { recorder.add($0) }  // fires once with .notInstalled
    // Pre-warm the shared logger: the download body's first suspension is a
    // log call, and first-time logger init would otherwise stretch the
    // un-gated body's latency past the absence window below, masking a
    // missing gate (found via negative control).
    await AppLogger.shared.log("drain-gate test warm-up", level: .debug, category: "LLM")

    // Held predecessor: finishes only when the stream is finished.
    let (releases, releaseCont) = AsyncStream.makeStream(of: Void.self)
    let drain = Task { for await _ in releases {} }
    await store.seedDrainingTaskForTest(drain)

    let accepted = await store.startDownload()
    #expect(accepted == true)
    // Pre-drain publish: instant progress state (complete partial → 1.0).
    #expect(await store.state == .downloading(fractionCompleted: 1.0))
    #expect(recorder.downloadingCount == 1)

    // Absence window in which an un-gated body would re-publish
    // `.downloading` and begin mutating disk (~ms with the logger warm).
    for _ in 0..<200 { await Task.yield() }
    try await Task.sleep(for: .milliseconds(150))  // settle: absence-of-effect window for the gated body
    #expect(
      recorder.downloadingCount == 1,
      "download body must not run while the drain is held (no re-publish)")
    #expect(
      try Data(contentsOf: partial) == content, "partial bytes must be untouched while drain held")
    #expect(
      !FileManager.default.fileExists(
        atPath: dir.appendingPathComponent(manifest.artifactFileName).path),
      "no install may happen behind a held drain")

    releaseCont.finish()
    let terminal = try await awaitTerminalState(store)
    #expect(terminal == .installed(version: "v1"))
    #expect(recorder.downloadingCount >= 2, "released body re-publishes and completes")
  }

  /// Cancel must stash the live task as the drain (single-flight reopens
  /// only through the gate), and a double-cancel must NOT clobber the stash
  /// with nil — cancel → cancel → Try Again would otherwise reopen the race.
  @Test func cancelStashesLiveTaskAsDrainAndDoubleCancelKeepsIt() async throws {
    let content = Data("model-bytes-stash".utf8)
    let (store, manifest, dir) = try Self.makeFixture(content: content)
    try content.write(to: dir.appendingPathComponent("\(manifest.artifactFileName).partial"))

    let (releases, releaseCont) = AsyncStream.makeStream(of: Void.self)
    let drain = Task { for await _ in releases {} }
    await store.seedDrainingTaskForTest(drain)

    // T1 is accepted and blocks awaiting the held drain — a live download task.
    #expect(await store.startDownload() == true)
    await store.cancelDownload()
    #expect(await store.hasPendingDrainForTest == true, "cancel stashes the live task")
    #expect(await store.state == .failed(.cancelled))

    await store.cancelDownload()  // double-cancel
    #expect(await store.hasPendingDrainForTest == true, "nil task must not clobber the stash")

    // Retry is accepted and chains behind the whole drain lineage.
    #expect(await store.startDownload() == true)
    #expect(await store.hasPendingDrainForTest == false, "retry consumed the drain slot")
    releaseCont.finish()
    let terminal = try await awaitTerminalState(store)
    #expect(terminal == .installed(version: "v1"))
  }

  /// A retry that was cancelled AND whose files were removed while it
  /// awaited the drain must never touch disk afterwards: no recreated
  /// `.partial`, no `.resume.json`, state stays `.notInstalled`.
  @Test func staleRetryNeverTouchesDiskAfterGenerationBump() async throws {
    let content = Data("model-bytes-stale-retry".utf8)
    let (store, manifest, dir) = try Self.makeFixture(content: content)
    let partial = dir.appendingPathComponent("\(manifest.artifactFileName).partial")
    let identity = dir.appendingPathComponent("\(manifest.artifactFileName).resume.json")
    try content.write(to: partial)

    let (releases, releaseCont) = AsyncStream.makeStream(of: Void.self)
    let drain = Task { for await _ in releases {} }
    await store.seedDrainingTaskForTest(drain)
    await AppLogger.shared.log("stale-retry test warm-up", level: .debug, category: "LLM")

    #expect(await store.startDownload() == true)  // T1 awaits the held drain
    try await store.removeModel()  // bumps generation, deletes files
    #expect(await store.state == .notInstalled)

    releaseCont.finish()  // T1 unblocks — its staleness stop must return
    // Absence window: an un-guarded stale body's first disk mutation
    // (partial re-creation in fetchArtifact) is synchronous actor work right
    // after the drain resumes, so this settle discriminates. Negative-control
    // validated: removing the staleness stop recreates the partial here.
    for _ in 0..<200 { await Task.yield() }
    try await Task.sleep(for: .milliseconds(100))  // settle: absence-of-effect window for the stale retry
    #expect(
      !FileManager.default.fileExists(atPath: partial.path),
      "stale retry must not recreate the partial")
    #expect(
      !FileManager.default.fileExists(atPath: identity.path),
      "stale retry must not write resume identity")
    #expect(await store.state == .notInstalled)
  }

  // MARK: - Download-completion keyed off the request flag (#1271 Codex r17)

  /// `.installed` re-emissions from refreshes (launch, activation, settings
  /// open) must NOT read as a download completion — no completion event, no
  /// auto-activate loop. Only a store-ACCEPTED download arms the flag; this
  /// runtime never started one, so repeated refreshes stay silent.
  @Test @MainActor func installedRefreshWithoutRequestEmitsNoCompletion() async throws {
    let content = Data("model-bytes-no-request".utf8)
    let (seedStore, manifest, dir) = try Self.makeFixture(content: content)
    try content.write(to: dir.appendingPathComponent("\(manifest.artifactFileName).partial"))
    try await seedStore.verifyAndInstall()

    let runtime = EGOneRuntime(manifest: manifest, serverBinaryURL: nil, storeDirectory: dir)
    nonisolated(unsafe) var completions = 0
    runtime.onEvent = { event in
      if case .downloadCompleted = event {
        Task { @MainActor in completions += 1 }
      }
    }
    // Drive several reactive refreshes (the loop the r4 P1 guard prevents).
    runtime.activateAndProbe()
    runtime.activateAndProbe()
    try await Task.sleep(for: .milliseconds(400))
    #expect(completions == 0)
    #expect(runtime.installState == .installed(version: "v1"))
  }
}
