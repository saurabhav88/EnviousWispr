import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// #2966: `eg1.health_changed` is a COLOUR transition. Measured 30d to
/// 2026-09-15, 12,900 of 20,192 live rows were same-colour reason changes, and
/// 6,478 of those were the initialiser's `.red(not_running)` placeholder
/// resolving to `.red(download_required)` once per launch on every install
/// without the model. Driven through the install-state seam with no delivery
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
    let store = try #require(UserDefaults(suiteName: suite))
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

  @Test(
    "a reason change inside one colour does not emit; a colour change does, carrying the new reason"
  )
  func colourChangeIsTheTransition() throws {
    let (runtime, recorded, cleanup) = try makeRuntime()
    defer { cleanup() }

    runtime.applyInstallStateForTesting(.verifying)  // seed: yellow(verifying), silent
    #expect(recorded.events.isEmpty)

    // Same colour, new reason: the delivery funnel's business, not this row's.
    runtime.applyInstallStateForTesting(.downloading(fractionCompleted: 0.1, upgrade: nil))
    #expect(EGOneRuntime.healthReason(runtime.health) == "downloading")
    #expect(recorded.events.isEmpty)

    // Installed with the server stopped stays yellow: still no row.
    runtime.applyInstallStateForTesting(.installed(version: nil))
    #expect(EGOneRuntime.healthReason(runtime.health) == "not_started")
    #expect(recorded.events.isEmpty)

    // A failure is a colour change and names its reason.
    runtime.applyInstallStateForTesting(.failed(.network))
    #expect(recorded.events == [.healthChanged(from: "yellow", to: "red", reason: "network")])

    // Red to red with a new reason: the launch-noise shape, now silent.
    runtime.applyInstallStateForTesting(.notInstalled)
    #expect(EGOneRuntime.healthReason(runtime.health) == "download_required")
    #expect(recorded.events.count == 1)

    // Back to a download: red -> yellow, a row with the new reason.
    runtime.applyInstallStateForTesting(.downloading(fractionCompleted: 0, upgrade: nil))
    #expect(
      recorded.events.last == .healthChanged(from: "red", to: "yellow", reason: "downloading"))
    #expect(recorded.events.count == 2)
  }

  /// The delivery funnel and the server lifecycle are the ONLY same-colour
  /// changes that go silent; a probe verdict or a memory-pressure pause has no
  /// other PostHog record, so it still emits inside one colour (Codex r1).
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

    // The set is derived from the producers, never retyped: every download
    // failure is in it, every reason the runtime can land on inside one
    // colour from the install state is in it.
    for failure in EGOneDownloadFailure.allCases {
      #expect(EGOneRuntime.reasonsCountedElsewhere.contains(failure.rawValue))
    }
    #expect(!EGOneRuntime.reasonsCountedElsewhere.contains("probe_slow"))
    #expect(!EGOneRuntime.reasonsCountedElsewhere.contains("probe_output_unexpected"))
    #expect(!EGOneRuntime.reasonsCountedElsewhere.contains("paused_for_memory"))
  }
}
