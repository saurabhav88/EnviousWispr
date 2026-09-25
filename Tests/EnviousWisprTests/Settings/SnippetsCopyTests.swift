import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPostProcessing

/// #3142: Snippets copy that used to splice "snippet"/"snippets", "entry"/"entries" or
/// "it"/"them" into a sentence now chooses whole sentences by count. Each oracle below rebuilds
/// the OLD spliced English independently, so the whole sentences must match it byte for byte at
/// 0, 1 and 2. Unit tests run outside the app bundle, so they read English.
@Suite("Snippets copy", .tags(.productOutcome))
struct SnippetsCopyTests {

  /// 1_234 and 25_000 pin the digits: the numbers are passed as text, so English never gains a
  /// thousands separator the old spliced string did not have (#3142 G6).
  private static let counts = [0, 1, 2, 7, 1_234, 25_000]

  @Test("the import result matches the old frame")
  func importResult() {
    for n in Self.counts {
      #expect(
        SnippetImportResultCopy.message(for: .completed(added: n))
          == "Added \(n) \(n == 1 ? "snippet" : "snippets"). Say your keyword, then the trigger, and it's pasted."
      )
      #expect(
        SnippetImportResultCopy.message(for: .nothingCompatible(found: n))
          == "Found \(n) \(n == 1 ? "entry" : "entries"), but none could be imported. Nothing was changed."
      )
    }
  }

  @Test("the confirm button says nothing, one or many, whole")
  func confirmTitle() {
    #expect(SnippetImportResultCopy.confirmTitle(approvedCount: 0) == "Add nothing")
    for n in [1, 2, 7, 1_234] {
      #expect(
        SnippetImportResultCopy.confirmTitle(approvedCount: n)
          == (n == 1 ? "Add 1 snippet" : "Add \(n) snippets"))
    }
  }

  @Test("the paste count matches the old frame for every count pair")
  func pasteSummary() {
    for found in [1, 2, 5, 1_234] {
      for skipped in [0, 1, 2, 1_001] {
        var old = "\(found) \(found == 1 ? "snippet" : "snippets") found"
        if skipped > 0 { old += ", \(skipped) \(skipped == 1 ? "line" : "lines") skipped" }
        old += "."
        #expect(SnippetImportResultCopy.pasteSummary(found: found, skipped: skipped) == old)
      }
    }
  }

  @Test("the review summary matches the old joined list for every combination")
  func reviewSummary() {
    for new in [0, 1, 2, 1_200] {
      for existing in [0, 1, 3, 4_999] {
        for duplicates in [0, 1, 4, 1_000] {
          var parts: [String] = []
          if new > 0 { parts.append("\(new) new \(new == 1 ? "snippet" : "snippets")") }
          if existing > 0 { parts.append("\(existing) you already have") }
          if duplicates > 0 { parts.append("\(duplicates) listed twice") }
          let old = parts.isEmpty ? "Nothing to review." : parts.joined(separator: ", ") + "."
          #expect(
            SnippetImportResultCopy.reviewSummary(
              new: new, existing: existing, duplicates: duplicates) == old)
        }
      }
    }
  }

  @Test("the review notices match the old frame")
  func notices() {
    for n in Self.counts {
      #expect(
        SnippetImportResultCopy.noticeMessage(for: .incompatibleSourceEntriesExcluded(count: n))
          == "\(n) \(n == 1 ? "entry was" : "entries were") left out because EnviousWispr can't use \(n == 1 ? "it" : "them")."
      )
      #expect(
        SnippetImportResultCopy.noticeMessage(for: .linesSkipped(count: n))
          == "\(n) \(n == 1 ? "line" : "lines") skipped because \(n == 1 ? "it has" : "they have") no trigger and text."
      )
    }
  }

  @Test("the list count says one or many, whole")
  @MainActor
  func listCount() {
    for n in Self.counts {
      #expect(
        SnippetsView.countLabel(shown: n, total: n, searching: false)
          == (n == 1 ? "1 snippet" : "\(n) snippets"))
      #expect(SnippetsView.countLabel(shown: n, total: 9, searching: true) == "\(n) of 9")
    }
  }

  /// The save dialog's line counts snippets as a whole sentence per count, with the count
  /// ungrouped so English reads exactly as before (#3142).
  @Test("the export dialog's summary keeps its English", arguments: [0, 2, 1000])
  @MainActor
  func exportSummary(count: Int) {
    #expect(
      SnippetsExportAction.summary(count: count) == "Exporting \(count) snippets and your keyword.")
  }

  @Test("one snippet is singular")
  @MainActor
  func exportSummaryOne() {
    #expect(SnippetsExportAction.summary(count: 1) == "Exporting 1 snippet and your keyword.")
    #expect(
      SnippetsExportAction.summary(count: 1000) == "Exporting 1000 snippets and your keyword.")
  }

  /// The import picker names the export file by its English name, which is a file, not copy.
  @Test("the import picker keeps its English and the export file's name")
  @MainActor
  func importPicker() {
    #expect(SnippetImportFilePanel.titleText == "Choose a snippets file")
    #expect(SnippetImportFilePanel.promptText == "Import")
    #expect(
      SnippetImportFilePanel.messageText
        == "Choose the EnviousWispr Snippets.json you exported, a CSV, or a plain list.")
    #expect(SnippetsExportAction.defaultFilename == "EnviousWispr Snippets.json")
  }
}
