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
    // Tiles cannot tell that apart from two people sharing a name, hence the flag below.
    return CallSpeakerReading(
      speaking: uniqueInOrder(speaking),
      roster: CallSpeakerRoster(
        names: uniqueInOrder(tileNames), selfNames: uniqueInOrder(selfNames)),
      rosterFromParticipantList: false)
  }

  /// `Lee, Dana, Computer audio unmuted, Video off, active speaker` → name `Lee, Dana`, talking.
  /// The name is everything before the first audio-state part, so commas inside a name survive.
  static func parseTile(_ label: String) -> (name: String, isActiveSpeaker: Bool)? {
    let parts = label.components(separatedBy: ", ")
    guard
      let stateIndex = parts.firstIndex(where: { part in
        audioStatePrefixes.contains { part.hasPrefix($0) }
      }), stateIndex > 0
    else { return nil }
    let name = parts[..<stateIndex].joined(separator: ", ")
    guard !name.isEmpty else { return nil }
    return (name, parts[stateIndex...].contains(activeSpeakerFlag))
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
    // The self tile's text continues past the name ("Saurabh Vaish, Muted, ..."): take the roster
    // name it starts with, so a comma inside a name is never cut.
    let selfNames = uniqueInOrder(rosterNames).filter { name in
      selfTiles.contains { $0 == name || $0.hasPrefix(name + ", ") }
    }
    return CallSpeakerReading(
      speaking: uniqueInOrder(speaking),
      roster: CallSpeakerRoster(names: rosterNames, selfNames: selfNames),
      rosterFromParticipantList: !rosterNames.isEmpty)
  }

  /// `Alex Rivera (Guest), Meeting guest, Muted` → `Alex Rivera`. A row without a known role
  /// (the "In this meeting, 4 total" header) is not a person.
  static func rosterName(_ label: String) -> String? {
    let parts = label.components(separatedBy: ", ")
    guard let roleIndex = parts.firstIndex(where: roles.contains), roleIndex > 0 else {
      return nil
    }
    let name = displayName(parts[..<roleIndex].joined(separator: ", "))
    return name.isEmpty ? nil : name
  }

  static func displayName(_ raw: String) -> String {
    raw.hasSuffix(guestSuffix) ? String(raw.dropLast(guestSuffix.count)) : raw
  }
}
