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
  /// The user pressed something on the presentation identified by this id.
  case action(PresentationID, OverlayAction)
  /// Hover began or ended on the presentation identified by this id.
  case hoverChanged(PresentationID, Bool)
  /// The expiry armed for this id fired.
  case expiryFired(PresentationID)
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
  /// True when the slot's occupant CHANGED, so the host must apply new content.
  /// False means the plan is a no-op for the window — an event arrived that the
  /// reducer deliberately ignored.
  let didChange: Bool
  /// The single expiry the director should arm, replacing any previous one.
  /// `nil` means disarm and arm nothing.
  let armExpiry: (id: PresentationID, seconds: Double)?
  /// An action the director should forward to the feature that owns it. The
  /// director holds exactly ONE active binding, so this is at most one.
  let deliverAction: OverlayAction?

  static func == (a: OverlayPlan, b: OverlayPlan) -> Bool {
    a.presentation == b.presentation && a.didChange == b.didChange
      && a.armExpiry?.id == b.armExpiry?.id && a.armExpiry?.seconds == b.armExpiry?.seconds
      && a.deliverAction == b.deliverAction
  }

  static let noChange = OverlayPlan(
    presentation: nil, didChange: false, armExpiry: nil, deliverAction: nil)

  init(
    presentation: OverlayPresentation?, didChange: Bool,
    armExpiry: (id: PresentationID, seconds: Double)? = nil,
    deliverAction: OverlayAction? = nil
  ) {
    self.presentation = presentation
    self.didChange = didChange
    self.armExpiry = armExpiry
    self.deliverAction = deliverAction
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

  fileprivate mutating func set(
    current: OverlayPresentation?, pipelineIntent: OverlayIntent? = nil, isHovered: Bool? = nil
  ) {
    self.current = current
    if let pipelineIntent { self.pipelineIntent = pipelineIntent }
    if let isHovered { self.isHovered = isHovered }
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

    guard let presentation = Self.presentation(for: intent, id: makeID()) else {
      // `.hidden`, and anything with no presentation, empties the slot.
      // `didChange` is read BEFORE the mutation: emptying an already-empty slot
      // is a genuine no-op and must not make the host re-apply nothing.
      let wasOccupied = state.current != nil
      state.set(current: nil, pipelineIntent: intent, isHovered: false)
      return OverlayPlan(presentation: nil, didChange: wasOccupied)
    }

    state.set(current: presentation, pipelineIntent: intent, isHovered: false)
    return OverlayPlan(
      presentation: presentation, didChange: true, armExpiry: Self.arm(presentation))
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
      presentation: presentation, didChange: true, armExpiry: Self.arm(presentation))
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
    state.set(current: current, isHovered: hovering)
    // Hover pauses expiry; leaving re-arms it from full.
    guard case .after(let seconds, let pausesOnHover) = current.expiry, pausesOnHover else {
      return .noChange
    }
    return hovering
      ? OverlayPlan(presentation: current, didChange: false)
      : OverlayPlan(
        presentation: current, didChange: false, armExpiry: (id: current.id, seconds: seconds))
  }

  private mutating func reduceExpiry(_ id: PresentationID) -> OverlayPlan {
    guard isCurrent(id) else { return .noChange }
    // A hovered presentation does not expire. Re-arming happens on hover exit.
    guard !state.isHovered else { return .noChange }
    state.set(current: nil, isHovered: false)
    return OverlayPlan(presentation: nil, didChange: true)
  }

  // MARK: - Intent and request to presentation

  private static func arm(_ p: OverlayPresentation) -> (id: PresentationID, seconds: Double)? {
    guard case .after(let seconds, _) = p.expiry else { return nil }
    return (id: p.id, seconds: seconds)
  }

  /// The shipped widths and dwells, gathered. Values are carried over from the
  /// panel's own `transitionTo*` methods rather than chosen here; C4 is where
  /// each is checked against its origin call site.
  private static func presentation(for intent: OverlayIntent, id: PresentationID)
    -> OverlayPresentation?
  {
    switch intent {
    case .hidden:
      return nil

    case .recording(let level):
      // The ONLY kind that reserves a fixed interaction frame. 92 points is
      // deliberate: it holds the normal 185x44, the locked 120x64 and the
      // #1060 in-panel notice expansion without resizing on every morph.
      return OverlayPresentation(
        id: id, content: .recording(audioLevel: level, isLocked: false, notice: nil),
        expiry: .untilReplaced, requestedWidth: 185, reservesFixedHeight: 92)

    case .processing(let phase):
      return notice(id: id, text: DictationNarrator.copy(for: phase), width: 185)

    case .clipboardFallback:
      return notice(
        id: id, text: DictationNarrator.clipboardFallbackText, width: 260,
        expiry: .after(seconds: 3))

    case .accessibilityToast:
      return notice(
        id: id, text: DictationNarrator.accessibilityToastText, width: 320,
        expiry: .after(seconds: 6), isMultiline: true,
        action: (label: "Grant", action: .grantAccessibility))

    case .warning(let reason):
      return notice(
        id: id, text: DictationNarrator.copy(for: reason), width: 260,
        expiry: .after(seconds: 2.5), severity: .warning)

    case .error(let reason):
      return notice(
        id: id, text: DictationNarrator.copy(for: reason), width: 260,
        expiry: .after(seconds: 3), severity: .error)

    case .advisory(let reason):
      // #1891: deliberately NOT `.error`. Multiline, and a dwell long enough
      // to read the sentence.
      return notice(
        id: id, text: DictationNarrator.copy(for: reason), width: 320,
        expiry: .after(seconds: 6), isMultiline: true)

    case .interruption(let reason):
      return notice(
        id: id, text: DictationNarrator.copy(for: reason), width: 260,
        expiry: .after(seconds: 2), severity: .distress)

    case .passiveChip(let payload):
      return OverlayPresentation(
        id: id, content: .languageChip(payload: payload),
        expiry: .after(seconds: 6, pausesOnHover: true), requestedWidth: 320)

    case .cachingModel(let engineLabel):
      return notice(
        id: id, text: DictationNarrator.coldStartTitle,
        secondary: DictationNarrator.coldStartSubtitle(engineLabel: engineLabel), width: 260,
        expiry: .after(seconds: 2))

    case .engineReady:
      return notice(
        id: id, text: DictationNarrator.readyTitle, width: 260,
        expiry: .after(seconds: 1.5))

    case .recoveringLastRecording:
      return notice(
        id: id, text: DictationNarrator.recoveryTitle, secondary: DictationNarrator.recoverySubtitle,
        width: 320,
        expiry: .untilReplaced, isMultiline: true,
        action: (label: "Discard", action: .discardRecovery))

    case .recoverySucceeded:
      return notice(
        id: id, text: DictationNarrator.recoverySucceededTitle,
        secondary: DictationNarrator.recoverySucceededSubtitle, width: 260,
        expiry: .after(seconds: 2))

    case .bluetoothAwareness:
      return OverlayPresentation(
        id: id, content: .bluetoothAwareness, expiry: .after(seconds: 6, pausesOnHover: true),
        requestedWidth: 320)

    case .escapeRecovery(let transcriptID):
      return OverlayPresentation(
        id: id, content: .escapeRecovery(transcriptID: transcriptID),
        expiry: .untilReplaced, requestedWidth: 320)
    }
  }

  private static func presentation(for request: OverlayRequest, id: PresentationID)
    -> OverlayPresentation
  {
    switch request {
    case .importStatus(let message):
      return OverlayPresentation(
        id: id, content: .notice(NoticeModel(text: message, isMultiline: true)),
        expiry: .after(seconds: 4), requestedWidth: 320)
    case .bluetoothAwareness:
      return OverlayPresentation(
        id: id, content: .bluetoothAwareness, expiry: .after(seconds: 6, pausesOnHover: true),
        requestedWidth: 320)
    case .passiveChip(let payload):
      return OverlayPresentation(
        id: id, content: .languageChip(payload: payload),
        expiry: .after(seconds: 6, pausesOnHover: true), requestedWidth: 320)
    case .accessibilityToast:
      return OverlayPresentation(
        id: id,
        content: .notice(
          NoticeModel(
            text: DictationNarrator.accessibilityToastText, isMultiline: true,
            action: (label: "Grant", action: .grantAccessibility))),
        expiry: .after(seconds: 6), requestedWidth: 320)
    }
  }

  private static func notice(
    id: PresentationID, text: String, secondary: String? = nil, width: CGFloat,
    expiry: OverlayExpiry = .untilReplaced, severity: NoticeModel.Severity = .neutral,
    isMultiline: Bool = false, action: (label: String, action: OverlayAction)? = nil
  ) -> OverlayPresentation {
    OverlayPresentation(
      id: id,
      content: .notice(
        NoticeModel(
          text: text, secondaryText: secondary, severity: severity, isMultiline: isMultiline,
          action: action)),
      expiry: expiry, requestedWidth: width)
  }
}
