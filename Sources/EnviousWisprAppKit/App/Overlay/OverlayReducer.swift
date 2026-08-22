import CoreGraphics
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

// The sole authority for WHAT occupies the overlay slot (#2292, chunk C2).
//
// Deliberately free of AppKit. It decides; it never draws, never touches a
// window, and never schedules anything. That is what makes the arbitration
// rules — which are today spread across a shared `currentIntent` slot, an
// `importStatusOwnsCurrentSlot` computed property, a Bluetooth `isPresented`
// flag and a passive-chip generation counter — assertable in a plain unit test.

/// Everything that can ask for the overlay slot, in one union.
///
/// Five producers reach the overlay today and each arrived through its own
/// entry point on the panel. Naming them as one type is what makes
/// "which of these outranks which" a question with a single written answer.
enum OverlayEvent: Equatable {
  /// The dictation pipeline. Outranks every feature.
  case pipeline(OverlayIntent)
  /// A feature that is not the pipeline.
  case featureRequest(OverlayRequest)
  /// A notice that morphs a LIVE recording pill rather than replacing it.
  case inPanelNotice(RecordingNoticeReason, dismissAfter: Double?)
  /// Hands-free lock engaged or released. `updateLockState` today; it
  /// morphs the live recording pill and does nothing otherwise. The first model
  /// carried `isLocked` on the presentation with no event able to change it.
  case lockStateChanged(Bool)
  /// The user pressed something on the presentation identified by this id.
  case action(PresentationID, OverlayAction)
  /// Hover began or ended on the presentation identified by this id.
  case hoverChanged(PresentationID, Bool)
  /// The expiry armed for this id fired.
  case expiryFired(PresentationID)
}

/// What the director should do to the single armed expiry.
///
/// **Three states, because two cannot express the difference between "leave the
/// timer alone" and "cancel it".** An optional would collapse them:
/// reading `nil` as cancel makes every stale or no-op
/// event kill a live timer, and reading it as unchanged leaves a hovered pill's
/// timer running so hover-pause does nothing at all. Cloud review named it, and
/// it is exactly the hazard I had flagged as my own least-confident change.
enum OverlayExpiryCommand: Equatable {
  /// Leave whatever is armed alone. The correct answer for every dropped stale
  /// event, which is most of them.
  case unchanged
  /// Disarm and arm nothing: the presentation went away, or hover paused it.
  case cancel
  case arm(id: PresentationID, seconds: Double)
}

/// What the director must do to make reality match the reducer's decision.
///
/// A PLAN, not a mutation: the reducer returns it and the director performs it.
/// Keeping the decision and the effect apart is what lets a test drive a whole
/// dictation's worth of events and assert on the resulting sequence without a
/// window server, a run loop, or a clock.
struct OverlayPlan: Equatable {
  /// What should occupy the slot now. `nil` means the slot is empty.
  let presentation: OverlayPresentation?
  /// True when the host must apply `presentation`.
  ///
  /// False leaves the window's content unchanged; it does NOT mean the plan is
  /// empty. Expiry commands, delivered actions and effects all remain operative
  /// on a `didChange == false` plan — a hover cancels a timer without touching
  /// a pixel. The first version's comment said "the reducer deliberately ignored
  /// this event", which stopped being true the moment hover and action plans
  /// began carrying commands.
  let didChange: Bool
  /// What to do with the single armed expiry.
  let expiryCommand: OverlayExpiryCommand
  /// An action the director should forward to the feature that owns it. The
  /// director holds exactly ONE active binding, so this is at most one.
  let deliverAction: OverlayAction?
  /// Side effects for feature owners that keep their own state. Usually empty.
  let effects: [OverlayEffect]

  static func == (a: OverlayPlan, b: OverlayPlan) -> Bool {
    a.presentation == b.presentation && a.didChange == b.didChange
      && a.expiryCommand == b.expiryCommand && a.deliverAction == b.deliverAction
      && a.effects == b.effects
  }

  static let noChange = OverlayPlan(presentation: nil, didChange: false)

  init(
    presentation: OverlayPresentation?, didChange: Bool,
    expiryCommand: OverlayExpiryCommand = .unchanged,
    deliverAction: OverlayAction? = nil,
    effects: [OverlayEffect] = []
  ) {
    self.presentation = presentation
    self.didChange = didChange
    self.expiryCommand = expiryCommand
    self.deliverAction = deliverAction
    self.effects = effects
  }
}

/// The reducer's own memory. Small on purpose: if this grows a per-kind field
/// collection it has become the thing it replaced.
struct OverlayState: Equatable {
  /// What occupies the slot, or nil.
  private(set) var current: OverlayPresentation?
  /// The last pipeline intent seen. A feature may take the slot only while this
  /// is `.hidden`, which is the arbitration rule the shipped code spells out
  /// separately at every feature.
  private(set) var pipelineIntent: OverlayIntent = .hidden
  /// True while the pointer is inside the current presentation. A hovered
  /// presentation does not expire.
  private(set) var isHovered = false
  /// Hands-free lock, which OUTLIVES any one presentation.
  ///
  /// Shipped `updateLockState` sets the shared `OverlayLockState`
  /// unconditionally with no recording guard, and `show(...)` takes an
  /// `isRecordingLocked:` argument so a pill is born locked rather than
  /// rendering unlocked and morphing a frame later. The first model held
  /// `isLocked` only inside the presentation and always started it `false`,
  /// which loses both: a lock set between dictations was dropped, and a locked
  /// start would have flashed unlocked.
  private(set) var isLocked = false

  fileprivate mutating func set(
    current: OverlayPresentation?, pipelineIntent: OverlayIntent? = nil, isHovered: Bool? = nil,
    isLocked: Bool? = nil
  ) {
    self.current = current
    if let pipelineIntent { self.pipelineIntent = pipelineIntent }
    if let isHovered { self.isHovered = isHovered }
    if let isLocked { self.isLocked = isLocked }
  }
}

struct OverlayReducer {
  private(set) var state = OverlayState()

  /// Injected so tests can assert on identity. Production passes the default.
  private let makeID: () -> PresentationID

  init(makeID: @escaping () -> PresentationID = { PresentationID() }) {
    self.makeID = makeID
  }

  mutating func reduce(_ event: OverlayEvent) -> OverlayPlan {
    switch event {
    case .pipeline(let intent):
      return reducePipeline(intent)
    case .featureRequest(let request):
      return reduceFeature(request)
    case .inPanelNotice(let reason, let dismissAfter):
      return reduceInPanelNotice(reason, dismissAfter: dismissAfter)
    case .lockStateChanged(let locked):
      return reduceLockState(locked)
    case .action(let id, let action):
      return reduceAction(id, action)
    case .hoverChanged(let id, let hovering):
      return reduceHover(id, hovering)
    case .expiryFired(let id):
      return reduceExpiry(id)
    }
  }

  // MARK: - Pipeline

  private mutating func reducePipeline(_ intent: OverlayIntent) -> OverlayPlan {
    // A live recording pill must keep its identity across audio-level updates,
    // or every metering tick would look like a new presentation and re-arm
    // expiry, re-measure the frame and reset the in-panel notice.
    if case .recording(let level) = intent,
      let current = state.current,
      case .recording(_, let isLocked, let notice) = current.content
    {
      let updated = OverlayPresentation(
        id: current.id,
        content: .recording(audioLevel: level, isLocked: isLocked, notice: notice),
        expiry: current.expiry,
        requestedWidth: current.requestedWidth,
        reservesFixedHeight: current.reservesFixedHeight)
      state.set(current: updated, pipelineIntent: intent)
      return OverlayPlan(presentation: updated, didChange: true)
    }

    guard var presentation = Self.presentation(for: intent, id: makeID()) else {
      // `.hidden`, and anything with no presentation, empties the slot.
      // `didChange` is read BEFORE the mutation: emptying an already-empty slot
      // is a genuine no-op and must not make the host re-apply nothing.
      let wasOccupied = state.current != nil
      let wasRecording = Self.isRecording(state.current)
      state.set(current: nil, pipelineIntent: intent, isHovered: false)
      return OverlayPlan(
        presentation: nil, didChange: wasOccupied,
        expiryCommand: wasOccupied ? .cancel : .unchanged,
        effects: wasRecording ? [.recordingIntentChanged(false)] : [])
    }

    // Born locked if the lock is on. `show(...isRecordingLocked:)`
    // exists precisely so this is applied in the SAME transaction rather than
    // rendered unlocked and morphed a frame later.
    if case .recording(let level, _, let notice) = presentation.content, state.isLocked {
      presentation = OverlayPresentation(
        id: presentation.id,
        content: .recording(audioLevel: level, isLocked: true, notice: notice),
        expiry: presentation.expiry, requestedWidth: presentation.requestedWidth,
        reservesFixedHeight: presentation.reservesFixedHeight)
    }
    let wasRecording = Self.isRecording(state.current)
    let isRecording = Self.isRecording(presentation)
    state.set(current: presentation, pipelineIntent: intent, isHovered: false)
    return OverlayPlan(
      presentation: presentation, didChange: true,
      expiryCommand: Self.command(for: presentation),
      effects: wasRecording == isRecording ? [] : [.recordingIntentChanged(isRecording)])
  }

  // MARK: - Features

  private mutating func reduceFeature(_ request: OverlayRequest) -> OverlayPlan {
    // THE arbitration rule, stated once: a feature may occupy the slot only
    // while the pipeline is idle. Today this is re-derived at each feature
    // (`importStatusOwnsCurrentSlot`, Bluetooth's `isPresented`, the chip's
    // generation), and nothing holds those three to the same answer.
    guard state.pipelineIntent == .hidden else { return .noChange }

    let presentation = Self.presentation(for: request, id: makeID())
    state.set(current: presentation, isHovered: false)
    return OverlayPlan(
      presentation: presentation, didChange: true, expiryCommand: Self.command(for: presentation))
  }

  private static func isRecording(_ p: OverlayPresentation?) -> Bool {
    if case .recording? = p?.content { return true }
    return false
  }

  /// Hands-free lock.
  ///
  /// **The flag is recorded whether or not a pill is showing**, because shipped
  /// `updateLockState` has NO recording guard — it sets the
  /// shared `OverlayLockState` unconditionally, and the next pill is then born
  /// locked through `show(...isRecordingLocked:)`. An earlier version of this
  /// comment claimed the shipped method guards on recording; it does not, and
  /// asserting a mechanism the code lacks is worse than saying nothing.
  /// Only the MORPH is conditional.
  private mutating func reduceLockState(_ locked: Bool) -> OverlayPlan {
    guard state.isLocked != locked else { return .noChange }
    guard let current = state.current,
      case .recording(let level, _, let notice) = current.content
    else {
      state.set(current: state.current, isLocked: locked)
      return .noChange
    }

    let updated = OverlayPresentation(
      id: current.id,
      content: .recording(audioLevel: level, isLocked: locked, notice: notice),
      expiry: current.expiry, requestedWidth: current.requestedWidth,
      reservesFixedHeight: current.reservesFixedHeight)
    state.set(current: updated, isLocked: locked)
    return OverlayPlan(presentation: updated, didChange: true)
  }

  // MARK: - In-panel notice

  private mutating func reduceInPanelNotice(
    _ reason: RecordingNoticeReason, dismissAfter: Double?
  ) -> OverlayPlan {
    // It morphs a LIVE recording pill and does nothing otherwise. The shipped
    // parallel `OverlayNoticeState` channel exists only because a replacement
    // would have torn the panel down; with the panel retained, this is a field
    // on the presentation that owns it.
    guard let current = state.current,
      case .recording(let level, let isLocked, _) = current.content
    else { return .noChange }

    let updated = OverlayPresentation(
      id: current.id,
      content: .recording(
        audioLevel: level, isLocked: isLocked,
        notice: InPanelNotice(reason: reason, dismissAfter: dismissAfter)),
      expiry: current.expiry,
      requestedWidth: current.requestedWidth,
      reservesFixedHeight: current.reservesFixedHeight)
    state.set(current: updated)
    return OverlayPlan(presentation: updated, didChange: true)
  }

  // MARK: - Identity-gated events

  /// An action, a hover or an expiry that names an id which is no longer
  /// current is STALE and is dropped. One rule, one place — this is the whole
  /// job `PresentationID` was introduced for, and the reason it must never be
  /// compared for order: the question is only ever "is this still the one".
  private func isCurrent(_ id: PresentationID) -> Bool { state.current?.id == id }

  private mutating func reduceAction(_ id: PresentationID, _ action: OverlayAction) -> OverlayPlan {
    guard isCurrent(id) else { return .noChange }
    return OverlayPlan(presentation: state.current, didChange: false, deliverAction: action)
  }

  private mutating func reduceHover(_ id: PresentationID, _ hovering: Bool) -> OverlayPlan {
    guard isCurrent(id), let current = state.current else { return .noChange }
    // **Only a hover-PAUSABLE presentation records hover at all.** The first
    // version set `isHovered` unconditionally and only then checked
    // `pausesOnHover`, so a stray hover over an ordinary notice suppressed its
    // expiry permanently — it would sit on screen until something replaced it.
    // Cloud review found it; no test reached it because every hover case in the
    // suite used a pausable kind.
    guard case .after(let seconds, true) = current.expiry, state.isHovered != hovering else {
      return .noChange
    }
    state.set(current: current, isHovered: hovering)
    // Leaving re-arms from FULL rather than resuming the remainder, matching
    // both shipped hover-pausing pills (`EscapeRecoveryPillView.swift`,
    // `LanguageChipView`).
    // Hover-enter CANCELS the armed timer; leaving re-arms from FULL rather than
    // resuming the remainder, matching both shipped hover-pausing pills
    // (`EscapeRecoveryPillView.swift`, `LanguageChipView`).
    return hovering
      ? OverlayPlan(presentation: current, didChange: false, expiryCommand: .cancel)
      : OverlayPlan(
        presentation: current, didChange: false,
        expiryCommand: .arm(id: current.id, seconds: seconds))
  }

  private mutating func reduceExpiry(_ id: PresentationID) -> OverlayPlan {
    guard isCurrent(id), let current = state.current else { return .noChange }
    // A `.untilReplaced` presentation has no timer, so an expiry naming it is
    // by definition stale — a timer armed for a PREVIOUS occupant that happened
    // to reuse this id, or a caller bug. The first version dismissed it, which
    // would silently close the recording pill mid-dictation.
    guard case .after = current.expiry else { return .noChange }
    // A hovered presentation does not expire. Re-arming happens on hover exit.
    guard !state.isHovered else { return .noChange }
    // A feature that keeps its OWN copy of this presentation must be told, or
    // clearing the slot leaves its state stale — `currentChip` survives, and the
    // escape-recovery payload is never released. Enumerated from the panel's
    // handler fields rather than found one at a time.
    var effects: [OverlayEffect] = []
    switch current.content {
    case .languageChip(let payload):
      effects.append(.languageChipAutoDismissed(generation: payload.generation))
    case .escapeRecovery(let transcriptID):
      effects.append(.escapeRecoveryExpired(transcriptID: transcriptID))
    case .recording:
      effects.append(.recordingIntentChanged(false))
    case .notice, .bluetoothAwareness:
      break
    }
    // **The pipeline returns to idle, and the first version did not do this.**
    // Shipped `hide()` sets `currentIntent = .hidden`, so
    // once a warning or error notice auto-dismisses the pipeline is idle again
    // and features may take the slot. Without it, `pipelineIntent` stayed at
    // `.warning` forever and EVERY feature pill was blocked for the rest of the
    // session — the arbitration rule this reducer exists to state, failing open
    // in the direction nothing would ever report.
    state.set(current: nil, pipelineIntent: .hidden, isHovered: false)
    return OverlayPlan(
      presentation: nil, didChange: true, expiryCommand: .cancel, effects: effects)
  }

  // MARK: - Intent and request to presentation

  /// A new occupant always replaces the armed expiry: `.arm` when it has a
  /// dwell, `.cancel` when it is persistent. Never `.unchanged` — leaving the
  /// previous occupant's timer running is how a stale dismissal reaches a live
  /// pill, which is the whole defect `PresentationID` exists to close.
  private static func command(for p: OverlayPresentation) -> OverlayExpiryCommand {
    guard case .after(let seconds, _) = p.expiry else { return .cancel }
    return .arm(id: p.id, seconds: seconds)
  }

  /// The shipped widths and dwells, gathered.
  ///
  /// **Every value here was MEASURED at its shipped call site, and the first
  /// version of this table was not.** It was written from the design and
  /// described in the commit as "carried over", which was false: eleven of the
  /// fifteen widths and six of the dwells were wrong. Cloud review caught it by
  /// opening the panel and reading them. The sites are cited per row so the next
  /// reader can re-check rather than trust this sentence.
  private static func presentation(for intent: OverlayIntent, id: PresentationID)
    -> OverlayPresentation?
  {
    switch intent {
    case .hidden:
      return nil

    case .recording(let level):
      // that site — the NON-PREVIEW recording pill, and only it, reserves a fixed
      // 92-point interaction frame: it holds the normal 185x44, the locked
      // 120x64 and the #1060 notice expansion without resizing on every morph.
      //
      // **This is NOT universal, and the first version of this table claimed it
      // was.** With Live Preview on, that site takes a different branch —
      // `fitToContent: true`, content-sized from the first frame so it does not
      // visibly snap. Whether preview is on is a provider the DIRECTOR owns, so
      // the reducer cannot decide it here. C3 obligation, recorded rather than
      // guessed: the director supplies the preview flag and this branch gains a
      // content-sized variant.
      return OverlayPresentation(
        id: id, content: .recording(audioLevel: level, isLocked: false, notice: nil),
        expiry: .untilReplaced, requestedWidth: .fixed(185), reservesFixedHeight: 92)

    case .processing(let phase):
      // `PolishingOverlayView` pins no width and that site passes `fitToContent: true`,
      // so the `230` at that call site is DISCARDED and the real width is the
      // view's `fittingSize`. Carrying the literal would have looked right.
      return notice(
        id: id, kind: .processing, text: DictationNarrator.copy(for: phase),
        width: .measured)

    case .clipboardFallback:
      // that site via `transitionToPolishingNow`, dwell from
      // `scheduleAutoDismiss`'s own default.
      return notice(
        // Routes through the same `PolishingOverlayView` path, so also measured.
        id: id, kind: .processing, text: DictationNarrator.clipboardFallbackText, width: .measured,
        expiry: .after(seconds: 2.5))

    case .accessibilityToast:
      return notice(
        id: id, kind: .accessibilityToast, text: DictationNarrator.accessibilityToastText,
        width: .fixed(300),  // :1035
        expiry: .after(seconds: 6), isMultiline: true,  // :1039
        action: (label: "Grant", action: .grantAccessibility))

    case .warning(let reason):
      return notice(
        id: id, kind: .notification, text: DictationNarrator.copy(for: reason), width: .fixed(280),  // :1189
        expiry: .after(seconds: 2.5), severity: .warning)  // NotificationStyle 2.5

    case .error(let reason):
      return notice(
        id: id, kind: .notification, text: DictationNarrator.copy(for: reason), width: .fixed(280),  // :1189
        expiry: .after(seconds: 3), severity: .error)  // NotificationStyle 3.0

    case .advisory(let reason):
      // #1891: deliberately NOT `.error`. Multiline, and a dwell long enough
      // to read the sentence.
      return notice(
        id: id, kind: .notification, text: DictationNarrator.copy(for: reason),
        width: .fixed(360),  // advisoryWidth
        expiry: .after(seconds: 8), severity: .advisory, isMultiline: true)

    case .interruption(let reason):
      return notice(
        id: id, kind: .notification, text: DictationNarrator.copy(for: reason), width: .fixed(280),  // :1189
        expiry: .after(seconds: 2), severity: .distress)  // NotificationStyle 2.0

    case .passiveChip(let payload):
      return OverlayPresentation(
        id: id, content: .languageChip(payload: payload),
        expiry: .after(seconds: 6, pausesOnHover: true), requestedWidth: .fixed(340))  // :1721

    case .cachingModel(let engineLabel):
      return notice(
        id: id, kind: .warmingUp, text: DictationNarrator.coldStartTitle,
        secondary: DictationNarrator.coldStartSubtitle(engineLabel: engineLabel),
        width: .fixed(300),  // :641
        expiry: .after(seconds: 2))  // :642

    case .engineReady:
      return notice(
        id: id, kind: .ready, text: DictationNarrator.readyTitle, width: .fixed(240),  // :656
        expiry: .after(seconds: 1.5))  // :657

    case .recoveringLastRecording:
      return notice(
        id: id, kind: .recovery, text: DictationNarrator.recoveryTitle,
        secondary: DictationNarrator.recoverySubtitle,
        width: .fixed(320),  // :688
        // that site gives it a 6-second dwell. The first version said `.untilReplaced`,
        // which would have left the recovery pill on screen forever.
        expiry: .after(seconds: 6), isMultiline: true,
        action: (label: "Discard", action: .discardRecovery))

    case .recoverySucceeded:
      return notice(
        id: id, kind: .notification, text: DictationNarrator.recoverySucceededTitle,
        secondary: DictationNarrator.recoverySucceededSubtitle, width: .fixed(300),  // :674
        expiry: .after(seconds: 3))  // :675

    case .bluetoothAwareness:
      return OverlayPresentation(
        // that site calls `showPanel` with NO `scheduleAutoDismiss`: the card is
        // PERSISTENT until something replaces it. The first version gave it a
        // 6-second dwell, which would have made it vanish on its own.
        id: id, content: .bluetoothAwareness, expiry: .untilReplaced,
        requestedWidth: .fixed(320))

    case .escapeRecovery(let transcriptID):
      return OverlayPresentation(
        // `EscapeRecoveryPillView.dwellSeconds = 3.0`, hover-pausable. The VIEW
        // owns this dwell today because a panel-level timer cannot be paused by
        // a hover only the view sees — the two would race and the hover would
        // appear to do nothing. Once the director owns the single
        // expiry, that reason is gone and this becomes an ordinary hover-pausing
        // expiry; C4 removes the view-owned task.
        id: id, content: .escapeRecovery(transcriptID: transcriptID),
        expiry: .after(seconds: 3, pausesOnHover: true), requestedWidth: .measured)
    }
  }

  private static func presentation(for request: OverlayRequest, id: PresentationID)
    -> OverlayPresentation
  {
    switch request {
    case .importStatus(let message):
      return OverlayPresentation(
        id: id, content: .notice(NoticeModel(kind: .importStatus, text: message, isMultiline: true)),
        // `ImportStatusOverlayView` uses `.frame(maxWidth: 280)` — a BOUND, not a
        // width — under `fitToContent`, so this is measured too.
        expiry: .after(seconds: 3), requestedWidth: .measured)  // :1105, :1148
    case .bluetoothAwareness:
      return OverlayPresentation(
        id: id, content: .bluetoothAwareness, expiry: .untilReplaced,
        requestedWidth: .fixed(320))  // :1790 — persistent
    case .passiveChip(let payload):
      return OverlayPresentation(
        id: id, content: .languageChip(payload: payload),
        expiry: .after(seconds: 6, pausesOnHover: true), requestedWidth: .fixed(340))  // :1721
    case .accessibilityToast:
      return OverlayPresentation(
        id: id,
        content: .notice(
          NoticeModel(
            kind: .accessibilityToast, text: DictationNarrator.accessibilityToastText,
            isMultiline: true,
            action: (label: "Grant", action: .grantAccessibility))),
        expiry: .after(seconds: 6), requestedWidth: .fixed(300))  // :1035, :1039
    }
  }

  private static func notice(
    id: PresentationID, kind: NoticeModel.Kind, text: String, secondary: String? = nil,
    width: OverlayWidth,
    expiry: OverlayExpiry = .untilReplaced, severity: NoticeModel.Severity = .neutral,
    isMultiline: Bool = false, action: (label: String, action: OverlayAction)? = nil
  ) -> OverlayPresentation {
    OverlayPresentation(
      id: id,
      content: .notice(
        NoticeModel(
          kind: kind, text: text, secondaryText: secondary, severity: severity,
          isMultiline: isMultiline, action: action)),
      expiry: expiry, requestedWidth: width)
  }
}
