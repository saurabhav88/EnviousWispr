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
  /// A web element's DOM id (`AXDOMIdentifier`), copied for buttons only: the Teams app's
  /// microphone button is found by it (#4248).
  package let domIdentifier: String?
  package let domClassList: [String]
  package let width: Double?
  package let height: Double?
  package let children: [CallAXNode]

  package init(
    role: String, title: String? = nil, description: String? = nil, value: String? = nil,
    identifier: String? = nil, domIdentifier: String? = nil, domClassList: [String] = [],
    width: Double? = nil, height: Double? = nil, children: [CallAXNode] = []
  ) {
    self.role = role
    self.title = title
    self.description = description
    self.value = value
    self.identifier = identifier
    self.domIdentifier = domIdentifier
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
/// participants it could see (#4013 §3 item 2, r5 item 1).
///
/// `participants` keeps distinct people apart before any name is de-duplicated, so two people
/// sharing a display name stay two entries; `participantIdentityEstablished` says whether the
/// reader could tell distinct people from repeated views of one person on this surface.
/// `sharedNames` are display names other evidence (a participant list) shows for two people.
/// `CallSpeakerAdmission` decides from these whether the reading may become a naming
/// observation. `speaking`, `roster` and `rosterFromParticipantList` stay for existing consumers;
/// the last is provenance (the roster came from the app's participant list), not admission.
package struct CallSpeakerReading: Sendable, Equatable {
  package let speaking: [String]
  package let roster: CallSpeakerRoster
  package let rosterFromParticipantList: Bool
  package let participants: [CallParticipant]
  package let participantIdentityEstablished: Bool
  package let sharedNames: Set<String>
  /// The roster is the app's whole participant list, checked against the count the app shows
  /// (#4013 13B). Only this can show that someone left; visible tiles or a list the app may
  /// draw only partly never can.
  package let participantListComplete: Bool
  /// How many people the call app itself said are on the call (#4013 chunk 14), when every
  /// count it showed agreed; `nil` when it showed none, the counts disagreed, or a list it
  /// showed did not match its own count. Never a count of what was read.
  package let participantCount: Int?
  /// The call app's signed-in account display name (Zoom's menu bar, `CallAccountMenu`), at most
  /// one; empty when not read. Not a meeting marking (#4013 plan r4): only the 1-on-1 rule may
  /// use it, and only when no app marking says who the user is.
  package let accountSelfNames: [String]

  package init(
    speaking: [String], roster: CallSpeakerRoster, rosterFromParticipantList: Bool,
    participants: [CallParticipant], participantIdentityEstablished: Bool,
    sharedNames: Set<String>, participantListComplete: Bool = false, participantCount: Int? = nil,
    accountSelfNames: [String] = []
  ) {
    self.accountSelfNames = accountSelfNames
    self.participantListComplete = participantListComplete
    self.participantCount = participantCount
    self.speaking = speaking
    self.roster = roster
    self.rosterFromParticipantList = rosterFromParticipantList
    self.participants = participants
    self.participantIdentityEstablished = participantIdentityEstablished
    self.sharedNames = sharedNames
  }
}

/// Display names that occur more than once in `names`.
func repeatedNames(_ names: [String]) -> Set<String> {
  var seen = Set<String>()
  var repeated = Set<String>()
  for name in names where !seen.insert(name).inserted { repeated.insert(name) }
  return repeated
}

/// Order-keeping de-duplication for names seen in more than one representation.
func uniqueInOrder(_ names: [String]) -> [String] {
  var seen = Set<String>()
  return names.filter { seen.insert($0).inserted }
}
