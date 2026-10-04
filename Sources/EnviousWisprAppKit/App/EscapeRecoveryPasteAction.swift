import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// What the Escape Recovery pill's Paste button does (#2087, chunk 12).
///
/// **Until this existed the button was decoration.** onEscapeRecoveryPaste was
/// declared, the pill rendered it, and nothing bound it — so the feature's one
/// visible promise, "we kept it, press to put it back", did nothing at all while
/// every layer beneath it passed its tests.
///
/// #3437: Undo has no paste of its own. It asks the coordinator for the text BY ID and hands it,
/// with the target the take captured, to `HeldTextDelivery`, which runs the dictation delivery's
/// own Smart Insertion and paste cascade. The text lands exactly where a dictation finishing at the
/// press would land; where that dictation would fall back to the clipboard, Undo shows the same
/// Copied notice.
@MainActor
enum EscapeRecoveryPasteAction {

  /// - Parameters:
  ///   - payload: the retained target, window, Smart Insertion facts and the row's id.
  ///   - restorable: the coordinator's single authority — text, stamp and join
  ///     key for the SAME row at the SAME instant, or nil if it may not be
  ///     restored. **Inert, not merely harmless**: pasting a cached snapshot
  ///     would hand back text the user was told had gone, which is the one thing
  ///     the 24-hour promise forbids.
  ///   - deliver: the held-text delivery (production: `HeldTextDelivery.deliver`), given the row's
  ///     text, the payload and the row's take id. Injected so tests never touch a real field or
  ///     the developer's clipboard.
  ///   - presentNotice: the guarded Copied notice for a fallback, given the result, the take id
  ///     and the row's id.
  ///   - report: the restore event, injected so a test can read it.
  static func paste(
    payload: CancelUndoPayload,
    restorable: (UUID) -> (text: String, stampedAt: Date, takeID: String?)?,
    deliver: @MainActor (String, CancelUndoPayload, String?) async -> HeldTextDeliveryResult,
    presentNotice: @MainActor (HeldTextDeliveryResult, _ takeID: String?, _ transcriptID: UUID) ->
      Void,
    report: (_ ageMs: Int, _ result: EscapeRecoveryPasteResult, _ takeID: String) -> Void,
    recordLog: @MainActor (_ outcome: String, _ ageMs: Int?, _ takeID: String?) -> Void = Self.log
  ) async {
    guard let row = restorable(payload.transcriptID) else {
      // Lapsed between render and press. Silent TO THE USER, whose row is
      // already gone from view and who cannot act on the explanation — but no
      // longer silent to us. A press that produced nothing is the single most
      // likely thing a support conversation is about.
      recordLog("no-row", nil, nil)
      return
    }

    let result = await deliver(row.text, payload, row.takeID)
    switch result.outcome {
    case .pasted:
      Self.finish(
        .pasted, stampedAt: row.stampedAt, takeID: row.takeID, report: report,
        recordLog: recordLog)
    case .clipboardOnly, .accessibilityDenied:
      // The text is on the clipboard, so this is still a restore: the user has their words back
      // and the row stands in History for 24 hours. The notice tells them where the words went.
      presentNotice(result, row.takeID, payload.transcriptID)
      Self.finish(
        .clipboardOnly, stampedAt: row.stampedAt, takeID: row.takeID, report: report,
        recordLog: recordLog)
    }
  }

  /// Record the outcome once, on every path, to BOTH channels.
  ///
  /// Founder 2026-08-18: "we should be able to tell post hoc how often this
  /// feature is being leveraged... and if for whatever reason it fails, we
  /// should know". Two channels, because they answer questions neither can
  /// answer alone: telemetry aggregates across users and is how the feature
  /// earns its keep; the app log is the only thing a support conversation about
  /// ONE user can read, and this path wrote nothing to it at all.
  ///
  /// **A MISSING TAKE ID NO LONGER SWALLOWS THE WHOLE EVENT.** It still
  /// suppresses the TELEMETRY — no join key means an event that inflates a
  /// denominator and answers nothing, the rule every event in this funnel
  /// follows — but the restore is now LOGGED as the anomaly it is. The earlier
  /// shape returned early, so the restore vanished from both channels at once:
  /// a silent subtraction from the exact count the feature is judged on, and
  /// invisible precisely because it never happens in a test.
  private static func finish(
    _ result: EscapeRecoveryPasteResult,
    stampedAt: Date,
    takeID: String?,
    report: (_ ageMs: Int, _ result: EscapeRecoveryPasteResult, _ takeID: String) -> Void,
    recordLog: @MainActor (_ outcome: String, _ ageMs: Int?, _ takeID: String?) -> Void
  ) {
    let ageMs = Int(Date().timeIntervalSince(stampedAt) * 1000)
    recordLog(result.rawValue, ageMs, takeID)
    guard let takeID else { return }
    report(ageMs, result, takeID)
  }

  /// One line per restore attempt, describing its SHAPE and never its content.
  ///
  /// No transcript, no text, no target application: the privacy boundary is the
  /// same here as everywhere else, and a debug log is still the user's machine.
  /// `take` is our own opaque join key, not anything they said.
  private static func log(outcome: String, ageMs: Int?, takeID: String?) {
    let age = ageMs.map(String.init) ?? "n/a"
    // The anomaly is carried by the TEXT, not by a level. `DebugLogLevel` has
    // only info/verbose/debug — there is no error level to raise it to — and a
    // marker that greps is worth more here anyway: whoever reads this file is
    // searching it, not filtering by severity.
    let take = takeID ?? "MISSING (restore not reported to telemetry)"
    Task {
      await AppLogger.shared.log(
        "escape recovery restore: outcome=\(outcome) age_ms=\(age) take=\(take)",
        level: .info,
        category: "EscapeRecovery"
      )
    }
  }
}
