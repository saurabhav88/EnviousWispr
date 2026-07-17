import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// #1386 PR-2a. Covers L3 (deletion authority), L8 (path safety), L9 (cancellation is not a
/// verdict) from the plan's §1.
///
/// Every refusal here is silent by design, which is exactly where a false green hides: a test
/// asserting "did not crash" cannot tell "refused correctly" from "never ran". So every
/// refusal case asserts a **positive** — the named file still exists, the hash count is zero,
/// the verdict is the specific one claimed.
@Suite struct LegacyRetirementTests {

  // MARK: - Fixtures

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("legacy-retirement-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  @discardableResult
  private func stage(_ root: URL, _ relativePath: String, _ bytes: Data) throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: url)
    return url
  }

  private func trusted(_ relativePath: String, _ bytes: Data) -> LegacyRetirement.TrustedFile {
    LegacyRetirement.TrustedFile(
      relativePath: relativePath, sizeBytes: Int64(bytes.count), sha256: digest(bytes))
  }

  private func identityOf(_ url: URL) -> LegacyRetirement.FileIdentity {
    var st = stat()
    _ = lstat(url.path, &st)
    return LegacyRetirement.FileIdentity(
      device: st.st_dev, inode: UInt64(st.st_ino), sizeBytes: Int64(st.st_size),
      modifiedAtSeconds: Int64(st.st_mtimespec.tv_sec),
      modifiedAtNanoseconds: Int64(st.st_mtimespec.tv_nsec),
      changedAtSeconds: Int64(st.st_ctimespec.tv_sec),
      changedAtNanoseconds: Int64(st.st_ctimespec.tv_nsec))
  }

  /// Counts hashes so "we never hashed it" is provable rather than assumed.
  private actor HashSpy {
    private(set) var count = 0

    func hash(_ url: URL) async throws -> String {
      count += 1
      return try await LegacyRetirement.streamingSHA256(of: url)
    }

    /// The `@Sendable` closure `fingerprint` takes, bound to this actor.
    nonisolated var callback: @Sendable (URL) async throws -> String {
      { url in try await self.hash(url) }
    }
  }

  // MARK: - L8: path safety

  @Test func honestNestedPathMatchesAtFullManifestDepth() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // The real manifest nests three deep, e.g. AudioEncoder.mlmodelc/analytics/coremldata.bin.
    let bytes = Data("weights".utf8)
    try stage(root, "AudioEncoder.mlmodelc/analytics/coremldata.bin", bytes)

    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("AudioEncoder.mlmodelc/analytics/coremldata.bin", bytes)])

    guard case .match = verdicts["AudioEncoder.mlmodelc/analytics/coremldata.bin"] else {
      Issue.record("an honest nested path must match: \(verdicts)")
      return
    }
  }

  @Test func symlinkAtAnIntermediateComponentIsMismatchAndIsNeverHashed() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // The bytes are real and correct — only the PATH lies. An escape via an intermediate
    // component is the case that checking the leaf alone cannot see, and we DELETE through
    // these paths, so a follow here would destroy a file outside the root.
    let bytes = Data("weights".utf8)
    let elsewhere = try makeRoot()
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    try stage(elsewhere, "analytics/coremldata.bin", bytes)

    let container = root.appendingPathComponent("AudioEncoder.mlmodelc", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: container.appendingPathComponent("analytics"),
      withDestinationURL: elsewhere.appendingPathComponent("analytics"))

    let spy = HashSpy()
    let verdicts = try await LegacyRetirement.fingerprint(
      root: root,
      files: [trusted("AudioEncoder.mlmodelc/analytics/coremldata.bin", bytes)],
      hashFile: spy.callback)

    #expect(verdicts["AudioEncoder.mlmodelc/analytics/coremldata.bin"] == .mismatch)
    #expect(await spy.count == 0, "a path we refuse must never be read")
    #expect(
      FileManager.default.fileExists(
        atPath: elsewhere.appendingPathComponent("analytics/coremldata.bin").path),
      "the escaped file must be untouched")
  }

  @Test func symlinkedLeafIsMismatchEvenWhenItPointsAtCorrectBytes() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let bytes = Data("weights".utf8)
    let elsewhere = try makeRoot()
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    let real = try stage(elsewhere, "real.bin", bytes)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("leaf.bin"), withDestinationURL: real)

    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("leaf.bin", bytes)])

    #expect(verdicts["leaf.bin"] == .mismatch, "lstat must describe the link, not its target")
  }

  @Test func nonDirectoryWhereADirectoryBelongsIsMismatch() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // A regular file sitting where the manifest says a directory goes: not our tree.
    try stage(root, "AudioEncoder.mlmodelc", Data("not a directory".utf8))

    let bytes = Data("weights".utf8)
    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("AudioEncoder.mlmodelc/coremldata.bin", bytes)])

    #expect(verdicts["AudioEncoder.mlmodelc/coremldata.bin"] == .mismatch)
  }

  @Test func missingFileIsAbsentAndIsNeverHashed() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let spy = HashSpy()
    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("gone.bin", Data("x".utf8))], hashFile: spy.callback)

    #expect(verdicts["gone.bin"] == .absent)
    #expect(await spy.count == 0)
  }

  @Test func missingIntermediateIsAbsentNotMismatch() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // ENOTDIR/ENOENT on the way down means nothing is there — not that someone else's bytes
    // are. `.mismatch` would be a permanent decline for a copy that simply does not exist.
    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("nope.mlmodelc/analytics/coremldata.bin", Data("x".utf8))])

    #expect(verdicts["nope.mlmodelc/analytics/coremldata.bin"] == .absent)
  }

  @Test func unreadableDirectoryIsUnreadableNotAbsent() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let bytes = Data("weights".utf8)
    try stage(root, "locked/coremldata.bin", bytes)
    let locked = root.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: locked.path)
    }

    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("locked/coremldata.bin", bytes)])

    // This is the distinction `FileManager.fileExists` cannot make: it answers false for both
    // "missing" and "cannot look". Calling this `.absent` would silently drop a real copy.
    #expect(
      verdicts["locked/coremldata.bin"] == .unreadable,
      "permission denial is 'cannot tell', never 'nothing there'")
  }

  @Test func sizeMismatchIsNeverHashed() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    try stage(root, "a.bin", Data("longer than expected".utf8))
    let spy = HashSpy()
    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("a.bin", Data("short".utf8))], hashFile: spy.callback)

    #expect(verdicts["a.bin"] == .mismatch)
    #expect(await spy.count == 0, "size gates hashing — 1.6 GB is never read speculatively")
  }

  @Test func aTraversingPathIsRefusedAndNeverReachesTheDiskOutsideTheRoot() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // `..` lstats as a perfectly ordinary directory, so a component walk waves it through and
    // the leaf lands outside the root — where this type would hash a stranger's file, call it
    // a match, and unlink it. Our manifests are pinned and carry no traversal; this is a
    // public deletion primitive and must not rely on its callers being careful.
    let bytes = Data("victim".utf8)
    let outside = root.deletingLastPathComponent()
      .appendingPathComponent("victim-\(UUID().uuidString).bin")
    try bytes.write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }

    let spy = HashSpy()
    let escaping = "../\(outside.lastPathComponent)"
    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted(escaping, bytes)], hashFile: spy.callback)

    #expect(verdicts[escaping] == .mismatch, "a traversing path is refused, not classified")
    #expect(await spy.count == 0)

    let result = LegacyRetirement.unlinkUnchanged(root: root, verdicts: verdicts)
    #expect(result.unlinked.isEmpty)
    #expect(FileManager.default.fileExists(atPath: outside.path), "the outside file survives")
  }

  @Test func anAbsolutePathIsRefused() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let bytes = Data("x".utf8)
    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("/etc/hosts", bytes)])

    #expect(verdicts["/etc/hosts"] == .mismatch)
  }

  @Test func aSameSecondRewriteOfEqualLengthIsNotMistakenForTheVerifiedFile() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let mine = Data("aaaa".utf8)
    let url = try stage(root, "a.bin", mine)
    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("a.bin", mine)])

    // Same length, different bytes, same wall-clock second, written in place so the inode
    // does not change. Second-granularity mtime cannot see this; nanoseconds and ctime can.
    let handle = try FileHandle(forWritingTo: url)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Data("bbbb".utf8))
    try handle.close()

    let result = LegacyRetirement.unlinkUnchanged(root: root, verdicts: verdicts)

    #expect(result.unlinked.isEmpty, "bytes we never hashed must never be deleted")
    #expect(result.preserved == ["a.bin"])
    #expect(try Data(contentsOf: url) == Data("bbbb".utf8))
  }

  // MARK: - L9: cancellation is not a verdict

  @Test func cancellationPropagatesAndIsNeverClassified() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let bytes = Data("weights".utf8)
    try stage(root, "a.bin", bytes)

    // Conflating a cancel with `.unreadable` would let a user who pressed Cancel permanently
    // brand their own good copy as un-examinable — the caller persists a declined record from
    // that verdict. So the cancel must arrive as a throw, not as an answer.
    var thrown: Error?
    do {
      _ = try await LegacyRetirement.fingerprint(root: root, files: [trusted("a.bin", bytes)]) {
        _ in throw CancellationError()
      }
    } catch {
      thrown = error
    }

    #expect(thrown is CancellationError, "a cancel must reach the caller as a cancel")
  }

  @Test func aGenericHashFailureStillClassifiesUnreadable() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    struct Boom: Error {}
    let bytes = Data("weights".utf8)
    try stage(root, "a.bin", bytes)

    // The other half of L9: only cancellation is special. An ordinary I/O failure is still a
    // verdict, or EG-1's unreadable-monolith behavior would change.
    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("a.bin", bytes)]
    ) { _ in throw Boom() }

    #expect(verdicts["a.bin"] == .unreadable)
  }

  @Test func streamingHashStopsWhenTheCallerCancels() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // 24 MB: enough to span several 4 MB chunks so a cancel can land mid-read.
    let big = Data(repeating: 0x41, count: 24 * 1_024 * 1_024)
    let url = try stage(root, "big.bin", big)

    let task = Task { try await LegacyRetirement.streamingSHA256(of: url) }
    task.cancel()

    var thrown: Error?
    do { _ = try await task.value } catch { thrown = error }

    // The detached hash inherits nothing; without the explicit cancellation handler this read
    // would run to completion after the caller gave up.
    #expect(thrown is CancellationError)
  }

  @Test func streamingHashMatchesCryptoKitOverAMultiChunkFile() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let big = Data((0..<(9 * 1_024 * 1_024)).map { UInt8($0 % 251) })
    let url = try stage(root, "big.bin", big)

    let streamed = try await LegacyRetirement.streamingSHA256(of: url)

    #expect(streamed == digest(big), "chunking must not change the digest")
  }

  @Test func theDigestComesFromTheDescriptorNotTheName() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // Hashing by path after lstat-ing by path proves nothing about the file we then delete:
    // a writer can swap the name to a decoy holding trusted bytes, let us hash THAT, restore
    // the original, and we delete bytes we never read. Binding both proofs to one descriptor
    // is what closes it. Unlinking the name mid-flight is the cheapest way to prove the read
    // follows the inode: if the digest still lands, it did not come from the path.
    let bytes = Data("weights".utf8)
    let url = try stage(root, "a.bin", bytes)

    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    #expect(fd >= 0)
    defer { close(fd) }
    try FileManager.default.removeItem(at: url)

    let digest = try await LegacyRetirement.streamingSHA256(fd: fd)

    #expect(digest == self.digest(bytes), "the read follows the inode, not the name")
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test func aMissingRootIsAbsentNotMismatch() async throws {
    let root = try makeRoot()
    try FileManager.default.removeItem(at: root)

    // The ~465 users who never had this model must not get a permanent decline persisted
    // for a copy they never owned. `.mismatch` would say "we looked, it is not ours".
    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("a.bin", Data("x".utf8))])

    #expect(verdicts["a.bin"] == .absent)
  }

  // MARK: - L3: roll-up is deterministic and total

  @Test func rollUpIsAbsentOnlyWhenEveryEntryIsAbsent() {
    #expect(LegacyRetirement.rollUp(["a": .absent, "b": .absent]) == .absent)
    #expect(LegacyRetirement.rollUp([:]) == .absent)
  }

  @Test func rollUpIsMatchOnlyWhenEveryEntryMatches() {
    let id = LegacyRetirement.FileIdentity(
      device: 1, inode: 2, sizeBytes: 3, modifiedAtSeconds: 4, modifiedAtNanoseconds: 5,
      changedAtSeconds: 6, changedAtNanoseconds: 7)
    #expect(LegacyRetirement.rollUp(["a": .match(id), "b": .match(id)]) == .match)
  }

  @Test func rollUpCarriesNoSetLevelIdentity() {
    // `SetVerdict` deliberately has no payload: a 24-file aggregate has no truthful single
    // identity, and handing back some arbitrary member's would be a lie a caller could act on.
    let id = LegacyRetirement.FileIdentity(
      device: 1, inode: 2, sizeBytes: 3, modifiedAtSeconds: 4, modifiedAtNanoseconds: 5,
      changedAtSeconds: 6, changedAtNanoseconds: 7)
    #expect(LegacyRetirement.rollUp(["a": .match(id)]) == LegacyRetirement.SetVerdict.match)
  }

  @Test func partialMatchRollsUpToMismatch() {
    let id = LegacyRetirement.FileIdentity(
      device: 1, inode: 2, sizeBytes: 3, modifiedAtSeconds: 4, modifiedAtNanoseconds: 5,
      changedAtSeconds: 6, changedAtNanoseconds: 7)
    // The crash-mid-delete shape. A partial match is not our artifact — without a marker it
    // must delete nothing. `match + absent` is the case a naive "any match wins" gets wrong.
    #expect(LegacyRetirement.rollUp(["a": .match(id), "b": .absent]) == .mismatch)
    #expect(LegacyRetirement.rollUp(["a": .match(id), "b": .mismatch]) == .mismatch)
    #expect(LegacyRetirement.rollUp(["a": .absent, "b": .mismatch]) == .mismatch)
  }

  @Test func unreadableOutranksEveryOtherVerdict() {
    let id = LegacyRetirement.FileIdentity(
      device: 1, inode: 2, sizeBytes: 3, modifiedAtSeconds: 4, modifiedAtNanoseconds: 5,
      changedAtSeconds: 6, changedAtNanoseconds: 7)
    // "Cannot tell" must never be reported as "can tell, and it is not ours": the second is a
    // permanent decline, the first is retryable.
    #expect(LegacyRetirement.rollUp(["a": .unreadable, "b": .match(id)]) == .unreadable)
    #expect(LegacyRetirement.rollUp(["a": .unreadable, "b": .mismatch]) == .unreadable)
    #expect(LegacyRetirement.rollUp(["a": .unreadable, "b": .absent]) == .unreadable)
  }

  // MARK: - L3: unlink only what we examined

  @Test func unlinkRemovesMatchesAndPreservesEverythingElse() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let mine = Data("mine".utf8)
    try stage(root, "mine.bin", mine)
    try stage(root, "theirs.bin", Data("theirs".utf8))

    let verdicts = try await LegacyRetirement.fingerprint(
      root: root,
      files: [trusted("mine.bin", mine), trusted("theirs.bin", Data("expected".utf8))])
    let result = LegacyRetirement.unlinkUnchanged(root: root, verdicts: verdicts)

    #expect(result.unlinked == ["mine.bin"])
    #expect(result.preserved == ["theirs.bin"])
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("mine.bin").path))
    #expect(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("theirs.bin").path),
      "bytes we could not identify must survive")
  }

  @Test func anEntryRewrittenAfterFingerprintIsPreservedNotDeleted() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let bytes = Data("mine".utf8)
    let url = try stage(root, "a.bin", bytes)
    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("a.bin", bytes)])

    // Someone replaces the file between our proof and our delete. Identity — not the path —
    // is what stops us destroying a file we never examined.
    try FileManager.default.removeItem(at: url)
    try Data("someone else's file, same name".utf8).write(to: url)

    let result = LegacyRetirement.unlinkUnchanged(root: root, verdicts: verdicts)

    #expect(result.unlinked.isEmpty)
    #expect(result.preserved == ["a.bin"])
    #expect(
      try Data(contentsOf: url) == Data("someone else's file, same name".utf8),
      "the replacement must be intact")
  }

  @Test func anIntermediateSwappedForASymlinkAfterFingerprintIsNotDeletedThrough() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let elsewhere = try makeRoot()
    defer { try? FileManager.default.removeItem(at: elsewhere) }

    let bytes = Data("mine".utf8)
    try stage(root, "dir/a.bin", bytes)
    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("dir/a.bin", bytes)])

    // The path was honest when we proved it. Between the proof and the delete, the
    // intermediate directory becomes a symlink pointing somewhere else. `lstat` declines to
    // follow only the FINAL component, so a path-based remove would traverse this.
    let victim = try stage(elsewhere, "a.bin", bytes)
    try FileManager.default.removeItem(at: root.appendingPathComponent("dir"))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("dir"), withDestinationURL: elsewhere)

    let result = LegacyRetirement.unlinkUnchanged(root: root, verdicts: verdicts)

    #expect(result.unlinked.isEmpty)
    #expect(result.preserved == ["dir/a.bin"])
    #expect(
      FileManager.default.fileExists(atPath: victim.path),
      "a file outside the root must survive a swapped intermediate")
  }

  @Test func aFailedRemoveReportsThePathAsPreserved() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let bytes = Data("mine".utf8)
    try stage(root, "a.bin", bytes)
    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("a.bin", bytes)])

    struct Boom: Error {}
    let result = LegacyRetirement.unlinkUnchanged(
      root: root, verdicts: verdicts, removeItem: { _ in throw Boom() })

    // A delete that threw must never be reported as unlinked — the caller keeps the marker
    // and replays on that basis.
    #expect(result.unlinked.isEmpty)
    #expect(result.preserved == ["a.bin"])
  }

  @Test func aSymlinkedRootIsRefusedForBothFingerprintAndUnlink() async throws {
    let real = try makeRoot()
    defer { try? FileManager.default.removeItem(at: real) }
    let holder = try makeRoot()
    defer { try? FileManager.default.removeItem(at: holder) }

    // The walk starts at the root's CHILDREN, so a root that is itself a link was never
    // inspected: `cache/legacy -> ~/Documents/foreign` would put every "contained" file
    // outside the intended store, and we delete what we match.
    let bytes = Data("victim".utf8)
    try stage(real, "a.bin", bytes)
    let linkedRoot = holder.appendingPathComponent("legacy")
    try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: real)

    let spy = HashSpy()
    let verdicts = try await LegacyRetirement.fingerprint(
      root: linkedRoot, files: [trusted("a.bin", bytes)], hashFile: spy.callback)

    #expect(verdicts["a.bin"] == .mismatch, "a symlinked root is not a store we may retire")
    #expect(await spy.count == 0)

    let result = LegacyRetirement.unlinkUnchanged(
      root: linkedRoot, verdicts: ["a.bin": .match(identityOf(real.appendingPathComponent("a.bin")))])
    #expect(result.unlinked.isEmpty)
    #expect(
      FileManager.default.fileExists(atPath: real.appendingPathComponent("a.bin").path),
      "files behind a linked root must survive")
  }

  @Test func productionRemovalGoesThroughUnlinkatNotAPathRemove() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // No `removeItem` seam: this is the production path. It must still delete a real match,
    // which is what proves `unlinkVerified` is wired rather than silently preserving.
    let bytes = Data("mine".utf8)
    let url = try stage(root, "dir/a.bin", bytes)
    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("dir/a.bin", bytes)])

    let result = LegacyRetirement.unlinkUnchanged(root: root, verdicts: verdicts)

    #expect(result.unlinked == ["dir/a.bin"])
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test func aGrandparentSwappedForALinkAfterTheWalkCannotRedirectTheDelete() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let elsewhere = try makeRoot()
    defer { try? FileManager.default.removeItem(at: elsewhere) }

    // Depth matters: `O_NOFOLLOW` guards only the FINAL component, so swapping the immediate
    // PARENT is refused even by a naive path open, and a test that swaps the parent passes
    // with or without the fix. The real hole is a swapped GRANDPARENT -- in
    // `open("<root>/a/b", O_NOFOLLOW)`, only `b` is guarded and `a` is followed.
    //
    // What this test does and does not prove, stated because the difference is easy to
    // over-claim. Falsified both ways: remove BOTH the lstat walk and the openat pinning and
    // this deletes the file outside the root, so it guards real behavior. Remove only the
    // openat pinning and it still passes, because the lstat walk refuses this STATIC case on
    // its own. The openat walk's marginal value is the RACE between that walk and the open,
    // which no deterministic test can stage without an injection seam. So: this is a genuine
    // regression test for the static case, and it is NOT evidence for the pinning. Do not
    // delete the pinning on the strength of this test staying green.
    let bytes = Data("mine".utf8)
    try stage(root, "a/b/c.bin", bytes)
    let verdicts = try await LegacyRetirement.fingerprint(
      root: root, files: [trusted("a/b/c.bin", bytes)])
    guard case .match = verdicts["a/b/c.bin"] else {
      Issue.record("fixture must match before the swap")
      return
    }

    // Move the whole subtree out and leave a link named `a` pointing at it. The leaf's inode
    // is unchanged, so the identity check still matches: only pinning the ancestors refuses.
    let victimTree = elsewhere.appendingPathComponent("a")
    try FileManager.default.moveItem(at: root.appendingPathComponent("a"), to: victimTree)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("a"), withDestinationURL: victimTree)

    let result = LegacyRetirement.unlinkUnchanged(root: root, verdicts: verdicts)

    #expect(result.unlinked.isEmpty)
    #expect(
      FileManager.default.fileExists(atPath: victimTree.appendingPathComponent("b/c.bin").path),
      "the file must survive: it now lives outside the retirement root")
  }

  // MARK: - Containment

  @Test func containmentAcceptsAnHonestNestedPathAndRejectsAnEscape() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(LegacyRetirement.isContained(root.appendingPathComponent("a/b"), within: root))
    #expect(LegacyRetirement.isContained(root, within: root))
    #expect(!LegacyRetirement.isContained(root.appendingPathComponent("../escape"), within: root))
  }

  @Test func containmentRejectsASymlinkEscapingTheRoot() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let elsewhere = try makeRoot()
    defer { try? FileManager.default.removeItem(at: elsewhere) }

    // Resolve-then-compare: this escapes in fact while comparing fine as a string.
    let link = root.appendingPathComponent("out")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)

    #expect(!LegacyRetirement.isContained(link, within: root))
  }

  // MARK: - Marker

  @Test func markerWritesReadsAndClearsIdempotently() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let marker = root.appendingPathComponent("nested/deeper/owed")
    #expect(LegacyRetirement.writeMarkerAtomically(marker), "must create intermediate dirs")
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(try Data(contentsOf: marker).isEmpty, "the marker is zero-byte")

    try LegacyRetirement.clearMarker(marker)
    #expect(!FileManager.default.fileExists(atPath: marker.path))

    // Clearing an absent marker is success: the postcondition the caller needs already holds.
    try LegacyRetirement.clearMarker(marker)
  }

  @Test func markerWriteReportsFailureRatherThanThrowing() throws {
    // A caller that cannot write the marker must delete nothing — that is a decision it makes
    // from a Bool, not an error it catches.
    let unwritable = URL(fileURLWithPath: "/System/nope-\(UUID().uuidString)/owed")
    #expect(!LegacyRetirement.writeMarkerAtomically(unwritable))
  }

  // MARK: - OS semantic (freezes §8.3)

  @Test func unlinkingAMappedFileLeavesTheMappingReadable() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let payload = Data(repeating: 0x5A, count: 64 * 1_024)
    let url = try stage(root, "mapped.bin", payload)

    let fd = open(url.path, O_RDONLY)
    #expect(fd >= 0)
    defer { close(fd) }
    let mapped = mmap(nil, payload.count, PROT_READ, MAP_PRIVATE, fd, 0)
    #expect(mapped != MAP_FAILED)
    defer { munmap(mapped, payload.count) }

    try FileManager.default.removeItem(at: url)

    // Removing a directory entry does not invalidate an existing mapping; the inode lives
    // until the last reference closes. This design only unlinks — it never truncates or
    // rewrites in place, which is what actually SIGBUSes. Frozen here so a future session
    // cannot re-derive the folklore from memory and rebuild a design around it.
    let seen = UnsafeRawBufferPointer(start: mapped, count: payload.count)
    #expect(seen.allSatisfy { $0 == 0x5A }, "the mapping must survive the unlink")
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }
}
