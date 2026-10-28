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
    // Every participants list on screen, each with the counts shown in its own window.
    var lists: [(entries: [String], counts: Set<Int>)] = []
    for window in windows {
      let nodes = window.root.allNodes
      let counts = Set(nodes.compactMap { $0.label.flatMap(participantCount) })
      for node in nodes where node.role == "AXOutline" && node.label == participantsListLabel {
        lists.append(
          (node.allNodes.filter { $0.role == "AXStaticText" }.compactMap(\.label), counts))
      }
    }
    // Speaker-view thumbnails carry a video state and show each participant once; the large
    // tile repeats one of them without it (C1a/C1b, 2026-10-28). Only thumbnails are people.
    var thumbnails: [(name: String?, talking: Bool)] = []
    var flaggedOutsideThumbnails = false
    for node in windows.flatMap({ $0.root.allNodes }) {
      if node.role == "AXTabGroup", let label = node.label, let tile = parseTile(label) {
        // A tile with Zoom's structure but no name is still a person; it is kept unnamed.
        let name: String? = tile.name.isEmpty ? nil : tile.name
        if let name {
          tileNames.append(name)
          if tile.isActiveSpeaker { speaking.append(name) }
        }
        if tile.hasVideoState {
          thumbnails.append((name, tile.isActiveSpeaker))
        } else if tile.isActiveSpeaker {
          flaggedOutsideThumbnails = true
        }
      } else if node.role == "AXStaticText", let label = node.label,
        let name = selfName(fromParticipantEntry: label)
      {
        selfNames.append(name)
      }
    }
    // The panel lists each person once, so a name listed twice is two people. It counts as the
    // participant list only when it is the only list on screen and complete: its own window
    // shows exactly one "Participants (N)" count, equal to the entries read. A longer list Zoom
    // draws only partly, or two lists, fall back to the tiles.
    let selfList = uniqueInOrder(selfNames)
    let thumbnailNames = thumbnails.compactMap(\.name)
    let participants = thumbnails.enumerated().map { index, tile in
      CallParticipant(
        key: "thumbnail-\(index)", name: tile.name, isTalking: tile.talking,
        isSelf: tile.name != nil && selfList == [tile.name!]
          && thumbnailNames.filter { $0 == tile.name }.count == 1)
    }
    // Every list's own duplicates are two people, whether or not that list is complete.
    let listedTwice = lists.reduce(into: Set<String>()) { shared, list in
      shared.formUnion(repeatedNames(list.entries.map { panelEntry($0).name }))
    }
    // Identity holds when the thumbnails are the people and no talking flag sits elsewhere.
    let identity = !thumbnails.isEmpty && !flaggedOutsideThumbnails
    if lists.count == 1, let list = lists.first, !list.entries.isEmpty,
      list.counts == [list.entries.count]
    {
      let names = list.entries.map { panelEntry($0).name }
      return CallSpeakerReading(
        speaking: uniqueInOrder(speaking),
        roster: CallSpeakerRoster(names: names, selfNames: selfList),
        rosterFromParticipantList: true, participants: participants,
        participantIdentityEstablished: identity,
        sharedNames: listedTwice.union(repeatedNames(thumbnailNames)))
    }
    return CallSpeakerReading(
      speaking: uniqueInOrder(speaking),
      roster: CallSpeakerRoster(
        names: identity ? thumbnailNames : uniqueInOrder(tileNames), selfNames: selfList),
      rosterFromParticipantList: false, participants: participants,
      participantIdentityEstablished: identity,
      sharedNames: listedTwice.union(repeatedNames(thumbnailNames)))
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
  static func parseTile(_ label: String)
    -> (name: String, isActiveSpeaker: Bool, hasVideoState: Bool)?
  {
    var parts = label.components(separatedBy: ", ")
    let isActiveSpeaker = parts.last == activeSpeakerFlag
    if isActiveSpeaker { parts.removeLast() }
    var hasVideoState = false
    if let last = parts.last, videoStates.contains(last) {
      parts.removeLast()
      hasVideoState = true
    }
    guard let state = parts.popLast(), audioStates.contains(state) else { return nil }
    // An empty name is returned as "": the tile is still a person the caller must not drop.
    return (parts.joined(separator: ", "), isActiveSpeaker, hasVideoState)
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
    var tileNames: [String] = []
    var unnamedTalker = false
    var selfTileTalking = false
    // Each window's roster rows and the "In this meeting, N total" counts shown in that window.
    var rosters: [(names: [String], counts: Set<Int>)] = []
    for window in windows {
      let nodes = window.root.allNodes
      let names = nodes.filter { $0.role == "AXRow" }.compactMap { $0.label.flatMap(rosterName) }
      let counts = Set(nodes.compactMap { $0.label.flatMap(meetingCount) })
      if !names.isEmpty { rosters.append((names, counts)) }
    }
    for node in windows.flatMap({ $0.root.allNodes }) {
      guard let label = node.label else { continue }
      switch node.role {
      case "AXGroup" where label.hasSuffix(speakingSuffix):
        let name = displayName(String(label.dropLast(speakingSuffix.count)))
        if name.isEmpty { unnamedTalker = true } else { speaking.append(name) }
      case "AXRow":
        if let name = rosterName(label) { rosterNames.append(name) }
      case "AXMenuItem" where label.hasPrefix(selfTilePrefix):
        selfTiles.append(String(label.dropFirst(selfTilePrefix.count)))
        if hasTalkingFrame(node) { selfTileTalking = true }
      case "AXMenuItem":
        // The main window marks the talker's gallery tile with a frame carrying this class
        // (C1 Teams run 2, 2026-10-28; the signal Superwhisper reads).
        let talkingTile = hasTalkingFrame(node)
        if let name = tileName(label) {
          tileNames.append(name)
          if talkingTile { speaking.append(name) }
        } else if talkingTile {
          unnamedTalker = true
        }
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
    // With People closed there are no rows: the one self tile gives the user's exact name.
    let selfFromTile = selfTiles.count == 1 ? selfTileName(selfTiles[0]) : nil
    let selfNames =
      rosterNames.isEmpty ? (selfFromTile.map { [$0] } ?? []) : (candidates.count == 1 ? candidates : [])
    // The user's own tile talking is the user (the namer removes self); a self tile whose name is
    // not known adds nobody.
    if selfTileTalking, selfNames.count == 1 { speaking.append(selfNames[0]) }
    // A complete participant list (C1 Teams run, 2026-10-28): roster rows in exactly one window,
    // whose own "In this meeting, N total" count is the one count there and equals the people
    // read. Duplicate names stay; a partial, uncounted or contested list keeps its names for
    // suggestions but is not a participant list.
    let complete =
      rosters.count == 1 && rosters[0].counts == [rosters[0].names.count]
    // People: the roster rows when People is open, one row per person; otherwise the gallery
    // tiles, one per person, with the user's own tile. Never both, so a row and its tile are not
    // counted as two people. A talker shown in neither is still a participant.
    let shown: [String]
    if rosters.count == 1 {
      shown = rosters[0].names
    } else if rosters.isEmpty {
      shown = tileNames + (selfNames.count == 1 ? selfNames : [])
    } else {
      shown = []
    }
    let talking = Set(uniqueInOrder(speaking))
    var participants = shown.enumerated().map { index, name in
      CallParticipant(
        key: "person-\(index)", name: name, isTalking: talking.contains(name),
        isSelf: selfNames == [name] && shown.filter { $0 == name }.count == 1)
    }
    if unnamedTalker {
      participants.append(
        CallParticipant(key: "unnamed-talker", name: nil, isTalking: true, isSelf: false))
    }
    for (index, name) in uniqueInOrder(speaking).enumerated() where !shown.contains(name) {
      participants.append(
        CallParticipant(key: "talker-\(index)", name: name, isTalking: true, isSelf: false))
    }
    return CallSpeakerReading(
      speaking: uniqueInOrder(speaking),
      // With People closed the gallery is the roster offered for renaming.
      roster: CallSpeakerRoster(names: rosterNames.isEmpty ? shown : rosterNames, selfNames: selfNames),
      rosterFromParticipantList: complete, participants: participants,
      // Rows in two windows cannot be matched to each other: no identity.
      participantIdentityEstablished: rosters.count <= 1 && !participants.isEmpty,
      // Each representation's own duplicates are two people; rows and tiles are never added.
      sharedNames: rosters.reduce(into: repeatedNames(tileNames)) { $0.formUnion(repeatedNames($1.names)) })
  }

  /// `Saurabh Vaish, Muted, Has context menu` (after "Myself video, ") → `Saurabh Vaish`:
  /// trailing tile states removed, the rest kept exactly.
  static func selfTileName(_ tile: String) -> String? {
    var parts = tile.components(separatedBy: ", ")
    while let last = parts.last, tileStates.contains(last) { parts.removeLast() }
    let name = parts.joined(separator: ", ")
    return name.isEmpty ? nil : name
  }

  /// A gallery tile, `Alex Rivera (Guest), muted, Context menu is available` → `Alex Rivera`.
  /// Read from the end: tile states only, then the name. Any other ending is not a tile.
  static func tileName(_ label: String) -> String? {
    var parts = label.components(separatedBy: ", ")
    guard parts.last == "Context menu is available" else { return nil }
    while let last = parts.last, galleryTileStates.contains(last) { parts.removeLast() }
    let name = displayName(parts.joined(separator: ", "))
    return name.isEmpty ? nil : name
  }

  /// The class on the frame inside the talker's gallery tile in the main meeting window.
  static let talkingFrameClass = "vdi-frame-occlusion"

  /// Whether the tile's own subtree holds the talking frame. A tile nested inside it is another
  /// participant, so its frame is never this tile's.
  static func hasTalkingFrame(_ tile: CallAXNode) -> Bool {
    var queue = tile.children
    while !queue.isEmpty {
      let node = queue.removeFirst()
      if node.role == "AXMenuItem" { continue }
      if node.domClassList.contains(talkingFrameClass) { return true }
      queue.append(contentsOf: node.children)
    }
    return false
  }

  /// What follows the name on another participant's gallery tile (C1 Teams run, 2026-10-28).
  static let galleryTileStates: Set<String> = ["muted", "Context menu is available"]

  /// `In this meeting, 4 total` or `In this meeting, 4 total Mute all` → 4. Any other text → nil.
  static func meetingCount(_ label: String) -> Int? {
    let prefix = "In this meeting, "
    guard label.hasPrefix(prefix) else { return nil }
    let rest = label.dropFirst(prefix.count)
    let digits = rest.prefix { $0.isASCII && $0.isNumber }
    guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(" total") else { return nil }
    let tail = rest.dropFirst(digits.count + " total".count)
    guard tail.isEmpty || tail == " Mute all" else { return nil }
    return Int(digits)
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
