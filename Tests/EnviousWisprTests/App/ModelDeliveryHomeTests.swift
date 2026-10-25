import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprModelDelivery
@testable import EnviousWisprPipeline
import EnviousWisprAppKitTestSupport

/// #1741 Chunk 6 — pins the gate-refusal contract for `ModelDeliveryHome`'s
/// two Settings-row mutation sites (Parakeet Cancel/Resume).
@MainActor
@Suite("ModelDeliveryHome — engine mutation gate refusal", .tags(.productOutcome))
struct ModelDeliveryHomeTests {

  /// A bundle holding only the named manifests (and nothing else).
  private static func bundle(with resources: [String]) throws -> Bundle {
    let dir = URL(fileURLWithPath: TestTemporaryDirectory.path)
      .appendingPathComponent("ew-3546-bundle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let source = try manifestBundle()
    for name in resources {
      let url = try #require(source.url(forResource: name, withExtension: "json"))
      try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent("\(name).json"))
    }
    return try #require(Bundle(url: dir))
  }

  @Test(
    "the Ultra target needs the shipped manifest; v3 acceptance needs the retired one",
    arguments: [
      (["parakeet-delivery-manifest", "parakeet-v3-retired-manifest"], true, true),
      (["parakeet-delivery-manifest"], true, false),
      (["parakeet-v3-retired-manifest"], false, false),
    ])
  func upgradeTargetFollowsTheBundledManifests(
    resources: [String], expectTarget: Bool, expectV3Acceptance: Bool
  ) throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.bundle(with: resources),
      appSupportOverride: try Self.tempAppSupport())
    let coordinator = home.installParakeetUpgrade(
      parakeetSelection: ParakeetSelectionProvider(), isOnboardingComplete: { true })
    #expect(coordinator.hasUpgradeTarget == expectTarget)
    #expect((home.parakeetRetiredV3Handle != nil) == expectV3Acceptance)
    if expectTarget {
      let handle = try #require(home.parakeetHandle)
      #expect(handle.progressOwnership == .scoped, "background work must not own progress")
      #expect(handle.installDirectory.lastPathComponent == "parakeet-ultra")
    } else {
      // The retired manifest is never substituted for the shipped one.
      #expect(home.parakeetHandle == nil)
    }
    if let v3 = home.parakeetRetiredV3Handle {
      #expect(v3.installDirectory.lastPathComponent == "parakeet-tdt-0.6b-v3")
    }
  }

  /// Waits for a task construction started. The deadline releases the caller
  /// even if the subject never ends, so a hung task fails instead of hanging.
  fileprivate static func awaitBounded<T: Sendable>(
    _ task: Task<T, Never>?,
    deadline: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws -> T {
    let task = try #require(task, sourceLocation: sourceLocation)
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<T, any Error>) in
      let result = TaskWaitResult(continuation)
      Task {
        let value = await task.value
        result.take()?.resume(returning: value)
      }
      Task {
        do {
          // deadline-fallback: release the caller even if the subject never ends.
          try await Task.sleep(for: deadline)
        } catch {
          return
        }
        guard let continuation = result.take() else { return }
        Issue.record("construction's task never finished", sourceLocation: sourceLocation)
        continuation.resume(throwing: CancellationError())
      }
    }
  }

  @Test("construction migrates an existing v3 donor copy into our v3 directory")
  func launchMigratesTheRetiredV3Donor() async throws {
    let fixture = try ParakeetHomeFixture.make()
    let donor = ParakeetInstallLocation.legacySharedDonor(appSupport: fixture.appSupport)
    try ParakeetHomeFixture.writeBytes(into: donor)
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: fixture.bundle, appSupportOverride: fixture.root,
      retiredV3Progress: .init(write: { _, _, _ in }, clear: {}))
    _ = try await Self.awaitBounded(home.retiredV3LaunchMigrationForTesting)
    let owned = ParakeetInstallLocation.directory(for: .v3, dataDirectory: fixture.dataDirectory)
    for file in ManifestFixture.smallFiles {
      #expect(try Data(contentsOf: owned.appendingPathComponent(file.path)) == file.content)
      #expect(
        try Data(contentsOf: donor.appendingPathComponent(file.path)) == file.content,
        "the donor is read only")
    }
  }

  @Test("before any selection, Settings names v3 for an upgrade and Ultra for a fresh install",
    arguments: [false, true])
  func fallbackModelLabel(admittedV3: Bool) async throws {
    let fixture = try ParakeetHomeFixture.make()
    if admittedV3 { try await ParakeetHomeFixture.seedAdmittedV3(fixture) }
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: fixture.bundle, appSupportOverride: fixture.root,
      retiredV3Progress: .init(write: { _, _, _ in }, clear: {}))
    _ = home.installParakeetUpgrade(
      parakeetSelection: ParakeetSelectionProvider(), isOnboardingComplete: { true })
    try await Self.awaitBounded(home.parakeetObserverSetupForTesting)
    #expect(home.parakeetModelLabel == (admittedV3 ? "Parakeet v3" : "Parakeet Ultra"))
    #expect(home.parakeetRowIsBackgroundUpgrade == admittedV3, "v3 serves while Ultra arrives")
  }

  /// A Home with the fixture's Ultra target and its observers wired.
  fileprivate static func upgradeHome(
    _ fixture: ParakeetHomeFixture.Made, enabled: Bool = true, onboarding: Bool = true
  ) async throws -> (ModelDeliveryHome, ParakeetUpgradeCoordinator) {
    let flags = TestDefaults.suite("test.home-upgrade.\(UUID().uuidString)")!
    flags.set(enabled, forKey: DeliveryFlags.key("enabled", family: .parakeet))
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: fixture.bundle, appSupportOverride: fixture.root,
      deliveryFlagDefaults: flags,
      retiredV3Progress: .init(write: { _, _, _ in }, clear: {}))
    let coordinator = home.installParakeetUpgrade(
      parakeetSelection: ParakeetSelectionProvider(), isOnboardingComplete: { onboarding })
    try await Self.awaitBounded(home.parakeetObserverSetupForTesting)
    return (home, coordinator)
  }

  @Test("Settings' Try again warms once after a granted cycle, never after a refused one",
    arguments: [(true, true), (true, false), (false, true)])
  func explicitRetryWarms(writable: Bool, enabled: Bool) async throws {
    let fixture = try ParakeetHomeFixture.make()
    let (home, _) = try await Self.upgradeHome(fixture, enabled: enabled)
    var warms = 0
    home.warmParakeetAfterExplicitRetry = { warms += 1 }
    let metadata = fixture.dataDirectory.appendingPathComponent("ModelDelivery")
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    if !writable {
      try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: metadata.path)
    }
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: metadata.path)
    }
    let warm = home.retryParakeetUpgradeAndWarm()
    if writable {
      _ = try await Self.awaitBounded(warm)
      #expect(warms == 1, "the granted cycle loads now, also with delivery off (\(enabled))")
    } else {
      #expect(warm == nil, "a refused grant starts no warm-up")
      #expect(warms == 0)
    }
  }

  @Test("a policy change Settings must re-read bumps the presentation revision")
  func presentationRevisionFollowsThePolicy() async throws {
    let fixture = try ParakeetHomeFixture.make()
    let (home, _) = try await Self.upgradeHome(fixture)
    let state = home.parakeetState
    let before = home.parakeetPresentationRevision
    #expect(home.retryParakeetUpgrade())
    #expect(home.parakeetState == state, "the delivery state did not move")
    #expect(home.parakeetPresentationRevision != before, "so the revision must")
  }

  @Test("E19: while Ultra's foreground fetch runs after v3 failed, its rows show under v3's name")
  func rejectedV3HandsTheRowToUltra() async throws {
    let fixture = try ParakeetHomeFixture.make()
    try await ParakeetHomeFixture.seedAdmittedV3(fixture)
    // Onboarding open: no background fetch starts, so only the foreground owns Ultra.
    let (home, coordinator) = try await Self.upgradeHome(fixture, onboarding: false)
    let prepared = try await coordinator.prepareLoad()
    #expect(home.parakeetModelLabel == "Parakeet v3")
    #expect(home.parakeetRowIsBackgroundUpgrade, "control: v3 serves while Ultra arrives")
    // The rejection is published before Ultra's foreground fetch awaits, so
    // the checks below run while that fetch (to an unreachable fixture host)
    // is in flight.
    let rejected = RejectionSignal()
    let refresh = coordinator.onPresentationChanged
    coordinator.onPresentationChanged = {
      refresh?()
      if home.parakeetV3Rejected { rejected.fire() }
    }
    struct VendorLoadFailed: Error {}
    let failure = Task { await coordinator.handleLoadFailure(prepared, error: VendorLoadFailed()) }
    await rejected.wait()
    #expect(home.parakeetModelLabel == "Parakeet v3", "the frozen name is still v3")
    #expect(home.parakeetRowIsBackgroundUpgrade == false)
    let downloading = SpeechEngineSettingsView.parakeetRow(
      needsExplicitRetry: home.parakeetNeedsExplicitRetry,
      rowIsBackgroundUpgrade: home.parakeetRowIsBackgroundUpgrade,
      background: home.parakeetBackgroundUpgrade,
      foreground: .downloading(fractionCompleted: 0.5, bytesWritten: 2_097_152, totalBytes: 4_194_304))
    #expect(downloading?.owner == .foreground, "Ultra's download shows with its own Cancel")
    #expect(downloading?.showsCancel == true)
    let failed = SpeechEngineSettingsView.parakeetRow(
      needsExplicitRetry: home.parakeetNeedsExplicitRetry,
      rowIsBackgroundUpgrade: home.parakeetRowIsBackgroundUpgrade,
      background: home.parakeetBackgroundUpgrade,
      foreground: .failed(DeliveryFailure(reason: .sourceUnreachable)))
    #expect(failed?.owner == .foreground, "Ultra's failure is not hidden")
    _ = try await Self.awaitBounded(failure)
  }

  @Test("the upgrade coordinator's usability changes reach the companion observers")
  func upgradeUsabilityReachesCompanions() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())
    var invited = 0
    home.addParakeetUsableObserver { invited += 1 }
    let coordinator = home.installParakeetUpgrade(
      parakeetSelection: ParakeetSelectionProvider(), isOnboardingComplete: { true })
    coordinator.onUsabilityMayHaveChanged?()
    #expect(invited == 1)
    #expect(coordinator.hasUpgradeTarget, "the shipped Ultra manifest configures the target")
  }

  @Test(
    "each engine's checker has its own registration, host rule and removal; an unadmitted base fetches nothing",
    arguments: LearnedWordCheckerEngine.allCases)
  func checkerRegistrationAndTriggerGate(engine: LearnedWordCheckerEngine) async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())
    let checker = try #require(home.checkerRegistrations[engine])
    #expect(
      checker.installDirectory.path.hasSuffix(engine.installFolder),
      "\(checker.installDirectory.path) is not under \(engine.installFolder)")
    #expect(checker.manifest.identity.family == engine.checkerFamily)
    #expect(ModelDeliveryHome.checkerHostIsConfigured(checker.manifest, engine: engine))
    let other: LearnedWordCheckerEngine = engine == .egOne ? .s1Mini : .egOne
    #expect(
      ModelDeliveryHome.checkerHostIsConfigured(checker.manifest, engine: other) == false,
      "a manifest is hosted only for its own engine")
    func hosted(_ url: String, id: String = "our_copy") throws -> DeliveryManifest {
      DeliveryManifest(
        schemaVersion: checker.manifest.schemaVersion,
        identity: checker.manifest.identity,
        files: checker.manifest.files,
        optionalFiles: checker.manifest.optionalFiles,
        totalBytes: checker.manifest.totalBytes,
        sources: [.init(id: id, baseURL: try #require(URL(string: url)))],
        admission: checker.manifest.admission,
        runtimeIdentityDigest: checker.manifest.runtimeIdentityDigest,
        checkerContract: checker.manifest.checkerContract,
        manifestDigest: checker.manifest.manifestDigest)
    }
    let prefix = engine.hostPathPrefix
    // #3271: the literal is the oracle; the constant is what the gate reads.
    #expect(ModelDeliveryHome.ownedModelHost == "models.enviouswispr.com")
    #expect(
      ModelDeliveryHome.checkerHostIsConfigured(
        try hosted("https://models.enviouswispr.com\(prefix)checker/next/"), engine: engine))
    for refused in [
      "https://models.enviouswispr.com/edit-judge/x/", "http://models.enviouswispr.com\(prefix)x/",
      "https://models.enviouswispr.com.evil.test\(prefix)x/",
      "https://adapter-host-pending.invalid\(prefix)",
      // The pre-#3271 host: installed older builds still use it, new builds must not.
      "https://models.enviouslabs.co\(prefix)x/",
    ] {
      #expect(
        ModelDeliveryHome.checkerHostIsConfigured(try hosted(refused), engine: engine) == false,
        "\(refused)")
    }
    #expect(
      ModelDeliveryHome.checkerHostIsConfigured(
        try hosted("https://models.enviouswispr.com\(prefix)x/", id: "backup"), engine: engine)
        == false)

    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let baseName = engine == .egOne ? "eg1-delivery-manifest" : "s1-delivery-manifest"
    let baseManifest = try DeliveryManifest.load(
      from: Data(
        contentsOf: root.appendingPathComponent(
          "Sources/EnviousWispr/Resources/\(baseName).json")))
    let base = DeliveryRegistration(
      manifest: baseManifest,
      installDirectory: checker.installDirectory.deletingLastPathComponent()
        .appendingPathComponent("base"),
      metadataDirectory: checker.metadataDirectory)
    let prompt = try #require(checker.manifest.checkerContract?.base.promptTemplateID)
    #expect(
      await home.ensureCheckerAdapter(
        engine: engine, baseRegistration: base, promptTemplateID: prompt) == .baseNotAdmitted)
    #expect(
      await home.admittedCompatibleCheckerURL(
        engine: engine, baseRegistration: base, promptTemplateID: prompt) == nil)
    #expect(FileManager.default.fileExists(atPath: checker.installDirectory.path) == false)
    #expect(await home.removeCheckerAdapter(engine) == .removed, "nothing on disk removes cleanly")
  }

  /// The family's delivery switch gates every mutation, deletion included, as
  /// `EGOneDeliveryAdapter.remove` does for the base (cloud review of #3227).
  @Test(
    "a switched-off checker family refuses removal and leaves its bytes",
    arguments: LearnedWordCheckerEngine.allCases)
  func checkerRemovalHonoursTheDeliverySwitch(engine: LearnedWordCheckerEngine) async throws {
    let suite = try #require(TestDefaults.suite("ew-3105-checker-switch-\(UUID().uuidString)"))
    suite.set(false, forKey: "modelDelivery.\(engine.checkerFamily.rawValue).enabled")
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport(),
      deliveryFlagDefaults: suite)
    let checker = try #require(home.checkerRegistrations[engine])
    try FileManager.default.createDirectory(
      at: checker.installDirectory, withIntermediateDirectories: true)
    let adapter = checker.installDirectory.appendingPathComponent(
      try #require(checker.manifest.checkerContract?.adapterFileName))
    try Data("adapter".utf8).write(to: adapter)
    #expect(home.checkerDeliveryEnabled(engine) == false)
    #expect(
      await home.removeCheckerAdapter(engine)
        == .failed(DeliveryFailure(reason: .unknown, detail: "delivery_disabled")))
    #expect(
      FileManager.default.fileExists(atPath: adapter.path), "switched off, nothing is deleted")
    suite.set(true, forKey: "modelDelivery.\(engine.checkerFamily.rawValue).enabled")
    #expect(await home.removeCheckerAdapter(engine) == .removed)
    #expect(
      FileManager.default.fileExists(atPath: adapter.path) == false, "switched on, removal proceeds"
    )
  }

  /// Production's trust root is the signed app's own `Bundle.main` (contract
  /// §4a), which a unit-test process cannot see — these resources ride the
  /// `EnviousWispr` app target, not any framework or test bundle. Rather than
  /// author a divergent fixture, point at a `Bundle` over the SAME committed
  /// manifest files `ModelDeliveryHome` loads in production. Same repo-root
  /// discovery as `ParakeetShippedManifestTests.repoRoot`
  /// (`Tests/EnviousWisprTests/ModelDelivery/DeliveryManifestTests.swift`).
  static func manifestBundle() throws -> Bundle {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // (file)
      .deletingLastPathComponent()  // App
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
    let resourcesDir = repoRoot.appendingPathComponent("Sources/EnviousWispr/Resources")
    return try #require(Bundle(url: resourcesDir))
  }

  /// A throwaway Application Support root, one per call.
  ///
  /// Construction runs a no-fetch delivery PROBE (#2123 whole-diff review), and a
  /// probe that finds a complete cache WRITES an admission marker. Pointed at the
  /// real Application Support, that makes this suite mutate the developer's own
  /// machine as a side effect of running — and on a machine where another process
  /// is measuring those markers, it plants a false row in their data rather than
  /// merely being untidy. Every construction site here takes its own root.
  ///
  /// Not deleted afterwards: these live under the system temp directory, which
  /// the OS reaps, and a `defer` per site would fire while the async work the
  /// constructor kicked off is still running.
  static func tempAppSupport() throws -> URL {
    let root = URL(fileURLWithPath: TestTemporaryDirectory.path)
      .appendingPathComponent("ew-2123-mdh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test("a gate-refused cancel reports the site and never releases or wakes")
  func aGateRefusedCancelReportsTheSiteAndNeverReleasesOrWakes() async throws {
    final class Box: @unchecked Sendable {
      var endCalls = 0
      var wakeCalls = 0
      var refusedSites: [String] = []
    }
    let box = Box()
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { false },
        end: {
          box.endCalls += 1
          return false
        },
        wake: { box.wakeCalls += 1 },
        onRefused: { box.refusedSites.append($0) }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())

    home.cancelParakeetDownload()
    // Signal, not clock: wait for the gate's own refusal telemetry, proving
    // the Task actually reached and was refused by the claim, before
    // asserting the negatives that a refusal implies.
    for _ in 0..<200 where box.refusedSites.isEmpty { await Task.yield() }

    #expect(box.refusedSites == ["parakeetCancelDownload"])
    #expect(box.endCalls == 0, "a refused claim is never released")
    #expect(box.wakeCalls == 0, "a refused claim never owes a wake")
  }

  /// The flag store is INJECTED and explicitly ENABLED, which this test did not
  /// need before #2139 and does now. `resumeParakeetDownload` reads the parakeet
  /// family kill switch, so without an injected suite it reads the real
  /// operational one — and on a machine where a developer has that switch set
  /// false the door refuses before the claim and this test fails on MACHINE
  /// STATE rather than on code. Found by cloud review; the omission was harmless
  /// only for as long as this door read no flag.
  @Test("a gate-refused resume reports the site and never releases or wakes")
  func aGateRefusedResumeReportsTheSiteAndNeverReleasesOrWakes() async throws {
    final class Box: @unchecked Sendable {
      var endCalls = 0
      var wakeCalls = 0
      var refusedSites: [String] = []
    }
    let box = Box()
    let suite = try #require(TestDefaults.suite("ew-2139-resume-\(UUID().uuidString)"))
    suite.set(true, forKey: "modelDelivery.parakeet.enabled")
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { false },
        end: {
          box.endCalls += 1
          return false
        },
        wake: { box.wakeCalls += 1 },
        onRefused: { box.refusedSites.append($0) }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport(),
      deliveryFlagDefaults: suite)

    home.resumeParakeetDownload()
    // Signal, not clock: wait for the gate's own refusal telemetry, proving
    // the Task actually reached and was refused by the claim, before
    // asserting the negatives that a refusal implies.
    for _ in 0..<200 where box.refusedSites.isEmpty { await Task.yield() }

    #expect(box.refusedSites == ["parakeetResumeDownload"])
    #expect(box.endCalls == 0, "a refused claim is never released")
    #expect(box.wakeCalls == 0, "a refused claim never owes a wake")
  }

  // MARK: - #2108: the Live Preview universal model registration

  /// The whole point of chunk 4a, and the one thing in it that can destroy data.
  ///
  /// `CacheAdmission` treats an install directory as exhaustive truth and deletes
  /// every top-level entry the active manifest does not list. If both Whisper
  /// registrations pointed at one directory, admitting either model would delete
  /// the other's files — the 1.6 GB transcription model, a heart-path artifact,
  /// wiped by a display-only limb.
  ///
  /// Asserted against the REAL `installDirectory` URLs rather than the manifests'
  /// `installLocation` tokens, because those tokens are documentary:
  /// `DeliveryManifest` decodes `installLocation` as a free `String` and never
  /// resolves it to a path. The directory is the authority, so the directory is
  /// what this test reads.
  @Test("the preview model installs to its own directory, never the transcription model's")
  func previewModelInstallsToItsOwnDirectory() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())

    let transcription = try #require(home.whisperRegistration)
    let preview = try #require(home.whisperPreviewRegistration)

    #expect(
      preview.installDirectory != transcription.installDirectory,
      "two registrations sharing an install directory delete each other's files")
    #expect(preview.installDirectory.lastPathComponent == "whisper-preview-gguf")
    #expect(transcription.installDirectory.lastPathComponent == "whisper-gguf")

    // Neither may be an ANCESTOR of the other either: the exhaustive sweep runs
    // over a directory's top-level entries, so a nested install would put one
    // model's folder inside the other's swept space. Equality alone would not
    // catch that.
    let previewPath = preview.installDirectory.standardizedFileURL.path
    let transcriptionPath = transcription.installDirectory.standardizedFileURL.path
    #expect(!previewPath.hasPrefix(transcriptionPath + "/"))
    #expect(!transcriptionPath.hasPrefix(previewPath + "/"))
  }

  /// Same family and same kill switch, so the separation above is carrying real
  /// weight rather than restating an accident. #3735: the GGUF pair differs by model
  /// name (one variant, `q8_0`, for both), where the WhisperKit pair differed by variant.
  @Test("the two Whisper registrations share a family and differ by model name")
  func previewAndTranscriptionShareFamilyAndRevision() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())

    let transcription = try #require(home.whisperRegistration).manifest.identity
    let preview = try #require(home.whisperPreviewRegistration).manifest.identity

    #expect(preview.family == .whisper)
    #expect(transcription.family == .whisper)
    #expect(preview.name == "whisper-small-gguf")
    #expect(transcription.name == "whisper-large-v3-turbo-gguf")
  }

  /// The shared metadata directory is deliberate and safe. Staging paths and
  /// admission markers key on the full `ModelIdentity.cacheKey`, which includes
  /// the variant, so two artifacts cannot collide there. Only the INSTALL
  /// directory is exhaustive — pinning that distinction stops a future reader
  /// "fixing" the shared metadata dir and losing the marker separation.
  @Test("the two registrations deliberately share one metadata directory")
  func previewAndTranscriptionShareMetadataDirectory() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())

    let transcription = try #require(home.whisperRegistration)
    let preview = try #require(home.whisperPreviewRegistration)
    #expect(preview.metadataDirectory == transcription.metadataDirectory)
    #expect(
      preview.manifest.identity.cacheKey != transcription.manifest.identity.cacheKey,
      "the cache key is what keeps markers and staging apart in that shared directory")
  }

  /// A handle exists, so the artifact is reachable for download once chunk 4b
  /// asks. Nil would mean the bundled manifest failed to load, which is the
  /// can't-happen-in-release condition the sibling registrations also guard.
  @Test("the preview registration produces a usable delivery handle")
  func previewRegistrationProducesAHandle() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())
    #expect(home.whisperPreviewHandle != nil)
  }

  /// #3546: the Parakeet load request takes its revision and byte total from
  /// the bundled manifest through the handle. The shipped manifest is Ultra
  /// (632,314,500 bytes); the no-manifest fallback loads v3 through the vendor,
  /// so its size is the retired v3 manifest's total. Literals are the
  /// independent oracles.
  @Test("the Parakeet request facts match the bundled manifest")
  func parakeetRequestFactsMatchTheBundledManifest() throws {
    let manifest = try DeliveryManifest.loadBundled(
      resource: "parakeet-delivery-manifest", bundle: Self.manifestBundle())
    #expect(manifest.identity.name == "parakeet-ultra-coreml")
    #expect(manifest.totalBytes == 632_314_500)
    let retired = try DeliveryManifest.loadBundled(
      resource: "parakeet-v3-retired-manifest", bundle: Self.manifestBundle())
    #expect(retired.identity.name == "parakeet-tdt-0.6b-v3-coreml")
    #expect(retired.totalBytes == 483_256_769)
    #expect(ParakeetModel.v3ShippedBytes == retired.totalBytes)
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())
    let handle = try #require(home.parakeetHandle)
    #expect(handle.modelTotalBytes == manifest.totalBytes)
    #expect(handle.modelRevision == manifest.identity.revision)
  }

  static func writeFastAdmissionFixture(home: ModelDeliveryHome) throws -> (
    manifest: DeliveryManifest, directory: URL, admission: CacheAdmission, marker: Data
  ) {
    let manifest = try DeliveryManifest.loadBundled(
      resource: "parakeet-delivery-manifest", bundle: Self.manifestBundle())
    let metadata = try #require(home.whisperRegistration).metadataDirectory
    let directory = ParakeetInstallLocation.directory(
      for: .ultra, dataDirectory: metadata.deletingLastPathComponent())
    let admission = CacheAdmission(
      manifest: manifest, installDirectory: directory, metadataDirectory: metadata)
    // Sparse fixture files match stamps without allocating the real model's bytes.
    var stamps: [CacheAdmission.AdmissionMarker.FileStamp] = []
    for file in manifest.files {
      let url = directory.appendingPathComponent(file.resolvedInstallPath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try #require(FileManager.default.createFile(atPath: url.path, contents: Data()))
      let handle = try FileHandle(forWritingTo: url)
      try handle.truncate(atOffset: UInt64(file.sizeBytes))
      try handle.close()
      let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
      let mtime = try #require(attrs[.modificationDate] as? Date).timeIntervalSince1970
      stamps.append(.init(path: file.resolvedInstallPath, sizeBytes: file.sizeBytes, mtime: mtime))
    }
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    let marker = try JSONEncoder().encode(
      CacheAdmission.AdmissionMarker(
        manifestDigest: manifest.manifestDigest, admittedAt: Date(), files: stamps))
    try marker.write(to: admission.markerURL)
    return (manifest, directory, admission, marker)
  }

  static func fastRenderFixture() throws -> (home: ModelDeliveryHome, directory: URL) {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: {
          Issue.record("render attempted engine mutation")
          return false
        },
        end: { false }, wake: {}, onRefused: { _ in }),
      manifestBundle: try manifestBundle(), appSupportOverride: try tempAppSupport())
    let fixture = try writeFastAdmissionFixture(home: home)
    return (home, fixture.directory)
  }

  @Test("Settings admission re-check sees file removal and acquires no mutation claim")
  func freshSettingsAdmission() async throws {
    final class Box { var claims = 0 }
    let box = Box()
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: {
          box.claims += 1
          return false
        }, end: { false }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(), appSupportOverride: try Self.tempAppSupport())
    #expect(await home.currentParakeetAdmission() == false)
    let (manifest, directory, admission, marker) = try Self.writeFastAdmissionFixture(home: home)
    #expect(await home.currentParakeetAdmission())
    try FileManager.default.removeItem(
      at: directory.appendingPathComponent(try #require(manifest.files.first).resolvedInstallPath))
    #expect(await home.currentParakeetAdmission() == false)
    #expect(try Data(contentsOf: admission.markerURL) == marker, "a read changed the marker")
    #expect(box.claims == 0, "a read attempted an engine mutation")
    #expect(
      await home.controller.state(of: manifest.identity) == .notReady, "a read started delivery")
  }

  // MARK: - #2123: removal frees the disk, which means releasing first

  /// **The drain must COMPLETE before the delete, not merely be requested.**
  ///
  /// Unlinking a file that is still open or mapped succeeds while its blocks stay
  /// allocated, so the space only returns once every holder has let go. FOUR can
  /// hold the model — the cached engine, a live session until its asynchronous
  /// teardown finishes, an in-flight preparation, and the session task itself
  /// between opening a session and registering its teardown — so a synchronous
  /// "please release" hook is not enough. The count was three when this comment
  /// was written and four by the next review pass, which is the argument for
  /// capturing holders rather than listing them from memory. The first version of this test asserted only
  /// that a hook had fired by the time `removePreviewModel()` returned, which
  /// stayed green with the delete moved BEFORE it. Cloud review caught that.
  ///
  /// This blocks inside the drain and asserts the removal has not finished while
  /// it is blocked — the property a request-shaped hook cannot have.
  @Test("removal waits for every holder to let go before deleting")
  func removalAwaitsTheDrain() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())

    final class Gate: @unchecked Sendable {
      private let mutex = NSLock()
      private var waiter: CheckedContinuation<Void, Never>?
      private var isOpen = false
      private var entered = false
      private var finished = false
      var drainEntered: Bool { mutex.withLock { entered } }
      var removalFinished: Bool { mutex.withLock { finished } }
      func noteFinished() { mutex.withLock { finished = true } }
      func wait() async {
        mutex.withLock { entered = true }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
          let alreadyOpen: Bool = mutex.withLock {
            if isOpen { return true }
            waiter = c
            return false
          }
          if alreadyOpen { c.resume() }
        }
      }
      func open() {
        let waiting: CheckedContinuation<Void, Never>? = mutex.withLock {
          isOpen = true
          let w = waiter
          waiter = nil
          return w
        }
        waiting?.resume()
      }
    }
    let gate = Gate()
    Self.bindPreviewCommandsForTests(home)
    home.drainPreviewHoldersBeforeRemoval = { await gate.wait() }
    home.previewRemovalDidFinish = { gate.noteFinished() }
    // **Never the real delete.** `manifestBundle` redirects only where manifests
    // are READ from; the install root and admission metadata are the developer's
    // own `~/Library/Application Support`, so a real removal here deletes their
    // installed preview model when the suite runs.
    home.deletePreviewModelOverrideForTests = {}

    home.removePreviewModel()
    for _ in 0..<2000 where !gate.drainEntered { await Task.yield() }
    #expect(gate.drainEntered, "control: removal must actually ask the holders to drain")

    // THE ASSERTION: while the drain is blocked, removal has not completed.
    for _ in 0..<200 { await Task.yield() }
    #expect(
      !gate.removalFinished,
      "removal completed while a holder was still draining, so the unlink could hit a mapped file")

    gate.open()
    for _ in 0..<2000 where !gate.removalFinished { await Task.yield() }
    #expect(gate.removalFinished, "removal must finish once the holders have let go")

    // **THE ORDER ITSELF**, which "finished after the drain" cannot see: the
    // finish callback trails both steps whichever way round they are, so an
    // earlier version of this test stayed green with the delete moved first.
    #expect(
      home.removalStepsForTests == ["drain", "delete", "finish"],
      "removal ran in the wrong order: \(home.removalStepsForTests)")
  }

  /// Two presses must produce ONE removal.
  ///
  /// The button stays on screen during the drain, so a second press is ordinary
  /// rather than exotic. Single-flighting only the coordinator's drain was not
  /// enough: both presses shared that and then ran two deletes and two finish
  /// callbacks, and one finish lifts the suppression while the other removal is
  /// still going — reopening the window suppression exists to close.
  ///
  /// Mutation control: drop the `removalTask == nil` guard and the counts double.
  @Test("pressing Remove twice removes once")
  func removalIsSingleFlight() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())

    final class Gate: @unchecked Sendable {
      private let mutex = NSLock()
      private var waiter: CheckedContinuation<Void, Never>?
      private var isOpen = false
      private(set) var entries = 0
      var entered: Int { mutex.withLock { entries } }
      func wait() async {
        mutex.withLock { entries += 1 }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
          let open: Bool = mutex.withLock {
            if isOpen { return true }
            waiter = c
            return false
          }
          if open { c.resume() }
        }
      }
      func open() {
        let w: CheckedContinuation<Void, Never>? = mutex.withLock {
          isOpen = true
          let w = waiter
          waiter = nil
          return w
        }
        w?.resume()
      }
    }
    let gate = Gate()
    Self.bindPreviewCommandsForTests(home)
    home.drainPreviewHoldersBeforeRemoval = { await gate.wait() }
    // Counted, not performed: see the note above about Application Support.
    let deletes = Deletes()
    home.deletePreviewModelOverrideForTests = { deletes.record() }

    home.removePreviewModel()
    for _ in 0..<2000 where gate.entered < 1 { await Task.yield() }
    #expect(gate.entered == 1, "control: the first removal is under way")

    // The user presses it again while the first is draining.
    home.removePreviewModel()
    for _ in 0..<200 { await Task.yield() }
    #expect(gate.entered == 1, "a second press started a competing removal")

    gate.open()
    for _ in 0..<2000 where !home.removalStepsForTests.contains("finish") { await Task.yield() }
    #expect(
      home.removalStepsForTests == ["drain", "delete", "finish"],
      "exactly one of each step, got \(home.removalStepsForTests)")
    #expect(deletes.count == 1, "two presses performed \(deletes.count) deletes")
  }

  /// #3735: preview commands refuse until the replacement record is bound. These tests are about
  /// the doors' other contracts, so the record here always accepts, and `download` reaches
  /// delivery the way `WhisperModelMigration.download` does.
  static func bindPreviewCommandsForTests(_ home: ModelDeliveryHome) {
    home.previewReplacement = .init(
      download: { [weak home] in
        _ = await home?.whisperPreviewHandle?.ensureAvailable()
        return true
      },
      decline: { true })
  }

  private final class Deletes: @unchecked Sendable {
    private let mutex = NSLock()
    private var value = 0
    var count: Int { mutex.withLock { value } }
    func record() { mutex.withLock { value += 1 } }
  }

  // MARK: - #2137 cloud review: the delivery kill switch

  /// The Download door must honour `modelDelivery.whisper.enabled`.
  ///
  /// `ensureAvailable()` does NOT enforce the flag itself — the primary Whisper
  /// door guards `handle.isEnabled()` immediately before calling it
  /// (`WhisperDeliveryWiring.swift`). This door did not, so an operator
  /// who had disabled the whole family could still have a preview model fetch
  /// start, bypassing the relaunch-free rollback the flag exists to provide.
  ///
  /// Asserted BOTH ways in one test, because either half alone is satisfiable by
  /// the opposite bug: flag-off must publish nothing, and flag-on must still
  /// reach the controller. A one-way test would pass against a door welded shut,
  /// which breaks the feature for every user to protect against a flag almost
  /// nobody sets.
  ///
  /// The flag store is injected. Writing a real kill switch into the shared suite
  /// to test it would leave an operational flag set on a developer's machine.
  @Test("the preview Download door honours the whisper kill switch, both ways")
  func previewDownloadHonoursTheKillSwitch() async throws {
    func home(enabled: Bool) throws -> ModelDeliveryHome {
      let suite = try #require(TestDefaults.suite("ew-2137-killswitch-\(UUID().uuidString)"))
      suite.set(enabled, forKey: "modelDelivery.whisper.enabled")
      return ModelDeliveryHome(
        engineMutationScope: .live(
          tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
        manifestBundle: try Self.manifestBundle(),
        appSupportOverride: try Self.tempAppSupport(),
        deliveryFlagDefaults: suite)
    }
    /// Take the baseline once the SUBJECT says its launch probe has finished.
    ///
    /// Construction runs that probe in an unstructured `Task`, and it is what
    /// moves `previewStateUpdatesForTests`. A baseline read before it completes is
    /// stale, and the assertion below then fails `2 == 1` — a confident accusation
    /// against production code that is correct.
    ///
    /// It failed exactly that way on CI (`build-debug`, #2400) while passing
    /// locally twice, after #2135 added a task per delivery event and pushed the
    /// probe past the old fixed 400-yield wait on a contended runner.
    ///
    /// **The first fix was also wrong, and wrong in the interesting way:** it
    /// waited for the counter to stop changing across 50 yields and called that
    /// stability. Still a COUNT — the counter is equally quiet when the task has
    /// not started, or is suspended inside `attachPreviewObserver` or
    /// `recordFirstRunBaseline`, neither of which touches it. And 50 is SHORTER
    /// than the 400 it replaced, so it widened the race it was meant to close.
    /// Cloud review caught that on the fix rather than on the original.
    ///
    /// The bound below is a HANG GUARD, not a settle budget: it can only fire when
    /// the subject never reports, and it says so instead of returning a guess.
    func baselineAfterLaunchProbe(_ home: ModelDeliveryHome) async -> Int {
      for _ in 0..<100_000 where !home.previewLaunchProbeDidFinishForTests {
        await Task.yield()
      }
      if !home.previewLaunchProbeDidFinishForTests {
        Issue.record(
          "the preview launch probe never reported completion; any baseline is a guess")
      }
      return home.previewStateUpdatesForTests
    }

    let off = try home(enabled: false)
    Self.bindPreviewCommandsForTests(off)
    let offBaseline = await baselineAfterLaunchProbe(off)
    off.startPreviewDownload()
    for _ in 0..<2000 { await Task.yield() }
    #expect(
      off.previewStateUpdatesForTests == offBaseline,
      "the kill switch is off but the download door still reached delivery")

    let on = try home(enabled: true)
    Self.bindPreviewCommandsForTests(on)
    let onBaseline = await baselineAfterLaunchProbe(on)
    on.startPreviewDownload()
    for _ in 0..<4000 where on.previewStateUpdatesForTests == onBaseline { await Task.yield() }
    #expect(
      on.previewStateUpdatesForTests > onBaseline,
      "with the flag ON the door must still reach delivery; a welded-shut door would pass the assertion above"
    )
  }

  /// The Parakeet Resume door honours `modelDelivery.parakeet.enabled` (#2139).
  ///
  /// The flag is enforced per FETCH door by the caller — the controller's own
  /// snapshot drives revalidation, source order and telemetry, never a refusal —
  /// so a door that omits the check ignores the flag rather than weakening it.
  /// Automatic warm-up checks it; this door did not, so an operator who had frozen
  /// delivery could still start a multi-gigabyte fetch from Settings.
  ///
  /// **Both directions in one case**, because either half alone is satisfiable by
  /// the opposite bug: flag-off must not reach the mutation claim, and flag-on
  /// must still reach it. A one-way test passes against a door welded shut, which
  /// breaks Resume for every user in order to honour a flag almost nobody sets.
  ///
  /// **The claim is the observable, and the gate is deliberately set to REFUSE.**
  /// `withClaim` calls `tryBegin` before anything else and reports the site
  /// through `onRefused`, so a refused claim proves control reached the claim —
  /// which is the statement immediately after the guard — while `ensureAvailable()`
  /// is never called. That last part is not a convenience: unlike its two
  /// siblings, Parakeet's install directory is deliberately NOT rerouted by
  /// `appSupportOverride` (it comes from `AsrModels.defaultCacheDirectory`), so a
  /// flag-on arm that reached real delivery would validate or fetch against the
  /// developer's own model cache and the network.
  ///
  /// **The flag-off arm asserts a POSITIVE.** `parakeetResumeRefusalsForTests` is
  /// incremented synchronously inside the guard, on the main actor, before any
  /// `Task` exists — so it is already true when the call returns and there is
  /// nothing to wait for. The companion `refusedSites` assertion is a genuine
  /// absence and is safe for the same structural reason: the refusal path creates
  /// no `Task`, so nothing could ever append to it later.
  ///
  /// The flag store is injected. Reading the real one would mean writing an
  /// operational delivery kill switch onto a developer's machine.
  ///
  /// **KNOWN SURVIVOR, and it is structural rather than an oversight (#2389).**
  /// Deleting the `_ = await handle.ensureAvailable()` line inside the claim
  /// leaves every row here green, confirmed by mutation. It cannot be otherwise:
  /// `tryBegin` returns false, so `withClaim` refuses and never runs its
  /// operation, which is exactly the property the paragraph above relies on to
  /// keep real Parakeet delivery off the developer's cache and the network.
  /// Binding "the download was actually asked for" needs a seam this file does
  /// not have, and buying it by letting delivery run would be the worse trade.
  @Test("the Parakeet Resume door honours the parakeet kill switch, both ways")
  func parakeetResumeHonoursTheKillSwitch() async throws {
    final class Box: @unchecked Sendable {
      var refusedSites: [String] = []
    }

    func makeHome(enabled: Bool, box: Box) throws -> ModelDeliveryHome {
      let suite = try #require(TestDefaults.suite("ew-2139-killswitch-\(UUID().uuidString)"))
      suite.set(enabled, forKey: "modelDelivery.parakeet.enabled")
      return ModelDeliveryHome(
        engineMutationScope: .live(
          tryBegin: { false },
          end: { false },
          wake: {},
          onRefused: { box.refusedSites.append($0) }),
        manifestBundle: try Self.manifestBundle(),
        appSupportOverride: try Self.tempAppSupport(),
        deliveryFlagDefaults: suite)
    }

    let offBox = Box()
    let off = try makeHome(enabled: false, box: offBox)
    off.resumeParakeetDownload()
    #expect(
      off.parakeetResumeRefusalsForTests == 1,
      "with the kill switch off the door must refuse synchronously, before any Task exists")
    #expect(
      offBox.refusedSites.isEmpty,
      "a refused door must not reach the mutation claim: a download that is never going to happen must not serialise against a dictation's engine switch"
    )

    let onBox = Box()
    let on = try makeHome(enabled: true, box: onBox)
    on.resumeParakeetDownload()
    // Signal, not clock: wait for the gate's own refusal telemetry, which the
    // subject fires from inside the door's Task.
    for _ in 0..<400 where onBox.refusedSites.isEmpty { await Task.yield() }
    #expect(
      on.parakeetResumeRefusalsForTests == 0,
      "with the flag ON nothing may refuse on the kill switch")
    #expect(
      onBox.refusedSites == ["parakeetResumeDownload"],
      "with the flag ON the door must still reach delivery; a welded-shut door would pass the assertions above"
    )
  }

  /// The Resume door's SECOND kill-switch read — the one inside the Task (#2389).
  ///
  /// **Nothing bound it, and the case beside this one cannot.** Deleting that
  /// guard left every row of `parakeetResumeHonoursTheKillSwitch()` green, found
  /// by a mutation of the night session's own choosing rather than by the filed
  /// recipe. The reason is structural: that case's flag-off arm returns at the
  /// SYNCHRONOUS guard, so the re-read is never reached, and its flag-on arm
  /// never turns the switch off. The second door was live code with no test
  /// entering it at all.
  ///
  /// **The window is real, not contrived.** The flag is set remotely, so it can
  /// go off between the user pressing Resume and the download starting. The
  /// re-read exists for exactly that, and it must refuse BEFORE the mutation
  /// claim: a download that is not going to happen must not serialise against a
  /// dictation's engine switch.
  ///
  /// **Staged, never raced.** `resumeParakeetDownload()` is synchronous and
  /// returns before its unstructured `Task` can run, so writing the flag on the
  /// next line puts the store in the off state for the re-read and only for the
  /// re-read. The first expectation is the precondition: if the synchronous
  /// guard had already refused, this case would be testing the first door again
  /// and would prove nothing about the second.
  @Test("the Resume door re-reads the kill switch after the button, not only before")
  func parakeetResumeRereadsTheKillSwitch() async throws {
    final class Box: @unchecked Sendable {
      var refusedSites: [String] = []
    }

    let box = Box()
    let suite = try #require(TestDefaults.suite("ew-2389-reread-\(UUID().uuidString)"))
    suite.set(true, forKey: "modelDelivery.parakeet.enabled")
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { false },
        end: { false },
        wake: {},
        onRefused: { box.refusedSites.append($0) }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport(),
      deliveryFlagDefaults: suite)

    home.resumeParakeetDownload()
    #expect(
      home.parakeetResumeRefusalsForTests == 0,
      "the switch was ON at the button, so the synchronous guard must let this through — a refusal here means this case never reaches the door it exists for"
    )

    suite.set(false, forKey: "modelDelivery.parakeet.enabled")

    // **A HANG GUARD, not a settle budget** — the convention this file already
    // records at `baselineAfterLaunchProbe`. A small count is a bet on how many
    // yields a contended runner needs before an unstructured task gets to run,
    // and losing that bet fails correct production code. This bound can only be
    // reached when the door never reports at all, and then it SAYS so rather
    // than letting the expectation below read a silence as a verdict.
    for _ in 0..<100_000 where home.parakeetResumeRefusalsForTests == 0 { await Task.yield() }
    if home.parakeetResumeRefusalsForTests == 0 {
      Issue.record(
        "the Resume door's task never reported, so it is not known whether the re-read ran")
    }

    #expect(
      home.parakeetResumeRefusalsForTests == 1,
      "the switch went off between the button and the download starting and the door carried on anyway"
    )
    #expect(
      box.refusedSites.isEmpty,
      "the re-read refused, so it must have refused BEFORE taking the mutation claim"
    )
  }

  /// A refused removal must still END the removal, or Live Preview dies for the
  /// rest of the launch.
  ///
  /// `remove()` returns `false` without touching the controller when the family
  /// kill switch is off (`DeliveredModelHandle.swift (remove)`) — deliberate, and
  /// owned there: the flag stands down the whole delivery layer, deletions
  /// included. So the model legitimately stays on disk. What is NOT legitimate
  /// is what that does to the finish callback.
  ///
  /// `previewRemovalDidFinish` means "no longer removing", never "removal
  /// succeeded" — it clears `isRemovingModel` in the coordinator. Making it
  /// conditional on success is the obvious-looking reading of a discarded result,
  /// and it latches removal suppression forever: the model will not delete AND
  /// the feature will not run. This pins the sequence so that reading cannot land
  /// silently.
  ///
  /// Both directions, because "the steps completed" alone is satisfiable by a
  /// build that never consults the flag at all: flag-off must record `refused`,
  /// flag-on must NOT, and both must reach `finish`.
  ///
  /// **The real `remove()` runs here, unlike the ordering tests above, which
  /// substitute it.** That is safe only because `appSupportOverride` roots BOTH
  /// the preview model's `installDirectory` and its `metadataDirectory`
  /// (`ModelDeliveryHome.swift:196-210`), so the flag-on half deletes inside a
  /// temp directory rather than the developer's installed preview model.
  @Test("a kill-switch-refused preview removal still finishes, both ways")
  func refusedPreviewRemovalStillFinishes() async throws {
    func home(enabled: Bool) throws -> ModelDeliveryHome {
      let suite = try #require(TestDefaults.suite("ew-2137-rmswitch-\(UUID().uuidString)"))
      suite.set(enabled, forKey: "modelDelivery.whisper.enabled")
      return ModelDeliveryHome(
        engineMutationScope: .live(
          tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
        manifestBundle: try Self.manifestBundle(),
        appSupportOverride: try Self.tempAppSupport(),
        deliveryFlagDefaults: suite)
    }

    // **Observes the CALLBACK, never the `finish` step marker**, and that
    // distinction is the whole test. `removalStepsForTests.append("finish")` is
    // a separate statement AFTER the callback, so it records that control
    // reached that line — not that the callback ran. Asserting the step array
    // passed against the exact mutation this test exists to catch (suppressing
    // the callback on a refusal), because the marker still landed. A proxy one
    // statement away from the subject is not an observation of it.
    @MainActor final class Finishes {
      private(set) var count = 0
      func record() { count += 1 }
    }

    let off = try home(enabled: false)
    Self.bindPreviewCommandsForTests(off)
    let offFinishes = Finishes()
    off.previewRemovalDidFinish = { offFinishes.record() }
    for _ in 0..<400 { await Task.yield() }
    off.removePreviewModel()
    for _ in 0..<4000 where offFinishes.count == 0 { await Task.yield() }
    #expect(
      offFinishes.count == 1,
      "a refused removal must still fire the finish callback; latching suppression kills Live Preview for the launch"
    )
    #expect(
      off.removalStepsForTests.contains("refused"),
      "control: with the flag OFF the removal must actually have been refused")

    let on = try home(enabled: true)
    Self.bindPreviewCommandsForTests(on)
    let onFinishes = Finishes()
    on.previewRemovalDidFinish = { onFinishes.record() }
    for _ in 0..<400 { await Task.yield() }
    on.removePreviewModel()
    for _ in 0..<4000 where onFinishes.count == 0 { await Task.yield() }
    #expect(
      onFinishes.count == 1,
      "with the flag ON removal must still finish exactly once")
    #expect(
      !on.removalStepsForTests.contains("refused"),
      "with the flag ON removal must NOT be refused; a build ignoring the flag would pass the OFF half above"
    )
  }

  // MARK: - #2123 whole-diff review: the launch probe

  /// Launching must PROBE delivery state, not merely wire an observer to it.
  ///
  /// The bug this pins: a model admitted in a previous app session leaves a fresh
  /// controller with no in-memory entry, so there is nothing for a new observer
  /// to be told about, and the card reports "Not downloaded yet" — hiding Remove
  /// — for a model sitting on disk. `recordFirstRunBaseline` cannot cover it; it
  /// records whether this is a first run and publishes no state.
  ///
  /// **What this does and does not pin, established by mutation rather than by
  /// argument.** Deleting the `admitIfComplete` probe from `init` fails it, which
  /// is the regression that matters. Reversing the observer-attach and the probe
  /// does NOT fail it — `addStateObserver` replays every existing entry's state
  /// to a newly attached observer, so attach order is genuinely not load-bearing.
  /// An earlier version of this test claimed to guard that ordering and did not;
  /// the claim is recorded here so nobody re-derives it from the test's shape.
  ///
  /// Rooted at a temp directory rather than the real Application Support, so the
  /// verdict does not depend on whether this machine has ever used the feature.
  @Test("construction probes delivery state rather than only observing it")
  func launchProbePublishesToAnAttachedObserver() async throws {
    let root = URL(fileURLWithPath: TestTemporaryDirectory.path)
      .appendingPathComponent("ew-2123-launch-probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: root)

    #expect(home.whisperPreviewRegistration?.metadataDirectory.path.hasPrefix(root.path) == true)

    for _ in 0..<4000 where home.previewStateUpdatesForTests == 0 { await Task.yield() }
    #expect(
      home.previewStateUpdatesForTests > 0,
      "launch published nothing to the preview mirror, so the no-fetch probe did not run"
    )
  }

  // MARK: - #2123: the preview model's download state is observable

  /// The state starts where a not-yet-downloaded model should start.
  ///
  /// Deliberately a separate mirror from Parakeet's rather than a shared one:
  /// they are different models with different lifecycles, and a settings page
  /// rendering one from the other's state would show a download that is not
  /// happening.
  @Test("the preview model has its own delivery state, separate from Parakeet's")
  func previewStateIsItsOwnMirror() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())

    #expect(home.parakeetState == .notReady)
    // Safe to assert absolutely ONLY because this suite is rooted at a throwaway
    // Application Support (see `tempAppSupport`). Construction now runs a
    // no-fetch launch probe, so against the real directory this value would
    // depend on whether the machine running the tests happens to have the preview
    // model on disk — green in CI, green on a clean machine, red on a developer's
    // machine that had used the feature. A fixture that varies by machine is not
    // a fixture; the temp root is what makes this line a constant.
    #expect(home.whisperPreviewState == .notReady)

    let preview = try #require(home.whisperPreviewRegistration)
    let transcription = try #require(home.whisperRegistration).manifest.identity
    #expect(
      preview.manifest.identity.cacheKey != transcription.cacheKey,
      "two mirrors over one identity would make each model report the other's progress")

    // **The observer must actually OBSERVE.** Checking the initial value cannot
    // tell a wired mirror from a deleted one — both read `.notReady`. So publish
    // a real state for the preview identity and watch which mirror moves.
    //
    // `admitIfComplete` with no fetch is the safe trigger: it validates what is
    // already on disk and never downloads, and never deletes. `remove` would
    // have published a state too, and would have deleted a real model from the
    // machine running the tests.
    // Measured against a BASELINE, not against zero. The launch probe may already
    // have applied an update by now, and `> 0` would then pass without this
    // explicit trigger proving anything — the assertion would be satisfied by
    // construction alone and would survive deleting the observer's reaction to
    // this publish entirely.
    let baseline = home.previewStateUpdatesForTests
    let parakeetBaseline = home.parakeetStateUpdatesForTests

    _ = await home.controller.admitIfComplete(preview)

    for _ in 0..<2000 where home.previewStateUpdatesForTests == baseline { await Task.yield() }
    #expect(
      home.previewStateUpdatesForTests > baseline,
      "the preview mirror never applied an update — observer missing or filtered wrongly")
    #expect(
      home.parakeetStateUpdatesForTests == parakeetBaseline,
      "a preview state reached Parakeet's mirror, so the identity filter is wrong")
  }
}

/// #3546: a fixture bundle holding tiny Ultra and retired-v3 Parakeet manifests
/// (the shared `ManifestFixture` files), under a throwaway root, so Home's
/// construction can be observed without the real 483 MB v3 bytes.
private enum ParakeetHomeFixture {
  struct Made {
    let root: URL
    let appSupport: URL
    let dataDirectory: URL
    let bundle: Bundle
    let ultra: DeliveryManifest
    let retired: DeliveryManifest
  }

  static func make() throws -> Made {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("ew-home-upgrade-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let appSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
    // The same resolver Home runs over the same override.
    let storage = StorageRoot.resolve(
      systemApplicationSupport: appSupport,
      home: root.appendingPathComponent("Home", isDirectory: true))
    let bundleURL = root.appendingPathComponent("Fixture.bundle")
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

    func write(_ resource: String, name: String) throws -> DeliveryManifest {
      let data = try ManifestFixture.manifestJSON(files: ManifestFixture.smallFiles) {
        var identity = $0["identity"] as! [String: Any]
        identity["name"] = name
        $0["identity"] = identity
      }
      try data.write(to: bundleURL.appendingPathComponent(resource + ".json"))
      return try DeliveryManifest.load(from: data)
    }

    let ultra = try write("parakeet-delivery-manifest", name: "parakeet-ultra-coreml")
    let retired = try write("parakeet-v3-retired-manifest", name: "parakeet-tdt-0.6b-v3-coreml")
    return Made(
      root: root, appSupport: appSupport, dataDirectory: storage.dataDirectory,
      bundle: try #require(Bundle(url: bundleURL)), ultra: ultra, retired: retired)
  }

  /// An admitted retired-v3 install, written before Home is constructed.
  static func seedAdmittedV3(_ fixture: Made) async throws {
    let seedController = ModelDeliveryController(
      defaults: TestDefaults.suite("test.home-seed.\(UUID().uuidString)")!,
      availableDiskBytes: { _ in .max })
    let registration = DeliveryRegistration(
      manifest: fixture.retired,
      installDirectory: ParakeetInstallLocation.directory(
        for: .v3, dataDirectory: fixture.dataDirectory),
      metadataDirectory: fixture.dataDirectory.appendingPathComponent("ModelDelivery"))
    try writeBytes(into: registration.installDirectory)
    #expect(await seedController.admitIfComplete(registration))
  }

  static func writeBytes(into directory: URL) throws {
    for file in ManifestFixture.smallFiles {
      let url = directory.appendingPathComponent(file.path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try file.content.write(to: url)
    }
  }
}

/// Fired by the subject when Home mirrors a v3 rejection. Deadline-bounded,
/// so a missing rejection fails loudly instead of hanging.
@MainActor
private final class RejectionSignal {
  private var fired = false
  private var waiting: CheckedContinuation<Void, Never>?

  func fire() {
    fired = true
    waiting?.resume()
    waiting = nil
  }

  func wait(sourceLocation: SourceLocation = #_sourceLocation) async {
    if fired { return }
    let deadline = Task { @MainActor [weak self] in
      // deadline-fallback: fail loudly and release a missing-signal wait.
      try? await Task.sleep(for: .seconds(5))
      guard let self, !self.fired, let waiting = self.waiting else { return }
      Issue.record("v3 was never rejected", sourceLocation: sourceLocation)
      self.waiting = nil
      waiting.resume()
    }
    await withCheckedContinuation { waiting = $0 }
    deadline.cancel()
  }
}

/// Releases a waiter exactly once, whichever of the subject or the deadline
/// arrives first.
private final class TaskWaitResult<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, any Error>?

  init(_ continuation: CheckedContinuation<Value, any Error>) {
    self.continuation = continuation
  }

  func take() -> CheckedContinuation<Value, any Error>? {
    lock.withLock {
      defer { continuation = nil }
      return continuation
    }
  }
}

/// #3546: when this fails, `first_run` telemetry misreports an upgrading user.
@MainActor
@Suite(.tags(.observabilityContract))
struct ParakeetUpgradeFirstRunTests {
  @Test("an upgrade from admitted v3 is not a first run", arguments: [false, true])
  func upgradeUsersAreNotFirstRun(admittedV3: Bool) async throws {
    let fixture = try ParakeetHomeFixture.make()
    if admittedV3 {
      let seedController = ModelDeliveryController(
        defaults: TestDefaults.suite("test.home-seed.\(UUID().uuidString)")!,
        availableDiskBytes: { _ in .max })
      let registration = DeliveryRegistration(
        manifest: fixture.retired,
        installDirectory: ParakeetInstallLocation.directory(
          for: .v3, dataDirectory: fixture.dataDirectory),
        metadataDirectory: fixture.dataDirectory.appendingPathComponent("ModelDelivery"))
      try ParakeetHomeFixture.writeBytes(into: registration.installDirectory)
      #expect(await seedController.admitIfComplete(registration))
    }
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: fixture.bundle, appSupportOverride: fixture.root,
      retiredV3Progress: .init(write: { _, _, _ in }, clear: {}))
    try await ModelDeliveryHomeTests.awaitBounded(home.parakeetObserverSetupForTesting)
    #expect(home.firstRunForTesting(fixture.ultra.identity) == !admittedV3)
  }
}

@MainActor
@Suite(.tags(.harnessContract))
struct ParakeetHomeTaskWaitTests {
  @Test func deadlineReleasesCallerBeforeSubjectFinishes() async {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    var finished = false
    let subject = Task { @MainActor in
      for await _ in stream {}
      finished = true
    }
    let fallback = Task { @MainActor in
      // deadline-fallback: release the fake even with a broken waiter.
      try? await Task.sleep(for: .seconds(1))
      continuation.finish()
    }
    await withKnownIssue("The unfinished subject must trigger the waiter deadline") {
      await #expect(throws: CancellationError.self) {
        try await ModelDeliveryHomeTests.awaitBounded(subject, deadline: .milliseconds(1))
      }
    }
    #expect(finished == false, "the waiter depended on subject completion")
    continuation.finish()
    await subject.value
    fallback.cancel()
  }
}

/// #3735: the transcribe.cpp Whisper registrations are defined on the home (the one owner
/// of "which models exist and where they install") but stay inert until the engine swap.
///
/// **What the user sees when this fails:** a Whisper user's new model installs over or beside
/// the wrong folder, or a launch starts downloading 886 MB the user never asked for.
@MainActor
@Suite("ModelDeliveryHome — transcribe.cpp Whisper registrations (#3735)", .tags(.productOutcome))
struct WhisperGGUFRegistrationTests {
  static func manifestBundle() throws -> Bundle {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // (file)
      .deletingLastPathComponent()  // App
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
    return try #require(Bundle(url: repoRoot.appendingPathComponent("Sources/EnviousWispr/Resources")))
  }

  @Test("both registrations load the bundled manifests and install into their own sibling folders")
  func registrationsInstallIntoDistinctGGUFHomes() throws {
    let appSupport = URL(fileURLWithPath: TestTemporaryDirectory.path)
      .appendingPathComponent("ew-3735-reg-\(UUID().uuidString)", isDirectory: true)
    let bundle = try Self.manifestBundle()
    let turbo = try ModelDeliveryHome.whisperGGUFRegistration(manifestBundle: bundle, appSupport: appSupport)
    let preview = try ModelDeliveryHome.whisperPreviewGGUFRegistration(
      manifestBundle: bundle, appSupport: appSupport)

    #expect(turbo.manifest.identity.name == "whisper-large-v3-turbo-gguf")
    #expect(preview.manifest.identity.name == "whisper-small-gguf")
    let models = appSupport.appendingPathComponent("EnviousWispr/Models", isDirectory: true)
    #expect(turbo.installDirectory.standardizedFileURL.path == models.appendingPathComponent("whisper-gguf").standardizedFileURL.path)
    #expect(preview.installDirectory.standardizedFileURL.path == models.appendingPathComponent("whisper-preview-gguf").standardizedFileURL.path)
    // Never the retired CoreML homes, and never each other.
    for dir in [turbo.installDirectory, preview.installDirectory] {
      #expect(!["whisper", "whisper-preview"].contains(dir.lastPathComponent))
    }
    #expect(turbo.installDirectory != preview.installDirectory)
    #expect(turbo.metadataDirectory == preview.metadataDirectory)
    #expect(turbo.manifest.identity.cacheKey != preview.manifest.identity.cacheKey)
  }

  @Test("construction registers the Whisper GGUF models and fetches nothing")
  func constructionRegistersTheGGUFModelsWithoutFetching() throws {
    let root = URL(fileURLWithPath: TestTemporaryDirectory.path)
      .appendingPathComponent("ew-3735-mdh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let home = ModelDeliveryHome(
      engineMutationScope: .live(tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: root)
    #expect(home.whisperRegistration?.manifest.identity.name == "whisper-large-v3-turbo-gguf")
    #expect(home.whisperPreviewRegistration?.manifest.identity.name == "whisper-small-gguf")
    #expect(home.whisperRegistration?.installDirectory.lastPathComponent == "whisper-gguf")
    #expect(
      home.whisperPreviewRegistration?.installDirectory.lastPathComponent == "whisper-preview-gguf")
    // Construction created no install folder: nothing was fetched or adopted.
    let models = root.appendingPathComponent("EnviousWispr/Models", isDirectory: true)
    for name in ["whisper-gguf", "whisper-preview-gguf"] {
      #expect(!FileManager.default.fileExists(atPath: models.appendingPathComponent(name).path))
    }
  }

  /// The Settings help promises an 886 MB download (`DictationSettingsCopy.Engine.modelSetupHelp`).
  /// This fails when the shipped manifest's size no longer rounds to that figure, so the copy
  /// cannot silently outlive a model change.
  @Test("the Settings download size is the shipped manifest's size")
  func settingsDownloadSizeMatchesManifest() throws {
    let appSupport = URL(fileURLWithPath: TestTemporaryDirectory.path)
      .appendingPathComponent("ew-3735-size-\(UUID().uuidString)", isDirectory: true)
    let turbo = try ModelDeliveryHome.whisperGGUFRegistration(
      manifestBundle: try Self.manifestBundle(), appSupport: appSupport)
    let megabytes = Int((Double(turbo.manifest.totalBytes) / 1_000_000).rounded())
    #expect(megabytes == 886)
    #expect(String(localized: DictationSettingsCopy.Engine.modelSetupHelp).contains("\(megabytes) MB"))
  }
}
