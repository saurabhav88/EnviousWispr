import CoreGraphics
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// Chunk C1 is a semantic no-op port, and this suite is what makes that claim
/// checkable rather than asserted (#2292 Phase 1).
///
/// **Every case drives the SAME request twice — once through the old ingress,
/// once through `OverlayPresenting` — and compares what an observer outside the
/// director can see.** Comparing the two requests to each other would prove
/// nothing: the whole risk of a port is that two spellings of the same intent
/// diverge in what they PRODUCE. So the comparison is on outputs only — what the
/// host was asked to present, what reached the screen reader, which effects were
/// emitted, and what the render model published.
///
/// **No `*ForTesting` accessor appears here, which is why this suite runs in
/// Release.** The existing director suite is `#if DEBUG` in its entirety because
/// every case reads private state through a debug hatch; 69 of the overlay's 141
/// tests are invisible to the Release lane for that reason. This suite is the
/// first of the replacements.
/// **Class: `.productOutcome`, and the judgment is worth stating because a parity suite could read as a
/// drift guard.** A drift guard freezes an internal property and fails when we change our own code. This
/// fails when the two spellings of one request produce DIFFERENT USER-VISIBLE RESULTS — a pill with a
/// button bound to nobody, the wrong copy, a screen-reader announcement that does not fire. Nothing calls
/// the façade in C1, so that divergence reaches a user only once C3 and C5 migrate the callers; the tag
/// describes what the suite PROTECTS, not when it activates.
@MainActor
@Suite("Pill request parity (#2292 C1)", .tags(.productOutcome))
struct PillRequestParityTests {

  /// One director, plus every observable output it produces, recorded in order.
  private final class Rig {
    let host = WindowlessOverlayHost()
    var effects: [PillEffect] = []
    var announcements: [OverlayAnnouncement] = []
    var appActions: [PillAction] = []
    private(set) var director: OverlayDirector!

    @MainActor
    init() {
      director = OverlayDirector(
        host: host,
        deliverEffect: { [self] in effects.append($0) },
        deliverAppAction: { [self] in appActions.append($0) },
        announce: { [self] in announcements.append($0) },
        deferFirstRender: { $0() })
    }

    /// What an observer outside the director can see, as one comparable value.
    @MainActor
    var observed: Observed {
      Observed(
        presentedWidths: host.presented.map(\.width),
        presentedFixedHeights: host.presented.map(\.fixedHeight),
        presentedFreshness: host.presented.map(\.isFresh),
        hideCount: host.hideCount,
        isShowing: host.isShowing,
        effects: effects,
        announcements: announcements,
        content: director.renderModel.presentation?.content,
        expiry: director.renderModel.presentation?.expiry,
        recordingLayout: director.renderModel.recordingLayout)
    }
  }

  private struct Observed: Equatable {
    let presentedWidths: [OverlayWidth]
    let presentedFixedHeights: [CGFloat?]
    let presentedFreshness: [Bool]
    let hideCount: Int
    let isShowing: Bool
    let effects: [PillEffect]
    let announcements: [OverlayAnnouncement]
    let content: OverlayContent?
    let expiry: OverlayExpiry?
    let recordingLayout: OverlayRecordingLayout
  }

  /// Drive `old` on one rig and `new` on another, then compare every output.
  private func parity(
    _ label: String,
    old: (OverlayDirector) -> Void,
    new: (any OverlayPresenting) -> Void
  ) {
    let a = Rig()
    let b = Rig()
    old(a.director)
    new(b.director)
    #expect(a.observed == b.observed, "\(label): the façade diverged from the old ingress")
  }

  // MARK: - Pipeline-owned requests

  @Test("recording") func recording() {
    parity(
      "recording",
      old: {
        $0.presentRecording(
          audioLevel: 0.4, audioLevelProvider: { 0.4 },
          recordingElapsedProvider: { 3 }, isRecordingLocked: false, actions: nil)
      },
      new: {
        $0.present(.recording(RecordingPillInput(
          audioLevel: 0.4, audioLevelProvider: { 0.4 },
          recordingElapsedProvider: { 3 }, isLocked: false)))
      })
  }

  @Test("recording, born locked") func recordingLocked() {
    parity(
      "recording locked",
      old: {
        $0.presentRecording(
          audioLevel: 0.2, audioLevelProvider: { 0.2 },
          recordingElapsedProvider: { nil }, isRecordingLocked: true, actions: nil)
      },
      new: {
        $0.present(.recording(RecordingPillInput(
          audioLevel: 0.2, audioLevelProvider: { 0.2 },
          recordingElapsedProvider: { nil }, isLocked: true)))
      })
  }

  @Test("processing") func processing() {
    parity(
      "processing",
      old: { $0.send(.pipeline(.processing(phase: .transcribing)), actions: nil) },
      new: { $0.present(.processing(phase: .transcribing)) })
  }

  @Test("clipboard fallback") func clipboardFallback() {
    parity(
      "clipboardFallback",
      old: { $0.send(.pipeline(.clipboardFallback), actions: nil) },
      new: { $0.present(.clipboardFallback) })
  }

  @Test("warning") func warning() {
    parity(
      "warning",
      old: { $0.send(.pipeline(.warning(reason: .polishFailed)), actions: nil) },
      new: { $0.present(.warning(reason: .polishFailed)) })
  }

  @Test("caching model") func cachingModel() {
    parity(
      "cachingModel",
      old: { $0.send(.pipeline(.cachingModel(engineLabel: "Parakeet")), actions: nil) },
      new: { $0.present(.cachingModel(engineLabel: "Parakeet")) })
  }

  @Test("engine ready") func engineReady() {
    parity(
      "engineReady",
      old: { $0.send(.pipeline(.engineReady), actions: nil) },
      new: { $0.present(.engineReady) })
  }

  @Test("recovery succeeded") func recoverySucceeded() {
    parity(
      "recoverySucceeded",
      old: { $0.send(.pipeline(.recoverySucceeded), actions: nil) },
      new: { $0.present(.recoverySucceeded) })
  }

  @Test("import status") func importStatus() {
    parity(
      "importStatus",
      old: { $0.send(.featureRequest(.importStatus(message: "Importing 12")), actions: nil) },
      new: { $0.present(.importStatus(message: "Importing 12")) })
  }

  // MARK: - Feature-owned requests

  @Test("accessibility notice") func accessibilityNotice() {
    parity(
      "accessibilityNotice",
      old: { $0.presentAccessibilityNotice() },
      new: { $0.present(.accessibilityNotice) })
  }

  @Test("recovery notice") func recoveryNotice() {
    parity(
      "recoveryNotice",
      old: { $0.presentRecoveryNotice() },
      new: { $0.present(.recoveryNotice(onDiscard: {})) })
  }

  /// **The chip travels as a `.pipeline` intent, not a `.featureRequest`.**
  /// `OverlayIntent` and `OverlayRequest` both declare a `passiveChip` case, so
  /// the wrong one compiles and only differs in whether `pipelineIntent` is set
  /// — which is exactly what the language presenter arbitrates against. This
  /// case is the one that catches it.
  @Test("language chip routes through the pipeline intent") func languageChip() {
    let payload = LanguageChipPayload(
      lang: "es", displayName: "Spanish", state: .askToLock, generation: 1)
    parity(
      "languageChip",
      old: { $0.send(.pipeline(.passiveChip(payload: payload)), actions: { _ in }) },
      new: {
        $0.present(.languageChip(
          payload: payload, onLock: {}, onDismiss: {}, onExpire: {}))
      })
  }

  /// The mirror image of the chip: Bluetooth genuinely IS a `.featureRequest`.
  @Test("bluetooth awareness routes through the feature request") func bluetooth() {
    parity(
      "bluetoothAwareness",
      old: { $0.send(.featureRequest(.bluetoothAwareness), actions: { _ in }) },
      new: {
        $0.present(.bluetoothAwareness(
          onAcknowledge: {}, onClose: {}, onOpenSettings: {}))
      })
  }

  // MARK: - Updates and dismissal

  @Test("recording lock update") func lockUpdate() {
    parity(
      "recordingLock",
      old: {
        $0.presentRecording(
          audioLevel: 0.1, audioLevelProvider: { 0.1 },
          recordingElapsedProvider: { nil }, isRecordingLocked: false, actions: nil)
        $0.send(.lockStateChanged(true), actions: nil)
      },
      new: {
        $0.present(.recording(RecordingPillInput(
          audioLevel: 0.1, audioLevelProvider: { 0.1 },
          recordingElapsedProvider: { nil }, isLocked: false)))
        $0.update(.recordingLock(true))
      })
  }

  @Test("in-panel notice update") func inPanelNoticeUpdate() {
    parity(
      "inPanelNotice",
      old: {
        $0.presentRecording(
          audioLevel: 0.1, audioLevelProvider: { 0.1 },
          recordingElapsedProvider: { nil }, isRecordingLocked: false, actions: nil)
        $0.send(.inPanelNotice(.approachingCap, dismissAfter: 2), actions: nil)
      },
      new: {
        $0.present(.recording(RecordingPillInput(
          audioLevel: 0.1, audioLevelProvider: { 0.1 },
          recordingElapsedProvider: { nil }, isLocked: false)))
        $0.update(.inPanelNotice(.approachingCap, dismissAfter: 2))
      })
  }

  /// **Announced and silent dismissal are different operations and the
  /// difference is audible.** A chip dismissal that announced "Recording
  /// complete" would be a false statement to a VoiceOver user, so the two must
  /// not collapse into one façade call.
  @Test("announced dismissal") func announcedDismissal() {
    parity(
      "dismiss announced",
      old: {
        $0.send(.pipeline(.engineReady), actions: nil)
        $0.send(.pipeline(.hidden), actions: nil)
      },
      new: {
        $0.present(.engineReady)
        $0.dismissCurrent(.announced)
      })
  }

  @Test("silent dismissal") func silentDismissal() {
    parity(
      "dismiss silent",
      old: {
        $0.send(.pipeline(.engineReady), actions: nil)
        $0.dismissSilently()
      },
      new: {
        $0.present(.engineReady)
        $0.dismissCurrent(.silent)
      })
  }

  @Test("announced and silent dismissal are not the same operation") func dismissalDiffers() {
    let announced = Rig()
    let silent = Rig()
    announced.director.present(.engineReady)
    announced.director.dismissCurrent(.announced)
    silent.director.present(.engineReady)
    silent.director.dismissCurrent(.silent)
    #expect(
      announced.announcements.count > silent.announcements.count,
      "silent dismissal must post fewer announcements than announced dismissal")
  }

  // MARK: - Receipts

  @Test("a receipt names the presentation it was issued for") func receiptIdentity() {
    let rig = Rig()
    let receipt = rig.director.present(.engineReady)
    #expect(receipt != nil)
    #expect(rig.director.isCurrent(receipt!))
  }

  @Test("a receipt goes stale when a successor replaces its presentation") func receiptStales() {
    let rig = Rig()
    let first = rig.director.present(.engineReady)
    #expect(first != nil)
    rig.director.present(.processing(phase: .transcribing))
    #expect(!rig.director.isCurrent(first!))
  }

  /// The reason receipts exist: a feature owner dismissing "its" pill must not
  /// dismiss a successor that has since taken the slot.
  @Test("dismissIfCurrent does not dismiss a successor") func dismissIfCurrentIsScoped() {
    let rig = Rig()
    let stale = rig.director.present(.engineReady)
    #expect(stale != nil)
    rig.director.present(.processing(phase: .transcribing))
    let hidesBefore = rig.host.hideCount
    rig.director.dismissIfCurrent(stale!)
    #expect(rig.host.hideCount == hidesBefore, "a stale receipt must not dismiss the successor")
    #expect(rig.host.isShowing, "the successor must still be on screen")
  }
}
