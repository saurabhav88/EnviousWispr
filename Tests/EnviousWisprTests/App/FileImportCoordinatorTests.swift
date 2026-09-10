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
  /// Counts calls made from a `@Sendable` closure. Same shape as `PartGate`
  /// below: a plain captured var is refused by strict concurrency, and a lock
  /// here would be a second way of doing what the suite already does once.
  private actor CallCounter {
    private var count = 0
    func record() { count += 1 }
    var value: Int { count }
  }

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
      FileImportCoordinator.RunConfiguration(
        polishIsCloud: false, localPolishProvider: nil, polishProvider: .egOne,
        ollamaModel: nil)
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
    // **Stays on Review, because nothing about the FILE needs redoing.** The
    // audio is decoded and in memory; sending the user to Upload made the only
    // recovery choosing the file again and paying the read a second time, which
    // on a long recording is the slowest part of the whole job.
    #expect(coordinator.step == .review, "an engine refusal sent the user back to the file picker")
    #expect(coordinator.canRetry, "the message says try again and nothing offers it")
  }

  /// **An abandoned read is STOPPED, not ignored.**
  ///
  /// The generation check answers "whose file is this" after the work is done,
  /// which is a different question from "should this still be running". A
  /// three-hour recording decodes to about 690 MB of samples, so picking a
  /// second file while the first was reading left both running and both arrays
  /// growing, to throw one away. Found by Codex.
  ///
  /// Asserted on the DECODER observing its own cancellation, not on the visible
  /// state: the screen looks identical either way, which is exactly why this
  /// went unnoticed.
  @Test("choosing another file stops the read already in progress")
  func replacingAFileCancelsItsRead() async {
    let started = PartGate()
    let cancelled = CallCounter()
    let coordinator = makeCoordinator(
      lease: EngineLease(),
      decode: { _ in
        // Park inside the decode, and record whether the wait ended because the
        // task was cancelled — which is what `AudioFileDecoder`'s own
        // `Task.checkCancellation()` would see.
        await started.wait()
        if Task.isCancelled { await cancelled.record() }
        try Task.checkCancellation()
        return Self.decoded(seconds: 1.0)
      })

    coordinator.choose(url: Self.anyURL)
    await settleUntil { await started.entered >= 1 }

    // The user picks a different file while the first is still reading.
    coordinator.choose(url: URL(fileURLWithPath: "/tmp/second.m4a"))
    await started.releaseAll()
    for _ in 0..<50 { await Task.yield() }

    #expect(
      await cancelled.value >= 1,
      "the abandoned read carried on to the end, holding its samples the whole way")
  }

  /// Try again does what it says: no second read, no second decode.
  @Test("retrying after a busy engine reuses the audio already in memory")
  func retryDoesNotReadTheFileAgain() async {
    let lease = EngineLease()
    let decodes = CallCounter()
    let coordinator = makeCoordinator(
      lease: lease,
      decode: { _ in
        await decodes.record()
        return Self.decoded(seconds: 1.0)
      })
    coordinator.choose(url: Self.anyURL)
    _ = await settleUntil {
      if case .ready = coordinator.state { return true } else { return false }
    }
    #expect(await decodes.value == 1)

    // Something else holds the engine, so Start is refused.
    guard case .granted(let token) = lease.admit(.dictation) else {
      Issue.record("the fixture could not take the engine")
      return
    }
    coordinator.advance()
    coordinator.advance()
    coordinator.advance()
    coordinator.advance()
    await settleUntil { coordinator.state == .rejected(.engineBusy(.dictation)) }
    #expect(coordinator.canRetry)

    // The engine frees up and the user presses Try again.
    lease.release(token)
    coordinator.retry()
    await settleUntil { coordinator.state == .finished }

    #expect(await decodes.value == 1, "Try again read the file a second time")
    #expect(!coordinator.rawTranscript.isEmpty)
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

  /// **Every mover reads ONE function**, so a step cannot look clickable and
  /// refuse, and no route can strand the document. Three rounds each found a
  /// different mover with its own rule: the BAR offered Working after a run,
  /// BACK walked from Polish to Upload where Continue is refused because the
  /// state is finished, and a REFUSAL sent the user to Upload, whose only offer
  /// is choosing another file — which clears the words they were trying to keep.
  ///
  /// **The property, stated once: from anywhere the user can reach, the finished
  /// document is still reachable.** The rows below check it by walking, not by
  /// restating the rule.
  @Test("a finished document stays reachable from every step the user can reach")
  func theDocumentIsNeverStranded() async {
    let coordinator = await finishedCoordinator(lease: EngineLease())
    #expect(coordinator.step == .done)
    let document = coordinator.documentText
    #expect(!document.isEmpty)

    // Dead ends are refused outright.
    #expect(coordinator.canGo(to: .working) == false)
    #expect(
      coordinator.canGo(to: .upload) == false,
      "Upload with a document offers only the thing that destroys it")

    // Walk every step the bar DOES offer, and from each one walk back.
    for target in [FileImportCoordinator.Step.transcription, .polish, .review] {
      #expect(coordinator.canGo(to: target), "\(target.title) is unreachable after a run")
      coordinator.jump(to: target)
      #expect(coordinator.step == target)
      #expect(
        coordinator.canGo(to: .done),
        "from \(target.title) there is no way back to the document")
      coordinator.jump(to: .done)
      #expect(coordinator.step == .done)
      #expect(coordinator.documentText == document, "the walk changed the document")
    }
  }

  /// The walk Codex found: Change, then Back, then Back again.
  @Test("walking Back from Change never leaves the document behind")
  func backFromChangeStaysReachable() async {
    let coordinator = await finishedCoordinator(lease: EngineLease())
    coordinator.choosePolisherAgain()
    #expect(coordinator.step == .polish)

    coordinator.goBack()
    #expect(coordinator.step == .transcription)
    coordinator.goBack()
    #expect(
      coordinator.step == .transcription,
      "Back walked onto Upload, where Continue is refused and the document is gone")
    #expect(coordinator.canGoBack == false, "Back is offered with nowhere to go")
    #expect(coordinator.canGo(to: .done))
  }

  /// A refusal must not cost the user the document either. Cleaning again while
  /// a dictation holds the engine is refused, and the refusal has to be readable
  /// somewhere the words still are.
  @Test("a refusal with a document in hand lands where the document is")
  func aRefusalKeepsTheDocumentReachable() async {
    let lease = EngineLease()
    let coordinator = await finishedCoordinator(lease: lease)
    let document = coordinator.documentText

    // Something else takes the engine, then the user asks to clean again.
    guard case .granted = lease.admit(.dictation) else {
      Issue.record("the fixture could not take the engine")
      return
    }
    coordinator.rePolish()

    #expect(coordinator.state == .rejected(.engineBusy(.dictation)))
    #expect(coordinator.step == .done, "the refusal stranded the finished document")
    #expect(coordinator.documentText == document, "the refusal ate the document")
  }

  // MARK: - The (step, state) matrix, enumerated

  /// **Every finding in rounds 2, 3 and 5 was ONE cell of this matrix**, found
  /// by a reviewer imagining a path: Working while rejected rendered no message,
  /// Done with no parts exported nothing, Upload while finished refused
  /// Continue, Done after an early Stop offered Copy over an empty clipboard.
  /// Four cells, three rounds, and each fix left the next cell invisible.
  ///
  /// So this row stops describing the set and ENUMERATES it. It drives the
  /// coordinator down every path the machine has and records the (step, state)
  /// pairs it actually reaches, then asserts two things of each:
  ///
  /// 1. **The pair is one somebody decided on.** A new one fails until it is
  ///    listed, which is the freeze.
  /// 2. **The user is not stuck**, and if a document exists it is reachable.
  ///
  /// The pairs come from RUNNING the machine, not from reading it. A list
  /// written by reading can only contain the paths the author thought of, which
  /// is exactly how the four cells above were missed.
  @Test("every reachable screen-and-state pair is one we chose, and none is a dead end")
  func theStepStateMatrixIsEnumerated() async {
    var seen: Set<String> = []

    func record(_ coordinator: FileImportCoordinator) {
      seen.insert("\(coordinator.step)/\(Self.label(for: coordinator.state))")
      // **Property 2, checked at every pair rather than at the end.** "Not
      // stuck" means: a run is in flight, or some step is reachable, or the
      // one-button reset is available. And a document, once it exists, is never
      // more than one move from the user.
      let canMove =
        coordinator.isRunning
        || FileImportCoordinator.Step.allCases.contains { coordinator.canGo(to: $0) }
        || coordinator.step == .upload
      #expect(
        canMove,
        "\(coordinator.step)/\(Self.label(for: coordinator.state)) has no way out")
      if coordinator.hasDocument, !coordinator.isRunning {
        #expect(
          coordinator.step == .done || coordinator.canGo(to: .done),
          "\(coordinator.step)/\(Self.label(for: coordinator.state)) strands the document")
      }
    }

    // Path A: the ordinary run, recorded at every step.
    let a = makeCoordinator(lease: EngineLease())
    record(a)
    a.choose(url: Self.anyURL)
    record(a)
    _ = await settleUntil { if case .ready = a.state { return true } else { return false } }
    record(a)
    a.advance(); record(a)
    a.advance(); record(a)
    a.advance(); record(a)
    a.advance()
    await settleUntil { a.state == .finished }
    await settleUntil { a.isEngineHeld == false }
    record(a)
    // Back through the choice steps with a document in hand.
    for target in [FileImportCoordinator.Step.review, .polish, .transcription] {
      a.jump(to: target)
      record(a)
    }
    a.jump(to: .done); record(a)
    a.startOver(); record(a)

    // Path B: a file that cannot be read.
    let b = makeCoordinator(
      lease: EngineLease(), decode: { _ in throw AudioFileDecoder.Rejection.noAudio })
    b.choose(url: Self.anyURL)
    await settleUntil { b.state == .rejected(.noAudio) }
    record(b)

    // Path C: the engine the user picked is not there. Lands on Review with the
    // audio still in hand, which is the `review/rejected` cell.
    let c = makeCoordinator(lease: EngineLease(), ensureEngineReady: { .notInstalled })
    c.choose(url: Self.anyURL)
    _ = await settleUntil { if case .ready = c.state { return true } else { return false } }
    c.advance(); c.advance(); c.advance(); c.advance()
    await settleUntil { c.state == .rejected(.engineNotInstalled) }
    record(c)

    // Path D: stopped BEFORE any words arrived, and stopped after some.
    for stopEarly in [true, false] {
      let gate = PartGate()
      let d = makeCoordinator(
        lease: EngineLease(),
        transcribe: { _ in
          if stopEarly { await gate.wait() }
          return "One. Two. Three."
        },
        processPart: { text in
          if !stopEarly { await gate.wait() }
          return Self.outcome(text)
        })
      d.choose(url: Self.anyURL)
      _ = await settleUntil { if case .ready = d.state { return true } else { return false } }
      d.start()
      // **Settle on the SPECIFIC state, not on `isRunning`.** Both working
      // states answer that true, so waiting on it recorded whichever came first
      // and the polishing cell was never visited — the freeze caught its own
      // walk being incomplete, which is the point of freezing the set rather
      // than describing it.
      if stopEarly {
        await settleUntil {
          if case .transcribing = d.state { return true } else { return false }
        }
      } else {
        await settleUntil {
          if case .polishing = d.state { return true } else { return false }
        }
      }
      record(d)
      d.stop()
      await gate.releaseAll()
      await settleUntil { d.isEngineHeld == false }
      record(d)
    }

    // Path E: a refusal WITH a document in hand.
    let lease = EngineLease()
    let e = await finishedCoordinator(lease: lease)
    guard case .granted = lease.admit(.dictation) else {
      Issue.record("the fixture could not take the engine")
      return
    }
    e.rePolish()
    record(e)

    // **The freeze.** A pair not listed here is either a new screen nobody has
    // designed the words for, or a state that was not supposed to reach it.
    let expected: Set<String> = [
      "upload/idle",
      "upload/reading",
      "upload/ready",
      "upload/rejected",
      "transcription/ready",
      "transcription/finished",
      "polish/ready",
      "polish/finished",
      "review/ready",
      "review/finished",
      "working/transcribing",
      "working/polishing",
      "done/finished",
      "done/stopped",
      "done/rejected",
      // An ENGINE refusal with the audio still in memory. The user stays where
      // Try again is rather than being sent back to the file picker.
      "review/rejected",
    ]
    #expect(
      seen == expected,
      """
      the reachable pairs changed.
        new, and nobody has said what the screen shows: \(seen.subtracting(expected).sorted())
        listed but no longer reachable: \(expected.subtracting(seen).sorted())
      """)
  }

  /// A stable name per state CASE, ignoring its payload — the payload varies per
  /// run and the matrix is about which screen meets which kind of state.
  private static func label(for state: FileImportCoordinator.State) -> String {
    switch state {
    case .idle: return "idle"
    case .reading: return "reading"
    case .ready: return "ready"
    case .transcribing: return "transcribing"
    case .polishing: return "polishing"
    case .finished: return "finished"
    case .rejected: return "rejected"
    case .stopped: return "stopped"
    }
  }

  /// **A behavioural walk cannot establish that every WRITER asks the rule.**
  /// Round 4 enumerated the writers from the source and found five of seven
  /// navigation sites bypassing the authority the commit message claimed was
  /// single — and every behavioural row still passed, because they exercised the
  /// two writers that did ask. So this row reads the FILE.
  ///
  /// The seven permitted direct writers are the two resets and the five
  /// run transitions, each named at `jump(to:advancing:)`. A new one fails here
  /// until somebody says which it is.
  @Test("every navigation writer goes through the one authority")
  func navigationHasOneWriter() throws {
    let source = try String(
      contentsOf: RepoRoot.url.appendingPathComponent(
        "Sources/EnviousWisprAppKit/App/FileImportCoordinator.swift"),
      encoding: .utf8)

    // **Matches the ASSIGNMENT, not one of its spellings.** The first version
    // required the value on the same line, so `showRejection`'s multi-line
    // `step =` followed by an `if` expression was invisible to it and the count
    // came back one short — a detector comparing a RENDERING rather than the
    // property it is about. This accepts `step =`, `step=`, `self.step =` and a
    // value on the next line, and rejects `==`.
    func isAssignment(_ line: String) -> Bool {
      guard !line.hasPrefix("//") else { return false }
      guard let equals = line.range(of: "step") else { return false }
      let after = line[equals.upperBound...].drop { $0 == " " }
      guard after.first == "=", after.dropFirst().first != "=" else { return false }
      // `myStep = x` and `a.step = x` are not writes to THIS property.
      let beforeIndex = equals.lowerBound
      if beforeIndex > line.startIndex {
        let previous = line[line.index(before: beforeIndex)]
        if previous.isLetter || previous.isNumber || previous == "_" { return false }
        if previous == "." { return line.contains("self.step") }
      }
      return true
    }

    // **Two-way control, because a count from a detector I just wrote is a
    // hypothesis.** A line that IS a write must match and a comparison must not,
    // or the number below is measuring the detector rather than the file.
    #expect(isAssignment("step = .upload"), "the detector misses a plain write")
    #expect(isAssignment("step ="), "the detector misses a multi-line write")
    #expect(isAssignment("self.step = .done"), "the detector misses a qualified write")
    #expect(!isAssignment("if step == .done {"), "the detector counts a comparison")
    #expect(!isAssignment("previousStep = .done"), "the detector counts another property")

    let writers = source.split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter(isAssignment)

    // `step = target` is the authority's own write and is not counted.
    let direct = writers.filter { $0 != "step = target" }
    #expect(
      direct.count == 8,
      """
      \(direct.count) direct writes to `step`, expected 8 \
      (choose, startOver, showRejection, start, stop, rePolish, polishAll twice). \
      A new one is either a navigation — which must call `jump(to:advancing:)` \
      — or an exception that needs naming at `jump`. Found: \(direct)
      """)
    #expect(
      writers.contains("step = target"),
      "the authority no longer writes the step; this test is measuring nothing")
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

    #expect(coordinator.canGo(to: .upload))
    #expect(coordinator.canGo(to: .transcription))
    #expect(coordinator.canGo(to: .review) == false, "the bar skipped a step forward")
    #expect(coordinator.canGo(to: .done) == false, "Done was offered with no document")

    // Continue is the one mover that goes forward, one step, and only then.
    #expect(coordinator.canGo(to: .review, advancing: true))
    #expect(
      coordinator.canGo(to: .done, advancing: true) == false,
      "Continue could skip the whole wizard")
  }

  /// **Continue must not work before a file has been read.** `advance()` used to
  /// carry that check itself, which is exactly why it could not call the
  /// authority; folding it in is what let every writer share one rule.
  @Test("Continue does nothing on an empty Upload step")
  func continueNeedsAFile() {
    let coordinator = makeCoordinator(lease: EngineLease())
    #expect(coordinator.step == .upload)

    coordinator.advance()

    #expect(coordinator.step == .upload, "the wizard advanced with no file chosen")
  }

  /// A save confirmation belongs to ONE set of words. Left standing over a new
  /// document it is the exact belief that makes a user press New transcription
  /// and lose them.
  @Test("the save confirmation does not survive the document it was about")
  func saveMessageDoesNotOutliveItsDocument() async {
    let coordinator = await finishedCoordinator(lease: EngineLease())
    coordinator.noteSaveSucceeded(fileName: "Meeting.txt")
    #expect(coordinator.saveMessage != nil)

    coordinator.startOver()
    #expect(
      coordinator.saveMessage == nil,
      "a new import claimed the previous document's save")

    let second = await finishedCoordinator(lease: EngineLease())
    second.noteSaveSucceeded(fileName: "Meeting.txt")
    second.rePolish()
    await settleUntil { second.state == .finished }
    #expect(
      second.saveMessage == nil,
      "re-cleaned words claimed the save of the words they replaced")
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
          polishIsCloud: cloud, localPolishProvider: cloud ? nil : .egOne,
          polishProvider: cloud ? .openAI : .egOne, ollamaModel: nil)
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
