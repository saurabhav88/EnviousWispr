import Foundation
import SwiftParser
import Testing

@testable import EnviousWisprAppKit

/// #3385: the Clipboard tab's words. Each switch gains one short line; Auto-copy gains a help
/// sentence; the Restore, Smart insertion and Quick Add explanations move behind "?" with the
/// English the page showed before. Expected strings are typed from the approved copy table and
/// the pre-#3385 source, not read from the code under test.
@Suite("Clipboard settings copy (#3385)", .tags(.productOutcome))
struct ClipboardSettingsCopyTests {
  typealias Copy = DictationSettingsCopy.Clipboard

  static let expected: [String: (LocalizedStringResource, String)] = [
    "autoCopyTitle": (Copy.autoCopyTitle, "Auto-copy to clipboard"),
    "autoCopyShort": (Copy.autoCopyShort, "Copies dictation when automatic pasting is skipped."),
    "autoCopyHelp": (
      Copy.autoCopyHelp,
      "Copies your dictation to the clipboard when automatic pasting is skipped. After an automatic paste, Restore clipboard after paste controls whether your earlier clipboard contents return."
    ),
    "restoreTitle": (Copy.restoreTitle, "Restore clipboard after paste"),
    "restoreShort": (Copy.restoreShort, "Puts back what was on your clipboard before pasting."),
    "restoreHelp": (
      Copy.restoreHelp,
      "Saves and restores whatever was on your clipboard before pasting your dictation."
    ),
    "smartInsertionTitle": (Copy.smartInsertionTitle, "Smart insertion"),
    "smartInsertionShort": (
      Copy.smartInsertionShort, "Fits text to the spacing and capitals around your cursor."
    ),
    "smartInsertionHelp": (
      Copy.smartInsertionHelp,
      "Matches spacing and capitalisation to the text around your cursor when you dictate into the middle of a sentence."
    ),
    "quickAddTitle": (Copy.quickAddTitle, "Read selections through the clipboard"),
    "quickAddShort": (Copy.quickAddShort, "Reads hidden selections and restores your clipboard."),
    "quickAddHelp": (
      Copy.quickAddHelp,
      "Some apps will not tell other apps what you have highlighted. In those, adding a word from your selection briefly copies it and then puts your clipboard back."
    ),
    "clipboardHeading": (Copy.clipboardHeading, "Clipboard"),
    "quickAddHeading": (Copy.quickAddHeading, "Quick Add"),
  ]

  @Test("every Clipboard string keeps its approved English")
  func approvedEnglish() {
    for (name, (resource, english)) in Self.expected {
      #expect(String(localized: resource) == english, "\(name)")
    }
  }

  @Test("each switch's short line fits under its title")
  func shortLinesFit() {
    for short in [
      Copy.autoCopyShort, Copy.restoreShort, Copy.smartInsertionShort, Copy.quickAddShort,
    ] {
      let line = String(localized: short)
      #expect(!line.isEmpty && line.count <= 60, "\(line) is \(line.count) characters")
    }
  }

  @Test("the three explanations the page showed before move behind \"?\" unchanged")
  func retainedExplanations() {
    // Typed from the pre-#3385 page (f485f2e8), British "capitalisation" included.
    #expect(
      String(localized: Copy.restoreHelp)
        == "Saves and restores whatever was on your clipboard before pasting your dictation.")
    #expect(
      String(localized: Copy.smartInsertionHelp)
        == "Matches spacing and capitalisation to the text around your cursor when you dictate into the middle of a sentence."
    )
    #expect(
      String(localized: Copy.quickAddHelp)
        == "Some apps will not tell other apps what you have highlighted. In those, adding a word from your selection briefly copies it and then puts your clipboard back."
    )
  }

  @Test("the test lists every Clipboard string, and the page shows every one")
  func everyStringIsCoveredAndUsed() throws {
    let copySource = try String(
      contentsOf: RepoRoot.url.appending(
        path: "Sources/EnviousWisprAppKit/Views/Settings/DictationSettingsCopy.swift"),
      encoding: .utf8)
    let declared = PillSettingsCopyTests.staticLets(inEnum: "Clipboard", source: copySource)
    #expect(declared.count >= 14, "parsed \(declared.count); the enum has moved")
    #expect(declared == Set(Self.expected.keys), "declared \(declared.sorted())")

    let page = Parser.parse(
      source: try String(
        contentsOf: RepoRoot.url.appending(path: ClipboardSettingsWiringTests.path), encoding: .utf8
      ))
    // #3482: the row titles and headings reach the page through the Settings Map.
    let map = Parser.parse(
      source: try String(
        contentsOf: RepoRoot.url.appending(
          path: "Sources/EnviousWisprAppKit/Views/Settings/SettingsMap.swift"),
        encoding: .utf8))
    let used = RecordingChimeCopyTests.members(
      of: ["Copy", "DictationSettingsCopy.Clipboard"], in: page)
      .union(RecordingChimeCopyTests.members(of: ["DictationSettingsCopy.Clipboard"], in: map))
    #expect(used.count > 0, "no Clipboard copy read from the page; the reader has stopped matching")
    let unused = declared.subtracting(used).sorted()
    #expect(unused.isEmpty, "declared but not shown on the page: \(unused)")
  }
}
