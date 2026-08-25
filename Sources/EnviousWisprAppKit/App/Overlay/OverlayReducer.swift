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

  /// How many times the SLOT has changed hands (#2375 C3a).
  ///
  /// **A slot revision, not a whole-state one, and the narrowing is a product
  /// decision rather than an optimisation.** A prepared recording is discarded
  /// when this moves between PREPARE and COMMIT. Two of `set`'s eleven callers
  /// are a hover change and a lock-only change with no presentation; neither can
  /// conflict with committing a fresh recording, and discarding on either means a
  /// recording pill that never appears. `CLAUDE.md` puts "dictation works 100% of
  /// the time it physically can" above every other audio decision, so an
  /// over-eager invalidation is the more expensive error here.
  ///
  /// A lock morph on a LIVE recording changes `current` and therefore does
  /// advance this, so no real slot conflict is missed.
  private(set) var slotRevision: UInt64 = 0

  fileprivate mutating func set(
    current: PillDefinition?, pipelineIntent: OverlayIntent? = nil, isHovered: Bool? = nil,
    isLocked: Bool? = nil
  ) {
    // **Compare VALUES, never "was a parameter supplied".** `set(current:isHovered:)`
    // passes the EXISTING current straight through on a hover change, and
    // `set(current:isLocked:)` does the same on a lock-only change, so an
    // increment keyed on the presence of an argument would advance on every hover
    // and silently undo the narrowing above.
    if current != self.current || (pipelineIntent != nil && pipelineIntent != self.pipelineIntent) {
      slotRevision &+= 1
    }
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

  // MARK: - The recording transaction

  /// What PREPARE decided, when it decided a fresh recording should start.
  ///
  /// **One-shot, and it publishes NO definition.** It carries only what RESOLVE
  /// and COMMIT need: the identity the pill will have, the effects the director
  /// must route before it may read capability, the sentence to speak, and the
  /// slot revision PREPARE observed. Nothing here has been applied to reducer
  /// state — that is the point of the split.
  struct PreparedRecordingTransition: Equatable, Sendable {
    let id: PresentationID
    let audioLevel: Float
    let effects: [PillEffect]
    let announcement: OverlayAnnouncement?
    /// The slot revision at PREPARE time. COMMIT refuses if it has moved.
    let observedSlotRevision: UInt64
  }

  /// The three things PREPARE can conclude.
  enum RecordingPreparation {
    /// The slot already holds a recording, so this is a same-id morph: the design
    /// is preserved from the live pill, RESOLVE is skipped entirely, and the plan
    /// is final and already applied.
    case morphed(OverlayPlan)
    /// Nothing to do.
    case refused(OverlayPlan)
    /// A fresh recording. Route `effects`, resolve a design, then COMMIT.
    case prepared(PreparedRecordingTransition)
  }

  /// PREPARE: decide admission, identity and effects for a recording WITHOUT
  /// minting a definition (#2375 C3a).
  ///
  /// **This exists because recording composition is not one transaction.** The
  /// shipped ordering routes the recording effect BEFORE reading whether Live
  /// Preview is on, and that ordering is load-bearing: `LivePreviewCoordinator`
  /// applies its model-removal suppression inside `setRecording`, so a capability
  /// read that beats the effect can pick the wide layout for a pill whose preview
  /// is about to resolve disabled — a preview-sized window with nothing in it.
  /// The catalog needs the resolved design as an INPUT to minting, so the mint
  /// has to happen after the effect, which means it cannot happen here.
  ///
  /// **Mutates nothing on the `prepared` path.** A caller that prepares and never
  /// commits leaves the reducer exactly as it found it.
  mutating func prepareRecording(audioLevel: Float) -> RecordingPreparation {
    let intent = OverlayIntent.recording(audioLevel: audioLevel)
    let isNewIntent = state.pipelineIntent != intent
    let announcement = isNewIntent ? PillCatalog.announcement(for: intent) : nil

    // A live recording keeps its identity across audio-level updates, and keeps
    // its DESIGN with it. An `NSPanel` cannot grow mid-recording without a
    // rebuild and a rebuild is the #930 flicker, so re-resolving here would
    // resize a live pill the moment the user changed the setting.
    if let current = state.current,
      case .recording(_, let isLocked, let notice, let design) = current.content
    {
      let updated = PillDefinition(
        id: current.id,
        content: .recording(
          audioLevel: audioLevel, isLocked: isLocked, notice: notice, design: design),
        expiry: current.expiry,
        requestedWidth: current.requestedWidth,
        reservesFixedHeight: current.reservesFixedHeight)
      state.set(current: updated, pipelineIntent: intent)
      return .morphed(
        OverlayPlan(presentation: updated, didChange: true, announcement: announcement))
    }

    // Fresh. `.recordingStateChanged(true)` is emitted here and routed by the
    // director BEFORE it reads capability; COMMIT emits no effects of its own.
    let wasRecording = Self.isRecording(state.current)
    return .prepared(
      PreparedRecordingTransition(
        id: makeID(), audioLevel: audioLevel,
        effects: wasRecording ? [] : [.recordingStateChanged(true)],
        announcement: announcement,
        observedSlotRevision: state.slotRevision))
  }

  /// COMMIT: install the definition the director obtained from the catalog.
  ///
  /// Returns `nil` when the token is stale, which means a newer overlay event
  /// reentered synchronously between PREPARE and COMMIT and is already
  /// authoritative. **A discarded transition is not an error and must not be
  /// retried** — retrying it would install an older pill over a newer one, which
  /// is the stale-first-presentation defect this phase must not introduce.
  ///
  /// **The born-locked rule reads the reducer's CURRENT lock, never one captured
  /// at PREPARE.** That is what makes the narrowed slot revision safe rather than
  /// merely defensible: a lock-only event arriving inside the window does not
  /// advance the slot revision, so it does not invalidate the transition — and
  /// because the lock is read here, its effect is preserved in the pill that
  /// commits rather than lost.
  mutating func commitRecording(
    _ token: PreparedRecordingTransition, definition: PillDefinition
  ) -> OverlayPlan? {
    guard state.slotRevision == token.observedSlotRevision else { return nil }

    var committed = definition
    if state.isLocked,
      case .recording(let level, _, let notice, let design) = definition.content
    {
      committed = PillDefinition(
        id: definition.id,
        content: .recording(audioLevel: level, isLocked: true, notice: notice, design: design),
        expiry: definition.expiry, requestedWidth: definition.requestedWidth,
        reservesFixedHeight: definition.reservesFixedHeight)
    }

    state.set(
      current: committed, pipelineIntent: .recording(audioLevel: token.audioLevel),
      isHovered: false)
    return OverlayPlan(
      presentation: committed, didChange: true,
      expiryCommand: Self.command(for: committed),
      // The effects went out at RESOLVE, before the capability read. Emitting
      // them again here would tell Live Preview a recording started twice.
      effects: [],
      announcement: token.announcement)
  }

  /// What the bridge reconciliation reads.
  ///
  /// **A snapshot rather than a bare boolean, because the exit condition is "did
  /// the world move", which a boolean cannot answer.** Reconciliation routes
  /// `.recordingStateChanged`, and routing calls back into the same boundary that
  /// created the prepare/commit hazard, so reading the answer before the call
  /// proves nothing about the answer after it.
  var recordingReconciliationSnapshot: (revision: UInt64, isRecording: Bool) {
    (state.slotRevision, Self.isRecording(state.current))
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
    let announcement = isNewIntent ? PillCatalog.announcement(for: intent) : nil

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

    // **A bare `.pipeline(.recording)` may MORPH a live recording and may not
    // START one.** The morph below preserves the current pill's design, so it
    // needs nothing resolved. Starting one does, and `presentation(for:)` returns
    // nil for `.recording`, so a fresh recording arriving here empties the slot
    // rather than minting — which is why the guard after the morph refuses it
    // loudly instead. Production never sends one: `OverlayDirector` uses
    // `prepareRecording`.
    //
    // A live recording pill must keep its identity across audio-level updates,
    // or every metering tick would look like a new presentation and re-arm
    // expiry, re-measure the frame and reset the in-panel notice.
    if case .recording(let level) = intent,
      let current = state.current,
      case .recording(_, let isLocked, let notice, let design) = current.content
    {
      let updated = PillDefinition(
        id: current.id,
        content: .recording(
          audioLevel: level, isLocked: isLocked, notice: notice, design: design),
        expiry: current.expiry,
        requestedWidth: current.requestedWidth,
        reservesFixedHeight: current.reservesFixedHeight)
      state.set(current: updated, pipelineIntent: intent)
      return OverlayPlan(presentation: updated, didChange: true, announcement: announcement)
    }

    if Self.isRecordingIntent(intent) {
      // Reached only when the slot does not already hold a recording, i.e. a
      // FRESH one. Refusing loudly beats emptying the slot, which is what falling
      // through to the nil branch below would do — a dictation that starts and
      // shows nothing, on the one path `CLAUDE.md` says must work every time it
      // physically can.
      assertionFailure(
        "a fresh recording cannot be started through reduce(.pipeline(.recording)); "
          + "use prepareRecording(audioLevel:) so a design can be resolved")
      return .noChange
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
    if case .recording(let level, _, let notice, let design) = presentation.content, state.isLocked {
      presentation = PillDefinition(
        id: presentation.id,
        content: .recording(audioLevel: level, isLocked: true, notice: notice, design: design),
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
      // The SECOND catalog request of this transition, with the SAME id.
      // Stated rather than left to be rediscovered: this path substitutes the
      // clipboard DEFINITION while retaining the accessibility entry's
      // ANNOUNCEMENT, which is the one place the two halves of an entry
      // legitimately come from different requests. Neither request carries or
      // resolves a recording design.
      let fallback = PillCatalog.entry(for: .clipboardFallback, id: shown.id).definition
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
    // **REDUNDANT TODAY, and deliberately kept.** `featureSlotIsAvailable`
    // already refuses whenever the pipeline is not idle, and the only occupants a
    // feature route can install while it IS idle are the Bluetooth card, which
    // that guard also refuses, and an import-status notice, which this one
    // admits. So no reachable state distinguishes the two, and deleting either
    // line alone changes nothing observable — a single-line mutant here survives
    // by construction rather than for want of a test.
    //
    // Written down because that is exactly how a later tidy-up removes half of a
    // pair: run one mutation, see green, delete the line. The pair states a rule
    // the arbitration guard does not — a status pill may replace ITSELF and
    // nothing else — and it becomes load-bearing the moment a third feature route
    // installs a non-notice occupant.
    if let current = state.current {
      guard case .notice(let notice) = current.content, notice.kind == .importStatus else {
        return .noChange
      }
    }
    return admitEntry(PillCatalog.entry(for: .importStatus(message: message), id: makeID()))
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
    return admitEntry(PillCatalog.entry(for: .bluetoothAwareness, id: makeID()))
  }

  /// Admit a catalog entry.
  ///
  /// **The `nil` branch cannot be reached and is loud rather than silent.**
  /// `.hidden` is the only request whose entry carries no definition, and no
  /// feature path asks for it — but a `return .noChange` alone would turn a
  /// future mistake into a pill that quietly never appears, which is the hardest
  /// overlay defect to notice. Debug builds trap; release leaves the slot as it
  /// was.
  private mutating func admitEntry(_ entry: PillCatalogEntry) -> OverlayPlan {
    guard let definition = entry.definition else {
      assertionFailure("a feature request resolved to no definition")
      return .noChange
    }
    return admit(definition, announcement: entry.announcement)
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
      case .recording(let level, _, let notice, let design) = current.content
    else {
      state.set(current: state.current, isLocked: locked)
      return .noChange
    }

    let updated = PillDefinition(
      id: current.id,
      content: .recording(audioLevel: level, isLocked: locked, notice: notice, design: design),
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
      case .recording(let level, let isLocked, _, let design) = current.content
    else { return .noChange }

    let updated = PillDefinition(
      id: current.id,
      content: .recording(
        audioLevel: level, isLocked: isLocked,
        notice: InPanelNotice(reason: reason, dismissAfter: dismissAfter), design: design),
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
      case .recording(let level, let isLocked, let notice, let design) = current.content,
      notice != nil
    else { return .noChange }

    let updated = PillDefinition(
      id: current.id,
      content: .recording(audioLevel: level, isLocked: isLocked, notice: nil, design: design),
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

  /// What a pipeline intent occupies the slot with.
  ///
  /// **The table this used to hold now lives in `PillCatalog`**, moved byte for
  /// byte with the comments citing the call sites each value was read off.
  ///
  ///
  /// Listing the other fifteen rather than writing `default` is deliberate: a new
  /// pipeline intent must fail to compile here as well as in the catalog.
  private static func presentation(for intent: OverlayIntent, id: PresentationID)
    -> PillDefinition?
  {
    switch intent {
    case .hidden, .processing, .clipboardFallback, .accessibilityToast, .warning,
      .error, .advisory, .interruption, .passiveChip, .cachingModel, .engineReady,
      .recoveringLastRecording, .recoverySucceeded, .bluetoothAwareness, .escapeRecovery:
      guard let request = PillCatalogRequest(nonRecording: intent) else {
        // Unreachable: the initialiser refuses `.recording` only, and that arm
        // returns above without reaching here.
        assertionFailure("PillCatalogRequest(nonRecording:) refused a non-recording intent")
        return nil
      }
      return PillCatalog.entry(for: request, id: id).definition

    case .recording:
      // **The reducer no longer mints a recording pill, and this is the whole of
      // G3 closing.** The old arm here emitted 185x92 and said so in its own
      // comment: "the 92 below is the NON-preview answer, and the director
      // overrides it to content-sized when the render model says preview is on".
      // Two authorities for one geometry, one of them ignored, documented as
      // though it were a design.
      //
      // **`.recording` is deliberately not minted here.** C3a moved its factory
      // into `PillCatalog`, and a fresh recording goes through
      // `prepareRecording(audioLevel:)` — it needs a RESOLVED design, which needs
      // a capability read, which must happen after the recording effect is
      // routed. Nothing holding only an intent has resolved one.
      return nil
    }
  }

  // **`presentation(for request:id:)` was DELETED with `OverlayRequest`**
  // (#2292 C5c). Two of its four arms — `.passiveChip` and `.accessibilityToast`
  // — went entirely, as unreachable duplicates of the pipeline presentations this
  // reducer already built: the chip travels as `.pipeline(.passiveChip)` and the
  // toast through `reduceAccessibilityNotice`.
  //
  // The other two, import status and Bluetooth, were minted INLINE in their own
  // reducers until #2375 C2 moved them into `PillCatalog` with everything else.
  // Stated in the past tense on purpose: this note is history, and an earlier
  // revision of it said "inline in their own reducers above", which C2 made false
  // on the same day it stopped being true.

  private static func isRecordingIntent(_ intent: OverlayIntent) -> Bool {
    if case .recording = intent { return true }
    return false
  }
}
