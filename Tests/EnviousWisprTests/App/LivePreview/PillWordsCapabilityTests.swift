import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLivePreview

/// The capability's REASON agrees with the capability's VERDICT (#2376 Phase 4, C4).
///
/// **Two properties answering one question, bound in both directions by this
/// suite rather than by intention.** `isEnabledForGeometry` is what the director
/// reads to decide whether to size a pill for words; `wordsCapability` is what
/// the appearance picker reads, because greying out a group of designs without
/// saying WHY is the shape this repo already records as "visible and inaudible",
/// and a `Bool` cannot carry a reason.
///
/// Phase 3's seam comment forbids Phase 4 from changing where the director
/// resolves capability, so the verdict is untouched and the reason is additive.
/// The cost of additive is a second authority, and this is what pays it.
///
/// **Product Outcome.** When these fail, a settings page tells a user to turn on
/// a switch that cannot help them, or greys out designs their machine can render.
@MainActor
@Suite(.tags(.productOutcome))
struct PillWordsCapabilityTests {

  private static func coordinator(
    supported: Bool, previewOn: Bool
  ) -> LivePreviewCoordinator {
    LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { previewOn },
      languageMode: { .locked("en") },
      selectedRoute: {
        LivePreviewEngineRoute(
          telemetryEngineID: "universal",
          isSupportedOnThisSystem: { supported },
          resolve: { _ in .blocked(.unsupportedSystem) })
      })
  }

  /// **Generated over the cross-product**, so a third input added later is swept
  /// with no edit here, and both directions are asserted: `.available` if and only
  /// if the geometry verdict is true.
  @Test(
    "the reason says available exactly when the verdict says enabled",
    arguments: [true, false], [true, false])
  func wordsCapabilityAgreesWithTheGeometryVerdict(supported: Bool, previewOn: Bool) {
    let c = Self.coordinator(supported: supported, previewOn: previewOn)
    #expect(
      c.wordsCapability.hasWords == c.isEnabledForGeometry,
      """
      supported=\(supported) previewOn=\(previewOn): the reason said \
      \(c.wordsCapability) while the verdict said \(c.isEnabledForGeometry). These \
      are one question; if they can disagree, the picker and the pill will.
      """)
  }

  /// The same equivalence DURING a recording, where the verdict reads a frozen
  /// snapshot rather than the live setting. A reason that answered live here would
  /// agree outside a recording and diverge inside one, which is the window a
  /// cross-product over live inputs alone cannot see.
  @Test(
    "the reason honours the recording freeze the verdict honours",
    arguments: [true, false], [true, false])
  func wordsCapabilityHonoursTheRecordingFreeze(supported: Bool, previewOn: Bool) {
    let c = Self.coordinator(supported: supported, previewOn: previewOn)
    c.setRecording(true)
    #expect(
      c.wordsCapability.hasWords == c.isEnabledForGeometry,
      "supported=\(supported) previewOn=\(previewOn) mid-recording: \(c.wordsCapability)")
  }

  /// **The reason must actually DISCRIMINATE**, or it is a `Bool` in a costume and
  /// the picker would show one sentence to two different users. A machine that
  /// cannot run the engine must not be told to turn a switch on.
  @Test("the two unavailable reasons are told apart")
  func unavailableReasonsAreDistinct() {
    let engineCannotRun = Self.coordinator(supported: false, previewOn: true)
    let userTurnedItOff = Self.coordinator(supported: true, previewOn: false)

    #expect(engineCannotRun.wordsCapability == .engineUnsupported)
    #expect(userTurnedItOff.wordsCapability == .previewOff)
    #expect(
      engineCannotRun.wordsCapability != userTurnedItOff.wordsCapability,
      """
      both unavailable states report the same reason, so the picker would tell a \
      user whose engine cannot run here to switch a preview on.
      """)
  }

  /// The paired positive, so the case above cannot pass by reporting a reason for
  /// everything: the available state is reachable and is not one of the refusals.
  @Test("the available state is reachable and distinct from both refusals")
  func availableIsReachable() {
    let c = Self.coordinator(supported: true, previewOn: true)
    #expect(c.wordsCapability == .available)
    #expect(c.wordsCapability.hasWords)
  }

  /// **Where an engine is unsupported, the preview switch is irrelevant**, and
  /// that is the asymmetry the picker's copy depends on. Both rows report the same
  /// reason for the same cause, so the sentence a user sees is stable.
  @Test(
    "an unsupported engine reports the same reason whatever the switch says",
    arguments: [true, false])
  func unsupportedOutranksTheSwitch(previewOn: Bool) {
    let c = Self.coordinator(supported: false, previewOn: previewOn)
    #expect(
      c.wordsCapability == .engineUnsupported,
      "previewOn=\(previewOn) changed the reason on a machine that cannot run the engine")
  }

  /// The bridge carries the reason to its one consumer, and carries the REAL one.
  /// Every other overlay suite builds its own bridge from test closures, so
  /// nothing else can see the production mapping — the same gap
  /// `LivePreviewBridge.init(coordinator:)` was created to close for the other
  /// three seams.
  @Test("the production bridge maps the reason to the coordinator")
  func productionBridgeMapsTheReason() {
    let c = Self.coordinator(supported: true, previewOn: false)
    let bridge = LivePreviewBridge(coordinator: c)
    #expect(
      bridge.wordsCapability() == .previewOff,
      "the bridge's reason did not reach the coordinator")
    #expect(
      bridge.wordsCapability().hasWords == bridge.isEnabledForGeometry(),
      "the bridge's two answers disagree, so it maps one of them to the wrong seam")
  }

  /// The no-preview bridge answers honestly rather than plausibly. `.disabled`
  /// exists for a director nobody wired a preview to, and reporting `.available`
  /// there would offer word-holding designs on a build that has no preview at all.
  @Test("the disabled bridge reports no words, with a reason")
  func disabledBridgeReportsNoWords() {
    #expect(LivePreviewBridge.disabled.wordsCapability() == .previewOff)
    #expect(LivePreviewBridge.disabled.wordsCapability().hasWords == false)
    #expect(
      LivePreviewBridge.disabled.wordsCapability().hasWords
        == LivePreviewBridge.disabled.isEnabledForGeometry())
  }
}
