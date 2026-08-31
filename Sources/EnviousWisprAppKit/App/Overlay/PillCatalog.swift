import CoreGraphics
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// The sole authority on what a pill IS: given a request and an identity, the
/// definition that occupies the slot and the sentence a screen reader speaks.
///
/// **AppKit-free and stateless, deliberately.** Everything here is a pure
/// function of its arguments, so the whole catalog is testable with no
/// windowing, no clock and no director present — the same property
/// `OverlayReducer` has and for the same reason.
///
/// **What it does NOT own, and the boundary is the point.** Admission,
/// arbitration, identity, staleness and the five same-id morphs stay on the
/// reducer: those are functions of `OverlayState`, not of a request. Geometry
/// overrides and capability stay on the director. This type answers one
/// question — what does this request look like and what does it say.
///
/// **Every value below was MEASURED at its shipped call site**, and was moved
/// here byte for byte rather than retyped. The comments citing those sites moved
/// with them, so the next reader can re-check rather than trust a summary. An
/// earlier port of this same table wrote it from the design instead and got
/// eleven of fifteen widths and six dwells wrong.
enum PillCatalogRequest: Equatable, Sendable {
  /// **The design rides on THIS case and no other.** A `design:` parameter on
  /// `entry` would force every import, Bluetooth, notice, language, recovery and
  /// `.hidden` lookup to supply a recording design that means nothing to them —
  /// an argument whose only correct value is "ignore me", which is the shape that
  /// later gets read by accident. Here the illegal call is unrepresentable.
  case recording(audioLevel: Float, design: RecordingPillDesign)
  case hidden
  case processing(phase: ProcessingPhase)
  case clipboardFallback
  case accessibilityToast
  case warning(reason: RecordingWarningReason)
  case error(reason: TerminalNoticeReason)
  case advisory(reason: TerminalAdvisoryReason)
  case interruption(reason: TerminalNoticeReason)
  case passiveChip(payload: LanguageChipPayload)
  case cachingModel(engineLabel: String)
  case engineReady
  case recoveringLastRecording
  case recoverySucceeded
  case bluetoothAwareness
  case escapeRecovery(transcriptID: UUID)

  /// The one request with no matching `OverlayIntent`. It is minted by a feature
  /// path rather than by the pipeline, which is why it announces nothing.
  case importStatus(message: String)

  // **SEVENTEEN cases: `.recording` plus sixteen non-recording.** C2 staged
  // `.recording` out because the catalog's recording arm needs a RESOLVED design
  // and no production caller could supply one before the recording transaction
  // existed. C3a builds that transaction, so the arm and its first caller land
  // together — no chunk ever contained an unimplemented case or a placeholder
  // design.
  //
  // **The non-recording count is sixteen, not seventeen, and the difference is
  // G2 itself.**
  // `bluetoothAwareness` is a pipeline intent AND is minted a second time by
  // `reduceBluetoothAwareness`; those are two ROUTES to one VALUE, not two
  // requests. C0 froze both routes as separate rows and they are identical field
  // for field, which is the measurement that settles it. A seventeenth
  // non-recording case here could only be a second Bluetooth arm — G2's
  // duplicate, reappearing inside the type built to remove it.
}

/// What one request resolves to.
///
/// **An ENTRY rather than a definition, because `.hidden` has neither.** It
/// empties the slot and still says "Recording complete", so a definition-only
/// return could not carry it — and `announcement(for:)` would have had to stay a
/// SECOND intent-to-value mapping on the reducer, which would make this type's
/// central claim false.
struct PillCatalogEntry: Equatable, Sendable {
  /// `nil` empties the slot.
  let definition: PillDefinition?
  /// `nil` says nothing. Only import status is silent.
  let announcement: OverlayAnnouncement?
}

enum PillCatalog {

  // MARK: - Which designs may be offered

  /// Whether a design may be OFFERED for a capability state (#2376 Phase 4, C4).
  ///
  /// **Defined in terms of `resolve`, and that definition IS the anti-drift
  /// mechanism.** A design the picker greys out is exactly a design `resolve`
  /// would substitute, so the two cannot disagree without `resolve` disagreeing
  /// with itself. The plan names catalog-versus-Settings drift as the risk to
  /// watch, and a parallel `allCases.filter { $0.canHoldWords == x }` would be a
  /// second derivation of the same rule even while it happened to agree.
  static func offers(_ design: RecordingPillDesign, capabilityHasWords: Bool) -> Bool {
    PillDesignSelections(withoutWords: design, withWords: design)
      .resolve(capabilityHasWords: capabilityHasWords)
      .substituted == false
  }

  /// The designs in one compatibility group, for the picker's ORDER only.
  ///
  /// **Every enabled-or-greyed decision goes through `offers`, never through
  /// this.** Grouping is presentation; offerability is policy, and keeping them
  /// separate is what stops the group list quietly becoming a second answer.
  static func designs(holdingWords: Bool) -> [RecordingPillDesign] {
    RecordingPillDesign.allCases.filter { $0.canHoldWords == holdingWords }
  }

  /// The one entry point.
  static func entry(for request: PillCatalogRequest, id: PresentationID) -> PillCatalogEntry {
    PillCatalogEntry(
      definition: definition(for: request, id: id),
      announcement: announcement(for: request))
  }

  /// The announcement alone, for the ONE caller that needs it before it has an
  /// identity to spend.
  ///
  /// **This is not a second entry point and must not be folded into `entry`.**
  /// The reducer decides whether to announce BEFORE its dedup guard and before
  /// the same-id morph path, and only allocates an id further down. Calling
  /// `entry` at the earlier site would burn a `PresentationID` on two paths that
  /// consume none today — invisible in production, where ids are UUIDs, and
  /// immediately wrong for every test that injects a deterministic id factory to
  /// assert on identity. There is still exactly one implementation: `entry`
  /// calls this.
  static func announcement(for request: PillCatalogRequest) -> OverlayAnnouncement? {
    guard let intent = request.matchingIntent else {
      // **Import status announces NOTHING, and that is preserved rather than
      // omitted.** It is the one presentation with no matching `OverlayIntent`,
      // so the shipped switch had no arm for it. A sentence here would be
      // inventing a notice.
      return nil
    }
    return announcement(for: intent)
  }

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

  // MARK: - The shipped table

  /// The shipped widths and dwells, gathered.
  ///
  /// **Every value here was MEASURED at its shipped call site, and the first
  /// version of this table was not.** It was written from the design and
  /// described in the commit as "carried over", which was false: eleven of the
  /// fifteen widths and six of the dwells were wrong. Cloud review caught it by
  /// opening the panel and reading them. The sites are cited per row so the next
  /// reader can re-check rather than trust this sentence.
  private static func definition(for request: PillCatalogRequest, id: PresentationID)
    -> PillDefinition?
  {
    switch request {

    case .hidden:
      return nil

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
        action: NoticeAction(label: "Grant", action: .grantAccessibility))

    case .warning(let reason):
      return notice(
        id: id, kind: .notification, text: DictationNarrator.copy(for: reason),
        // A single-line notification is NOT `fitToContent`, so it takes
        // `showPanel`'s own `height: 44` default and keeps the 280x44 box.
        width: .fixed(280), fixedHeight: 44,
        expiry: .after(seconds: 2.5), severity: .warning)  // NotificationStyle 2.5

    case .error(let reason):
      // #2549: `.permissionDenied` gets a wider, content-sized box (no
      // `fixedHeight` — see `notice`'s doc comment: omitting it is what makes
      // `showPanel` call `fitToContent: true`) plus a button to the
      // Microphone settings pane, because the fixed 280×44 single-line box
      // truncated "Microphone access is off." mid-word. Every other `.error`
      // reason keeps the original fixed box unchanged — those sentences are
      // short and this is the one that was actually broken.
      if reason == .permissionDenied {
        return notice(
          id: id, kind: .notification, text: DictationNarrator.copy(for: reason),
          width: .fixed(320),
          expiry: .after(seconds: 6), severity: .error, isMultiline: true,
          action: NoticeAction(label: "Open Settings", action: .openMicrophoneSettings))
      }
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
        // **The 8 seconds is READING TIME, and the reason moved here from the
        // dead table it used to live in** (#2376 C3). `NotificationStyle`
        // carried an `autoDismissSeconds` table with no reader at all, and its
        // #1891 note is the only place this number was ever justified: the
        // advisory sentence is ~23 words, which at roughly 200 wpm needs about
        // seven seconds to read, so the 3-second error dwell would show a
        // message the user physically cannot finish.
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
        // Deliberately NOT the title. The spoken label drops the title's
        // ellipsis, and `DictationNarratorTests` pins the two as different
        // strings — the leaf used to read this constant itself, which is the
        // duplication this chunk removes.
        accessibilityLabel: DictationNarrator.recoveryAccessibilityLabel,
        width: .fixed(320), fixedHeight: 56,  // :530
        // that site gives it a 6-second dwell. The first version said `.untilReplaced`,
        // which would have left the recovery pill on screen forever.
        expiry: .after(seconds: 6), isMultiline: true,
        action: NoticeAction(
          label: "Discard",
          // The button's own spoken label, which the leaf used to spell as a bare
          // literal with no model field behind it. "Discard" alone is ambiguous
          // out of context; this says what is being discarded.
          accessibilityLabel: "Discard recovering recording",
          action: .discardRecovery))

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

    case .recording(let level, let design):
      // Moved from `OverlayReducer.presentation(for:id:)` in C3a with its own
      // comment, which is repaired rather than carried: the reducer's version
      // said the 92 was "the NON-preview answer" and that the DIRECTOR overrode
      // it to content-sized when preview was on. That was true and was the whole
      // of G3 — two authorities for one geometry, one of them ignored. There is
      // now one. The definition carries the RESOLVED design's own width and
      // height, so nothing downstream has anything left to override.
      //
      // The values are unchanged: classic is 185 wide with a fixed 92-point
      // interaction frame that holds the normal capsule, the locked state and the
      // #1060 notice expansion without resizing on every morph; the reading well
      // is 400 wide and content-sized from the first frame so it does not visibly
      // snap. Both are properties of `RecordingPillDesign`, measured at the sites
      // its own doc comments cite.
      return PillDefinition(
        id: id,
        content: .recording(audioLevel: level, isLocked: false, notice: nil, design: design),
        expiry: .untilReplaced, requestedWidth: .fixed(design.width),
        reservesFixedHeight: design.reservedHeight)

    case .importStatus(let message):
      // Lifted from `reduceImportStatus`, where it was minted inline. The
      // ADMISSION rule around it — that a status pill may only replace itself —
      // stays on the reducer, because admission is a function of `OverlayState`
      // and not of this value.
      return PillDefinition(
        id: id,
        content: .notice(NoticeModel(kind: .importStatus, text: message, isMultiline: true)),
        // `ImportStatusOverlayView` uses `.frame(maxWidth: 280)` — a BOUND, not a
        // width — under `fitToContent`, so this is measured too.
        expiry: .after(seconds: 3), requestedWidth: .measured)  // :1105, :1148

    }
  }

  // MARK: - Shared shape

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
  private static func notice(
    id: PresentationID, kind: NoticeModel.Kind, text: String, secondary: String? = nil,
    accessibilityLabel: String? = nil,
    width: OverlayWidth, fixedHeight: CGFloat? = nil,
    expiry: OverlayExpiry = .untilReplaced, severity: NoticeModel.Severity = .neutral,
    isMultiline: Bool = false, action: NoticeAction? = nil
  ) -> PillDefinition {
    PillDefinition(
      id: id,
      content: .notice(
        NoticeModel(
          kind: kind, text: text, secondaryText: secondary,
          accessibilityLabel: accessibilityLabel, severity: severity,
          isMultiline: isMultiline, action: action)),
      expiry: expiry, requestedWidth: width, reservesFixedHeight: fixedHeight)
  }
}

/// The pipeline intent a request mirrors, where one exists.
///
/// **This and `PillCatalogRequest(pipeline:)` are one bijection written twice,
/// which is a duplicate-authority risk and is therefore CHECKED rather than
/// intended.** `PillCatalogRoundTripTests` walks every `OverlayIntent` arm and
/// every `PillCatalogRequest` case and requires both directions to agree, so a
/// case added to one side and forgotten on the other fails a test rather than
/// silently resolving to the wrong pill.
extension PillCatalogRequest {
  var matchingIntent: OverlayIntent? {
    switch self {
    case .recording(let level, _): return .recording(audioLevel: level)
    case .hidden: return .hidden
    case .processing(let phase): return .processing(phase: phase)
    case .clipboardFallback: return .clipboardFallback
    case .accessibilityToast: return .accessibilityToast
    case .warning(let reason): return .warning(reason: reason)
    case .error(let reason): return .error(reason: reason)
    case .advisory(let reason): return .advisory(reason: reason)
    case .interruption(let reason): return .interruption(reason: reason)
    case .passiveChip(let payload): return .passiveChip(payload: payload)
    case .cachingModel(let engineLabel): return .cachingModel(engineLabel: engineLabel)
    case .engineReady: return .engineReady
    case .recoveringLastRecording: return .recoveringLastRecording
    case .recoverySucceeded: return .recoverySucceeded
    case .bluetoothAwareness: return .bluetoothAwareness
    case .escapeRecovery(let transcriptID): return .escapeRecovery(transcriptID: transcriptID)
    case .importStatus: return nil
    }
  }

  /// The request a NON-RECORDING pipeline intent resolves to.
  ///
  /// **`nil` for `.recording` and only for `.recording`, and since C3a that is a
  /// permanent fact rather than a staging one.** A recording pill cannot be
  /// requested without a resolved design; a caller holding only an intent has not
  /// resolved one and has no business minting one. The recording request is built
  /// from its case directly, at the one site that has a design to give it.
  ///
  /// The name says `nonRecording` rather than `pipeline` so the refusal is
  /// legible at the call site instead of looking like a failure that might mean
  /// something else.
  init?(nonRecording intent: OverlayIntent) {
    switch intent {
    case .recording: return nil
    case .hidden: self = .hidden
    case .processing(let phase): self = .processing(phase: phase)
    case .clipboardFallback: self = .clipboardFallback
    case .accessibilityToast: self = .accessibilityToast
    case .warning(let reason): self = .warning(reason: reason)
    case .error(let reason): self = .error(reason: reason)
    case .advisory(let reason): self = .advisory(reason: reason)
    case .interruption(let reason): self = .interruption(reason: reason)
    case .passiveChip(let payload): self = .passiveChip(payload: payload)
    case .cachingModel(let engineLabel): self = .cachingModel(engineLabel: engineLabel)
    case .engineReady: self = .engineReady
    case .recoveringLastRecording: self = .recoveringLastRecording
    case .recoverySucceeded: self = .recoverySucceeded
    case .bluetoothAwareness: self = .bluetoothAwareness
    case .escapeRecovery(let transcriptID): self = .escapeRecovery(transcriptID: transcriptID)
    }
  }
}
