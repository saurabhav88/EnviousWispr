#if DEBUG
  import EnviousWisprASR
  import EnviousWisprCore
  import EnviousWisprPipeline
  import EnviousWisprServices
  import Foundation
  import Testing

  @testable import EnviousWisprAppKit

  /// #2885 — the DEBUG-only door through which Live UAT hands a running dev build a file.
  ///
  /// Harness Contract: the door is the instrument Live UAT reads a verdict through. When
  /// this fails, a UAT run reports the wrong instance's row, waits on a file the user
  /// replaced, or reads a refusal as an acceptance; no user sees any of it.
  @Suite(.tags(.harnessContract))
  @MainActor
  struct DebugImportDoorTests {
    /// Replies the door posted, in order, plus a deadline-bounded wait for one with a
    /// given status. The signal is the SUBJECT's own reply; the deadline only turns a
    /// missing reply into a failure.
    @MainActor
    final class ReplySink {
      private(set) var replies: [[String: String]] = []

      func post(_ fields: [String: String]) { replies.append(fields) }

      /// The first reply with `status` at or after index `after`, waiting for it if it has
      /// not landed yet. `after` lets a test ask for the SECOND finished reply.
      ///
      /// The wait is the shared file-import settle (`FileImportSettle.swift`), deadline
      /// bounded: a reply that never comes is a FAILED row naming the statuses that did
      /// arrive, never a hung lane (the first version of this suite hung the lane for 40
      /// minutes on exactly that defect).
      func reply(withStatus status: String, after: Int = 0) async -> [String: String] {
        let landed = await settleUntilObserved {
          self.replies.dropFirst(after).contains { $0["status"] == status }
        }
        if landed, let found = replies.dropFirst(after).first(where: { $0["status"] == status }) {
          return found
        }
        return ["status": "NO \(status) REPLY WITHIN THE DEADLINE; got \(statuses())"]
      }

      func statuses() -> [String] { replies.map { $0["status"] ?? "" } }
    }

    @MainActor
    final class SavedRows {
      var rows: [Transcript] = []
    }

    /// A decode or transcribe the test holds closed until it chooses to open it.
    private actor ManualGate {
      private var isOpen = false
      private var waiters: [CheckedContinuation<Void, Never>] = []
      private(set) var arrivals = 0

      func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
      }

      func pass() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
      }
    }

    nonisolated private static func decoded(seconds: Double) -> AudioFileDecoder.Decoded {
      AudioFileDecoder.Decoded(
        samples: Array(repeating: 0.1, count: Int(seconds * 16_000)),
        seconds: seconds, byteCount: Int64(seconds * 32_000), codec: "AAC",
        sampleRate: 44_100, channelCount: 1)
    }

    private static let pid: Int32 = 4242
    private static let path = "/tmp/door-recording.m4a"

    private func makeCoordinator(
      decodeGate: ManualGate? = nil,
      transcribeGate: ManualGate? = nil,
      transcribedText: String = "one two three",
      engineAdmission: EngineAdmissionAccess = .live(lease: EngineLease(), as: .fileImport),
      saveToHistory: @escaping @MainActor (Transcript) throws -> Void = { _ in }
    ) -> FileImportCoordinator {
      FileImportCoordinator(
        decode: { _ in
          if let decodeGate { await decodeGate.pass() }
          return Self.decoded(seconds: 1.0)
        },
        transcribe: { _ in
          if let transcribeGate { await transcribeGate.pass() }
          return ASRResult(
            text: transcribedText, language: "en", duration: 0, processingTime: 0,
            backendType: .parakeet, wordTimings: nil, wordTimingCoverage: nil)
        },
        engineAdmission: engineAdmission,
        beginRun: {
          FileImportCoordinator.RunConfiguration(
            polishIsCloud: false, localPolishProvider: nil, polishProvider: .egOne,
            ollamaModel: nil, polishModel: "eg-1", backendType: .parakeet)
        },
        saveToHistory: saveToHistory,
        updateHistoryRow: { _ in true },
        mergeSpeakerFields: { _, _, _ in true },
        historyRowExists: { _ in true },
        processPart: { part, _ in
          FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
        })
    }

    @MainActor
    final class ReadinessBox {
      var value: FileImportPolishReadiness = .ready
    }

    private func makeDoor(
      _ coordinator: FileImportCoordinator, sink: ReplySink,
      readiness: ReadinessBox = ReadinessBox()
    ) -> DebugImportDoor {
      DebugImportDoor(
        coordinator: coordinator, polishReadiness: { readiness.value }, pid: Self.pid,
        pollInterval: .milliseconds(1), post: { sink.post($0) })
    }

    private func transcribeRequest(
      _ door: DebugImportDoor, request: String = UUID().uuidString, launch: String? = nil,
      extra: [String: String] = [:]
    ) -> [String: String] {
      var info = [
        "kind": "transcribe", "pid": String(Self.pid), "request": request,
        "launch": launch ?? door.launchID.uuidString, "path": Self.path,
      ]
      for (k, v) in extra { info[k] = v }
      return info
    }

    @Test("a request naming another PID gets no reply at all, not even a refusal")
    func otherPIDIsIgnored() async {
      let sink = ReplySink()
      let door = makeDoor(makeCoordinator(), sink: sink)
      door.handle(["kind": "discover", "pid": "1", "request": UUID().uuidString])
      var info = transcribeRequest(door)
      info["pid"] = "1"
      door.handle(info)
      // A positive control on the same door, so an empty sink cannot mean "nothing runs".
      door.handle(["kind": "discover", "pid": String(Self.pid), "request": "mine"])
      let mine = await sink.reply(withStatus: "alive")
      #expect(mine["request"] == "mine")
      #expect(sink.replies.count == 1)
    }

    @Test("discover answers with the per-launch id and whether work would be accepted")
    func discoverReportsLaunchAndAcceptance() async {
      let sink = ReplySink()
      let door = makeDoor(makeCoordinator(), sink: sink)
      door.handle(["kind": "discover", "pid": String(Self.pid), "request": "r1"])
      let reply = await sink.reply(withStatus: "alive")
      #expect(reply["launch"] == door.launchID.uuidString)
      #expect(reply["acceptance"] == "accept")
      #expect(reply["polish"] == "ready")
      #expect(reply["pid"] == String(Self.pid))
      #expect(reply["request"] == "r1")
    }

    @Test(
      "a transcribe carrying the wrong launch id, a repeated request id, or a bad timeout is refused before any file is chosen"
    )
    func malformedAndWrongLaunchAreRefusedWithoutChoosing() {
      let sink = ReplySink()
      let coordinator = makeCoordinator()
      let door = makeDoor(coordinator, sink: sink)
      door.handle(transcribeRequest(door, launch: UUID().uuidString))
      #expect(sink.statuses() == ["wrongLaunch"])
      let id = UUID().uuidString
      door.handle(transcribeRequest(door, request: id, extra: ["timeout": "nan"]))
      #expect(sink.statuses().last == "malformed")
      door.handle(transcribeRequest(door, request: id))
      #expect(sink.statuses().last == "duplicate")
      door.handle(transcribeRequest(door, extra: ["path": "relative.m4a"]))
      #expect(sink.statuses().last == "malformed")
      #expect(coordinator.state == .idle, "no refusal may have reached choose(url:)")
    }

    @Test(
      "an accepted file runs the wizard's own steps to Done and the reply names the row it saved")
    func acceptedFileRunsToFinishedWithARow() async throws {
      let sink = ReplySink()
      let saved = SavedRows()
      let coordinator = makeCoordinator(saveToHistory: { saved.rows.append($0) })
      let door = makeDoor(coordinator, sink: sink)
      door.handle(transcribeRequest(door))
      let accepted = await sink.reply(withStatus: "accepted")
      #expect(accepted["launch"] == door.launchID.uuidString)
      let finished = await sink.reply(withStatus: "finished")
      #expect(coordinator.step == .done)
      #expect(coordinator.state == .finished)
      #expect(finished["saved"] == "true")
      #expect(finished["polisher"] == "eg-1")
      // `#require`, not optional equality: `nil == nil` would pass with no row at all.
      let row = try #require(saved.rows.first)
      let history = try #require(finished["history"])
      #expect(history == row.id.uuidString)
      #expect(coordinator.historyID == row.id)
      #expect(sink.statuses() == ["accepted", "finished"])
    }

    @Test("a run whose save failed still finishes, and the reply says the row was not saved")
    func failedSaveIsReportedSeparatelyFromFinished() async {
      struct SaveError: Error {}
      let sink = ReplySink()
      let coordinator = makeCoordinator(saveToHistory: { _ in throw SaveError() })
      let door = makeDoor(coordinator, sink: sink)
      door.handle(transcribeRequest(door))
      let finished = await sink.reply(withStatus: "finished")
      #expect(finished["saved"] == "false")
      #expect(coordinator.historySaveFailure != nil)
      // The words exist only on screen now; a second request must not discard them.
      door.handle(transcribeRequest(door))
      #expect(sink.replies.last?["status"] == "busy")
      #expect(sink.replies.last?["reason"] == "unsavedDocument")
      #expect(coordinator.hasDocument)
    }

    @Test(
      "a second request during a run is refused as busy, and a user's file in hand is never replaced"
    )
    func busyWhileRunningAndWhileAFileIsInHand() async {
      let sink = ReplySink()
      let gate = ManualGate()
      let coordinator = makeCoordinator(transcribeGate: gate)
      let door = makeDoor(coordinator, sink: sink)
      door.handle(transcribeRequest(door))
      _ = await sink.reply(withStatus: "accepted")
      // Immediately after acceptance the reservation refuses (`requestInFlight`). This
      // row is about the RUN refusing, so wait until the transcribe fake is holding it.
      let running = await settleUntilObserved { coordinator.isRunning }
      #expect(running)
      door.handle(transcribeRequest(door))
      let busy = await sink.reply(withStatus: "busy")
      #expect(busy["reason"] == "requestInFlight", "the reservation is checked first")
      await gate.open()
      let finished = await sink.reply(withStatus: "finished")
      #expect(finished["status"] == "finished")

      // A run the USER started from the screen, with no door request in flight: the
      // running rule itself refuses.
      let screenGate = ManualGate()
      let screen = makeCoordinator(transcribeGate: screenGate)
      let screenSink = ReplySink()
      let screenDoor = makeDoor(screen, sink: screenSink)
      screen.choose(url: URL(fileURLWithPath: "/tmp/users-own.m4a"))
      let screenReady = await settleUntilObserved {
        if case .ready = screen.state { return true } else { return false }
      }
      #expect(screenReady)
      for _ in 0..<4 { screen.advance() }
      let screenRunning = await settleUntilObserved { screen.isRunning }
      #expect(screenRunning)
      screenDoor.handle(transcribeRequest(screenDoor))
      #expect(screenSink.replies.first?["status"] == "busy")
      #expect(screenSink.replies.first?["reason"] == "running")
      await screenGate.open()
      let screenDone = await settleUntilObserved { screen.state == .finished }
      #expect(screenDone)

      // The user picks a file on screen and has not pressed Start: the door must not
      // clobber it, because a second `choose(url:)` would silently supersede the decode.
      let idle = makeCoordinator()
      let idleSink = ReplySink()
      let idleDoor = makeDoor(idle, sink: idleSink)
      idle.choose(url: URL(fileURLWithPath: "/tmp/users-own.m4a"))
      let ready = await settleUntilObserved {
        if case .ready = idle.state { return true } else { return false }
      }
      #expect(ready)
      idleDoor.handle(transcribeRequest(idleDoor))
      #expect(idleSink.replies.first?["status"] == "busy")
      #expect(idleSink.replies.first?["reason"] == "fileInHand")
      #expect(idle.file?.name == "users-own.m4a")
    }

    @Test(
      "a user replacing the file during the door's decode makes the door stand down without claiming that import's row"
    )
    func replacedDuringDecodeIsSuperseded() async {
      let sink = ReplySink()
      let gate = ManualGate()
      let coordinator = makeCoordinator(decodeGate: gate)
      let door = makeDoor(coordinator, sink: sink)
      door.handle(transcribeRequest(door))
      _ = await sink.reply(withStatus: "accepted")
      // The user's own pick, before the door's decode returns.
      coordinator.choose(url: URL(fileURLWithPath: "/tmp/users-own.m4a"))
      let superseded = await sink.reply(withStatus: "superseded")
      #expect(superseded["history"] == nil)
      #expect(superseded["saved"] == nil)
      await gate.open()
      // The user's import is untouched by the door standing down.
      let ready = await settleUntilObserved {
        if case .ready = coordinator.state { return true } else { return false }
      }
      #expect(ready)
      #expect(coordinator.file?.name == "users-own.m4a")
      #expect(coordinator.step == .upload)
      // And the door is free again.
      let before = sink.replies.count
      door.handle(["kind": "discover", "pid": String(Self.pid), "request": "r2"])
      let alive = await sink.reply(withStatus: "alive", after: before)
      #expect(alive["acceptance"] == "fileInHand")
    }

    @Test(
      "a file the user can Try again after an engine refusal is protected exactly like a file in hand; a refusal about the file is not"
    )
    func retryableScreenFileIsProtected() async throws {
      // The engine is held by dictation, so the user's Start is refused for an ENGINE
      // reason and the decoded audio stays in hand (`canRetry`).
      let lease = EngineLease()
      guard case .granted(let token) = lease.admit(.dictation) else {
        Issue.record("the fixture must hold the engine")
        return
      }
      defer { lease.release(token) }
      let held = makeCoordinator(engineAdmission: .live(lease: lease, as: .fileImport))
      let sink = ReplySink()
      let door = makeDoor(held, sink: sink)
      held.choose(url: URL(fileURLWithPath: "/tmp/users-own.m4a"))
      let ready = await settleUntilObserved { held.isReadyToRun }
      try #require(ready)
      for _ in 0..<4 { held.advance() }
      try #require(held.canRetry)
      let generation = held.generation
      door.handle(transcribeRequest(door))
      #expect(sink.replies.last?["status"] == "busy")
      #expect(sink.replies.last?["reason"] == "fileInHand")
      #expect(held.generation == generation, "the user's decoded audio was not replaced")
      #expect(held.file?.name == "users-own.m4a")

      // A refusal about the FILE leaves nothing to protect: the door takes over, and its
      // refused reply names no polisher (the previous run's would otherwise leak) and no row.
      let refusing = FileImportCoordinator(
        decode: { url in
          if url.lastPathComponent == "door-recording.m4a" {
            throw AudioFileDecoder.Rejection.unreadable
          }
          return Self.decoded(seconds: 1.0)
        },
        transcribe: { _ in
          ASRResult(
            text: "one two three", language: "en", duration: 0, processingTime: 0,
            backendType: .parakeet, wordTimings: nil, wordTimingCoverage: nil)
        },
        engineAdmission: .live(lease: EngineLease(), as: .fileImport),
        beginRun: {
          FileImportCoordinator.RunConfiguration(
            polishIsCloud: false, localPolishProvider: nil, polishProvider: .egOne,
            ollamaModel: nil, polishModel: "eg-1", backendType: .parakeet)
        },
        saveToHistory: { _ in }, updateHistoryRow: { _ in true },
        mergeSpeakerFields: { _, _, _ in true }, historyRowExists: { _ in true },
        processPart: { part, _ in
          FileImportRunner.PartOutcome(text: part, polishedText: part, polishError: nil)
        })
      let refusingSink = ReplySink()
      let refusingDoor = makeDoor(refusing, sink: refusingSink)
      // A completed import first, so `runConfiguration` holds a previous run's model.
      refusing.choose(url: URL(fileURLWithPath: "/tmp/earlier.m4a"))
      let earlierReady = await settleUntilObserved {
        if case .ready = refusing.state { return true } else { return false }
      }
      try #require(earlierReady)
      for _ in 0..<4 { refusing.advance() }
      let earlierDone = await settleUntilObserved { refusing.state == .finished }
      try #require(earlierDone)
      try #require(refusing.runConfiguration?.polishModel == "eg-1")
      refusingDoor.handle(transcribeRequest(refusingDoor))
      let refused = await refusingSink.reply(withStatus: "refused")
      #expect(refused["reason"] == "cannotRead")
      #expect(refused["polisher"] == nil, "a refusal before beginRun names no polisher")
      #expect(refused["history"] == nil)
      #expect(refused["saved"] == nil)
    }

    @Test("a refusal raised after Start names THIS run's polisher; one raised before Start names none")
    func polisherIsThisRunsOrAbsent() async {
      // No speech found is raised after `beginRun()`: the polisher belongs to this run.
      let silent = makeCoordinator(transcribedText: "")
      let sink = ReplySink()
      let door = makeDoor(silent, sink: sink)
      door.handle(transcribeRequest(door))
      let refused = await sink.reply(withStatus: "refused")
      #expect(refused["reason"] == "noSpeechFound")
      #expect(refused["polisher"] == "eg-1")
      #expect(refused["history"] == nil, "nothing was persisted")
    }

    @Test(
      "the screen's polish gate refuses the door too: before any file is chosen, and again before Start when it closes during the decode"
    )
    func polishReadinessGatesTheDoorLikeTheScreen() async {
      let readiness = ReadinessBox()
      readiness.value = .blocked(.needsSetup)
      let coordinator = makeCoordinator()
      let sink = ReplySink()
      let door = makeDoor(coordinator, sink: sink, readiness: readiness)
      door.handle(["kind": "discover", "pid": String(Self.pid), "request": "r1"])
      let alive = await sink.reply(withStatus: "alive")
      #expect(alive["polish"] == "needsSetup")
      door.handle(transcribeRequest(door))
      let refusedEarly = await sink.reply(withStatus: "refused")
      #expect(refusedEarly["reason"] == "polishNotReady")
      #expect(refusedEarly["block"] == "needsSetup")
      #expect(coordinator.state == .idle, "refused before choose(url:)")
      // The reservation is released with the refusal: the next request is not busy.
      let again = sink.replies.count
      door.handle(["kind": "discover", "pid": String(Self.pid), "request": "r2"])
      let alive2 = await sink.reply(withStatus: "alive", after: again)
      #expect(alive2["acceptance"] == "accept")

      // Open at the request, closed by the time the decode lands: refused before Start.
      let gate = ManualGate()
      let late = makeCoordinator(decodeGate: gate)
      let lateBox = ReadinessBox()
      let lateSink = ReplySink()
      let lateDoor = makeDoor(late, sink: lateSink, readiness: lateBox)
      lateDoor.handle(transcribeRequest(lateDoor))
      _ = await lateSink.reply(withStatus: "accepted")
      lateBox.value = .blocked(.unsavedKey)
      await gate.open()
      let refused = await lateSink.reply(withStatus: "refused")
      #expect(refused["reason"] == "polishNotReady:unsavedKey")
      #expect(late.step == .upload, "never advanced")
      #expect(refused["polisher"] == nil)
      // The door's own decoded file is released, so the door is free again rather than
      // blocked by a "file in hand" that is its own.
      #expect(late.file == nil)
      #expect(late.state == .idle)
      lateBox.value = .ready
      let count = lateSink.replies.count
      lateDoor.handle(["kind": "discover", "pid": String(Self.pid), "request": "r3"])
      let alive3 = await lateSink.reply(withStatus: "alive", after: count)
      #expect(alive3["acceptance"] == "accept")
    }

    @Test("a request after Done replaces the finished document exactly as the picker would")
    func acceptsAfterDone() async {
      let sink = ReplySink()
      let coordinator = makeCoordinator()
      let door = makeDoor(coordinator, sink: sink)
      door.handle(transcribeRequest(door))
      _ = await sink.reply(withStatus: "finished")
      let firstRow = coordinator.historyID
      let before = sink.replies.count
      door.handle(transcribeRequest(door))
      let second = await sink.reply(withStatus: "finished", after: before)
      #expect(sink.statuses() == ["accepted", "finished", "accepted", "finished"])
      #expect(second["history"] != nil)
      #expect(second["history"] != firstRow?.uuidString, "a different file is a different row")
    }
  }
#endif
