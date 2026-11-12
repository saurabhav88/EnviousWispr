import EnviousWisprCore
import EnviousWisprLlamaEngine
import Foundation
import Observation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprLocalPolish

/// #4525 §3.3: which EG-1 size is starting or running, for the size cards' memory bar. When this
/// fails, a running size's memory is drawn twice (once in gray, once in purple) or a stopped size
/// is told its memory is already in use.
@MainActor
@Suite("LocalPolishRuntime.serverActivity follows the helper's lifecycle, not health (#4525)",
  .tags(.productOutcome))
struct LocalPolishMemoryLifecycleTests {
  private typealias Lifecycle = LocalPolishProcessManager.Lifecycle
  private static let endpoint = LocalPolishEndpoint(
    socketPath: "/t/4525.sock", authToken: "t", contextTokens: 1)

  private func makeRuntime() throws -> (LocalPolishRuntime, () -> Void) {
    let suite = "eg1-activity-\(UUID().uuidString)"
    let store = try #require(TestDefaults.suite(suite))
    let runtime = LocalPolishRuntime(
      manifest: EGOneManifest(
        modelName: LLMProvider.egOneModelName, version: "v2-sharded", contextTokens: 4096,
        promptTemplateID: "eg1-v1", minAppVersion: "0",
        downloadURL: URL(string: "https://example.invalid/eg1.gguf")!
      ).runtimeFacts(expectedModelName: LLMProvider.egOneModelName),
      serverBinaryURL: nil, delivery: nil,
      engine: TestLocalPolishEngine(), defaults: store)
    runtime.applyInstallStateForTesting(.installed(version: nil))
    return (runtime, { store.removePersistentDomain(forName: suite) })
  }

  @Test("each of the six server states projects to starting, ready or inactive")
  func everyServerState() throws {
    let (runtime, cleanup) = try makeRuntime()
    defer { cleanup() }
    let expected: [(LocalPolishProcessManager.ServerState, LocalPolishRuntime.ServerActivity)] = [
      (.stopped, .inactive),
      (.starting, .starting),
      (.ready(Self.endpoint), .ready),
      (.pausedForMemoryPressure, .inactive),
      (.failed(reason: "spawn_failed"), .inactive),
      (.stoppedOutside, .inactive),
    ]
    for (state, activity) in expected {
      runtime.applyServerStateForTesting(state)
      #expect(runtime.serverActivity == activity, "\(state)")
    }
  }

  @Test("a ready helper stays ready whatever its probe says: unchecked, slow or failed")
  func readyIgnoresHealth() throws {
    let (runtime, cleanup) = try makeRuntime()
    defer { cleanup() }
    runtime.applyServerStateForTesting(.starting)
    runtime.applyServerStateForTesting(.ready(Self.endpoint))
    #expect(LocalPolishRuntime.healthLabel(runtime.health) == "yellow")  // ready_unchecked
    #expect(runtime.serverActivity == .ready)
    runtime.acceptProbeResult(.yellow(reason: "probe_slow"), for: Self.endpoint)
    #expect(runtime.serverActivity == .ready)
    runtime.acceptProbeResult(.red(reason: "probe_failed"), for: Self.endpoint)
    #expect(LocalPolishRuntime.healthLabel(runtime.health) == "red")
    #expect(runtime.serverActivity == .ready)
  }

  /// Counts observable changes of `serverActivity` caused by one lifecycle event, with the
  /// Observation framework's own change signal (the size cards redraw on it).
  private static func notifies(_ runtime: LocalPolishRuntime, during apply: () -> Void) -> Bool {
    final class Fired: @unchecked Sendable {
      // Written only by onChange, which fires synchronously inside `apply` on this actor.
      var value = false
    }
    let fired = Fired()
    withObservationTracking {
      _ = runtime.serverActivity
    } onChange: {
      fired.value = true
    }
    apply()
    return fired.value
  }

  @Test("stop, failed start and memory-pressure eviction each notify and restore inactive")
  func lifecycleChangesNotify() throws {
    let (runtime, cleanup) = try makeRuntime()
    defer { cleanup() }
    let ends: [Lifecycle] = [
      .stopped,
      Lifecycle(state: .failed(reason: "spawn_failed")),
      Lifecycle(state: .pausedForMemoryPressure),
    ]
    for end in ends {
      runtime.applyLifecycleForTesting(Lifecycle(state: .ready(Self.endpoint)))
      #expect(runtime.serverActivity == .ready)
      #expect(Self.notifies(runtime) { runtime.applyLifecycleForTesting(end) }, "\(end.state)")
      #expect(runtime.serverActivity == .inactive, "\(end.state)")
    }
  }
}
