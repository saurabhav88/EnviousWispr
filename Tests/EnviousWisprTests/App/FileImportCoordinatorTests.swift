import EnviousWisprASR
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2648 — the state machine behind Transcribe a File.
///
/// **When this fails, the user presses Stop and the screen carries on, or presses Stop and a dictation
/// is admitted while their import is still inside the polish server, or picks a second file and gets the
/// first one's transcript.** Product coverage.
@Suite(.tags(.productOutcome))
@MainActor
struct FileImportCoordinatorTests {

  // MARK: - A controllable part processor

  /// Lets a row hold a part inside the runner for as long as it wants, which is the only way to observe
  /// the property that matters: Stop changes the screen at once, and the claim waits for the work.
  private actor PartGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var enteredCount = 0

    var entered: Int { enteredCount }

    func wait() async {
      enteredCount += 1
      await withCheckedContinuation { continuations.append($0) }
    }

    func releaseAll() {
      let held = continuations
      continuations = []
      for continuation in held { continuation.resume() }
    }
  }

  /// A plain counter for rows that only need to know how many times something ran.
  private actor Counter {
    private var value = 0
    var count: Int { value }
    func bump() { value += 1 }
  }

  private static func outcome(_ text: String) -> FileImportRunner.PartOutcome {
    FileImportRunner.PartOutcome(text: text, polishedText: text, polishError: nil)
  }

  private func makeCoordinator(
    lease: EngineLease,
    decode: @escaping @Sendable (URL) async throws -> [Float] = { _ in
      Array(repeating: 0.1, count: 16_000)
    },
    transcribe: @escaping @MainActor ([Float]) async throws -> String = { _ in "One. Two. Three." },
    processPart: @escaping @MainActor (String) async throws -> FileImportRunner.PartOutcome = {
      Self.outcome($0)
    },
    beginRun: @escaping @MainActor () -> Void = {}
  ) -> FileImportCoordinator {
    FileImportCoordinator(
      decode: decode,
      transcribe: transcribe,
      engineAdmission: .live(lease: lease, as: .fileImport),
      beginRun: beginRun,
      processPart: processPart)
  }

  /// Yields until the condition holds, or gives up. `Task.yield()` rather than a sleep: everything
  /// here is main-actor work with no real waiting in it, so a clock would only make the suite slower
  /// and flakier.
  @discardableResult
  private func settleUntil(
    limit: Int = 500, _ condition: @MainActor () async -> Bool
  ) async -> Bool {
    for _ in 0..<limit {
      if await condition() { return true }
      await Task.yield()
    }
    return await condition()
  }

  private static let anyURL = URL(fileURLWithPath: "/tmp/recording.m4a")

  // MARK: - Choosing a file

  @Test("a file that cannot be read is refused, and no engine is touched")
  func unreadableFileIsRejected() async {
    let lease = EngineLease()
    let coordinator = makeCoordinator(
      lease: lease, decode: { _ in throw AudioFileDecoder.Rejection.unreadable })

    coordinator.choose(url: Self.anyURL)
    await settleUntil { coordinator.state == .rejected(.cannotRead) }

    #expect(coordinator.state == .rejected(.cannotRead))
    #expect(lease.isBusy == false, "a refused file must not have claimed the engine")
  }

  @Test("a file with no audio is refused by its own name")
  func noAudioFileIsRejected() async {
    let coordinator = makeCoordinator(
      lease: EngineLease(), decode: { _ in throw AudioFileDecoder.Rejection.noAudioTrack })

    coordinator.choose(url: Self.anyURL)
    await settleUntil { coordinator.state == .rejected(.noAudio) }

    #expect(coordinator.state == .rejected(.noAudio))
  }

  /// Picking a second file while the first is still being read is an ordinary thing to do. Without a
  /// generation bump on `choose`, whichever decode finishes last wins — which can be the file the user
  /// already replaced.
  @Test("a second file replaces the first, even if the first finishes reading later")
  func aSecondChoiceWinsRegardlessOfOrder() async {
    let slowFirst = PartGate()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      decode: { url in
        if url.lastPathComponent == "first.m4a" {
          await slowFirst.wait()
          return Array(repeating: 0.1, count: 160_000)
        }
        return Array(repeating: 0.1, count: 16_000)
      })

    coordinator.choose(url: URL(fileURLWithPath: "/tmp/first.m4a"))
    await settleUntil { await slowFirst.entered == 1 }
    coordinator.choose(url: URL(fileURLWithPath: "/tmp/second.m4a"))
    await settleUntil { coordinator.state == .ready(fileName: "second.m4a", seconds: 1.0) }

    // The first file's decode now finishes, late.
    await slowFirst.releaseAll()
    for _ in 0..<50 { await Task.yield() }

    #expect(
      coordinator.state == .ready(fileName: "second.m4a", seconds: 1.0),
      "a late decode from a replaced file overwrote the current one")
  }

  // MARK: - Starting

  @Test("start is refused while another workload holds the engine")
  func startRefusedWhileEngineHeld() async {
    let lease = EngineLease()
    let coordinator = makeCoordinator(lease: lease)
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    guard case .granted = lease.admit(.dictation) else {
      Issue.record("a fresh lease refused the first claim")
      return
    }

    coordinator.start()

    #expect(coordinator.state == .rejected(.engineBusy(.dictation)))
    #expect(lease.currentHolder == .dictation, "the refusal must not disturb the holder")
  }

  @Test("a finished run hands the engine back")
  func finishedRunReleasesTheEngine() async {
    let lease = EngineLease()
    let coordinator = makeCoordinator(lease: lease)
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }

    coordinator.start()
    await settleUntil { coordinator.state == .finished }

    #expect(coordinator.state == .finished)
    #expect(coordinator.parts.count == 1, "three short sentences pack into one part")
    #expect(lease.isBusy == false, "a finished run left the engine claimed")
  }

  @Test("no speech in the file is its own refusal, not an empty document")
  func noSpeechIsRejected() async {
    let lease = EngineLease()
    let coordinator = makeCoordinator(lease: lease, transcribe: { _ in "   " })
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }

    coordinator.start()
    await settleUntil { coordinator.state == .rejected(.noSpeechFound) }

    #expect(coordinator.state == .rejected(.noSpeechFound))
    #expect(lease.isBusy == false)
  }

  // MARK: - Stopping — the property the whole design is built around

  /// **Two guarantees, and they are separate.** The screen must stop at once, because the user pressed
  /// Stop. The claim must NOT come back until the work has physically left the engine, because a
  /// dictation admitted on top of a part still inside the polish server is the exact collision this
  /// feature exists to prevent.
  ///
  /// A test that only checked the visible state would pass against a design that released the claim in
  /// `stop()`, which is the mistake the plan's review round found.
  @Test("stop changes the screen at once and still holds the engine until the work exits")
  func stopIsImmediateButTheClaimWaits() async {
    let lease = EngineLease()
    let gate = PartGate()
    let coordinator = makeCoordinator(
      lease: lease,
      transcribe: { _ in "One. Two. Three." },
      processPart: { text in
        await gate.wait()
        return Self.outcome(text)
      })
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    await settleUntil { await gate.entered == 1 }

    coordinator.stop()

    // Immediately, with no awaiting in between.
    #expect(coordinator.state == .stopped)
    #expect(lease.isBusy, "the claim came back while a part was still inside the engine")

    // The part now finishes and the run task exits.
    await gate.releaseAll()
    await settleUntil { lease.isBusy == false }
    #expect(lease.isBusy == false, "the claim never came back after the work exited")
  }

  @Test("stop keeps what already finished")
  func stopKeepsFinishedParts() async {
    let lease = EngineLease()
    let gate = PartGate()
    let coordinator = makeCoordinator(
      lease: lease,
      // Long enough to split into several parts.
      transcribe: { _ in (0..<900).map { "word\($0)" }.joined(separator: " ") },
      processPart: { text in
        if await gate.entered >= 1 { await gate.wait() }
        return Self.outcome(text)
      })
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    await settleUntil { coordinator.parts.count == 1 }

    coordinator.stop()
    await gate.releaseAll()
    for _ in 0..<50 { await Task.yield() }

    #expect(coordinator.state == .stopped)
    #expect(
      coordinator.parts.count == 1, "stopping threw away work the user had already waited for")
  }

  /// A part that lands after Stop must not write into a run the user has ended.
  @Test("a late part from a stopped run cannot write into the document")
  func aLatePartCannotWrite() async {
    let lease = EngineLease()
    let gate = PartGate()
    let coordinator = makeCoordinator(
      lease: lease,
      processPart: { text in
        await gate.wait()
        return Self.outcome(text)
      })
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    await settleUntil { await gate.entered == 1 }

    coordinator.stop()
    await gate.releaseAll()
    for _ in 0..<50 { await Task.yield() }

    #expect(coordinator.parts.isEmpty, "a part from a stopped run reached the document")
    #expect(coordinator.state == .stopped, "a stopped run moved on to another state")
  }

  // MARK: - Changing the polisher

  /// **The file is never read a second time.** That is the whole reason the raw transcript is kept, and
  /// the decode call count is the oracle: a re-polish that re-read the file would show two.
  @Test("changing the polisher re-runs from the transcript, never from the file")
  func rePolishNeverReadsTheFileAgain() async {
    let lease = EngineLease()
    let decodes = Counter()
    let coordinator = makeCoordinator(
      lease: lease,
      decode: { _ in
        await decodes.bump()
        return Array(repeating: 0.1, count: 16_000)
      })

    coordinator.choose(url: Self.anyURL)
    await settleUntil { if case .ready = coordinator.state { return true } else { return false } }
    coordinator.start()
    await settleUntil { coordinator.state == .finished }
    #expect(await decodes.count == 1)

    coordinator.rePolish()
    await settleUntil { coordinator.state == .finished && !coordinator.parts.isEmpty }

    #expect(await decodes.count == 1, "changing the polisher read the file again")
    #expect(!coordinator.parts.isEmpty)
    #expect(lease.isBusy == false, "the re-polish left the engine claimed")
  }
}
