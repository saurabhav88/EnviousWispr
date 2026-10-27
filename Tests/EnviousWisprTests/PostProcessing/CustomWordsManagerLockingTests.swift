import EnviousWisprCore
import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import EnviousWisprPostProcessing
import EnviousWisprAppKitTestSupport

/// #1690 — the cross-process lock foundation. Explicit user
/// mutations acquire the companion `.lock` file NON-BLOCKING: on contention
/// (another process/descriptor holds it) they fail instantly with
/// `.libraryBusy` rather than freezing this `@MainActor` class, and a
/// non-contention `flock` failure maps to `.coordinationUnavailable`.
@MainActor
@Suite("CustomWordsManager — cross-process lock (#1690)")
struct CustomWordsManagerLockingTests {
  private static func tempDir() -> URL {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("EnviousWispr-1690-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private static func cleanup(_ dir: URL) {
    try? FileManager.default.removeItem(at: dir)
  }

  private static func backupFiles(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
      .filter { $0.hasPrefix("custom-words.backup-") }
  }

  /// A local mirror of the production `CustomWordsFile` schema. It was written
  /// when that type was `private` to `CustomWordsManager.swift`; #4086 moved it to
  /// `CustomWordsFileStore.swift`, and the mirror stays independent so these bytes
  /// never come from the production encoder under test. Field-for-field identical, so
  /// bytes this encodes decode identically through the real production
  /// decoder — used to simulate a sibling process's fresh on-disk write.
  private struct SiblingFileFixture: Encodable {
    var version: Int = 1
    var builtinsVersion: Int = 1
    var deletedBuiltinIds: [String] = []
    var words: [CustomWord]
  }

  private enum SiblingSimulationError: Error {
    case timedOutWaitingForLockRequest
    case unlockFailed(Int32)
    case closeFailed(Int32)
  }

  /// Independently opens a REAL second OS file descriptor on the real
  /// companion `.lock` file and takes `flock` on it directly — exercising the
  /// same open-file-description mechanism `withExclusiveFileLock` relies on,
  /// unlike a mock or an in-process stub.
  @Test(.timeLimit(.minutes(1)))
  func realContentionFailsClosedInsteadOfBlocking() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let mgr = CustomWordsManager(fileURL: url)

    var words = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Kubernetes"), to: &words)
    let bytesBefore = try Data(contentsOf: url)

    let lockURL = url.appendingPathExtension("lock")
    let openedFD = lockURL.path.withCString { open($0, O_RDWR | O_CREAT, 0o600) }
    let rawFD = try #require(openedFD >= 0 ? openedFD : nil)
    defer { close(rawFD) }
    try #require(flock(rawFD, LOCK_EX) == 0)

    // A synchronous blocked `flock` cannot be interrupted by `.timeLimit`, so
    // that trait alone cannot prove non-blocking behavior — it would just
    // make a regression fail slowly instead of hanging forever. This proves
    // it directly: the manager's OWN acquisition call is intercepted, and any
    // request that doesn't carry LOCK_NB is refused WITHOUT ever touching the
    // real (and, here, genuinely contended) syscall, so a regression to
    // blocking mode fails fast on the flags assertion rather than hanging.
    var observedFlags: Int32?
    mgr.lockSyscall = { fd, flags in
      observedFlags = flags
      guard flags & LOCK_NB != 0 else {
        errno = EINVAL
        return -1
      }
      return flock(fd, flags)
    }

    let error = #expect(throws: CustomWordsPersistenceError.self) {
      try mgr.add(word: CustomWord(canonical: "Terraform"), to: &words)
    }
    #expect(observedFlags == (LOCK_EX | LOCK_NB))
    #expect(error == .libraryBusy)
    #expect(
      error?.errorDescription
        == "Your word list is being updated by another EnviousWispr window. Nothing was changed. Try again."
    )

    // Nothing changed: neither disk nor the caller's in-memory list.
    #expect(try Data(contentsOf: url) == bytesBefore)
    #expect(words.contains { $0.canonical == "Terraform" } == false)

    // Release the raw lock; the identical mutation now succeeds against the
    // fresh disk baseline.
    try #require(flock(rawFD, LOCK_UN) == 0)
    try mgr.add(word: CustomWord(canonical: "Terraform"), to: &words)
    #expect(words.contains { $0.canonical == "Terraform" })
  }

  /// Uses the injected `lockSyscall` seam (not a real second process) to
  /// force an unexpected, non-`EWOULDBLOCK` `flock` failure.
  @Test
  func injectedNonContentionFailureMapsToCoordinationUnavailable() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let mgr = CustomWordsManager(fileURL: url)

    var words = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Kubernetes"), to: &words)
    let bytesBefore = try Data(contentsOf: url)

    var seamFD: Int32 = -1
    mgr.lockSyscall = { fd, _ in
      seamFD = fd
      errno = EIO
      return -1
    }

    let error = #expect(throws: CustomWordsPersistenceError.self) {
      try mgr.add(word: CustomWord(canonical: "Terraform"), to: &words)
    }
    #expect(error == .coordinationUnavailable)
    #expect(
      error?.errorDescription
        == "Your saved words could not be updated safely. Nothing was changed. Try again."
    )

    // Nothing changed: neither disk nor the caller's in-memory list.
    #expect(try Data(contentsOf: url) == bytesBefore)
    #expect(words.contains { $0.canonical == "Terraform" } == false)

    // The seam received a real descriptor. Whether it was closed afterwards is
    // not asserted: a closed descriptor's number is reused at once by any test
    // running in parallel, so `fcntl(F_GETFD)` on it failed at random in CI
    // (#3817).
    #expect(seamFD >= 0)
  }

  /// The debounced usage-count writer is the one AUTOMATIC (non-user-triggered)
  /// caller of the lock authority (#1690). Contention must requeue the whole
  /// captured snapshot rather than drop it, and the second explicit flush
  /// (not a timer) is what proves the retry — never a fixed sleep.
  @Test
  func usageFlushContentionRequeuesInsteadOfDropping() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let mgr = CustomWordsManager(fileURL: url)

    var words = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Kubernetes"), to: &words)
    let target = try #require(words.first { $0.canonical == "Kubernetes" })
    let bytesBefore = try Data(contentsOf: url)

    mgr.recordReplacements([target.id])

    let lockURL = url.appendingPathExtension("lock")
    let openedFD = lockURL.path.withCString { open($0, O_RDWR | O_CREAT, 0o600) }
    let rawFD = try #require(openedFD >= 0 ? openedFD : nil)
    defer { close(rawFD) }
    try #require(flock(rawFD, LOCK_EX) == 0)

    var sawBlockingRequest = false
    mgr.lockSyscall = { fd, flags in
      guard flags & LOCK_NB != 0 else {
        sawBlockingRequest = true
        errno = EINVAL
        return -1
      }
      return flock(fd, flags)
    }

    // Contended: the debounced writer fails closed instantly, same as any
    // explicit mutation, and must not lose the captured increment.
    mgr.flushPendingIncrementsForTesting()
    #expect(try Data(contentsOf: url) == bytesBefore)

    // Release the raw lock; the SECOND explicit flush call is the retry
    // driver here, not a timer — this cancels the requeue's rescheduled
    // debounce task and drives the flush itself, so no sleep is needed.
    try #require(flock(rawFD, LOCK_UN) == 0)
    mgr.flushPendingIncrementsForTesting()

    #expect(sawBlockingRequest == false)
    let reloaded = try #require(CustomWordsManager(fileURL: url).load())
    let flushed = try #require(reloaded.first { $0.id == target.id })
    #expect(flushed.frequencyUsed == 1)
  }

  /// `commitImport` is the other complex mutation that routes through the
  /// lock (#1690): its staleness check, validation, backup, and save must all
  /// occur under one lock hold, and contention must surface the same honest
  /// `.libraryBusy` an ordinary mutation would, not a misleading "unreadable
  /// library" error.
  @Test
  func commitImportContentionPropagatesLibraryBusyAndRetriesCleanly() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let mgr = CustomWordsManager(fileURL: url)

    var words = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Qualtrics"), to: &words)
    let bytesBefore = try Data(contentsOf: url)
    let wordsBefore = words
    let backupsBefore = Self.backupFiles(in: dir)

    let importPlan = CustomWordsImportCommitPlan(
      baseline: CustomWordsImportLibrarySnapshot(words: words),
      additions: [CustomWordsImportCandidate(canonical: "Kubernetes")],
      replacements: [])

    let lockURL = url.appendingPathExtension("lock")
    let openedFD = lockURL.path.withCString { open($0, O_RDWR | O_CREAT, 0o600) }
    let rawFD = try #require(openedFD >= 0 ? openedFD : nil)
    defer { close(rawFD) }
    try #require(flock(rawFD, LOCK_EX) == 0)

    mgr.lockSyscall = { fd, flags in
      guard flags & LOCK_NB != 0 else {
        errno = EINVAL
        return -1
      }
      return flock(fd, flags)
    }

    let error = #expect(throws: CustomWordsPersistenceError.self) {
      try mgr.commitImport(importPlan, to: &words)
    }
    #expect(error == .libraryBusy)
    #expect(try Data(contentsOf: url) == bytesBefore)
    #expect(words == wordsBefore)
    #expect(Self.backupFiles(in: dir) == backupsBefore)

    try #require(flock(rawFD, LOCK_UN) == 0)
    let receipt = try mgr.commitImport(importPlan, to: &words)
    #expect(receipt.addedIDs.count == 1)
    #expect(words.contains { $0.canonical == "Kubernetes" })
    let onDisk = try #require(CustomWordsManager(fileURL: url).load())
    #expect(onDisk.contains { $0.canonical == "Kubernetes" })
  }

  /// A non-contention `flock` failure (e.g. a permissions/disk problem, not
  /// another process holding the lock) must surface as `.coordinationUnavailable`
  /// through `commitImport`, never silently collapsed into the existing
  /// `.unreadableLibrary` case — those mean different things to the coordinator.
  @Test
  func commitImportNonContentionLockFailurePropagatesCoordinationUnavailable() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let mgr = CustomWordsManager(fileURL: url)

    var words = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Qualtrics"), to: &words)
    let bytesBefore = try Data(contentsOf: url)
    let wordsBefore = words
    let backupsBefore = Self.backupFiles(in: dir)

    let importPlan = CustomWordsImportCommitPlan(
      baseline: CustomWordsImportLibrarySnapshot(words: words),
      additions: [CustomWordsImportCandidate(canonical: "Kubernetes")],
      replacements: [])

    var seamFD: Int32 = -1
    mgr.lockSyscall = { fd, _ in
      seamFD = fd
      errno = EIO
      return -1
    }

    let error = #expect(throws: CustomWordsPersistenceError.self) {
      try mgr.commitImport(importPlan, to: &words)
    }
    #expect(error == .coordinationUnavailable)
    #expect(try Data(contentsOf: url) == bytesBefore)
    #expect(words == wordsBefore)
    #expect(Self.backupFiles(in: dir) == backupsBefore)

    #expect(seamFD >= 0)
  }

  /// A fresh Phase 3 review finding (#1690): the lock alone does not stop a
  /// duplicate canonical, because `add`'s uniqueness check runs against the
  /// CALLER's `words` snapshot before the lock is even requested. A sibling
  /// process can commit the SAME canonical after that snapshot was taken;
  /// without a fresh re-check under the lock, both processes would append
  /// their own copy, leaving a permanent on-disk duplicate. Proves the
  /// locked transform's own fresh re-check is what actually prevents it.
  @Test
  func addRechecksUniquenessAgainstTheFreshFileNotTheStaleSnapshot() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let mgr = CustomWordsManager(fileURL: url)

    // The caller's snapshot is taken BEFORE any word exists — this is the
    // exact staleness the pre-lock check alone cannot see past.
    var staleWords = try #require(mgr.load())
    #expect(staleWords.contains { $0.canonical == "Kubernetes" } == false)

    // Simulate a sibling process's already-completed, already-saved add of
    // the SAME canonical, landing after the snapshot above.
    let sibling = CustomWordsManager(fileURL: url)
    var siblingWords = try #require(sibling.load())
    try sibling.add(word: CustomWord(canonical: "Kubernetes"), to: &siblingWords)

    // This call's pre-lock check sees only the stale (empty) snapshot, so it
    // reaches the locked transaction regardless.
    try mgr.add(word: CustomWord(canonical: "Kubernetes"), to: &staleWords)

    let onDisk = try #require(CustomWordsManager(fileURL: url).load())
    let onDiskMatches = onDisk.filter {
      $0.canonical.caseInsensitiveCompare("Kubernetes") == .orderedSame
    }
    #expect(onDiskMatches.count == 1)
    let callerMatches = staleWords.filter {
      $0.canonical.caseInsensitiveCompare("Kubernetes") == .orderedSame
    }
    #expect(callerMatches.count == 1)
  }

  /// A second fresh Phase 3 review finding (#1690): `update` was the only
  /// one of the six ordinary mutations that published the caller's manually
  /// patched, stale array instead of the freshly merged file. Proves it now
  /// surfaces a sibling's concurrent change instead of silently dropping it
  /// until the next reload.
  @Test
  func updatePublishesTheFreshlyMergedFileNotAStalePatch() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let mgr = CustomWordsManager(fileURL: url)

    var words = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Qualtrics"), to: &words)
    let target = try #require(words.first { $0.canonical == "Qualtrics" })

    // Simulate a sibling process's concurrent, already-saved addition of a
    // DIFFERENT word, landing after this caller's snapshot was taken.
    let sibling = CustomWordsManager(fileURL: url)
    var siblingWords = try #require(sibling.load())
    try sibling.add(word: CustomWord(canonical: "Kubernetes"), to: &siblingWords)
    #expect(words.contains { $0.canonical == "Kubernetes" } == false)

    var edited = target
    edited.aliases = ["Qualtrics XM"]
    try mgr.update(word: edited, in: &words)

    #expect(words.contains { $0.canonical == "Kubernetes" })
    #expect(words.first { $0.canonical == "Qualtrics" }?.aliases == ["Qualtrics XM"])
  }

  /// A cloud review finding on the PR built from this plan (#1690): `update`'s
  /// fallback branch assumed a missing id always meant "a built-in being
  /// overridden for the first time." It could also mean a sibling process
  /// deleted this exact user word while the edit was in flight — absence
  /// alone cannot tell the two apart. The old code silently resurrected the
  /// deleted word by appending the caller's stale edit. Proves it now drops
  /// the stale edit and publishes the fresh (word-gone) state instead.
  @Test
  func updateDoesNotResurrectAWordASiblingDeleted() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let mgr = CustomWordsManager(fileURL: url)

    var words = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Qualtrics"), to: &words)
    let target = try #require(words.first { $0.canonical == "Qualtrics" })

    // This caller's snapshot still shows "Qualtrics" as present — captured
    // before the sibling's delete below.
    var staleWords = words
    var edited = target
    edited.aliases = ["Qualtrics XM"]

    // A sibling process deletes the SAME word the edit above targets,
    // landing after staleWords was captured.
    let sibling = CustomWordsManager(fileURL: url)
    var siblingWords = try #require(sibling.load())
    try sibling.remove(id: target.id, from: &siblingWords)

    try mgr.update(word: edited, in: &staleWords)

    let onDisk = try #require(CustomWordsManager(fileURL: url).load())
    #expect(onDisk.contains { $0.id == target.id } == false)
    #expect(onDisk.contains { $0.canonical == "Qualtrics" } == false)
    #expect(staleWords.contains { $0.id == target.id } == false)
    #expect(staleWords.contains { $0.canonical == "Qualtrics" } == false)
  }

  /// A third fresh Phase 3 review finding (#1690): the debounced usage-count
  /// writer assigned `lastUsed` unconditionally, so an older captured
  /// timestamp could regress a newer one already persisted by a sibling
  /// process's own, later-ordered flush. Proves it now merges via the same
  /// `max()` pattern `requeuePendingIncrementSnapshot` already uses, by
  /// persisting a future timestamp directly (standing in for "a sibling
  /// already recorded something newer than anything this flush's own,
  /// always-`Date()` capture time could be) and confirming a flush cannot
  /// regress it.
  @Test
  func flushKeepsTheNewestCrossProcessUsageTimestamp() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let mgr = CustomWordsManager(fileURL: url)

    var words = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Kubernetes"), to: &words)
    let target = try #require(words.first { $0.canonical == "Kubernetes" })

    let futureTimestamp = Date().addingTimeInterval(3600)
    var persisted = target
    persisted.lastUsed = futureTimestamp
    try mgr.update(word: persisted, in: &words)

    // This flush's captured timestamp is `Date()` at call time — strictly
    // OLDER than the already-persisted future value above.
    mgr.recordReplacements([target.id])
    mgr.flushPendingIncrementsForTesting()

    let reloaded = try #require(CustomWordsManager(fileURL: url).load())
    let flushed = try #require(reloaded.first { $0.id == target.id })
    #expect(flushed.frequencyUsed == 1)
    #expect(flushed.lastUsed == futureTimestamp)
  }

  // MARK: - load()'s lock-free fast path and blocking repair path

  /// A fourth fresh Phase 3 review finding (#1690): if a sibling process's
  /// file removal races between `loadFileReadOnly()`'s existence check and
  /// its read, the read fails with a bare "file not found" — which, left
  /// unclassified, was reported as `.unreadable` instead of routing through
  /// the SAME locked repair path an ordinary `.needsRepair` case already
  /// uses. That silently lost the fact that something was ever wrong here:
  /// the coordinator's corruption latch (guarding against writing an empty
  /// export over a real backup) only ever gets set from a `.corrupted`
  /// result, never from `.unreadable`. Proves the vanished-file race now
  /// correctly resolves to `.corrupted`, not a clean "first run."
  @Test
  func loadFileReadOnlyRaceOnDisappearanceRoutesToCorruptedNotUnreadable() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let garbage = Data("not valid json at all {{{".utf8)
    try garbage.write(to: url)
    let mgr = CustomWordsManager(fileURL: url)

    // Fires after loadFileReadOnly() confirms the file exists but before it
    // reads it — simulating a sibling process completing its own quarantine
    // move in that exact window.
    mgr.afterFileExistsCheckForTesting = {
      try? FileManager.default.removeItem(at: url)
    }

    let words = mgr.load()
    #expect(words == nil)
    #expect(mgr.lastLoadFailure == .corrupted)
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
  }

  /// A current-format file must never touch the lock at all (#1690) — the
  /// fast path in `loadFileReadOnly()` decodes and returns directly.
  @Test
  func currentFormatFastPathIgnoresAHeldLock() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let mgr = CustomWordsManager(fileURL: url)

    var words = try #require(mgr.load())
    try mgr.add(word: CustomWord(canonical: "Kubernetes"), to: &words)

    let lockURL = url.appendingPathExtension("lock")
    let openedFD = lockURL.path.withCString { open($0, O_RDWR | O_CREAT, 0o600) }
    let rawFD = try #require(openedFD >= 0 ? openedFD : nil)
    defer { close(rawFD) }
    try #require(flock(rawFD, LOCK_EX) == 0)

    var lockSyscallCalled = false
    mgr.lockSyscall = { _, _ in
      // Never call a potentially blocking real syscall from this seam. If
      // the fast path regresses and reaches the lock at all, failing fast
      // here — rather than actually attempting a real `flock` against the
      // externally held raw lock — keeps this test from ever hanging.
      lockSyscallCalled = true
      errno = EINVAL
      return -1
    }

    let reloaded = try #require(mgr.load())
    #expect(reloaded.contains { $0.canonical == "Kubernetes" })
    #expect(lockSyscallCalled == false)
    #expect(mgr.lastLoadFailure == nil)
  }

  /// The rare repair path waits for a genuinely held lock, then adopts
  /// whatever a sibling process left behind rather than the stale
  /// non-current-format bytes it observed before waiting (#1690).
  @Test
  func repairLoadWaitsAndAdoptsASiblingsFreshResult() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    // Legacy [String] bytes: readable, but not current-format, so the
    // lock-free classifier returns .needsRepair.
    try JSONEncoder().encode(["LegacyTerm"]).write(to: url)
    let mgr = CustomWordsManager(fileURL: url)

    let lockURL = url.appendingPathExtension("lock")
    let openedFD = lockURL.path.withCString { open($0, O_RDWR | O_CREAT, 0o600) }
    let rawFD = try #require(openedFD >= 0 ? openedFD : nil)
    try #require(flock(rawFD, LOCK_EX) == 0)

    let lockRequested = DispatchSemaphore(value: 0)
    let siblingFinished = DispatchSemaphore(value: 0)
    // Single-touch handoff: the background closure writes these once, then
    // signals `siblingFinished`; the test only reads them after waiting on
    // that semaphore, so the write happens-before the read.
    nonisolated(unsafe) var observedFlags: Int32?
    nonisolated(unsafe) var siblingError: Error?

    mgr.lockSyscall = { fd, flags in
      observedFlags = flags
      lockRequested.signal()
      // The real, genuinely blocking syscall — it will not return until the
      // background closure below releases the raw lock.
      return flock(fd, flags)
    }

    // Sole ownership of rawFD transfers to this background closure: it is the
    // only code path that unlocks and closes it, on every exit including a
    // signal timeout, so a regression can never leave the manager's real
    // blocking `flock` call — or this raw descriptor — stuck forever.
    DispatchQueue.global().async {
      func finish(recording primaryError: Error?) {
        var finalError = primaryError
        if flock(rawFD, LOCK_UN) != 0 {
          let unlockErrno = errno
          if finalError == nil { finalError = SiblingSimulationError.unlockFailed(unlockErrno) }
        }
        if close(rawFD) != 0 {
          let closeErrno = errno
          if finalError == nil { finalError = SiblingSimulationError.closeFailed(closeErrno) }
        }
        siblingError = finalError
        siblingFinished.signal()
      }

      // deadline-fallback: guards a genuine hang if the manager never locks.
      guard lockRequested.wait(timeout: .now() + 5) == .success else {
        finish(recording: SiblingSimulationError.timedOutWaitingForLockRequest)
        return
      }
      do {
        let fresh = SiblingFileFixture(words: [CustomWord(canonical: "FreshFromSibling")])
        try JSONEncoder().encode(fresh).write(to: url)
        finish(recording: nil)
      } catch {
        finish(recording: error)
      }
    }

    let loadedWords = mgr.load()
    // deadline-fallback: joins the sibling worker before any throwing assertion.
    let siblingDidFinish = siblingFinished.wait(timeout: .now() + 5)
    #expect(siblingDidFinish == .success)
    let words = try #require(loadedWords)
    #expect(siblingError == nil)
    #expect(observedFlags == LOCK_EX)
    #expect(words.contains { $0.canonical == "FreshFromSibling" })
    #expect(words.contains { $0.canonical == "LegacyTerm" } == false)
    #expect(mgr.lastLoadFailure == nil)
  }

  /// If a sibling completes quarantine WHILE this call is waiting for the
  /// lock, the locked reread sees a genuinely `.missing` canonical file —
  /// but this same call already observed non-current-format bytes moments
  /// ago, so that must report `.corrupted`, never a clean empty library
  /// (#1690).
  @Test
  func siblingQuarantineWhileWaitingPreservesTheEarlierRepairObservation() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let garbage = Data("not valid json at all {{{".utf8)
    try garbage.write(to: url)
    let mgr = CustomWordsManager(fileURL: url)

    let lockURL = url.appendingPathExtension("lock")
    let openedFD = lockURL.path.withCString { open($0, O_RDWR | O_CREAT, 0o600) }
    let rawFD = try #require(openedFD >= 0 ? openedFD : nil)
    try #require(flock(rawFD, LOCK_EX) == 0)

    let lockRequested = DispatchSemaphore(value: 0)
    let siblingFinished = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var observedFlags: Int32?
    nonisolated(unsafe) var siblingError: Error?
    let sidecarURL = dir.appendingPathComponent("custom-words.json.corrupted-sibling-test")

    mgr.lockSyscall = { fd, flags in
      observedFlags = flags
      lockRequested.signal()
      return flock(fd, flags)
    }

    // Sole ownership of rawFD transfers to this background closure: it is the
    // only code path that unlocks and closes it, on every exit including a
    // signal timeout, so a regression can never leave the manager's real
    // blocking `flock` call — or this raw descriptor — stuck forever.
    DispatchQueue.global().async {
      func finish(recording primaryError: Error?) {
        var finalError = primaryError
        if flock(rawFD, LOCK_UN) != 0 {
          let unlockErrno = errno
          if finalError == nil { finalError = SiblingSimulationError.unlockFailed(unlockErrno) }
        }
        if close(rawFD) != 0 {
          let closeErrno = errno
          if finalError == nil { finalError = SiblingSimulationError.closeFailed(closeErrno) }
        }
        siblingError = finalError
        siblingFinished.signal()
      }

      // deadline-fallback: guards a genuine hang if the manager never locks.
      guard lockRequested.wait(timeout: .now() + 5) == .success else {
        finish(recording: SiblingSimulationError.timedOutWaitingForLockRequest)
        return
      }
      do {
        try FileManager.default.moveItem(at: url, to: sidecarURL)
        finish(recording: nil)
      } catch {
        finish(recording: error)
      }
    }

    let words = mgr.load()
    // deadline-fallback: joins the sibling worker before any throwing assertion.
    let siblingDidFinish = siblingFinished.wait(timeout: .now() + 5)
    #expect(siblingDidFinish == .success)
    #expect(siblingError == nil)
    #expect(observedFlags == LOCK_EX)
    #expect(words == nil)
    #expect(mgr.lastLoadFailure == .corrupted)
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
    #expect(try Data(contentsOf: sidecarURL) == garbage)
  }

  /// A blocking-mode `flock` failure that is NOT contention (a genuine
  /// open/syscall problem) must map to `.unreadable`, never a new
  /// `.libraryBusy`-shaped signal on the public `load()` surface, and must
  /// still close its descriptor (#1690).
  @Test
  func blockingAcquisitionFailureMapsToUnreadableAndClosesItsDescriptor() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    // A current-format file would never enter the lock path at all.
    try JSONEncoder().encode(["LegacyTerm"]).write(to: url)
    let bytesBefore = try Data(contentsOf: url)
    let mgr = CustomWordsManager(fileURL: url)

    var seamFD: Int32 = -1
    var observedFlags: Int32?
    mgr.lockSyscall = { fd, flags in
      seamFD = fd
      observedFlags = flags
      errno = EIO
      return -1
    }

    let words = mgr.load()
    #expect(words == nil)
    #expect(mgr.lastLoadFailure == .unreadable)
    #expect(observedFlags == LOCK_EX)

    #expect(seamFD >= 0)

    #expect(try Data(contentsOf: url) == bytesBefore)
    let sidecars =
      (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
      .filter { $0.contains(".corrupted-") } ?? []
    #expect(sidecars.isEmpty)
  }

  // MARK: - Repair-outcome coverage

  /// Closes the approved plan §11 repair matrix's fresh-migration member: a
  /// legacy `[CustomWord]` file no sibling has touched, migrated for the
  /// first time under the blocking lock.
  @Test
  func freshLegacyCustomWordMigrationRunsUnderTheBlockingLock() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    try JSONEncoder().encode([CustomWord(canonical: "LegacyTerm")]).write(to: url)
    let mgr = CustomWordsManager(fileURL: url)

    var acquisitionCount = 0
    var observedFlags: Int32?
    mgr.lockSyscall = { fd, flags in
      acquisitionCount += 1
      observedFlags = flags
      return flock(fd, flags)
    }

    let words = try #require(mgr.load())
    #expect(acquisitionCount == 1)
    #expect(observedFlags == LOCK_EX)
    #expect(words.contains { $0.canonical == "LegacyTerm" })
    #expect(mgr.lastLoadFailure == nil)

    let migrated = try Data(contentsOf: url)
    #expect(String(data: migrated, encoding: .utf8)?.contains("\"version\"") == true)

    var reloadLockSyscallCalled = false
    mgr.lockSyscall = { fd, flags in
      reloadLockSyscallCalled = true
      return flock(fd, flags)
    }
    let reloaded = try #require(mgr.load())
    #expect(reloadLockSyscallCalled == false)
    #expect(reloaded.contains { $0.canonical == "LegacyTerm" })
  }

  /// Closes the plan §11 fresh-migration member for the OTHER legacy format:
  /// a bare `[String]` array, including a blank entry the migration must
  /// discard.
  @Test
  func freshLegacyStringMigrationRunsUnderTheBlockingLock() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    try JSONEncoder().encode(["LegacyStringTerm", "  "]).write(to: url)
    let mgr = CustomWordsManager(fileURL: url)

    var acquisitionCount = 0
    var observedFlags: Int32?
    mgr.lockSyscall = { fd, flags in
      acquisitionCount += 1
      observedFlags = flags
      return flock(fd, flags)
    }

    let words = try #require(mgr.load())
    #expect(acquisitionCount == 1)
    #expect(observedFlags == LOCK_EX)
    #expect(words.contains { $0.canonical == "LegacyStringTerm" })
    #expect(words.contains { $0.canonical.isEmpty } == false)
    #expect(mgr.lastLoadFailure == nil)

    let migrated = try Data(contentsOf: url)
    #expect(String(data: migrated, encoding: .utf8)?.contains("\"version\"") == true)

    var reloadLockSyscallCalled = false
    mgr.lockSyscall = { fd, flags in
      reloadLockSyscallCalled = true
      return flock(fd, flags)
    }
    let reloaded = try #require(mgr.load())
    #expect(reloadLockSyscallCalled == false)
    #expect(reloaded.contains { $0.canonical == "LegacyStringTerm" })
  }

  /// Closes the plan §11 local-quarantine-success member under the blocking
  /// lock, mirroring the pre-#1690 behavior `CustomWordsPersistenceTests`
  /// already covers single-process, now proven under a real acquisition.
  @Test
  func localCorruptionQuarantineSucceedsUnderTheBlockingLock() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let garbage = Data("not valid json at all {{{".utf8)
    try garbage.write(to: url)
    let mgr = CustomWordsManager(fileURL: url)

    var acquisitionCount = 0
    var observedFlags: Int32?
    mgr.lockSyscall = { fd, flags in
      acquisitionCount += 1
      observedFlags = flags
      return flock(fd, flags)
    }

    let words = mgr.load()
    #expect(acquisitionCount == 1)
    #expect(observedFlags == LOCK_EX)
    #expect(words == nil)
    #expect(mgr.lastLoadFailure == .corrupted)
    #expect(FileManager.default.fileExists(atPath: url.path) == false)

    let sidecars =
      (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
      .filter { $0.contains(".corrupted-") } ?? []
    #expect(sidecars.count == 1)
    let sidecar = try #require(sidecars.first)
    let archived = try Data(contentsOf: dir.appendingPathComponent(sidecar))
    #expect(archived == garbage)
  }

  /// Closes the plan §11 local-quarantine-archive-failure member under the
  /// blocking lock. Pre-creates the companion lock while the directory is
  /// still writable — the same founder-authorized fixture pattern
  /// `CustomWordsPersistenceTests.corruptedArchiveFailureKeepsOriginalAndFailsClosedRepeatedly`
  /// uses — so this targets the archive `moveItem` failing, not lock
  /// creation itself failing.
  @Test
  func localQuarantineArchiveMovementFailureRemainsUnreadableUnderTheBlockingLock() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent("custom-words.json")
    let garbage = Data("not valid json at all {{{".utf8)
    try garbage.write(to: url)
    let mgr = CustomWordsManager(fileURL: url)

    let lockURL = url.appendingPathExtension("lock")
    let lockCreated = FileManager.default.createFile(
      atPath: lockURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    try #require(lockCreated)

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    var acquisitionCount = 0
    var observedFlags: Int32?
    mgr.lockSyscall = { fd, flags in
      acquisitionCount += 1
      observedFlags = flags
      return flock(fd, flags)
    }

    let words = mgr.load()
    #expect(acquisitionCount == 1)
    #expect(observedFlags == LOCK_EX)
    #expect(words == nil)
    #expect(mgr.lastLoadFailure == .unreadable)
    #expect(try Data(contentsOf: url) == garbage)

    let sidecars =
      (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
      .filter { $0.contains(".corrupted-") } ?? []
    #expect(sidecars.isEmpty)
  }

  // MARK: - Persistent structural source audit

  /// Freezes the single-lock-authority shape (#1690) so a future edit cannot
  /// silently reintroduce a second lock path, an unlocked write, or a stale
  /// helper name. Deliberately the ONE source-reading test for this file —
  /// every assertion is bounded to a specific parsed function body, not vague
  /// whole-file keyword presence.
  ///
  /// #4086 moved every disk touch into `CustomWordsFileStore`, verbatim. Whole-file
  /// counts now cover the manager AND the store together, so a second lock path or
  /// save helper cannot hide in either file; function-specific checks read each
  /// function at its actual owner. Both files are parsed with SwiftParser
  /// (swift-patterns.md RULE: scan-swift-source-with-swiftparser-never-a-hand-rolled-lexer).
  @Test
  func singleLockAuthorityStructureHoldsAcrossTheWholeFile() throws {
    let store = try CachedSwiftParser.snapshot(
      at: RepoRoot.sourceURL("Sources/EnviousWisprPostProcessing/CustomWordsFileStore.swift"))
    let manager = try CachedSwiftParser.snapshot(
      at: RepoRoot.sourceURL("Sources/EnviousWisprPostProcessing/CustomWordsManager.swift"))
    let trees = [store.tree, manager.tree]
    let both = trees.map { Syntax($0) }

    let load = try function(named: "load", in: manager.tree)
    // #1701 Chunk 2: the missing/loaded/unreadable/needsRepair cascade —
    // including load()'s blocking repair path — moved out of load() into
    // this shared helper, verbatim, so loadSnapshot() and
    // loadPendingEnrichmentWords() can reuse the identical resolution
    // without duplicating it. load() itself is now a thin two-line wrapper.
    let resolveCurrentFile = try function(named: "resolveCurrentFile", in: store.tree)
    let transaction = try function(named: "performLockedTransaction", in: store.tree)
    let loadFileWhileLocked = try function(named: "loadFileWhileLocked", in: store.tree)
    let saveFileWhileLocked = try function(named: "saveFileWhileLocked", in: store.tree)
    let commitImport = try function(named: "commitImport", in: manager.tree)

    // 1. Exactly one declaration of withExclusiveFileLock across both files.
    #expect(
      declarationCount(named: "withExclusiveFileLock", in: trees) == 1,
      "Expected exactly one withExclusiveFileLock declaration.")

    // 2. Exactly two code calls across both files: load()'s blocking
    // repair path and performLockedTransaction's non-blocking wrapper — no
    // third site hiding elsewhere.
    #expect(
      calls(named: "withExclusiveFileLock", in: both).count == 2,
      "Expected exactly two withExclusiveFileLock call sites across manager and store.")
    let repairLockCalls = calls(named: "withExclusiveFileLock", in: [Syntax(resolveCurrentFile)])
    #expect(
      repairLockCalls.count == 1,
      "resolveCurrentFile()'s repair path must call withExclusiveFileLock.")
    #expect(
      calls(named: "withExclusiveFileLock", in: [Syntax(transaction)]).count == 1,
      "performLockedTransaction must call withExclusiveFileLock.")

    // 3. resolveCurrentFile()'s shape — load() is just a wrapper delegating
    // to it (#1701 Chunk 2).
    #expect(calls(named: "loadFileReadOnly", in: [Syntax(resolveCurrentFile)]).count == 1)
    #expect(
      repairLockCalls.first.flatMap { argument(labeled: "blocking", of: $0) } == "true",
      "The repair path must take the lock blocking.")
    #expect(calls(named: "loadFileWhileLocked", in: [Syntax(resolveCurrentFile)]).count == 1)
    #expect(
      calls(named: "resolveCurrentFile", in: [Syntax(load)]).count == 1,
      "load() must delegate to resolveCurrentFile(), not inline the cascade.")

    // 4. performLockedTransaction's shape — the mutation loader and its sole
    // save call (already proven non-blocking by check 2 above).
    #expect(calls(named: "loadFileForMutationWhileLocked", in: [Syntax(transaction)]).count == 1)
    #expect(
      calls(named: "saveFileWhileLocked", in: [Syntax(transaction)]).count == 1,
      "performLockedTransaction must call saveFileWhileLocked exactly once.")

    // 5. Exactly three saveFileWhileLocked calls exist across both files:
    // the transaction wrapper, and the two legacy migrations.
    #expect(
      calls(named: "saveFileWhileLocked", in: both).count == 3,
      "Expected exactly three saveFileWhileLocked call sites across manager and store.")

    // 6. loadFileWhileLocked owns exactly two of those three save calls (the
    // legacy migrations) and the sole quarantine move.
    #expect(
      calls(named: "saveFileWhileLocked", in: [Syntax(loadFileWhileLocked)]).count == 2,
      "loadFileWhileLocked must call saveFileWhileLocked exactly twice.")
    #expect(
      quarantineMoves(in: [Syntax(loadFileWhileLocked)]) == 1,
      "loadFileWhileLocked must contain exactly one quarantine moveItem call.")

    // 7. Neither lock-free helper reacquires the lock.
    #expect(
      calls(named: "withExclusiveFileLock", in: [Syntax(loadFileWhileLocked)]).isEmpty,
      "loadFileWhileLocked must never call withExclusiveFileLock.")
    #expect(
      calls(named: "withExclusiveFileLock", in: [Syntax(saveFileWhileLocked)]).isEmpty,
      "saveFileWhileLocked must never call withExclusiveFileLock.")

    // 8. Exactly one quarantine move of fileURL exists across both files.
    #expect(
      quarantineMoves(in: both) == 1,
      "Expected exactly one quarantine moveItem(at: fileURL...) call across manager and store.")

    // 9. writePreImportBackup() has exactly one declaration and one call
    // across both files, and that call sits inside commitImport's locked
    // transaction — after entering performLockedTransaction, before the
    // transform hands back shouldSave: true.
    #expect(
      declarationCount(named: "writePreImportBackup", in: trees) == 1,
      "Expected exactly one writePreImportBackup declaration.")
    #expect(
      calls(named: "writePreImportBackup", in: both).count == 1,
      "Expected exactly one writePreImportBackup call across manager and store.")
    let transactionStart = try #require(
      calls(named: "performLockedTransaction", in: [Syntax(commitImport)]).first?.position,
      "commitImport must enter performLockedTransaction before creating its backup.")
    let backupCall = try #require(
      calls(named: "writePreImportBackup", in: [Syntax(commitImport)]).first?.position,
      "commitImport must call writePreImportBackup().")
    #expect(
      transactionStart < backupCall,
      "writePreImportBackup() must remain inside commitImport's transaction closure.")
    let shouldSaveTrue = try #require(
      returns(of: "((receipt, resulting), true)", in: commitImport).first?.position,
      "commitImport's transaction transform must return shouldSave: true on the changing-commit path."
    )
    #expect(
      backupCall < shouldSaveTrue,
      "writePreImportBackup() must run before the transform returns shouldSave: true.")

    // 10. The atomic-write shape is intact — at its OWNER.
    //
    // #628 moved the sequence out of `saveFileWhileLocked` into `DurableJSONFile`, verbatim,
    // when a second user-owned store needed the identical primitive. The guarantee this clause
    // protects did not change; the address did. So it now asserts BOTH halves: the save helper
    // delegates rather than growing its own write back, and the sequence still exists in one
    // place. Asserting only the delegation would let the shape rot in the file nothing else
    // checks, which is the failure mode extraction invites.
    #expect(
      calls(named: "write", in: [Syntax(saveFileWhileLocked)]).contains {
        $0.calledExpression.trimmedDescription == "DurableJSONFile.write"
      })
    #expect(
      calls(named: "open", in: [Syntax(saveFileWhileLocked)]).isEmpty,
      "The save helper must delegate the write, not carry a second copy of it.")

    let durable = try CachedSwiftParser.snapshot(
      at: RepoRoot.sourceURL("Sources/EnviousWisprCore/DurableJSONFile.swift"))
    let durableWrite = try function(
      named: "write", firstParameterLabel: "data", in: durable.tree)
    let durableCalls = Set(
      CallCollector.collect(in: [Syntax(durableWrite)]).map(\.calledExpression.trimmedDescription))
    #expect(durableCalls.contains("Foundation.open"))
    #expect(durableCalls.contains("Foundation.rename"))
    let durableTokens = Set(durableWrite.tokens(viewMode: .sourceAccurate).map { (token: TokenSyntax) in token.text })
    #expect(durableTokens.contains("O_EXCL"))
    #expect(durableTokens.contains("0o600"))
    #expect(durableTokens.contains("F_FULLFSYNC"))

    // 11. Neither removed helper name reappears in either file, as code or prose.
    for source in [store.source, manager.source] {
      let ns = source as NSString
      let bareLoadFile = try NSRegularExpression(pattern: #"\bloadFile\b"#)
      let bareSaveFile = try NSRegularExpression(pattern: #"\bsaveFile\b"#)
      #expect(
        bareLoadFile.numberOfMatches(in: source, range: NSRange(location: 0, length: ns.length))
          == 0,
        "The removed `loadFile` name must never reappear, in code or comments.")
      #expect(
        bareSaveFile.numberOfMatches(in: source, range: NSRange(location: 0, length: ns.length))
          == 0,
        "The removed `saveFile` name must never reappear, in code or comments.")
    }
  }
}

// MARK: - Parsed-source helpers for the structural audit

/// The single function named `name` (optionally with this first parameter label).
/// Zero or several matches fail the test rather than picking one.
private func function(
  named name: String, firstParameterLabel: String? = nil, in tree: SourceFileSyntax,
  sourceLocation: Testing.SourceLocation = #_sourceLocation
) throws -> FunctionDeclSyntax {
  let matches = FunctionCollector.collect(in: tree).filter { decl in
    guard decl.name.text == name else { return false }
    guard let firstParameterLabel else { return true }
    return decl.signature.parameterClause.parameters.first?.firstName.text == firstParameterLabel
  }
  return try #require(
    matches.count == 1 ? matches.first : nil,
    "Expected exactly one function named \(name), found \(matches.count)",
    sourceLocation: sourceLocation)
}

private func declarationCount(named name: String, in trees: [SourceFileSyntax]) -> Int {
  trees.flatMap { FunctionCollector.collect(in: $0) }.filter { $0.name.text == name }.count
}

/// Calls whose callee's final name is `name` (`name(...)`, `x.name(...)`).
private func calls(named name: String, in nodes: [Syntax]) -> [FunctionCallExprSyntax] {
  CallCollector.collect(in: nodes).filter { call in
    if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
      return ref.baseName.text == name
    }
    if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
      return member.declName.baseName.text == name
    }
    return false
  }
}

private func argument(labeled label: String, of call: FunctionCallExprSyntax) -> String? {
  call.arguments.first { $0.label?.text == label }?.expression.trimmedDescription
}

/// `FileManager.default.moveItem(at: fileURL, to: backup)` calls.
private func quarantineMoves(in nodes: [Syntax]) -> Int {
  calls(named: "moveItem", in: nodes).filter {
    $0.calledExpression.trimmedDescription == "FileManager.default.moveItem"
      && argument(labeled: "at", of: $0) == "fileURL"
      && argument(labeled: "to", of: $0) == "backup"
  }.count
}

private func returns(of expression: String, in node: some SyntaxProtocol) -> [ReturnStmtSyntax] {
  let collector = ReturnCollector(viewMode: .sourceAccurate)
  collector.walk(node)
  return collector.found.filter { $0.expression?.trimmedDescription == expression }
}

private final class FunctionCollector: SyntaxVisitor {
  private(set) var found: [FunctionDeclSyntax] = []
  static func collect(in tree: SourceFileSyntax) -> [FunctionDeclSyntax] {
    let collector = FunctionCollector(viewMode: .sourceAccurate)
    collector.walk(tree)
    return collector.found
  }
  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    found.append(node)
    return .visitChildren
  }
}

private final class CallCollector: SyntaxVisitor {
  private(set) var found: [FunctionCallExprSyntax] = []
  static func collect(in nodes: [Syntax]) -> [FunctionCallExprSyntax] {
    let collector = CallCollector(viewMode: .sourceAccurate)
    for node in nodes { collector.walk(node) }
    return collector.found
  }
  override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
    found.append(node)
    return .visitChildren
  }
}

private final class ReturnCollector: SyntaxVisitor {
  private(set) var found: [ReturnStmtSyntax] = []
  override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
    found.append(node)
    return .visitChildren
  }
}
