import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprServices

/// #4017 R5, R11; #4286: which calendar event a meeting uses. When these fail, a meeting is named
/// after the wrong event or saves the wrong event's invited people, or a slow calendar holds up
/// the Start.
@Suite("Meeting calendar name", .tags(.productOutcome))
struct MeetingCalendarLookupTests {
  private typealias Candidate = CalendarAccess.Candidate

  private static func snapshot(_ title: String) -> CalendarEventSnapshot {
    CalendarEventSnapshot(title: title, start: Date(), end: Date(), attendees: [])
  }

  @Test("one event is used; none gives nil")
  func singleAndNone() {
    #expect(CalendarAccess.pick([Candidate(title: "Standup", hasMeetingPlace: false)]) == 0)
    #expect(CalendarAccess.pick([]) == nil)
  }

  @Test("two plain events are ambiguous: no event rather than a wrong one")
  func ambiguous() {
    let two = [
      Candidate(title: "Lunch", hasMeetingPlace: false),
      Candidate(title: "Focus time", hasMeetingPlace: false),
    ]
    #expect(CalendarAccess.pick(two) == nil)
  }

  @Test("two events that both have a meeting link or place are still ambiguous")
  func twoPreferredAmbiguous() {
    let two = [
      Candidate(title: "Acme call", hasMeetingPlace: true),
      Candidate(title: "Beta call", hasMeetingPlace: true),
      Candidate(title: "Focus time", hasMeetingPlace: false),
    ]
    #expect(CalendarAccess.pick(two) == nil)
  }

  @Test("an event with a meeting link or place wins, and its position is the one used")
  func meetingPlaceWins() {
    let events = [
      Candidate(title: "Focus time", hasMeetingPlace: false),
      Candidate(title: "Acme renewal call", hasMeetingPlace: true),
    ]
    #expect(CalendarAccess.pick(events) == 1)
  }

  @Test("blank titles never count, and long ones are cut to 120 characters")
  func blankAndLong() {
    #expect(CalendarAccess.pick([Candidate(title: "   ", hasMeetingPlace: true)]) == nil)
    #expect(
      CalendarAccess.pick([
        Candidate(title: " ", hasMeetingPlace: true), Candidate(title: "Real", hasMeetingPlace: false),
      ]) == 1)
    #expect(CalendarAccess.cleanTitle("  Weekly sync  ") == "Weekly sync")
    #expect(CalendarAccess.cleanTitle(String(repeating: "a", count: 300))?.count == 120)
    #expect(CalendarAccess.cleanTitle(nil) == nil)
  }

  @Test("a calendar read that does not return in time leaves the meeting without an event")
  func slowReadIsBounded() async {
    let release = DispatchSemaphore(value: 0)
    let lane = MeetingCalendarLookup.Lane()
    let found = await MeetingCalendarLookup.lookup(
      at: Date(), bound: .milliseconds(50), lane: lane
    ) { _ in
      // Blocks past the bound; released after the Start has moved on.
      release.wait()
      return Self.snapshot("Too late")
    }
    #expect(found == nil)
    // While that read is stuck, the next Start skips the lookup at once.
    let started = ContinuousClock.now
    let next = await MeetingCalendarLookup.lookup(at: Date(), bound: .seconds(5), lane: lane) { _ in
      Self.snapshot("Never read")
    }
    #expect(next == nil)
    #expect(ContinuousClock.now - started < .seconds(5))
    release.signal()
  }

  @Test("a read that returns in time gives its event")
  func fastReadNames() async {
    let found = await MeetingCalendarLookup.lookup(
      at: Date(), bound: .seconds(5), lane: MeetingCalendarLookup.Lane()
    ) { _ in
      Self.snapshot("Weekly sync")
    }
    #expect(found?.title == "Weekly sync")
  }
}
