import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #1690 — the cross-process lock foundation. Explicit user
/// mutations acquire the companion `.lock` file NON-BLOCKING: on contention
/// (another process/descriptor holds it) they fail instantly with
/// `.libraryBusy` rather than freezing this `@MainActor` class, and a
/// non-contention `flock` failure maps to `.coordinationUnavailable`.
@MainActor
@Suite("CustomWordsManager — cross-process lock (#1690)")
struct CustomWordsManagerLockingTests {
  private static func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
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

  /// A local mirror of the production `CustomWordsFile` schema, needed
  /// because that type is `private` to `CustomWordsManager.swift` and not
  /// reachable even via `@testable import`. Field-for-field identical, so
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
    var producedFD: Int32?
    var observedFlags: Int32?
    mgr.lockSyscall = { fd, flags in
      producedFD = fd
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

    // The production descriptor was closed on the contention path too, not
    // just the injected-failure path.
    let producedFDValue = try #require(producedFD)
    errno = 0
    let producedFDStatus = fcntl(producedFDValue, F_GETFD)
    let producedFDErrno = errno
    #expect(producedFDStatus == -1)
    #expect(producedFDErrno == EBADF)

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

    // The real descriptor handed to the seam was still closed by
    // `withExclusiveFileLock`'s own `defer` — an injected acquisition
    // failure must not leak the fd. `fcntl(F_GETFD)` on a closed descriptor
    // fails with EBADF specifically, pinning down "closed" as the cause
    // rather than some other fcntl failure.
    #expect(seamFD >= 0)
    errno = 0
    let seamFDStatus = fcntl(seamFD, F_GETFD)
    let seamFDErrno = errno
    #expect(seamFDStatus == -1)
    #expect(seamFDErrno == EBADF)
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
    errno = 0
    let seamFDStatus = fcntl(seamFD, F_GETFD)
    let seamFDErrno = errno
    #expect(seamFDStatus == -1)
    #expect(seamFDErrno == EBADF)
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
    errno = 0
    let seamFDStatus = fcntl(seamFD, F_GETFD)
    let seamFDErrno = errno
    #expect(seamFDStatus == -1)
    #expect(seamFDErrno == EBADF)

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
  /// every assertion is bounded to a specific function-body slice via
  /// `functionBody(in:declaring:)`, not vague whole-file keyword presence.
  @Test
  func singleLockAuthorityStructureHoldsAcrossTheWholeFile() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(
        "Sources/EnviousWisprPostProcessing/CustomWordsManager.swift"),
      encoding: .utf8)

    let loadSlice = try functionBody(
      in: source, declaring: "public func load() -> [CustomWord]?")
    // #1701 Chunk 2: the missing/loaded/unreadable/needsRepair cascade —
    // including load()'s blocking repair path — moved out of load() into
    // this shared helper, verbatim, so loadSnapshot() and
    // loadPendingEnrichmentWords() can reuse the identical resolution
    // without duplicating it. load() itself is now a thin two-line wrapper.
    let resolveCurrentFileSlice = try functionBody(
      in: source, declaring: "private func resolveCurrentFile() -> CustomWordsFile?")
    let transactionSlice = try functionBody(
      in: source, declaring: "private func performLockedTransaction<T>(")
    let loadFileWhileLockedSlice = try functionBody(
      in: source, declaring: "private func loadFileWhileLocked() -> CustomWordsLoadResult")
    let saveFileWhileLockedSlice = try functionBody(
      in: source, declaring: "private func saveFileWhileLocked(_ file: CustomWordsFile) throws")
    let commitImportSlice = try functionBody(
      in: source, declaring: "package func commitImport(")

    // 1. Exactly one declaration of withExclusiveFileLock.
    #expect(
      source.components(separatedBy: "private func withExclusiveFileLock<T>(").count - 1 == 1,
      "Expected exactly one withExclusiveFileLock declaration.")

    // 2. Exactly two code calls anywhere in the file: load()'s blocking
    // repair path and performLockedTransaction's non-blocking wrapper — no
    // third site hiding elsewhere.
    #expect(
      source.components(separatedBy: "try withExclusiveFileLock").count - 1 == 2,
      "Expected exactly two `try withExclusiveFileLock` call sites in the whole file.")
    #expect(
      resolveCurrentFileSlice.contains("try withExclusiveFileLock"),
      "resolveCurrentFile()'s repair path must call withExclusiveFileLock.")
    #expect(
      transactionSlice.contains("try withExclusiveFileLock"),
      "performLockedTransaction must call withExclusiveFileLock.")

    // 3. resolveCurrentFile()'s slice shape — load()'s own slice is now just
    // a two-line wrapper delegating to it (#1701 Chunk 2).
    #expect(resolveCurrentFileSlice.contains("loadFileReadOnly()"))
    #expect(resolveCurrentFileSlice.contains("withExclusiveFileLock(blocking: true)"))
    #expect(resolveCurrentFileSlice.contains("loadFileWhileLocked()"))
    #expect(
      loadSlice.contains("resolveCurrentFile()"),
      "load() must delegate to resolveCurrentFile(), not inline the cascade.")

    // 4. performLockedTransaction's slice shape — the mutation loader and
    // its sole save call (already proven non-blocking by check 2 above).
    #expect(transactionSlice.contains("loadFileForMutationWhileLocked()"))
    let saveCallsInTransaction =
      transactionSlice.components(separatedBy: "saveFileWhileLocked(file)").count - 1
    #expect(
      saveCallsInTransaction == 1,
      "performLockedTransaction must call saveFileWhileLocked(file) exactly once.")

    // 5. Exactly three saveFileWhileLocked(file) calls exist anywhere in the
    // file: the transaction wrapper, and the two legacy migrations.
    #expect(
      source.components(separatedBy: "saveFileWhileLocked(file)").count - 1 == 3,
      "Expected exactly three saveFileWhileLocked(file) call sites in the whole file.")

    // 6. loadFileWhileLocked's slice owns exactly two of those three save
    // calls (the legacy migrations) and the sole quarantine move.
    let saveCallsInLoadFileWhileLocked =
      loadFileWhileLockedSlice.components(separatedBy: "saveFileWhileLocked(file)").count - 1
    #expect(
      saveCallsInLoadFileWhileLocked == 2,
      "loadFileWhileLocked must call saveFileWhileLocked(file) exactly twice.")
    let moveCallsInLoadFileWhileLocked =
      loadFileWhileLockedSlice.components(
        separatedBy: "FileManager.default.moveItem(at: fileURL, to: backup)"
      ).count - 1
    #expect(
      moveCallsInLoadFileWhileLocked == 1,
      "loadFileWhileLocked must contain exactly one quarantine moveItem call.")

    // 7. Neither lock-free helper reacquires the lock.
    #expect(
      loadFileWhileLockedSlice.contains("withExclusiveFileLock") == false,
      "loadFileWhileLocked must never call withExclusiveFileLock.")
    #expect(
      saveFileWhileLockedSlice.contains("withExclusiveFileLock") == false,
      "saveFileWhileLocked must never call withExclusiveFileLock.")

    // 8. Exactly one quarantine move targeting fileURL exists anywhere.
    #expect(
      source.components(
        separatedBy: "FileManager.default.moveItem(at: fileURL, to: backup)"
      ).count - 1 == 1,
      "Expected exactly one quarantine moveItem(at: fileURL...) call in the whole file.")

    // 9. writePreImportBackup() has exactly one declaration and one call
    // repo-wide, and that call sits inside commitImport's locked
    // transaction — after entering performLockedTransaction, before the
    // transform hands back shouldSave: true.
    #expect(
      source.components(separatedBy: "private func writePreImportBackup() {").count - 1 == 1,
      "Expected exactly one writePreImportBackup declaration.")
    #expect(
      source.components(separatedBy: "writePreImportBackup()").count - 1 == 2,
      "Expected exactly one writePreImportBackup declaration and one call repo-wide.")
    let transactionStartRange = try #require(
      commitImportSlice.range(of: "outcome = try performLockedTransaction"),
      "commitImport must enter performLockedTransaction before creating its backup.")
    let backupCallRange = try #require(
      commitImportSlice.range(of: "writePreImportBackup()"),
      "commitImport must call writePreImportBackup().")
    #expect(
      transactionStartRange.lowerBound < backupCallRange.lowerBound,
      "writePreImportBackup() must remain inside commitImport's transaction closure.")
    let shouldSaveTrueRange = try #require(
      commitImportSlice.range(of: "return ((receipt, resulting), true)"),
      "commitImport's transaction transform must return shouldSave: true on the changing-commit path."
    )
    #expect(
      backupCallRange.lowerBound < shouldSaveTrueRange.lowerBound,
      "writePreImportBackup() must run before the transform returns shouldSave: true.")

    // 10. The save helper's atomic-write shape is intact.
    #expect(saveFileWhileLockedSlice.contains("Foundation.open"))
    #expect(saveFileWhileLockedSlice.contains("O_EXCL"))
    #expect(saveFileWhileLockedSlice.contains("0o600"))
    #expect(saveFileWhileLockedSlice.contains("Foundation.rename"))

    // 11. Neither removed helper name reappears anywhere, as code or prose.
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

/// Brace-balanced extraction of a function body, anchored on its EXACT
/// declaration-line substring rather than the first inner brace — the same
/// technique `AppWindowCoordinatorCeilingsTests.classBodyOfAppWindowCoordinator`
/// uses for a class body, applied here to a function signature that may span
/// multiple lines before its opening brace.
private func functionBody(
  in source: String, declaring signature: String,
  sourceLocation: SourceLocation = #_sourceLocation
) throws -> String {
  let declRange = try #require(
    source.range(of: signature), "Declaration not found: \(signature)",
    sourceLocation: sourceLocation)
  let openIdx = try #require(
    source[declRange.upperBound...].firstIndex(of: "{"),
    "No opening brace found after declaration: \(signature)", sourceLocation: sourceLocation)
  var depth = 0
  var idx = openIdx
  while idx < source.endIndex {
    let c = source[idx]
    if c == "{" { depth += 1 }
    if c == "}" {
      depth -= 1
      if depth == 0 { return String(source[source.index(after: openIdx)..<idx]) }
    }
    idx = source.index(after: idx)
  }
  Issue.record("Unbalanced braces after declaration: \(signature)", sourceLocation: sourceLocation)
  throw POSIXError(.EILSEQ)
}
