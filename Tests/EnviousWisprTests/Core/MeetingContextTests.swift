import Foundation
import Testing

@testable import EnviousWisprCore

/// #4286: the shape of `context.json`. When these fail, a fact written by a newer build is lost
/// or changed when this build adds facts, or a readable file stops reading.
@Suite("Meeting context file shape (#4286)", .tags(.driftGuard))
struct MeetingContextTests {

  private func decode(_ json: String) throws -> MeetingContext {
    try JSONDecoder().decode(MeetingContext.self, from: Data(json.utf8))
  }

  private func roundTrip(_ context: MeetingContext) throws -> MeetingContext {
    try JSONDecoder().decode(MeetingContext.self, from: JSONEncoder().encode(context))
  }

  /// Every JSON value kind reads as itself: true is not 1, 0 is not false, null is not absent.
  @Test("every JSON value kind keeps its kind")
  func valueKinds() throws {
    let json = """
      {"formatVersion": 1, "facts": [{"kind": "probe", "source": "test", "capturedAt": 0,
       "value": {"s": "x", "n": 1, "z": 0, "t": true, "f": false, "nil": null,
                 "list": [1, "a", false, null], "nested": {"k": [ {"deep": 2.5} ]}}}]}
      """
    let value = try #require(try decode(json).facts.first?.value)
    let expected: MeetingFactValue = .object([
      "s": .string("x"), "n": .number(1), "z": .number(0), "t": .bool(true), "f": .bool(false),
      "nil": .null,
      "list": .array([.number(1), .string("a"), .bool(false), .null]),
      "nested": .object(["k": .array([.object(["deep": .number(2.5)])])]),
    ])
    #expect(value == expected)
    guard case .object(let object) = value else {
      Issue.record("value is not an object")
      return
    }
    #expect(object["absent"] == nil)
  }

  /// A kind and source this build does not know, with nested values, survive adding a fact and
  /// writing the file again.
  @Test("an unknown fact survives decode, append and encode")
  func unknownFactSurvives() throws {
    let json = """
      {"formatVersion": 1, "facts": [{"kind": "futureThing", "source": "calendar.google",
       "capturedAt": 10, "value": {"a": [1, {"b": null}], "c": "d"}}]}
      """
    var context = try decode(json)
    let original = try #require(context.facts.first)
    context.append([
      AttendeeFact(
        name: "Dana Lee", email: "dana@acme.com", role: .required, status: .accepted,
        isSelf: false, isOrganizer: true
      ).fact(
        source: MeetingFact.eventKitSource, capturedAt: Date(timeIntervalSinceReferenceDate: 20))
    ])
    let reread = try roundTrip(context)
    #expect(reread.facts.count == 2)
    #expect(reread.facts.first == original)
    #expect(reread.facts.first?.kind == "futureThing")
    #expect(reread.facts.first?.source == "calendar.google")
    #expect(
      reread.facts.first?.value
        == .object(["a": .array([.number(1), .object(["b": .null])]), "c": .string("d")]))
    #expect(reread.attendees.map(\.name) == ["Dana Lee"])
  }

  /// Keys this build does not know inside a fact it does know are kept on rewrite, and the
  /// typed view still reads.
  @Test("extra keys inside a known fact survive a rewrite")
  func extraKeysSurvive() throws {
    let json = """
      {"formatVersion": 1, "facts": [{"kind": "calendarEvent", "source": "calendar.eventkit",
       "capturedAt": 5, "value": {"title": "Acme renewal", "start": 100, "end": 3700,
       "location": "Room 4", "futureKey": {"x": true}}}]}
      """
    var context = try decode(json)
    context.append([])
    let reread = try roundTrip(context)
    let value = try #require(reread.facts.first?.value)
    guard case .object(let object) = value else {
      Issue.record("value is not an object")
      return
    }
    #expect(object["location"] == .string("Room 4"))
    #expect(object["futureKey"] == .object(["x": .bool(true)]))
    #expect(
      reread.calendarEvents == [
        CalendarEventFact(
          title: "Acme renewal", start: Date(timeIntervalSinceReferenceDate: 100),
          end: Date(timeIntervalSinceReferenceDate: 3700))
      ])
  }

  /// Typed views read complete values, accept missing optional fields, and refuse values missing
  /// a required field or of another kind.
  @Test("typed views read valid facts and refuse malformed ones")
  func typedViews() throws {
    let json = """
      {"formatVersion": 1, "facts": [
       {"kind": "calendarEvent", "source": "s", "capturedAt": 0, "value": {"title": "T", "start": 1, "end": 2}},
       {"kind": "calendarEvent", "source": "s", "capturedAt": 0, "value": {"title": "No end", "start": 1}},
       {"kind": "calendarEvent", "source": "s", "capturedAt": 0, "value": {"title": 7, "start": 1, "end": 2}},
       {"kind": "calendarEvent", "source": "s", "capturedAt": 0, "value": "not an object"},
       {"kind": "attendee", "source": "s", "capturedAt": 0, "value": {"email": "li@acme.com"}},
       {"kind": "attendee", "source": "s", "capturedAt": 0, "value": {"name": "Sam", "role": "chair",
        "status": "declined", "isSelf": true, "isOrganizer": false}},
       {"kind": "attendee", "source": "s", "capturedAt": 0, "value": {"role": "required", "status": "accepted"}},
       {"kind": "other", "source": "s", "capturedAt": 0, "value": {"title": "T", "start": 1, "end": 2}}
      ]}
      """
    let context = try decode(json)
    #expect(context.calendarEvents.map(\.title) == ["T"])
    #expect(
      context.attendees == [
        AttendeeFact(
          name: nil, email: "li@acme.com", role: .unknown, status: .unknown, isSelf: false,
          isOrganizer: false),
        AttendeeFact(
          name: "Sam", email: nil, role: .chair, status: .declined, isSelf: true,
          isOrganizer: false),
      ])
  }

  /// A role or status this build does not know reads as unknown, and its stored text survives
  /// a rewrite.
  @Test("an unknown role or status reads as unknown and keeps its text")
  func unknownRoleAndStatus() throws {
    let json = """
      {"formatVersion": 1, "facts": [{"kind": "attendee", "source": "s", "capturedAt": 0,
       "value": {"name": "Kim", "role": "observer", "status": "maybeLater"}}]}
      """
    let reread = try roundTrip(try decode(json))
    let attendee = try #require(reread.attendees.first)
    #expect(attendee.role == .unknown)
    #expect(attendee.status == .unknown)
    guard case .object(let object) = try #require(reread.facts.first?.value) else {
      Issue.record("value is not an object")
      return
    }
    #expect(object["role"] == .string("observer"))
    #expect(object["status"] == .string("maybeLater"))
  }

  /// A file with another format version is still read; new files are written as version 1.
  @Test("a readable file with another format version still reads")
  func otherFormatVersionReads() throws {
    let json = """
      {"formatVersion": 7, "facts": [{"kind": "attendee", "source": "s", "capturedAt": 0,
       "value": {"name": "Ana"}}]}
      """
    let context = try decode(json)
    #expect(context.formatVersion == 7)
    #expect(context.attendees.map(\.name) == ["Ana"])
    #expect(MeetingContext().formatVersion == 1)
  }

  /// The facts this build writes read back as the typed values they were made from.
  @Test("written facts read back as their typed values")
  func writtenFactsReadBack() throws {
    let event = CalendarEventFact(
      title: "Acme x Envious: renewal", start: Date(timeIntervalSinceReferenceDate: 815_000_000),
      end: Date(timeIntervalSinceReferenceDate: 815_002_700))
    let person = AttendeeFact(
      name: nil, email: "li@acme.com", role: .optional, status: .tentative, isSelf: false,
      isOrganizer: false)
    let at = Date(timeIntervalSinceReferenceDate: 815_000_001)
    let context = MeetingContext(facts: [
      event.fact(source: MeetingFact.eventKitSource, capturedAt: at),
      person.fact(source: MeetingFact.eventKitSource, capturedAt: at),
    ])
    let reread = try roundTrip(context)
    #expect(reread.calendarEvents == [event])
    #expect(reread.attendees == [person])
    #expect(reread.facts.allSatisfy { $0.source == "calendar.eventkit" && $0.capturedAt == at })
  }
}
