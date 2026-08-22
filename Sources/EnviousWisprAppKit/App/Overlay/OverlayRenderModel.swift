import CoreGraphics
import Foundation
import SwiftUI

/// The bridge the retained hosting view reads (#2292, chunk C4b).
///
/// **One observable value replaces the parallel channels.** The shipped panel
/// carries `OverlayLockState` and `OverlayNoticeState` as separate observable
/// objects, and `OverlayNoticeState`'s own doc comment says it exists so a
/// notice can morph the live recording pill "WITHOUT tearing the panel down" —
/// a workaround that has no reason to exist once the panel is retained, because
/// every change is a morph.
///
/// Deliberately thin. It holds what to draw and the two per-frame providers the
/// recording pill pulls from; it makes no decisions. The director decides.
@MainActor
final class OverlayRenderModel: ObservableObject {

  /// What the retained root should render, or `nil` for an empty slot.
  @Published var presentation: OverlayPresentation?

  /// **Retained for the rendered recording's lifetime**, which is the obligation
  /// recorded against `OverlayContent.recording`.
  ///
  /// These are PULLS, not pushes: the shipped
  /// `show(intent:audioLevelProvider:recordingElapsedProvider:isRecordingLocked:)`
  /// hands the panel two closures the view calls per frame. A snapshot pushed
  /// through the reducer would either lag the meter or churn a presentation
  /// identity many times a second, so the level a VIEW reads comes from here
  /// while the level the reducer carries is only ever a snapshot for identity
  /// and morph decisions.
  ///
  /// `recordingElapsedProvider` had no representation anywhere in the value
  /// vocabulary; it is named here because nothing else would have named it.
  private(set) var audioLevelProvider: () -> Float = { 0 }
  private(set) var recordingElapsedProvider: () -> TimeInterval? = { nil }
  /// #1988. What the live preview should show, polled on the same 50 ms loop as
  /// the other two rather than pushed, because that loop already exists and
  /// coalesces naturally.
  private(set) var livePreviewProvider: () -> LivePreviewDisplay = { .off }
  /// The capsule reports its measured height so the window can follow it. A
  /// callback rather than a value: it flows the other way.
  private(set) var onContentHeightChange: (CGFloat) -> Void = { _ in }
  /// Whether the recording pill uses the preview layout — 400 points wide and
  /// content-sized, rather than 185 in a reserved 92-point frame.
  ///
  /// **A PROVIDER, not a snapshot, and the shipped code says why in its own
  /// words.** `setLivePreviewProviders` takes `enabled` and `display` as two
  /// closures deliberately: "Reading the SETTING for geometry means the answer
  /// does not depend on whether the preview coordinator happened to be started
  /// before this push." A stored `Bool` reintroduces exactly that ordering
  /// dependency — the pill's size would come from whenever the caller last
  /// happened to set it rather than from the setting at the moment it is shown.
  private(set) var usesPreviewLayout: () -> Bool = { false }

  func setRecordingProviders(
    audioLevel: @escaping () -> Float,
    recordingElapsed: @escaping () -> TimeInterval?,
    livePreview: @escaping () -> LivePreviewDisplay,
    usesPreviewLayout: @escaping () -> Bool,
    onContentHeightChange: @escaping (CGFloat) -> Void
  ) {
    audioLevelProvider = audioLevel
    recordingElapsedProvider = recordingElapsed
    livePreviewProvider = livePreview
    self.usesPreviewLayout = usesPreviewLayout
    self.onContentHeightChange = onContentHeightChange
  }

  /// Dropped when the recording pill goes, so a stale closure cannot outlive the
  /// dictation it was reading. The shipped providers are installed once and live
  /// for the app's lifetime, which is safe only because they are re-set on every
  /// `show`.
  func clearRecordingProviders() {
    audioLevelProvider = { 0 }
    recordingElapsedProvider = { nil }
    livePreviewProvider = { .off }
    onContentHeightChange = { _ in }
    usesPreviewLayout = { false }
  }
}
