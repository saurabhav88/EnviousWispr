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

  /// A decoded file of a given length, with plausible metadata. The Upload step
  /// shows every one of these fields, so a fixture that returned only samples
  /// could not exercise the screen the user actually sees.
  nonisolated private static func decoded(seconds: Double) -> AudioFileDecoder.Decoded {
    AudioFileDecoder.Decoded(
      samples: Array(repeating: 0.1, count: Int(seconds * 16_000)),
      seconds: seconds, byteCount: Int64(seconds * 32_000), codec: "AAC",
      sampleRate: 44_100, channelCount: 1)
  }

  private static func outcome(_ text: String) -> FileImportRunner.PartOutcome {
    FileImportRunner.PartOutcome(text: text, polishedText: text, polishError: nil)
  }

  private func makeCoordinator(
    lease: EngineLease,
    decode: @escaping @Sendable (URL) async throws -> AudioFileDecoder.Decoded = { _ in
      Self.decoded(seconds: 1.0)
    },
    transcribe: @escaping @MainActor ([Float]) async throws -> String = { _ in "One. Two. Three." },
    processPart: @escaping @MainActor (String) async throws -> FileImportRunner.PartOutcome = {
      Self.outcome($0)
    },
    beginRun: @escaping @MainActor () -> FileImportCoordinator.RunConfiguration = {
      FileImportCoordinator.RunConfiguration(polishIsCloud: false, localPolishProvider: nil)
    },
    ensureEngineReady: @escaping @MainActor () async -> FileImportCoordinator.EngineReadiness = {
      .ready
    }
  ) -> FileImportCoordinator {
    FileImportCoordinator(
      decode: decode,
      transcribe: transcribe,
      engineAdmission: .live(lease: lease, as: .fileImport),
      ensureEngineReady: ensureEngineReady,
      beginRun: beginRun,
      processPart: processPart)
  }

  /// Drives a coordinator to a finished document, so a test about what happens
  /// AFTER a run does not restate the run.
  private func finishedCoordinator(
    lease: EngineLease, transcribe: @escaping @MainActor ([Float]) async throws -> String = { _ in
      "One. Two. Three."
    }
  ) async -> FileImportCoordinator {
    let coordinator = makeCoordinator(lease: lease, transcribe: transcribe)
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    await settleUntil { coordinator.state == .finished }
    await settleUntil { coordinator.isEngineHeld == false }
    return coordinator
  }

  // MARK: - The engine the user picked has to be the engine that runs

  /// **The Review step promises an engine by name.** Choosing All Languages
  /// without its model downloaded leaves the app's active engine unchanged, so
  /// the import ran the fast English engine while the screen said otherwise —
  /// silently, with a plausible transcript. Nothing about the output says which
  /// engine produced it, which is why this is a refusal and not a fallback.
  @Test(
    "an import refuses rather than running an engine the user did not pick",
    arguments: [
      (FileImportCoordinator.EngineReadiness.notInstalled,
       FileImportCoordinator.FileImportRejection.engineNotInstalled),
      (.notReady, .engineNotReady),
    ])
  func refusesWhenTheChosenEngineIsNotReady(
    _ readiness: FileImportCoordinator.EngineReadiness,
    _ expected: FileImportCoordinator.FileImportRejection
  ) async {
    var transcribed = false
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      transcribe: { _ in
        transcribed = true
        return "Should never run."
      },
      ensureEngineReady: { readiness })
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }

    coordinator.start()
    await settleUntil { coordinator.state == .rejected(expected) }

    #expect(coordinator.state == .rejected(expected))
    #expect(transcribed == false, "the import transcribed on an engine it was told was not ready")
    #expect(
      coordinator.step == .upload,
      "the refusal landed on a step that does not render one")
  }

  /// The claim is taken only AFTER the engine is confirmed, so a refused import
  /// must not be holding it — otherwise the next dictation is blocked by a run
  /// that never happened.
  @Test("a refused import holds nothing")
  func aRefusedImportHoldsNothing() async {
    let lease = EngineLease()
    let coordinator = makeCoordinator(lease: lease, ensureEngineReady: { .notInstalled })
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }

    coordinator.start()
    await settleUntil { coordinator.state == .rejected(.engineNotInstalled) }

    #expect(coordinator.isEngineHeld == false)
    #expect(lease.currentHolder == nil, "a refused import left the engine claimed")
  }

  // MARK: - What the finished screen lets the user do

  /// **Copy and Save must hand over what the page is showing.** Stopping inside
  /// the first passage leaves no finished parts and a full raw transcript, which
  /// Done renders — and Copy used to put nothing on the clipboard while Save
  /// wrote an empty file over the user's only copy.
  @Test("the exported document is the words on screen, not an empty string")
  func exportMatchesWhatIsRendered() async {
    let lease = EngineLease()
    let gate = PartGate()
    let coordinator = makeCoordinator(
      lease: lease,
      transcribe: { _ in "The whole recording, transcribed." },
      processPart: { text in
        await gate.wait()
        return Self.outcome(text)
      })
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.start()
    await settleUntil { !coordinator.rawTranscript.isEmpty }

    coordinator.stop()
    await gate.releaseAll()
    await settleUntil { coordinator.isEngineHeld == false }

    #expect(coordinator.parts.isEmpty, "the fixture did not reach the state under test")
    #expect(
      coordinator.documentText == "The whole recording, transcribed.",
      "Copy and Save would have handed the user an empty document")
  }

  /// A save the user believes happened, and did not, costs them the document:
  /// New transcription is the next button along and it clears everything.
  @Test("a failed save says so and a successful one names the file")
  func saveOutcomesAreReported() async {
    let coordinator = await finishedCoordinator(lease: EngineLease())
    #expect(coordinator.saveMessage == nil, "a run that has not been saved claims a save")

    coordinator.noteSaveFailed(CocoaError(.fileWriteOutOfSpace))
    #expect(coordinator.saveMessage?.contains("couldn't be saved") == true)
    #expect(
      coordinator.saveMessage?.contains("still here") == true,
      "the failure does not tell the user their words survived")

    coordinator.noteSaveSucceeded(fileName: "Meeting.txt")
    #expect(coordinator.saveMessage?.contains("Meeting.txt") == true)
  }

  // MARK: - Where the step bar may take you

  /// **The bar and the jump read ONE function**, so a step cannot look clickable
  /// and refuse. Before this, a finished run offered Working — an inactive
  /// progress bar with a dead Stop button and no route back to the document —
  /// and Upload, where Continue was refused because the state was finished.
  @Test("a finished run cannot navigate into Working or back to an empty Upload")
  func finishedRunNavigatesOnlyWhereSomethingWorks() async {
    let coordinator = await finishedCoordinator(lease: EngineLease())
    #expect(coordinator.step == .done)

    #expect(coordinator.canJump(to: .working) == false)
    #expect(coordinator.canJump(to: .upload) == false)
    #expect(coordinator.canJump(to: .done) == false)
    // Picking another polisher for the same words is a supported thing to do.
    #expect(coordinator.canJump(to: .polish))
    #expect(coordinator.canJump(to: .transcription))

    coordinator.jump(to: .working)
    #expect(coordinator.step == .done, "the bar took the user to a dead screen")
    coordinator.jump(to: .polish)
    #expect(coordinator.step == .polish)
  }

  /// The other direction, so a rule that refused everything would fail too.
  @Test("before any run the bar goes back to Upload and no further forward")
  func freshRunNavigatesBackwardsOnly() async {
    let coordinator = makeCoordinator(lease: EngineLease())
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    coordinator.advance()
    coordinator.advance()
    #expect(coordinator.step == .polish)

    #expect(coordinator.canJump(to: .upload))
    #expect(coordinator.canJump(to: .transcription))
    #expect(coordinator.canJump(to: .review) == false, "the bar skipped a step forward")
  }

  /// Change hands the user the choice instead of re-running what they already
  /// have. The document survives the move, which is the point of keeping it.
  @Test("Change returns to the Polish step with the document intact")
  func changeOffersAChoiceAndKeepsTheDocument() async {
    let coordinator = await finishedCoordinator(lease: EngineLease())
    let before = coordinator.documentText
    #expect(!before.isEmpty)

    coordinator.choosePolisherAgain()

    #expect(coordinator.step == .polish)
    #expect(coordinator.documentText == before, "Change threw the document away")
    #expect(!coordinator.rawTranscript.isEmpty, "Change lost the words a re-run needs")
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
          return Self.decoded(seconds: 10.0)
        }
        return Self.decoded(seconds: 1.0)
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
    // **Keeping the work is only half of it: the user has to be able to REACH
    // it.** Asserting the state alone passes against a screen still showing a
    // progress bar that will never move, beside a Stop button already pressed,
    // with Copy and Save on a step nothing navigates to.
    #expect(
      coordinator.step == .done,
      "stopping left the user on the progress screen with no way to the words it kept")
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

  /// **The finished document's disclosure must describe the run that produced it.**
  ///
  /// Cloud review found the page reading LIVE settings: start with a cloud polisher, switch to a local
  /// one, and the page claimed "Nothing is uploaded" over text that had just gone to the cloud. The
  /// coordinator now holds the frozen configuration and keeps it until a new run starts.
  @Test("the run's configuration is frozen at Start and survives the run")
  func runConfigurationIsFrozen() async {
    let lease = EngineLease()
    var cloud = true
    let coordinator = makeCoordinator(
      lease: lease,
      beginRun: {
        FileImportCoordinator.RunConfiguration(
          polishIsCloud: cloud, localPolishProvider: cloud ? nil : .egOne)
      })
    coordinator.choose(url: Self.anyURL)
    await settleUntil { if case .ready = coordinator.state { return true } else { return false } }

    coordinator.start()
    await settleUntil { coordinator.state == .finished }
    #expect(coordinator.runConfiguration?.polishIsCloud == true)

    // The user now picks a local polisher. The FINISHED document was still
    // produced by the cloud one, so the disclosure must not change.
    cloud = false
    #expect(
      coordinator.runConfiguration?.polishIsCloud == true,
      "the finished document's disclosure changed under it")

    // A NEW run adopts the new choice, and pins its local server while running.
    coordinator.rePolish()
    await settleUntil { coordinator.state == .finished }
    #expect(coordinator.runConfiguration?.polishIsCloud == false)

    // **The pin follows the ENGINE, not the screen.** The document is on screen
    // before the run task has unwound, and in that window the polish server is
    // still this run's. Releasing the pin when the screen finished would let a
    // provider switch tear the server down under work still inside it.
    await settleUntil { coordinator.isEngineHeld == false }
    #expect(coordinator.pinnedLocalPolishProvider == nil, "a released run pins nothing")
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
        return Self.decoded(seconds: 1.0)
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
