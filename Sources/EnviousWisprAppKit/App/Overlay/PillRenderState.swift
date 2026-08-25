import CoreGraphics
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// One atomic snapshot containing everything required for one rendered frame
/// (#2377 Phase 5, C1).
///
/// **Recording facts and providers publish TOGETHER.** The lock, the resolved
/// notice copy and the four per-frame providers reach a leaf in the same value
/// as the presentation that owns them, so no leaf can be built from a new
/// presentation and a previous pill's lock.
///
/// **The dwell is the one field that may update later**, because its clock
/// starts only after the host accepts the presentation — see `replacingDwell`.
///
/// **Not `Equatable`, deliberately.** It carries per-frame closures, and the one
/// consumer that would have needed equality is a post-publication comparison,
/// which is the shape a single atomic value exists to remove.
struct PillRenderState {

  /// What the retained root should render, or `nil` for an empty slot.
  let presentation: PillDefinition?

  /// The dwell a countdown is drawing, already matched to `presentation`.
  ///
  /// Matched at publication rather than by the view, so a window belonging to a
  /// previous pill cannot reach this frame at all. The root holds no policy.
  ///
  /// See `OverlayDwellWindow` for why this carries a TIME rather than an
  /// identity: SwiftUI delivers a published change on a later render
  /// transaction, so a rail keyed to the signal's arrival would lag the timer it
  /// draws and be cut off before its end.
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

  /// The #1060 banner's copy, already resolved by the publisher.
  ///
  /// `DictationNarrator` is the one authority for this sentence. It is asked here
  /// because the root holds exhaustive routing and no copy, and the leaf renders
  /// a string it is handed.
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
