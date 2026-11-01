import Foundation

/// One person invited to a meeting, derived from its attendee facts (#4286). An invitation says
/// nothing about who attended, who spoke, which voice is whose, or which company anyone works
/// for; nothing here claims any of those.
public struct MeetingParticipant: Sendable, Equatable {
  /// The display name as the invite spells it, trimmed; nil when the invite gave none.
  public var name: String?
  /// The trimmed, lowercased email; nil when the invite gave none.
  public var email: String?
  /// The part of `email` after its last "@" (for example "acme.com"); nil without one.
  public var emailDomain: String?
  public var role: AttendeeFact.Role
  public var status: AttendeeFact.Status
  public var isSelf: Bool
  public var isOrganizer: Bool

  public init(
    name: String?, email: String?, emailDomain: String?, role: AttendeeFact.Role,
    status: AttendeeFact.Status, isSelf: Bool, isOrganizer: Bool
  ) {
    self.name = name
    self.email = email
    self.emailDomain = emailDomain
    self.role = role
    self.status = status
    self.isSelf = isSelf
    self.isOrganizer = isOrganizer
  }
}

public enum MeetingParticipants {
  /// The invited people, in first-seen order, never persisted.
  ///
  /// Two entries are one person only when their trimmed, lowercased emails are identical and
  /// non-empty. Same name, same domain or no email at all never merges: two invitees can share
  /// a name. An entry with neither a name nor an email is dropped.
  ///
  /// When one email appears more than once, the person keeps the first entry's position and:
  /// the first non-empty name; the first role other than `unknown`; `declined` if any entry
  /// says declined, else the first status other than `unknown`; self and organizer if any entry
  /// says so. Entry order is not treated as a history of calendar updates.
  public static func resolve(attendees: [AttendeeFact]) -> [MeetingParticipant] {
    var people: [MeetingParticipant] = []
    var indexByEmail: [String: Int] = [:]
    for attendee in attendees {
      let name = trimmed(attendee.name)
      let email = trimmed(attendee.email)?.lowercased()
      guard name != nil || email != nil else { continue }
      let person = MeetingParticipant(
        name: name, email: email, emailDomain: email.flatMap(domain(of:)), role: attendee.role,
        status: attendee.status, isSelf: attendee.isSelf, isOrganizer: attendee.isOrganizer)
      guard let email else {
        people.append(person)
        continue
      }
      if let index = indexByEmail[email] {
        people[index] = merged(people[index], person)
      } else {
        indexByEmail[email] = people.count
        people.append(person)
      }
    }
    return people
  }

  private static func merged(_ first: MeetingParticipant, _ later: MeetingParticipant)
    -> MeetingParticipant
  {
    var person = first
    if person.name == nil { person.name = later.name }
    if person.role == .unknown { person.role = later.role }
    if later.status == .declined || person.status == .unknown { person.status = later.status }
    person.isSelf = first.isSelf || later.isSelf
    person.isOrganizer = first.isOrganizer || later.isOrganizer
    return person
  }

  private static func trimmed(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
    else { return nil }
    return text
  }

  private static func domain(of email: String) -> String? {
    guard let at = email.lastIndex(of: "@") else { return nil }
    let domain = email[email.index(after: at)...]
    return domain.isEmpty ? nil : String(domain)
  }
}
