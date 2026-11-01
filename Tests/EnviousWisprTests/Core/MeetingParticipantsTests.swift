import Foundation
import Testing

@testable import EnviousWisprCore

/// #4286: when these fail, two different invited people are merged into one, an invited person
/// disappears, or an invitation reads as attendance in the meeting's summary and search.
@Suite("Meeting invited people (#4286)", .tags(.productOutcome))
struct MeetingParticipantsTests {

  private func invite(
    _ name: String?, _ email: String?, role: AttendeeFact.Role = .required,
    status: AttendeeFact.Status = .accepted, isSelf: Bool = false, isOrganizer: Bool = false
  ) -> AttendeeFact {
    AttendeeFact(
      name: name, email: email, role: role, status: status, isSelf: isSelf,
      isOrganizer: isOrganizer)
  }

  private func person(
    _ name: String?, _ email: String?, _ domain: String?, role: AttendeeFact.Role = .required,
    status: AttendeeFact.Status = .accepted, isSelf: Bool = false, isOrganizer: Bool = false
  ) -> MeetingParticipant {
    MeetingParticipant(
      name: name, email: email, emailDomain: domain, role: role, status: status, isSelf: isSelf,
      isOrganizer: isOrganizer)
  }

  @Test("no attendees gives no people")
  func empty() {
    #expect(MeetingParticipants.resolve(attendees: []) == [])
  }

  @Test("an ordinary invitee keeps name, email, domain and invitation markers")
  func ordinary() {
    let result = MeetingParticipants.resolve(attendees: [
      invite("Dana Lee", "dana@acme.com", role: .chair, status: .tentative, isOrganizer: true)
    ])
    #expect(
      result == [
        person(
          "Dana Lee", "dana@acme.com", "acme.com", role: .chair, status: .tentative,
          isOrganizer: true)
      ])
  }

  @Test("the same email in another case or with spaces is one person")
  func sameEmailMerges() {
    let result = MeetingParticipants.resolve(attendees: [
      invite("Dana Lee", "Dana@Acme.com"),
      invite(nil, "  dana@acme.com "),
    ])
    #expect(result == [person("Dana Lee", "dana@acme.com", "acme.com")])
  }

  @Test("the same name with different emails, or the same domain, stays two people")
  func differentEmailsStaySeparate() {
    let result = MeetingParticipants.resolve(attendees: [
      invite("Sam Wu", "sam@acme.com"),
      invite("Sam Wu", "sam.wu@other.org"),
      invite("Li", "li@acme.com"),
    ])
    #expect(
      result == [
        person("Sam Wu", "sam@acme.com", "acme.com"),
        person("Sam Wu", "sam.wu@other.org", "other.org"),
        person("Li", "li@acme.com", "acme.com"),
      ])
  }

  @Test("two invitees with the same name and no email stay two people")
  func emaillessNamesStaySeparate() {
    let result = MeetingParticipants.resolve(attendees: [invite("Alex", nil), invite("Alex", "")])
    #expect(result == [person("Alex", nil, nil), person("Alex", nil, nil)])
  }

  @Test("an empty or blank email is no email, and never joins two people")
  func blankEmailIsNoKey() {
    let result = MeetingParticipants.resolve(attendees: [
      invite("Ana", "   "), invite("Bo", ""), invite("Cy", nil),
    ])
    #expect(result.map(\.name) == ["Ana", "Bo", "Cy"])
    #expect(result.allSatisfy { $0.email == nil && $0.emailDomain == nil })
  }

  @Test("a name-only or email-only invitee is kept; one with neither is dropped")
  func usableAndUnusable() {
    let result = MeetingParticipants.resolve(attendees: [
      invite("  Kim  ", nil), invite(nil, "ops@acme.com"), invite("  ", " "), invite(nil, nil),
    ])
    #expect(result == [person("Kim", nil, nil), person(nil, "ops@acme.com", "acme.com")])
  }

  @Test("merging one email keeps the first name, any self or organizer mark, and a decline")
  func mergeRule() {
    let result = MeetingParticipants.resolve(attendees: [
      invite(nil, "li@acme.com", role: .unknown, status: .unknown),
      invite("Li Wu", "li@acme.com", role: .optional, status: .accepted, isOrganizer: true),
      invite("L. Wu", "LI@acme.com", role: .required, status: .declined, isSelf: true),
      invite(nil, "li@acme.com", status: .tentative),
    ])
    #expect(
      result == [
        person(
          "Li Wu", "li@acme.com", "acme.com", role: .optional, status: .declined,
          isSelf: true, isOrganizer: true)
      ])
  }

  @Test("a declined invitee stays in the list, marked declined")
  func declinedKept() {
    let result = MeetingParticipants.resolve(attendees: [
      invite("Ana", "ana@acme.com"), invite("Bo", "bo@acme.com", status: .declined),
    ])
    #expect(result.map(\.status) == [.accepted, .declined])
    #expect(result.map(\.name) == ["Ana", "Bo"])
  }

  @Test("first-seen order holds across merged and email-less entries")
  func order() {
    let result = MeetingParticipants.resolve(attendees: [
      invite("Ana", nil), invite("Bo", "bo@x.com"), invite("Cy", nil), invite(nil, "BO@x.com"),
      invite("Di", "di@x.com"),
    ])
    #expect(result.map(\.name) == ["Ana", "Bo", "Cy", "Di"])
  }

  @Test("the domain keeps subdomains and is nil without one")
  func domains() {
    let result = MeetingParticipants.resolve(attendees: [
      invite("A", "a@mail.eu.acme.co.uk"), invite("B", "no-at-sign"), invite("C", "c@"),
    ])
    #expect(result.map(\.emailDomain) == ["mail.eu.acme.co.uk", nil, nil])
    #expect(result.map(\.email) == ["a@mail.eu.acme.co.uk", "no-at-sign", "c@"])
  }

  @Test("resolving leaves the attendee values unchanged")
  func inputUnchanged() {
    let input = [
      invite(" Dana ", " Dana@Acme.com ", isOrganizer: true), invite(nil, "dana@acme.com"),
    ]
    let copy = input
    _ = MeetingParticipants.resolve(attendees: input)
    #expect(input == copy)
    #expect(input.first?.email == " Dana@Acme.com ")
  }
}
