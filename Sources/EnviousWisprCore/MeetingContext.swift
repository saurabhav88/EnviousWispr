import Foundation

/// Facts about one meeting that are not the user's words: who was invited, which calendar event
/// it was, and later facts from other sources (#4286). Saved as `context.json` beside
/// `meeting.json`. Each fact names its own kind and source as open strings, so a build that does
/// not know a kind keeps it unchanged when it adds facts, and no future kind needs a format
/// refusal. A future change to this SHAPE (not a new kind) gets a new file name instead.
public struct MeetingContext: Sendable, Equatable, Codable {
  /// Written for new files. Not a read gate: every field is open, so any readable file is read.
  public static let currentFormatVersion = 1

  public var formatVersion: Int
  public var facts: [MeetingFact]

  public init(facts: [MeetingFact] = []) {
    formatVersion = Self.currentFormatVersion
    self.facts = facts
  }

  /// Adds facts after the existing ones. Existing facts, including kinds this build does not
  /// know, are never rebuilt, so their values survive the rewrite unchanged.
  public mutating func append(_ newFacts: [MeetingFact]) {
    facts.append(contentsOf: newFacts)
  }

  /// The calendar event facts, in file order, that this build can read.
  public var calendarEvents: [CalendarEventFact] { facts.compactMap(\.calendarEvent) }

  /// The invited people, in file order, that this build can read.
  public var attendees: [AttendeeFact] { facts.compactMap(\.attendee) }
}

/// One fact: what it is (`kind`), where it came from (`source`), when it was captured, and its
/// value as a JSON tree. Kinds known in #4286 Phase A: `calendarEvent`, `attendee`.
public struct MeetingFact: Sendable, Equatable, Codable {
  public static let calendarEventKind = "calendarEvent"
  public static let attendeeKind = "attendee"
  /// The macOS Calendar app, read through EventKit.
  public static let eventKitSource = "calendar.eventkit"

  public var kind: String
  public var source: String
  public var capturedAt: Date
  public var value: MeetingFactValue

  public init(kind: String, source: String, capturedAt: Date, value: MeetingFactValue) {
    self.kind = kind
    self.source = source
    self.capturedAt = capturedAt
    self.value = value
  }
}

/// A JSON value kept exactly as read, so a fact this build does not understand, or keys it does
/// not know inside a fact it does, are written back unchanged. Numbers are `Double`, as in JSON;
/// integers beyond 2^53 lose precision, which no Phase A fact uses.
public indirect enum MeetingFactValue: Sendable, Equatable, Codable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  case array([MeetingFactValue])
  case object([String: MeetingFactValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      // Before Double: a JSON true/false never decodes as a number, and 0/1 never as a Bool.
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([MeetingFactValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: MeetingFactValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "not a JSON value")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var numberValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  var objectValue: [String: MeetingFactValue]? {
    if case .object(let value) = self { return value }
    return nil
  }
}

/// The calendar event a meeting matched at its start: only what #4286 Phase A uses. Times are
/// stored as seconds since the reference date, the same clock `meeting.json` uses.
public struct CalendarEventFact: Sendable, Equatable {
  public var title: String
  public var start: Date
  public var end: Date

  public init(title: String, start: Date, end: Date) {
    self.title = title
    self.start = start
    self.end = end
  }

  public func fact(source: String, capturedAt: Date) -> MeetingFact {
    MeetingFact(
      kind: MeetingFact.calendarEventKind, source: source, capturedAt: capturedAt,
      value: .object([
        "title": .string(title),
        "start": .number(start.timeIntervalSinceReferenceDate),
        "end": .number(end.timeIntervalSinceReferenceDate),
      ]))
  }
}

/// One person invited to the meeting's calendar event. An invitation says nothing about who
/// attended, who spoke, which voice is whose, or which company anyone works for.
public struct AttendeeFact: Sendable, Equatable {
  public enum Role: String, Sendable, Equatable {
    case required, optional, chair, nonParticipant, unknown
  }

  public enum Status: String, Sendable, Equatable {
    case accepted, declined, tentative, pending, delegated, completed, inProcess, unknown
  }

  public var name: String?
  public var email: String?
  public var role: Role
  public var status: Status
  public var isSelf: Bool
  public var isOrganizer: Bool

  public init(
    name: String?, email: String?, role: Role, status: Status, isSelf: Bool, isOrganizer: Bool
  ) {
    self.name = name
    self.email = email
    self.role = role
    self.status = status
    self.isSelf = isSelf
    self.isOrganizer = isOrganizer
  }

  public func fact(source: String, capturedAt: Date) -> MeetingFact {
    var object: [String: MeetingFactValue] = [
      "role": .string(role.rawValue),
      "status": .string(status.rawValue),
      "isSelf": .bool(isSelf),
      "isOrganizer": .bool(isOrganizer),
    ]
    if let name { object["name"] = .string(name) }
    if let email { object["email"] = .string(email) }
    return MeetingFact(
      kind: MeetingFact.attendeeKind, source: source, capturedAt: capturedAt,
      value: .object(object))
  }
}

extension MeetingFact {
  /// This fact as a calendar event, or nil for another kind or a value missing its title, start
  /// or end. Keys this build does not know are ignored here and kept in `value`.
  public var calendarEvent: CalendarEventFact? {
    guard kind == Self.calendarEventKind, let object = value.objectValue,
      let title = object["title"]?.stringValue,
      let start = object["start"]?.numberValue,
      let end = object["end"]?.numberValue
    else { return nil }
    return CalendarEventFact(
      title: title, start: Date(timeIntervalSinceReferenceDate: start),
      end: Date(timeIntervalSinceReferenceDate: end))
  }

  /// This fact as an invited person, or nil for another kind or a value with neither a name nor
  /// an email. A role or status this build does not know reads as `unknown`; the stored text is
  /// kept in `value`.
  public var attendee: AttendeeFact? {
    guard kind == Self.attendeeKind, let object = value.objectValue else { return nil }
    let name = object["name"]?.stringValue
    let email = object["email"]?.stringValue
    guard name != nil || email != nil else { return nil }
    return AttendeeFact(
      name: name, email: email,
      role: object["role"]?.stringValue.flatMap(AttendeeFact.Role.init(rawValue:)) ?? .unknown,
      status: object["status"]?.stringValue.flatMap(AttendeeFact.Status.init(rawValue:))
        ?? .unknown,
      isSelf: object["isSelf"]?.boolValue ?? false,
      isOrganizer: object["isOrganizer"]?.boolValue ?? false)
  }
}

/// The facts a meeting saves from the calendar event it matched at its start (#4286): one
/// `calendarEvent` fact and one `attendee` fact per invited person, in the calendar's order, all
/// stamped with the same source and capture time. Who those people are is derived later
/// (`MeetingParticipants`), never merged here.
public enum MeetingCalendarFacts {
  public static func facts(from snapshot: CalendarEventSnapshot, at capturedAt: Date)
    -> [MeetingFact]
  {
    let source = MeetingFact.eventKitSource
    let event = CalendarEventFact(title: snapshot.title, start: snapshot.start, end: snapshot.end)
    return [event.fact(source: source, capturedAt: capturedAt)]
      + snapshot.attendees.map { $0.fact(source: source, capturedAt: capturedAt) }
  }
}
