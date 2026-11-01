import EnviousWisprCore
import EnviousWisprServices
import Foundation
import os

/// The calendar lookup a meeting Start waits for, bounded (#4017 R11): the matched event's
/// title and invited people as one snapshot (#4286).
///
/// EventKit's read is synchronous and can be slow, so it runs on its own serial queue (never
/// the shared Swift worker pool), and the Start waits at most `bound`: whichever finishes first
/// resumes the Start exactly once. A lookup still running when the bound passes is abandoned;
/// its late answer is dropped, so it can never name a meeting or add its facts after the Start
/// moved on. Only
/// one read runs at a time: while an abandoned read is still stuck, later Starts skip the
/// lookup at once instead of queueing behind it.
enum MeetingCalendarLookup {
  /// Where reads run, and whether one is still running. The app shares one; a test makes its own.
  final class Lane: Sendable {
    let queue = DispatchQueue(label: "com.enviouswispr.meeting-calendar-title", qos: .userInitiated)
    let reading = OSAllocatedUnfairLock(initialState: false)
    static let shared = Lane()
  }

  static func lookup(
    at date: Date, bound: Duration, lane: Lane = .shared,
    read: @escaping @Sendable (Date) -> CalendarEventSnapshot? = {
      CalendarAccess.eventSnapshot(at: $0)
    }
  ) async -> CalendarEventSnapshot? {
    let reading = lane.reading
    let claimed = reading.withLock { busy -> Bool in
      if busy { return false }
      busy = true
      return true
    }
    guard claimed else { return nil }
    return await withCheckedContinuation { (continuation: CheckedContinuation<CalendarEventSnapshot?, Never>) in
      let resumed = OSAllocatedUnfairLock(initialState: false)
      let finish: @Sendable (CalendarEventSnapshot?) -> Void = { snapshot in
        let first = resumed.withLock { done -> Bool in
          if done { return false }
          done = true
          return true
        }
        if first { continuation.resume(returning: snapshot) }
      }
      lane.queue.async {
        let snapshot = read(date)
        reading.withLock { $0 = false }
        finish(snapshot)
      }
      // A timer, not a task: it fires even when every worker thread is busy.
      let seconds = Double(bound.components.seconds) + Double(bound.components.attoseconds) / 1e18
      DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
        finish(nil)
      }
    }
  }
}
