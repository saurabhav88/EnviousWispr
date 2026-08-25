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

/// Which recording pill the user gets (#2375 Phase 3, chunk C3a).
///
/// **A DESIGN, not a capability.** Whether the machine can show words as you
/// speak is a capability the director reads; which pill is drawn is a choice.
/// Until Phase 4 the two are locked together by a constant, and separating the
/// vocabulary now is what lets Phase 4 change one without touching the other.
///
/// **`.readingWell`, deliberately not `.livePreview`.** Naming a design after
/// the capability that enables it makes the settings group label and the card
/// label the same word, and forecloses a second with-words design before one
/// exists. The capability keeps its own name.
enum RecordingPillDesign: Equatable, Sendable, CaseIterable {
  /// The rainbow-lips capsule: a fixed 185x92 interaction frame that holds the
  /// normal capsule, the locked state and the #1060 notice expansion without
  /// resizing on every morph.
  case classic
  /// The wide panel that shows words as you speak. Content-sized from the first
  /// frame so it does not visibly snap as lines wrap.
  case readingWell

  /// Whether this design can display transcribed words while recording.
  ///
  /// **This is the authority for provider gating, and since C3b it is the only
  /// one.** The consumers key directly off `canHoldWords`. Before that the
  /// shipped code keyed off a layout value that also carried geometry and
  /// position, which is why one authority could disagree with another about what
  /// is on screen; C3a derived that value from this one and C3b deleted it.
  var canHoldWords: Bool {
    switch self {
    case .classic: return false
    case .readingWell: return true
    }
  }

  /// The width the window is sized to. Measured from
  /// `RecordingOverlayPanel`: `showsPreview ? previewPillWidth : 185`.
  var width: CGFloat {
    switch self {
    case .classic: return 185
    case .readingWell: return 400
    }
  }

  /// `nil` means content-sized, which is `fitToContent: true` at the shipped
  /// site. The classic pill reserves a fixed box; the reading well does not.
  var reservedHeight: CGFloat? {
    switch self {
    case .classic: return 92
    case .readingWell: return nil
    }
  }
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

  /// The pair the shipped code produces, and what Phase 3 injects everywhere.
  ///
  /// Phase 4 replaces the CLOSURE that returns this, never this constant's
  /// meaning — it is the current behaviour written down, so a Phase 4 regression
  /// is measurable against it.
  static let shipped = PillDesignSelections(withoutWords: .classic, withWords: .readingWell)

  /// Resolve the selection for a capability state, FAIL-CLOSED.
  ///
  /// **The fallback is a RETURNED VALUE rather than a promise.** An earlier
  /// draft of this design said a mismatch "is recorded", which named no owner, no
  /// event and no seam — a claim about observability that nothing would have made
  /// true. `DesignResolution` cannot lie about which of the two happened, and a
  /// caller may assert on it, log it, or ignore it.
  ///
  /// **No production caller can produce a mismatch this phase**, because
  /// selections are constructed from `shipped`. That branch is covered by unit
  /// tests only and ships no logging, telemetry or composition wiring. Phase 4
  /// introduces the first real producer of an incompatible value and owns the
  /// decision about what `substituted` should then cause.
  func resolve(capabilityHasWords: Bool) -> DesignResolution {
    let chosen = capabilityHasWords ? withWords : withoutWords
    // Written as an `if` rather than a `guard`, because the mismatch is the
    // EXCEPTIONAL case and a guard whose success path is the exception reads
    // backwards to everyone after the author.
    if capabilityHasWords, !chosen.canHoldWords {
      // The capability can show words and the chosen design cannot hold them.
      // Substituting the canonical with-words design is the fail-closed answer:
      // the alternative is a pill that silently drops the feature it was enabled
      // for.
      return DesignResolution(design: .readingWell, substituted: true)
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
  let severity: Severity
  /// A notice long enough to need wrapping renders multiline with a
  /// content-driven height. `.advisory` is the shipped case and its dwell is
  /// deliberately long enough to read (#1891).
  let isMultiline: Bool
  let action: (label: String, action: PillAction)?

  static func == (a: NoticeModel, b: NoticeModel) -> Bool {
    a.kind == b.kind && a.text == b.text && a.secondaryText == b.secondaryText
      && a.severity == b.severity
      && a.isMultiline == b.isMultiline && a.action?.label == b.action?.label
      && a.action?.action == b.action?.action
  }

  init(
    kind: Kind, text: String, secondaryText: String? = nil, severity: Severity = .neutral,
    isMultiline: Bool = false, action: (label: String, action: PillAction)? = nil
  ) {
    self.kind = kind
    self.text = text
    self.secondaryText = secondaryText
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
