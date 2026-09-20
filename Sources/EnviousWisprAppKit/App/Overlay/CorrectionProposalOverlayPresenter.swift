import Foundation

// MARK: - The card's presenter adapter (#996 §3.1 step 9)
//
// The one object that speaks both vocabularies: `CorrectionProposalPresenting`
// on the coordinator's side (offer, showResult) and the director's typed pill
// boundary on the overlay's side (present, resolve, dismiss). It keeps no state
// of its own: identity is the reducer's `PresentationID`, whose UUID IS the
// coordinator's `CorrectionPresentationToken`, so both ends gate stale events
// on the same value without a lookup table between them.
//
// Callback order, per offer:
//   present(request, onResult)         the coordinator has recorded the attempt
//   │  isStillWanted()                 read by the director immediately before the
//   │                                  card is committed to the screen: a Pending click
//   │                                  that resolved the proposal during a deferred first
//   │                                  render rolls the offer back unrendered → .notPresented
//   ├─ .notPresented                   declined or rolled back: nothing is reported;
//   │                                  the offer is spent, the proposal waits in Pending
//   └─ .presented(receipt)             the card reached the screen:
//        coordinator.presentationAdmitted(id, token)
//   deliver(.accept | .reject)         → coordinator.resolve(id, decision, .card(token))
//   effect ended(presentation, reason) → coordinator.presentationEnded(id, token, reason)
//   showResult(model, token)           → director.resolveCorrectionProposal (same identity)

/// What the adapter needs from the overlay. `OverlayDirector` conforms; tests
/// supply a fake that records requests and answers `onResult` on demand.
@MainActor
protocol CorrectionProposalOverlayHosting: AnyObject {
  @discardableResult
  func present(
    _ request: PillRequest, onResult: @escaping (PillPresentationResult) -> Void
  ) -> PillReceipt?
  func resolveCorrectionProposal(
    id: UUID, presentation: PresentationID, outcome: CorrectionCardResult)
}

extension OverlayDirector: CorrectionProposalOverlayHosting {}

@MainActor
final class CorrectionProposalOverlayPresenter: CorrectionProposalPresenting {
  private let host: any CorrectionProposalOverlayHosting
  /// Strong on purpose: the coordinator holds its presenter weakly, so the
  /// composition root retains this adapter and this adapter retains the
  /// coordinator; there is no cycle.
  private let coordinator: CorrectionProposalCoordinator

  init(host: any CorrectionProposalOverlayHosting, coordinator: CorrectionProposalCoordinator) {
    self.host = host
    self.coordinator = coordinator
  }

  func offer(_ model: CorrectionProposalCardModel) {
    let coordinator = self.coordinator
    let request = PillRequest.correctionProposal(
      model: model,
      // Read by the director at the last moment before the card is drawn; a
      // proposal a Pending click already resolved is not offered again.
      isStillWanted: { coordinator.proposal(id: model.id)?.status == .pending },
      onAccept: { token in coordinator.resolve(id: model.id, .accept, surface: .card(token)) },
      onReject: { token in coordinator.resolve(id: model.id, .reject, surface: .card(token)) },
      onEnded: { token, reason in
        coordinator.presentationEnded(id: model.id, token: token, reason: reason)
      })
    host.present(request) { result in
      guard case .presented(let receipt) = result else { return }
      coordinator.presentationAdmitted(
        id: model.id, token: CorrectionPresentationToken(id: receipt.presentationID.rawValue))
    }
  }

  func showResult(_ model: CorrectionProposalCardModel, presentation: CorrectionPresentationToken) {
    guard case .result(let outcome) = model.phase else { return }
    host.resolveCorrectionProposal(
      id: model.id, presentation: PresentationID(rawValue: presentation.id), outcome: outcome)
  }
}
