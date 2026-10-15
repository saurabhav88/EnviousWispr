#if DEBUG
  import EnviousWisprASR
  import EnviousWisprCore
  import EnviousWisprModelDelivery
  import EnviousWisprPipeline
  import EnviousWisprServices
  import Foundation

  /// #3765: turns one dev-control request into one call on the owner the UI uses.
  ///
  /// The door hands it an admitted command and its arguments; it returns a result payload
  /// or an error code. Only allowlisted command names exist, so the door can log the
  /// command without logging anything the client wrote. Error codes are a closed set
  /// (`ErrorCode`), so a log line never carries owner text.
  @MainActor
  final class DevControlDispatcher {
    enum Command: String, CaseIterable {
      case ping
      case settingsList = "settings.list"
      case settingsGet = "settings.get"
      case settingsSet = "settings.set"
      case status
      case historyList = "history.list"
      case historyGet = "history.get"
    }

    enum ErrorCode: String, CaseIterable {
      case unknownCommand
      case unknownKey
      case badArgs
      case badValue
      case checkFailed
      case checkNotYetShared
      case catalogUnavailable
      case notFound
    }

    enum Result {
      /// `forced` is true only for a settings write that skipped the screens' checks; the
      /// door puts it in the request's log line.
      case ok([String: Any], forced: Bool = false)
      case error(code: String, message: String)

      static func failure(_ code: ErrorCode, _ message: String) -> Result {
        .error(code: code.rawValue, message: message)
      }
    }

    /// The owners `status` reads, one closure each, so the bootstrapper can hand over the
    /// live objects and tests can hand over plain values. Every one is required: a missing
    /// owner is a wiring fault, never a default answer.
    struct StatusSources {
      /// `EngineCoordinator.status`: one snapshot per request, so selected, active and the
      /// switch fields never come from two different moments.
      let engineStatus: @MainActor () -> EngineStatus
      /// `EngineCoordinator.isSwitching`.
      let isSwitching: @MainActor () -> Bool
      /// The pipeline state of the dictation driver for one engine (the Parakeet kernel
      /// driver or the WhisperKit one). Asked only for `engineStatus().active`.
      let driverState: @MainActor (ASRBackendType) -> PipelineState
      /// `ModelDeliveryHome.parakeetState`.
      let parakeetDelivery: @MainActor () -> DeliveryState
      /// `WhisperKitSetupService.setupState`.
      let whisperKitSetup: @MainActor () -> WhisperKitSetupState
      /// `FileImportCoordinator.isRunning`.
      let isFileImportRunning: @MainActor () -> Bool
      /// `SavedKeyPresence.state(for:)`: what a path already learned, never a fresh read.
      let savedKeyState: @MainActor (LLMProvider) -> SavedKeyState
    }

    /// History's rows as the History screen offers them (`TranscriptCoordinator
    /// .visibleTranscripts`): expired pending rows already left out, newest first, and no
    /// kind filter or search applied.
    struct HistorySource {
      let visibleTranscripts: @MainActor () -> [Transcript]
    }

    /// Rows `history.list` returns when the request names no limit.
    static let defaultHistoryLimit = 20
    /// The most rows one `history.list` may ask for.
    static let maxHistoryLimit = 200

    private let settings: SettingsManager
    private let writeContext: DevControlSettings.WriteContext
    private let statusSources: StatusSources
    private let history: HistorySource

    init(
      settings: SettingsManager, writeContext: DevControlSettings.WriteContext,
      status: StatusSources, history: HistorySource
    ) {
      self.settings = settings
      self.writeContext = writeContext
      self.statusSources = status
      self.history = history
    }

    func handle(_ command: Command?, args: [String: Any]) async -> Result {
      guard let command else {
        return .failure(.unknownCommand, "no such command")
      }
      switch command {
      case .ping:
        return .ok(["pong": true])
      case .settingsList:
        return .ok(["settings": DevControlSettings.catalog(settings)])
      case .settingsGet:
        switch key(in: args) {
        case .failure(let result): return result
        case .success(let key): return .ok(row(key))
        }
      case .settingsSet:
        return set(args)
      case .status:
        return .ok(status())
      case .historyList:
        return historyList(args)
      case .historyGet:
        return historyGet(args)
      }
    }

    // MARK: - Settings

    private enum KeyLookup {
      case success(SettingsManager.SettingKey)
      case failure(Result)
    }

    private func key(in args: [String: Any]) -> KeyLookup {
      guard let name = args["key"] as? String else {
        return .failure(.failure(.badArgs, "key must be a string"))
      }
      guard let key = DevControlSettings.key(named: name) else {
        return .failure(.failure(.unknownKey, "no such setting"))
      }
      return .success(key)
    }

    private func row(_ key: SettingsManager.SettingKey) -> [String: Any] {
      let entry = DevControlSettings.entry(key)
      return [
        "key": entry.name,
        "value": DevControlSettings.read(key, from: settings),
        "kind": entry.kind.rawValue,
        "deferredTo": entry.deferredTo.map { $0 as Any } ?? NSNull(),
        "legacy": entry.legacy,
      ]
    }

    /// `{key, value, force?}`. `force` must be a JSON boolean when present.
    private func set(_ args: [String: Any]) -> Result {
      let key: SettingsManager.SettingKey
      switch self.key(in: args) {
      case .failure(let result): return result
      case .success(let found): key = found
      }
      guard let value = args["value"] else {
        return .failure(.badArgs, "value is required")
      }
      var force = false
      if let raw = args["force"] {
        guard let flag = DevControlSettings.Codec.bool(raw) else {
          return .failure(.badArgs, "force must be a boolean")
        }
        force = flag
      }
      switch DevControlSettings.write(
        key, value: value, force: force, context: writeContext, to: settings)
      {
      case .written(let forced):
        var payload = row(key)
        payload["forced"] = forced
        return .ok(payload, forced: forced)
      case .refused(let code, let message):
        return .error(
          code: ErrorCode(rawValue: code)?.rawValue ?? ErrorCode.badValue.rawValue, message: message
        )
      }
    }

    // MARK: - Status

    /// One point-in-time reading. A download or a switch can move on the next instant, so
    /// this is never a completion receipt.
    ///
    /// `selectedBackend` is the live setting; `engine.selected` is the coordinator's
    /// published snapshot of it. They can differ for the moment between a settings change
    /// and the coordinator's next reconcile, so both are reported.
    private func status() -> [String: Any] {
      let engine = statusSources.engineStatus()
      let switchFailure: Any
      let switchPhase: String
      switch engine.switchPhase {
      case .idle:
        switchPhase = "idle"
        switchFailure = NSNull()
      case .switching:
        switchPhase = "switching"
        switchFailure = NSNull()
      case .failed(let reason):
        // A stable non-PII token by `EngineStatus.SwitchPhase`'s own contract.
        switchPhase = "failed"
        switchFailure = reason
      }
      let driver = Self.project(statusSources.driverState(engine.active))
      var savedKeys: [String: Any] = [:]
      for provider in SavedKeyPresence.cloudProviders {
        savedKeys[provider.rawValue] = Self.project(statusSources.savedKeyState(provider))
      }
      return [
        "selectedBackend": settings.selectedBackend.rawValue,
        "engine": [
          "selected": engine.selected.rawValue,
          "active": engine.active.rawValue,
          "diverged": engine.isDiverged,
          "selectedReadiness": Self.project(engine.selectedReadiness),
          "activeReadiness": Self.project(engine.activeReadiness),
          "selectedInstalled": engine.selectedInstalled,
          "switchPhase": switchPhase,
          "switchFailure": switchFailure,
          "blockedReason": engine.blockedReason?.rawValue as Any? ?? NSNull(),
          "warmInFlight": engine.warmInFlight?.rawValue as Any? ?? NSNull(),
          "isSwitching": statusSources.isSwitching(),
        ] as [String: Any],
        "activeDriver": [
          "backend": engine.active.rawValue,
          "state": driver.state,
          "reason": driver.reason as Any? ?? NSNull(),
        ] as [String: Any],
        "parakeetDelivery": Self.project(statusSources.parakeetDelivery()),
        "whisperKitSetup": Self.project(statusSources.whisperKitSetup()),
        "fileImportRunning": statusSources.isFileImportRunning(),
        "savedKeys": savedKeys,
      ]
    }

    private static func project(_ readiness: ASREngineReadiness) -> String {
      switch readiness {
      case .notReady: return "notReady"
      case .warming: return "warming"
      case .ready: return "ready"
      }
    }

    /// `PipelineState.telemetryLabel` folds advisory into "error" on purpose for its
    /// series; a UAT script needs the two apart, so this mapping is its own.
    private static func project(_ state: PipelineState) -> (state: String, reason: String?) {
      switch state {
      case .idle: return ("idle", nil)
      case .loadingModel: return ("loadingModel", nil)
      case .recording: return ("recording", nil)
      case .transcribing: return ("transcribing", nil)
      case .polishing: return ("polishing", nil)
      case .complete: return ("complete", nil)
      case .error(let reason): return ("error", reason.rawValue)
      case .advisory(let reason):
        switch reason {
        case .zeroSignal: return ("advisory", "zeroSignal")
        case .vadGateNoSpeech: return ("advisory", "vadGateNoSpeech")
        case .noTransport: return ("advisory", "noTransport")
        }
      }
    }

    /// The failure keeps its class only: `detail` and the failing source name are for the
    /// local log, not for a reply a script may print.
    private static func project(_ state: DeliveryState) -> [String: Any] {
      switch state {
      case .notReady:
        return ["state": "notReady"]
      case .preparing(let validatingExistingCache):
        return ["state": "preparing", "validatingExistingCache": validatingExistingCache]
      case .downloading(let fraction, let bytesWritten, let totalBytes):
        return [
          "state": "downloading", "fractionCompleted": finite(fraction),
          "bytesWritten": bytesWritten, "totalBytes": totalBytes,
        ]
      case .verifying:
        return ["state": "verifying"]
      case .admitted:
        return ["state": "admitted"]
      case .cancelled(let resumable):
        return ["state": "cancelled", "resumable": resumable]
      case .failed(let failure):
        return ["state": "failed", "reason": failure.reason.rawValue]
      }
    }

    /// The download's status line and the error's text are screen copy, so they stay out.
    private static func project(_ state: WhisperKitSetupState) -> [String: Any] {
      switch state {
      case .checking: return ["state": "checking"]
      case .notDownloaded: return ["state": "notDownloaded"]
      case .downloading(let progress, _):
        return ["state": "downloading", "progress": finite(progress)]
      case .paused: return ["state": "paused"]
      case .ready: return ["state": "ready"]
      case .error: return ["state": "error"]
      }
    }

    private static func project(_ state: SavedKeyState) -> String {
      switch state {
      case .present: return "present"
      case .absent: return "absent"
      case .unknown: return "unknown"
      }
    }

    /// JSON has no NaN or infinity; a non-finite number becomes null instead of making the
    /// whole reply unencodable.
    private static func finite(_ value: Double) -> Any {
      value.isFinite ? value : NSNull()
    }

    // MARK: - History

    /// `{limit?}`: an integer from 1 to `maxHistoryLimit`; anything else is refused, never
    /// clamped. Rows keep the owner's order (newest first). A summary carries no text and
    /// no file name, only fixed-size fields, so the reply's size is bounded by the limit.
    private func historyList(_ args: [String: Any]) -> Result {
      var limit = Self.defaultHistoryLimit
      if let raw = args["limit"] {
        guard let value = DevControlSettings.Codec.exactInteger(raw, Int.self),
          (1...Self.maxHistoryLimit).contains(value)
        else {
          return .failure(.badArgs, "limit must be an integer from 1 to \(Self.maxHistoryLimit)")
        }
        limit = value
      }
      let visible = history.visibleTranscripts()
      return .ok([
        "rows": visible.prefix(limit).map(Self.summary),
        "total": visible.count,
        "limit": limit,
      ])
    }

    /// `{id}`: a UUID string of one row History offers now. A row that expired or was
    /// deleted since the client last looked is `notFound`, never a neighbour.
    private func historyGet(_ args: [String: Any]) -> Result {
      guard let raw = args["id"] as? String, let id = UUID(uuidString: raw) else {
        return .failure(.badArgs, "id must be a UUID string")
      }
      guard let row = history.visibleTranscripts().first(where: { $0.id == id }) else {
        return .failure(.notFound, "no visible History row has that id")
      }
      return .ok(["row": Self.detail(row)])
    }

    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func summary(_ row: Transcript) -> [String: Any] {
      [
        "id": row.id.uuidString,
        "createdAt": row.createdAt.formatted(timestamp),
        "kind": row.isImported ? "import" : "dictation",
        "pending": row.escapeRecoveredAt != nil,
        "backend": row.backendType.rawValue,
        "duration": finite(row.duration),
        "textBytes": row.text.utf8.count,
        "hasPolishedText": row.polishedText != nil,
        "hasProcessedText": row.processedText != nil,
      ]
    }

    /// The row's own fields, each as stored: raw ASR text, AI-polished text and the
    /// deterministic processed text stay three separate fields, and a missing one is null.
    private static func detail(_ row: Transcript) -> [String: Any] {
      var detail = summary(row)
      detail["text"] = row.text
      detail["polishedText"] = row.polishedText as Any? ?? NSNull()
      detail["processedText"] = row.processedText as Any? ?? NSNull()
      detail["language"] = row.language as Any? ?? NSNull()
      detail["processingTime"] = finite(row.processingTime)
      detail["llmProvider"] = row.llmProvider as Any? ?? NSNull()
      detail["llmModel"] = row.llmModel as Any? ?? NSNull()
      detail["isRecovered"] = row.isRecovered as Any? ?? NSNull()
      detail["inputDeviceWasRemoved"] = row.inputDeviceWasRemoved as Any? ?? NSNull()
      detail["escapeRecoveredAt"] =
        row.escapeRecoveredAt.map { $0.formatted(timestamp) as Any } ?? NSNull()
      detail["importedFileName"] = row.importedFileName as Any? ?? NSNull()
      return detail
    }
  }
#endif
