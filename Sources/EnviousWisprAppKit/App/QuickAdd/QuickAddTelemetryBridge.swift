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
/// Sentry gets FAILURES only, because they are about something being broken. The local log gets a
/// support line — and the heard word is NOT in it, including under Debug Mode.
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
        log(
          "opened door=\(door.rawValue) app=\(bundleID ?? "unknown") "
            + "selection=\(refusal == nil ? "yes" : "no") len=\(heardScalarCount) "
            + "candidates=\(candidateCount) preselect=\(preselected ? "yes" : "no")")

      case .resolved(
        let outcome, let usedSearch, let candidateRank, let targetKind, let elapsed):
        TelemetryService.shared.quickAddResolved(
          outcome: outcome.rawValue,
          usedSearch: usedSearch,
          candidateRank: candidateRank,
          targetKind: targetKind?.rawValue,
          elapsedMilliseconds: elapsed)
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
  private static func log(_ line: String) {
    Task { await AppLogger.shared.log("[QuickAdd] \(line)", level: .info, category: "QuickAdd") }
  }
}
