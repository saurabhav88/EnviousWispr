import EnviousWisprCore
import SwiftUI

/// The one retained root the window host hosts (#2292, chunk C4c).
///
/// **View construction lives HERE, not in the render model and not in the
/// director.** The model holds values and providers; the director decides; this
/// switches over `PillDefinition.content` and builds the EXISTING leaf
/// views. Putting the `switch` in the model would make the model know about
/// SwiftUI, and putting it in the director would make the director know about
/// pixels — both are the god-object shape this migration is removing, relocated.
///
/// **It holds no copy and no policy** — the plan's own ownership table says
/// exactly that of this type (#2377 Phase 5 C1). It reads
/// ONE `PillRenderState` per evaluation and destructures it. The lock, the
/// notice sentence and the dwell-to-presentation match were all decided here
/// once; all three now arrive already decided, because a value the root computes
/// after publication is a value that can disagree with the frame it is drawn on.
struct OverlayRootView: View {

  @ObservedObject var model: OverlayRenderModel

  /// Where an interaction goes. One closure carrying whole EVENTS rather than
  /// bare actions, because both things a view reports — a press and a hover —
  /// have to name the presentation they happened to.
  ///
  /// **The ID comes from the presentation the view was BUILT with, never from
  /// whatever is current when the finger lands.** Reading the live ID at press
  /// time relabels a click on an outgoing pill with its successor's identity, so
  /// the director's staleness check waves it through and the new pill receives a
  /// press meant for the old one. Capturing it here makes a stale press
  /// unrepresentable rather than merely unlikely.
  let sendEvent: (OverlayEvent) -> Void

  /// What a recording leaf was BUILT with, reported at the construction boundary
  /// (#2377 Phase 5 C1).
  ///
  /// **The seam exists because the property under test is not observable from
  /// the outside.** Atomicity is a claim about the FIRST evaluation after a
  /// publication, and every other instrument settles before it can be read:
  /// `fittingSize` is taken after layout has finished, so a torn first pass has
  /// already been replaced by a correct second one by the time anything measures
  /// it. Reading the definition proves nothing either — the tear was never about
  /// what the definition said, it was about what reached the leaf.
  ///
  /// **Not `#if DEBUG`, deliberately, and the plan is why.** Phase 5's "Proven
  /// by" line requires Release execution, and its test strategy says each phase
  /// installs the smallest observable seam its own change requires — a
  /// DEBUG-only seam satisfies the second and makes the first impossible. It is
  /// `internal`, `nil` in production, set by nothing but a test, and read once
  /// per recording frame.
  ///
  /// Cited by SECTION rather than line: the plan lives under a gitignored
  /// `docs/`, so a line number in shipped source points at a file most readers
  /// cannot open and cannot check.
  ///
  /// It reports the values PASSED to the leaf, never the values present on the
  /// definition, because those two agreeing is the thing being tested.
  @MainActor static var leafObserverForTesting: ((PresentationID, Bool, String?) -> Void)?

  var body: some View {
    // **ONE snapshot read, at the top, used by everything below** (#2377 Phase 5
    // C1). Reading `model.state` again inside a closure would reintroduce the
    // defect this chunk removes in its worst form: a press or a frame assembled
    // from whatever is current at the moment it runs rather than from the frame
    // the user is looking at.
    let frame = model.state
    return Group {
      if let presentation = frame.presentation {
        content(for: presentation, frame: frame)
          // **Identity at the occupant boundary.** A same-id morph — an audio
          // tick, a lock change, an in-panel notice — preserves SwiftUI's view
          // identity so animations and `@State` continue; a genuinely new
          // presentation resets them, which is what the shipped teardown used to
          // achieve by destroying the window.
          .id(presentation.id)
          // Hover-pause was expressible from the first model —
          // `OverlayExpiry.after(seconds:pausesOnHover:)` and
          // `OverlayEvent.hoverChanged` both existed — and nothing ever sent the
          // event, so the language chip's pause did nothing at all. A capability
          // with no producer reads as present in every grep of the vocabulary.
          .onHover { sendEvent(.hoverChanged(presentation.id, $0)) }
      }
    }
  }

  /// Every leaf callback goes through here, so the presentation's own ID travels
  /// with the press instead of being looked up afterwards.
  private func press(_ action: PillAction, on presentation: PillDefinition) {
    sendEvent(.action(presentation.id, action))
  }

  /// Send a NOTICE's own action (#2376 Phase 4, C3).
  ///
  /// **The literal is gone, and that is the point.** This site used to dispatch
  /// `.discardRecovery` and `.grantAccessibility` by name while `PillCatalog`
  /// carried the same two values on the model, so `NoticeModel.action` had no
  /// production reader at all — a field set by two rows and read by nothing but
  /// the model's own `==`.
  ///
  /// **There is no `??` fallback to the old literal, deliberately.** A fallback
  /// would reinstate exactly the duplicate authority this deletes, and would do
  /// it silently: a row that lost its action would keep working and nothing would
  /// say so. A button with no action does not render at all
  /// (`RecoveryNoticeView` and `AccessibilityToastView` both bind `if let
  /// action`), and `noticeActionsAreCarriedByEveryKindThatDrawsAButton` sweeps the
  /// catalog's closed set so a row cannot lose one unnoticed.
  private func dispatch(_ action: NoticeAction?, on presentation: PillDefinition) {
    guard let action else { return }
    press(action.action, on: presentation)
  }

  @ViewBuilder
  private func content(for presentation: PillDefinition, frame: PillRenderState) -> some View {
    switch presentation.content {
    case .recording:
      // The LEVEL on the presentation is a snapshot the reducer carries for
      // identity and morph decisions; the view reads the live provider instead,
      // which is why it is not bound here.
      //
      // **The FRAME is part of the composition, not a detail of the window.** The
      // shipped site frames this view before handing it to `showPanel`, and the
      // panel is then sized to match. Dropping the frame leaves the capsule to
      // size itself inside a 92-point window: the #1341 Bottom case in
      // particular depends on the ALIGNMENT here, because bottom-aligning the
      // content is what makes the panel's Y origin the capsule's visible bottom
      // edge. The DESIGN owns the size and the captured position owns the
      // alignment; nothing bundles them together any more.
      //
      // **`frame.recording` is non-nil exactly when this case matched**, because
      // `OverlayRenderModel.recordingFrame(for:)` builds it from the same
      // `.recording` binding. `EmptyView` is the unreachable arm rather than a
      // fallback: substituting a default design here would be a second answer to
      // a question the definition already answers, which is what #2375 C3b
      // deleted.
      if let recordingFrame = frame.recording {
        recording(recordingFrame, id: presentation.id)
      }

    case .notice(let notice):
      notices(notice, on: presentation)

    case .languageChip(let payload):
      LanguageChipView(
        payload: payload,
        onLock: { press(.lockLanguage, on: presentation) },
        onDismiss: { press(.dismissChip, on: presentation) })

    case .bluetoothAwareness:
      BluetoothAwarenessCardView(
        onGotIt: { press(.acknowledgeBluetoothAwareness, on: presentation) },
        onClose: { press(.closeBluetoothAwareness, on: presentation) },
        onAdjustSettings: { press(.openBluetoothSettings, on: presentation) })

    case .escapeRecovery(let transcriptID):
      EscapeRecoveryPillView(
        onPaste: { press(.pasteEscapeRecovery(transcriptID: transcriptID), on: presentation) },
        // Already matched to this presentation at publication — see
        // `PillRenderState.dwell`. The root holds no policy, so a window left by
        // a previous pill never reaches this frame rather than being filtered
        // out by the view that draws it.
        dwell: frame.dwell)
    }
  }

  /// **`usesPreviewLayout` IS GONE, and the design itself is what the leaf gets**
  /// (#2376 Phase 4, C2). #2375 C3b deleted the layout bundle and left this
  /// boolean as the declared boundary; it is now replaced by
  /// `RecordingPillChrome`, a value carrying what the pill DRAWS. `canHoldWords`
  /// survives untouched as a CAPABILITY fact, read by
  /// `OverlayRenderModel.setRecordingProviders` to decide whether a live-preview
  /// provider is installed at all. It never reaches a view.
  ///
  /// **The design is NON-OPTIONAL, and an earlier version of this took an
  /// optional and fell back to `.classic`.** The definition's own recording case
  /// carries the design, so the caller binds it there and nothing here can
  /// substitute a second answer — which is exactly the arrangement #2375 C3b
  /// deleted, and a small one had been rebuilt inside the fix for it.
  ///
  /// **The framing switch is EXHAUSTIVE over `RecordingPillDesign` and carries no
  /// `default:`.** A default would let a design added later render inside a
  /// neighbour's frame — correct model data with the wrong geometry, which is
  /// this phase's named regression arriving through the one construct that hides
  /// it from the compiler.
  @ViewBuilder
  private func recording(_ recordingFrame: RecordingFrame, id: PresentationID) -> some View {
    let _ = Self.leafObserverForTesting?(
      id, recordingFrame.isLocked, recordingFrame.noticeText)
    let design = recordingFrame.design
    let view = RecordingOverlayView(
      audioLevelProvider: recordingFrame.audioLevelProvider,
      recordingElapsedProvider: recordingFrame.recordingElapsedProvider,
      livePreviewProvider: recordingFrame.livePreviewProvider,
      onContentHeightChange: recordingFrame.onContentHeightChange,
      chrome: design.chrome,
      isLocked: recordingFrame.isLocked,
      noticeText: recordingFrame.noticeText)

    switch design {
    case .readingWell:
      // Width only. The height is content-driven so the pill earns its size a
      // line at a time rather than snapping once the real height is measured.
      view.frame(width: design.width)
    case .classic, .levelRail:
      // The shared without-words arm: both reserve a fixed interaction frame, and
      // both do it for the same reason — the #1060 banner has to fit a box neither
      // can grow out of.
      //
      // #1341: Bottom bottom-aligns, Top centres. Centring in Bottom leaves ~24
      // points of invisible space under a ~44-point capsule, which mutes the
      // Bottom offset and visibly misaligns the polishing pill that replaces it.
      view.frame(
        width: design.width, height: design.reservedHeight,
        alignment: recordingFrame.position == .bottom ? .bottom : .center)
    }
  }

  /// Eleven shipped pills collapse to one MODEL, and `NoticeModel.Kind` is what
  /// keeps their appearance intact — the model says what to say, the kind says
  /// which pill says it.
  @ViewBuilder
  private func notices(_ notice: NoticeModel, on presentation: PillDefinition) -> some View {
    switch notice.kind {
    case .processing:
      PolishingOverlayView(label: notice.text)
    case .warmingUp:
      ColdStartNoticeView(title: notice.text, subtitle: notice.secondaryText, icon: .spinner)
    case .ready:
      ColdStartNoticeView(title: notice.text, subtitle: notice.secondaryText, icon: .ready)
    case .notification:
      NotificationOverlayView(
        message: notice.text, style: Self.style(for: notice.severity),
        isMultiline: notice.isMultiline, secondaryText: notice.secondaryText,
        action: notice.action,
        onAction: notice.action == nil ? nil : { dispatch(notice.action, on: presentation) }
      )
      // Same shape `.recovery` already ships: `.contain` (not `.combine`) so
      // the action button below stays its own reachable VoiceOver element
      // instead of being flattened into one non-interactive label.
      .accessibilityElement(children: .contain)
      .accessibilityLabel(notice.accessibilityLabel ?? notice.text)
    case .importStatus:
      ImportStatusOverlayView(message: notice.text)
    case .recovery:
      RecoveryNoticeView(
        title: notice.text, subtitle: notice.secondaryText,
        accessibilityLabel: notice.accessibilityLabel ?? notice.text,
        action: notice.action,
        onAction: { dispatch(notice.action, on: presentation) })
    case .accessibilityToast:
      AccessibilityToastView(
        text: notice.text, action: notice.action,
        onAction: { dispatch(notice.action, on: presentation) })
    }
  }

  /// Total over the four shipped styles.
  ///
  /// `.neutral` is the notice helper's DEFAULT, so plenty of notices carry it —
  /// but none of those reach here, because every row whose kind is
  /// `.notification` states its severity outright.
  /// `notificationNoticesNeverTakeTheSeverityDefault` sweeps that closed set and
  /// fails if a `.notification` row ever leaves the severity unset, which is
  /// what would land it in this branch.
  ///
  /// It maps to `.warning` rather than to a `default:` so such a row is
  /// STYLED-WRONG-BUT-VISIBLE instead of silently unstyled. A `default:` would
  /// also hide a genuinely new severity from the compiler.
  static func style(for severity: NoticeModel.Severity) -> NotificationStyle {
    switch severity {
    case .error: return .error
    case .warning, .neutral: return .warning
    case .distress: return .interruption
    case .advisory: return .advisory
    }
  }
}
