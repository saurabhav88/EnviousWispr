import AppKit
import Foundation

// MARK: - The late clipboard notice for a paste that went nowhere (#3106 PR B)
//
// The pipeline's clipboard cleanup keeps a dictation on the board when its paste went nowhere, and
// reports that about 0.3 s after the paste, when the take has usually finished and the overlay is
// idle. This owner turns that report into the EXISTING "Copied. Press ⌘V to paste" notice, but only
// while it is still true:
//
//   takeAccepted(takeID)                 every accepted session; the latest one wins
//   retained(takeID, changeCount)        from the cleanup, once per kept dictation
//   ├─ not the latest take               dropped: a newer dictation owns the screen
//   └─ present(.retainedClipboardFallback)
//      │  reducer: idle pipeline AND empty slot, or refused
//      │  isStillWanted()                read immediately before a deferred first render:
//      │                                 still the latest take AND the board still holds the
//      │                                 kept text (its change count is unchanged)
//      └─ onPresentation(takeID, shown)  the director's actual verdict, never inferred

/// What the notice needs from the overlay. `OverlayDirector` conforms; tests supply a fake.
@MainActor
protocol RetainedPasteNoticeHosting: AnyObject {
  @discardableResult
  func present(
    _ request: PillRequest, onResult: @escaping (PillPresentationResult) -> Void
  ) -> PillReceipt?
}

extension OverlayDirector: RetainedPasteNoticeHosting {}

@MainActor
final class RetainedPasteNotice {
  private var latestTakeID: String?
  private weak var host: (any RetainedPasteNoticeHosting)?
  private let boardChangeCount: @MainActor () -> Int
  /// The director's verdict for each notice this owner asked for: `true` only when it reached the
  /// screen. Chunk 4's `paste.landing_retained pill_shown` reads it.
  var onPresentation: (@MainActor (_ takeID: String, _ shown: Bool) -> Void)?

  /// Created before the drivers (they report into it from their first dictation); connected to the
  /// overlay once `OverlayDirector` exists.
  init(boardChangeCount: @escaping @MainActor () -> Int = { NSPasteboard.general.changeCount }) {
    self.boardChangeCount = boardChangeCount
  }

  func connect(_ host: any RetainedPasteNoticeHosting) {
    self.host = host
  }

  /// Every accepted session, from both engines' factories.
  func takeAccepted(_ takeID: String) {
    latestTakeID = takeID
  }

  /// The cleanup kept `takeID`'s dictation on the board; `changeCount` is the board's count at that
  /// moment, the receipt that says the board still holds it.
  func retained(takeID: String, changeCount: Int) {
    // The same two facts `isStillWanted` re-checks at render, checked before asking at all, so a
    // stale report never takes an admission.
    guard takeID == latestTakeID, boardChangeCount() == changeCount, let host else {
      onPresentation?(takeID, false)
      return
    }
    let request = PillRequest.retainedClipboardFallback(
      takeID: takeID,
      isStillWanted: { [weak self] in
        guard let self else { return false }
        return self.latestTakeID == takeID && self.boardChangeCount() == changeCount
      })
    host.present(request) { [weak self] result in
      guard let self else { return }
      switch result {
      case .presented: self.onPresentation?(takeID, true)
      case .notPresented: self.onPresentation?(takeID, false)
      }
    }
  }
}
