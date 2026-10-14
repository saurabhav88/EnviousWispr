#if DEBUG
  import Foundation
  import Observation

  /// Plays sample pills for a developer (#3736). It sends a `PillRequest` through the same
  /// `OverlayPresenting` door a real pill uses, so `PillCatalog` and the real views draw and
  /// time it. It owns no pill logic.
  ///
  /// **It never replaces anything real.** The reducer cannot tell a preview from a real
  /// request, so a preview could end a live recording or clear a real Undo offer. Play
  /// therefore refuses unless the real pipeline is idle and the overlay is either empty or
  /// still showing this controller's own last preview.
  @MainActor
  @Observable
  final class PillPreviewController {

    enum Outcome: Equatable {
      case idle
      /// Admitted, host has not answered yet.
      case pending(String)
      case shown(String)
      case notShown(String)
    }

    /// Reveals the controls. Not persisted. Turning it off clears this controller's own preview.
    var isReviewEnabled = false {
      didSet { if !isReviewEnabled { dismiss() } }
    }
    var selectedID: String

    private(set) var outcome: Outcome = .idle
    /// The last thing a sample button or expiry told us, for the status line.
    private(set) var lastEvent: String?

    @ObservationIgnored private var lastReceipt: PillReceipt?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private let presenter: any OverlayPresenting
    @ObservationIgnored private let isPipelineBusy: @MainActor () -> Bool
    @ObservationIgnored private let overlayIsEmpty: @MainActor () -> Bool
    @ObservationIgnored let entries: [PillPreviewEntry]

    init(
      presenter: any OverlayPresenting,
      isPipelineBusy: @escaping @MainActor () -> Bool,
      overlayIsEmpty: @escaping @MainActor () -> Bool,
      entries: [PillPreviewEntry] = PillPreviewCatalog.all
    ) {
      self.presenter = presenter
      self.isPipelineBusy = isPipelineBusy
      self.overlayIsEmpty = overlayIsEmpty
      self.entries = entries
      self.selectedID = entries.first?.id ?? ""
    }

    var selectedEntry: PillPreviewEntry? { entries.first { $0.id == selectedID } }

    /// Whether Play may present right now. Pipeline idle AND (overlay empty OR still our own
    /// preview). `featureSlotIsAvailable` is deliberately not used: it is not an emptiness
    /// test (it is true for several real pills).
    private var isEligible: Bool {
      guard !isPipelineBusy() else { return false }
      if overlayIsEmpty() { return true }
      if let lastReceipt { return presenter.isCurrent(lastReceipt) }
      return false
    }

    func play() {
      guard let entry = selectedEntry else { return }
      guard isEligible else {
        outcome = .notShown("a real dictation or a real pill is on screen")
        return
      }
      // Replace only our own preview: clear it first, then check the slot again.
      if let receipt = lastReceipt, presenter.isCurrent(receipt) {
        presenter.dismissIfCurrent(receipt)
        lastReceipt = nil
        guard isEligible else {
          outcome = .notShown("the previous preview did not clear")
          return
        }
      }

      attempt += 1
      let thisAttempt = attempt
      lastEvent = nil
      outcome = .pending(entry.title)

      let request = entry.make { [weak self] text in
        guard let self, thisAttempt == self.attempt else { return }
        self.lastEvent = text
      }
      lastReceipt = presenter.present(request) { [weak self] result in
        guard let self, thisAttempt == self.attempt else { return }
        switch result {
        case .presented:
          self.outcome = .shown(entry.title)
        case .notPresented:
          self.outcome = .notShown("the overlay refused it")
        }
      }
    }

    /// Clears only this controller's own preview, never a pill that replaced it.
    func dismiss() {
      if let lastReceipt { presenter.dismissIfCurrent(lastReceipt) }
      lastReceipt = nil
      attempt += 1
      outcome = .idle
      lastEvent = nil
    }
  }
#endif
