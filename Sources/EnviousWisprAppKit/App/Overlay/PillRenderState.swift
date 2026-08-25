import CoreGraphics
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// One atomic snapshot containing everything required for one frame (#2377
/// Phase 5, C1).
///
/// **The point is that it is ONE value.** Before this, a frame was assembled
/// from four sources that changed at four different moments: a published
/// presentation, a separately published dwell window, and two `@Observable`
/// side-channels the root wrote AFTER the presentation had already been
/// published. `OverlayRootView` ran `sync(_:)` from `.onChange`, so the body
/// evaluated once with the OUTGOING lock and notice before the channels caught
/// up — a one-frame tear, structural rather than occasional.
///
/// Their own doc comments recorded why they existed and are carried here rather
/// than deleted with them, because the reason is the thing worth keeping:
/// `OverlayNoticeState` existed so a notice could morph a live recording pill
/// "WITHOUT tearing the panel down", and `OverlayLockState` came out of
/// `RecordingOverlayPanel` for the same reason. Every other notice path rebuilt
/// the single panel and lost the `.recording` state, so a side-channel was the
/// only way to change one field without destroying the window. #2292 retained
/// the panel, which made every change a morph and left both channels solving a
/// problem that no longer exists.
///
/// **Not `Equatable`, deliberately.** It carries per-frame closures, and the one
/// consumer that used to need equality — the root's `.onChange(of:)` — is what
/// this type deletes. Anything reaching for `==` here is reintroducing the
/// post-publication comparison the tear came from.
struct PillRenderState {

  /// What the retained root should render, or `nil` for an empty slot.
  let presentation: PillDefinition?

  /// The dwell a countdown is drawing, **already matched to `presentation`**.
  ///
  /// The match used to be made in the root (`model.dwellWindow?.id ==
  /// presentation.id ? … : nil`), which is a policy read in the one place the
  /// plan says holds no policy. Resolving it at publication means a window left
  /// by a previous pill cannot reach this frame at all, rather than being
  /// filtered out by the view that draws it.
  ///
  /// See `OverlayDwellWindow` for why this carries a TIME rather than an
  /// identity: SwiftUI delivers a published change on a later render
  /// transaction, so a rail that started when the signal ARRIVED would lag the
  /// timer it draws and be cut off before its end.
  let dwell: OverlayDwellWindow?

  /// Everything a recording leaf needs, or `nil` when the frame is not a
  /// recording.
  ///
  /// Non-nil exactly when `presentation?.content` is `.recording`, which is what
  /// makes the root's recording branch a destructure rather than a lookup.
  let recording: RecordingFrame?

  /// `@MainActor` because the frame carries main-actor closures and is therefore
  /// not `Sendable`; the whole overlay runs on the main actor anyway.
  @MainActor static let empty = PillRenderState(presentation: nil, dwell: nil, recording: nil)

  /// Replace only the dwell, keeping the rest of the frame byte-for-byte.
  ///
  /// The dwell is published at a genuinely later instant than the presentation —
  /// it begins when the pill is VISIBLE, after the host has accepted it — so it
  /// is the one field that legitimately arrives second. Rebuilding the whole
  /// snapshot around it keeps a single publication rather than reinstating a
  /// second channel for the one value that needs one.
  func replacingDwell(_ dwell: OverlayDwellWindow?) -> PillRenderState {
    PillRenderState(presentation: presentation, dwell: dwell, recording: recording)
  }
}

/// The complete input to one recording leaf evaluation.
///
/// **Providers and per-frame facts travel TOGETHER here, and that is the whole
/// design.** The providers are installed once per fresh recording and pulled
/// fifty times a second; the lock and the notice change many times within one
/// pill's life. Keeping them in one value means a leaf cannot be built from a
/// new presentation's lock and an old presentation's providers, which is the
/// same class of disagreement one level down from the tear this replaces.
struct RecordingFrame {

  /// The resolved design. Never re-read and never defaulted: the definition's
  /// own `.recording` case carries it, so there is exactly one answer.
  let design: RecordingPillDesign

  /// Where the pill is anchored (#2375 C3b). **A POSITION, not a layout bundle** —
  /// the bundle it replaced carried width and height too, and that geometry half
  /// was a second authority which disagreed with the definition and won.
  ///
  /// Resolved once per FRESH recording and then held: an `NSPanel` cannot grow
  /// mid-recording without a rebuild, and a rebuild is the #930 flicker, so a
  /// mid-dictation settings change must not resize the live pill.
  let position: OverlayPillPosition

  /// Hands-free lock, taken from the presentation being published.
  let isLocked: Bool

  /// The #1060 banner's copy, **already resolved**.
  ///
  /// `DictationNarrator.copy(for:)` used to run inside the root. The plan gives
  /// the root exhaustive routing and no copy, so the sentence is decided here
  /// and the leaf renders a string it is handed.
  let noticeText: String?

  /// PULLS, not pushes. A snapshot pushed through the reducer would either lag
  /// the meter or churn a presentation identity many times a second, so the
  /// level a VIEW reads comes from here while the level the definition carries
  /// is only ever a snapshot for identity and morph decisions.
  let audioLevelProvider: () -> Float
  let recordingElapsedProvider: () -> TimeInterval?
  let livePreviewProvider: () -> LivePreviewDisplay

  /// The capsule reports its measured height so the window can follow it. A
  /// callback rather than a value: it flows the other way.
  let onContentHeightChange: (CGFloat) -> Void
}
