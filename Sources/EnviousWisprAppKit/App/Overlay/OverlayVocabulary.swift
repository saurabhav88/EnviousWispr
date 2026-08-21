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
enum OverlayAction: Equatable, Sendable {
  case grantAccessibility
  case discardRecovery
  case pasteEscapeRecovery
  case lockLanguage
  case dismissChip
  case openLanguageSettings
  case dismissBluetoothAwareness
  case openBluetoothSettings
}

// MARK: - What ends up on screen

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
  enum Severity: Equatable, Sendable {
    case neutral
    case warning
    case error
    /// Red pulsing lips — the interruption look.
    case distress
  }

  let text: String
  let secondaryText: String?
  let severity: Severity
  /// A notice long enough to need wrapping renders multiline with a
  /// content-driven height. `.advisory` is the shipped case and its dwell is
  /// deliberately long enough to read (#1891).
  let isMultiline: Bool
  let action: (label: String, action: OverlayAction)?

  static func == (a: NoticeModel, b: NoticeModel) -> Bool {
    a.text == b.text && a.secondaryText == b.secondaryText && a.severity == b.severity
      && a.isMultiline == b.isMultiline && a.action?.label == b.action?.label
      && a.action?.action == b.action?.action
  }

  init(
    text: String, secondaryText: String? = nil, severity: Severity = .neutral,
    isMultiline: Bool = false, action: (label: String, action: OverlayAction)? = nil
  ) {
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
  /// (`RecordingOverlayPanel.swift:1430-1435`), so any row whose view does not
  /// pin its own width is measured no matter what number sits at the call site.
  ///
  /// The test is not "did the call site pass a width" but **"does the VIEW pin
  /// one"**:
  /// - `PolishingOverlayView` pins nothing → processing and clipboard fallback
  ///   are `.measured`, and their `230` is dead at the call site.
  /// - `ImportStatusOverlayView` uses `.frame(maxWidth: 280)` → `.measured`; a
  ///   max is a bound, not a width.
  /// - `BluetoothAwarenessCardView` has `.frame(width: 320)` of its own
  ///   (`:58`, `:119`) → `.fixed(320)` even though the call passes
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
