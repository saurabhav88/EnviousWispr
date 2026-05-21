@preconcurrency import AVFoundation
import EnviousWisprAudio
import EnviousWisprCore
import Foundation

// MARK: - RecordingSessionKernel (epic #827, PR-3; built from PR-1 §B spec)
//
// The single recording-session finite state machine. One kernel owns one
// dictation's full lifecycle — prepare, warm up, record, stop, transcribe,
// finalize — as the 14-state FSM in PR-1 §B.1. It delegates transcription to
// an `ASREngineAdapter` and post-ASR text-processing / storage / delivery to
// injected closure seams (PR-3 plan §14a — closure seams match
// `TranscriptFinalizer`'s own house style; PR-4 wires the production
// `TranscriptFinalizer` into them).
//
// PR-3 ships this production-unwired (epic §14.3): no App-layer caller. It is
// driven only by the deterministic PR-2 simulator through a test-side
// `RecordingSessionDriving` wrapper. PR-4 wires it into the live app.
//
// Transitions are methods, never open `state =` mutation (epic §3.3). A
// forbidden transition is logged and refused — never a silent no-op, never an
// `assertionFailure` (PR-3 plan §3.10).

/// A normalized, recoverable failure reason for the `failed` terminal state
/// (PR-1 §B.1.2 transition table).
public enum RecordingFailureReason: Equatable, Sendable {
  case prepareFailed
  case permissionDenied
  case modelWedged
  case modelLoadFailed
  case captureStartFailed
  case noAudioCaptured
  case asrEmpty
  case asrFailed
  case asrWedged
  case emptyAfterProcessing
  case storageFailed
  case captureStalled
}

/// The 14 recording-session FSM states (PR-1 §B.1.1). Seven are terminal.
public enum RecordingSessionState: Equatable, Sendable {
  case idle
  case preparing
  case warmingUp
  case recording
  case stopping
  case transcribing
  case finalizing
  // Terminal states.
  case completed
  case failed(RecordingFailureReason)
  case cancelled
  case discarded
  case noSpeech
  case audioInterrupted
  case asrInterrupted

  /// `true` for the seven terminal states (PR-1 §B.1.1).
  public var isTerminal: Bool {
    switch self {
    case .completed, .failed, .cancelled, .discarded, .noSpeech,
      .audioInterrupted, .asrInterrupted:
      return true
    case .idle, .preparing, .warmingUp, .recording, .stopping, .transcribing,
      .finalizing:
      return false
    }
  }
}

/// The `finalizing` sub-status surfaced for the overlay string (PR-1 §B.4,
/// PR-3 plan §3.5). The kernel owns the observation point; a limb only emits.
public enum FinalizingSubStatus: Equatable, Sendable {
  case transcribing
  case polishing
}

/// How the transcript reached the user (PR-1 §B.1.3). The kernel records this
/// from the `deliver` seam's return value.
public enum KernelDeliveryOutcome: Equatable, Sendable {
  case pasted
  case clipboardOnly
}

/// The user-visible error surface a terminal state renders (PR-1 §B.1.3).
public enum KernelErrorCategory: Equatable, Sendable {
  case recoverableError
  case interruption
}

/// A typed limb-seam failure the kernel maps to a `failed` terminal reason
/// (PR-3 plan §14a). The `processText` / `store` seams throw these.
public enum KernelLimbError: Error, Sendable {
  /// Text processing produced empty output (PR-1 §B.1.2 `emptyAfterProcessing`).
  case emptyAfterProcessing
  /// Transcript disk-save threw (epic §3.8 caveat b, deferred #830).
  case storageFailed
}

/// The single recording-session FSM (PR-1 §B.1). `@MainActor @Observable`.
/// Internal — consumed within `EnviousWisprPipeline`; PR-4 wires the App layer
/// through a driver protocol, never by direct mutation.
@MainActor
@Observable
final class RecordingSessionKernel {

  // MARK: Injected dependencies

  private let adapter: any ASREngineAdapter
  private let audioCapture: any AudioCaptureInterface
  private let vad: any VADSignalSource

  /// Logical-time seam (PR-3 plan §14a). Production wiring of a real clock is
  /// PR-4/PR-7; the simulator wires `FakeClock`.
  private let currentTick: @MainActor () -> UInt64
  private let sleepTicks: @MainActor (Int) async -> Void

  /// Limb / storage / delivery seams (PR-3 plan §14a — closure seams, matching
  /// `TranscriptFinalizer`'s house style). `processText` runs the text steps
  /// and signals polish-start via its callback; `store` persists; `deliver`
  /// pastes. PR-4 wires these to a real `TranscriptFinalizer` call site.
  private let processText:
    @MainActor (_ raw: String, _ onPolishStarted: @MainActor () -> Void) async throws -> String
  private let store: @MainActor (_ text: String) async throws -> Void
  private let deliver: @MainActor (_ text: String) async -> KernelDeliveryOutcome

  // MARK: Wedge-detection tuning

  /// Logical-tick window of progress-signal silence (after the stream has
  /// armed with at least one tick) that the kernel treats as a cadence stall.
  /// Mirrors `LoadProgressWatcher`'s arm-then-silence shape (PR-1 §B.1.7) in
  /// the simulator's logical-tick time base — not a wall-clock deadline.
  private let wedgeStallTicks: Int

  // MARK: Observable surface

  /// The current FSM state. Callers observe; they never mutate it.
  private(set) var state: RecordingSessionState = .idle

  /// The session identity of the in-flight (or last) session. Minted at every
  /// `idle → preparing` / `terminal → preparing` (PR-1 §B.1.5).
  private(set) var currentSessionID = SessionID()

  /// The `finalizing` sub-status — `polishing` once the polish signal is
  /// observed (PR-1 §B.4).
  private(set) var finalizingSubStatus: FinalizingSubStatus = .transcribing

  /// The text delivered to the user, or `nil` if none.
  private(set) var deliveredTranscript: String?

  /// How delivery happened, or `nil` if nothing was delivered.
  private(set) var deliveryOutcome: KernelDeliveryOutcome?

  /// Real pastes delivered — 0 or 1. `clipboardOnly` delivery counts 0.
  private(set) var pasteCount: Int = 0

  /// `true` while the kernel holds no capture / task resources — `true` at
  /// `idle`, `false` once a session spawns work, `true` again at terminal
  /// cleanup (PR-1 §B.1.3 cleanup column).
  private(set) var resourcesReleased: Bool = true

  /// `true` when the FSM rejected a forbidden transition this session — a
  /// direct test reads it (PR-3 plan §3.10).
  private(set) var forbiddenTransitionRejected = false

  /// Monotonic counter bumped on every transition / work resumption. The
  /// simulator drains kernel work to quiescence by observing this stop
  /// advancing (PR-3 plan §3.3 — deterministic step ordering).
  private(set) var workEpoch: UInt64 = 0

  /// The user-visible error category for the current terminal state, derived
  /// from the FSM state (PR-1 §B.1.3). `nil` for non-error terminals.
  var userVisibleError: KernelErrorCategory? {
    switch state {
    case .audioInterrupted:
      return .interruption
    case .asrInterrupted, .failed:
      return .recoverableError
    default:
      return nil
    }
  }

  // MARK: Session-scoped mutable state

  /// The session task bag, keyed by `SessionID` (PR-1 §B.1.6). Reaching a
  /// terminal state cancels and clears it — nonblocking (PR-3 plan §3.1a).
  private var taskBag: [Task<Void, Never>] = []
  private var taskBagSessionID = SessionID()

  /// Stop-latch (PR-1 §B.1.4 invariant 1) — consumed exactly once.
  private var stopLatched = false
  /// Cancel requested before `recording` (during `preparing` / `warmingUp`).
  private var cancelRequested = false

  /// The recording-phase exit channel. The forward path parks on
  /// `awaitRecordingExit()`; one of stop / VAD / interruption resumes it once.
  private var recordingExitContinuation: CheckedContinuation<RecordingExit, Never>?
  private var pendingRecordingExit: RecordingExit?
  private var recordingExitLatched = false

  /// Buffers handed to the adapter this session — the sub-minimum-duration
  /// proxy (PR-1 §B.1.2 `recording → discarded`): zero buffers ⇒ `discarded`.
  private var bufferCountThisSession = 0
  private var bufferSequence: UInt64 = 0

  /// Capture-engine lifecycle. The kernel stops capture exactly once per
  /// session: the normal `stopping` path owns the stop when it runs;
  /// `finishTerminal` owns it for a terminal reached straight from `recording`
  /// (cancel / interruption / stall). `resourcesReleased` flips true only once
  /// the stop has actually completed (Codex P1b, P2-round3).
  private enum CaptureLifecycle { case notStarted, active, stopping, stopped }
  private var captureLifecycle: CaptureLifecycle = .notStarted

  /// `true` between a successful `adapter.beginSession()` and `finalize()`. A
  /// terminal reached in this window without a `finalize()` (zero-buffer
  /// stop, confirmed no-speech, no-audio, interruption) must call
  /// `adapter.cancel()` to discard the adapter's open session (Codex P2-r3).
  private var adapterSessionActive = false

  /// Wedge-detection observed state, per phase. `last*TickAt` is the logical
  /// tick of the most recent progress signal — the wedge watcher measures
  /// silence *since the last tick*, so an adapter that keeps reporting
  /// progress is never misclassified as wedged (Codex review P2).
  private var loadTickCount = 0
  private var finalizeTickCount = 0
  private var lastLoadTickAt: UInt64 = 0
  private var lastFinalizeTickAt: UInt64 = 0
  private var loadWedgeDetected = false
  private var finalizeWedgeDetected = false
  private var finalizeCompleted = false

  /// The reason the recording phase ended.
  private enum RecordingExit: Sendable {
    case userStop
    case vadAutoStop
    case maxDuration
    case captureStall
    case audioInterruption
    case asrInterruption
    case cancel
  }

  // MARK: Init

  init(
    adapter: any ASREngineAdapter,
    audioCapture: any AudioCaptureInterface,
    vad: any VADSignalSource,
    currentTick: @escaping @MainActor () -> UInt64,
    sleepTicks: @escaping @MainActor (Int) async -> Void,
    processText: @escaping @MainActor (
      _ raw: String, _ onPolishStarted: @MainActor () -> Void
    ) async throws -> String,
    store: @escaping @MainActor (_ text: String) async throws -> Void,
    deliver: @escaping @MainActor (_ text: String) async -> KernelDeliveryOutcome,
    wedgeStallTicks: Int = 2
  ) {
    self.adapter = adapter
    self.audioCapture = audioCapture
    self.vad = vad
    self.currentTick = currentTick
    self.sleepTicks = sleepTicks
    self.processText = processText
    self.store = store
    self.deliver = deliver
    self.wedgeStallTicks = wedgeStallTicks
  }

  // MARK: Driver entry points (PR-1 §A.2 trigger vocabulary)

  /// Start a new recording session. Legal from `idle` or any terminal state;
  /// ignored while a session is active (PR-1 §B.1.2 — "don't interrupt
  /// processing").
  func start() {
    guard state == .idle || state.isTerminal else {
      log("start ignored — session active at \(state)")
      return
    }
    let sid = SessionID()
    currentSessionID = sid
    resetSessionState()
    transition(to: .preparing)
    spawn(sid) { [weak self] in
      await self?.runForwardPath(sid)
    }
  }

  /// Request a stop. From `recording` it latches the recording-exit; from
  /// `preparing` / `warmingUp` it latches a stop the forward path resolves to
  /// `discarded`; elsewhere it is ignored (PR-1 §B.1.2, invariant 1).
  func requestStop() {
    switch state {
    case .recording:
      deliverRecordingExit(.userStop)
    case .preparing, .warmingUp:
      stopLatched = true
      bump()
    case .idle, .stopping, .transcribing, .finalizing, .completed, .failed,
      .cancelled, .discarded, .noSpeech, .audioInterrupted, .asrInterrupted:
      log("stop ignored at \(state)")
    }
  }

  /// Cancel. From `A⁻` (before `finalizing`) it routes to `cancelled`; from
  /// `finalizing` it is ignored — the safe point is inviolable (PR-1 §B.1.4
  /// invariant 5); elsewhere ignored.
  func cancel() {
    switch state {
    case .recording:
      deliverRecordingExit(.cancel)
    case .preparing, .warmingUp:
      cancelRequested = true
      detachedAdapterCancel()
      bump()
    case .stopping, .transcribing:
      // Cancel from `A⁻` after `recording` — no transcript exists yet, so the
      // safe point does not apply (PR-1 §B.1.2 `A⁻ | cancel → cancelled`).
      // Terminate now; `finishTerminal` discards the adapter's open session
      // (which also unblocks an in-flight `finalize()`), and the forward path
      // drops its in-flight `stopCapture()` / `finalize()` result when it
      // returns (state is terminal). `stopping` is included so a cancel
      // during a slow capture-stop is not lost (Codex P2).
      finishTerminal(.cancelled, sid: currentSessionID)
    case .finalizing:
      log("cancel ignored — safe point (transcript in hand)")
    case .idle, .completed, .failed, .cancelled, .discarded, .noSpeech,
      .audioInterrupted, .asrInterrupted:
      log("cancel ignored at \(state)")
    }
  }

  /// Reset to `idle`. Legal only from a terminal state; from `finalizing` it
  /// is deferred (not implemented as a queue in PR-3 — logged and refused,
  /// the safe point completes then `start` mints fresh); elsewhere ignored.
  func reset() {
    guard state.isTerminal else {
      log("reset ignored / deferred at \(state)")
      return
    }
    // Mint a fresh `SessionID` so any same-session async work still unwinding
    // from the terminal state fails its next `isCurrent(sid)` guard. Without
    // this, those continuations see `.idle` (non-terminal) after the reset and
    // could resume into transcription/finalization, delivering text after the
    // user reset (Codex P1-round5).
    currentSessionID = SessionID()
    transition(to: .idle)
    // Do not claim resources released while a capture stop is still in flight.
    // The detached stop task (gated on `captureLifecycle`, not `SessionID`)
    // flips both fields when `stopCapture()` returns (Codex P2-round6).
    resourcesReleased = (captureLifecycle != .stopping)
  }

  /// Sessionless pre-warm — drives `adapter.readiness` toward `.ready` with no
  /// `SessionID`, no state change (PR-1 §B.1.2, §B.2.2). Valid only from
  /// `idle` / terminal.
  func preWarm() {
    guard state == .idle || state.isTerminal else {
      log("preWarm ignored — session active at \(state)")
      return
    }
    let sid = currentSessionID
    spawn(sid) { [adapter] in
      try? await adapter.warmUp()
    }
  }

  // MARK: Forward path

  private func runForwardPath(_ sid: SessionID) async {
    // Preparing: configure VAD, bind capture callbacks, derive options.
    audioCapture.configureVAD(
      autoStop: true, silenceTimeout: 0, sensitivity: 0, energyGate: false)
    bindCaptureCallbacks(sid)
    subscribeVADSignals(sid)

    guard isCurrent(sid) else { return }
    if stopLatched {
      // PTT released before `recording` — no transcribable audio (PR-1 §B.1.2).
      finishTerminal(.discarded, sid: sid)
      return
    }
    if cancelRequested {
      finishTerminal(.cancelled, sid: sid)
      return
    }

    // Warm-up (skipped if the adapter is already ready — the warm path).
    if adapter.readiness != .ready {
      transition(to: .warmingUp)
      let warmResult = await warmUp(sid)
      guard isCurrent(sid) else { return }
      switch warmResult {
      case .ready:
        break
      case .wedged:
        finishTerminal(.failed(.modelWedged), sid: sid)
        return
      case .loadFailed:
        finishTerminal(.failed(.modelLoadFailed), sid: sid)
        return
      case .cancelled:
        finishTerminal(.cancelled, sid: sid)
        return
      case .stopped:
        finishTerminal(.discarded, sid: sid)
        return
      }
    }

    // Capture start.
    do {
      try await audioCapture.startEnginePhase()
    } catch {
      guard isCurrent(sid) else { return }
      finishTerminal(.failed(classifyCaptureStartError(error)), sid: sid)
      return
    }
    guard isCurrent(sid) else { return }
    // The capture engine is up — every terminal from here must stop capture.
    captureLifecycle = .active
    if stopLatched {
      finishTerminal(.discarded, sid: sid)
      return
    }
    if cancelRequested {
      finishTerminal(.cancelled, sid: sid)
      return
    }
    // Install the buffer callback BEFORE `beginCapturePhase()` — a direct
    // (non-XPC) capture source snapshots `onBufferCaptured` into the active
    // source at capture-start, so a callback set afterward would never be
    // seen for the whole session (Codex review P1). The callback itself gates
    // delivery on `state == .recording` + `SessionID`, so a buffer arriving
    // before the `→ recording` transition is dropped, not mis-counted.
    audioCapture.onBufferCaptured = makeBufferCallback(sid)
    do {
      _ = try await audioCapture.beginCapturePhase()
    } catch {
      guard isCurrent(sid) else { return }
      audioCapture.onBufferCaptured = nil
      finishTerminal(.failed(.captureStartFailed), sid: sid)
      return
    }
    guard isCurrent(sid) else { return }

    // Begin the adapter session.
    do {
      try await adapter.beginSession(sid, options: TranscriptionOptions.default)
    } catch {
      guard isCurrent(sid) else { return }
      audioCapture.onBufferCaptured = nil
      finishTerminal(.failed(.asrFailed), sid: sid)
      return
    }
    guard isCurrent(sid) else { return }
    // The adapter now holds an open session — a terminal before `finalize()`
    // must discard it via `adapter.cancel()` (`finishTerminal` does this).
    adapterSessionActive = true
    // Final latch check before `recording` — a stop / cancel that arrived
    // while `beginCapturePhase()` / `beginSession()` was suspended set only
    // `stopLatched` / `cancelRequested` (the FSM was still `warmingUp`); it
    // must be consumed here, not lost on the way into `recording` (Codex P1).
    if stopLatched {
      finishTerminal(.discarded, sid: sid)
      return
    }
    if cancelRequested {
      finishTerminal(.cancelled, sid: sid)
      return
    }

    // Recording.
    transition(to: .recording)
    resourcesReleased = false

    let exit = await awaitRecordingExit()
    guard isCurrent(sid), !state.isTerminal else { return }
    audioCapture.onBufferCaptured = nil

    // `finishTerminal` discards the adapter's open session (`adapterSessionActive`)
    // and stops capture — no per-exit `adapter.cancel()` needed here.
    switch exit {
    case .cancel:
      finishTerminal(.cancelled, sid: sid)
      return
    case .audioInterruption:
      finishTerminal(.audioInterrupted, sid: sid)
      return
    case .asrInterruption:
      finishTerminal(.asrInterrupted, sid: sid)
      return
    case .captureStall:
      finishTerminal(.failed(.captureStalled), sid: sid)
      return
    case .userStop, .vadAutoStop, .maxDuration:
      break
    }

    // Stopping. The `stopping` path owns the capture stop: marking
    // `.stopping` before the await tells a concurrent `finishTerminal`
    // (a cancel landing mid-stop) not to fire a second, racing stop — it
    // waits for this one. `resourcesReleased` flips true once the stop
    // genuinely completes, even if the session went terminal meanwhile.
    transition(to: .stopping)
    captureLifecycle = .stopping
    let captureResult = await audioCapture.stopCapture()
    // Guard BEFORE touching kernel state — if a new session started while
    // `stopCapture()` was suspended, these fields belong to that session now
    // (Codex P2-round4 stale-completion guard).
    guard isCurrent(sid) else { return }
    captureLifecycle = .stopped
    resourcesReleased = true
    guard !state.isTerminal else { return }

    // Sub-minimum-duration proxy: zero buffers handed off ⇒ discarded
    // (PR-1 §B.1.2 `recording → discarded`).
    if bufferCountThisSession == 0 {
      finishTerminal(.discarded, sid: sid)
      return
    }
    if captureResult.samples.isEmpty {
      finishTerminal(.failed(.noAudioCaptured), sid: sid)
      return
    }

    // VAD no-speech gate (PR-1 §B.6) — keys on *confirmed* no-speech.
    if vad.speechEvidenceAtStop() == .confirmedNoSpeech {
      finishTerminal(.noSpeech, sid: sid)
      return
    }

    // Transcribing.
    transition(to: .transcribing)
    let outcome = await finalize(sid)
    guard isCurrent(sid), !state.isTerminal else { return }

    switch outcome {
    case .transcript(let result):
      await runFinalizing(sid, asrText: result.text)
    case .empty(let hadSpeechEvidence):
      finishTerminal(hadSpeechEvidence ? .failed(.asrEmpty) : .noSpeech, sid: sid)
    case .cancelled:
      finishTerminal(.cancelled, sid: sid)
    case .failed(.wedged):
      finishTerminal(.failed(.asrWedged), sid: sid)
    case .failed:
      finishTerminal(.failed(.asrFailed), sid: sid)
    }
  }

  /// The finalizing phase — the transcript is in hand, the safe point is in
  /// force (PR-1 §B.5). Cancel / interruption from here are ignored.
  private func runFinalizing(_ sid: SessionID, asrText: String) async {
    transition(to: .finalizing)
    finalizingSubStatus = .transcribing

    let processed: String
    do {
      processed = try await processText(asrText) { [weak self] in
        self?.finalizingSubStatus = .polishing
        self?.bump()
      }
    } catch {
      guard isCurrent(sid) else { return }
      finishTerminal(.failed(.emptyAfterProcessing), sid: sid)
      return
    }
    guard isCurrent(sid) else { return }

    // Empty after the limb steps — clipboard untouched (PR-1 §B.1.2).
    if processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      finishTerminal(.failed(.emptyAfterProcessing), sid: sid)
      return
    }

    do {
      try await store(processed)
    } catch {
      guard isCurrent(sid) else { return }
      finishTerminal(.failed(.storageFailed), sid: sid)
      return
    }
    guard isCurrent(sid) else { return }

    let result = await deliver(processed)
    guard isCurrent(sid) else { return }
    deliveredTranscript = processed
    deliveryOutcome = result
    pasteCount = (result == .pasted) ? 1 : 0
    finishTerminal(.completed, sid: sid)
  }

  // MARK: Warm-up + wedge detection

  private enum WarmUpResult { case ready, wedged, loadFailed, cancelled, stopped }

  private func warmUp(_ sid: SessionID) async -> WarmUpResult {
    loadWedgeDetected = false
    loadTickCount = 0

    // Consume the optional load-progress stream. The wedge watcher is armed
    // by the FIRST tick — real progress must be observed before a stall
    // counts (PR-1 §B.1.7). A warm-up that emits no progress signal at all is
    // the signal-free case: no watcher is ever spawned, no wedge detection.
    if let stream = adapter.loadProgress {
      spawn(sid) { [weak self] in
        for await _ in stream {
          guard let self, self.isCurrent(sid) else { return }
          self.loadTickCount += 1
          self.lastLoadTickAt = self.currentTick()
          self.bump()
          if self.loadTickCount == 1 {
            self.spawn(sid) { [weak self] in
              await self?.detectLoadWedge(sid)
            }
          }
        }
      }
    }

    do {
      try await adapter.warmUp()
    } catch {
      // Classified below — `warmUp()` throwing is expected on the wedge path
      // (the watcher cancels the adapter, which unblocks the parked load).
    }
    guard isCurrent(sid) else { return .cancelled }

    if loadWedgeDetected { return .wedged }
    if stopLatched { return .stopped }
    if cancelRequested { return .cancelled }
    if adapter.readiness == .ready { return .ready }
    return .loadFailed
  }

  /// Armed by the first load tick. Each cycle sleeps a `wedgeStallTicks`
  /// window, then measures silence *since the most recent tick*: if the load
  /// emitted no further progress for a full window and is still not ready, it
  /// is a cadence stall (PR-1 §B.1.7 — keyed on absence of progress, never a
  /// wall-clock deadline on completion). An adapter that keeps reporting
  /// progress refreshes `lastLoadTickAt` and is never misclassified — the
  /// loop just keeps watching. On detection it cancels the adapter, which
  /// unblocks the parked load.
  private func detectLoadWedge(_ sid: SessionID) async {
    while isCurrent(sid), !Task.isCancelled, !loadWedgeDetected {
      await sleepTicks(wedgeStallTicks)
      guard isCurrent(sid), !Task.isCancelled, !loadWedgeDetected else { return }
      if adapter.readiness == .ready { return }  // healthy completion
      if currentTick() &- lastLoadTickAt >= UInt64(wedgeStallTicks) {
        loadWedgeDetected = true
        bump()
        await adapter.cancel()
        return
      }
      // A tick landed within the window — the load is still progressing.
    }
  }

  // MARK: Finalize + wedge detection

  private func finalize(_ sid: SessionID) async -> ASREngineOutcome {
    finalizeWedgeDetected = false
    finalizeCompleted = false
    finalizeTickCount = 0

    if let stream = adapter.finalizeProgress {
      spawn(sid) { [weak self] in
        for await _ in stream {
          guard let self, self.isCurrent(sid) else { return }
          self.finalizeTickCount += 1
          self.lastFinalizeTickAt = self.currentTick()
          self.bump()
          if self.finalizeTickCount == 1 {
            self.spawn(sid) { [weak self] in
              await self?.detectFinalizeWedge(sid)
            }
          }
        }
      }
    }

    let outcome = await adapter.finalize()
    // Guard BEFORE touching kernel state — a `finalize()` unblocked after a
    // cancel, with a new session already started, must not clear the new
    // session's flags (Codex P2-round4 stale-completion guard).
    guard isCurrent(sid) else { return .cancelled }
    finalizeCompleted = true
    // `finalize()` is the adapter's own session-terminal hook — the open
    // session is now closed, so a later `finishTerminal` must NOT also call
    // `adapter.cancel()`.
    adapterSessionActive = false
    if finalizeWedgeDetected { return .failed(.wedged) }
    return outcome
  }

  /// Armed by the first finalize tick. Same cadence model as
  /// `detectLoadWedge` — silence since the most recent finalize tick, not a
  /// fixed window from the first (Codex review P2). A `finalize()` still in
  /// flight after a full silent window is a cadence stall (PR-1 §B.1.7).
  private func detectFinalizeWedge(_ sid: SessionID) async {
    while isCurrent(sid), !Task.isCancelled, !finalizeWedgeDetected {
      await sleepTicks(wedgeStallTicks)
      guard isCurrent(sid), !Task.isCancelled, !finalizeWedgeDetected else { return }
      if finalizeCompleted { return }  // healthy completion
      if currentTick() &- lastFinalizeTickAt >= UInt64(wedgeStallTicks) {
        finalizeWedgeDetected = true
        bump()
        await adapter.cancel()
        return
      }
      // A finalize tick landed within the window — still progressing.
    }
  }

  // MARK: Capture callbacks + buffer handoff

  private func bindCaptureCallbacks(_ sid: SessionID) {
    audioCapture.onEngineInterrupted = { [weak self] in
      self?.deliverRecordingExitIfCurrent(.audioInterruption, sid: sid)
    }
    audioCapture.onCaptureStalled = { [weak self] _ in
      self?.deliverRecordingExitIfCurrent(.captureStall, sid: sid)
    }
    audioCapture.onXPCServiceError = { [weak self] _ in
      self?.deliverRecordingExitIfCurrent(.asrInterruption, sid: sid)
    }
    audioCapture.onVADAutoStop = { [weak self] in
      self?.deliverRecordingExitIfCurrent(.vadAutoStop, sid: sid)
    }
  }

  /// The buffer-handoff callback (PR-3 plan §3.4 — reuses the shipped
  /// `Task { @MainActor }` per-buffer hop pattern). The audio-thread closure
  /// does the minimum — wrap + hop; the `@MainActor` side gates on
  /// `SessionID` + FSM state, then forwards to the adapter.
  private func makeBufferCallback(_ sid: SessionID) -> (@Sendable (AVAudioPCMBuffer) -> Void) {
    return { [weak self] buffer in
      let pcm = Self.extractSamples(buffer)
      let frameCount = Int(buffer.frameLength)
      Task { @MainActor [weak self] in
        guard let self, self.isCurrent(sid), self.state == .recording else { return }
        self.bufferSequence += 1
        let handoff = AudioBufferHandoff(
          pcm: pcm, frameCount: frameCount, sequence: self.bufferSequence, sessionID: sid)
        self.adapter.acceptAudio(handoff)
        self.bufferCountThisSession += 1
        self.bump()
      }
    }
  }

  private nonisolated static func extractSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
    let count = Int(buffer.frameLength)
    guard count > 0, let channel = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: count))
  }

  // MARK: VAD subscription

  private func subscribeVADSignals(_ sid: SessionID) {
    spawn(sid) { [weak self] in
      guard let self else { return }
      for await signal in self.vad.stopSignals {
        guard self.isCurrent(sid) else { return }
        // Stale-callback drop (PR-1 §B.1.4 invariant 7) — a signal stamped
        // with a non-current `SessionID` cannot terminate this session.
        guard signal.sessionID == self.currentSessionID else {
          self.log("dropped stale VAD signal from \(signal.sessionID.raw)")
          continue
        }
        switch signal.kind {
        case .autoStopTriggered:
          self.deliverRecordingExitIfCurrent(.vadAutoStop, sid: sid)
        case .maxDurationReached:
          self.deliverRecordingExitIfCurrent(.maxDuration, sid: sid)
        }
      }
    }
  }

  // MARK: Recording-exit channel

  private func awaitRecordingExit() async -> RecordingExit {
    if let pending = pendingRecordingExit {
      pendingRecordingExit = nil
      return pending
    }
    return await withCheckedContinuation { continuation in
      recordingExitContinuation = continuation
    }
  }

  private func deliverRecordingExit(_ exit: RecordingExit) {
    guard !recordingExitLatched else { return }
    recordingExitLatched = true
    bump()
    if let continuation = recordingExitContinuation {
      recordingExitContinuation = nil
      continuation.resume(returning: exit)
    } else {
      pendingRecordingExit = exit
    }
  }

  private func deliverRecordingExitIfCurrent(_ exit: RecordingExit, sid: SessionID) {
    guard isCurrent(sid), state == .recording else { return }
    deliverRecordingExit(exit)
  }

  // MARK: Transitions

  /// Apply one FSM transition. A forbidden transition (into a state from an
  /// illegal predecessor) is logged and refused — FSM state is left unchanged
  /// (PR-1 §B.1.2; PR-3 plan §3.10 — not `assertionFailure`, the simulator
  /// drives forbidden transitions deliberately).
  @discardableResult
  private func transition(to next: RecordingSessionState) -> Bool {
    guard isLegalTransition(from: state, to: next) else {
      forbiddenTransitionRejected = true
      log("FORBIDDEN transition \(state) → \(next) — refused, state unchanged")
      return false
    }
    state = next
    bump()
    return true
  }

  /// The legal FSM edges (PR-1 §B.1.2 transition table). Any pair not listed
  /// here is a forbidden transition — `transition(to:)` refuses it. Encoded as
  /// the per-from-state allowed `to` set rather than a blanket "any active
  /// jump is fine" (Codex P2-round3): a gross jump like `preparing → completed`
  /// or `recording → finalizing` must be rejected.
  private func isLegalTransition(
    from current: RecordingSessionState, to next: RecordingSessionState
  ) -> Bool {
    if current == next { return false }
    switch current {
    case .idle:
      // Only `start` — `idle → preparing`.
      if case .preparing = next { return true }
      return false
    case .preparing:
      switch next {
      case .warmingUp, .recording, .failed, .discarded, .cancelled,
        .audioInterrupted, .asrInterrupted:
        return true
      default:
        return false
      }
    case .warmingUp:
      switch next {
      case .recording, .failed, .discarded, .cancelled, .audioInterrupted,
        .asrInterrupted:
        return true
      default:
        return false
      }
    case .recording:
      switch next {
      case .stopping, .failed, .discarded, .cancelled, .audioInterrupted,
        .asrInterrupted:
        return true
      default:
        return false
      }
    case .stopping:
      switch next {
      case .transcribing, .failed, .noSpeech, .discarded, .cancelled,
        .audioInterrupted, .asrInterrupted:
        return true
      default:
        return false
      }
    case .transcribing:
      switch next {
      case .finalizing, .failed, .noSpeech, .cancelled, .audioInterrupted,
        .asrInterrupted:
        return true
      default:
        return false
      }
    case .finalizing:
      // Safe point — only `completed` or a `failed` delivery outcome.
      switch next {
      case .completed, .failed:
        return true
      default:
        return false
      }
    case .completed, .failed, .cancelled, .discarded, .noSpeech,
      .audioInterrupted, .asrInterrupted:
      // A terminal state may only move to `idle` (reset) or `preparing`
      // (start of a new session).
      switch next {
      case .idle, .preparing:
        return true
      default:
        return false
      }
    }
  }

  /// Reach a terminal state: transition, run nonblocking cleanup, drain the
  /// task bag (PR-1 §B.1.6, PR-3 plan §3.1a — cancel + clear, never `await`).
  /// Discards the adapter's open session and stops the capture engine if
  /// either is still in flight (PR-1 §B.1.3 cleanup column; Codex P1b / P2-r3).
  private func finishTerminal(_ terminal: RecordingSessionState, sid: SessionID) {
    guard isCurrent(sid) else { return }
    guard transition(to: terminal) else { return }
    audioCapture.onBufferCaptured = nil
    audioCapture.onEngineInterrupted = nil
    audioCapture.onCaptureStalled = nil
    audioCapture.onXPCServiceError = nil
    audioCapture.onVADAutoStop = nil
    drainTaskBag()

    // Discard the adapter's open session — the only discard hook is
    // `cancel()`. A terminal after `beginSession()` but without a `finalize()`
    // would otherwise leave a real adapter mid-session (Codex P2-round3).
    if adapterSessionActive {
      adapterSessionActive = false
      detachedAdapterCancel()
    }

    // Stop the capture engine. `resourcesReleased` flips true only once the
    // stop genuinely completes, so the cleanup surface never lies.
    switch captureLifecycle {
    case .active:
      // No stop in flight — this terminal owns it.
      captureLifecycle = .stopping
      resourcesReleased = false
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.bump()
        _ = await self.audioCapture.stopCapture()
        // Gate on the capture lifecycle, not `SessionID`. A new session that
        // started while this stop was suspended sets `captureLifecycle` to
        // `.active` via `beginCapturePhase()`, so this guard refuses to
        // overwrite its fresh state (Codex P2-round4). It still fires when the
        // session was reset to idle meanwhile — `reset()` mints a new
        // `SessionID` but leaves `captureLifecycle` at `.stopping`, so this
        // task completes its own bookkeeping rather than being orphaned
        // (Codex P2-round6).
        guard self.captureLifecycle == .stopping else { return }
        self.captureLifecycle = .stopped
        self.resourcesReleased = true
        self.bump()
      }
    case .stopping:
      // The `stopping` forward path already owns the stop; it flips
      // `resourcesReleased` true when its `stopCapture()` returns.
      resourcesReleased = false
    case .notStarted, .stopped:
      resourcesReleased = true
    }
    log("terminal \(terminal)")
  }

  // MARK: Task bag

  private func spawn(_ sid: SessionID, _ work: @escaping @MainActor () async -> Void) {
    if taskBagSessionID != sid {
      // A new session is taking over the bag — cancel the prior session's
      // stragglers (e.g. a `preWarm()` warm-up still running when `start()`
      // mints the first session), do not silently drop their handles
      // (Codex P2-round4). Their late completions are still `SessionID`-gated.
      for task in taskBag { task.cancel() }
      taskBag.removeAll()
      taskBagSessionID = sid
    }
    let task = Task { @MainActor in await work() }
    taskBag.append(task)
  }

  /// Cancel every task in the bag and clear the bag reference — nonblocking
  /// (PR-3 plan §3.1a). A task that ignores cooperative cancellation outlives
  /// the session; its late completion carries the old `SessionID` and is
  /// dropped on arrival (FSM invariant 7).
  private func drainTaskBag() {
    for task in taskBag { task.cancel() }
    taskBag.removeAll()
  }

  // MARK: Helpers

  private func isCurrent(_ sid: SessionID) -> Bool {
    currentSessionID == sid
  }

  private func resetSessionState() {
    stopLatched = false
    cancelRequested = false
    recordingExitContinuation = nil
    pendingRecordingExit = nil
    recordingExitLatched = false
    bufferCountThisSession = 0
    bufferSequence = 0
    captureLifecycle = .notStarted
    adapterSessionActive = false
    loadTickCount = 0
    finalizeTickCount = 0
    lastLoadTickAt = 0
    lastFinalizeTickAt = 0
    loadWedgeDetected = false
    finalizeWedgeDetected = false
    finalizeCompleted = false
    finalizingSubStatus = .transcribing
    deliveredTranscript = nil
    deliveryOutcome = nil
    pasteCount = 0
    forbiddenTransitionRejected = false
  }

  private func classifyCaptureStartError(_ error: Error) -> RecordingFailureReason {
    // The capture seam surfaces permission revocation distinctly from a
    // generic engine-start failure (PR-1 §B.1.2).
    let description = String(describing: error).lowercased()
    if description.contains("permission") { return .permissionDenied }
    return .captureStartFailed
  }

  private func bump() {
    workEpoch &+= 1
  }

  /// Fire `adapter.cancel()` without blocking the caller (best-effort load /
  /// finalize cancellation, D6). Bumps `workEpoch` so the simulator's
  /// quiescence drain accounts for this detached work.
  private func detachedAdapterCancel() {
    bump()
    Task { @MainActor [weak self] in
      await self?.adapter.cancel()
      self?.bump()
    }
  }

  private func log(_ message: String) {
    // Kernel logs carry FSM states / SessionIDs / counters only — never
    // transcript text (PR-3 plan §3.10 privacy boundary).
    Task { await AppLogger.shared.log("[kernel] \(message)", level: .debug, category: "Kernel") }
  }

  #if DEBUG
    // MARK: Test-only seams (PR-3 plan §3.10, §3.1a)
    //
    // These exist ONLY so the direct FSM-invariant tests can exercise the
    // forbidden-transition guard and the task-bag drain. Production callers use
    // the trigger entry points and never touch these.

    /// Drive a raw transition to exercise the forbidden-transition guard.
    @discardableResult
    func testForceTransition(to next: RecordingSessionState) -> Bool {
      transition(to: next)
    }

    /// The count of task references still held on the kernel — the §3.1a
    /// "no active task references remain after a terminal state" invariant.
    var testActiveTaskCount: Int { taskBag.count }
  #endif
}
