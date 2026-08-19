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

  /// Wall clock, injected so the #2087 expiry check is testable without waiting
  /// 24 hours. A test that slept on real time to cross this boundary would be
  /// flaky by construction and would take a day to exercise the case that
  /// matters.
  private let now: @Sendable () -> Date

  init(
    activeEngine: ActiveEngineOperation,
    keyStore: RecoveryKeyStore,
    makeSpoolStore: @escaping @Sendable () -> RecoverySpoolStore,
    transcriptStore: TranscriptStore,
    transcriptCoordinator: TranscriptCoordinator,
    keychainManager: KeychainManager,
    outputClassifierHolder: OutputClassifierHolder,
    egOneRuntime: (any EGOneEndpointProviding)? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    currentVocabulary: @escaping @MainActor () -> (
      corrector: CorrectorVocabulary, polish: PolishVocabulary
    )
  ) {
    self.now = now
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
    // #2087: is this spool a cancelled-but-kept dictation? Read BEFORE spending
    // ASR, because a marker we cannot trust must abort the whole replay rather
    // than be discovered after the expensive work.
    //
    // `.absent` for anyone who has not turned Escape Recovery on, which is the
    // default, so the path below stays exactly today's behaviour for them.
    let escapeMarker = spoolStore.readEscapeMarker(for: id)
    if case .malformed = escapeMarker {
      // FAIL CLOSED, and note which way "closed" points here. The safe default
      // is NOT "carry on as an ordinary crash rescue": a corrupt Escape marker
      // is positive evidence this spool probably WAS a cancel, so recovering it
      // normally would hand the user a PERMANENT History row wearing the
      // crash-Recovered badge for a dictation they deliberately cancelled.
      // Nor can it become a pending row — the trustworthy `triggeredAt` is
      // exactly what was lost, so its 24-hour clock is unknowable.
      //
      // `.unrecoverable` because the coordinator deletes on every `.failed`, and
      // deleting is the honest outcome: the user asked for this to go away, and
      // the one artefact that could have kept it is unreadable.
      //
      // Routed through `failUnrecoverable` — the single place that maps a reason
      // to its category and its channel — rather than emitting here. Hand-rolled
      // emission is how the sibling verdict branch below came to be classified as
      // alerting while producing no Sentry error at all.
      return failUnrecoverable(reason: .malformedEscapeMarker)
    }
    // #2087: a marker the store would refuse to SHOW must not cost the engine.
    //
    // Asked through the shared `PendingAdmission` rule rather than re-derived
    // here. The first version of this gate checked only elapsed time, and missed
    // future-dated markers: a skewed clock would decrypt, transcribe, polish and
    // save a row that `loadPending` then rejects as corrupt — pure waste, and on
    // a BYOK provider the user's own money spent producing something they can
    // never see. Two copies of one rule diverge the moment one gains a condition,
    // which is precisely what happened, so there is now only one copy.
    //
    // Both non-live verdicts discard, but they are NOT the same event: `.expired`
    // is a Mac left off over a weekend (ordinary, counted), `.corrupt` is a clock
    // we cannot reason about (ours, alerted).
    if case .valid(let marker) = escapeMarker {
      let verdict = PendingAdmission.verdict(stampedAt: marker.triggeredAt, now: now())
      if verdict != .live {
        // Routed through `failUnrecoverable`, which is the ONE place that turns a
        // reason into a channel. An earlier version emitted its own breadcrumb
        // here and never called `captureError`, so `.corrupt` was documented as
        // alerting, carried an alerting category, sat in the alert inventory —
        // and silently produced no Sentry error at all. The classification was
        // decorative; the routing is what makes it real.
        return failUnrecoverable(
          reason: verdict == .expired ? .escapeRecoveryExpired : .malformedEscapeMarker)
      }
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
      let diagnosis = Self.diagnose(error, operation: .modelLoad)
      if Self.engineWasNeverAvailable(diagnosis) {
        return deferForUnavailableEngine(
          spoolStore: spoolStore, id: id, reason: .modelLoadFailed, diagnosis: diagnosis,
          reconstructedSampleCount: recovered.samples.count)
      }
      return failUnrecoverable(
        reason: .modelLoadFailed, diagnosis: diagnosis,
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
      let diagnosis = Self.diagnose(error, operation: .transcription)
      if Self.engineWasNeverAvailable(diagnosis) {
        return deferForUnavailableEngine(
          spoolStore: spoolStore, id: id, reason: .transcribeError, diagnosis: diagnosis,
          reconstructedSampleCount: recovered.samples.count)
      }
      return failUnrecoverable(
        reason: .transcribeError, diagnosis: diagnosis,
        reconstructedSampleCount: recovered.samples.count)
    }
    if isAborted() { return .aborted }
    guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      // ASR ran and returned an empty result. This used to file under
      // `.recoveryTranscribeFailed`, the same category as a THROW, so one label
      // covered both. That was expensive: it made #1813 read as a 76-user P0
      // transcription bug when genuine throws are 5 events / 2 users.
      //
      // What the existing `recovery.completed.reason` split shows, once anyone
      // looks at it: `empty_text` is ~93% of non-successes on the current
      // release, all 161 carry `audio_decrypted=true`, `reconstruction_failed`
      // and `empty_or_unreadable_samples` are both zero, 158 of 161 are under
      // ten seconds, and twelve users produce ~58% of events. Decrypt and
      // reconstruct worked and ASR ran without error. WHY it came back empty is
      // not established by any of that.
      //
      // Still no error and no failure class — nothing threw. It carries its own
      // category so it stops being counted as a transcription failure.
      //
      // THE CATEGORY RECORDS WHAT HAPPENED, NOT WHY (#1897). "ASR returned an
      // empty result" is a fact; "the recording was silent" is an inference this
      // path cannot make, and three review rounds were spent trying:
      //
      //   1. Assume every empty is silence — no evidence at all.
      //   2. Use the dead-air classifier as speech evidence — but that is a
      //      DEAD-AIR detector, not a speech detector. Ordinary room noise sits
      //      around 0.0178 against a 0.006 floor (13 quiet-room controls
      //      measured 0.0170-0.0930), so nearly every real silent room would
      //      read as "had signal" and the split would barely fire.
      //   3. Rerun VAD here — the only true discriminator, and the live path's
      //      `speechEvidenceAtStop()` is exactly that. Out of scope: it is a
      //      second inference pass over a recovered buffer to decide a label.
      //
      // So this stops inferring. `recovery_transcribe_failed` now means ASR
      // THREW; `recovery_empty_text` means ASR RETURNED EMPTY. Both are
      // observations, neither claims a cause, and the false P0 in #1813 came
      // from the two sharing one label — not from anyone knowing which were
      // silent. If a cause is ever needed per-take, VAD evidence is the way,
      // and it belongs with the #1876 input-attribution work rather than here.
      return failUnrecoverable(
        reason: .emptyText, reconstructedSampleCount: recovered.samples.count)
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
    //
    // #2087: a valid Escape marker changes what this row IS, so it is read here
    // rather than at the save call. `isRecovered` must be FALSE for an escape
    // recovery: that flag drives the crash-rescue badge, and this take was not
    // rescued from a crash — the user cancelled it on purpose and the app kept
    // it as they asked. Wearing the crash badge would misdescribe both what
    // happened and why the row is there.
    let escapeInfo: EscapeRecoveryMarker? = {
      if case .valid(let marker) = escapeMarker { return marker }
      return nil
    }()
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
      isRecovered: escapeInfo == nil,
      // #1408: unknown, never guessed. The spool's own `RecoverySpoolTermination
      // Reason` is a WRITER-side reason (its `.interrupted` means the helper
      // process exited); a mic disconnect leaves the helper alive, so it never
      // appears there and cannot answer "was the input device removed." `true`
      // would lie for app-crash recovery, `false` for a retained disconnect
      // spool. `isRecovered: true` above is the honest abnormal-exit signal.
      inputDeviceWasRemoved: nil,
      // #2087: the user's own clock, carried across the crash. Measuring the 24
      // hours from replay instead would hand them a fresh day they were never
      // offered — and on a Mac left off for two days, would resurrect a take
      // that should already have expired.
      escapeRecoveredAt: escapeInfo?.triggeredAt,
      escapeRecoveryTakeID: escapeInfo?.takeID)

    // FINAL abort check immediately before the SYNCHRONOUS save + append — there
    // is no `await` between here and `append`, so a Discard cannot interleave a
    // stale save (the uncancellable-transcribe stale-save guard, Codex REV-2 R2).
    if isAborted() { return .aborted }
    let spoolSeconds = Int(recoveredSeconds.rounded())
    do {
      // #2087: an escape recovery lands in the `pending/` namespace with its
      // 24-hour clock, never in ordinary History. Routed here rather than at the
      // store because the DESTINATION is a property of what this session was,
      // and the store must not have to infer that from a stamped field.
      if escapeInfo != nil {
        try transcriptStore.savePending(transcript)
      } else {
        try transcriptStore.save(transcript)
      }
    } catch {
      // #1740 — the ATTEMPT is spent. ASR ran and produced text; only the
      // History write failed. The attempt marker written above stays
      // COMMITTED (it used to be cleared here so the next launch would
      // replay), so if the coordinator's best-effort deletion fails, the
      // surviving spool abandons at the entry guard instead of running ASR a
      // second time. One attempt is therefore a property of the file, not a
      // consequence of a deletion succeeding. The coordinator deletes on
      // `.save` (`shouldDeleteAfterReplay`).
      // #2132: storage errors are NOT an ASR vocabulary. `HistorySaveErrorClass`
      // owns them; this stays `.other` until a separate change routes it there,
      // which is exactly what the old shared `classify` returned here anyway.
      let failureClass = RecoveryFailureClass.other
      SentryBreadcrumb.add(
        stage: "recovery", message: "recovered transcript save failed — attempt spent",
        level: .warning, data: ["error": String(describing: error)])
      TelemetryService.shared.recoveryCompleted(
        outcome: "failed", reason: .saveFailed, failureClass: failureClass,
        audioDecrypted: true, spoolSeconds: spoolSeconds)
      return .failed(.save(failureClass))
    }
    // Both paths append: History is where the user looks either way, and the
    // live Escape path appends its pending row too. What makes a pending row
    // LOOK pending — the Kept badge, the countdown, read-time expiry, exclusion
    // from search — belongs to `TranscriptCoordinator`, not to this replay.
    transcriptCoordinator.append(transcript)

    // Success. #1464: the coordinator deletes the spool (+ marker) + key on
    // `.recovered` and posts the success notice; the replayer only reports.
    //
    // #1762: character COUNT and audio duration only — never the transcript. A
    // count is enough to tell "recovered something real" from "recovered a
    // fragment", which is the question you ask standing at the machine.
    RecoveryLog.line(
      "replay recovered \(textOutcome.text.count) chars from "
        + "\(Int(recoveredSeconds.rounded()))s of audio")
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
  /// ASR returned an empty result". That conflation made #1813 read as a
  /// 76-user P0.
  /// A pair can no longer be mismatched at a call site, and the switch is
  /// exhaustive so a new reason cannot be added without choosing a category.
  /// `nonisolated` because it is a pure total function of its argument and
  /// touches no instance state — the enclosing type's `@MainActor` would
  /// otherwise force every caller onto the main actor for a switch.
  nonisolated static func category(for reason: RecoveryTelemetryReason)
    -> SentryBreadcrumb.ErrorCategory
  {
    switch reason {
    // Nothing usable came back out of the spool.
    case .keyMissing, .keyReadFailed, .reconstructionFailed, .emptyOrUnreadableSamples:
      return .recoveryDecryptFailed
    // ASR could not run, or ran and threw.
    case .modelLoadFailed, .transcribeError:
      return .recoveryTranscribeFailed
    // ASR ran and returned an empty result. Deliberately NOT "the recording was
    // silent" — this path has no speech evidence and cannot know (see the call
    // site). The category separates a THROW from an EMPTY RESULT, which is all
    // that is needed to stop one from inflating the other's count.
    case .emptyText:
      return .recoveryEmptyText
    // Reached after a successful transcribe, or outside the replay chain
    // entirely. These do not travel through `failUnrecoverable` today; they map
    // to the decrypt bucket only so this switch stays total.
    case .saveFailed, .markerWriteFailed, .markerClearFailed, .attemptAlreadySpent,
      .keychainTransient:
      return .recoveryDecryptFailed
    // #2087: its own category, not the decrypt catch-all above. Nothing was
    // decrypted on this path — the spool is refused at the entry guard on the
    // strength of an untrustworthy sidecar. Folding it into the decrypt bucket
    // would inflate a count that is meant to mean "the audio would not come
    // back", which is the conflation this function was written to end.
    case .malformedEscapeMarker:
      return .recoveryMalformedEscapeMarker
    // #2087: distinct from the malformed case above. That one is OUR defect and
    // alerts; this is the world being ordinary — a Mac that stayed off — and is
    // counted only.
    case .escapeRecoveryExpired:
      return .recoveryEscapeRecoveryExpired
    }
  }

  /// Reasons that are COUNTED but never alert (#1942).
  ///
  /// `empty_text` means the recovered audio was transcribed without error and
  /// ASR returned nothing. That is not a defect of ours: the overwhelmingly
  /// likely cause is a recording with no speech in it, and #1900 created this
  /// reason precisely so it would stop inflating `recovery_transcribe_failed`
  /// and producing the false P0 in #1813. Splitting it out fixed the
  /// CONFLATION; it left the benign half filing its own alerting error, which
  /// is the loop this closes.
  ///
  /// Evidence that it is not actionable, rather than an assumption: this issue
  /// was re-triaged on four consecutive days and every pass reached the same
  /// verdict — best-effort post-crash replay, no live-dictation impact, hold at
  /// P3. A condition whose triage conclusion never moves is a counted outcome
  /// sitting on the wrong channel.
  ///
  /// NOTHING GOES DARK, and that was measured before the alert was removed:
  /// `recovery.completed` already carries `reason`, and production on 2.4.3
  /// shows `empty_text` at 13 events / 5 people — the SAME 13/5 the Sentry
  /// fingerprint carries. The count is complete without the error.
  ///
  /// Deliberately narrow. `transcribe_error` (ASR threw), `model_load_failed`,
  /// `key_missing`, `decrypt` and every future reason keep alerting: those are
  /// ours. The general principle: Sentry errors are for OUR defects, while a
  /// user-environment or expected outcome is counted in analytics and carries a
  /// breadcrumb for context, never an alert.
  nonisolated static func isCountedNotAlerted(_ reason: RecoveryTelemetryReason) -> Bool {
    switch reason {
    // #2087: an escape recovery that outlived its 24 hours while the Mac was off
    // is the world behaving normally, not a defect of ours. Counted so we can see
    // how often it happens; never alerted, for the same reason `.emptyText` is
    // not — a condition whose triage verdict can only ever be "working as
    // designed" is a counted outcome sitting on the wrong channel.
    case .emptyText, .escapeRecoveryExpired: return true
    // Listed exhaustively rather than with a `default`, so a NEW reason is a
    // compile error here and someone has to decide its channel on purpose
    // instead of inheriting silence.
    // #2087 `malformedEscapeMarker` ALERTS, deliberately. By the principle
    // above it is unambiguously OUR defect: we wrote that marker durably
    // ourselves, so a version we do not recognise, an id that does not match its
    // filename, or bytes that will not decode means our write path or format is
    // broken — never a user's environment. It should sit at ~0, and its cost when
    // non-zero is silently discarding dictations users chose to keep.
    case .keyMissing, .keyReadFailed, .reconstructionFailed, .emptyOrUnreadableSamples,
      .modelLoadFailed, .transcribeError, .saveFailed, .markerWriteFailed,
      .markerClearFailed, .attemptAlreadySpent, .keychainTransient,
      .malformedEscapeMarker:
      return false
    }
  }

  private func failUnrecoverable(
    reason: RecoveryTelemetryReason,
    failureClass: RecoveryFailureClass? = nil,
    diagnosis: RecoveryFailureDiagnosis? = nil,
    reconstructedSampleCount: Int? = nil
  ) -> RecoveryReplayOutcome {
    let category = Self.category(for: reason)
    // One value wins: a diagnosis supersedes a bare class, and both may be nil
    // for a DECISION-driven failure (escape verdict, empty prefix, empty text),
    // where absence is the signal rather than a gap.
    let resolvedClass = diagnosis?.failureClass ?? failureClass
    if Self.isCountedNotAlerted(reason) {
      SentryBreadcrumb.add(
        stage: "recovery",
        message: "recovery.outcome=\(reason.rawValue)",
        level: .info,
        data: ["recovery.reason": reason.rawValue])
    } else {
      // #2132: tags, never `fingerprintDetail` — tags are searchable metadata and
      // do NOT feed `handledErrorFingerprint`, so grouping is byte-identical and
      // the measured, pinned descriptors of #1525 PR C keep their history.
      var tags = ["recovery.reason": reason.rawValue]
      if let resolvedClass { tags["recovery.failure_class"] = resolvedClass.rawValue }
      if let identity = diagnosis?.sentryIdentity { tags["recovery.identity"] = identity }
      SentryBreadcrumb.captureError(
        RecoveryReplayError.failed(reason.rawValue), category: category, stage: "recovery",
        tags: tags)
    }
    let spoolSeconds = reconstructedSampleCount.map {
      Int((Double($0) / AudioConstants.sampleRate).rounded())
    }
    // #1762: the REASON, which the coordinator's outcome line cannot carry —
    // `.failed(.unrecoverable)` covers key-missing, decrypt, reconstruct,
    // model-load, throw and empty-result alike, and telling them apart on a real
    // machine is the whole point of this issue. Closed vocabulary, no id, no path.
    //
    // `failUnrecoverable` is synchronous (it is called from `guard` bodies all
    // through `replay`), so this cannot await. Ordering is still sound: the
    // coordinator's own awaited outcome line lands after `replay` returns, and
    // this reason line is enqueued strictly before that.
    let failureReason = reason.rawValue
    // #2132: the CLASS on the local line. Vendor telemetry cannot diagnose the one
    // user report in front of support; `app.log` is the artifact a user can send.
    // Bounded vocabulary only — no identifiers, no paths, no descriptions.
    let classSuffix = resolvedClass.map { " class=\($0.rawValue)" } ?? ""
    let identitySuffix = diagnosis?.sentryIdentity.map { " identity=\($0)" } ?? ""
    RecoveryLog.line("replay failed: \(failureReason)\(classSuffix)\(identitySuffix)")
    TelemetryService.shared.recoveryCompleted(
      outcome: "failed",
      reason: reason,
      failureClass: resolvedClass,
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
  /// #2132 — THE ENGINE NEVER LOOKED AT THE AUDIO, SO THE ATTEMPT IS NOT SPENT.
  ///
  /// Measured on this machine, 2026-08-01 and 2026-08-18: a replay failed in the
  /// SAME SECOND it was attempted, with no engine activity logged between
  /// `attempting replay` and `replay failed`, each preceded by two
  /// `deferred — the engine gate is held` passes. A healthy replay in the same
  /// logs takes 1-4 seconds and prints the recovered text. The outcome was
  /// `.unrecoverable`, which spends the single permitted attempt and has the
  /// coordinator DELETE the spool — so a recording was destroyed by an engine
  /// that refused instantly, never having decoded a sample.
  ///
  /// The root is upstream and is not fixed here: `ASRManager.loadModel()`
  /// RECORDS readiness (`isModelLoaded = ready`) rather than requiring it, so a
  /// load can report success while the backend is not ready and the truth
  /// arrives one call later as an instant refusal. Pinned by
  /// `loadModelSucceedsWhileBackendIsNotReady`.
  ///
  /// The line drawn here is availability versus verdict: `.notReady`,
  /// `.xpcUnreachable`, `.managerNotOwned` and `.cancelled` all mean the engine
  /// was never in a position to try, so this take deserves its attempt back.
  /// A genuine decode failure (`.transcriptionFailed`, `.parakeetTranscription`)
  /// or a model that will not load stays unrecoverable — retrying those forever
  /// would strand a spool no launch can ever redeem.
  ///
  /// Mirrors `deferForTransientKeychainFailure` exactly, which is the shipped
  /// precedent for "transient condition, give the attempt back".
  private static func engineWasNeverAvailable(_ diagnosis: RecoveryFailureDiagnosis) -> Bool {
    switch diagnosis {
    case .classified(let failureClass):
      switch failureClass {
      // Deliberately NARROW. These two mean the engine was categorically not
      // there to ask — the observed production shape, and the one
      // `loadModelSucceedsWhileBackendIsNotReady` reproduces against the real
      // manager.
      case .notReady, .managerNotOwned: return true
      // `.xpcUnreachable` ALSO never saw the audio and is arguably the same
      // class, and `camp_b_candidate=true` already marks it retryable. It is
      // deliberately NOT deferred here: a permanently dead helper would defer
      // every launch forever, and `telemetryTranscribeFailIsCampBCandidate`
      // pins its current failure semantics. Widening to it is a separate,
      // evidenced decision — not a silent side effect of this fix.
      case .xpcUnreachable, .cancelled, .transcriptionFailed, .whisperKitModelLoad,
        .parakeetModelLoad, .parakeetTranscription, .xpcTransport, .other:
        return false
      }
    // An error family we do not own says nothing about availability; it ran and
    // failed. Listed explicitly so a future reader must choose, not inherit.
    case .unrecognized: return false
    }
  }

  /// Give the attempt back and leave the spool on disk for the next launch.
  /// `reconstructedSampleCount` is REQUIRED, not optional, and that is the point:
  /// both callers reach here only after reconstruction returned a non-empty
  /// prefix, and omitting these fields would emit `audio_decrypted` ABSENT —
  /// which `recoveryCompleted`'s contract reads as "nothing came back out of the
  /// spool" (audio-recovery-internals.md FACT: recovery-telemetry-fields). That
  /// is the exact inverse of what happened: the audio reconstructed perfectly and
  /// the ENGINE was missing. Codex review caught this on the first pass.
  private func deferForUnavailableEngine(
    spoolStore: RecoverySpoolStore, id: String, reason: RecoveryTelemetryReason,
    diagnosis: RecoveryFailureDiagnosis, reconstructedSampleCount: Int
  ) -> RecoveryReplayOutcome {
    let spoolSeconds = Int(
      (Double(reconstructedSampleCount) / AudioConstants.sampleRate).rounded())
    RecoveryLog.line(
      "replay deferred: \(reason.rawValue) class=\(diagnosis.failureClass.rawValue) "
        + "— the engine was never available, the attempt is NOT spent")
    do {
      try spoolStore.deleteAttemptMarker(for: id)
      TelemetryService.shared.recoveryCompleted(
        outcome: "deferred", reason: reason, failureClass: diagnosis.failureClass,
        // Same facts the failure path emitted for this take. `camp_b_candidate`
        // is if anything MORE true here: good audio, and a retry is now real
        // rather than hypothetical because the attempt was given back.
        audioDecrypted: true, campBCandidate: true, spoolSeconds: spoolSeconds)
      return .deferred
    } catch {
      TelemetryService.shared.recoveryCompleted(outcome: "deferred", reason: .markerClearFailed)
      return .deferredMarkerClearFailed
    }
  }

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
  /// Which ASR seam caught the error. Selects the residual identity policy, so
  /// the choice is made by the compiler rather than by a comment: Core already
  /// owns DIFFERENT policies per seam and #2132 rev 3 nearly overrode them.
  private enum RecoveryFailureOperation {
    case modelLoad
    case transcription
  }

  /// One caught error, one derivation. Either we recognised the family or we
  /// kept its Sentry identity — never both, never neither, and never two
  /// helpers disagreeing about the same throw.
  private enum RecoveryFailureDiagnosis {
    case classified(RecoveryFailureClass)
    case unrecognized(sentryIdentity: String)

    var failureClass: RecoveryFailureClass {
      switch self {
      case .classified(let failureClass): return failureClass
      case .unrecognized: return .other
      }
    }
    var sentryIdentity: String? {
      switch self {
      case .classified: return nil
      case .unrecognized(let identity): return identity
      }
    }
  }

  /// #2132: replaces the old `classify`, which lived in the wrong module to see
  /// four of the families it needed and so returned `.other` for 100% of genuine
  /// failures. Recognition moved to `EnviousWisprASR.recoveryFailureClass(for:)`;
  /// an unrecognised error keeps its own identity through the boundary
  /// normalizer FOR ITS SEAM.
  private static func diagnose(
    _ error: any Error, operation: RecoveryFailureOperation
  ) -> RecoveryFailureDiagnosis {
    if let known = recoveryFailureClass(for: error) { return .classified(known) }
    let normalized: any Error & StableSentryErrorIdentity
    switch operation {
    case .modelLoad:
      normalized = SentryCaptureBoundaryError.normalizingModelLoadFailure(error)
    case .transcription:
      normalized = SentryCaptureBoundaryError.normalizingTranscriptionFailure(error)
    }
    return .unrecognized(sentryIdentity: normalized.sentryFingerprintDescriptor)
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
