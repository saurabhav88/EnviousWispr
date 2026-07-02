import EnviousWisprCore
import Foundation
import Observation
import os

/// Narrow seam the dictation pipeline reads at polish time. The pipeline
/// never sees the store/manager internals — only "is there a ready
/// endpoint right now" (fast, never boots or blocks).
@MainActor
public protocol EGOneEndpointProviding: AnyObject {
  func activeEndpoint() async -> EGOneEndpoint?
}

/// Observable lifecycle events the AppKit layer forwards to telemetry
/// (#1271). Emission lives ABOVE this module because the LLM module cannot
/// import Services (`TelemetryService`); the composition root wires the
/// observer.
public enum EGOneRuntimeEvent: Sendable, Equatable {
  case downloadStarted(resumed: Bool)
  case downloadCompleted(durationBucket: String)
  case downloadFailed(reason: String)
  /// Transition-only (debounced by construction — fired from a state
  /// didSet, identical states never re-fire).
  case healthChanged(from: String, to: String, reason: String?)
}

/// Single owner of the EG-1 model store and inference server (#1271):
/// exposes their state to the pipeline (endpoint) and the settings UI
/// (install/health/progress). Constructed ONCE by `WisprBootstrapper` —
/// a shared runtime consumed by both layers belongs at the composition
/// root (`state-ownership.md` shared-infra-homes rule), never inside a
/// settings-setup service.
@Observable
@MainActor
public final class EGOneRuntime: EGOneEndpointProviding {

  // MARK: - Published state (settings UI reads these)

  public private(set) var installState: EGOneModelStore.InstallState = .notInstalled
  public private(set) var health: EGOneHealth = .red(reason: "not_running") {
    didSet {
      guard
        Self.healthLabel(oldValue) != Self.healthLabel(health)
          || Self.healthReason(oldValue) != Self.healthReason(health)
      else { return }
      onEvent?(
        .healthChanged(
          from: Self.healthLabel(oldValue), to: Self.healthLabel(health),
          reason: Self.healthReason(health)))
    }
  }
  /// Why the manifest cannot activate on this app build (empty = fine).
  /// Non-empty reads RED in the UI ("app update required" for an unknown
  /// prompt template).
  public private(set) var activationBlockers: [String] = []

  /// Telemetry forwarding hook, set by the composition root.
  public var onEvent: (@Sendable (EGOneRuntimeEvent) -> Void)?

  /// Live "is EG-1 the selected provider?" read, set by the composition
  /// root (#1271 Codex r2). The runtime cannot import Services to read
  /// settings; this closure lets a download that completes while EG-1 is
  /// selected auto-start the server instead of silently skipping until
  /// relaunch.
  public var isActiveProvider: (@MainActor () -> Bool)?

  /// Live "did an in-flight recording freeze .egOne?" read, set by the
  /// composition root (#1271 matrix gap 3; the authority is
  /// `PipelineSettingsSync.isEGOnePinnedInFlight`). Remove Model must not
  /// stop the server and delete the artifact underneath a recording that
  /// still needs it.
  public var isPinnedInFlight: (@MainActor () -> Bool)?
  private var removalPending = false

  public let manifest: EGOneManifest?
  private let store: EGOneModelStore?
  private let server: EGOneServerManager
  private let serverBinaryURL: URL?
  private var downloadStartedAt: ContinuousClock.Instant?

  // MARK: - Init

  /// Production init: loads the bundled manifest; a missing/corrupt bundled
  /// manifest is a RED state, never a crash (limb).
  public convenience init() {
    let manifest = try? EGOneManifest.loadBundled()
    self.init(
      manifest: manifest,
      serverBinaryURL: Bundle.main.url(forResource: "llama-server", withExtension: nil)
    )
  }

  public init(manifest: EGOneManifest?, serverBinaryURL: URL?, storeDirectory: URL? = nil) {
    self.manifest = manifest
    self.serverBinaryURL = serverBinaryURL
    self.server = EGOneServerManager()
    if let manifest {
      self.store = EGOneModelStore(manifest: manifest, directory: storeDirectory)
      self.activationBlockers = manifest.activationBlockers()
    } else {
      self.store = nil
      self.activationBlockers = ["manifest_missing"]
    }
    wireObservers()
  }

  /// Last applied observer sequence numbers (#1271 enumeration pass): the
  /// MainActor hops below are unstructured Tasks with NO ordering guarantee,
  /// so two rapid transitions could apply in reverse and leave the UI on a
  /// stale state. Sequence numbers are assigned on the emitting actor
  /// (serialized by construction); an out-of-order older hop is dropped.
  private var installStateSeqApplied = 0
  private var serverStateSeqApplied = 0

  private func wireObservers() {
    Task { [weak self] in
      guard let self, let store = self.store else { return }
      let seq = OSAllocatedUnfairLock(initialState: 0)
      await store.setStateObserver { [weak self] state in
        let mySeq = seq.withLock {
          $0 += 1
          return $0
        }
        Task { @MainActor [weak self] in
          guard let self, mySeq > self.installStateSeqApplied else { return }
          self.installStateSeqApplied = mySeq
          self.applyInstallState(state)
        }
      }
      await store.refreshInstalledState()
    }
    Task { [weak self] in
      guard let self else { return }
      let seq = OSAllocatedUnfairLock(initialState: 0)
      await self.server.setStateObserver { [weak self] state in
        let mySeq = seq.withLock {
          $0 += 1
          return $0
        }
        Task { @MainActor [weak self] in
          guard let self, mySeq > self.serverStateSeqApplied else { return }
          self.serverStateSeqApplied = mySeq
          self.applyServerState(state)
        }
      }
    }
  }

  private func applyInstallState(_ state: EGOneModelStore.InstallState) {
    installState = state
    switch state {
    case .installed:
      // Only a genuine download completion may emit telemetry or
      // auto-activate — `refreshInstalledState()` re-emits `.installed` on
      // every refresh, and an unconditional activate loops forever (r4 P1).
      // Completion is keyed off the REQUEST flag, not off the previous
      // observed state: the MainActor observer hops drop out-of-order older
      // updates (enumeration pass), so `.installed` can legitimately arrive
      // with no `.downloading` ever applied (Codex r17).
      if downloadCompletionPending {
        downloadCompletionPending = false
        let bucket = Self.durationBucket(since: downloadStartedAt)
        onEvent?(.downloadCompleted(durationBucket: bucket))
        // Download finished while EG-1 is the selected provider → bring the
        // server up now, not at next relaunch (#1271 Codex r2).
        if isActiveProvider?() == true {
          activateAndProbe()
        }
      }
    case .failed(let failure):
      downloadCompletionPending = false
      onEvent?(.downloadFailed(reason: failure.rawValue))
    case .notInstalled, .downloading, .verifying:
      break
    }
    recomputeHealth()
  }

  /// Set when the store ACCEPTS a download request; consumed by the first
  /// `.installed` apply (completion telemetry + auto-activate) and cleared
  /// by any terminal failure. Ordering-immune by construction.
  private var downloadCompletionPending = false

  private var serverState: EGOneServerManager.ServerState = .stopped
  private func applyServerState(_ state: EGOneServerManager.ServerState) {
    serverState = state
    recomputeHealth()
  }

  /// Cheap health projection from install + server state. The EXPENSIVE
  /// probe (`runHealthProbe`) upgrades yellow→green on demand only
  /// (on-activation + on-settings-open; no background polling).
  private func recomputeHealth() {
    if !activationBlockers.isEmpty {
      health = .red(
        reason: activationBlockers.contains("unknown_prompt_template")
          ? "app_update_required" : activationBlockers.joined(separator: ","))
      return
    }
    switch installState {
    case .notInstalled: health = .red(reason: "download_required")
    case .downloading: health = .yellow(reason: "downloading")
    case .verifying: health = .yellow(reason: "verifying")
    case .failed(let failure): health = .red(reason: failure.rawValue)
    case .installed:
      switch serverState {
      case .stopped: health = .yellow(reason: "not_started")
      case .starting: health = .yellow(reason: "starting")
      case .pausedForMemoryPressure: health = .yellow(reason: "paused_for_memory")
      case .failed(let reason): health = .red(reason: reason)
      case .ready: break  // keep last probe result (green or probe-derived yellow)
      }
    }
  }

  // MARK: - UI actions

  /// True while a start request is between the tap and the store observing
  /// `.downloading` — a double-tap in that window must not double-emit the
  /// funnel event or re-stamp the duration clock (#1271 Codex r13).
  private var downloadRequestInFlight = false

  public func startDownload() {
    guard let store else { return }
    // Only states a download can genuinely BEGIN from. `.verifying` and
    // `.installed` matter too: the store would no-op those, but falling
    // through here would still re-stamp `downloadStartedAt` and emit a
    // spurious downloadStarted event, corrupting the duration bucket a
    // moments-later `.installed` reports (#1271 seam review).
    switch installState {
    case .notInstalled, .failed: break
    case .downloading, .verifying, .installed: return
    }
    guard !downloadRequestInFlight else { return }
    downloadRequestInFlight = true
    downloadStartedAt = ContinuousClock.now
    Task {
      // Resume truth lives on disk behind the store actor — read it before
      // emitting, or the telemetry hardcodes resumed=false (#1271 matrix
      // gap 4). The funnel event fires only when the store ACCEPTS the
      // start (enumeration pass: a rejected start — stub URL, racing task —
      // must not count as a started download).
      let resumed = await store.hasPartialDownload
      if await store.startDownload() {
        self.downloadCompletionPending = true
        self.onEvent?(.downloadStarted(resumed: resumed))
      }
      self.downloadRequestInFlight = false
    }
  }

  public func cancelDownload() {
    guard let store else { return }
    Task { await store.cancelDownload() }
  }

  /// Delete the model. Caller (settings) owns reverting the provider.
  /// Defers while a recording froze `.egOne` in its session config — the
  /// terminal pipeline transition retries via `retryPendingRemoval()`
  /// (#1271 matrix gap 3; same defer shape as switch-away deactivation).
  public func removeModel() {
    guard let store else { return }
    if isPinnedInFlight?() == true {
      removalPending = true
      return
    }
    removalPending = false
    activationGeneration += 1
    Task {
      await self.server.stop()
      try? await store.removeModel()
    }
  }

  /// Called on terminal pipeline states (alongside the deactivation retry).
  /// Idempotent: no-op unless a removal is actually pending.
  public func retryPendingRemoval() {
    guard removalPending else { return }
    removeModel()
  }

  /// Monotonic activation token (#1271 Codex r5): ONLY `deactivate()` /
  /// `removeModel()` bump it, so an activation task that was suspended when
  /// the user switched away aborts instead of booting a multi-GB server for
  /// a provider that is no longer selected. `activateAndProbe()` itself must
  /// NOT bump it: concurrent activations are harmless (idempotent start,
  /// last probe wins), and cancelling the earlier one strands the launch
  /// probe when settings opens mid-start (#1271 Codex r6).
  private var activationGeneration = 0

  /// Full activation-probe pass: ensure server running, then run the real
  /// inference probe. Called on provider activation and on settings-open.
  public func activateAndProbe() {
    // Choosing EG-1 cancels any deferred removal FIRST, even if activation
    // itself then bails on a blocker — otherwise remove-during-recording
    // followed by re-selecting EG-1 still deletes the model the user just
    // re-picked once the recording ends (#1271 seam review P1).
    removalPending = false
    guard let manifest, activationBlockers.isEmpty else {
      // Blocked manifest = spawn will never run this session, so its
      // pre-spawn sweep never reaps a crash orphan; reap here (idle-gated
      // on the server actor, so it cannot touch a live child) (#1271 r11).
      sweepStaleServersAtLaunch()
      return
    }
    let generation = activationGeneration
    Task {
      // First hop back onto the main actor: a switch-to-then-away that beat
      // this task bumped the generation — do not start the server.
      guard generation == self.activationGeneration else { return }
      await self.startServerIfInstalled()
      // A deactivate DURING the start already stopped the server (the
      // manager's mid-start guards handle that); just don't probe or stamp
      // health for a stale generation.
      guard generation == self.activationGeneration else { return }
      guard let family = manifest.promptFamily else { return }
      let result = await self.server.probeHealth(promptFamily: family)
      await MainActor.run {
        // Probe verdict wins over the cheap projection while server is ready.
        guard generation == self.activationGeneration else { return }
        if case .ready = self.serverState { self.health = result }
      }
    }
  }

  /// Launch-time entry: called by the composition root when the persisted
  /// provider is EG-1 — the server must come up without the settings view
  /// ever opening.
  public func startIfActiveProvider() {
    activateAndProbe()
  }

  /// Orphan reap for no-spawn paths (#1271 confirm round + r11): a crash
  /// bypasses `applicationWillTerminate`, and when nothing spawns this
  /// session (provider not EG-1, model missing, manifest blocked) the
  /// in-spawn sweep never runs — the orphaned multi-GB child would live
  /// until EG-1 next activates. Routed through the server actor's
  /// idle-gated reap, so it can never race or kill a live/starting child.
  /// Composition-root + internal activation paths only (tests construct
  /// with fake binary paths a pkill must never see).
  public func sweepStaleServersAtLaunch() {
    guard let serverBinaryURL else { return }
    let path = serverBinaryURL.path
    Task { await self.server.reapOrphansIfIdle(binaryPath: path) }
  }

  /// Provider switched away: free the RAM (isolate-limbs).
  public func deactivate() {
    activationGeneration += 1
    Task { await self.server.stop() }
  }

  /// App-quit path (#1271 Codex r1 P1): `applicationWillTerminate` cannot
  /// await into the server actor, and `Process` children are NOT killed
  /// when the parent exits — kill synchronously or orphan a multi-GB
  /// server. Crash orphans are reaped by the stale-sweep on next start.
  public func terminateServerForAppQuit() {
    server.terminateImmediately()
  }

  private func startServerIfInstalled() async {
    guard let manifest, let store, let serverBinaryURL else { return }
    await store.refreshInstalledState()
    guard case .installed = await store.state else {
      // No model = no spawn = no in-spawn sweep; reap orphans here
      // (idle-gated on the server actor) (#1271 r11).
      await server.reapOrphansIfIdle(binaryPath: serverBinaryURL.path)
      return
    }
    let configuration = EGOneServerManager.Configuration(
      serverBinaryURL: serverBinaryURL,
      modelURL: await store.installedArtifactURL,
      contextTokens: manifest.contextTokens,
      // Measured 2026-07-02 (M4 Pro, real EG-1 v1 GGUF): flash-attention +
      // q8 KV cache at 16384 context = 4.1 GB RSS vs 7.4 GB at the naive
      // 32768/fp16 config, with identical probe output and ~0.2 s warm
      // latency. The MacBook-friendly footprint is a launch-flag choice,
      // not a model choice — engine flags live here, model identity in the
      // manifest.
      extraArguments: [
        "-fa", "on", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0",
      ]
    )
    await server.start(configuration: configuration)
  }

  // MARK: - EGOneEndpointProviding (pipeline seam)

  public func activeEndpoint() async -> EGOneEndpoint? {
    await server.activeEndpoint()
  }

  // MARK: - Helpers

  static func healthLabel(_ health: EGOneHealth) -> String {
    switch health {
    case .green: return "green"
    case .yellow: return "yellow"
    case .red: return "red"
    }
  }

  static func healthReason(_ health: EGOneHealth) -> String? {
    switch health {
    case .green: return nil
    case .yellow(let reason), .red(let reason): return reason
    }
  }

  static func durationBucket(since start: ContinuousClock.Instant?) -> String {
    guard let start else { return "unknown" }
    let seconds = (ContinuousClock.now - start) / .seconds(1)
    switch seconds {
    case ..<60: return "under_1m"
    case ..<300: return "1m_5m"
    case ..<1200: return "5m_20m"
    default: return "over_20m"
    }
  }
}
