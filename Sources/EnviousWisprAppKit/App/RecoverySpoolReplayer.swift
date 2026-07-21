import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Security

/// The terminal outcome of one orphan's recovery attempt (#1063 PR2). The
/// `discarded` outcome is owned by `RecoveryCoordinator` (it deletes + emits on
/// Discard), never produced by the replayer. #1464: the replayer no longer
/// destroys the spool/key — it returns this outcome and `RecoveryCoordinator`
/// (the sole destructor) applies the delete-versus-retain predicate.
enum RecoveryReplayOutcome: Equatable {
  case recovered
  /// The attempt failed. The payload tells the coordinator whether to delete
  /// (Camp A / a Camp B *candidate* Phase 1 does not yet retain) or RETAIN (a
  /// History-write failure — the audio is still good, §3.3).
  case failed(RecoveryReplayFailure)
  case abandoned
  /// A Discard bumped the recovery generation mid-flight: drop the result, save
  /// nothing. The coordinator already deleted the spool/key/marker.
  case aborted
  /// The attempt marker could not be written, so recovery was deferred WITHOUT
  /// risking an un-guarded attempt — the spool stays for a future launch.
  case deferred
  /// #1707 Phase 3 (§3.3): a Keychain read failed with a TRANSIENT status
  /// (device locked / keychain daemon not yet unlocked) and the attempt
  /// marker's clear ALSO failed — distinct from bare `.deferred` because the
  /// surviving marker means only a genuine NEW launch (never a same-launch
  /// rescan) may safely re-check this spool; `RecoveryCoordinator` routes
  /// this into `nextLaunchOnlyRecoveryIDs`.
  case deferredMarkerClearFailed
}

/// Why a replay `.failed`, carried to `RecoveryCoordinator` so it can apply the
/// sole destruction predicate (#1464). The fine-grained telemetry reason is
/// emitted by the replayer itself; this payload carries only the retain-vs-delete
/// distinction plus the class, so a test can assert the exact returned outcome.
enum RecoveryReplayFailure: Equatable {
  /// The recording could not be turned into text — key / decrypt / reconstruct /
  /// empty-samples / model-load / transcribe / empty-text. DELETE.
  case unrecoverable
  /// The transcript was produced but the History write threw; the audio is still
  /// good. RETAIN for a next-launch retry — the attempt marker was cleared.
  case save(RecoveryFailureClass)
  /// As `.save`, but clearing the attempt marker ALSO threw — RETAIN this launch,
  /// next-launch retry durability not guaranteed (the marker survives, so a
  /// future launch may treat the spool as a crashed attempt).
  case saveMarkerClearFailed(RecoveryFailureClass)
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
/// Strict LIMB: every failure path surfaces "couldn't recover" via
/// telemetry/breadcrumb and never throws into the heart path. #1464: it no longer
/// destroys the spool/key — it returns a typed outcome and `RecoveryCoordinator`
/// (the sole destructor) deletes or retains. It KEEPS the attempt-marker lifecycle
/// (the crash-loop guard): one attempt only — a per-spool marker written BEFORE the
/// risky load/transcribe means a recovery that crashed the app is abandoned (not
/// retried) on the next launch. On a History-save failure it clears that marker
/// itself so the RETAINED spool replays next launch rather than reading as
/// abandoned (§3.3).
@MainActor
final class RecoverySpoolReplayer: RecoverySpoolReplaying {
  /// #1386 PR-2: recovery used to call `ASRManagerInterface.loadModel()`, which for
  /// WhisperKit crossed XPC and had the helper build its own backend — a model the app's
  /// injected `admittedModelFolder` closure cannot reach, so it could not resolve the owned
  /// folder and could only fall back to fetching. It now goes through the active-engine door,
  /// which routes each engine to its own in-process loader.
  private let activeEngine: ActiveEngineOperation
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

  /// Test-only observation seam (GitHub cloud review, PR #1732): fires right
  /// after the attempt marker write succeeds, before the Keychain retrieve
  /// begins. Nil in production — exists so a test can deterministically
  /// revoke spool-directory write access between the marker WRITE and its
  /// later CLEAR (simulating a marker-clear failure) instead of polling
  /// `hasAttemptMarker`, which can miss the narrow true→false window
  /// entirely if the detached Keychain-read task races ahead of the poll.
  var onAttemptMarkerWritten: (() -> Void)?

  init(
    activeEngine: ActiveEngineOperation,
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
    self.activeEngine = activeEngine
    self.keyStore = keyStore
    self.makeSpoolStore = makeSpoolStore
    self.transcriptStore = transcriptStore
    self.transcriptCoordinator = transcriptCoordinator
    self.keychainManager = keychainManager
    self.outputClassifierHolder = outputClassifierHolder
    self.egOneRuntime = egOneRuntime
    self.currentVocabulary = currentVocabulary
  }

  enum RecoveryReplayError: Error {
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
    // crashed the app — abandon (log + emit), never retry. #1464: the coordinator
    // deletes on `.abandoned`; the replayer no longer destroys.
    if spoolStore.hasAttemptMarker(for: id) {
      SentryBreadcrumb.captureError(
        RecoveryReplayError.abandonedAfterAttempt,
        category: .recoveryAbandonedAfterAttempt, stage: "recovery")
      TelemetryService.shared.recoveryCompleted(outcome: "abandoned", reason: .crashLoop)
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
      TelemetryService.shared.recoveryCompleted(outcome: "deferred", reason: .markerWriteFailed)
      return .deferred
    }
    onAttemptMarkerWritten?()

    // Retrieve the per-session key off the MainActor (`keychain-not-mainactor`).
    // #1464: split a MISSING key (`key_missing`) from a store READ failure
    // (`key_read_failed`) — the `try?` that swallowed both is gone.
    let keyStore = self.keyStore
    let keyResult: Result<Data, any Error> = await Task.detached(priority: .utility) {
      Result { try keyStore.retrieve(for: id) }
    }.value
    if isAborted() { return .aborted }
    let keyData: Data
    switch keyResult {
    case .success(let data):
      keyData = data
    case .failure(let error):
      // #1707 Phase 3 (§3.3, #1360): a TRANSIENT Keychain status (device
      // locked / keychain daemon not yet unlocked) is a genuinely different
      // condition from a permanent read failure — defer this attempt rather
      // than treating it as unrecoverable and deleting a recoverable spool.
      if let keyStoreError = error as? RecoveryKeyStoreError,
        case .retrieveFailed(let status) = keyStoreError,
        Self.isTransientKeychainStatus(status)
      {
        return deferForTransientKeychainFailure(spoolStore: spoolStore, id: id)
      }
      let reason: RecoveryTelemetryReason =
        (error as? RecoveryKeyStoreError) == .notFound ? .keyMissing : .keyReadFailed
      return failUnrecoverable(reason: reason, category: .recoveryDecryptFailed)
    }

    // Decrypt + reconstruct the valid prefix off the MainActor (heavy for a long
    // take). `recover` fails closed on a cipher-mode mismatch. #1464: a THROW
    // before a `RecoveredSpool` exists is `reconstruction_failed`; a spool that
    // decodes to an EMPTY authenticated prefix is `empty_or_unreadable_samples`.
    // Neither emits `audio_decrypted` (its absence IS the "not reconstructed"
    // signal); a NON-EMPTY prefix continues below with `audio_decrypted=true`.
    let cipher = RecoverySpoolCipher(mode: .aesGcm256, keyData: keyData)
    let recoverResult: Result<RecoveredSpool, any Error> = await Task.detached(priority: .utility) {
      Result { try spoolStore.recover(recoverySessionID: id, cipher: cipher) }
    }.value
    if isAborted() { return .aborted }
    let recovered: RecoveredSpool
    switch recoverResult {
    case .success(let spool):
      recovered = spool
    case .failure:
      return failUnrecoverable(reason: .reconstructionFailed, category: .recoveryDecryptFailed)
    }
    guard !recovered.samples.isEmpty else {
      return failUnrecoverable(
        reason: .emptyOrUnreadableSamples, category: .recoveryDecryptFailed)
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
      // A replay racing the #1386 launch migration can find no admitted model,
      // fail, and delete the spool. ACCEPTED, not a defect (founder ruling,
      // plan §2.4: "If we lose a recording, we lose a recording"): recovery is
      // a limb, and a migration gate here is the crash-recovery coupling that
      // ruling exists to forbid. Reviewers keep re-deriving this — do not
      // "fix" it without a new founder decision.
      try await activeEngine.load()
    } catch {
      // Discard hard-resets the engine, which can throw here — that's an abort,
      // not a recovery failure (don't log/emit; the coordinator owns cleanup).
      if isAborted() { return .aborted }
      return failUnrecoverable(
        reason: .modelLoadFailed, failureClass: Self.classify(error),
        reconstructedSampleCount: recovered.samples.count, category: .recoveryTranscribeFailed)
    }
    // Discard during the model load: bail BEFORE the expensive batch transcribe.
    if isAborted() { return .aborted }
    let result: ASRResult
    do {
      result = try await activeEngine.transcribe(recovered.samples, options)
    } catch {
      // A Discard-driven engine reset kills the in-flight transcribe and surfaces
      // here as a throw — treat it as an abort (the user discarded), not a failure.
      if isAborted() { return .aborted }
      return failUnrecoverable(
        reason: .transcribeError, failureClass: Self.classify(error),
        reconstructedSampleCount: recovered.samples.count, category: .recoveryTranscribeFailed)
    }
    if isAborted() { return .aborted }
    guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      // Empty text on good audio: a Camp B *candidate* (genuine silence vs a
      // transcribe hiccup are indistinguishable here) — no error, so no class.
      return failUnrecoverable(
        reason: .emptyText, reconstructedSampleCount: recovered.samples.count,
        category: .recoveryTranscribeFailed)
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
    let spoolSeconds = Int(recoveredSeconds.rounded())
    do {
      try transcriptStore.save(transcript)
    } catch {
      // §3.3 (#1464) — a History-write failure is NOT audio loss. RETAIN the spool
      // (the coordinator does not delete `.save`) and clear the attempt marker so
      // the next launch REPLAYS instead of reading the spool as a crashed attempt.
      // The clear can throw (`RecoverySpoolStore.deleteAttemptMarker`); if it does,
      // retain THIS launch but do not claim durable next-launch retry.
      let failureClass = Self.classify(error)
      SentryBreadcrumb.add(
        stage: "recovery", message: "recovered transcript save failed — retaining spool",
        level: .warning, data: ["error": String(describing: error)])
      do {
        try spoolStore.deleteAttemptMarker(for: id)
        TelemetryService.shared.recoveryCompleted(
          outcome: "failed", reason: .saveFailed, failureClass: failureClass,
          audioDecrypted: true, spoolSeconds: spoolSeconds)
        return .failed(.save(failureClass))
      } catch {
        TelemetryService.shared.recoveryCompleted(
          outcome: "failed", reason: .markerClearFailed, failureClass: failureClass,
          audioDecrypted: true, spoolSeconds: spoolSeconds)
        return .failed(.saveMarkerClearFailed(failureClass))
      }
    }
    transcriptCoordinator.append(transcript)

    // Success. #1464: the coordinator deletes the spool (+ marker) + key on
    // `.recovered` and posts the success notice; the replayer only reports.
    TelemetryService.shared.recoveryCompleted(
      outcome: "recovered",
      recoveredSeconds: Int(recoveredSeconds.rounded()),
      polishFellBack: textOutcome.polishedText == nil)
    return .recovered
  }

  /// Emit the failure breadcrumb + telemetry and return `.failed(.unrecoverable)`.
  /// Does NOT delete — the coordinator is the sole destructor (#1464), deleting on
  /// `.unrecoverable`. `reconstructedSampleCount` present ⇒ authenticated
  /// reconstruction succeeded, so emit `audio_decrypted=true`, the spool-seconds
  /// bucket, and `camp_b_candidate=true` (good audio, failed downstream — the only
  /// case a future retry could help). Absent ⇒ omit both (never `audio_decrypted
  /// =false`).
  private func failUnrecoverable(
    reason: RecoveryTelemetryReason,
    failureClass: RecoveryFailureClass? = nil,
    reconstructedSampleCount: Int? = nil,
    category: SentryBreadcrumb.ErrorCategory
  ) -> RecoveryReplayOutcome {
    SentryBreadcrumb.captureError(
      RecoveryReplayError.failed(reason.rawValue), category: category, stage: "recovery")
    let spoolSeconds = reconstructedSampleCount.map {
      Int((Double($0) / AudioConstants.sampleRate).rounded())
    }
    TelemetryService.shared.recoveryCompleted(
      outcome: "failed",
      reason: reason,
      failureClass: failureClass,
      audioDecrypted: reconstructedSampleCount != nil ? true : nil,
      campBCandidate: reconstructedSampleCount != nil ? true : nil,
      spoolSeconds: spoolSeconds)
    return .failed(.unrecoverable)
  }

  /// #1707 Phase 3 (§3.3): a Keychain read failed with a status expected to
  /// clear on its own — defer this attempt WITHOUT treating it as
  /// unrecoverable. Clears the attempt marker written above (mirrors the
  /// existing `.save`/`.saveMarkerClearFailed` retention path, RULE:
  /// port-proven-patterns-wholesale) so a same-launch or next-launch retry
  /// sees a clean spool, not a crashed one. If the clear itself throws, the
  /// marker survives and `RecoveryCoordinator` must treat this id as
  /// next-launch-only — a same-launch rescan would otherwise misread the
  /// surviving marker as a crashed attempt and abandon (delete) it.
  private func deferForTransientKeychainFailure(
    spoolStore: RecoverySpoolStore, id: String
  ) -> RecoveryReplayOutcome {
    do {
      try spoolStore.deleteAttemptMarker(for: id)
      TelemetryService.shared.recoveryCompleted(outcome: "deferred", reason: .keychainTransient)
      return .deferred
    } catch {
      TelemetryService.shared.recoveryCompleted(outcome: "deferred", reason: .markerClearFailed)
      return .deferredMarkerClearFailed
    }
  }

  /// #1707 Phase 3 (§3.3): OSStatus values expected to clear on their own —
  /// documented Apple meanings, not app-evidenced (the raw status is
  /// discarded before Sentry/PostHog ever see it, so no production history
  /// exists to confirm against). A false-transient (retrying a truly-terminal
  /// code) costs one extra deferred cycle before the next wake-up re-attempts
  /// and still eventually fails clean; a false-terminal (deleting a
  /// recoverable spool) costs the recording permanently — the asymmetry
  /// favors inclusion. `errSecAuthFailed`/`errSecUserCanceled` stay terminal:
  /// a later retry CAN succeed after user action, but nothing in this flow (a
  /// background replay, no user present to act) can clear them.
  private static func isTransientKeychainStatus(_ status: OSStatus) -> Bool {
    switch status {
    case errSecInteractionNotAllowed, errSecInteractionRequired, errSecInDarkWake,
      errSecNotAvailable, errSecServiceNotAvailable, errSecDatabaseLocked:
      return true
    default:
      return false
    }
  }

  /// Map a caught ASR/storage error to the narrow telemetry failure class (#1464).
  /// The `NSError` domain/code is INPUT only — never emitted. Starts narrow
  /// (D-030): only the two host-side wrappers are reliably typed — the default ASR
  /// engine crosses XPC, which bridges everything else to an opaque `NSError` and
  /// collapses decode causes into one string. `.notReady` is reserved for a Phase 2
  /// in-process producer (`ASRError` is ASR-module-internal, kept isolated per
  /// D-028); an unrecognized error is `.other`.
  private static func classify(_ error: any Error) -> RecoveryFailureClass {
    // #1525 PR I-B: narrowed from a bare type-check — the 6 new
    // codec/transport cases are transport/codec failures, not "XPC
    // unreachable," and mislabeling them would corrupt recovery telemetry.
    if let transport = error as? XPCASRTransportError, transport.isServiceUnreachable {
      return .xpcUnreachable
    }
    if error is ASRLoadSupersededError { return .cancelled }
    return .other
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

// MARK: - Sentry identity

/// Pins each case's Sentry grouping key to its exact pre-migration string
/// already observed in Sentry (#1525 PR C), mirroring `HeartPathError`'s
/// shipped pattern.
///
/// The descriptors are NOT derived — they were MEASURED with this type still
/// `private` (widened to `internal` in this same PR, only after measuring —
/// widening first would have corrupted the baseline, see plan §2.5.4) and
/// cross-checked against the live Sentry issue titles (ENVIOUSWISPR-2R/1Z/2N/
/// 2M/20). A `private`-or-narrower type's bridged domain falls back to the
/// bare simple type name (`SentryBreadcrumb.structuredDescriptor`'s
/// `(unknown context at ...)` branch — proven by the shipped
/// `SentryEventSanitizerTests.nestedPrivateErrorDescriptorNormalizes`
/// fixture), never the module- or class-qualified name — so `internal`
/// widening never changes what was already shipping.
extension RecoverySpoolReplayer.RecoveryReplayError: StableSentryErrorIdentity {
  var sentryFingerprintDescriptor: String {
    switch self {
    case .abandonedAfterAttempt: return "RecoveryReplayError#1"
    case .failed: return "RecoveryReplayError#0"
    }
  }

  var sentrySemanticID: String {
    switch self {
    case .abandonedAfterAttempt: return "recovery.replay_abandoned_after_attempt"
    case .failed: return "recovery.replay_failed"
    }
  }
}
