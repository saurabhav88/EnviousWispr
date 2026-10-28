import EnviousWisprCore
import Foundation

/// Reads the Zoom web client (#4013 r5 item 4). Observed 2026-10-28 in Chrome on the Mac (C1 Zoom
/// web run, `docs/audits/2026-10-27-4013/c1w-receipt.txt`): in Speaker view each participant has
/// one thumbnail frame with class `speaker-bar-container__video-frame`, the talker's frame also
/// carries `speaker-bar-container__video-frame--active` (the signal Superwhisper reads), and the
/// large `speaker-active-container__video-frame` repeats the talker. Each frame's name is the text
/// under `video-avatar__avatar-footer` (the host's tile had no `video-avatar__avatar-name`). Only
/// thumbnails are people; without thumbnail frames (another layout) no one is named and the names
/// on screen are kept for the rename list.
package enum ZoomWebSpeakerReader {
  static let thumbnailFrameClass = "speaker-bar-container__video-frame"
  static let activeThumbnailClass = "speaker-bar-container__video-frame--active"
  static let footerClass = "video-avatar__avatar-footer"
  static let nameClass = "video-avatar__avatar-name"

  /// `nil` when the pages hold no single Zoom call page: none, or more than one (two call tabs
  /// cannot be told apart, so neither is read).
  package static func read(documents: [CallAXDocument]) -> CallSpeakerReading? {
    let calls = documents.filter { document in
      document.url.flatMap(CallMeetingURL.classify)?.family == .zoom
    }
    guard calls.count == 1, let page = calls.first else { return nil }

    let frames = page.root.allNodes.filter { $0.domClassList.contains(thumbnailFrameClass) }
    var participants: [CallParticipant] = []
    for (index, frame) in frames.enumerated() {
      participants.append(
        CallParticipant(
          key: "thumbnail-\(index)", name: name(in: ownSubtree(of: frame)),
          isTalking: frame.domClassList.contains(activeThumbnailClass), isSelf: false))
    }
    let names = participants.compactMap(\.name)
    let identity = !frames.isEmpty
    // Without thumbnails the names on screen still serve the rename list.
    let visible = page.root.allNodes
      .filter { $0.domClassList.contains(footerClass) || $0.domClassList.contains(nameClass) }
      .compactMap { name(in: $0.allNodes) }
    return CallSpeakerReading(
      speaking: identity ? uniqueInOrder(participants.filter(\.isTalking).compactMap(\.name)) : [],
      roster: CallSpeakerRoster(names: identity ? names : uniqueInOrder(visible), selfNames: []),
      rosterFromParticipantList: false, participants: participants,
      participantIdentityEstablished: identity, sharedNames: repeatedNames(names))
  }

  /// The first text under the footer, else under the name block, within the given nodes.
  static func name(in nodes: [CallAXNode]) -> String? {
    for wanted in [footerClass, nameClass] {
      for node in nodes where node.domClassList.contains(wanted) {
        if let text = node.allNodes.first(where: { $0.role == "AXStaticText" })?.label,
          !text.isEmpty
        {
          return text
        }
      }
    }
    return nil
  }

  /// The frame and its descendants, stopping at any nested thumbnail frame.
  static func ownSubtree(of frame: CallAXNode) -> [CallAXNode] {
    var nodes = [frame]
    var queue = frame.children
    while !queue.isEmpty {
      let node = queue.removeFirst()
      if node.domClassList.contains(thumbnailFrameClass) { continue }
      nodes.append(node)
      queue.append(contentsOf: node.children)
    }
    return nodes
  }
}
