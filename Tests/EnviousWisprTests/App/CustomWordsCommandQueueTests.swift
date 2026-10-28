import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPostProcessing

/// #4086 Chunk 7: every dictionary save runs on the file worker as one queued command.
/// These hold the REAL worker with a signal and check what a person would notice: the
/// app stays usable while a save is stuck, the last saved list keeps working, the save
/// is only reported once it is really on disk, saves finish in the order they were
/// asked for, and a "nothing changed" or failed save is never reported as saved.
/// Holding the worker proves responsiveness, not disk speed. Class: `.productOutcome`.
@MainActor
@Suite(.tags(.productOutcome)) struct CustomWordsCommandQueueTests {

  /// Holds the file worker at its first transaction until `release()`.
  final class WorkerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var arrivals = 0
    private let opened = DispatchSemaphore(value: 0)
    private var expired = false

    var arrived: Bool { lock.withLock { arrivals > 0 } }
    var timedOut: Bool { lock.withLock { expired } }

    var hook: @Sendable () -> Void {
      { [self] in
        let first = lock.withLock { () -> Bool in
          arrivals += 1
          return arrivals == 1
        }
        guard first else { return }
        // The wait below is on the `release()` signal. Its deadline only stops a broken test
        // from holding the worker forever, and a hit is reported through `timedOut`.
        // settle: signal wait with a 10 s hang guard, not a guessed delay
        if opened.wait(timeout: .now() + 10) == .timedOut {
          lock.withLock { expired = true }
        }
      }
    }

    func release() { opened.signal() }
  }

  /// Records probe events in order.
  final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CustomWordsProbe.Event] = []
    var all: [CustomWordsProbe.Event] { lock.withLock { recorded } }
    func record(_ event: CustomWordsProbe.Event) { lock.withLock { recorded.append(event) } }
  }

  private struct Fixture {
    let words: CustomWordsCoordinator
    let manager: CustomWordsManager
    let url: URL
    let events: Events
  }

  private func fixture(seed: [CustomWord] = []) async throws -> Fixture {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-command-queue-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("custom-words.json")
    if !seed.isEmpty { _ = try await CustomWordsManager(fileURL: url).addBatch(seed) }
    let manager = CustomWordsManager(fileURL: url)
    let words = CustomWordsCoordinator(manager: manager)
    let events = Events()
    words.probe = CustomWordsProbe { event, _ in events.record(event) }
    return Fixture(words: words, manager: manager, url: url, events: events)
  }

  private func onDisk(_ url: URL) -> [CustomWord] {
    CustomWordsManager(fileURL: url).load() ?? []
  }

  private func has(_ events: [CustomWordsProbe.Event], _ match: (CustomWordsProbe.Event) -> Bool)
    -> Bool
  {
    events.contains(where: match)
  }

  @Test(
    "while a save is stuck on disk the app keeps working, and the save is reported only once it is on disk"
  )
  func heldSaveKeepsTheAppUsable() async throws {
    let original = CustomWord(canonical: "Kubernetes")
    let f = try await fixture(seed: [original])
    let gate = WorkerGate()
    f.manager.fileWorkWillStartForTesting = gate.hook
    var edited = try #require(f.words.customWords.first { $0.id == original.id })
    edited.aliases = ["cube nets"]

    let save = Task { await f.words.update(edited) }
    #expect(await settleUntilObserved { gate.arrived }, "the save never reached the file worker")

    // The main actor is free: other main-actor work runs to its end while the save is held.
    var otherWorkRan = false
    await Task { @MainActor in otherWorkRan = true }.value
    #expect(otherWorkRan)
    // The last saved list keeps working, and nothing claims the save happened.
    #expect(f.words.customWords.first { $0.id == original.id }?.aliases == [])
    let held = f.events.all
    #expect(has(held) { if case .storageStarted = $0 { true } else { false } })
    #expect(!has(held) { if case .storageReturned = $0 { true } else { false } })
    #expect(!has(held) { if case .published = $0 { true } else { false } })
    #expect(!has(held) { if case .completed = $0 { true } else { false } })
    #expect(onDisk(f.url).first { $0.id == original.id }?.aliases == [])

    gate.release()
    #expect(await save.value == nil)

    #expect(onDisk(f.url).first { $0.id == original.id }?.aliases == ["cube nets"])
    #expect(f.words.customWords.first { $0.id == original.id }?.aliases == ["cube nets"])
    let done = f.events.all
    let returned = try #require(
      done.firstIndex(of: .storageReturned(command: 1, operation: .update, outcome: .committed)))
    let published = try #require(done.firstIndex(of: .published(command: 1, operation: .update)))
    let completed = try #require(done.firstIndex(of: .completed(command: 1, operation: .update)))
    #expect(returned < published && published < completed)
    #expect(gate.timedOut == false)
  }

  @Test("an edit whose word is gone writes nothing and is reported as unchanged, never as saved")
  func unchangedIsNotACommit() async throws {
    let f = try await fixture(seed: [CustomWord(canonical: "Kubernetes")])
    let before = try Data(contentsOf: f.url)

    #expect(await f.words.update(CustomWord(canonical: "Ghost")) == nil)

    #expect(try Data(contentsOf: f.url) == before)
    #expect(
      f.events.all.contains(.storageReturned(command: 1, operation: .update, outcome: .unchanged)))
    #expect(!f.events.all.contains(.published(command: 1, operation: .update)))
  }

  @Test("a save that fails is reported as failed and changes neither the list nor the file")
  func failedIsNotACommit() async throws {
    let original = CustomWord(canonical: "Kubernetes")
    let f = try await fixture(seed: [original])
    let before = try Data(contentsOf: f.url)
    let shown = f.words.customWords
    // Hold the dictionary's companion lock the way a second app instance would.
    let lockURL = f.url.appendingPathExtension("lock")
    let openedFD = lockURL.path.withCString { open($0, O_RDWR | O_CREAT, 0o600) }
    let fd = try #require(openedFD >= 0 ? openedFD : nil)
    defer { close(fd) }
    try #require(flock(fd, LOCK_EX) == 0)
    defer { flock(fd, LOCK_UN) }
    var edited = original
    edited.aliases = ["cube nets"]

    #expect(await f.words.update(edited) != nil)

    #expect(try Data(contentsOf: f.url) == before)
    #expect(f.words.customWords == shown)
    #expect(
      f.events.all.contains(.storageReturned(command: 1, operation: .update, outcome: .failed)))
    #expect(!f.events.all.contains(.published(command: 1, operation: .update)))
  }

  @Test(
    "saves asked for while one is stuck finish in the order they were asked for, and none is lost")
  func heldSavesFinishInOrder() async throws {
    let f = try await fixture()
    let gate = WorkerGate()
    f.manager.fileWorkWillStartForTesting = gate.hook

    let a = Task { await f.words.add(CustomWord(canonical: "Alpha")) }
    #expect(await settleUntilObserved { gate.arrived })
    let b = Task { await f.words.add(CustomWord(canonical: "Bravo")) }
    let refreshes = (0..<3).map { _ in Task { await f.words.refreshFromDiskIfPossible() } }
    #expect(
      await settleUntilObserved {
        f.events.all.contains { if case .admitted(_, .refresh) = $0 { true } else { false } }
      })

    gate.release()
    #expect(await a.value == nil)
    #expect(await b.value == nil)
    for refresh in refreshes { #expect(await refresh.value) }

    let canonicals = onDisk(f.url).map(\.canonical)
    #expect(canonicals.contains("Alpha") && canonicals.contains("Bravo"))
    let order = f.events.all.compactMap { event -> CustomWordsProbe.Operation? in
      if case .completed(_, let operation) = event { return operation }
      return nil
    }
    #expect(Array(order.prefix(2)) == [.add, .add])
    // Three refreshes queued behind the same save read the file once.
    #expect(order.filter { $0 == .refresh }.count == 1)
    #expect(gate.timedOut == false)
  }

  @Test("a learn queued behind a delete sees the no that delete recorded")
  func queuedLearnSeesTheRefusalBeforeIt() async throws {
    let learned = CustomWord(canonical: "Kwmala", aliases: ["kumala"], learnedAliases: ["kumala"])
    let f = try await fixture(seed: [learned])
    let key = CorrectionPairKey.make(original: "kumala", corrected: "Kwmala")
    // One earlier no: the delete's no is the second, which blocks the pair.
    f.words.learnMemory.recordUndo(key)
    #expect(f.words.learnMemory.isBlocked(key) == false)
    let gate = WorkerGate()
    f.manager.fileWorkWillStartForTesting = gate.hook

    let delete = Task { await f.words.deleteByUser(id: learned.id) }
    #expect(await settleUntilObserved { gate.arrived })
    // Queued while the delete is held: it must run after the delete's refusal landed.
    let learn = Task {
      await f.words.performAction(closing: false) { f.words.learnMemory.isBlocked(key) }
    }
    #expect(
      await settleUntilObserved {
        f.events.all.contains { if case .admitted(_, .action) = $0 { true } else { false } }
      })

    gate.release()
    #expect(await delete.value == nil)
    #expect(await learn.value == true, "the learn ran before the delete's no was recorded")
  }

  @Test("a step inside a running command joins it instead of waiting behind it")
  func nestedStepsDoNotDeadlock() async throws {
    let f = try await fixture()
    let saved = await f.words.performAction(closing: false) { () -> Bool in
      let added = await f.words.add(CustomWord(canonical: "Alpha")) == nil
      let read = await f.words.refreshFromDiskIfPossible()
      return added && read
    }
    #expect(saved)
    let admitted = f.events.all.filter { if case .admitted = $0 { true } else { false } }
    #expect(admitted == [.admitted(command: 1, operation: .action)])
  }

  // MARK: - A change saved meanwhile is never overwritten

  /// Another app window: its own manager, its own worker, the same file.
  private func siblingEdit(_ url: URL, id: UUID, _ change: (inout CustomWord) -> Void) async throws
    -> CustomWord
  {
    let sibling = CustomWordsManager(fileURL: url)
    var word = try #require(sibling.load()?.first { $0.id == id })
    change(&word)
    _ = try await sibling.update(word: word)
    return try #require(sibling.load()?.first { $0.id == id })
  }

  @Test("an edit that expects the word as it was writes nothing when another window changed it while the save waited")
  func guardedEditKeepsASiblingChange() async throws {
    let original = CustomWord(canonical: "Kubernetes")
    let f = try await fixture(seed: [original])
    let shown = try #require(f.words.customWords.first { $0.id == original.id })
    let gate = WorkerGate()
    f.manager.fileWorkWillStartForTesting = gate.hook
    var mine = shown
    mine.aliases = ["mine"]

    let save = Task { await f.words.update(mine, expecting: shown) }
    #expect(await settleUntilObserved { gate.arrived })
    let theirs = try await siblingEdit(f.url, id: original.id) { $0.aliases = ["theirs"] }
    gate.release()

    #expect(await save.value == nil)
    #expect(onDisk(f.url).first { $0.id == original.id } == theirs)
    #expect(f.words.customWords.first { $0.id == original.id } == theirs)
    #expect(
      f.events.all.contains(.storageReturned(command: 1, operation: .update, outcome: .unchanged)))
    #expect(gate.timedOut == false)
  }

  @Test("a delete that expects the word as it was leaves it when another window changed it while the delete waited")
  func guardedDeleteKeepsASiblingChange() async throws {
    let original = CustomWord(canonical: "Kubernetes")
    let f = try await fixture(seed: [original])
    let shown = try #require(f.words.customWords.first { $0.id == original.id })
    let gate = WorkerGate()
    f.manager.fileWorkWillStartForTesting = gate.hook

    let delete = Task { await f.words.remove(id: original.id, expecting: shown) }
    #expect(await settleUntilObserved { gate.arrived })
    let theirs = try await siblingEdit(f.url, id: original.id) { $0.aliases = ["theirs"] }
    gate.release()

    #expect(await delete.value == nil)
    #expect(onDisk(f.url).first { $0.id == original.id } == theirs)
    #expect(f.words.customWords.first { $0.id == original.id } == theirs)
    #expect(gate.timedOut == false)
  }

  @Test("Undo of a learn leaves the word alone when another window changed it after the learn")
  func undoKeepsASiblingChange() async throws {
    let target = CustomWord(canonical: "Kwmala")
    let f = try await fixture(seed: [target])
    let telemetry = LearnedTelemetrySpy()
    let learner = LearnedCorrectionCoordinator(
      vocabulary: LearnFromEditsWiring.vocabulary(customWords: f.words, packTerms: { [] }),
      memory: f.words.learnMemory, telemetry: telemetry)
    let outcome = await learner.learn(
      original: "kumala", corrected: "Kwmala", expectedTarget: .existingWord(target.id))
    guard case .learned(let pill) = outcome else {
      Issue.record("the learn did not save: \(outcome)")
      return
    }
    #expect(f.words.customWords.first { $0.id == target.id }?.aliases == ["kumala"])

    let theirs = try await siblingEdit(f.url, id: target.id) { $0.aliases.append("theirs") }

    #expect(await learner.undo(pillID: pill.id) == .alreadyChanged)
    #expect(onDisk(f.url).first { $0.id == target.id } == theirs)
    #expect(f.words.customWords.first { $0.id == target.id } == theirs)
    #expect(f.words.learnMemory.entry(CorrectionPairKey.make(original: "kumala", corrected: "Kwmala")) == nil,
      "an Undo that changed nothing recorded the user's no")
  }

  @Test("usage counts save as a queued dictionary command")
  func usageFlushIsACommand() async throws {
    let word = CustomWord(canonical: "Kubernetes")
    let f = try await fixture(seed: [word])
    f.manager.recordReplacements([word.id])
    await f.manager.flushPendingIncrementsForTesting()
    #expect(f.events.all.contains(.admitted(command: 1, operation: .usageFlush)))
    #expect(f.events.all.contains(.completed(command: 1, operation: .usageFlush)))
    #expect(onDisk(f.url).first { $0.id == word.id }?.frequencyUsed == 1)
  }

  @Test("a learn whose save waited while another window added the same spelling owns no Undo")
  func learnThatWroteNothingOwnsNoUndo() async throws {
    let target = CustomWord(canonical: "Kwmala")
    let f = try await fixture(seed: [target])
    let learner = LearnedCorrectionCoordinator(
      vocabulary: LearnFromEditsWiring.vocabulary(customWords: f.words, packTerms: { [] }),
      memory: f.words.learnMemory, telemetry: LearnedTelemetrySpy())
    let gate = WorkerGate()
    f.manager.fileWorkWillStartForTesting = gate.hook

    let learn = Task {
      await learner.learn(
        original: "kumala", corrected: "Kwmala", expectedTarget: .existingWord(target.id))
    }
    #expect(await settleUntilObserved { gate.arrived })
    let theirs = try await siblingEdit(f.url, id: target.id) {
      $0.aliases.append("kumala")
      $0.priority = 7
    }
    gate.release()

    #expect(await learn.value == .alreadyCovered)
    #expect(learner.undoRecord == nil, "a learn that changed nothing was given an Undo")
    #expect(onDisk(f.url).first { $0.id == target.id } == theirs)
    #expect(f.words.customWords.first { $0.id == target.id } == theirs)
    #expect(gate.timedOut == false)
  }

  // MARK: - Work started inside a command queues like any other

  @Test("a task started inside a command waits behind it, even while that command waits on disk")
  func spawnedTaskDoesNotJoinTheCommand() async throws {
    let f = try await fixture()
    let gate = WorkerGate()
    f.manager.fileWorkWillStartForTesting = gate.hook
    let spawned = SpawnedBox()

    let action = Task {
      await f.words.performAction(closing: ()) {
        spawned.task = Task { await f.words.add(CustomWord(canonical: "Spawned")) }
        // This command now waits on the held worker while the spawned task runs.
        _ = await f.words.add(CustomWord(canonical: "Owner"))
      }
    }
    #expect(await settleUntilObserved { gate.arrived })
    #expect(
      await settleUntilObserved {
        f.events.all.contains(.admitted(command: 2, operation: .add))
      }, "the spawned save joined the running command instead of queuing")
    gate.release()
    await action.value
    #expect(await spawned.task?.value == nil)
    let completed = f.events.all.compactMap { event -> Int? in
      if case .completed(let number, _) = event { return number }
      return nil
    }
    #expect(completed == [1, 2], "the spawned save finished before the command it started in")
  }

  @MainActor final class SpawnedBox {
    var task: Task<String?, Never>?
  }

  @Test("enrichment started by an import queues its own saves, and Quit waits for them")
  func importStartedEnrichmentQueuesAndQuitWaits() async throws {
    let f = try await fixture()
    let suggester = HeldEnrichmentSuggester()
    let enrichment = BulkImportEnrichmentCoordinator(
      customWords: f.words, aliasSuggester: suggester, presentStatus: { _ in })
    f.words.onImportCommitted = { enrichment.requestDrain() }

    let outcome = await f.words.commitImport(
      CustomWordsImportCommitPlan(
        baseline: CustomWordsImportLibrarySnapshot(words: f.words.customWords),
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")], replacements: []))
    guard case .committed = outcome else {
      Issue.record("the import did not commit: \(outcome)")
      return
    }
    // The drain is asking for aliases now; its checkpoint is still ahead.
    #expect(await settleUntilObserved { suggester.asked })
    let commandsBefore = f.events.all.filter { if case .admitted = $0 { true } else { false } }.count

    let replies = QuitReplies()
    suggester.release()
    // The drain's checkpoint must queue as its own command, so Quit sees it.
    #expect(
      await settleUntilObserved {
        f.events.all.filter { if case .admitted = $0 { true } else { false } }.count > commandsBefore
      })
    _ = f.words.requestQuit { replies.values.append($0) }
    await enrichment.awaitDrainForTesting()
    let admittedOps = f.events.all.compactMap { event -> CustomWordsProbe.Operation? in
      if case .admitted(_, let operation) = event { return operation }
      return nil
    }
    #expect(admittedOps.contains(.enrichmentApply), "the checkpoint skipped the queue")
    #expect(admittedOps.contains(.enrichmentRepair), "the drain's repair skipped the queue")
  }

  // MARK: - Quit

  /// Holds the enrichment drain's alias request until `release()`.
  final class HeldEnrichmentSuggester: AliasSuggesting, @unchecked Sendable {
    private let lock = NSLock()
    private var wasAsked = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    var isAvailable: Bool { true }
    var asked: Bool { lock.withLock { wasAsked } }

    func release() {
      let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        released = true
        defer { waiting = [] }
        return waiting
      }
      for continuation in ready { continuation.resume() }
    }

    private func hold() async {
      let mustWait = lock.withLock { () -> Bool in
        wasAsked = true
        return !released
      }
      guard mustWait else { return }
      await withCheckedContinuation { continuation in
        let resumeNow = lock.withLock { () -> Bool in
          if released { return true }
          waiting.append(continuation)
          return false
        }
        if resumeNow { continuation.resume() }
      }
    }

    func suggestAliases(
      for word: String, category: WordCategory, priority: AliasSuggestionPriority
    ) async -> [String]? {
      await hold()
      return ["cube nets"]
    }

    func suggestAliases(for word: String, priority: AliasSuggestionPriority) async -> [String]? {
      await hold()
      return ["cube nets"]
    }
  }

  /// Records the one answer Quit owes AppKit.
  final class QuitReplies {
    var values: [Bool] = []
  }

  @Test("Quit with nothing queued may quit at once and owes no later answer")
  func idleQuitIsImmediate() async throws {
    let f = try await fixture()
    #expect(f.words.requestQuit { _ in Issue.record("no later answer is owed") })
  }

  @Test(
    "Quit waits for a queued save, a second Quit joins it, a new change is refused, and one answer says quit"
  )
  func quitWaitsForAQueuedSave() async throws {
    let f = try await fixture()
    let gate = WorkerGate()
    f.manager.fileWorkWillStartForTesting = gate.hook
    let replies = QuitReplies()

    let save = Task { await f.words.add(CustomWord(canonical: "Alpha")) }
    #expect(await settleUntilObserved { gate.arrived })
    #expect(f.words.requestQuit { replies.values.append($0) } == false)
    #expect(f.words.requestQuit { replies.values.append($0) } == false)
    // A change asked for while Quit waits does not join the queue, so it cannot delay Quit.
    #expect(await f.words.add(CustomWord(canonical: "Bravo")) == CustomWordsCoordinator.quittingMessage)
    #expect(replies.values.isEmpty, "Quit was answered before the queued save finished")

    gate.release()
    #expect(await save.value == nil)
    #expect(await settleUntilObserved { !replies.values.isEmpty })
    #expect(replies.values == [true])
    let canonicals = onDisk(f.url).map(\.canonical)
    #expect(canonicals.contains("Alpha") && !canonicals.contains("Bravo"))
  }

  @Test(
    "a queued save that fails stops Quit once, keeps its error, takes changes again, and a later Quit goes through"
  )
  func failedSaveCancelsQuit() async throws {
    let f = try await fixture()
    let replies = QuitReplies()
    let lockURL = f.url.appendingPathExtension("lock")
    let openedFD = lockURL.path.withCString { open($0, O_RDWR | O_CREAT, 0o600) }
    let fd = try #require(openedFD >= 0 ? openedFD : nil)
    defer { close(fd) }
    // Another instance holds the dictionary, so the held save will fail.
    try #require(flock(fd, LOCK_EX) == 0)
    let gate = WorkerGate()
    f.manager.fileWorkWillStartForTesting = gate.hook

    let save = Task { await f.words.add(CustomWord(canonical: "Alpha")) }
    #expect(await settleUntilObserved { gate.arrived })
    #expect(f.words.requestQuit { replies.values.append($0) } == false)
    #expect(f.words.requestQuit { replies.values.append($0) } == false)
    gate.release()

    #expect(await save.value != nil)
    #expect(await settleUntilObserved { !replies.values.isEmpty })
    #expect(replies.values == [false])
    #expect(f.words.customWordError != nil, "the failed save's message was lost")

    // The other instance lets go; the person tries again and it saves.
    try #require(flock(fd, LOCK_UN) == 0)
    #expect(await f.words.add(CustomWord(canonical: "Alpha")) == nil)
    #expect(onDisk(f.url).contains { $0.canonical == "Alpha" })
    // Nothing queued now, so the next Quit goes through at once.
    #expect(f.words.requestQuit { _ in Issue.record("no later answer is owed") })
    #expect(replies.values == [false])
  }
}
