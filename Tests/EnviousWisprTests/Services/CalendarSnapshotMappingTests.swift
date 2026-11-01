import EventKit
import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprServices

/// #4286: how a calendar participant becomes an invited person, and which facts a meeting saves
/// from its event. When these fail, a meeting room is listed as a person, an address is lost or
/// wrong, a decline reads as an acceptance, or the saved facts carry more than the event's title,
/// times and people.
@Suite("Calendar event facts (#4286)", .tags(.productOutcome))
struct CalendarSnapshotMappingTests {

  private func map(
    _ name: String? = "Dana Lee", url: String? = "mailto:Dana@Acme.com",
    type: EKParticipantType = .person, role: EKParticipantRole = .required,
    status: EKParticipantStatus = .accepted, isCurrentUser: Bool = false,
    isOrganizer: Bool = false
  ) -> AttendeeFact? {
    CalendarAccess.attendee(
      name: name, url: url.flatMap(URL.init(string:)), type: type, role: role, status: status,
      isCurrentUser: isCurrentUser, isOrganizer: isOrganizer)
  }

  @Test("a person keeps name, lowercased mailto address, role, status and markers")
  func person() {
    #expect(
      map(role: .chair, status: .tentative, isCurrentUser: true, isOrganizer: true)
        == AttendeeFact(
          name: "Dana Lee", email: "dana@acme.com", role: .chair, status: .tentative,
          isSelf: true, isOrganizer: true))
  }

  @Test("people and unknown participants are kept; rooms, resources and groups are not")
  func types() {
    #expect(map(type: .person) != nil)
    #expect(map(type: .unknown) != nil)
    #expect(map(type: .room) == nil)
    #expect(map(type: .resource) == nil)
    #expect(map(type: .group) == nil)
  }

  @Test("an email comes only from a mailto address")
  func emailSource() {
    #expect(map(url: "mailto:li%40acme.com")?.email == "li@acme.com")
    #expect(map(url: "https://acme.com/li")?.email == nil)
    #expect(map(url: nil)?.email == nil)
    #expect(map(nil, url: "MAILTO:Ops@Acme.com")?.email == "ops@acme.com")
  }

  @Test("every calendar role and status maps to its own value")
  func vocabulary() {
    let roles: [(EKParticipantRole, AttendeeFact.Role)] = [
      (.required, .required), (.optional, .optional), (.chair, .chair),
      (.nonParticipant, .nonParticipant), (.unknown, .unknown),
    ]
    for (calendar, expected) in roles { #expect(map(role: calendar)?.role == expected) }
    let statuses: [(EKParticipantStatus, AttendeeFact.Status)] = [
      (.accepted, .accepted), (.declined, .declined), (.tentative, .tentative),
      (.pending, .pending), (.delegated, .delegated), (.completed, .completed),
      (.inProcess, .inProcess), (.unknown, .unknown),
    ]
    for (calendar, expected) in statuses { #expect(map(status: calendar)?.status == expected) }
  }

  @Test("an event's facts are its title and times plus one fact per invitee, nothing else")
  func facts() throws {
    let at = Date(timeIntervalSinceReferenceDate: 815_000_000)
    let dana = try #require(map(isOrganizer: true))
    let li = try #require(map("Li Wu", url: "mailto:li@acme.com", status: .declined))
    let snapshot = CalendarEventSnapshot(
      title: "Acme renewal", start: Date(timeIntervalSinceReferenceDate: 815_000_100),
      end: Date(timeIntervalSinceReferenceDate: 815_002_800), attendees: [dana, li])
    let facts = MeetingCalendarFacts.facts(from: snapshot, at: at)
    #expect(facts.map(\.kind) == ["calendarEvent", "attendee", "attendee"])
    #expect(facts.allSatisfy { $0.source == "calendar.eventkit" && $0.capturedAt == at })
    #expect(
      facts.first?.value
        == .object([
          "title": .string("Acme renewal"), "start": .number(815_000_100),
          "end": .number(815_002_800),
        ]))
    #expect(facts.compactMap(\.attendee) == [dana, li])
  }

  @Test("the organizer is marked when listed and appended when absent")
  func organizerAssembly() throws {
    let dana = try #require(map())
    let li = try #require(map("Li Wu", url: "mailto:li@acme.com"))
    let danaURL = try #require(URL(string: "mailto:Dana@Acme.com"))
    let liURL = try #require(URL(string: "mailto:li@acme.com"))

    let listed = CalendarAccess.attendees(
      [(url: danaURL, fact: dana), (url: liURL, fact: li)],
      organizer: (url: danaURL, fact: dana))
    #expect(listed.map(\.name) == ["Dana Lee", "Li Wu"])
    #expect(listed.map(\.isOrganizer) == [true, false])

    let absent = CalendarAccess.attendees(
      [(url: liURL, fact: li)],
      organizer: (url: danaURL, fact: dana))
    #expect(absent.map(\.name) == ["Li Wu", "Dana Lee"])
    #expect(absent.map(\.isOrganizer) == [false, true])

    var sameName = li
    sameName.name = dana.name
    let distinct = CalendarAccess.attendees(
      [(url: liURL, fact: sameName)],
      organizer: (url: danaURL, fact: dana))
    #expect(distinct.count == 2, "matching names do not identify the organizer")
    #expect(distinct.map(\.isOrganizer) == [false, true])
  }
}
