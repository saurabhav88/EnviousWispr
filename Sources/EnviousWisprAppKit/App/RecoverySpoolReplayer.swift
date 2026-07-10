import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import EnviousWisprServices
import EnviousWisprStorage
import Foundation

/// The terminal outcome of one orphan's recovery attempt (#1063 PR2). The
/// `discarded` outcome is owned by `RecoveryCoordinator` (it deletes + emits on
/// Discard), never produced by the replayer.
enum RecoveryReplayOutcome: Equatable {
  case recovered
  case failed
  case abandoned
  /// A Discard bumped the recovery generation mid-flight: drop the result, save
  /// nothing. The coordinator already deleted the spool/key/marker.
  case aborted
  /// The attempt marker could not be written, so recovery was deferred WITHOUT
  /// risking an un-guarded attempt — the spool stays for a future launch.
  case deferred
}

/// Per-orphan recovery execution seam — lets `RecoveryCoordinator` drive scan /
/// gate / generation / single-flight logic against a test double while the real
/// `RecoverySpoolReplayer` owns the heavy decrypt→transcribe→polish→save chain.
@MainActor
protocol RecoverySpoolReplaying: AnyObject {
  func replay(recoverySessionID: String, isAborted: @MainActor () -> Bool) async
    -> RecoveryReplayOutcome
}

/// Per-orphan execution of the crash-recovery REPLAY flow (#1063 PR2).
///
/// `RecoveryCoordinator` owns the launch scan, the recording gate, dedup, and
/// cleanup routing; this type owns the heavy per-spool chain so the coordinator
/// stays thin (`keep-central-types-thin`): write the one-attempt marker, decrypt,
/// transcribe on the shared engine, polish under record-time settings, and save a
/// non-auto-pasting "Recovered" transcript to History.
///
/// Strict LIMB: every failure path deletes the orphan and surfaces "couldn't
/// recover" via telemetry/breadcrumb — it never throws into the heart path. One
/// attempt only: a per-spool marker written BEFORE the risky load/transcribe means
/// a recovery that crashed the app is abandoned (not retried) on the next launch.
@MainActor
final class RecoverySpoolReplayer: RecoverySpoolReplaying {
  private let asrManager: any ASRManagerInterface
  private let keyStore: RecoveryKeyStore
  private let makeSpoolStore: @Sendable () -> RecoverySpoolStore
  private let transcriptStore: TranscriptStore
  private let transcriptCoordinator: TranscriptCoordinator
  private let keychainManager: KeychainManager
  private let outputClassifierHolder: OutputClassifierHolder
  /// #1271: EG-1 runtime handle — recovery polishes through the same server
  /// as live dictation (or silently skips when it is not ready).
  private let egOneRuntime: (any EGOneEndpointProviding)?
  /// Current custom-words vocabulary, best-effort (the snapshot carries only the
  /// version, not the terms — recovery promises normal-quality, not byte-exact).
  private let currentVocabulary:
    @MainActor () -> (corrector: CorrectorVocabulary, polish: PolishVocabulary)

  init(
    asrManager: any ASRManagerInterface,
    keyStore: RecoveryKeyStore,
    makeSpoolStore: @escaping @Sendable () -> RecoverySpoolStore,
    transcriptStore: TranscriptStore,
    transcriptCoordinator: TranscriptCoordinator,
    keychainManager: KeychainManager,
    outputClassifierHolder: OutputClassifierHolder,
    egOneRuntime: (any EGOneEndpointProviding)? = nil,
    currentVocabulary: @escaping @MainActor () -> (
      corrector: CorrectorVocabulary, polish: PolishVocabulary
    )
  ) {
    self.asrManager = asrManager
    self.keyStore = keyStore
    self.makeSpoolStore = makeSpoolStore
    self.transcriptStore = transcriptStore
    self.transcriptCoordinator = transcriptCoordinator
    self.keychainManager = keychainManager
    self.outputClassifierHolder = outputClassifierHolder
    self.egOneRuntime = egOneRuntime
    self.currentVocabulary = currentVocabulary
  }

  private enum RecoveryReplayError: Error {
    case abandonedAfterAttempt
    case failed(String)
  }

  /// Replay one orphan end to end. `isAborted` returns true once a Discard has
  /// bumped the recovery generation since this orphan started; it is checked
  /// after every `await` and immediately before the synchronous save so a
  /// discarded in-flight (uncancellable) batch transcribe can never write a stale
  /// "Recovered" entry. Emits recovery telemetry + breadcrumbs itself (the
  /// `discarded` outcome is the coordinator's).
  func replay(recoverySessionID id: String, isAborted: @MainActor () -> Bool) async
    -> RecoveryReplayOutcome
  {
    let spoolStore = makeSpoolStore()

    // One-attempt crash-loop guard: a marker already present means a prior attempt
    // crashed the app — abandon (delete + log), never retry.
    if spoolStore.hasAttemptMarker(for: id) {
      cleanUp(id, spoolStore: spoolStore)
      SentryBreadcrumb.captureError(
        RecoveryReplayError.abandonedAfterAttempt,
        category: .recoveryAbandonedAfterAttempt, stage: "recovery")
      TelemetryService.shared.recoveryCompleted(outcome: "abandoned", reason: "crash_loop")
      return .abandoned
    }
    // Write the marker DURABLY before any risky load/transcribe (warm-up included).
    // If it can't be written, defer rather than risk an un-guarded attempt.
    do {
      try spoolStore.writeAttemptMarker(for: id)
    } catch {
      SentryBreadcrumb.add(
        stage: "recovery", message: "attempt-marker write failed — deferring recovery",
        level: .warning, data: ["error": String(describing: error)])
      return .deferred
    }

    // Retrieve the per-session key off the MainActor (`keychain-not-mainactor`).
    let keyStore = self.keyStore
    let keyData: Data? = await Task.detached(priority: .utility) {
      try? keyStore.retrieve(for: id)
    }.value
    if isAborted() { return .aborted }
    guard let keyData else {
      return fail(id, spoolStore: spoolStore, reason: "decrypt", category: .recoveryDecryptFailed)
    }

    // Decrypt + reconstruct the valid prefix off the MainActor (heavy for a long
    // take). `recover` fails closed on a cipher-mode mismatch.
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: keyData)
    let recovered: RecoveredSpool? = await Task.detached(priority: .utility) {
      try? spoolStore.recover(recoverySessionID: id, cipher: cipher)
    }.value
    if isAborted() { return .aborted }
    guard let recovered, !recovered.samples.isEmpty else {
      return fail(id, spoolStore: spoolStore, reason: "decrypt", category: .recoveryDecryptFailed)
    }

    // Transcribe on the shared engine (batch). The marker already covers warm-up.
    //
    // BEST-EFFORT BACKEND (deliberate; Codex code-diff r4 P2 → PR3): recovery uses
    // the CURRENT active engine, not `recovered.settings?.backendType`. The audio is
    // backend-neutral (16 kHz mono), so either engine yields valid text; the only
    // effect is a possible quality difference for the rare user who SWITCHED engines
    // between the recording and this crash-recovery. Switching the shared engine to
    // the record-time backend (and restoring after, across the discard/abort paths)
    // is heavy for a limb; record-time backend FIDELITY is routed to PR3 hardening.
    // The saved transcript's `backendType` is `result.backendType` — the engine that
    // actually transcribed — so the metadata stays accurate either way.
    let options = Self.transcriptionOptions(for: recovered.settings)
    do {
      try await asrManager.loadModel()
    } catch {
      // Discard hard-resets the engine, which can throw here — that's an abort,
      // not a recovery failure (don't delete/log; the coordinator owns cleanup).
      if isAborted() { return .aborted }
      return fail(
        id, spoolStore: spoolStore, reason: "transcribe", category: .recoveryTranscribeFailed)
    }
    // Discard during the model load: bail BEFORE the expensive batch transcribe.
    if isAborted() { return .aborted }
    let result: ASRResult
    do {
      result = try await asrManager.transcribe(audioSamples: recovered.samples, options: options)
    } catch {
      // A Discard-driven engine reset kills the in-flight transcribe and surfaces
      // here as a throw — treat it as an abort (the user discarded), not a failure.
      if isAborted() { return .aborted }
      return fail(
        id, spoolStore: spoolStore, reason: "transcribe", category: .recoveryTranscribeFailed)
    }
    if isAborted() { return .aborted }
    guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return fail(id, spoolStore: spoolStore, reason: "empty", category: .recoveryTranscribeFailed)
    }

    // Polish under the recording's record-time settings (raw-fallback floor
    // guaranteed: a failed/skipped polish lands raw text, still saved + labeled).
    let processor = RecoveryTextProcessor(
      keychainManager: keychainManager, outputClassifierHolder: outputClassifierHolder,
      egOneRuntime: egOneRuntime)
    if let settings = recovered.settings { processor.applySettings(settings) }
    let vocab = currentVocabulary()
    processor.applyCustomWordsVocabulary(corrector: vocab.corrector, polish: vocab.polish)
    let textOutcome = await processor.process(rawText: result.text)
    if isAborted() { return .aborted }

    // Build the recovered transcript.
    let recoveredSeconds = Double(recovered.samples.count) / AudioConstants.sampleRate
    let transcript = Transcript(
      text: textOutcome.text,
      polishedText: textOutcome.polishedText,
      language: result.language ?? Self.lockedLanguage(recovered.settings?.languageMode),
      duration: recoveredSeconds,
      backendType: result.backendType,
      // #1305: stamp provider/model ONLY when polish actually produced output —
      // the live path never stamps on a failed/skipped polish, and the settings
      // snapshot would otherwise label a raw recovered transcript AI-polished.
      llmProvider: textOutcome.polishedText != nil ? recovered.settings?.llmProvider : nil,
      llmModel: textOutcome.polishedText != nil ? recovered.settings?.llmModel : nil,
      recoverySessionID: id,
      isRecovered: true,
      // #1408: unknown, never guessed. The spool's own `RecoverySpoolTermination
      // Reason` is a WRITER-side reason (its `.interrupted` means the helper
      // process exited); a mic disconnect leaves the helper alive, so it never
      // appears there and cannot answer "was the input device removed." `true`
      // would lie for app-crash recovery, `false` for a retained disconnect
      // spool. `isRecovered: true` above is the honest abnormal-exit signal.
      inputDeviceWasRemoved: nil)

    // FINAL abort check immediately before the SYNCHRONOUS save + append — there
    // is no `await` between here and `append`, so a Discard cannot interleave a
    // stale save (the uncancellable-transcribe stale-save guard, Codex REV-2 R2).
    if isAborted() { return .aborted }
    do {
      try transcriptStore.save(transcript)
    } catch {
      SentryBreadcrumb.add(
        stage: "recovery", message: "recovered transcript save failed",
        level: .warning, data: ["error": String(describing: error)])
      cleanUp(id, spoolStore: spoolStore)
      TelemetryService.shared.recoveryCompleted(outcome: "failed", reason: "save")
      return .failed
    }
    transcriptCoordinator.append(transcript)

    // Success: delete spool (+ marker) + key.
    cleanUp(id, spoolStore: spoolStore)
    TelemetryService.shared.recoveryCompleted(
      outcome: "recovered",
      recoveredSeconds: Int(recoveredSeconds.rounded()),
      polishFellBack: textOutcome.polishedText == nil)
    return .recovered
  }

  /// Delete + log a failed orphan (one attempt — no keep-for-retry in PR2).
  private func fail(
    _ id: String, spoolStore: RecoverySpoolStore, reason: String,
    category: SentryBreadcrumb.ErrorCategory
  ) -> RecoveryReplayOutcome {
    cleanUp(id, spoolStore: spoolStore)
    SentryBreadcrumb.captureError(
      RecoveryReplayError.failed(reason), category: category, stage: "recovery")
    TelemetryService.shared.recoveryCompleted(outcome: "failed", reason: reason)
    return .failed
  }

  /// Delete a spool (which also clears its attempt marker) and destroy its key.
  private func cleanUp(_ id: String, spoolStore: RecoverySpoolStore) {
    try? spoolStore.delete(recoverySessionID: id)
    let keyStore = self.keyStore
    Task.detached(priority: .utility) { try? keyStore.delete(for: id) }
  }

  private static func transcriptionOptions(for settings: RecordingSettingsSnapshot?)
    -> TranscriptionOptions
  {
    var options = TranscriptionOptions()
    if let code = lockedLanguage(settings?.languageMode) { options.language = code }
    return options
  }

  private static func lockedLanguage(_ mode: LanguageMode?) -> String? {
    if case .locked(let code) = mode { return code }
    return nil
  }
}
