#if DEBUG
  import AppKit
  import EnviousWisprASR
  import EnviousWisprCore
  import EnviousWisprPipeline
  import Foundation

  /// #3765: the door's dictation commands and the receipts that tie each request to the
  /// one take it started.
  ///
  /// A start registers the take id the active driver minted, so a later read answers about
  /// THAT take only: never the newest History row, never whichever take is running now. The
  /// take's ending comes from the kernel's own terminal callbacks (the lifecycle
  /// coordinator fans them out here), not from public driver state, which can show a
  /// terminal while the kernel is still finalizing.
  @MainActor
  final class DevControlDictation {
    /// The runtime calls the commands make, one closure each, so tests can stand in for the
    /// app. Every one is required.
    struct Control {
      /// `EngineCoordinator.status.active`: the engine a start actually records on, which
      /// can differ from the selected one during a switch.
      let activeBackend: @MainActor () -> ASRBackendType
      let driverState: @MainActor (ASRBackendType) -> PipelineState
      let readiness: @MainActor (ASRBackendType) -> ASREngineReadiness
      /// The driver's `continuingSessionID`: the take still arming or live and not yet
      /// latched to exit, or nil.
      let continuingTakeID: @MainActor (ASRBackendType) -> String?
      /// The driver's `lastTakeID`: stamped at the accepted terminal, cleared at the next
      /// take's start.
      let lastTakeID: @MainActor (ASRBackendType) -> String?
      /// Read at the accepted terminal of `takeID`: whether its History save succeeded and
      /// the id of the row it wrote, when the driver's transcript is that take's.
      let terminalFacts: @MainActor (ASRBackendType, String) -> TerminalFacts
      /// `DictationRuntime.toggleRecording(source: .programmatic)`.
      let start: @MainActor () async -> Void
      /// `DictationRuntime.devControlUserStop()`.
      let stop: @MainActor () async -> Void
      /// `DictationRuntime.cancelRecording(trigger: .cancelButton)`.
      let cancel: @MainActor () async -> Void
      let frontApp: FrontApp
    }

    struct TerminalFacts: Equatable {
      let savedRowID: UUID?
      let historySaved: Bool

      /// The live projection, read at `takeID`'s accepted terminal: the driver's transcript
      /// names a row only when the kernel recorded that row for THIS take; otherwise the
      /// row id stays null rather than a neighbour's.
      @MainActor static func of(_ driver: KernelDictationDriver, takeID: String) -> TerminalFacts {
        let row = driver.currentTranscript.flatMap { transcript in
          driver.concludedTake(forTranscriptID: transcript.id)?.takeID == takeID
            ? transcript.id : nil
        }
        return TerminalFacts(savedRowID: row, historySaved: driver.lastHistorySaved)
      }
    }

    /// The front-app checks a start makes when asked to dictate into one app.
    struct FrontApp {
      /// Running, not-terminated processes with this bundle id.
      let processes: @MainActor (String) -> [pid_t]
      let activate: @MainActor (pid_t) -> Void
      let frontmost: @MainActor () -> pid_t?
      /// Waits up to its own bound (2 s live) for `pid` to be frontmost.
      let waitUntilFrontmost: @MainActor (pid_t) async -> Bool
    }

    /// One door start: this launch, the engine it recorded on, and the kernel's take id.
    struct Receipt: Equatable {
      let launch: UUID
      let backend: ASRBackendType
      let takeID: String

      var json: [String: Any] {
        ["launch": launch.uuidString, "backend": backend.rawValue, "take": takeID]
      }
    }

    /// How a take ended, frozen at its accepted terminal.
    struct Terminal: Equatable {
      /// `completed`, `historySaveFailed`, or the kernel's non-completed ending.
      let ending: String
      let cancelOrigin: String?
      /// The History row the take wrote; null unless the save succeeded and the driver's
      /// transcript is this take's. Kept even if the row is deleted later.
      let savedRowID: UUID?
    }

    /// Terminal receipts kept; a ninth evicts the oldest, which then reads `receiptExpired`.
    static let retainedTerminals = 8
    /// In-flight receipts allowed at once. A start beyond this is refused, never evicting.
    static let maxPending = 8
    /// Evicted take ids remembered so they read `receiptExpired`, not `unknownReceipt`.
    static let rememberedEvictions = 256

    let launchID: UUID
    private let control: Control

    private var pending: [String: Receipt] = [:]
    private var terminals: [(receipt: Receipt, terminal: Terminal)] = []
    private var evicted: [String] = []
    /// The non-completed ending the kernel reported for a backend's take, held until that
    /// take's accepted terminal arrives in the same synchronous turn.
    private var endings: [ASRBackendType: (takeID: String, ending: RecordingRecoveryEnding)] = [:]
    /// True while a start, stop or cancel is between admission and its reply.
    private var lifecycleBusy = false
    private(set) var isClosed = false

    init(launchID: UUID, control: Control) {
      self.launchID = launchID
      self.control = control
    }

    /// Door shutdown: refuse new lifecycle commands and ignore every later callback.
    func close() {
      isClosed = true
      pending.removeAll()
      endings.removeAll()
    }

    // MARK: - Terminal callbacks (fanned out by DictationLifecycleCoordinator)

    /// `onSessionEndedWithoutSave`: fires, before `sessionTerminalAccepted`, for every
    /// accepted ending except `.completed`. The take is the driver's `lastTakeID`, which
    /// the kernel stamps before either callback runs.
    func sessionEndedWithoutSave(_ backend: ASRBackendType, _ ending: RecordingRecoveryEnding) {
      guard !isClosed, let takeID = control.lastTakeID(backend) else { return }
      endings[backend] = (takeID, ending)
    }

    /// `onSessionTerminalAccepted`: fires exactly once per accepted terminal. A take with no
    /// held ending completed.
    func sessionTerminalAccepted(_ backend: ASRBackendType, _ takeID: String) {
      guard !isClosed else { return }
      let held = endings.removeValue(forKey: backend)
      let ending = held.flatMap { $0.takeID == takeID ? $0.ending : nil }
      let terminal: Terminal
      if let ending {
        terminal = Self.terminal(for: ending)
      } else {
        let facts = control.terminalFacts(backend, takeID)
        terminal = Terminal(
          ending: facts.historySaved ? "completed" : "historySaveFailed", cancelOrigin: nil,
          savedRowID: facts.historySaved ? facts.savedRowID : nil)
      }
      // A take no door request started (a hotkey take) has no receipt to freeze.
      if let receipt = pending.removeValue(forKey: takeID) {
        retain(receipt, terminal)
      }
    }

    private func retain(_ receipt: Receipt, _ terminal: Terminal) {
      terminals.append((receipt, terminal))
      while terminals.count > Self.retainedTerminals {
        evicted.append(terminals.removeFirst().receipt.takeID)
      }
      if evicted.count > Self.rememberedEvictions {
        evicted.removeFirst(evicted.count - Self.rememberedEvictions)
      }
    }

    private static func terminal(for ending: RecordingRecoveryEnding) -> Terminal {
      let name: String
      var origin: String?
      switch ending {
      case .discarded: name = "discarded"
      case .noSpeech: name = "noSpeech"
      case .failed: name = "failed"
      case .asrRetryExhausted: name = "asrRetryExhausted"
      case .audioInterrupted: name = "audioInterrupted"
      case .asrInterrupted: name = "asrInterrupted"
      case .noTransport: name = "noTransport"
      case .stoppedWaitingForDecode: name = "stoppedWaitingForDecode"
      case .asrEmptyDespiteAudio: name = "asrEmptyDespiteAudio"
      case .cancelled(let cancelOrigin):
        name = "cancelled"
        switch cancelOrigin {
        case .user(.shortcut): origin = "shortcut"
        case .user(.cancelButton): origin = "cancelButton"
        case .user(.otherKeyInterference): origin = "otherKeyInterference"
        case .systemOrFault: origin = "systemOrFault"
        }
      }
      return Terminal(ending: name, cancelOrigin: origin, savedRowID: nil)
    }

    // MARK: - Commands

    typealias Result = DevControlDispatcher.Result

    /// `{frontApp?}`: start one take on the active engine through the app's own
    /// programmatic start, and return its receipt.
    func start(_ args: [String: Any]) async -> Result {
      guard Set(args.keys).isSubset(of: ["frontApp"]) else {
        return .failure(.badArgs, "dictation.start takes frontApp only")
      }
      var bundleID: String?
      if let raw = args["frontApp"] {
        guard let value = raw as? String, !value.isEmpty, value.count <= 255 else {
          return .failure(.badArgs, "frontApp must be a bundle id string")
        }
        bundleID = value
      }
      guard !isClosed else { return .failure(.doorClosed, "the door is closing") }
      // Admission is reserved before the first await, so two door starts never overlap.
      guard !lifecycleBusy else {
        return .failure(.busy, "another dictation command is still running")
      }
      lifecycleBusy = true
      defer { lifecycleBusy = false }
      guard pending.count < Self.maxPending else {
        return .failure(.busy, "too many dictations are still in flight")
      }

      var backend = control.activeBackend()
      guard Self.admitsStart(control.driverState(backend)) else {
        return busyWithState(backend)
      }
      var targetPID: pid_t?
      if let bundleID {
        let pids = control.frontApp.processes(bundleID)
        guard !pids.isEmpty else {
          return .failure(.frontAppNotRunning, "no running app has that bundle id")
        }
        guard pids.count == 1 else {
          return .failure(.frontAppAmbiguous, "\(pids.count) running apps have that bundle id")
        }
        let pid = pids[0]
        if control.frontApp.frontmost() != pid {
          control.frontApp.activate(pid)
          guard await control.frontApp.waitUntilFrontmost(pid) else {
            return .failure(.frontAppNotFront, "the app did not come to the front")
          }
        }
        // Everything read before the wait may have moved.
        guard !isClosed else { return .failure(.doorClosed, "the door is closing") }
        backend = control.activeBackend()
        guard Self.admitsStart(control.driverState(backend)) else {
          return busyWithState(backend)
        }
        guard control.frontApp.frontmost() == pid else {
          return .failure(.frontAppNotFront, "the app left the front before the start")
        }
        targetPID = pid
      }

      let continuingBefore = control.continuingTakeID(backend)
      // The kernel mints synchronously inside the start and queues its forward path, and
      // nothing on the start path suspends after the mint, so a take this call started is
      // still arming, and still continuing, when the call returns.
      await control.start()
      guard !isClosed else { return .failure(.doorClosed, "the door closed during the start") }

      // From here to the cancel below nothing awaits: the take id, the frontmost check and
      // the entry into cancellation happen in one MainActor turn.
      if let takeID = control.continuingTakeID(backend), takeID != continuingBefore {
        let receipt = Receipt(launch: launchID, backend: backend, takeID: takeID)
        pending[takeID] = receipt
        if let targetPID, control.frontApp.frontmost() != targetPID {
          await control.cancel()
          return .errorWithReceipt(
            code: DevControlDispatcher.ErrorCode.frontAppLost.rawValue,
            message: "the app left the front after the start; cancellation requested",
            receipt: receipt.json)
        }
        return .ok(["receipt": receipt.json, "status": "pending"])
      }
      let state = DevControlDispatcher.project(control.driverState(backend))
      return .failure(
        .notStarted,
        "no take started (engine \(backend.rawValue), state \(state.state), readiness "
          + "\(DevControlDispatcher.project(control.readiness(backend))))")
    }

    /// `{receipt}`: stop that take the way the stop control does (clears hands-free lock).
    func stop(_ args: [String: Any]) async -> Result {
      guard Set(args.keys).isSubset(of: ["receipt"]) else {
        return .failure(.badArgs, "dictation.stop takes receipt only")
      }
      let receipt: Receipt
      switch parse(args["receipt"]) {
      case .failure(let result): return result
      case .success(let parsed): receipt = parsed
      }
      guard !isClosed else { return .failure(.doorClosed, "the door is closing") }
      guard !lifecycleBusy else {
        return .failure(.busy, "another dictation command is still running")
      }
      lifecycleBusy = true
      defer { lifecycleBusy = false }
      guard let continuing = control.continuingTakeID(receipt.backend) else {
        return .failure(.notRecording, "that engine has no take to stop")
      }
      guard continuing == receipt.takeID, control.activeBackend() == receipt.backend else {
        return .failure(.superseded, "another take is running now")
      }
      await control.stop()
      return .ok(["receipt": receipt.json, "stopRequested": true])
    }

    /// `{}`: the Cancel button, for whatever take the active engine is running.
    func cancel(_ args: [String: Any]) async -> Result {
      guard args.isEmpty else { return .failure(.badArgs, "dictation.cancel takes no arguments") }
      guard !isClosed else { return .failure(.doorClosed, "the door is closing") }
      guard !lifecycleBusy else {
        return .failure(.busy, "another dictation command is still running")
      }
      lifecycleBusy = true
      defer { lifecycleBusy = false }
      let backend = control.activeBackend()
      switch control.driverState(backend) {
      case .recording, .loadingModel, .transcribing: break
      default: return busyWithState(backend, code: .notRecording)
      }
      await control.cancel()
      return .ok(["cancelRequested": true, "backend": backend.rawValue])
    }

    /// `{receipt}`: pending, or the frozen terminal result. Reads only.
    func receipt(_ args: [String: Any]) -> Result {
      guard Set(args.keys).isSubset(of: ["receipt"]) else {
        return .failure(.badArgs, "dictation.receipt takes receipt only")
      }
      let receipt: Receipt
      switch parse(args["receipt"]) {
      case .failure(let result): return result
      case .success(let parsed): receipt = parsed
      }
      if let stored = pending[receipt.takeID], stored == receipt {
        return .ok(["receipt": receipt.json, "status": "pending"])
      }
      if let found = terminals.last(where: { $0.receipt == receipt }) {
        let terminal = found.terminal
        return .ok([
          "receipt": receipt.json, "status": "terminal", "ending": terminal.ending,
          "cancelOrigin": terminal.cancelOrigin as Any? ?? NSNull(),
          "savedRowID": terminal.savedRowID?.uuidString as Any? ?? NSNull(),
        ])
      }
      if evicted.contains(receipt.takeID) {
        return .failure(.receiptExpired, "that receipt was evicted; read History instead")
      }
      return .failure(.unknownReceipt, "no receipt with that take")
    }

    // MARK: - Helpers

    /// A start is admitted from rest only: idle, a finished take, an error or an advisory.
    private static func admitsStart(_ state: PipelineState) -> Bool {
      switch state {
      case .idle, .complete, .error, .advisory: return true
      case .loadingModel, .recording, .transcribing, .polishing: return false
      }
    }

    private func busyWithState(
      _ backend: ASRBackendType, code: DevControlDispatcher.ErrorCode = .busy
    ) -> Result {
      let state = DevControlDispatcher.project(control.driverState(backend))
      return .failure(code, "engine \(backend.rawValue) is \(state.state)")
    }

    private enum Parsed {
      case success(Receipt)
      case failure(Result)
    }

    private func parse(_ raw: Any?) -> Parsed {
      guard let object = raw as? [String: Any],
        Set(object.keys) == ["launch", "backend", "take"],
        let launchText = object["launch"] as? String, let launch = UUID(uuidString: launchText),
        let backendText = object["backend"] as? String,
        let backend = ASRBackendType(rawValue: backendText),
        let takeID = object["take"] as? String, UUID(uuidString: takeID) != nil
      else {
        return .failure(.failure(.badArgs, "receipt must be the object dictation.start returned"))
      }
      guard launch == launchID else {
        return .failure(.failure(.wrongLaunch, "that receipt is from another launch"))
      }
      return .success(Receipt(launch: launch, backend: backend, takeID: takeID))
    }
  }

  extension DevControlDictation.FrontApp {
    /// The live checks: NSWorkspace for the front app, NSRunningApplication for the target.
    static let live = DevControlDictation.FrontApp(
      processes: { bundleID in
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
          .filter { !$0.isTerminated }.map(\.processIdentifier)
      },
      activate: { pid in
        NSRunningApplication(processIdentifier: pid)?.activate(
          from: NSRunningApplication.current, options: [])
      },
      frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
      waitUntilFrontmost: { pid in
        // settle: activation is asynchronous and has no completion callback; poll the
        // frontmost app every 50 ms up to the plan's 2 s bound.
        for _ in 0..<40 {
          if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
          try? await Task.sleep(for: .milliseconds(50))
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
      })
  }
#endif
