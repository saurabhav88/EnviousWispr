import Foundation
import Testing

@testable import EnviousWisprServices

/// #4036: a real huddle must count in each verified Slack language; an idle channel must not.
@Suite("Slack huddle windows in every language", .tags(.productOutcome))
struct SlackHuddleWindowTests {
  typealias Read = SlackHuddleWindow.Read

  func verdict(_ windows: [(Read, Read)]) -> SlackHuddleWindow.Verdict {
    SlackHuddleWindow.classify(
      windowCount: windows.count, identifier: { windows[$0].0 }, title: { windows[$0].1 })
  }

  @Test("Verified Slack huddles count; idle conversations and failed reads do not become calls",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/4036"),
    arguments: [
      ("English", "Leave Huddle", "huddle-test (Channel) - Qualtrics - Slack"),
      ("German", "Huddle verlassen", "huddle-test (Channel) - Qualtrics - Slack"),
      ("French", "Quitter l’appel d’équipe", "huddle-test (canal) - Qualtrics - Slack"),
    ])
  func verifiedHuddle(language: String, leaveLabel: String, idleTitle: String) {
    // Literal tokens read from the live en/de/fr controls. Their labels are diagnostic only:
    // production deliberately never reads a translated description to identify the button.
    let control = SlackHuddleWindow.classRead(
      NSArray(array: ["c-button-unstyled", "leaveButton__wzISw", "c-button--danger"]))
    let active = (control, Read.value("huddle-test - Qualtrics - Slack"))
    #expect(verdict([active]) == .call, "\(language): \(leaveLabel)")
    #expect(verdict([(.missing, .value(idleTitle))]) == .none)
    #expect(verdict([(.missing, .value("Saurabh Vaish (DM) - Qualtrics - Slack"))]) == .none)
    #expect(verdict([]) == .none)

    // The control must prove the call even if its title cannot be read, or another window failed.
    #expect(verdict([(control, .failed)]) == .call)
    #expect(verdict([(.failed, .failed), active]) == .call)
    var titleReads = 0
    #expect(SlackHuddleWindow.classify(
      windowCount: 1, identifier: { _ in control }, title: { _ in
        titleReads += 1
        return .failed
      }) == .call)
    #expect(titleReads == 0)
    #expect(verdict([(.failed, .value(idleTitle))]) == .unknown)
    #expect(verdict([(.missing, .failed)]) == .unknown)

    // Native AX arrays bridge; a stringified/malformed array and lookalike token cannot prove a call.
    #expect(SlackHuddleWindow.classRead(["leaveButton__wzISw-extra"]) == .missing)
    #expect(SlackHuddleWindow.classRead([String]()) == .missing)
    #expect(SlackHuddleWindow.classRead("leaveButton__wzISw") == .failed)
    #expect(SlackHuddleWindow.classRead(NSArray(array: ["leaveButton__wzISw", 1])) == .failed)
    #expect(verdict([(.value("leaveButton__other"), .value(idleTitle))]) == .none)

    // Compatibility fallback is case-sensitive and excludes ordinary conversation-title labels.
    #expect(verdict([(.missing, .value("Huddle"))]) == .call)
    #expect(verdict([(.missing, .value("Huddle - Team"))]) == .call)
    for title in ["Huddle-test (Channel) - Team - Slack", "Huddle (Channel) - Team - Slack",
      "Huddle Buddy (DM) - Team - Slack", "huddle-test - Team - Slack"] {
      #expect(verdict([(.missing, .value(title))]) == .none, "\(title)")
    }
  }
}
