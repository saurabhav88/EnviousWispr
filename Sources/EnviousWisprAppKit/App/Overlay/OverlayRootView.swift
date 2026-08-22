import EnviousWisprCore
import SwiftUI

/// The one retained root the window host hosts (#2292, chunk C4c).
///
/// **View construction lives HERE, not in the render model and not in the
/// director.** The model holds values and providers; the director decides; this
/// switches over `OverlayPresentation.content` and builds the EXISTING leaf
/// views. Putting the `switch` in the model would make the model know about
/// SwiftUI, and putting it in the director would make the director know about
/// pixels — both are the god-object shape this migration is removing, relocated.
///
/// The leaf views are untouched. Their cleanup is explicitly out of scope for
/// this chunk: only the composition changes.
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

  /// The two legacy observable channels, adapted rather than removed.
  ///
  /// `OverlayLockState` and `OverlayNoticeState` exist in the shipped code as
  /// PARALLEL channels, and `OverlayNoticeState`'s own doc comment says why: so
  /// a notice could morph the live pill "WITHOUT tearing the panel down". With
  /// one retained window every change is a morph, so the channels have no reason
  /// to exist — but deleting them means editing the leaf views, which this chunk
  /// deliberately does not do. They are driven FROM the presentation here, which
  /// makes the presentation the single source and leaves the views alone.
  @StateObject private var lockState = ObservableLockState()
  @StateObject private var noticeState = ObservableNoticeState()

  var body: some View {
    Group {
      if let presentation = model.presentation {
        content(for: presentation)
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
    .onAppear { sync(model.presentation) }
    .onChange(of: model.presentation) { _, new in sync(new) }
  }

  private func sync(_ presentation: OverlayPresentation?) {
    guard case .recording(_, let isLocked, let notice)? = presentation?.content else {
      lockState.value.isLocked = false
      noticeState.value.message = nil
      return
    }
    lockState.value.isLocked = isLocked
    noticeState.value.message = notice.map { DictationNarrator.copy(for: $0.reason) }
  }

  /// Every leaf callback goes through here, so the presentation's own ID travels
  /// with the press instead of being looked up afterwards.
  private func press(_ action: OverlayAction, on presentation: OverlayPresentation) {
    sendEvent(.action(presentation.id, action))
  }

  @ViewBuilder
  private func content(for presentation: OverlayPresentation) -> some View {
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
      // edge. `OverlayRecordingLayout` owns all of it.
      recording(model.recordingLayout)

    case .notice(let notice):
      notices(notice, on: presentation)

    case .languageChip(let payload):
      LanguageChipView(
        payload: payload,
        onLock: { press(.lockLanguage, on: presentation) },
        onDismiss: { press(.dismissChip, on: presentation) },
        onAutoDismiss: {})

    case .bluetoothAwareness:
      BluetoothAwarenessCardView(
        onGotIt: { press(.acknowledgeBluetoothAwareness, on: presentation) },
        onClose: { press(.closeBluetoothAwareness, on: presentation) },
        onAdjustSettings: { press(.openBluetoothSettings, on: presentation) })

    case .escapeRecovery(let transcriptID):
      EscapeRecoveryPillView(
        onPaste: { press(.pasteEscapeRecovery(transcriptID: transcriptID), on: presentation) },
        onExpire: {},
        // Matched against THIS presentation, so a signal left by a previous pill
        // cannot start this one's rail early.
        dwellStarted: model.dwellStarted == presentation.id ? presentation.id : nil)
    }
  }

  @ViewBuilder
  private func recording(_ layout: OverlayRecordingLayout) -> some View {
    let view = RecordingOverlayView(
      audioLevelProvider: model.audioLevelProvider,
      recordingElapsedProvider: model.recordingElapsedProvider,
      livePreviewProvider: model.livePreviewProvider,
      onContentHeightChange: model.onContentHeightChange,
      usesPreviewLayout: layout.usesPreview,
      lockState: lockState.value,
      noticeState: noticeState.value)

    switch layout {
    case .preview(_):
      // Width only. The height is content-driven so the pill earns its size a
      // line at a time rather than snapping once the real height is measured.
      view.frame(width: layout.width)
    case .compact(let position):
      // #1341: Bottom bottom-aligns, Top centres. Centring in Bottom leaves ~24
      // points of invisible space under a ~44-point capsule, which mutes the
      // Bottom offset and visibly misaligns the polishing pill that replaces it.
      view.frame(
        width: layout.width, height: layout.fixedHeight,
        alignment: position == .bottom ? .bottom : .center)
    }
  }

  /// Eleven shipped pills collapse to one MODEL, and `NoticeModel.Kind` is what
  /// keeps their appearance intact — the model says what to say, the kind says
  /// which pill says it.
  @ViewBuilder
  private func notices(_ notice: NoticeModel, on presentation: OverlayPresentation) -> some View {
    switch notice.kind {
    case .processing:
      PolishingOverlayView(label: notice.text)
    case .warmingUp:
      ColdStartNoticeView(title: notice.text, subtitle: notice.secondaryText, icon: .spinner)
    case .ready:
      ColdStartNoticeView(title: notice.text, subtitle: notice.secondaryText, icon: .ready)
    case .notification:
      NotificationOverlayView(message: notice.text, style: Self.style(for: notice.severity))
    case .importStatus:
      ImportStatusOverlayView(message: notice.text)
    case .recovery:
      RecoveryNoticeView(onDiscard: { press(.discardRecovery, on: presentation) })
    case .accessibilityToast:
      AccessibilityToastView(onGrant: { press(.grantAccessibility, on: presentation) })
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

/// `OverlayLockState` and `OverlayNoticeState` are `@Observable` classes the leaf
/// views take by value-reference; these wrap them so the root can own their
/// lifetime with `@StateObject` without editing the leaf views.
@MainActor
private final class ObservableLockState: ObservableObject {
  let value = OverlayLockState()
}

@MainActor
private final class ObservableNoticeState: ObservableObject {
  let value = OverlayNoticeState()
}
