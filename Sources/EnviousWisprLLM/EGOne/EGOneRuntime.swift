import EnviousWisprCore
import EnviousWisprModelDelivery
import Foundation
import Observation
import os

/// Narrow seam the dictation pipeline reads at polish time. The pipeline
/// never sees the delivery/manager internals — only "is there a ready
/// endpoint right now" (fast, never boots or blocks).
@MainActor
public protocol EGOneEndpointProviding: AnyObject {
  func activeEndpoint() async -> EGOneEndpoint?
}

/// Observable lifecycle events the AppKit layer forwards to telemetry.
///
/// #1348 Phase 3: EG-1's DOWNLOAD lifecycle telemetry now flows through the
/// shared delivery engine (`model_delivery.*` with `family=eg1`), so the old
/// `downloadStarted/Completed/Failed` cases are gone. What remains here is
/// server HEALTH — a runtime probe result with no delivery equivalent — and,
/// since #2109, PAUSED RESIDENCY, which likewise has no delivery equivalent:
/// the delivery funnel reports moments (a cancel happened), never how long a
/// user then sat unable to polish.
/// Transition-only, by two different mechanisms: health is guarded in its
/// `didSet`, paused residency by its projection tracker in
/// `applyInstallState`. Naming both matters — a reader who assumes the didSet
/// guard covers everything would conclude paused telemetry is debounced by
/// construction, when it is debounced by a tracker that deliberately skips
/// `.verifying`.
public enum EGOneRuntimeEvent: Sendable, Equatable {
  case healthChanged(from: String, to: String, reason: String?)
  /// The user ENTERED or LEFT a paused install state (#2109). `nil` means
  /// they left one.
  ///
  /// Deliberately narrower than "the install state changed", and the narrowing
  /// is the whole design. A general state-changed event double-counts: the
  /// settings-open activation path runs `adoptIfPresent`, which CYCLES the
  /// state (`updatePaused → verifying → updatePaused`), so every visit to the
  /// AI settings panel would have emitted twice. The metric would have read as
  /// a growing population of affected users while actually counting panel
  /// visits — plausible, actionable, and wrong. Measured, not theorised: the
  /// observed sequence across three probes was update_paused, verifying,
  /// update_paused, verifying, update_paused, verifying, update_paused.
  ///
  /// `.verifying` is therefore IGNORED rather than mapped: it is an adoption
  /// probe artefact, not a state a user rests in. Every other non-paused state
  /// maps to `nil`, so entry and exit are both observable and nothing in
  /// between generates traffic.
  ///
  /// Named for the STATE, never a cause. An event called `upgrade_stalled` or
  /// `polish_silently_off` would be a causal claim about a state with more
  /// than one producer, and would count a deliberate decline as a malfunction
  /// — the #2066 defect, avoided at design time.
  case pausedInstallStateChanged(EGOnePausedInstallState?)
}

/// The closed vocabulary for paused-residency telemetry (#2109). A raw String
/// so the analytics value is declared HERE and cannot drift when a Swift case
/// is renamed — a silently changed value splits every historical query in two.
public enum EGOnePausedInstallState: String, Sendable, Equatable {
  case paused
  case updatePaused = "update_paused"
  case updatePausedResumable = "update_paused_resumable"

  /// The paused projection of an install state, or nil when the user is not in
  /// one. `.verifying` has no projection at all — see the event's own doc.
  static func projection(of state: EGOneInstallState) -> EGOnePausedInstallState? {
    switch state {
    case .paused: return .paused
    case .updatePaused(let resumable): return resumable ? .updatePausedResumable : .updatePaused
    case .notInstalled, .downloading, .verifying, .installed, .failed: return nil
    }
  }
}

/// Single owner of the EG-1 inference server and its delivery adapter (#1271,
/// #1348 Phase 3): exposes their state to the pipeline (endpoint) and the
/// settings UI (install/health/progress). Constructed ONCE by
/// `WisprBootstrapper` — a shared runtime consumed by both layers belongs at
/// the composition root (`state-ownership.md` shared-infra-homes rule).
///
/// The model bytes move through the shared `EnviousWisprModelDelivery` engine
/// via `EGOneDeliveryAdapter` (a limb: a delivery failure degrades polish to
/// raw text, never blocks dictation). This runtime keeps orchestrating install
/// state, health, and server activation; only the byte-moving relocated.
@Observable
@MainActor
public final class EGOneRuntime: EGOneEndpointProviding {

  // MARK: - Published state (settings UI reads these)

  public private(set) var installState: EGOneInstallState = .notInstalled
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
  private let delivery: EGOneDeliveryAdapter?
  private let server: EGOneServerManager
  private let serverBinaryURL: URL?

  // MARK: - Init

  /// Production init: the composition root builds the shared delivery adapter
  /// (over the one `ModelDeliveryController`) and injects it FIRST, so the
  /// adapter exists before launch activation calls it (#1348 §Decision A
  /// construction-order fix). A nil adapter (bundled-manifest load failure)
  /// is a RED limb state, never a crash.
  public init(manifest: EGOneManifest?, serverBinaryURL: URL?, delivery: EGOneDeliveryAdapter?) {
    self.manifest = manifest
    self.serverBinaryURL = serverBinaryURL
    self.delivery = delivery
    self.server = EGOneServerManager()
    if let manifest {
      self.activationBlockers = manifest.activationBlockers()
    } else {
      self.activationBlockers = ["manifest_missing"]
    }
    wireObservers()
  }

  /// Last applied server-observer sequence number (#1271 enumeration pass):
  /// the MainActor hops below are unstructured Tasks with NO ordering
  /// guarantee. The install-state stream is ordered by the adapter itself; the
  /// server stream is guarded here.
  private var serverStateSeqApplied = 0

  private func wireObservers() {
    // Install-state stream from the shared delivery engine, mapped to the
    // EG-1 UI vocabulary and ORDERED by the adapter (it mints the sequence on
    // the controller actor and replays the current state on registration — so
    // this also seeds the initial UI state; no separate refresh needed).
    delivery?.observeInstallState { [weak self] state in
      self?.applyInstallState(state)
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

  private func applyInstallState(_ state: EGOneInstallState) {
    // Pure UI projection: the install-state stream drives the settings row and
    // health only. Server activation is triggered by EXPLICIT actions — launch
    // (`startIfActiveProvider`), provider switch, settings-open, and a
    // completed user download (`startDownload`) — never reactively from this
    // stream. Reactively re-activating here would loop: an in-flight
    // activation's own `ensureAvailable()` republishes `.admitted` → `.installed`
    // while the server is still `.stopped` (grounded r2 P1).
    // #2109: the single UI-state owner. The adapter has TWO publication sites
    // — the launch seed and the observer replay — so neither is the authority;
    // both converge here. This guard makes a republish of the SAME state a
    // no-op for the UI, and that is ALL it does. It does NOT keep telemetry
    // honest: the settings-open probe cycles updatePaused → verifying →
    // updatePaused, so every leg is a genuine change and passes straight
    // through. Paused telemetry has its own projection guard below, which
    // skips `.verifying` precisely because this one cannot.
    guard installState != state else { return }
    installState = state

    // Paused-residency telemetry, emitted HERE and nowhere else. The adapter
    // has TWO publication sites — the launch seed (which covers both the
    // admitted and not-admitted cases) and the observer replay — so neither is
    // the authority; both converge on this method. Counted, not remembered:
    // `grep -n "onState(" EGOneDeliveryAdapter.swift` returns exactly two.
    //
    // `.verifying` is skipped BEFORE the comparison, not mapped to nil: the
    // settings-open probe cycles updatePaused → verifying → updatePaused, and
    // treating the middle leg as a real value would emit an exit and a
    // re-entry on every visit to the panel. Skipping it leaves the tracked
    // value untouched, so a cycle that returns to the same paused state is
    // silent. Measured behaviour, not a guess.
    if case .verifying = state {
      recomputeHealth()
      return
    }
    let projection = EGOnePausedInstallState.projection(of: state)
    if projection != lastPausedProjection {
      // Only when a paused state is involved on one side or the other. Two
      // non-paused states in succession are none of this event's business.
      if projection != nil || lastPausedProjection != nil {
        onEvent?(.pausedInstallStateChanged(projection))
      }
      lastPausedProjection = projection
    }
    recomputeHealth()
  }

  /// Last paused projection reported to telemetry (#2109). Tracked separately
  /// from `installState` because `.verifying` deliberately does not update it.
  private var lastPausedProjection: EGOnePausedInstallState?

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
    // #2109: an interrupted first install is not a failure — the user chose
    // it, and their progress is kept. Yellow, not red.
    case .paused: health = .yellow(reason: "download_paused")
    // A working older revision is on disk but the pinned one is not, so polish
    // is genuinely unavailable. RED is correct and deliberate: this is exactly
    // the silently-off state #2109 exists to stop hiding.
    case .updatePaused: health = .red(reason: "update_required")
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

  /// Start (or resume) the EG-1 download. Idempotent by construction: the
  /// shared controller single-flights per identity, so a double-tap joins the
  /// same attempt. Download telemetry (`attempt_started/completed`) flows
  /// through the shared engine now, not from here.
  public func startDownload() {
    guard let delivery else { return }
    // #2109: the decision lives on the state itself, exhaustively, so a future
    // case cannot silently render a button that does nothing when pressed.
    guard installState.acceptsDownloadStart else { return }
    Task {
      let outcome = await delivery.ensureAvailable()
      // A user-initiated download that completes while EG-1 is the selected
      // provider boots the server now, not at next relaunch (#1271 Codex r2).
      // Explicit here (not reactive from the state stream) so it fires exactly
      // once per completed download.
      if case .admitted = outcome, isActiveProvider?() == true {
        activateAndProbe()
      }
    }
  }

  public func cancelDownload() {
    guard let delivery else { return }
    Task { await delivery.cancel() }
  }

  /// Delete the model. Caller (settings) owns reverting the provider.
  /// Defers while a recording froze `.egOne` in its session config — the
  /// terminal pipeline transition retries via `retryPendingRemoval()`
  /// (#1271 matrix gap 3; same defer shape as switch-away deactivation).
  public func removeModel() {
    guard let delivery else { return }
    if isPinnedInFlight?() == true {
      removalPending = true
      return
    }
    removalPending = false
    activationGeneration += 1
    Task {
      await self.server.stop()
      _ = await delivery.remove()
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

  /// Full activation-probe pass: ensure the model is delivered + server
  /// running, then run the real inference probe. Called on provider
  /// activation and on settings-open. Safe to call concurrently: server start
  /// is idempotent (no-ops if starting/ready) and the last probe wins (#1271
  /// Codex r6); the generation token handles switch-away. The returned task is
  /// discardable in production and gives tests the exact completion signal.
  @discardableResult
  public func activateAndProbe() -> Task<Void, Never>? {
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
      return nil
    }
    let generation = activationGeneration
    return Task {
      // First hop back onto the main actor: a switch-to-then-away that beat
      // this task bumped the generation — do not start the server.
      guard generation == self.activationGeneration else { return }
      await self.startServerIfInstalled(generation: generation)
      // A deactivate DURING the start already stopped the server (the
      // manager's mid-start guards handle that); just don't probe or stamp
      // health for a stale generation.
      guard generation == self.activationGeneration else { return }
      guard let family = manifest.promptFamily else { return }
      let result = await self.server.probeHealth(promptFamily: family)
      // Probe verdict wins over the cheap projection while server is ready.
      guard generation == self.activationGeneration else { return }
      if case .ready = self.serverState { self.health = result }
    }
  }

  /// Launch-time entry: called by the composition root when the persisted
  /// provider is EG-1 — the server must come up without the settings view
  /// ever opening.
  public func startIfActiveProvider() {
    activateAndProbe()
  }

  /// Automatic legacy replacement completed (#1386 PR-1, PR #1500 cloud P1):
  /// an explicit activation trigger parallel to a completed user download
  /// (`startDownload`'s admitted branch). The runtime owns the policy and
  /// starts only when EG-1 is the live effective provider. Never called
  /// reactively from the install-state stream (activation-loop precedent
  /// above). Non-admitted cancellation, failure, or decline boots nothing;
  /// admission-winning races retain the trusted model and may activate
  /// normally. Returns the activation task when the live-provider guard passes.
  @discardableResult
  public func activateAfterAutomaticReplacementIfNeeded() -> Task<Void, Never>? {
    guard isActiveProvider?() == true else { return nil }
    return activateAndProbe()
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

  /// Adopt-if-present THEN boot (#1348 §16.4, refined grounded r4 P2): a legacy
  /// byte-correct `.gguf` has NO shared admission marker until it is validated
  /// + admitted in place, so a pure marker check would never boot an existing
  /// user's EG-1 on the first launch of this build — `adoptIfPresent()` does
  /// that in-place admission. Crucially it NEVER fetches: activation (launch /
  /// provider-switch / settings-open) must not start a multi-GB download behind
  /// the user's back — only the explicit Download button (`startDownload`)
  /// fetches. Delivery may continue after a provider switch-away, but the boot
  /// is generation-gated.
  private func startServerIfInstalled(generation: Int) async {
    guard let manifest, let delivery, serverBinaryURL != nil else { return }
    let admitted = await delivery.adoptIfPresent()
    guard generation == self.activationGeneration else { return }
    guard admitted else {
      // Not installed (or incomplete): no server, no download. The install-
      // state stream settles at "not installed" (Download button). Reap any
      // crash orphan (idle-gated).
      if let path = serverBinaryURL?.path {
        await server.reapOrphansIfIdle(binaryPath: path)
      }
      return
    }
    await bootServer(manifest: manifest, delivery: delivery)
    // #1348 §16.5: the controller reported `.admitted` but the server has no
    // usable endpoint (file missing/unreadable/rejected after admission — a
    // stale marker or post-admission mutation). Run ONE repair pass + ONE
    // retry; a second failure is terminal (limb-red + raw fallback).
    if await server.activeEndpoint() == nil {
      guard generation == self.activationGeneration else { return }
      guard case .admitted = await delivery.repair() else { return }
      guard generation == self.activationGeneration else { return }
      await bootServer(manifest: manifest, delivery: delivery)
    }
  }

  private func bootServer(manifest: EGOneManifest, delivery: EGOneDeliveryAdapter) async {
    guard let serverBinaryURL else { return }
    let configuration = EGOneServerManager.Configuration(
      serverBinaryURL: serverBinaryURL,
      // The verified admitted location (install dir + resolved install path).
      modelURL: delivery.installedArtifactURL,
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
}
