import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprModelDelivery

/// The two behaviours #2109 depends on that a pure-value test cannot reach:
/// the cold-launch SEED (without which the paused-upgrade state is unreachable
/// in production) and the runtime's download GUARD (without which Resume is a
/// button that silently does nothing).
@MainActor
@Suite struct EGOneSeedAndResumeTests {

  private func makeDirs() throws -> (install: URL, metadata: URL, cleanup: () -> Void) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("eg1-seed-\(UUID().uuidString)", isDirectory: true)
    let install = root.appendingPathComponent("Models/eg-1", isDirectory: true)
    let metadata = root.appendingPathComponent("ModelDelivery", isDirectory: true)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    return (install, metadata, { try? FileManager.default.removeItem(at: root) })
  }

  /// A prior revision that was admitted AND whose bytes survive — the exact
  /// precondition `supersededInstallSurvives` requires.
  private func seedSurvivingOlderRevision(_ registration: DeliveryRegistration) throws {
    let identity = registration.manifest.identity
    let key = "\(identity.family.rawValue)-\(identity.name)-v1-legacy-\(identity.variant)"
    let name = "eg-1-v1-legacy.gguf"
    let installed = registration.installDirectory.appendingPathComponent(name)
    try Data([0xAB, 0xCD]).write(to: installed)
    let attrs = try FileManager.default.attributesOfItem(atPath: installed.path)
    let marker: [String: Any] = [
      "manifestDigest": "older-digest", "admittedAt": 0,
      "files": [
        [
          "path": name,
          "sizeBytes": attrs[.size] as? Int64 ?? 2,
          "mtime": (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
        ]
      ],
    ]
    try JSONSerialization.data(withJSONObject: marker).write(
      to: registration.metadataDirectory.appendingPathComponent("\(key).admission.json"))
  }

  /// Collects everything the adapter publishes, so the SEED is observable.
  private final class Published: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [EGOneInstallState] = []
    func append(_ s: EGOneInstallState) {
      lock.lock()
      states.append(s)
      lock.unlock()
    }
    var all: [EGOneInstallState] {
      lock.lock()
      defer { lock.unlock() }
      return states
    }
  }

  /// THE cold-launch case, and the reason seed-before-observe exists.
  ///
  /// `addStateObserver` replays only identities the controller already knows,
  /// and a user sitting on a prior revision with no fetch in flight has no
  /// entry — so the observer never fires for them. The old seed was gated on
  /// `isAdmitted`, which is false for exactly that user. Neither path
  /// published anything, so the row kept its initial `.notInstalled` and the
  /// paused-upgrade state was unreachable at the only moment it matters.
  @Test func coldLaunchWithASurvivingOlderRevisionSeedsUpdatePaused() async throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }
    let registration = try EGOneDeliveryAdapterMappingTests.shardedFixtureRegistration(
      install: dirs.install, metadata: dirs.metadata)
    try seedSurvivingOlderRevision(registration)

    let suite = "eg1-seed-\(UUID().uuidString)"
    let adapter = EGOneDeliveryAdapter(
      controller: ModelDeliveryController(defaults: UserDefaults(suiteName: suite)!),
      registration: registration, version: "1.1",
      defaults: UserDefaults(suiteName: suite)!)

    let published = Published()
    adapter.observeInstallState { published.append($0) }

    let seeded = await withDeadline(seconds: 5) {
      while true {
        if let first = await MainActor.run(body: { published.all.first }) { return first }
        await Task.yield()
      }
    }
    #expect(
      seeded == .updatePaused(resumable: false),
      "a cold launch owing an upgrade must seed updatePaused, not notInstalled")
  }

  /// Two-way control on the seed: with nothing on disk the same path must
  /// still produce `notInstalled`. Without this, a seed hard-coded to
  /// `updatePaused` would pass the test above and show every new user a
  /// paused-upgrade row for a model they never had.
  @Test func coldLaunchWithNothingOnDiskSeedsNotInstalled() async throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }
    let registration = try EGOneDeliveryAdapterMappingTests.shardedFixtureRegistration(
      install: dirs.install, metadata: dirs.metadata)

    let suite = "eg1-seed-\(UUID().uuidString)"
    let adapter = EGOneDeliveryAdapter(
      controller: ModelDeliveryController(defaults: UserDefaults(suiteName: suite)!),
      registration: registration, version: "1.1",
      defaults: UserDefaults(suiteName: suite)!)

    let published = Published()
    adapter.observeInstallState { published.append($0) }

    let seeded = await withDeadline(seconds: 5) {
      while true {
        if let first = await MainActor.run(body: { published.all.first }) { return first }
        await Task.yield()
      }
    }
    #expect(seeded == .notInstalled)
  }

  // MARK: - The download guard, through the real runtime (#2109)

  /// The dead-button case, driven through a REAL `EGOneRuntime` rather than
  /// the enum property, because the property proves the RULE while this proves
  /// the runtime actually consults it. A state missing from `startDownload`'s
  /// guard renders its button and silently ignores the press: no crash, no
  /// error, no compiler complaint, and to a user indistinguishable from the
  /// app ignoring them.
  ///
  /// Staged partials with no admission marker make the seed publish `.paused`,
  /// which is the state under test. Pressing then has to MOVE the state — with
  /// no server binary and an unreachable source the attempt fails fast, and a
  /// failure is proof the guard was passed. A swallowed press would leave the
  /// row sitting in `.paused` forever, which is the bug.
  @Test func startDownloadActsWhenPaused() async throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }
    let registration = try EGOneDeliveryAdapterMappingTests.shardedFixtureRegistration(
      install: dirs.install, metadata: dirs.metadata)

    // Partials, no marker → `.paused`.
    let staging = ModelDeliveryController.stagingDirectoryURL(for: registration)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try Data([0x01, 0x02, 0x03]).write(to: staging.appendingPathComponent("partial.bin"))

    let suite = "eg1-guard-\(UUID().uuidString)"
    let store = try #require(UserDefaults(suiteName: suite))
    let adapter = EGOneDeliveryAdapter(
      controller: ModelDeliveryController(defaults: UserDefaults(suiteName: suite)!),
      registration: registration, version: "1.1", defaults: store)
    let runtime = EGOneRuntime(
      manifest: EGOneManifest(
        modelName: LLMProvider.egOneModelName, version: "v2-sharded", contextTokens: 4096,
        promptTemplateID: "eg1-v1", minAppVersion: "0",
        downloadURL: URL(string: "https://example.invalid/eg1.gguf")!,
        displayVersion: "1.1"),
      serverBinaryURL: nil, delivery: adapter)
    defer { store.removePersistentDomain(forName: suite) }

    let reachedPaused = await withDeadline(seconds: 5) {
      while true {
        if await MainActor.run(body: { runtime.installState == .paused }) { return true }
        await Task.yield()
      }
    }
    try #require(reachedPaused == true, "fixture did not produce the paused state under test")

    runtime.startDownload()

    let moved = await withDeadline(seconds: 10) {
      while true {
        if await MainActor.run(body: { runtime.installState != .paused }) { return true }
        await Task.yield()
      }
    }
    #expect(
      moved == true,
      "pressing Resume while paused did nothing — the guard swallowed the press")
  }

  /// The upgrade doors, through the real runtime. `.paused` above covers the
  /// first-install door; these cover the two the founder directives are
  /// actually about — a user with a working older model who is being asked to
  /// finish or resume an upgrade. Each is a separate door and each could be
  /// dropped from the guard independently.
  @Test(arguments: [true, false])
  func startDownloadActsOnBothUpdatePausedVariants(_ resumable: Bool) async throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }
    let registration = try EGOneDeliveryAdapterMappingTests.shardedFixtureRegistration(
      install: dirs.install, metadata: dirs.metadata)
    try seedSurvivingOlderRevision(registration)
    if resumable {
      let staging = ModelDeliveryController.stagingDirectoryURL(for: registration)
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      try Data([0x01]).write(to: staging.appendingPathComponent("partial.bin"))
    }

    let suite = "eg1-guard-\(UUID().uuidString)"
    let store = try #require(UserDefaults(suiteName: suite))
    defer { store.removePersistentDomain(forName: suite) }
    let adapter = EGOneDeliveryAdapter(
      controller: ModelDeliveryController(defaults: UserDefaults(suiteName: suite)!),
      registration: registration, version: "1.1", defaults: store)
    let runtime = EGOneRuntime(
      manifest: runtimeManifest(), serverBinaryURL: nil, delivery: adapter)

    let expected = EGOneInstallState.updatePaused(resumable: resumable)
    let reached = await withDeadline(seconds: 5) {
      while true {
        if await MainActor.run(body: { runtime.installState == expected }) { return true }
        await Task.yield()
      }
    }
    try #require(reached == true, "fixture did not produce \(expected)")

    runtime.startDownload()

    let moved = await withDeadline(seconds: 10) {
      while true {
        if await MainActor.run(body: { runtime.installState != expected }) { return true }
        await Task.yield()
      }
    }
    #expect(moved == true, "\(expected): the press was swallowed by the guard")
  }

  /// The other half of the seed contract: a CURRENT admitted cache must still
  /// seed `installed`. Without this, a seed rewritten to always consult disk
  /// predicates would show a paused-upgrade row to a user whose model is
  /// perfectly current — the inverse of the bug and equally wrong.
  @Test func coldLaunchWithTheCurrentRevisionAdmittedSeedsInstalled() async throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }
    let registration = try EGOneDeliveryAdapterMappingTests.shardedFixtureRegistration(
      install: dirs.install, metadata: dirs.metadata)

    // Real bytes matching the fixture manifest, then admit them in place.
    for file in registration.manifest.files {
      let url = registration.installDirectory.appendingPathComponent(file.resolvedInstallPath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(count: Int(file.sizeBytes)).write(to: url)
    }
    let suite = "eg1-seed-\(UUID().uuidString)"
    let store = try #require(UserDefaults(suiteName: suite))
    defer { store.removePersistentDomain(forName: suite) }
    let controller = ModelDeliveryController(defaults: UserDefaults(suiteName: suite)!)
    let admitted = await controller.admitIfComplete(registration)
    try #require(admitted == true, "fixture cache was not admitted, so the test proves nothing")

    let adapter = EGOneDeliveryAdapter(
      controller: controller, registration: registration, version: "1.1", defaults: store)
    let published = Published()
    adapter.observeInstallState { published.append($0) }

    let seeded = await withDeadline(seconds: 5) {
      while true {
        if let first = await MainActor.run(body: { published.all.first }) { return first }
        await Task.yield()
      }
    }
    #expect(seeded == .installed(version: "1.1"))
  }

  private func runtimeManifest() -> EGOneManifest {
    EGOneManifest(
      modelName: LLMProvider.egOneModelName, version: "v2-sharded", contextTokens: 4096,
      promptTemplateID: "eg1-v1", minAppVersion: "0",
      downloadURL: URL(string: "https://example.invalid/eg1.gguf")!, displayVersion: "1.1")
  }

  /// Live truth must defeat the earlier disk seed. This is the ordering half
  /// of seed-before-observe: the seed publishes a GUESS derived from disk, and
  /// if it could outrank a real in-flight state the row would show a paused
  /// upgrade over a download that is actively running.
  ///
  /// Deterministic via the barrier C2 already added — no new production seam.
  /// The attempt is parked after `.preparing` publishes, so an entry provably
  /// exists in the controller when `observeInstallState` attaches, which is
  /// the condition that cannot otherwise be constructed without racing a real
  /// fetch.
  @Test func liveStateOverridesTheDiskSeedOnAttach() async throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }
    let registration = try EGOneDeliveryAdapterMappingTests.shardedFixtureRegistration(
      install: dirs.install, metadata: dirs.metadata)

    let suite = "eg1-replay-\(UUID().uuidString)"
    let store = try #require(UserDefaults(suiteName: suite))
    defer { store.removePersistentDomain(forName: suite) }
    let controller = ModelDeliveryController(defaults: UserDefaults(suiteName: suite)!)

    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    await controller.setBeforeExistingCacheValidationForTesting {
      entered.continuation.yield()
      entered.continuation.finish()
      var iterator = release.stream.makeAsyncIterator()
      _ = await iterator.next()
    }

    async let attempt = controller.ensureModelAvailable(registration)

    let didEnter = await withDeadline(seconds: 5) {
      var iterator = entered.stream.makeAsyncIterator()
      return await iterator.next() != nil
    }
    try #require(didEnter == true, "the attempt never parked, so no live entry exists")

    let adapter = EGOneDeliveryAdapter(
      controller: controller, registration: registration, version: "1.1", defaults: store)
    let published = Published()
    adapter.observeInstallState { published.append($0) }

    // The seed lands first (disk says nothing installed), then the observer's
    // replay of the LIVE `.preparing` state must supersede it.
    let sawLive = await withDeadline(seconds: 5) {
      while true {
        if await MainActor.run(body: { published.all.last == .verifying }) { return true }
        await Task.yield()
      }
    }

    // Cancel BEFORE releasing so the parked attempt unwinds immediately.
    // Letting it run to completion instead means waiting on a real network
    // failure against an unreachable fixture host, which took 4.3 seconds
    // against a 5 second deadline elsewhere in this file — close enough to
    // read as an instrument fault to the next person, and slow for no
    // coverage. Every sibling test here runs in single-digit milliseconds.
    _ = await controller.cancel(registration.manifest.identity)
    release.continuation.yield()
    release.continuation.finish()
    _ = await attempt

    #expect(
      sawLive == true,
      "the disk seed outranked a live in-flight state; ordering is inverted")
    #expect(
      published.all.first == .notInstalled,
      "the seed should still have published first, just been superseded")
  }
}
