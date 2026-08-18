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
/// Class: `.productOutcome` — a kept dictation is lost early, offered late, or never cleaned up.
@Suite(.tags(.productOutcome)) struct PendingTranscriptStoreTests {

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
    let expired = try await store.deleteExpiredPending(now: now).expired
    #expect(expired.isEmpty, "future-stamped is INVALID, not expired")
    let file = dir.appendingPathComponent(AppConstants.pendingTranscriptsDir)
      .appendingPathComponent("\(row.id.uuidString).json")
    #expect(!FileManager.default.fileExists(atPath: file.path), "and it must be swept")
  }

  /// An unremovable file must be reported EVEN WITH NO IDENTITY.
  ///
  /// `unremovable` is a count rather than a set of ids for exactly this file. A
  /// corrupt entry whose name is not a UUID cannot be named, so an identity-keyed
  /// signal reported nothing about it — and the caller, told the directory was
  /// clean, stopped retrying and stranded the one file the sweep exists to clear.
  ///
  /// The failure is real: removing a file needs write permission on the
  /// CONTAINING directory, so `0500` makes `removeItem` fail while leaving the
  /// walk able to list.
  @Test("a file that cannot be removed is reported even when its name is not a UUID")
  func unremovableCorruptFileIsStillReported() async throws {
    let (store, dir) = makeStore()
    // Save a real row first, so the pending directory exists with its hardened
    // permissions rather than being created by this test.
    try store.savePending(pendingRow(at: Date().addingTimeInterval(-3600)))
    let pending = dir.appendingPathComponent(AppConstants.pendingTranscriptsDir)
    let garbage = pending.appendingPathComponent("garbage.json")
    try Data("not a transcript".utf8).write(to: garbage)

    let sealed: [FileAttributeKey: Any] = [.posixPermissions: 0o500]
    let unsealed: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
    try FileManager.default.setAttributes(sealed, ofItemAtPath: pending.path)
    defer { try? FileManager.default.setAttributes(unsealed, ofItemAtPath: pending.path) }

    let swept = try await store.deleteExpiredPending()

    #expect(
      swept.unremovable >= 1,
      "a file it meant to remove and could not must be counted, name or no name")
    #expect(
      FileManager.default.fileExists(atPath: garbage.path),
      "control: the removal genuinely failed, so there is something to report")
    #expect(swept.deletedIDs.isEmpty, "nothing was actually removed")
  }

  /// An UNREADABLE directory must not report itself as a clean one.
  ///
  /// `unremovable == 0` has two causes: the sweep saw everything and cleared it,
  /// or it could not look. Those are opposite facts, and the second one masks
  /// work. Swallowed into an empty list they are the same number, and the caller
  /// then evicts its own records and stops retrying while the files remain.
  ///
  /// `0300` is write-plus-execute with no READ, so `contentsOfDirectory` fails
  /// while the directory itself is otherwise intact — enumeration failure
  /// specifically, not removal failure.
  @Test("a directory that cannot be enumerated reports an incomplete walk")
  func unreadableDirectoryReportsIncompleteWalk() async throws {
    let (store, dir) = makeStore()
    try store.savePending(
      pendingRow(at: Date().addingTimeInterval(-(AppConstants.pendingTranscriptRetention + 1))))
    let pending = dir.appendingPathComponent(AppConstants.pendingTranscriptsDir)

    // Control FIRST: the same call on a readable directory completes and sweeps,
    // so a false `walkComplete` cannot be what makes this test pass.
    let readable = try await store.deleteExpiredPending()
    #expect(readable.walkComplete, "control: a readable directory completes its walk")
    #expect(readable.expired.count == 1, "control: and actually sweeps the lapsed row")

    try store.savePending(
      pendingRow(at: Date().addingTimeInterval(-(AppConstants.pendingTranscriptRetention + 1))))
    let sealed: [FileAttributeKey: Any] = [.posixPermissions: 0o300]
    let unsealed: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
    try FileManager.default.setAttributes(sealed, ofItemAtPath: pending.path)
    defer { try? FileManager.default.setAttributes(unsealed, ofItemAtPath: pending.path) }

    let blind = try await store.deleteExpiredPending()

    #expect(blind.walkComplete == false, "it could not look, and must say so")
    #expect(blind.expired.isEmpty, "it saw nothing, so it can report nothing")
    #expect(
      blind.unremovable == 0,
      "and zero here means NOT MEASURED — which is exactly why walkComplete has to exist")
  }

  @Test("a row with no escapeRecoveredAt is refused, swept, and produces no receipt")
  func missingStampFailsClosed() async throws {
    let (store, dir) = makeStore()
    // Pending by LOCATION but carrying no clock — the shape a legacy or
    // partially-written file would have.
    let row = Transcript(text: "no stamp")
    try store.savePending(row)

    #expect(try await store.loadPending().isEmpty)

    let expired = try await store.deleteExpiredPending().expired
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

    let expired = try await store.deleteExpiredPending().expired
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

    let expired = try await store.deleteExpiredPending().expired
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

    let expired = try await store.deleteExpiredPending().expired
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

    let expired = try await store.deleteExpiredPending(now: now).expired
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

  // MARK: - Crash-recovery de-duplication (#2087)

  /// A pending row proves its spool was ALREADY recovered, so launch recovery
  /// must not replay that spool again.
  ///
  /// The gap this closes: a live Escape Recovery saves into `pending/`, then the
  /// app dies before the spool is deleted. That spool carries no attempt marker
  /// — the live save never writes one — so without this the next launch
  /// transcribes it a second time and the user finds the same dictation twice.
  @Test("pending rows contribute their recovery ids to the de-dup set")
  func pendingRowsAreCountedForDeduplication() async throws {
    let (store, _) = makeStore()
    var row = pendingRow(at: Date())
    row = Transcript(
      id: row.id, text: row.text, createdAt: row.createdAt,
      recoverySessionID: "spool-abc",
      escapeRecoveredAt: row.escapeRecoveredAt,
      escapeRecoveryTakeID: row.escapeRecoveryTakeID)
    try store.savePending(row)

    #expect(try await store.pendingRecoverySessionIDs() == ["spool-abc"])
  }

  /// The UNION is what launch recovery actually consumes, so it is asserted
  /// directly rather than inferred from its two halves.
  ///
  /// Both halves passing does not prove the union: a caller that read only
  /// `loadAll` — the bug this fixes — leaves every other test in this file green
  /// while replaying escape-recovered spools a second time.
  @Test("allRecoveredSessionIDs unions permanent and pending")
  func recoveredIDsUnionBothNamespaces() async throws {
    let (store, _) = makeStore()

    let permanent = Transcript(
      text: "ordinary crash rescue", recoverySessionID: "spool-permanent", isRecovered: true)
    try store.save(permanent)

    let stamped = Date()
    var pending = pendingRow(at: stamped)
    pending = Transcript(
      id: pending.id, text: pending.text, createdAt: stamped,
      recoverySessionID: "spool-pending",
      escapeRecoveredAt: stamped,
      escapeRecoveryTakeID: pending.escapeRecoveryTakeID)
    try store.savePending(pending)

    #expect(
      try await store.allRecoveredSessionIDs() == ["spool-permanent", "spool-pending"],
      "dropping either namespace re-opens a duplicate replay")
  }

  /// EXPIRY IS DELIBERATELY IGNORED here, and this is the assertion that keeps it
  /// that way.
  ///
  /// "This spool was already recovered" stays true forever; the 24-hour window
  /// governs whether the user may still SEE the row, not whether the audio was
  /// already turned into text. Filtering by expiry would let the spool be
  /// replayed again the moment the row aged out — a duplicate appearing exactly
  /// 24 hours later. A bug that is correct for a day and then not is the worst
  /// kind, because nothing in a normal test run reaches it.
  @Test("an EXPIRED pending row still counts for de-duplication")
  func expiredPendingRowsStillDeduplicate() async throws {
    let (store, _) = makeStore()
    let longAgo = Date(timeIntervalSince1970: 1_000_000)
    var row = pendingRow(at: longAgo)
    row = Transcript(
      id: row.id, text: row.text, createdAt: longAgo,
      recoverySessionID: "spool-stale",
      escapeRecoveredAt: longAgo,
      escapeRecoveryTakeID: row.escapeRecoveryTakeID)
    try store.savePending(row)

    // Invisible to the user...
    #expect(try await store.loadPending(now: Date()).isEmpty, "expired: never offered")
    // ...but still proof its spool was recovered.
    #expect(
      try await store.pendingRecoverySessionIDs() == ["spool-stale"],
      "an expired row must still block a second replay of its spool")
  }

  // MARK: - Promotions that left a shadow

  /// A Keep the user pressed must never be counted as an expiry.
  ///
  /// `promotePending` writes the permanent row FIRST and removes the pending
  /// file second, deliberately — a crash between the two keeps the text rather
  /// than losing it. The cost is that a failed removal, or a crash, leaves the
  /// stamped copy beside its permanent twin. Twenty-four hours later the sweep
  /// would see a stamped row past its window and report it expired, for a
  /// dictation the user explicitly chose to keep.
  ///
  /// The text is safe either way; what breaks is the kept-versus-expired ratio,
  /// which is the one number this funnel exists to produce — and it breaks in
  /// the direction that makes the feature look worse than it is.
  @Test("a promoted row's leftover pending copy is swept without an expiry receipt")
  func shadowOfAPromotedRowIsNotAnExpiry() async throws {
    let (store, dir) = makeStore()
    let longAgo = Date(timeIntervalSinceNow: -(25 * 60 * 60))
    let row = pendingRow(at: longAgo)
    try store.savePending(row)
    // The permanent twin, exactly as a successful promotion leaves it.
    try store.save(row)

    let swept = try await store.deleteExpiredPending()

    #expect(
      swept.expired.isEmpty,
      "the user pressed Keep; reporting an expiry would understate the one ratio")
    #expect(
      swept.deletedIDs.contains(row.id),
      "the shadow is still litter and must be cleared, receipt or no receipt")
    let shadow = dir.appendingPathComponent("pending/\(row.id.uuidString).json")
    #expect(!FileManager.default.fileExists(atPath: shadow.path))
  }

  /// The control. Without a permanent twin the SAME row is a real expiry, so the
  /// suppression above cannot be satisfied by suppressing everything.
  @Test("an expired row with no permanent twin still earns its receipt")
  func genuineExpiryStillReports() async throws {
    let (store, _) = makeStore()
    let row = pendingRow(at: Date(timeIntervalSinceNow: -(25 * 60 * 60)))
    try store.savePending(row)

    let swept = try await store.deleteExpiredPending()

    #expect(
      swept.expired.map(\.takeID) == [row.escapeRecoveryTakeID],
      "nothing promoted this one, so it genuinely aged out")
  }

  // MARK: - Interrupted writes

  /// A killed write strands the whole transcript under a name the sweep could
  /// not see (#2087, cloud review).
  ///
  /// `savePending` is temp-then-rename into `.<id>.tmp`, and the sweep
  /// enumerated `.json` only — so a process killed between filling the temp file
  /// and renaming it left a COMPLETE pending transcript that no later sweep ever
  /// looked at. It outlived the 24-hour window indefinitely, which is exactly
  /// what the setting's copy and the help centre both say does not happen. The
  /// file is 0600 inside a 0700 directory so it was never exposed, but the
  /// promise is about TIME, and retained is retained.
  @Test("a stale interrupted write is swept")
  func staleTempFileIsSwept() async throws {
    let (store, dir) = makeStore()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let pending = dir.appendingPathComponent("pending", isDirectory: true)
    try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
    let stray = pending.appendingPathComponent(".\(UUID().uuidString).tmp")
    try "the whole cancelled dictation".write(to: stray, atomically: true, encoding: .utf8)
    // Older than the retention window, which is what makes it stale rather than
    // a write in flight.
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -(25 * 60 * 60))],
      ofItemAtPath: stray.path)

    _ = try await store.deleteExpiredPending()

    #expect(
      !FileManager.default.fileExists(atPath: stray.path),
      "an interrupted write holds the same text as the row it was becoming")
  }

  /// The other direction, and the reason the sweep is age-gated rather than
  /// clearing every `.tmp` on sight: a healthy write in progress looks exactly
  /// like this, and deleting one would corrupt a save that was about to succeed.
  @Test("a FRESH interrupted write is left alone")
  func freshTempFileSurvives() async throws {
    let (store, dir) = makeStore()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let pending = dir.appendingPathComponent("pending", isDirectory: true)
    try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
    let inFlight = pending.appendingPathComponent(".\(UUID().uuidString).tmp")
    try "a save that is still happening".write(to: inFlight, atomically: true, encoding: .utf8)

    _ = try await store.deleteExpiredPending()

    #expect(
      FileManager.default.fileExists(atPath: inFlight.path),
      "seconds old is a live write, not litter")
  }
}
