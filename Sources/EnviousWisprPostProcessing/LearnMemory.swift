import EnviousWisprCore
import Foundation

// MARK: - Learn memory (#3975)
//
// What the Self-Learning Dictionary remembers about the user's fixes, per
// ordered correction pair (`CorrectionPairKey`), in its own file next to the
// dictionary: `learn-memory.json`. Two facts per pair:
//
// - the judge refused it on a finished edit (a later identical fix may then be
//   learned without asking the judge again), and
// - how many times the user said no to it (Undo, deleting the learned word,
//   removing the learned sound-alike); the second no blocks the pair for good.
//
// It is not part of the dictionary: the memory must outlive a deleted word,
// and keeping it out of `custom-words.json` leaves the dictionary's
// transactions, backups, imports and exports exactly as they were.
//
// Concurrency: one main-actor owner per process. Every mutation takes the
// store's companion-file lock, RELOADS the file, applies the one event and
// writes, so a second app instance (dev and release side by side) never loses
// the other's committed change. A busy lock or a failed write returns
// `.notRemembered`: the event is dropped, never queued or replayed, so a Forget
// in one instance can never be resurrected by another. A dropped event only
// means the app behaves for it exactly as it did before #3975.
//
// Reads are fresh: before each answer the memory compares the file's identity,
// size and modification date with what it last read and reloads only on a
// change.

/// The result of a mutation that may not be remembered.
package enum LearnMemoryMutation<Value: Equatable & Sendable>: Equatable, Sendable {
  case committed(Value)
  /// The lock was busy, the write failed, or a cap refused the event. Nothing
  /// changed on disk or in memory.
  case notRemembered
}

/// What a user "no" did to its pair.
package enum LearnUserNoResult: String, Equatable, Sendable {
  /// First no: remembered, the pair may still be learned again.
  case watching
  /// Second no: the pair is never learned again until the memory is forgotten.
  case blocked
}

/// Text-free signals for diagnostics; production forwards them to the debug
/// log and a breadcrumb (wiring), tests read them directly.
package enum LearnMemoryDiagnostic: Equatable, Sendable {
  /// An unreadable or wrong-version file was set aside; the memory restarted
  /// empty.
  case memoryReset
  case notRemembered(Reason)

  package enum Reason: String, Equatable, Sendable {
    case lockBusy
    case lockUnavailable
    case writeFailed
    case blockCap
  }
}

@MainActor
package final class LearnMemory {

  /// Entries without a block that may be kept; past this the oldest go first.
  package static let unblockedCap = 2_000
  /// Blocks are deliberate user acts and are never evicted or expired; past
  /// this a new block is refused (`.notRemembered`).
  package static let blockedCap = 10_000
  /// An unblocked entry unseen for this long is dropped.
  package static let unblockedLifetime: TimeInterval = 90 * 24 * 60 * 60
  package static let currentVersion = 1
  package static let fileName = "learn-memory.json"
  static let corruptedMarker = ".corrupted-"

  package struct Entry: Codable, Equatable, Sendable {
    package var judgeRefusals: Int
    package var userNos: Int
    package var blocked: Bool
    package var lastSeen: Date
  }

  private struct StoreFile: Codable {
    var version: Int
    var pairs: [String: Entry]
  }

  /// What was on disk at the last read: absent, or a file with this identity.
  private enum Stamp: Equatable {
    case absent
    case file(fileNumber: Int, size: Int, modified: Date)
  }

  package let fileURL: URL
  private let now: () -> Date
  private let lockSyscall: (Int32, Int32) -> Int32
  private let report: (LearnMemoryDiagnostic) -> Void
  private var pairs: [String: Entry] = [:]
  /// The identity of the file `pairs` was read from; nil means "read again".
  private var stamp: Stamp?
  /// Test seam: runs after a read and before the file is stat-ed again, so a
  /// test can commit from another instance in exactly that window.
  var afterReadForTesting: (() -> Void)?

  /// - Parameters:
  ///   - lockSyscall: test seam for the companion-file lock; production
  ///     passes the real `flock`.
  package init(
    fileURL: URL,
    now: @escaping () -> Date = Date.init,
    lockSyscall: @escaping (Int32, Int32) -> Int32 = { flock($0, $1) },
    report: @escaping (LearnMemoryDiagnostic) -> Void = { _ in }
  ) {
    self.fileURL = fileURL
    self.now = now
    self.lockSyscall = lockSyscall
    self.report = report
    DurableJSONFile.prepareDirectory(at: fileURL.deletingLastPathComponent())
    DurableJSONFile.tightenFileIfPresent(at: fileURL)
  }

  /// The production store, in the same Application Support folder as the
  /// dictionary (`CustomWordsManager.liveFileURL`).
  package static var liveFileURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("EnviousWispr", isDirectory: true)
      .appendingPathComponent(fileName)
  }

  // MARK: Reads

  /// The judge refused this pair on a finished edit, and the user has not
  /// blocked it.
  package func isRepeat(_ pairKey: String) -> Bool {
    refreshIfChanged()
    guard let entry = pairs[pairKey] else { return false }
    return entry.judgeRefusals >= 1 && !entry.blocked
  }

  package func isBlocked(_ pairKey: String) -> Bool {
    refreshIfChanged()
    return pairs[pairKey]?.blocked ?? false
  }

  package var blockedKeys: Set<String> {
    refreshIfChanged()
    return Set(pairs.filter { $0.value.blocked }.keys)
  }

  package var blockedCount: Int {
    refreshIfChanged()
    return pairs.values.filter(\.blocked).count
  }

  /// Something is stored that "Forget learning memory" would delete: entries,
  /// or a corrupt copy set aside earlier.
  package var hasStoredMemory: Bool {
    refreshIfChanged()
    // A folder that cannot be listed may still hold a copy: show the control.
    return !pairs.isEmpty || ((try? corruptedCopies()).map { !$0.isEmpty } ?? true)
  }

  package func entry(_ pairKey: String) -> Entry? {
    refreshIfChanged()
    return pairs[pairKey]
  }

  // MARK: Mutations

  /// The judge refused this pair on a finished (strong) edit.
  @discardableResult
  package func recordJudgeRefusal(_ pairKey: String) -> LearnMemoryMutation<Bool> {
    let at = now()
    return transact { pairs in
      var entry =
        pairs[pairKey] ?? Entry(judgeRefusals: 0, userNos: 0, blocked: false, lastSeen: at)
      entry.judgeRefusals = 1
      entry.lastSeen = at
      pairs[pairKey] = entry
      return true
    }
  }

  /// One user "no" for this pair (Undo, deleting the learned word, removing
  /// the learned sound-alike). The second blocks it.
  @discardableResult
  package func recordUndo(_ pairKey: String) -> LearnMemoryMutation<LearnUserNoResult> {
    let at = now()
    return transact { pairs in
      var entry =
        pairs[pairKey] ?? Entry(judgeRefusals: 0, userNos: 0, blocked: false, lastSeen: at)
      if entry.blocked { return .blocked }
      entry.userNos += 1
      entry.lastSeen = at
      if entry.userNos >= 2 {
        guard pairs.values.filter(\.blocked).count < Self.blockedCap else {
          report(.notRemembered(.blockCap))
          return nil
        }
        entry.blocked = true
      }
      pairs[pairKey] = entry
      return entry.blocked ? .blocked : .watching
    }
  }

  /// Deletes the memory file and every corrupt copy. True only when the file
  /// and every copy are proven gone; any failure leaves the state to be read
  /// again.
  @discardableResult
  package func forgetAll() -> Bool {
    do {
      return try DurableJSONFile.withExclusiveLock(on: fileURL, lockSyscall: lockSyscall) {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
          try fm.removeItem(at: fileURL)
        }
        for copy in try corruptedCopies() { try fm.removeItem(at: copy) }
        guard !fm.fileExists(atPath: fileURL.path), try corruptedCopies().isEmpty else {
          stamp = nil
          return false
        }
        pairs = [:]
        stamp = .absent
        return true
      }
    } catch {
      stamp = nil
      return false
    }
  }

  // MARK: Transaction

  /// Lock, reload, prune, apply, write; publish only after the write landed.
  /// `apply` returns nil to refuse the event (a cap).
  private func transact<T: Equatable & Sendable>(
    _ apply: (inout [String: Entry]) -> T?
  ) -> LearnMemoryMutation<T> {
    do {
      return try DurableJSONFile.withExclusiveLock(on: fileURL, lockSyscall: lockSyscall) {
        var fresh = loadWhileLocked()
        guard let value = apply(&fresh) else { return .notRemembered }
        Self.prune(&fresh, now: now())
        do {
          let data = try Self.encoder().encode(
            StoreFile(version: Self.currentVersion, pairs: fresh))
          try DurableJSONFile.write(data: data, to: fileURL, tempPrefix: ".learn-memory")
        } catch {
          report(.notRemembered(.writeFailed))
          stamp = nil
          return .notRemembered
        }
        pairs = fresh
        stamp = currentStamp()
        return .committed(value)
      }
    } catch DurableJSONFile.LockFailure.busy {
      report(.notRemembered(.lockBusy))
      return .notRemembered
    } catch {
      report(.notRemembered(.lockUnavailable))
      return .notRemembered
    }
  }

  // MARK: Loading

  /// Reloads when the file changed. The stamp kept is the one taken BEFORE
  /// the read, and the read counts only if the file still has that stamp
  /// after it: a commit from another instance in between makes the read
  /// stale, so it is read again (a few times, then left for the next call).
  private func refreshIfChanged() {
    for _ in 0..<3 {
      let before = currentStamp()
      guard before != stamp else { return }
      let result = read()
      afterReadForTesting?()
      guard currentStamp() == before else { continue }
      switch result {
      case .absent:
        pairs = [:]
        stamp = before
      case .loaded(var loaded):
        Self.prune(&loaded, now: now())
        pairs = loaded
        stamp = before
      case .unreadable:
        refreshUnreadableUnderLock()
      }
      return
    }
    stamp = nil
  }

  /// The file read as unreadable: decide again under the lock, where no other
  /// instance can replace it, and set it aside only if it is still unreadable.
  private func refreshUnreadableUnderLock() {
    do {
      try DurableJSONFile.withExclusiveLock(on: fileURL, lockSyscall: lockSyscall) {
        pairs = loadWhileLocked()
        stamp = currentStamp()
      }
    } catch {
      // Busy: no valid memory can be read now; the next call tries again.
      pairs = [:]
      stamp = nil
    }
  }

  /// Caller holds the lock.
  private func loadWhileLocked() -> [String: Entry] {
    switch read() {
    case .absent: return [:]
    case .loaded(var loaded):
      Self.prune(&loaded, now: now())
      return loaded
    case .unreadable:
      moveAsideCorrupt()
      report(.memoryReset)
      return [:]
    }
  }

  private enum ReadResult {
    case absent
    case loaded([String: Entry])
    case unreadable
  }

  private func read() -> ReadResult {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return .absent }
    guard let data = try? Data(contentsOf: fileURL),
      let file = try? Self.decoder().decode(StoreFile.self, from: data),
      file.version == Self.currentVersion
    else { return .unreadable }
    return .loaded(file.pairs)
  }

  /// Keeps at most one corrupt copy: older copies go before the new one is set
  /// aside.
  private func moveAsideCorrupt() {
    let fm = FileManager.default
    for copy in (try? corruptedCopies()) ?? [] { try? fm.removeItem(at: copy) }
    let aside = fileURL.deletingLastPathComponent()
      .appendingPathComponent(Self.fileName + Self.corruptedMarker + UUID().uuidString)
    try? fm.moveItem(at: fileURL, to: aside)
  }

  /// Throws when the folder cannot be listed: "could not look" is never "none".
  package func corruptedCopies() throws -> [URL] {
    let dir = fileURL.deletingLastPathComponent()
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    return names.filter { $0.hasPrefix(Self.fileName + Self.corruptedMarker) }
      .map { dir.appendingPathComponent($0) }
  }

  private func currentStamp() -> Stamp {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
      return .absent
    }
    return .file(
      fileNumber: (attrs[.systemFileNumber] as? NSNumber)?.intValue ?? -1,
      size: (attrs[.size] as? NSNumber)?.intValue ?? -1,
      modified: attrs[.modificationDate] as? Date ?? .distantPast)
  }

  // MARK: Format

  /// Dates are ISO 8601 (plan §3.1 schema), whole seconds.
  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  // MARK: Bounds

  /// Drops unblocked entries unseen for `unblockedLifetime`, then the oldest
  /// unblocked entries past `unblockedCap`. Blocks are never touched.
  static func prune(_ pairs: inout [String: Entry], now: Date) {
    let cutoff = now.addingTimeInterval(-unblockedLifetime)
    pairs = pairs.filter { $0.value.blocked || $0.value.lastSeen >= cutoff }
    let unblocked = pairs.filter { !$0.value.blocked }
    guard unblocked.count > unblockedCap else { return }
    let oldest = unblocked.sorted { $0.value.lastSeen < $1.value.lastSeen }
      .prefix(unblocked.count - unblockedCap)
    for (key, _) in oldest { pairs[key] = nil }
  }
}
