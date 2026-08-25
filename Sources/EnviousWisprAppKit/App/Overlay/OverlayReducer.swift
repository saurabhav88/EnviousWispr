import CoreGraphics
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

// The sole authority for WHAT occupies the overlay slot (#2292, chunk C2).
//
// Deliberately free of AppKit. It decides; it never draws, never touches a
// window, and never schedules anything. That is what makes the arbitration
// rules — which are today spread across a shared `currentIntent` slot, an
// importStatusOwnsCurrentSlot computed property, a Bluetooth `isPresented`
// flag and a passive-chip generation counter — assertable in a plain unit test.

/// Everything that can ask for the overlay slot, in one union.
///
/// Five producers reach the overlay today and each arrived through its own
/// entry point on the panel. Naming them as one type is what makes
/// "which of these outranks which" a question with a single written answer.
enum OverlayEvent: Equatable {
  /// The dictation pipeline. Outranks every feature.
  case pipeline(OverlayIntent)
  /// A bulk-import progress pill. A feature, so it takes the slot only while
  /// the pipeline is idle, and only from ITSELF.
  case importStatus(message: String)
  /// The Bluetooth-microphone card. A feature, so it takes the slot only while
  /// the pipeline is idle, and persists until it is replaced.
  case bluetoothAwareness
  /// A notice that morphs a LIVE recording pill rather than replacing it.
  case inPanelNotice(RecordingNoticeReason, dismissAfter: Double?)
  /// Hands-free lock engaged or released. updateLockState today; it
  /// morphs the live recording pill and does nothing otherwise. The first model
  /// carried `isLocked` on the presentation with no event able to change it.
  case lockStateChanged(Bool)
  /// The user pressed something on the presentation identified by this id.
  case action(PresentationID, PillAction)
  /// Hover began or ended on the presentation identified by this id.
  case hoverChanged(PresentationID, Bool)
  /// The expiry armed for this id fired.
  case expiryFired(PresentationID)
  /// The IN-PANEL NOTICE's dwell armed for this id fired. The pill stays.
  case inPanelNoticeExpiryFired(PresentationID)
}

/// What the director should do to the single armed expiry.
///
/// **Three states, because two cannot express the difference between "leave the
/// timer alone" and "cancel it".** An optional would collapse them:
/// reading `nil` as cancel makes every stale or no-op
/// event kill a live timer, and reading it as unchanged leaves a hovered pill's
/// timer running so hover-pause does nothing at all. Cloud review named it, and
/// it is exactly the hazard I had flagged as my own least-confident change.
/// What the single armed timer is counting down.
///
/// **One timer, two things it can end.** A presentation's own dwell and the
/// #1060 in-panel notice's `dismissAfter` are both "arm a timer for this id",
/// and without this the director could not tell them apart — so the notice's
/// timer was never armed at all and `dismissAfter: 4.0` reached the model and
/// was never read. A dwell that never fires is a banner that stays until the
/// recording ends.
enum OverlayExpiryTarget: Equatable, Sendable {
  case presentation
  case inPanelNotice
}

enum OverlayExpiryCommand: Equatable {
  /// Leave whatever is armed alone. The correct answer for every dropped stale
  /// event, which is most of them.
  case unchanged
  /// Disarm and arm nothing: the presentation went away, or hover paused it.
  case cancel
  case arm(id: PresentationID, seconds: Double, target: OverlayExpiryTarget)
}

/// What the director must do to make reality match the reducer's decision.
///
/// A PLAN, not a mutation: the reducer returns it and the director performs it.
/// Keeping the decision and the effect apart is what lets a test drive a whole
/// dictation's worth of events and assert on the resulting sequence without a
/// window server, a run loop, or a clock.
struct OverlayPlan: Equatable {
  /// What should occupy the slot now. `nil` means the slot is empty.
  let presentation: PillDefinition?
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
  let deliverAction: PillAction?
  /// Side effects for feature owners that keep their own state. Usually empty.
  let effects: [PillEffect]
  /// What a screen reader should say, and how loudly.
  ///
  /// **On the PLAN rather than on the presentation, because `.hidden` has no
  /// presentation and still announces "Recording complete".** Fifteen of the
  /// sixteen would sit naturally on the presentation and the sixteenth cannot,
  /// so the presentation is the wrong home for all of them.
  ///
  /// Not a `PillEffect` either: effects are delivered to the composition
  /// root's closure, and posting an accessibility notification is not the
  /// composition root's job — it is part of presenting, which the director does.
  let announcement: OverlayAnnouncement?

  static func == (a: OverlayPlan, b: OverlayPlan) -> Bool {
    a.presentation == b.presentation && a.didChange == b.didChange
      && a.expiryCommand == b.expiryCommand && a.deliverAction == b.deliverAction
      && a.effects == b.effects && a.announcement == b.announcement
  }

  static let noChange = OverlayPlan(presentation: nil, didChange: false)

  init(
    presentation: PillDefinition?, didChange: Bool,
    expiryCommand: OverlayExpiryCommand = .unchanged,
    deliverAction: PillAction? = nil,
    effects: [PillEffect] = [],
    announcement: OverlayAnnouncement? = nil
  ) {
    self.presentation = presentation
    self.didChange = didChange
    self.expiryCommand = expiryCommand
    self.deliverAction = deliverAction
    self.effects = effects
    self.announcement = announcement
  }
}

/// The reducer's own memory. Small on purpose: if this grows a per-kind field
/// collection it has become the thing it replaced.
struct OverlayState: Equatable {
  /// What occupies the slot, or nil.
  private(set) var current: PillDefinition?
  /// The last pipeline intent seen. A feature may take the slot only while this
  /// is `.hidden`, which is the arbitration rule the shipped code spells out
  /// separately at every feature.
  private(set) var pipelineIntent: OverlayIntent = .hidden
  /// True while the pointer is inside the current presentation. A hovered
  /// presentation does not expire.
  private(set) var isHovered = false
  /// Hands-free lock, which OUTLIVES any one presentation.
  ///
  /// Shipped updateLockState sets the shared `OverlayLockState`
  /// unconditionally with no recording guard, and `show(...)` takes an
  /// `isRecordingLocked:` argument so a pill is born locked rather than
  /// rendering unlocked and morphing a frame later. The first model held
  /// `isLocked` only inside the presentation and always started it `false`,
  /// which loses both: a lock set between dictations was dropped, and a locked
  /// start would have flashed unlocked.
  private(set) var isLocked = false

  /// Whether a FEATURE may take the slot right now.
  ///
  /// **THE arbitration rule, stated once and owned by state** (#2292 C5c). It
  /// used to be re-derived at every feature — import status read
  /// `currentIntent == .hidden && …`, Bluetooth kept its own `isPresented` flag,
  /// the chip kept a generation counter — and nothing held those three to the
  /// same answer. Two conditions, both required: the pipeline is idle, and no
  /// other feature already holds the slot.
  ///
  /// The second half is not redundant. A feature does not touch `pipelineIntent`,
  /// so a card or a chip on screen leaves it `.hidden`, and idleness alone would
  /// let either be replaced by the next feature to ask.
  var featureSlotIsAvailable: Bool {
    guard pipelineIntent == .hidden else { return false }
    switch current?.content {
    case .bluetoothAwareness, .languageChip: return false
    default: return true
    }
  }

  fileprivate mutating func set(
    current: PillDefinition?, pipelineIntent: OverlayIntent? = nil, isHovered: Bool? = nil,
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
    case .importStatus(let message):
      return reduceImportStatus(message: message)
    case .bluetoothAwareness:
      return reduceBluetoothAwareness()
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
    case .inPanelNoticeExpiryFired(let id):
      return reduceInPanelNoticeExpiry(id)
    }
  }

  // MARK: - Pipeline

  private mutating func reducePipeline(_ intent: OverlayIntent) -> OverlayPlan {
    // **Announce on a CHANGE of intent, which is the shipped dedup guard's own
    // condition.** The shipped post sits after `guard intent != currentIntent`,
    // so a repeated push is silent — and every production `.recording` push
    // carries `audioLevel: 0` (the real level is PULLED by the view through a
    // provider), so a live dictation announces once rather than per frame.
    //
    // ONE deliberate difference, recorded rather than inherited: the shipped
    // guard has a second clause letting a push through when only the LOCK
    // changed, which re-announces "Recording started" as the user engages
    // hands-free. The lock is its own event here, so that path does not exist,
    // and re-announcing a recording that never stopped is not behaviour worth
    // porting.
    let isNewIntent = state.pipelineIntent != intent
    let announcement = isNewIntent ? Self.announcement(for: intent) : nil

    // **The shipped dedup DROPS a repeated intent, it does not merely silence
    // it.** The first version returned a fresh presentation with a new ID and
    // re-armed the expiry, so a duplicate push restarted a notice's dwell and
    // reset SwiftUI identity — the #930 flicker arriving through the guard that
    // exists to prevent it. `.hidden` is exempt because emptying an already
    // empty slot is handled below and must stay a genuine no-op with its own
    // `didChange` accounting.
    if !isNewIntent, intent != .hidden, !Self.isRecordingIntent(intent) {
      return .noChange
    }

    // A live recording pill must keep its identity across audio-level updates,
    // or every metering tick would look like a new presentation and re-arm
    // expiry, re-measure the frame and reset the in-panel notice.
    if case .recording(let level) = intent,
      let current = state.current,
      case .recording(_, let isLocked, let notice) = current.content
    {
      let updated = PillDefinition(
        id: current.id,
        content: .recording(audioLevel: level, isLocked: isLocked, notice: notice),
        expiry: current.expiry,
        requestedWidth: current.requestedWidth,
        reservesFixedHeight: current.reservesFixedHeight)
      state.set(current: updated, pipelineIntent: intent)
      return OverlayPlan(presentation: updated, didChange: true, announcement: announcement)
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
        effects: wasRecording ? [.recordingStateChanged(false)] : [],
        announcement: announcement)
    }

    // Born locked if the lock is on. `show(...isRecordingLocked:)`
    // exists precisely so this is applied in the SAME transaction rather than
    // rendered unlocked and morphed a frame later.
    if case .recording(let level, _, let notice) = presentation.content, state.isLocked {
      presentation = PillDefinition(
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
      effects: wasRecording == isRecording ? [] : [.recordingStateChanged(isRecording)],
      announcement: announcement)
  }

  /// The accessibility notice, as ONE transition.
  ///
  /// **The eligibility decision changes what is DRAWN, not what the pipeline
  /// intent is.** Reducing `.accessibilityToast` and then `.clipboardFallback`
  /// as two transitions left the state saying `.clipboardFallback` — so a real
  /// clipboard-fallback push arriving next would be deduped away, and the
  /// arbitration rule that lets a feature take the slot only while the pipeline
  /// is idle would be reading the wrong intent. It also DISCARDED the first
  /// transition's effects, losing `.recordingStateChanged(false)` when this
  /// notice replaces a live recording, which is how Live Preview learns the
  /// dictation ended.
  ///
  /// The dedup guard is the shipped one: an identical intent is dropped, which
  /// is what stops a duplicate push spending a second eligibility ask and
  /// swapping a visible toast for the fallback.
  /// `showingToast` is a CLOSURE so the dedup guard below runs BEFORE the
  /// eligibility ask. Taking a `Bool` evaluates it at the call site, which spends
  /// the session's one showing on a push this method then drops — and the next
  /// genuine ask is refused, so the user is never told. My own guard caught that,
  /// which is the argument for the guard rather than for the parameter.
  mutating func reduceAccessibilityNotice(showingToast: () -> Bool) -> OverlayPlan {
    guard state.pipelineIntent != .accessibilityToast else { return .noChange }

    let showToast = showingToast()
    let toast = reducePipeline(.accessibilityToast)
    guard !showToast, let shown = toast.presentation,
      let fallback = Self.presentation(for: .clipboardFallback, id: shown.id)
    else {
      return toast
    }

    // Only the picture changes. `reducePipeline` has already set the intent to
    // `.accessibilityToast` and that is the intent this IS; the fallback merely
    // draws in its place.
    state.set(current: fallback)

    return OverlayPlan(
      presentation: fallback, didChange: toast.didChange,
      expiryCommand: Self.command(for: fallback),
      deliverAction: toast.deliverAction, effects: toast.effects,
      announcement: toast.announcement)
  }

  // MARK: - Features

  /// **Import status may only replace ITSELF.** Pipeline idleness alone is not
  /// the shipped rule: a status pill could otherwise take the slot from the
  /// Bluetooth card or the language chip, which the panel refused.
  ///
  /// **It announces nothing, and that is preserved rather than omitted.** It is
  /// the one presentation with no matching `OverlayIntent`, so the shipped
  /// switch had no arm for it. A sentence here would be inventing a notice.
  private mutating func reduceImportStatus(message: String) -> OverlayPlan {
    guard state.featureSlotIsAvailable else { return .noChange }
    if let current = state.current {
      guard case .notice(let notice) = current.content, notice.kind == .importStatus else {
        return .noChange
      }
    }
    return admit(
      PillDefinition(
        id: makeID(),
        content: .notice(NoticeModel(kind: .importStatus, text: message, isMultiline: true)),
        // `ImportStatusOverlayView` uses `.frame(maxWidth: 280)` — a BOUND, not a
        // width — under `fitToContent`, so this is measured too.
        expiry: .after(seconds: 3), requestedWidth: .measured),  // :1105, :1148
      announcement: nil)
  }

  /// **The card is announced at MEDIUM priority, read off the shipped switch.**
  /// `RecordingOverlayPanel.apply(intent:)` has a `.bluetoothAwareness` arm
  /// posting `DictationNarrator`'s sentence, reached because the wiring called
  /// `show(intent:)` for it. The cutover routed the card through the one
  /// presenting plan that carried no announcement, so it appeared in silence —
  /// and it is the worst pill for that, being the only one that persists until
  /// dismissed rather than expiring on its own.
  private mutating func reduceBluetoothAwareness() -> OverlayPlan {
    guard state.featureSlotIsAvailable else { return .noChange }
    return admit(
      PillDefinition(
        id: makeID(), content: .bluetoothAwareness, expiry: .untilReplaced,
        requestedWidth: .fixed(320)),  // :1790 — persistent
      announcement: Self.announcement(for: .bluetoothAwareness))
  }

  /// The tail every feature shares: take the slot, arm the expiry, speak.
  private mutating func admit(
    _ presentation: PillDefinition, announcement: OverlayAnnouncement?
  ) -> OverlayPlan {
    state.set(current: presentation, isHovered: false)
    return OverlayPlan(
      presentation: presentation, didChange: true, expiryCommand: Self.command(for: presentation),
      announcement: announcement)
  }

  // **`announcement(forFeature:)` was DELETED with `OverlayRequest`** (#2292 C5c).
  // It existed to map a feature request onto the intent whose sentence it should
  // speak, and its own comment records what that duplication cost: `OverlayRequest`
  // and `OverlayIntent` both carried `.bluetoothAwareness` and `.passiveChip`, so a
  // bare `.bluetoothAwareness` resolved to that overload rather than the intent one
  // and recursed until the stack ended — compiling perfectly and crashing at
  // runtime, killing five tests before an annotation went in. With one vocabulary
  // there is no overload to resolve wrongly, and each feature names its own
  // sentence at the point it takes the slot.

  private static func isRecording(_ p: PillDefinition?) -> Bool {
    if case .recording? = p?.content { return true }
    return false
  }

  /// Hands-free lock.
  ///
  /// **The flag is recorded whether or not a pill is showing**, because shipped
  /// updateLockState has NO recording guard — it sets the
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

    let updated = PillDefinition(
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

    let updated = PillDefinition(
      id: current.id,
      content: .recording(
        audioLevel: level, isLocked: isLocked,
        notice: InPanelNotice(reason: reason, dismissAfter: dismissAfter)),
      expiry: current.expiry,
      requestedWidth: current.requestedWidth,
      reservesFixedHeight: current.reservesFixedHeight)
    state.set(current: updated)
    // #1060's `dismissAfter` is a real dwell and it must be ARMED. The
    // approaching-cap banner passes nil and is persistent until the recording
    // ends; `autoStopUnavailable` passes 4.0 and must clear itself.
    let expiry: OverlayExpiryCommand =
      dismissAfter.map { .arm(id: current.id, seconds: $0, target: .inPanelNotice) } ?? .cancel
    return OverlayPlan(presentation: updated, didChange: true, expiryCommand: expiry)
  }

  /// The in-panel notice's dwell elapsed: clear the BANNER, keep the pill.
  ///
  /// Distinct from `reduceExpiry`, which ends a whole presentation. A recording
  /// outlives its banner.
  mutating func reduceInPanelNoticeExpiry(_ id: PresentationID) -> OverlayPlan {
    guard isCurrent(id), let current = state.current,
      case .recording(let level, let isLocked, let notice) = current.content, notice != nil
    else { return .noChange }

    let updated = PillDefinition(
      id: current.id,
      content: .recording(audioLevel: level, isLocked: isLocked, notice: nil),
      expiry: current.expiry,
      requestedWidth: current.requestedWidth,
      reservesFixedHeight: current.reservesFixedHeight)
    state.set(current: updated)
    return OverlayPlan(presentation: updated, didChange: true, expiryCommand: .cancel)
  }

  // MARK: - Identity-gated events

  /// An action, a hover or an expiry that names an id which is no longer
  /// current is STALE and is dropped. One rule, one place — this is the whole
  /// job `PresentationID` was introduced for, and the reason it must never be
  /// compared for order: the question is only ever "is this still the one".
  private func isCurrent(_ id: PresentationID) -> Bool { state.current?.id == id }

  private mutating func reduceAction(_ id: PresentationID, _ action: PillAction) -> OverlayPlan {
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
        expiryCommand: .arm(id: current.id, seconds: seconds, target: .presentation))
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
    var effects: [PillEffect] = []
    switch current.content {
    case .languageChip(let payload):
      effects.append(.languageChipExpired(generation: payload.generation))
    case .escapeRecovery:
      // **No effect since C4a.** The director holds the payload and clears it
      // itself when the slot changes hands, so there is no owner outside to
      // tell. The row stays in History under its own expiry.
      break
    case .recording:
      effects.append(.recordingStateChanged(false))
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
  private static func command(for p: PillDefinition) -> OverlayExpiryCommand {
    guard case .after(let seconds, _) = p.expiry else { return .cancel }
    return .arm(id: p.id, seconds: seconds, target: .presentation)
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
    -> PillDefinition?
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
      // the reducer cannot decide it here, and it does not: the 92 below is the
      // NON-preview answer, and `OverlayDirector.fixedHeight(for:)` overrides it
      // to content-sized when the render model says preview is on.
      return PillDefinition(
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
      // that site via transitionToPolishingNow, dwell from
      // `scheduleAutoDismiss`'s own default.
      return notice(
        // Routes through the same `PolishingOverlayView` path, so also measured.
        id: id, kind: .processing, text: DictationNarrator.clipboardFallbackText, width: .measured,
        expiry: .after(seconds: 2.5))

    case .accessibilityToast:
      return notice(
        id: id, kind: .accessibilityToast, text: DictationNarrator.accessibilityToastText,
        width: .fixed(300), fixedHeight: 56,  // :859 and :1118 both pass height: 56
        expiry: .after(seconds: 6), isMultiline: true,
        action: (label: "Grant", action: .grantAccessibility))

    case .warning(let reason):
      return notice(
        id: id, kind: .notification, text: DictationNarrator.copy(for: reason),
        // A single-line notification is NOT `fitToContent`, so it takes
        // `showPanel`'s own `height: 44` default and keeps the 280x44 box.
        width: .fixed(280), fixedHeight: 44,
        expiry: .after(seconds: 2.5), severity: .warning)  // NotificationStyle 2.5

    case .error(let reason):
      return notice(
        id: id, kind: .notification, text: DictationNarrator.copy(for: reason),
        width: .fixed(280), fixedHeight: 44,
        expiry: .after(seconds: 3), severity: .error)  // NotificationStyle 3.0

    case .advisory(let reason):
      // #1891. A user-setup advisory draws the mic-slash glyph in the secondary
      // colour, not the red failure treatment, and `NotificationStyle` owns both
      // — so it needs a severity of its own rather than inheriting the helper's
      // `.neutral`, which `OverlayRootView.style(for:)` paints as a warning.
      //
      // **The ONLY notification that is content-sized**, because `showPanel` is
      // called with `fitToContent: style.isMultiline` and this is the one style
      // where that is true. No `fixedHeight` here is deliberate, not an omission.
      return notice(
        id: id, kind: .notification, text: DictationNarrator.copy(for: reason),
        width: .fixed(360),  // RecordingOverlayPanel.advisoryWidth
        expiry: .after(seconds: 8), severity: .advisory, isMultiline: true)

    case .interruption(let reason):
      return notice(
        id: id, kind: .notification, text: DictationNarrator.copy(for: reason),
        width: .fixed(280), fixedHeight: 44,
        expiry: .after(seconds: 2), severity: .distress)  // NotificationStyle 2.0

    case .passiveChip(let payload):
      return PillDefinition(
        id: id, content: .languageChip(payload: payload),
        expiry: .after(seconds: 6, pausesOnHover: true),
        requestedWidth: .fixed(340), reservesFixedHeight: 56)  // :1410

    case .cachingModel(let engineLabel):
      return notice(
        id: id, kind: .warmingUp, text: DictationNarrator.coldStartTitle,
        secondary: DictationNarrator.coldStartSubtitle(engineLabel: engineLabel),
        width: .fixed(300), fixedHeight: 56,  // :483
        expiry: .after(seconds: 2))  // :642

    case .engineReady:
      return notice(
        id: id, kind: .ready, text: DictationNarrator.readyTitle,
        width: .fixed(240), fixedHeight: 44,  // :498
        expiry: .after(seconds: 1.5))  // :657

    case .recoveringLastRecording:
      return notice(
        id: id, kind: .recovery, text: DictationNarrator.recoveryTitle,
        secondary: DictationNarrator.recoverySubtitle,
        width: .fixed(320), fixedHeight: 56,  // :530
        // that site gives it a 6-second dwell. The first version said `.untilReplaced`,
        // which would have left the recovery pill on screen forever.
        expiry: .after(seconds: 6), isMultiline: true,
        action: (label: "Discard", action: .discardRecovery))

    case .recoverySucceeded:
      // `.ready`, NOT `.notification`. The shipped site draws
      // `ColdStartNoticeView(title:subtitle:icon: .ready)` — the same green
      // success mark `.engineReady` uses — and routing it through
      // `NotificationOverlayView` would have painted a success message as a
      // warning, which is the exact failure this whole mapping exists to stop.
      return notice(
        id: id, kind: .ready, text: DictationNarrator.recoverySucceededTitle,
        secondary: DictationNarrator.recoverySucceededSubtitle,
        width: .fixed(300), fixedHeight: 56,  // :516
        expiry: .after(seconds: 3))  // :675

    case .bluetoothAwareness:
      return PillDefinition(
        // that site calls `showPanel` with NO `scheduleAutoDismiss`: the card is
        // PERSISTENT until something replaces it. The first version gave it a
        // 6-second dwell, which would have made it vanish on its own.
        id: id, content: .bluetoothAwareness, expiry: .untilReplaced,
        requestedWidth: .fixed(320))

    case .escapeRecovery(let transcriptID):
      return PillDefinition(
        // **THIS expiry is the only one. The director owns it; the view draws
        // it.** Three seconds, hover-pausable, exactly like any other dwell.
        //
        // The shipped panel could not do that -- it had no single owner of
        // expiry, so a panel-level timer could not be paused by a hover only the
        // view sees and the view kept its own. That reason died with the
        // retained window, and this comment used to LEAD with it as though it
        // were still true, correcting itself only at the end.
        //
        // It cost two independent three-second timers running side by side from
        // the cutover until cloud review found the rail finishing while the pill
        // was still on screen. The trap worth naming: a comment asserting a
        // FUTURE state ("a later chunk removes the view's task") is invisible to
        // every diff review, because nothing in a diff can contradict a promise.
        // C4 was recorded as doing it and did not; C18 did.
        id: id, content: .escapeRecovery(transcriptID: transcriptID),
        expiry: .after(seconds: 3, pausesOnHover: true), requestedWidth: .measured)
    }
  }

  // **`presentation(for request:id:)` was DELETED with `OverlayRequest`**
  // (#2292 C5c). Its four arms are now: import status and Bluetooth inline in
  // their own reducers above, and `.passiveChip` / `.accessibilityToast` gone
  // entirely — those were unreachable duplicates of the pipeline presentations
  // `presentation(for intent:)` already builds, since the chip travels as
  // `.pipeline(.passiveChip)` and the toast through `reduceAccessibilityNotice`.

  /// `fixedHeight` is the shipped `showPanel(height:)` for this notice, and
  /// omitting it means CONTENT-SIZED, which is what `fitToContent: true` does at
  /// the shipped site.
  ///
  /// **It defaults to nil and that default is a trap worth naming.** Every
  /// notice in the first port took it, so eight pills that reserve a fixed box
  /// became content-sized — a geometry change with no compiler error, no test
  /// failure and no mention in any diff. `noticeGeometryIsPinned` sweeps the
  /// closed set against the shipped call sites so a new row cannot inherit the
  /// default silently.
  /// The spoken announcement for a pipeline intent, and its priority.
  ///
  /// **Both halves come from the shipped `apply(intent:)` switch, read one arm
  /// at a time.** The TEXT is `DictationNarrator.announcement(for:)`, which is
  /// already the sole author (#1569 E4). The PRIORITY is the panel's own choice
  /// per case — nine `.high` and seven `.medium` — and it is not derivable from
  /// severity: `.recording` and `.engineReady` are high while `.warning` is
  /// medium, so it is enumerated rather than computed.
  static func announcement(for intent: OverlayIntent) -> OverlayAnnouncement {
    let text = DictationNarrator.announcement(for: intent)
    switch intent {
    case .recording, .clipboardFallback, .accessibilityToast, .error, .advisory,
      .interruption, .engineReady, .recoverySucceeded, .recoveringLastRecording:
      return .high(text)
    case .hidden, .processing, .warning, .passiveChip, .cachingModel,
      .bluetoothAwareness, .escapeRecovery:
      return .medium(text)
    }
  }

  private static func isRecordingIntent(_ intent: OverlayIntent) -> Bool {
    if case .recording = intent { return true }
    return false
  }

  private static func notice(
    id: PresentationID, kind: NoticeModel.Kind, text: String, secondary: String? = nil,
    width: OverlayWidth, fixedHeight: CGFloat? = nil,
    expiry: OverlayExpiry = .untilReplaced, severity: NoticeModel.Severity = .neutral,
    isMultiline: Bool = false, action: (label: String, action: PillAction)? = nil
  ) -> PillDefinition {
    PillDefinition(
      id: id,
      content: .notice(
        NoticeModel(
          kind: kind, text: text, secondaryText: secondary, severity: severity,
          isMultiline: isMultiline, action: action)),
      expiry: expiry, requestedWidth: width, reservesFixedHeight: fixedHeight)
  }
}
