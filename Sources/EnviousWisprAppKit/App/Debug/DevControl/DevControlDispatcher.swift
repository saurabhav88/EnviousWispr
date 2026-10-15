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
      case wordsList = "words.list"
      case wordsAdd = "words.add"
      case wordsUpdate = "words.update"
      case wordsRemove = "words.remove"
      case modelsParakeetDownload = "models.parakeet.download"
      case modelsParakeetCancel = "models.parakeet.cancel"
      case modelsWhisperKitDownload = "models.whisperkit.download"
      case modelsWhisperKitCancel = "models.whisperkit.cancel"
      case dictationStart = "dictation.start"
      case dictationStop = "dictation.stop"
      case dictationCancel = "dictation.cancel"
      case dictationReceipt = "dictation.receipt"
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
      /// The word owner refused the change; the reply carries its own message.
      case rejected
      /// Another dictation command is running, or the engine is not at rest.
      case busy
      case doorClosed
      case frontAppNotRunning
      case frontAppAmbiguous
      case frontAppNotFront
      /// The front app changed after a take started; its cancellation was requested and
      /// the reply carries the take's receipt.
      case frontAppLost
      /// The start path warmed or refused without minting a take.
      case notStarted
      case notRecording
      case superseded
      case wrongLaunch
      case unknownReceipt
      case receiptExpired
    }

    enum Result {
      /// `forced` is true only for a settings write that skipped the screens' checks; the
      /// door puts it in the request's log line.
      case ok([String: Any], forced: Bool = false)
      case error(code: String, message: String)
      /// A refusal that still names a take the caller must inspect (`frontAppLost`).
      case errorWithReceipt(code: String, message: String, receipt: [String: Any])

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
      /// driver or the Whisper one). Asked only for `engineStatus().active`.
      let driverState: @MainActor (ASRBackendType) -> PipelineState
      /// `ModelDeliveryHome.parakeetState`.
      let parakeetDelivery: @MainActor () -> DeliveryState
      /// `WhisperSetupService.setupState`.
      let whisperSetup: @MainActor () -> WhisperSetupState
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

    /// The Settings rows' model buttons, one closure each: Parakeet's foreground Resume and
    /// Cancel (`ModelDeliveryHome.resumeParakeetDownload()` / `cancelParakeetDownload()`;
    /// the row's background-upgrade and retry routes are not offered here) and
    /// WhisperKit's Download and Cancel (`WhisperKitSetupService.downloadModel()` /
    /// `cancelDownload()`). Each owner keeps its own guards and schedules its own work, so
    /// a call returning means the button was pressed, never that a download finished or a
    /// cancel drained.
    struct ModelActions {
      let parakeetDownload: @MainActor () -> Void
      let parakeetCancel: @MainActor () -> Void
      let whisperKitDownload: @MainActor () -> Void
      let whisperKitCancel: @MainActor () -> Void
    }

    /// Rows `history.list` returns when the request names no limit.
    static let defaultHistoryLimit = 20
    /// The most rows one `history.list` may ask for.
    static let maxHistoryLimit = 200

    private let settings: SettingsManager
    private let writeContext: DevControlSettings.WriteContext
    private let statusSources: StatusSources
    private let history: HistorySource
    private let models: ModelActions
    /// Dictation commands and their receipts. Its launch id is the door's.
    let dictation: DevControlDictation
    var launchID: UUID { dictation.launchID }
    /// The same coordinator Your Words calls; every word command goes through it.
    private let words: CustomWordsCoordinator

    init(
      settings: SettingsManager, writeContext: DevControlSettings.WriteContext,
      status: StatusSources, history: HistorySource, models: ModelActions,
      dictation: DevControlDictation, words: CustomWordsCoordinator
    ) {
      self.dictation = dictation
      self.settings = settings
      self.writeContext = writeContext
      self.statusSources = status
      self.history = history
      self.models = models
      self.words = words
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
      case .wordsList:
        return wordsList(args)
      case .wordsAdd:
        return wordsAdd(args)
      case .wordsUpdate:
        return wordsUpdate(args)
      case .wordsRemove:
        return wordsRemove(args)
      case .modelsParakeetDownload:
        return model(.parakeet, "download", args, models.parakeetDownload)
      case .modelsParakeetCancel:
        return model(.parakeet, "cancel", args, models.parakeetCancel)
      case .modelsWhisperKitDownload:
        return model(.whisperKit, "download", args, models.whisperKitDownload)
      case .modelsWhisperKitCancel:
        return model(.whisperKit, "cancel", args, models.whisperKitCancel)
      case .dictationStart:
        return await dictation.start(args)
      case .dictationStop:
        return await dictation.stop(args)
      case .dictationCancel:
        return await dictation.cancel(args)
      case .dictationReceipt:
        return dictation.receipt(args)
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
        "whisperSetup": Self.project(statusSources.whisperSetup()),
        "fileImportRunning": statusSources.isFileImportRunning(),
        "savedKeys": savedKeys,
      ]
    }

    static func project(_ readiness: ASREngineReadiness) -> String {
      switch readiness {
      case .notReady: return "notReady"
      case .warming: return "warming"
      case .ready: return "ready"
      }
    }

    /// `PipelineState.telemetryLabel` folds advisory into "error" on purpose for its
    /// series; a UAT script needs the two apart, so this mapping is its own.
    static func project(_ state: PipelineState) -> (state: String, reason: String?) {
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
    private static func project(_ state: WhisperSetupState) -> [String: Any] {
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

    // MARK: - Models

    /// `{}`: press one model button, then read that engine's state. The state is the
    /// instant after the press: an owner that refused or had nothing to do leaves it as it
    /// was, and one that scheduled work may not have moved it yet. Poll `status` for
    /// progress; this reply is never a completion receipt.
    private func model(
      _ backend: ASRBackendType, _ action: String, _ args: [String: Any],
      _ press: @MainActor () -> Void
    ) -> Result {
      guard !unexpectedKeys(args, allowed: []) else {
        return .failure(.badArgs, "model commands take no arguments")
      }
      press()
      let state: [String: Any]
      switch backend {
      case .parakeet: state = Self.project(statusSources.parakeetDelivery())
      case .whisperKit: state = Self.project(statusSources.whisperKitSetup())
      }
      return .ok(["backend": backend.rawValue, "action": action, "state": state])
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

    // MARK: - Words

    /// Each word command names the only argument keys it accepts. Any other key (an id on
    /// add, a source, a usage count) is refused rather than ignored, so a script never
    /// believes it set a field the screens do not let a person set.
    private func unexpectedKeys(_ args: [String: Any], allowed: Set<String>) -> Bool {
      !Set(args.keys).isSubset(of: allowed)
    }

    /// The aliases argument: an array whose every element is a string. One non-string
    /// element refuses the whole request; nothing is dropped.
    private enum AliasesArgument {
      case absent
      case value([String])
      case invalid
    }

    private func aliases(in args: [String: Any]) -> AliasesArgument {
      guard let raw = args["aliases"] else { return .absent }
      guard let array = raw as? [Any] else { return .invalid }
      var strings: [String] = []
      for element in array {
        guard let string = element as? String else { return .invalid }
        strings.append(string)
      }
      return .value(strings)
    }

    private func id(in args: [String: Any]) -> UUID? {
      (args["id"] as? String).flatMap(UUID.init(uuidString:))
    }

    /// `{}`: the coordinator's list, in its order.
    private func wordsList(_ args: [String: Any]) -> Result {
      guard !unexpectedKeys(args, allowed: []) else {
        return .failure(.badArgs, "words.list takes no arguments")
      }
      return .ok(["words": words.customWords.map(Self.project)])
    }

    /// `{word, aliases?}`. The coordinator owns trimming, the storable-value check,
    /// duplicates and bringing back a deleted built-in, so the reply reads what the list
    /// holds after the call instead of assuming a new row:
    /// - `created`: the list now holds the row this request made.
    /// - `restored`: a deleted built-in came back under its own id.
    /// - `existing`: a word with that spelling was already there (here, or saved by another
    ///   window first); nothing new was made.
    /// - `unchanged`: the owner accepted the request and the list holds no such word (a
    ///   blank word, which the owner ignores).
    private func wordsAdd(_ args: [String: Any]) -> Result {
      guard !unexpectedKeys(args, allowed: ["word", "aliases"]) else {
        return .failure(.badArgs, "words.add takes word and aliases only")
      }
      guard let canonical = args["word"] as? String else {
        return .failure(.badArgs, "word must be a string")
      }
      let newAliases: [String]
      switch aliases(in: args) {
      case .absent: newAliases = []
      case .value(let value): newAliases = value
      case .invalid: return .failure(.badArgs, "aliases must be an array of strings")
      }
      let candidate = CustomWord(canonical: canonical, aliases: newAliases)
      let beforeIDs = Set(words.customWords.map(\.id))
      if let message = words.add(candidate) {
        return .failure(.rejected, message)
      }
      let spelling = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        !spelling.isEmpty,
        let match = words.customWords.first(where: {
          $0.canonical.caseInsensitiveCompare(spelling) == .orderedSame
        })
      else {
        return .ok(["outcome": "unchanged", "word": NSNull()])
      }
      let outcome: String
      if match.id == candidate.id {
        outcome = "created"
      } else if !beforeIDs.contains(match.id) && match.source == .builtin {
        outcome = "restored"
      } else {
        outcome = "existing"
      }
      return .ok(["outcome": outcome, "word": Self.project(match)])
    }

    /// `{id, word?, aliases?}`: at least one of word and aliases. The row is copied and
    /// only the supplied fields change; `aliases: []` clears them. When another window
    /// deleted the word first, the owner drops the edit and adopts the saved list; the
    /// reply then says `targetGone` instead of naming a row.
    private func wordsUpdate(_ args: [String: Any]) -> Result {
      guard !unexpectedKeys(args, allowed: ["id", "word", "aliases"]) else {
        return .failure(.badArgs, "words.update takes id, word and aliases only")
      }
      guard let id = id(in: args) else {
        return .failure(.badArgs, "id must be a UUID string")
      }
      var newCanonical: String?
      if let raw = args["word"] {
        guard let string = raw as? String else {
          return .failure(.badArgs, "word must be a string")
        }
        newCanonical = string
      }
      let newAliases: [String]?
      switch aliases(in: args) {
      case .absent: newAliases = nil
      case .value(let value): newAliases = value
      case .invalid: return .failure(.badArgs, "aliases must be an array of strings")
      }
      guard newCanonical != nil || newAliases != nil else {
        return .failure(.badArgs, "give word, aliases or both")
      }
      guard var edited = words.customWords.first(where: { $0.id == id }) else {
        return .failure(.notFound, "no word has that id")
      }
      if let newCanonical { edited.canonical = newCanonical }
      if let newAliases { edited.aliases = newAliases }
      if let message = words.update(edited) {
        return .failure(.rejected, message)
      }
      guard let saved = words.customWords.first(where: { $0.id == id }) else {
        return .ok(["outcome": "targetGone", "word": NSNull()])
      }
      return .ok(["outcome": "updated", "word": Self.project(saved)])
    }

    /// `{id}`. Removing a built-in records its deletion, as the screen does.
    private func wordsRemove(_ args: [String: Any]) -> Result {
      guard !unexpectedKeys(args, allowed: ["id"]) else {
        return .failure(.badArgs, "words.remove takes id only")
      }
      guard let id = id(in: args) else {
        return .failure(.badArgs, "id must be a UUID string")
      }
      guard words.customWords.contains(where: { $0.id == id }) else {
        return .failure(.notFound, "no word has that id")
      }
      if let message = words.remove(id: id) {
        return .failure(.rejected, message)
      }
      let stillListed = words.customWords.contains { $0.id == id }
      return .ok(["outcome": stillListed ? "stillListed" : "removed", "id": id.uuidString])
    }

    private static func project(_ word: CustomWord) -> [String: Any] {
      [
        "id": word.id.uuidString,
        "word": word.canonical,
        "aliases": word.aliases,
        "learnedAliases": word.learnedAliases,
        "source": word.source.rawValue,
        "category": word.category.rawValue,
        "priority": word.priority,
        "forceReplace": word.forceReplace,
        "caseSensitive": word.caseSensitive,
        "frequencyUsed": word.frequencyUsed,
        "lastUsed": word.lastUsed.map { $0.formatted(timestamp) as Any } ?? NSNull(),
        "enrichmentPending": word.enrichmentPending,
      ]
    }
  }
#endif
