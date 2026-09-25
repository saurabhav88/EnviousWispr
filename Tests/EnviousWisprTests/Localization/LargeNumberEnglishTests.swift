import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing

/// #3142 G6: English stays byte-identical. An `Int` interpolated into `String(localized:)` is
/// formatted for the locale ("25,000"), where the old spliced string printed "25000", so
/// translated sentences pass counts and limits as text. Each oracle is the old English, typed
/// out, at a value of 1,000 or more.
@Suite("Large numbers keep their English digits", .tags(.productOutcome))
struct LargeNumberEnglishTests {

  @Test("import limit errors print the limit without a separator")
  func importLimits() {
    #expect(
      SnippetImportValidationError.tooManySnippets(limit: 5_000).errorDescription
        == "That has more than 5000 snippets, which is more than EnviousWispr can import at once. Nothing was imported."
    )
    #expect(
      SnippetImportValidationError.tooMuchText(limit: 4_000_000).errorDescription
        == "That has more than 4000000 characters of snippet text in total, which is more than EnviousWispr can import at once. Nothing was imported."
    )
    #expect(
      SnippetImportValidationError.triggerTooLong(limit: 1_500).errorDescription
        == "That contains a trigger longer than 1500 characters, which is too long to say. Nothing was imported."
    )
    #expect(
      SnippetImportValidationError.expansionTooLong(trigger: "hi", limit: 20_000).errorDescription
        == "The text for \(CustomWordsImportValidationError.describe("hi")) is longer than 20000 characters. Nothing was imported."
    )
    #expect(
      ImportFileError.tooManyWords(found: 25_001, limit: 25_000).errorDescription
        == "That file has more than 25000 words, which is more than EnviousWispr can import at once. Try splitting it into smaller files."
    )
    #expect(
      ImportFileError.tooManyStoredValues(found: 100_001, limit: 100_000).errorDescription
        == "That file has more than 100000 words and alternate spellings combined, which is more than EnviousWispr can import at once."
    )
    #expect(
      PasteWordsImportError.tooManyWords(found: 25_001, limit: 25_000).errorDescription
        == "That's more than 25000 words, which is more than EnviousWispr can import at once. Try pasting a smaller batch."
    )
    #expect(
      SmartImportError.tooManySourceEntries(appName: "Wispr Flow", limit: 25_000).errorDescription
        == "Wispr Flow has more than 25000 dictionary entries, including entries it may hide or disable. EnviousWispr stopped without importing anything."
    )
    #expect(
      CustomWordsImportValidationError.wordTooLong(limit: 1_000).errorDescription
        == "That contains an entry longer than 1000 characters, which is too long to be a word. Nothing was imported."
    )
    // The format version comes from the file itself, so it can be any number.
    #expect(
      SnippetsTransferError.unsupportedVersion(1_234).errorDescription
        == "That file was exported by a newer version of EnviousWispr (format 1234). Update the app, then try again."
    )
    #expect(
      CustomWordsTransferError.unsupportedVersion(1_234).errorDescription
        == "That file was exported by a newer version of EnviousWispr (format 1234). Update the app, then try again."
    )
    #expect(
      SnippetImportSourceError.malformedCSV(line: 1_234).errorDescription
        == "That CSV has a quoting problem on line 1234. Nothing was imported.")
  }

  @Test("the correction model download prints megabytes without a separator")
  func downloadMegabytes() {
    let mb: Int64 = 1_048_576
    #expect(
      LearnFromEditsSettingsPresentation.downloadingLine(
        fraction: 0.75, written: 1_500 * mb, total: 2_000 * mb)
        == "Downloading the correction model (1500 of 2000 MB)")
  }
}
