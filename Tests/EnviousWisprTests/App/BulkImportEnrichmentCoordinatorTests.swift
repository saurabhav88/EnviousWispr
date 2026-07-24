import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPostProcessing

/// Test double for the on-device alias generator. `@unchecked Sendable`
/// mirrors `ContactsImportCoordinatorTests`'s `FakeAliasSuggester`: the
/// coordinator's drain loop calls it sequentially behind `await`, so mutable
/// state here never races against the drain itself. `gate` lets a test hold
/// every call open until it has set up the "mid-flight" state it needs, then
/// release all of them at once.
private final class FakeAliasSuggester: AliasSuggesting, @unchecked Sendable {
  private let aliasesByWord: [String: [String]]
  private let gate: CallGate?
  /// Known-category-overload calls (`suggestAliases(for:category:priority:)`).
  private(set) var calls: [String] = []
  /// Classification-overload calls (`suggestAliases(for:priority:)`,
  /// #1701 Phase 3 review finding A) — recorded SEPARATELY so tests can
  /// assert which path a word actually took.
  private(set) var classificationCalls: [String] = []
  var available = true
  var isAvailable: Bool { available }

  init(aliasesByWord: [String: [String]] = [:], gate: CallGate? = nil) {
    self.aliasesByWord = aliasesByWord
    self.gate = gate
  }

  private(set) var priorities: [AliasSuggestionPriority] = []

  func suggestAliases(
    for word: String, category: WordCategory, priority: AliasSuggestionPriority
  ) async -> [String]? {
    calls.append(word)
    priorities.append(priority)
    // Mirrors `WordSuggestionService.suggestAliases`'s own real behavior:
    // unavailable always resolves to nil, never a call that hangs or throws.
    guard available else { return nil }
    if let gate {
      await gate.markCallStarted()
      try? await gate.waitUntilOpen()
    }
    return aliasesByWord[word]
  }

  func suggestAliases(
    for word: String, priority: AliasSuggestionPriority
  ) async -> [String]? {
    classificationCalls.append(word)
    priorities.append(priority)
    guard available else { return nil }
    if let gate {
      await gate.markCallStarted()
      try? await gate.waitUntilOpen()
    }
    return aliasesByWord[word]
  }
}

/// Test-only rendezvous: closed by default, `open()` releases every call
/// currently waiting AND every future one immediately. `waitUntilCallCount`
/// gives a happens-before point to act from once a call has genuinely
/// started, never racing real Swift Concurrency scheduling. Deadline-bounded
/// (`withThrowingTimeout`), matching `WordSuggestionServiceTests`'s
/// `ResumeGate` shape (`swift-patterns.md` RULE:
/// tests-no-unconditional-continuation-await).
private actor CallGate {
  private var open = false
  private(set) var callsStarted = 0

  func markCallStarted() { callsStarted += 1 }
  func open_() { open = true }

  func waitUntilOpen(timeoutSeconds: Double = 5) async throws {
    try await withThrowingTimeout(seconds: timeoutSeconds) {
      while await self.open == false {
        try Task.checkCancellation()
        await Task.yield()
      }
    }
  }

  func waitUntilCallCount(_ expected: Int, timeoutSeconds: Double = 5) async throws {
    try await withThrowingTimeout(seconds: timeoutSeconds) {
      while await self.callsStarted != expected {
        try Task.checkCancellation()
        await Task.yield()
      }
    }
  }
}

/// Records `retrySleep` calls without ever actually sleeping — the bounded
/// `.libraryBusy` retry tests (#1701 Phase 3 review finding B) assert the
/// exact delay schedule and count without depending on wall-clock time.
private actor DelayRecorder {
  private(set) var delays: [Duration] = []
  func record(_ delay: Duration) { delays.append(delay) }
}

@MainActor
@Suite("BulkImportEnrichmentCoordinator (#1701 Chunk 2)")
struct BulkImportEnrichmentCoordinatorTests {

  private func makeCoordinator() -> (CustomWordsCoordinator, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-bulk-coordinator-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("custom-words.json")
    return (CustomWordsCoordinator(manager: CustomWordsManager(fileURL: url)), url)
  }

  private func plan(
    baseline: [CustomWord], additions: [CustomWordsImportCandidate]
  ) -> CustomWordsImportCommitPlan {
    CustomWordsImportCommitPlan(
      baseline: CustomWordsImportLibrarySnapshot(words: baseline), additions: additions,
      replacements: [])
  }

  // MARK: - Resume after relaunch

  @Test("a fresh instance against pre-set pending state reads real progress, not a reset to zero")
  func freshInstanceReadsRealProgressOnFirstObservation() async throws {
    let (seedCoordinator, url) = makeCoordinator()
    _ = seedCoordinator.commitImport(
      plan(
        baseline: seedCoordinator.customWords,
        additions: [
          CustomWordsImportCandidate(canonical: "Kubernetes"),
          CustomWordsImportCandidate(canonical: "Qualtrics"),
        ]))

    // A fresh coordinator instance, as a relaunched process would construct —
    // never the seeding instance held onto in memory.
    let relaunchedCoordinator = CustomWordsCoordinator(manager: CustomWordsManager(fileURL: url))
    var presented: [String] = []
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: relaunchedCoordinator, aliasSuggester: FakeAliasSuggester(),
      presentStatus: { presented.append($0) })

    // The FIRST observation, before requestDrain() has run at all: real
    // durable state, not an in-memory counter reset to zero.
    #expect(relaunchedCoordinator.pendingEnrichmentBatchTotal == 2)
    #expect(relaunchedCoordinator.pendingEnrichmentWords()?.count == 2)

    bulkCoordinator.requestDrain()
    await bulkCoordinator.awaitDrainForTesting()

    #expect(relaunchedCoordinator.pendingEnrichmentBatchTotal == nil)
    #expect(presented.contains("Finished importing your words."))
  }

  // MARK: - Cancel

  @Test(
    "Cancel lets an in-flight checkpoint land, then sweeps a word added after the drain started"
  )
  func cancelLetsInFlightLandThenSweepsLiveStateNotAStaleCallerList() async throws {
    let (coordinator, url) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")]))
    let kubernetesID = try #require(
      coordinator.customWords.first { $0.canonical == "Kubernetes" }
    ).id

    let gate = CallGate()
    let suggester = FakeAliasSuggester(aliasesByWord: ["Kubernetes": ["k8s"]], gate: gate)
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator, aliasSuggester: suggester, presentStatus: { _ in })

    bulkCoordinator.requestDrain()
    try await gate.waitUntilCallCount(1)  // "Kubernetes"'s call has genuinely started

    // A second import lands on the SAME FILE while the drain is mid-flight,
    // through a raw manager the drain's own in-memory `pending` snapshot
    // never saw — this coordinator's idea of the target list is now stale
    // relative to the file.
    let rawManager = CustomWordsManager(fileURL: url)
    var rawWords = try #require(rawManager.load())
    _ = try rawManager.commitImport(
      plan(baseline: rawWords, additions: [CustomWordsImportCandidate(canonical: "Qualtrics")]),
      to: &rawWords)

    bulkCoordinator.cancel()
    await gate.open_()  // let the in-flight "Kubernetes" call finish
    await bulkCoordinator.awaitDrainForTesting()

    let final = try #require(coordinator.customWords.first { $0.id == kubernetesID })
    #expect(final.aliases == ["k8s"], "the in-flight call must finish and checkpoint normally")
    #expect(final.enrichmentPending == false)

    let qualtrics = try #require(coordinator.customWords.first { $0.canonical == "Qualtrics" })
    #expect(
      qualtrics.enrichmentPending == false,
      "Cancel's reload-and-sweep must clear a word the drain's stale in-memory list never saw")
    #expect(coordinator.pendingEnrichmentBatchTotal == nil)
  }

  @Test("cancel() with no active drain is a safe no-op sweep")
  func cancelWithNoActiveDrainIsSafeNoOpSweep() {
    let (coordinator, _) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")]))

    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator, aliasSuggester: FakeAliasSuggester(), presentStatus: { _ in })

    bulkCoordinator.cancel()

    #expect(coordinator.pendingEnrichmentBatchTotal == nil)
    #expect(coordinator.customWords.allSatisfy { $0.enrichmentPending == false })
  }

  @Test(
    "a cancel requested before the drain task even starts fires no pill and no model call, but still durably sweeps"
  )
  func cancelBeforeDrainStartsFiresNoPillAndSweeps() async throws {
    // Plan-completion audit finding 1: `requestDrain()` immediately followed
    // by `cancel()` — both synchronous MainActor calls with no `await`
    // between them — sets `cancelRequested` before the spawned Task can run
    // at all (the same synchronous-stretch guarantee this suite already
    // relies on elsewhere). The old code only checked `cancelRequested`
    // inside the per-word loop, so `drainOnce` still announced the start
    // pill before that loop's own guard caught the cancellation and broke
    // before any model call — zero calls even pre-fix, but a pill fired
    // that should never have fired.
    let (coordinator, _) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")]))

    let suggester = FakeAliasSuggester(aliasesByWord: ["Kubernetes": ["k8s"]])
    var presented: [String] = []
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator, aliasSuggester: suggester,
      presentStatus: { presented.append($0) })

    bulkCoordinator.requestDrain()
    bulkCoordinator.cancel()
    await bulkCoordinator.awaitDrainForTesting()

    #expect(suggester.calls.isEmpty, "a pre-start cancel must trigger zero model calls")
    #expect(
      suggester.classificationCalls.isEmpty, "a pre-start cancel must trigger zero model calls")
    #expect(presented.isEmpty, "a pre-start cancel must never announce a start pill")
    #expect(
      coordinator.pendingEnrichmentBatchTotal == nil, "the sweep must durably clear the total")
    #expect(
      coordinator.customWords.allSatisfy { $0.enrichmentPending == false },
      "the sweep must durably clear every pending word")
  }

  // MARK: - Second import mid-drain

  @Test("a second import mid-drain is picked up by the SAME drain, not dropped")
  func secondImportMidDrainIsPickedUpNotDropped() async throws {
    let (coordinator, _) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")]))

    let gate = CallGate()
    let suggester = FakeAliasSuggester(
      aliasesByWord: ["Kubernetes": ["k8s"], "Qualtrics": ["qualtrix"]], gate: gate)
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator, aliasSuggester: suggester, presentStatus: { _ in })

    bulkCoordinator.requestDrain()
    try await gate.waitUntilCallCount(1)  // "Kubernetes"'s call has genuinely started

    // A second import lands mid-drain, through the coordinator itself —
    // mirrors production: `CustomWordsCoordinator.onImportCommitted` would
    // call `requestDrain()` again here.
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Qualtrics")]))
    #expect(coordinator.pendingEnrichmentBatchTotal == 2, "extended, never reset")
    bulkCoordinator.requestDrain()  // coalesces: marks "one more pass" since a drain is active

    await gate.open_()
    await bulkCoordinator.awaitDrainForTesting()

    // The coalesced extra pass must have picked up "Qualtrics" too, not just
    // stopped after the original word.
    #expect(
      suggester.classificationCalls.contains("Qualtrics"),
      "the newly added word must be drained too")
    let qualtrics = try #require(coordinator.customWords.first { $0.canonical == "Qualtrics" })
    #expect(qualtrics.aliases == ["qualtrix"])
    #expect(coordinator.pendingEnrichmentBatchTotal == nil)
  }

  // MARK: - Write failure

  @Test("a locked-transaction write failure stops the drain without a completion pill")
  func writeFailureStopsTheDrainWithoutCompletionPill() async throws {
    let (coordinator, url) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")]))
    let dir = url.deletingLastPathComponent()

    // Lock the containing directory down AFTER the seeding commit succeeded,
    // so only the CHECKPOINT write fails.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    var presented: [String] = []
    let delayRecorder = DelayRecorder()
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator,
      aliasSuggester: FakeAliasSuggester(aliasesByWord: ["Kubernetes": ["k8s"]]),
      presentStatus: { presented.append($0) },
      retrySleep: { await delayRecorder.record($0) })

    bulkCoordinator.requestDrain()
    await bulkCoordinator.awaitDrainForTesting()

    #expect(presented.contains("Importing your words now. Check progress in the Your Words menu."))
    #expect(
      !presented.contains("Finished importing your words."),
      "a failed checkpoint write must never announce completion")
    #expect(
      await delayRecorder.delays.isEmpty,
      "a permanent (non-.libraryBusy) failure must never retry — Phase 3 review finding B")

    // Restore permissions before reading back, so the read-side of this
    // assertion isn't itself blocked by the fixture's own lockdown.
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    let onDisk = try #require(CustomWordsManager(fileURL: url).load())
    let word = try #require(onDisk.first { $0.canonical == "Kubernetes" })
    #expect(
      word.enrichmentPending == true,
      "an unresolved word must keep its pending flag when the checkpoint failed to write")
  }

  // MARK: - Bounded .libraryBusy recovery (Phase 3 review finding B)

  /// Unlike `makeCoordinator()`, keeps the manager reference so its
  /// `lockSyscall` seam can be rigged after seeding (#1701 finding B).
  private func makeCoordinatorRetainingManager() -> (CustomWordsCoordinator, CustomWordsManager) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-bulk-coordinator-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let mgr = CustomWordsManager(fileURL: dir.appendingPathComponent("custom-words.json"))
    return (CustomWordsCoordinator(manager: mgr), mgr)
  }

  @Test("busy on the initial repair, then success: one retry, clean completion")
  func busyOnRepairThenSucceeds() async throws {
    let (coordinator, mgr) = makeCoordinatorRetainingManager()
    // Seed through the coordinator's own commit path — real `lockSyscall`,
    // exactly as production writes — before rigging contention.
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")])
    )
    var lockCalls = 0
    mgr.lockSyscall = { fd, flags in
      lockCalls += 1
      guard lockCalls == 1 else { return flock(fd, flags) }
      errno = EWOULDBLOCK
      return -1
    }

    let delayRecorder = DelayRecorder()
    var presented: [String] = []
    let suggester = FakeAliasSuggester(aliasesByWord: ["Kubernetes": ["k8s"]])
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator,
      aliasSuggester: suggester,
      presentStatus: { presented.append($0) },
      retrySleep: { await delayRecorder.record($0) })

    bulkCoordinator.requestDrain()
    await bulkCoordinator.awaitDrainForTesting()

    #expect(await delayRecorder.delays == [.seconds(1)])
    #expect(
      suggester.classificationCalls == ["Kubernetes"],
      "the busy repair failed before the word loop ever ran — exactly one model call, on retry")
    #expect(coordinator.pendingEnrichmentCount == 0, "eventually persisted despite the busy repair")
    #expect(
      presented == [
        "Importing your words now. Check progress in the Your Words menu.",
        "Finished importing your words.",
      ], "no duplicate pills across the retry")
  }

  @Test("busy on the checkpoint, then success: eventually persisted, pills not duplicated")
  func busyOnCheckpointThenSucceeds() async throws {
    let (coordinator, mgr) = makeCoordinatorRetainingManager()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")])
    )
    // Call 1 = the repair (must succeed); call 2 = the checkpoint (busy
    // once); every later call succeeds — this puts the busy failure past the
    // word loop, unlike `busyOnRepairThenSucceeds` above.
    var lockCalls = 0
    mgr.lockSyscall = { fd, flags in
      lockCalls += 1
      guard lockCalls == 2 else { return flock(fd, flags) }
      errno = EWOULDBLOCK
      return -1
    }

    let delayRecorder = DelayRecorder()
    var presented: [String] = []
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator,
      aliasSuggester: FakeAliasSuggester(aliasesByWord: ["Kubernetes": ["k8s"]]),
      presentStatus: { presented.append($0) },
      retrySleep: { await delayRecorder.record($0) })

    bulkCoordinator.requestDrain()
    await bulkCoordinator.awaitDrainForTesting()

    #expect(await delayRecorder.delays == [.seconds(1)])
    let word = try #require(coordinator.customWords.first { $0.canonical == "Kubernetes" })
    #expect(word.aliases == ["k8s"], "the word is eventually persisted despite the busy checkpoint")
    #expect(
      presented == [
        "Importing your words now. Check progress in the Your Words menu.",
        "Finished importing your words.",
      ], "the pills are not duplicated by the retry")
  }

  @Test("exhausting all retries hard-stops once, keeps the queue pending, never loops tightly")
  func exhaustedRetriesHardStops() async throws {
    let (coordinator, mgr) = makeCoordinatorRetainingManager()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")])
    )
    // Every acquisition is busy, with no escape — proves genuine exhaustion,
    // not a lucky later success.
    mgr.lockSyscall = { _, _ in
      errno = EWOULDBLOCK
      return -1
    }

    let delayRecorder = DelayRecorder()
    var presented: [String] = []
    let suggester = FakeAliasSuggester(aliasesByWord: ["Kubernetes": ["k8s"]])
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator,
      aliasSuggester: suggester,
      presentStatus: { presented.append($0) },
      retrySleep: { await delayRecorder.record($0) })

    bulkCoordinator.requestDrain()
    await bulkCoordinator.awaitDrainForTesting()

    #expect(
      await delayRecorder.delays == [.seconds(1), .seconds(2), .seconds(4)],
      "four total attempts (one initial + three retries), then genuine exhaustion")
    #expect(
      suggester.classificationCalls.isEmpty,
      "every attempt failed at the repair, before the word loop could ever run")
    #expect(
      coordinator.pendingEnrichmentCount == 1, "the queue stays pending — nothing was abandoned")
    #expect(
      !presented.contains("Finished importing your words."),
      "exhaustion is a hard stop, never a false completion")
  }

  // MARK: - Fail-open (Codex Chunk 2 review finding 1)

  @Test("an unavailable model still resolves the whole queue, never stranding it")
  func unavailableModelStillResolvesTheQueue() async throws {
    let (coordinator, _) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [
          CustomWordsImportCandidate(canonical: "Kubernetes"),
          CustomWordsImportCandidate(canonical: "Qualtrics"),
        ]))

    let suggester = FakeAliasSuggester()
    suggester.available = false
    var presented: [String] = []
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator, aliasSuggester: suggester, presentStatus: { presented.append($0) })

    bulkCoordinator.requestDrain()
    await bulkCoordinator.awaitDrainForTesting()

    #expect(
      coordinator.customWords.allSatisfy { $0.enrichmentPending == false },
      "every word must still resolve — a stranded flag is what the old isAvailable guard caused")
    #expect(coordinator.pendingEnrichmentBatchTotal == nil)
    #expect(presented.contains("Finished importing your words."))
  }

  @Test(
    "a duplicate late result for a word another instance already checkpointed cannot overwrite it"
  )
  func duplicateLateResultCannotOverwriteAnotherInstancesFirstCheckpoint() async throws {
    // Codex Chunk 2 review round 2 finding 2: the per-word fresh re-read this
    // test used to prove was itself an O(n²) main-thread cost at the
    // 25,000-word ceiling. Correctness does not depend on skipping the
    // duplicate call — `applyEnrichmentResults`'s own pending-gate is what
    // actually protects the other instance's already-checkpointed result,
    // proven here at the coordinator level: the drain WILL call the model
    // again for "Qualtrics" (no per-word skip anymore), but its late result
    // must still lose to the other instance's first checkpoint.
    let (coordinator, url) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [
          CustomWordsImportCandidate(canonical: "Kubernetes"),
          CustomWordsImportCandidate(canonical: "Qualtrics"),
        ]))
    let qualtricsID = try #require(
      coordinator.customWords.first { $0.canonical == "Qualtrics" }
    ).id

    let gate = CallGate()
    let suggester = FakeAliasSuggester(
      aliasesByWord: ["Kubernetes": ["k8s"], "Qualtrics": ["late-duplicate"]], gate: gate)
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator, aliasSuggester: suggester, presentStatus: { _ in })

    bulkCoordinator.requestDrain()
    try await gate.waitUntilCallCount(1)  // "Kubernetes"'s call has genuinely started

    // A SEPARATE manager instance (simulating a second running app copy,
    // #1747) checkpoints "Qualtrics" FIRST, directly, bypassing this
    // coordinator entirely.
    let rawManager = CustomWordsManager(fileURL: url)
    _ = try rawManager.applyEnrichmentResults([
      CustomWordEnrichmentResult(id: qualtricsID, generatedAliases: ["other-instance-alias"])
    ])

    await gate.open_()
    await bulkCoordinator.awaitDrainForTesting()

    #expect(
      suggester.classificationCalls.contains("Qualtrics"),
      "the model IS called again — no per-word skip")
    let qualtrics = try #require(coordinator.customWords.first { $0.id == qualtricsID })
    #expect(
      qualtrics.aliases == ["other-instance-alias"],
      "the late duplicate must never overwrite the other instance's first checkpoint")
    #expect(!qualtrics.aliases.contains("late-duplicate"))
  }

  // MARK: - Worker failure terminality (Codex Chunk 2 review finding 4)

  @Test("a checkpoint failure with a wake already queued still hard-stops, never retries")
  func checkpointFailureWithQueuedWakeStillHardStops() async throws {
    let (coordinator, url) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")]))
    let dir = url.deletingLastPathComponent()

    let gate = CallGate()
    let suggester = FakeAliasSuggester(aliasesByWord: ["Kubernetes": ["k8s"]], gate: gate)
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator, aliasSuggester: suggester, presentStatus: { _ in })

    bulkCoordinator.requestDrain()
    try await gate.waitUntilCallCount(1)

    // A wake arrives WHILE this pass is in flight, mirroring
    // `onImportCommitted` firing mid-drain — queues "run one more pass."
    bulkCoordinator.requestDrain()

    // Lock the directory down so the tail checkpoint this pass is about to
    // attempt fails to write.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    await gate.open_()
    await bulkCoordinator.awaitDrainForTesting()

    // Exactly one call: the failure must hard-stop the loop before the
    // queued wake gets a chance to retry the same broken write again.
    #expect(suggester.classificationCalls == ["Kubernetes"])
  }

  #if DEBUG
    // `forcePendingEnrichmentWordsFailureOnCallForTesting` is `#if
    // DEBUG`-gated end to end (matches `rawSuggestionOverrideForTesting`'s
    // own precedent), so this test is gated the same way since it
    // references that symbol.
    @Test(
      "a failed final scan never fires a false completion pill, even after the checkpoint succeeded"
    )
    func failedFinalScanNeverFiresAFalseCompletionPill() async throws {
      // Codex Chunk 2 review round 2 finding 3: the drain's tail checkpoint
      // write and its immediately-following final re-scan read are both
      // synchronous with no suspension point between them — no external task
      // can time a real file-permission change to land strictly between
      // them. `forcePendingEnrichmentWordsFailureOnCallForTesting` targets
      // the SECOND call deterministically (call 1 = drainOnce's initial
      // scan, which must succeed; call 2 = the final re-scan, forced to
      // fail) with no file-system race at all — permissions stay open
      // throughout, so the checkpoint write genuinely succeeds first.
      let (coordinator, _) = makeCoordinator()
      _ = coordinator.commitImport(
        plan(
          baseline: coordinator.customWords,
          additions: [CustomWordsImportCandidate(canonical: "Kubernetes")]))
      coordinator.forcePendingEnrichmentWordsFailureOnCallForTesting = 2

      let suggester = FakeAliasSuggester(aliasesByWord: ["Kubernetes": ["k8s"]])
      var presented: [String] = []
      let bulkCoordinator = BulkImportEnrichmentCoordinator(
        customWords: coordinator, aliasSuggester: suggester,
        presentStatus: { presented.append($0) })

      bulkCoordinator.requestDrain()
      await bulkCoordinator.awaitDrainForTesting()

      let onDisk = try #require(coordinator.customWords.first { $0.canonical == "Kubernetes" })
      #expect(onDisk.aliases == ["k8s"], "the checkpoint itself must have genuinely succeeded")
      #expect(
        !presented.contains("Finished importing your words."),
        "a failed final read must never be treated as an empty, completed queue")

      // Codex Chunk 2 review round 3 finding 2: a failed final scan used to
      // leave `didAnnounceStart` (and the diagnostic counters) stuck forever,
      // so the NEXT session's genuine completion, and even its start pill,
      // could be silently suppressed. Retry now that the injected failure has
      // stopped firing (it targets call 2 only, already consumed above).
      coordinator.forcePendingEnrichmentWordsFailureOnCallForTesting = nil
      bulkCoordinator.requestDrain()
      await bulkCoordinator.awaitDrainForTesting()

      #expect(
        presented == [
          "Importing your words now. Check progress in the Your Words menu.",
          "Finished importing your words.",
        ],
        "the lingering session must finalize exactly once, with no duplicate start pill")

      // A genuinely NEW import must announce its own start pill normally —
      // proving `didAnnounceStart` was reset, not left stuck true forever.
      _ = coordinator.commitImport(
        plan(
          baseline: coordinator.customWords,
          additions: [CustomWordsImportCandidate(canonical: "Qualtrics")]))
      bulkCoordinator.requestDrain()
      await bulkCoordinator.awaitDrainForTesting()

      #expect(
        presented == [
          "Importing your words now. Check progress in the Your Words menu.",
          "Finished importing your words.",
          "Importing your words now. Check progress in the Your Words menu.",
          "Finished importing your words.",
        ],
        "the new session's start pill must fire, and its own completion must land, not be suppressed"
      )
    }
  #endif

  @Test("a Cancel whose durable sweep fails to write is never reported as a clean cancel")
  func cancelWriteFailureIsNeverReportedAsCleanCancel() throws {
    let (coordinator, url) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")]))
    let dir = url.deletingLastPathComponent()

    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator, aliasSuggester: FakeAliasSuggester(), presentStatus: { _ in })

    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    bulkCoordinator.cancel()  // no active drain — direct performCancelSweep() path

    // Restore permissions before reading back, so the assertion's own read
    // isn't blocked by the fixture's lockdown.
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    let onDisk = try #require(CustomWordsManager(fileURL: url).load())
    let word = try #require(onDisk.first { $0.canonical == "Kubernetes" })
    #expect(
      word.enrichmentPending == true,
      "a failed sweep write must never be reported as a successful cancel")
  }

  // MARK: - Classification-aware routing (Phase 3 review finding A)

  @Test(
    "a never-classified .general word is routed through classification; an explicitly categorized word is not"
  )
  func generalWordsClassifyExplicitlyCategorizedWordsDoNot() async throws {
    let (coordinator, _) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [
          CustomWordsImportCandidate(canonical: "Kubernetes"),
          CustomWordsImportCandidate(
            canonical: "Qualtrics", category: .supplied(.brand)),
        ]))
    let suggester = FakeAliasSuggester(
      aliasesByWord: ["Kubernetes": ["k8s"], "Qualtrics": ["qualtrix"]])
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator, aliasSuggester: suggester, presentStatus: { _ in })

    bulkCoordinator.requestDrain()
    await bulkCoordinator.awaitDrainForTesting()

    #expect(
      suggester.classificationCalls == ["Kubernetes"],
      "the never-classified word must take the classification path, not the known-category one")
    #expect(
      suggester.calls == ["Qualtrics"],
      "the explicitly categorized word must take the known-category path, not classification")
    #expect(suggester.priorities == [.background, .background])

    let kubernetes = try #require(coordinator.customWords.first { $0.canonical == "Kubernetes" })
    #expect(kubernetes.aliases == ["k8s"], "classified aliases still persist")
    #expect(
      kubernetes.category == .general,
      "the classifier's category is prompt-routing input only — the stored word stays .general")
    let qualtrics = try #require(coordinator.customWords.first { $0.canonical == "Qualtrics" })
    #expect(qualtrics.aliases == ["qualtrix"])
  }

  // MARK: - Required coverage: priority, single-flight, pill counts, chunking

  @Test("every suggestion call uses .background priority")
  func everyCallUsesBackgroundPriority() async throws {
    let (coordinator, _) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [
          CustomWordsImportCandidate(canonical: "Kubernetes"),
          CustomWordsImportCandidate(canonical: "Qualtrics"),
        ]))
    let suggester = FakeAliasSuggester()
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator, aliasSuggester: suggester, presentStatus: { _ in })

    bulkCoordinator.requestDrain()
    await bulkCoordinator.awaitDrainForTesting()

    #expect(suggester.priorities == [.background, .background])
  }

  @Test("two overlapping requestDrain() calls run exactly one walker, never two")
  func overlappingRequestDrainCallsAreSingleFlight() async throws {
    let (coordinator, _) = makeCoordinator()
    _ = coordinator.commitImport(
      plan(
        baseline: coordinator.customWords,
        additions: [CustomWordsImportCandidate(canonical: "Kubernetes")]))
    let gate = CallGate()
    let suggester = FakeAliasSuggester(aliasesByWord: ["Kubernetes": ["k8s"]], gate: gate)
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator, aliasSuggester: suggester, presentStatus: { _ in })

    bulkCoordinator.requestDrain()
    try await gate.waitUntilCallCount(1)
    // Fired repeatedly while the first pass is in flight — must coalesce,
    // never start a second concurrent walker calling the model again.
    bulkCoordinator.requestDrain()
    bulkCoordinator.requestDrain()
    bulkCoordinator.requestDrain()

    await gate.open_()
    await bulkCoordinator.awaitDrainForTesting()

    #expect(
      suggester.classificationCalls == ["Kubernetes"],
      "one word, called exactly once, by one walker"
    )
  }

  @Test("the start and finish pills each fire exactly once per continuous session")
  func startAndFinishPillsFireExactlyOncePerSession() async throws {
    let (coordinator, _) = makeCoordinator()
    let manyWords = (0..<30).map { CustomWordsImportCandidate(canonical: "Word\($0)") }
    _ = coordinator.commitImport(plan(baseline: coordinator.customWords, additions: manyWords))

    let suggester = FakeAliasSuggester()
    var presented: [String] = []
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator, aliasSuggester: suggester,
      presentStatus: { presented.append($0) })

    bulkCoordinator.requestDrain()
    await bulkCoordinator.awaitDrainForTesting()

    #expect(
      presented.filter { $0 == "Importing your words now. Check progress in the Your Words menu." }
        .count == 1)
    #expect(presented.filter { $0 == "Finished importing your words." }.count == 1)
  }

  @Test("more than 25 pending words checkpoint in chunks, not one call at the end")
  func checkpointsInChunksOf25() async throws {
    let (coordinator, _) = makeCoordinator()
    let manyWords = (0..<30).map { CustomWordsImportCandidate(canonical: "Word\($0)") }
    _ = coordinator.commitImport(plan(baseline: coordinator.customWords, additions: manyWords))

    var checkpointSizes: [Int] = []
    coordinator.onWordsChanged = { _ in
      // Each `onWordsChanged` firing corresponds to one
      // `applyEnrichmentResults` write; record the live pending count at that
      // moment as a proxy for "a checkpoint just landed mid-drain."
      checkpointSizes.append(coordinator.pendingEnrichmentCount)
    }
    let suggester = FakeAliasSuggester()
    let bulkCoordinator = BulkImportEnrichmentCoordinator(
      customWords: coordinator, aliasSuggester: suggester, presentStatus: { _ in })

    bulkCoordinator.requestDrain()
    await bulkCoordinator.awaitDrainForTesting()

    // 30 words, chunked at 25: one checkpoint at 5 remaining, one at 0 —
    // never a single checkpoint carrying all 30 at once.
    #expect(checkpointSizes.count >= 2, "expected at least two separate checkpoint writes")
    #expect(checkpointSizes.contains(5), "the first chunk boundary must land at 25 processed")
    #expect(coordinator.pendingEnrichmentBatchTotal == nil)
  }
}
