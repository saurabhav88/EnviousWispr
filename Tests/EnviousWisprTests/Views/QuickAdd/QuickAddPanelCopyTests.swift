import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2381 — the panel's copy, and the promise each refusal line makes.
///
/// When this fails the user is told the wrong thing about why their selection could not be read, and
/// goes looking in the wrong place. The one refusal they can ACT on is the Accessibility permission;
/// every other line has to be honest enough that they stop rather than retry forever.
///
/// A frozen copy table rather than strings inline in the view, so this asserts without rendering.
@Suite("Quick Add panel copy — #2381", .tags(.driftGuard))
struct QuickAddPanelCopyTests {

  @Test("The row subtitle says what accepting does, then how much that word already carries")
  func rowSubtitleShape() {
    #expect(
      QuickAddPanelCopy.rowSubtitle(spellingCount: 4)
        == "add as a new spelling · 4 spellings already saved")
  }

  @Test("One spelling is singular")
  func rowSubtitleIsSingularForOne() {
    // "1 spellings already saved" is the kind of thing users screenshot.
    #expect(QuickAddPanelCopy.rowSubtitle(spellingCount: 1).contains("1 spelling already saved"))
    #expect(!QuickAddPanelCopy.rowSubtitle(spellingCount: 1).contains("spellings"))
  }

  @Test("A word with no spellings yet reads as plural, which is correct for zero")
  func rowSubtitleIsPluralForZero() {
    #expect(QuickAddPanelCopy.rowSubtitle(spellingCount: 0).contains("0 spellings already saved"))
  }

  @Test("Every refusal has its own sentence")
  func everyRefusalHasItsOwnSentence() {
    // A single "could not read your selection" would be technically true for all of them and useless
    // for the only one the user can do anything about.
    let messages = SelectionReader.Refusal.allCases.map(QuickAddPanelCopy.refusalMessage)

    #expect(Set(messages).count == messages.count, "two refusals share a sentence")
    #expect(messages.allSatisfy { !$0.isEmpty })
  }

  @Test("The Accessibility refusal names the fix, because it is the only one the user can act on")
  func theAccessibilityRefusalNamesTheFix() {
    let message = QuickAddPanelCopy.refusalMessage(.accessibilityNotTrusted)

    #expect(message.contains("System Settings"))
    #expect(message.contains("Accessibility"))
  }

  @Test("The terminal refusal says WHY rather than blaming the user's aim")
  func theTerminalRefusalExplains() {
    // Measured: a terminal advertises the attribute and then answers with nothing, so "select the
    // word again" would send the user round a loop that cannot end.
    let message = QuickAddPanelCopy.refusalMessage(.selectionUnavailable)

    #expect(message.lowercased().contains("terminal"))
    #expect(!message.lowercased().contains("try again"))
  }

  @Test("The too-long refusal DOES tell the user to try again, because retrying works there")
  func theTooLongRefusalAsksForARetry() {
    // The paired case for the one above: the difference between the two is whether a retry can
    // succeed, and the copy has to reflect that rather than being uniformly apologetic.
    let message = QuickAddPanelCopy.refusalMessage(.selectionTooLong)

    #expect(message.lowercased().contains("try again"))
  }

  @Test("No panel copy contains an em-dash or en-dash")
  func noDashesInUserFacingCopy() {
    // GR-NO-DASHES. The row subtitle's separator is a MIDDLE DOT, which is not one of these.
    let all =
      SelectionReader.Refusal.allCases.map(QuickAddPanelCopy.refusalMessage)
      + [
        QuickAddPanelCopy.heardLabel, QuickAddPanelCopy.searchPlaceholder,
        QuickAddPanelCopy.createNewWord, QuickAddPanelCopy.returnHint,
        QuickAddPanelCopy.rowSubtitle(spellingCount: 3),
      ]

    for text in all {
      #expect(!text.contains("\u{2014}"), "em-dash in: \(text)")
      #expect(!text.contains("\u{2013}"), "en-dash in: \(text)")
    }
  }
}
