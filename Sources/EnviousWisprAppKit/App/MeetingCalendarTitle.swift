import EnviousWisprServices
import Foundation
import os

/// The calendar lookup a meeting Start waits for, bounded (#4017 R11).
///
/// EventKit's read is synchronous and can be slow, so it runs on a detached task, and the
/// Start waits at most `bound`: whichever finishes first resumes the Start exactly once. A
/// lookup still running when the bound passes is abandoned; its late answer is dropped, so it
/// can never name a meeting after the Start moved on.
enum MeetingCalendarTitle {
  static func lookup(
    at date: Date, bound: Duration,
    read: @escaping @Sendable (Date) -> String? = { CalendarAccess.eventTitle(at: $0) }
  ) async -> String? {
    await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
      let resumed = OSAllocatedUnfairLock(initialState: false)
      let finish: @Sendable (String?) -> Void = { title in
        let first = resumed.withLock { done -> Bool in
          if done { return false }
          done = true
          return true
        }
        if first { continuation.resume(returning: title) }
      }
      // Detached: the read blocks its thread, and a plain Task would inherit the main actor
      // the Start runs on. `@concurrent` would still be awaited by the Start, and the bound
      // must release the Start even when the read does not return.
      Task.detached(priority: .userInitiated) { finish(read(date)) }
      Task.detached {
        try? await Task.sleep(for: bound)
        finish(nil)
      }
    }
  }
}
