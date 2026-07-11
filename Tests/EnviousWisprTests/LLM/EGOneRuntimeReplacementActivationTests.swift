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
      manifest: runtimeManifest(), serverBinaryURL: missingBinary, delivery: adapter)
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

  /// Deterministic settle for ABSENCE assertions: a round-trip through the
  /// controller actor drains work enqueued before it (actor FIFO), then
  /// main-actor yields drain the fire-and-forget activation task's
  /// completion hops. No wall clock.
  @MainActor
  private func settle(_ adapter: EGOneDeliveryAdapter) async {
    _ = await adapter.isAdmitted()
    for _ in 0..<20 { await Task.yield() }
  }

  @MainActor
  @Test func automaticReplacementAdmissionStartsEGOneWhenEffectivelyActive() async throws {
    let h = try makeHarness(egOneActive: true)
    defer { h.cleanup() }
    try stageValidShards(h.registration)
    #expect(await h.adapter.adoptIfPresent())

    h.runtime.activateAfterAutomaticReplacementIfNeeded()

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

    h.runtime.activateAfterAutomaticReplacementIfNeeded()
    await settle(h.adapter)

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

    h.runtime.activateAfterAutomaticReplacementIfNeeded()
    await settle(h.adapter)

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

    let coordinator = EGOneLegacyUpgradeCoordinator(
      adapter: h.adapter,
      appSupportDirectory: h.root,
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

    let coordinator = EGOneLegacyUpgradeCoordinator(
      adapter: h.adapter,
      appSupportDirectory: h.root,
      defaults: h.store,
      trustedArtifact: .init(
        name: "eg-1-v1.gguf",
        sizeBytes: Int64(bytes.count),
        sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()))
    await coordinator.runLaunch()

    h.provider.isEGOneActive = false
    h.runtime.activateAfterAutomaticReplacementIfNeeded()
    await settle(h.adapter)

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

    h.runtime.activateAfterAutomaticReplacementIfNeeded()
    await settle(h.adapter)

    #expect(h.runtime.installState == .notInstalled)
    #expect(!h.signal.sawServerBinaryMissing)
  }
}
