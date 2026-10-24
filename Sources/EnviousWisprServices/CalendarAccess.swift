@preconcurrency import EventKit
import Foundation

/// The user's calendar, read on the Mac to name EnviousMeet meetings (#4017 R1, R5).
///
/// It only reads: it never creates, changes or deletes an event, and nothing it reads leaves the
/// Mac. macOS 14 offers "full access" or "write only" for events; reading titles needs full
/// access, so that is what it asks for (`NSCalendarsFullAccessUsageDescription`, plus the
/// `com.apple.security.personal-information.calendars` entitlement Hardened Runtime requires).
public enum CalendarAccess {
  public enum Status: String, Sendable, Equatable {
    case granted
    case denied
    /// macOS has not asked yet.
    case notAsked
    /// Restricted by a device profile, or write-only access that cannot read titles.
    case unavailable
  }

  public static func status() -> Status {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess: return .granted
    case .denied: return .denied
    case .notDetermined: return .notAsked
    case .restricted, .writeOnly: return .unavailable
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

  /// One event's title for a meeting that starts at `date`: an event whose time span contains
  /// `date` (with ten minutes of slack each side), skipping all-day events. When several match,
  /// one with a meeting link or a location wins; still several, or none, gives nil (a wrong
  /// name is worse than the date). Nil without full access.
  public static func eventTitle(at date: Date) -> String? {
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
    return pickTitle(
      candidates.map {
        Candidate(title: $0.title, hasMeetingPlace: $0.url != nil || !($0.location ?? "").isEmpty)
      })
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

  public static func pickTitle(_ candidates: [Candidate]) -> String? {
    let named = candidates.filter {
      !($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let preferred = named.filter(\.hasMeetingPlace)
    let pool = preferred.isEmpty ? named : preferred
    guard pool.count == 1, let title = pool[0].title else { return nil }
    return String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
  }
}
