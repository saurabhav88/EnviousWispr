import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPostProcessing

/// #1680 — the export action, including the ORDER of its steps.
///
/// These exist because the safety guard was once written as a property and
/// never wired into the button, and the tests could not tell: they exercised
/// the property directly, so they passed with it disconnected. Testing the
/// ingredients is not testing the dish.
@MainActor
@Suite("CustomWordsExportAction")
struct CustomWordsExportActionTests {

  /// `@MainActor`-isolated recorder rather than a captured var: the write
  /// closure is `@Sendable`, and hiding a race behind an unchecked conformance
  /// is the thing this codebase already learned not to do.
  @MainActor
  final class WriteSpy {
    /// Captures the BYTES now, which is what actually reaches disk — so
    /// assertions decode what would have been written rather than trusting an
    /// object that was never serialised.
    var written: Data?
    var writeCount = 0
  }

  private func tempURL() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-export-action-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("custom-words.json")
  }

  private func coordinator(seedWords: [CustomWord] = []) throws -> CustomWordsCoordinator {
    let url = tempURL()
    let manager = CustomWordsManager(fileURL: url)
    var live = manager.load() ?? []
    for word in seedWords { try manager.add(word: word, to: &live) }
    return CustomWordsCoordinator(manager: manager)
  }

  private func corruptedCoordinator() throws -> CustomWordsCoordinator {
    let url = tempURL()
    try Data("not valid json at all {{{".utf8).write(to: url)
    return CustomWordsCoordinator(manager: CustomWordsManager(fileURL: url))
  }

  @Test("cancelling touches nothing at all")
  func cancellingWritesNothingAndChangesNothing() async throws {
    let coordinator = try coordinator(seedWords: [CustomWord(canonical: "Kubernetes")])
    let before = coordinator.customWords
    let spy = WriteSpy()

    let outcome = await CustomWordsExportAction.run(
      coordinator: coordinator,
      chooseDestination: { nil },
      write: { _, _ in await MainActor.run { spy.writeCount += 1 } }
    )

    #expect(outcome == .cancelled)
    #expect(spy.writeCount == 0)
    // Refreshing before asking where would have mutated state on cancel.
    #expect(coordinator.customWords == before)
  }

  @Test("a corrupted library refuses to export instead of writing an empty file")
  func corruptedLibraryRefusesRatherThanWritingEmpty() async throws {
    // The guard being PRESENT is not enough — it has to be reached. This test
    // fails if the export path stops consulting it, which is the exact bug
    // that shipped and was caught in cloud review.
    let coordinator = try corruptedCoordinator()
    let spy = WriteSpy()

    let outcome = await CustomWordsExportAction.run(
      coordinator: coordinator,
      chooseDestination: { self.tempURL() },
      write: { data, _ in await MainActor.run { spy.written = data } }
    )

    #expect(outcome == .refusedUnsafeLibrary)
    #expect(spy.written == nil, "an empty export must never reach the writer")
  }

  @Test("a healthy library exports exactly the user's own words")
  func healthyLibraryExportsUserWordsOnly() async throws {
    let coordinator = try coordinator(seedWords: [
      CustomWord(canonical: "Kubernetes"), CustomWord(canonical: "Qualtrics"),
    ])
    let spy = WriteSpy()

    let outcome = await CustomWordsExportAction.run(
      coordinator: coordinator,
      chooseDestination: { self.tempURL() },
      write: { data, _ in await MainActor.run { spy.written = data } }
    )

    #expect(outcome == .exported)
    let document = try CustomWordsTransferDocument(data: try #require(spy.written))
    #expect(document.words.map(\.canonical).sorted() == ["Kubernetes", "Qualtrics"])
    // Built-ins are excluded: this is "your words", not "everything".
    #expect(!document.words.contains { $0.canonical == "GitHub" })
  }

  @Test("a write failure is reported rather than reading as success")
  func writeFailureIsReported() async throws {
    struct Boom: Error {}
    let coordinator = try coordinator(seedWords: [CustomWord(canonical: "Kubernetes")])

    let outcome = await CustomWordsExportAction.run(
      coordinator: coordinator,
      chooseDestination: { self.tempURL() },
      write: { _, _ in throw Boom() }
    )

    guard case .failed = outcome else {
      Issue.record("expected a failure outcome, got \(outcome)")
      return
    }
  }

  @Test("corruption discovered by an EDIT still blocks a later export")
  func corruptionFoundByAMutationBlocksExport() async throws {
    // A fourth door into the same data loss (cloud review): when a mutation is
    // what first hits the damaged file, the manager archives it and throws
    // WITHOUT touching the launch flag. The next read then sees a legitimately
    // missing file and looks perfectly healthy — so export would write an
    // empty file over the user's real one while their words sat in the
    // archive. Corruption has several discoverers, not one.
    let url = tempURL()
    let manager = CustomWordsManager(fileURL: url)
    var live = manager.load() ?? []
    try manager.add(word: CustomWord(canonical: "Kubernetes"), to: &live)

    // The app is running with a healthy library — launch flag clean.
    let coordinator = CustomWordsCoordinator(manager: manager)
    #expect(coordinator.wordsLoadFailureAtLaunch == nil)
    #expect(coordinator.customWords.contains { $0.canonical == "Kubernetes" })

    // The file goes bad underneath it, and an EDIT is what finds out.
    try Data("not valid json at all {{{".utf8).write(to: url)
    #expect(coordinator.add(CustomWord(canonical: "Qualtrics")) != nil, "the edit must fail")

    let spy = WriteSpy()
    let outcome = await CustomWordsExportAction.run(
      coordinator: coordinator,
      chooseDestination: { self.tempURL() },
      write: { data, _ in await MainActor.run { spy.written = data } }
    )

    #expect(outcome == .refusedUnsafeLibrary)
    #expect(spy.written == nil, "an empty export must never reach the writer")
  }

  @Test("export refuses to write a file the importer would reject")
  func exportRefusesUnimportableFile() throws {
    // The exporter and importer are one round trip. Raising the IMPORT
    // ceilings while export kept no preflight left the same "writes a file it
    // then refuses" hole open from the other direction.
    let over = (0...CustomWordsImportLimits.maximumExportedCandidates).map {
      CustomWord(canonical: "Term\($0)", aliases: [], category: .general)
    }
    let document = CustomWordsTransferDocument(words: over)

    let refusal = CustomWordsExportAction.refusalIfUnimportable(
      document: document, encoded: try document.encoded())

    #expect(refusal != nil)
    #expect(refusal?.contains("Nothing was exported") == true)
  }

  @Test("an export at the limit is allowed through")
  func exportAtLimitAllowed() throws {
    let atLimit = (0..<CustomWordsImportLimits.maximumExportedCandidates).map {
      CustomWord(canonical: "T\($0)", aliases: [], category: .general)
    }
    let document = CustomWordsTransferDocument(words: atLimit)

    #expect(
      CustomWordsExportAction.refusalIfUnimportable(
        document: document, encoded: try document.encoded()) == nil)
  }


  @Test("a word the importer would refuse blocks the export")
  func unstorableWordBlocksExport() throws {
    // Size was not the only way to write an unimportable file. A word authored
    // in the editor can hold a scalar the import policy refuses, so a
    // count-and-bytes preflight still produced a file that import rejected
    // wholesale. The preflight runs the importer's OWN validation now, so the
    // two cannot describe "storable" differently.
    let document = CustomWordsTransferDocument(words: [
      CustomWord(canonical: "Kub\u{202E}ernetes", aliases: [], category: .general)
    ])

    let refusal = CustomWordsExportAction.refusalIfUnimportable(
      document: document, encoded: try document.encoded())

    #expect(refusal?.contains("Nothing was exported") == true)
  }

  @Test("a normal library is not blocked by the storability check")
  func normalLibraryPassesStorabilityCheck() throws {
    // The check must not become a wall: real words, including non-Latin ones
    // and joiners, export fine.
    let document = CustomWordsTransferDocument(words: [
      CustomWord(canonical: "Kubernetes", aliases: ["k8s"], category: .brand),
      CustomWord(canonical: "東京", aliases: [], category: .general),
      CustomWord(canonical: "क्\u{200D}ष", aliases: [], category: .general),
    ])

    #expect(
      CustomWordsExportAction.refusalIfUnimportable(
        document: document, encoded: try document.encoded()) == nil)
  }


  @Test("export refuses a library that trips the stored-surface ceiling")
  func exportRefusesOnStoredSurface() throws {
    // The fifth instance of one defect: a ceiling added to import and not to
    // export. This library has an acceptable WORD count and byte size, and
    // trips only the surface ceiling — which the previous preflight, holding
    // its own list of checks, did not know about.
    let perWord = 5_000
    let count = (CustomWordsImportLimits.maximumExportedStoredValues / perWord) + 2
    let words = (0..<count).map { index in
      CustomWord(
        canonical: "Term\(index)",
        aliases: (0..<perWord).map { "a\(index)_\($0)" },
        category: .general)
    }
    let document = CustomWordsTransferDocument(words: words)
    #expect(document.words.count < CustomWordsImportLimits.maximumExportedCandidates)

    let refusal = CustomWordsExportAction.refusalIfUnimportable(
      document: document, encoded: try document.encoded())

    #expect(refusal?.contains("Nothing was exported") == true)
    // Reported as words AND alternate spellings, not as a word count the user
    // cannot see anywhere.
    #expect(refusal?.contains("alternate spellings") == true)
  }

  @Test("whatever the importer refuses, export refuses — by construction")
  func exportRefusalTracksTheImporter() throws {
    // The property that matters is not that today's ceilings are checked, but
    // that a ceiling added to the parser LATER is enforced here with no change
    // to this file. Proven by driving the real parser: anything it rejects,
    // the preflight rejects, because the preflight IS the parser.
    let unstorable = CustomWordsTransferDocument(words: [
      CustomWord(canonical: "Kub\u{202E}ernetes", aliases: [], category: .general)
    ])
    let overWordCeiling = CustomWordsTransferDocument(
      words: (0...CustomWordsImportLimits.maximumExportedCandidates).map {
        CustomWord(canonical: "T\($0)", aliases: [], category: .general)
      })

    for document in [unstorable, overWordCeiling] {
      let encoded = try document.encoded()
      let importerRefuses: Bool
      do {
        let candidates = try ExportedWordsFileParser().parse(data: encoded)
        _ = try CustomWordsImportBatch(
          sourceID: "exported-words", sourceDisplayName: "x", candidates: candidates
        ).validated()
        importerRefuses = false
      } catch {
        importerRefuses = true
      }
      let exportRefuses = CustomWordsExportAction.refusalIfUnimportable(
        document: document, encoded: encoded) != nil

      #expect(importerRefuses == exportRefuses)
    }
  }


  @Test("the app cannot author a word it would then refuse to export")
  func authoringCannotCreateAnUnexportableLibrary() throws {
    // "What may be stored" is ONE rule, and the library is what it protects.
    // Applying part of it here — length but not the character policy — let the
    // editor author a word export then refused. Both halves now come from the
    // same predicate every authoring path shares.
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-author-\(UUID().uuidString).json")
    let manager = CustomWordsManager(fileURL: url)
    var live = manager.load() ?? []

    let tooLong = String(
      repeating: "x", count: CustomWordsImportLimits.maximumStoredValueScalars + 1)
    let deceptive = "Kub\u{202E}ernetes"
    let invisible = "\u{200D}"

    for bad in [tooLong, deceptive, invisible] {
      try manager.add(word: CustomWord(canonical: bad), to: &live)
      #expect(!live.contains { $0.canonical == bad }, "authored an unstorable word: \(bad.debugDescription)")
    }
    try manager.add(
      word: CustomWord(canonical: "Kubernetes", aliases: [deceptive, tooLong, "k8s"]),
      to: &live)

    #expect(live.contains { $0.canonical == "Kubernetes" && $0.aliases == ["k8s"] })

    // Whatever the library holds after all that, export accepts it.
    let document = CustomWordsTransferDocument(words: live.filter { $0.source == .user })
    #expect(
      CustomWordsExportAction.refusalIfUnimportable(
        document: document, encoded: try document.encoded()) == nil)
  }


}
