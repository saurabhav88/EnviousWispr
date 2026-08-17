import EnviousWisprCore
import EnviousWisprModelDelivery
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2123 chunk F1 — what each engine card says, in every state.
///
/// The plan's acceptance is "no state where the page offers no actionable next
/// step", scoped to RECOVERABLE states. So the load-bearing test is the
/// exhaustive walk at the bottom: it enumerates every delivery state and asserts
/// each one produces either an action or an explanation the user can act on
/// elsewhere — and names the single deliberate exception.
@Suite struct LivePreviewEnginePresentationTests {

  private func universal(
    selected: Bool = false, routeExists: Bool = true, _ state: DeliveryState
  ) -> LivePreviewEnginePresentation.Card {
    LivePreviewEnginePresentation.universalCard(
      isSelected: selected, routeExists: routeExists, state: state)
  }

  @Test("both engines describe themselves in every state, since there is no Help article yet")
  func descriptionsAlwaysRender() {
    let apple = LivePreviewEnginePresentation.appleCard(isSelected: true, isSupported: true)
    let appleOld = LivePreviewEnginePresentation.appleCard(isSelected: false, isSupported: false)
    #expect(!apple.description.isEmpty)
    #expect(appleOld.description == apple.description, "the description cannot depend on support")

    for state in Self.everyState {
      #expect(!universal(state).description.isEmpty, "no description in \(state)")
      #expect(
        !universal(routeExists: false, state).description.isEmpty,
        "even an unbuildable engine must say what it would have been")
    }
  }

  @Test("Apple's card explains the OS requirement rather than going blank")
  func appleStatesItsRequirement() {
    let supported = LivePreviewEnginePresentation.appleCard(isSelected: true, isSupported: true)
    #expect(supported.unavailability == nil)
    #expect(supported.action == nil, "we never download or remove Apple's engine")

    let unsupported = LivePreviewEnginePresentation.appleCard(isSelected: false, isSupported: false)
    #expect(unsupported.unavailability == LivePreviewEngineCopy.appleNeedsNewerMacOS)
  }

  @Test("a download in flight offers cancel and reports its progress")
  func downloadingShowsProgressAndCancel() {
    let card = universal(.downloading(fractionCompleted: 0.42, bytesWritten: 1, totalBytes: 2))
    #expect(card.action == .cancelDownload)
    #expect(card.progress == 0.42)
    #expect(card.unavailability == nil, "a running download is not an unavailability")
  }

  /// **The verb follows `resumable`; the COPY must claim nothing beyond it.**
  ///
  /// `resumable` reports whether staged partials exist — not whether the next
  /// attempt starts from zero, because verified components can survive and be
  /// skipped. So "Resume" is honest when it is true, and the false case says the
  /// download stopped without promising a fresh start. An earlier draft here
  /// promised exactly that, and it sounded careful while being wrong.
  @Test("a cancelled download offers resume only when there is something to resume")
  func cancelledDistinguishesResumable() {
    let resumable = universal(.cancelled(resumable: true))
    #expect(resumable.action == .resumeDownload)
    #expect(resumable.unavailability == LivePreviewEngineCopy.downloadCancelled)

    let stopped = universal(.cancelled(resumable: false))
    #expect(stopped.action == .download, "no staged partials, so the verb is download")
    #expect(stopped.unavailability == LivePreviewEngineCopy.downloadStopped)
    #expect(
      !LivePreviewEngineCopy.downloadStopped.lowercased().contains("beginning"),
      "this copy must not promise a restart it cannot guarantee")
  }

  /// A progress value the UI cannot draw must become NO bar, not a wrong one.
  ///
  /// Manifest validation permits zero or non-positive sizes, so the delivery
  /// layer can hand over a NaN or an out-of-range fraction.
  @Test("unrenderable progress becomes no progress rather than a nonsense bar")
  func progressIsAlwaysRenderable() {
    #expect(LivePreviewEnginePresentation.renderableProgress(.nan) == nil)
    #expect(LivePreviewEnginePresentation.renderableProgress(.infinity) == nil)
    #expect(LivePreviewEnginePresentation.renderableProgress(-0.5) == 0)
    #expect(LivePreviewEnginePresentation.renderableProgress(1.7) == 1)
    #expect(LivePreviewEnginePresentation.renderableProgress(0.25) == 0.25)

    // Through the real card, not just the helper.
    let nanCard = universal(
      .downloading(fractionCompleted: .nan, bytesWritten: 0, totalBytes: 0))
    #expect(nanCard.progress == nil, "a NaN fraction reached the card")
    #expect(nanCard.action == .cancelDownload, "control: it is still a running download")
  }

  @Test("an installed engine offers removal, so 217 MB is reclaimable")
  func admittedOffersRemove() {
    let card = universal(.admitted)
    #expect(card.action == .remove)
    #expect(card.unavailability == nil)
  }

  @Test("a build without the engine says so and offers nothing to press")
  func buildDefectOffersNoFalseRemedy() {
    // Delivery state is irrelevant here: there is nothing registered to download.
    for state in Self.everyState {
      let card = universal(routeExists: false, state)
      #expect(card.unavailability == LivePreviewEngineCopy.unavailableInThisBuild)
      #expect(card.action == nil, "a build defect must not offer a button that cannot help")
      #expect(card.progress == nil)
    }
  }

  /// THE EXHAUSTIVE WALK. Every delivery state, with a real route, must leave the
  /// user something to do or something true to read.
  @Test("every state either offers an action or explains itself")
  func noDeadEnds() {
    for state in Self.everyState {
      let card = universal(state)
      #expect(
        card.action != nil || card.unavailability != nil || card.progress != nil,
        "\(state) renders a card with no action, no explanation and no progress")
    }
  }

  /// Both cards must be able to show as selected, or the picker cannot indicate
  /// which engine is in use.
  @Test("selection is carried through, for both engines and every state")
  func selectionIsCarried() {
    #expect(LivePreviewEnginePresentation.appleCard(isSelected: true, isSupported: true).isSelected)
    #expect(
      !LivePreviewEnginePresentation.appleCard(isSelected: false, isSupported: true).isSelected)
    for state in Self.everyState {
      #expect(universal(selected: true, state).isSelected, "selection lost in \(state)")
      #expect(!universal(selected: false, state).isSelected)
    }
  }

  /// Every case of the delivery state, listed once.
  ///
  /// Hand-maintained because `DeliveryState` has associated values and cannot be
  /// `CaseIterable`. If a case is added and not listed here these tests keep
  /// passing — so the real enforcement is the exhaustive `switch` in the
  /// presentation, which will not compile until the new state is handled. This
  /// list is what checks the ANSWERS; the compiler is what checks the coverage.
  static let everyState: [DeliveryState] = [
    .notReady,
    .preparing(validatingExistingCache: false),
    .preparing(validatingExistingCache: true),
    .downloading(fractionCompleted: 0.1, bytesWritten: 1, totalBytes: 10),
    .verifying,
    .admitted,
    .cancelled(resumable: true),
    .cancelled(resumable: false),
    .failed(DeliveryFailure(reason: .source5xx, detail: "test")),
  ]
}
