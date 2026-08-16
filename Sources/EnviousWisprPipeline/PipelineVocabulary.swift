import EnviousWisprAudio
import EnviousWisprCore
import Foundation

// Pipeline vocabulary shared across the recording driver and its consumers:
// the event input (`PipelineEvent`), the UI output (`OverlayIntent`), the
// interruption message constants, and the heart-path telemetry-target protocol.
// The `DictationPipeline` driver protocol that once lived here was deleted in
// PR-9 of #827 — `KernelDictationDriver` is the single concrete driver and the
// App consumes it directly. `KernelOwnershipFreezeTests` keeps it deleted.

// #1558 (heartpath E1): `InterruptionMessages` — the former single authority
// for interruption copy — was deleted. The driver now stamps a typed
// `TerminalNoticeReason` (`.deviceRemoved` / `.engineLost` / `.unknownInterruption`)
// and `DictationNarrator` in AppKit authors the sentence.

/// #1408 (grounded review A1): what a COMPLETED take discloses about the
/// interruption that cut it short. Derived from the stamped
/// `EngineInterruptionCause` at the planner call sites; carried as a typed
/// value instead of a Bool so a non-disconnect salvage can no longer paste
/// potentially truncated text with no notice at all.
///
/// nil (no value) = a normal completion, nothing to disclose. The two cases
/// split on the ONLY evidence axis the pipeline has: was the input device
/// verified removed (`isDeviceLoss`), or did capture die some other way with
/// the microphone, as far as we know, still attached. Completed-warning copy is
/// authored only by `DictationNarrator` in AppKit; the factory forwards typed
/// `RecordingWarningReason` facts (#1567, heartpath E3).
public enum CompletionInterruptionDisclosure: Equatable, Sendable {
  /// Core Audio confirmed the input device went away mid-recording.
  case deviceRemoved
  /// Capture was interrupted by anything else: engine lost, capture session
  /// lost. No claim about the microphone is allowed.
  case otherInterruption

  /// nil cause → nil disclosure (normal completion). Every stamped cause on a
  /// COMPLETED take is a disclosure: the take survived an interruption, so the
  /// pasted text may be missing its tail.
  public init?(cause: EngineInterruptionCause?) {
    guard let cause else { return nil }
    self = cause.isDeviceLoss ? .deviceRemoved : .otherInterruption
  }
}

/// #1567 (heartpath E3): a typed fact explaining a post-completion or advisory
/// warning rendered through `OverlayIntent.warning`. The engine/coordinator
/// emits this; `DictationNarrator` in AppKit authors the user-facing words.
/// Lives in Pipeline because `.interruptedTail` carries a
/// `CompletionInterruptionDisclosure` (a Pipeline type) and `OverlayIntent` —
/// its only consumer — is also Pipeline.
public enum RecordingWarningReason: Equatable, Sendable {
  /// The SELECTED ASR engine isn't downloaded yet. Carries its display name.
  case modelNotDownloaded(engineLabel: String)
  /// AI polish failed; the raw transcript was pasted instead.
  case polishFailed
  /// The dictation was pasted but the history write threw. Carries the reason.
  case historySaveFailed(reason: String)
  /// The degraded-lead retry recovered this take by trimming a poisoned opening.
  case salvagedBeginning
  /// Capture died mid-recording; the pasted text is what survived. `disclosure`
  /// picks the sentence family (verified device removal vs neutral);
  /// `alsoTrimmedLead` is true when the take ALSO lost its opening (#1408/#1434).
  case interruptedTail(disclosure: CompletionInterruptionDisclosure, alsoTrimmedLead: Bool)
}

/// Events the recording driver handles.
public enum PipelineEvent: Sendable {
  case preWarm
  /// Toggle recording. Carries the per-recording configuration snapshot; pipelines
  /// consume the config on start transitions and ignore it on stop transitions.
  /// Settings mutated mid-recording apply to the next recording's snapshot.
  case toggleRecording(DictationSessionConfig)
  case requestStop
  case cancelRecording
  case reset
}

/// What the overlay should display — decoupled from internal pipeline state.
public enum OverlayIntent: Equatable, Sendable {
  case hidden
  case recording(audioLevel: Float)
  /// #1564 (heartpath E2): carries a TYPED `ProcessingPhase`; `DictationNarrator`
  /// in AppKit authors the "Transcribing..." / "Polishing..." / max-duration words.
  case processing(phase: ProcessingPhase)
  /// Transient notice shown when paste fell back to clipboard-only (Tier 3).
  /// Auto-dismissed by the overlay panel after a short delay.
  case clipboardFallback
  /// Educational notice shown once-per-session when paste cascade falls back
  /// to clipboard because Accessibility permission is denied. Includes an
  /// inline Grant button. Auto-dismissed after about 6 seconds.
  case accessibilityToast
  /// Transient warning notice for degraded-but-delivered results (e.g. polish failed).
  /// #1567 (heartpath E3): carries a TYPED `RecordingWarningReason`;
  /// `DictationNarrator` in AppKit authors the sentence. Orange icon,
  /// auto-dismissed by the overlay panel after 2.5 seconds.
  case warning(reason: RecordingWarningReason)
  /// Transient error notice for a terminal capture / transcription failure.
  /// #1558: carries a TYPED reason; `DictationNarrator` authors the
  /// sentence. Auto-dismissed by the overlay panel after 3 seconds.
  case error(reason: TerminalNoticeReason)
  /// #1891 (epic #1876 Phase 2b). A user-setup advisory: the microphone
  /// delivered nothing usable, so there is no text — and that is NOT our
  /// software failing. Deliberately not `.error`, which carries a red
  /// `xmark.circle.fill`, a 3-second dismissal too short to read this
  /// sentence, a main-window "Error" heading with a Try Again button, a red
  /// menu-bar state and a VoiceOver "Error: " prefix. Every one of those
  /// contradicts the fact and sends the user to retry something that cannot
  /// work. `DictationNarrator` authors the sentence; the panel renders it
  /// multiline with a content-driven height and a dwell long enough to read.
  case advisory(reason: TerminalAdvisoryReason)
  /// Transient interruption notice shown when the recording was cut short
  /// (device removed, or engine lost with the mic still attached). #1558:
  /// carries a TYPED reason. Distress lips (red pulse), auto-dismissed after 2 seconds.
  case interruption(reason: TerminalNoticeReason)
  /// Passive language-lock discoverability chip surfaced post-dictation when the
  /// detector observed N consecutive high-confidence accepts of the same non-English
  /// language. Renders State A (strikes 1+2: Lock + Dismiss) or State B (strike 3:
  /// Dismiss only with Settings copy). Auto-dismissed after 6 seconds; pauses on hover.
  case passiveChip(payload: LanguageChipPayload)
  /// Cold-boot warm-up notice (#879). Shown when the user presses while the
  /// active engine is not yet ready (fresh install, or first launch after a
  /// macOS update wiped the compiled-model cache). Replaces the bare
  /// "Preparing dictation…" wall: an honest, plain-English "getting ready"
  /// pill. `engineLabel` is the active engine's display name, shown as a
  /// secondary line. Auto-dismissed after about 2 seconds.
  case cachingModel(engineLabel: String)
  /// Cold-boot "ready" announcement (#879). Fired when a warm-up that the user
  /// raced (saw a `.cachingModel` pill for) finishes, so they know to press
  /// again. Auto-dismissed after about 1.5 seconds. Never fired at launch when
  /// no cold press preceded it.
  case engineReady
  /// Crash-recovery hold notice (#1063 PR2). Shown when the user presses to
  /// record while the one leftover recording from a prior abnormal exit is
  /// backfilling behind the shared engine — exactly the cold-engine
  /// `.cachingModel` shape, plus a Discard affordance for "I don't want to
  /// wait." No session is minted. Auto-dismissed after a few seconds; re-shown
  /// on each blocked press.
  case recoveringLastRecording
  /// Crash-recovery SUCCESS notice (#1464). A standalone, launch-visible green
  /// "recovered your last recording" pill posted after a leftover recording lands
  /// in History — the `.recovered` path was silent before. A DEDICATED case (not
  /// `.warning`, which shows an orange triangle + a "Warning" announcement, and not
  /// `flashRecordingNotice`, which no-ops without a live recording panel):
  /// `DictationNarrator` authors the copy and the panel renders it with the green
  /// ready/success presentation. No associated value; auto-dismissed by the panel.
  case recoverySucceeded
  /// Bluetooth cold-start education card (#1480). Shown once per launch when the
  /// configured input is a Bluetooth microphone and dictation is idle, sitting in
  /// the same top-middle slot as the recording pill. Unlike every other intent it
  /// has NO auto-dismiss: it persists until the user starts recording (which
  /// supersedes it via the single-slot dedup), taps "Got it" / close / "Adjust
  /// settings", the input changes away from Bluetooth, or the tips setting is
  /// turned off. Its decision + lifecycle are owned by `BluetoothAwarenessPresenter`.
  case bluetoothAwareness
  /// The Escape Recovery pill (#2087) — the sixteenth case. Offers to paste a
  /// dictation the user cancelled with the cancel shortcut while the feature is
  /// on. One sentence, one action, 3 seconds, and it NEVER blocks: no focus
  /// steal, no modal, no required dismissal. A user who did not mean to cancel
  /// is by definition not watching, so a prompt demanding an answer is the
  /// wrong shape; History is the unhurried second door for 24 hours.
  ///
  /// Carries the transcript's **id, never its text**. The pill re-reads by id
  /// when Paste is pressed, so a row deleted or expired inside the 3-second
  /// dwell resolves to nothing and no-ops, instead of pasting from a stale
  /// in-memory copy the store no longer agrees with.
  ///
  /// Shown only AFTER the row is durably saved (#1897): an offer to restore
  /// something that failed to save is a lie the user cannot detect.
  ///
  /// Sits beside the five existing post-dictation intents rather than reusing
  /// `flashRecordingNotice`, whose `gotchas-audio.md`
  /// RULE: in-panel-notice-not-new-overlay-intent scopes to *during* recording.
  /// This fires after the session concluded.
  case escapeRecovery(transcriptID: UUID)
}

/// How an Escape Recovery attempt ended (#2087). A CLOSED set, and `Sendable`, so
/// it can cross into the planner's value-only plan while the paste target cannot.
///
/// Distinguished rather than collapsed into success/failure because the four
/// non-saved endings are not one thing: `abandoned` is a choice the user made,
/// `empty` is a recording with no speech in it, and only `transcriptionFailed`
/// and `saveFailed` are faults of ours. A boolean would report all four as
/// failures and make the feature look broken to whoever reads the data.
public enum EscapeRecoveryTerminalOutcome: String, Equatable, Sendable, CaseIterable {
  /// Text was durably written. The ONLY outcome that may present a pill, because
  /// the pill is an offer to restore something that exists. (Chunk 9 owns where
  /// the row lives and how long it lasts.)
  case saved
  /// ASR returned nothing. There is no text to keep, and nothing to apologise
  /// for — the user cancelled a recording that had no speech in it.
  case empty
  /// Transcription failed outright. Distinct from `empty`: something broke, and
  /// conflating them would hide a real failure inside an ordinary one.
  case transcriptionFailed
  /// Text existed but the durable write failed. No pill, deliberately: offering
  /// to restore a row that was never saved is a promise the app cannot keep.
  case saveFailed
  /// The user pressed the cancel shortcut a second time and discarded the
  /// output. Not a failure — a choice, and it must never read as one in the data.
  case abandoned
}

/// Commit this session's spool to Escape Recovery, returning whether it worked
/// (#2087).
///
/// Dependency injection for STORAGE, not a second completion route. The kernel
/// already receives closures for processing, storage and delivery; this is the
/// same shape, and it exists because kernel construction had no way to write a
/// crash-provenance marker at all.
///
/// **`false` means fail closed**, and the caller's fallback is today's ordinary
/// destructive cancel — so a failure here costs the user exactly what pressing
/// cancel already costs them, and never leaves a spool that a later launch would
/// replay into permanent History.
///
/// Called BEFORE the disposition changes and before the stop tail is entered: the
/// marker must be durable before anything downstream can start behaving as though
/// the take is being kept.
public typealias PrepareEscapeRecovery = @MainActor (
  _ recoverySessionID: String, _ triggeredAt: Date, _ takeID: String?
) -> Bool

/// What a finalizing session IS, for the run that is finishing (#2087).
///
/// **Kernel-owned and session-scoped.** Set once when the exit arm decides, read
/// by storage, delivery, terminal routing and telemetry, and reset to `.ordinary`
/// in `resetSessionState()`.
///
/// This is one authority rather than a boolean inspected at delivery, because
/// `runFinalizing` orders the work **process → store → deliver → conclude**.
/// Storage runs BEFORE delivery, so a flag consulted at delivery arrives after
/// the row has already been written into ordinary History instead of `pending/`.
/// A delivery-only signal cannot express this fact early enough to be correct.
///
/// `triggeredAt` is the moment the user pressed the cancel shortcut, captured at
/// the exit and carried forward, NOT the moment finalization happened. The 24-hour
/// clock the user was promised starts when they hit Escape; a long transcription
/// must not silently spend part of their recovery window.
///
/// Deliberately INTERNAL to Pipeline. AppKit never needs the disposition, only
/// the narrow capability "is an escape recovery transcribing right now", exposed
/// as `KernelDictationDriver.isEscapeRecoveryTranscribing`. Publishing the enum
/// would widen the public surface for no consumer.
enum FinalizationDisposition: Equatable, Sendable {
  /// Every dictation that is not an escape recovery. The default.
  case ordinary
  /// The user cancelled with the shortcut while Escape Recovery was on: run the
  /// ordinary pipeline, but hold the text instead of pasting it.
  case escapeRecovery(triggeredAt: Date)
  /// The user pressed the shortcut a SECOND time during the recovery, asking to
  /// discard the result. The session stays busy until the decode returns, because
  /// adapter cancellation invalidates the generation without interrupting the
  /// decode — starting a new recording on top of one that is still running would
  /// recreate the two-decodes-one-engine hazard the toggle never disclosed.
  /// Abandonment discards the OUTPUT; it cannot shorten the WAIT.
  case abandonedEscapeRecovery(triggeredAt: Date)
}

/// Typed cancellation PROVENANCE for a `.cancelled` terminal: who asked —
/// the user, or the system/a fault. Under the #1755 discard doctrine both
/// origins delete the recovery spool; the distinction survives for
/// diagnostics and copy, not as a retain/delete fork.
public enum RecordingCancelOrigin: Equatable, Sendable {
  case user(UserCancelTrigger)
  case systemOrFault
}

/// WHICH control the user reached for (#2087).
///
/// The distinction exists because the two are not equally unambiguous. A click
/// on a button labelled Cancel says exactly one thing. A press of the cancel
/// shortcut — Escape by default — is also how people dismiss popovers, leave
/// fields and back out of menus, so it collides with dictation by accident.
/// Escape Recovery is therefore offered for `.shortcut` only; `.cancelButton`
/// keeps discarding immediately.
///
/// Carried as an associated value on `.user` rather than as a sibling enum so
/// that `.systemOrFault` cannot be paired with a user trigger — the invalid
/// combination is unrepresentable instead of merely undocumented. Consumers
/// that do not care may match `.user(_)`; today exactly one behavioural site
/// switches on the origin at all (`RecoveryCoordinator.shouldDeleteOnLiveEnding`).
public enum UserCancelTrigger: Equatable, Sendable {
  /// The configured cancel shortcut. Escape by default, and user-rebindable —
  /// which is why copy says "your cancel shortcut", never a hard-coded key.
  case shortcut
  /// The explicit Cancel button in the main window.
  case cancelButton
}

/// The narrow PUBLIC projection of a recording's terminal `RecordingOutcome` that
/// the crash-recovery cleanup signal needs (#1464). The internal `RecordingOutcome`
/// (and its `DiscardReason` / `NoSpeechSource` payloads) stays inside Pipeline;
/// `KernelDictationDriver` maps the already-floored outcome into this before it
/// crosses into AppKit, where `RecoveryCoordinator` applies the SOLE
/// delete-versus-retain predicate.
///
/// #1755 (founder Gate 2 2026-07-23): EVERY represented non-saved live ending
/// requests best-effort deletion — an ending fired means the app was alive, the
/// user witnessed the outcome, and the one in-session rescue already ran.
/// `.asrRetryExhausted` stays a distinct case for typed projection/diagnostic
/// clarity even though it now agrees with `.failed` on deletion. Launch replay
/// serves only the no-ending app-gone orphan (which never projects here).
///
/// `.completed` is not representable here — a durable save has its own cleanup
/// callback (`handleDurableSave`).
public enum RecordingRecoveryEnding: Equatable, Sendable {
  case discarded
  case noSpeech
  case failed
  /// #1707 Phase 2: a `.failed` session that spent and exhausted its one
  /// Phase-2 retry over the exact same already-captured audio. Distinct from
  /// plain `.failed` for diagnostics; both delete under #1755.
  case asrRetryExhausted
  case audioInterrupted
  case asrInterrupted
  case noTransport
  case cancelled(RecordingCancelOrigin)
  /// #1920: audio was arriving, the engine ran clean, and it produced no words.
  /// Kept distinct from `.noSpeech` because it asserts nothing about whether
  /// speech occurred. Deletes like every other concluded live ending (#1755) —
  /// `RecoveryCoordinator.shouldDeleteOnLiveEnding` is exhaustive, so that
  /// decision is made explicitly there rather than inherited.
  case asrEmptyDespiteAudio
}

/// Issue #285 — heart-path telemetry callbacks that the former root state routes to
/// whichever pipeline is currently recording. The underlying `AudioCapture*`
/// callback properties are single-owner on the shared capture instance, so
/// per-pipeline wiring would let the second-initialized pipeline steal them.
@MainActor
public protocol HeartPathTelemetryTarget: AnyObject {
  func handleCaptureStall(_ ctx: CaptureStallContext)

  /// #1578: the zero-signal discriminator refused to fire capture-stall
  /// recovery, and this is WHY. Observation only — unlike `handleCaptureStall`,
  /// nothing on this path may move the recording state machine.
  func handleZeroSignalRefusal(_ context: ZeroSignalRefusalContext)
}
