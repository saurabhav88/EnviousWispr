import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Observation

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit

/// #1171 — a fully programmable fake for `EngineCoordinator.Dependencies`, so
/// every race the duct-tape design lost can be expressed as a deterministic
/// `@Test` (fake want / active / busy / recovering / installed / readiness, a
/// recording-free switch fn, a programmable warm fn). The coordinator is a thin
/// policy object over these closures, so this fake exercises its full logic with
/// no drivers / audio / ASR machinery booting.
@MainActor
final class FakeEngineDeps {
  var selected: ASRBackendType
  var active: ASRBackendType
  var parakeetReadiness: ASREngineReadiness
  var whisperKitReadiness: ASREngineReadiness
  var parakeetActive = false
  var whisperKitActive = false
  var recovering = false
  var parakeetInstalled = true

  /// #1635: backed by an `@Observable` box so `EngineCoordinator.observeInstalledState()`
  /// can genuinely track it.
  ///
  /// That method wraps `deps.isInstalled(.whisperKit)` in `withObservationTracking`, and
  /// its own comment says "In unit tests the fake reader touches no `@Observable` source,
  /// so this is inert." A plain stored property therefore made the real download-completion
  /// trigger untestable, and a test could only fake it by calling
  /// `poke(.setupStateChanged)` by hand — which exercises the EFFECT, not the trigger.
  /// Reading through this box makes the observation fire for real.
  var whisperKitInstalled: Bool {
    get { whisperKitInstalledBox.value }
    set { whisperKitInstalledBox.value = newValue }
  }
  private let whisperKitInstalledBox = ObservableInstallFlag(true)

  /// Switch bookkeeping.
  private(set) var switchCount = 0
  private(set) var switchHistory: [ASRBackendType] = []
  /// Optional hook awaited INSIDE `performSwitch`, before it lands — lets a test
  /// flip `selected` mid-switch to drive the superseded path.
  var onSwitchAwait: (@MainActor () async -> Void)?

  /// Warm bookkeeping.
  private(set) var warmCount = 0
  private(set) var warmHistory: [ASRBackendType] = []
  /// Per-engine warm outcome; default `.ready`.
  var warmOutcome: [ASRBackendType: EngineWarmupOutcome] = [:]
  /// Optional hook awaited INSIDE `warm`, before it resolves.
  var onWarmAwait: (@MainActor () async -> Void)?

  /// #1635: the mutation scope handed to the coordinator. Defaults to the existing
  /// always-allowed test value so every prior test is byte-for-byte unchanged; a test that
  /// needs the REFUSED branch (which clears and republishes `warmInFlight` without any
  /// `.warmCompleted` poke to follow it) swaps in a refusing `.live`.
  var mutationScope: EngineMutationScope = .alwaysAllowedForTesting

  /// Records the site string of every refused claim, so a test can prove the refusal
  /// actually happened rather than inferring it from an absence.
  private(set) var refusedSites: [String] = []

  /// Released from `onRefused`, so a test can await the refusal instead of polling.
  var onRefusedSignal: (@MainActor () -> Void)?

  /// A scope that refuses every claim, recording the site and firing the signal.
  func makeRefusingScope() -> EngineMutationScope {
    .live(
      tryBegin: { false }, end: { false }, wake: {},
      onRefused: { site in
        self.refusedSites.append(site)
        self.onRefusedSignal?()
      })
  }

  init(
    selected: ASRBackendType = .parakeet,
    active: ASRBackendType = .parakeet,
    parakeetReadiness: ASREngineReadiness = .ready,
    whisperKitReadiness: ASREngineReadiness = .ready
  ) {
    self.selected = selected
    self.active = active
    self.parakeetReadiness = parakeetReadiness
    self.whisperKitReadiness = whisperKitReadiness
  }

  func readiness(_ b: ASRBackendType) -> ASREngineReadiness {
    b == .whisperKit ? whisperKitReadiness : parakeetReadiness
  }
  func setReadiness(_ b: ASRBackendType, _ r: ASREngineReadiness) {
    if b == .whisperKit { whisperKitReadiness = r } else { parakeetReadiness = r }
  }
  func isActive(_ b: ASRBackendType) -> Bool {
    b == .whisperKit ? whisperKitActive : parakeetActive
  }
  func installed(_ b: ASRBackendType) -> Bool {
    b == .whisperKit ? whisperKitInstalled : parakeetInstalled
  }

  func makeDependencies() -> EngineCoordinator.Dependencies {
    EngineCoordinator.Dependencies(
      selectedBackend: { self.selected },
      activeBackend: { self.active },
      readiness: { self.readiness($0) },
      isEngineActive: { self.isActive($0) },
      isRecovering: { self.recovering },
      isInstalled: { self.installed($0) },
      stateLabel: { _ in "idle" },
      performSwitch: { backend in
        if let hook = self.onSwitchAwait { await hook() }
        self.switchCount += 1
        self.switchHistory.append(backend)
        // Mirror `switchBackend`: the old engine is unloaded and the new one is
        // set active but NOT yet loaded (a warm follows).
        self.active = backend
        self.setReadiness(backend, .notReady)
      },
      warm: { backend in
        self.warmCount += 1
        self.warmHistory.append(backend)
        if let hook = self.onWarmAwait { await hook() }
        let outcome = self.warmOutcome[backend] ?? .ready
        if case .ready = outcome { self.setReadiness(backend, .ready) }
        return outcome
      },
      engineMutationScope: mutationScope)
  }

  /// Build a started coordinator over this fake. `start()` fires the initial
  /// converged reconcile; callers `await` convergence via `poll`.
  func makeStartedCoordinator() -> EngineCoordinator {
    let c = EngineCoordinator(dependencies: makeDependencies())
    c.start()
    return c
  }
}

/// Poll a MainActor condition to a deadline — the async-convergence assert helper
/// for the coordinator's worker (which switches/warms off the caller's stack).
///
/// Each iteration `Task.yield()`s BEFORE sleeping so the coordinator's worker Task
/// (also MainActor) is given a scheduling slice even when many `@MainActor` test
/// suites run in parallel and contend for the executor — without the yield, a
/// short wall-clock deadline can elapse while the worker is starved (a flake).
/// The default deadline is generous because it is a worst-case ceiling, not the
/// expected duration: a positive poll returns the instant the condition holds
/// (typically <50ms). Negative-window checks pass an explicit short `timeout`.
@MainActor
func enginePoll(
  _ timeout: Duration = .seconds(10),
  interval: Duration = .milliseconds(2),
  _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    await Task.yield()
    try? await Task.sleep(for: interval)
  }
  return condition()
}

enum FakeWarmError: Error { case failed }

/// #1635: an `@Observable` cell so `FakeEngineDeps.whisperKitInstalled` participates in
/// `withObservationTracking`. Without this, `EngineCoordinator.observeInstalledState()` is
/// inert under test and the real download-completion trigger cannot be exercised.
@Observable
final class ObservableInstallFlag {
  var value: Bool
  init(_ value: Bool) { self.value = value }
}
