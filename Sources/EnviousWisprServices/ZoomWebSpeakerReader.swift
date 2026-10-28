import EnviousWisprCore
import Foundation

/// What is known about the Zoom web client's layout when a snapshot is read. Each value is
/// `nil` until something actually establishes it: no Accessibility detector for Speaker view,
/// pinning or spotlight exists yet (#4013 C1 must establish one), and Zoom's default layout or a
/// missing control is not proof. A caller that knows nothing passes `.unknown`.
package struct ZoomWebLayoutEvidence: Sendable, Equatable {
  package let isSpeakerView: Bool?
  package let hasPinnedOrSpotlightedTile: Bool?

  package init(isSpeakerView: Bool?, hasPinnedOrSpotlightedTile: Bool?) {
    self.isSpeakerView = isSpeakerView
    self.hasPinnedOrSpotlightedTile = hasPinnedOrSpotlightedTile
  }

  package static let unknown = ZoomWebLayoutEvidence(
    isSpeakerView: nil, hasPinnedOrSpotlightedTile: nil)

  /// The largest tile follows the talker only in Speaker view with nothing pinned or spotlighted.
  var largestTileFollowsTalker: Bool {
    isSpeakerView == true && hasPinnedOrSpotlightedTile == false
  }
}

/// Reads the Zoom web client (#4013 r1 R1). Observed 2026-10-27 in Chrome
/// (`docs/audits/2026-10-27-4013/zoom-web-names-findings.md`): each tile's name is an
/// `AXStaticText` inside a group with DOM class `video-avatar__avatar-name`; there is no text
/// talking label, and in Speaker view the main tile's name is much larger than the thumbnails'
/// and moved to the new talker. That size is talking evidence only under
/// `ZoomWebLayoutEvidence.largestTileFollowsTalker`; otherwise only the roster is read.
package enum ZoomWebSpeakerReader {
  static let nameClass = "video-avatar__avatar-name"

  /// `nil` when the pages hold no single Zoom call page: none, or more than one (two call tabs
  /// cannot be told apart, so neither is read).
  package static func read(documents: [CallAXDocument], layout: ZoomWebLayoutEvidence)
    -> CallSpeakerReading?
  {
    let calls = documents.filter { document in
      document.url.flatMap(CallMeetingURL.classify)?.family == .zoom
    }
    guard calls.count == 1, let page = calls.first else { return nil }

    let tiles = page.root.allNodes.compactMap(nameTile)
    let speaking = layout.largestTileFollowsTalker ? uniqueLargest(tiles).map { [$0] } ?? [] : []
    // Each person shows as a thumbnail and, when talking, as the main tile: tiles never prove two
    // people share a name, so the roster is de-duplicated and marked as tile-only.
    return CallSpeakerReading(
      speaking: speaking,
      roster: CallSpeakerRoster(names: uniqueInOrder(tiles.map(\.name)), selfNames: []),
      rosterFromParticipantList: false)
  }

  /// A tile's name: the first text inside a name-class group, with that text's height.
  static func nameTile(_ node: CallAXNode) -> (name: String, height: Double?)? {
    guard node.domClassList.contains(nameClass) else { return nil }
    guard let text = node.allNodes.first(where: { $0.role == "AXStaticText" && $0.label != nil }),
      let name = text.label, !name.isEmpty
    else { return nil }
    return (name, text.height)
  }

  /// The one tile whose name is strictly taller than every other tile's. Any tile without a
  /// usable height, a tie for tallest (even between two tiles with one name), or a lone tile
  /// means no talker (#4013 D5).
  static func uniqueLargest(_ tiles: [(name: String, height: Double?)]) -> String? {
    var measured: [(name: String, height: Double)] = []
    for tile in tiles {
      guard let height = tile.height, height.isFinite, height > 0 else { return nil }
      measured.append((tile.name, height))
    }
    guard let tallest = measured.max(by: { $0.height < $1.height }) else { return nil }
    // Exactly one tallest tile, and at least one smaller tile. Two tiles at the top are a tie
    // even with one name: tiles cannot prove two entries are the same person.
    let atTallest = measured.filter { $0.height == tallest.height }
    guard atTallest.count == 1, measured.count > 1 else { return nil }
    return tallest.name
  }
}
