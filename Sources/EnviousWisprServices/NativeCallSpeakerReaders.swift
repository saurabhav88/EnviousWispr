import EnviousWisprCore
import Foundation

/// Reads the Zoom desktop app's own talker signal (#4013 r1 R1). Observed on Zoom Workplace,
/// 2026-10-27 (`docs/audits/2026-10-27-4013/zoom-mac-names-findings.md`): every participant tile
/// is an `AXTabGroup` labelled `<Name>, Computer audio muted, Video off`, and the person talking
/// gets `, active speaker` added. The large Speaker-view tile alone is not evidence of talking.
///
/// The roster comes from the participants panel when it is open and complete (#4013 C1a,
/// 2026-10-28, `docs/audits/2026-10-27-4013/c1a-receipt.txt`): an `AXOutline` labelled
/// `Participants list` holds one `AXStaticText` per person, duplicates kept, and a
/// `Participants (N)` text gives the count. Zoom keeps the panel closed by default; then the roster
/// is the tiles', which cannot tell one person on two tiles from two people sharing a name.
package enum ZoomAppSpeakerReader {
  /// The audio-state part of a tile label, exactly as observed. A label without one is not a
  /// participant tile; an unobserved wording is not read rather than matched by prefix.
  static let audioStates: Set<String> = [
    "Computer audio muted", "Computer audio unmuted", "No audio connected",
  ]
  static let activeSpeakerFlag = "active speaker"
  static let videoStates: Set<String> = ["Video off", "Video on"]
  static let participantsListLabel = "Participants list"
  static let participantsCountPrefix = "Participants ("
  /// The words Zoom puts in brackets after a name in the participants panel.
  static let panelTags: Set<String> = ["Host", "Co-host", "me", "Guest"]

  package static func read(windows: [CallAXWindow]) -> CallSpeakerReading {
    var tileNames: [String] = []
    var speaking: [String] = []
    var selfNames: [String] = []
    var listEntries: [String]?
    var listedCounts: Set<Int> = []
    for node in windows.flatMap({ $0.root.allNodes }) {
      if node.role == "AXOutline", node.label == participantsListLabel, listEntries == nil {
        listEntries = node.allNodes.filter { $0.role == "AXStaticText" }.compactMap(\.label)
      }
      if let label = node.label, let count = participantCount(label) {
        listedCounts.insert(count)
      }
      if node.role == "AXTabGroup", let label = node.label, let tile = parseTile(label) {
        tileNames.append(tile.name)
        if tile.isActiveSpeaker { speaking.append(tile.name) }
      } else if node.role == "AXStaticText", let label = node.label,
        let name = selfName(fromParticipantEntry: label)
      {
        selfNames.append(name)
      }
    }
    // The panel lists each person once, so a name listed twice is two people. It counts as the
    // participant list only when it is complete: exactly one "Participants (N)" count, equal to
    // the entries read. A longer list Zoom draws only partly fails that check.
    if let entries = listEntries, !entries.isEmpty, listedCounts == [entries.count] {
      return CallSpeakerReading(
        speaking: uniqueInOrder(speaking),
        roster: CallSpeakerRoster(
          names: entries.map { panelEntry($0).name }, selfNames: uniqueInOrder(selfNames)),
        rosterFromParticipantList: true)
    }
    // A person appears as a thumbnail and as the large Speaker-view tile: one name, two tiles.
    // Tiles cannot tell that apart from two people sharing a name, hence the flag below.
    return CallSpeakerReading(
      speaking: uniqueInOrder(speaking),
      roster: CallSpeakerRoster(
        names: uniqueInOrder(tileNames), selfNames: uniqueInOrder(selfNames)),
      rosterFromParticipantList: false)
  }

  /// `Participants (4)` → 4. Any other text → `nil`.
  static func participantCount(_ label: String) -> Int? {
    guard label.hasPrefix(participantsCountPrefix), label.hasSuffix(")") else { return nil }
    let digits = label.dropFirst(participantsCountPrefix.count).dropLast()
    guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else {
      return nil
    }
    return Int(digits)
  }

  /// `Saurabh A Vaish (Host, me)` → name `Saurabh A Vaish`. Only a trailing bracket made of
  /// Zoom's own tags is removed, so a name such as `Dana (Design)` keeps its bracket.
  static func panelEntry(_ label: String) -> (name: String, tags: [String]) {
    guard label.hasSuffix(")"), let open = label.range(of: " (", options: .backwards) else {
      return (label, [])
    }
    let tags = label[open.upperBound..<label.index(before: label.endIndex)]
      .components(separatedBy: ", ")
    guard tags.allSatisfy(panelTags.contains) else { return (label, []) }
    let name = String(label[..<open.lowerBound])
    return name.isEmpty ? (label, []) : (name, tags)
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
    guard let state = parts.popLast(), audioStates.contains(state) else { return nil }
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
  static let tileStates: Set<String> = [
    "Muted", "Unmuted", "Has context menu", "Context menu is available",
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
    // The self tile's text continues past the name ("Saurabh Vaish, Muted, ..."). A roster name
    // marks the user only when the text after it is a tile state or nothing, so "Lee" never
    // matches "Myself video, Lee, Dana, ...". More than one match is ambiguous: nobody is marked.
    let candidates = uniqueInOrder(rosterNames).filter { name in
      selfTiles.contains { tile in
        if tile == name { return true }
        guard tile.hasPrefix(name + ", ") else { return false }
        // Every remaining part must be a known tile state, so "Lee, Muted engineer, Muted"
        // never makes "Lee" the user.
        return tile.dropFirst(name.count + 2).components(separatedBy: ", ")
          .allSatisfy(tileStates.contains)
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
