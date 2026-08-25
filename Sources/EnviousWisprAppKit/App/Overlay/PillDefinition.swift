import CoreGraphics
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

// The overlay's shared vocabulary (#2292, chunk C2). Deliberately free of
// AppKit: everything here is a value, so the reducer and the placement state
// are testable with no windowing present, which is the property `OverlayReducer`
// exists to have.
// MARK: - Identity

/// Identity for one presentation of the overlay slot.
///
/// **This replaces seven independently owned staleness mechanisms**, each of
/// which answered "is this deferred work still valid" its own way: the panel's
/// `generation` counter, noticeDismissWork, pendingCreateWork,
/// autoDismissTask, the drag-retry work item, two view-owned dismiss tasks,
/// and `LanguageSuggestionPresenter`'s own counter.
///
/// It is an IDENTITY, never an ordering. Nothing may compare two of these for
/// which is newer — the only legal question is whether the id a piece of
/// deferred work captured is still the id the director considers current. A
/// counter invites `>` comparisons and the seven mechanisms it replaces all
/// drifted apart precisely because each chose its own answer.
struct PresentationID: Hashable, Sendable {
  let rawValue: UUID
  init() { rawValue = UUID() }
  /// Test seam only: a deterministic id, so a suite can assert on identity
  /// without threading a UUID factory through every call site.
  init(rawValue: UUID) { self.rawValue = rawValue }
}

// MARK: - The recording pill's design

/// The PIXELS of a recording design. Its identity lives in `EnviousWisprCore`,
/// because a setting persists it and `SettingsManager` is in Services; everything
/// here is what AppKit knows and Core must not.
extension RecordingPillDesign {

  /// Whether this design can display transcribed words while recording.
  ///
  /// **This is the authority for provider gating, and since C3b it is the only
  /// one.** The consumers key directly off `canHoldWords`. Before that the
  /// shipped code keyed off a layout value that also carried geometry and
  /// position, which is why one authority could disagree with another about what
  /// is on screen; C3a derived that value from this one and C3b deleted it.
  var canHoldWords: Bool {
    switch self {
    case .classic, .levelRail: return false
    case .readingWell: return true
    }
  }

  /// The width the window is sized to. Measured from
  /// `RecordingOverlayPanel`: `showsPreview ? previewPillWidth : 185`.
  var width: CGFloat {
    switch self {
    case .classic: return 185
    case .readingWell: return 400
    // Wide enough that the rail is the pill's subject rather than an ornament
    // beside the clock, and unmistakably not 185 at a glance. A CHOSEN number,
    // not a measured one — there is no mockup in the tree — and the one value in
    // this design a founder should move before it ships.
    case .levelRail: return 260
    }
  }

  /// What the Appearance picker calls this design.
  ///
  /// **On the design rather than in the picker, deliberately.** A per-design
  /// table in the view would be a second one on day one — the drift shape this
  /// phase exists to remove, one field over — and a design added later would
  /// render with a blank card until somebody remembered the other list.
  var displayName: String {
    switch self {
    case .classic: return "Capsule"
    case .readingWell: return "Reading Well"
    case .levelRail: return "Level Rail"
    }
  }

  /// One sentence on the card, in the user's terms rather than ours. No em or en
  /// dashes (GR-NO-DASHES).
  var summary: String {
    switch self {
    case .classic:
      return "A small capsule with the rainbow mark and a timer. The pill EnviousWispr has always shown."
    case .readingWell:
      return "A wide panel that shows your words as you speak, growing a line at a time."
    case .levelRail:
      return "A wider capsule with a live rainbow meter of your voice beside the timer."
    }
  }

  /// `nil` means content-sized, which is `fitToContent: true` at the shipped
  /// site. The classic pill reserves a fixed box; the reading well does not.
  var reservedHeight: CGFloat? {
    switch self {
    // **92 IS THE WITHOUT-WORDS NOTICE BUDGET, and it is inherited rather than
    // chosen.** The #1060 in-panel banner is rendered by every layout from one
    // `Text` inside the root stack, and a design that cannot hold words is handed
    // a no-op growth callback by `OverlayRenderModel` — so it CANNOT resize its
    // window when the banner arrives mid-recording. Measured 2026-08-25: the
    // longest shipped banner fills this box EXACTLY, with zero headroom, and a
    // three-line sentence measures 120 and would be clipped in silence. A 40 or
    // 44-point box would clip the graceful-cap warning on a shipping path with no
    // test able to see it, which is why `.levelRail` takes the same number as
    // `.classic` rather than one sized to its own contents.
    case .classic, .levelRail: return 92
    case .readingWell: return nil
    }
  }
}

/// Why the recording pill can or cannot show words as you speak (#2376 Phase 4).
///
/// **A REASON, where `LivePreviewBridge.isEnabledForGeometry` is a verdict.** The
/// director only needs to know whether to size a pill for words; a settings page
/// that greys out a whole group of designs has to say WHY, and a `Bool` cannot
/// carry that. One sentence for both causes would be worse than none: it would
/// tell a user on an unsupported machine to turn on a setting that would not help
/// them.
///
/// **Additive, and the verdict it sits beside is untouched.** Phase 3's seam
/// comment forbids Phase 4 from changing where the director resolves capability,
/// so this is produced alongside the property the director reads rather than
/// replacing it.
///
/// **It reads LIVE while that verdict reads a frozen snapshot, and the difference
/// is deliberate** (corrected by cloud review). The verdict answers "what is THIS
/// recording doing", so a pill on screen keeps the geometry it was sized for.
/// This answers "what will the NEXT recording do", which is the only question a
/// settings page can honestly answer — and Settings is reachable DURING a
/// recording, so a snapshot-backed answer would tell a user who just switched
/// Live Preview off that their words will still be shown.
/// `PillWordsCapabilityTests` asserts the agreement outside a recording and the
/// divergence during one.
enum PillWordsCapability: Equatable, Sendable, CaseIterable {
  /// Words are available: an engine that runs here, and the preview turned on.
  case available
  /// The engine would run here; the user has the preview switched off.
  case previewOff
  /// The selected engine cannot run on this machine, so the switch would not help.
  case engineUnsupported
  /// The selected model is being removed, so the next recording is frozen wordless
  /// however the switch is set. Transient, and the only cause here that resolves
  /// itself: it lasts as long as the removal drain.
  case modelBeingRemoved

  var hasWords: Bool { self == .available }
}

/// Which design the user has chosen for each capability state.
///
/// **Two selections, not one, because the two states are genuinely different
/// products.** Without words the choice is cosmetic; with words the pill has to
/// be able to hold them, which is why `resolve` may substitute.
struct PillDesignSelections: Equatable, Sendable {
  /// The design to use when the machine cannot show words as you speak.
  let withoutWords: RecordingPillDesign
  /// The design to use when it can.
  let withWords: RecordingPillDesign

  init(withoutWords: RecordingPillDesign, withWords: RecordingPillDesign) {
    self.withoutWords = withoutWords
    self.withWords = withWords
  }

  /// The pair the shipped code produces, and the FROZEN REFERENCE tests measure
  /// against.
  ///
  /// **Production no longer reads it** (#2376 Phase 4). The bootstrapper's
  /// selections closure is settings-backed, and this constant's job is to be the
  /// thing those defaults are asserted to equal — one production authority, one
  /// frozen reference, and a test saying they agree. It is kept rather than
  /// deleted because 22 test call sites across 8 files use it as the neutral pair
  /// for a director that is not about design selection.
  static let shipped = PillDesignSelections(withoutWords: .classic, withWords: .readingWell)

  /// The design substituted when the chosen one cannot hold the capability's
  /// content. Stated ONCE each rather than spelled at the branch that needs it.
  static let canonicalWithWords: RecordingPillDesign = .readingWell
  /// The design substituted when a with-words design is chosen for a pill that
  /// will show no words.
  static let canonicalWithoutWords: RecordingPillDesign = .classic

  /// Resolve the selection for a capability state, FAIL-CLOSED.
  ///
  /// **The fallback is a RETURNED VALUE rather than a promise.** An earlier
  /// draft of this design said a mismatch "is recorded", which named no owner, no
  /// event and no seam — a claim about observability that nothing would have made
  /// true. `DesignResolution` cannot lie about which of the two happened, and a
  /// caller may assert on it, log it, or ignore it.
  ///
  /// **What `substituted` CAUSES is nothing, and that is the decision rather than
  /// an omission** (#2376 Phase 4). Phase 3 recorded that Phase 4 introduces the
  /// first real producer and owns this call. It does: two independently persisted
  /// selections. But the picker cannot OFFER an incompatible design — it asks
  /// `PillCatalog.offers`, which is defined in terms of this very function — so a
  /// substitution is reachable only from a hand-edited plist or a downgrade. It
  /// stays a returned value with no logging and no telemetry, and its
  /// unreachability is asserted by the picker's cross-product rather than watched
  /// for at runtime.
  func resolve(capabilityHasWords: Bool) -> DesignResolution {
    let chosen = capabilityHasWords ? withWords : withoutWords
    // Written as `if`s rather than `guard`s, because the mismatches are the
    // EXCEPTIONAL cases and a guard whose success path is the exception reads
    // backwards to everyone after the author.
    if capabilityHasWords, !chosen.canHoldWords {
      // The capability can show words and the chosen design cannot hold them.
      // Substituting the canonical with-words design is the fail-closed answer:
      // the alternative is a pill that silently drops the feature it was enabled
      // for.
      return DesignResolution(design: Self.canonicalWithWords, substituted: true)
    }
    // **THE MIRROR DIRECTION, CLOSED IN #2376 C4, AND IT WAS NOT HYPOTHETICAL.**
    // Phase 3 guarded only the case above, so a with-words design sitting in the
    // without-words slot was accepted with `substituted: false` —
    // `RecordingDirectorCaptureTests` MEASURES that combination installing a live
    // display provider and resizing the window to 400x123 on a machine with no
    // preview: a wide empty panel with nothing to put in it.
    //
    // C6 introduces the first producer that can reach this — two independently
    // persisted selections, either of which a hand-edited plist or a downgrade
    // can cross — so the guard lands one chunk BEFORE the thing that can trip it
    // rather than one chunk after.
    if !capabilityHasWords, chosen.canHoldWords {
      return DesignResolution(design: Self.canonicalWithoutWords, substituted: true)
    }
    return DesignResolution(design: chosen, substituted: false)
  }
}

/// What `PillDesignSelections.resolve` decided, and whether it had to override.
struct DesignResolution: Equatable, Sendable {
  let design: RecordingPillDesign
  /// True when the group's selection could not hold the capability's content and
  /// the canonical default was substituted.
  let substituted: Bool
}

// MARK: - What ends up on screen

/// What a screen reader says when a presentation arrives, and how loudly.
///
/// **The priority is per-INTENT and was read off the shipped switch**, which
/// posts for all sixteen: nine at `.high` and seven at `.medium`. It is not
/// derivable from severity — `.recording` and `.engineReady` are high while
/// `.warning` is medium — so it is carried rather than computed.
struct OverlayAnnouncement: Equatable, Sendable {
  let text: String
  let isHighPriority: Bool

  /// `NSAccessibilityPriorityLevel` is an AppKit type and the reducer is
  /// deliberately free of AppKit, so the level is carried as the one bit that
  /// distinguishes the two values actually used and resolved at the post.
  static func high(_ text: String) -> OverlayAnnouncement {
    OverlayAnnouncement(text: text, isHighPriority: true)
  }

  static func medium(_ text: String) -> OverlayAnnouncement {
    OverlayAnnouncement(text: text, isHighPriority: false)
  }
}


/// How a presentation's width is decided. `.measured` means the render model
/// computes it; nothing may substitute a default for it.
enum OverlayWidth: Equatable, Sendable {
  case fixed(CGFloat)
  case measured
}

/// The one button a notice may carry.
///
/// **A struct rather than the tuple it replaces, because the button needs a
/// THIRD value and a tuple cannot grow one** (#2376 Phase 4, C3). The shipped
/// recovery pill spells its button's accessibility label as a bare literal
/// inside the view — "Discard recovering recording" — with no field behind it, so
/// nothing could read it, nothing could check it, and it was invisible to the
/// catalog that owns every other word on that pill. A tuple's third element would
/// have had to be restated positionally at every site; a struct names it once.
///
/// It is also what lets `NoticeModel`'s hand-written `==` shrink rather than
/// grow: the tuple is why that operator had to compare two members by hand.
struct NoticeAction: Equatable, Sendable {
  /// What is printed on the button.
  let label: String
  /// What a screen reader says instead, where the printed label is too terse to
  /// stand alone. `nil` means the label speaks for itself.
  let accessibilityLabel: String?
  /// What pressing it sends.
  let action: PillAction

  init(label: String, accessibilityLabel: String? = nil, action: PillAction) {
    self.label = label
    self.accessibilityLabel = accessibilityLabel
    self.action = action
  }

  /// What VoiceOver should read: the explicit label where one is given, and the
  /// printed one otherwise. Resolved HERE rather than at each leaf, so two leaves
  /// cannot answer it differently.
  var spokenLabel: String { accessibilityLabel ?? label }
}

/// The collapsed notice. Processing, clipboard fallback, warning, error,
/// advisory, interruption, caching, ready, recovery-success, the accessibility
/// toast and import status are all THIS — a sentence, a visual severity, and
/// optionally one button. They are separate `transitionTo*` methods today for
/// no reason that survives inspection: each differs only in its words, its icon
/// and its dwell.
struct NoticeModel: Equatable, Sendable {

  /// **Which leaf view renders this notice.**
  ///
  /// Collapsing eleven `transitionTo*` methods into one MODEL does not collapse
  /// their appearance, and this is the obligation recorded when the model was
  /// first written: a sentence, a severity and a dwell do not say whether to
  /// draw a spinner, a spectrum wheel or a warning triangle. Named here rather
  /// than inferred from the text, because inferring a visual from a string is
  /// how a copy edit silently changes an icon.
  enum Kind: Equatable, Sendable {
    /// `PolishingOverlayView` — the spectrum wheel with a label.
    case processing
    /// `ColdStartNoticeView` with its spinner.
    case warmingUp
    /// `ColdStartNoticeView` with its ready mark.
    case ready
    /// `NotificationOverlayView`, whose own style carries the icon and colour.
    case notification
    /// `ImportStatusOverlayView`.
    case importStatus
    /// `RecoveryNoticeView`, which offers Discard.
    case recovery
    /// `AccessibilityToastView`, which offers Grant.
    case accessibilityToast
  }

  enum Severity: Equatable, Sendable {
    case neutral
    case warning
    case error
    /// Red pulsing lips — the interruption look.
    case distress
    /// #1891. Deliberately NOT `.error`: a user-setup advisory is not our
    /// software failing, and `.error`'s red mark, 3-second dwell and "Error"
    /// heading would all say it was. Its own case rather than
    /// `neutral + isMultiline`, because the shipped `NotificationStyle` has four
    /// styles and inferring one from a layout flag is how a wrapping change
    /// silently repaints a pill.
    case advisory
  }

  let kind: Kind
  let text: String
  let secondaryText: String?
  /// What VoiceOver reads for the pill AS A WHOLE, where that is deliberately
  /// different from what is printed on it.
  ///
  /// **Required rather than tidy, and exactly one pill needs it.**
  /// `DictationNarrator.recoveryAccessibilityLabel` is pinned as deliberately
  /// DIFFERENT from `recoveryTitle` — the title carries an ellipsis and the
  /// spoken label does not — so folding it into `text` would ship an ellipsis
  /// into VoiceOver and break a test that exists to keep them apart. `nil` means
  /// the pill's own contents are what a screen reader should compose.
  let accessibilityLabel: String?
  let severity: Severity
  /// A notice long enough to need wrapping renders multiline with a
  /// content-driven height. `.advisory` is the shipped case and its dwell is
  /// deliberately long enough to read (#1891).
  ///
  /// **Read by `NotificationOverlayView`, which is the leaf whose wrapping it
  /// decides** (#2376 Phase 4, C3). That leaf used to re-derive the same fact
  /// from its own style table as `self == .advisory`, so one pill's wrapping was
  /// stated twice and the model's copy was the one nobody read; the style's copy
  /// is deleted and this is the survivor.
  ///
  /// `.importStatus` also sets it, and its leaf pins a two-line CAP of its own.
  /// Those are not the same question — this says the text wraps rather than being
  /// clipped to one line, and the cap says how far — so the row is accurate and
  /// the leaf is not duplicating it.
  let isMultiline: Bool
  let action: NoticeAction?

  static func == (a: NoticeModel, b: NoticeModel) -> Bool {
    a.kind == b.kind && a.text == b.text && a.secondaryText == b.secondaryText
      && a.accessibilityLabel == b.accessibilityLabel
      && a.severity == b.severity
      && a.isMultiline == b.isMultiline && a.action == b.action
  }

  init(
    kind: Kind, text: String, secondaryText: String? = nil, accessibilityLabel: String? = nil,
    severity: Severity = .neutral,
    isMultiline: Bool = false, action: NoticeAction? = nil
  ) {
    self.kind = kind
    self.text = text
    self.secondaryText = secondaryText
    self.accessibilityLabel = accessibilityLabel
    self.severity = severity
    self.isMultiline = isMultiline
    self.action = action
  }
}

/// What the retained hosting view renders. One of these occupies the slot at a
/// time; there is no second slot and no parallel channel.
enum OverlayContent: Equatable, Sendable {
  /// **`audioLevel` is a SNAPSHOT and the shipped path is a PULL.**
  /// `show(intent:audioLevelProvider:recordingElapsedProvider:isRecordingLocked:)`
  /// (`05411427:Sources/EnviousWisprAppKit/App/RecordingOverlayPanel.swift`) hands the panel two CLOSURES that
  /// the view calls per frame, plus the initial lock. The reducer models the
  /// lock (persistent, in `OverlayState`) and carries a level snapshot, but it
  /// deliberately does NOT own per-frame providers — a value type invoked from a
  /// render loop is the wrong home for them.
  ///
  /// **Obligation for the chunk that adds the render model, recorded rather
  /// than left implicit:** it must retain BOTH the audio-level and the recording-elapsed provider for the
  /// rendered recording's lifetime. `recordingElapsedProvider` has no
  /// representation in this vocabulary at all and must not be forgotten because nothing
  /// here names it — which is precisely why it is named here.
  /// **The resolved design rides HERE, on the one content case that has one.**
  /// Putting it on `PillDefinition` instead would let a notice carry a recording
  /// design — representable, meaningless, and eventually read by accident. Here
  /// the illegal state cannot be constructed.
  ///
  /// It also makes morph preservation a COMPILER obligation rather than a test
  /// one: every same-id reconstruction has to bind and pass it, so a morph that
  /// drops the design fails to build instead of silently dropping the pill back
  /// to the other design's geometry mid-recording.
  case recording(
    audioLevel: Float, isLocked: Bool, notice: InPanelNotice?, design: RecordingPillDesign)
  case notice(NoticeModel)
  case languageChip(payload: LanguageChipPayload)
  case bluetoothAwareness
  case escapeRecovery(transcriptID: UUID)
}

/// The in-panel notice that morphs a LIVE recording pill without replacing it.
///
/// It is modelled as part of `recording` rather than as its own presentation
/// because that is what it is: the shipped `OverlayNoticeState` exists as a
/// parallel channel purely so a notice can change the pill "WITHOUT tearing the
/// panel down", which was only ever necessary because every other change DID
/// tear it down. Once the panel is retained, the parallel channel has no reason
/// to exist and this is a field on the presentation that owns it.
struct InPanelNotice: Equatable, Sendable {
  let reason: RecordingNoticeReason
  let dismissAfter: Double?
}

/// One occupancy of the overlay slot: what to show, how it is identified, and
/// when it goes away. The director never holds a per-kind field collection —
/// this value IS the state.
struct PillDefinition: Equatable, Sendable {
  let id: PresentationID
  let content: OverlayContent

  /// The resolved recording design, or nil for every pill that is not a
  /// recording.
  ///
  /// **This is the authority initial host sizing reads.** Before #2375 the
  /// reducer emitted one geometry and `OverlayDirector.geometry(for:)`
  /// substituted another for the preview case, so two values described one pill
  /// and the reducer's was ignored. There is now one, and it is this.
  var recordingDesign: RecordingPillDesign? {
    guard case .recording(_, _, _, let design) = content else { return nil }
    return design
  }
  let expiry: OverlayExpiry
  /// How the presentation's width is decided.
  ///
  /// **Two rounds of review were needed to get this shape right, and the reason
  /// generalises: a literal that the shipped code IGNORES looks exactly like a
  /// literal it uses.** Round 1 carried a number for every kind. Round 2 made
  /// the field optional with Escape Recovery as the only `nil`. Both were wrong
  /// in the same direction — `showPanel(fitToContent:)` sizes the panel from the
  /// view's own `fittingSize` and DISCARDS the `width` argument entirely
  /// (`05411427:Sources/EnviousWisprAppKit/App/RecordingOverlayPanel.swift`), so any row whose view does not
  /// pin its own width is measured no matter what number sits at the call site.
  ///
  /// The test is not "did the call site pass a width" but **"does the VIEW pin
  /// one"**:
  /// - `PolishingOverlayView` pins nothing → processing and clipboard fallback
  ///   are `.measured`, and their `230` is dead at the call site.
  /// - `ImportStatusOverlayView` uses `.frame(maxWidth: 280)` → `.measured`; a
  ///   max is a bound, not a width.
  /// - `BluetoothAwarenessCardView` has `.frame(width: 320)` of its own
  ///   → `.fixed(320)` even though the call passes
  ///   `fitToContent: true`.
  /// - Escape Recovery's `PillMetrics.pillWidth` is computed from the title
  ///   font's text metrics at runtime → `.measured`, and no literal is correct.
  let requestedWidth: OverlayWidth
  /// True when this presentation must reserve a fixed interaction frame rather
  /// than shrink to its content. **Only the non-preview recording pill sets
  /// this**, and its 92-point frame is deliberate: it reserves room for the
  /// lock state and for in-panel notice expansion (#1060). Everything else is
  /// content-sized. This migration does not make every kind content-sized, and
  /// it does not make every kind fixed.
  let reservesFixedHeight: CGFloat?

  init(
    id: PresentationID, content: OverlayContent, expiry: OverlayExpiry,
    requestedWidth: OverlayWidth, reservesFixedHeight: CGFloat? = nil
  ) {
    self.id = id
    self.content = content
    self.expiry = expiry
    self.requestedWidth = requestedWidth
    self.reservesFixedHeight = reservesFixedHeight
  }
}
