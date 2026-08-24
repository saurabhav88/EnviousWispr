import CoreGraphics
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

// The typed pill boundary (#2292 Phase 1, chunk C1). This file is the FINAL
// caller-facing surface: a request carries everything its presentation needs,
// including the callbacks for every button it draws, so a pill cannot reach the
// screen with a control bound to nobody.
//
// Chunk C1 was a semantic no-op port: `PillAction` and `PillEffect` moved here
// from `OverlayVocabulary.swift` under new names with their behavior unchanged.
// `OverlayRequest` stayed behind until C5c, which deleted it — the reducer now
// speaks one vocabulary rather than a pipeline enum and a feature enum that both
// declared `passiveChip` and `bluetoothAwareness`.

// MARK: - What the user did

/// Something the USER did to a live presentation.
///
/// Every one of these is a button the shipped pill already offers. They are
/// gathered here because the director holds **exactly one** active action
/// binding for the current presentation, rather than the eight
/// `set*Handler` closure fields the panel keeps alive for the app's lifetime
/// whether or not the pill that uses them is showing.
/// **Every case here is a button the shipped pill offers, and every case carries
/// the fact its handler needs.** Three rounds of review each found one place
/// where a bare enum case had thrown away something the feature depends on, so
/// the whole surface was then enumerated at once rather than waiting for a
/// fourth. The panel's own handler fields are the authority
/// (`05411427:Sources/EnviousWisprAppKit/App/RecordingOverlayPanel.swift`); each row below names the field it
/// replaces.
enum PillAction: Equatable, Sendable {
  /// grantHandler.
  case grantAccessibility
  /// discardRecoveryHandler.
  case discardRecovery
  /// onEscapeRecoveryPaste, which takes the `CancelUndoPayload`.
  ///
  /// **Carries the transcript id, and the first version did not.** The director
  /// holds the payload and compares this id against the one it took custody of
  /// when the pill was raised, so a press for a transcript it no longer holds
  /// forwards nothing. A bare case would have delivered "the user pressed Undo"
  /// with nothing to undo.
  case pasteEscapeRecovery(transcriptID: UUID)
  /// passiveChipLockHandler.
  case lockLanguage
  /// passiveChipDismissHandler.
  case dismissChip
  /// bluetoothAwarenessGotItHandler.
  ///
  /// **Distinct from `closeBluetoothAwareness`, and collapsing them lost real
  /// telemetry.** `BluetoothAwarenessPresenter` emits `.dismissed/.gotIt` versus
  /// `.dismissed/.closed`: acknowledging the card and closing it
  /// are different user answers and the dashboard reads them apart.
  case acknowledgeBluetoothAwareness
  /// bluetoothAwarenessCloseHandler.
  case closeBluetoothAwareness
  /// bluetoothAwarenessAdjustSettingsHandler.
  case openBluetoothSettings
}

// MARK: - What the director must tell a feature owner

/// A side effect the director must forward to a feature owner, beyond changing
/// what is on screen.
///
/// **These exist because a feature keeps state the overlay does not own, and
/// clearing only the overlay's copy leaves the feature's stale.**
/// `LanguageSuggestionPresenter.currentChip` is cleared by a
/// generation-gated call, and the escape-recovery payload is taken
/// by transcript id — neither is reachable from "the slot is now empty".
///
/// An array rather than a field per occasion: a field dedicated to expiry alone would
/// needed a sibling the moment the recording-intent observer was wired, and
/// accreting one field per occasion is how the type this migration deletes grew
/// its 33 stored properties. Usually empty; at most a couple, emitted in order.
enum PillEffect: Equatable, Sendable {
  /// passiveChipAutoDismissHandler, which takes the generation.
  case languageChipExpired(generation: UInt64)
  /// setRecordingIntentObserver. Fires when the recording pill
  /// arrives or leaves. Nothing in the first model expressed it at all.
  case recordingStateChanged(Bool)
}

// MARK: - The typed request

/// The five values a recording pill needs, travelling together.
///
/// **They travel together because splitting them made a wrong first frame
/// expressible.** The shipped panel takes the lock in the same call that shows
/// the pill and commits it before drawing; supplying it separately afterwards
/// renders unlocked and morphs a frame later, which loses hands-free lock
/// silently when a caller forgets.
@MainActor
struct RecordingPillInput {
  let audioLevel: Float
  let audioLevelProvider: () -> Float
  let recordingElapsedProvider: () -> TimeInterval?
  let isLocked: Bool

  init(
    audioLevel: Float,
    audioLevelProvider: @escaping () -> Float,
    recordingElapsedProvider: @escaping () -> TimeInterval?,
    isLocked: Bool
  ) {
    self.audioLevel = audioLevel
    self.audioLevelProvider = audioLevelProvider
    self.recordingElapsedProvider = recordingElapsedProvider
    self.isLocked = isLocked
  }
}

/// One thing to put on screen, carrying everything that presentation needs.
///
/// **Interactive cases carry their callbacks as non-optional associated values,
/// which is the entire point of the type.** The binding used to arrive through a
/// separate `actions:` parameter that defaulted to nothing, so a caller that
/// should have passed one compiled silently without it and the pill rendered a
/// button that reached nobody. Here the omission does not compile.
///
/// **Not `Equatable` and not `Sendable`**, because the interactive cases hold
/// closures and erasing them to regain equality would be inventing a comparison
/// nothing needs: no site in `Sources` or `Tests` compares a request. Requests
/// stop at the director boundary, which translates them into the equatable
/// reducer events the reducer and its tests actually assert on.
@MainActor
enum PillRequest {

  // Pipeline-owned: raised by the dictation pipeline, no user controls.
  case recording(RecordingPillInput)
  case processing(phase: ProcessingPhase)
  case clipboardFallback
  case warning(reason: RecordingWarningReason)
  case error(reason: TerminalNoticeReason)
  case advisory(reason: TerminalAdvisoryReason)
  case interruption(reason: TerminalNoticeReason)
  case cachingModel(engineLabel: String)
  case engineReady
  case recoverySucceeded
  case importStatus(message: String)

  // Feature-owned: raised by a feature that owns the buttons it draws.
  case accessibilityNotice
  case recoveryNotice(onDiscard: () -> Void)
  case languageChip(
    payload: LanguageChipPayload,
    onLock: () -> Void,
    onDismiss: () -> Void,
    onExpire: () -> Void
  )
  case bluetoothAwareness(
    onAcknowledge: () -> Void,
    onClose: () -> Void,
    onOpenSettings: () -> Void
  )
  case escapeRecovery(
    payload: CancelUndoPayload,
    onPaste: (CancelUndoPayload) -> Void
  )
}

// MARK: - What a caller gets back, and what it may change afterwards

/// Proof that a specific presentation was accepted, and the only safe way to ask
/// about it later.
///
/// A feature owner that presented a pill and then wants to dismiss "its" pill
/// must not dismiss whatever is on screen now — a successor may have replaced
/// it. The receipt names the presentation it was issued for, so
/// `dismissIfCurrent` is a no-op once the slot has moved on. `present` returns
/// nil when the request was refused, which is itself the answer to "did mine
/// get shown".
struct PillReceipt: Hashable, Sendable {
  let presentationID: PresentationID
}

/// A change to the presentation already on screen, distinct from replacing it.
///
/// Both cases are morphs of a live recording pill rather than new
/// presentations, which is why they are not `PillRequest` cases: a new request
/// would take a new identity and re-run placement.
enum PillUpdate: Equatable, Sendable {
  case recordingLock(Bool)
  case inPanelNotice(RecordingNoticeReason, dismissAfter: Double?)
}

/// Whether dismissing speaks.
///
/// **Silent is not a convenience, it is a correctness case.** Chip dismissal
/// bypasses the "Recording complete" screen-reader announcement that the hidden
/// intent otherwise posts, because nothing was recording.
enum PillDismissal: Equatable, Sendable {
  case announced
  case silent
}

/// Whether a request reached the screen.
///
/// **A receipt cannot answer this, and that is a fact about time rather than a
/// design choice** (#2292, PR #2370). `present` returns synchronously; the FIRST
/// presentation of a launch is handed to the host a run loop later, because
/// building the hosting view inside the status-item menu's dismiss animation
/// causes a re-entrant layout cycle and SIGABRT. So at the moment `present`
/// returns there is nothing truthful it can say about a host call that has not
/// happened.
///
/// The receipt still means what it always meant: the request was ADMITTED and
/// the caller OWNS that presentation. A caller that also needs to know the pill
/// was SEEN — because it is about to spend a once-per-launch allowance, or
/// record that the user was shown something — takes this instead.
enum PillPresentationResult: Equatable, Sendable {
  case presented(PillReceipt)
  case notPresented
}

// MARK: - The façade

/// The whole overlay surface, as its callers see it.
///
/// **Narrow on purpose.** Callers reach a pill through `present` and nothing
/// else: there is no generic event ingress, no way to read what is currently on
/// screen and decide from it, and no separate step that installs a handler after
/// the pill already exists.
@MainActor
protocol OverlayPresenting: AnyObject {

  /// Whether a feature-owned pill would be admitted right now.
  ///
  /// **Never use this to admit a presentation. `present(_:)` is the
  /// authoritative admission transaction** (#2292 C3), and it performs this
  /// same check inside itself, beside the state change. Asking here and then
  /// presenting gives one decision two authorities, which is the defect this
  /// phase removes — not a timing window, since both are synchronous on the
  /// MainActor.
  ///
  /// It survives for exactly one caller: Bluetooth's tips-disabled
  /// `suppressed_by_setting` metric, which counts users who would OTHERWISE
  /// have qualified and had a clear slot. That is an eligibility snapshot for a
  /// dashboard, not an admission.
  var featureSlotIsAvailable: Bool { get }

  /// Show `request`, returning its receipt, or nil when it was refused.
  @discardableResult
  func present(_ request: PillRequest) -> PillReceipt?

  /// Present, and hear exactly once whether it reached the screen.
  ///
  /// `onResult` fires exactly once per call, on every path: admission refused,
  /// host refused, a deferred presentation superseded before it rendered, or
  /// presented. **Commit anything a user would notice inside the `.presented`
  /// arm, never on the receipt alone** — a Bluetooth card that spends its
  /// once-per-launch allowance on a pill the host refused is a tip nobody sees
  /// and a telemetry row saying they did.
  @discardableResult
  func present(
    _ request: PillRequest,
    onResult: @escaping (PillPresentationResult) -> Void
  ) -> PillReceipt?

  /// Change the presentation already on screen.
  func update(_ update: PillUpdate)

  /// Dismiss whatever is on screen.
  func dismissCurrent(_ mode: PillDismissal)

  /// Dismiss only if `receipt` still names the current presentation.
  func dismissIfCurrent(_ receipt: PillReceipt)

  /// Whether `receipt` still names the current presentation.
  func isCurrent(_ receipt: PillReceipt) -> Bool
}
