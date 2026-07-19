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
    var document: CustomWordsTransferDocument?
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
      write: { document, _ in await MainActor.run { spy.document = document } }
    )

    #expect(outcome == .refusedUnsafeLibrary)
    #expect(spy.document == nil, "an empty export must never reach the writer")
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
      write: { document, _ in await MainActor.run { spy.document = document } }
    )

    #expect(outcome == .exported)
    let document = try #require(spy.document)
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
}
