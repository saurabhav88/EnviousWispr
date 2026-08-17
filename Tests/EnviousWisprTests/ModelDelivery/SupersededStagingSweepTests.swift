import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// The sweep that reclaims abandoned partial downloads (#2109, #2119).
///
/// This is the only code in the change that DELETES bytes from a user's disk,
/// so every test here is paired: one asserting something is removed, one
/// asserting something adjacent survives. A sweep that deleted nothing and a
/// sweep that deleted everything both pass a one-sided suite.
@Suite struct SupersededStagingSweepTests {
  init() {
    // Deterministic network, matching the sibling controller suite. Without
    // it the rollback test makes REAL connection attempts to the unreachable
    // fixture hosts and the suite takes ~9.6s instead of milliseconds — slow
    // for no coverage, and dependent on the machine's DNS behaviour.
    ChunkAppendDelegate.protocolClassesForTesting = [DeliveryStubProtocol.self]
  }

  private func makeDirs() throws -> (install: URL, metadata: URL, cleanup: () -> Void) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("sweep-\(UUID().uuidString)", isDirectory: true)
    let install = root.appendingPathComponent("install", isDirectory: true)
    let metadata = root.appendingPathComponent("metadata", isDirectory: true)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    return (install, metadata, { try? FileManager.default.removeItem(at: root) })
  }

  /// A staging directory with real bytes in it, named by an explicit cache key.
  @discardableResult
  private func seedStaging(_ metadata: URL, key: String) throws -> URL {
    let dir =
      metadata
      .appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(key, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data([0x01, 0x02, 0x03]).write(to: dir.appendingPathComponent("partial.bin"))
    return dir
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  private func identity(
    family: ModelFamily = .egOne, name: String = "eg-1",
    revision: String, variant: String = "q5km"
  ) -> ModelIdentity {
    ModelIdentity(
      family: family, name: name, revision: revision, variant: variant, runtimeABI: "abi")
  }

  // MARK: - Identification

  /// The core pair. A superseded revision is found; the CURRENT one never is.
  /// Deleting the current revision's staging would destroy exactly the
  /// partials that make Resume work.
  @Test func findsSupersededRevisionsAndNeverTheCurrentOne() throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }
    let current = identity(revision: "v3-eg2")

    try seedStaging(dirs.metadata, key: "eg_one-eg-1-v2-sharded-q5km")
    try seedStaging(dirs.metadata, key: current.cacheKey)

    let found = PriorRevisionAdmission.supersededStagingURLs(
      for: current, metadataDirectory: dirs.metadata)

    #expect(found.count == 1)
    #expect(found.first?.lastPathComponent == "eg_one-eg-1-v2-sharded-q5km")
  }

  /// A different FAMILY sharing the metadata directory must be untouched. All
  /// engines share one `staging/` root, so a sweep run for EG-1 that matched
  /// loosely would delete Parakeet's or WhisperKit's work.
  @Test func ignoresOtherFamiliesInTheSharedStagingRoot() throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }

    try seedStaging(dirs.metadata, key: "parakeet-parakeet-tdt-0.6b-v3-coreml-abc123-int8")
    try seedStaging(
      dirs.metadata, key: "whisper_kit-whisperkit-coreml-def456-openai_whisper-small_216MB")

    let found = PriorRevisionAdmission.supersededStagingURLs(
      for: identity(revision: "v3-eg2"), metadataDirectory: dirs.metadata)

    #expect(found.isEmpty, "an EG-1 sweep must not see other families")
  }

  /// THE case that nearly shipped wrong. WhisperKit stable and Preview share
  /// family, name AND revision, and differ only by variant. A sweep for one
  /// must never see the other, or it deletes a live download.
  @Test func neverMatchesADifferentVariantOfTheSameModel() throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }

    let stable = identity(
      family: .whisperKit, name: "whisperkit-coreml", revision: "aaa",
      variant: "openai_whisper-large-v3-v20240930_turbo")
    let previewKey = "whisper_kit-whisperkit-coreml-aaa-openai_whisper-small_216MB"
    try seedStaging(dirs.metadata, key: previewKey)

    let found = PriorRevisionAdmission.supersededStagingURLs(
      for: stable, metadataDirectory: dirs.metadata)

    #expect(
      found.isEmpty, "Preview differs only by variant and is a LIVE model, not a superseded one")
  }

  /// The hyphen-ambiguous real key, which is why the revision cannot be
  /// recovered by splitting on `-`.
  @Test func handlesTheHyphenAmbiguousShippedKey() throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }

    try seedStaging(dirs.metadata, key: "eg_one-eg-1-v2-sharded-q5km")
    let found = PriorRevisionAdmission.supersededStagingURLs(
      for: identity(revision: "v3-eg2"), metadataDirectory: dirs.metadata)

    #expect(
      found.count == 1, "both name and revision contain hyphens; prefix/suffix must still work")
  }

  /// An unreadable or absent staging root yields nothing, so the caller
  /// deletes nothing. "I could not look" must never mean "delete freely".
  @Test func anAbsentStagingRootFindsNothing() throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }
    let found = PriorRevisionAdmission.supersededStagingURLs(
      for: identity(revision: "v3-eg2"), metadataDirectory: dirs.metadata)
    #expect(found.isEmpty)
  }

  // MARK: - Deletion, through the real controller

  private func makeRegistration(
    _ metadata: URL, install: URL, revision: String, variant: String = "q5km"
  ) throws -> DeliveryRegistration {
    // The fixture exposes identity through `mutate`, not a parameter, so the
    // EG-1 shape used throughout these tests is set there.
    let manifest = try DeliveryManifest.load(
      from: ManifestFixture.manifestJSON(
        files: ManifestFixture.smallFiles,
        sources: [["id": "our_copy", "baseURL": "https://sweep.invalid.example/"]],
        family: "eg_one",
        mutate: { object in
          object["identity"] = [
            "family": "eg_one", "name": "eg-1", "revision": revision, "variant": variant,
            "runtimeABI": "abi",
          ]
        }))
    return DeliveryRegistration(
      manifest: manifest, installDirectory: install, metadataDirectory: metadata)
  }

  /// THE reclamation, end to end: a superseded directory is actually removed
  /// from disk while the current revision's partials survive. Both halves in
  /// one test, because a sweep that deletes everything and one that deletes
  /// nothing each pass half of this.
  @Test func sweepRemovesSupersededStagingAndKeepsTheCurrent() async throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }
    let registration = try makeRegistration(
      dirs.metadata, install: dirs.install, revision: "v3-eg2")

    let superseded = try seedStaging(dirs.metadata, key: "eg_one-eg-1-v2-sharded-q5km")
    let current = try seedStaging(dirs.metadata, key: registration.manifest.identity.cacheKey)
    try #require(exists(superseded) && exists(current), "fixture did not stage both directories")

    let controller = ModelDeliveryController(
      defaults: UserDefaults(suiteName: "sweep-\(UUID().uuidString)")!,
      availableDiskBytes: { _ in .max })
    await controller.sweepSupersededStaging(registration)

    #expect(exists(superseded) == false, "the superseded revision's bytes were not reclaimed")
    #expect(
      exists(current) == true, "the current revision's partials were destroyed, breaking Resume")
  }

  /// Another family's staging in the SHARED root must survive an EG-1 sweep.
  /// All engines write under one `staging/`, so a loose match here deletes
  /// another engine's work.
  @Test func sweepLeavesOtherFamiliesAlone() async throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }
    let registration = try makeRegistration(
      dirs.metadata, install: dirs.install, revision: "v3-eg2")

    let parakeet = try seedStaging(
      dirs.metadata, key: "parakeet-parakeet-tdt-0.6b-v3-coreml-abc-int8")
    let preview = try seedStaging(
      dirs.metadata, key: "whisper_kit-whisperkit-coreml-aaa-openai_whisper-small_216MB")
    let superseded = try seedStaging(dirs.metadata, key: "eg_one-eg-1-v2-sharded-q5km")

    let controller = ModelDeliveryController(
      defaults: UserDefaults(suiteName: "sweep-\(UUID().uuidString)")!,
      availableDiskBytes: { _ in .max })
    await controller.sweepSupersededStaging(registration)

    #expect(exists(superseded) == false, "the EG-1 sweep did not do its job")
    #expect(exists(parakeet) == true, "Parakeet's staging was deleted by an EG-1 sweep")
    #expect(exists(preview) == true, "WhisperKit Preview's staging was deleted by an EG-1 sweep")
  }

  /// Nothing to do must mean nothing done. A sweep with no superseded
  /// candidates must not touch the directory at all.
  @Test func sweepWithNothingSupersededIsANoOp() async throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }
    let registration = try makeRegistration(
      dirs.metadata, install: dirs.install, revision: "v3-eg2")
    let current = try seedStaging(dirs.metadata, key: registration.manifest.identity.cacheKey)

    let controller = ModelDeliveryController(
      defaults: UserDefaults(suiteName: "sweep-\(UUID().uuidString)")!,
      availableDiskBytes: { _ in .max })
    await controller.sweepSupersededStaging(registration)

    #expect(exists(current) == true)
  }

  // MARK: - Liveness protection

  /// THE test standing between a running download and deletion.
  ///
  /// A superseded-looking revision that is ACTUALLY BEING FETCHED right now
  /// must survive. This is reachable in production: a user on v1 starts the v2
  /// download, an app update ships pinning v3, and the launch sweep for v3 sees
  /// v2 as superseded while v2's fetch is still in flight.
  ///
  /// Deterministic via the barrier C2 added — the attempt is PARKED inside the
  /// validation window, so it provably has a live task when the sweep runs,
  /// with no race to lose.
  @Test func sweepNeverDeletesStagingForAnAttemptInFlight() async throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }

    let inFlight = try makeRegistration(
      dirs.metadata, install: dirs.install, revision: "v2-sharded")
    let current = try makeRegistration(dirs.metadata, install: dirs.install, revision: "v3-eg2")

    let inFlightStaging = try seedStaging(
      dirs.metadata, key: inFlight.manifest.identity.cacheKey)
    let deadStaging = try seedStaging(dirs.metadata, key: "eg_one-eg-1-v1-legacy-q5km")

    let controller = ModelDeliveryController(
      defaults: UserDefaults(suiteName: "sweep-\(UUID().uuidString)")!,
      availableDiskBytes: { _ in .max })

    // Park v2's attempt inside the validation window so it holds a live task.
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    await controller.setBeforeExistingCacheValidationForTesting {
      entered.continuation.yield()
      entered.continuation.finish()
      var iterator = release.stream.makeAsyncIterator()
      _ = await iterator.next()
    }
    async let attempt = controller.ensureModelAvailable(inFlight)

    let didEnter = await withDeadline(seconds: 5) {
      var iterator = entered.stream.makeAsyncIterator()
      return await iterator.next() != nil
    }
    try #require(didEnter == true, "v2's attempt never parked, so nothing is in flight")

    // Sweep for v3. v2 LOOKS superseded and is being fetched.
    await controller.sweepSupersededStaging(current)

    #expect(
      exists(inFlightStaging) == true,
      "the sweep deleted staging for a download that is actively running")
    #expect(
      exists(deadStaging) == false,
      "the sweep protected everything, so it is not doing its job")

    _ = await controller.cancel(inFlight.manifest.identity)
    release.continuation.yield()
    release.continuation.finish()
    _ = await attempt
  }

  /// The other half, and the reason entry-presence is not liveness: entries
  /// are RETAINED after their task completes. Keying protection on an entry
  /// existing would shield long-dead revisions forever and quietly turn the
  /// sweep into a no-op.
  @Test func aCompletedEntryDoesNotProtectItsStaging() async throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }

    let old = try makeRegistration(dirs.metadata, install: dirs.install, revision: "v2-sharded")
    let current = try makeRegistration(dirs.metadata, install: dirs.install, revision: "v3-eg2")
    let oldStaging = try seedStaging(dirs.metadata, key: old.manifest.identity.cacheKey)

    // Disk preflight rejects instantly, which is all this test needs: a
    // COMPLETED attempt leaving a retained entry with no live task. Running a
    // real fetch to completion instead cost ~3.8s of retry and failover for no
    // extra coverage — the entry is retained either way.
    let controller = ModelDeliveryController(
      defaults: UserDefaults(suiteName: "sweep-\(UUID().uuidString)")!,
      availableDiskBytes: { _ in 1 })

    _ = await controller.ensureModelAvailable(old)

    await controller.sweepSupersededStaging(current)

    #expect(
      exists(oldStaging) == false,
      "a retained entry with no live task protected staging, so the sweep never reclaims anything")
  }

  // MARK: - The four remaining plan controls

  /// A regular FILE whose name matches must survive. The sweep deletes
  /// whatever identification returns, so a name match alone must not
  /// authorise deletion — staging is always a directory.
  @Test func aMatchingRegularFileIsNeverTreatedAsStaging() throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }
    let staging = dirs.metadata.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

    // Same name a superseded staging directory would have, but a file.
    let impostor = staging.appendingPathComponent("eg_one-eg-1-v2-sharded-q5km")
    try Data([0xFF]).write(to: impostor)

    let found = PriorRevisionAdmission.supersededStagingURLs(
      for: identity(revision: "v3-eg2"), metadataDirectory: dirs.metadata)

    #expect(found.isEmpty, "a regular file matched the staging pattern and would have been deleted")
    #expect(exists(impostor), "the file was destroyed")
  }

  /// The REAL shipped pair, both directions, with their actual cache keys
  /// rather than synthetic ones. Stable and Preview differ only by variant and
  /// each must be invisible to the other's sweep.
  @Test func theShippedWhisperKitPairIsMutuallyInvisible() throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }

    // Loaded from the COMMITTED manifests, not copied literals: a literal
    // drifts silently the day either manifest is re-pinned, and this test
    // would then assert something about a pair we no longer ship.
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let resourceDir = repoRoot.appendingPathComponent("Sources/EnviousWispr/Resources")
    func shippedIdentity(_ resource: String) throws -> ModelIdentity {
      let url = resourceDir.appendingPathComponent("\(resource).json")
      return try DeliveryManifest.load(from: try Data(contentsOf: url)).identity
    }
    let stable = try shippedIdentity("whisperkit-delivery-manifest")
    let preview = try shippedIdentity("whisperkit-preview-delivery-manifest")
    // Equal REVISIONS is part of "differ only by variant" and is the half that
    // makes this pair dangerous: same family, same name, same revision means
    // only the variant separates them in the cache key.
    try #require(
      stable.family == preview.family && stable.name == preview.name
        && stable.revision == preview.revision && stable.variant != preview.variant,
      "the shipped pair no longer differs ONLY by variant, so this test no longer covers that case")

    try seedStaging(dirs.metadata, key: stable.cacheKey)
    try seedStaging(dirs.metadata, key: preview.cacheKey)

    #expect(
      PriorRevisionAdmission.supersededStagingURLs(
        for: stable, metadataDirectory: dirs.metadata
      ).isEmpty,
      "a stable sweep saw Preview's staging")
    #expect(
      PriorRevisionAdmission.supersededStagingURLs(
        for: preview, metadataDirectory: dirs.metadata
      ).isEmpty,
      "a Preview sweep saw stable's staging")
  }

  /// Same family, DIFFERENT name. The prefix technique is only sound while no
  /// name is a prefix of another, which `ShippedModelNames` freezes; this
  /// asserts the runtime half of that contract.
  @Test func adifferentNameInTheSameFamilySurvives() throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }

    let other = try seedStaging(dirs.metadata, key: "eg_one-other-model-v1-q5km")
    let superseded = try seedStaging(dirs.metadata, key: "eg_one-eg-1-v2-sharded-q5km")

    let found = PriorRevisionAdmission.supersededStagingURLs(
      for: identity(revision: "v3-eg2"), metadataDirectory: dirs.metadata)

    #expect(found.count == 1, "expected only eg-1's superseded revision")
    #expect(found.first?.lastPathComponent == "eg_one-eg-1-v2-sharded-q5km")
    #expect(exists(other), "a different model in the same family was matched")
  }

  /// A DRAINING attempt is protected too. `cancel` moves the task to
  /// `drainingTask` and it keeps writing until its URLSession delegate
  /// finishes; deleting underneath it is the same damage as deleting a live
  /// one. The sweep checks both fields and only `activeTask` was covered.
  @Test func sweepProtectsADrainingAttempt() async throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }

    let draining = try makeRegistration(
      dirs.metadata, install: dirs.install, revision: "v2-sharded")
    let current = try makeRegistration(dirs.metadata, install: dirs.install, revision: "v3-eg2")
    let drainingStaging = try seedStaging(dirs.metadata, key: draining.manifest.identity.cacheKey)

    let controller = ModelDeliveryController(
      defaults: UserDefaults(suiteName: "sweep-\(UUID().uuidString)")!,
      availableDiskBytes: { _ in .max })

    let entered = AsyncStream<Void>.makeStream()
    // THE PARK MUST SURVIVE CANCELLATION, and an `AsyncStream` iterator does
    // not (cloud-review P1 on the first version of this fix).
    //
    // `cancel` fires the draining signal and then IMMEDIATELY calls
    // `task.cancel()`. An attempt parked in `AsyncStream.Iterator.next()`
    // returns `nil` on cancellation, so it finishes, `await task.value`
    // returns, and `drainingTask` is cleared — possibly before this test's
    // waiter has reacquired the actor. That reintroduces the very
    // intermittency this change exists to remove, one mechanism over: version
    // one failed by STARVATION, this would fail by the window CLOSING early.
    //
    // `withCheckedContinuation` (non-throwing) is not cancellation-aware, so
    // the attempt stays parked until the test opens the gate explicitly. The
    // drain window is then held open BY CONSTRUCTION rather than by winning a
    // race.
    //
    // `sweepNeverDeletesStagingForAnAttemptInFlight` keeps the plain
    // `AsyncStream` park deliberately: it asserts BEFORE it cancels, so the
    // cancellation never closes a window it still needs.
    let gate = CancellationInsensitiveGate()
    await controller.setBeforeExistingCacheValidationForTesting {
      entered.continuation.yield()
      entered.continuation.finish()
      await gate.wait()
    }
    async let attempt = controller.ensureModelAvailable(draining)
    let didEnter = await withDeadline(seconds: 5) {
      var iterator = entered.stream.makeAsyncIterator()
      return await iterator.next() != nil
    }
    try #require(didEnter == true, "the attempt never parked")

    // `cancel` moves the task from `activeTask` to `drainingTask` and then
    // awaits the drain. A bare `Task.yield()` does NOT prove that move
    // happened, so the sweep could have been protected by `activeTask` and the
    // draining branch never exercised — the test would pass while covering the
    // wrong field. Park until the controller reports no active task for the
    // identity, which is only true once the move has landed.
    // WAIT ON THE SIGNAL, NOT ON A POLL.
    //
    // This used to spin on `isDrainingForTesting` with `Task.yield()`, which
    // STARVES the transition it waits for: every probe is a hop onto the
    // controller actor, so the loop keeps the controller answering "are you
    // draining yet" instead of draining. It passed locally and timed out on
    // post-merge main (fewer cores, more contention) — `movedToDraining` came
    // back nil and the test correctly reported the draining branch as untested.
    // The controller now announces the move at the instant it lands.
    let moved = AsyncStream<Void>.makeStream()
    await controller.setAfterMovedToDrainingForTesting {
      moved.continuation.yield()
      moved.continuation.finish()
    }
    async let cancelled = controller.cancel(draining.manifest.identity)
    let movedToDraining = await withDeadline(seconds: 5) {
      var iterator = moved.stream.makeAsyncIterator()
      return await iterator.next() != nil
    }
    try #require(
      movedToDraining == true,
      "never observed the LIVE draining window, so the draining branch is untested")

    // THE SIGNAL AND THE STATE ARE TWO CONDITIONS. The signal proves the move
    // HAPPENED; it does not prove the window is still OPEN when the sweep runs.
    // They coincide here only because the attempt is parked on `release` and so
    // cannot finish draining — assert it rather than rely on that reasoning,
    // because a future change to the park would silently turn this into a test
    // of the already-drained path while still passing.
    try #require(
      await controller.isDrainingForTesting(draining.manifest.identity),
      "the draining window closed before the sweep, so the protection is untested")

    await controller.sweepSupersededStaging(current)
    #expect(
      exists(drainingStaging),
      "the sweep deleted staging for an attempt that is still draining")

    // Open the gate only now — after the sweep has run against a window this
    // test held open deliberately.
    await gate.open()
    _ = await cancelled
    _ = await attempt

    // And once the drain COMPLETES, the protection must lift — otherwise a
    // cancelled-and-abandoned download is shielded for the process lifetime,
    // which is exactly the population #2119 exists to reclaim.
    await controller.sweepSupersededStaging(current)
    #expect(
      exists(drainingStaging) == false,
      "a finished drain still protected its staging, so an abandoned download is never reclaimed")
  }

  /// The accepted cost, asserted rather than assumed: after a superseded
  /// revision's staging is reclaimed, re-pinning it later must still SUCCEED
  /// by refetching. Deleting cache may cost bytes; it must never leave a
  /// revision uninstallable.
  @Test func aSweptRevisionCanStillBeFetchedAgain() async throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }

    let old = try makeRegistration(dirs.metadata, install: dirs.install, revision: "v2-sharded")
    let current = try makeRegistration(dirs.metadata, install: dirs.install, revision: "v3-eg2")
    let oldStaging = try seedStaging(dirs.metadata, key: old.manifest.identity.cacheKey)

    let controller = ModelDeliveryController(
      defaults: UserDefaults(suiteName: "sweep-\(UUID().uuidString)")!,
      availableDiskBytes: { _ in .max })
    await controller.sweepSupersededStaging(current)
    try #require(
      exists(oldStaging) == false, "the sweep did not reclaim it, so this proves nothing")

    // Prove it ADMITS, not merely that it fails in a tolerable way. Accepting
    // a failure here would pass even if the swept revision were permanently
    // uninstallable, which is the exact outcome this test exists to rule out.
    // Bodies are served for every manifest file so the refetch can succeed.
    // Serve the fixture's REAL bytes. Zero-filled bodies of the right length
    // pass Content-Length and fail the sha256 the manifest pins — which the
    // strengthened assertion caught immediately, and the previous
    // failure-tolerant version would have swallowed.
    DeliveryStubProtocol.reset()
    for file in ManifestFixture.smallFiles {
      DeliveryStubProtocol.enqueue(
        url: "https://sweep.invalid.example/\(file.path)",
        .init(
          status: 200,
          headers: ["Content-Length": String(file.content.count)],
          body: file.content))
    }
    let outcome = await controller.ensureModelAvailable(old)
    #expect(
      outcome == .admitted,
      "a swept revision must still install by refetching; reclaiming cache may cost bytes and must never cost installability"
    )
  }

  // MARK: - The operational kill switch

  /// Deleting while delivery is FROZEN is the one deletion nothing can undo.
  ///
  /// Every other byte-mutating path into the controller sits behind the
  /// adapter, which returns early while the switch is off. This sweep is a
  /// public door the adapter does not stand in front of, so it carries its own
  /// gate. During an incident freeze the partials it would reclaim are exactly
  /// the ones nothing is permitted to re-fetch.
  ///
  /// BOTH HALVES RUN AGAINST THE SAME FIXTURE. A gate that refused
  /// unconditionally would satisfy the disabled half while silently disabling
  /// reclamation for every user, and that is indistinguishable from deleting
  /// the sweep — which is why the enabled half is not a separate test.
  @Test func theKillSwitchFreezesTheSweepWithoutDisablingIt() async throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }
    let registration = try makeRegistration(
      dirs.metadata, install: dirs.install, revision: "v3-eg2")
    let flagKey = DeliveryFlags.key("enabled", family: .egOne)

    // FROZEN: the superseded partials must survive untouched.
    let suiteOff = "sweep-off-\(UUID().uuidString)"
    let defaultsOff = try #require(UserDefaults(suiteName: suiteOff))
    defer { UserDefaults().removePersistentDomain(forName: suiteOff) }
    defaultsOff.set(false, forKey: flagKey)
    try #require(
      DeliveryFlags.snapshot(family: .egOne, defaults: defaultsOff).familyEnabled == false,
      "fixture did not actually disable delivery, so the frozen half proves nothing")

    let supersededFrozen = try seedStaging(dirs.metadata, key: "eg_one-eg-1-v2-sharded-q5km")
    await ModelDeliveryController(defaults: defaultsOff, availableDiskBytes: { _ in .max })
      .sweepSupersededStaging(registration)
    #expect(
      exists(supersededFrozen) == true,
      "the sweep deleted resumable partials while delivery was frozen, at the one moment nothing may re-fetch them"
    )

    // THAWED: the identical fixture must be reclaimed. Without this half a
    // permanently-refusing gate reads green.
    let suiteOn = "sweep-on-\(UUID().uuidString)"
    let defaultsOn = try #require(UserDefaults(suiteName: suiteOn))
    defer { UserDefaults().removePersistentDomain(forName: suiteOn) }

    await ModelDeliveryController(defaults: defaultsOn, availableDiskBytes: { _ in .max })
      .sweepSupersededStaging(registration)
    #expect(
      exists(supersededFrozen) == false,
      "with delivery enabled the same fixture was not reclaimed, so the gate is refusing unconditionally"
    )
  }

  /// The key is ABSENT for every ordinary user, and absent must mean ENABLED.
  /// `familyEnabled` reads through `object(forKey:) as? Bool ?? true`; a
  /// `defaults.bool(forKey:)` reading would return false for a missing key and
  /// turn the gate above into a permanent freeze for everyone — cleanup that
  /// never runs, with no error anywhere.
  @Test func anUnsetKillSwitchSweepsNormally() async throws {
    let dirs = try makeDirs()
    defer { dirs.cleanup() }
    let registration = try makeRegistration(
      dirs.metadata, install: dirs.install, revision: "v3-eg2")

    let suite = "sweep-unset-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    try #require(
      defaults.object(forKey: DeliveryFlags.key("enabled", family: .egOne)) == nil,
      "fixture suite was not clean, so this says nothing about the unset case")

    let superseded = try seedStaging(dirs.metadata, key: "eg_one-eg-1-v2-sharded-q5km")
    await ModelDeliveryController(defaults: defaults, availableDiskBytes: { _ in .max })
      .sweepSupersededStaging(registration)

    #expect(
      exists(superseded) == false,
      "an unset kill switch froze the sweep, so no ordinary user would ever reclaim abandoned downloads"
    )
  }
}

/// A park that CANCELLATION CANNOT OPEN.
///
/// `AsyncStream.Iterator.next()` returns `nil` when its task is cancelled, so a
/// test parking on one cannot hold a window open across a `cancel()` — the
/// subject finishes early and the state under test is gone before the
/// assertion runs. `withCheckedContinuation` (non-throwing) has no
/// cancellation path, so the only way out is `open()`.
///
/// Not a clock wait and not a poll: the waiter suspends until explicitly
/// resumed. Use it when the test must OWN when the subject proceeds.
actor CancellationInsensitiveGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}
