import CryptoKit
import EnviousWisprAudio
import EnviousWisprCore
import Foundation

/// Runs one EnviousMeet meeting's after-recording pass (#3972 §3, R23-R25).
///
/// Order: for each track, speech in pieces cut at quiet moments (R16) with the Superwhisper
/// seam rule (R23) → speaker analysis per track → compose. ONE unit runs at a time, and a unit
/// starts only while dictation is idle (R25). Each decode is one engine operation
/// (`engineOperation`, #3973 C1): the engine is acquired for it and given back as soon as it
/// has physically finished, so a dictation pressed meanwhile waits only for that decode and
/// goes first; the next decode acquires again.
///
/// The engine, the speaker analysis and the dictation-activity facts are injected, so this type
/// holds only sequencing policy and is testable without models.
@MainActor
package final class MeetingTranscriptionJob {
  package struct Dependencies {
    /// True when no dictation is recording, transcribing, polishing or pasting.
    package var isDictationIdle: @MainActor () -> Bool
    /// Returns once `isDictationIdle` is true (event-driven in production). Must also return
    /// promptly when its task is cancelled: the job cancels it on `cancel()`.
    package var waitUntilDictationIdle: @MainActor () async -> Void
    /// Model-use gate (R26): held from before the engine loads until after it unloads.
    package var beginModelUse: @MainActor () async throws -> Void
    package var endModelUse: @MainActor () async -> Void
    package var loadEngine: @MainActor () async throws -> Void
    /// Transcribes 16 kHz mono samples in the pass's language (a code; nil is Auto); word times
    /// relative to the first sample.
    package var transcribe: @MainActor (_ samples: [Float], _ language: String?) async throws -> ASRResult
    package var unloadEngine: @MainActor () async -> Void
    /// Loads the bundled speaker models, analyses the whole track, releases the models (R25).
    package var analyzeSpeakers: @Sendable (MeetingTrackAudio) async -> MeetingSpeakerAnalysis
    /// Whether a `loadEngine` error is temporary contention (another load holds the shared
    /// offline mode), never a missing or broken model.
    package var isTemporaryEngineContention: @Sendable (Error) -> Bool
    /// Returns once that contention has ended (event-driven); throws when cancelled.
    package var waitForEngineAvailability: @MainActor () async throws -> Void
    /// Whether the installed model may still be read by a meeting. False when model delivery
    /// was turned off: dictation may then load with downloads allowed, and the vendor can
    /// write or purge the install. Checked before every unit; the pass then stops.
    package var isModelSourceUsable: @MainActor () -> Bool
    /// The loaded model's identity (model and revision), read after a load, so checkpointed
    /// pieces from another model are never mixed in. Nil when unknown.
    package var engineIdentity: @MainActor () -> String?
    /// macOS reports memory pressure at `.warning` or worse (plan §6: the job finishes its
    /// unit, unloads its engine and waits for `.normal`).
    package var isMemoryPressureElevated: @MainActor () -> Bool
    /// Returns once memory pressure is back to normal (event-driven). Must also return promptly
    /// when its task is cancelled.
    package var waitUntilMemoryNormal: @MainActor () async -> Void
    /// Told when a unit (normal or teardown) starts, in the same main-actor step as its
    /// admission check, and when it has physically ended (#3972 R50: the shared local-model
    /// lane, so no other local model work is admitted in between).
    package var unitStarted: @MainActor () -> Void
    package var unitEnded: @MainActor () -> Void
    /// #4052: told when a pass starts, before any engine work: the meeting and its recorded
    /// duration in seconds (the longest track's timeline end, gaps included; never the summed
    /// track audio).
    package var passStarted: @MainActor (_ meetingID: UUID?, _ meetingSeconds: Int) -> Void
    /// #4052: whether the engine this job holds is its own separate model (not one borrowed
    /// from dictation). Read by the engine switch gate.
    package var isOwnModelResident: @MainActor () -> Bool

    package init(
      isDictationIdle: @escaping @MainActor () -> Bool,
      waitUntilDictationIdle: @escaping @MainActor () async -> Void,
      beginModelUse: @escaping @MainActor () async throws -> Void,
      endModelUse: @escaping @MainActor () async -> Void,
      loadEngine: @escaping @MainActor () async throws -> Void,
      transcribe: @escaping @MainActor ([Float], String?) async throws -> ASRResult,
      unloadEngine: @escaping @MainActor () async -> Void,
      analyzeSpeakers: @escaping @Sendable (MeetingTrackAudio) async -> MeetingSpeakerAnalysis,
      isTemporaryEngineContention: @escaping @Sendable (Error) -> Bool = { _ in false },
      waitForEngineAvailability: @escaping @MainActor () async throws -> Void = {},
      isModelSourceUsable: @escaping @MainActor () -> Bool = { true },
      engineIdentity: @escaping @MainActor () -> String? = { nil },
      isMemoryPressureElevated: @escaping @MainActor () -> Bool = { false },
      waitUntilMemoryNormal: @escaping @MainActor () async -> Void = {},
      unitStarted: @escaping @MainActor () -> Void = {},
      unitEnded: @escaping @MainActor () -> Void = {},
      passStarted: @escaping @MainActor (UUID?, Int) -> Void = { _, _ in },
      isOwnModelResident: @escaping @MainActor () -> Bool = { false }
    ) {
      self.isDictationIdle = isDictationIdle
      self.waitUntilDictationIdle = waitUntilDictationIdle
      self.beginModelUse = beginModelUse
      self.endModelUse = endModelUse
      self.loadEngine = loadEngine
      self.transcribe = transcribe
      self.unloadEngine = unloadEngine
      self.analyzeSpeakers = analyzeSpeakers
      self.isTemporaryEngineContention = isTemporaryEngineContention
      self.waitForEngineAvailability = waitForEngineAvailability
      self.isModelSourceUsable = isModelSourceUsable
      self.engineIdentity = engineIdentity
      self.isMemoryPressureElevated = isMemoryPressureElevated
      self.waitUntilMemoryNormal = waitUntilMemoryNormal
      self.unitStarted = unitStarted
      self.unitEnded = unitEnded
      self.passStarted = passStarted
      self.isOwnModelResident = isOwnModelResident
    }
  }

  package struct Configuration: Sendable {
    package var pieceTargetSeconds: Double = 60
    package var pieceSearchSeconds: Double = 15
    package var seamPaddingSeconds: Double = 1
    /// #4052: false decodes each contiguous run in one call, the founder-approved final-pass
    /// shape (Transcribe a File's: #2648 measured 45 minutes in one Parakeet call losing fewer
    /// words than 5-minute slices did at their joins). No cut search, no seam padding, and every
    /// word the engine returns is kept. True keeps the earlier cut pieces.
    package var cutsPieces = true
    package init() {}
  }

  package enum Stage: Sendable, Equatable {
    case transcribing(track: MeetingTrackKind, fraction: Double)
    case findingSpeakers(track: MeetingTrackKind)
    case composing
  }

  package struct Result: Sendable {
    package let composition: MeetingComposition
    package let speakerOutcomes: [MeetingTrackKind: MeetingSpeakerOutcome]
    package let forcedCuts: Int
    package let failedPieces: Int
    /// Ranges (track timeline samples) whose piece failed twice: words missing there, not
    /// silence.
    package let failedRanges: [MeetingTrackKind: [Range<Int>]]
    /// Pieces taken from a checkpoint instead of being transcribed again.
    package let resumedPieces: Int
    /// Checkpoint saves that failed (the previous checkpoint stayed).
    package let checkpointSaveFailures: Int
    package let yieldCount: Int
    package let processingSeconds: Double
    package let audioSeconds: Double
    /// #3973 C2: what the attempt resolved to: the engine and model its words came from.
    package let resolved: MeetingResolvedAttempt
  }

  package enum JobError: Error, Equatable {
    case cancelled
    case engineUnavailable(String)
    /// `run` was called while a pass was already running on this job.
    case alreadyRunning
    /// #3973 C2: `language` is not the attempt's effective language. Both come from the same
    /// saved attempt; a disagreement is a caller defect, refused before any reuse or decode.
    case attemptMismatch
  }

  /// Where a pass keeps its progress (#3972 C3b). The job reads it once at the start and
  /// writes it after each piece or speaker analysis has physically finished, never after a
  /// cancel.
  /// `load` and `save` run off the main actor (encoding and the durable write can take
  /// tens of milliseconds on a multi-hour meeting); the job awaits each in order.
  ///
  /// Persistence drain contract: `run` returns (or throws) only after any save it started has
  /// returned, so an owner that cancels the job and awaits `run`'s end before deleting the
  /// meeting folder can never race a save; and the store refuses to recreate a missing meeting
  /// folder, so a save that loses that race fails instead of bringing the meeting back.
  package struct CheckpointAccess: Sendable {
    package let meetingID: UUID
    package let load: @Sendable () async -> MeetingProcessingCheckpoint?
    package let save: @Sendable (MeetingProcessingCheckpoint) async throws -> Void

    package init(
      meetingID: UUID, load: @escaping @Sendable () async -> MeetingProcessingCheckpoint?,
      save: @escaping @Sendable (MeetingProcessingCheckpoint) async throws -> Void
    ) {
      self.meetingID = meetingID
      self.load = load
      self.save = save
    }
  }

  /// Bumped whenever segmentation or ownership changes what a piece contains; a checkpoint
  /// from another version is discarded.
  package nonisolated static let processingVersion = 3

  private let dependencies: Dependencies
  private let configuration: Configuration
  private var cancelled = false
  /// #4105: the running pass's transcript language (a code; nil is Auto), from the meeting
  /// record. Every piece of the pass decodes with it.
  private var passLanguage: String?
  private var unitInFlight = false
  private var engineResident = false
  private var engineLoaded = false
  private var firstEngineIdentity: String?
  /// Times memory pressure unloaded the engine mid-pass. (#3973 C1 retired #3972's
  /// prolonged-pause unload: the job never waits for dictation with the engine loaded, so the
  /// memory that rule freed after 60 s is now never held during a pause at all.)
  private(set) package var pressureUnloads = 0
  private var running = false
  private(set) package var yieldCount = 0
  /// Told true when a unit starts waiting for dictation to finish, and false when it goes on
  /// (#3972 C5: the EnviousMeet page's "Paused while you dictate").
  package var onWaitingForDictation: (@MainActor (Bool) -> Void)?

  package init(dependencies: Dependencies, configuration: Configuration = .init()) {
    self.dependencies = dependencies
    self.configuration = configuration
  }

  /// Asks the job to stop at the next unit boundary. A running unit always finishes first; a
  /// wait for the engine to become available ends at once.
  package func cancel() {
    cancelled = true
    pendingWait?.cancel()
  }

  /// The wait in progress that `cancel()` interrupts: model-use acquisition or the wait for
  /// engine availability. Never a unit, which always finishes physically.
  private var pendingWait: (any PendingWait)?

  private protocol PendingWait { func cancel() }

  private struct PendingTask<T: Sendable>: PendingWait {
    let task: Task<T, Error>
    func cancel() { task.cancel() }
  }

  /// Runs `body` as a wait `cancel()` can interrupt; throws `JobError.cancelled` when it was.
  @discardableResult
  private func cancellableWait<T: Sendable>(_ body: @escaping @MainActor () async throws -> T)
    async throws -> T
  {
    let task = Task { @MainActor in try await body() }
    pendingWait = PendingTask(task: task)
    defer { pendingWait = nil }
    if cancelled { task.cancel() }
    do {
      return try await task.value
    } catch {
      if cancelled || error is CancellationError { throw JobError.cancelled }
      throw error
    }
  }
  /// Times the engine load met temporary contention and waited for it to end.
  private(set) package var engineContentionWaits = 0

  package var isUnitInFlight: Bool { unitInFlight }

  /// True from before the model-use gate is asked until the engine has unloaded. Dictation's
  /// Ultra activation waits while this is true (#3972: retiring an install would otherwise wait
  /// on the gate inside the switch).
  package var isEngineResident: Bool { engineResident }

  /// #4052: the engine this job holds is its own separate model (see `Dependencies`).
  package var isOwnModelResident: Bool { dependencies.isOwnModelResident() }

  private func releaseModelUse() async {
    engineResident = false
    engineLoaded = false
    await dependencies.endModelUse()
  }

  /// Unloads the engine and releases model use mid-pass, without waiting for dictation to go
  /// idle (unloading frees memory; it competes with nothing).
  private func releaseEngine() async {
    await unitIgnoringCancel { await self.dependencies.unloadEngine() }
    await releaseModelUse()
  }

  /// Before an engine operation: under memory pressure, unload and wait for normal; then load if
  /// needed. A load that brings a different model fails the pass, so two models' words are
  /// never mixed.
  private func prepareModelUnit() async throws {
    if dependencies.isMemoryPressureElevated() {
      if engineLoaded {
        pressureUnloads += 1
        await releaseEngine()
      }
      try await waitForNormalMemory()
    }
    if !engineLoaded {
      try await waitForNormalMemory()
      try await acquireAndLoadEngine()
      let identity = dependencies.engineIdentity()
      if let first = firstEngineIdentity, first != identity {
        await releaseEngine()
        throw JobError.engineUnavailable("model_changed")
      }
    }
  }

  /// Under memory pressure, waits (cancellably) for normal before any heavy model load.
  private func waitForNormalMemory() async throws {
    guard dependencies.isMemoryPressureElevated() else { return }
    try await cancellableWait { await self.dependencies.waitUntilMemoryNormal() }
    try checkCancelled()
  }

  /// A stretch of the meeting timeline whose audio file exists but cannot be read (#3972 R3).
  /// `endMs` is nil when nothing on disk bounds it (a damaged last file), never a guess.
  package struct MissingAudio: Sendable, Equatable {
    package let startMs: Int
    package let endMs: Int?

    package init(startMs: Int, endMs: Int?) {
      self.startMs = startMs
      self.endMs = endMs
    }
  }

  /// `missingAudio`: per track, the stretches no readable file covers. Each becomes a visible
  /// gap marker in timeline order, like a piece that failed twice, even for a track with no
  /// readable audio at all.
  ///
  /// `attempt` (#3973 C2) is the saved attempt this pass runs; `language` is its effective
  /// language, passed separately so the existing input stays. They must agree.
  package func run(
    tracks: [MeetingTrackKind: MeetingTrackAudio], language: String?,
    checkpoint access: CheckpointAccess? = nil,
    missingAudio: [MeetingTrackKind: [MissingAudio]] = [:],
    onStage: @escaping @MainActor (Stage) -> Void,
    attempt: MeetingAttemptConfiguration
  ) async throws -> Result {
    guard !running else { throw JobError.alreadyRunning }
    guard MeetingAttemptConfiguration.normalized(language) == attempt.requestedEffectiveLanguage
    else { throw JobError.attemptMismatch }
    running = true
    firstEngineIdentity = nil
    passLanguage = language?.isEmpty == false ? language : nil
    defer {
      running = false
      passLanguage = nil
    }
    let started = Date()
    let order: [MeetingTrackKind] = [.callSound, .microphone].filter {
      tracks[$0]?.isEmpty == false
    }
    let totalSamples = order.reduce(0) {
      $0 + (tracks[$1]?.runs.reduce(0) { $0 + $1.sampleCount } ?? 0)
    }
    let timelineEnd = order.compactMap { tracks[$0]?.endSample }.max() ?? 0
    dependencies.passStarted(
      access?.meetingID, Int((Double(timelineEnd) / MeetingAudioFormat.sampleRate).rounded()))

    // 0. Progress already committed for exactly these inputs, settings, attempt and model.
    // #3973 C2: the model identity is read before any reuse, so even a fully covered checkpoint
    // from another model is never reused. C2 resolves every attempt to its requested engine.
    if !order.isEmpty {
      try await waitForNormalMemory()
      firstEngineIdentity = try await probeEngineIdentity()
    }
    let resolved = MeetingResolvedAttempt(
      attemptID: attempt.attemptID, requestedEngine: attempt.requestedEngine,
      resolvedEngine: attempt.requestedEngine, effectiveLanguage: passLanguage,
      modelIdentity: firstEngineIdentity, fallbackReason: nil)
    var progress: MeetingProcessingCheckpoint?
    var saveFailures = 0
    if let access {
      // The key hashes every segment file, off the main actor. An input that cannot be read
      // fails closed: no reuse and no checkpoint for this pass.
      let config = configuration
      let meetingID = access.meetingID
      let language = passLanguage
      let engine = MeetingProcessingCheckpoint.Engine(
        requested: resolved.requestedEngine, resolved: resolved.resolvedEngine,
        modelIdentity: resolved.modelIdentity)
      let key = try? await Task.detached(priority: .utility) {
        try Self.key(
          meetingID: meetingID, attemptID: attempt.attemptID, tracks: tracks, order: order,
          language: language, engine: engine, config)
      }.value
      if let key {
        if let stored = await access.load(), stored.key == key,
          Self.isValid(stored, tracks: tracks)
        {
          progress = stored
        } else {
          progress = MeetingProcessingCheckpoint(key: key)
        }
      }
    }
    func commit() async {
      guard let access, let snapshot = progress, !cancelled else { return }
      do {
        try await access.save(snapshot)
      } catch {
        saveFailures += 1
      }
    }
    let resumedAtStart = progress?.tracks.values.reduce(0) { $0 + $1.pieces.count } ?? 0

    // 1. Speech, both tracks, one engine operation per decode (#3973 C1), only if some range is
    // not yet committed. The model identity was read above; a decode under another model fails
    // the pass (`prepareModelUnit`).
    let speechNeeded = order.contains { kind in
      guard let audio = tracks[kind] else { return false }
      return !Self.isFullyCovered(audio, by: progress?.tracks[kind]?.pieces ?? [])
    }
    if speechNeeded {
      do {
        for kind in order {
          guard let audio = tracks[kind] else { continue }
          let trackSamples = audio.runs.reduce(0) { $0 + $1.sampleCount }
          var done = 0
          let committed = progress?.tracks[kind]?.pieces ?? []
          var walked: [MeetingProcessingCheckpoint.Piece] = []
          for run in audio.runs {
            var cursor = run.startSample
            while cursor < run.endSample {
              try checkCancelled()
              let piece: MeetingProcessingCheckpoint.Piece
              if let reused = committed.first(where: {
                $0.startSample == cursor && $0.endSample <= run.endSample && $0.endSample > cursor
              }) {
                piece = reused
              } else {
                piece = try await nextPiece(audio: audio, run: run, from: cursor)
                if progress != nil {
                  progress?.tracks[kind, default: .init()].pieces =
                    walked + [piece] + committed.filter { $0.startSample > piece.startSample }
                  await commit()
                }
              }
              walked.append(piece)
              done += piece.endSample - cursor
              cursor = piece.endSample
              onStage(
                .transcribing(
                  track: kind, fraction: trackSamples > 0 ? Double(done) / Double(trackSamples) : 1))
            }
          }
          if progress != nil {
            progress?.tracks[kind, default: .init()].pieces = walked
            await commit()
          } else {
            transient[kind] = walked
          }
        }
      } catch {
        // Every operation gives its engine back on every exit; this only covers a throw that
        // could ever land between an acquisition and its operation.
        if engineResident { await releaseEngine() }
        throw error
      }
    }

    let piecesByTrack: [MeetingTrackKind: [MeetingProcessingCheckpoint.Piece]] =
      Dictionary(uniqueKeysWithValues: order.map { kind in
        (kind, progress?.tracks[kind]?.pieces ?? transient[kind] ?? [])
      })
    transient = [:]

    // 2. Speakers, one track at a time, each a full unit (models loaded and released inside).
    var outcomes: [MeetingTrackKind: MeetingSpeakerOutcome] = [:]
    var segments: [MeetingTrackKind: [SpeakerSegment]] = [:]
    for kind in order {
      guard let audio = tracks[kind],
        piecesByTrack[kind]?.contains(where: { $0.words != nil }) == true
      else { continue }
      if let stored = progress?.tracks[kind]?.speakers {
        outcomes[kind] = stored.outcome
        segments[kind] = stored.segments.map {
          SpeakerSegment(
            speakerId: $0.speakerId, startMs: $0.startMs, endMs: $0.endMs, quality: $0.quality)
        }
        continue
      }
      try checkCancelled()
      try await waitForNormalMemory()
      onStage(.findingSpeakers(track: kind))
      let analysis = try await unit { await self.dependencies.analyzeSpeakers(audio) }
      outcomes[kind] = analysis.outcome
      segments[kind] = analysis.segments
      if progress != nil {
        progress?.tracks[kind, default: .init()].speakers = .init(
          outcome: analysis.outcome,
          segments: analysis.segments.map {
            .init(speakerId: $0.speakerId, startMs: $0.startMs, endMs: $0.endMs, quality: $0.quality)
          })
        await commit()
      }
    }

    // 3. Compose off the main actor (an O(words x segments) scan on long meetings).
    try checkCancelled()
    onStage(.composing)
    let composedKinds = [MeetingTrackKind.callSound, .microphone].filter {
      order.contains($0) || missingAudio[$0]?.isEmpty == false
    }
    let inputs = composedKinds.map { kind in
      let markers = (missingAudio[kind] ?? []).map(Self.missingAudioMarker)
      let pieces = (piecesByTrack[kind] ?? []).compactMap(Self.trackPiece) + markers
      return MeetingTrackInput(
        kind: kind, pieces: pieces.sorted { $0.startMs < $1.startMs },
        speakerSegments: segments[kind] ?? [])
    }
    let composition = try await unit {
      await Task.detached(priority: .utility) { MeetingTranscriptComposer.compose(tracks: inputs) }
        .value
    }
    let all = piecesByTrack.values.flatMap { $0 }
    var failedRanges: [MeetingTrackKind: [Range<Int>]] = [:]
    for (kind, list) in piecesByTrack {
      let failed = list.filter { $0.words == nil }.map { $0.startSample..<$0.endSample }
      if !failed.isEmpty { failedRanges[kind] = failed }
    }
    return Result(
      composition: composition, speakerOutcomes: outcomes,
      forcedCuts: all.filter(\.forcedCut).count,
      failedPieces: all.filter { $0.words == nil }.count, failedRanges: failedRanges,
      resumedPieces: resumedAtStart == 0 ? 0 : min(resumedAtStart, all.count),
      checkpointSaveFailures: saveFailures, yieldCount: yieldCount,
      processingSeconds: Date().timeIntervalSince(started),
      audioSeconds: Double(totalSamples) / MeetingAudioFormat.sampleRate, resolved: resolved)
  }

  /// Pieces of a pass run without a checkpoint, held only for the pass.
  private var transient: [MeetingTrackKind: [MeetingProcessingCheckpoint.Piece]] = [:]

  /// Model use, then the engine load, waiting through temporary contention (C3a).
  private func acquireAndLoadEngine() async throws {
    // #3973 C1: nothing is held across any wait. A dictation running now is waited for first;
    // one that starts while the model-use claim is being taken, or a load refused by temporary
    // contention, gives the claim back before waiting, then the claim is taken again.
    while true {
      if !dependencies.isDictationIdle() { try await waitForDictationHoldingNothing() }
      // Memory pressure can rise during any earlier wait or a refused load: wait it out first.
      try await waitForNormalMemory()
      engineResident = true
      do {
        // A mutation of the model can hold this for its duration; a cancel ends the wait.
        try await cancellableWait { try await self.dependencies.beginModelUse() }
      } catch {
        engineResident = false
        throw error
      }
      if cancelled {
        // Acquired in the same moment as the cancel: give it straight back.
        await releaseModelUse()
        throw JobError.cancelled
      }
      // Same main-actor step as the load unit's own admission check: no dictation slips in,
      // and no load starts under memory pressure that rose while the claim was being taken.
      guard dependencies.isDictationIdle(), !dependencies.isMemoryPressureElevated() else {
        await releaseModelUse()
        continue
      }
      do {
        try await unit {
          try self.requireModelSource()
          try await self.dependencies.loadEngine()
        }
        engineLoaded = true
        return
      } catch let error where !(error is JobError)
        && dependencies.isTemporaryEngineContention(error)
      {
        // Contention for the shared offline mode is temporary: give the claim back, wait for
        // the contention to end (no polling, no failure counted), then take the claim again.
        await releaseModelUse()
        engineContentionWaits += 1
        try await cancellableWait { try await self.dependencies.waitForEngineAvailability() }
        try checkCancelled()
      } catch let error as JobError {
        await releaseModelUse()
        throw error
      } catch {
        await releaseModelUse()
        throw JobError.engineUnavailable(String(describing: error))
      }
    }
  }

  /// #3973 C1: the model identity, read under the model-use claim and given straight back, before
  /// any checkpointed piece is reused. Nothing is loaded and nothing stays held: the reused-piece
  /// walk, checkpoint saves and waits that follow run with the engine free.
  private func probeEngineIdentity() async throws -> String? {
    if !dependencies.isDictationIdle() { try await waitForDictationHoldingNothing() }
    engineResident = true
    do {
      try await cancellableWait { try await self.dependencies.beginModelUse() }
    } catch {
      engineResident = false
      throw error
    }
    let identity = dependencies.engineIdentity()
    await releaseModelUse()
    try checkCancelled()
    return identity
  }

  /// Waits, holding no engine resource, until dictation is idle, re-checking after every wake
  /// (work that took the turn meanwhile is waited for too). One yield however many waits it
  /// takes, reported as "Paused while you dictate"; `cancel()` ends it.
  private func waitForDictationHoldingNothing() async throws {
    guard !dependencies.isDictationIdle() else { return }
    yieldCount += 1
    while !dependencies.isDictationIdle() {
      try await reportingDictationWait {
        try await self.cancellableWait { await self.dependencies.waitUntilDictationIdle() }
      }
      try checkCancelled()
    }
  }

  // MARK: - Pieces

  /// The next piece from `cursor`: the cut (its own unit: the window read and the pause search
  /// are compute, R25), then the transcription (one unit per attempt, retried once).
  private func nextPiece(audio: MeetingTrackAudio, run: MeetingTrackAudio.Run, from cursor: Int)
    async throws -> MeetingProcessingCheckpoint.Piece
  {
    let (end, forced) = try await unit { try await self.nextCut(audio: audio, run: run, from: cursor) }
    let owned = try await transcribePiece(audio: audio, run: run, start: cursor, end: end)
    return MeetingProcessingCheckpoint.Piece(
      startSample: cursor, endSample: end, forcedCut: forced, text: owned?.text,
      words: owned?.words.map {
        .init(
          word: $0.word, lower: $0.range.lowerBound, upper: $0.range.upperBound,
          startMs: $0.startMs, endMs: $0.endMs)
      })
  }

  /// The marker turn a piece that failed twice becomes (plan §6): one word spanning the piece,
  /// so the transcript shows the missing stretch in place instead of skipping it.
  nonisolated static func gapMarker(startSample: Int, endSample: Int) -> MeetingTrackPiece {
    let text = "[Could not transcribe \(clock(ms(startSample))) to \(clock(ms(endSample)))]"
    return MeetingTrackPiece(
      text: text, startMs: ms(startSample), endMs: ms(endSample),
      words: [
        ASRWordTiming(
          word: text, range: 0..<text.utf16.count, startMs: ms(startSample), endMs: ms(endSample))
      ], isSpeech: false)
  }

  /// The marker for audio that exists but cannot be read: the gap marker when both ends are
  /// known, else "from" its start only.
  nonisolated static func missingAudioMarker(_ missing: MissingAudio) -> MeetingTrackPiece {
    guard let endMs = missing.endMs else {
      let text = "[Could not transcribe from \(clock(missing.startMs))]"
      return MeetingTrackPiece(
        text: text, startMs: missing.startMs, endMs: missing.startMs,
        words: [
          ASRWordTiming(
            word: text, range: 0..<text.utf16.count, startMs: missing.startMs,
            endMs: missing.startMs)
        ], isSpeech: false)
    }
    let text = "[Could not transcribe \(clock(missing.startMs)) to \(clock(endMs))]"
    return MeetingTrackPiece(
      text: text, startMs: missing.startMs, endMs: endMs,
      words: [
        ASRWordTiming(word: text, range: 0..<text.utf16.count, startMs: missing.startMs, endMs: endMs)
      ], isSpeech: false)
  }

  /// `m:ss`, or `h:mm:ss` from an hour.
  nonisolated static func clock(_ ms: Int) -> String {
    let total = ms / 1_000
    let (h, m, sec) = (total / 3_600, (total % 3_600) / 60, total % 60)
    return h > 0
      ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
  }

  nonisolated static func trackPiece(_ piece: MeetingProcessingCheckpoint.Piece) -> MeetingTrackPiece? {
    guard let text = piece.text, let words = piece.words else {
      return gapMarker(startSample: piece.startSample, endSample: piece.endSample)
    }
    return MeetingTrackPiece(
      text: text, startMs: ms(piece.startSample), endMs: ms(piece.endSample),
      words: words.map {
        ASRWordTiming(word: $0.word, range: $0.lower..<$0.upper, startMs: $0.startMs, endMs: $0.endMs)
      })
  }

  /// Whether a stored checkpoint is internally sound for these tracks before any of it is used:
  /// every piece lies inside one current run with a positive length, pieces are ordered and do
  /// not overlap, a piece has text and words together or neither, and every word range lies
  /// inside its text. Anything else is rejected and the pass starts fresh.
  nonisolated static func isValid(
    _ checkpoint: MeetingProcessingCheckpoint, tracks: [MeetingTrackKind: MeetingTrackAudio]
  ) -> Bool {
    for (kind, progress) in checkpoint.tracks {
      guard let audio = tracks[kind] else { return false }
      var previousEnd = Int.min
      for piece in progress.pieces {
        guard piece.endSample > piece.startSample, piece.startSample >= previousEnd,
          audio.runs.contains(where: {
            piece.startSample >= $0.startSample && piece.endSample <= $0.endSample
          })
        else { return false }
        previousEnd = piece.endSample
        switch (piece.text, piece.words) {
        case (nil, nil): continue
        case (let text?, let words?):
          let length = text.utf16.count
          guard words.allSatisfy({ $0.lower >= 0 && $0.lower <= $0.upper && $0.upper <= length })
          else { return false }
        default: return false
        }
      }
    }
    return true
  }

  /// Whether `pieces` already cover every run of `audio` end to end.
  nonisolated static func isFullyCovered(
    _ audio: MeetingTrackAudio, by pieces: [MeetingProcessingCheckpoint.Piece]
  ) -> Bool {
    for run in audio.runs {
      var cursor = run.startSample
      while cursor < run.endSample {
        guard let next = pieces.first(where: { $0.startSample == cursor && $0.endSample > cursor })
        else { return false }
        cursor = next.endSample
      }
    }
    return true
  }

  /// The checkpoint key for these inputs and settings: each segment identified by name, start,
  /// frame count, byte size and a SHA-256 of its bytes, never by path alone. Throws when any
  /// file cannot be read, so a pass never reuses work against inputs it could not verify.
  nonisolated static func key(
    meetingID: UUID, attemptID: UUID, tracks: [MeetingTrackKind: MeetingTrackAudio],
    order: [MeetingTrackKind], language: String?, engine: MeetingProcessingCheckpoint.Engine,
    _ configuration: Configuration
  ) throws -> MeetingProcessingCheckpoint.Key {
    MeetingProcessingCheckpoint.Key(
      meetingID: meetingID, attemptID: attemptID, processingVersion: processingVersion,
      pieceTargetSeconds: configuration.pieceTargetSeconds,
      pieceSearchSeconds: configuration.pieceSearchSeconds,
      seamPaddingSeconds: configuration.seamPaddingSeconds,
      cutsPieces: configuration.cutsPieces,
      transcriptLanguage: language, engine: engine,
      inputs: try order.map { kind in
        MeetingProcessingCheckpoint.TrackInventory(
          track: kind,
          segments: try (tracks[kind]?.segments ?? []).map { segment in
            let (size, hash) = try contentIdentity(of: segment.url)
            return .init(
              fileName: segment.url.lastPathComponent, startSample: segment.startSample,
              frameCount: segment.frameCount, byteSize: size, sha256: hash)
          })
      })
  }

  /// Byte count and SHA-256 (hex) of `url`, read in 1 MB chunks.
  nonisolated static func contentIdentity(of url: URL) throws -> (Int64, String) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var size: Int64 = 0
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
      size += Int64(chunk.count)
    }
    let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (size, hex)
  }

  private func nextCut(audio: MeetingTrackAudio, run: MeetingTrackAudio.Run, from cursor: Int)
    async throws
    -> (Int, Bool)
  {
    // #4052: a whole-run pass reads no audio to search for a cut.
    guard configuration.cutsPieces else { return (run.endSample, false) }
    let rate = MeetingAudioFormat.sampleRate
    let target = Int(configuration.pieceTargetSeconds * rate)
    let search = Int(configuration.pieceSearchSeconds * rate)
    guard run.endSample - cursor > target + search else { return (run.endSample, false) }
    let windowCount = min(run.endSample - cursor, target + search + Int(rate))
    var finder = MeetingPauseFinder.Configuration()
    finder.targetSeconds = configuration.pieceTargetSeconds
    finder.searchSeconds = configuration.pieceSearchSeconds
    let window = try await readOffMain(audio: audio, from: cursor, count: windowCount)
    let cuts = await Task.detached(priority: .utility) {
      MeetingPauseFinder.cuts(in: window, configuration: finder)
    }.value
    guard let first = cuts.first else { return (min(run.endSample, cursor + target), true) }
    return (cursor + first.sample, first.forced)
  }

  /// One segment: read the padded audio, transcribe, keep the words this piece owns (midpoint
  /// inside `start..<end`, R23), all inside one unit. Retries once; nil after the second
  /// failure. Cancellation and model-source loss are not failures and propagate.
  private func transcribePiece(
    audio: MeetingTrackAudio, run: MeetingTrackAudio.Run, start: Int, end: Int
  )
    async throws -> MeetingTrackPiece?
  {
    let rate = MeetingAudioFormat.sampleRate
    let cutsPieces = configuration.cutsPieces
    let language = passLanguage
    let pad = cutsPieces ? Int(configuration.seamPaddingSeconds * rate) : 0
    let paddedStart = max(run.startSample, start - pad)
    let paddedEnd = min(run.endSample, end + pad)
    for attempt in 0..<2 {
      do {
        return try await engineOperation { () async throws -> MeetingTrackPiece in
          try self.requireModelSource()
          let samples = try await self.readOffMain(
            audio: audio, from: paddedStart, count: paddedEnd - paddedStart)
          let result = try await self.dependencies.transcribe(samples, language)
          guard cutsPieces else {
            return Self.wholeRunPiece(result: result, startMs: Self.ms(start), endMs: Self.ms(end))
          }
          return await Task.detached(priority: .utility) {
            Self.ownedPiece(
              result: result, paddedStartMs: Self.ms(paddedStart), startMs: Self.ms(start),
              endMs: Self.ms(end))
          }.value
        }
      } catch let error as JobError {
        throw error
      } catch {
        if attempt == 1 { return nil }
      }
    }
    return nil
  }

  /// #4052: a whole run decoded in one call has no seam, so nothing is filtered: the engine's
  /// text and every word are kept as returned (boundary and untimed words included), with the
  /// word times moved onto the meeting timeline. Text ranges are unchanged.
  nonisolated static func wholeRunPiece(result: ASRResult, startMs: Int, endMs: Int)
    -> MeetingTrackPiece
  {
    MeetingTrackPiece(
      text: result.text, startMs: startMs, endMs: endMs,
      words: (result.wordTimings ?? []).map {
        ASRWordTiming(
          word: $0.word, range: $0.range, startMs: $0.startMs.map { startMs + $0 },
          endMs: $0.endMs.map { startMs + $0 })
      })
  }

  /// The words of `result` whose midpoint falls in this piece's own range, as a piece on the
  /// meeting timeline. An untimed word belongs with the nearest timed word before it (or, when
  /// none precedes it, after it), so it is owned exactly when that neighbour is. Without any
  /// word timings the whole text is kept (no seam rule possible; nothing is dropped).
  nonisolated static func ownedPiece(
    result: ASRResult, paddedStartMs: Int, startMs: Int, endMs: Int
  )
    -> MeetingTrackPiece
  {
    guard let timings = result.wordTimings, !timings.isEmpty,
      timings.contains(where: { $0.startMs != nil && $0.endMs != nil })
    else {
      return MeetingTrackPiece(text: result.text, startMs: startMs, endMs: endMs, words: [])
    }
    func owned(_ w: ASRWordTiming) -> Bool? {
      guard let s = w.startMs, let e = w.endMs else { return nil }
      let mid = paddedStartMs + (s + e) / 2
      return mid >= startMs && mid < endMs
    }
    // Ownership per word: timed words by midpoint; untimed words inherit from a neighbour.
    var ownership = timings.map(owned)
    var last: Bool?
    for i in ownership.indices {
      if let value = ownership[i] { last = value } else if let last { ownership[i] = last }
    }
    var next: Bool?
    for i in ownership.indices.reversed() {
      if let value = ownership[i] { next = value } else if let next { ownership[i] = next }
    }
    var text = ""
    var words: [ASRWordTiming] = []
    for (w, isOwned) in zip(timings, ownership) where isOwned == true {
      let trimmed = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      if !text.isEmpty { text += " " }
      let lower = text.utf16.count
      text += trimmed
      words.append(
        ASRWordTiming(
          word: trimmed, range: lower..<text.utf16.count,
          startMs: w.startMs.map { paddedStartMs + $0 }, endMs: w.endMs.map { paddedStartMs + $0 }))
    }
    return MeetingTrackPiece(text: text, startMs: startMs, endMs: endMs, words: words)
  }

  // MARK: - Units and admission

  /// Runs one unit: waits until dictation is idle, holds the actor-owned token until the
  /// unit's task has physically finished, then releases it (R25).
  private func unit<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws
    -> T
  {
    try checkCancelled()
    // Checked again after every wait, and the unit starts in the same main-actor step as the
    // last check: work that took the turn while this one resumed is waited for too (#3972 R50).
    var yielded = false
    while !dependencies.isDictationIdle() {
      if !yielded {
        yieldCount += 1
        yielded = true
      }
      try await reportingDictationWait {
        try await self.cancellableWait { await self.dependencies.waitUntilDictationIdle() }
      }
      try checkCancelled()
    }
    try checkCancelled()
    precondition(!unitInFlight, "MeetingTranscriptionJob runs one unit at a time")
    unitInFlight = true
    // Same main-actor step as the admission check above: nothing is admitted in between.
    dependencies.unitStarted()
    let task = Task { @MainActor in try await work() }
    let result = await task.result
    unitInFlight = false
    dependencies.unitEnded()
    return try result.get()
  }

  /// Runs one wait for dictation to finish, telling `onWaitingForDictation` true before it and
  /// false after it, however it ends (#3972 C5). Every dictation wait goes through here.
  private func reportingDictationWait<T>(_ wait: () async throws -> T) async rethrows -> T {
    onWaitingForDictation?(true)
    defer { onWaitingForDictation?(false) }
    return try await wait()
  }

  /// #3973 C1: one engine operation (one decode attempt; a retry is another operation). The
  /// engine is acquired and loaded for it (`prepareModelUnit`: the route, the model-use claim and
  /// the model are taken fresh and the model identity checked), the decode runs as one unit and
  /// is joined physically, and then everything the operation held is given back: the shared
  /// lease (handing the turn to a waiting dictation in the same step), the model-use claim,
  /// timer suppression, and the meeting's own Parakeet copy. Only after that does the caller
  /// write a checkpoint or wait. Dictation has priority (decision 11), so it never waits for
  /// more than the operation running when it pressed.
  ///
  /// The boundary is this method, not the generic unit: a cut search, a speaker analysis or the
  /// composition is a unit too, and none of them holds or releases the engine.
  private func engineOperation<T: Sendable>(
    _ work: @escaping @MainActor () async throws -> T
  ) async throws -> T {
    // A dictation that started while the engine was being acquired or loaded goes first: the
    // operation gives everything back, waits holding nothing, and acquires again.
    // Memory pressure that rose during the load is handled the same way: unload, wait for
    // normal holding nothing, load again; no decode starts under pressure.
    while true {
      try await prepareModelUnit()
      if dependencies.isMemoryPressureElevated() {
        pressureUnloads += 1
        await releaseEngine()
        try await waitForNormalMemory()
        continue
      }
      // Same main-actor step as the unit's admission check below: no dictation slips in.
      if dependencies.isDictationIdle() { break }
      await releaseEngine()
      try await waitForDictationHoldingNothing()
    }
    let result: Swift.Result<T, Error>
    do {
      result = .success(try await unit(work))
    } catch {
      result = .failure(error)
    }
    // `unit` returned only after the decode's task physically ended, success or not.
    if engineResident { await releaseEngine() }
    return try result.get()
  }

  /// Teardown units (unloading the engine) run even after a cancel, and never wait for
  /// dictation: an operation's end, cancellation, errors, memory pressure and R32 release at
  /// once, so a dictation waiting for the engine, or a cancelled or deleted job, is never kept
  /// waiting by the release itself (#3973 C1).
  private func unitIgnoringCancel(_ work: @escaping @MainActor () async -> Void) async {
    unitInFlight = true
    dependencies.unitStarted()
    await Task { @MainActor in await work() }.value
    unitInFlight = false
    dependencies.unitEnded()
  }

  /// Model work stops once the installed model may no longer be read (delivery turned off).
  /// Checked inside the unit, after its dictation-idle wait, so no load or decode starts after
  /// the switch. Known system quirk (#3972 plan R32, founder-accepted): a running decode is not
  /// interrupted, and the vendor's download path does not honour the use claim. (#3973 C1 removed
  /// the other half of that quirk: the job no longer pauses for dictation with the model loaded
  /// and its use claim held.)
  private func requireModelSource() throws {
    guard dependencies.isModelSourceUsable() else {
      throw JobError.engineUnavailable("model_source_unavailable")
    }
  }

  private func checkCancelled() throws {
    if cancelled { throw JobError.cancelled }
  }

  private func readOffMain(audio: MeetingTrackAudio, from start: Int, count: Int) async throws
    -> [Float]
  {
    try await Task.detached(priority: .utility) { try audio.read(from: start, count: count) }.value
  }

  nonisolated static func ms(_ sample: Int) -> Int {
    Int((Double(sample) * 1000 / MeetingAudioFormat.sampleRate).rounded())
  }
}

/// What speaker analysis of one track produced (#3972 R5, R25).
package struct MeetingSpeakerAnalysis: Sendable {
  package let outcome: MeetingSpeakerOutcome
  package let segments: [SpeakerSegment]

  package init(outcome: MeetingSpeakerOutcome, segments: [SpeakerSegment]) {
    self.outcome = outcome
    self.segments = segments
  }
}
