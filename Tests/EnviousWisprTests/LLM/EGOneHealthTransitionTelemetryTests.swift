import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #2966: `eg1.health_changed` is a colour change or an unsuppressed
/// same-colour reason change. Measured 30d to 2026-09-15, 12,900 of 20,192
/// live rows were same-colour reason changes; 6,478 of those were the
/// initialiser's `.red(not_running)` placeholder resolving to
/// `.red(download_required)` once per launch on every install without the
/// model, and 3,771 the `not_started`/`starting` steps of every activation. Driven through the install-state seam with no delivery
/// adapter, so the only thing moving is `health`.
@MainActor
@Suite(.tags(.observabilityContract)) struct EGOneHealthTransitionTelemetryTests {

  private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [EGOneRuntimeEvent] = []
    func append(_ event: EGOneRuntimeEvent) {
      lock.lock()
      stored.append(event)
      lock.unlock()
    }
    var events: [EGOneRuntimeEvent] {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
  }

  private func makeRuntime() throws -> (EGOneRuntime, Recorded, () -> Void) {
    let suite = "eg1-health-\(UUID().uuidString)"
    let store = try #require(TestDefaults.suite(suite))
    let runtime = EGOneRuntime(
      manifest: EGOneManifest(
        modelName: LLMProvider.egOneModelName, version: "v2-sharded", contextTokens: 4096,
        promptTemplateID: "eg1-v1", minAppVersion: "0",
        downloadURL: URL(string: "https://example.invalid/eg1.gguf")!),
      serverBinaryURL: nil, delivery: nil, defaults: store)
    let recorded = Recorded()
    runtime.onEvent = { event in
      if case .healthChanged = event { recorded.append(event) }
    }
    return (runtime, recorded, { store.removePersistentDomain(forName: suite) })
  }

  @Test("the first resolved health is the launch seed, not a transition")
  func launchSeedDoesNotEmit() throws {
    let (runtime, recorded, cleanup) = try makeRuntime()
    defer { cleanup() }
    #expect(EGOneRuntime.healthLabel(runtime.health) == "red")  // placeholder

    // A launch whose first resolved state is a download in flight: red
    // placeholder -> yellow. A colour change, but the seed, so no row.
    // (`.notInstalled` cannot be the seed here: it equals the initial
    // `installState` and the UI dedupe never recomputes health for it. In
    // production the server observer's first tick does that recompute, and
    // the live shape it produced, `red -> red download_required` once per
    // launch, is the second test's last step.)
    runtime.applyInstallStateForTesting(.downloading(fractionCompleted: 0, upgrade: nil))
    #expect(EGOneRuntime.healthLabel(runtime.health) == "yellow")
    #expect(recorded.events.isEmpty)

    // The next colour change is a real transition.
    runtime.applyInstallStateForTesting(.notInstalled)
    #expect(EGOneRuntime.healthReason(runtime.health) == "download_required")
    #expect(
      recorded.events == [.healthChanged(from: "yellow", to: "red", reason: "download_required")])
  }

  @Test("only the three suppressed reasons stay silent within one colour")
  func sameColourSuppressionIsSelective() throws {
    let (runtime, recorded, cleanup) = try makeRuntime()
    defer { cleanup() }

    runtime.applyInstallStateForTesting(.verifying)  // seed: yellow(verifying), silent
    #expect(recorded.events.isEmpty)

    // Same colour, new reason, NOT a launch shape: a download phase may be the
    // only record of that moment, so it still earns a row.
    runtime.applyInstallStateForTesting(.downloading(fractionCompleted: 0.1, upgrade: nil))
    #expect(
      recorded.events == [.healthChanged(from: "yellow", to: "yellow", reason: "downloading")])

    // Installed with the server stopped: `not_started` is a launch shape, silent.
    runtime.applyInstallStateForTesting(.installed(version: nil))
    #expect(EGOneRuntime.healthReason(runtime.health) == "not_started")
    #expect(recorded.events.count == 1)

    // A failure is a colour change and names its reason.
    runtime.applyInstallStateForTesting(.failed(.network))
    #expect(recorded.events.last == .healthChanged(from: "yellow", to: "red", reason: "network"))
    #expect(recorded.events.count == 2)

    // Red to red into `download_required`: the launch-noise shape, silent.
    runtime.applyInstallStateForTesting(.notInstalled)
    #expect(EGOneRuntime.healthReason(runtime.health) == "download_required")
    #expect(recorded.events.count == 2)

    // Back to a download: red -> yellow, a row with the new reason.
    runtime.applyInstallStateForTesting(.downloading(fractionCompleted: 0, upgrade: nil))
    #expect(
      recorded.events.last == .healthChanged(from: "red", to: "yellow", reason: "downloading"))
    #expect(recorded.events.count == 3)
  }

  /// The two launch observers are unordered. When the server's `.stopped` seed
  /// lands BEFORE the install seed, health resolves against the default
  /// `.notInstalled`; the install seed that follows is still the launch, not a
  /// transition (cloud review P1 on #2974).
  @Test(
    "a server seed that lands before the install seed does not turn the install seed into a row")
  func serverSeedBeforeInstallSeedStaysSilent() throws {
    let (runtime, recorded, cleanup) = try makeRuntime()
    defer { cleanup() }

    runtime.applyServerStateForTesting(.stopped)  // red(download_required) against the default
    #expect(EGOneRuntime.healthReason(runtime.health) == "download_required")
    #expect(recorded.events.isEmpty)

    runtime.applyInstallStateForTesting(.installed(version: "v2-sharded"))  // the real seed
    #expect(EGOneRuntime.healthReason(runtime.health) == "not_started")
    #expect(recorded.events.isEmpty)

    // Only now is a change a transition.
    runtime.applyServerStateForTesting(.failed(reason: "spawn_failed"))
    #expect(recorded.events == [.healthChanged(from: "yellow", to: "red", reason: "spawn_failed")])
  }

  /// A seed equal to the default is deduplicated for the UI but must still
  /// resolve health, or a manifest blocker sits on the placeholder until the
  /// server seed lands and that reads as a red-to-red transition (Codex r5).
  @Test("a default-equal install seed still resolves health under a manifest blocker")
  func defaultEqualSeedResolvesHealth() throws {
    let suite = "eg1-health-blocker-\(UUID().uuidString)"
    let store = try #require(TestDefaults.suite(suite))
    defer { store.removePersistentDomain(forName: suite) }
    // No manifest: `activationBlockers == ["manifest_missing"]` from init.
    let runtime = EGOneRuntime(manifest: nil, serverBinaryURL: nil, delivery: nil, defaults: store)
    let recorded = Recorded()
    runtime.onEvent = { event in
      if case .healthChanged = event { recorded.append(event) }
    }
    #expect(EGOneRuntime.healthReason(runtime.health) == "not_running")  // placeholder

    runtime.applyInstallStateForTesting(.notInstalled)  // equals the default
    #expect(EGOneRuntime.healthReason(runtime.health) == "manifest_missing")
    #expect(recorded.events.isEmpty)

    runtime.applyServerStateForTesting(.stopped)  // the server seed, after the gate opened
    #expect(EGOneRuntime.healthReason(runtime.health) == "manifest_missing")
    #expect(recorded.events.isEmpty)
  }

  /// Only the launch shapes go silent; a probe verdict or a memory-pressure
  /// pause may be the only record of that moment, so it still emits inside one
  /// colour (Codex r1, r2).
  @Test("a same-colour change into a runtime diagnosis still emits")
  func runtimeDiagnosisEmitsInsideOneColour() throws {
    let (runtime, recorded, cleanup) = try makeRuntime()
    defer { cleanup() }

    runtime.applyInstallStateForTesting(.installed(version: nil))  // seed: yellow(not_started)
    runtime.applyServerStateForTesting(.starting)  // yellow(starting): lifecycle, silent
    #expect(EGOneRuntime.healthReason(runtime.health) == "starting")
    #expect(recorded.events.isEmpty)

    runtime.applyServerStateForTesting(.pausedForMemoryPressure)
    #expect(
      recorded.events == [.healthChanged(from: "yellow", to: "yellow", reason: "paused_for_memory")]
    )

    // The silent set is exactly the launch shapes measured live; widening it
    // is a decision that needs its own measurement, not a code edit.
    // #3988 added `ready_unchecked` without a new measurement, by equivalence:
    // it takes over the stretch between ready and the probe that `starting`
    // covered, so every activation still emits exactly the rows it did before.
    #expect(
      EGOneRuntime.reasonsCountedElsewhere
        == Set(["download_required", "not_started", "starting", "ready_unchecked"]))
  }
}

// MARK: - #3988: `ready_unchecked` emits the rows `starting` did

extension EGOneHealthTransitionTelemetryTests {

  /// Each sequence is driven through the real health path; its expected rows are written out
  /// literally from the pre-#3988 behaviour (a ready server kept showing `starting` until a probe
  /// answered, and an outside stop went the crash path to `starting`), never derived from the
  /// code under test. The only delta: the outside-stop row names `stopped_outside` where the
  /// crash path named `starting`, the same row in the same place.
  @Test("ready_unchecked adds and removes no rows on activation, a skipped probe, recovery or a probe verdict")
  func readyUncheckedRowEquivalence() throws {
    let endpoint = EGOneEndpoint(port: 9, authToken: "t", contextTokens: 1)
    func run(_ steps: (EGOneRuntime) -> Void) throws -> [EGOneRuntimeEvent] {
      let (runtime, recorded, cleanup) = try makeRuntime()
      defer { cleanup() }
      runtime.applyInstallStateForTesting(.installed(version: nil))  // seed: not_started
      steps(runtime)
      return recorded.events
    }
    func activate(_ runtime: EGOneRuntime) {
      runtime.applyServerStateForTesting(.starting)
      runtime.applyServerStateForTesting(.ready(endpoint))
    }

    // An ordinary activation whose probe passes: one yellow -> green row, as before.
    #expect(
      try run { runtime in
        activate(runtime)
        runtime.acceptProbeResult(.green, for: endpoint)
      } == [.healthChanged(from: "yellow", to: "green", reason: nil)])

    // A probe skipped because a take holds the engine: no row, as before.
    #expect(try run { runtime in activate(runtime) } == [])

    // A probe verdict that is not green: the same row `starting` -> verdict made.
    #expect(
      try run { runtime in
        activate(runtime)
        runtime.acceptProbeResult(.yellow(reason: "probe_slow"), for: endpoint)
      } == [.healthChanged(from: "yellow", to: "yellow", reason: "probe_slow")])
    #expect(
      try run { runtime in
        activate(runtime)
        runtime.acceptProbeResult(.red(reason: "probe_failed"), for: endpoint)
      } == [.healthChanged(from: "yellow", to: "red", reason: "probe_failed")])

    // An outside stop of a green server, then recovery with a passing probe: two rows, as the
    // crash path made (green -> yellow, yellow -> green); the first now names stopped_outside.
    #expect(
      try run { runtime in
        activate(runtime)
        runtime.acceptProbeResult(.green, for: endpoint)
        runtime.applyLifecycleForTesting(
          EGOneServerManager.Lifecycle(state: .stoppedOutside, outsideStopGeneration: 1))
        runtime.applyLifecycleForTesting(
          EGOneServerManager.Lifecycle(state: .starting, outsideStopGeneration: 1))
        let replacement = EGOneEndpoint(port: 10, authToken: "u", contextTokens: 1)
        runtime.applyServerStateForTesting(.ready(replacement))
        runtime.acceptProbeResult(.green, for: replacement)
      } == [
        .healthChanged(from: "yellow", to: "green", reason: nil),
        .healthChanged(from: "green", to: "yellow", reason: "stopped_outside"),
        .healthChanged(from: "yellow", to: "green", reason: nil),
      ])
  }
}
