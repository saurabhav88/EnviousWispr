import EnviousWisprASR
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import EnviousWisprServices
import EnviousWisprStorage
import Foundation

/// Builds EnviousMeet's coordinator from the app's owners (#3972 C4a), so the composition root
/// adds one call instead of a page of closures.
///
/// What it connects, and why each piece is separate from dictation:
/// - Its own `MeetingParakeetEngine` (never dictation's backend) behind the model-use gate the
///   delivery controller owns, so no install changes under a meeting load or decode (R26).
/// - Dictation activity read from the same facts the engine switch reads, so a pass unit never
///   starts while the user dictates (R25).
/// - History through `TranscriptCoordinator`, with EnviousMeet as the deletion authority of its
///   rows (R12, R19).
@MainActor
enum MeetingWiring {
  struct Inputs {
    let store: MeetingStore
    let settings: SettingsManager
    let permissions: PermissionsService
    let otherAudioHold: OtherAudioHold
    let transcriptCoordinator: TranscriptCoordinator
    /// True when no dictation is starting, recording, transcribing, polishing or pasting.
    let isDictationIdle: @MainActor () -> Bool
    /// Poked by owners of dictation-activity inputs that Observation cannot see.
    let dictationWakes: MeetingWakeSignal
    let memoryPressure: MeetingMemoryPressure
    let offlineModeAdmission: ASRManager
    /// The installed, admitted model a meeting may load (`ParakeetUpgradeCoordinator`).
    let meetingSelection: @MainActor () async -> ParakeetModelSelection?
    /// The delivery controller's gate; never a second one.
    let modelUseGate: MeetingModelUseGate
    /// The live Parakeet delivery switch (R32).
    let isDeliveryEnabled: @MainActor () -> Bool
    /// Meeting work started or ended, or its engine was released: offer an owed Ultra
    /// activation again.
    let workChanged: @MainActor () -> Void
    let log: @MainActor (String) -> Void
    /// The AI Polish keys, for meeting summaries (#3972 R44).
    let keychain: KeychainManager
    /// The `meeting.ended` emitter (`TelemetryService.trackMeetingEnded` in production).
    var emitMeetingEnded: @MainActor (MeetingEndedTelemetry) -> Void = {
      TelemetryService.shared.trackMeetingEnded($0)
    }
    /// The `meeting.summary_finished` emitter.
    var emitSummaryFinished: @MainActor (MeetingSummaryFinishedTelemetry) -> Void = {
      TelemetryService.shared.trackMeetingSummaryFinished($0)
    }
  }

  static func make(_ inputs: Inputs) -> MeetingCoordinator {
    let store = inputs.store
    let lane = MeetingLocalModelLane()
    let coordinator = MeetingCoordinator(
      dependencies: MeetingCoordinator.Dependencies(
        store: store,
        makeRecorder: { configuration, onSegment, onFailure in
          MeetingRecorder(configuration: configuration, onSegment: onSegment, onFailure: onFailure)
        },
        makeJob: { makeJob(inputs, lane: lane, kind: .finalPass) },
        makePreviewJob: { makeJob(inputs, lane: lane, kind: .preview) },
        microphoneSelection: { [settings = inputs.settings] in
          let chosen = settings.preferredInputDeviceIDOverride
          return (chosen.isEmpty ? nil : chosen, settings.inputChannelByDeviceUID)
        },
        captureCallSound: { [settings = inputs.settings] in settings.meetingCaptureCallSound },
        microphoneAuthorized: { [permissions = inputs.permissions] in
          permissions.hasMicrophonePermission
        },
        settleDictationHold: { [otherAudioHold = inputs.otherAudioHold] in
          await otherAudioHold.meetingRecordingWillStart()
        },
        freeDiskBytes: { ModelDeliveryController.volumeAvailableBytes(store.root) },
        saveTranscript: { [transcriptCoordinator = inputs.transcriptCoordinator] transcript in
          try await transcriptCoordinator.saveAndShowDurably(transcript)
        },
        removeTranscriptRow: { [transcriptCoordinator = inputs.transcriptCoordinator] id in
          try transcriptCoordinator.removeRow(id: id)
        },
        emitEnded: { [log = inputs.log, emit = inputs.emitMeetingEnded] event in
          log("meeting ended outcome=\(event.outcome.rawValue)")
          emit(event)
        },
        log: inputs.log,
        workChanged: inputs.workChanged))
    inputs.transcriptCoordinator.deleteMeeting = { [weak coordinator] meetingID in
      Task { await coordinator?.delete(meetingID: meetingID) }
    }
    inputs.transcriptCoordinator.meetingRecords = { [weak coordinator] in
      coordinator?.meetings ?? []
    }
    inputs.transcriptCoordinator.meetingNotes = { [weak coordinator] meetingID in
      coordinator?.documents.notes(meetingID)
    }
    coordinator.onMeetingsPublished = { [weak transcriptCoordinator = inputs.transcriptCoordinator] in
      transcriptCoordinator?.meetingsDidChange()
    }
    inputs.transcriptCoordinator.meetingInfo = { [weak coordinator] meetingID in
      historyInfo(coordinator, meetingID: meetingID)
    }
    inputs.transcriptCoordinator.meetingsWillBeDeletedWithAll = { [weak coordinator] ids in
      // No coordinator means no meeting can be marked: History then deletes nothing.
      coordinator?.deleteForHistoryDeleteAll(meetingIDs: ids) ?? false
    }
    coordinator.summaries = makeSummaries(inputs, coordinator: coordinator, lane: lane)
    return coordinator
  }

  /// The summary owner (#3972 R39, R44, R50): the user's AI Polish provider and key, what
  /// History shows (echo hidden), and local calls only on the shared lane's turn.
  static func makeSummaries(
    _ inputs: Inputs, coordinator: MeetingCoordinator, lane: MeetingLocalModelLane
  ) -> MeetingSummaryOwner {
    let settings = inputs.settings
    let keychain = inputs.keychain
    let isIdle = inputs.isDictationIdle
    return MeetingSummaryOwner(
      dependencies: .init(
        isEnabled: { settings.meetingWriteSummary },
        selection: { (settings.llmProvider, settings.effectiveLLMModel) },
        prepare: { provider, model in
          await MeetingSummaryProviders.prepare(provider: provider, model: model, keychain: keychain)
        },
        visibleTranscript: {
          [weak coordinator, transcriptCoordinator = inputs.transcriptCoordinator] meetingID in
          guard let record = coordinator?.record(id: meetingID),
            let row = transcriptCoordinator.currentRow(id: record.transcriptID),
            case .visible(_, let text) = MeetingHistoryPresentation.project(
              row, info: historyInfo(coordinator, meetingID: meetingID), showEcho: false),
            !text.isEmpty
          else { return nil }
          return .init(text: text, speakerNames: row.speakerNames ?? [:])
        },
        isLocalTurn: { [weak coordinator] in
          isIdle() && lane.asrUnits == 0 && !(coordinator?.hasFinalPassWork ?? false)
        },
        wakes: inputs.dictationWakes,
        emitFinished: inputs.emitSummaryFinished,
        log: inputs.log),
      documents: coordinator.documents, lane: lane)
  }

  /// Which work a job does, for the lane (R50): a final pass yields only to a running local
  /// summary call; a preview also to a local summary waiting for its turn.
  enum JobKind {
    case finalPass
    case preview
  }

  /// When a job's unit may start: dictation first, then the lane's order (R50).
  static func admission(
    _ kind: JobKind, lane: MeetingLocalModelLane, dictationIdle: @escaping @MainActor () -> Bool
  ) -> @MainActor () -> Bool {
    switch kind {
    case .finalPass: return { dictationIdle() && !lane.summaryCallRunning }
    case .preview: return { dictationIdle() && !lane.summaryActive }
    }
  }

  /// History's meeting facts, from the coordinator's in-memory durable copy (observable), and
  /// only while that copy is ready (`MeetingHistoryInfo.paired(with:)`).
  static func historyInfo(_ coordinator: MeetingCoordinator?, meetingID: UUID)
    -> MeetingHistoryInfo?
  {
    MeetingHistoryInfo.paired(with: coordinator?.record(id: meetingID))
  }

  /// One pass's job, with its own engine and its own model claim.
  static func makeJob(
    _ inputs: Inputs, lane: MeetingLocalModelLane, kind: JobKind
  ) -> MeetingTranscriptionJob {
    let isDeliveryEnabled = inputs.isDeliveryEnabled
    let engine = MeetingParakeetEngine(
      offlineModeAdmission: inputs.offlineModeAdmission, isModelSourceUsable: isDeliveryEnabled)
    let claim = MeetingModelClaim(gate: inputs.modelUseGate, resolve: inputs.meetingSelection)
    let isIdle = admission(kind, lane: lane, dictationIdle: inputs.isDictationIdle)
    let wakes = inputs.dictationWakes
    let pressure = inputs.memoryPressure
    let workChanged = inputs.workChanged
    return MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: isIdle,
        waitUntilDictationIdle: { await MeetingWorkAdmission.waitUntil(isIdle, wakes: wakes) },
        beginModelUse: { try await claim.acquire() },
        endModelUse: {
          await claim.release()
          workChanged()
        },
        loadEngine: {
          guard let selection = claim.selection else { throw MeetingWiringError.noModelClaim }
          try await engine.load(selection: selection)
        },
        transcribe: { samples in try await engine.transcribe(samples: samples, language: nil) },
        unloadEngine: { await engine.unload() },
        analyzeSpeakers: { audio in
          let analysis = await MeetingSpeakerAnalyzer.analyze(audio)
          // The speaker unit was an activation blocker; it has ended.
          await MainActor.run { workChanged() }
          return analysis
        },
        isTemporaryEngineContention: { MeetingParakeetEngine.isTemporaryContention($0) },
        waitForEngineAvailability: { try await engine.waitUntilOfflineModeAvailable() },
        isModelSourceUsable: isDeliveryEnabled,
        engineIdentity: { claim.engineIdentity },
        isMemoryPressureElevated: { pressure.isElevated },
        waitUntilMemoryNormal: { await pressure.waitUntilNormal() },
        // Every unit, teardown included, holds the lane from its admission to its physical end.
        unitStarted: { lane.asrBegan() },
        unitEnded: { lane.asrEnded() }))
  }
}

/// A meeting's hold on one installed model (#3972 R26, C4a item 15): the selection resolved
/// from the cache, the gate's use of its install directory, and a re-resolve under that use so
/// the engine loads exactly what the gate protects.
@MainActor
final class MeetingModelClaim {
  private let gate: MeetingModelUseGate
  private let resolve: @MainActor () async -> ParakeetModelSelection?
  private var held: (key: String, selection: ParakeetModelSelection)?
  /// Resolve attempts that changed under the gate before one held; bounded so a selection
  /// that never settles fails the unit instead of spinning.
  static let maxAttempts = 3

  init(
    gate: MeetingModelUseGate, resolve: @escaping @MainActor () async -> ParakeetModelSelection?
  ) {
    self.gate = gate
    self.resolve = resolve
  }

  var selection: ParakeetModelSelection? { held?.selection }
  var key: String? { held?.key }

  /// Model and revision of the held selection, for checkpoint identity. Nil when the revision
  /// is unknown, so pieces from an unnamed model are never reused.
  var engineIdentity: String? {
    guard let selection = held?.selection, let revision = selection.revision else { return nil }
    return "\(selection.model.rawValue):\(revision)"
  }

  /// Holds a use of the selected install. Throws `CancellationError` when cancelled (nothing is
  /// then held) and `MeetingWiringError` when no model is installed or the selection keeps
  /// changing.
  func acquire() async throws {
    guard held == nil else { return }
    for _ in 0..<Self.maxAttempts {
      try Task.checkCancellation()
      guard let first = await resolve() else { throw MeetingWiringError.noInstalledModel }
      let key = MeetingModelUseGate.key(forInstallDirectory: first.directory)
      try await gate.beginUse(key)
      // Held from here: every exit below either keeps it in `held` or ends it.
      let current = await resolve()
      if Task.isCancelled {
        await gate.endUse(key)
        throw CancellationError()
      }
      guard let current else {
        await gate.endUse(key)
        throw MeetingWiringError.noInstalledModel
      }
      if current == first {
        held = (key, current)
        return
      }
      await gate.endUse(key)
    }
    throw MeetingWiringError.selectionUnstable
  }

  /// Ends the held use, after the engine unloaded. Repeatable.
  func release() async {
    guard let held else { return }
    self.held = nil
    await gate.endUse(held.key)
  }
}

enum MeetingWiringError: Error, Equatable {
  /// No installed Parakeet model the meeting may load from the cache.
  case noInstalledModel
  /// The engine was asked to load without a held model claim.
  case noModelClaim
  /// The selected install changed under the gate on every attempt.
  case selectionUnstable
}
