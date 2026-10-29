import EnviousWisprCore
import Foundation

/// The names the speaker-rename popover offers (#4013 r3 F3, r2 item 9): this meeting's saved
/// participant list, and the names the user wrote that no speaker carries any more
/// (`Transcript.unassignedSpeakerNames`). Never names from another meeting.
///
/// A value, compared by bytes, so a change to the suggestions alone redraws the document.
struct SpeakerRenameSuggestions: Equatable, Sendable {
  /// The call app's participant names for this meeting, as saved (duplicates kept).
  let roster: [String]
  /// Names the call app marked as the user; filtered from `roster` only.
  let selfNames: [String]
  /// Names the user wrote, kept on the row. Offered even when they match a self name.
  let authored: [String]
  /// Every speaker's current display name on the row, including speakers not shown now.
  let assigned: [String: String]

  static let none = SpeakerRenameSuggestions(roster: [], selfNames: [], authored: [], assigned: [:])

  init(roster: [String], selfNames: [String], authored: [String], assigned: [String: String]) {
    self.roster = roster
    self.selfNames = selfNames
    self.authored = authored
    self.assigned = assigned
  }

  /// From a History row and its meeting's saved roster (`nil` when none could be read).
  init(row: Transcript, roster: CallSpeakerRoster?) {
    self.init(
      roster: roster?.names ?? [], selfNames: roster?.selfNames ?? [],
      authored: row.unassignedSpeakerNames ?? [], assigned: row.speakerNames ?? [:])
  }

  /// What to offer when renaming `speakerId`: the user's own names first, then the roster
  /// without self names, each listed once in the first spelling seen; a name another speaker
  /// already shows is left out. The speaker's own current name is not "elsewhere".
  ///
  /// Names MATCH by Swift string equality (canonical equivalence: a composed and a decomposed
  /// "é" are one name), so an equivalent spelling never slips past the self, assigned or
  /// duplicate checks. Case and spaces still count. Redraw comparison (`==`) stays byte-exact.
  func names(for speakerId: String) -> [String] {
    let selfSet = Set(selfNames)
    let elsewhere = Set(assigned.filter { $0.key != speakerId }.values)
    var seen = Set<String>()
    var result: [String] = []
    for name in authored + roster.filter({ !selfSet.contains($0) }) {
      guard !name.isEmpty, !elsewhere.contains(name), seen.insert(name).inserted else { continue }
      result.append(name)
    }
    return result
  }

  static func == (a: Self, b: Self) -> Bool {
    sameBytes(a.roster, b.roster) && sameBytes(a.selfNames, b.selfNames)
      && sameBytes(a.authored, b.authored) && MeetingDocumentHash.sameBytes(a.assigned, b.assigned)
  }

  private static func sameBytes(_ a: [String], _ b: [String]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { MeetingDocumentHash.sameBytes($0, $1) }
  }
}

/// What History shows from a meeting's saved speaker evidence (#4013): the call's roster for the
/// rename list, and whether the recording positively noted that Accessibility was not allowed.
/// A missing, older or unreadable file gives no evidence at all, never a missing permission; a
/// recording with any segment that could read its call never shows permission as missing.
struct CallSpeakerEvidence: Equatable {
  let roster: CallSpeakerRoster
  let permissionMissing: Bool

  init(_ log: CallSpeakerLog) {
    roster = log.combinedRoster
    let statuses = log.segments.map(\.status)
    permissionMissing = statuses.contains(.noPermission) && !statuses.contains(.observed)
  }
}

/// A speaker-evidence read and the request it answers (#4013 r3 F3). A presentation shows it only
/// while its current request is this one, so a read that finishes after a switch to another
/// meeting, or after Delete audio or a deletion changed the request, is never shown.
struct KeyedRosterRead<Key: Hashable>: Equatable {
  let key: Key
  let evidence: CallSpeakerEvidence?

  /// The roster when `current` is the request this read answered, else `nil`.
  func roster(for current: Key?) -> CallSpeakerRoster? {
    current == key ? evidence?.roster : nil
  }

  /// Whether to explain missing speaker names: only for the request this read answered, and only
  /// when the recording noted that Accessibility was not allowed.
  func permissionMissing(for current: Key?) -> Bool {
    current == key && evidence?.permissionMissing == true
  }
}

/// The rename popover's keyboard highlight (#4013 r3 F3): which suggestion Return chooses. By
/// name, never by position, so a list that changes while the popover is open never moves it to
/// a neighbour. Editing the typed name clears it, so Return then saves what was typed.
struct RenameSuggestionHighlight: Equatable {
  private(set) var name: String?

  /// Down: the first suggestion, then the next; stays on the last.
  mutating func down(in suggestions: [String]) -> Bool {
    guard !suggestions.isEmpty else { return false }
    let next = name.flatMap(suggestions.firstIndex(of:)).map { $0 + 1 } ?? 0
    name = suggestions[min(next, suggestions.count - 1)]
    return true
  }

  /// Up: the previous suggestion; from the first, none. Unhandled when nothing is highlighted.
  mutating func up(in suggestions: [String]) -> Bool {
    guard let current = name.flatMap(suggestions.firstIndex(of:)) else { return false }
    name = current > 0 ? suggestions[current - 1] : nil
    return true
  }

  /// The user typed: Return saves the field, not an earlier highlight.
  mutating func fieldEdited() { name = nil }

  /// The highlighted name left the list: nothing is highlighted.
  mutating func listChanged(to suggestions: [String]) {
    if let name, !suggestions.contains(name) { self.name = nil }
  }

  mutating func clear() { name = nil }

  /// What Return chooses: the highlighted suggestion while it is still listed, else nothing
  /// (the typed name is committed).
  func choice(in suggestions: [String]) -> String? {
    name.flatMap { suggestions.contains($0) ? $0 : nil }
  }
}
