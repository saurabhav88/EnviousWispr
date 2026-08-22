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

  /// Where a button press goes. One closure, because the director holds exactly
  /// one active binding — there is no per-kind handler collection to thread.
  let dispatch: (OverlayAction) -> Void

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

  @ViewBuilder
  private func content(for presentation: OverlayPresentation) -> some View {
    switch presentation.content {
    case .recording:
      // The LEVEL on the presentation is a snapshot the reducer carries for
      // identity and morph decisions; the view reads the live provider instead,
      // which is why it is not bound here.
      RecordingOverlayView(
        audioLevelProvider: model.audioLevelProvider,
        recordingElapsedProvider: model.recordingElapsedProvider,
        livePreviewProvider: model.livePreviewProvider,
        onContentHeightChange: model.onContentHeightChange,
        usesPreviewLayout: model.usesPreviewLayout,
        lockState: lockState.value,
        noticeState: noticeState.value)

    case .notice(let notice):
      notices(notice)

    case .languageChip(let payload):
      LanguageChipView(
        payload: payload,
        onLock: { dispatch(.lockLanguage) },
        onDismiss: { dispatch(.dismissChip) },
        onAutoDismiss: {})

    case .bluetoothAwareness:
      BluetoothAwarenessCardView(
        onGotIt: { dispatch(.acknowledgeBluetoothAwareness) },
        onClose: { dispatch(.closeBluetoothAwareness) },
        onAdjustSettings: { dispatch(.openBluetoothSettings) })

    case .escapeRecovery(let transcriptID):
      EscapeRecoveryPillView(
        onPaste: { dispatch(.pasteEscapeRecovery(transcriptID: transcriptID)) },
        onExpire: {})
    }
  }

  /// Eleven shipped pills collapse to one MODEL, and `NoticeModel.Kind` is what
  /// keeps their appearance intact — the model says what to say, the kind says
  /// which pill says it.
  @ViewBuilder
  private func notices(_ notice: NoticeModel) -> some View {
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
      RecoveryNoticeView(onDiscard: { dispatch(.discardRecovery) })
    case .accessibilityToast:
      AccessibilityToastView(onGrant: { dispatch(.grantAccessibility) })
    }
  }

  /// Total over the four shipped styles. `neutral` has no notification style of
  /// its own and no row produces it, so it maps to `.warning` rather than
  /// silently rendering nothing — a `default:` here would hide a missing case
  /// instead of failing it.
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
