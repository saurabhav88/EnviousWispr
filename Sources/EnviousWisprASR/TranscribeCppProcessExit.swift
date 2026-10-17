import Darwin
import EnviousWisprServices
import EnviousWisprTranscribeCpp
import Foundation
import os

/// #3849: frees every transcribe.cpp model before the process exits. A session still alive at
/// `exit()` lets the static ggml Metal device destructor assert (`[rsets->data count] == 0`),
/// which the user sees as a crash dialog on quit. AppKit reaches this through ASR, so the app
/// layer gains no direct transcribe.cpp dependency.
package enum TranscribeCppProcessExit {
  /// The native-drain bound (plan §3a: turbo abort-to-return p99 129 ms, open p99 276 ms on the
  /// measuring Mac). It bounds the drain only: earlier quit steps and the note write are outside.
  package static let timeout: Duration = .seconds(2)

  /// Forward to the shared executor's quit release.
  package static func releaseModels(timeout: Duration) -> TranscribeCppExecutor.TerminationRelease {
    TranscribeCppExecutor.shared.releaseAllForTermination(timeout: timeout)
  }

  /// The quit step `applicationWillTerminate` runs last, synchronously. Returns normally when
  /// every model was freed; otherwise writes the timeout note and ends the process at once.
  package static func releaseBeforeExit() {
    releaseBeforeExit(
      release: releaseModels, noteDirectory: ModelReleaseTimeoutNote.productionDirectory,
      exitNow: { _exit(0) })
  }

  /// What the quit step did.
  package enum Outcome: Equatable, Sendable {
    case released(sessions: Int, waitedMs: Int)
    /// The process was ended after a timed-out or already-started release.
    case exited(noteWritten: Bool)
  }

  /// The one owner of the quit release's result handling; production and the child-process
  /// test run this same function (the test with a private executor and a temporary note
  /// directory).
  ///
  /// `.released`: log and return, so AppKit's normal termination runs. `.timedOut`: a native call
  /// still owns its session, so freeing it would be a use-after-free and a normal `exit()` would
  /// assert in the Metal destructor; write the note, then end the process (founder-approved last
  /// resort). `.alreadyStarted`: completion is unconfirmed, so it is handled like `.timedOut`;
  /// the session count is not observable on this branch, so the note records none.
  @discardableResult
  package static func releaseBeforeExit(
    release: (Duration) -> TranscribeCppExecutor.TerminationRelease,
    noteDirectory: URL, timeout: Duration = timeout, exitNow: () -> Void
  ) -> Outcome {
    let sessions: Int?
    switch release(timeout) {
    case .released(let count, let waitedMs):
      logger.notice(
        "transcribe.cpp quit release: ok sessions=\(count, privacy: .public) waited_ms=\(waitedMs, privacy: .public)"
      )
      return .released(sessions: count, waitedMs: waitedMs)
    case .timedOut(let count):
      logger.error("transcribe.cpp quit release: timed out sessions=\(count, privacy: .public)")
      sessions = count
    case .alreadyStarted:
      logger.error("transcribe.cpp quit release: already started")
      sessions = nil
    }
    let note = ModelReleaseTimeoutNote.current(
      sessions: sessions, boundMs: Int(timeout / .milliseconds(1)))
    let noteWritten: Bool
    do {
      try ModelReleaseTimeoutNote.write(note, to: noteDirectory)
      noteWritten = true
    } catch {
      logger.error(
        "transcribe.cpp quit release: note write failed code=\((error as NSError).code, privacy: .public)"
      )
      noteWritten = false
    }
    exitNow()
    return .exited(noteWritten: noteWritten)
  }

  private static let logger = Logger(subsystem: "com.enviouswispr.app", category: "TranscribeCpp")
}
