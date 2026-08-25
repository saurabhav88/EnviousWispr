import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprModelDelivery

/// The SECOND obligation source on `EGOneUpgradeCoordinator` (#2096 §3.2): a prior revision of
/// the same model was admitted, its bytes are still on disk, and this app ships a different
/// revision. Kept in its own suite so `EGOneUpgradeCoordinatorTests` stays recognisable as the
/// 29-case monolith-retirement oracle that `LegacyRetirement` names as its extraction oracle —
/// these cases stage admission markers, those stage a monolith, and mixing the fixtures would
/// make both harder to read.
///
/// Every guard here is proven against a negative control: the test that shows a protection holds
/// is paired with one showing the same code fetches when the protection is removed, so a guard
/// that silently stopped working could not pass both.
@Suite struct EGOneRevisionUpgradeTests {
  static let currentRevision = "v3-eg2"
  static let priorRevision = "v2-sharded"

  static func identity(revision: String = currentRevision) -> ModelIdentity {
    ModelIdentity(
      family: .egOne, name: "eg-1", revision: revision, variant: "q5km", runtimeABI: "test")
  }

  @MainActor
  private final class Probe {
    var admitted = false
    var ensureCount = 0
    var ensureOutcome: ModelDeliveryController.DeliveryOutcome = .admitted
    var removedURLs: [URL] = []
    var events: [EGOneUpgradeCoordinator.Event] = []
  }

  // MARK: - Fixtures

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "eg1-revision-upgrade-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func metadataDirectory(_ root: URL) -> URL {
    root.appendingPathComponent("EnviousWispr/ModelDelivery", isDirectory: true)
  }

  private func installDirectory(_ root: URL) -> URL {
    root.appendingPathComponent("EnviousWispr/Models/eg-1", isDirectory: true)
  }

  private func declineMarker(_ root: URL, revision: String = currentRevision) -> URL {
    metadataDirectory(root).appendingPathComponent(
      "eg1-revision-decline-\(Self.identity(revision: revision).cacheKey)")
  }

  private func defaults() throws -> (UserDefaults, String) {
    let suite = "eg1-revision-test-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
  }

  /// Writes a REAL `CacheAdmission.AdmissionMarker` for `revision`, and optionally the files it
  /// records. Using the production type rather than hand-rolled JSON means a change to the
  /// marker's shape breaks these tests instead of silently making them test nothing.
  @discardableResult
  private func stagePriorAdmission(
    root: URL,
    revision: String = priorRevision,
    fileNames: [String] = ["eg-1-v1-00001-of-00008.gguf", "eg-1-v1-00002-of-00008.gguf"],
    createFiles: Bool = true
  ) throws -> URL {
    let metadata = metadataDirectory(root)
    let install = installDirectory(root)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)

    var stamps: [CacheAdmission.AdmissionMarker.FileStamp] = []
    for name in fileNames {
      let url = install.appendingPathComponent(name)
      if createFiles { try Data("prior-revision-bytes".utf8).write(to: url) }
      stamps.append(.init(path: name, sizeBytes: 20, mtime: 1))
    }

    let marker = CacheAdmission.AdmissionMarker(
      manifestDigest: "prior-digest", admittedAt: Date(timeIntervalSince1970: 1), files: stamps)
    let url = metadata.appendingPathComponent(
      "\(Self.identity(revision: revision).cacheKey).admission.json")
    try JSONEncoder().encode(marker).write(to: url)
    return url
  }

  @MainActor
  private func coordinator(
    root: URL,
    defaults: UserDefaults,
    probe: Probe,
    identity: ModelIdentity? = nil,
    writeMarker: (@MainActor @Sendable (URL) -> Bool)? = nil,
    isOnboardingComplete: @escaping @MainActor @Sendable () -> Bool = { true }
  ) -> EGOneUpgradeCoordinator {
    let subject = EGOneUpgradeCoordinator(
      appSupportDirectory: root,
      identity: identity ?? Self.identity(),
      installDirectory: installDirectory(root),
      defaults: defaults,
      trustedArtifact: .init(name: "eg-1-v1.gguf", sizeBytes: 11, sha256: "unused-here"),
      isOnboardingComplete: isOnboardingComplete,
      ensureCurrentModel: { onWillRequestFetch, onFetchDecision in
        probe.ensureCount += 1
        onWillRequestFetch()
        // Report STARTED, as the real controller does the moment it decides
        // (#2110). A closure reporting nothing would leave the attempt
        // `.pending`, which now REFUSES a cancel — correct behaviour, and not
        // what these cases are about.
        onFetchDecision(.started)
        return probe.ensureOutcome
      },
      currentModelIsAdmitted: { probe.admitted },
      writeMarker: writeMarker,
      removeItem: { url in
        probe.removedURLs.append(url)
        try FileManager.default.removeItem(at: url)
      }
    )
    subject.onEvent = { event in probe.events.append(event) }
    return subject
  }

  // MARK: - Telemetry: the eligibility denominator

  @MainActor
  private func eligibleRoutings(_ probe: Probe) -> [EGOneUpgradeCoordinator.UpgradeRouting] {
    probe.events.compactMap {
      if case .upgradeEligible(let routing, _, _, _) = $0 { return routing }
      return nil
    }
  }

  /// The denominator must be emitted BEFORE every gate, including the gates that stop the upgrade
  /// dead. #1386's ship criterion counted from `attempt_started`, which grades only the upgrades
  /// that began — but an upgrade that never begins is the exact failure this path exists to
  /// prevent, so that shape reports success while hiding it.
  @MainActor
  @Test func eligibleEventFiresBeforeEveryGate() async throws {
    for (label, arrange, expected) in [
      (
        "disabled",
        { (store: UserDefaults, _: URL) in
          store.set(false, forKey: DeliveryFlags.key("enabled", family: .egOne))
        },
        EGOneUpgradeCoordinator.UpgradeRouting.disabled
      ),
      (
        "declined",
        { (_: UserDefaults, root: URL) in
          try? Data().write(to: self.declineMarker(root))
        },
        .declined
      ),
      ("started", { (_: UserDefaults, _: URL) in }, .started),
    ] {
      let root = try makeRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let (store, suite) = try defaults()
      defer { store.removePersistentDomain(forName: suite) }

      try stagePriorAdmission(root: root)
      arrange(store, root)

      let probe = Probe()
      let subject = coordinator(root: root, defaults: store, probe: probe)
      await subject.runLaunch()

      #expect(
        eligibleRoutings(probe) == [expected],
        "eligible install routed \(label) must still emit exactly one denominator event")
    }
  }

  /// The onboarding routing, which needs its own case because the deferral gate sits between the
  /// kill switch and the decline check.
  @MainActor
  @Test func eligibleEventReportsOnboardingDeferral() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    // A decline is ALSO recorded. Onboarding must still win, because that is the gate this launch
    // actually meets first. Without this the case would pass under either ordering.
    try Data().write(to: declineMarker(root))
    let probe = Probe()
    let subject = coordinator(
      root: root, defaults: store, probe: probe, isOnboardingComplete: { false })

    await subject.runLaunch()

    #expect(
      eligibleRoutings(probe) == [.deferredOnboarding],
      "onboarding outranks decline, matching the order runLaunch takes the gates")
  }

  /// The control. An install that could never have upgraded is NOT in the denominator, or the
  /// completion rate would be diluted by every user who was never a candidate.
  @MainActor
  @Test func ineligibleInstallIsNotCountedInTheDenominator() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    // No prior admission at all: a first-run user.
    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)
    await subject.runLaunch()
    #expect(eligibleRoutings(probe).isEmpty, "a first-run user was never a candidate")

    // And an already-admitted current revision, which has nothing left to take.
    let root2 = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root2) }
    try stagePriorAdmission(root: root2)
    let probe2 = Probe()
    probe2.admitted = true
    let subject2 = coordinator(root: root2, defaults: store, probe: probe2)
    await subject2.runLaunch()
    #expect(eligibleRoutings(probe2).isEmpty, "already on the current revision")
  }

  /// `upgrade_declined` reports a DURABLE refusal. Emitting one for a decline that failed to
  /// persist would report an outcome the very next launch contradicts.
  @MainActor
  @Test func declinedEventFiresOnlyWhenTheDeclinePersisted() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)

    let ok = Probe()
    let succeeds = coordinator(root: root, defaults: store, probe: ok)
    #expect(succeeds.recordUserDecline(source: .remove))
    #expect(
      ok.events.contains(.upgradeDeclined(targetRevision: Self.currentRevision)),
      "a persisted decline is reported")

    let root2 = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root2) }
    try stagePriorAdmission(root: root2)
    let failed = Probe()
    let fails = coordinator(
      root: root2, defaults: store, probe: failed, writeMarker: { _ in false })
    #expect(fails.recordUserDecline(source: .remove) == false)
    #expect(
      !failed.events.contains(.upgradeDeclined(targetRevision: Self.currentRevision)),
      "an unpersisted decline is NOT reported")
  }

  // MARK: - Onboarding deferral

  /// EG-1 polish is a LIMB. During first-run setup the HEART's model is downloading and dictation
  /// does not work at all until it lands, so a limb must never compete with it.
  @MainActor
  @Test func upgradeDefersWhileOnboardingIncomplete() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    let probe = Probe()
    let subject = coordinator(
      root: root, defaults: store, probe: probe, isOnboardingComplete: { false })

    await subject.runLaunch()

    #expect(probe.ensureCount == 0, "the limb stands aside while the heart's model downloads")
  }

  /// The deferral must RE-ARM in the same session. `runLaunch` fires once at bootstrap, so without
  /// this the deferral would silently mean "never, until the app is restarted" and the user would
  /// sit on a superseded model with nothing to tell them why.
  @MainActor
  @Test func upgradeStartsWhenOnboardingCompletesWithoutRelaunch() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    let probe = Probe()
    let onboarded = OnboardingGate()
    let subject = coordinator(
      root: root, defaults: store, probe: probe,
      isOnboardingComplete: { [onboarded] in onboarded.complete })

    await subject.runLaunch()
    #expect(probe.ensureCount == 0, "precondition: it really did defer")

    onboarded.complete = true
    #expect(await subject.onboardingDidComplete(), "it reports a REAL resumption to its caller")

    #expect(probe.ensureCount == 1, "the upgrade resumes without waiting for a relaunch")
  }

  /// The control that keeps the resume from becoming a second, unconditional launch trigger. An
  /// app whose onboarding was already finished at launch has nothing deferred, so completing
  /// onboarding again must do nothing at all.
  @MainActor
  @Test func onboardingCompletionDoesNothingWhenNothingWasDeferred() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    await subject.runLaunch()
    #expect(probe.ensureCount == 1)

    #expect(
      !(await subject.onboardingDidComplete()),
      "nothing was deferred, so the caller must NOT be told to run post-upgrade activation")

    #expect(probe.ensureCount == 1, "no second fetch: nothing had been deferred")
  }

  @MainActor
  private final class OnboardingGate {
    var complete = false
  }

  // MARK: - D2: a prior revision was admitted

  @MainActor
  @Test func autoUpgradeStartsWhenPriorRevisionMarkerExists() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    await subject.runLaunch()

    #expect(probe.ensureCount == 1, "a superseded revision with surviving bytes owes a fetch")
  }

  /// The negative control for the case above, and the invariant `EGOneRuntime`'s never-fetch
  /// comment protects: a user who never had EG-1 has no prior marker, so nothing starts behind
  /// their back. Same code, same launch, only the marker removed.
  @MainActor
  @Test func autoUpgradeDoesNotStartForFirstRunUser() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    await subject.runLaunch()

    #expect(probe.ensureCount == 0, "no prior admission means no automatic download, ever")
  }

  /// A marker proves an install once completed, never that its bytes survive. Someone who
  /// reclaimed space in Finder must not have 2.9 GB re-fetched unasked.
  @MainActor
  @Test func markerWithoutFilesOnDiskDoesNotTriggerReinstall() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root, createFiles: false)
    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    await subject.runLaunch()

    #expect(probe.ensureCount == 0, "D2b: the marker survived but its bytes did not")
  }

  /// D1. An already-admitted current manifest owes nothing, even with a prior marker present.
  @MainActor
  @Test func admittedCurrentRevisionOwesNoUpgrade() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    let probe = Probe()
    probe.admitted = true
    let subject = coordinator(root: root, defaults: store, probe: probe)

    await subject.runLaunch()

    #expect(probe.ensureCount == 0)
  }

  /// An admission marker for ANOTHER family in the same shared metadata directory must not read
  /// as a superseded EG-1 revision. The directory is shared by every family, so identification
  /// has to be exact rather than "some marker is present".
  @MainActor
  @Test func anotherFamilysMarkerDoesNotTriggerUpgrade() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let metadata = metadataDirectory(root)
    let install = installDirectory(root)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    let foreign = ModelIdentity(
      family: .parakeet, name: "parakeet", revision: "v9", variant: "q5km", runtimeABI: "test")
    let file = "parakeet-weights.bin"
    try Data("x".utf8).write(to: install.appendingPathComponent(file))
    let marker = CacheAdmission.AdmissionMarker(
      manifestDigest: "d", admittedAt: Date(timeIntervalSince1970: 1),
      files: [.init(path: file, sizeBytes: 1, mtime: 1)])
    try JSONEncoder().encode(marker).write(
      to: metadata.appendingPathComponent("\(foreign.cacheKey).admission.json"))

    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    await subject.runLaunch()

    #expect(probe.ensureCount == 0, "a foreign family's marker is not our superseded revision")
  }

  /// Nil-class row of the lifecycle audit. An unreadable metadata directory yields no prior
  /// revision, which means no download — the failure direction that cannot cost a user bytes.
  @MainActor
  @Test func unreadableMetadataFailsClosed() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    // A FILE where the metadata directory should be: enumeration throws rather than returning
    // an empty list, which is the case a `try?` could quietly turn into "no markers".
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("EnviousWispr", isDirectory: true),
      withIntermediateDirectories: true)
    try Data("not a directory".utf8).write(to: metadataDirectory(root))

    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    await subject.runLaunch()

    #expect(probe.ensureCount == 0)
  }

  // MARK: - D4: the kill switch

  @MainActor
  @Test func killSwitchSuppressesAutomaticUpgrade() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    store.set(false, forKey: DeliveryFlags.key("enabled", family: .egOne))

    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    await subject.runLaunch()

    #expect(probe.ensureCount == 0, "delivery disabled means no automatic fetch")
  }

  // MARK: - The delete-first path stays monolith-only

  /// The highest-consequence assertion in this suite. The revision trigger must never reach the
  /// legacy delete-first branch: that branch is gated behind a digest-pinned `TrustedArtifact`,
  /// and a revision upgrade neither owns nor may remove the old store's bytes.
  @MainActor
  @Test func revisionTriggerNeverEntersLegacyDeleteFirst() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)

    // A file sitting exactly where the monolith would live, whose bytes do NOT match the
    // trusted fingerprint. Nothing on the revision path may touch it.
    let oldStore = root.appendingPathComponent("EnviousWispr/PolishModels", isDirectory: true)
    try FileManager.default.createDirectory(at: oldStore, withIntermediateDirectories: true)
    let decoy = oldStore.appendingPathComponent("eg-1-v1.gguf")
    try Data("not the trusted monolith".utf8).write(to: decoy)

    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    await subject.runLaunch()

    #expect(probe.ensureCount == 1, "the revision upgrade still runs")
    #expect(
      FileManager.default.fileExists(atPath: decoy.path),
      "the revision trigger must never delete old-store bytes")
    #expect(!probe.removedURLs.contains(decoy))
    #expect(!probe.events.contains(.legacyDetected))
    #expect(!probe.events.contains(.legacyRetired))
  }

  /// Preparation is not a no-op and must keep running on every launch, but WITHOUT the trusted
  /// fingerprint it may only sweep retired sidecars — never model bytes, and never the legacy
  /// owed marker. Asserts what preparation must NOT do, rather than that it did nothing.
  @MainActor
  @Test func legacyPreparationPreservesModelBytesWithoutTheMonolithFingerprint() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    let shard = installDirectory(root).appendingPathComponent("eg-1-v1-00001-of-00008.gguf")
    let owedMarker = metadataDirectory(root).appendingPathComponent("eg1-v1-replacement-owed")

    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    await subject.runLaunch()

    #expect(FileManager.default.fileExists(atPath: shard.path), "model bytes survive preparation")
    #expect(
      !FileManager.default.fileExists(atPath: owedMarker.path),
      "no legacy owed marker is written without a fingerprint match")
  }

  // MARK: - Containment scoping

  /// A legacy-store containment refusal describes the OLD store, which a revision upgrade never
  /// reads or deletes. Letting it block would permanently and silently deny every future model
  /// upgrade on a machine layout the user cannot know is the cause.
  @MainActor
  @Test func legacyContainmentRefusalDoesNotSuppressRevisionUpgrade() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    try makeOldStoreEscapeContainment(root: root)

    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    await subject.runLaunch()

    #expect(
      probe.events.contains(.legacyRetirementFailed(reason: .containment)),
      "precondition: containment really was refused")
    #expect(probe.ensureCount == 1, "the revision upgrade proceeds regardless")
  }

  /// The two-way control: the SAME containment refusal must still block the LEGACY obligation.
  /// Without this, the fix above could have widened into "containment never blocks anything".
  @MainActor
  @Test func legacyContainmentRefusalStillBlocksTheLegacyObligation() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    // Legacy owed, and NO prior-revision admission: the only obligation is the legacy one.
    let metadata = metadataDirectory(root)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    try Data().write(to: metadata.appendingPathComponent("eg1-v1-replacement-owed"))
    try makeOldStoreEscapeContainment(root: root)

    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    await subject.runLaunch()

    #expect(probe.events.contains(.legacyRetirementFailed(reason: .containment)))
    #expect(probe.ensureCount == 0, "containment still blocks the legacy obligation")
  }

  /// Points the old store at a symlink outside the app-support tree, which is what
  /// `prepareOnce`'s containment check refuses.
  private func makeOldStoreEscapeContainment(root: URL) throws {
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "eg1-outside-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let tree = root.appendingPathComponent("EnviousWispr", isDirectory: true)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: tree.appendingPathComponent("PolishModels", isDirectory: true),
      withDestinationURL: outside)
  }

  // MARK: - Decline semantics

  /// Remove is a statement about the MODEL. Without a recorded decline the previous revision's
  /// marker and shards outlive `remove()`, so the next launch would re-fetch exactly what the
  /// user just deleted.
  @MainActor
  @Test func autoUpgradeDoesNotStartAfterUserRemovedTheModel() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    #expect(subject.recordUserDecline(source: .remove))
    #expect(FileManager.default.fileExists(atPath: declineMarker(root).path))

    await subject.runLaunch()

    #expect(probe.ensureCount == 0, "a removed model stays removed, with its bytes still present")
  }

  /// The multi-producer distinction, for the case this test actually stages: a cancel arriving
  /// with NOTHING in flight. The settings row's own Cancel reaches the same hook as ours, so a
  /// cancel that is not attributable to us must not switch off the automatic path.
  ///
  /// **SCOPE — this case stages a cancel with NOTHING in flight, and that is all it proves.**
  /// It used to carry a note saying the JOINED case was uncovered and must not be written against
  /// then-current behaviour, because #2110 had two candidate designs. That is now settled and the
  /// joined case is covered by `joinedCancelDoesNotDeclineAndPendingAttributionRefuses` below.
  /// This case is kept as the third arm — no attempt registered at all — which neither of the
  /// other two reaches.
  @MainActor
  @Test func userInitiatedCancelDoesNotRecordDecline() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    #expect(subject.recordUserDecline(source: .cancel))
    #expect(
      !FileManager.default.fileExists(atPath: declineMarker(root).path),
      "no automatic upgrade was in flight, so this cancel says nothing about the model")

    await subject.runLaunch()

    #expect(probe.ensureCount == 1, "the automatic path is untouched by a user's own cancel")
  }

  /// The other half of that distinction: a cancel arriving WHILE our own upgrade is running is
  /// attributable to us and does record a decline.
  @MainActor
  @Test func cancelDuringAutomaticUpgradeRecordsDecline() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    let probe = Probe()

    // Cancel from inside the fetch, which is exactly when the adapter's hook would fire.
    let box = CancelBox()
    let subject = EGOneUpgradeCoordinator(
      appSupportDirectory: root,
      identity: Self.identity(),
      installDirectory: installDirectory(root),
      defaults: store,
      trustedArtifact: .init(name: "eg-1-v1.gguf", sizeBytes: 11, sha256: "unused-here"),
      ensureCurrentModel: { onWillRequestFetch, onFetchDecision in
        probe.ensureCount += 1
        onWillRequestFetch()
        // STARTED first, then the cancel — the real order. The controller reports
        // its decision when it decides, and Cancel arrives later, during the
        // fetch. Reporting it is what makes this case about ATTRIBUTION rather
        // than about the `.pending` refusal (#2110).
        onFetchDecision(.started)
        _ = box.coordinator?.recordUserDecline(source: .cancel)
        return .failed(DeliveryFailure(reason: .unknown, detail: "cancelled"))
      },
      currentModelIsAdmitted: { probe.admitted })
    box.coordinator = subject

    await subject.runLaunch()

    #expect(probe.ensureCount == 1)
    #expect(
      FileManager.default.fileExists(atPath: declineMarker(root).path),
      "a cancel during OUR upgrade is a decline of the upgrade")
  }

  /// The defect this issue names, and the fail-closed state that replaced the guess (#2110).
  ///
  /// `ModelDeliveryController` single-flights per identity, so an automatic ensure can JOIN a
  /// download the user started from the settings row. Before this, that made the user's own Cancel
  /// write a revision decline — suppressing the next automatic upgrade they had never refused.
  ///
  /// **Three arms, because each is satisfiable by the opposite bug.**
  ///
  /// - JOINED must write NO decline. Alone, this passes against a coordinator that never records
  ///   anything, which would break the feature to fix the bug.
  /// - STARTED must still write one. That arm lives in
  ///   `cancelDuringAutomaticUpgradeRecordsDecline` and is the reason this case does not repeat it.
  /// - PENDING — the decision has not reached the main actor — must REFUSE, returning `false` so
  ///   the caller blocks rather than guessing. Both guesses are wrong in a way the user notices:
  ///   assuming ours suppresses upgrades never refused; assuming theirs drops a real refusal and
  ///   re-fetches on the next launch, contradicting the Cancel just pressed. Refusing is the same
  ///   fail-closed direction C14 takes when a decline cannot be persisted.
  ///
  /// **Attribution is driven through the production seam**, the decision handler the controller
  /// invokes at the instant it decides start-vs-join. That the controller actually reports
  /// `.joined` on its join branch is a property of the controller, not of this coordinator, and is
  /// asserted separately — see the recipe filed with this change.
  @MainActor
  @Test func joinedCancelDoesNotDeclineAndPendingAttributionRefuses() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    let probe = Probe()
    let box = CancelBox()

    // Records what `recordUserDecline` ANSWERED, not merely whether a marker exists:
    // a refusal and a permitted-but-not-declining cancel both leave no marker, and
    // only the return value separates them.
    final class Answers: @unchecked Sendable {
      var whileJoined: Bool?
      var whilePending: Bool?
      var beforeEnteringController: Bool?
    }
    let answers = Answers()

    let subject = EGOneUpgradeCoordinator(
      appSupportDirectory: root,
      identity: Self.identity(),
      installDirectory: installDirectory(root),
      defaults: store,
      trustedArtifact: .init(name: "eg-1-v1.gguf", sizeBytes: 11, sha256: "unused-here"),
      ensureCurrentModel: { onWillRequestFetch, onFetchDecision in
        probe.ensureCount += 1
        // BEFORE entering the controller — this is the retirement-preparation
        // window, which can hash a 2.9 GB monolith. Nothing has been joined or
        // started, so a cancel here is the user's own and must be PERMITTED.
        // Registering `.pending` ahead of this refused it for the whole hash
        // (#2110 cloud review P2).
        answers.beforeEnteringController = box.coordinator?.recordUserDecline(source: .cancel)
        onWillRequestFetch()
        // Now inside the controller, decision not yet back: genuinely `.pending`.
        answers.whilePending = box.coordinator?.recordUserDecline(source: .cancel)
        // Now the controller's answer arrives: we joined someone else's download.
        onFetchDecision(.joined)
        answers.whileJoined = box.coordinator?.recordUserDecline(source: .cancel)
        return .failed(DeliveryFailure(reason: .unknown, detail: "cancelled"))
      },
      currentModelIsAdmitted: { probe.admitted })
    box.coordinator = subject

    await subject.runLaunch()

    #expect(probe.ensureCount == 1, "the ensure must actually have run, or the arms prove nothing")

    #expect(
      answers.beforeEnteringController == true,
      "before the ensure enters the controller nothing can have been joined, so the user's own cancel must be permitted, not refused while we hash a 2.9 GB file")
    #expect(
      answers.whilePending == false,
      "with attribution still pending a cancel must be REFUSED, not guessed either way")

    #expect(
      answers.whileJoined == true,
      "a joined cancel is permitted; it simply does not decline the revision")
    #expect(
      !FileManager.default.fileExists(atPath: declineMarker(root).path),
      "cancelling a download WE joined is the user cancelling THEIRS, and declines nothing")
  }

  @MainActor
  private final class CancelBox {
    var coordinator: EGOneUpgradeCoordinator?
  }

  /// Pressing Download or Try Again is the clearest possible statement of intent, so it clears a
  /// decline. It arrives through the adapter's `beforeEnsure` door.
  @MainActor
  @Test func userInitiatedDownloadClearsDecline() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    #expect(subject.recordUserDecline(source: .remove))
    #expect(FileManager.default.fileExists(atPath: declineMarker(root).path))

    _ = await subject.prepareForEnsure()

    #expect(!FileManager.default.fileExists(atPath: declineMarker(root).path))

    await subject.runLaunch()
    #expect(probe.ensureCount == 1, "the automatic path is armed again after an explicit ask")
  }

  /// A launch must NOT clear a decline on its way past. `runLaunch` deliberately calls
  /// `prepareForDownload()` rather than the `beforeEnsure` door for exactly this reason, and
  /// without that separation the decline would survive nothing.
  @MainActor
  @Test func launchDoesNotClearARecordedDecline() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    #expect(subject.recordUserDecline(source: .remove))
    await subject.runLaunch()
    await subject.runLaunch()

    #expect(
      FileManager.default.fileExists(atPath: declineMarker(root).path),
      "two launches must not erase the user's refusal")
    #expect(probe.ensureCount == 0)
  }

  /// Declining THIS revision must not suppress the NEXT one. The decline is keyed by cache key,
  /// so a later app shipping a newer revision reads a different marker.
  @MainActor
  @Test func declineIsScopedToTheRevisionThatWasDeclined() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)

    let declined = Probe()
    let first = coordinator(root: root, defaults: store, probe: declined)
    #expect(first.recordUserDecline(source: .remove))
    await first.runLaunch()
    #expect(declined.ensureCount == 0)

    // A later app version shipping the NEXT revision, same machine, same markers.
    let next = Probe()
    let second = coordinator(
      root: root, defaults: store, probe: next, identity: Self.identity(revision: "v4-eg3"))
    await second.runLaunch()

    #expect(next.ensureCount == 1, "declining one model says nothing about the next one")
  }

  /// A decline that cannot be PERSISTED must block the action. If the write fails and we proceed
  /// anyway, the refusal exists only in memory and the next launch re-fetches the model the user
  /// just declined — silently, which is what makes failing closed the only safe direction.
  @MainActor
  @Test func declineThatCannotBePersistedBlocksTheAction() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    // The legacy owed marker must survive a failed decline rather than being cleared by a
    // half-applied one.
    let owedMarker = metadataDirectory(root).appendingPathComponent("eg1-v1-replacement-owed")
    try Data().write(to: owedMarker)

    let probe = Probe()
    let subject = coordinator(
      root: root, defaults: store, probe: probe, writeMarker: { _ in false })

    #expect(
      subject.recordUserDecline(source: .remove) == false,
      "an unpersistable decline must not report success")
    #expect(!FileManager.default.fileExists(atPath: declineMarker(root).path))
    #expect(
      FileManager.default.fileExists(atPath: owedMarker.path),
      "the legacy marker is untouched, so nothing is left half-applied")
  }

  /// Overlapping automatic attempts. `runLaunch` is re-entered within one session when onboarding
  /// completes, so two automatic fetches can be live at once. With a Boolean flag the inner
  /// attempt's completion would clear it while the outer was still fetching, and a Cancel
  /// belonging to the outer attempt would be misattributed to the user's own download.
  @MainActor
  @Test func overlappingAutomaticAttemptsKeepCancelAttributedToUs() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    let probe = Probe()
    let box = CancelBox()

    let subject = EGOneUpgradeCoordinator(
      appSupportDirectory: root,
      identity: Self.identity(),
      installDirectory: installDirectory(root),
      defaults: store,
      trustedArtifact: .init(name: "eg-1-v1.gguf", sizeBytes: 11, sha256: "unused-here"),
      ensureCurrentModel: { onWillRequestFetch, onFetchDecision in
        probe.ensureCount += 1
        onWillRequestFetch()
        onFetchDecision(.started)
        if probe.ensureCount == 1 {
          // Re-enter while THIS attempt is still in flight, and let the inner one finish.
          await box.coordinator?.runLaunch()
          // The inner attempt has completed. A Boolean would now read false.
          _ = box.coordinator?.recordUserDecline(source: .cancel)
        }
        return .failed(DeliveryFailure(reason: .unknown, detail: "cancelled"))
      },
      currentModelIsAdmitted: { probe.admitted })
    box.coordinator = subject

    await subject.runLaunch()

    #expect(probe.ensureCount == 2, "precondition: the attempts really did overlap")
    #expect(
      FileManager.default.fileExists(atPath: declineMarker(root).path),
      "the outer attempt was still ours when the cancel arrived")
  }

  /// Every other case in this suite calls `recordUserDecline` on the coordinator DIRECTLY, which
  /// proves the coordinator's logic but says nothing about the wiring that feeds it. This one goes
  /// through the REAL adapter, so a future edit that passed the wrong producer — or the same one
  /// twice — fails here rather than shipping a Remove that reads as a Cancel.
  @MainActor
  @Test func declineHookReceivesDistinctAdapterProducers() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    let install = installDirectory(root)
    let metadata = metadataDirectory(root)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)

    let registration = try EGOneDeliveryAdapterMappingTests.shardedFixtureRegistration(
      install: install, metadata: metadata)
    let controllerSuite = "eg1-revision-adapter-\(UUID().uuidString)"
    // The actor gets its OWN suite instance, constructed inline so it is region-moved rather than
    // bound into this test's isolation region first — the ModelDeliveryControllerTests pattern.
    let controller = ModelDeliveryController(defaults: UserDefaults(suiteName: controllerSuite)!)
    defer { UserDefaults.standard.removePersistentDomain(forName: controllerSuite) }

    let adapter = EGOneDeliveryAdapter(
      controller: controller, registration: registration, version: "v3-eg2", defaults: store)

    let recorder = ProducerRecorder()
    adapter.installLegacyUpgradeHooks(
      beforeEnsure: { true },
      beforeDecline: { [recorder] source in
        recorder.sources.append(source)
        return true
      },
      onAdmitted: {})

    await adapter.cancel()
    _ = await adapter.remove()

    #expect(
      recorder.sources == [.cancel, .remove],
      "the adapter must report WHICH action declined, in order, and never the same one twice")
  }

  @MainActor
  private final class ProducerRecorder {
    var sources: [EGOneUpgradeCoordinator.DeclineSource] = []
  }

  /// A successful admission settles the decline: leaving it behind would suppress the next
  /// revision for a reason the user could never discover.
  @MainActor
  @Test func admissionClearsTheDecline() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let (store, suite) = try defaults()
    defer { store.removePersistentDomain(forName: suite) }

    try stagePriorAdmission(root: root)
    let probe = Probe()
    let subject = coordinator(root: root, defaults: store, probe: probe)

    #expect(subject.recordUserDecline(source: .remove))
    #expect(FileManager.default.fileExists(atPath: declineMarker(root).path))

    probe.admitted = true
    await subject.runLaunch()

    #expect(
      !FileManager.default.fileExists(atPath: declineMarker(root).path),
      "the model demonstrably installed, so the refusal no longer describes reality")
  }
}
