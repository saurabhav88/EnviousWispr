#if DEBUG
  import EnviousWisprCore
  import EnviousWisprPipeline
  import Foundation

  /// #3972 C6a: EnviousMeet through the DEBUG control door. Every command goes through the
  /// owner the page and the menu use (`MeetingStartFlow`, `MeetingCoordinator`), checks that the
  /// operation applies before it calls, and reads the owner back afterwards, so a reply states
  /// what happened, never what was asked. Nothing here records transcript text in a log or an
  /// error; text appears only in an explicit `meeting.get` reply.
  @MainActor
  final class DevControlMeetings {
    typealias Result = DevControlDispatcher.Result

    /// The owners, one closure each, so the bootstrapper hands over the live objects and tests
    /// hand over their own. A nil owner is a wiring fault and every command refuses.
    struct Sources {
      let coordinator: @MainActor () -> MeetingCoordinator?
      let startFlow: @MainActor () -> MeetingStartFlow?
      let transcripts: @MainActor () -> TranscriptCoordinator?
      var now: @MainActor () -> Date = { Date() }
    }

    /// Rows `meeting.list` returns when the request names no limit, and the most it may ask.
    static let defaultListLimit = 20
    static let maxListLimit = 200
    /// Turns `meeting.get` returns per page, and the most one page may ask.
    static let defaultTurnLimit = 200
    static let maxTurnLimit = 500
    /// The most stored transcript text `meeting.get` returns whole; larger asks page the turns.
    static let maxTextBytes = 256 * 1024

    private let sources: Sources

    init(sources: Sources) {
      self.sources = sources
    }

    /// Every command refuses without its owners.
    static func unwired() -> DevControlMeetings {
      DevControlMeetings(
        sources: Sources(coordinator: { nil }, startFlow: { nil }, transcripts: { nil }))
    }

    private var unwiredResult: Result {
      .failure(.notWired, "the EnviousMeet owners are not wired")
    }

    // MARK: - Start and stop

    /// `{entryPoint: <MeetingEntryPoint>, callSound?: Bool}`. The call-sound choice is this request's
    /// only; the saved setting is never changed. The explainer and the microphone prompt are
    /// never answered for the caller: `waitingForExplainer` means the page shows the explainer.
    func start(_ args: [String: Any]) async -> Result {
      guard Set(args.keys).isSubset(of: ["entryPoint", "callSound"]) else {
        return .failure(.badArgs, "meeting.start takes entryPoint and callSound only")
      }
      guard let raw = args["entryPoint"] as? String,
        let entryPoint = MeetingEntryPoint(rawValue: raw)
      else {
        return .failure(.badArgs, "entryPoint must be a MeetingEntryPoint name")
      }
      var callSound: Bool?
      if let value = args["callSound"] {
        guard let flag = DevControlSettings.Codec.bool(value) else {
          return .failure(.badArgs, "callSound must be a JSON boolean")
        }
        callSound = flag
      }
      guard let flow = sources.startFlow(), sources.coordinator() != nil else {
        return unwiredResult
      }
      let outcome = await flow.requestStart(from: entryPoint, captureCallSound: callSound)
      return .ok(Self.encode(outcome))
    }

    /// `{meetingID}`: stops that meeting's recording. Any other meeting, or none recording, is
    /// refused before the owner is called.
    func stop(_ args: [String: Any]) async -> Result {
      let meetingID: UUID
      switch Self.meetingID(args, allowed: ["meetingID"]) {
      case .failure(let result): return result
      case .success(let id): meetingID = id
      }
      guard let coordinator = sources.coordinator() else { return unwiredResult }
      guard case .recording(let recording, _) = coordinator.phase, recording == meetingID else {
        return .failure(.notRecording, "that meeting is not the one recording")
      }
      await coordinator.stop()
      guard let record = coordinator.record(id: meetingID) else {
        return .ok(["meetingID": meetingID.uuidString, "stopped": true, "state": NSNull()])
      }
      return .ok([
        "meetingID": meetingID.uuidString, "stopped": coordinator.phase == .idle,
        "state": record.state.rawValue,
      ])
    }

    // MARK: - Reads

    /// `{}`: the coordinator's live state, with the Start flow's pending steps.
    func status(_ args: [String: Any]) -> Result {
      guard args.isEmpty else { return .failure(.badArgs, "meeting.status takes no arguments") }
      guard let coordinator = sources.coordinator(), let flow = sources.startFlow() else {
        return unwiredResult
      }
      var phase: [String: Any]
      switch coordinator.phase {
      case .idle: phase = ["name": "idle"]
      case .starting: phase = ["name": "starting"]
      case .recording(let id, let startedAt):
        phase = [
          "name": "recording", "meetingID": id.uuidString,
          "startedAt": startedAt.formatted(Self.timestamp),
          "elapsedMs": max(0, Int(sources.now().timeIntervalSince(startedAt) * 1_000)),
        ]
      case .stopping(let id): phase = ["name": "stopping", "meetingID": id.uuidString]
      }
      let processing: Any =
        coordinator.processing.map { processing -> [String: Any] in
          [
            "meetingID": processing.meetingID.uuidString,
            "stage": Self.encode(processing.stage),
            "waitingForDictation": processing.waitingForDictation,
          ]
        } ?? NSNull()
      let pass: Any =
        coordinator.passDiagnostics.map { pass -> [String: Any] in
          ["unitInFlight": pass.isUnitInFlight, "engineResident": pass.isEngineResident]
        } ?? NSNull()
      return .ok([
        "phase": phase,
        "processing": processing,
        "pass": pass,
        // Not exposed by the pass while it runs; reported in `meeting.ended` at its end.
        "yieldCount": NSNull(),
        "notice": coordinator.notice.map { Self.name($0) as Any } ?? NSNull(),
        "callSoundStatus": coordinator.callSoundStatus.map { $0.rawValue as Any } ?? NSNull(),
        "boundMicrophoneUID": coordinator.boundMicrophoneUID as Any? ?? NSNull(),
        "workInFlight": coordinator.isWorkInFlight,
        "pendingExplainer": flow.pendingExplainer.map { $0.rawValue as Any } ?? NSNull(),
        "waitingForMicrophone": flow.waitingForMicrophone.map { $0.rawValue as Any } ?? NSNull(),
        "meetingCount": coordinator.meetings.count,
        "newerFormatCount": coordinator.newerFormatMeetings.count,
      ])
    }

    /// `{limit?}`: saved meetings, newest first, as their records say.
    func list(_ args: [String: Any]) -> Result {
      guard Set(args.keys).isSubset(of: ["limit"]) else {
        return .failure(.badArgs, "meeting.list takes limit only")
      }
      var limit = Self.defaultListLimit
      if let raw = args["limit"] {
        guard let value = DevControlSettings.Codec.exactInteger(raw, Int.self), (1...Self.maxListLimit).contains(value) else {
          return .failure(.badArgs, "limit must be an integer from 1 to \(Self.maxListLimit)")
        }
        limit = value
      }
      guard let coordinator = sources.coordinator() else { return unwiredResult }
      let meetings = coordinator.meetings
      return .ok([
        "meetings": meetings.prefix(limit).map { summary($0, coordinator: coordinator) },
        "total": meetings.count,
        "limit": limit,
      ])
    }

    /// `{meetingID, turnOffset?, turnLimit?, includeText?}`: one meeting and its own History row,
    /// found through the meeting's transcript id. Stored turns (every turn, echo flagged) and
    /// the default visible projection are reported separately; `includeText` adds the stored
    /// text when it is at most `maxTextBytes`.
    func get(_ args: [String: Any]) -> Result {
      let meetingID: UUID
      switch Self.meetingID(
        args, allowed: ["meetingID", "turnOffset", "turnLimit", "includeText"])
      {
      case .failure(let result): return result
      case .success(let id): meetingID = id
      }
      var offset = 0
      if let raw = args["turnOffset"] {
        guard let value = DevControlSettings.Codec.exactInteger(raw, Int.self), value >= 0 else {
          return .failure(.badArgs, "turnOffset must be a non-negative integer")
        }
        offset = value
      }
      var limit = Self.defaultTurnLimit
      if let raw = args["turnLimit"] {
        guard let value = DevControlSettings.Codec.exactInteger(raw, Int.self), (1...Self.maxTurnLimit).contains(value) else {
          return .failure(.badArgs, "turnLimit must be an integer from 1 to \(Self.maxTurnLimit)")
        }
        limit = value
      }
      var includeText = false
      if let raw = args["includeText"] {
        guard let flag = DevControlSettings.Codec.bool(raw) else {
          return .failure(.badArgs, "includeText must be a JSON boolean")
        }
        includeText = flag
      }
      guard let coordinator = sources.coordinator(), let transcripts = sources.transcripts() else {
        return unwiredResult
      }
      guard let record = coordinator.record(id: meetingID) else {
        return .failure(.notFound, "no meeting has that id")
      }
      var reply: [String: Any] = ["meeting": summary(record, coordinator: coordinator)]
      guard let row = transcripts.currentRow(id: record.transcriptID) else {
        reply["transcript"] = NSNull()
        return .ok(reply)
      }
      let textBytes = row.text.utf8.count
      if includeText, textBytes > Self.maxTextBytes {
        return .failure(
          .tooLarge, "the stored text is \(textBytes) bytes; page the turns instead")
      }
      let echo = Set(record.echoTurnIDs)
      let turns = row.turns ?? []
      let page = turns.dropFirst(offset).prefix(limit)
      let projection = transcripts.meetingProjection(of: row)
      var projected: [String: Any]
      switch projection {
      case .visible(let visible, _):
        projected = ["kind": "visible", "visibleTurnIDs": visible.map(\.id)]
      case .everythingHidden: projected = ["kind": "everythingHidden"]
      case .unavailable: projected = ["kind": "unavailable"]
      }
      var transcript: [String: Any] = [
        "rowID": row.id.uuidString,
        "textBytes": textBytes,
        "speakerNames": row.speakerNames ?? [:],
        "echoTurnIDs": record.echoTurnIDs,
        "totalTurns": turns.count,
        "turnOffset": offset,
        "turns": page.map { turn -> [String: Any] in
          [
            "id": turn.id, "speakerId": turn.speakerId,
            "startMs": turn.startMs as Any? ?? NSNull(), "endMs": turn.endMs as Any? ?? NSNull(),
            "range": [turn.originalTextRange.lowerBound, turn.originalTextRange.upperBound],
            "echo": echo.contains(turn.id),
            "text": TranscriptDocumentPresenter.slice(row.text, turn.originalTextRange),
          ]
        },
        "projection": projected,
      ]
      if includeText { transcript["text"] = row.text }
      reply["transcript"] = transcript
      return .ok(reply)
    }

    // MARK: - Changes

    /// `{meetingID}`: Transcribe again. Refused when the meeting's state does not allow it.
    func retry(_ args: [String: Any]) async -> Result {
      await change(args, name: "retry") { coordinator, record in
        guard record.audioKept, [.failed, .ready, .interrupted].contains(record.state) else {
          return "the meeting has no audio, or is not finished"
        }
        return nil
      } run: { coordinator, id in
        await coordinator.retry(meetingID: id)
      } check: { record in
        record.map { [.queued, .processing].contains($0.state) } ?? false
      }
    }

    /// `{meetingID}`: Delete audio, keeping the transcript.
    func deleteAudio(_ args: [String: Any]) async -> Result {
      await change(args, name: "deleteAudio") { _, record in
        record.audioKept ? nil : "the meeting's audio is already deleted"
      } run: { coordinator, id in
        await coordinator.deleteAudio(meetingID: id)
      } check: { record in
        record.map { !$0.audioKept } ?? false
      }
    }

    /// `{meetingID}`: Delete meeting. A meeting whose files a timed-out close still owns is
    /// only marked; the next launch finishes it, and the reply says so.
    func delete(_ args: [String: Any]) async -> Result {
      let meetingID: UUID
      switch Self.meetingID(args, allowed: ["meetingID"]) {
      case .failure(let result): return result
      case .success(let id): meetingID = id
      }
      guard let coordinator = sources.coordinator() else { return unwiredResult }
      guard let record = coordinator.record(id: meetingID) else {
        return .failure(.notFound, "no meeting has that id")
      }
      guard record.isWritableByThisBuild else {
        return .failure(.rejected, "a newer version saved that meeting")
      }
      await coordinator.delete(meetingID: meetingID)
      if let after = coordinator.record(id: meetingID) {
        guard after.deletionRequested else {
          return .failure(.rejected, "the meeting was not deleted")
        }
        return .ok(["meetingID": meetingID.uuidString, "deleted": false, "markedForDeletion": true])
      }
      return .ok(["meetingID": meetingID.uuidString, "deleted": true, "markedForDeletion": false])
    }

    /// The shared shape of retry and delete-audio: the meeting exists, is writable, is not
    /// recording, being transcribed or held by a timed-out close, and passes `refusal`; the
    /// owner runs; the record read back passes `check`, or the reply says it did not happen.
    private func change(
      _ args: [String: Any], name: String,
      refusal: (MeetingCoordinator, MeetingRecord) -> String?,
      run: (MeetingCoordinator, UUID) async -> Void,
      check: (MeetingRecord?) -> Bool
    ) async -> Result {
      let meetingID: UUID
      switch Self.meetingID(args, allowed: ["meetingID"]) {
      case .failure(let result): return result
      case .success(let id): meetingID = id
      }
      guard let coordinator = sources.coordinator() else { return unwiredResult }
      guard let record = coordinator.record(id: meetingID) else {
        return .failure(.notFound, "no meeting has that id")
      }
      guard record.isWritableByThisBuild else {
        return .failure(.rejected, "a newer version saved that meeting")
      }
      guard !Self.isBusy(meetingID, coordinator) else {
        return .failure(.busy, "the meeting is recording, being transcribed or being closed")
      }
      if let reason = refusal(coordinator, record) {
        return .failure(.rejected, reason)
      }
      await run(coordinator, meetingID)
      let after = coordinator.record(id: meetingID)
      guard check(after) else {
        return .failure(.rejected, "\(name) did not change the meeting")
      }
      return .ok([
        "meetingID": meetingID.uuidString, "state": after?.state.rawValue as Any? ?? NSNull(),
      ])
    }

    private static func isBusy(_ meetingID: UUID, _ coordinator: MeetingCoordinator) -> Bool {
      if coordinator.processing?.meetingID == meetingID || coordinator.isCloseOwned(meetingID) {
        return true
      }
      switch coordinator.phase {
      case .recording(let id, _), .stopping(let id): return id == meetingID
      case .starting, .idle: return false
      }
    }

    // MARK: - Encoding

    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private func summary(_ record: MeetingRecord, coordinator: MeetingCoordinator) -> [String: Any]
    {
      var tracks: [String: Any] = [:]
      for kind in MeetingTrackKind.allCases {
        let segments = record.segments[kind] ?? []
        tracks[kind.rawValue] = [
          "status": record.trackStatus[kind].map { $0.rawValue as Any } ?? NSNull(),
          "segments": segments.count,
          "frames": segments.reduce(0) { $0 + $1.frameCount },
          "firstStartMs": segments.first.map { $0.startMs as Any } ?? NSNull(),
          "lastEndMs": segments.last.map { $0.endMs as Any } ?? NSNull(),
          "gaps": record.gaps[kind]?.count ?? 0,
          "speakerOutcome": record.speakerOutcomes[kind].map { $0.rawValue as Any } ?? NSNull(),
        ]
      }
      return [
        "meetingID": record.id.uuidString,
        "transcriptID": record.transcriptID.uuidString,
        "createdAt": record.createdAt.formatted(Self.timestamp),
        "endedAt": record.endedAt.map { $0.formatted(Self.timestamp) as Any } ?? NSNull(),
        "state": record.state.rawValue,
        "engine": record.engine.rawValue,
        "hasTitle": record.title?.isEmpty == false,
        "durationMs": record.recordedDurationMs,
        "audioKept": record.audioKept,
        "deletionRequested": record.deletionRequested,
        "failureCode": record.failureCode as Any? ?? NSNull(),
        "wasInterrupted": record.wasInterrupted as Any? ?? NSNull(),
        "echoTurnCount": record.echoTurnIDs.count,
        "closeOwned": coordinator.isCloseOwned(record.id),
        "writable": record.isWritableByThisBuild,
        "tracks": tracks,
      ]
    }

    static func encode(_ outcome: MeetingStartFlow.Outcome) -> [String: Any] {
      switch outcome {
      case .waitingForExplainer: return ["outcome": "waitingForExplainer"]
      case .joinedMicrophonePrompt: return ["outcome": "joinedMicrophonePrompt"]
      case .cancelled: return ["outcome": "cancelled"]
      case .notIdle: return ["outcome": "notIdle"]
      case .started(let start):
        switch start {
        case .recording(let id): return ["outcome": "recording", "meetingID": id.uuidString]
        case .refused(let notice): return ["outcome": "refused", "notice": name(notice)]
        case .superseded(let id):
          return [
            "outcome": "superseded", "meetingID": id.map { $0.uuidString as Any } ?? NSNull(),
          ]
        case .failed(let id): return ["outcome": "failed", "meetingID": id.uuidString]
        case .notIdle: return ["outcome": "notIdle"]
        }
      }
    }

    private static func encode(_ stage: MeetingTranscriptionJob.Stage?) -> Any {
      switch stage {
      case .transcribing(let track, let fraction)?:
        return [
          "name": "transcribing", "track": track.rawValue,
          "fraction": fraction.isFinite ? fraction : 0,
        ]
      case .findingSpeakers(let track)?:
        return ["name": "findingSpeakers", "track": track.rawValue]
      case .composing?:
        return ["name": "composing"]
      case nil:
        return NSNull()
      }
    }

    static func name(_ notice: MeetingCoordinator.Notice) -> String {
      switch notice {
      case .microphoneDenied: return "microphoneDenied"
      case .microphoneUnavailable: return "microphoneUnavailable"
      case .finishDictationFirst: return "finishDictationFirst"
      case .lowDisk: return "lowDisk"
      case .stoppedLowDisk: return "stoppedLowDisk"
      case .recordingStoppedFileError: return "recordingStoppedFileError"
      case .callSoundUnavailable: return "callSoundUnavailable"
      case .callSoundFailed: return "callSoundFailed"
      case .storageFailed: return "storageFailed"
      }
    }

    // MARK: - Arguments

    private enum IDLookup {
      case success(UUID)
      case failure(Result)
    }

    private static func meetingID(_ args: [String: Any], allowed: Set<String>) -> IDLookup {
      guard Set(args.keys).isSubset(of: allowed) else {
        return .failure(.failure(.badArgs, "unexpected argument"))
      }
      guard let raw = args["meetingID"] as? String, let id = UUID(uuidString: raw) else {
        return .failure(.failure(.badArgs, "meetingID must be a UUID string"))
      }
      return .success(id)
    }
  }
#endif
