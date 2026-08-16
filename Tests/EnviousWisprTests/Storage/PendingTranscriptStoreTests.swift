import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// Chunk 1 of #2087 — the `pending/` Escape Recovery namespace.
///
/// Every test here is about a FAIL-CLOSED property. The feature's promise is
/// "restorable for 24 hours, then gone", and the ways that promise breaks are:
/// a pending row leaking into permanent History, an expired row still being
/// offered, a corrupt row impersonating a fresh one, or a promotion that loses
/// the text. Each has a test below.
@MainActor
@Suite struct PendingTranscriptStoreTests {

  private func makeStore() -> (TranscriptStore, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-pending-\(UUID().uuidString)", isDirectory: true)
    return (TranscriptStore(directory: dir), dir)
  }

  private func pendingRow(
    text: String = "cancelled text",
    at stamped: Date,
    takeID: String? = "TAKE-1"
  ) -> Transcript {
    Transcript(
      text: text,
      createdAt: stamped,
      escapeRecoveredAt: stamped,
      escapeRecoveryTakeID: takeID)
  }

  // MARK: - The invisibility property

  @Test("a pending row is invisible to loadAll, so it can never read as permanent History")
  func pendingIsInvisibleToLoadAll() async throws {
    let (store, _) = makeStore()
    try store.savePending(pendingRow(at: Date()))

    let permanent = try await store.loadAll()
    #expect(permanent.isEmpty)

    // Two-way control: the same store DOES surface an ordinary row, so the
    // empty result above is the namespace working and not a broken store.
    try store.save(Transcript(text: "ordinary"))
    let afterOrdinary = try await store.loadAll()
    #expect(afterOrdinary.count == 1)
    #expect(afterOrdinary.first?.text == "ordinary")
  }

  @Test("a live pending row is returned by loadPending")
  func livePendingIsReturned() async throws {
    let (store, _) = makeStore()
    try store.savePending(pendingRow(at: Date()))
    let pending = try await store.loadPending()
    #expect(pending.count == 1)
    #expect(pending.first?.escapeRecoveryTakeID == "TAKE-1")
  }

  // MARK: - The clock

  @Test("expiry boundary: just-before is offered, exactly-at and just-after are not")
  func expiryBoundary() async throws {
    let (store, _) = makeStore()
    let now = Date()
    let retention = AppConstants.pendingTranscriptRetention

    // Three points around the boundary. The exactly-at case is what makes this
    // resistant to a `<` / `<=` mutation in production: without it, flipping
    // the comparison would still pass.
    let justBefore = pendingRow(text: "before", at: now.addingTimeInterval(-retention + 1))
    let exactlyAt = pendingRow(text: "at", at: now.addingTimeInterval(-retention))
    let justAfter = pendingRow(text: "after", at: now.addingTimeInterval(-retention - 1))
    try store.savePending(justBefore)
    try store.savePending(exactlyAt)
    try store.savePending(justAfter)

    let live = try await store.loadPending(now: now)
    #expect(live.count == 1)
    #expect(live.first?.text == "before")
  }

  @Test("an expired row is hidden even when no sweep has run")
  func readTimeFilterIsAuthoritative() async throws {
    let (store, _) = makeStore()
    let now = Date()
    try store.savePending(
      pendingRow(at: now.addingTimeInterval(-AppConstants.pendingTranscriptRetention - 1)))

    // No deleteExpiredPending call: the row is still on disk.
    let live = try await store.loadPending(now: now)
    #expect(live.isEmpty)
  }

  @Test("a future timestamp is refused, swept, and produces no expiry receipt")
  func futureStampFailsClosed() async throws {
    let (store, dir) = makeStore()
    let now = Date()
    let row = pendingRow(at: now.addingTimeInterval(3600))
    try store.savePending(row)

    #expect(try await store.loadPending(now: now).isEmpty)

    // Invisibility alone is not enough: a mutation classifying this as
    // `.expired` would still pass an invisibility-only test while emitting a
    // false expiry event about a recovery the user never let lapse.
    let expired = try store.deleteExpiredPending(now: now)
    #expect(expired.isEmpty, "future-stamped is INVALID, not expired")
    let file = dir.appendingPathComponent(AppConstants.pendingTranscriptsDir)
      .appendingPathComponent("\(row.id.uuidString).json")
    #expect(!FileManager.default.fileExists(atPath: file.path), "and it must be swept")
  }

  @Test("a row with no escapeRecoveredAt is refused, swept, and produces no receipt")
  func missingStampFailsClosed() async throws {
    let (store, dir) = makeStore()
    // Pending by LOCATION but carrying no clock — the shape a legacy or
    // partially-written file would have.
    let row = Transcript(text: "no stamp")
    try store.savePending(row)

    #expect(try await store.loadPending().isEmpty)

    let expired = try store.deleteExpiredPending()
    #expect(expired.isEmpty, "unstamped is INVALID, not expired")
    let file = dir.appendingPathComponent(AppConstants.pendingTranscriptsDir)
      .appendingPathComponent("\(row.id.uuidString).json")
    #expect(!FileManager.default.fileExists(atPath: file.path), "and it must be swept")
  }

  @Test("a present-but-unreadable .json is swept rather than accumulating forever")
  func unreadableFileIsSwept() async throws {
    let (store, dir) = makeStore()
    try store.savePending(pendingRow(at: Date()))
    let pendingDir = dir.appendingPathComponent(AppConstants.pendingTranscriptsDir)

    // A DIRECTORY named `<uuid>.json`. It is listed by the directory walk and
    // matches the `.json` extension filter, but `Data(contentsOf:)` cannot read
    // it — the "present but unreadable" shape, without depending on permission
    // semantics that vary by platform and privilege.
    let unreadable = pendingDir.appendingPathComponent("\(UUID().uuidString).json")
    try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)

    #expect(try await store.loadPending().count == 1, "the live row is unaffected")

    let expired = try store.deleteExpiredPending()
    #expect(expired.isEmpty, "unreadable is INVALID, not expired")
    #expect(
      !FileManager.default.fileExists(atPath: unreadable.path),
      "an unreadable file must be swept, not skipped forever")
  }

  @Test("an undecodable file is swept but NOT reported as expired")
  func corruptRowIsSweptWithoutAnExpiryReceipt() async throws {
    let (store, dir) = makeStore()
    try store.savePending(pendingRow(at: Date()))
    let pendingDir = dir.appendingPathComponent(AppConstants.pendingTranscriptsDir)
    let corrupt = pendingDir.appendingPathComponent("\(UUID().uuidString).json")
    try Data("{ not json".utf8).write(to: corrupt)

    let live = try await store.loadPending()
    #expect(live.count == 1, "the corrupt file must not be offered")

    let expired = try store.deleteExpiredPending()
    #expect(!FileManager.default.fileExists(atPath: corrupt.path), "it must be swept")
    #expect(
      expired.isEmpty,
      "an unreadable file is INVALID, not expired: reporting it would emit a false expiry event")
  }

  @Test("a row whose filename disagrees with its id is invalid, not offered, and swept")
  func filenameIdMismatchFailsClosed() async throws {
    let (store, dir) = makeStore()
    let row = pendingRow(at: Date())
    try store.savePending(row)

    // Rename the file so the filename no longer matches the embedded id. Such a
    // row is unreachable by `promotePending`, which looks up by filename, so
    // offering it would promise a restore that can never happen.
    let pendingDir = dir.appendingPathComponent(AppConstants.pendingTranscriptsDir)
    let original = pendingDir.appendingPathComponent("\(row.id.uuidString).json")
    let misnamed = pendingDir.appendingPathComponent("\(UUID().uuidString).json")
    try FileManager.default.moveItem(at: original, to: misnamed)

    let live = try await store.loadPending()
    #expect(live.isEmpty)

    let expired = try store.deleteExpiredPending()
    #expect(expired.isEmpty, "invalid, so no expiry receipt")
    #expect(!FileManager.default.fileExists(atPath: misnamed.path))
  }

  @Test("Keep revalidates: an expired row cannot be promoted by a stale click")
  func promotionRefusesAnExpiredRow() async throws {
    let (store, _) = makeStore()
    let now = Date()
    let stale = pendingRow(
      at: now.addingTimeInterval(-AppConstants.pendingTranscriptRetention - 1))
    try store.savePending(stale)

    // The row expired between render and click. Keep must be inert, not merely
    // harmless — promoting it would make a lapsed recovery permanent.
    try store.promotePending(id: stale.id, now: now)

    let permanent = try await store.loadAll()
    #expect(permanent.isEmpty, "an expired row must never become permanent History")
  }

  // MARK: - The sweep must name what it deleted

  @Test("deleteExpiredPending returns the expired identities and their take ids")
  func sweepReturnsWhatItDeleted() async throws {
    let (store, _) = makeStore()
    let now = Date()
    let stale = pendingRow(
      at: now.addingTimeInterval(-AppConstants.pendingTranscriptRetention - 1),
      takeID: "TAKE-STALE")
    let fresh = pendingRow(at: now, takeID: "TAKE-FRESH")
    try store.savePending(stale)
    try store.savePending(fresh)

    let expired = try store.deleteExpiredPending(now: now)
    #expect(expired.count == 1)
    #expect(expired.first?.id == stale.id)
    #expect(expired.first?.takeID == "TAKE-STALE")

    // The fresh one survived the sweep.
    let live = try await store.loadPending(now: now)
    #expect(live.count == 1)
    #expect(live.first?.escapeRecoveryTakeID == "TAKE-FRESH")
  }

  // MARK: - Promotion

  @Test("Keep promotes into permanent History, clears the clock, and keeps the take id")
  func promotionMovesRowAndStopsTheClock() async throws {
    let (store, _) = makeStore()
    let row = pendingRow(text: "keep me", at: Date())
    try store.savePending(row)

    try store.promotePending(id: row.id)

    let permanent = try await store.loadAll()
    #expect(permanent.count == 1)
    #expect(permanent.first?.text == "keep me")
    #expect(permanent.first?.escapeRecoveredAt == nil, "the clock must stop")
    #expect(
      permanent.first?.escapeRecoveryTakeID == "TAKE-1",
      "the join key survives promotion")

    let stillPending = try await store.loadPending()
    #expect(stillPending.isEmpty)
  }

  @Test("promotion is idempotent: a second press is inert, not a duplicate")
  func promotionIsIdempotent() async throws {
    let (store, _) = makeStore()
    let row = pendingRow(at: Date())
    try store.savePending(row)

    try store.promotePending(id: row.id)
    try store.promotePending(id: row.id)
    try store.promotePending(id: UUID())  // never existed

    let permanent = try await store.loadAll()
    #expect(permanent.count == 1)
  }

  @Test("if both copies exist, the permanent row wins and pending is not double-counted")
  func rootPrecedenceAfterInterruptedPromotion() async throws {
    let (store, dir) = makeStore()
    let row = pendingRow(text: "interrupted", at: Date())
    try store.savePending(row)
    // Simulate a crash between "write permanent" and "delete pending".
    try store.save(row.promotedFromPending())

    let permanent = try await store.loadAll()
    #expect(permanent.count == 1)
    #expect(permanent.first?.escapeRecoveredAt == nil)

    // The orphaned pending copy is still on disk and still shares the id, so a
    // caller merging the two lists must key on id with root precedence.
    let pendingDir = dir.appendingPathComponent(AppConstants.pendingTranscriptsDir)
    let orphan = pendingDir.appendingPathComponent("\(row.id.uuidString).json")
    #expect(FileManager.default.fileExists(atPath: orphan.path))
  }

  // MARK: - Legacy decode

  @Test("a pre-#2087 transcript decodes with both new fields nil")
  func legacyJSONDecodes() throws {
    let legacy = """
      {"id":"\(UUID().uuidString)","text":"old","duration":0,"processingTime":0,
       "backendType":"parakeet","createdAt":768000000}
      """
    let decoded = try JSONDecoder().decode(Transcript.self, from: Data(legacy.utf8))
    #expect(decoded.escapeRecoveredAt == nil)
    #expect(decoded.escapeRecoveryTakeID == nil)
    #expect(decoded.text == "old")
  }

  // MARK: - Permissions

  @Test("the pending directory is 0700 and its files are 0600")
  func pendingNamespaceIsHardened() throws {
    let (store, dir) = makeStore()
    let row = pendingRow(at: Date())
    try store.savePending(row)

    let pendingDir = dir.appendingPathComponent(AppConstants.pendingTranscriptsDir)
    let dirPerms =
      try FileManager.default.attributesOfItem(atPath: pendingDir.path)[
        .posixPermissions] as? NSNumber
    #expect(dirPerms?.intValue == 0o700)

    let file = pendingDir.appendingPathComponent("\(row.id.uuidString).json")
    let filePerms =
      try FileManager.default.attributesOfItem(atPath: file.path)[
        .posixPermissions] as? NSNumber
    #expect(filePerms?.intValue == 0o600)
  }
}
