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
/// `generation` counter, `noticeDismissWork`, `pendingCreateWork`,
/// `autoDismissTask`, the drag-retry work item, two view-owned dismiss tasks,
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

// MARK: - Screens and geometry

/// A screen's stable identity, so placement can say "the same screen" without
/// holding an `NSScreen` and without AppKit being present in a test.
struct ScreenID: Hashable, Sendable {
  let rawValue: Int
  init(rawValue: Int) { self.rawValue = rawValue }
}

/// Everything placement needs to know about a screen. A value, so the geometry
/// rules are exercisable against invented screens — including the ones that are
/// awkward to obtain on the dev machine, such as a display whose `visibleFrame`
/// is inset by a notch or by a full-screen space.
struct ScreenGeometry: Equatable, Sendable {
  let id: ScreenID
  /// Full display bounds.
  let frame: CGRect
  /// Bounds excluding menu bar and Dock.
  let visibleFrame: CGRect
  /// True when the screen currently shows a full-screen space, which is the
  /// condition the Bottom rule keys off.
  let hasFullScreenSpace: Bool

  init(id: ScreenID, frame: CGRect, visibleFrame: CGRect, hasFullScreenSpace: Bool = false) {
    self.id = id
    self.frame = frame
    self.visibleFrame = visibleFrame
    self.hasFullScreenSpace = hasFullScreenSpace
  }
}

/// Whether a presentation is arriving into an empty slot or replacing a live one.
///
/// **`continuing` carries the COMPLETE current frame, both axes.** That is the
/// whole of the #2195 fix: the shipped path inherits only `y` and always
/// recentres `x`, so a pill the user dragged horizontally jumps back to centre
/// the moment its content changes. A single value carrying the whole rect makes
/// the half-inheritance unrepresentable rather than merely discouraged.
enum OverlayContinuity: Equatable, Sendable {
  case fresh(position: OverlayPillPosition, screen: ScreenID)
  /// `outgoingWasContentSized` is required, not optional: the shipped Top rule
  /// re-anchors a content-sized outgoing panel by its TOP edge and a
  /// fixed-frame one by its CENTRE, and getting that wrong moves the pill
  /// vertically on an ordinary recording-to-polishing hand-off.
  case continuing(
    currentFrame: CGRect, anchoredScreen: ScreenID, outgoingWasContentSized: Bool)
}

// MARK: - Feature requests and actions

/// A request from a FEATURE — something that is not the dictation pipeline.
///
/// The pipeline speaks `OverlayIntent`; features speak this. Keeping them as
/// two types is what lets the reducer state the arbitration rule as a fact about
/// types rather than as a convention: a feature may occupy the slot only while
/// the pipeline is idle. Today that rule is spelled out separately at every
/// feature — `importStatusOwnsCurrentSlot` reads
/// `currentIntent == .hidden && …`, Bluetooth keeps its own `isPresented`
/// flag, and the passive chip keeps a generation counter — and nothing holds
/// them to the same answer.
enum OverlayRequest: Equatable, Sendable {
  case importStatus(message: String)
  case bluetoothAwareness
  case passiveChip(payload: LanguageChipPayload)
  case accessibilityToast
}

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
/// (`RecordingOverlayPanel.swift`); each row below names the field it
/// replaces.
enum OverlayAction: Equatable, Sendable {
  /// `grantHandler`.
  case grantAccessibility
  /// `discardRecoveryHandler`.
  case discardRecovery
  /// `onEscapeRecoveryPaste`, which takes the `CancelUndoPayload`.
  ///
  /// **Carries the transcript id, and the first version did not.** The panel
  /// holds the payload itself and looks it up with
  /// `takeEscapeRecoveryPayload(matching:)` — a one-shot take, so the
  /// id is what makes the hand-off safe against a stale press. A bare case
  /// would have delivered "the user pressed Undo" with nothing to undo.
  case pasteEscapeRecovery(transcriptID: UUID)
  /// `passiveChipLockHandler`.
  case lockLanguage
  /// `passiveChipDismissHandler`.
  case dismissChip
  /// `bluetoothAwarenessGotItHandler`.
  ///
  /// **Distinct from `closeBluetoothAwareness`, and collapsing them lost real
  /// telemetry.** `BluetoothAwarenessPresenter` emits `.dismissed/.gotIt` versus
  /// `.dismissed/.closed`: acknowledging the card and closing it
  /// are different user answers and the dashboard reads them apart.
  case acknowledgeBluetoothAwareness
  /// `bluetoothAwarenessCloseHandler`.
  case closeBluetoothAwareness
  /// `bluetoothAwarenessAdjustSettingsHandler`.
  case openBluetoothSettings
}

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
enum OverlayEffect: Equatable, Sendable {
  /// `passiveChipAutoDismissHandler`, which takes the generation.
  case languageChipAutoDismissed(generation: UInt64)
  /// The escape-recovery pill went away without the user pressing Undo, so the
  /// owner must drop the payload it is holding.
  case escapeRecoveryExpired(transcriptID: UUID)
  /// `setRecordingIntentObserver`. Fires when the recording pill
  /// arrives or leaves. Nothing in the first model expressed it at all.
  case recordingIntentChanged(Bool)
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

/// How the recording pill is composed, which is FIVE decisions and not one.
///
/// The shipped site takes them together from a single `showsPreview` read, and
/// porting them one at a time is how four of them went missing: the pill was
/// carrying the compact width at the preview's content height, with no frame, no
/// alignment, and the preview's own providers live in a pill that does not show a
/// preview. They travel together here so a caller cannot install half of them.
///
/// - **width** 400 with preview, 185 without.
/// - **height** content-driven with preview so the pill earns its size a line at
///   a time; a reserved 92 without, which holds the normal 185x44, the locked
///   120x64 and the #1060 notice expansion without resizing on every morph.
/// - **alignment** #1341. In Bottom position the compact content is BOTTOM-
///   aligned so the panel's Y origin is the capsule's visible bottom edge.
///   Centred, the 92-point frame leaves ~24 points of invisible space below a
///   ~44-point capsule, which mutes the Bottom offset and visibly misaligns the
///   polishing pill that replaces it. Top keeps centring.
/// - **the preview display provider**, which the shipped site replaces with
///   `{ .off }` when preview is off rather than passing the live one.
/// - **the content-height callback**, likewise `{ _ in }` when preview is off.
enum OverlayRecordingLayout: Equatable, Sendable {
  case compact(position: OverlayPillPosition)
  case preview(position: OverlayPillPosition)

  var usesPreview: Bool {
    if case .preview = self { return true }
    return false
  }

  var position: OverlayPillPosition {
    switch self {
    case .compact(let position), .preview(let position): return position
    }
  }

  /// `RecordingOverlayPanel`: `showsPreview ? previewPillWidth : 185`.
  var width: CGFloat {
    switch self {
    case .compact: return 185
    case .preview: return 400
    }
  }

  /// nil means content-sized, which is `fitToContent: true` at the shipped site.
  var fixedHeight: CGFloat? {
    switch self {
    case .compact: return 92
    case .preview: return nil
    }
  }
}

/// How a presentation's width is decided. `.measured` means the render model
/// computes it; nothing may substitute a default for it.
enum OverlayWidth: Equatable, Sendable {
  case fixed(CGFloat)
  case measured
}

/// How long a presentation lives without further input.
enum OverlayExpiry: Equatable, Sendable {
  /// Stays until something replaces it. Recording and processing are persistent.
  case untilReplaced
  /// Dismisses itself after an interval, unless the user is hovering it.
  case after(seconds: Double, pausesOnHover: Bool)

  static func after(seconds: Double) -> OverlayExpiry {
    .after(seconds: seconds, pausesOnHover: false)
  }
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
  let action: (label: String, action: OverlayAction)?

  static func == (a: NoticeModel, b: NoticeModel) -> Bool {
    a.kind == b.kind && a.text == b.text && a.secondaryText == b.secondaryText
      && a.severity == b.severity
      && a.isMultiline == b.isMultiline && a.action?.label == b.action?.label
      && a.action?.action == b.action?.action
  }

  init(
    kind: Kind, text: String, secondaryText: String? = nil, severity: Severity = .neutral,
    isMultiline: Bool = false, action: (label: String, action: OverlayAction)? = nil
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
  /// (`RecordingOverlayPanel.swift`) hands the panel two CLOSURES that
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
  case recording(audioLevel: Float, isLocked: Bool, notice: InPanelNotice?)
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
struct OverlayPresentation: Equatable, Sendable {
  let id: PresentationID
  let content: OverlayContent
  let expiry: OverlayExpiry
  /// How the presentation's width is decided.
  ///
  /// **Two rounds of review were needed to get this shape right, and the reason
  /// generalises: a literal that the shipped code IGNORES looks exactly like a
  /// literal it uses.** Round 1 carried a number for every kind. Round 2 made
  /// the field optional with Escape Recovery as the only `nil`. Both were wrong
  /// in the same direction — `showPanel(fitToContent:)` sizes the panel from the
  /// view's own `fittingSize` and DISCARDS the `width` argument entirely
  /// (`RecordingOverlayPanel.swift`), so any row whose view does not
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
