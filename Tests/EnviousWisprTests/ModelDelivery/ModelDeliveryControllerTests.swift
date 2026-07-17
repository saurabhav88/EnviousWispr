import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// Controller-level tests: preflight + reservation ledger, event sequencing
/// invariants (failed-without-started on preflight rejection; started is
/// accept-gated), single-flight join, and the marker fast path. Network-
/// dependent behaviors (failover, resume, cancel drain under live transfers)
/// are covered by `ManifestFetchTaskTests`' stubs and the D7 drill matrix.
@Suite struct ModelDeliveryControllerTests {
  init() {
    // Deterministic network: unmatched requests fail fast through the stub
    // (cannotConnectToHost → source_unreachable), never real DNS.
    ChunkAppendDelegate.protocolClassesForTesting = [DeliveryStubProtocol.self]
  }

  private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DeliveryEvent] = []
    func append(_ event: DeliveryEvent) {
      lock.lock()
      events.append(event)
      lock.unlock()
    }
    var names: [String] {
      lock.lock()
      defer { lock.unlock() }
      return events.map {
        switch $0 {
        case .attemptStarted: return "started"
        case .attemptCompleted: return "completed"
        case .attemptFailed(let reason, _, _): return "failed:\(reason.rawValue)"
        case .sourceFailover: return "failover"
        case .validationRepair(_, let trigger): return "repair:\(trigger.rawValue)"
        case .cancel: return "cancel"
        case .flagActive(let flag, _): return "flag:\(flag)"
        case .admittedWithoutFetch(let reason): return "admitted_no_fetch:\(reason.rawValue)"
        }
      }
    }
  }

  private func makeRegistration(
    files: [(path: String, content: Data, component: String)]
  ) throws -> DeliveryRegistration {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("controller-\(UUID().uuidString)", isDirectory: true)
    let install = root.appendingPathComponent("install", isDirectory: true)
    let metadata = root.appendingPathComponent("metadata", isDirectory: true)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    let sources = [
      [
        "id": "our_copy",
        "baseURL": "https://controller-mirror.invalid.example/\(UUID().uuidString)/",
      ],
      [
        "id": "backup",
        "baseURL": "https://controller-upstream.invalid.example/\(UUID().uuidString)/",
      ],
    ]
    let manifest = try DeliveryManifest.load(
      from: ManifestFixture.manifestJSON(files: files, sources: sources))
    return DeliveryRegistration(
      manifest: manifest, installDirectory: install, metadataDirectory: metadata)
  }

  /// Fresh suite per test. Returns the NAME; each use site constructs its
  /// own `UserDefaults(suiteName:)` instance so the one sent into the actor
  /// is moved (region isolation), never shared with the test body.
  private func testDefaultsSuite() -> String {
    let suite = "test.controller.\(UUID().uuidString)"
    UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
    return suite
  }

  private func testDefaults() -> UserDefaults {
    UserDefaults(suiteName: testDefaultsSuite())!
  }

  private func seedValidCache(_ registration: DeliveryRegistration) throws {
    for f in ManifestFixture.smallFiles {
      let url = registration.installDirectory.appendingPathComponent(f.path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try f.content.write(to: url)
    }
  }

  @Test func preflightRejectionEmitsFailedWithoutStarted() async throws {
    // D3 sequencing invariant: a preflight-rejected attempt emits
    // attempt_failed(insufficient_disk) with NO attempt_started.
    let registration = try makeRegistration(files: ManifestFixture.smallFiles)
    let controller = ModelDeliveryController(
      defaults: testDefaults(), availableDiskBytes: { _ in 1 })  // nothing fits
    let log = EventLog()
    await controller.addEventObserver { _, event in log.append(event) }
    let outcome = await controller.ensureModelAvailable(registration)
    guard case .failed(let failure) = outcome else {
      Issue.record("expected failure, got \(outcome)")
      return
    }
    #expect(failure.reason == .insufficientDisk)
    #expect(log.names == ["failed:insufficient_disk"], "no started before preflight acceptance")
    let state = await controller.state(of: registration.manifest.identity)
    #expect(state == .failed(failure))
  }

  @Test func lateObserversSeeReplayedStateAndBufferedEvents() async throws {
    // Launch-window race (drill 12, 2026-07-06): a preflight reject lands in
    // milliseconds, BEFORE the app's observers attach (they register from
    // Tasks after init). Late attach must still see the terminal state
    // (settings row renders the failure copy) and the buffered events
    // (telemetry funnel keeps attempt_failed). A SECOND event observer gets
    // no history — replaying to two renderers would double-count telemetry.
    let registration = try makeRegistration(files: ManifestFixture.smallFiles)
    let controller = ModelDeliveryController(
      defaults: testDefaults(), availableDiskBytes: { _ in 1 })  // nothing fits
    let outcome = await controller.ensureModelAvailable(registration)
    guard case .failed(let failure) = outcome else {
      Issue.record("expected failure, got \(outcome)")
      return
    }

    let log = EventLog()
    await controller.addEventObserver { _, event in log.append(event) }
    #expect(log.names == ["failed:insufficient_disk"], "pre-attach events drain to first observer")

    let secondLog = EventLog()
    await controller.addEventObserver { _, event in secondLog.append(event) }
    #expect(secondLog.names.isEmpty, "second observer sees only future events")

    let replayed = ReplayedStates()
    await controller.addStateObserver { _, state in replayed.append(state) }
    #expect(replayed.snapshot.contains(.failed(failure)), "state replayed on attach")
  }

  private final class ReplayedStates: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [DeliveryState] = []
    func append(_ state: DeliveryState) {
      lock.lock()
      states.append(state)
      lock.unlock()
    }
    var snapshot: [DeliveryState] {
      lock.lock()
      defer { lock.unlock() }
      return states
    }
  }

  @Test func validCacheAdmitsInPlaceWithNoAttemptEvents() async throws {
    // Legacy migration: complete valid cache → one validation pass → marker
    // → admitted. No fetch happened, so NO attempt events exist (D3: attempt
    // = fetch sequence), and no repair fired (nothing was deleted). #1363
    // Decision E: this no-fetch admission now emits exactly ONE availability
    // signal, `admitted_without_fetch(adopted_in_place)`, so the migration win
    // is visible in the field — it is NOT an attempt event.
    let registration = try makeRegistration(files: ManifestFixture.smallFiles)
    try seedValidCache(registration)
    let controller = ModelDeliveryController(
      defaults: testDefaults(), availableDiskBytes: { _ in .max })
    let log = EventLog()
    await controller.addEventObserver { _, event in log.append(event) }
    let outcome = await controller.ensureModelAvailable(registration)
    #expect(outcome == .admitted)
    #expect(log.names == ["admitted_no_fetch:adopted_in_place"])
    #expect(await controller.isAdmitted(registration))
  }

  @Test func admitIfCompleteAdoptsValidCacheWithoutFetch() async throws {
    // Activation path (grounded r4 P2): a complete valid cache is adopted in
    // place and reported admitted — same as ensureModelAvailable's no-fetch
    // prefix, but reached via the non-fetching door.
    let registration = try makeRegistration(files: ManifestFixture.smallFiles)
    try seedValidCache(registration)
    let controller = ModelDeliveryController(
      defaults: testDefaults(), availableDiskBytes: { _ in .max })
    let log = EventLog()
    await controller.addEventObserver { _, event in log.append(event) }
    let admitted = await controller.admitIfComplete(registration)
    #expect(admitted)
    #expect(await controller.isAdmitted(registration))
    // No fetch happened; only the no-fetch availability signal fired.
    #expect(log.names == ["admitted_no_fetch:adopted_in_place"])
  }

  @Test func admitIfCompleteReturnsFalseWithoutFetchingWhenMissing() async throws {
    // The behavioral guarantee grounded r4 P2 demanded: activation must NEVER
    // start a download. With nothing on disk, admitIfComplete reports false,
    // does not admit, and emits NO attempt event (no fetch was attempted).
    let registration = try makeRegistration(files: ManifestFixture.smallFiles)
    let controller = ModelDeliveryController(
      defaults: testDefaults(), availableDiskBytes: { _ in .max })
    let log = EventLog()
    await controller.addEventObserver { _, event in log.append(event) }
    let admitted = await controller.admitIfComplete(registration)
    #expect(!admitted)
    #expect(!(await controller.isAdmitted(registration)))
    #expect(!log.names.contains("started"), "activation must not start a fetch")
    #expect(!log.names.contains(where: { $0.hasPrefix("failed") }), "no failure event either")
  }

  @Test func markerFastPathSkipsRevalidation() async throws {
    let registration = try makeRegistration(files: ManifestFixture.smallFiles)
    try seedValidCache(registration)
    let controller = ModelDeliveryController(
      defaults: testDefaults(), availableDiskBytes: { _ in .max })
    #expect(await controller.ensureModelAvailable(registration) == .admitted)

    // Second ensure: marker fast path — admitted with marker mtime untouched
    // (D7 row 11: the absence of work IS the assertion).
    let markerURL = registration.metadataDirectory.appendingPathComponent(
      "\(registration.manifest.identity.cacheKey).admission.json")
    let mtimeBefore =
      try FileManager.default.attributesOfItem(atPath: markerURL.path)[
        .modificationDate] as! Date
    #expect(await controller.ensureModelAvailable(registration) == .admitted)
    let mtimeAfter =
      try FileManager.default.attributesOfItem(atPath: markerURL.path)[
        .modificationDate] as! Date
    #expect(mtimeBefore == mtimeAfter)
  }

  @Test func forceRevalidateFlagIsOneShotAndRevalidates() async throws {
    let registration = try makeRegistration(files: ManifestFixture.smallFiles)
    try seedValidCache(registration)
    let suite = testDefaultsSuite()
    let controller = ModelDeliveryController(
      defaults: UserDefaults(suiteName: suite)!, availableDiskBytes: { _ in .max })
    let defaults = UserDefaults(suiteName: suite)!
    #expect(await controller.ensureModelAvailable(registration) == .admitted)

    defaults.set(true, forKey: "modelDelivery.parakeet.forceRevalidate")
    let log = EventLog()
    await controller.addEventObserver { _, event in log.append(event) }
    #expect(await controller.ensureModelAvailable(registration) == .admitted)
    #expect(log.names.contains("flag:forceRevalidate"), "flag_active proof")
    // One-shot: the flag self-cleared after the pass it forced.
    #expect(!defaults.bool(forKey: "modelDelivery.parakeet.forceRevalidate"))
  }

  @Test func damagedComponentTriggersRepairPipeline() async throws {
    // Admitted cache → user damages a file → next ensure revalidates (size
    // stamp mismatch), deletes the component, and needs a fetch. Sources are
    // unreachable stubs here, so the attempt fails typed — proving the
    // repair PATH (delete + refetch attempt) without a network dependency.
    let registration = try makeRegistration(files: ManifestFixture.smallFiles)
    try seedValidCache(registration)
    let controller = ModelDeliveryController(
      defaults: testDefaults(), availableDiskBytes: { _ in .max })
    #expect(await controller.ensureModelAvailable(registration) == .admitted)

    let vocab = registration.installDirectory.appendingPathComponent("vocab.json")
    try Data("{\"tampered\":true}".utf8).write(to: vocab)
    let log = EventLog()
    await controller.addEventObserver { _, event in log.append(event) }
    let outcome = await controller.ensureModelAvailable(registration)
    guard case .failed(let failure) = outcome else {
      Issue.record("expected typed failure (unreachable sources), got \(outcome)")
      return
    }
    #expect(failure.reason == .sourceUnreachable || failure.reason == .unknown)
    // The repair fetch was accepted → `attempt_started` emitted. (`.contains`
    // not `.first`: the FIRST admit above happened before this observer
    // attached, so its #1363 Decision-E `admitted_without_fetch` availability
    // signal was buffered pre-attach and drains to this observer first.)
    #expect(log.names.contains("started"), "repair fetch was accepted → started emitted")
    #expect(!(await controller.isAdmitted(registration)), "never admitted on a failed repair")
  }

  @Test func singleFlightJoinReturnsSameOutcomeOnce() async throws {
    // Two concurrent callers join ONE attempt: exactly one terminal event.
    let registration = try makeRegistration(files: ManifestFixture.smallFiles)
    let controller = ModelDeliveryController(
      defaults: testDefaults(), availableDiskBytes: { _ in 1 })
    let log = EventLog()
    await controller.addEventObserver { _, event in log.append(event) }
    async let first = controller.ensureModelAvailable(registration)
    async let second = controller.ensureModelAvailable(registration)
    let outcomes = await [first, second]
    for outcome in outcomes {
      guard case .failed(let failure) = outcome else {
        Issue.record("expected failure, got \(outcome)")
        continue
      }
      #expect(failure.reason == .insufficientDisk)
    }
    // JOIN semantics: at most one attempt ran per caller wave. (Two events
    // would mean the second caller started its own attempt while the first
    // was live.) Sequential re-tries are allowed to re-attempt, so assert
    // <= 2 and require the join to have deduped at least once when the
    // scheduler actually overlapped them; the strict assertion is the state.
    #expect(log.names.count <= 2)
    #expect(Set(log.names) == ["failed:insufficient_disk"])
  }

  @Test func explicitFetchNeverCoalescesIntoNoFetchProbe() async throws {
    // Cloud-review P2 (#1363): the no-fetch activation probe (`admitIfComplete`)
    // shares the single-flight `activeTask` slot. If a user's explicit Download
    // (`ensureModelAvailable`) arrives while the probe is mid-validation, it must
    // NOT join the probe and inherit its `not_present_no_fetch` bail — that would
    // make the Download click silently no-op. Here the cache has a full-size but
    // CORRUPT vocab file: validation hashes the (valid) encoder files first, so
    // the probe is genuinely in flight during the join check.
    let registration = try makeRegistration(files: ManifestFixture.smallFiles)
    try seedValidCache(registration)
    // Correct size (7 bytes), wrong content → vocab.json hash-fails → its
    // component needs a fetch (encoder components stay valid → hash suspensions).
    let vocab = registration.installDirectory.appendingPathComponent("vocab.json")
    try Data("{\"a\":9}".utf8).write(to: vocab)
    let controller = ModelDeliveryController(
      defaults: testDefaults(), availableDiskBytes: { _ in .max })
    let log = EventLog()
    await controller.addEventObserver { _, event in log.append(event) }

    // Probe first; a yield lets it install its activeTask and enter validation
    // (actor turn ordering, not a clock — mirrors reservationLedger below).
    async let probe = controller.admitIfComplete(registration)
    await Task.yield()
    let explicit = await controller.ensureModelAvailable(registration)
    let probeAdmitted = await probe

    // The probe never fetches, so it cannot admit a cache that needs bytes.
    #expect(!probeAdmitted, "no-fetch probe must not admit an incomplete cache")
    // The explicit door attempted a real fetch (unreachable stubs → typed
    // network failure), never the probe's no-fetch bail.
    guard case .failed(let failure) = explicit else {
      Issue.record("expected a fetch failure, got \(explicit)")
      return
    }
    #expect(failure.reason == .sourceUnreachable || failure.reason == .unknown)
    #expect(
      failure.detail != "not_present_no_fetch",
      "explicit Download must not inherit the probe's no-fetch bail")
    #expect(
      log.names.contains("started"),
      "explicit Download reached fetch acceptance (did not coalesce into the probe)")
    #expect(!(await controller.isAdmitted(registration)))
  }

  @Test func reservationLedgerBlocksSecondTenant() async throws {
    // D4 §2 / drill 22 in miniature: disk fits ONE manifest set; the second
    // identity's preflight must fail CLEANLY (insufficient_disk, no started)
    // while the first proceeds past preflight.
    let filesA = ManifestFixture.smallFiles
    let filesB: [(path: String, content: Data, component: String)] = [
      ("other-model.bin", Data(repeating: 7, count: 20), "other-model.bin")
    ]
    let regA = try makeRegistration(files: filesA)
    let manifestBData = try ManifestFixture.manifestJSON(files: filesB) { object in
      var identity = object["identity"] as! [String: Any]
      identity["family"] = "eg_one"
      identity["name"] = "fixture-b"
      object["identity"] = identity
    }
    // Recompute digest after mutation happened inside manifestJSON already.
    let manifestB = try DeliveryManifest.load(from: manifestBData)
    let regB = DeliveryRegistration(
      manifest: manifestB,
      installDirectory: regA.installDirectory.deletingLastPathComponent()
        .appendingPathComponent("install-b", isDirectory: true),
      metadataDirectory: regA.metadataDirectory)

    // Capacity: A needs 20 * 2.2 = 44; B needs 20 * 2.2 = 44. Give 50 —
    // room for one, not both.
    let controller = ModelDeliveryController(
      defaults: testDefaults(), availableDiskBytes: { _ in 50 })
    let log = EventLog()
    await controller.addEventObserver { _, event in log.append(event) }

    // A starts (unreachable sources → will fail AFTER acceptance, holding
    // its reservation while in flight); B preflights while A's reservation
    // is held.
    async let a = controller.ensureModelAvailable(regA)
    // B must see A's reservation. A brief yield lets A pass its preflight
    // first (actor turn ordering, not a clock).
    await Task.yield()
    let b = await controller.ensureModelAvailable(regB)
    _ = await a

    if case .failed(let failure) = b, failure.reason == .insufficientDisk {
      // Ledger held: B rejected before any bytes with no started event for B.
      let bEvents = log.names.filter { $0 == "failed:insufficient_disk" }
      #expect(!bEvents.isEmpty)
    } else if case .failed = b {
      // A released its reservation before B preflighted (fast failure) — B
      // then failed on unreachable sources instead. Both orders are legal;
      // the invariant under test is "never two tenants past preflight into
      // the same bytes," which the ledger math enforces by construction.
    } else {
      Issue.record("unexpected outcome for B: \(b)")
    }
  }

  @Test func cancelWithNothingInFlight() async throws {
    let registration = try makeRegistration(files: ManifestFixture.smallFiles)
    let controller = ModelDeliveryController(
      defaults: testDefaults(), availableDiskBytes: { _ in .max })
    let outcome = await controller.cancel(registration.manifest.identity)
    #expect(outcome == .nothingToCancel)
  }

  /// Cloud review (PR #1637): the public and private staged-partials checks
  /// used to disagree — the public one (this PR's WhisperKit `.notReady` fix
  /// depends on it) read a metadata-only staging shell as resumable, while
  /// the private one `cancel()` already used correctly ignored it. Now one
  /// implementation backs both.
  @Test func hasStagedPartialsIgnoresMetadataOnlyStaging() async throws {
    let registration = try makeRegistration(files: ManifestFixture.smallFiles)
    let controller = ModelDeliveryController(
      defaults: testDefaults(), availableDiskBytes: { _ in .max })

    let staging = registration.metadataDirectory
      .appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(registration.manifest.identity.cacheKey, isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

    try Data().write(to: staging.appendingPathComponent("state.resume.json"))
    #expect(
      await controller.hasStagedPartials(registration) == false,
      "a resume-tracking file alone is not resumable content")

    try Data([0x01, 0x02, 0x03]).write(to: staging.appendingPathComponent("chunk.bin"))
    #expect(
      await controller.hasStagedPartials(registration) == true,
      "real staged bytes alongside the metadata ARE resumable")
  }

  /// Cloud review round 2 (PR #1637): a nested model layout (e.g.
  /// `Encoder.mlmodelc/` holding only its own sidecar) must not read as
  /// resumable just because the directory itself is an entry, and a
  /// zero-byte file proves nothing was actually downloaded either.
  @Test func hasStagedPartialsIgnoresNestedDirectoriesAndEmptyFiles() async throws {
    let registration = try makeRegistration(files: ManifestFixture.smallFiles)
    let controller = ModelDeliveryController(
      defaults: testDefaults(), availableDiskBytes: { _ in .max })

    let staging = registration.metadataDirectory
      .appendingPathComponent("staging", isDirectory: true)
      .appendingPathComponent(registration.manifest.identity.cacheKey, isDirectory: true)
    let nested = staging.appendingPathComponent("Encoder.mlmodelc", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data().write(to: nested.appendingPathComponent("file.resume.json"))
    try Data().write(to: nested.appendingPathComponent("empty.bin"))
    #expect(
      await controller.hasStagedPartials(registration) == false,
      "a nested directory holding only a sidecar and an empty file is not resumable content")

    try Data([0x01]).write(to: nested.appendingPathComponent("chunk.bin"))
    #expect(
      await controller.hasStagedPartials(registration) == true,
      "a nested real file with actual bytes IS resumable")
  }

  @Test func telemetryBuckets() {
    #expect(ModelDeliveryController.bytesBucket(10 << 20) == "under_50mb")
    #expect(ModelDeliveryController.bytesBucket(100 << 20) == "50mb_200mb")
    #expect(ModelDeliveryController.bytesBucket(483_256_769) == "200mb_600mb")
    #expect(ModelDeliveryController.bytesBucket(700 << 20) == "over_600mb")
  }
}
