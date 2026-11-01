@preconcurrency import EventKit
import EnviousWisprCore
import Foundation

/// The user's calendar, read on the Mac to name EnviousMeet meetings and note who was invited
/// (#4017 R1, R5; #4286).
///
/// It only reads: it never creates, changes or deletes an event. What it reads is saved with the
/// meeting on the Mac; the invited people also go into the meeting's summary request, which
/// reaches only the summary provider the user chose. macOS 14 offers "full access" or "write
/// only" for events; reading events needs full access, so that is what it asks for (`NSCalendarsFullAccessUsageDescription`, plus the
/// `com.apple.security.personal-information.calendars` entitlement Hardened Runtime requires).
public enum CalendarAccess {
  public enum Status: String, Sendable, Equatable {
    case granted
    case denied
    /// macOS has not asked yet.
    case notAsked
    /// Restricted by a device profile.
    case unavailable
  }

  public static func status() -> Status {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess: return .granted
    // Write-only access cannot read titles; full access is granted in System Settings,
    // so it reads like a refusal and offers that page.
    case .denied, .writeOnly: return .denied
    case .notDetermined: return .notAsked
    case .restricted: return .unavailable
    @unknown default: return .unavailable
    }
  }

  /// Makes macOS ask for full calendar access. Returns the resulting status; a throw from
  /// EventKit reads as the status macOS now reports.
  public static func request() async -> Status {
    let store = EKEventStore()
    _ = try? await store.requestFullAccessToEvents()
    return status()
  }

  /// The event a meeting that starts at `date` matches, as plain values (#4017 R5; #4286): an
  /// event whose time span contains `date` (with ten minutes of slack each side), skipping
  /// all-day events. When several match, one with a meeting link or a location wins; still
  /// several, or none, gives nil (a wrong name is worse than the date). The title and the
  /// invited people come from that one event. Nil without full access.
  public static func eventSnapshot(at date: Date) -> CalendarEventSnapshot? {
    guard status() == .granted else { return nil }
    let store = EKEventStore()
    let slack: TimeInterval = 10 * 60
    let predicate = store.predicateForEvents(
      withStart: date.addingTimeInterval(-slack), end: date.addingTimeInterval(slack),
      calendars: nil)
    let candidates = store.events(matching: predicate).filter { event in
      !event.isAllDay
        && event.startDate.addingTimeInterval(-slack) <= date
        && date <= event.endDate.addingTimeInterval(slack)
    }
    guard
      let index = pick(
        candidates.map {
          Candidate(
            title: $0.title, hasMeetingPlace: $0.url != nil || !($0.location ?? "").isEmpty)
        }),
      let title = cleanTitle(candidates[index].title)
    else { return nil }
    let event = candidates[index]
    return CalendarEventSnapshot(
      title: title, start: event.startDate, end: event.endDate,
      attendees: attendees(of: event))
  }

  /// The choice rule on plain values, so it can be tested without a calendar.
  public struct Candidate: Sendable, Equatable {
    public let title: String?
    public let hasMeetingPlace: Bool
    public init(title: String?, hasMeetingPlace: Bool) {
      self.title = title
      self.hasMeetingPlace = hasMeetingPlace
    }
  }

  /// The index of the one event to use, or nil: events with a blank title never count; among
  /// the rest, those with a meeting link or a place win; exactly one must remain.
  public static func pick(_ candidates: [Candidate]) -> Int? {
    let named = candidates.indices.filter { cleanTitle(candidates[$0].title) != nil }
    let preferred = named.filter { candidates[$0].hasMeetingPlace }
    let pool = preferred.isEmpty ? named : preferred
    guard pool.count == 1 else { return nil }
    return pool[0]
  }

  /// The title trimmed and cut to 120 characters, or nil when blank.
  public static func cleanTitle(_ title: String?) -> String? {
    let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
  }

  /// One calendar participant as plain values: its address (to recognise the organizer) and
  /// the invited person it maps to, if any.
  typealias ParticipantInput = (url: URL?, fact: AttendeeFact?)

  private static func participantInput(_ participant: EKParticipant) -> ParticipantInput {
    (
      participant.url,
      attendee(
        name: participant.name, url: participant.url, type: participant.participantType,
        role: participant.participantRole, status: participant.participantStatus,
        isCurrentUser: participant.isCurrentUser, isOrganizer: false)
    )
  }

  private static func attendees(of event: EKEvent) -> [AttendeeFact] {
    attendees(
      (event.attendees ?? []).map { participantInput($0) },
      organizer: event.organizer.map { participantInput($0) })
  }

  /// The event's invited people in the calendar's order. The organizer is marked on the
  /// attendee with the same address, or added when the calendar lists it only as organizer;
  /// a display name never identifies anyone.
  static func attendees(
    _ participants: [ParticipantInput], organizer: ParticipantInput?
  ) -> [AttendeeFact] {
    let organizerURL = organizer?.url
    var people: [AttendeeFact] = []
    var organizerListed = false
    for participant in participants {
      let isOrganizer = organizerURL != nil && participant.url == organizerURL
      if isOrganizer { organizerListed = true }
      if var person = participant.fact {
        person.isOrganizer = isOrganizer
        people.append(person)
      }
    }
    if !organizerListed, var person = organizer?.fact {
      person.isOrganizer = true
      people.append(person)
    }
    return people
  }

  /// One participant as an invited person, on plain values so it can be tested without a
  /// calendar. Rooms, resources and groups give nil. The email is taken only from a `mailto:`
  /// address, lowercased.
  public static func attendee(
    name: String?, url: URL?, type: EKParticipantType, role: EKParticipantRole,
    status: EKParticipantStatus, isCurrentUser: Bool, isOrganizer: Bool
  ) -> AttendeeFact? {
    switch type {
    case .person, .unknown: break
    case .room, .resource, .group: return nil
    @unknown default: return nil
    }
    var email: String?
    if let url, url.scheme?.lowercased() == "mailto" {
      let address = url.absoluteString.dropFirst("mailto:".count)
        .removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if let address, !address.isEmpty { email = address }
    }
    return AttendeeFact(
      name: name, email: email, role: attendeeRole(role), status: attendeeStatus(status),
      isSelf: isCurrentUser, isOrganizer: isOrganizer)
  }

  static func attendeeRole(_ role: EKParticipantRole) -> AttendeeFact.Role {
    switch role {
    case .required: return .required
    case .optional: return .optional
    case .chair: return .chair
    case .nonParticipant: return .nonParticipant
    case .unknown: return .unknown
    @unknown default: return .unknown
    }
  }

  static func attendeeStatus(_ status: EKParticipantStatus) -> AttendeeFact.Status {
    switch status {
    case .accepted: return .accepted
    case .declined: return .declined
    case .tentative: return .tentative
    case .pending: return .pending
    case .delegated: return .delegated
    case .completed: return .completed
    case .inProcess: return .inProcess
    case .unknown: return .unknown
    @unknown default: return .unknown
    }
  }
}
