import EnviousWisprCore
import Foundation

/// How far a selector rule has been checked against a real call (#4013 D3, chunk 4). Only a
/// `.verified` rule may report who is talking; an `.unverified` rule (copied from another app's
/// defaults, or written before a capture) still reads names but never a talker.
package enum TalkerRuleVerification: String, Sendable, Equatable {
  case verified
  case unverified
}

/// Where a participant tile's name comes from.
package enum TileNameSource: Sendable, Equatable {
  /// The first static text inside the tile (Meet, Slack).
  case firstStaticText
  /// The tile's own label, with an exact structural suffix removed when present
  /// (Teams web guest tiles read `<Name> Unverified`).
  case ownLabel(removingSuffix: String?)
}

/// One surface's selectors (#4013 §3 item 2, chunk 4). Plain values: the rules store (chunk 5)
/// decodes them from the bundled and downloaded file. A `nil` tile selector means the surface's
/// tile shape is not known yet: nothing is read from tiles.
package struct SpeakerSelectorRule: Sendable, Equatable {
  package let surface: CallSpeakerSurface
  /// A participant tile is an element whose role equals this, when set...
  package let tileRole: String?
  /// ...and whose DOM classes include this exact token, when set. At least one must be set.
  package let tileClass: String?
  package let nameSource: TileNameSource
  /// Exact DOM class tokens that mark a tile as talking when found on the tile or inside it
  /// (never inside another tile nested within it). Empty for roster-only surfaces.
  package let talkingClasses: [String]
  /// The participant list: an element with this exact DOM class whose direct children are one
  /// entry per person, each named by its first static text. `nil` when the list is not known.
  package let participantListClass: String?
  package let verification: TalkerRuleVerification

  package init(
    surface: CallSpeakerSurface, tileRole: String?, tileClass: String?,
    nameSource: TileNameSource, talkingClasses: [String], participantListClass: String?,
    verification: TalkerRuleVerification
  ) {
    self.surface = surface
    self.tileRole = tileRole
    self.tileClass = tileClass
    self.nameSource = nameSource
    self.talkingClasses = talkingClasses
    self.participantListClass = participantListClass
    self.verification = verification
  }

  /// A surface whose shape is not captured yet: reads nothing (#4013 chunk 4).
  package static func unconfigured(_ surface: CallSpeakerSurface) -> Self {
    Self(
      surface: surface, tileRole: nil, tileClass: nil, nameSource: .firstStaticText,
      talkingClasses: [], participantListClass: nil, verification: .unverified)
  }

  /// Roster-only surfaces never report a talker, whatever the rule says (#4013 D4).
  var mayReportTalker: Bool {
    verification == .verified && !talkingClasses.isEmpty && !Self.rosterOnly.contains(surface)
  }

  static let rosterOnly: Set<CallSpeakerSurface> = [
    .facetime, .webex, .dialpad, .gather, .lark, .voov, .whereby, .jitsi,
  ]

  func isTile(_ node: CallAXNode) -> Bool {
    guard tileRole != nil || tileClass != nil else { return false }
    if let tileRole, node.role != tileRole { return false }
    if let tileClass, !node.domClassList.contains(tileClass) { return false }
    return true
  }
}

/// Reads a call surface through a `SpeakerSelectorRule` (#4013 chunk 4): Meet, Teams web and
/// Slack huddles, and the roster-only surfaces. The selectors are data, so a changed call app is
/// fixed by a new rules file rather than an app release (#4013 D3).
package enum RulesSpeakerReader {

  /// A browser surface: reads the single page whose address classifies as `family`. No page, or
  /// two call pages, reads nothing.
  package static func read(
    documents: [CallAXDocument], family: CallAppFamily, rule: SpeakerSelectorRule
  ) -> CallSpeakerReading? {
    let pages = documents.filter { $0.url.flatMap(CallMeetingURL.classify)?.family == family }
    guard pages.count == 1, let page = pages.first else { return nil }
    return read(root: page.root, rule: rule)
  }

  /// An app surface (Slack app, roster-only apps): reads every window of that app.
  package static func read(windows: [CallAXWindow], rule: SpeakerSelectorRule)
    -> CallSpeakerReading
  {
    read(root: CallAXNode(role: "AXApplication", children: windows.map(\.root)), rule: rule)
  }

  static func read(root: CallAXNode, rule: SpeakerSelectorRule) -> CallSpeakerReading {
    var tileNames: [String] = []
    var speaking: [String] = []
    for tile in tiles(in: root, rule: rule) {
      // A tile without a readable name is skipped, and its talking signal with it: a signal is
      // never given another tile's name.
      guard let name = name(of: tile, rule: rule) else { continue }
      tileNames.append(name)
      if rule.mayReportTalker, isTalking(tile, rule: rule) { speaking.append(name) }
    }
    let listNames = participantList(in: root, rule: rule)
    let fromList = listNames != nil
    return CallSpeakerReading(
      speaking: uniqueInOrder(speaking),
      // A participant list shows each person once, so its duplicates are real; tiles repeat one
      // person, so they are de-duplicated and the roster is marked tile-only.
      roster: CallSpeakerRoster(names: listNames ?? uniqueInOrder(tileNames), selfNames: []),
      rosterFromParticipantList: fromList)
  }

  /// Tiles in document order, outermost first. A tile nested in another is its own tile.
  static func tiles(in root: CallAXNode, rule: SpeakerSelectorRule) -> [CallAXNode] {
    root.allNodes.filter(rule.isTile)
  }

  static func name(of tile: CallAXNode, rule: SpeakerSelectorRule) -> String? {
    let raw: String?
    switch rule.nameSource {
    case .firstStaticText:
      raw =
        ownSubtree(of: tile, rule: rule).first { $0.role == "AXStaticText" && $0.label != nil }?
        .label
    case .ownLabel(let suffix):
      if let label = tile.label, let suffix, label.hasSuffix(suffix) {
        raw = String(label.dropLast(suffix.count))
      } else {
        raw = tile.label
      }
    }
    guard let name = raw, !name.isEmpty else { return nil }
    return name
  }

  /// A talking class on the tile itself or anywhere inside it, nested tiles excluded.
  static func isTalking(_ tile: CallAXNode, rule: SpeakerSelectorRule) -> Bool {
    ownSubtree(of: tile, rule: rule).contains { node in
      node.domClassList.contains { rule.talkingClasses.contains($0) }
    }
  }

  /// The tile and its descendants, stopping at any nested tile.
  static func ownSubtree(of tile: CallAXNode, rule: SpeakerSelectorRule) -> [CallAXNode] {
    var nodes = [tile]
    var queue = tile.children
    while !queue.isEmpty {
      let node = queue.removeFirst()
      if rule.isTile(node) { continue }
      nodes.append(node)
      queue.append(contentsOf: node.children)
    }
    return nodes
  }

  /// The participant list's names, one per direct child entry, when exactly one list exists.
  /// `nil` when the rule names no list, the list is absent, or more than one matches.
  static func participantList(in root: CallAXNode, rule: SpeakerSelectorRule) -> [String]? {
    guard let listClass = rule.participantListClass else { return nil }
    let lists = root.allNodes.filter { $0.domClassList.contains(listClass) }
    guard lists.count == 1, let list = lists.first else { return nil }
    let names = list.children.compactMap { entry in
      entry.allNodes.first { $0.role == "AXStaticText" && $0.label?.isEmpty == false }?.label
    }
    return names.isEmpty ? nil : names
  }
}
