import CoreGraphics
import EnviousWisprCore
import Foundation
import SwiftUI

/// The bridge the retained hosting view reads (#2292 C4b, #2377 Phase 5 C1).
///
/// **It publishes exactly one value and holds no decisions.** `PillRenderState`
/// owns what a frame is; this owns when one is published. The director decides.
///
/// The recording providers are STAGED privately and folded into the snapshot at
/// publication, so there is no window in which the root can read a new
/// presentation beside an old provider set.
@MainActor
final class OverlayRenderModel: ObservableObject {

  /// The one frame. Nothing else is published, and nothing else is readable.
  @Published private(set) var state: PillRenderState = .empty

  // MARK: - Staged recording inputs

  /// What `setRecordingProviders` last installed.
  ///
  /// **Private, and the root cannot reach it.** A reader that could see staged
  /// inputs alongside a published presentation could assemble a frame from two
  /// different moments, which is the defect this whole chunk removes wearing a
  /// different name.
  ///
  /// Defaults mirror what `clearRecordingProviders` restores, so a recording
  /// published with nothing staged renders exactly as it did before this
  /// snapshot existed: a silent meter, no clock, no words, no growth.
  private var staged = StagedRecordingInputs()

  private struct StagedRecordingInputs {
    var audioLevelProvider: () -> Float = { 0 }
    var recordingElapsedProvider: () -> TimeInterval? = { nil }
    var livePreviewProvider: () -> LivePreviewDisplay = { .off }
    var onContentHeightChange: (CGFloat) -> Void = { _ in }
    var position: OverlayPillPosition = .top
  }

  /// Install the providers for one fresh recording. **Stages only — it publishes
  /// nothing.** The director publishes once, after it has decided the whole
  /// plan.
  func setRecordingProviders(
    audioLevel: @escaping () -> Float,
    recordingElapsed: @escaping () -> TimeInterval?,
    livePreview: @escaping () -> LivePreviewDisplay,
    design: RecordingPillDesign,
    position: OverlayPillPosition,
    onContentHeightChange: @escaping (CGFloat) -> Void
  ) {
    staged.audioLevelProvider = audioLevel
    staged.recordingElapsedProvider = recordingElapsed
    // **Gated off the DESIGN, exactly as the shipped site gates it.** A pill that
    // cannot hold words is handed `{ .off }` rather than the live provider, so a
    // pill showing no preview cannot be reading one. The gate used to key off a
    // geometry bundle's preview flag, which is how one authority came to
    // disagree with another about what was on screen.
    staged.livePreviewProvider = design.canHoldWords ? livePreview : { .off }
    staged.position = position
    // Likewise `{ _ in }` for a pill that holds no words: only that one grows.
    staged.onContentHeightChange = design.canHoldWords ? onContentHeightChange : { _ in }
  }

  /// Drop the providers, so a stale closure cannot outlive the dictation it was
  /// reading. Staging only; the publication that follows carries the result.
  func clearRecordingProviders() {
    staged = StagedRecordingInputs()
  }

  // MARK: - Publication

  /// Publish one frame. **The only writer of `state`, apart from the dwell.**
  ///
  /// The recording half is assembled HERE rather than by the root, which is what
  /// makes the lock, the notice copy and the providers arrive in the same
  /// transaction as the presentation that owns them.
  ///
  /// **A dwell survives a SAME-ID publication and dies on any other**, and the
  /// distinction is the reducer's: three same-id recording morphs — an audio
  /// tick, a lock change, a notice change — emit `.unchanged` for the expiry,
  /// which means "the clock keeps running" and arms nothing. Clearing the dwell
  /// on every publication silently discarded a window the director had armed,
  /// twenty times a second during a live recording with a timed #1060 banner.
  ///
  /// Invisible today, because the only view that reads a dwell is the Escape
  /// Recovery rail and no recording is one. That is exactly why it is worth
  /// fixing here rather than when a second countdown appears: the model was
  /// throwing away state the director owned, and nothing would have said so.
  ///
  /// Both ids must EXIST and match. Two nil presentations comparing equal would
  /// carry a window across an empty slot, which is the stale-countdown defect
  /// `PresentationID` exists to close.
  func publish(_ presentation: PillDefinition?) {
    let carriedDwell: OverlayDwellWindow?
    if let id = presentation?.id, state.presentation?.id == id {
      carriedDwell = state.dwell
    } else {
      carriedDwell = nil
    }
    state = PillRenderState(
      presentation: presentation, dwell: carriedDwell,
      recording: recordingFrame(for: presentation))
  }

  /// Republish the same frame with its dwell filled in.
  ///
  /// **A dwell starts when the pill is VISIBLE, not when the plan is applied**,
  /// so it genuinely arrives after the presentation and cannot be folded into
  /// `publish`. Arming early spends part of a transient pill's dwell before
  /// anything is on screen, and Escape Recovery draws a countdown rail from the
  /// same dwell — a clock that starts early finishes early and the rail
  /// disagrees with the pill it is drawn on.
  ///
  /// **Matched to the current presentation here, not in the view.** A window
  /// naming a pill that is no longer current is dropped rather than published
  /// and filtered downstream.
  func markDwellStarted(_ window: OverlayDwellWindow?) {
    guard let window else {
      state = state.replacingDwell(nil)
      return
    }
    guard window.id == state.presentation?.id else { return }
    state = state.replacingDwell(window)
  }

  private func recordingFrame(for presentation: PillDefinition?) -> RecordingFrame? {
    guard case .recording(_, let isLocked, let notice, let design)? = presentation?.content
    else { return nil }
    return RecordingFrame(
      design: design,
      position: staged.position,
      isLocked: isLocked,
      // Resolved at publication so the root carries no copy. `DictationNarrator`
      // is the one authority for this sentence and always has been; what moved
      // is only WHERE it is asked.
      noticeText: notice.map { DictationNarrator.copy(for: $0.reason) },
      audioLevelProvider: staged.audioLevelProvider,
      recordingElapsedProvider: staged.recordingElapsedProvider,
      livePreviewProvider: staged.livePreviewProvider,
      onContentHeightChange: staged.onContentHeightChange)
  }
}
