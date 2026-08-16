import CryptoKit
import EnviousWisprModelDelivery
import Foundation

/// Owns one concern: **EG-1's installed bytes are superseded and a replacement is owed.**
///
/// That obligation has exactly two sources, and one response path serves both (#2096 §3b):
///
/// 1. **An unsupported, app-owned monolith** — the original `eg-1-v1.gguf`. Detected by a pinned
///    size+digest, marked owed, then unlinked. This source, and only this source, deletes bytes.
/// 2. **A superseded revision** — a prior revision of the SAME model was admitted, its bytes are
///    still on disk, and the manifest this app ships names a different revision. Deletes nothing;
///    the shared promotion path orphan-cleans the old shards once the new set is admitted.
///
/// The response is identical either way: owe, fetch through the adapter, then admit or decline.
/// The delete-first step stays gated behind the digest-pinned `TrustedArtifact` and is unreachable
/// from the revision trigger.
///
/// It still does not understand current shards, download them, verify them, or admit them. Those
/// responsibilities stay in EGOneDeliveryAdapter and ModelDeliveryController.
@MainActor
public final class EGOneUpgradeCoordinator {
  /// Which user action produced a decline. Cancel and Remove reach one hook but do NOT mean the
  /// same thing, and #2066's lesson is not to attach meaning to a state with several producers
  /// without distinguishing them. Remove is a statement about the MODEL; Cancel is a statement
  /// about THIS DOWNLOAD, and the settings row can start a download we did not.
  /// Internal on purpose. Both producers (`EGOneDeliveryAdapter.cancel` and `.remove`) and the
  /// hook that carries this live in this module, so widening it to `public` would enlarge the
  /// shipped surface for no consumer.
  enum DeclineSource: Sendable, Equatable {
    case cancel
    case remove
  }

  public struct TrustedArtifact: Sendable, Equatable {
    public let name: String
    public let sizeBytes: Int64
    public let sha256: String

    public init(name: String, sizeBytes: Int64, sha256: String) {
      self.name = name
      self.sizeBytes = sizeBytes
      self.sha256 = sha256
    }
  }

  public enum FailureReason: String, Sendable, Equatable {
    case markerWrite = "marker_write"
    case delete
    case unreadable
    case containment
  }

  /// Where an ELIGIBLE upgrade actually went. Emitted for every eligible install, including the
  /// ones that go nowhere, because the denominator is the point: an upgrade that never begins is
  /// the exact failure this whole path exists to prevent, and counting only started attempts
  /// would grade the successes and hide it.
  public enum UpgradeRouting: String, Sendable, Equatable {
    case started
    case declined
    case disabled
    case deferredOnboarding = "deferred_onboarding"
  }

  public enum Event: Sendable, Equatable {
    case legacyDetected
    case legacyRetired
    case legacyRetirementFailed(reason: FailureReason)
    case replacementCompleted
    case replacementDeclined
    case upgradeEligible(
      routing: UpgradeRouting, targetRevision: String,
      deliveryEnabled: Bool, onboardingComplete: Bool)
    case upgradeDeclined(targetRevision: String)
  }

  public static let shippedLegacyArtifact = TrustedArtifact(
    name: "eg-1-v1.gguf",
    sizeBytes: 2_889_511_680,
    sha256: "3343fc1a30a3e82df7499a4775ef73dd6e28dea1cc39bb58197ec0b66ec874f6"
  )

  public var onEvent: (@MainActor @Sendable (Event) -> Void)?

  /// EG-1's local vocabulary is now the shared one (#1386 PR-2a). The mechanism moved to
  /// `LegacyRetirement`; this policy did not. Kept as an alias so this file's call sites and
  /// its 29 tests read exactly as before.
  private typealias Fingerprint = LegacyRetirement.SetVerdict

  private let appSupportDirectory: URL
  private let defaults: UserDefaults
  private let trustedArtifact: TrustedArtifact

  /// The identity and install location of the manifest THIS app ships. Needed to recognise a
  /// marker belonging to a different revision of the same model, and to check whether that
  /// revision's files survive. Injected from the composition root, which already holds the
  /// registration, rather than widening the adapter's surface to expose it.
  private let identity: ModelIdentity
  private let installDirectory: URL

  /// True only while THIS coordinator is driving a fetch it started itself. It distinguishes an
  /// automatic upgrade from a download the user began in settings — the two reach the same
  /// adapter hooks and must not mean the same thing on cancel.
  ///
  /// A COUNT, not a flag. `runLaunch()` runs once at bootstrap today, but it is re-entered within
  /// the same session when onboarding completes, so two automatic attempts can overlap. With a
  /// plain Boolean the first to finish would clear it while the second was still fetching, and a
  /// Cancel belonging to that second attempt would be misread as the user's own.
  private var automaticUpgradeInFlightCount = 0
  private var automaticUpgradeInFlight: Bool { automaticUpgradeInFlightCount > 0 }

  /// Whether first-run setup has finished. EG-1 polish is a LIMB; during onboarding the HEART's
  /// model (Parakeet or WhisperKit) is downloading, and dictation does not work at all until it
  /// lands. A limb must never compete with it for bandwidth or disk.
  private let isOnboardingComplete: @MainActor @Sendable () -> Bool

  /// Set when a launch was turned away by onboarding, and the only thing `onboardingDidComplete`
  /// acts on. Without it that entry point would be a second, unconditional launch trigger.
  private var deferredForOnboarding = false

  private let ensureCurrentModel:
    @MainActor @Sendable () async -> ModelDeliveryController.DeliveryOutcome
  private let currentModelIsAdmitted: @MainActor @Sendable () async -> Bool

  /// nil in production: `LegacyRetirement` then hashes the descriptor it verified, so the
  /// digest and the identity provably describe one inode. Tests inject a closure.
  private let hashFile: (@Sendable (URL) async throws -> String)?
  private let writeMarker: @MainActor @Sendable (URL) -> Bool
  private let removeItem: @MainActor @Sendable (URL) throws -> Void

  private var preparationTask: Task<Bool, Never>?
  private var containmentRefused = false

  public convenience init(
    adapter: EGOneDeliveryAdapter,
    appSupportDirectory: URL,
    identity: ModelIdentity,
    installDirectory: URL,
    isOnboardingComplete: @escaping @MainActor @Sendable () -> Bool,
    defaults: UserDefaults? = nil,
    trustedArtifact: TrustedArtifact = shippedLegacyArtifact
  ) {
    self.init(
      appSupportDirectory: appSupportDirectory,
      identity: identity,
      installDirectory: installDirectory,
      defaults: defaults
        ?? UserDefaults(suiteName: DeliveryFlags.suiteName)
        ?? .standard,
      trustedArtifact: trustedArtifact,
      isOnboardingComplete: isOnboardingComplete,
      ensureCurrentModel: { [weak adapter] in
        guard let adapter else {
          return .failed(DeliveryFailure(reason: .unknown, detail: "adapter_released"))
        }
        return await adapter.ensureAvailable()
      },
      currentModelIsAdmitted: { [weak adapter] in
        guard let adapter else { return false }
        return await adapter.isAdmitted()
      }
    )

    // The adapter retains these closures, and therefore this coordinator.
    // The coordinator's adapter closures above are weak: no cycle.
    adapter.installLegacyUpgradeHooks(
      beforeEnsure: { [self] in await prepareForEnsure() },
      beforeDecline: { [self] source in recordUserDecline(source: source) },
      onAdmitted: { [self] in handleAdmission() }
    )
  }

  /// Internal test seam. It changes no production abstraction.
  init(
    appSupportDirectory: URL,
    identity: ModelIdentity,
    installDirectory: URL,
    defaults: UserDefaults,
    trustedArtifact: TrustedArtifact,
    isOnboardingComplete: @escaping @MainActor @Sendable () -> Bool = { true },
    ensureCurrentModel:
      @escaping @MainActor @Sendable () async -> ModelDeliveryController.DeliveryOutcome,
    currentModelIsAdmitted: @escaping @MainActor @Sendable () async -> Bool,
    hashFile: (@Sendable (URL) async throws -> String)? = nil,
    writeMarker: (@MainActor @Sendable (URL) -> Bool)? = nil,
    removeItem: (@MainActor @Sendable (URL) throws -> Void)? = nil
  ) {
    self.appSupportDirectory = appSupportDirectory
    self.identity = identity
    self.installDirectory = installDirectory
    self.isOnboardingComplete = isOnboardingComplete
    self.defaults = defaults
    self.trustedArtifact = trustedArtifact
    self.ensureCurrentModel = ensureCurrentModel
    self.currentModelIsAdmitted = currentModelIsAdmitted
    self.hashFile = hashFile
    self.writeMarker = writeMarker ?? Self.atomicWriteMarker
    self.removeItem = removeItem ?? { try FileManager.default.removeItem(at: $0) }
  }

  private var oldStoreDirectory: URL {
    appSupportDirectory.appendingPathComponent(
      "EnviousWispr/PolishModels", isDirectory: true)
  }

  private var legacyArtifactURL: URL {
    oldStoreDirectory.appendingPathComponent(trustedArtifact.name)
  }

  private var metadataDirectory: URL {
    appSupportDirectory.appendingPathComponent(
      "EnviousWispr/ModelDelivery", isDirectory: true)
  }

  private var owedMarkerURL: URL {
    metadataDirectory.appendingPathComponent("eg1-v1-replacement-owed")
  }

  private var isReplacementOwed: Bool {
    FileManager.default.fileExists(atPath: owedMarkerURL.path)
  }

  /// Revision-scoped, so declining THIS model never suppresses the NEXT one. Keyed by
  /// `cacheKey`, which is documented filesystem-safe and already carries family, name,
  /// revision and variant.
  private var revisionDeclineMarkerURL: URL {
    metadataDirectory.appendingPathComponent("eg1-revision-decline-\(identity.cacheKey)")
  }

  private var isRevisionDeclined: Bool {
    FileManager.default.fileExists(atPath: revisionDeclineMarkerURL.path)
  }

  /// D2 + D2b + D3 of plan §3.2. **D1 (the current manifest is not admitted) is deliberately NOT
  /// here** — `runLaunch` already computes it asynchronously, and keeping this property
  /// synchronous is what lets the decline path consult it.
  ///
  /// D2 is "a prior revision was admitted", never "the install directory has files in it".
  /// `remove()` deletes only the roots the CURRENT manifest claims
  /// (`ModelDeliveryController.remove`), so a previous revision's shards outlive it — testing
  /// for files would resurrect a model the user deliberately deleted.
  /// D2 + D2b ALONE — a prior revision was admitted and its bytes survive. Deliberately separate
  /// from the decline check so eligibility can be classified BEFORE any gate: a declined or
  /// disabled install is still an install that could have upgraded, and it belongs in the
  /// denominator.
  private var hasSupersededInstall: Bool {
    PriorRevisionAdmission.supersededInstallSurvives(
      identity: identity,
      metadataDirectory: metadataDirectory,
      installDirectory: installDirectory)
  }

  /// Which gate an eligible upgrade will actually meet, evaluated in the order the gates are
  /// taken so the reported reason is the OUTERMOST one that stops it. `.started` is a statement
  /// about routing, not about success: the fetch can still fail, and that failure is reported by
  /// the shared `model_delivery.*` funnel rather than duplicated here.
  /// Evaluated in the order `runLaunch` ACTUALLY takes the gates — disabled, then onboarding,
  /// then decline — so the reported reason is the one that really stopped this install. An
  /// earlier draft checked decline before onboarding and would have reported `.declined` for an
  /// install that was in fact waiting on first-run setup.
  ///
  /// Both facts are passed in rather than re-read, so the routing cannot disagree with the gates
  /// the same launch then takes.
  private func currentRouting(
    deliveryEnabled: Bool, onboardingComplete: Bool
  ) -> UpgradeRouting {
    if !deliveryEnabled { return .disabled }
    if !onboardingComplete { return .deferredOnboarding }
    if isRevisionDeclined { return .declined }
    return .started
  }

  private var isRevisionUpgradeOwed: Bool {
    guard !isRevisionDeclined else { return false }
    return PriorRevisionAdmission.supersededInstallSurvives(
      identity: identity,
      metadataDirectory: metadataDirectory,
      installDirectory: installDirectory)
  }

  @discardableResult
  private func writeRevisionDecline() -> Bool {
    guard !isRevisionDeclined else { return true }
    return writeMarker(revisionDeclineMarkerURL)
  }

  private func clearRevisionDecline() {
    guard isRevisionDeclined else { return }
    try? removeItem(revisionDeclineMarkerURL)
  }

  // C1 - One real switch for adapter and coordinator.
  private var isEnabled: Bool {
    EGOneDeliveryAdapter.isDeliveryEnabled(defaults: defaults)
  }

  // C2 - Prepare before the admitted return so an exact reintroduced monolith
  // is still retired.
  public func runLaunch() async {
    // C16 - Classify ELIGIBILITY before every gate, and emit it before taking any of them.
    //
    // This is the denominator, and it must count the installs that go nowhere. #1386's ship
    // criterion counted from `attempt_started`, which grades only the upgrades that began — but an
    // upgrade that never begins is the exact failure this path exists to prevent, so that shape
    // would have reported success while hiding it. Reading admission while the kill switch is off
    // is a read, never a mutation, and matches what `adoptIfPresent` already does when disabled.
    let admitted = await currentModelIsAdmitted()
    let deliveryEnabled = isEnabled
    let onboardingComplete = isOnboardingComplete()
    if !admitted, hasSupersededInstall {
      emit(
        .upgradeEligible(
          routing: currentRouting(
            deliveryEnabled: deliveryEnabled, onboardingComplete: onboardingComplete),
          targetRevision: identity.revision,
          deliveryEnabled: deliveryEnabled,
          onboardingComplete: onboardingComplete))
    }

    guard deliveryEnabled else { return }

    // C15 - Defer the WHOLE launch while first-run setup is unfinished, before preparation and
    // before any obligation is classified. Preparation can hash a 2.9 GB monolith, so gating only
    // the fetch would still put a limb in the heart's way. Nothing is lost by waiting: this is
    // re-entered the moment onboarding completes, in the same session.
    guard onboardingComplete else {
      deferredForOnboarding = true
      return
    }

    // C11 - Classify the REVISION obligation BEFORE preparation runs.
    //
    // Preparation can latch `containmentRefused` on a legacy-store topology that a revision
    // upgrade neither reads nor deletes. Deciding afterwards would let that refusal suppress
    // every future model upgrade permanently and silently, on a machine layout the user cannot
    // know is the cause. Fail-closed is correct for deleting bytes; it is not correct for
    // declining to fetch them.
    let revisionUpgradeOwed = !admitted && isRevisionUpgradeOwed

    // C3 - Preparation still runs on EVERY enabled launch, unconditionally. It is not merely a
    // check: it is where an unmarked monolith is discovered, fingerprinted, marked owed, and
    // unlinked. Gating it on a known obligation would mean a first-encounter monolith is never
    // retired at all.
    let prepared = await prepareForDownload()

    if admitted {
      handleAdmission()
      return
    }

    // The LEGACY obligation keeps both of its original guards: preparation must have succeeded
    // and containment must not have been refused. Only its scope narrowed.
    let legacyOwed = prepared && !containmentRefused && isReplacementOwed

    guard legacyOwed || revisionUpgradeOwed else { return }

    // C7 - The existing adapter/controller is the only download door.
    //
    // Marked in-flight across the fetch so a Cancel arriving through the adapter's shared
    // decline hook is attributable to US rather than to the settings row.
    automaticUpgradeInFlightCount += 1
    let outcome = await ensureCurrentModel()
    automaticUpgradeInFlightCount -= 1

    if case .admitted = outcome {
      handleAdmission()
    }
  }

  /// Re-entry when first-run setup finishes, WITHOUT waiting for a relaunch.
  ///
  /// `runLaunch()` runs once at bootstrap, so a deferral with no re-arm would not mean "later" —
  /// it would mean "never, until the app is restarted", and the user would sit on a superseded
  /// model with nothing to tell them why. Guarded on `deferredForOnboarding` so this is a
  /// RESUMPTION of a turned-away launch rather than a second unconditional trigger: an app whose
  /// onboarding was already complete at launch does nothing here.
  /// Returns whether a deferred launch was actually resumed. The caller needs that answer: the
  /// bootstrap launch path is `runLaunch()` FOLLOWED BY `activateAfterAutomaticReplacementIfNeeded()`,
  /// and a resumption that ran only the first half would admit the model and never boot the server,
  /// leaving polish silently unavailable until some other activation path happened to run.
  @discardableResult
  public func onboardingDidComplete() async -> Bool {
    guard deferredForOnboarding else { return false }
    deferredForOnboarding = false
    await runLaunch()
    return true
  }

  /// The adapter's `beforeEnsure` door, and the ONLY caller that may clear a decline.
  ///
  /// Reached by both an automatic upgrade and a user pressing Download / Try Again. Only the
  /// second clears: pressing Download is the clearest possible statement of intent, while our
  /// own fetch must not erase the record of a refusal it is about to act against. `runLaunch`
  /// calls `prepareForDownload()` directly rather than coming through here, so a launch can
  /// never clear a decline on its way past.
  ///
  /// This lives on the coordinator rather than inside the composition root's closure so it is
  /// reachable from the test seam; logic that only exists in a wiring closure cannot be tested.
  func prepareForEnsure() async -> Bool {
    if !automaticUpgradeInFlight { clearRevisionDecline() }
    return await prepareForDownload()
  }

  // C3 - Launch and a simultaneous Download click share one fingerprint/delete.
  func prepareForDownload() async -> Bool {
    guard isEnabled else { return false }

    if let preparationTask {
      return await preparationTask.value
    }

    let task = Task { @MainActor [self] in
      await prepareOnce()
    }
    preparationTask = task
    let result = await task.value
    preparationTask = nil
    return result
  }

  private func prepareOnce() async -> Bool {
    guard isEnabled else { return false }

    containmentRefused = false

    // C4 - Compare resolved candidate to a tree built from the resolved root.
    let resolvedRoot =
      appSupportDirectory.resolvingSymlinksInPath().standardizedFileURL
    let canonicalTree = resolvedRoot.appendingPathComponent(
      "EnviousWispr", isDirectory: true
    ).standardizedFileURL
    let resolvedOldStore =
      oldStoreDirectory.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedOldStore.path.hasPrefix(canonicalTree.path + "/") else {
      containmentRefused = true
      emit(.legacyRetirementFailed(reason: .containment))
      return true
    }

    sweepExactRetiredSidecars()

    if isReplacementOwed {
      return await retireMarkerBackedArtifactIfNeeded()
    }

    // C4 - Exact path + regular file + size + digest.
    switch await fingerprintLegacyArtifact() {
    case .absent, .mismatch:
      return true

    case .unreadable:
      emit(.legacyRetirementFailed(reason: .unreadable))
      return true

    case .match:
      emit(.legacyDetected)

      // C5 - Marker is the linearization point and precedes unlink.
      guard writeMarker(owedMarkerURL) else {
        emit(.legacyRetirementFailed(reason: .markerWrite))
        return false
      }

      do {
        // No suspension occurs between successful marker persistence and unlink.
        try removeItem(legacyArtifactURL)
      } catch {
        // C6 - Keep the marker and block the replacement.
        emit(.legacyRetirementFailed(reason: .delete))
        return false
      }

      emit(.legacyRetired)
      cleanRetiredStoreMetadataAfterProvenOwnership()
      return true
    }
  }

  private func retireMarkerBackedArtifactIfNeeded() async -> Bool {
    switch await fingerprintLegacyArtifact() {
    case .absent:
      cleanRetiredStoreMetadataAfterProvenOwnership()
      return true

    case .match:
      emit(.legacyDetected)
      do {
        try removeItem(legacyArtifactURL)
      } catch {
        emit(.legacyRetirementFailed(reason: .delete))
        return false
      }
      emit(.legacyRetired)
      cleanRetiredStoreMetadataAfterProvenOwnership()
      return true

    case .mismatch:
      // The marker proves a replacement is owed, but no longer proves these
      // changed bytes are ours. Preserve them and continue the replacement.
      return true

    case .unreadable:
      // It may still be the trusted artifact. Refuse to delete or duplicate it
      // until it can be classified.
      emit(.legacyRetirementFailed(reason: .unreadable))
      return false
    }
  }

  /// Delegates to the shared mechanism (#1386 PR-2a). EG-1's artifact is a single flat file,
  /// so it passes a one-element set and reads the roll-up.
  ///
  /// A thrown error here is a cancellation and nothing else: `LegacyRetirement.fingerprint`
  /// classifies every other failure into a verdict and rethrows only `CancellationError`.
  /// EG-1 exposes no cancellation path for its preparation task today, so this branch is
  /// unreachable from EG-1 — but it must stay honest rather than fold a cancel into
  /// `.unreadable`, which would write a permanent decline for a user who asked us to stop.
  private func fingerprintLegacyArtifact() async -> Fingerprint {
    let file = LegacyRetirement.TrustedFile(
      relativePath: trustedArtifact.name,
      sizeBytes: trustedArtifact.sizeBytes,
      sha256: trustedArtifact.sha256)
    do {
      let verdicts = try await LegacyRetirement.fingerprint(
        root: oldStoreDirectory, files: [file], hashFile: hashFile)
      return LegacyRetirement.rollUp(verdicts)
    } catch {
      return .unreadable
    }
  }

  private func sweepExactRetiredSidecars() {
    for name in [
      "\(trustedArtifact.name).partial",
      "\(trustedArtifact.name).resume.json",
    ] {
      let url = oldStoreDirectory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: url.path) {
        try? removeItem(url)
      }
    }
    removeOldStoreIfEmpty()
  }

  private func cleanRetiredStoreMetadataAfterProvenOwnership() {
    for name in [
      "installed-manifest.json",
      "\(trustedArtifact.name).partial",
      "\(trustedArtifact.name).resume.json",
    ] {
      let url = oldStoreDirectory.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: url.path) {
        try? removeItem(url)
      }
    }
    removeOldStoreIfEmpty()
  }

  private func removeOldStoreIfEmpty() {
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: oldStoreDirectory,
        includingPropertiesForKeys: nil
      ),
      entries.isEmpty
    else {
      return
    }
    try? removeItem(oldStoreDirectory)
  }

  // C8 - Admission clears the marker only while model delivery is enabled and
  // preparation did not refuse the old-store topology.
  private func handleAdmission() {
    guard isEnabled else { return }

    // C12 - A successful admission settles the REVISION decline regardless of legacy
    // containment. Containment describes the old PolishModels store, which this obligation
    // never touched; leaving a decline behind after the model demonstrably installed would
    // suppress the NEXT revision for no reason the user could discover.
    clearRevisionDecline()

    guard !containmentRefused else { return }
    let wasOwed = isReplacementOwed
    guard clearOwedMarker() else { return }
    if wasOwed {
      emit(.replacementCompleted)
    }
  }

  // C9 - Explicit Cancel/Remove records decline even while delivery is off.
  //
  // C13 - The two producers are separated rather than inferred. **Remove** is a statement about
  // the MODEL and always declines while an upgrade is owed — without it, `remove()` leaves the
  // previous revision's marker and shards untouched, so the next launch would re-fetch 2.9 GB of
  // the very thing the user just deleted. **Cancel** is a statement about THIS DOWNLOAD, so it
  // declines only when the download was ours; the settings row's own Cancel must not poison the
  // automatic path.
  // C14 - A decline that could not be PERSISTED must block the action, exactly as the legacy
  // marker write does. Ignoring a failed write would let Cancel/Remove succeed while the refusal
  // existed only in memory, and the next launch would automatically re-fetch the model the user
  // just declined — the failure being silent is precisely what makes it worth failing closed.
  // Written before the owed marker is cleared, so a failure leaves BOTH markers in their
  // pre-decline state rather than a half-applied one.
  func recordUserDecline(source: DeclineSource) -> Bool {
    let declinesRevision = source == .remove ? isRevisionUpgradeOwed : automaticUpgradeInFlight
    guard !declinesRevision || writeRevisionDecline() else { return false }
    // Emitted only after the decline is DURABLE. An event for a refusal that failed to persist
    // would report an outcome the next launch is about to contradict.
    if declinesRevision { emit(.upgradeDeclined(targetRevision: identity.revision)) }

    let wasOwed = isReplacementOwed
    guard clearOwedMarker() else { return false }
    if wasOwed {
      emit(.replacementDeclined)
    }
    return true
  }

  @discardableResult
  private func clearOwedMarker() -> Bool {
    guard isReplacementOwed else { return true }
    do {
      try removeItem(owedMarkerURL)
      return true
    } catch {
      return false
    }
  }

  // C10 - Typed, bounded, content-free events.
  private func emit(_ event: Event) {
    onEvent?(event)
  }

  private static func atomicWriteMarker(_ url: URL) -> Bool {
    LegacyRetirement.writeMarkerAtomically(url)
  }

}
