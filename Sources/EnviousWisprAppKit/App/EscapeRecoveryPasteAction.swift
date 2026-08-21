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
  ///   - targetHasQuit: whether the app this dictation was aimed at is gone.
  ///     Injected because `NSRunningApplication.isTerminated` cannot be staged
  ///     in a unit test, and the branch it guards is the one that decides
  ///     whether the user's words land somewhere they never asked for.
  ///   - retarget: activate the app and refocus the field, injected for the same
  ///     reason `report` is. It defaults to the real AX calls, so production
  ///     reads exactly as it did; a test cannot otherwise observe that the
  ///     FIELD was restored, only that the app was, and those are the two
  ///     halves a cancel most often separates.
  static func paste(
    payload: CancelUndoPayload,
    restorable: (UUID) -> (text: String, stampedAt: Date, takeID: String?)?,
    report: (_ ageMs: Int, _ result: EscapeRecoveryPasteResult, _ takeID: String) -> Void,
    retarget: @MainActor (CancelUndoPayload) -> Bool = Self.defaultRetarget,
    targetHasQuit: (CancelUndoPayload) -> Bool = { $0.targetApp?.isTerminated == true },
    recordLog: @MainActor (_ outcome: String, _ ageMs: Int?, _ takeID: String?) -> Void = Self.log
  ) {
    guard let row = restorable(payload.transcriptID) else {
      // Lapsed between render and press. Silent TO THE USER, whose row is
      // already gone from view and who cannot act on the explanation — but no
      // longer silent to us. A press that produced nothing is the single most
      // likely thing a support conversation is about.
      recordLog("no-row", nil, nil)
      return
    }

    PasteService.copyToClipboard(row.text)

    // A TARGET THAT HAS QUIT MUST NOT BE PASTED PAST (cloud review).
    //
    // The app the dictation was aimed at can quit while the recovery is still
    // transcribing, or while the pill is on screen. Activation then fails
    // silently — `forceActivateApp` against a dead pid, `activate()` on a
    // terminated `NSRunningApplication` — and the unconditional Cmd-V that
    // follows lands in whatever happens to be frontmost NOW. That is the user's
    // words arriving in an unrelated application, which is worse than not
    // restoring them at all. PID reuse makes it worse still: the pid can belong
    // to a replacement process by then.
    //
    // Distinct from a NIL target, which stays as it was and pastes wherever
    // focus is. Nil means no target was ever captured, which is History's
    // shipped behaviour and a documented normal case; terminated means we knew
    // where the text belonged and that place is gone.
    //
    // The text is already on the clipboard by this point, so the user still has
    // it and the row still stands in History for 24 hours. `.clipboardOnly` is
    // the vocabulary's own word for exactly this — "the target was gone, so the
    // text went to the clipboard instead. Still a restore."
    if targetHasQuit(payload) {
      Self.finish(
        .clipboardOnly, stampedAt: row.stampedAt, takeID: row.takeID, report: report,
        recordLog: recordLog)
      return
    }

    // A RETARGET THAT FAILED MUST NOT BE FOLLOWED BY A KEYSTROKE.
    //
    // The app can be alive while the FIELD is gone: the view closed, the
    // document was shut, the element refuses focus. `focusElement` says so, and
    // ignoring it sent Cmd-V anyway — into whatever that app has focused now.
    // The user dictated into one box and the words arrive in another, which is
    // the same harm as the terminated case one branch above, one level finer.
    //
    // The text is already on the clipboard, so refusing costs nothing: the user
    // pastes it themselves, or takes it from History for the next 24 hours.
    guard retarget(payload) else {
      Self.finish(
        .clipboardOnly, stampedAt: row.stampedAt, takeID: row.takeID, report: report,
        recordLog: recordLog)
      return
    }
    // `NSApp?`, not `NSApp`. It is an implicitly-unwrapped optional and is nil
    // in any process that is not a running application, so the bare form traps.
    // Found 2026-08-18: this suite PASSES in a full run — something earlier
    // brings `NSApplication` up — and CRASHES when run alone, which is an order
    // dependency hiding in what looks like a settled test. Hiding ourselves is
    // a courtesy so the target app is visible when the keystroke lands; the
    // paste does not depend on it, so a nil app must skip it, never trap.
    NSApp?.hide(nil)
    Task {
      try? await Task.sleep(for: .milliseconds(TimingConstants.appHideBeforePasteDelayMs))
      PasteService.simulatePaste()
    }

    // Reported as `.pasted` because that is what was ATTEMPTED and what the user
    // asked for. There is deliberately no `.failed` case in the vocabulary: a
    // simulated paste gives no completion signal, so a failure value here would
    // be a guess presented as a measurement.
    //
    Self.finish(
      .pasted, stampedAt: row.stampedAt, takeID: row.takeID, report: report,
      recordLog: recordLog)
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
  /// somewhere they never dictated them.
  ///
  /// - Returns: whether the caller may paste. False means a field WAS captured
  ///   and could not be focused, so the place those words belong is gone and a
  ///   keystroke would put them somewhere else.
  ///
  /// **What this verifies, stated rather than implied.** The FIELD, because
  /// `AXUIElementSetAttributeValue` returns a definite answer. NOT that the app
  /// came frontmost: `forceActivateApp` reports only its own call, and polling
  /// `isActive` afterwards is a race with no clean settle. The app-level failure
  /// that actually happens — the app quit — is refused by the caller before this
  /// is reached.
  ///
  /// A nil TARGET APP returns true: nothing was ever captured, so there is
  /// nothing to return to and the paste goes where focus is, exactly as
  /// History's button does. A nil ELEMENT with a live app also returns true —
  /// an app-only target is a documented normal case.
  ///
  /// What does NOT return true is a captured target we failed to reach. An
  /// earlier revision returned true whenever no element was captured, whatever
  /// activation did, so an app that refuses to come forward still got a
  /// keystroke — sent to whoever is frontmost instead. The reasoning behind that
  /// was right about History and wrong about the pill: History activates
  /// nothing, so it promises nothing, while returning to the target app is the
  /// entire reason this pill exists.
  private static func defaultRetarget(_ payload: CancelUndoPayload) -> Bool {
    retargetWithAccessibility(payload)
  }

  @MainActor
  static func retargetWithAccessibility(
    _ payload: CancelUndoPayload,
    forceActivate: (pid_t) -> Bool = PasteService.forceActivateApp,
    activateFallback: (NSRunningApplication) -> Bool = { $0.activate() },
    focusElement: (AXUIElement) -> Bool = PasteService.focusElement
  ) -> Bool {
    guard let app = payload.targetApp else { return true }
    // Both routes report. `forceActivateApp` is the AX path macOS 14+ needs for
    // a background process; `activate()` is the fallback when Accessibility is
    // refused, in which case the paste was never going to work anyway.
    guard forceActivate(app.processIdentifier) || activateFallback(app) else {
      return false
    }
    guard let element = payload.targetElement else { return true }
    return focusElement(element)
  }
}
