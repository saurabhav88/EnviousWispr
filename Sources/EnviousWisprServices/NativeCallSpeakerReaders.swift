import EnviousWisprCore
import Foundation

/// Reads the Zoom desktop app's own talker signal (#4013 r1 R1). Observed on Zoom Workplace,
/// 2026-10-27 (`docs/audits/2026-10-27-4013/zoom-mac-names-findings.md`): every participant tile
/// is an `AXTabGroup` labelled `<Name>, Computer audio muted, Video off`, and the person talking
/// gets `, active speaker` added. The large Speaker-view tile alone is not evidence of talking.
package enum ZoomAppSpeakerReader {
  /// The audio-state part of a tile label. A label without one is not a participant tile.
  static let audioStatePrefixes = ["Computer audio", "Phone audio", "No audio"]
  static let activeSpeakerFlag = "active speaker"
  static let videoStates: Set<String> = ["Video off", "Video on"]

  package static func read(windows: [CallAXWindow]) -> CallSpeakerReading {
    var tileNames: [String] = []
    var speaking: [String] = []
    var selfNames: [String] = []
    for node in windows.flatMap({ $0.root.allNodes }) {
      if node.role == "AXTabGroup", let label = node.label, let tile = parseTile(label) {
        tileNames.append(tile.name)
        if tile.isActiveSpeaker { speaking.append(tile.name) }
      } else if node.role == "AXStaticText", let label = node.label,
        let name = selfName(fromParticipantEntry: label)
      {
        selfNames.append(name)
      }
    }
    // A person appears as a thumbnail and as the large Speaker-view tile: one name, two tiles.
    // Tiles cannot tell that apart from two people sharing a name, hence the flag below. The
    // participants panel would list each person once, but its tree was not captured on
    // 2026-10-27; reading it waits for that capture (#4013 C1) rather than a guessed shape.
    return CallSpeakerReading(
      speaking: uniqueInOrder(speaking),
      roster: CallSpeakerRoster(
        names: uniqueInOrder(tileNames), selfNames: uniqueInOrder(selfNames)),
      rosterFromParticipantList: false)
  }

  /// `Lee, Dana, Computer audio unmuted, Video off, active speaker` → name `Lee, Dana`, talking.
  /// Read from the end, where Zoom's structure is fixed: an optional `active speaker`, an
  /// optional video state, then exactly one audio state. Everything before that is the name, so
  /// commas and look-alike words inside a name survive. Any other ending is not read (no guess).
  static func parseTile(_ label: String) -> (name: String, isActiveSpeaker: Bool)? {
    var parts = label.components(separatedBy: ", ")
    let isActiveSpeaker = parts.last == activeSpeakerFlag
    if isActiveSpeaker { parts.removeLast() }
    if let last = parts.last, videoStates.contains(last) { parts.removeLast() }
    guard let state = parts.popLast(), audioStatePrefixes.contains(where: { state.hasPrefix($0) })
    else { return nil }
    let name = parts.joined(separator: ", ")
    return name.isEmpty ? nil : (name, isActiveSpeaker)
  }

  /// The participants panel marks the user: `Saurabh A Vaish (Host, me)` or `Dana (me)`.
  /// Only an explicit `me` counts; `(Host)` or `(Co-host)` alone is a role, not the user.
  static func selfName(fromParticipantEntry label: String) -> String? {
    guard label.hasSuffix(")"), let open = label.range(of: " (", options: .backwards) else {
      return nil
    }
    let inner = label[open.upperBound..<label.index(before: label.endIndex)]
    guard inner.components(separatedBy: ", ").contains("me") else { return nil }
    let name = String(label[..<open.lowerBound])
    return name.isEmpty ? nil : name
  }
}

/// Reads the Microsoft Teams app (teams2) (#4013 r1 R1). Observed 2026-10-27
/// (`docs/audits/2026-10-27-4013/teams-mac-names-findings.md`): the compact meeting view shows
/// `<Name> (Guest) is speaking`; roster rows read `<Name>[ (Guest)], <role>, <state>`; the
/// user's own tile reads `Myself video, <Name>, ...`. A role such as `Organizer` never marks the
/// user, and the main meeting window showed no talker signal, so none is read from it.
package enum TeamsAppSpeakerReader {
  static let speakingSuffix = " is speaking"
  static let guestSuffix = " (Guest)"
  static let selfTilePrefix = "Myself video, "
  /// Roles Teams places after the name in a roster row.
  static let roles: Set<String> = [
    "Organizer", "Co-organizer", "Presenter", "Attendee", "Meeting guest",
  ]
  /// The mute state that ends a roster row.
  static let muteStates: Set<String> = ["Muted", "Unmuted"]
  /// What follows the name on the user's own tile ("Muted, Has context menu").
  static let tileStates = ["Muted", "Unmuted", "Has context menu", "Context menu is available"]

  package static func read(windows: [CallAXWindow]) -> CallSpeakerReading {
    var speaking: [String] = []
    var rosterNames: [String] = []
    var selfTiles: [String] = []
    for node in windows.flatMap({ $0.root.allNodes }) {
      guard let label = node.label else { continue }
      switch node.role {
      case "AXGroup" where label.hasSuffix(speakingSuffix):
        let name = displayName(String(label.dropLast(speakingSuffix.count)))
        if !name.isEmpty { speaking.append(name) }
      case "AXRow":
        if let name = rosterName(label) { rosterNames.append(name) }
      case "AXMenuItem" where label.hasPrefix(selfTilePrefix):
        selfTiles.append(String(label.dropFirst(selfTilePrefix.count)))
      default:
        break
      }
    }
    // The self tile's text continues past the name ("Saurabh Vaish, Muted, ..."). A roster name
    // marks the user only when the text after it is a tile state or nothing, so "Lee" never
    // matches "Myself video, Lee, Dana, ...". More than one match is ambiguous: nobody is marked.
    let candidates = uniqueInOrder(rosterNames).filter { name in
      selfTiles.contains { tile in
        guard tile == name || tile.hasPrefix(name + ", ") else { return false }
        let rest = tile.dropFirst(name.count).drop { $0 == "," || $0 == " " }
        return rest.isEmpty || tileStates.contains(where: { rest.hasPrefix($0) })
      }
    }
    let selfNames = candidates.count == 1 ? candidates : []
    return CallSpeakerReading(
      speaking: uniqueInOrder(speaking),
      roster: CallSpeakerRoster(names: rosterNames, selfNames: selfNames),
      rosterFromParticipantList: !rosterNames.isEmpty)
  }

  /// `Alex Rivera (Guest), Meeting guest, Muted` → `Alex Rivera`. Read from the end: an optional
  /// mute state, then exactly one role; everything before is the name, so a role word inside a
  /// name survives. A row without that ending (the "In this meeting, 4 total" header) is not a
  /// person.
  static func rosterName(_ label: String) -> String? {
    var parts = label.components(separatedBy: ", ")
    if let last = parts.last, muteStates.contains(last) { parts.removeLast() }
    guard let role = parts.popLast(), roles.contains(role) else { return nil }
    let name = displayName(parts.joined(separator: ", "))
    return name.isEmpty ? nil : name
  }

  static func displayName(_ raw: String) -> String {
    raw.hasSuffix(guestSuffix) ? String(raw.dropLast(guestSuffix.count)) : raw
  }
}
