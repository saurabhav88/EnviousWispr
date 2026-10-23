import AVFoundation
import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// Blocks the calling thread on `semaphore` for at most `seconds` (a synchronous helper, so an
/// async closure can hold a thread on purpose in a test). True when signalled, false on timeout.
@discardableResult
func blockThread(on semaphore: DispatchSemaphore, seconds: Double = 10) -> Bool {
  semaphore.wait(timeout: .now() + seconds) == .success
}

/// Deterministic stand-in for the engine, shared by the job tests and the process-death child:
/// one word every 500 ms of the audio it is handed, timed from the piece's first sample.
enum FakeSpeech {
  static func transcribe(_ samples: [Float]) -> ASRResult {
    let ms = samples.count * 1000 / 16_000
    var text = ""
    var timings: [ASRWordTiming] = []
    var t = 0
    while t + 400 <= ms {
      if !text.isEmpty { text += " " }
      let lower = text.utf16.count
      text += "w"
      timings.append(ASRWordTiming(word: "w", range: lower..<text.utf16.count, startMs: t, endMs: t + 400))
      t += 500
    }
    return ASRResult(
      text: text, language: nil, duration: Double(ms) / 1000, processingTime: 0,
      backendType: .parakeet, wordTimings: timings)
  }
}

/// #3972 R23, R25: when these fail, a meeting transcript loses or doubles words where pieces
/// join, or meeting work runs while the user dictates.
@Suite("MeetingTranscriptionJob", .tags(.productOutcome))
@MainActor
struct MeetingTranscriptionJobTests {

  // MARK: - Fixtures

  /// Writes a 16 kHz mono CAF of `seconds` of tone at `startMs` and returns its file entry.
  private func segment(in dir: URL, index: Int, startMs: Int, seconds: Double) throws -> (
    url: URL, startMs: Int
  ) {
    let name = MeetingSegmentNaming.fileName(
      track: .microphone, index: index, startMs: startMs, partial: false)
    let url = dir.appendingPathComponent(name)
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
      ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * 16_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.3 }
    try file.write(from: buffer)
    return (url, startMs)
  }

  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("MeetingJobTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A fake engine: one "word" per 500 ms of the audio it is handed, timed relative to the
  /// piece's first sample. Words land in the padding too, so the seam rule is what keeps each
  /// word exactly once.
  @MainActor
  private final class FakeEngine {
    var calls: [Int] = []  // sample counts per call
    var dictationActiveDuringCall = false
    var isDictationIdle: @MainActor () -> Bool = { true }

    func transcribe(_ samples: [Float]) -> ASRResult {
      calls.append(samples.count)
      if !isDictationIdle() { dictationActiveDuringCall = true }
      let ms = samples.count * 1000 / 16_000
      var text = ""
      var timings: [ASRWordTiming] = []
      var t = 0
      while t + 400 <= ms {
        if !text.isEmpty { text += " " }
        let lower = text.utf16.count
        text += "w"
        timings.append(
          ASRWordTiming(word: "w", range: lower..<text.utf16.count, startMs: t, endMs: t + 400))
        t += 500
      }
      return ASRResult(
        text: text, language: nil, duration: Double(ms) / 1000, processingTime: 0,
        backendType: .parakeet, wordTimings: timings)
    }
  }

  private func makeJob(
    engine: FakeEngine, idle: @escaping @MainActor () -> Bool,
    wait: @escaping @MainActor () async -> Void
  )
    -> MeetingTranscriptionJob
  {
    engine.isDictationIdle = idle
    var config = MeetingTranscriptionJob.Configuration()
    config.pieceTargetSeconds = 20
    config.pieceSearchSeconds = 5
    return MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: idle, waitUntilDictationIdle: wait, beginModelUse: {}, endModelUse: {},
        loadEngine: {}, transcribe: { engine.transcribe($0) }, unloadEngine: {},
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }),
      configuration: config)
  }

  // MARK: - Tests

  @Test(
    "a 70 s track is transcribed in pieces and every word appears exactly once across the joins")
  func seamsKeepEveryWordOnce() async throws {
    let dir = try folder()
    let files = [
      try segment(in: dir, index: 1, startMs: 0, seconds: 60),
      try segment(in: dir, index: 2, startMs: 60_000, seconds: 10),
    ]
    let engine = FakeEngine()
    let job = makeJob(engine: engine, idle: { true }, wait: {})
    let result = try await job.run(tracks: [.microphone: MeetingTrackAudio(files: files)]) { _ in }

    #expect(engine.calls.count >= 3)
    // The fake emits a word every 500 ms over each PADDED piece; ownership by midpoint must
    // leave one word per 500 ms of the whole 70 s track, no more and no fewer.
    let wordCount = result.composition.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    #expect(abs(wordCount - 140) <= 4, "words=\(wordCount)")
    #expect(result.failedPieces == 0)
  }

  @Test("every engine call runs inside a unit the lane is told about, teardown included (R50)")
  func unitsReportToTheLane() async throws {
    let dir = try folder()
    let files = [try segment(in: dir, index: 1, startMs: 0, seconds: 10)]
    let engine = FakeEngine()
    var open = 0
    var started = 0
    var outsideUnit: [String] = []
    func inUnit(_ name: String) { if open != 1 { outsideUnit.append(name) } }
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { true }, waitUntilDictationIdle: {}, beginModelUse: {},
        endModelUse: {},
        loadEngine: { inUnit("load") },
        transcribe: {
          inUnit("transcribe")
          return engine.transcribe($0)
        },
        unloadEngine: { inUnit("unload") },
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) },
        unitStarted: {
          open += 1
          started += 1
        },
        unitEnded: { open -= 1 }))
    _ = try await job.run(tracks: [.microphone: MeetingTrackAudio(files: files)]) { _ in }
    #expect(outsideUnit.isEmpty, "engine work outside a reported unit: \(outsideUnit)")
    #expect(open == 0, "every unit that started has ended")
    #expect(started >= 3, "load, decode and unload each report")
  }

  @Test("no unit starts while dictation is active; the job waits and counts the yield")
  func waitsForDictation() async throws {
    let dir = try folder()
    let files = [try segment(in: dir, index: 1, startMs: 0, seconds: 10)]
    let engine = FakeEngine()
    var dictating = true
    var waits = 0
    let job = makeJob(
      engine: engine, idle: { !dictating },
      wait: {
        waits += 1
        dictating = false
      })
    // #3972 C5: the page's "Paused while you dictate" reads these reports.
    var waitReports: [Bool] = []
    job.onWaitingForDictation = { waitReports.append($0) }
    let result = try await job.run(tracks: [.microphone: MeetingTrackAudio(files: files)]) { _ in }
    #expect(waits >= 1)
    #expect(result.yieldCount >= 1)
    #expect(!engine.dictationActiveDuringCall)
    #expect(waitReports.first == true)
    #expect(waitReports.last == false)
    #expect(waitReports.filter { $0 }.count == waitReports.filter { !$0 }.count)
  }

  @Test("a gap between segments is two runs: no piece spans the gap")
  func gapsSplitRuns() async throws {
    let dir = try folder()
    let files = [
      try segment(in: dir, index: 1, startMs: 0, seconds: 5),
      try segment(in: dir, index: 2, startMs: 30_000, seconds: 5),
    ]
    let audio = MeetingTrackAudio(files: files)
    #expect(audio.runs.count == 2)
    let engine = FakeEngine()
    let job = makeJob(engine: engine, idle: { true }, wait: {})
    _ = try await job.run(tracks: [.microphone: audio]) { _ in }
    #expect(engine.calls.allSatisfy { $0 <= 6 * 16_000 })
  }

  // MARK: - Engine ownership (C3a)

  private struct Contention: Error {}

  /// A job whose engine load meets `contentions` temporary refusals before it loads. The
  /// availability wait parks until `release` is called. Records the order of ownership steps.
  @MainActor
  private final class OwnershipRig {
    var log: [String] = []
    var contentions: Int
    var waiting: CheckedContinuation<Void, Error>?
    var waitEntered: CheckedContinuation<Void, Never>?
    var residentDuringLoad: Bool?
    var job: MeetingTranscriptionJob!

    init(contentions: Int) {
      self.contentions = contentions
      job = MeetingTranscriptionJob(
        dependencies: .init(
          isDictationIdle: { true }, waitUntilDictationIdle: {},
          beginModelUse: { [unowned self] in log.append("use") },
          endModelUse: { [unowned self] in log.append("release") },
          loadEngine: { [unowned self] in
            residentDuringLoad = job.isEngineResident
            if self.contentions > 0 {
              self.contentions -= 1
              log.append("busy")
              throw Contention()
            }
            log.append("load")
          },
          transcribe: { _ in
            ASRResult(text: "", language: nil, duration: 0, processingTime: 0, backendType: .parakeet)
          },
          unloadEngine: { [unowned self] in log.append("unload") },
          analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) },
          isTemporaryEngineContention: { $0 is Contention },
          waitForEngineAvailability: { [unowned self] in
            log.append("wait")
            // Honors cancellation as the production wait (`ASRManager`) does.
            try await withTaskCancellationHandler {
              try await withCheckedThrowingContinuation { continuation in
                waiting = continuation
                waitEntered?.resume()
                waitEntered = nil
              }
            } onCancel: {
              Task { @MainActor [unowned self] in
                waiting?.resume(throwing: CancellationError())
                waiting = nil
              }
            }
          }))
    }

    func untilWaiting() async {
      guard waiting == nil else { return }
      await withCheckedContinuation { waitEntered = $0 }
    }

    func release() {
      waiting?.resume()
      waiting = nil
    }
  }

  @Test(
    "a load refused by temporary contention waits for its release and loads; nothing fails",
    .timeLimit(.minutes(1)))
  func contentionWaitsThenLoads() async throws {
    let dir = try folder()
    let files = [try segment(in: dir, index: 1, startMs: 0, seconds: 2)]
    let rig = OwnershipRig(contentions: 1)
    let run = Task { try await rig.job.run(tracks: [.microphone: MeetingTrackAudio(files: files)]) { _ in } }
    await rig.untilWaiting()
    #expect(rig.job.isEngineResident, "ownership is held through the wait")
    rig.release()
    _ = try await run.value
    #expect(rig.job.engineContentionWaits == 1)
    #expect(rig.log == ["use", "busy", "wait", "load", "unload", "release"])
    #expect(rig.residentDuringLoad == true)
    #expect(!rig.job.isEngineResident)
  }

  @Test("a cancel during the contention wait ends the job and releases the model", .timeLimit(.minutes(1)))
  func cancelDuringContentionWait() async throws {
    let dir = try folder()
    let files = [try segment(in: dir, index: 1, startMs: 0, seconds: 2)]
    let rig = OwnershipRig(contentions: 1)
    let run = Task { try await rig.job.run(tracks: [.microphone: MeetingTrackAudio(files: files)]) { _ in } }
    await rig.untilWaiting()
    rig.job.cancel()
    await #expect(throws: MeetingTranscriptionJob.JobError.cancelled) { _ = try await run.value }
    #expect(rig.log == ["use", "busy", "wait", "release"])
    #expect(!rig.job.isEngineResident)
    rig.release()  // a late release finds nothing to resume
  }

  @Test(
    "a cancel while waiting for model access behind a model change ends at once, holding nothing",
    .timeLimit(.minutes(1)))
  func cancelWhileWaitingForModelUse() async throws {
    let dir = try folder()
    let files = [try segment(in: dir, index: 1, startMs: 0, seconds: 2)]
    let gate = MeetingModelUseGate()
    try await gate.beginMutation("model")  // a model change in progress
    let (asked, askedSignal) = AsyncStream<Void>.makeStream()
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { true }, waitUntilDictationIdle: {},
        beginModelUse: {
          askedSignal.yield()
          try await gate.beginUse("model")
        },
        endModelUse: { await gate.endUse("model") },
        loadEngine: {},
        transcribe: { _ in
          ASRResult(text: "", language: nil, duration: 0, processingTime: 0, backendType: .parakeet)
        },
        unloadEngine: {},
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }))
    let run = Task { try await job.run(tracks: [.microphone: MeetingTrackAudio(files: files)]) { _ in } }
    var iterator = asked.makeAsyncIterator()
    _ = await iterator.next()
    job.cancel()
    await #expect(throws: MeetingTranscriptionJob.JobError.cancelled) { _ = try await run.value }
    #expect(!job.isEngineResident)
    #expect(await gate.isInUse("model") == false, "no use was counted or leaked")
    await gate.endMutation("model")
  }

  @Test("model delivery turned off after the load stops the pass before the next decode")
  func deliveryOffStopsModelWork() async throws {
    let dir = try folder()
    let files = [try segment(in: dir, index: 1, startMs: 0, seconds: 2)]
    final class State: @unchecked Sendable {
      var usable = true
      var decodes = 0
      var log: [String] = []
    }
    let state = State()
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { true }, waitUntilDictationIdle: {},
        beginModelUse: { state.log.append("use") },
        endModelUse: { state.log.append("release") },
        loadEngine: {
          state.log.append("load")
          state.usable = false  // the switch flips right after the load
        },
        transcribe: { _ in
          state.decodes += 1
          return ASRResult(
            text: "", language: nil, duration: 0, processingTime: 0, backendType: .parakeet)
        },
        unloadEngine: { state.log.append("unload") },
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) },
        isModelSourceUsable: { state.usable }))
    await #expect(throws: MeetingTranscriptionJob.JobError.engineUnavailable("model_source_unavailable")) {
      _ = try await job.run(tracks: [.microphone: MeetingTrackAudio(files: files)]) { _ in }
    }
    #expect(state.decodes == 0)
    #expect(state.log == ["use", "load", "unload", "release"])
    #expect(!job.isEngineResident)
  }

  @Test(
    "delivery off while paused for dictation: the model stays held until dictation ends, then no decode, unload, release",
    .timeLimit(.minutes(1)))
  func deliveryOffWhilePausedForDictation() async throws {
    let dir = try folder()
    let files = [try segment(in: dir, index: 1, startMs: 0, seconds: 2)]
    @MainActor final class State {
      var usable = true
      var dictating = false
      var decodes = 0
      var log: [String] = []
      var idleWaiter: CheckedContinuation<Void, Never>?
      var pausedSignal: CheckedContinuation<Void, Never>?
    }
    let state = State()
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { !state.dictating },
        waitUntilDictationIdle: {
          state.log.append("paused")
          await withCheckedContinuation { continuation in
            state.idleWaiter = continuation
            state.pausedSignal?.resume()
            state.pausedSignal = nil
          }
        },
        beginModelUse: { state.log.append("use") },
        endModelUse: { state.log.append("release") },
        loadEngine: {
          state.log.append("load")
          state.dictating = true  // the user starts dictating right after the load
        },
        transcribe: { _ in
          state.decodes += 1
          return ASRResult(
            text: "", language: nil, duration: 0, processingTime: 0, backendType: .parakeet)
        },
        unloadEngine: { state.log.append("unload") },
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) },
        isModelSourceUsable: { state.usable }))
    let run = Task { try await job.run(tracks: [.microphone: MeetingTrackAudio(files: files)]) { _ in } }
    await withCheckedContinuation { state.pausedSignal = $0 }
    state.usable = false  // delivery turned off while the job is paused
    // Documented limit: the model is still loaded and its use still held while dictation runs.
    #expect(state.log == ["use", "load", "paused"])
    #expect(job.isEngineResident)
    state.dictating = false
    state.idleWaiter?.resume()
    await #expect(throws: MeetingTranscriptionJob.JobError.engineUnavailable("model_source_unavailable")) {
      _ = try await run.value
    }
    #expect(state.decodes == 0)
    #expect(state.log == ["use", "load", "paused", "unload", "release"])
    #expect(!job.isEngineResident)
  }

  // MARK: - Checkpoints and pieces (C3b)

  /// A job over a fake engine with a real checkpoint store. `afterSaves` runs after each
  /// successful save with the running count (a test cancels there to simulate a crash).
  private func checkpointJob(
    engine: FakeEngine, identity: String = "ultra:r1", target: Double = 20,
    analyses: OSAllocatedUnfairLock<Int>? = nil
  ) -> MeetingTranscriptionJob {
    var config = MeetingTranscriptionJob.Configuration()
    config.pieceTargetSeconds = target
    config.pieceSearchSeconds = 5
    return MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { true }, waitUntilDictationIdle: {}, beginModelUse: {}, endModelUse: {},
        loadEngine: {}, transcribe: { engine.transcribe($0) }, unloadEngine: {},
        analyzeSpeakers: { _ in
          analyses?.withLock { $0 += 1 }
          return MeetingSpeakerAnalysis(
            outcome: .single, segments: [SpeakerSegment(speakerId: "1", startMs: 0, endMs: 1_000, quality: 1)])
        },
        engineIdentity: { identity }),
      configuration: config)
  }

  private func access(
    _ store: MeetingProcessingCheckpointStore, meetingID: UUID,
    afterSave: (@MainActor (Int) -> Void)? = nil
  ) -> MeetingTranscriptionJob.CheckpointAccess {
    let saves = OSAllocatedUnfairLock(initialState: 0)
    return .init(
      meetingID: meetingID,
      load: {
        if case .checkpoint(let c) = store.load() { return c }
        return nil
      },
      save: { checkpoint in
        try store.save(checkpoint)
        let count = saves.withLock { value -> Int in
          value += 1
          return value
        }
        if let afterSave { await MainActor.run { afterSave(count) } }
      })
  }

  private func words(_ result: MeetingTranscriptionJob.Result) -> Int {
    result.composition.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
  }

  @Test("an interrupted pass resumes from its checkpoint: done pieces are not redone, every word appears once")
  func resumesWithoutRedoingOrDoubling() async throws {
    let dir = try folder()
    let files = [
      try segment(in: dir, index: 1, startMs: 0, seconds: 60),
      try segment(in: dir, index: 2, startMs: 60_000, seconds: 10),
    ]
    let audio = MeetingTrackAudio(files: files)
    let store = MeetingProcessingCheckpointStore(meetingFolder: dir)
    let meetingID = UUID()

    // Pass 1 stops after its second committed piece (a crash leaves the same files).
    let first = FakeEngine()
    let job1 = checkpointJob(engine: first)
    await #expect(throws: MeetingTranscriptionJob.JobError.cancelled) {
      _ = try await job1.run(
        tracks: [.microphone: audio],
        checkpoint: access(store, meetingID: meetingID) { saves in if saves == 2 { job1.cancel() } }
      ) { _ in }
    }
    guard case .checkpoint(let saved) = store.load() else {
      Issue.record("no checkpoint after the interrupted pass")
      return
    }
    let committed = saved.tracks[.microphone]?.pieces.count ?? 0
    #expect(committed == 2)

    // Pass 2 on a fresh job: only the remaining pieces are transcribed.
    let second = FakeEngine()
    let analyses = OSAllocatedUnfairLock(initialState: 0)
    let job2 = checkpointJob(engine: second, analyses: analyses)
    let result = try await job2.run(
      tracks: [.microphone: audio], checkpoint: access(store, meetingID: meetingID)) { _ in }
    let fresh = FakeEngine()
    let reference = try await checkpointJob(engine: fresh).run(tracks: [.microphone: audio]) { _ in }
    #expect(second.calls.count == fresh.calls.count - committed)
    #expect(result.resumedPieces == committed)
    #expect(words(result) == words(reference))
    #expect(result.composition.text == reference.composition.text)
    #expect(analyses.withLock { $0 } == 1)

    // Pass 3: everything committed, including speakers. No engine, no analysis.
    let third = FakeEngine()
    let again = OSAllocatedUnfairLock(initialState: 0)
    let result3 = try await checkpointJob(engine: third, analyses: again).run(
      tracks: [.microphone: audio], checkpoint: access(store, meetingID: meetingID)) { _ in }
    #expect(third.calls.isEmpty)
    #expect(again.withLock { $0 } == 0)
    #expect(result3.composition.text == reference.composition.text)
  }

  @Test("a checkpoint for other settings, another meeting or another model is not reused")
  func incompatibleCheckpointsAreDiscarded() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 30)])
    let store = MeetingProcessingCheckpointStore(meetingFolder: dir)
    let meetingID = UUID()
    let baseline = FakeEngine()
    _ = try await checkpointJob(engine: baseline).run(
      tracks: [.microphone: audio], checkpoint: access(store, meetingID: meetingID)) { _ in }
    let total = baseline.calls.count
    #expect(total > 1)

    let otherSettings = FakeEngine()
    _ = try await checkpointJob(engine: otherSettings, target: 10).run(
      tracks: [.microphone: audio], checkpoint: access(store, meetingID: meetingID)) { _ in }
    #expect(otherSettings.calls.count > 0, "a different piece length starts over")

    let otherMeeting = FakeEngine()
    _ = try await checkpointJob(engine: otherMeeting).run(
      tracks: [.microphone: audio], checkpoint: access(store, meetingID: UUID())) { _ in }
    #expect(otherMeeting.calls.count == total)

    // Same meeting and settings, interrupted after one piece, resumed under a different model:
    // every piece is redone, so two models' words are never mixed. (A pass already complete is
    // reused whatever model is current: nothing is left to mix.)
    try store.clear()
    let base2 = FakeEngine()
    let job2 = checkpointJob(engine: base2)
    await #expect(throws: MeetingTranscriptionJob.JobError.cancelled) {
      _ = try await job2.run(
        tracks: [.microphone: audio],
        checkpoint: access(store, meetingID: meetingID) { saves in if saves == 1 { job2.cancel() } }
      ) { _ in }
    }
    let otherModel = FakeEngine()
    _ = try await checkpointJob(engine: otherModel, identity: "v3:r9").run(
      tracks: [.microphone: audio], checkpoint: access(store, meetingID: meetingID)) { _ in }
    #expect(otherModel.calls.count == total)
  }

  @Test("a piece that fails twice is a reported gap; its neighbours keep their words")
  func failedPieceIsAGap() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 50)])
    struct Broken: Error {}
    var calls = 0
    var config = MeetingTranscriptionJob.Configuration()
    config.pieceTargetSeconds = 20
    config.pieceSearchSeconds = 5
    let engine = FakeEngine()
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { true }, waitUntilDictationIdle: {}, beginModelUse: {}, endModelUse: {},
        loadEngine: {},
        transcribe: { samples in
          calls += 1
          // The second piece fails on both attempts (calls 2 and 3).
          if calls == 2 || calls == 3 { throw Broken() }
          return engine.transcribe(samples)
        },
        unloadEngine: {},
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }),
      configuration: config)
    let result = try await job.run(tracks: [.microphone: audio]) { _ in }
    #expect(result.failedPieces == 1)
    #expect(result.failedRanges[.microphone]?.count == 1)
    #expect(words(result) > 0)
  }

  @Test("run while a pass is running is refused")
  func reentrantRunRefused() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 2)])
    let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
    var release: CheckedContinuation<Void, Never>?
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { true }, waitUntilDictationIdle: {},
        beginModelUse: {
          enteredSignal.yield()
          await withCheckedContinuation { release = $0 }
        },
        endModelUse: {}, loadEngine: {},
        transcribe: { _ in ASRResult(text: "", language: nil, duration: 0, processingTime: 0, backendType: .parakeet) },
        unloadEngine: {},
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }))
    let first = Task { try await job.run(tracks: [.microphone: audio]) { _ in } }
    var iterator = entered.makeAsyncIterator()
    _ = await iterator.next()
    await #expect(throws: MeetingTranscriptionJob.JobError.alreadyRunning) {
      _ = try await job.run(tracks: [.microphone: audio]) { _ in }
    }
    release?.resume()
    _ = try await first.value
  }

  @Test("word ownership: midpoint at the start is owned, at the end is not; untimed words follow a neighbour")
  func ownershipRules() {
    func timing(_ word: String, _ s: Int?, _ e: Int?, at offset: Int) -> ASRWordTiming {
      ASRWordTiming(word: word, range: offset..<(offset + word.utf16.count), startMs: s, endMs: e)
    }
    // Padded piece starts at 9,000 ms; it owns 10,000..<20,000.
    let result = ASRResult(
      text: "uh before ok edge late", language: nil, duration: 12, processingTime: 0,
      backendType: .parakeet,
      wordTimings: [
        timing("uh", nil, nil, at: 0),  // leading untimed: follows the next timed word
        timing("before", 800, 1_000, at: 3),  // mid 9,900: not owned
        timing("ok", 900, 1_100, at: 10),  // mid 10,000: owned (start is inclusive)
        timing("edge", 10_900, 11_100, at: 13),  // mid 20,000: not owned (end is exclusive)
        timing("late", nil, nil, at: 18),  // trailing untimed: follows "edge"
      ])
    let piece = MeetingTranscriptionJob.ownedPiece(
      result: result, paddedStartMs: 9_000, startMs: 10_000, endMs: 20_000)
    #expect(piece.text == "ok")
    let leadingOwned = MeetingTranscriptionJob.ownedPiece(
      result: ASRResult(
        text: "ünï ok", language: nil, duration: 2, processingTime: 0, backendType: .parakeet,
        wordTimings: [timing("ünï", nil, nil, at: 0), timing("ok", 1_000, 1_200, at: 4)]),
      paddedStartMs: 9_000, startMs: 10_000, endMs: 20_000)
    #expect(leadingOwned.text == "ünï ok", "a leading untimed word is kept with its owned neighbour")
    #expect(leadingOwned.words.map(\.range) == [0..<3, 4..<6])
    let untimed = MeetingTranscriptionJob.ownedPiece(
      result: ASRResult(
        text: "all untimed", language: nil, duration: 2, processingTime: 0, backendType: .parakeet,
        wordTimings: [timing("all", nil, nil, at: 0), timing("untimed", nil, nil, at: 4)]),
      paddedStartMs: 9_000, startMs: 10_000, endMs: 20_000)
    #expect(untimed.text == "all untimed", "no timings at all: nothing is dropped")
  }

  #if DEBUG
    @Test(
      "a pass killed after two committed pieces resumes in a new process: done pieces kept, every word once",
      .tags(.realBoundary), .timeLimit(.minutes(2)))
    func killedPassResumes() async throws {
      let dir = try folder()
      _ = try segment(in: dir, index: 1, startMs: 0, seconds: 60)
      _ = try segment(in: dir, index: 2, startMs: 60_000, seconds: 10)
      let child = try await MeetingProcessingCrash.runAndKill(folder: dir, stopAfter: 2)
      #expect(child.reachedStop, "child never reported two saves: \(child.output.suffix(400))")
      #expect(child.killedBySIGKILL)

      var resumedCalls = 0
      let audio = try MeetingProcessingCrash.audio(in: dir)
      let resumed = try await MeetingProcessingCrash.job(onTranscribe: { resumedCalls += 1 }).run(
        tracks: [.microphone: audio], checkpoint: MeetingProcessingCrash.access(folder: dir)
      ) { _ in }
      var referenceCalls = 0
      let reference = try await MeetingProcessingCrash.job(onTranscribe: { referenceCalls += 1 }).run(
        tracks: [.microphone: audio]) { _ in }
      print("MEETING_JOB_KILL resumed_calls=\(resumedCalls) reference_calls=\(referenceCalls) resumed_pieces=\(resumed.resumedPieces)")
      #expect(resumed.resumedPieces == 2)
      #expect(resumedCalls == referenceCalls - 2)
      #expect(resumed.composition.text == reference.composition.text)
      let words = resumed.composition.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
      #expect(abs(words - 140) <= 4, "words=\(words)")
    }
  #endif

  @MainActor final class PauseState {
    var dictating = false
    var pressure = false
    var log: [String] = []
    var idleWaiters: [CheckedContinuation<Void, Never>] = []
    func endDictation() {
      dictating = false
      releaseWaiters()
    }
    func releaseWaiters() {
      let waiters = idleWaiters
      idleWaiters.removeAll()
      waiters.forEach { $0.resume() }
    }
  }

  private func pauseJob(_ state: PauseState, onSecondPiece: @escaping @MainActor () -> Void)
    -> MeetingTranscriptionJob
  {
    var config = MeetingTranscriptionJob.Configuration()
    config.pieceTargetSeconds = 20
    config.pieceSearchSeconds = 5
    var decodes = 0
    return MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { !state.dictating },
        waitUntilDictationIdle: {
          if !state.dictating { return }
          // Honors cancellation, as the production wait must.
          await withTaskCancellationHandler {
            await withCheckedContinuation { state.idleWaiters.append($0) }
          } onCancel: {
            Task { @MainActor in state.releaseWaiters() }
          }
        },
        beginModelUse: { state.log.append("use") },
        endModelUse: { state.log.append("release") },
        loadEngine: { state.log.append("load") },
        transcribe: { samples in
          decodes += 1
          state.log.append("decode")
          if decodes == 1 { onSecondPiece() }
          return FakeSpeech.transcribe(samples)
        },
        unloadEngine: { state.log.append("unload") },
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) },
        engineIdentity: { "fake" },
        isMemoryPressureElevated: { state.pressure },
        waitUntilMemoryNormal: {
          state.log.append("pressure-wait")
          state.pressure = false
        },
        sleep: { _ in
          // The prolonged-pause limit elapses at once; dictation ends right after it.
          await MainActor.run {
            Task { @MainActor in state.endDictation() }
          }
        }),
      configuration: config)
  }

  #if DEBUG
    @Test(
      "paused for dictation longer than the limit: the engine unloads, then reloads to finish",
      .timeLimit(.minutes(1)))
    func prolongedPauseUnloads() async throws {
      let dir = try folder()
      let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 50)])
      let state = PauseState()
      let job = pauseJob(state, onSecondPiece: { state.dictating = true })
      // #3972 C5: the page's pause line follows this wait too, and always ends cleared.
      var waitReports: [Bool] = []
      job.onWaitingForDictation = { waitReports.append($0) }
      let result = try await job.run(tracks: [.microphone: audio]) { _ in }
      #expect(waitReports.first == true)
      #expect(waitReports.last == false)
      #expect(waitReports.filter { $0 }.count == waitReports.filter { !$0 }.count)
      #expect(job.pauseUnloads == 1)
      #expect(Array(state.log.prefix(6)) == ["use", "load", "decode", "unload", "release", "use"])
      #expect(state.log.last == "release")
      #expect(result.failedPieces == 0)
      #expect(!job.isEngineResident)
    }

    @Test("memory pressure: the engine unloads, the pass waits for normal, then reloads", .timeLimit(.minutes(1)))
    func memoryPressureUnloads() async throws {
      let dir = try folder()
      let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 50)])
      let state = PauseState()
      let job = pauseJob(state, onSecondPiece: { state.pressure = true })
      _ = try await job.run(tracks: [.microphone: audio]) { _ in }
      #expect(job.pressureUnloads == 1)
      #expect(
        Array(state.log.prefix(8))
          == ["use", "load", "decode", "unload", "release", "pressure-wait", "use", "load"])
    }
  #endif

  // MARK: - C3b round 2

  @Test("replacing a file's samples without changing its length or size discards the checkpoint")
  func sameSizeContentChangeIsDetected() async throws {
    let dir = try folder()
    let file = try segment(in: dir, index: 1, startMs: 0, seconds: 30)
    let audio = MeetingTrackAudio(files: [file])
    let store = MeetingProcessingCheckpointStore(meetingFolder: dir)
    let meetingID = UUID()
    let first = FakeEngine()
    _ = try await checkpointJob(engine: first).run(
      tracks: [.microphone: audio], checkpoint: access(store, meetingID: meetingID)) { _ in }
    let sizeBefore = try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber
    // Flip bytes near the end of the file: same length, same size, different samples.
    let handle = try FileHandle(forUpdating: file.url)
    try handle.seek(toOffset: try handle.seekToEnd() - 64)
    try handle.write(contentsOf: Data(repeating: 0x5A, count: 32))
    try handle.close()
    let sizeAfter = try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber
    #expect(sizeBefore == sizeAfter)
    let second = FakeEngine()
    let result = try await checkpointJob(engine: second).run(
      tracks: [.microphone: MeetingTrackAudio(files: [file])],
      checkpoint: access(store, meetingID: meetingID)) { _ in }
    #expect(second.calls.count == first.calls.count, "changed audio is transcribed again")
    #expect(result.resumedPieces == 0)
  }

  @Test("an input whose identity cannot be read fails closed: no reuse and no checkpoint written")
  func unreadableInputFailsClosed() async throws {
    let dir = try folder()
    let file = try segment(in: dir, index: 1, startMs: 0, seconds: 10)
    let audio = MeetingTrackAudio(files: [file])
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.url.path) }
    let store = MeetingProcessingCheckpointStore(meetingFolder: dir)
    _ = try? await checkpointJob(engine: FakeEngine()).run(
      tracks: [.microphone: audio], checkpoint: access(store, meetingID: UUID())) { _ in }
    #expect(store.load() == .none)
  }

  @Test("checkpoint saves run off the main actor: a held save does not block it", .timeLimit(.minutes(1)))
  func savesDoNotBlockMainActor() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 10)])
    let held = DispatchSemaphore(value: 0)
    let entered = AsyncStream<Void>.makeStream()
    let timedOut = OSAllocatedUnfairLock(initialState: false)
    let blocking = MeetingTranscriptionJob.CheckpointAccess(
      meetingID: UUID(), load: { nil },
      save: { _ in
        entered.continuation.yield()
        // Blocks this thread until the main actor shows it is free. If the save ran ON the main
        // actor, nothing could signal it: the bounded wait then times out and the test fails.
        if !blockThread(on: held, seconds: 5) { timedOut.withLock { $0 = true } }
      })
    let job = checkpointJob(engine: FakeEngine())
    let run = Task { try await job.run(tracks: [.microphone: audio], checkpoint: blocking) { _ in } }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    // This line runs on the main actor while the save is held: the main actor is not blocked.
    for _ in 0..<8 { held.signal() }
    _ = try await run.value
    #expect(timedOut.withLock { $0 } == false, "a save blocked the main actor")
  }

  @Test("a cancel while paused for dictation ends the pass at once, without dictation ending", .timeLimit(.minutes(1)))
  func cancelWhilePausedWithoutIdle() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 50)])
    let state = PauseState()
    state.dictating = true  // dictating from the start; never ends in this test
    let (paused, pausedSignal) = AsyncStream<Void>.makeStream()
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { !state.dictating },
        waitUntilDictationIdle: {
          pausedSignal.yield()
          await withTaskCancellationHandler {
            await withCheckedContinuation { state.idleWaiters.append($0) }
          } onCancel: {
            Task { @MainActor in state.releaseWaiters() }
          }
        },
        beginModelUse: { state.log.append("use") }, endModelUse: { state.log.append("release") },
        loadEngine: { state.log.append("load") }, transcribe: { FakeSpeech.transcribe($0) },
        unloadEngine: { state.log.append("unload") },
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }))
    let run = Task { try await job.run(tracks: [.microphone: audio]) { _ in } }
    var iterator = paused.makeAsyncIterator()
    _ = await iterator.next()
    job.cancel()
    await #expect(throws: MeetingTranscriptionJob.JobError.cancelled) { _ = try await run.value }
    #expect(!job.isEngineResident)
    #expect(state.log.last == "release" || state.log == ["use"] || state.log.isEmpty || state.log.last == "release")
  }

  @Test("memory pressure before the pass starts delays the first load until normal", .timeLimit(.minutes(1)))
  func pressureBeforeStartDelaysLoad() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 10)])
    let state = PauseState()
    state.pressure = true
    let job = pauseJob(state, onSecondPiece: {})
    _ = try await job.run(tracks: [.microphone: audio]) { _ in }
    #expect(Array(state.log.prefix(3)) == ["pressure-wait", "use", "load"])
  }

  @Test("a piece that fails twice shows as a marker line in place, between its neighbours' words")
  func failedPieceShowsMarker() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 50)])
    struct Broken: Error {}
    var calls = 0
    var config = MeetingTranscriptionJob.Configuration()
    config.pieceTargetSeconds = 20
    config.pieceSearchSeconds = 5
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { true }, waitUntilDictationIdle: {}, beginModelUse: {}, endModelUse: {},
        loadEngine: {},
        transcribe: { samples in
          calls += 1
          if calls == 2 || calls == 3 { throw Broken() }
          return FakeSpeech.transcribe(samples)
        },
        unloadEngine: {},
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }),
      configuration: config)
    let result = try await job.run(tracks: [.microphone: audio]) { _ in }
    let range = try #require(result.failedRanges[.microphone]?.first)
    let marker =
      "[Could not transcribe \(MeetingTranscriptionJob.clock(MeetingTranscriptionJob.ms(range.lowerBound))) "
      + "to \(MeetingTranscriptionJob.clock(MeetingTranscriptionJob.ms(range.upperBound)))]"
    let shown = MeetingTranscriptProjection.plainText(
      text: result.composition.text, turns: result.composition.turns, speakerNames: [:],
      echoTurnIDs: [], showEcho: false)
    #expect(shown.contains(marker), "\(shown)")
    let parts = result.composition.text.components(separatedBy: marker)
    #expect(parts.count == 2)
    #expect(parts[0].contains("w") && parts[1].contains("w"), "neighbours keep their words")
  }

  @Test("damaged audio shows as a gap in place, also for a track with no readable audio")
  func missingAudioShowsMarker() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 10)])
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { true }, waitUntilDictationIdle: {}, beginModelUse: {}, endModelUse: {},
        loadEngine: {}, transcribe: { FakeSpeech.transcribe($0) }, unloadEngine: {},
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }))
    let result = try await job.run(
      tracks: [.microphone: audio],
      missingAudio: [
        .microphone: [.init(startMs: 60_000, endMs: 90_000), .init(startMs: 120_000, endMs: nil)],
        .callSound: [.init(startMs: 5_000, endMs: 65_000)],
      ]) { _ in }
    let text = result.composition.text
    #expect(text.contains("[Could not transcribe 1:00 to 1:30]"), "\(text)")
    #expect(text.contains("[Could not transcribe 0:05 to 1:05]"), "\(text)")
    // An unbounded stretch names only its start, never an invented end.
    #expect(text.contains("[Could not transcribe from 2:00]"), "\(text)")
    // In timeline order: the call-sound gap at 0:05 comes before the microphone gap at 1:00.
    let call = try #require(text.range(of: "0:05 to 1:05"))
    let mic = try #require(text.range(of: "1:00 to 1:30"))
    #expect(call.lowerBound < mic.lowerBound)
  }

  // MARK: - C3b round 3

  @Test(
    "a save in flight when the meeting is cancelled and deleted cannot bring the folder back",
    .timeLimit(.minutes(1)))
  func inFlightSaveCannotRecreateDeletedMeeting() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 50)])
    let store = MeetingProcessingCheckpointStore(meetingFolder: dir)
    let held = DispatchSemaphore(value: 0)
    let entered = AsyncStream<Void>.makeStream()
    let access = MeetingTranscriptionJob.CheckpointAccess(
      meetingID: UUID(), load: { nil },
      save: { checkpoint in
        entered.continuation.yield()
        blockThread(on: held)
        try store.save(checkpoint)
      })
    let job = checkpointJob(engine: FakeEngine())
    let run = Task { try await job.run(tracks: [.microphone: audio], checkpoint: access) { _ in } }
    var iterator = entered.stream.makeAsyncIterator()
    _ = await iterator.next()
    job.cancel()
    try FileManager.default.removeItem(at: dir)  // the owner deletes the meeting
    held.signal()
    await #expect(throws: MeetingTranscriptionJob.JobError.cancelled) { _ = try await run.value }
    #expect(!FileManager.default.fileExists(atPath: dir.path), "the deleted meeting came back")
  }

  @Test("a checkpoint that decodes but holds impossible ranges is rejected and the pass starts fresh")
  func invalidCheckpointIsRejected() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 30)])
    let meetingID = UUID()
    let key = try MeetingTranscriptionJob.key(
      meetingID: meetingID, tracks: [.microphone: audio], order: [.microphone],
      { var c = MeetingTranscriptionJob.Configuration(); c.pieceTargetSeconds = 20; c.pieceSearchSeconds = 5; return c }())
    let store = MeetingProcessingCheckpointStore(meetingFolder: dir)
    for bad in [
      // A word range running backwards.
      MeetingProcessingCheckpoint.Piece(
        startSample: 0, endSample: 320_000, forcedCut: false, text: "w",
        words: [.init(word: "w", lower: 1, upper: 0, startMs: 0, endMs: 400)]),
      // A piece running past the end of the audio, which would fake full coverage.
      MeetingProcessingCheckpoint.Piece(
        startSample: 0, endSample: 99_000_000, forcedCut: false, text: "w",
        words: [.init(word: "w", lower: 0, upper: 1, startMs: 0, endMs: 400)]),
    ] {
      try store.save(
        MeetingProcessingCheckpoint(
          key: key, engineIdentity: "ultra:r1", tracks: [.microphone: .init(pieces: [bad])]))
      let engine = FakeEngine()
      let result = try await checkpointJob(engine: engine).run(
        tracks: [.microphone: audio], checkpoint: access(store, meetingID: meetingID)) { _ in }
      #expect(result.resumedPieces == 0)
      #expect(engine.calls.count > 0)
    }
  }

  @Test(
    "after the last decode the normal unload waits for dictation; a cancel then releases at once",
    .timeLimit(.minutes(1)))
  func normalUnloadWaitsForDictation() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 10)])
    for cancelDuringWait in [false, true] {
      let state = PauseState()
      let (paused, pausedSignal) = AsyncStream<Void>.makeStream()
      let job = MeetingTranscriptionJob(
        dependencies: .init(
          isDictationIdle: { !state.dictating },
          waitUntilDictationIdle: {
            pausedSignal.yield()
            await withTaskCancellationHandler {
              await withCheckedContinuation { state.idleWaiters.append($0) }
            } onCancel: {
              Task { @MainActor in state.releaseWaiters() }
            }
          },
          beginModelUse: { state.log.append("use") }, endModelUse: { state.log.append("release") },
          loadEngine: { state.log.append("load") },
          transcribe: { samples in
            state.dictating = true  // the user starts dictating during the final decode
            return FakeSpeech.transcribe(samples)
          },
          unloadEngine: { state.log.append("unload") },
          analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }))
      // #3972 C5: the page's pause line shows during this wait and clears after it.
      var waiting = false
      job.onWaitingForDictation = { waiting = $0 }
      let run = Task { try await job.run(tracks: [.microphone: audio]) { _ in } }
      var iterator = paused.makeAsyncIterator()
      _ = await iterator.next()
      #expect(state.log == ["use", "load"], "unload waits while dictating")
      #expect(waiting, "the unload wait is reported")
      if cancelDuringWait {
        job.cancel()
        _ = try? await run.value
        #expect(state.log == ["use", "load", "unload", "release"])
      } else {
        state.endDictation()
        _ = try await run.value
        #expect(Array(state.log.prefix(4)) == ["use", "load", "unload", "release"])
      }
      #expect(!waiting, "cleared after the wait ends")
    }
  }
}
