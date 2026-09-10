import Foundation
import Testing

@testable import EnviousWispr

/// #2772 finding 9 — "buttons need to look like this everywhere".
///
/// The founder said that about the Transcribe a File wizard's Back / Continue pair, and the
/// note scopes it: "Applies to EVERY step and to Choose a file / Choose a different file."
/// The shipped wizard used the settings-wide capsule with a purple border, which is the pill
/// he rejected by name.
///
/// **What this check is, and what it is NOT.** It COUNTS direct `SettingsActionButton`
/// constructions in `TranscribeFileView.swift`. It does not verify WHERE they occur, so two
/// constructions somewhere else would pass it; it says nothing about the plain `Button`
/// controls the file also uses on purpose (the drop zone, the X, the six polish cards); and
/// it renders no pixel, so it cannot see whether anything LOOKS right. Styling is verified
/// by screenshot and accessibility by driving the running app, which are the only
/// instruments that can. Narrowed by Codex, whose point was that "every button" was a claim
/// this count cannot make.
///
/// **It is worth having anyway, for the reason the ownership tripwire in
/// `ProviderSetupOwnershipTests` is.** The cheap thing to do when adding a seventh button to
/// this wizard is to reach for the same type every other settings page uses, and that button
/// would be a purple pill among rounded rectangles. Two buttons of different shapes pass
/// every behavioural test in the suite, because both work.
///
/// Two-way controlled: verified failing on 2026-09-10 by restoring one direct construction
/// in the Done step's action row, which it named in its failure message.
@Suite("Transcribe a File button treatment (#2772)", .tags(.driftGuard))
struct TranscribeFileButtonTreatmentTests {
  /// Derived from this file rather than the working directory: a relative path would scan
  /// whichever checkout happens to be current, and this repo routinely has four open.
  static var viewSource: String? {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Views
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("Sources/EnviousWisprAppKit/Views/Settings/TranscribeFileView.swift")
    return try? String(contentsOf: url, encoding: .utf8)
  }

  @Test("the scanner can see its subject")
  func theScannerCanSeeItsSubject() {
    let source = Self.viewSource
    #expect(source != nil, "TranscribeFileView.swift is unreadable, so the result below is vacuous")
    #expect(
      source?.contains("private func wizardPrimary") == true,
      "the helper this checks for is gone, so the check no longer means anything")
  }

  /// The two helpers each construct one, and the wizard's own body constructs none.
  @Test("the wizard contains three direct SettingsActionButton constructions")
  func theWizardHasThreeDirectConstructions() {
    guard let source = Self.viewSource else { return }

    // Lines that CONSTRUCT one. A type annotation (`SettingsActionButton.Size`) is not a
    // construction and must not count, or the check fires on its own helper signature.
    let constructions =
      source
      .split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
      .filter { _, line in
        line.contains("SettingsActionButton(") && !line.contains("SettingsActionButton.")
      }
      .map { index, line in "line \(index + 1): \(line.trimmingCharacters(in: .whitespaces))" }

    // THREE since #2772 chunk 7: one inside each of the two helpers, plus the Share button's
    // label. `ShareLink` supplies its own control, so its label is the treatment WITHOUT an
    // action — which is exactly what `SettingsActionButton` grew the ability to be in chunk
    // 4, and why the platform control could replace a hand-rolled picker.
    #expect(
      constructions.count == 3,
      """
      exactly three constructions are expected: wizardSecondary, wizardPrimary, and the \
      ShareLink label. Found \(constructions.count):
      \(constructions.joined(separator: "\n"))
      """)
  }

  /// The secondary must not be the purple-bordered pill. `outlined` is that pill and it
  /// stays available for the rest of Settings, so this pins which one the wizard asks for.
  @Test("the wizard's secondary is the quiet treatment, never the purple pill")
  func theSecondaryIsQuiet() {
    guard let source = Self.viewSource else { return }
    guard let helper = source.range(of: "private func wizardSecondary") else {
      Issue.record("wizardSecondary is gone")
      return
    }
    let body = source[helper.lowerBound...].prefix(600)
    #expect(body.contains("emphasis: .quiet"), "the wizard's secondary is not the quiet one")
    #expect(body.contains("shape: .roundedRect"), "the wizard's secondary is still a capsule")
  }
}
