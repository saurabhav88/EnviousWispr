import EnviousWisprASR
import EnviousWisprAppKitTestSupport
import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// History's access to imported files' originals (#3147 PR3, plan §3.5, §17 R2).
///
/// **When this fails, the user is told the original is there when it is gone or is a different
/// recording, plays the wrong file, links a different recording to the transcript, or hears
/// audio from an entry they just deleted.** Product coverage: real files on disk, the real
/// fingerprint reader, real bookmarks and the real History commands.
@MainActor
@Suite("Imported sources (#3147 PR3)", .tags(.productOutcome))
struct ImportedSourcesTests {

  /// Holds one identity read so a test can change the world while a lookup is in flight.
  @MainActor
  @Observable
  final class Probe {
    private(set) var identityCalls = 0
    private(set) var held = false
    @ObservationIgnored var holdOnCall: Int?
    /// Read off the main actor by the resolve step.
    nonisolated let staleFlag = OSAllocatedUnfairLock(initialState: false)
    var staleResolutions: Bool {
      get { staleFlag.withLock { $0 } }
      set { staleFlag.withLock { $0 = newValue } }
    }
    @ObservationIgnored private var waiter: CheckedContinuation<Void, Never>?

    func identityCalled() async {
      identityCalls += 1
      guard identityCalls == holdOnCall else { return }
      held = true
      await withCheckedContinuation { waiter = $0 }
    }

    func release() {
      held = false
      waiter?.resume()
      waiter = nil
    }
  }

  struct Rig {
    let dir: URL
    let coordinator: TranscriptCoordinator
    let arbiter: PlaybackArbiter
    let probe: Probe
    let sources: ImportedSources
  }

  private func makeRig() throws -> Rig {
    let dir = try ImportedMediaFixture.directory()
    let coordinator = TranscriptCoordinator(
      store: TranscriptStore(directory: dir.appendingPathComponent("store", isDirectory: true)))
    let arbiter = PlaybackArbiter()
    coordinator.onImportedContentWillChange = { arbiter.stopForDeletion(.transcript($0)) }
    let probe = Probe()
    let live = ImportedSourceIO.live
    let io = ImportedSourceIO(
      resolve: { data in
        guard let resolution = live.resolve(data) else { return nil }
        let stale = probe.staleFlag.withLock { $0 }
        return .init(url: resolution.url, isStale: resolution.isStale || stale)
      },
      fileExists: live.fileExists,
      identity: { url in
        await probe.identityCalled()
        return try await live.identity(url)
      },
      makeBookmark: live.makeBookmark,
      openAudio: live.openAudio)
    let sources = ImportedSources(coordinator: coordinator, arbiter: arbiter, io: io)
    return Rig(dir: dir, coordinator: coordinator, arbiter: arbiter, probe: probe, sources: sources)
  }

  /// An import row linked to `url` exactly as the import links it.
  private func importRow(linkedTo url: URL?, rig: Rig) async throws -> Transcript {
    var bookmark: Data?
    var fingerprint: String?
    if let url {
      bookmark = try ImportedSourceIO.live.makeBookmark(url)
      fingerprint = try await ImportedSourceFingerprint.read(url: url).fingerprint
    }
    let row = Transcript(
      text: "words", importedFileName: url?.lastPathComponent ?? "old.wav",
      sourceBookmark: bookmark, sourceFingerprint: fingerprint, importAttemptID: UUID())
    try await rig.coordinator.saveAndShow(row)
    return row
  }

  private func eventually(_ label: String, _ condition: @escaping @MainActor () -> Bool) async {
    await MeetingCoordinatorTests.eventually(label, condition)
  }

  private func url(of state: ImportedSourceState) -> URL? {
    if case .available(let resolved) = state { return resolved.url }
    return nil
  }

  // MARK: - States

  @Test("a linked original is available, read once and then answered from the cache")
  func availableAndCached() async throws {
    let rig = try makeRig()
    let file = try ImportedMediaFixture.write(.wav16kMono, seconds: 1, in: rig.dir)
    let row = try await importRow(linkedTo: file, rig: rig)

    let first = await rig.sources.state(for: row.id)
    #expect(url(of: first)?.standardizedFileURL.path == file.standardizedFileURL.path)
    let revision = rig.sources.revision(for: row.id)
    #expect(await rig.sources.state(for: row.id) == first)
    #expect(rig.sources.lookupsStarted == 1, "the second look is the cache")
    #expect(rig.sources.revision(for: row.id) == revision)
  }

  @Test("two windows asking at once share one disk lookup")
  func concurrentLookupsShare() async throws {
    let rig = try makeRig()
    let file = try ImportedMediaFixture.write(.wav16kMono, seconds: 1, in: rig.dir)
    let row = try await importRow(linkedTo: file, rig: rig)
    rig.probe.holdOnCall = 1
    async let a = rig.sources.state(for: row.id)
    async let b = rig.sources.state(for: row.id)
    await eventually("lookup held") { rig.probe.held }
    rig.probe.release()
    let (first, second) = await (a, b)
    #expect(first == second)
    #expect(rig.probe.identityCalls == 1)
    #expect(rig.sources.lookupsStarted == 1)
  }

  @Test("a moved original is found at its new place")
  func movedIsFound() async throws {
    let rig = try makeRig()
    let file = try ImportedMediaFixture.write(.m4aAAC44kStereo, seconds: 1, in: rig.dir)
    let row = try await importRow(linkedTo: file, rig: rig)
    let moved = rig.dir.appendingPathComponent("archive/talk-moved.m4a")
    try FileManager.default.createDirectory(
      at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: file, to: moved)

    let state = await rig.sources.state(for: row.id)
    #expect(url(of: state)?.standardizedFileURL.path == moved.standardizedFileURL.path)
  }

  @Test(
    "a stale link to the matching file is refreshed through the History command, keeping the fingerprint"
  )
  func staleRefreshed() async throws {
    let rig = try makeRig()
    let file = try ImportedMediaFixture.write(.wav16kMono, seconds: 1, in: rig.dir)
    let row = try await importRow(linkedTo: file, rig: rig)
    rig.probe.staleResolutions = true

    let state = await rig.sources.state(for: row.id)
    let stored = try #require(rig.coordinator.currentRow(id: row.id))
    #expect(stored.sourceFingerprint == row.sourceFingerprint)
    #expect(stored.sourceBookmark != nil)
    // The same file yields the same bookmark bytes, so the write itself is the evidence: the
    // command ran (it stops the row's players first, which the arbiter counts).
    #expect(rig.arbiter.deletionCount(for: .transcript(row.id)) == 1, "the refresh went through setImportedSource")
    guard case .available(let resolved) = state else {
      Issue.record("expected available, got \(state)")
      return
    }
    #expect(resolved.reference == ImportedSourceReference(stored))
  }

  @Test("a stale link to a DIFFERENT file is never refreshed and reads as changed")
  func staleButDifferentNotRefreshed() async throws {
    let rig = try makeRig()
    let file = try ImportedMediaFixture.write(.wav16kMono, seconds: 2, in: rig.dir)
    let row = try await importRow(linkedTo: file, rig: rig)
    try ImportedMediaFixture.write(.wav16kMono, seconds: 2, in: rig.dir, seed: 3)
    rig.probe.staleResolutions = true

    #expect(await rig.sources.state(for: row.id) == .changed)
    #expect(rig.coordinator.currentRow(id: row.id)?.sourceBookmark == row.sourceBookmark)
  }

  @Test("a deleted original reads missing, and Play finds that out even from a cached answer")
  func deletedIsMissing() async throws {
    let rig = try makeRig()
    let file = try ImportedMediaFixture.write(.wav16kMono, seconds: 1, in: rig.dir)
    let row = try await importRow(linkedTo: file, rig: rig)
    #expect(url(of: await rig.sources.state(for: row.id)) != nil)
    let revision = rig.sources.revision(for: row.id)
    try FileManager.default.removeItem(at: file)

    #expect(try await rig.sources.playbackSource(for: row.id) == nil)
    #expect(await rig.sources.state(for: row.id) == .missing)
    #expect(rig.sources.revision(for: row.id) != revision, "views learn the state changed")
  }

  @Test("a different recording at the original's place reads changed, never available")
  func replacedIsChanged() async throws {
    let rig = try makeRig()
    let file = try ImportedMediaFixture.write(.wav16kMono, seconds: 2, in: rig.dir)
    let row = try await importRow(linkedTo: file, rig: rig)
    // Same name, same length, different audio (written in place, as an editor's Save does).
    try ImportedMediaFixture.write(.wav16kMono, seconds: 2, in: rig.dir, seed: 5)
    #expect(await rig.sources.state(for: row.id) == .changed)
    #expect(try await rig.sources.playbackSource(for: row.id) == nil)
  }

  @Test("an original that is there but cannot be read reads unreadable")
  func unreadable() async throws {
    let rig = try makeRig()
    let file = try ImportedMediaFixture.write(.wav16kMono, seconds: 1, in: rig.dir)
    let row = try await importRow(linkedTo: file, rig: rig)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    }
    #expect(await rig.sources.state(for: row.id) == .unreadable)
  }

  @Test("no link reads missing; an unknown fingerprint version is never read as no fingerprint")
  func missingAndUnsupported() async throws {
    let rig = try makeRig()
    let legacy = try await importRow(linkedTo: nil, rig: rig)
    #expect(await rig.sources.state(for: legacy.id) == .missing)

    let file = try ImportedMediaFixture.write(.wav16kMono, seconds: 1, in: rig.dir)
    let future = Transcript(
      text: "w", importedFileName: "talk.wav",
      sourceBookmark: try ImportedSourceIO.live.makeBookmark(file), sourceFingerprint: "v9:1:2:ab")
    try await rig.coordinator.saveAndShow(future)
    #expect(await rig.sources.state(for: future.id) == .unsupportedIdentity)
    await #expect(throws: ImportedSourceError.unsupportedIdentity) {
      _ = try await rig.sources.relocate(rowID: future.id, to: file, userConfirmed: true)
    }
    #expect(await rig.sources.state(for: UUID()) == .removed)
  }

  // MARK: - Locate original

  @Test("a legacy entry adopts a file only after the user confirms")
  func legacyNeedsConfirmation() async throws {
    let rig = try makeRig()
    let row = try await importRow(linkedTo: nil, rig: rig)
    let file = try ImportedMediaFixture.write(.wav16kMono, seconds: 1, in: rig.dir)

    #expect(
      try await rig.sources.relocate(rowID: row.id, to: file, userConfirmed: false)
        == .confirmationRequired)
    #expect(rig.coordinator.currentRow(id: row.id)?.sourceBookmark == nil)
    #expect(try await rig.sources.relocate(rowID: row.id, to: file, userConfirmed: true) == .linked)
    let stored = try #require(rig.coordinator.currentRow(id: row.id))
    #expect(
      stored.sourceFingerprint == (try await ImportedSourceFingerprint.read(url: file)).fingerprint)
    #expect(url(of: await rig.sources.state(for: row.id)) != nil)
  }

  @Test("a known original takes only its own recording back, whatever the user confirms")
  func knownFingerprintMustMatch() async throws {
    let rig = try makeRig()
    let file = try ImportedMediaFixture.write(.m4aAAC44kStereo, seconds: 2, in: rig.dir)
    let row = try await importRow(linkedTo: file, rig: rig)
    let other = try ImportedMediaFixture.write(
      .m4aAAC44kStereo, seconds: 2, in: rig.dir, name: "other", seed: 2)
    let copy = rig.dir.appendingPathComponent("copy-of-talk.m4a")
    try FileManager.default.copyItem(at: file, to: copy)
    try FileManager.default.removeItem(at: file)

    #expect(
      try await rig.sources.relocate(rowID: row.id, to: other, userConfirmed: true) == .wrongFile)
    #expect(rig.coordinator.currentRow(id: row.id)?.sourceBookmark == row.sourceBookmark)
    #expect(
      try await rig.sources.relocate(rowID: row.id, to: copy, userConfirmed: false) == .linked)
    let state = await rig.sources.state(for: row.id)
    #expect(url(of: state)?.standardizedFileURL.path == copy.standardizedFileURL.path)
    #expect(rig.coordinator.currentRow(id: row.id)?.sourceFingerprint == row.sourceFingerprint)
  }

  @Test(
    "Locate original on an entry whose link changed meanwhile is stale; on a deleted one, removed")
  func relocateFences() async throws {
    let rig = try makeRig()
    let row = try await importRow(linkedTo: nil, rig: rig)
    let file = try ImportedMediaFixture.write(.wav16kMono, seconds: 1, in: rig.dir)
    rig.probe.holdOnCall = 1
    async let outcome = rig.sources.relocate(rowID: row.id, to: file, userConfirmed: true)
    await eventually("relocate held") { rig.probe.held }
    // Another window linked a file meanwhile.
    #expect(
      try await rig.coordinator.setImportedSource(
        bookmark: Data([9]), fingerprint: "v1:1:1:aa", for: row.id,
        expected: ImportedSourceReference(row), confirmedLegacy: true))
    rig.probe.release()
    #expect(try await outcome == .stale)
    #expect(rig.coordinator.currentRow(id: row.id)?.sourceBookmark == Data([9]))

    let gone = try await importRow(linkedTo: nil, rig: rig)
    _ = await rig.coordinator.deleteHistoryItem(id: .transcript(gone.id), kind: .textAndRecordings)
    #expect(
      try await rig.sources.relocate(rowID: gone.id, to: file, userConfirmed: true) == .removed)
  }

  // MARK: - Lookups that something overtook

  @Test("a lookup overtaken by a relink describes the new link")
  func lookupOvertakenByRelink() async throws {
    let rig = try makeRig()
    let first = try ImportedMediaFixture.write(.wav16kMono, seconds: 1, in: rig.dir, name: "first")
    let row = try await importRow(linkedTo: first, rig: rig)
    let moved = rig.dir.appendingPathComponent("moved-first.wav")
    rig.probe.holdOnCall = 1
    async let state = rig.sources.state(for: row.id)
    await eventually("lookup held") { rig.probe.held }
    // Meanwhile the row is relinked to a copy elsewhere (same recording, new bookmark).
    try FileManager.default.copyItem(at: first, to: moved)
    let fresh = try ImportedSourceIO.live.makeBookmark(moved)
    #expect(
      try await rig.coordinator.setImportedSource(
        bookmark: fresh, fingerprint: row.sourceFingerprint, for: row.id,
        expected: ImportedSourceReference(row), confirmedLegacy: false))
    rig.probe.release()
    guard case .available(let resolved) = await state else {
      Issue.record("expected available")
      return
    }
    #expect(resolved.reference.bookmark == fresh, "answered for the current link")
    #expect(resolved.url.standardizedFileURL.path == moved.standardizedFileURL.path)
    #expect(rig.probe.identityCalls == 2, "the overtaken lookup was redone")
  }

  @Test("Play that began before the entry was deleted never gets a player")
  func lateCompletionAfterDeletion() async throws {
    let rig = try makeRig()
    let file = try ImportedMediaFixture.write(.wav16kMono, seconds: 1, in: rig.dir)
    let row = try await importRow(linkedTo: file, rig: rig)
    rig.probe.holdOnCall = 1
    async let source = rig.sources.playbackSource(for: row.id)
    await eventually("lookup held") { rig.probe.held }
    _ = await rig.coordinator.deleteHistoryItem(id: .transcript(row.id), kind: .textAndRecordings)
    rig.probe.release()
    #expect(try await source == nil)
    #expect(await rig.sources.state(for: row.id) == .removed)
    #expect(
      FileManager.default.fileExists(atPath: file.path),
      "deleting an entry never deletes its original")
  }

  @Test("Play that began before Delete All stopped transcript players never gets a player")
  func lateCompletionAfterDeleteAllEpoch() async throws {
    let rig = try makeRig()
    let file = try ImportedMediaFixture.write(.wav16kMono, seconds: 1, in: rig.dir)
    let row = try await importRow(linkedTo: file, rig: rig)
    rig.probe.holdOnCall = 2  // the re-check after the reader opened
    async let source = rig.sources.playbackSource(for: row.id)
    await eventually("re-check held") { rig.probe.held }
    rig.arbiter.stopAllTranscriptsForDeletion()
    rig.probe.release()
    #expect(try await source == nil)
  }

  // MARK: - Playback

  @Test("Play opens the original itself, and nothing ever writes to it")
  func playbackOpensOriginalWithoutWriting() async throws {
    let rig = try makeRig()
    let file = try ImportedMediaFixture.write(.mp4AAC48kStereo, seconds: 2, in: rig.dir)
    let before = try ImportedMediaFixture.fingerprint(of: file)
    let row = try await importRow(linkedTo: file, rig: rig)
    rig.probe.staleResolutions = true  // exercise the refresh write too

    let source = try #require(try await rig.sources.playbackSource(for: row.id))
    #expect(abs(source.durationMs - 2_000) <= 50)
    let decoded = try await AudioFileDecoder.decode(url: file).samples
    let window = try source.audio.window(startMs: 0, count: 250)
    #expect(window == Array(decoded.prefix(4_000)))
    #expect(
      source.source.reference
        == ImportedSourceReference(try #require(rig.coordinator.currentRow(id: row.id))))
    _ = try await rig.sources.relocate(rowID: row.id, to: file, userConfirmed: false)
    #expect(try ImportedMediaFixture.fingerprint(of: file) == before)
    let names = try FileManager.default.contentsOfDirectory(atPath: rig.dir.path).sorted()
    #expect(
      names == ["store", file.lastPathComponent].sorted(), "no copy appeared beside the original")
  }

  @Test("a stale link is not refreshed while that entry is playing")
  func noRefreshWhilePlaying() async throws {
    let rig = try makeRig()
    let file = try ImportedMediaFixture.write(.wav16kMono, seconds: 3, in: rig.dir)
    let row = try await importRow(linkedTo: file, rig: rig)
    let source = try #require(try await rig.sources.playbackSource(for: row.id))
    let output = MeetingPlaybackControllerTests.FakeOutput()
    let player = MeetingPlaybackController(
      media: .transcript(source.audio), durationMs: source.durationMs, output: output,
      sourceID: .transcript(row.id), arbiter: rig.arbiter)
    player.play()
    #expect(rig.arbiter.isPlaying(.transcript(row.id)))
    rig.sources.invalidateAll()
    rig.probe.staleResolutions = true
    _ = await rig.sources.state(for: row.id)
    #expect(rig.coordinator.currentRow(id: row.id)?.sourceBookmark == row.sourceBookmark)
    #expect(player.state == .playing, "the player was not stopped by a refresh")
    player.stop()
  }
}
