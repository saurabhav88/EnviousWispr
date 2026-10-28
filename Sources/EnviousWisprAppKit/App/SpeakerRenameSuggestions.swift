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
  /// without self names, each spelled as stored and listed once; a name another speaker
  /// already shows is left out. The speaker's own current name is not "elsewhere".
  func names(for speakerId: String) -> [String] {
    let selfSet = Set(selfNames.map(Self.bytes))
    let elsewhere = Set(assigned.filter { $0.key != speakerId }.values.map(Self.bytes))
    var seen = Set<[UInt8]>()
    var result: [String] = []
    for name in authored + roster.filter({ !selfSet.contains(Self.bytes($0)) }) {
      let key = Self.bytes(name)
      guard !name.isEmpty, !elsewhere.contains(key), seen.insert(key).inserted else { continue }
      result.append(name)
    }
    return result
  }

  /// Strings compared as their UTF-8 bytes, as the rest of the meeting document is: two
  /// spellings that Swift calls equal ("é" composed or not) are different names on screen.
  private static func bytes(_ name: String) -> [UInt8] { Array(name.utf8) }

  static func == (a: Self, b: Self) -> Bool {
    sameBytes(a.roster, b.roster) && sameBytes(a.selfNames, b.selfNames)
      && sameBytes(a.authored, b.authored) && MeetingDocumentHash.sameBytes(a.assigned, b.assigned)
  }

  private static func sameBytes(_ a: [String], _ b: [String]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { MeetingDocumentHash.sameBytes($0, $1) }
  }
}
