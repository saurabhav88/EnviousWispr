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
      proposedExportWords: CustomWordsExportAction.exportableWords(
        from: coordinator.customWords),
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
      proposedExportWords: CustomWordsExportAction.exportableWords(
        from: coordinator.customWords),
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
      proposedExportWords: CustomWordsExportAction.exportableWords(
        from: coordinator.customWords),
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
      proposedExportWords: CustomWordsExportAction.exportableWords(
        from: coordinator.customWords),
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
      proposedExportWords: CustomWordsExportAction.exportableWords(
        from: coordinator.customWords),
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
      let exportRefuses =
        CustomWordsExportAction.refusalIfUnimportable(
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

    // Refused LOUDLY, not silently. A silent return dismissed the edit sheet
    // on a nil error, so the user was shown a save that never happened
    // (cloud review, #1683).
    for bad in [tooLong, deceptive, invisible] {
      #expect(throws: CustomWordsPersistenceError.unusableValue) {
        try manager.add(word: CustomWord(canonical: bad), to: &live)
      }
      #expect(
        !live.contains { $0.canonical == bad },
        "authored an unstorable word: \(bad.debugDescription)")
    }

    // An unstorable ALIAS is the same lie one layer down: dropping it quietly
    // reports a save that lost part of what the user typed.
    #expect(throws: CustomWordsPersistenceError.unusableValue) {
      try manager.add(
        word: CustomWord(canonical: "Kubernetes", aliases: [deceptive, tooLong, "k8s"]),
        to: &live)
    }
    #expect(!live.contains { $0.canonical == "Kubernetes" })

    // Blank alias rows are not a refusal — the editor leaves them behind and
    // trimming them away loses nothing the user meant.
    try manager.add(
      word: CustomWord(canonical: "Kubernetes", aliases: ["k8s", "  ", ""]), to: &live)
    #expect(live.contains { $0.canonical == "Kubernetes" && $0.aliases == ["k8s"] })

    // Whatever the library holds after all that, export accepts it.
    let document = CustomWordsTransferDocument(words: live.filter { $0.source == .user })
    #expect(
      CustomWordsExportAction.refusalIfUnimportable(
        document: document, encoded: try document.encoded()) == nil)
  }


  // MARK: - #1697: the count on screen and the bytes on disk are one fact

  /// The oracle here is an INDEPENDENTLY enumerated set, not `exportableWords`.
  ///
  /// Comparing the displayed count against the file proves the two AGREE, which
  /// is not the same as proving either is right: a filter that drops a word
  /// drops it from both and the test still passes green. Six later phases treat
  /// this file as the user's backup, so the expected set has to come from
  /// somewhere the export code cannot influence (council finding 2).
  @Test("the exported file contains exactly the user's own words, judged independently")
  func exportedFileMatchesAnIndependentlyEnumeratedSet() async throws {
    let expected = ["Kubernetes", "Qualtrics", "Threadripper"]
    // The oracle is only independent if it names words the app does not already
    // ship. Seeding a built-in canonical collapses it onto the built-in, which
    // export correctly excludes — the first draft of this test used
    // "EnviousWispr" and failed for exactly that reason. Assert the fixture's
    // own premise so the next author cannot repeat it silently.
    for canonical in expected {
      #expect(
        !CustomWordsManager.builtinDefaults.contains { $0.word.canonical == canonical },
        "\(canonical) is a built-in; it can never appear in a user-word export")
    }
    let coordinator = try coordinator(seedWords: expected.map { CustomWord(canonical: $0) })
    let spy = WriteSpy()
    let proposed = CustomWordsExportAction.exportableWords(from: coordinator.customWords)

    let outcome = await CustomWordsExportAction.run(
      coordinator: coordinator,
      proposedExportWords: proposed,
      chooseDestination: { self.tempURL() },
      write: { data, _ in await MainActor.run { spy.written = data } }
    )

    #expect(outcome == .exported)
    #expect(proposed.count == expected.count, "the number the user is shown")
    let document = try CustomWordsTransferDocument(data: try #require(spy.written))
    #expect(document.words.map(\.canonical).sorted() == expected.sorted())
    // And the bytes round-trip back through the REAL import path, because a
    // file the importer cannot read is not a backup.
    let candidates = try ExportedWordsFileParser().parse(data: try #require(spy.written))
    #expect(candidates.count == expected.count)
  }

  @Test("a same-size edit while the folder is being chosen refuses the write")
  func sameCountRecordChangeRefusesTheWrite() async throws {
    // The drift a count comparison cannot see: one word swapped for another, so
    // the total never moves. This is why the check compares complete records.
    let coordinator = try coordinator(seedWords: [CustomWord(canonical: "Kubernetes")])
    let stale = [CustomWord(canonical: "SomethingElse")]
    let spy = WriteSpy()

    let outcome = await CustomWordsExportAction.run(
      coordinator: coordinator,
      proposedExportWords: stale,
      chooseDestination: { self.tempURL() },
      write: { data, _ in await MainActor.run { spy.written = data } }
    )

    #expect(outcome == .libraryChanged)
    #expect(spy.written == nil, "nothing may be written when the list moved")
  }

  @Test("a field-only edit refuses the write")
  func fieldOnlyChangeRefusesTheWrite() async throws {
    let coordinator = try coordinator(seedWords: [CustomWord(canonical: "Kubernetes")])
    var drifted = CustomWordsExportAction.exportableWords(from: coordinator.customWords)
    drifted[0].aliases = ["kubernetties"]
    let spy = WriteSpy()

    let outcome = await CustomWordsExportAction.run(
      coordinator: coordinator,
      proposedExportWords: drifted,
      chooseDestination: { self.tempURL() },
      write: { data, _ in await MainActor.run { spy.written = data } }
    )

    #expect(outcome == .libraryChanged)
    #expect(spy.written == nil)
  }

  @Test("an order-only change refuses the write")
  func orderOnlyChangeRefusesTheWrite() async throws {
    let coordinator = try coordinator(seedWords: [
      CustomWord(canonical: "Kubernetes"), CustomWord(canonical: "Qualtrics"),
    ])
    let reversed = Array(
      CustomWordsExportAction.exportableWords(from: coordinator.customWords).reversed())
    let spy = WriteSpy()

    let outcome = await CustomWordsExportAction.run(
      coordinator: coordinator,
      proposedExportWords: reversed,
      chooseDestination: { self.tempURL() },
      write: { data, _ in await MainActor.run { spy.written = data } }
    )

    #expect(outcome == .libraryChanged)
    #expect(spy.written == nil)
  }

  @Test("no words of your own reports an honest empty state without opening a panel")
  func emptyLibraryReportsNothingToExportAndNeverAsksForAFolder() async throws {
    let coordinator = try coordinator()
    let spy = WriteSpy()
    var panelOpened = false

    let outcome = await CustomWordsExportAction.run(
      coordinator: coordinator,
      proposedExportWords: [],
      chooseDestination: {
        panelOpened = true
        return self.tempURL()
      },
      write: { data, _ in await MainActor.run { spy.written = data } }
    )

    #expect(outcome == .nothingToExport)
    #expect(!panelOpened, "a dialog that can only produce an empty file is a trap")
    #expect(spy.written == nil)
  }

  @Test("an empty count that is actually stale says so instead of exporting silently")
  func emptyProposalThatRefreshesToNonEmptyReportsLibraryChanged() async throws {
    // The user was shown zero; disk disagrees. Exporting here would write a
    // snapshot they were never shown a number for.
    let coordinator = try coordinator(seedWords: [CustomWord(canonical: "Kubernetes")])
    var panelOpened = false

    let outcome = await CustomWordsExportAction.run(
      coordinator: coordinator,
      proposedExportWords: [],
      chooseDestination: {
        panelOpened = true
        return self.tempURL()
      },
      write: { _, _ in }
    )

    #expect(outcome == .libraryChanged)
    #expect(!panelOpened)
  }

  @Test("a retry against unchanged state exports rather than refusing forever")
  func stableRetryExportsAndDoesNotLoop() async throws {
    let coordinator = try coordinator(seedWords: [CustomWord(canonical: "Kubernetes")])
    let spy = WriteSpy()

    // First attempt drifts and is refused.
    let first = await CustomWordsExportAction.run(
      coordinator: coordinator,
      proposedExportWords: [CustomWord(canonical: "Stale")],
      chooseDestination: { self.tempURL() },
      write: { data, _ in await MainActor.run { spy.written = data } }
    )
    #expect(first == .libraryChanged)

    // The screen re-renders from adopted state; the retry must succeed.
    let second = await CustomWordsExportAction.run(
      coordinator: coordinator,
      proposedExportWords: CustomWordsExportAction.exportableWords(
        from: coordinator.customWords),
      chooseDestination: { self.tempURL() },
      write: { data, _ in await MainActor.run { spy.written = data } }
    )
    #expect(second == .exported)
  }

  // MARK: - #1696 / #1699: panel defaults

  @Test("the save panel starts in Downloads, and survives Downloads being unresolvable")
  func startingDirectoryPrefersDownloadsAndToleratesItsAbsence() {
    let downloads = URL(fileURLWithPath: "/Users/someone/Downloads", isDirectory: true)
    #expect(CustomWordsExportPanel.startingDirectory(searchResults: [downloads]) == downloads)
    // Unresolvable is not worth failing an export over: leave it unset.
    #expect(CustomWordsExportPanel.startingDirectory(searchResults: []) == nil)
  }

  @Test("the import screen names the file the exporter actually writes")
  func importCopyAndExportFilenameShareOneAuthority() {
    // Two literals would let the exporter rename the file and leave the import
    // copy describing one that no longer exists.
    #expect(CustomWordsExportPanel.defaultFilename == "EnviousWispr Words.json")
  }
}
