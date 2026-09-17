import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2997 — what Export writes, Import reads back as the same snippets.
///
/// `.productOutcome`: when this fails a user restoring on a new Mac gets different text
/// than they saved, or an import of their own export collides on identity.
@Suite("Snippets export round trip (#2997)", .tags(.productOutcome))
struct SnippetsExportRoundTripTests {

  @Test("An export decodes to candidates with the same triggers and text, and fresh review ids")
  @MainActor func exportDecodesToEqualCandidates() async throws {
    let snippets = [
      Snippet(trigger: "my email", expansion: "sam@example.com"),
      Snippet(trigger: "sign off", expansion: "Best,\nSam\n"),
      Snippet(trigger: "tabbed", expansion: "a\tb  c"),
      // A fill-in must survive the round trip as the TOKEN, not as the date it resolved to on
      // the machine that exported it (#3018). Upper case, because that is what a TypeWhisper
      // import writes and the matcher is case-insensitive.
      Snippet(trigger: "stamp", expansion: "Filed {{DATE}} at {{time}} from {{CLIPBOARD}}"),
    ]
    let vocabulary = SnippetVocabulary(snippets: snippets, keyword: "hey", generation: 4)
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-snippets-roundtrip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let destination = dir.appendingPathComponent(SnippetsExportAction.defaultFilename)
    // The export's own writer, then the import's own file reader: the real bytes both ways.
    try DurableJSONFile.write(
      SnippetsExportAction.document(for: vocabulary), to: destination,
      tempPrefix: ".ew-snippets-export")
    let batch = try await SnippetFileImportSource(url: destination).loadCandidates()
    let read = try SnippetsTransferDocument(data: Data(contentsOf: destination))
    let candidates = read.candidatesForImport()
    #expect(batch.candidates.map(\.trigger) == candidates.map(\.trigger))
    #expect(batch.candidates.map(\.expansion) == candidates.map(\.expansion))

    #expect(candidates.map(\.trigger) == snippets.map(\.trigger))
    #expect(candidates.map(\.expansion) == snippets.map(\.expansion))
    #expect(Set(candidates.map(\.id)).isDisjoint(with: snippets.map(\.id)))
    #expect(read.keyword == "hey", "decoded and then ignored by the import (plan §14 Q1)")
    let validated = try SnippetImportBatch(
      sourceID: "file_json", sourceDisplayName: "x", candidates: candidates
    ).validated()
    #expect(validated.candidates.count == snippets.count)
    // The fill-in snippet is the reason this suite grew a fourth row: it must arrive as its
    // TOKEN, so a restore on a new Mac still resolves the date on the day it is spoken rather
    // than freezing the day it was exported.
    #expect(
      validated.candidates.map(\.expansion).contains(
        "Filed {{DATE}} at {{time}} from {{CLIPBOARD}}"))
  }
}
