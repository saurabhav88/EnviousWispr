import EnviousWisprCore

/// #1762 — the ONE place recovery writes to the local debug log.
///
/// Recovery emitted nothing to `app.log`: neither `RecoveryCoordinator` nor
/// `RecoverySpoolReplayer` carried a single line, so on a real machine a
/// replay-and-delete of an orphan that produced no text looked exactly like
/// "recovery is broken". That cost an hour of live diagnosis and one falsely
/// filed bug (#1760), and it is why #1813's cause had to be inferred from
/// aggregate telemetry across 50 users instead of reproduced on one.
///
/// Telemetry already covers the fleet (`recovery.found`, `recovery.completed`,
/// breadcrumbs). This is the local oracle those cannot be: it answers "what did
/// THIS launch just do" while you are standing in front of the machine.
///
/// ## Why this is `async` rather than fire-and-forget
///
/// The first cut wrapped each line in an unstructured `Task`. Review round 2
/// killed it, correctly: separate tasks reach the logger in whatever order the
/// scheduler picks, and a task queued just before a wedge or a process exit may
/// never run at all. Both of those destroy the one signature this diagnostic
/// exists to produce — an `attempting replay` line with NO outcome after it. A
/// reordered pair says the opposite of the truth, and a dropped pair says
/// nothing, in exactly the crash this was built to investigate.
///
/// So callers `await`. Ordering then follows the call order, and the line has
/// reached `AppLogger` before the risky work starts. Where a caller genuinely
/// cannot await — a synchronous cleanup hook — it wraps this in its own `Task`
/// at the CALL SITE, so the weaker guarantee is visible there instead of hidden
/// in here.
///
/// **Never pass transcript text, spool bytes, key material, or a device
/// identifier.** Counts, outcomes, durations and closed-vocabulary labels only —
/// the same content-free rule the telemetry boundary follows. A recovered
/// transcript is described by its character count and nothing else.
///
/// Release builds do nothing: the body compiles out rather than relying on
/// `AppLogger.log` being internally `#if DEBUG`.
enum RecoveryLog {
  /// Takes an already-built `String`, not an autoclosure.
  ///
  /// An autoclosure would have to be `@Sendable` to cross into the `AppLogger`
  /// actor, and these messages legitimately read MainActor state and local
  /// counters — `recoveryScanTrigger`, a pass number, `logLabel(outcome)`. A
  /// `@Sendable` closure cannot capture any of it, so the argument is evaluated
  /// eagerly on the caller's actor and only the resulting `String` travels.
  ///
  /// The cost is one interpolation per line in release, where the body does
  /// nothing. These paths run once per launch scan and once per orphan, so it is
  /// not worth trading correctness for.
  static func line(_ message: String) async {
    #if DEBUG
      await AppLogger.shared.log(message, level: .info, category: "Recovery")
    #endif
  }
}
