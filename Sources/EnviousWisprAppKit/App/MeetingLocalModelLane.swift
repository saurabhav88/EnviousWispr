import Foundation
import Observation

/// Who may use a local model now, across EnviousMeet's three kinds of work (#3972 R50): final
/// passes, local summary calls and live-words previews. One local model unit of any kind runs
/// at a time, by priority final pass > local summary > preview.
///
/// - A meeting engine unit (load, decode, speaker analysis, unload) is counted while it runs
///   (`asrUnits`), by the wiring around the job's engine calls.
/// - A local summary call is admitted only when dictation is idle, no engine unit runs and no
///   final pass is due (`MeetingSummaryOwner`), and holds `summaryCallRunning` until the call
///   has physically ended.
/// - A final pass unit waits while a summary call runs; a preview unit also waits while a local
///   summary waits for its turn (`summaryWaiting`), so a summary is not starved by live words.
///
/// Observable, so `MeetingWorkAdmission.waitUntil` wakes on every change.
@MainActor
@Observable
final class MeetingLocalModelLane {
  private(set) var asrUnits = 0
  private(set) var summaryCallRunning = false
  /// Local summaries scheduled and not yet finished (waiting for their turn or calling).
  private(set) var summaryWaiting = 0

  /// A local summary is waiting for its turn or calling: previews give way.
  var summaryActive: Bool { summaryCallRunning || summaryWaiting > 0 }

  /// A meeting engine unit starts and ends (the wiring calls both around each engine call).
  func asrBegan() { asrUnits += 1 }
  func asrEnded() { asrUnits = max(0, asrUnits - 1) }

  func summaryQueued() { summaryWaiting += 1 }
  func summaryFinished() { summaryWaiting = max(0, summaryWaiting - 1) }

  /// A local summary call starts. Local summaries run one after another
  /// (`MeetingSummaryOwner`), so at most one call is open.
  func beginSummaryCall() { summaryCallRunning = true }

  /// The open local summary call has ended. Repeatable.
  func endSummaryCall() { summaryCallRunning = false }
}
