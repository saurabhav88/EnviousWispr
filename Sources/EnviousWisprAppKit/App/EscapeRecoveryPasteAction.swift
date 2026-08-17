import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// What the Escape Recovery pill's Paste button does (#2087, chunk 12).
///
/// **Until this existed the button was decoration.** `onEscapeRecoveryPaste` was
/// declared, the pill rendered it, and nothing bound it — so the feature's one
/// visible promise, "we kept it, press to put it back", did nothing at all while
/// every layer beneath it passed its tests.
///
/// Reuses History's shipped path rather than inventing one: ask the coordinator
/// for the text BY ID, copy, then paste. The single thing the pill adds is the
/// TARGET — it brings back the app the dictation was aimed at, which is the
/// whole reason the payload retains a handle to it.
@MainActor
enum EscapeRecoveryPasteAction {

  /// - Parameters:
  ///   - payload: the retained target and the row's id.
  ///   - restorable: the coordinator's single authority — text, stamp and join
  ///     key for the SAME row at the SAME instant, or nil if it may not be
  ///     restored. **Inert, not merely harmless**: pasting a cached snapshot
  ///     would hand back text the user was told had gone, which is the one thing
  ///     the 24-hour promise forbids.
  ///   - report: the restore event, injected so a test can read it.
  static func paste(
    payload: CancelUndoPayload,
    restorable: (UUID) -> (text: String, stampedAt: Date, takeID: String?)?,
    report: (_ ageMs: Int, _ result: EscapeRecoveryPasteResult, _ takeID: String) -> Void
  ) {
    guard let row = restorable(payload.transcriptID) else {
      // Lapsed between render and press. Silent: the row is already gone from
      // the user's view, and a message about text they can no longer see would
      // explain a state they cannot act on.
      return
    }

    PasteService.copyToClipboard(row.text)
    // The pill's advantage over History: go back to the app the dictation was
    // aimed at, rather than whatever happens to be frontmost now. `activate`
    // fails quietly for an app that has since quit, and the paste then lands
    // wherever focus actually is — the same cascade History relies on.
    payload.targetApp?.activate()
    NSApp.hide(nil)
    Task {
      try? await Task.sleep(for: .milliseconds(TimingConstants.appHideBeforePasteDelayMs))
      PasteService.simulatePaste()
    }

    // Reported as `.pasted` because that is what was ATTEMPTED and what the user
    // asked for. There is deliberately no `.failed` case in the vocabulary: a
    // simulated paste gives no completion signal, so a failure value here would
    // be a guess presented as a measurement.
    //
    // No take id means no join key, so the event is dropped rather than emitted
    // unmatched — the same rule every other event in this funnel follows.
    guard let takeID = row.takeID else { return }
    report(Int(Date().timeIntervalSince(row.stampedAt) * 1000), .pasted, takeID)
  }
}
