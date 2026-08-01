import EnviousWisprCore

/// #1762 — the ONE place recovery writes to the local debug log.
///
/// Recovery emitted nothing to `app.log`: neither `RecoveryCoordinator` nor
/// `RecoverySpoolReplayer` carried a single line, so on a real machine a
/// replay-and-delete of an orphan that held no speech looked exactly like
/// "recovery is broken". That cost an hour of live diagnosis and one falsely
/// filed bug (#1760), and it is why #1813's cause had to be inferred from
/// aggregate telemetry across 50 users instead of reproduced on one.
///
/// Telemetry already covers the fleet (`recovery.found`, `recovery.completed`,
/// breadcrumbs). This is the local oracle those cannot be: it answers "what did
/// THIS launch just do" while you are standing in front of the machine.
///
/// **Never pass transcript text, spool bytes, key material, or a device
/// identifier.** Counts, outcomes, durations and closed-vocabulary labels only —
/// the same content-free rule the telemetry boundary follows. A recovered
/// transcript is described by its character count and nothing else.
///
/// Release builds allocate nothing: the call site compiles away entirely rather
/// than relying on `AppLogger.log` being internally `#if DEBUG`.
enum RecoveryLog {
  static func line(_ message: @autoclosure () -> String) {
    #if DEBUG
      let text = message()
      Task { await AppLogger.shared.log(text, level: .info, category: "Recovery") }
    #endif
  }
}
