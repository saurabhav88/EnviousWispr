#if DEBUG
  @testable import EnviousWisprAudio
  import EnviousWisprCore
  import EnviousWisprLLM
  @testable import EnviousWisprStorage
  import Foundation
  import Testing

  @testable import EnviousWisprASR
  @testable import EnviousWisprAppKit
  @testable import EnviousWisprPipeline
  @testable import EnviousWisprServices

  /// #3765: the dev control door's dictation commands and request-bound receipts.
  ///
  /// Harness Contract: a UAT script reads a take's result through its receipt. When this
  /// fails, a script waits on the wrong take, reports another take's History row as its
  /// own, or starts a second dictation over a running one. No customer sees it.
  @Suite(.serialized, .tags(.harnessContract))
  @MainActor
  struct DevControlDictationTests {
    /// A stand-in runtime: one state, take ids and readiness per engine, and start / stop /
    /// cancel closures a test scripts. A start mints the scripted take unless told not to.
    @MainActor
    final class FakeRuntime {
      var active: ASRBackendType = .parakeet
      var states: [ASRBackendType: PipelineState] = [.parakeet: .idle, .whisper: .idle]
      var readiness: [ASRBackendType: ASREngineReadiness] = [
        .parakeet: .ready, .whisper: .ready,
      ]
      var continuing: [ASRBackendType: String] = [:]
      var last: [ASRBackendType: String] = [:]
      var facts: [String: DevControlDictation.TerminalFacts] = [:]
      var processes: [String: [pid_t]] = [:]
      var front: pid_t? = 1
      var activationBrings = true
      private(set) var starts = 0
      private(set) var stops = 0
      private(set) var cancels = 0
      private(set) var activated: [pid_t] = []
      /// Runs inside the start call, after the counter. Default: mint `nextTake` on the
      /// active engine and show it recording.
      var onStart: (@MainActor (FakeRuntime) async -> Void)?
      var onCancel: (@MainActor (FakeRuntime) -> Void)?
      var nextTake = UUID().uuidString

      var control: DevControlDictation.Control {
        DevControlDictation.Control(
          activeBackend: { [self] in active },
          driverState: { [self] in states[$0] ?? .idle },
          readiness: { [self] in readiness[$0] ?? .notReady },
          continuingTakeID: { [self] in continuing[$0] },
          lastTakeID: { [self] in last[$0] },
          terminalFacts: { [self] _, take in
            facts[take] ?? .init(savedRowID: nil, historySaved: true)
          },
          start: { [self] in
            starts += 1
            if let onStart { await onStart(self) } else { mint() }
          },
          stop: { [self] in stops += 1 },
          cancel: { [self] in
            cancels += 1
            onCancel?(self)
          },
          frontApp: DevControlDictation.FrontApp(
            processes: { [self] in processes[$0] ?? [] },
            activate: { [self] pid in
              activated.append(pid)
              if activationBrings { front = pid }
            },
            frontmost: { [self] in front },
            waitUntilFrontmost: { [self] pid in front == pid }))
      }

      func mint() {
        last[active] = nil
        continuing[active] = nextTake
        states[active] = .recording
      }
    }

    private static let launch = UUID()

    /// Runs one command on the main actor in its own task, so a test can act while it is
    /// suspended. `Result` carries `Any` payloads, so it stays on the main actor rather than
    /// crossing a task boundary.
    @MainActor
    final class Background {
      private var result: DevControlDispatcher.Result?
      private var task: Task<Void, Never>?

      init(_ body: @escaping @MainActor () async -> DevControlDispatcher.Result) {
        task = Task { @MainActor [weak self] in
          let value = await body()
          self?.result = value
        }
      }

      var value: DevControlDispatcher.Result {
        get async {
          await task?.value
          return result ?? .error(code: "noResult", message: "the command never returned")
        }
      }
    }

    private static func make(_ runtime: FakeRuntime) -> DevControlDictation {
      DevControlDictation(launchID: launch, control: runtime.control)
    }

    private func payload(_ result: DevControlDispatcher.Result) -> [String: Any]? {
      if case .ok(let payload, _) = result { return payload }
      return nil
    }

    private func code(_ result: DevControlDispatcher.Result) -> String? {
      switch result {
      case .ok: return nil
      case .error(let code, _): return code
      case .errorWithReceipt(let code, _, _): return code
      }
    }

    private func receipt(_ result: DevControlDispatcher.Result) throws -> [String: Any] {
      switch result {
      case .ok(let payload, _):
        return try #require(payload["receipt"] as? [String: Any], "\(payload)")
      case .errorWithReceipt(_, _, let receipt):
        return receipt
      case .error(let code, let message):
        Issue.record("refused \(code): \(message)")
        throw CancellationError()
      }
    }

    /// Ends the take the way the kernel's relay does: the ending first (when not completed),
    /// then the accepted terminal, in one turn, with `lastTakeID` already stamped.
    private func conclude(
      _ dictation: DevControlDictation, _ runtime: FakeRuntime, _ backend: ASRBackendType,
      take: String, ending: RecordingRecoveryEnding? = nil, state: PipelineState = .complete
    ) {
      runtime.continuing[backend] = nil
      runtime.last[backend] = take
      runtime.states[backend] = state
      if let ending { dictation.sessionEndedWithoutSave(backend, ending) }
      dictation.sessionTerminalAccepted(backend, take)
    }

    private func read(
      _ dictation: DevControlDictation, _ receipt: [String: Any]
    ) -> DevControlDispatcher.Result {
      dictation.receipt(["receipt": receipt])
    }

    // MARK: - Start

    @Test("a start from rest calls the programmatic start once and returns its take's receipt")
    func startReturnsReceipt() async throws {
      let runtime = FakeRuntime()
      let dictation = Self.make(runtime)
      let reply = try #require(payload(await dictation.start([:])))
      #expect(runtime.starts == 1)
      #expect(reply["status"] as? String == "pending")
      let receipt = try #require(reply["receipt"] as? [String: String])
      #expect(
        receipt == [
          "launch": Self.launch.uuidString, "backend": "parakeet", "take": runtime.nextTake,
        ])
      #expect(payload(read(dictation, receipt))?["status"] as? String == "pending")
    }

    @Test(
      "a start is admitted from rest only; any running state is busy and starts nothing",
      arguments: [
        PipelineState.loadingModel, .recording, .transcribing, .polishing,
      ])
    func startRefusesWhileRunning(state: PipelineState) async throws {
      let runtime = FakeRuntime()
      runtime.states[.parakeet] = state
      let dictation = Self.make(runtime)
      #expect(code(await dictation.start([:])) == "busy")
      #expect(runtime.starts == 0)
    }

    @Test(
      "error, advisory and complete are rest states a start accepts",
      arguments: [
        PipelineState.complete, .error(.modelWedged), .advisory(.vadGateNoSpeech),
      ])
    func startAcceptsRestStates(state: PipelineState) async throws {
      let runtime = FakeRuntime()
      runtime.states[.parakeet] = state
      let dictation = Self.make(runtime)
      #expect(payload(await dictation.start([:])) != nil)
      #expect(runtime.starts == 1)
    }

    @Test("a start records on the ACTIVE engine, not the selected one, and both engines work")
    func startUsesActiveEngine() async throws {
      for backend in [ASRBackendType.whisper, .parakeet] {
        let runtime = FakeRuntime()
        runtime.active = backend
        // The other engine is busy: only the active one's state may decide admission.
        runtime.states[backend == .parakeet ? .whisper : .parakeet] = .recording
        let dictation = Self.make(runtime)
        let receipt = try receipt(await dictation.start([:]))
        #expect(receipt["backend"] as? String == backend.rawValue)
      }
    }

    @Test("a start that only warms mints no take: notStarted with the observed readiness")
    func warmingStartIsNotStarted() async throws {
      let runtime = FakeRuntime()
      runtime.readiness[.parakeet] = .warming
      runtime.onStart = { _ in }  // the cold-press guard warms and returns
      let dictation = Self.make(runtime)
      let result = await dictation.start([:])
      #expect(code(result) == "notStarted")
      if case .error(_, let message) = result { #expect(message.contains("warming")) }
      #expect(runtime.starts == 1)
      #expect(runtime.cancels == 0)
    }

    @Test("a second door command while a start is suspended is busy; receipt reads still answer")
    func overlappingLifecycleCommandsAreBusy() async throws {
      let runtime = FakeRuntime()
      let dictation = Self.make(runtime)
      // A first take, finished, so a read has something to answer while the second start
      // is suspended.
      let first = try receipt(await dictation.start([:]))
      conclude(dictation, runtime, .parakeet, take: try #require(first["take"] as? String))

      var release: CheckedContinuation<Void, Never>?
      var suspended = false
      runtime.nextTake = UUID().uuidString
      runtime.onStart = { runtime in
        suspended = true
        await withCheckedContinuation { release = $0 }
        runtime.mint()
      }
      let second = Background { await dictation.start([:]) }
      try #require(await settleUntilObserved { suspended }, "the second start never suspended")
      #expect(code(await dictation.start([:])) == "busy")
      #expect(code(await dictation.stop(["receipt": first])) == "busy")
      #expect(code(await dictation.cancel([:])) == "busy")
      #expect(payload(read(dictation, first))?["status"] as? String == "terminal")
      release?.resume()
      #expect(payload(await second.value)?["status"] as? String == "pending")
      #expect(runtime.starts == 2)
    }

    @Test("start arguments: only frontApp, and only a non-empty string")
    func startArguments() async throws {
      let runtime = FakeRuntime()
      let dictation = Self.make(runtime)
      #expect(code(await dictation.start(["frontapp": "x"])) == "badArgs")
      #expect(code(await dictation.start(["frontApp": 3])) == "badArgs")
      #expect(code(await dictation.start(["frontApp": ""])) == "badArgs")
      #expect(runtime.starts == 0)
    }

    // MARK: - Front app

    @Test("front app: none running, two running, or one that never comes forward start nothing")
    func frontAppRefusals() async throws {
      let runtime = FakeRuntime()
      runtime.processes = ["one.app": [42], "two.app": [43, 44]]
      let dictation = Self.make(runtime)
      #expect(code(await dictation.start(["frontApp": "none.app"])) == "frontAppNotRunning")
      #expect(code(await dictation.start(["frontApp": "two.app"])) == "frontAppAmbiguous")
      runtime.activationBrings = false
      #expect(code(await dictation.start(["frontApp": "one.app"])) == "frontAppNotFront")
      #expect(runtime.activated == [42])
      #expect(runtime.starts == 0)
    }

    @Test("front app: activated, then the take starts in front of it")
    func frontAppActivatesThenStarts() async throws {
      let runtime = FakeRuntime()
      runtime.processes = ["notes.app": [42]]
      let dictation = Self.make(runtime)
      let reply = try #require(payload(await dictation.start(["frontApp": "notes.app"])))
      #expect(runtime.activated == [42])
      #expect(runtime.starts == 1)
      #expect(reply["status"] as? String == "pending")
    }

    @Test("front app lost after the start: the same take is cancelled and its receipt returned")
    func frontAppLostCancelsTheMintedTake() async throws {
      let runtime = FakeRuntime()
      runtime.processes = ["notes.app": [42]]
      runtime.onStart = { runtime in
        runtime.mint()
        runtime.front = 7  // focus moved during the start
      }
      var cancelledTake: String?
      runtime.onCancel = { cancelledTake = $0.continuing[.parakeet] }
      let dictation = Self.make(runtime)
      let result = await dictation.start(["frontApp": "notes.app"])
      #expect(code(result) == "frontAppLost")
      let receipt = try receipt(result)
      #expect(runtime.cancels == 1)
      // Cancellation reached the take the receipt names, before anything else ran.
      #expect(cancelledTake == runtime.nextTake)
      #expect(receipt["take"] as? String == runtime.nextTake)
      #expect(payload(read(dictation, receipt))?["status"] as? String == "pending")
      conclude(
        dictation, runtime, .parakeet, take: runtime.nextTake,
        ending: .cancelled(.user(.cancelButton)), state: .idle)
      let ended = try #require(payload(read(dictation, receipt)))
      #expect(ended["ending"] as? String == "cancelled")
      #expect(ended["cancelOrigin"] as? String == "cancelButton")
    }

    @Test("a start that minted nothing never cancels, even when the front app moved")
    func noMintNeverCancels() async throws {
      let runtime = FakeRuntime()
      runtime.processes = ["notes.app": [42]]
      runtime.onStart = { $0.front = 7 }
      let dictation = Self.make(runtime)
      #expect(code(await dictation.start(["frontApp": "notes.app"])) == "notStarted")
      #expect(runtime.cancels == 0)
    }

    // MARK: - Terminal results

    @Test("completed, historySaveFailed and each non-completed ending freeze on their receipt")
    func terminalResults() async throws {
      let row = UUID()
      let cases: [(RecordingRecoveryEnding?, DevControlDictation.TerminalFacts, String, UUID?)] = [
        (nil, .init(savedRowID: row, historySaved: true), "completed", row),
        (nil, .init(savedRowID: row, historySaved: false), "historySaveFailed", nil),
        (nil, .init(savedRowID: nil, historySaved: true), "completed", nil),
        (.noSpeech, .init(savedRowID: row, historySaved: true), "noSpeech", nil),
        (.discarded, .init(savedRowID: row, historySaved: true), "discarded", nil),
        (.failed, .init(savedRowID: row, historySaved: true), "failed", nil),
        (.noTransport, .init(savedRowID: row, historySaved: true), "noTransport", nil),
        (.cancelled(.systemOrFault), .init(savedRowID: row, historySaved: true), "cancelled", nil),
      ]
      for (ending, facts, expected, savedRow) in cases {
        let runtime = FakeRuntime()
        let dictation = Self.make(runtime)
        let receipt = try receipt(await dictation.start([:]))
        let take = try #require(receipt["take"] as? String)
        runtime.facts[take] = facts
        // Still pending while the take stops and processes.
        runtime.states[.parakeet] = .transcribing
        runtime.continuing[.parakeet] = nil
        #expect(payload(read(dictation, receipt))?["status"] as? String == "pending")
        conclude(dictation, runtime, .parakeet, take: take, ending: ending)
        let result = try #require(payload(read(dictation, receipt)), "\(expected)")
        #expect(result["status"] as? String == "terminal")
        #expect(result["ending"] as? String == expected)
        #expect((result["savedRowID"] as? String) == savedRow?.uuidString, "\(expected)")
      }
    }

    @Test("a later take, a duplicate terminal or another engine's ending never rewrites a result")
    func terminalResultIsFrozen() async throws {
      let runtime = FakeRuntime()
      let dictation = Self.make(runtime)
      let row = UUID()
      let first = try receipt(await dictation.start([:]))
      let firstTake = try #require(first["take"] as? String)
      runtime.facts[firstTake] = .init(savedRowID: row, historySaved: true)
      // Whisper reports an ending for its own take in between: it must not attach here.
      runtime.last[.whisper] = UUID().uuidString
      dictation.sessionEndedWithoutSave(.whisper, .failed)
      conclude(dictation, runtime, .parakeet, take: firstTake)
      // The same terminal again, now with an ending: ignored.
      runtime.last[.parakeet] = firstTake
      dictation.sessionEndedWithoutSave(.parakeet, .failed)
      dictation.sessionTerminalAccepted(.parakeet, firstTake)
      // A second take ends differently.
      runtime.nextTake = UUID().uuidString
      let second = try receipt(await dictation.start([:]))
      conclude(dictation, runtime, .parakeet, take: runtime.nextTake, ending: .discarded)

      let frozen = try #require(payload(read(dictation, first)))
      #expect(frozen["ending"] as? String == "completed")
      #expect(frozen["savedRowID"] as? String == row.uuidString)
      #expect(payload(read(dictation, second))?["ending"] as? String == "discarded")
    }

    @Test("eight terminal receipts are kept; the ninth expires the oldest; others refuse by kind")
    func retentionAndRefusals() async throws {
      let runtime = FakeRuntime()
      let dictation = Self.make(runtime)
      var receipts: [[String: Any]] = []
      for _ in 0...DevControlDictation.retainedTerminals {
        runtime.nextTake = UUID().uuidString
        receipts.append(try receipt(await dictation.start([:])))
        conclude(dictation, runtime, .parakeet, take: runtime.nextTake)
      }
      #expect(code(read(dictation, receipts[0])) == "receiptExpired")
      for kept in receipts.dropFirst() {
        #expect(payload(read(dictation, kept))?["status"] as? String == "terminal")
      }
      var foreign = receipts[1]
      foreign["launch"] = UUID().uuidString
      #expect(code(read(dictation, foreign)) == "wrongLaunch")
      var unknown = receipts[1]
      unknown["take"] = UUID().uuidString
      #expect(code(read(dictation, unknown)) == "unknownReceipt")
      var renamed = receipts[1]
      renamed["backend"] = "whisper"
      #expect(code(read(dictation, renamed)) == "unknownReceipt")
      #expect(code(dictation.receipt([:])) == "badArgs")
      #expect(code(dictation.receipt(["receipt": ["take": "x"]])) == "badArgs")
    }

    @Test("in-flight receipts are never evicted; past the in-flight bound a start is refused")
    func pendingReceiptsAreBounded() async throws {
      let runtime = FakeRuntime()
      let dictation = Self.make(runtime)
      var pending: [[String: Any]] = []
      for _ in 0..<DevControlDictation.maxPending {
        runtime.nextTake = UUID().uuidString
        pending.append(try receipt(await dictation.start([:])))
        // Leave each take unfinished but let the engine rest, so the next start is admitted.
        runtime.states[.parakeet] = .idle
        runtime.continuing[.parakeet] = nil
      }
      #expect(code(await dictation.start([:])) == "busy")
      for kept in pending {
        #expect(payload(read(dictation, kept))?["status"] as? String == "pending")
      }
    }

    // MARK: - Stop and cancel

    @Test(
      "stop: its own running take is stopped once; another take, none, or another launch refuse")
    func stopValidatesTheReceipt() async throws {
      let runtime = FakeRuntime()
      let dictation = Self.make(runtime)
      let receipt = try receipt(await dictation.start([:]))
      var foreign = receipt
      foreign["launch"] = UUID().uuidString
      #expect(code(await dictation.stop(["receipt": foreign])) == "wrongLaunch")
      runtime.continuing[.parakeet] = UUID().uuidString
      #expect(code(await dictation.stop(["receipt": receipt])) == "superseded")
      runtime.continuing[.parakeet] = receipt["take"] as? String
      runtime.active = .whisper
      #expect(code(await dictation.stop(["receipt": receipt])) == "superseded")
      runtime.active = .parakeet
      #expect(runtime.stops == 0)
      #expect(
        payload(await dictation.stop(["receipt": receipt]))?["stopRequested"] as? Bool == true)
      #expect(runtime.stops == 1)
      runtime.continuing[.parakeet] = nil
      #expect(code(await dictation.stop(["receipt": receipt])) == "notRecording")
      #expect(runtime.stops == 1)
      #expect(runtime.starts == 1, "a stop never goes through the start-capable toggle")
    }

    @Test(
      "cancel presses Cancel only while recording, loading or transcribing",
      arguments: [
        (PipelineState.recording, true), (.loadingModel, true), (.transcribing, true),
        (.polishing, false), (.idle, false), (.complete, false),
      ])
    func cancelAdmission(state: PipelineState, admitted: Bool) async throws {
      let runtime = FakeRuntime()
      runtime.states[.parakeet] = state
      let dictation = Self.make(runtime)
      let result = await dictation.cancel([:])
      #expect((payload(result) != nil) == admitted)
      if !admitted { #expect(code(result) == "notRecording") }
      #expect(runtime.cancels == (admitted ? 1 : 0))
      #expect(code(await dictation.cancel(["x": 1])) == "badArgs")
    }

    // MARK: - Shutdown

    @Test("after close no command mutates and no late callback updates a receipt")
    func closeStopsEverything() async throws {
      let runtime = FakeRuntime()
      let dictation = Self.make(runtime)
      let receipt = try receipt(await dictation.start([:]))
      dictation.shutDown()
      conclude(dictation, runtime, .parakeet, take: try #require(receipt["take"] as? String))
      #expect(code(read(dictation, receipt)) == "unknownReceipt")
      runtime.states[.parakeet] = .idle
      #expect(code(await dictation.start([:])) == "doorClosed")
      #expect(code(await dictation.cancel([:])) == "doorClosed")
      #expect(code(await dictation.stop(["receipt": receipt])) == "doorClosed")
      #expect(runtime.starts == 1)
      #expect(runtime.cancels == 0)
    }

    @Test("close during a suspended start: the start reports doorClosed and registers nothing")
    func closeDuringSuspendedStart() async throws {
      let runtime = FakeRuntime()
      let dictation = Self.make(runtime)
      var release: CheckedContinuation<Void, Never>?
      var suspended = false
      runtime.onStart = { runtime in
        suspended = true
        await withCheckedContinuation { release = $0 }
        runtime.mint()
      }
      let started = Background { await dictation.start([:]) }
      try #require(await settleUntilObserved { suspended }, "the start never suspended")
      dictation.shutDown()
      release?.resume()
      #expect(code(await started.value) == "doorClosed")
      #expect(runtime.cancels == 0)
    }

    @Test("close during the front-app wait: the start never reaches the runtime")
    func closeDuringFrontAppWait() async throws {
      let runtime = FakeRuntime()
      runtime.processes = ["notes.app": [42]]
      runtime.front = 7
      var waiting = false
      var release: CheckedContinuation<Void, Never>?
      let base = runtime.control
      let control = DevControlDictation.Control(
        activeBackend: base.activeBackend, driverState: base.driverState,
        readiness: base.readiness, continuingTakeID: base.continuingTakeID,
        lastTakeID: base.lastTakeID, terminalFacts: base.terminalFacts, start: base.start,
        stop: base.stop, cancel: base.cancel,
        frontApp: DevControlDictation.FrontApp(
          processes: base.frontApp.processes, activate: base.frontApp.activate,
          frontmost: base.frontApp.frontmost,
          waitUntilFrontmost: { _ in
            waiting = true
            await withCheckedContinuation { release = $0 }
            return true
          }))
      let gated = DevControlDictation(launchID: Self.launch, control: control)
      let started = Background { await gated.start(["frontApp": "notes.app"]) }
      try #require(await settleUntilObserved { waiting }, "the start never waited")
      gated.shutDown()
      release?.resume()
      #expect(code(await started.value) == "doorClosed")
      #expect(runtime.starts == 0)
    }

    // MARK: - Real terminal producer

    /// A factory-built Parakeet driver (the real kernel and its terminal relay) whose
    /// callbacks feed the registry exactly as `DictationLifecycleCoordinator` wires them.
    @Test("a real driver's cancelled take reaches its receipt through the kernel's own relay")
    func realDriverCancelReachesTheReceipt() async throws {
      let fixture = try SyntheticAudioFixture.make(
        fileName: "dev-control-cancel.wav", pattern: .toneBurst)
      let audioCapture = try FixtureAudioCapture(fixtureURL: fixture.url)
      let asrManager = MockASRManager(
        transcribeBehavior: .success(
          ASRResult(
            text: "never used", language: "en", duration: fixture.durationSeconds,
            processingTime: 0.02, backendType: .parakeet)))
      let driver = KernelDictationDriverFactory.makeForParakeet(
        inputs: .init(
          audioCapture: audioCapture, asrManager: asrManager,
          parakeetUpgrade: .legacyForTesting(),
          vadSignalSource: KernelDictationDriverFactory.makeSharedVADSignalSource(
            audioCapture: audioCapture),
          transcriptStore: TranscriptStore(), keychainManager: KeychainManager(),
          captureTelemetry: CaptureTelemetryState(),
          pasteCompletionRegistry: PasteCompletionRegistry(),
          engineMutationScope: .alwaysAllowedForTesting))
      let waiter = PipelineStateWaiter(driver)
      let control = DevControlDictation.Control(
        activeBackend: { .parakeet },
        driverState: { _ in driver.state },
        readiness: { _ in driver.engineReadiness },
        continuingTakeID: { _ in driver.continuingSessionID },
        lastTakeID: { _ in driver.lastTakeID },
        terminalFacts: { _, _ in .init(savedRowID: nil, historySaved: driver.lastHistorySaved) },
        start: { try? await driver.handle(event: .toggleRecording(.testDefault())) },
        stop: {},
        cancel: { await driver.cancelRecording(disposition: .user(.cancelButton)) },
        frontApp: .init(
          processes: { _ in [] }, activate: { _ in }, frontmost: { nil },
          waitUntilFrontmost: { _ in false }))
      let dictation = DevControlDictation(launchID: Self.launch, control: control)
      driver.onSessionEndedWithoutSave = { (_: String?, ending: RecordingRecoveryEnding) in
        dictation.sessionEndedWithoutSave(.parakeet, ending)
      }
      driver.onSessionTerminalAccepted = { (take: String) in
        dictation.sessionTerminalAccepted(.parakeet, take)
      }

      let started = try receipt(await dictation.start([:]))
      let take = try #require(started["take"] as? String)
      // settle: PipelineStateWaiter resumes on the driver's own onStateChange signal, no clock.
      await waiter.wait(for: .recording)
      #expect(payload(read(dictation, started))?["status"] as? String == "pending")
      #expect(payload(await dictation.cancel([:]))?["cancelRequested"] as? Bool == true)

      let ended = try #require(payload(read(dictation, started)))
      #expect(ended["status"] as? String == "terminal")
      #expect(ended["ending"] as? String == "cancelled")
      #expect(ended["cancelOrigin"] as? String == "cancelButton")
      #expect(ended["savedRowID"] is NSNull)
      #expect(driver.lastTakeID == take)
    }

    /// A factory-built driver completes a real take into an isolated store; the receipt's
    /// row is the row that store holds, read through the same projection the app wires.
    @Test("a real completed take's receipt names the History row the store actually saved")
    func realDriverCompletionNamesTheSavedRow() async throws {
      let fixture = try SyntheticAudioFixture.make(
        fileName: "dev-control-complete.wav", pattern: .toneBurst)
      let audioCapture = try FixtureAudioCapture(
        fixtureURL: fixture.url, deliverFirstBuffer: true)
      let asrManager = MockASRManager(
        transcribeBehavior: .success(
          ASRResult(
            text: "receipt row check", language: "en", duration: fixture.durationSeconds,
            processingTime: 0.02, backendType: .parakeet)))
      let store = DictationRuntimeFixtures.tempStore()
      let driver = DictationRuntimeFixtures.makeParakeetDriver(
        audioCapture: audioCapture, asrManager: asrManager, store: store)
      let waiter = PipelineStateWaiter(driver)
      // No paste and no clipboard write: the test must not touch the desktop.
      let config = DictationSessionConfig.testDefault(
        autoCopyToClipboard: false, autoPasteToActiveApp: false, useStreamingASR: false)
      let control = DevControlDictation.Control(
        activeBackend: { .parakeet },
        driverState: { _ in driver.state },
        readiness: { _ in driver.engineReadiness },
        continuingTakeID: { _ in driver.continuingSessionID },
        lastTakeID: { _ in driver.lastTakeID },
        terminalFacts: { DevControlDictation.TerminalFacts.of(driver, takeID: $1) },
        start: { try? await driver.handle(event: .toggleRecording(config)) },
        stop: { try? await driver.handle(event: .requestStop) },
        cancel: {},
        frontApp: DevControlDictation.FrontApp(
          processes: { _ in [] }, activate: { _ in }, frontmost: { nil },
          waitUntilFrontmost: { _ in false }))
      let dictation = DevControlDictation(launchID: Self.launch, control: control)
      var concluded = false
      driver.onSessionEndedWithoutSave = { (_: String?, ending: RecordingRecoveryEnding) in
        dictation.sessionEndedWithoutSave(.parakeet, ending)
      }
      driver.onSessionTerminalAccepted = { (take: String) in
        dictation.sessionTerminalAccepted(.parakeet, take)
        concluded = true
      }

      let started = try receipt(await dictation.start([:]))
      // settle: PipelineStateWaiter resumes on the driver's own onStateChange signal, no clock.
      await waiter.wait(for: .recording)
      // settle: the kernel discards a take shorter than its 0.5 s minimum (5 ticks of 100 ms
      // of real uptime); this test needs a take that long, not a measurement of it.
      try await Task.sleep(for: .milliseconds(700))
      #expect(payload(await dictation.stop(["receipt": started]))?["stopRequested"] as? Bool == true)
      try #require(await settleUntilObserved { concluded }, "the take never concluded")

      let ended = try #require(payload(read(dictation, started)))
      #expect(ended["ending"] as? String == "completed", "\(ended)")
      let saved = try await store.loadAll()
      try #require(saved.count == 1, "saved rows: \(saved.count)")
      #expect(ended["savedRowID"] as? String == saved[0].id.uuidString)
      #expect(saved[0].text == "receipt row check")
    }

    /// `dictation.stop` through `DictationRuntime.devControlUserStop()` and the real
    /// finalizer: the hands-free lock clears and the stop reaches the ACTIVE engine's
    /// driver, here while that take is still arming.
    @Test("stop goes through the real finalizer: lock cleared, the active driver stopped while arming")
    func stopThroughTheRealFinalizer() async throws {
      for backend in [ASRBackendType.parakeet, .whisper] {
        let audio = RouterTestAudioCapture()
        let asr = RouterTestASRManager()
        asr.activeBackendType = backend
        let store = DictationRuntimeFixtures.tempStore()
        let parakeet = DictationRuntimeFixtures.makeParakeetDriver(
          audioCapture: audio, asrManager: asr, store: store)
        let whisper = DictationRuntimeFixtures.makeWhisperPipeline(
          audioCapture: audio, store: store)
        let locked = TestRecordingLockedBox()
        let runtime = Self.runtime(
          audio: audio, asr: asr, parakeet: parakeet, whisper: whisper, locked: locked)
        let driverFor = { (b: ASRBackendType) in b == .whisper ? whisper : parakeet }
        let control = DevControlDictation.Control(
          activeBackend: { asr.activeBackendType },
          driverState: { driverFor($0).state },
          readiness: { driverFor($0).engineReadiness },
          continuingTakeID: { driverFor($0).continuingSessionID },
          lastTakeID: { driverFor($0).lastTakeID },
          terminalFacts: { DevControlDictation.TerminalFacts.of(driverFor($0), takeID: $1) },
          start: {
            try? await driverFor(asr.activeBackendType).handle(
              event: .toggleRecording(.testDefault(autoCopyToClipboard: false)))
          },
          stop: { await runtime.devControlUserStop() },
          cancel: {},
          frontApp: DevControlDictation.FrontApp(
            processes: { _ in [] }, activate: { _ in }, frontmost: { nil },
            waitUntilFrontmost: { _ in false }))
        let dictation = DevControlDictation(launchID: Self.launch, control: control)
        var terminals: [ASRBackendType] = []
        for (engine, driver) in [(ASRBackendType.parakeet, parakeet), (.whisper, whisper)] {
          driver.onSessionEndedWithoutSave = { (_: String?, ending: RecordingRecoveryEnding) in
            dictation.sessionEndedWithoutSave(engine, ending)
          }
          driver.onSessionTerminalAccepted = { (take: String) in
            dictation.sessionTerminalAccepted(engine, take)
            terminals.append(engine)
          }
        }

        let started = try receipt(await dictation.start([:]))
        // The take minted synchronously and its forward path has not run: still arming.
        #expect(driverFor(backend).continuingSessionID == started["take"] as? String)
        locked.isLocked = true
        #expect(payload(await dictation.stop(["receipt": started]))?["stopRequested"] as? Bool == true)
        #expect(locked.isLocked == false, "\(backend): the stop control clears the hands-free lock")
        try #require(
          await settleUntilObserved { !terminals.isEmpty }, "\(backend): the take never concluded")
        #expect(terminals == [backend], "\(backend): only the active engine's take ended")
        let ended = try #require(payload(read(dictation, started)))
        #expect(ended["status"] as? String == "terminal")
        // Stopping while arming latches the stop, which the forward path concludes as
        // discarded (released before recording); any other ending means the stop did not
        // reach this take.
        #expect(ended["ending"] as? String == "discarded", "\(backend): \(ended)")
      }
    }

    /// The runtime graph the Microphone page harness assembles, with an observable lock.
    private static func runtime(
      audio: RouterTestAudioCapture, asr: RouterTestASRManager,
      parakeet: KernelDictationDriver, whisper: KernelDictationDriver,
      locked: TestRecordingLockedBox
    ) -> DictationRuntime {
      typealias Harness = DictationSettingsRenderHarness
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dev-control-stop-\(UUID().uuidString)")
      let settings = SettingsManager(
        defaults: TestDefaults.suite("ew.tests.3765.stop.\(UUID().uuidString)")!)
      let overlay = OverlayTestDouble.headlessDirector()
      let hotkey = HotkeyService(effects: RecordingDesktopHotkeyEffects())
      let hold = OtherAudioHold(dependencies: .init(
        effects: OtherAudioEffects(volume: Harness.NoVolume(), media: Harness.NoMedia()),
        defaultOutputDeviceID: { nil },
        store: OtherAudioHoldStore(directory: directory.appending(path: "holds")),
        telemetry: Harness.NoTelemetry(), log: { _ in }, nowMicros: { 0 }, sleep: { _ in },
        pid: 0, isProcessAlive: { _ in false }))
      let sync = PipelineSettingsSync(
        kernelDriver: parakeet, whisperKernelDriver: whisper, audioCapture: audio,
        asrManager: asr, hotkeyService: hotkey, ollamaRemotenessLookup: { _ in nil })
      let last = LastRecordingResult()
      let lockAccess = DictationLifecycleCoordinator.RecordingLockedAccess(
        get: { locked.isLocked }, set: { locked.isLocked = $0 })
      let lease = EngineLease()
      let lifecycle = DictationLifecycleCoordinator(
        kernelDriver: parakeet, whisperKernelDriver: whisper,
        recordingOverlay: overlay, hotkeyService: hotkey, settingsSync: sync,
        audioCapture: audio,
        transcriptCoordinator: TranscriptCoordinator(store: DictationRuntimeFixtures.tempStore()),
        settings: settings, lastRecordingResult: last, languageSuggestionPresenter: nil,
        recordingLockedAccess: lockAccess, releaseEngineClaim: { lease.release($0) },
        otherAudioHold: hold)
      let recovery = RecoveryCoordinator(
        keyStore: RecoveryKeyStore(backend: .file, fileDirectory: directory.appending(path: "keys")),
        makeSpoolStore: { RecoverySpoolStore(directory: directory.appending(path: "spools")) },
        replayer: Harness.NoReplay(), existingRecoveryIDs: { [] }, isDictationActive: { false },
        recoveryEngineClaim: .alwaysAllowedForTesting,
        engineAdmission: .live(lease: lease, as: .crashRecovery))
      return DictationRuntime(
        audioCapture: audio, asrManager: asr,
        kernelDriver: parakeet, whisperKernelDriver: whisper,
        settings: settings,
        permissions: PermissionsService(
          accessibilityReader: { true }, microphoneReader: { .authorized },
          openMicrophoneSettings: { _ in }),
        recordingOverlay: overlay, hotkeyService: hotkey, lastRecordingResult: last,
        languageSuggestionPresenter: nil, dictationLifecycleCoordinator: lifecycle,
        otherAudioHold: hold, recoveryCoordinator: recovery, recordingLockedAccess: lockAccess,
        engineAdmission: .live(lease: lease, as: .dictation),
        resolveActiveCaptureBackend: { nil }, resolveActiveTelemetryTarget: { nil },
        isCurrentSession: { _ in false })
    }
  }
#endif
