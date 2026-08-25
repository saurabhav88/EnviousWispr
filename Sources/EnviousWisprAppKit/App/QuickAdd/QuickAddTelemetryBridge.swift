import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// Maps `QuickAddEvent` onto the telemetry vendors (#2381).
///
/// **Deleting this file leaves Quick Add working, silently.** That is the point, and it is the test
/// of whether observability was wired in or bolted on: the coordinator emits facts and names no
/// vendor, so nothing about the feature's behaviour depends on anyone listening. Modelled on
/// `EGOneTelemetryBridge`, which exists for the same reason one module over.
///
/// **THE ROUTING IS THE DECISION, and the three destinations answer different questions.** PostHog
/// gets the two shape-only events, because they are about how the feature performs across users.
/// Sentry gets a BREADCRUMB TRAIL — open, resolve and failure — because its job is to explain a crash
/// that happens next, and a trail with only the failures in it cannot say how the user got there. It
/// gets no Sentry EVENT and no `ErrorCategory`, which is the part that stays true. The local log gets
/// a support line — and the heard word is NOT in it, including under Debug Mode.
///
/// That distinction was wrong in this comment until the confirming review round: it read "Sentry gets
/// FAILURES only", which described the code and contradicted §3e, and the code was the thing that was
/// wrong. A comment agreeing with defective code is the shape that retires the check instead of
/// failing it.
///
/// That last one was argued the other way first: `CORRECTION_DEBUG` already writes full transcripts
/// to `app.log` behind the Debug Mode gate, so a heard word there looked like it widened nothing.
/// Review overruled it — `observability-operations.md` says local lines carry never user content with
/// NO Debug Mode exception, and the precedent was UNCHECKED. The support cost is real and accepted:
/// a user reporting "it added the wrong word" cannot be answered from their log alone.
enum QuickAddTelemetryBridge {

  /// The handler the composition root installs on the coordinator.
  @MainActor
  static var handler: (QuickAddEvent) -> Void {
    { event in
      switch event {
      case .opened(
        let door, let refusal, let bundleID, let heardScalarCount, let candidateCount,
        let preselected, let topScore):
        TelemetryService.shared.quickAddOpened(
          door: door.rawValue,
          hadSelection: refusal == nil,
          refuseReason: refusal?.rawValue,
          candidateCount: candidateCount,
          preselected: preselected,
          topScore: topScore,
          sourceBundleID: bundleID,
          heardLength: heardScalarCount)
        // §3e: "Breadcrumbs on open and resolve so a crash inside the panel arrives with the door,
        // the candidate count, and the outcome attached." Only `failed` was leaving a breadcrumb, so
        // a crash while the panel was up arrived with no trail of how it got there.
        SentryBreadcrumb.add(
          stage: "quick_add",
          message: "quick_add opened",
          data: [
            "door": door.rawValue, "candidate_count": candidateCount,
            "refuse_reason": refusal?.rawValue ?? "none",
          ])
        // `top=` and `reason=` are BOTH required by §3e's own sample line, and both were missing.
        // Without the score a wrong-preselection report cannot show whether the confidence bar was
        // crossed, which is the single number this feature will be tuned on; without the reason a
        // support reader sees `selection=no` and cannot tell a terminal apart from a missing
        // permission. Vendor telemetry carried both all along — this is the artifact for ONE
        // person's report, which is a different job.
        log(
          "opened door=\(door.rawValue) app=\(bundleID ?? "unknown") "
            + "selection=\(refusal == nil ? "yes" : "no") reason=\(refusal?.rawValue ?? "none") "
            + "len=\(heardScalarCount) candidates=\(candidateCount) "
            + "top=\(topScore.map { String(format: "%.2f", $0) } ?? "none") "
            + "preselect=\(preselected ? "yes" : "no")")

      case .resolved(
        let outcome, let usedSearch, let candidateRank, let targetKind, let elapsed):
        TelemetryService.shared.quickAddResolved(
          outcome: outcome.rawValue,
          usedSearch: usedSearch,
          candidateRank: candidateRank,
          targetKind: targetKind?.rawValue,
          elapsedMilliseconds: elapsed)
        SentryBreadcrumb.add(
          stage: "quick_add",
          message: "quick_add resolved",
          data: ["outcome": outcome.rawValue, "used_search": usedSearch])
        log(
          "resolved outcome=\(outcome.rawValue) search=\(usedSearch ? "yes" : "no") "
            + "rank=\(candidateRank.map(String.init) ?? "none") "
            + "target=\(targetKind?.rawValue ?? "none") elapsed=\(elapsed)ms")

      case .failed(let stage, let reason):
        // Sentry gets failures and nothing else. A BREADCRUMB, not a captured error: this is a limb,
        // so a Quick Add that cannot write is worth having in the trail of whatever the user reports
        // next, and is not worth an issue of its own.
        //
        // Deliberately NOT a new `SentryBreadcrumb.ErrorCategory`. That enum is read by
        // `workers/reporting/sentry-section.js`, which classifies every raw value into
        // lost-vs-degraded and has a test enumerating the Swift cases against its table — so adding
        // one turns `worker-tests` red while every Swift test passes. There is no classification this
        // failure needs that the breadcrumb trail does not already give.
        SentryBreadcrumb.add(
          stage: "quick_add",
          message: "quick_add failed at \(stage)",
          data: ["stage": stage, "reason": reason])
        log("failed stage=\(stage) reason=\(reason)")
      }
    }
  }

  /// One line per event in the debug log.
  ///
  /// **`len=` is a CHARACTER COUNT and the word itself never appears here.** Every value on these
  /// lines is a closed-set token, a number, or an app's bundle id. If you are ever tempted to add the
  /// word to make a support case easier, that is the exact trade this was decided against.
  ///
  /// **`#if DEBUG` HERE, not only inside `AppLogger`, and the difference is not stylistic.**
  /// `AppLogger.log`'s BODY is `#if DEBUG` — its own doc says call sites compile unchanged and
  /// produce no output — so a release build discards these lines. But discarding them happens AFTER
  /// the caller has already interpolated the string and spawned a Task to hand it over. Every panel
  /// open in a shipped build would format `top=%.2f`, build a sentence and hop actors for a sink that
  /// cannot exist.
  ///
  /// The cost is small; the absurdity is the argument. And it corrects a premise worth stating,
  /// because it is the kind that gets inherited and restated: a RELEASE build writes no
  /// `~/Library/Logs/EnviousWispr/app.log` at all. These lines are for us reproducing locally and for
  /// the founder on a dev build during UAT — never something a shipped user can send in. Any support
  /// workflow written around them is a workflow around an artifact that does not exist.
  /// (Owed to a peer session finding the same inherited premise under #2135.)
  /// **`@autoclosure`, and without it the `#if DEBUG` below is a fix that reads as a fix and is not.**
  /// The interpolation happens at the CALL SITE — `log("opened door=\(door) top=\(score)")` builds
  /// its string before `log` is entered — so guarding only the body would still format every sentence
  /// in a release build and then throw it away. Deferring the expression is what actually removes the
  /// work. Non-escaping and evaluated synchronously inside the guard, so the Task captures a rendered
  /// String rather than a closure.
  private static func log(_ line: @autoclosure () -> String) {
    #if DEBUG
      let rendered = "[QuickAdd] \(line())"
      Task { await AppLogger.shared.log(rendered, level: .info, category: "QuickAdd") }
    #endif
  }
}
