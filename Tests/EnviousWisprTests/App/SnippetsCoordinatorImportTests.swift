import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPostProcessing

/// #2997 — what the coordinator publishes after an import, and how it reports the store.
///
/// `.productOutcome`: when this fails the settings list and the dictation drivers disagree
/// about which snippets exist, an edit made during an import is silently undone, every
/// snippet is switched off for the session, or a stale review is shown as a failure.
@MainActor
@Suite("Snippets coordinator import (#2997)", .tags(.productOutcome))
struct SnippetsCoordinatorImportTests {

  private func makeCoordinator() -> (SnippetsCoordinator, SnippetsManager) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-snippets-coordinator-\(UUID().uuidString)", isDirectory: true)
    let manager = SnippetsManager(fileURL: dir.appendingPathComponent("snippets.json"))
    // A first launch seeds starter snippets; the tests want a known list, so clear them.
    let coordinator = SnippetsCoordinator(manager: manager)
    for starter in coordinator.snippets { coordinator.delete(starter) }
    return (coordinator, manager)
  }

  /// A complete file from a NEWER app: the store reads it as unreadable (unknown data that
  /// must not be overwritten), which is the case these tests stage. A truncated document
  /// would instead be archived as corrupt and read as empty.
  private static let newerVersionFile = Data(
    "{\"version\": 99, \"keyword\": \"backslash\", \"snippets\": []}".utf8)

  /// Stages the unreadable re-read and PROVES it: a fixture write that failed would leave a
  /// readable file, and the test would then pass through the branch it is not about.
  private static func makeUnreadable(_ manager: SnippetsManager) {
    do {
      try newerVersionFile.write(to: manager.storageURL)
    } catch {
      Issue.record("could not stage the unreadable file: \(error)")
    }
    #expect(manager.loadedVocabulary() == nil, "the staged file must read as unreadable")
  }

  private func plan(
    _ coordinator: SnippetsCoordinator, additions: [Snippet]
  ) -> SnippetsCoordinator.SnippetImportCommitPlan {
    SnippetsCoordinator.SnippetImportCommitPlan(
      baseline: coordinator.snippets, additions: additions)
  }

  @Test("A committed import is published once, to the list and to the drivers")
  func commitPublishes() async throws {
    let (coordinator, _) = makeCoordinator()
    let existing = Snippet(trigger: "my email", expansion: "sam@example.com")
    #expect(coordinator.save(existing))
    var published: [SnippetVocabulary] = []
    coordinator.onVocabularyChanged = { published.append($0) }
    let addition = Snippet(trigger: "sig", expansion: "Best,\nSam")

    let outcome = await coordinator.commitImport(plan(coordinator, additions: [addition]))

    guard case .committed(let receipt) = outcome else {
      Issue.record("expected .committed, got \(outcome)")
      return
    }
    #expect(receipt.addedIDs == [addition.id])
    #expect(coordinator.snippets.map(\.id) == [addition.id, existing.id])
    #expect(published.count == 1)
    #expect(published.first?.snippets.map(\.id) == [addition.id, existing.id])
    #expect(coordinator.errorMessage == nil)
  }

  @Test("An empty plan publishes nothing and touches no file")
  func emptyPlanPublishesNothing() async throws {
    let (coordinator, manager) = makeCoordinator()
    let before = manager.load()
    var published = 0
    coordinator.onVocabularyChanged = { _ in published += 1 }

    let outcome = await coordinator.commitImport(plan(coordinator, additions: []))

    guard case .committed(let receipt) = outcome else {
      Issue.record("expected .committed, got \(outcome)")
      return
    }
    #expect(receipt.addedIDs.isEmpty)
    #expect(published == 0)
    #expect(manager.load().generation == before.generation)
  }

  @Test("What is published is the DISK state: an edit saved after the store write wins")
  func publishesDiskStateNotTheReceipt() async throws {
    let (coordinator, _) = makeCoordinator()
    let addition = Snippet(trigger: "sig", expansion: "hi")
    let lateEdit = Snippet(trigger: "late", expansion: "saved during the import")
    // The window between the store write returning and the main actor publishing.
    coordinator.importWriteDidReturn = { #expect(coordinator.save(lateEdit)) }

    let outcome = await coordinator.commitImport(plan(coordinator, additions: [addition]))

    guard case .committed(let receipt) = outcome else {
      Issue.record("expected .committed, got \(outcome)")
      return
    }
    // The receipt predates the edit; the published list carries both.
    #expect(receipt.vocabulary.snippets.map(\.id) == [addition.id])
    #expect(Set(coordinator.snippets.map(\.id)) == [lateEdit.id, addition.id])
    #expect(coordinator.vocabulary.generation > receipt.vocabulary.generation)
  }

  @Test("If the re-read fails, a newer published list is kept and an older one is replaced by the receipt; never empty")
  func unreadableRereadFallsBackOnGenerations() async throws {
    // Case 1: nothing newer was published, so the receipt is adopted.
    do {
      let (coordinator, manager) = makeCoordinator()
      let addition = Snippet(trigger: "sig", expansion: "hi")
      coordinator.importWriteDidReturn = {
        Self.makeUnreadable(manager)
      }
      let outcome = await coordinator.commitImport(plan(coordinator, additions: [addition]))
      guard case .committed(let receipt) = outcome else {
        Issue.record("expected .committed, got \(outcome)")
        return
      }
      #expect(coordinator.vocabulary == receipt.vocabulary)
      #expect(coordinator.snippets.map(\.id) == [addition.id])
    }
    // Case 2: an edit was published after the write, so it is kept over the older receipt.
    do {
      let (coordinator, manager) = makeCoordinator()
      let addition = Snippet(trigger: "sig", expansion: "hi")
      let lateEdit = Snippet(trigger: "late", expansion: "newer")
      coordinator.importWriteDidReturn = {
        #expect(coordinator.save(lateEdit))
        Self.makeUnreadable(manager)
      }
      let generationBefore = coordinator.vocabulary.generation
      let outcome = await coordinator.commitImport(plan(coordinator, additions: [addition]))
      guard case .committed(let receipt) = outcome else {
        Issue.record("expected .committed, got \(outcome)")
        return
      }
      #expect(coordinator.vocabulary.generation > receipt.vocabulary.generation)
      #expect(coordinator.vocabulary.generation > generationBefore)
      #expect(Set(coordinator.snippets.map(\.id)) == [lateEdit.id, addition.id])
      #expect(!coordinator.snippets.isEmpty)
    }
  }

  @Test("A list changed during review is reported as stale, not as a failure, and writes nothing")
  func staleIsAnOutcome() async throws {
    let (coordinator, manager) = makeCoordinator()
    let reviewedAgainst = coordinator.snippets
    // Another EnviousWispr process saves after the review was built.
    let other = SnippetsManager(fileURL: manager.storageURL)
    try other.upsert(Snippet(trigger: "elsewhere", expansion: "x"))
    var published = 0
    coordinator.onVocabularyChanged = { _ in published += 1 }

    let outcome = await coordinator.commitImport(
      SnippetsCoordinator.SnippetImportCommitPlan(
        baseline: reviewedAgainst, additions: [Snippet(trigger: "sig", expansion: "hi")]))

    #expect(outcome == .stale)
    #expect(published == 0)
    #expect(coordinator.errorMessage == nil)
    #expect(manager.load().snippets.map(\.trigger) == ["elsewhere"])
  }

  @Test("Validation and store failures carry the coordinator's own sentences and never the page's error slot")
  func failuresAreMappedToSentences() async throws {
    let (coordinator, manager) = makeCoordinator()
    #expect(coordinator.save(Snippet(trigger: "my email", expansion: "sam@example.com")))

    let duplicate = await coordinator.commitImport(
      plan(coordinator, additions: [Snippet(trigger: "MY EMAIL", expansion: "other")]))
    #expect(duplicate == .failed(.validation(.duplicateTrigger(existing: "my email"))))
    if case .failed(let error) = duplicate {
      #expect(
        error.message
          == SnippetsCoordinator.message(
            for: SnippetValidationError.duplicateTrigger(existing: "my email")))
    }

    let baseline = coordinator.snippets
    try Self.newerVersionFile.write(to: manager.storageURL)
    let unreadable = await coordinator.commitImport(
      SnippetsCoordinator.SnippetImportCommitPlan(
        baseline: baseline, additions: [Snippet(trigger: "sig", expansion: "hi")]))
    #expect(unreadable == .failed(.store(.existingFileUnreadable)))
    if case .failed(let error) = unreadable {
      #expect(
        error.message == SnippetsCoordinator.message(for: SnippetStoreError.existingFileUnreadable))
    }
    #expect(coordinator.errorMessage == nil)
  }

  @Test("A refresh against an unreadable file keeps the published list and publishes nothing")
  func refreshAgainstUnreadableFileKeepsPublishedList() throws {
    let (coordinator, manager) = makeCoordinator()
    let existing = Snippet(trigger: "my email", expansion: "sam@example.com")
    #expect(coordinator.save(existing))
    var published = 0
    coordinator.onVocabularyChanged = { _ in published += 1 }

    try Self.newerVersionFile.write(to: manager.storageURL)
    let refreshed = coordinator.refreshFromDisk()

    #expect(refreshed.snippets.map(\.id) == [existing.id])
    #expect(coordinator.snippets.map(\.id) == [existing.id])
    #expect(published == 0)
    #expect(manager.load().snippets.isEmpty, "load() reads it as empty; the refresh must not")

    // A missing file IS empty, and a refresh says so.
    try FileManager.default.removeItem(at: manager.storageURL)
    #expect(coordinator.refreshFromDisk().snippets.isEmpty)
    #expect(published == 1)
  }

  @Test("A contended refresh adopts the writer's fresh disk state and publishes it")
  func refreshWaitsForAWriter() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-refresh-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("snippets.json")
    let fixture = RefreshLockFixture(url: url)
    let manager = SnippetsManager(fileURL: url, lockObserver: { flags, result, error in
      fixture.observe(flags: flags, result: result, error: error)
    })
    let coordinator = SnippetsCoordinator(manager: manager)
    for starter in coordinator.snippets { coordinator.delete(starter) }
    let before = Snippet(trigger: "before", expansion: "x")
    try #require(coordinator.save(before))
    let after = Snippet(trigger: "added by writer", expansion: "y")
    let data = try JSONEncoder().encode(SnippetsManager.StoredFile(
      version: SnippetsManager.currentVersion, keyword: "backslash", snippets: [after, before]))
    var published: [SnippetVocabulary] = []
    coordinator.onVocabularyChanged = { published.append($0) }
    // This binds the stale-backup outcome, not elapsed time inside the kernel syscall.
    // The observer releases the writer before acquisition; actual syscall blocking is not measured.
    fixture.arm()
    fixture.startWriter(data: data)
    var joined = false
    defer {
      fixture.release.signal()
      if joined == false { #expect(RefreshLockFixture.wait(fixture.finished)) }
    }
    try #require(RefreshLockFixture.wait(fixture.acquired), "holder acquisition never arrived")
    try #require(fixture.errors.isEmpty, "holder setup failed: \(fixture.errors)")

    let refreshed = coordinator.refreshFromDisk()
    fixture.record("returned")
    joined = RefreshLockFixture.wait(fixture.finished)
    #expect(joined, "holder completion never arrived")
    #expect(fixture.errors.isEmpty, "fixture failures: \(fixture.errors)")
    #expect(refreshed.snippets.map(\.id) == [after.id, before.id])
    #expect(coordinator.snippets.map(\.id) == [after.id, before.id])
    #expect(published.count == 1)
    #expect(published.first?.snippets.map(\.id) == [after.id, before.id])
    #expect(fixture.trace == ["holder", "contended", "written", "acquired", "returned"])
  }

  @Test("Every store error has a sentence, including the stale one")
  func staleErrorHasASentence() {
    let sentence = SnippetsCoordinator.message(for: SnippetStoreError.listChangedDuringReview)
    #expect(sentence.contains("changed while you were reviewing"))
    #expect(sentence.contains("Nothing was imported"))
  }
}

/// Real lock orchestration: the observer receives no descriptor and cannot replace flock.
private final class RefreshLockFixture: @unchecked Sendable {
  let url: URL
  let acquired = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let finished = DispatchSemaphore(value: 0)
  private let state = NSLock()
  private var armed = false
  private var events: [String] = []
  private var failures: [String] = []

  init(url: URL) { self.url = url }

  func arm() { state.withLock { armed = true } }
  func record(_ event: String) { state.withLock { events.append(event) } }
  func fail(_ message: String) { state.withLock { failures.append(message) } }
  var trace: [String] { state.withLock { events } }
  var errors: [String] { state.withLock { failures } }

  // deadline-fallback: same five-second signal guard as CustomWordsManagerLockingTests.
  static func wait(_ signal: DispatchSemaphore, seconds: Double = 5) -> Bool {
    signal.wait(timeout: .now() + seconds) == .success
  }

  func startWriter(data: Data) {
    DispatchQueue.global().async { [self] in
      defer { finished.signal() }
      do {
        try DurableJSONFile.withExclusiveLock(on: url, blocking: true) {
          record("holder")
          acquired.signal()
          guard Self.wait(release) else {
            fail("writer release signal never arrived")
            return
          }
          try DurableJSONFile.write(data: data, to: url, tempPrefix: ".refresh-fixture")
          record("written")
        }
      } catch {
        fail("writer failed: \(error)")
        acquired.signal() // wake the caller so the setup error is reported, never hidden as a hang.
      }
    }
  }

  func observe(flags: Int32, result: Int32?, error: Int32?) {
    guard state.withLock({ armed }) else { return }
    if let result {
      if result == 0 { record("acquired") }
      else if flags & LOCK_NB != 0 {
        if result != -1 || error != EWOULDBLOCK { fail("unexpected nonblocking result") }
        release.signal()
      }
      return
    }
    let fd = Foundation.open(url.appendingPathExtension("lock").path, O_RDWR | O_CLOEXEC)
    guard fd >= 0 else {
      fail("could not open contention probe")
      release.signal()
      return
    }
    defer { close(fd) }
    let probe = flock(fd, LOCK_EX | LOCK_NB)
    let probeError = errno
    if probe == 0 { _ = flock(fd, LOCK_UN) }
    guard probe == -1, probeError == EWOULDBLOCK else {
      fail("writer did not actually hold the companion lock")
      release.signal()
      return
    }
    record("contended")
    // A nonblocking mutation must try while the holder remains locked; only its result releases it.
    if flags & LOCK_NB == 0 { release.signal() }
  }
}

@Suite("Refresh lock fixture deadlines (#3414)", .tags(.harnessContract))
struct RefreshLockFixtureDeadlineTests {
  @Test("An absent fixture signal expires rather than hanging")
  func missingSignalExpires() {
    #expect(RefreshLockFixture.wait(DispatchSemaphore(value: 0), seconds: 0.05) == false)
  }
}
