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

  /// **The presentation whose dwell has actually started**, published so a view
  /// drawing a countdown starts it at the same instant the director arms the
  /// real dismissal. `nil` while nothing is dwelling.
  ///
  /// A view cannot see this for itself: `onAppear` fires during construction and
  /// attachment, which on a deferred first presentation is before the window is
  /// ordered on screen. Two clocks with different start instants is exactly what
  /// made the recovery rail finish while its pill was still visible.
  @Published private(set) var dwellStarted: PresentationID?

  func markDwellStarted(_ id: PresentationID?) {
    dwellStarted = id
  }

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
  /// How the current recording pill is composed. See `OverlayRecordingLayout`
  /// for the five decisions it carries and why they cannot be installed apart.
  ///
  /// **Resolved once per FRESH recording and then held, rather than re-read.**
  /// The shipped site reads the setting once at panel creation and the width is
  /// fixed for that panel's life — an `NSPanel` cannot grow mid-recording
  /// without a rebuild, and a rebuild is the #930 flicker. So a mid-dictation
  /// settings change must NOT resize the live pill, which is what re-reading a
  /// provider on every morph would do.
  private(set) var recordingLayout: OverlayRecordingLayout = .compact(position: .top)

  func setRecordingProviders(
    audioLevel: @escaping () -> Float,
    recordingElapsed: @escaping () -> TimeInterval?,
    livePreview: @escaping () -> LivePreviewDisplay,
    layout: OverlayRecordingLayout,
    onContentHeightChange: @escaping (CGFloat) -> Void
  ) {
    audioLevelProvider = audioLevel
    recordingElapsedProvider = recordingElapsed
    // **Gated exactly as the shipped site gates it.** With preview off it passes
    // `{ .off }` rather than the live display provider, so a pill that shows no
    // preview cannot be reading one.
    livePreviewProvider = layout.usesPreview ? livePreview : { .off }
    recordingLayout = layout
    // Likewise `{ _ in }` off-preview: only the preview pill grows to its text.
    self.onContentHeightChange = layout.usesPreview ? onContentHeightChange : { _ in }
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
    recordingLayout = .compact(position: .top)
  }
}
