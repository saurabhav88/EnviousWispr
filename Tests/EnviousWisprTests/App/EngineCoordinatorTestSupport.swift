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
  var whisperReadiness: ASREngineReadiness
  var parakeetActive = false
  var whisperActive = false
  var recovering = false
  var parakeetInstalled = true

  /// #1635: backed by an `@Observable` box so `EngineCoordinator.observeInstalledState()`
  /// can genuinely track it.
  ///
  /// That method wraps `deps.isInstalled(.whisper)` in `withObservationTracking`, and
  /// its own comment says "In unit tests the fake reader touches no `@Observable` source,
  /// so this is inert." A plain stored property therefore made the real download-completion
  /// trigger untestable, and a test could only fake it by calling
  /// `poke(.setupStateChanged)` by hand — which exercises the EFFECT, not the trigger.
  /// Reading through this box makes the observation fire for real.
  var whisperInstalled: Bool {
    get { whisperInstalledBox.value }
    set { whisperInstalledBox.value = newValue }
  }
  private let whisperInstalledBox = ObservableInstallFlag(true)

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

  /// #3546 A3: the owed in-session Parakeet Ultra activation. `activate` clears the debt,
  /// counts, and awaits `onActivateAwait` (so a test can hold it open and inspect the gate).
  var activationOwed = false
  var fileImportRunning = false
  var meetingEngineResident = false
  /// #4052: EnviousMeet's final pass holds its own Parakeet (gate 6d).
  var meetingOwnParakeetResident: @MainActor () -> Bool = { false }
  /// The shared engine lease's holder check; a test can bind it to a real `EngineLease`.
  var engineHeld: @MainActor () -> Bool = { false }
  private(set) var activationCount = 0
  var onActivateAwait: (@MainActor () async -> Void)?

  /// #3849: when set, `performSwitch` runs the production `WisprBootstrapper.switchEngine`
  /// sequence over this probe's Whisper backend stub, and a Whisper warm is the stub's real
  /// `prepare()` (refused while parked). Every probe event lands in one ordered log.
  var whisperSwitch: WhisperSwitchProbe?

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
    whisperReadiness: ASREngineReadiness = .ready
  ) {
    self.selected = selected
    self.active = active
    self.parakeetReadiness = parakeetReadiness
    self.whisperReadiness = whisperReadiness
  }

  func readiness(_ b: ASRBackendType) -> ASREngineReadiness {
    b == .whisper ? whisperReadiness : parakeetReadiness
  }
  func setReadiness(_ b: ASRBackendType, _ r: ASREngineReadiness) {
    if b == .whisper { whisperReadiness = r } else { parakeetReadiness = r }
  }
  func isActive(_ b: ASRBackendType) -> Bool {
    b == .whisper ? whisperActive : parakeetActive
  }
  func installed(_ b: ASRBackendType) -> Bool {
    b == .whisper ? whisperInstalled : parakeetInstalled
  }

  func makeDependencies() -> EngineCoordinator.Dependencies {
    EngineCoordinator.Dependencies(
      selectedBackend: { self.selected },
      activeBackend: { self.active },
      readiness: { self.readiness($0) },
      isEngineActive: { self.isActive($0) },
      isRecovering: { self.recovering },
      isFileImportRunning: { self.fileImportRunning },
      isEngineHeld: { self.engineHeld() },
      isMeetingEngineResident: { self.meetingEngineResident },
      isMeetingOwnModelResident: { $0 == .parakeet && self.meetingOwnParakeetResident() },
      isInstalled: { self.installed($0) },
      stateLabel: { _ in "idle" },
      performSwitch: { backend in
        if let hook = self.onSwitchAwait { await hook() }
        guard let probe = self.whisperSwitch else {
          self.landSwitch(backend)
          return
        }
        await WisprBootstrapper.switchEngine(
          to: backend, activeBackend: { self.active },
          parkWhisper: {
            probe.record("park")
            if let hook = probe.onPark { await hook() }
            let receipt = await probe.backend.park()
            probe.record("parked")
            return receipt
          },
          switchManager: { backend in
            probe.record("switch \(backend.rawValue)")
            if let hook = probe.onManagerSwitch { await hook() }
            self.landSwitch(backend)
          },
          unparkWhisper: {
            await probe.backend.unpark()
            probe.record("unpark")
          },
          log: { probe.record($0) })
      },
      warm: { backend in
        self.warmCount += 1
        self.warmHistory.append(backend)
        self.whisperSwitch?.record("warm \(backend.rawValue)")
        if let hook = self.onWarmAwait { await hook() }
        var outcome = self.warmOutcome[backend] ?? .ready
        if backend == .whisper, let probe = self.whisperSwitch {
          do {
            try await probe.backend.prepare()
          } catch {
            outcome = .failed(error)
          }
        }
        if case .ready = outcome { self.setReadiness(backend, .ready) }
        return outcome
      },
      engineMutationScope: mutationScope,
      isParakeetActivationOwed: { self.activationOwed },
      activateParakeetUpgrade: {
        self.activationOwed = false
        self.activationCount += 1
        if let hook = self.onActivateAwait { await hook() }
      })
  }

  /// Mirror `switchBackend`: the old engine is unloaded and the new one is set active but NOT
  /// yet loaded (a warm follows).
  private func landSwitch(_ backend: ASRBackendType) {
    switchCount += 1
    switchHistory.append(backend)
    active = backend
    setReadiness(backend, .notReady)
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

/// #3849: the Whisper side of a switch run through `WisprBootstrapper.switchEngine`: a backend
/// stub (parked as the composition parks it), hooks that hold the park or the manager switch
/// open, and one ordered event log shared with the fake's warm.
@MainActor
final class WhisperSwitchProbe {
  let backend = StubWhisperBackend()
  private(set) var events: [String] = []
  var onPark: (@MainActor () async -> Void)?
  var onManagerSwitch: (@MainActor () async -> Void)?

  func record(_ event: String) { events.append(event) }
}

/// #1635: an `@Observable` cell so `FakeEngineDeps.whisperInstalled` participates in
/// `withObservationTracking`. Without this, `EngineCoordinator.observeInstalledState()` is
/// inert under test and the real download-completion trigger cannot be exercised.
@Observable
final class ObservableInstallFlag {
  var value: Bool
  init(_ value: Bool) { self.value = value }
}
