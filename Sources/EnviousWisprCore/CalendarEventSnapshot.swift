import Foundation

/// The calendar event a meeting matched at its start, read once on the Mac (#4286): only its
/// title, times and invited people. Plain values, so no EventKit object leaves the calendar
/// read. Event notes, location, links and identifiers are deliberately not carried.
public struct CalendarEventSnapshot: Sendable, Equatable {
  /// Trimmed and at most 120 characters, as the meeting's name has always been.
  public var title: String
  public var start: Date
  public var end: Date
  /// Invited people in the calendar's order; rooms, resources and groups are left out.
  public var attendees: [AttendeeFact]

  public init(title: String, start: Date, end: Date, attendees: [AttendeeFact]) {
    self.title = title
    self.start = start
    self.end = end
    self.attendees = attendees
  }
}
