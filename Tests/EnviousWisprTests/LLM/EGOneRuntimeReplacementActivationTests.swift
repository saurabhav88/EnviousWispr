import CryptoKit
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprModelDelivery

/// The post-replacement activation trigger (#1386 PR-1 addendum r4, PR #1500
/// cloud P1): `activateAfterAutomaticReplacementIfNeeded()` starts EG-1 only
/// when it is the LIVE effective provider at completion time. Real controller,
/// real adapter, tiny fixture manifest, and a deliberately MISSING server
/// binary: an activation attempt is unmistakable as the
/// `server_binary_missing` health transition, while an inactive admitted
/// state stays `yellow(not_started)`. Signal-based waits only — the health
/// event stream is the signal; no wall-clock polling.
@Suite struct EGOneRuntimeReplacementActivationTests {
  @MainActor
  private final class ProviderBox {
    var isEGOneActive: Bool
    init(_ isEGOneActive: Bool) { self.isEGOneActive = isEGOneActive }
  }

  /// Event-stream waiter: `next(where:)` suspends until a matching runtime
  /// health event arrives (or returns a recorded one). The event IS the
  /// signal; there is no clock.
  @MainActor
  private final class HealthSignal {
    private var waiters:
      [((EGOneRuntimeEvent) -> Bool, CheckedContinuation<EGOneRuntimeEvent, Never>)] = []
    private(set) var events: [EGOneRuntimeEvent] = []

    func record(_ event: EGOneRuntimeEvent) {
      events.append(event)
      if let index = waiters.firstIndex(where: { $0.0(event) }) {
        let waiter = waiters.remove(at: index)
        waiter.1.resume(returning: event)
      }
    }

    func next(
      where predicate: @escaping (EGOneRuntimeEvent) -> Bool
    ) async -> EGOneRuntimeEvent {
      if let event = events.first(where: predicate) {
        return event
      }
      return await withCheckedContinuation { continuation in
        waiters.append((predicate, continuation))
      }
    }

    var sawServerBinaryMissing: Bool {
      events.contains { event in
        if case .healthChanged(_, _, "server_binary_missing") = event { return true }
        return false
      }
    }
  }

  private struct Harness {
    let root: URL
    let store: UserDefaults
    let suite: String
    let adapter: EGOneDeliveryAdapter
    let runtime: EGOneRuntime
    let registration: DeliveryRegistration
    let provider: ProviderBox
    let signal: HealthSignal

    func cleanup() {
      store.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func runtimeManifest() -> EGOneManifest {
    EGOneManifest(
      modelName: LLMProvider.egOneModelName,
      version: "v2-sharded",
      contextTokens: 4096,
      promptTemplateID: "eg1-v1",
      minAppVersion: "0",
      downloadURL: URL(string: "https://example.invalid/eg1.gguf")!
    )
  }

  @MainActor
  private func makeHarness(egOneActive: Bool) throws -> Harness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "eg1-activation-\(UUID().uuidString)", isDirectory: true)
    let install = root.appendingPathComponent("EnviousWispr/Models/eg-1", isDirectory: true)
    let metadata = root.appendingPathComponent("EnviousWispr/ModelDelivery", isDirectory: true)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)

    let suite = "eg1-activation-\(UUID().uuidString)"
    let store = try #require(UserDefaults(suiteName: suite))

    let registration = try EGOneDeliveryAdapterMappingTests.shardedFixtureRegistration(
      install: install, metadata: metadata)
    let controller = ModelDeliveryController(defaults: UserDefaults(suiteName: suite)!)
    let adapter = EGOneDeliveryAdapter(
      controller: controller, registration: registration, version: "v2-sharded",
      defaults: store)

    let provider = ProviderBox(egOneActive)
    let signal = HealthSignal()
    // The binary path exists as a URL but not on disk: activation reaches the
    // server manager and fails with the precise `server_binary_missing`
    // signal instead of spawning anything.
    let missingBinary = root.appendingPathComponent("missing-llama-server")
    let runtime = EGOneRuntime(
      manifest: runtimeManifest(), serverBinaryURL: missingBinary, delivery: adapter,
      defaults: store)
    runtime.isActiveProvider = { [provider] in provider.isEGOneActive }
    runtime.onEvent = { event in
      Task { @MainActor in signal.record(event) }
    }
    return Harness(
      root: root, store: store, suite: suite, adapter: adapter, runtime: runtime,
      registration: registration, provider: provider, signal: signal)
  }

  private func stageValidShards(_ registration: DeliveryRegistration) throws {
    try Data(count: 1000).write(
      to: registration.installDirectory.appendingPathComponent("eg-1-00001-of-00002.gguf"))
    try Data(count: 2000).write(
      to: registration.installDirectory.appendingPathComponent("eg-1-00002-of-00002.gguf"))
  }

  private func stageMonolith(_ root: URL, bytes: Data) throws {
    let store = root.appendingPathComponent("EnviousWispr/PolishModels", isDirectory: true)
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    try bytes.write(to: store.appendingPathComponent("eg-1-v1.gguf"))
  }

  @MainActor
  @Test func automaticReplacementAdmissionStartsEGOneWhenEffectivelyActive() async throws {
    let h = try makeHarness(egOneActive: true)
    defer { h.cleanup() }
    try stageValidShards(h.registration)
    #expect(await h.adapter.adoptIfPresent())

    _ = try #require(h.runtime.activateAfterAutomaticReplacementIfNeeded())

    let event = await h.signal.next { event in
      if case .healthChanged(_, _, "server_binary_missing") = event { return true }
      return false
    }
    #expect(
      event == .healthChanged(from: "yellow", to: "red", reason: "server_binary_missing"))
  }

  /// #2649 (cloud review P1): the two bundled engines share one server, so a
  /// direct activation of THIS engine, from the status card's refresh button
  /// or a completed download, would evict the engine a running take froze and
  /// that take would silently polish to raw. Both direct entry points refuse
  /// while the OTHER engine is pinned; the sync layer's deferred retry starts
  /// this one once the take ends.
  @MainActor
  @Test func directActivationRefusesWhileTheOtherEngineIsPinnedInFlight() async throws {
    let h = try makeHarness(egOneActive: true)
    defer { h.cleanup() }
    try stageValidShards(h.registration)
    #expect(await h.adapter.adoptIfPresent())
    h.runtime.isBlockedByOtherPinnedSession = { true }

    // Refresh button path.
    #expect(h.runtime.activateAndProbe() == nil)
    // Completed-download path.
    #expect(h.runtime.activateAfterAutomaticReplacementIfNeeded() == nil)
    // Nothing reached the server manager: the missing-binary signal that a
    // real start produces on this harness never fires.
    for _ in 0..<50 { await Task.yield() }
    #expect(!h.signal.sawServerBinaryMissing)

    // Two-way control: the same runtime, unblocked, starts (and reports the
    // missing binary exactly as the row above this one does).
    h.runtime.isBlockedByOtherPinnedSession = { false }
    _ = try #require(h.runtime.activateAndProbe())
    let event = await h.signal.next { event in
      if case .healthChanged(_, _, "server_binary_missing") = event { return true }
      return false
    }
    #expect(
      event == .healthChanged(from: "yellow", to: "red", reason: "server_binary_missing"))
  }

  @MainActor
  @Test func automaticReplacementAdmissionDoesNotStartWhenPolishIsOff() async throws {
    // Polish off IS provider .none (LLMPolishStep.isEnabled == llmProvider != .none):
    // the runtime sees the effective predicate as false.
    let h = try makeHarness(egOneActive: false)
    defer { h.cleanup() }
    try stageValidShards(h.registration)
    #expect(await h.adapter.adoptIfPresent())

    let activation = h.runtime.activateAfterAutomaticReplacementIfNeeded()
    #expect(activation == nil)

    _ = await h.signal.next { event in
      if case .healthChanged(_, "yellow", "not_started") = event { return true }
      return false
    }

    #expect(h.runtime.installState == .installed(version: "v2-sharded"))
    #expect(!h.signal.sawServerBinaryMissing)
  }

  @MainActor
  @Test func automaticReplacementAdmissionDoesNotStartWhenAnotherProviderIsActive()
    async throws
  {
    // The runtime sees only the effective-provider Boolean: another active
    // provider and polish-off are the same false predicate at this layer;
    // which of the two it was is composition-root policy.
    let h = try makeHarness(egOneActive: false)
    defer { h.cleanup() }
    try stageValidShards(h.registration)
    #expect(await h.adapter.adoptIfPresent())

    let activation = h.runtime.activateAfterAutomaticReplacementIfNeeded()
    #expect(activation == nil)

    _ = await h.signal.next { event in
      if case .healthChanged(_, "yellow", "not_started") = event { return true }
      return false
    }

    #expect(h.runtime.installState == .installed(version: "v2-sharded"))
    #expect(!h.signal.sawServerBinaryMissing)
  }

  @MainActor
  @Test func providerSwitchToEGOneDuringReplacementStartsAfterAdmission() async throws {
    // Starts as C3 (predicate false); the user switches to EG-1 while the
    // replacement runs; the predicate is read AT COMPLETION, so the switch
    // wins. Full replacement flow: monolith retired, staged shards admitted.
    let h = try makeHarness(egOneActive: false)
    defer { h.cleanup() }
    let bytes = Data("trusted".utf8)
    try stageMonolith(h.root, bytes: bytes)
    try stageValidShards(h.registration)

    let coordinator = EGOneUpgradeCoordinator(
      adapter: h.adapter,
      appSupportDirectory: h.root,
      identity: h.registration.manifest.identity,
      installDirectory: h.registration.installDirectory,
      isOnboardingComplete: { true },
      defaults: h.store,
      trustedArtifact: .init(
        name: "eg-1-v1.gguf",
        sizeBytes: Int64(bytes.count),
        sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
    await coordinator.runLaunch()

    h.provider.isEGOneActive = true
    h.runtime.activateAfterAutomaticReplacementIfNeeded()

    _ = await h.signal.next { event in
      if case .healthChanged(_, _, "server_binary_missing") = event { return true }
      return false
    }
    #expect(h.signal.sawServerBinaryMissing)
  }

  @MainActor
  @Test func providerSwitchAwayDuringReplacementDoesNotStartEGOne() async throws {
    // Starts as C2; the user switches away mid-download; completion must not
    // boot the engine they just left.
    let h = try makeHarness(egOneActive: true)
    defer { h.cleanup() }
    let bytes = Data("trusted".utf8)
    try stageMonolith(h.root, bytes: bytes)
    try stageValidShards(h.registration)

    let coordinator = EGOneUpgradeCoordinator(
      adapter: h.adapter,
      appSupportDirectory: h.root,
      identity: h.registration.manifest.identity,
      installDirectory: h.registration.installDirectory,
      isOnboardingComplete: { true },
      defaults: h.store,
      trustedArtifact: .init(
        name: "eg-1-v1.gguf",
        sizeBytes: Int64(bytes.count),
        sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
    await coordinator.runLaunch()

    h.provider.isEGOneActive = false
    let activation = h.runtime.activateAfterAutomaticReplacementIfNeeded()

    #expect(activation == nil)
    #expect(!h.signal.sawServerBinaryMissing)
  }

  @MainActor
  @Test func nonAdmittedCancelledOrFailedReplacementDoesNotStartEGOne() async throws {
    // Terminal cancellation/failure BEFORE admission: disk truth is "nothing
    // admitted", so activation's no-fetch adoption settles not-installed and
    // boots nothing. (Admission-winning cancellation is a valid admitted-model
    // path — covered by
    // cancelLosingAdmissionRaceLeavesAdmittedModelInstalledAndMarkerCleared —
    // and an active-provider runtime may correctly start that admitted model.)
    let h = try makeHarness(egOneActive: true)
    defer { h.cleanup() }
    // No shards staged: adoption cannot admit and must not fetch.

    let activation = try #require(h.runtime.activateAfterAutomaticReplacementIfNeeded())
    await activation.value

    #expect(h.runtime.installState == .notInstalled)
    #expect(!h.signal.sawServerBinaryMissing)
  }

  /// A removal whose stop is superseded must not delete the model the user has
  /// just selected.
  ///
  /// The race is real on an ordinary click: Remove and the provider switch
  /// arrive as separate tasks, the stop is correctly rejected as superseded,
  /// and the deletion that followed it in the same task used to run anyway.
  /// Losing 462 MB the user is now waiting on is the worst outcome in this
  /// whole area, because unlike a wrong process it cannot be undone by
  /// switching back.
  ///
  /// **The control runs FIRST and is not optional.** "The file is still there"
  /// is also what a task that has not run yet looks like, so without a control
  /// proving this harness observes a real deletion within the same wait, the
  /// subject row passes against a coordinator that never removes anything.
  @MainActor
  @Test func aRemovalSupersededByReselectionDoesNotDeleteTheModel() async throws {
    // CONTROL: nobody re-selects, so the deletion must actually happen.
    let control = try makeHarness(egOneActive: false)
    defer { control.cleanup() }
    try stageValidShards(control.registration)
    let controlShard = control.registration.installDirectory
      .appendingPathComponent("eg-1-00001-of-00002.gguf")
    #expect(FileManager.default.fileExists(atPath: controlShard.path), "fixture did not stage")

    control.runtime.removeModel()
    let controlGone = await Self.settle {
      !FileManager.default.fileExists(atPath: controlShard.path)
    }
    #expect(controlGone, "control: an unselected model must really be deleted")

    // SUBJECT: the user re-selects this engine while the stop is in flight.
    // This test is @MainActor and `removeModel` spawns its work, so the switch
    // below lands before that work can observe anything — which is exactly the
    // ordering the defect needs.
    let h = try makeHarness(egOneActive: false)
    defer { h.cleanup() }
    try stageValidShards(h.registration)
    let shard = h.registration.installDirectory
      .appendingPathComponent("eg-1-00001-of-00002.gguf")

    h.runtime.removeModel()
    h.provider.isEGOneActive = true

    // Watch for the BAD outcome, so the wait runs to its full length. Polling
    // for "still there" would return on the first tick and prove nothing,
    // which is the shape this row exists to avoid.
    let deleted = await Self.settle {
      !FileManager.default.fileExists(atPath: shard.path)
    }
    #expect(!deleted, "the model the user just re-selected must not be deleted")
  }

  /// Bounded settle. Used only to let a fire-and-forget task run, never as the
  /// assertion itself — every caller pairs it with a control that fails if the
  /// window is too short to observe the real effect.
  @MainActor
  private static func settle(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
      if condition() { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
  }
}
