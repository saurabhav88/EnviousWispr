import CryptoKit
import EnviousWisprModelDelivery
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// #1386 PR-2b. The retire-and-refetch coordinator: L1–L7 of the plan's §1.
///
/// Every refusal here is silent by design, which is exactly where a false green hides. So each
/// refusal asserts a **positive**: the named file still exists, the fetch count is zero, the
/// hash count is zero. "Did not crash" cannot tell a correct refusal from a path that never
/// ran.
@Suite @MainActor struct WhisperKitLegacyUpgradeCoordinatorTests {

  nonisolated static let variant = "openai_whisper-large-v3-v20240930_turbo"

  // MARK: - Fixture

  private final class World {
    static let variant = WhisperKitLegacyUpgradeCoordinatorTests.variant

    let root: URL
    let documents: URL
    let appSupport: URL
    var files: [LegacyRetirement.TrustedFile] = []
    var fetches = 0
    var admitted = false
    var admitOnFetch = true
    var deliveryEnabled = true
    var holdFetch = false
    var fetchRelease: CheckedContinuation<Void, Never>?
    var holdCancel = false
    var cancelRelease: CheckedContinuation<Void, Never>?
    var cancelCalls = 0
    var unloadCalls = 0
    var removeCalls = 0
    var removeSucceeds = true
    /// Collaborator-order log for the L1 ordering assertion.
    var callOrder: [String] = []
    var events: [WhisperKitLegacyUpgradeCoordinator.Event] = []

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wk-coord-\(UUID().uuidString)", isDirectory: true)
      documents = root.appendingPathComponent("Documents", isDirectory: true)
      appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
      try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }

    var foreignDirectory: URL {
      documents
        .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
        .appendingPathComponent(World.variant, isDirectory: true)
    }

    var markerURL: URL {
      appSupport.appendingPathComponent("EnviousWispr/ModelDelivery/whisperkit-replacement-owed")
    }

    var declinedURL: URL {
      appSupport.appendingPathComponent(
        "EnviousWispr/ModelDelivery/whisperkit-foreign-declined.json")
    }

    /// Two nested files, mirroring the real manifest's depth (three components).
    @discardableResult
    func stageForeignCopy() throws -> [String: Data] {
      let payloads = [
        "AudioEncoder.mlmodelc/analytics/coremldata.bin": Data("encoder-analytics".utf8),
        "TextDecoder.mlmodelc/coremldata.bin": Data("decoder".utf8),
      ]
      for (relativePath, bytes) in payloads {
        let url = foreignDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
      }
      files = payloads.map { path, bytes in
        LegacyRetirement.TrustedFile(
          relativePath: path, sizeBytes: Int64(bytes.count),
          sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
      }
      return payloads
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
  }

  private func makeCoordinator(_ world: World) -> WhisperKitLegacyUpgradeCoordinator {
    let coordinator = WhisperKitLegacyUpgradeCoordinator(
      documentsDirectory: world.documents,
      appSupportDirectory: world.appSupport,
      variant: Self.variant,
      trustedFiles: world.files,
      isAdmitted: { world.admitted },
      ensureAvailable: {
        world.fetches += 1
        if world.holdFetch {
          await withCheckedContinuation { world.fetchRelease = $0 }
        }
        if world.admitOnFetch { world.admitted = true }
        return world.admitted
      },
      cancelActiveFetch: {
        world.cancelCalls += 1
        world.callOrder.append("cancelFetch")
        if world.holdCancel {
          await withCheckedContinuation { world.cancelRelease = $0 }
        }
        world.fetchRelease?.resume()
        world.fetchRelease = nil
      },
      isDeliveryEnabled: { world.deliveryEnabled })
    coordinator.onEvent = { world.events.append($0) }
    coordinator.unloadForRemoval = {
      world.unloadCalls += 1
      world.callOrder.append("unload")
    }
    coordinator.removeFromDelivery = {
      world.removeCalls += 1
      world.callOrder.append("remove")
      return world.removeSucceeds
    }
    return coordinator
  }

  // MARK: - The main path

  @Test func anExactCopyIsRetiredAndReplaced() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()

    await makeCoordinator(world).runLaunch()

    #expect(!FileManager.default.fileExists(atPath: world.foreignDirectory.path))
    #expect(world.fetches == 1)
    #expect(world.admitted)
    #expect(!FileManager.default.fileExists(atPath: world.markerURL.path), "marker clears on admit")
    #expect(world.events.contains(.legacyRetired))
    #expect(world.events.contains(.replacementCompleted))
  }

  @Test func noForeignCopyIsSilentAndDoesNothing() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    try FileManager.default.removeItem(at: world.foreignDirectory)

    await makeCoordinator(world).runLaunch()

    // The ~465 users who never had this model. A no-op event on every launch forever is not
    // telemetry, it is noise — and §2.1 makes "forever" literal.
    #expect(world.events.isEmpty)
    #expect(world.fetches == 0)
    #expect(!FileManager.default.fileExists(atPath: world.markerURL.path))
  }

  // MARK: - L3: nothing but a full-set match deletes

  @Test func aMismatchedCopyIsPreservedEntirelyAndFetchesNothing() async throws {
    let world = try World()
    defer { world.cleanUp() }
    let payloads = try world.stageForeignCopy()
    let victim = world.foreignDirectory.appendingPathComponent(
      "AudioEncoder.mlmodelc/analytics/coremldata.bin")
    try Data("someone else's bytes".utf8).write(to: victim)

    await makeCoordinator(world).runLaunch()

    // Every byte survives, including the files that DID match: a partial match is not our
    // artifact, and refusing to delete is a separate decision from refusing to serve.
    for (relativePath, bytes) in payloads where relativePath != victim.lastPathComponent {
      let url = world.foreignDirectory.appendingPathComponent(relativePath)
      if relativePath.hasSuffix("TextDecoder.mlmodelc/coremldata.bin") {
        #expect(try Data(contentsOf: url) == bytes, "a matching sibling must survive too")
      }
    }
    #expect(try Data(contentsOf: victim) == Data("someone else's bytes".utf8))
    #expect(world.fetches == 0, "we refuse to delete; we do not then download over the top")
    #expect(!FileManager.default.fileExists(atPath: world.markerURL.path))
    #expect(world.events.contains(.legacyRetirementRefused(reason: .mismatch)))
  }

  // MARK: - L4: the declined record

  @Test func aDeclinedCopyIsNeverRehashedWhileItIsUnchanged() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    try Data("not ours".utf8).write(
      to: world.foreignDirectory.appendingPathComponent("TextDecoder.mlmodelc/coremldata.bin"))

    var hashes = 0
    func countingHash(_ url: URL) async throws -> String {
      hashes += 1
      return try await LegacyRetirement.streamingSHA256(of: url)
    }

    let first = WhisperKitLegacyUpgradeCoordinator(
      documentsDirectory: world.documents, appSupportDirectory: world.appSupport,
      variant: Self.variant, trustedFiles: world.files,
      isAdmitted: { world.admitted },
      ensureAvailable: {
        world.fetches += 1
        return false
      },
      cancelActiveFetch: {}, isDeliveryEnabled: { true }, hashFile: countingHash)
    await first.runLaunch()
    let afterFirst = hashes
    #expect(afterFirst > 0, "the first pass must actually hash")
    #expect(FileManager.default.fileExists(atPath: world.declinedURL.path))

    let second = WhisperKitLegacyUpgradeCoordinator(
      documentsDirectory: world.documents, appSupportDirectory: world.appSupport,
      variant: Self.variant, trustedFiles: world.files,
      isAdmitted: { world.admitted },
      ensureAvailable: {
        world.fetches += 1
        return false
      },
      cancelActiveFetch: {}, isDeliveryEnabled: { true }, hashFile: countingHash)
    await second.runLaunch()

    // This is the forever-cost guard: §2.1 makes this run on every launch for the life of the
    // app, and re-hashing 1.6 GB each time to re-derive a refusal we already made is the whole
    // reason the record exists.
    #expect(hashes == afterFirst, "an unchanged declined copy must never be rehashed")
  }

  @Test func aRepairedCopyIsReExaminedRatherThanRefusedForever() async throws {
    let world = try World()
    defer { world.cleanUp() }
    let payloads = try world.stageForeignCopy()
    let path = "TextDecoder.mlmodelc/coremldata.bin"
    let url = world.foreignDirectory.appendingPathComponent(path)
    try Data("not ours".utf8).write(to: url)

    await makeCoordinator(world).runLaunch()
    #expect(world.events.contains(.legacyRetirementRefused(reason: .mismatch)))
    #expect(world.fetches == 0)

    // The user repairs their copy. A bare "declined" flag would refuse them for as long as the
    // app exists; the identity record notices the bytes changed and looks again.
    try payloads[path]!.write(to: url)
    world.events.removeAll()
    await makeCoordinator(world).runLaunch()

    #expect(!FileManager.default.fileExists(atPath: world.foreignDirectory.path))
    #expect(world.fetches == 1)
    #expect(world.events.contains(.legacyRetired))
  }

  // MARK: - L2/L3: the marker

  @Test func aMarkerSurvivesAFailedFetchAndReplaysOnTheNextLaunch() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    world.admitOnFetch = false

    await makeCoordinator(world).runLaunch()

    // The plane case: bytes gone, network dead. We owe them a model and the marker says so.
    #expect(!FileManager.default.fileExists(atPath: world.foreignDirectory.path))
    #expect(FileManager.default.fileExists(atPath: world.markerURL.path))
    #expect(world.fetches == 1)

    world.admitOnFetch = true
    await makeCoordinator(world).runLaunch()

    #expect(world.fetches == 2, "the next launch replays what we owe")
    #expect(world.admitted)
    #expect(!FileManager.default.fileExists(atPath: world.markerURL.path))
  }

  @Test func aMarkerBeatsAPartiallyDeletedForeignTree() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()

    // Crash mid-delete: one file gone, one left, marker written. This is the wedge that killed
    // an earlier draft — the survivor re-reads as `.mismatch`, so a fingerprint-first design
    // refuses, the marker is never cleared, and the user is stranded with no model and no
    // replay, forever. The marker has to win.
    try FileManager.default.createDirectory(
      at: world.markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: world.markerURL)
    try FileManager.default.removeItem(
      at: world.foreignDirectory.appendingPathComponent("TextDecoder.mlmodelc/coremldata.bin"))

    await makeCoordinator(world).runLaunch()

    #expect(world.fetches == 1, "a marker-owed replay reaches the fetch from ANY foreign state")
    #expect(world.admitted)
    #expect(!FileManager.default.fileExists(atPath: world.markerURL.path))
  }

  @Test func aMarkerReplaysEvenWhenTheForeignTreeIsEntirelyGone() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    try FileManager.default.createDirectory(
      at: world.markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: world.markerURL)
    try FileManager.default.removeItem(at: world.foreignDirectory)

    await makeCoordinator(world).runLaunch()

    #expect(world.fetches == 1)
    #expect(!FileManager.default.fileExists(atPath: world.markerURL.path))
  }

  // MARK: - L1: Cancel

  @Test func cancelClearsTheMarkerSoNoLaterLaunchAutoRefetches() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    world.admitOnFetch = false
    let coordinator = makeCoordinator(world)
    await coordinator.runLaunch()
    #expect(FileManager.default.fileExists(atPath: world.markerURL.path))

    try await coordinator.cancel()

    // An explicit Cancel is a DECLINE, not an interruption: the user said stop, so no later
    // launch may quietly finish the job on their behalf (contract §5b, `:179`).
    #expect(!FileManager.default.fileExists(atPath: world.markerURL.path))

    let fetchesBefore = world.fetches
    await makeCoordinator(world).runLaunch()
    #expect(world.fetches == fetchesBefore, "a declined replacement never auto-refetches")
  }

  @Test func aFailedMarkerClearRefusesTheWholeCancel() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    world.admitOnFetch = false
    let coordinator = makeCoordinator(world)
    await coordinator.runLaunch()

    // Make the clear fail: the marker's directory becomes unwritable.
    let directory = world.markerURL.deletingLastPathComponent()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }

    var threw = false
    do { try await coordinator.cancel() } catch { threw = true }

    // L1: nothing may be superseded until the marker is provably gone. Bumping first would
    // strand a fetch that can still admit while its completion is forbidden from clearing.
    #expect(threw, "a Cancel that cannot clear the marker must refuse, not proceed")
    #expect(FileManager.default.fileExists(atPath: world.markerURL.path))
  }

  // MARK: - L5: one fetch per identity

  @Test func aDownloadDuringAnInFlightLaunchJoinsItRatherThanFetchingTwice() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    let coordinator = makeCoordinator(world)

    async let launch: Void = coordinator.runLaunch()
    async let download: Void = coordinator.download()
    _ = await (launch, download)

    // Two fetches of one identity is the single-writer violation this epic exists to delete.
    #expect(world.fetches == 1, "Download joins the in-flight command; it never starts a second")
    #expect(world.admitted)
  }

  // MARK: - Scope

  @Test func siblingVariantsAndUnlistedFilesAreNeverTouched() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()

    // The founder's own disk carries four variants; only the pinned one is ours to retire.
    let cacheRoot = world.foreignDirectory.deletingLastPathComponent()
    let sibling = cacheRoot.appendingPathComponent("openai_whisper-small_216MB", isDirectory: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    try Data("another variant".utf8).write(to: sibling.appendingPathComponent("model.bin"))

    // An unlisted file inside OUR variant dir is still not ours to delete.
    let unlisted = world.foreignDirectory.appendingPathComponent("README.md")
    try Data("not in the manifest".utf8).write(to: unlisted)

    await makeCoordinator(world).runLaunch()

    #expect(
      FileManager.default.fileExists(atPath: sibling.appendingPathComponent("model.bin").path))
    #expect(FileManager.default.fileExists(atPath: unlisted.path), "unlisted files survive")
    #expect(
      FileManager.default.fileExists(atPath: cacheRoot.path),
      "argmaxinc/ is never removed")
    #expect(world.events.contains(.legacyRetired))
  }

  // MARK: - The kill switch (Codex 2b-r1 P1)

  @Test func aDisabledKillSwitchRefusesTheWholeRunBeforeAnyDiskMutation() async throws {
    let world = try World()
    defer { world.cleanUp() }
    let payloads = try world.stageForeignCopy()
    world.deliveryEnabled = false

    await makeCoordinator(world).runLaunch()

    // Rollback case: switch off means NOTHING happened — every legacy byte intact,
    // no marker, no declined record, no fetch, no event. Deleting and then refusing
    // the refetch would strand the user with neither model.
    for relativePath in payloads.keys {
      #expect(
        FileManager.default.fileExists(
          atPath: world.foreignDirectory.appendingPathComponent(relativePath).path),
        "legacy file untouched: \(relativePath)")
    }
    #expect(!FileManager.default.fileExists(atPath: world.markerURL.path))
    #expect(!FileManager.default.fileExists(atPath: world.declinedURL.path))
    #expect(world.fetches == 0)
    #expect(world.events.isEmpty)
  }

  @Test func aDisabledKillSwitchPreservesAnOwedMarkerForAFutureLaunch() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    world.admitOnFetch = false
    await makeCoordinator(world).runLaunch()
    #expect(FileManager.default.fileExists(atPath: world.markerURL.path), "debt recorded")

    world.deliveryEnabled = false
    await makeCoordinator(world).runLaunch()

    // The debt is neither paid nor forgiven while the switch is off.
    #expect(FileManager.default.fileExists(atPath: world.markerURL.path))
    #expect(world.fetches == 1, "no fetch attempt while disabled")

    world.deliveryEnabled = true
    world.admitOnFetch = true
    await makeCoordinator(world).runLaunch()

    #expect(world.fetches == 2, "a re-enabled launch replays the owed fetch")
    #expect(!FileManager.default.fileExists(atPath: world.markerURL.path))
  }

  // MARK: - Cancel vs Download (Codex 2b-r3 P1)

  @Test func aCancelDuringTheJoinedLaunchWorkDoesNotRestartTheFetch() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    world.admitOnFetch = false
    world.holdFetch = true
    let coordinator = makeCoordinator(world)

    let downloadTask = Task { await coordinator.download() }
    // Signal, not clock: the parked fetch IS the "mid-download" state.
    while world.fetches == 0 { await Task.yield() }
    try await coordinator.cancel()
    await downloadTask.value

    // Without the generation guard, download() falls through its admission
    // re-check after the cancelled join and immediately starts fetch #2 —
    // restarting the multi-GB download the user just cancelled.
    #expect(world.fetches == 1, "the cancelled Download must not fall through to a second fetch")
    #expect(!FileManager.default.fileExists(atPath: world.markerURL.path), "cancel cleared the debt")
  }

  @Test func aDownloadDuringTheCancelDrainWaitsItOutThenFetchesFresh() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    world.admitOnFetch = false
    world.holdFetch = true
    world.holdCancel = true
    let coordinator = makeCoordinator(world)

    // A launch refetch is mid-flight (parked)...
    let launchTask = Task { await coordinator.runLaunch() }
    while world.fetches == 0 { await Task.yield() }

    // ...the user cancels; the drain parks inside cancelActiveFetch...
    let cancelTask = Task { try await coordinator.cancel() }
    while world.cancelCalls == 0 { await Task.yield() }

    // ...and presses Download while the drain is STILL running. L5: it must
    // JOIN the drain, not race the controller cancellation (Codex 2b-r4 P2) —
    // racing could join the dying fetch and end with nothing started.
    let downloadTask = Task { await coordinator.download() }
    for _ in 0..<20 { await Task.yield() }
    #expect(world.fetches == 1, "no new fetch may start while the drain holds the slot")

    world.holdFetch = false  // the honored Download's own fetch must not park
    world.cancelRelease?.resume()
    world.cancelRelease = nil
    try await cancelTask.value
    await downloadTask.value
    await launchTask.value

    // After the drain settles, the queued Download runs its OWN fresh attempt
    // (the cancelled fetch stays failed — admitOnFetch is false throughout, so
    // a rising fetch count is attributable only to the honored Download).
    #expect(world.fetches == 2, "the Download pressed mid-drain is honored afterwards")
    #expect(world.admitted == false)
  }

  // MARK: - 2c: Remove (L1 order, L5 rows)

  @Test func removeRunsL1VerbatimAndReportsRemoved() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    world.admitOnFetch = false
    let coordinator = makeCoordinator(world)
    await coordinator.runLaunch()  // leaves an owed marker (fetch failed)
    world.callOrder.removeAll()

    let outcome = await coordinator.remove()

    #expect(outcome == .removed)
    #expect(!FileManager.default.fileExists(atPath: world.markerURL.path), "marker cleared FIRST")
    // L1: controller drain precedes unload precedes deletion.
    #expect(world.callOrder == ["cancelFetch", "unload", "remove"],
      "L1 order violated: \(world.callOrder)")
  }

  @Test func aFailedMarkerClearRefusesTheWholeRemove() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    world.admitOnFetch = false
    let coordinator = makeCoordinator(world)
    await coordinator.runLaunch()

    let directory = world.markerURL.deletingLastPathComponent()
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: directory.path)
    }
    let fetchesBefore = world.fetches

    let outcome = await coordinator.remove()

    // Each of L1's no-clauses, positively: refused outcome, marker intact,
    // no drain, no unload, no deletion, no new fetch.
    #expect(outcome == .refusedMarkerClear)
    #expect(FileManager.default.fileExists(atPath: world.markerURL.path))
    #expect(world.unloadCalls == 0)
    #expect(world.removeCalls == 0)
    #expect(world.fetches == fetchesBefore)
  }

  @Test func duplicateRemoveJoinsAndDeletesOnce() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    world.admitOnFetch = false
    world.holdCancel = true  // parks the remove drain inside cancelActiveFetch
    let coordinator = makeCoordinator(world)
    await coordinator.runLaunch()

    let first = Task { await coordinator.remove() }
    while world.cancelCalls == 0 { await Task.yield() }
    let second = Task { await coordinator.remove() }
    for _ in 0..<20 { await Task.yield() }
    world.holdCancel = false
    world.cancelRelease?.resume()
    world.cancelRelease = nil

    let o1 = await first.value
    let o2 = await second.value
    #expect(o1 == .removed)
    #expect(o2 == .removed, "the join reads the world: model is gone")
    #expect(world.removeCalls == 1, "one deletion, not two")
    #expect(world.unloadCalls == 1)
  }

  @Test func cancelDuringRemoveJoinsAndCannotUndoTheDeletion() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    world.admitOnFetch = false
    world.holdCancel = true
    let coordinator = makeCoordinator(world)
    await coordinator.runLaunch()

    let removeTask = Task { await coordinator.remove() }
    while world.cancelCalls == 0 { await Task.yield() }
    let cancelTask = Task { try await coordinator.cancel() }
    for _ in 0..<20 { await Task.yield() }
    world.holdCancel = false
    world.cancelRelease?.resume()
    world.cancelRelease = nil

    let outcome = await removeTask.value
    try await cancelTask.value

    #expect(outcome == .removed, "a joined Cancel cannot undo the accepted deletion")
    #expect(world.removeCalls == 1)
    #expect(world.cancelCalls == 1, "Cancel joined; it did not run its own drain")
  }

  @Test func duplicateRemoveJoinersReceiveTheDrainsRealOutcomeOnFailure() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    world.admitOnFetch = false
    world.removeSucceeds = false  // deletion fails AFTER marker clear
    world.holdCancel = true
    let coordinator = makeCoordinator(world)
    await coordinator.runLaunch()

    let first = Task { await coordinator.remove() }
    while world.cancelCalls == 0 { await Task.yield() }
    let second = Task { await coordinator.remove() }
    for _ in 0..<20 { await Task.yield() }
    world.holdCancel = false
    world.cancelRelease?.resume()
    world.cancelRelease = nil

    // Codex 2c-r1 P2: the joiner must get the drain's OWN verdict — a
    // world-read here would say "not admitted, so removed" while bytes remain.
    let o1 = await first.value
    let o2 = await second.value
    #expect(o1 == .failed)
    #expect(o2 == .failed, "the joiner reports the real failure, not a success")
  }

  @Test func aFailedDeliveryDeletionReportsFailed() async throws {
    let world = try World()
    defer { world.cleanUp() }
    try world.stageForeignCopy()
    world.admitOnFetch = false
    world.removeSucceeds = false
    let coordinator = makeCoordinator(world)
    await coordinator.runLaunch()

    let outcome = await coordinator.remove()
    #expect(outcome == .failed)
    #expect(world.unloadCalls == 1, "the unload ran; only the deletion failed")
  }
}
