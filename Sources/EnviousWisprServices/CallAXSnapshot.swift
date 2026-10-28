import EnviousWisprCore
import Foundation

/// An immutable copy of part of a call app's Accessibility tree (#4013). Speaker readers work
/// only on these copies, so they never message another app and tests feed them literal trees.
/// Taking the copy (bounded, off the main actor) belongs to the live observer.
package struct CallAXNode: Sendable, Equatable {
  package let role: String
  package let title: String?
  package let description: String?
  package let value: String?
  package let identifier: String?
  package let domClassList: [String]
  package let width: Double?
  package let height: Double?
  package let children: [CallAXNode]

  package init(
    role: String, title: String? = nil, description: String? = nil, value: String? = nil,
    identifier: String? = nil, domClassList: [String] = [], width: Double? = nil,
    height: Double? = nil, children: [CallAXNode] = []
  ) {
    self.role = role
    self.title = title
    self.description = description
    self.value = value
    self.identifier = identifier
    self.domClassList = domClassList
    self.width = width
    self.height = height
    self.children = children
  }

  /// The element's visible label: the first non-empty of title, description and value. Call apps
  /// put the same label in more than one of these (Teams sets title and description alike).
  package var label: String? {
    [title, description, value].lazy.compactMap { $0 }.first { !$0.isEmpty }
  }

  /// This node and every descendant, depth first.
  package var allNodes: [CallAXNode] {
    [self] + children.flatMap(\.allNodes)
  }
}

/// One window of a call app, with the window's title kept apart from its tree.
package struct CallAXWindow: Sendable, Equatable {
  package let title: String?
  package let root: CallAXNode

  package init(title: String?, root: CallAXNode) {
    self.title = title
    self.root = root
  }
}

/// One web page in a browser window: its address and its tree. Browser readers keep pages apart,
/// so names from an unrelated tab never join a call's roster (#4013 chunk 3).
package struct CallAXDocument: Sendable, Equatable {
  package let url: String?
  package let root: CallAXNode

  package init(url: String?, root: CallAXNode) {
    self.url = url
    self.root = root
  }
}

/// What a speaker reader found in one snapshot: who the app showed as talking, and the
/// participants it could see (#4013 §3 item 2).
///
/// `speaking` lists every name shown as talking at once, so the namer can abstain when it is
/// more than one. `rosterFromParticipantList` says whether the roster came from the app's
/// participant list, which shows every person once, or only from tiles, where two people with
/// one display name cannot be told from one person shown twice.
package struct CallSpeakerReading: Sendable, Equatable {
  package let speaking: [String]
  package let roster: CallSpeakerRoster
  package let rosterFromParticipantList: Bool

  package init(speaking: [String], roster: CallSpeakerRoster, rosterFromParticipantList: Bool) {
    self.speaking = speaking
    self.roster = roster
    self.rosterFromParticipantList = rosterFromParticipantList
  }
}

/// Order-keeping de-duplication for names seen in more than one representation.
func uniqueInOrder(_ names: [String]) -> [String] {
  var seen = Set<String>()
  return names.filter { seen.insert($0).inserted }
}
