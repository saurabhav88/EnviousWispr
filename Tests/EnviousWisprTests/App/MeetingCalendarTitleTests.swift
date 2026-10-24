import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4017 R5, R11: how a meeting gets its calendar name. When these fail, a meeting is named
/// after the wrong event, or a slow calendar holds up the Start.
@Suite("Meeting calendar name", .tags(.productOutcome))
struct MeetingCalendarTitleTests {
  private typealias Candidate = CalendarAccess.Candidate

  @Test("one event gives its title; none gives nil")
  func singleAndNone() {
    #expect(
      CalendarAccess.pickTitle([Candidate(title: "Standup", hasMeetingPlace: false)]) == "Standup")
    #expect(CalendarAccess.pickTitle([]) == nil)
  }

  @Test("two plain events are ambiguous: no name rather than a wrong one")
  func ambiguous() {
    let two = [
      Candidate(title: "Lunch", hasMeetingPlace: false),
      Candidate(title: "Focus time", hasMeetingPlace: false),
    ]
    #expect(CalendarAccess.pickTitle(two) == nil)
  }

  @Test("an event with a meeting link or place wins over one without")
  func meetingPlaceWins() {
    let events = [
      Candidate(title: "Focus time", hasMeetingPlace: false),
      Candidate(title: "Acme renewal call", hasMeetingPlace: true),
    ]
    #expect(CalendarAccess.pickTitle(events) == "Acme renewal call")
  }

  @Test("blank titles never name a meeting, and long ones are cut to 120 characters")
  func blankAndLong() {
    #expect(CalendarAccess.pickTitle([Candidate(title: "   ", hasMeetingPlace: true)]) == nil)
    let long = String(repeating: "a", count: 300)
    #expect(
      CalendarAccess.pickTitle([Candidate(title: long, hasMeetingPlace: false)])?.count == 120)
  }

  @Test("a calendar read that does not return in time leaves the meeting unnamed")
  func slowReadIsBounded() async {
    let release = DispatchSemaphore(value: 0)
    let title = await MeetingCalendarTitle.lookup(at: Date(), bound: .milliseconds(50)) { _ in
      // Blocks past the bound; released after the Start has moved on.
      release.wait()
      return "Too late"
    }
    #expect(title == nil)
    release.signal()
  }

  @Test("a read that returns in time names the meeting")
  func fastReadNames() async {
    let title = await MeetingCalendarTitle.lookup(at: Date(), bound: .seconds(5)) { _ in
      "Weekly sync"
    }
    #expect(title == "Weekly sync")
  }
}
