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
  ///   - retarget: activate the app and refocus the field, injected for the same
  ///     reason `report` is. It defaults to the real AX calls, so production
  ///     reads exactly as it did; a test cannot otherwise observe that the
  ///     FIELD was restored, only that the app was, and those are the two
  ///     halves a cancel most often separates.
  static func paste(
    payload: CancelUndoPayload,
    restorable: (UUID) -> (text: String, stampedAt: Date, takeID: String?)?,
    report: (_ ageMs: Int, _ result: EscapeRecoveryPasteResult, _ takeID: String) -> Void,
    retarget: @MainActor (CancelUndoPayload) -> Void = Self.retargetWithAccessibility
  ) {
    guard let row = restorable(payload.transcriptID) else {
      // Lapsed between render and press. Silent: the row is already gone from
      // the user's view, and a message about text they can no longer see would
      // explain a state they cannot act on.
      return
    }

    PasteService.copyToClipboard(row.text)
    retarget(payload)
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

  /// The production retarget: bring back the app, then the field.
  ///
  /// `forceActivateApp` and not `NSRunningApplication.activate()`. macOS 14+
  /// restricts a background process from taking focus, so the plain call fails
  /// quietly and the paste lands wherever focus already was; the AX route is the
  /// one this app already ships for exactly that restriction. It needs
  /// Accessibility permission, which the paste itself needs anyway, so
  /// `activate()` is the fallback for the case where nothing was going to be
  /// pasted regardless.
  ///
  /// Then the FIELD, which is the half that is easy to drop. Restoring the app
  /// alone hands the caret back to wherever that app last left it, and after a
  /// cancel that is frequently a different field — so the user's words arrive
  /// somewhere they never dictated them. A nil element is normal and documented,
  /// not a failure: an app-only target still pastes wherever focus lands.
  @MainActor
  static func retargetWithAccessibility(_ payload: CancelUndoPayload) {
    if let app = payload.targetApp {
      if !PasteService.forceActivateApp(pid: app.processIdentifier) { app.activate() }
    }
    if let element = payload.targetElement { PasteService.focusElement(element) }
  }
}
