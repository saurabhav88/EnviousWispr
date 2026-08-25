import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLivePreview

/// The pill's VERDICT and the picker's REASON, and where they must part company
/// (#2376 Phase 4, C4; scope corrected by cloud review on C7).
///
/// **TWO PROPERTIES ANSWERING TWO QUESTIONS, and an earlier version of this suite
/// asserted they were one.** `isEnabledForGeometry` answers "what is THIS
/// recording doing" and reads a frozen snapshot, so a pill on screen cannot
/// resize when a setting moves underneath it. `wordsCapability` answers "what
/// will the NEXT recording do", which is what the Appearance picker has to say,
/// and reads live.
///
/// They agree outside a recording and DIVERGE during one. Both directions are
/// asserted here, because the agreement was the easy half to write and the
/// divergence is the half a user can be lied to by.
///
/// The picker needs a reason at all because greying out a group of designs
/// without saying WHY is the shape this repo already records as "visible and
/// inaudible", and a `Bool` cannot carry one. Phase 3's seam comment forbids
/// Phase 4 from changing where the DIRECTOR resolves capability, so the verdict
/// is untouched and the reason is additive; the cost of additive is a second
/// authority, and this suite is what pays it.
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
  /// **Scoped to OUTSIDE a recording and to NO REMOVAL IN FLIGHT**, which is where
  /// the two answer the same question. Both exclusions are real divergences with a
  /// case of their own below, not conditions swept under the rug: during a
  /// recording the verdict is frozen and this is not, and during a removal drain
  /// this refuses while the verdict's live branch does not read the suppression at
  /// all. Fresh coordinators are never mid-removal, so every row here is inside
  /// the scope by construction.
  @Test(
    "outside a recording, the reason says available exactly when the verdict says enabled",
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

  /// **THE TWO DELIBERATELY DIVERGE DURING A RECORDING, and this is the case
  /// cloud review's second P2 exists as.**
  ///
  /// `isEnabledForGeometry` answers "what is THIS recording doing" and reads the
  /// frozen snapshot, because a pill already on screen must not resize when a
  /// setting moves underneath it. `wordsCapability` answers "what will the NEXT
  /// recording do", which is what the Appearance picker has to say.
  ///
  /// Settings is reachable WHILE recording — the menu item carries no recording
  /// gate and the Live Preview toggle is disabled only when no engine is
  /// available — so this sequence is a real user's, not a contrived one: start a
  /// take, switch Live Preview off, open Appearance. An earlier version honoured
  /// the snapshot here and would have told that user "Live Preview is on, so the
  /// pill shows your words" about a recording where it will not be, contradicting
  /// the panel's own promise that changes apply the next time you record.
  @Test("mid-recording, the pill keeps its frozen verdict and the picker does not")
  func thePickerAnswersTheNextRecordingNotThisOne() {
    var previewOn = true
    let c = LivePreviewCoordinator(
      readSamples: { _ in ([], 0) },
      isPreviewOn: { previewOn },
      languageMode: { .locked("en") },
      selectedRoute: {
        LivePreviewEngineRoute(
          telemetryEngineID: "universal",
          isSupportedOnThisSystem: { true },
          resolve: { _ in .blocked(.unsupportedSystem) })
      })

    c.setRecording(true)
    #expect(c.isEnabledForGeometry, "control: this recording began with words available")
    #expect(c.wordsCapability == .available, "control: so does the next one, so far")

    // The user opens Settings mid-take and switches Live Preview off.
    previewOn = false

    #expect(
      c.isEnabledForGeometry,
      """
      the LIVE pill's verdict moved when the setting did. A recording already on \
      screen must keep the geometry it was sized for; re-reading here is what makes \
      a pill resize mid-dictation.
      """)
    #expect(
      c.wordsCapability == .previewOff,
      """
      the picker still reports words available for the NEXT recording after the user \
      turned Live Preview off. It would enable the wrong group and print a reason \
      that is false by the time the user records again.
      """)
  }

  /// **The reason must actually DISCRIMINATE**, or it is a `Bool` in a costume and
  /// the picker would show one sentence to two different users. A machine that
  /// cannot run the engine must not be told to turn a switch on.
  @Test("the two settings-shaped causes are told apart")
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

  /// **THIS PROPERTY'S COMPLETENESS CRITERION, asserted rather than described:
  /// what it reports is what `setRecording(true)` would freeze right now.**
  ///
  /// Cloud review's THIRD finding on this one property, and the first two are why
  /// it is written this way. The original read a frozen snapshot, which made it
  /// answer the wrong recording. The correction made it read live and still missed
  /// a condition, because "read the live settings" names the INPUTS and a
  /// condition absent from that list is invisible to it. Mirroring a decision
  /// names the decision instead, so the test can hold the two side by side.
  ///
  /// The user's sequence is real: press Remove on the selected model, and while
  /// the drain is still running start another recording. That recording is frozen
  /// wordless by `setRecording`. Appearance said the with-words designs were
  /// available.
  @Test("mid-removal, the picker reports what the next recording would actually get")
  func removalSuppressionReachesThePicker() async {
    let c = Self.coordinator(supported: true, previewOn: true)
    #expect(c.wordsCapability == .available, "control: words are available before the removal")

    await c.releaseAndDrainForRemoval()

    #expect(
      c.wordsCapability == .modelBeingRemoved,
      """
      the picker still offers the with-words designs during a removal drain, so a \
      user starting a recording now gets a wordless pill while Appearance says \
      otherwise.
      """)
    #expect(!c.wordsCapability.hasWords)

    // The mirror claim itself: what the picker reports is what the freeze does.
    c.setRecording(true)
    #expect(
      !c.isEnabledForGeometry,
      """
      the recording started during a removal drain was NOT frozen wordless, so the \
      premise this property mirrors is false and its reason is the wrong one.
      """)
    c.setRecording(false)

    // And the suppression lifts, so the reason is transient rather than sticky.
    c.endRemovalSuppression()
    #expect(
      c.wordsCapability == .available,
      "the removal reason outlived the removal, so the picker stays wrong afterwards")
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

  /// **A CAPABILITY NOBODY IS TOLD ABOUT IS A STALE PAGE, and this is the input
  /// that has no settings key to announce it** (cloud review round 4).
  ///
  /// Every other input to `wordsCapability` is settings-backed, so a page reading
  /// it registers a dependency and refreshes on its own. Removal suppression is a
  /// private field on a class that is not `@Observable`, and the capability's
  /// guard returns on it BEFORE any settings read — so during a drain the page
  /// depends on nothing, and the end of the drain cannot invalidate it.
  ///
  /// Both transitions are asserted because the user meets them in both
  /// directions: removal starting while the page is open, and finishing while
  /// they are looking at it.
  @Test("both ends of a removal are announced to whoever is watching")
  func removalTransitionsAreAnnounced() async {
    let c = Self.coordinator(supported: true, previewOn: true)
    var announcements = 0
    c.onWordsCapabilityMayHaveChanged = { announcements += 1 }

    await c.releaseAndDrainForRemoval()
    #expect(
      announcements >= 1,
      """
      the removal began and nothing was announced, so a page already showing the \
      with-words designs keeps offering what the next recording will not deliver.
      """)
    #expect(c.wordsCapability == .modelBeingRemoved, "control: the state did change")

    let afterBegin = announcements
    c.endRemovalSuppression()
    #expect(
      announcements > afterBegin,
      """
      the removal ENDED and nothing was announced. This is the direction a user \
      actually meets: the drain finishes while they are on the page, and the \
      removal sentence stays up over designs that are available again.
      """)
    #expect(c.wordsCapability == .available, "control: the state changed back")
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
