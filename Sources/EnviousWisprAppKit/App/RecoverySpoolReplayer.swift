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
  /// The attempt failed. The coordinator deletes on every `.failed` payload
  /// (#1740: an attempt that ran is spent, whatever its outcome).
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
  /// Recovery produced text, but the History write failed. The attempt marker
  /// stays COMMITTED (#1740): the attempt is spent, so no later scan may run
  /// ASR for this spool again even if best-effort deletion fails.
  case save(RecoveryFailureClass)
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
/// Strict LIMB: every failure path reports itself through telemetry/breadcrumb
/// and never throws into the heart path. "Reports" means TO US — there is no
/// user-visible failure notice on this path at all (#1897); read this line as
/// being about the signal, never about what the user is shown. #1464: it no longer
/// destroys the spool/key — it returns a typed outcome and `RecoveryCoordinator`
/// (the sole destructor) deletes or retains. It KEEPS the attempt-marker lifecycle
/// (the one-attempt guard): a per-spool marker written BEFORE the risky
/// load/transcribe means a spool whose attempt already started is abandoned (not
/// retried) on the next launch. #1740: a History-save failure LEAVES that marker
/// committed — the attempt is spent — so a spool that survives a failed cleanup
/// cannot run ASR twice. The marker is cleared only where no ASR ran (the
/// transient-Keychain deferral).
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

    // One-attempt guard: a marker already present means a recovery attempt was
    // already STARTED for this spool and may not run again — whether it crashed,
    // or completed ASR and failed the History save (#1740), or ended before
    // cleanup finished. Abandon (log + emit), never retry. #1464: the coordinator
    // deletes on `.abandoned`; the replayer no longer destroys.
    if spoolStore.hasAttemptMarker(for: id) {
      SentryBreadcrumb.captureError(
        RecoveryReplayError.abandonedAfterAttempt,
        category: .recoveryAbandonedAfterAttempt, stage: "recovery")
      TelemetryService.shared.recoveryCompleted(
        outcome: "abandoned", reason: .attemptAlreadySpent)
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
      return failUnrecoverable(reason: reason)
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
      return failUnrecoverable(reason: .reconstructionFailed)
    }
    guard !recovered.samples.isEmpty else {
      return failUnrecoverable(
        reason: .emptyOrUnreadableSamples)
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
        reconstructedSampleCount: recovered.samples.count)
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
        reconstructedSampleCount: recovered.samples.count)
    }
    if isAborted() { return .aborted }
    guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      // Empty text on good audio. This used to file under
      // `.recoveryTranscribeFailed` under a comment calling genuine silence and a
      // transcribe hiccup "indistinguishable here". #1897: they are separable
      // now, and the conflation was expensive — it made #1813 read as a 76-user
      // P0 transcription bug when genuine throws are 5 events / 2 users.
      //
      // What separated them was existing telemetry nobody had split by `reason`:
      // all 161 carry `audio_decrypted=true`, `reconstruction_failed` and
      // `empty_or_unreadable_samples` are both zero, 158 of 161 are under ten
      // seconds, and twelve users produce ~58% of events. Decrypt, reconstruct
      // and ASR all worked; the recording held no speech.
      //
      // Still no error and no failure class — nothing threw.
      //
      // MEASURE, do not assume. The aggregate evidence says most of these are
      // silence, but no aggregate can tell you which of THESE samples held
      // speech, and an empty decode on audio that DID carry signal is a real
      // transcription failure that must not vanish into a "silence" bucket.
      // So the buffer is classified with the same primitive the live path uses,
      // and only a dead-air verdict earns the silent category.
      //
      // OFF THE MAIN ACTOR, for the same reason the decrypt above is: a
      // supported 60-minute spool is ~57.6M samples (~230 MB), and this walks it
      // twice — once for the peak, once inside `measure`. On the MainActor that
      // is a visible launch stall for the longest recordings, which are exactly
      // the ones a user most wants back. Detached rather than plain `Task`
      // because this is CPU work that must leave the main actor entirely
      // (`task-detached-proof`), mirroring `keyStore.retrieve` and `recover`.
      let samples = recovered.samples
      let measurement = await Task.detached(priority: .utility) {
        let peak = samples.reduce(Float(0)) { Swift.max($0, Swift.abs($1)) }
        return RawAudioDeadAirClassifier.measure(samples, peak: peak)
      }.value
      if isAborted() { return .aborted }
      return failUnrecoverable(
        reason: .emptyText, reconstructedSampleCount: recovered.samples.count,
        emptyDecodeHadSignal: !measurement.isDeadAir)
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
      // #1740 — the ATTEMPT is spent. ASR ran and produced text; only the
      // History write failed. The attempt marker written above stays
      // COMMITTED (it used to be cleared here so the next launch would
      // replay), so if the coordinator's best-effort deletion fails, the
      // surviving spool abandons at the entry guard instead of running ASR a
      // second time. One attempt is therefore a property of the file, not a
      // consequence of a deletion succeeding. The coordinator deletes on
      // `.save` (`shouldDeleteAfterReplay`).
      let failureClass = Self.classify(error)
      SentryBreadcrumb.add(
        stage: "recovery", message: "recovered transcript save failed — attempt spent",
        level: .warning, data: ["error": String(describing: error)])
      TelemetryService.shared.recoveryCompleted(
        outcome: "failed", reason: .saveFailed, failureClass: failureClass,
        audioDecrypted: true, spoolSeconds: spoolSeconds)
      return .failed(.save(failureClass))
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
  /// The ONE place a recovery reason is mapped to its Sentry category (#1897).
  ///
  /// It was previously chosen inline at each `failUnrecoverable` call, which is
  /// how `.emptyText` came to share `.recoveryTranscribeFailed` with a genuine
  /// ASR throw — one label covering both "transcription broke" and "the
  /// recording held no words". That conflation made #1813 read as a 76-user P0.
  /// A pair can no longer be mismatched at a call site, and the switch is
  /// exhaustive so a new reason cannot be added without choosing a category.
  /// `nonisolated` because it is a pure total function of its argument and
  /// touches no instance state — the enclosing type's `@MainActor` would
  /// otherwise force every caller onto the main actor for a switch.
  nonisolated static func category(
    for reason: RecoveryTelemetryReason,
    emptyDecodeHadSignal: Bool = false
  )
    -> SentryBreadcrumb.ErrorCategory
  {
    switch reason {
    // Nothing usable came back out of the spool.
    case .keyMissing, .keyReadFailed, .reconstructionFailed, .emptyOrUnreadableSamples:
      return .recoveryDecryptFailed
    // ASR could not run, or ran and threw.
    case .modelLoadFailed, .transcribeError:
      return .recoveryTranscribeFailed
    // An empty decode means one of two different things, and this mirrors the
    // live path EXACTLY (`RecordingSessionKernel.swift:2400`, which routes
    // `effectiveSpeechEvidence ? .failed(.asrEmpty) : .noSpeech(.asrEmptyNoSpeech)`).
    // With signal in the buffer, ASR returned nothing it should have found —
    // that is a real transcription failure and MUST stay in the transcribe
    // metric, or a genuine decode regression would hide inside "silence".
    // Only a buffer measured as dead air is the honest silent case.
    case .emptyText:
      return emptyDecodeHadSignal ? .recoveryTranscribeFailed : .recoveryEmptyText
    // Reached after a successful transcribe, or outside the replay chain
    // entirely. These do not travel through `failUnrecoverable` today; they map
    // to the decrypt bucket only so this switch stays total.
    case .saveFailed, .markerWriteFailed, .markerClearFailed, .attemptAlreadySpent,
      .keychainTransient:
      return .recoveryDecryptFailed
    }
  }

  private func failUnrecoverable(
    reason: RecoveryTelemetryReason,
    failureClass: RecoveryFailureClass? = nil,
    reconstructedSampleCount: Int? = nil,
    emptyDecodeHadSignal: Bool = false
  ) -> RecoveryReplayOutcome {
    let category = Self.category(for: reason, emptyDecodeHadSignal: emptyDecodeHadSignal)
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
  /// unrecoverable. ASR never ran, so the attempt is UNSPENT: clear the marker
  /// written above so a later retry remains eligible. If the clear itself
  /// throws, the marker survives and the next-launch guard reads the attempt as
  /// already spent, abandoning before ASR; `RecoveryCoordinator` therefore
  /// treats this id as next-launch-only so a same-launch rescan cannot burn it.
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
