import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #996 chunk 5a: the ledger is what makes a proposal survive a quit, what
/// keeps a rejected pair rejected, and what stops a half-written file from
/// being read as "nothing to remember". Every case asserts the persisted
/// outcome on disk, not merely that a helper was called.
/// Class: `.productOutcome`.
@Suite(.tags(.productOutcome)) struct CorrectionProposalStoreTests {

  private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-proposals-\(UUID().uuidString)", isDirectory: true)
    return dir
  }

  private func proposal(_ o: String, _ c: String, at time: Date = t0) -> CorrectionProposal {
    CorrectionProposal(
      original: o, corrected: c, state: .newWord, language: "en", contextExcerpt: "ctx",
      sourceBundleID: "com.example.app", createdAt: time, advisorySafeAlias: nil)
  }

  private func readLedger(_ url: URL) throws -> CorrectionProposalLedger {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return try d.decode(CorrectionProposalLedger.self, from: Data(contentsOf: url))
  }

  private func permissions(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
  }

  // MARK: - Load classification

  @Test("an absent file is the only `empty`; it becomes a trusted empty ledger")
  func absentFileIsEmpty() throws {
    let store = CorrectionProposalStore(directory: tempDir())
    #expect(store.load() == .empty)
    #expect(store.ledger == .empty)
    #expect(store.isTrusted)
  }

  @Test("an unreadable file is untrusted and every write is refused")
  func unreadableIsUntrusted() throws {
    let dir = tempDir()
    let store = CorrectionProposalStore(directory: dir)
    #expect(store.load() == .empty)
    try store.upsert(proposal("Sarah", "Saira"))
    var ops = CorrectionProposalStore.FileOps.live
    ops.read = { _ in throw CocoaError(.fileReadNoPermission) }
    let blind = CorrectionProposalStore(directory: dir, fileOps: ops)
    #expect(blind.load() == .untrusted(kind: .unreadable, archivedTo: nil))
    #expect(blind.isTrusted == false)
    #expect(throws: CorrectionProposalStoreError.ledgerUntrusted) {
      try blind.upsert(proposal("a", "b"))
    }
    // The good file on disk is untouched by the refusal.
    #expect(try readLedger(store.fileURL).proposals.count == 1)
  }

  @Test(
    "corrupt, unsupported-version and unknown-status files are untrusted, archived, kept in place, and untrusted again next launch"
  )
  func untrustedFilesAreArchivedAndStayUntrusted() throws {
    let cases: [(String, CorrectionLedgerUntrustedKind)] = [
      ("{not json", .corrupt),
      (#"{"version":2,"proposals":[],"rejectedPairs":[]}"#, .unsupportedVersion),
      (#"{"proposals":[],"rejectedPairs":[]}"#, .corrupt),
      (
        #"{"version":1,"rejectedPairs":[],"proposals":[{"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","pairKey":"v1:[\"a\",\"b\"]","original":"a","corrected":"b","state":{"kind":"newWord"},"status":"paused","overlayAttempted":false,"createdAt":"2027-01-15T00:00:00Z","updatedAt":"2027-01-15T00:00:00Z"}]}"#,
        .unknownStatus
      ),
    ]
    for (text, kind) in cases {
      let dir = tempDir()
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let file = dir.appendingPathComponent(CorrectionProposalStore.fileName)
      try Data(text.utf8).write(to: file)
      let store = CorrectionProposalStore(directory: dir, now: { Self.t0 })
      let outcome = store.load()
      guard case .untrusted(let gotKind, let archived) = outcome else {
        Issue.record("expected untrusted for \(kind), got \(outcome)")
        continue
      }
      #expect(gotKind == kind, "\(text)")
      let archive = try #require(archived, "\(text)")
      #expect(
        try Data(contentsOf: archive) == Data(text.utf8), "archive is the evidence, byte for byte")
      #expect(try permissions(archive) == 0o600)
      #expect(try Data(contentsOf: file) == Data(text.utf8), "the original stays in place")
      #expect(throws: CorrectionProposalStoreError.ledgerUntrusted) {
        try store.upsert(proposal("a", "b"))
      }
      #expect(throws: CorrectionProposalStoreError.ledgerUntrusted) {
        try store.prune(now: Self.t0)
      }
      // Next launch: same verdict, and the earlier archive is not overwritten.
      let relaunch = CorrectionProposalStore(
        directory: dir, now: { Self.t0.addingTimeInterval(60) })
      guard case .untrusted(let again, let archived2) = relaunch.load() else {
        Issue.record("relaunch read the untrusted file as trusted or empty")
        continue
      }
      #expect(again == kind)
      #expect(archived2 != nil && archived2 != archive)
    }
  }

  @Test("only a confirmed missing file is `empty`; a path that cannot be inspected is untrusted")
  func absenceIsConfirmedNotAssumed() throws {
    let dir = tempDir()
    var ops = CorrectionProposalStore.FileOps.live
    ops.read = { _ in throw CocoaError(.fileReadNoPermission) }
    let blocked = CorrectionProposalStore(directory: dir, fileOps: ops)
    #expect(blocked.load() == .untrusted(kind: .unreadable, archivedTo: nil))
    #expect(throws: CorrectionProposalStoreError.ledgerUntrusted) { try blocked.upsert(proposal("a", "b")) }
    var posix = CorrectionProposalStore.FileOps.live
    posix.read = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
    #expect(CorrectionProposalStore(directory: dir, fileOps: posix).load() == .untrusted(kind: .unreadable, archivedTo: nil))
    var missing = CorrectionProposalStore.FileOps.live
    missing.read = { _ in throw CocoaError(.fileReadNoSuchFile) }
    #expect(CorrectionProposalStore(directory: dir, fileOps: missing).load() == .empty)
    var enoent = CorrectionProposalStore.FileOps.live
    enoent.read = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
    #expect(CorrectionProposalStore(directory: dir, fileOps: enoent).load() == .empty)
  }

  @Test("a decodable document that breaks the ledger's own invariants is corrupt, not trusted")
  func inconsistentDocumentsAreCorrupt() throws {
    let base = #"{"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","pairKey":"v1:[\"a\",\"b\"]","original":"a","corrected":"b","state":{"kind":"newWord"},"status":"pending","overlayAttempted":false,"createdAt":"2027-01-15T00:00:00Z","updatedAt":"2027-01-15T00:00:00Z"}"#
    let cases: [(String, String, String)] = [
      ("pairKey unrelated to its strings", base.replacingOccurrences(of: #""original":"a""#, with: #""original":"zzz""#), "pairKey does not match"),
      ("duplicate ids", base + "," + base, "duplicate proposal id"),
      ("accepting without an intent", base.replacingOccurrences(of: #""status":"pending""#, with: #""status":"accepting""#), "accepting without an intent"),
      ("terminal without resolvedAt", base.replacingOccurrences(of: #""status":"pending""#, with: #""status":"accepted""#), "terminal without resolvedAt"),
    ]
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    // Control: the base document is well-formed JSON, decodes, and is consistent.
    let baseDoc = #"{"version":1,"rejectedPairs":[],"proposals":[\#(base)]}"#
    #expect(try decoder.decode(CorrectionProposalLedger.self, from: Data(baseDoc.utf8)).validationProblems() == [])
    for (name, rows, expectedProblem) in cases {
      let text = #"{"version":1,"rejectedPairs":[],"proposals":[\#(rows)]}"#
      // The fixture must reach the invariant boundary: it DECODES, and the
      // authority names the defect. A parse failure here would test nothing.
      let decoded = try decoder.decode(CorrectionProposalLedger.self, from: Data(text.utf8))
      let problems = decoded.validationProblems()
      #expect(problems.count == 1 && problems[0].contains(expectedProblem), "\(name): \(problems)")
      let dir = tempDir()
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try Data(text.utf8).write(to: dir.appendingPathComponent(CorrectionProposalStore.fileName))
      let store = CorrectionProposalStore(directory: dir)
      guard case .untrusted(let kind, let archived) = store.load() else {
        Issue.record("\(name): read as trusted")
        continue
      }
      #expect(kind == .corrupt, "\(name)")
      #expect(archived != nil, "\(name)")
    }
    // The same authority guards the write side: an in-memory record that
    // breaks an invariant is refused before any byte is written.
    let store = CorrectionProposalStore(directory: tempDir())
    _ = store.load()
    var bad = proposal("a", "b")
    bad.status = .accepting
    #expect(throws: CorrectionProposalStoreError.invalidLedger(["proposal \(bad.id): accepting without an intent"])) {
      try store.upsert(bad)
    }
    #expect(FileManager.default.fileExists(atPath: store.fileURL.path) == false)
  }

  @Test("a write before any load is refused")
  func writeBeforeLoadIsRefused() {
    let store = CorrectionProposalStore(directory: tempDir())
    #expect(throws: CorrectionProposalStoreError.notLoaded) { try store.upsert(proposal("a", "b")) }
  }

  // MARK: - Durable writes

  @Test("upsert lands on disk with owner-only permissions and reloads identically")
  func upsertPersists() throws {
    let dir = tempDir()
    let store = CorrectionProposalStore(directory: dir)
    #expect(store.load() == .empty)
    var p = proposal("Sarah", "Saira")
    try store.upsert(p)
    #expect(try permissions(store.fileURL) == 0o600)
    #expect(try readLedger(store.fileURL).proposals == [p])
    p.overlayAttempted = true
    p.status = .accepting
    p.acceptingIntent = CorrectionAcceptingIntent(pairKey: p.pairKey, operation: .createWord, targetWordID: UUID())
    try store.upsert(p)
    #expect(try readLedger(store.fileURL).proposals == [p], "replacement by id, not a second row")
    let reloaded = CorrectionProposalStore(directory: dir)
    #expect(reloaded.load() == .trusted(CorrectionProposalLedger(proposals: [p])))
    // Temp files never linger.
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter {
      $0.hasSuffix(".tmp")
    }
    #expect(leftovers.isEmpty)
  }

  @Test("an upsert that changes an existing record's pairKey is refused")
  func pairKeyIsImmutable() throws {
    let store = CorrectionProposalStore(directory: tempDir())
    _ = store.load()
    let p = proposal("Sarah", "Saira")
    try store.upsert(p)
    let impostor = CorrectionProposal(
      id: p.id, original: "Bob", corrected: "Rob", state: .newWord, language: "en",
      contextExcerpt: nil,
      sourceBundleID: nil, createdAt: Self.t0, advisorySafeAlias: nil)
    #expect(throws: CorrectionProposalStoreError.unknownProposal(p.id)) {
      try store.upsert(impostor)
    }
    #expect(try readLedger(store.fileURL).proposals == [p])
  }

  @Test("a temp-stage failure changes nothing; a commit or sync failure locks the ledger until it is re-read and made durable")
  func writeStageFailures() throws {
    enum Stage: CaseIterable { case temp, commit, sync }
    for stage in Stage.allCases {
      let dir = tempDir()
      var ops = CorrectionProposalStore.FileOps.live
      let store0 = CorrectionProposalStore(directory: dir)
      #expect(store0.load() == .empty)
      let first = proposal("Sarah", "Saira")
      try store0.upsert(first)
      let bytesBefore = try Data(contentsOf: store0.fileURL)
      switch stage {
      case .temp: ops.writeTemp = { _, _ in throw CorrectionProposalStoreError.tempWriteFailed(28) }
      case .commit: ops.commit = { _, _ in throw CocoaError(.fileWriteNoPermission) }
      case .sync: ops.syncDirectory = { _ in throw CorrectionProposalStoreError.directorySyncFailed(5) }
      }
      let store = CorrectionProposalStore(directory: dir, fileOps: ops)
      #expect(store.load() == .trusted(CorrectionProposalLedger(proposals: [first])))
      let expectedError: CorrectionProposalStoreError
      switch stage {
      case .temp: expectedError = .tempWriteFailed(28)
      case .commit: expectedError = .commitFailed
      case .sync: expectedError = .directorySyncFailed(5)
      }
      #expect(throws: expectedError, "\(stage)") { try store.upsert(proposal("Bob", "Rob")) }
      let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
      #expect(leftovers.isEmpty, "temp cleaned after \(stage)")
      switch stage {
      case .temp:
        #expect(store.ledger == CorrectionProposalLedger(proposals: [first]), "memory unchanged")
        #expect(try Data(contentsOf: store.fileURL) == bytesBefore, "disk unchanged")
        // Still writable: the same store with the temp stage repaired.
        let repaired = CorrectionProposalStore(directory: dir)
        #expect(repaired.load() == .trusted(CorrectionProposalLedger(proposals: [first])))
        try repaired.upsert(proposal("Cid", "Sid"))
      case .commit, .sync:
        // Past the commit point memory may no longer describe disk: every
        // mutation is refused until a re-read confirms what landed.
        #expect(store.ledger == nil)
        #expect(throws: CorrectionProposalStoreError.recoveryRequired, "\(stage)") { try store.upsert(proposal("Cid", "Sid")) }
        #expect(throws: CorrectionProposalStoreError.recoveryRequired, "\(stage)") { try store.reject(id: first.id, at: Self.t0) }
        #expect(throws: CorrectionProposalStoreError.recoveryRequired, "\(stage)") { try store.prune(now: Self.t0) }
        if stage == .sync {
          // Recovery must re-establish durability with the SAME failing sync: refused again.
          #expect(store.load() == .untrusted(kind: .durabilityUnconfirmed, archivedTo: nil))
          // Still in recovery: the caller must load() again once the disk cooperates.
          #expect(throws: CorrectionProposalStoreError.recoveryRequired) {
            try store.upsert(proposal("Cid", "Sid"))
          }
        }
        // A fresh instance (relaunch) reads what actually landed.
        let repaired = CorrectionProposalStore(directory: dir)
        let recovered = repaired.load()
        guard case .trusted(let ledger) = recovered else {
          Issue.record("relaunch did not trust the on-disk ledger after \(stage): \(recovered)")
          continue
        }
        let expectedCount = stage == .sync ? 2 : 1  // sync: the replacement landed; commit (threw before replacing): it did not
        #expect(ledger.proposals.count == expectedCount, "\(stage)")
        #expect(ledger.proposals.first == first)
        try repaired.upsert(proposal("Cid", "Sid"))
      }
    }
  }

  @Test("the SAME instance recovers only through a re-read that syncs; a read failure in between keeps the obligation")
  func sameInstanceRecoveryKeepsTheObligation() throws {
    let dir = tempDir()
    let faults = FaultBox()
    var ops = CorrectionProposalStore.FileOps.live
    let liveRead = ops.read
    let liveSync = ops.syncDirectory
    ops.read = { url in
      if faults.failRead { throw CocoaError(.fileReadNoPermission) }
      return try liveRead(url)
    }
    ops.syncDirectory = { url in
      if faults.failSync { throw CorrectionProposalStoreError.directorySyncFailed(5) }
      try liveSync(url)
    }
    let store = CorrectionProposalStore(directory: dir, fileOps: ops)
    #expect(store.load() == .empty)
    let first = proposal("Sarah", "Saira")
    try store.upsert(first)
    faults.failSync = true
    #expect(throws: CorrectionProposalStoreError.directorySyncFailed(5)) { try store.upsert(proposal("Bob", "Rob")) }
    #expect(throws: CorrectionProposalStoreError.recoveryRequired) { try store.upsert(proposal("Cid", "Sid")) }
    // A temporary read failure during recovery must NOT clear the obligation.
    faults.failRead = true
    #expect(store.load() == .untrusted(kind: .unreadable, archivedTo: nil))
    faults.failRead = false
    // Readable again, sync still failing: refused again, still in recovery.
    #expect(store.load() == .untrusted(kind: .durabilityUnconfirmed, archivedTo: nil))
    #expect(throws: CorrectionProposalStoreError.recoveryRequired) { try store.upsert(proposal("Cid", "Sid")) }
    // Repair the sync: the same instance recovers with what landed (both rows).
    faults.failSync = false
    guard case .trusted(let ledger) = store.load() else {
      Issue.record("same-instance recovery failed")
      return
    }
    #expect(ledger.proposals.count == 2)
    try store.upsert(proposal("Cid", "Sid"))
    #expect(try readLedger(store.fileURL).proposals.count == 3)
    // Confirmed absence during recovery also needs the sync before trust.
    let dir2 = tempDir()
    let faults2 = FaultBox()
    var ops2 = CorrectionProposalStore.FileOps.live
    let liveRead2 = ops2.read
    ops2.read = { url in
      if faults2.failRead { throw CocoaError(.fileReadNoSuchFile) }
      return try liveRead2(url)
    }
    ops2.syncDirectory = { _ in if faults2.failSync { throw CorrectionProposalStoreError.directorySyncFailed(5) } }
    ops2.commit = { _, _ in throw CocoaError(.fileWriteNoPermission) }
    let store2 = CorrectionProposalStore(directory: dir2, fileOps: ops2)
    #expect(store2.load() == .empty)
    #expect(throws: CorrectionProposalStoreError.commitFailed) { try store2.upsert(first) }
    faults2.failRead = true  // the file reads as absent while recovering
    faults2.failSync = true
    #expect(store2.load() == .untrusted(kind: .durabilityUnconfirmed, archivedTo: nil))
    #expect(throws: CorrectionProposalStoreError.recoveryRequired) { try store2.upsert(first) }
    faults2.failSync = false
    #expect(store2.load() == .empty)
    #expect(store2.isTrusted)
  }

  @Test("a Reject whose directory sync fails keeps its tombstone through recovery and refuses unrelated writes meanwhile")
  func failedSyncRejectPreservesTombstone() throws {
    let dir = tempDir()
    var ops = CorrectionProposalStore.FileOps.live
    ops.syncDirectory = { _ in throw CorrectionProposalStoreError.directorySyncFailed(5) }
    let good = CorrectionProposalStore(directory: dir)
    _ = good.load()
    let p = proposal("Sarah", "Saira")
    let other = proposal("Bob", "Rob")
    try good.upsert(p)
    try good.upsert(other)
    let flaky = CorrectionProposalStore(directory: dir, fileOps: ops)
    _ = flaky.load()
    #expect(throws: CorrectionProposalStoreError.directorySyncFailed(5)) { try flaky.reject(id: p.id, at: Self.t0) }
    // The unrelated write that would have overwritten the tombstone from stale memory is refused.
    #expect(throws: CorrectionProposalStoreError.recoveryRequired) { try flaky.upsert(other) }
    let recovered = CorrectionProposalStore(directory: dir)
    guard case .trusted(let ledger) = recovered.load() else {
      Issue.record("recovery failed")
      return
    }
    #expect(ledger.isRejected(pairKey: p.pairKey))
    #expect(ledger.proposal(id: p.id)?.status == .rejected)
    try recovered.upsert(other)
    #expect(try readLedger(recovered.fileURL).isRejected(pairKey: p.pairKey), "the tombstone survives the next write")
  }

  // MARK: - Reject and prune

  @Test("reject writes the tombstone and the rejected status in ONE replacement")
  func rejectIsAtomic() throws {
    let dir = tempDir()
    var writes: [Data] = []
    var ops = CorrectionProposalStore.FileOps.live
    let liveWrite = ops.writeTemp
    let box = WriteBox()
    ops.writeTemp = { url, data in
      box.append(data)
      try liveWrite(url, data)
    }
    let store = CorrectionProposalStore(directory: dir, fileOps: ops)
    _ = store.load()
    let p = proposal("Sarah", "Saira")
    try store.upsert(p)
    let when = Self.t0.addingTimeInterval(10)
    try store.reject(id: p.id, at: when)
    writes = box.data
    #expect(writes.count == 2, "one write for the upsert, ONE for the reject")
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    let afterReject = try d.decode(CorrectionProposalLedger.self, from: writes[1])
    #expect(afterReject.proposals[0].status == .rejected)
    #expect(afterReject.proposals[0].resolvedAt == when)
    #expect(
      afterReject.rejectedPairs == [
        CorrectionRejectedPair(pairKey: p.pairKey, rejectedAt: when, language: "en")
      ])
    #expect(try readLedger(store.fileURL) == afterReject)
    #expect(
      throws: CorrectionProposalStoreError.unknownProposal(
        UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!)
    ) {
      try store.reject(id: UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!, at: when)
    }
  }

  @Test(
    "prune drops only terminal payloads thirty days after resolution; pending, accepting and tombstones stay"
  )
  func pruneBoundaries() throws {
    let store = CorrectionProposalStore(directory: tempDir())
    _ = store.load()
    let day: TimeInterval = 24 * 60 * 60
    var oldAccepted = proposal("a", "b")
    oldAccepted.status = .accepted
    oldAccepted.resolvedAt = Self.t0
    var youngAccepted = proposal("c", "d")
    youngAccepted.status = .accepted
    youngAccepted.resolvedAt = Self.t0.addingTimeInterval(day)  // 29 days old at the cut
    var oldRejected = proposal("e", "f")
    oldRejected.status = .rejected
    oldRejected.resolvedAt = Self.t0
    let pending = proposal("g", "h")
    var accepting = proposal("i", "j")
    accepting.status = .accepting
    accepting.acceptingIntent = CorrectionAcceptingIntent(
      pairKey: accepting.pairKey, operation: .createWord, targetWordID: UUID())
    for p in [oldAccepted, youngAccepted, oldRejected, pending, accepting] { try store.upsert(p) }
    try store.reject(id: oldRejected.id, at: Self.t0)  // tombstone present
    let cut = Self.t0.addingTimeInterval(30 * day)
    #expect(try store.prune(now: cut) == 2)
    let after = try readLedger(store.fileURL)
    #expect(Set(after.proposals.map(\.id)) == Set([youngAccepted.id, pending.id, accepting.id]))
    #expect(
      after.rejectedPairs.map(\.pairKey) == [oldRejected.pairKey], "tombstones survive pruning")
    // Just under the boundary removes nothing and writes nothing.
    let bytes = try Data(contentsOf: store.fileURL)
    #expect(try store.prune(now: cut.addingTimeInterval(day - 1)) == 0)
    #expect(try Data(contentsOf: store.fileURL) == bytes)
    #expect(
      try store.prune(now: cut.addingTimeInterval(day)) == 1, "the 29-day-old one crosses the line")
  }
}

/// Mutable fault switches the injected seams read from a `@Sendable` closure,
/// so one store instance can be driven through failure and repair.
private final class FaultBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _failRead = false
  private var _failSync = false
  var failRead: Bool {
    get { lock.withLock { _failRead } }
    set { lock.withLock { _failRead = newValue } }
  }
  var failSync: Bool {
    get { lock.withLock { _failSync } }
    set { lock.withLock { _failSync = newValue } }
  }
}

/// A box the write seam can append into from a `@Sendable` closure.
private final class WriteBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Data] = []
  func append(_ d: Data) { lock.withLock { storage.append(d) } }
  var data: [Data] { lock.withLock { storage } }
}
