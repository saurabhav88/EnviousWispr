import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing
import os

@testable import EnviousWisprLLM
@testable import EnviousWisprLocalPolish
@testable import EnviousWisprModelDelivery

/// #4845 LIFE-5: when a model downloaded in this process is ready for dictation.
///
/// **Product Outcome.** When this fails, the "AI polish download complete" pill shows while the
/// model cannot polish yet (a skipped, failed or summary-only check), never shows after a busy
/// engine frees up, shows for a model the user already switched away from, or a stale press of
/// an old pill spends a newer one.
@Suite("Dictation activation outcome (#4845)", .serialized, .tags(.productOutcome))
@MainActor
struct DictationActivationOutcomeTests {
  fileprivate typealias Fixture = EGOneAdapterLifecycleTests.Fixture

  /// What the fake probe answers, and a hook that runs while it answers.
  final class ProbeScript: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<(verdict: EGOneHealth, calls: Int)>(
      initialState: (.green, 0))
    var duringProbe: (@Sendable () -> Void)?
    var verdict: EGOneHealth {
      get { lock.withLock { $0.verdict } }
      set { lock.withLock { $0.verdict = newValue } }
    }
    var calls: Int { lock.withLock { $0.calls } }
    func answer() -> EGOneHealth {
      duringProbe?()
      return lock.withLock {
        $0.calls += 1
        return $0.verdict
      }
    }
  }

  /// The selection and busy facts the composition root supplies, settable from the probe.
  final class Facts: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<(active: Bool, busy: Bool)>(
      initialState: (true, false))
    var active: Bool {
      get { lock.withLock { $0.active } }
      set { lock.withLock { $0.active = newValue } }
    }
    var busy: Bool {
      get { lock.withLock { $0.busy } }
      set { lock.withLock { $0.busy = newValue } }
    }
  }

  struct Rig {
    let runtime: LocalPolishRuntime
    let probe: ProbeScript
    let facts: Facts
    let releases: ReleaseRecorder
    /// Builds another model's runtime over the same fake server, delivery and coordinator.
    let sibling: @MainActor (LocalPolishModelID) -> (LocalPolishRuntime, Facts, ReleaseRecorder)
    let coordinator: LocalPolishServerCoordinator
    let cleanup: () -> Void
  }

  /// An admitted EG-1 over the shared fake server (the `EGOneRecordingRecoveryTests` rig), with
  /// the probe answered by `ProbeScript`.
  func makeRig() async throws -> Rig {
    let fixture = try Fixture()
    let suite = "eg1-activation-outcome-\(UUID().uuidString)"
    let store = try #require(TestDefaults.suite(suite))
    let install = fixture.root.appendingPathComponent("base-install", isDirectory: true)
    let metadata = fixture.root.appendingPathComponent("metadata", isDirectory: true)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    let registration = try EGOneDeliveryAdapterMappingTests.shardedFixtureRegistration(
      install: install, metadata: metadata)
    try Data(count: 1000).write(to: install.appendingPathComponent("eg-1-00001-of-00002.gguf"))
    try Data(count: 2000).write(to: install.appendingPathComponent("eg-1-00002-of-00002.gguf"))
    let controller = ModelDeliveryController(defaults: TestDefaults.suite(suite)!)
    let delivery = EGOneDeliveryAdapter(
      controller: controller, registration: registration, version: nil, defaults: store)
    try #require(await delivery.adoptIfPresent(), "fixture model was not admitted")
    let manifest = EGOneManifest(
      modelName: LLMProvider.egOneModelName, version: "v2-sharded",
      contextTokens: 4096, promptTemplateID: "eg1-v1", minAppVersion: "0",
      downloadURL: URL(string: "https://example.invalid/eg1.gguf")!)
    let probe = ProbeScript()
    let engine = TestLocalPolishEngine(makeHealthProbe: { _, _ in { _ in probe.answer() } })
    let coordinator = LocalPolishServerCoordinator()
    let make: @MainActor (LocalPolishModelID) -> (LocalPolishRuntime, Facts, ReleaseRecorder) = {
      model in
      let facts = Facts()
      let runtime = LocalPolishRuntime(
        manifest: manifest.runtimeFacts(expectedModelName: LLMProvider.egOneModelName),
        serverBinaryURL: fixture.binary, delivery: delivery,
        engine: fixture.engine(engine), defaults: store, coordinator: coordinator, modelID: model)
      runtime.isActiveProvider = { facts.active }
      runtime.isSharedEngineBusy = { facts.busy }
      runtime.downloadConfirmationQuietPeriod = .zero
      let releases = ReleaseRecorder()
      runtime.onReleaseObservedForTesting = { releases.record() }
      return (runtime, facts, releases)
    }
    let (runtime, facts, releases) = make(.egOne(.full))
    return Rig(
      runtime: runtime, probe: probe, facts: facts, releases: releases, sibling: make,
      coordinator: coordinator,
      cleanup: {
        runtime.terminateServerForAppQuit()
        store.removePersistentDomain(forName: suite)
        fixture.cleanup()
      })
  }

  /// Delivery reports a completed transfer for this model: the call
  /// `EGOneDeliveryAdapter.observeCompletedTransfers` makes on the controller's `attemptCompleted`.
  func completeTransfer(_ rig: Rig) async -> UUID? {
    rig.runtime.transferCompleted()
    await rig.runtime.awaitDownloadConfirmationForTesting()
    return rig.runtime.completedDownloadIDForTesting
  }

  @Test("a passed probe and a download completed here make one notice; only its own id spends it")
  func greenQualifiesAndOnlyItsIDSpendsIt() async throws {
    let rig = try await makeRig()
    defer { rig.cleanup() }
    // Passed, but no download completed in this process: no notice.
    guard case .ready(let endpoint) = await rig.runtime.activateForDictation().value else {
      Issue.record("expected a passed check")
      return
    }
    #expect(rig.runtime.pendingDownloadNotice == nil)
    // The download completes; the check taken before it does not count, a new one on the ready
    // server does.
    let callsBefore = rig.probe.calls
    let id = try #require(await completeTransfer(rig))
    #expect(rig.probe.calls == callsBefore + 1, "a verdict from before the download was reused")
    let notice = try #require(rig.runtime.pendingDownloadNotice)
    #expect(notice.id == id && notice.endpoint == endpoint && notice.model == .egOne(.full))
    #expect(await rig.runtime.isCurrent(notice))
    rig.runtime.acknowledgeDownloadNotice(UUID())  // a stale pill
    #expect(rig.runtime.pendingDownloadNotice == notice, "a stale press spent a newer notice")
    rig.runtime.acknowledgeDownloadNotice(id)
    #expect(rig.runtime.pendingDownloadNotice == nil)
    #expect(rig.runtime.completedDownloadIDForTesting == nil)
    rig.runtime.acknowledgeDownloadNotice(id)  // repeated: nothing left to spend
    // The next passed check finds no completed download: no second pill.
    _ = await rig.runtime.activateForDictation().value
    #expect(rig.runtime.pendingDownloadNotice == nil)
  }

  @Test("only delivery's completed transfer counts as a download; a cache hit never does")
  func onlyACompletedTransferCounts() async throws {
    // When this fails, a model already on disk (or a second caller joining one download) shows
    // the download-complete pill, or a real download shows none.
    let identity = ModelIdentity(
      family: .egOne, name: "eg-1", revision: "r1", variant: "", runtimeABI: "gguf")
    let other = ModelIdentity(
      family: .egOne, name: "eg-1", revision: "r2", variant: "", runtimeABI: "gguf")
    let completed = DeliveryEvent.attemptCompleted(
      durationBucket: "lt_1m", bytesDownloadedBucket: "1_5gb", sourcesUsed: 1,
      finalSourceID: "cdn", repairedComponentsCount: 0)
    let filter = EGOneDeliveryAdapter.isCompletedTransfer
    #expect(filter(completed, identity, identity))
    #expect(!filter(completed, identity, other), "another model's download counted")
    #expect(!filter(.admittedWithoutFetch(reason: .markerFastPath), identity, identity))
    #expect(!filter(.attemptStarted(resumed: false), identity, identity))

    let rig = try await makeRig()
    defer { rig.cleanup() }
    _ = await rig.runtime.activateForDictation().value
    // An installed state alone (a cache hit, or a late replay of the stream) mints nothing.
    rig.runtime.applyInstallStateForTesting(.verifying)
    rig.runtime.applyInstallStateForTesting(.installed(version: nil))
    #expect(rig.runtime.completedDownloadIDForTesting == nil, "a cache hit counted as a download")
    // A completed transfer while another model is selected earns nothing.
    rig.facts.active = false
    #expect(await completeTransfer(rig) == nil)
  }

  @Test("a download of a newer revision is never confirmed on the older revision still running")
  func olderRevisionCannotConfirmANewerDownload() async throws {
    // When this fails, an upgrade shows "download complete" while the old model still answers.
    let rig = try await makeRig()
    defer { rig.cleanup() }
    guard case .ready = await rig.runtime.activateForDictation().value else {
      Issue.record("the current revision never came up")
      return
    }
    let newer = ModelIdentity(
      family: .egOne, name: "eg-1", revision: "next-revision", variant: "", runtimeABI: "gguf")
    let callsBefore = rig.probe.calls
    rig.runtime.transferCompleted(artifact: newer)
    await rig.runtime.awaitDownloadConfirmationForTesting()
    #expect(rig.probe.calls == callsBefore + 1, "the confirmation never probed")
    #expect(rig.runtime.pendingDownloadNotice == nil, "the old revision confirmed the new download")
    // A passed activation on that same older server does not confirm it either.
    guard case .ready = await rig.runtime.activateForDictation().value else {
      Issue.record("expected a passed check")
      return
    }
    #expect(rig.runtime.pendingDownloadNotice == nil)
    #expect(rig.runtime.completedDownloadIDForTesting != nil, "the newer download was forgotten")
  }

  @Test("a skipped, unchecked or failed check makes no notice")
  func outcomesThatCannotQualify() async throws {
    let rig = try await makeRig()
    defer { rig.cleanup() }
    rig.facts.busy = true
    #expect(await rig.runtime.activateForDictation().value == .readyUnchecked)
    #expect(await completeTransfer(rig) != nil)
    #expect(rig.runtime.pendingDownloadNotice == nil, "no check passed yet")
    #expect(await rig.runtime.activateForDictation().value == .readyUnchecked)
    #expect(rig.runtime.pendingDownloadNotice == nil)

    rig.facts.busy = false
    rig.probe.verdict = .red(reason: "probe_failed")
    #expect(
      await rig.runtime.activateForDictation().value
        == .failed(health: .red(reason: "probe_failed")))
    #expect(rig.runtime.pendingDownloadNotice == nil)

    rig.runtime.isBlockedByOtherPinnedSession = { true }
    #expect(await rig.runtime.activateForDictation().value == .skipped(.otherEnginePinned))
    #expect(rig.runtime.activateAndProbe() == nil, "the old entry point stopped refusing")
    #expect(rig.runtime.pendingDownloadNotice == nil)
  }

  @Test("after a busy engine frees up, one confirmation on the same server earns the notice")
  func releaseConfirmsOnTheSameResidentServer() async throws {
    let rig = try await makeRig()
    defer { rig.cleanup() }
    rig.facts.busy = true
    #expect(await rig.runtime.activateForDictation().value == .readyUnchecked)
    let id = try #require(await completeTransfer(rig))
    rig.facts.busy = false

    // A summary held the server and lets it go: the same server stays resident.
    guard case .granted(let reservation) = await rig.runtime.reserveServerForSummary() else {
      Issue.record("the summary was not granted the server")
      return
    }
    let callsBefore = rig.probe.calls
    await rig.runtime.releaseServerReservation(reservation)
    await rig.runtime.releaseServerReservation(reservation)  // stale repeat: no second run
    await Self.settleConfirmation(rig, releases: 1)
    #expect(rig.probe.calls == callsBefore + 1, "the release did not confirm exactly once")
    let notice = try #require(rig.runtime.pendingDownloadNotice)
    let current = await rig.runtime.isCurrent(notice)
    #expect(notice.id == id && current)

    // While a summary holds the server, the notice is not current for dictation.
    guard case .granted(let held) = await rig.runtime.reserveServerForSummary() else {
      Issue.record("the summary was not granted the server")
      return
    }
    #expect(await rig.runtime.isCurrent(notice) == false)
    await rig.runtime.releaseServerReservation(held)
    await Self.settleConfirmation(rig, releases: 2)
    #expect(rig.releases.count == 2, "a stale release was heard")
    #expect(rig.probe.calls == callsBefore + 1, "a notice already earned on this server reprobed")
    #expect(await rig.runtime.isCurrent(notice))
  }

  @Test("closed dictation admission makes the notice not live while the old server still reads ready")
  func admissionClosedIsNotLive() async throws {
    // When this fails, the pill renders while a summary holds the server, because the runtime's
    // own copy of the server state still says ready.
    let rig = try await makeRig()
    defer { rig.cleanup() }
    _ = await rig.runtime.activateForDictation().value
    _ = await completeTransfer(rig)
    let notice = try #require(rig.runtime.pendingDownloadNotice)
    #expect(rig.runtime.isLive(notice))
    guard case .granted(let reservation) = await rig.runtime.reserveServerForSummary() else {
      Issue.record("the summary was not granted the server")
      return
    }
    #expect(rig.runtime.serverActivity == .ready, "the runtime's copy still reads ready")
    #expect(rig.runtime.isLive(notice) == false, "admission closed but the notice read live")
    await rig.runtime.releaseServerReservation(reservation)
    #expect(rig.runtime.isLive(notice))
  }

  @Test(
    "after the same model restarts, only the new server's endpoint reads open for dictation",
    .timeLimit(.minutes(1)))
  func admissionIsBoundToTheServingEndpoint() async throws {
    // When this fails, the old notice renders (and is spent) in the moment after the model
    // restarted, while the runtime's own copy still names the old server and its green verdict.
    let rig = try await makeRig()
    defer { rig.cleanup() }
    _ = await rig.runtime.activateForDictation().value
    let first = try #require(
      await rig.coordinator.endpoint(for: .egOne(.full)), "the model never came up")
    #expect(rig.coordinator.dictationAdmissionOpenNow(for: .egOne(.full), endpoint: first))
    // The same model is stopped and started again: a new process, a new endpoint. A start that
    // meets the stop in progress answers not ready (#4951), so wait until the stop is published,
    // then until the coordinator ends that change (a removal nobody wants waits and claims nothing).
    let (stops, stopped) = AsyncStream<Void>.makeStream()
    rig.runtime.onLifecycleAppliedForTesting = { [coordinator = rig.coordinator] in
      // The launch's own first `.stopped` seed can land late; only a real stop closes admission.
      guard case .stopped = $0.state,
        !coordinator.dictationAdmissionOpenNow(for: .egOne(.full), endpoint: first)
      else { return }
      stopped.yield()
    }
    rig.runtime.deactivate()
    for await _ in stops { break }
    _ = await rig.coordinator.beginRemoval(for: .egOne(.full), intent: 0) { false }
    _ = await rig.runtime.activateForDictation().value
    let second = try #require(
      await rig.coordinator.endpoint(for: .egOne(.full)), "the model never came back")
    #expect(second != first, "the restart reused the endpoint; the case is not exercised")
    #expect(
      rig.coordinator.dictationAdmissionOpenNow(for: .egOne(.full), endpoint: first) == false,
      "the old server's endpoint still read open after the restart")
    #expect(rig.coordinator.dictationAdmissionOpenNow(for: .egOne(.full), endpoint: second))
    #expect(
      rig.coordinator.dictationAdmissionOpenNow(for: .egOne(.mini), endpoint: second) == false)
  }

  @Test("a selection change while the confirmation runs keeps the notice back")
  func selectionChangeDuringConfirmation() async throws {
    let rig = try await makeRig()
    defer { rig.cleanup() }
    rig.facts.busy = true
    #expect(await rig.runtime.activateForDictation().value == .readyUnchecked)
    #expect(await completeTransfer(rig) != nil)
    rig.facts.busy = false

    // The user switches to another polish model while the confirmation's probe runs.
    rig.probe.duringProbe = { [facts = rig.facts] in facts.active = false }
    guard case .granted(let lease) = await rig.runtime.acquireLocalServerLease() else {
      Issue.record("no lease")
      return
    }
    await rig.runtime.releaseLocalServerLease(lease)
    await Self.settleConfirmation(rig, releases: 1)
    #expect(rig.runtime.pendingDownloadNotice == nil, "a notice for a model no longer selected")

    // Switched away for real: the completed download no longer earns a notice later.
    rig.probe.duringProbe = nil
    rig.runtime.deactivate()
    #expect(rig.runtime.completedDownloadIDForTesting == nil)
  }

  @Test("a summary release that boots the selected model confirms it with no later action")
  func releaseThatBootsTheSelectedModelConfirms() async throws {
    // When this fails, a download that finished while a meeting summary held the engine never
    // shows its pill, because the check ran before the selected model was started again.
    let rig = try await makeRig()
    defer { rig.cleanup() }
    guard case .ready = await rig.runtime.activateForDictation().value else {
      Issue.record("EG-1 full never came up")
      return
    }
    let (mini, miniFacts, miniReleases) = rig.sibling(.egOne(.mini))
    guard case .granted(let reservation) = await rig.runtime.reserveServerForSummary() else {
      Issue.record("the summary was not granted the server")
      return
    }
    // The user switches to EG-1 mini while the summary holds the server: its start is deferred.
    rig.facts.active = false
    miniFacts.active = true
    rig.runtime.deactivate()
    _ = await mini.activateForDictation().value
    #expect(mini.serverActivity != .ready, "the summary did not defer the switch")
    mini.transferCompleted()
    #expect(mini.pendingDownloadNotice == nil)

    await rig.runtime.releaseServerReservation(reservation)
    await rig.coordinator.awaitSelectionAfterSummaryForTesting()
    // Told once at the release and once after the deferred start ran.
    #expect(await miniReleases.reach(2), "the deferred start was never announced")
    await mini.awaitDownloadConfirmationForTesting()
    let notice = try #require(mini.pendingDownloadNotice, "the booted model was never confirmed")
    #expect(await mini.isCurrent(notice))
  }

  @Test("a confirmation stands aside when a take used the engine, and the next release asks again")
  func confirmationNeverMakesATakeWait() async throws {
    // When this fails, the readiness check queues a user's take behind it on the one inference
    // slot, or a cancelled take leaves the download-complete pill stuck forever.
    let rig = try await makeRig()
    defer { rig.cleanup() }
    rig.facts.busy = true
    #expect(await rig.runtime.activateForDictation().value == .readyUnchecked)
    #expect(await completeTransfer(rig) != nil)
    rig.facts.busy = false
    // A take is admitted during the quiet period (the admission counter moves): no probe.
    var admissions = 0
    rig.runtime.sharedEngineAdmissionEpoch = {
      admissions += 1
      return admissions
    }
    let callsBefore = rig.probe.calls
    rig.runtime.confirmPendingDownload()
    await rig.runtime.awaitDownloadConfirmationForTesting()
    #expect(rig.probe.calls == callsBefore, "the check probed after a take used the engine")
    #expect(rig.runtime.pendingDownloadNotice == nil)
    // The take ends (cancelled, or too short for polish: no polish lease release): the engine
    // release asks again and the quiet engine confirms.
    rig.runtime.sharedEngineAdmissionEpoch = { 7 }
    rig.runtime.confirmPendingDownload()
    await rig.runtime.awaitDownloadConfirmationForTesting()
    #expect(rig.probe.calls == callsBefore + 1)
    #expect(rig.runtime.pendingDownloadNotice != nil, "the pill stayed stuck after a cancelled take")
  }

  @Test("claiming the engine cancels a waiting confirmation; the next release asks again")
  func claimCancelsTheConfirmation() async throws {
    // When this fails, a readiness check that began just before a record press keeps running on
    // the one inference slot and the take's paste waits for it, or a cancelled check never asks
    // again and the download-complete pill never shows.
    let rig = try await makeRig()
    defer { rig.cleanup() }
    rig.facts.busy = true
    #expect(await rig.runtime.activateForDictation().value == .readyUnchecked)
    #expect(await completeTransfer(rig) != nil)
    rig.facts.busy = false
    // A long quiet period, so the check is still waiting when the press arrives.
    rig.runtime.downloadConfirmationQuietPeriod = .seconds(60)
    let callsBefore = rig.probe.calls
    rig.runtime.confirmPendingDownload()
    // A record press claims the engine while the check waits: it is cancelled at once.
    rig.runtime.standDownDownloadConfirmation()
    await rig.runtime.awaitDownloadConfirmationForTesting()
    #expect(rig.probe.calls == callsBefore, "a cancelled check still probed")
    #expect(rig.runtime.pendingDownloadNotice == nil)
    // The engine is released: the check asks again and confirms.
    rig.runtime.downloadConfirmationQuietPeriod = .zero
    rig.runtime.confirmPendingDownload()
    await rig.runtime.awaitDownloadConfirmationForTesting()
    #expect(rig.probe.calls == callsBefore + 1)
    #expect(rig.runtime.pendingDownloadNotice != nil, "the check never asked again after a claim")
  }

  @Test("every runtime hears a valid release of the shared server; a stale one is silent")
  func releaseReachesEveryModel() async throws {
    // When this fails, S1-mini's finished download never earns its pill after a summary held
    // EG-1, because only the runtime that held the server was told it was free.
    let coordinator = await LocalPolishSummaryReservationTests.resident(.egOne)
    let heard = OSAllocatedUnfairLock<[String]>(initialState: [])
    await coordinator.setReleaseObserver(for: .egOne) { heard.withLock { $0.append("eg1") } }
    await coordinator.setReleaseObserver(for: .s1Mini) { heard.withLock { $0.append("s1") } }
    let reservation = try #require(
      LocalPolishSummaryReservationTests.granted(await coordinator.reserveForSummary(.egOne)))
    await coordinator.releaseSummaryReservation(reservation)
    await coordinator.releaseSummaryReservation(reservation)  // stale repeat
    #expect(heard.withLock { $0.sorted() } == ["eg1", "s1"])

    guard case .granted(let first) = await coordinator.acquireLease(for: .egOne, purpose: .inference),
      case .granted(let second) = await coordinator.acquireLease(for: .egOne, purpose: .residency)
    else {
      Issue.record("no leases")
      return
    }
    await coordinator.releaseLease(first)  // another lease still holds the server
    #expect(heard.withLock { $0.count } == 2)
    await coordinator.releaseLease(second)  // the last one
    await coordinator.releaseLease(second)  // stale repeat
    #expect(heard.withLock { $0.count } == 4)
  }

  /// Releases the runtime has observed on the main actor, from its own completion signal. A
  /// waiter parks until the count is reached, or gives up so the test fails by name.
  @MainActor
  final class ReleaseRecorder {
    private(set) var count = 0
    private var waiters: [(target: Int, resume: CheckedContinuation<Bool, Never>)] = []
    func record() {
      count += 1
      let ready = waiters.filter { $0.target <= count }
      waiters.removeAll { $0.target <= count }
      for waiter in ready { waiter.resume.resume(returning: true) }
    }
    func reach(_ target: Int, deadline: Duration = .seconds(20)) async -> Bool {
      if count >= target { return true }
      return await withCheckedContinuation { continuation in
        waiters.append((target, continuation))
        Task { @MainActor [weak self] in
          // deadline-fallback: give up so the test fails by name instead of hanging
          try? await Task.sleep(for: deadline)
          guard let self, let index = self.waiters.firstIndex(where: { $0.target == target })
          else { return }
          self.waiters.remove(at: index).resume.resume(returning: false)
        }
      }
    }
  }

  /// Waits until the runtime observed `releases` releases, then for the confirmation the last
  /// one scheduled (the runtime's own completion signal for each step).
  static func settleConfirmation(_ rig: Rig, releases: Int) async {
    #expect(await rig.releases.reach(releases), "the release never reached the runtime")
    await rig.runtime.awaitDownloadConfirmationForTesting()
  }
}
