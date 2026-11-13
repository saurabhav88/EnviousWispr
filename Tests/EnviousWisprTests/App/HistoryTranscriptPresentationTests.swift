import AppKit
import CoreTransferable
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers

@testable import EnviousWisprAppKit
@testable import EnviousWisprStorage

/// #3147 PR3 lane B: what an imported transcript's card, full view and dock say and hand over.
/// What fails when these fail is a card that hides a status the old row showed, a promise that a
/// missing file plays (or a claim that a file was verified), a Share or Save that delivers text
/// for a row that changed or was deleted, or time buttons that keep driving a stopped player.
@MainActor
@Suite("History transcript card and full view (#3147 PR3)", .tags(.productOutcome))
struct HistoryTranscriptPresentationTests {
  typealias P = HistoryTranscriptPresentation

  private static func turn(_ id: String, _ speaker: String, _ range: Range<Int>, startMs: Int?)
    -> Turn
  {
    Turn(
      id: id, speakerId: speaker, startMs: startMs, endMs: nil, originalTextRange: range,
      processedText: nil, wasPolished: true)
  }

  // MARK: - Card inventory

  @Test("the card keeps every status the legacy row showed, in its order")
  func chipInventory() {
    let row = Transcript(
      text: "hello there", polishedText: "Hello there.", backendType: .parakeet,
      llmModel: "gpt-x", isRecovered: true, inputDeviceWasRemoved: true,
      importedFileName: "call.m4a", speakerNames: ["s2": "Zach", "s1": "Ariana"])
    #expect(
      P.chips(for: row) == [
        .file("call.m4a"), .speakers("Ariana, Zach"), .recovered, .interrupted,
        .polish(model: "gpt-x"), .backend(ASRBackendType.parakeet.displayName),
      ])
    // No polish, no speakers, no flags: only the file and the engine.
    let plain = Transcript(text: "x", backendType: .whisper, importedFileName: "a.wav")
    #expect(P.chips(for: plain) == [.file("a.wav"), .backend(ASRBackendType.whisper.displayName)])
    // A recorded model without polished text is not polish provenance.
    let unpolished = Transcript(text: "x", llmModel: "gpt-x", importedFileName: "a.wav")
    #expect(P.chips(for: unpolished).contains(.polish(model: "gpt-x")) == false)
  }

  @Test("the card's title is the file name and its length is the source duration")
  func titleAndLength() {
    let row = Transcript(text: "x", duration: 724, importedFileName: "talk.mp4")
    #expect(P.title(for: row) == "talk.mp4")
    #expect(P.lengthLine(for: row)?.contains("12:04") == true)
    #expect(P.lengthLine(for: Transcript(text: "x", importedFileName: "a.wav")) == nil)
  }

  // MARK: - Original file copy

  @Test("each source state maps to one honest line; only a missing original offers Locate")
  func sourceLines() throws {
    let url = URL(fileURLWithPath: "/tmp/a.m4a")
    let resolved = ResolvedImportedSource(
      rowID: UUID(), reference: ImportedSourceReference(bookmark: nil, fingerprint: "v1:1:1:aa"),
      url: url, identity: ImportedSourceIdentity(byteCount: 1, durationMs: 1, digest: "aa"))
    #expect(P.sourceLine(state: nil, playable: false) == .checking)
    #expect(P.sourceLine(state: .available(resolved), playable: true) == .plays)
    #expect(P.sourceLine(state: .available(resolved), playable: false) == .unavailable(.cannotPlay))
    #expect(P.sourceLine(state: .missing, playable: false) == .unavailable(.missing))
    #expect(P.sourceLine(state: .changed, playable: false) == .unavailable(.changed))
    #expect(P.sourceLine(state: .unreadable, playable: false) == .unavailable(.unreadable))
    #expect(P.sourceLine(state: .unverifiable(url), playable: false) == .unavailable(.unproven))
    #expect(P.sourceLine(state: .unverifiable(url), playable: true) == .plays)
    #expect(
      P.sourceLine(state: .unsupportedIdentity, playable: false) == .unavailable(.unsupported))
    #expect(P.sourceLine(state: .removed, playable: false) == .removed)

    #expect(P.offersLocate(.plays) == false)
    #expect(P.offersLocate(.checking) == false)
    #expect(P.offersLocate(.removed) == false)
    #expect(P.offersLocate(.unavailable(.missing)))
    #expect(P.cardLine(.checking) == nil, "nothing is claimed before the lookup answers")
  }

  @Test("no line claims a moved file or a verified one")
  func noUnprovenClaims() {
    let reasons: [P.UnavailableReason] = [
      .missing, .changed, .unreadable, .unproven, .unsupported, .cannotPlay,
    ]
    let lines =
      reasons.map(P.unavailableLine) + reasons.map(P.dockUnavailableLine)
      + [ImportedRelocationOutcome.linked, .wrongFile, .stale, .removed].compactMap(
        P.relocationLine)
    for line in lines {
      let lower = line.lowercased()
      #expect(lower.contains("moved") == false, "\(line)")
      #expect(lower.contains("verif") == false, "\(line)")
      #expect(lower.contains("renamed") == false, "\(line)")
    }
    #expect(P.unavailableLine(.missing).contains("unavailable"))
    #expect(P.dockUnavailableLine(.missing).contains("reading only"))
  }

  @Test("Locate original asks first only for a row with no stored identity")
  func locateConfirmation() {
    let legacy = Transcript(text: "x", importedFileName: "a.wav")
    let known = Transcript(text: "x", importedFileName: "a.wav", sourceFingerprint: "v1:1:1:aa")
    #expect(P.locateNeedsConfirmation(legacy))
    #expect(P.locateNeedsConfirmation(known) == false)
    #expect(P.relocationLine(.confirmationRequired) == nil, "the confirmation is asked instead")
  }

  // MARK: - Header and fallback

  @Test("the header names the model and AI Polished only from real polish provenance")
  func provenance() {
    let polished = Transcript(text: "a", polishedText: "A.", llmModel: "m", importedFileName: "f")
    #expect(P.provenance(for: polished).polishModel == "m")
    #expect(P.provenance(for: polished).aiPolished)
    let processed = Transcript(text: "a", llmModel: "m", importedFileName: "f", processedText: "A")
    #expect(P.provenance(for: processed).polishModel == nil)
    #expect(P.provenance(for: processed).aiPolished == false)
  }

  @Test("nil and empty turns fall back to the plain document, Processed never reads as polished")
  func plainFallback() {
    let raw = Transcript(text: "raw words", importedFileName: "f")
    #expect(P.plainDocument(for: raw) == .raw("raw words"))
    #expect(P.hasRenderableTurns(raw) == false)
    let empty = Transcript(text: "raw", importedFileName: "f", turns: [])
    #expect(P.hasRenderableTurns(empty) == false)
    let processed = Transcript(text: "raw", importedFileName: "f", processedText: "Raw.")
    #expect(P.plainDocument(for: processed) == .processed(output: "Raw.", original: "raw"))
    let polished = Transcript(
      text: "raw", polishedText: "Polished.", importedFileName: "f", processedText: "Raw.")
    #expect(P.plainDocument(for: polished) == .polished(output: "Polished.", original: "raw"))
    let turned = Transcript(
      text: "hi", importedFileName: "f", turns: [Self.turn("t1", "s1", 0..<2, startMs: 0)])
    #expect(P.hasRenderableTurns(turned))
  }

  @Test("rename and diff state is keyed by the row and its import attempt")
  func documentKey() {
    let id = UUID()
    let first = Transcript(id: id, text: "a", importedFileName: "f", importAttemptID: UUID())
    let replaced = first.withImportAttempt(UUID())
    #expect(P.DocumentKey(first) != P.DocumentKey(replaced))
    #expect(
      P.DocumentKey(first) == P.DocumentKey(first.withSource(bookmark: Data(), fingerprint: nil)))
  }

  // MARK: - Dock

  @Test("back and forward 15 seconds stay inside the recording")
  func skips() {
    #expect(P.skip(from: 10_000, by: -P.skipMs, durationMs: 60_000) == 0)
    #expect(P.skip(from: 20_000, by: -P.skipMs, durationMs: 60_000) == 5_000)
    #expect(P.skip(from: 50_000, by: P.skipMs, durationMs: 60_000) == 60_000)
    #expect(P.skip(from: 0, by: P.skipMs, durationMs: 60_000) == 15_000)
  }

  @Test("the speed menu shows the shared five speeds, and the main button follows the player")
  func dockLabels() {
    #expect(MeetingPlaybackController.playbackRates.map(P.rateLabel).count == 5)
    #expect(P.rateLabel(1).hasPrefix("1") && P.rateLabel(1).hasSuffix("×"))
    #expect(P.rateLabel(1.25).contains("25"))
    #expect(P.playAction(for: .playing) == .pause)
    #expect(P.playAction(for: .finished) == .replay)
    #expect(P.playAction(for: .paused) == .play)
    #expect(P.playAction(for: .idle) == .play)
  }

  @Test("a new player replaces a stopped one or another file's, and keeps a working one")
  func playerReplacement() {
    let a = ResolvedImportedSource(
      rowID: UUID(), reference: ImportedSourceReference(bookmark: nil, fingerprint: nil),
      url: URL(fileURLWithPath: "/tmp/a.m4a"),
      identity: ImportedSourceIdentity(byteCount: 1, durationMs: 1, digest: "a"))
    let b = ResolvedImportedSource(
      rowID: a.rowID, reference: a.reference, url: URL(fileURLWithPath: "/tmp/b.m4a"),
      identity: ImportedSourceIdentity(byteCount: 2, durationMs: 2, digest: "b"))
    let player = MeetingPlaybackController(
      media: .transcript(Tone()), durationMs: 1_000,
      output: MeetingPlaybackControllerTests.FakeOutput())
    #expect(P.needsNewPlayer(current: nil, currentSource: nil, resolved: a))
    #expect(P.needsNewPlayer(current: player, currentSource: a, resolved: a) == false)
    #expect(P.needsNewPlayer(current: player, currentSource: a, resolved: b))
    player.stopForDeletion()
    #expect(P.needsNewPlayer(current: player, currentSource: a, resolved: a))
  }

  @Test("the dock is the mock's 88 points, playing or not")
  func dockHeight() {
    let player = MeetingPlaybackController(
      media: .transcript(Tone()), durationMs: 90_000,
      output: MeetingPlaybackControllerTests.FakeOutput())
    for content in [
      HistoryTranscriptPlayerBar.Content.player(player),
      .unavailable(.missing, onLocate: {}),
    ] {
      let host = NSHostingView(
        rootView: HistoryTranscriptPlayerBar(content: content).frame(width: 750))
      #expect(host.fittingSize.height == HistoryTranscriptPlayerBar.height)
    }
  }

  // MARK: - Turn time buttons

  @Test("an original that becomes playable, or a new player, redraws the turn document")
  func playerIdentityInInputs() {
    let turns = [Self.turn("t1", "s1", 0..<2, startMs: 1_000)]
    func inputs(_ identity: ObjectIdentifier?) -> TranscriptTurnsDocument.Inputs {
      TranscriptTurnsDocument.Inputs(
        rowID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, text: "hi",
        turns: turns, speakerNames: [:], language: nil, isMeeting: false, mode: .cleaned,
        timesOn: true, documentFinished: true, playerIdentity: identity)
    }
    let first = MeetingPlaybackController(
      media: .transcript(Tone()), durationMs: 1_000,
      output: MeetingPlaybackControllerTests.FakeOutput())
    let second = MeetingPlaybackController(
      media: .transcript(Tone()), durationMs: 1_000,
      output: MeetingPlaybackControllerTests.FakeOutput())
    #expect(inputs(nil) == inputs(nil))
    #expect(inputs(nil) != inputs(ObjectIdentifier(first)))
    #expect(inputs(ObjectIdentifier(first)) == inputs(ObjectIdentifier(first)))
    #expect(inputs(ObjectIdentifier(first)) != inputs(ObjectIdentifier(second)))
    // The wizard and the legacy detail never set a player: no play control by default.
    let legacy = TranscriptTurnsDocument.Inputs(
      rowID: UUID(), text: "hi", turns: turns, speakerNames: [:], language: nil, isMeeting: false,
      mode: .cleaned, timesOn: true, documentFinished: true)
    #expect(legacy.playerIdentity == nil)
  }

  // MARK: - Transcribe again with

  @Test("Transcribe again with progress and every outcome have their own line")
  func retranscriptionLines() {
    #expect(P.retranscriptionLine(.idle) == nil)
    #expect(P.retranscriptionLine(.running(fraction: nil)) != nil)
    #expect(P.retranscriptionLine(.running(fraction: 0.42))?.contains("42") == true)
    #expect(P.retranscriptionLine(.cancelling) != nil)
    let outcomes: [ImportedRetranscriptionOutcome] = [
      .replaced, .busy, .sourceUnavailable, .stale, .cancelled, .failed,
    ]
    #expect(Set(outcomes.map(P.outcomeLine)).count == outcomes.count)
    #expect(P.isBusy(.running(fraction: nil)) && P.isBusy(.cancelling))
    #expect(P.isBusy(.finished(.failed)) == false)
    #expect(P.isFailure(.finished(.failed)) && P.isFailure(.finished(.stale)))
    #expect(P.isFailure(.finished(.replaced)) == false)
    #expect(P.isFailure(.finished(.cancelled)) == false)
  }

  // MARK: - Delivery

  @available(macOS 15.2, *)
  @Test(
    "Share reads the export when the receiver asks: a later edit is delivered, a deletion refused")
  func deferredShare() async throws {
    try await withCoordinator { coordinator in
      let attempt = UUID()
      let row = Transcript(
        text: "hello world", importedFileName: "call.m4a", speakerAnalysis: .labeled(count: 1),
        speakerNames: ["s1": "Ariana"],
        turns: [Self.turn("t1", "s1", 0..<11, startMs: 0)], importAttemptID: attempt)
      try await coordinator.saveAndShow(row)
      let item = DeliverableText {
        HistoryTranscriptExport.text(
          rowID: row.id, coordinator: coordinator, mode: .cleaned, timesOn: false)
      }
      // A rename lands after the Share item exists (rename is the shared command).
      let failure = await coordinator.renameSpeaker(
        id: row.id, speakerId: "s1", name: "Zach", isMeeting: false)
      #expect(failure == nil)
      let shared = String(decoding: try await Self.exportInBackground(item), as: UTF8.self)
      #expect(shared.contains("Zach"))
      #expect(shared.contains("Ariana") == false)

      _ = await coordinator.deleteHistoryItem(id: .transcript(row.id), kind: .textAndRecordings)
      await #expect(throws: (any Error).self) { try await Self.exportInBackground(item) }
    }
  }

  @Test(
    "Save's text, read after the panel, is nil once the row is gone; Paste never takes the view mode"
  )
  func saveAndPasteReads() async throws {
    try await withCoordinator { coordinator in
      let row = Transcript(
        text: "hello world", importedFileName: "call.m4a", speakerNames: ["s1": "Ariana"],
        turns: [Self.turn("t1", "s1", 0..<11, startMs: 0)])
      try await coordinator.saveAndShow(row)
      let original = HistoryTranscriptExport.text(
        rowID: row.id, coordinator: coordinator, mode: .original, timesOn: true)
      #expect(original?.contains("Ariana") == true, "the export keeps turn labels")
      let paste = HistoryTranscriptExport.pasteText(rowID: row.id, coordinator: coordinator)
      #expect(paste == "hello world", "Paste is the plain delivery text, not the labelled export")
      _ = await coordinator.deleteHistoryItem(id: .transcript(row.id), kind: .textAndRecordings)
      #expect(
        HistoryTranscriptExport.text(
          rowID: row.id, coordinator: coordinator, mode: .cleaned, timesOn: true) == nil)
      #expect(HistoryTranscriptExport.pasteText(rowID: row.id, coordinator: coordinator) == nil)
    }
  }

  // MARK: - Card lookup

  @Test("the card looks up the original when it appears and again when the owner bumps the row")
  func cardLookup() async throws {
    try await withCoordinator { coordinator in
      let row = Transcript(text: "hello", importedFileName: "call.m4a")
      try await coordinator.saveAndShow(row)
      let sources = FakeSources()
      sources.answer = .missing
      let host = NSHostingView(
        rootView: HistoryTranscriptCard(
          rowID: row.id, sources: sources, onOpen: {}, onLocate: {}
        )
        .environment(coordinator)
        .frame(width: 600))
      host.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
      let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      window.contentView = host
      defer { window.contentView = nil }
      host.layoutSubtreeIfNeeded()
      await MeetingCoordinatorTests.eventually("first lookup") { sources.lookups >= 1 }
      let before = sources.lookups
      sources.bump(row.id)
      host.layoutSubtreeIfNeeded()
      await MeetingCoordinatorTests.eventually("lookup after the revision bump") {
        sources.lookups > before
      }
      #expect(sources.playbackRequests == 0, "the card never opens a player")
    }
  }

  // MARK: - Fixtures

  final class Tone: PlaybackWindowAudio, @unchecked Sendable {
    func window(startMs: Int, count: Int) throws -> [Float] {
      [Float](repeating: 0, count: count * 16)
    }
  }

  /// The source owner as the card and view consume it; never a production implementation.
  @MainActor @Observable
  final class FakeSources: ImportedSourceAccessing {
    var answer: ImportedSourceState = .missing
    private(set) var lookups = 0
    private(set) var playbackRequests = 0
    private var revisions: [UUID: Int] = [:]

    func bump(_ rowID: UUID) { revisions[rowID, default: 0] += 1 }
    func revision(for rowID: UUID) -> Int { revisions[rowID, default: 0] }
    func state(for rowID: UUID) async -> ImportedSourceState {
      lookups += 1
      return answer
    }
    func playbackSource(for rowID: UUID) async throws -> ImportedPlaybackSource? {
      playbackRequests += 1
      return nil
    }
    func relocate(rowID: UUID, to url: URL, userConfirmed: Bool) async throws
      -> ImportedRelocationOutcome
    { .stale }
  }

  @available(macOS 15.2, *)
  @concurrent
  private static func exportInBackground(_ item: DeliverableText) async throws -> Data {
    try await item.exported(as: .plainText)
  }

  private func withCoordinator(
    _ operation: @MainActor (TranscriptCoordinator) async throws -> Void
  ) async throws {
    let directory = TestTemporaryDirectory.url
      .appendingPathComponent("ew-3147-lane-b-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let coordinator = TranscriptCoordinator(store: TranscriptStore(directory: directory))
    try await operation(coordinator)
  }
}
