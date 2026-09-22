import Foundation

// MARK: - The Undo pill's presenter adapter (#996, 2026-09-21 plan §3.1 step 9)
//
// The one object that speaks both vocabularies: `LearnedCorrectionPresenting`
// on the coordinator's side (show, showUndone, showError, showUndoError,
// close) and the director's typed pill boundary on the overlay's side
// (present, resolve, close). It keeps only the admitted presentation
// identities needed for same-identity result morphs; vocabulary and Undo
// state remain owned by the coordinator, and the reducer's `PresentationID`
// gates every morph.
//
// Callback order, per learned word:
//   present(request, onResult)          the coordinator has recorded the Undo
//   │  isStillWanted()                  read by the director immediately before the
//   │                                   pill is committed: a newer learn that replaced
//   │                                   the record rolls this offer back unrendered
//   ├─ .notPresented                    coordinator.pillEnded(pillID)
//   └─ .presented(receipt)              coordinator.pillAdmitted(pillID) (learn_undo_shown)
//   deliver(.undoLearnedCorrection)     → coordinator.undo(pillID:)
//   effect correctionLearnedEnded       → coordinator.pillEnded(pillID)
//   showUndone / showUndoError          → director.resolveLearnedCorrection (same identity)
//   close                               → director.closeLearnedCorrection (id-gated)

/// What the adapter needs from the overlay. `OverlayDirector` conforms; tests
/// supply a fake that records requests and answers `onResult` on demand.
@MainActor
protocol LearnedCorrectionOverlayHosting: AnyObject {
  @discardableResult
  func present(
    _ request: PillRequest, onResult: @escaping (PillPresentationResult) -> Void
  ) -> PillReceipt?
  func resolveLearnedCorrection(
    pillID: UUID, presentation: PresentationID, phase: LearnedCorrectionPillModel.Phase)
  func closeLearnedCorrection(pillID: UUID)
}

extension OverlayDirector: LearnedCorrectionOverlayHosting {}

@MainActor
final class LearnedCorrectionOverlayPresenter: LearnedCorrectionPresenting {
  private let host: any LearnedCorrectionOverlayHosting
  /// Strong on purpose: the coordinator holds its presenter weakly, so the
  /// composition root retains this adapter and this adapter retains the
  /// coordinator; there is no cycle.
  private let coordinator: LearnedCorrectionCoordinator
  /// The presentation identity of the pill this adapter last saw admitted,
  /// by pill id, so a result morph names the right `PresentationID` and a
  /// stale result (for a pill that was replaced) names nothing current.
  private var presentations: [UUID: PresentationID] = [:]

  init(host: any LearnedCorrectionOverlayHosting, coordinator: LearnedCorrectionCoordinator) {
    self.host = host
    self.coordinator = coordinator
  }

  func show(pill: LearnedCorrectionPillModel) {
    let coordinator = self.coordinator
    let request = PillRequest.correctionLearned(
      model: pill,
      // Read by the director at the last moment before the pill is drawn: a
      // record a newer learn replaced is not offered.
      isStillWanted: { coordinator.undoRecord?.pillID == pill.id },
      onUndo: { coordinator.undo(pillID: pill.id) },
      onEnded: { [weak self] in
        self?.presentations.removeValue(forKey: pill.id)
        coordinator.pillEnded(pillID: pill.id)
      })
    host.present(request) { [weak self] result in
      guard case .presented(let receipt) = result else {
        coordinator.pillEnded(pillID: pill.id)
        return
      }
      self?.presentations[pill.id] = receipt.presentationID
      coordinator.pillAdmitted(pillID: pill.id)
    }
  }

  func showUndone(pillID: UUID) {
    guard let presentation = presentations.removeValue(forKey: pillID) else { return }
    host.resolveLearnedCorrection(pillID: pillID, presentation: presentation, phase: .undone)
  }

  func showUndoError(_ error: LearnedCorrectionUndoError) {
    guard let presentation = presentations.removeValue(forKey: error.pillID) else { return }
    host.resolveLearnedCorrection(pillID: error.pillID, presentation: presentation, phase: .undoError)
  }

  func showError(_ error: LearnedCorrectionSaveError) {
    host.present(.correctionLearnedSaveError(error)) { _ in }
  }

  func close(pillID: UUID) {
    presentations.removeValue(forKey: pillID)
    host.closeLearnedCorrection(pillID: pillID)
  }
}
