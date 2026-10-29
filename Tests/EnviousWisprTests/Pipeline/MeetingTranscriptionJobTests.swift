import AVFoundation
import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage
import EnviousWisprAppKitTestSupport

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

  /// Reads audio written by `slotted` segments: every 500 ms slot of the meeting is its own
  /// word, `w<slot>`, timed at the slot's true start inside the piece. A slot's first
  /// millisecond is negative (its start marker); the rest of it holds the slot number as a
  /// level. Only a slot whose start marker and whole 400 ms word lie inside the piece is heard,
  /// so a word is never invented from a slot the piece only partly holds.
  static func transcribeSlots(_ samples: [Float]) -> ASRResult {
    var text = ""
    var timings: [ASRWordTiming] = []
    for i in samples.indices where samples[i] < 0 && (i == 0 || samples[i - 1] >= 0) {
      let startMs = i * 1000 / 16_000
      guard i + 400 * 16 <= samples.count else { break }
      let slot = Int((-samples[i] / slotLevelStep).rounded()) - 1
      if !text.isEmpty { text += " " }
      let lower = text.utf16.count
      text += "w\(slot)"
      timings.append(
        ASRWordTiming(
          word: "w\(slot)", range: lower..<text.utf16.count, startMs: startMs,
          endMs: startMs + 400))
    }
    return ASRResult(
      text: text, language: nil, duration: Double(samples.count) / 16_000, processingTime: 0,
      backendType: .parakeet, wordTimings: timings)
  }

  /// One slot level step: slot `k` is written as `(k + 1) * step`, far above 16-bit rounding.
  static let slotLevelStep: Float = 0.002

  /// The sample at `absoluteSample` of a slotted meeting track.
  static func slotSample(_ absoluteSample: Int) -> Float {
    let slotSamples = 500 * 16
    let level = Float(absoluteSample / slotSamples + 1) * slotLevelStep
    return absoluteSample % slotSamples < 16 ? -level : level
  }
}

/// #3972 R23, R25: when these fail, a meeting transcript loses or doubles words where pieces
/// join, or meeting work runs while the user dictates.
// #3973 C1: a suite-wide limit, so one parked fixture fails in a minute instead of holding the
// shared local test queue (a hang here held it for 38 minutes).
@Suite("MeetingTranscriptionJob", .tags(.productOutcome), .timeLimit(.minutes(1)))
@MainActor
struct MeetingTranscriptionJobTests {

  // MARK: - Fixtures

  /// Writes a 16 kHz mono CAF of `seconds` of tone at `startMs` and returns its file entry.
  /// `slotted`: the audio carries `FakeSpeech.slotSample` levels on the meeting timeline, so
  /// `FakeSpeech.transcribeSlots` hears a distinct word for every 500 ms.
  private func segment(
    in dir: URL, index: Int, startMs: Int, seconds: Double, slotted: Bool = false
  ) throws -> (
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
    let firstSample = startMs * 16
    for i in 0..<Int(frames) {
      buffer.floatChannelData![0][i] =
        slotted ? FakeSpeech.slotSample(firstSample + i) : sin(Float(i) * 0.05) * 0.3
    }
    try file.write(from: buffer)
    return (url, startMs)
  }

  private func folder() throws -> URL {
    let url = TestTemporaryDirectory.url
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
    /// Hears `slotted` audio (`FakeSpeech.transcribeSlots`) instead of one word per 500 ms.
    var hearsSlots = false

    func transcribe(_ samples: [Float]) -> ASRResult {
      calls.append(samples.count)
      if !isDictationIdle() { dictationActiveDuringCall = true }
      if hearsSlots { return FakeSpeech.transcribeSlots(samples) }
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
        loadEngine: {}, transcribe: { samples, _ in engine.transcribe(samples) }, unloadEngine: {},
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }),
      configuration: config)
  }

  // MARK: - Tests

  @Test(
    "a 70 s track is transcribed in pieces and every word appears exactly once, in order, across the joins")
  func seamsKeepEveryWordOnce() async throws {
    let dir = try folder()
    let files = [
      try segment(in: dir, index: 1, startMs: 0, seconds: 60, slotted: true),
      try segment(in: dir, index: 2, startMs: 60_000, seconds: 10, slotted: true),
    ]
    let engine = FakeEngine()
    engine.hearsSlots = true
    let job = makeJob(engine: engine, idle: { true }, wait: {})
    let result = try await job.runTestAttempt(tracks: [.microphone: MeetingTrackAudio(files: files)], language: nil) { _ in }

    #expect(engine.calls.count >= 3)
    // Every padded piece hears the slots it fully holds, so slots near a seam are heard twice;
    // ownership by midpoint must keep each of the 140 slots exactly once and in order.
    let words = result.composition.text.split(whereSeparator: { $0 == " " || $0 == "\n" })
      .map(String.init)
    #expect(words == (0..<140).map { "w\($0)" })
    #expect(result.failedPieces == 0)
  }

  @Test("a word on the seam between two pieces belongs to exactly one of them")
  func seamWordOwnedOnce() {
    func piece(_ startMs: Int, _ endMs: Int) -> MeetingTrackPiece {
      // Words whose midpoints sit 1 ms before, on and 1 ms after the shared seam at 10,000 ms.
      let words = [("before", 9_999), ("on", 10_000), ("after", 10_001)]
      var text = ""
      var timings: [ASRWordTiming] = []
      for (word, mid) in words {
        if !text.isEmpty { text += " " }
        let lower = text.utf16.count
        text += word
        // The padded piece starts at 0, so the timing is the meeting time.
        timings.append(
          ASRWordTiming(
            word: word, range: lower..<text.utf16.count, startMs: mid - 100, endMs: mid + 100))
      }
      return MeetingTranscriptionJob.ownedPiece(
        result: ASRResult(
          text: text, language: nil, duration: 20, processingTime: 0, backendType: .parakeet,
          wordTimings: timings),
        paddedStartMs: 0, startMs: startMs, endMs: endMs)
    }
    #expect(piece(0, 10_000).text == "before")
    #expect(piece(10_000, 20_000).text == "on after")
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
        transcribe: { samples, _ in
          inUnit("transcribe")
          return engine.transcribe(samples)
        },
        unloadEngine: { inUnit("unload") },
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) },
        unitStarted: {
          open += 1
          started += 1
        },
        unitEnded: { open -= 1 }))
    _ = try await job.runTestAttempt(tracks: [.microphone: MeetingTrackAudio(files: files)], language: nil) { _ in }
    #expect(outsideUnit.isEmpty, "engine work outside a reported unit: \(outsideUnit)")
    #expect(open == 0, "every unit that started has ended")
    #expect(started >= 3, "load, decode and unload each report")
  }

  @Test("a unit re-checks its admission after the wait: work that took the turn is waited for")
  func admissionRecheckedAfterWait() async throws {
    let dir = try folder()
    let files = [try segment(in: dir, index: 1, startMs: 0, seconds: 10)]
    let engine = FakeEngine()
    var dictating = true
    var laneTaken = false
    var waits = 0
    var workWhileTaken: [String] = []
    let idle: @MainActor () -> Bool = { !dictating && !laneTaken }
    func check(_ name: String) { if !idle() { workWhileTaken.append(name) } }
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: idle,
        waitUntilDictationIdle: {
          waits += 1
          if waits == 1 {
            // Dictation ended, but a local summary took the turn before the unit resumed.
            dictating = false
            laneTaken = true
          } else {
            laneTaken = false
          }
        },
        beginModelUse: {}, endModelUse: {},
        loadEngine: { check("load") },
        transcribe: { samples, _ in
          check("transcribe")
          return engine.transcribe(samples)
        },
        unloadEngine: {},
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }))
    _ = try await job.runTestAttempt(tracks: [.microphone: MeetingTrackAudio(files: files)], language: nil) { _ in }
    #expect(workWhileTaken.isEmpty, "engine work while the turn was taken: \(workWhileTaken)")
    #expect(waits >= 2)
    #expect(job.yieldCount == 1, "one yield, however many waits it took")
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
    let result = try await job.runTestAttempt(tracks: [.microphone: MeetingTrackAudio(files: files)], language: nil) { _ in }
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
    _ = try await job.runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in }
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
          transcribe: { _, _ in
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
    let run = Task { try await rig.job.runTestAttempt(tracks: [.microphone: MeetingTrackAudio(files: files)], language: nil) { _ in } }
    await rig.untilWaiting()
    // #3973 C1: the claim is given back before the contention wait and taken again after it.
    #expect(!rig.job.isEngineResident, "nothing is held through the wait")
    rig.release()
    _ = try await run.value
    #expect(rig.job.engineContentionWaits == 1)
    #expect(
      rig.log == ["use", "release", "use", "busy", "release", "wait", "use", "load", "unload", "release"])
    #expect(rig.residentDuringLoad == true)
    #expect(!rig.job.isEngineResident)
  }

  @Test("a cancel during the contention wait ends the job and releases the model", .timeLimit(.minutes(1)))
  func cancelDuringContentionWait() async throws {
    let dir = try folder()
    let files = [try segment(in: dir, index: 1, startMs: 0, seconds: 2)]
    let rig = OwnershipRig(contentions: 1)
    let run = Task { try await rig.job.runTestAttempt(tracks: [.microphone: MeetingTrackAudio(files: files)], language: nil) { _ in } }
    await rig.untilWaiting()
    rig.job.cancel()
    await #expect(throws: MeetingTranscriptionJob.JobError.cancelled) { _ = try await run.value }
    #expect(rig.log == ["use", "release", "use", "busy", "release", "wait"])
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
        transcribe: { _, _ in
          ASRResult(text: "", language: nil, duration: 0, processingTime: 0, backendType: .parakeet)
        },
        unloadEngine: {},
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }))
    let run = Task { try await job.runTestAttempt(tracks: [.microphone: MeetingTrackAudio(files: files)], language: nil) { _ in } }
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
        transcribe: { _, _ in
          state.decodes += 1
          return ASRResult(
            text: "", language: nil, duration: 0, processingTime: 0, backendType: .parakeet)
        },
        unloadEngine: { state.log.append("unload") },
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) },
        isModelSourceUsable: { state.usable }))
    await #expect(throws: MeetingTranscriptionJob.JobError.engineUnavailable("model_source_unavailable")) {
      _ = try await job.runTestAttempt(tracks: [.microphone: MeetingTrackAudio(files: files)], language: nil) { _ in }
    }
    #expect(state.decodes == 0)
    // The identity probe (#3973 C1), then the operation's load, unload and release.
    #expect(state.log == ["use", "release", "use", "load", "unload", "release"])
    #expect(!job.isEngineResident)
  }

  /// #3973 C1 retired #3972 R32's documented limit here: the operation gives the engine back
  /// before it pauses for a dictation, so delivery turned off during the pause finds nothing held,
  /// and the next acquisition stops at the model-source check without a decode.
  @Test(
    "delivery off while paused for dictation: nothing is held during the pause, then no decode",
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
        transcribe: { _, _ in
          state.decodes += 1
          return ASRResult(
            text: "", language: nil, duration: 0, processingTime: 0, backendType: .parakeet)
        },
        unloadEngine: { state.log.append("unload") },
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) },
        isModelSourceUsable: { state.usable }))
    let run = Task { try await job.runTestAttempt(tracks: [.microphone: MeetingTrackAudio(files: files)], language: nil) { _ in } }
    await withCheckedContinuation { state.pausedSignal = $0 }
    state.usable = false  // delivery turned off while the job is paused
    // The identity probe, then the operation's load, given back before the pause.
    #expect(state.log == ["use", "release", "use", "load", "unload", "release", "paused"])
    #expect(!job.isEngineResident, "nothing is held while the job waits for dictation")
    state.dictating = false
    state.idleWaiter?.resume()
    await #expect(throws: MeetingTranscriptionJob.JobError.engineUnavailable("model_source_unavailable")) {
      _ = try await run.value
    }
    #expect(state.decodes == 0)
    #expect(
      state.log == ["use", "release", "use", "load", "unload", "release", "paused", "use", "release"])
    #expect(!job.isEngineResident)
  }

  // MARK: - Checkpoints and pieces (C3b)

  /// A job over a fake engine with a real checkpoint store. `afterSaves` runs after each
  /// successful save with the running count (a test cancels there to simulate a crash).
  private func checkpointJob(
    engine: FakeEngine, identity: String = "ultra:r1", target: Double = 20,
    analyses: OSAllocatedUnfairLock<Int>? = nil, cutsPieces: Bool = true,
    languages: OSAllocatedUnfairLock<[String?]>? = nil,
    speakerSegments: [SpeakerSegment] = [
      SpeakerSegment(speakerId: "1", startMs: 0, endMs: 1_000, quality: 1)
    ]
  ) -> MeetingTranscriptionJob {
    var config = MeetingTranscriptionJob.Configuration()
    config.pieceTargetSeconds = target
    config.pieceSearchSeconds = 5
    config.cutsPieces = cutsPieces
    return MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { true }, waitUntilDictationIdle: {}, beginModelUse: {}, endModelUse: {},
        loadEngine: {},
        transcribe: { samples, language in
          languages?.withLock { $0.append(language) }
          return engine.transcribe(samples)
        },
        unloadEngine: {},
        analyzeSpeakers: { _ in
          analyses?.withLock { $0 += 1 }
          return MeetingSpeakerAnalysis(outcome: .single, segments: speakerSegments)
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
      _ = try await job1.runTestAttempt(
        tracks: [.microphone: audio], language: nil,
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
    let result = try await job2.runTestAttempt(
      tracks: [.microphone: audio], language: nil, checkpoint: access(store, meetingID: meetingID)) { _ in }
    let fresh = FakeEngine()
    let reference = try await checkpointJob(engine: fresh).runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in }
    #expect(second.calls.count == fresh.calls.count - committed)
    #expect(result.resumedPieces == committed)
    #expect(words(result) == words(reference))
    #expect(result.composition.text == reference.composition.text)
    #expect(analyses.withLock { $0 } == 1)

    // Pass 3: everything committed, including speakers. No engine, no analysis.
    let third = FakeEngine()
    let again = OSAllocatedUnfairLock(initialState: 0)
    let result3 = try await checkpointJob(engine: third, analyses: again).runTestAttempt(
      tracks: [.microphone: audio], language: nil, checkpoint: access(store, meetingID: meetingID)) { _ in }
    #expect(third.calls.isEmpty)
    #expect(again.withLock { $0 } == 0)
    #expect(result3.composition.text == reference.composition.text)
  }

  // MARK: - Automatic speaker naming (#4013 chunk 12A)

  @Test("a pass names the call speaker from saved evidence; a resumed pass names the same way")
  func namesFromSavedEvidenceFreshAndResumed() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 50)])
    let caller = [SpeakerSegment(speakerId: "1", startMs: 0, endMs: 50_000, quality: 1)]
    let log = try CallSpeakerTestLog.meet()

    let reference = try await checkpointJob(engine: FakeEngine(), speakerSegments: caller)
      .runTestAttempt(tracks: [.callSound: audio], language: nil, callSpeakers: .usable(log)) { _ in }
    let naming = try #require(reference.naming)
    #expect(naming.evidence == .usable(log))
    #expect(naming.result.outcome == .named)
    #expect(naming.result.proposals == ["sys:1": "Alex Rivera"])
    #expect(naming.eligibility.callSpeakerIDs == ["sys:1"])

    // Naming never changes the composition.
    let unnamed = try await checkpointJob(engine: FakeEngine(), speakerSegments: caller)
      .runTestAttempt(tracks: [.callSound: audio], language: nil) { _ in }
    #expect(unnamed.composition == reference.composition)
    #expect(unnamed.naming?.result.proposals == [:])
    #expect(unnamed.naming?.result.outcome == .noLog)
    #expect(unnamed.naming?.evidence == .absent)

    // A pass interrupted after one piece, then resumed from its checkpoint, gives the same
    // eligibility and the same names as the uninterrupted pass.
    let store = MeetingProcessingCheckpointStore(meetingFolder: dir)
    let meetingID = UUID()
    let first = checkpointJob(engine: FakeEngine(), speakerSegments: caller)
    await #expect(throws: MeetingTranscriptionJob.JobError.cancelled) {
      _ = try await first.runTestAttempt(
        tracks: [.callSound: audio], language: nil,
        checkpoint: access(store, meetingID: meetingID) { saves in if saves == 1 { first.cancel() } },
        callSpeakers: .usable(log)
      ) { _ in }
    }
    let resumed = try await checkpointJob(engine: FakeEngine(), speakerSegments: caller)
      .runTestAttempt(
        tracks: [.callSound: audio], language: nil, checkpoint: access(store, meetingID: meetingID),
        callSpeakers: .usable(log)) { _ in }
    #expect(resumed.resumedPieces > 0)
    #expect(resumed.naming == reference.naming)
  }

  @Test("unusable saved evidence leaves the pass successful with no names, and says why")
  func unusableEvidenceNamesNobody() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 30)])
    let result = try await checkpointJob(
      engine: FakeEngine(),
      speakerSegments: [SpeakerSegment(speakerId: "1", startMs: 0, endMs: 30_000, quality: 1)]
    ).runTestAttempt(
      tracks: [.callSound: audio], language: nil, callSpeakers: .unusable(.newerFormat)) { _ in }
    #expect(result.naming?.evidence == .unusable(.newerFormat))
    #expect(result.naming?.result.proposals == [:])
    #expect(!result.composition.text.isEmpty)
  }

  @Test("eligibility comes from the pieces: speech, failed pieces and unreadable audio per track")
  func eligibilityFromPieces() {
    typealias Piece = MeetingProcessingCheckpoint.Piece
    func spoken(_ start: Int, _ end: Int, _ text: String) -> Piece {
      Piece(
        startSample: start, endSample: end, forcedCut: false, text: text,
        words: text.isEmpty ? [] : [.init(word: text, lower: 0, upper: text.utf16.count, startMs: 0, endMs: 1)])
    }
    func failed(_ start: Int, _ end: Int) -> Piece {
      Piece(startSample: start, endSample: end, forcedCut: false, text: nil, words: nil)
    }
    let eligibility = MeetingTranscriptionJob.namingEligibility(
      pieces: [
        .callSound: [spoken(0, 16_000, "hi"), failed(16_000, 32_000), spoken(32_000, 48_000, " ")],
        .microphone: [failed(0, 16_000)],
      ],
      callSegments: [
        SpeakerSegment(speakerId: "1", startMs: 0, endMs: 1_000, quality: 1),
        SpeakerSegment(speakerId: "2", startMs: 1_000, endMs: 3_000, quality: 1),
      ],
      missingAudio: [
        .callSound: [.init(startMs: 5_000, endMs: nil)],
        .microphone: [.init(startMs: 7_000, endMs: 8_000)],
      ])
    #expect(eligibility.callSpeakerIDs == ["sys:1", "sys:2"])
    #expect(eligibility.callSpeech == [MeetingNamingInterval(startMs: 0, endMs: 1_000)!])
    let expected = [
      MeetingNamingMarker(track: .callSound, startMs: 1_000, endMs: 2_000),
      MeetingNamingMarker(track: .callSound, startMs: 5_000, endMs: nil),
      MeetingNamingMarker(track: .microphone, startMs: 0, endMs: 1_000),
      MeetingNamingMarker(track: .microphone, startMs: 7_000, endMs: 8_000),
    ]
    #expect(eligibility.markers.count == expected.count)
    for marker in expected { #expect(eligibility.markers.contains(marker), "\(marker)") }
  }

  @Test("a checkpoint for other settings, another meeting or another model is not reused")
  func incompatibleCheckpointsAreDiscarded() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 30)])
    let store = MeetingProcessingCheckpointStore(meetingFolder: dir)
    let meetingID = UUID()
    let baseline = FakeEngine()
    _ = try await checkpointJob(engine: baseline).runTestAttempt(
      tracks: [.microphone: audio], language: nil, checkpoint: access(store, meetingID: meetingID)) { _ in }
    let total = baseline.calls.count
    #expect(total > 1)

    let otherSettings = FakeEngine()
    _ = try await checkpointJob(engine: otherSettings, target: 10).runTestAttempt(
      tracks: [.microphone: audio], language: nil, checkpoint: access(store, meetingID: meetingID)) { _ in }
    #expect(otherSettings.calls.count > 0, "a different piece length starts over")

    let otherMeeting = FakeEngine()
    _ = try await checkpointJob(engine: otherMeeting).runTestAttempt(
      tracks: [.microphone: audio], language: nil, checkpoint: access(store, meetingID: UUID())) { _ in }
    #expect(otherMeeting.calls.count == total)

    // Same meeting and settings, interrupted after one piece, resumed under a different model:
    // every piece is redone, so two models' words are never mixed.
    try store.clear()
    let base2 = FakeEngine()
    let job2 = checkpointJob(engine: base2)
    await #expect(throws: MeetingTranscriptionJob.JobError.cancelled) {
      _ = try await job2.runTestAttempt(
        tracks: [.microphone: audio], language: nil,
        checkpoint: access(store, meetingID: meetingID) { saves in if saves == 1 { job2.cancel() } }
      ) { _ in }
    }
    let otherModel = FakeEngine()
    _ = try await checkpointJob(engine: otherModel, identity: "v3:r9").runTestAttempt(
      tracks: [.microphone: audio], language: nil, checkpoint: access(store, meetingID: meetingID)) { _ in }
    #expect(otherModel.calls.count == total)
  }

  /// #3973 C2 (plan G3): the model and the attempt are checked before the full-reuse branch, so
  /// a COMPLETE checkpoint from another model, or from an earlier attempt (Transcribe again),
  /// is never reused: the pass decodes every piece and analyses speakers again.
  @Test("a complete checkpoint from another model or another attempt is not reused")
  func completeCheckpointNeedsSameModelAndAttempt() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 30)])
    let store = MeetingProcessingCheckpointStore(meetingFolder: dir)
    let meetingID = UUID()
    let baseline = FakeEngine()
    _ = try await checkpointJob(engine: baseline).runTestAttempt(
      tracks: [.microphone: audio], language: nil, checkpoint: access(store, meetingID: meetingID)) { _ in }
    let total = baseline.calls.count
    #expect(total > 1)

    let same = FakeEngine()
    let reused = try await checkpointJob(engine: same).runTestAttempt(
      tracks: [.microphone: audio], language: nil, checkpoint: access(store, meetingID: meetingID)) { _ in }
    #expect(same.calls.isEmpty, "control: the same model and attempt reuse the whole pass")
    #expect(reused.resolved.modelIdentity == "ultra:r1")

    let otherModel = FakeEngine()
    let analyses = OSAllocatedUnfairLock(initialState: 0)
    let redone = try await checkpointJob(engine: otherModel, identity: "v3:r9", analyses: analyses).runTestAttempt(
      tracks: [.microphone: audio], language: nil, checkpoint: access(store, meetingID: meetingID)) { _ in }
    #expect(otherModel.calls.count == total)
    #expect(analyses.withLock { $0 } == 1, "speakers are analysed again too")
    #expect(redone.resolved.modelIdentity == "v3:r9")

    let newAttempt = FakeEngine()
    _ = try await checkpointJob(engine: newAttempt, identity: "v3:r9").run(
      tracks: [.microphone: audio], language: nil, checkpoint: access(store, meetingID: meetingID),
      onStage: { _ in }, attempt: MeetingTestAttempt.attempt(language: nil, id: UUID()))
    #expect(newAttempt.calls.count == total)
  }

  /// #3973 C2 (chunk review): the model identity is read under a claim that may load the shared
  /// model, so memory pressure that rose while the pass waited for dictation is waited out
  /// before the claim, even when the checkpoint already covers every piece.
  @Test("pressure that rises during the dictation wait is waited out before the identity claim")
  func identityClaimWaitsForNormalMemory() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 5)])
    var dictating = true
    var pressure = false
    var log: [String] = []
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { !dictating },
        waitUntilDictationIdle: {
          log.append("dictation wait")
          pressure = true  // rises while dictation runs
          dictating = false
        },
        beginModelUse: { log.append(pressure ? "use under pressure" : "use") },
        endModelUse: {}, loadEngine: {},
        transcribe: { samples, _ in FakeSpeech.transcribe(samples) },
        unloadEngine: {},
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) },
        engineIdentity: { "ultra:r1" },
        isMemoryPressureElevated: { pressure },
        waitUntilMemoryNormal: {
          log.append("memory wait")
          pressure = false
        }))
    _ = try await job.runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in }
    #expect(Array(log.prefix(3)) == ["dictation wait", "memory wait", "use"])
    #expect(!log.contains("use under pressure"))
  }

  /// #3973 C2: the language and the attempt come from the same saved attempt; a pass given two
  /// that disagree refuses before it reads a checkpoint or decodes anything.
  @Test("a language that disagrees with the attempt is refused before any work")
  func languageMustMatchTheAttempt() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 5)])
    let engine = FakeEngine()
    let loads = OSAllocatedUnfairLock(initialState: 0)
    let store = MeetingProcessingCheckpointStore(meetingFolder: dir)
    let job = checkpointJob(engine: engine)
    await #expect(throws: MeetingTranscriptionJob.JobError.attemptMismatch) {
      _ = try await job.run(
        tracks: [.microphone: audio], language: "de",
        checkpoint: .init(
          meetingID: UUID(),
          load: {
            loads.withLock { $0 += 1 }
            if case .checkpoint(let c) = store.load() { return c }
            return nil
          }, save: { _ in }),
        onStage: { _ in }, attempt: MeetingTestAttempt.attempt(language: "fr"))
    }
    #expect(engine.calls.isEmpty)
    #expect(loads.withLock { $0 } == 0)
  }

  /// #4105: when this fails, a meeting is transcribed in a language other than the one it was
  /// started with, or words decoded in one language are mixed into a pass in another.
  @Test("the pass's language reaches every decode, and a checkpoint resumes only in that language")
  func languageReachesEveryDecodeAndKeysTheCheckpoint() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [
      try segment(in: dir, index: 1, startMs: 0, seconds: 60),
      try segment(in: dir, index: 2, startMs: 60_000, seconds: 10),
    ])
    let store = MeetingProcessingCheckpointStore(meetingFolder: dir)
    let meetingID = UUID()
    let reference = FakeEngine()
    _ = try await checkpointJob(engine: reference).runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in }
    let total = reference.calls.count
    #expect(total > 2)

    // Pass 1 in German, interrupted after its first committed piece.
    let german = OSAllocatedUnfairLock<[String?]>(initialState: [])
    let job1 = checkpointJob(engine: FakeEngine(), languages: german)
    await #expect(throws: MeetingTranscriptionJob.JobError.cancelled) {
      _ = try await job1.runTestAttempt(
        tracks: [.microphone: audio], language: "de",
        checkpoint: access(store, meetingID: meetingID) { saves in if saves == 1 { job1.cancel() } }
      ) { _ in }
    }
    #expect(!german.withLock { $0 }.isEmpty)
    #expect(german.withLock { $0 }.allSatisfy { $0 == "de" })

    // The same meeting in Auto (an empty lock is Auto too): the German piece is not reused.
    let autoSeen = OSAllocatedUnfairLock<[String?]>(initialState: [])
    let autoEngine = FakeEngine()
    let auto = try await checkpointJob(engine: autoEngine, languages: autoSeen).runTestAttempt(
      tracks: [.microphone: audio], language: "", checkpoint: access(store, meetingID: meetingID)
    ) { _ in }
    #expect(auto.resumedPieces == 0)
    #expect(autoEngine.calls.count == total, "every piece decoded again")
    #expect(autoSeen.withLock { $0 }.count == total)
    #expect(autoSeen.withLock { $0 }.allSatisfy { $0 == nil }, "Auto reaches the engine as nil")

    // Interrupted in German again, then resumed in German: the committed piece is reused and
    // every remaining decode is German.
    try store.clear()
    let job3 = checkpointJob(engine: FakeEngine())
    await #expect(throws: MeetingTranscriptionJob.JobError.cancelled) {
      _ = try await job3.runTestAttempt(
        tracks: [.microphone: audio], language: "de",
        checkpoint: access(store, meetingID: meetingID) { saves in if saves == 1 { job3.cancel() } }
      ) { _ in }
    }
    let resumedSeen = OSAllocatedUnfairLock<[String?]>(initialState: [])
    let resumedEngine = FakeEngine()
    let resumed = try await checkpointJob(engine: resumedEngine, languages: resumedSeen).runTestAttempt(
      tracks: [.microphone: audio], language: "de", checkpoint: access(store, meetingID: meetingID)
    ) { _ in }
    #expect(resumed.resumedPieces == 1)
    #expect(resumedEngine.calls.count == total - 1)
    #expect(resumedSeen.withLock { $0 }.allSatisfy { $0 == "de" })
  }

  // MARK: - Whole runs (#4052)

  @Test("whole-run mode decodes each contiguous run once, unpadded, and keeps every word")
  func wholeRunDecodesEachRunOnce() async throws {
    let dir = try folder()
    // 0-70 s contiguous across two files, then a gap, then 80-85 s: two runs.
    let audio = MeetingTrackAudio(files: [
      try segment(in: dir, index: 1, startMs: 0, seconds: 60),
      try segment(in: dir, index: 2, startMs: 60_000, seconds: 10),
      try segment(in: dir, index: 3, startMs: 80_000, seconds: 5),
    ])
    #expect(audio.runs.count == 2)
    let engine = FakeEngine()
    var fractions: [Double] = []
    let result = try await checkpointJob(engine: engine, cutsPieces: false).runTestAttempt(
      tracks: [.microphone: audio]
    , language: nil) { stage in
      if case .transcribing(_, let fraction) = stage { fractions.append(fraction) }
    }
    // One call per run, each exactly the run (no seam padding on either side).
    #expect(engine.calls == [70 * 16_000, 5 * 16_000])
    // The fake hears one word per 500 ms: 140 + 10, none dropped.
    #expect(words(result) == 150)
    #expect(result.forcedCuts == 0)
    #expect(result.failedPieces == 0)
    // Progress moves once per finished run.
    #expect(fractions.count == 2)
    #expect(fractions.last == 1)
  }

  @Test("a whole-run piece keeps boundary and untimed words, shifted onto the meeting timeline")
  func wholeRunPieceKeepsEveryWord() {
    // "late" ends after the run's end (a rounding past the edge); "um" has no times.
    let text = "first um late"
    let timings = [
      ASRWordTiming(word: "first", range: 0..<5, startMs: 0, endMs: 300),
      ASRWordTiming(word: "um", range: 6..<8, startMs: nil, endMs: nil),
      ASRWordTiming(word: "late", range: 9..<13, startMs: 9_900, endMs: 10_300),
    ]
    let piece = MeetingTranscriptionJob.wholeRunPiece(
      result: ASRResult(
        text: text, language: nil, duration: 10, processingTime: 0, backendType: .parakeet,
        wordTimings: timings),
      startMs: 80_000, endMs: 90_000)
    #expect(piece.text == "first um late")
    #expect(piece.words.map(\.word) == ["first", "um", "late"])
    #expect(piece.words.map(\.range) == [0..<5, 6..<8, 9..<13])
    #expect(piece.words.map(\.startMs) == [80_000, nil, 89_900])
    #expect(piece.words.map(\.endMs) == [80_300, nil, 90_300])
    #expect(piece.startMs == 80_000)
    #expect(piece.endMs == 90_000)
  }

  @Test("a whole run that fails twice is one gap marker spanning the run")
  func wholeRunFailingTwiceIsAGap() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 50)])
    struct Broken: Error {}
    var calls = 0
    var config = MeetingTranscriptionJob.Configuration()
    config.cutsPieces = false
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { true }, waitUntilDictationIdle: {}, beginModelUse: {}, endModelUse: {},
        loadEngine: {},
        transcribe: { _, _ in
          calls += 1
          throw Broken()
        }, unloadEngine: {},
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }),
      configuration: config)
    let result = try await job.runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in }
    #expect(calls == 2)
    #expect(result.failedPieces == 1)
    #expect(result.failedRanges[.microphone] == [0..<(50 * 16_000)])
    #expect(result.composition.text == "[Could not transcribe 0:00 to 0:50]")
  }

  @Test("a whole-run checkpoint resumes, and is never mixed with a cut-pieces one")
  func wholeRunCheckpointIdentity() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [
      try segment(in: dir, index: 1, startMs: 0, seconds: 30),
      try segment(in: dir, index: 2, startMs: 40_000, seconds: 5),
    ])
    let store = MeetingProcessingCheckpointStore(meetingFolder: dir)
    let meetingID = UUID()

    // Interrupted after the first run's save; the resume decodes only the second run.
    let first = FakeEngine()
    let job1 = checkpointJob(engine: first, cutsPieces: false)
    await #expect(throws: MeetingTranscriptionJob.JobError.cancelled) {
      _ = try await job1.runTestAttempt(
        tracks: [.microphone: audio], language: nil,
        checkpoint: access(store, meetingID: meetingID) { saves in if saves == 1 { job1.cancel() } }
      ) { _ in }
    }
    guard case .checkpoint(let saved) = store.load() else {
      Issue.record("no checkpoint after the interrupted whole-run pass")
      return
    }
    #expect(saved.key.cutsPieces == false)
    #expect(saved.key.processingVersion == MeetingTranscriptionJob.processingVersion)
    let resumed = FakeEngine()
    let result = try await checkpointJob(engine: resumed, cutsPieces: false).runTestAttempt(
      tracks: [.microphone: audio], language: nil, checkpoint: access(store, meetingID: meetingID)) { _ in }
    #expect(resumed.calls == [5 * 16_000])
    #expect(words(result) == 70)

    // The same meeting under cut pieces starts over: nothing whole-run is reused.
    let cut = FakeEngine()
    _ = try await checkpointJob(engine: cut, cutsPieces: true).runTestAttempt(
      tracks: [.microphone: audio], language: nil, checkpoint: access(store, meetingID: meetingID)) { _ in }
    #expect(cut.calls.count >= 3, "a cut-pieces pass must not reuse whole-run pieces")
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
        transcribe: { samples, _ in
          calls += 1
          // The second piece fails on both attempts (calls 2 and 3).
          if calls == 2 || calls == 3 { throw Broken() }
          return engine.transcribe(samples)
        },
        unloadEngine: {},
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }),
      configuration: config)
    let result = try await job.runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in }
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
    var uses = 0
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { true }, waitUntilDictationIdle: {},
        beginModelUse: {
          // Only the first model-use claim parks: #3973 C1 takes it again for each operation.
          uses += 1
          guard uses == 1 else { return }
          enteredSignal.yield()
          await withCheckedContinuation { release = $0 }
        },
        endModelUse: {}, loadEngine: {},
        transcribe: { _, _ in ASRResult(text: "", language: nil, duration: 0, processingTime: 0, backendType: .parakeet) },
        unloadEngine: {},
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }))
    let first = Task { try await job.runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in } }
    var iterator = entered.makeAsyncIterator()
    _ = await iterator.next()
    await #expect(throws: MeetingTranscriptionJob.JobError.alreadyRunning) {
      _ = try await job.runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in }
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
      let resumed = try await MeetingProcessingCrash.job(onTranscribe: { resumedCalls += 1 }).runTestAttempt(
        tracks: [.microphone: audio], language: nil, checkpoint: MeetingProcessingCrash.access(folder: dir)
      ) { _ in }
      var referenceCalls = 0
      let reference = try await MeetingProcessingCrash.job(onTranscribe: { referenceCalls += 1 }).runTestAttempt(
        tracks: [.microphone: audio], language: nil) { _ in }
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
        transcribe: { samples, _ in
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
        }),
      configuration: config)
  }

  #if DEBUG
    /// #3973 C1: a dictation that starts during a decode finds the engine given back at the
    /// end of that decode (one engine operation), so the job never pauses with the engine
    /// loaded and the prolonged-pause unload has nothing to do; the next decode loads again
    /// after the dictation.
    @Test(
      "a dictation during a decode: the engine is given back after it, and reloaded after dictation",
      .timeLimit(.minutes(1)))
    func aDictationDuringADecodeFindsTheEngineGivenBack() async throws {
      let dir = try folder()
      let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 50)])
      let state = PauseState()
      let job = pauseJob(state, onSecondPiece: { state.dictating = true })
      // #3972 C5: the page's pause line follows this wait too, and always ends cleared. The
      // dictation ends once the job reports it is waiting for it (the job's own signal).
      var waitReports: [Bool] = []
      job.onWaitingForDictation = { waiting in
        waitReports.append(waiting)
        if waiting {
          #expect(Array(state.log.suffix(2)) == ["unload", "release"], "waiting with nothing held")
          state.endDictation()
        }
      }
      let result = try await job.runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in }
      #expect(waitReports.first == true)
      #expect(waitReports.last == false)
      #expect(waitReports.filter { $0 }.count == waitReports.filter { !$0 }.count)
      // The identity probe first (#3973 C1), then one operation, given back, then the next.
      #expect(
        Array(state.log.prefix(8))
          == ["use", "release", "use", "load", "decode", "unload", "release", "use"])
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
      _ = try await job.runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in }
      // #3973 C1: the decode's operation already gave the engine back; the pass then waits for
      // normal with nothing loaded, so no separate pressure unload is counted.
      #expect(job.pressureUnloads == 0)
      #expect(
        Array(state.log.prefix(10))
          == [
            "use", "release", "use", "load", "decode", "unload", "release", "pressure-wait", "use",
            "load",
          ])
    }
  #endif

  /// A job whose model load or contention wait can raise memory pressure (#3973 C1).
  private func pressureJob(
    _ state: PauseState, loadRaisesPressure: Bool, contentions: Int
  ) -> MeetingTranscriptionJob {
    var refusals = contentions
    var raised = false
    return MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { true }, waitUntilDictationIdle: {},
        beginModelUse: { state.log.append("use") },
        endModelUse: { state.log.append("release") },
        loadEngine: {
          if refusals > 0 {
            refusals -= 1
            state.log.append("busy")
            throw Contention()
          }
          state.log.append("load")
          if loadRaisesPressure, !raised {
            raised = true
            state.pressure = true  // pressure rises while the model loads
          }
        },
        transcribe: { samples, _ in
          state.log.append("decode")
          return FakeSpeech.transcribe(samples)
        },
        unloadEngine: { state.log.append("unload") },
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) },
        isTemporaryEngineContention: { $0 is Contention },
        waitForEngineAvailability: {
          state.log.append("wait")
          state.pressure = true  // pressure rises while the load waits for contention
        },
        engineIdentity: { "fake" },
        isMemoryPressureElevated: { state.pressure },
        waitUntilMemoryNormal: {
          state.log.append("pressure-wait")
          state.pressure = false
        }))
  }

  /// #3973 C1: memory pressure that rises during the load is checked before the decode: the
  /// operation unloads, waits for normal holding nothing, loads again, and only then decodes.
  @Test("pressure rising during a load: no decode until normal, then the pass resumes")
  func pressureDuringLoadStopsTheDecode() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 2)])
    let state = PauseState()
    let job = pressureJob(state, loadRaisesPressure: true, contentions: 0)
    let result = try await job.runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in }
    #expect(
      state.log == [
        "use", "release", "use", "load", "unload", "release", "pressure-wait", "use", "load",
        "decode", "unload", "release",
      ])
    #expect(job.pressureUnloads == 1)
    #expect(result.failedPieces == 0)
    #expect(!job.isEngineResident)
  }

  /// #3973 C1: memory pressure that rises during a contention wait is waited out, holding
  /// nothing, before the load is tried again.
  @Test("pressure rising during a contention wait: no load until normal, then the pass resumes")
  func pressureDuringContentionStopsTheLoad() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try segment(in: dir, index: 1, startMs: 0, seconds: 2)])
    let state = PauseState()
    let job = pressureJob(state, loadRaisesPressure: false, contentions: 1)
    let result = try await job.runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in }
    #expect(
      state.log == [
        "use", "release", "use", "busy", "release", "wait", "pressure-wait", "use", "load",
        "decode", "unload", "release",
      ])
    #expect(result.failedPieces == 0)
    #expect(!job.isEngineResident)
  }

  // MARK: - C3b round 2

  @Test("replacing a file's samples without changing its length or size discards the checkpoint")
  func sameSizeContentChangeIsDetected() async throws {
    let dir = try folder()
    let file = try segment(in: dir, index: 1, startMs: 0, seconds: 30)
    let audio = MeetingTrackAudio(files: [file])
    let store = MeetingProcessingCheckpointStore(meetingFolder: dir)
    let meetingID = UUID()
    let first = FakeEngine()
    _ = try await checkpointJob(engine: first).runTestAttempt(
      tracks: [.microphone: audio], language: nil, checkpoint: access(store, meetingID: meetingID)) { _ in }
    let sizeBefore = try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber
    // Flip bytes near the end of the file: same length, same size, different samples.
    let handle = try FileHandle(forUpdating: file.url)
    try handle.seek(toOffset: try handle.seekToEnd() - 64)
    try handle.write(contentsOf: Data(repeating: 0x5A, count: 32))
    try handle.close()
    let sizeAfter = try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber
    #expect(sizeBefore == sizeAfter)
    let second = FakeEngine()
    let result = try await checkpointJob(engine: second).runTestAttempt(
      tracks: [.microphone: MeetingTrackAudio(files: [file])], language: nil,
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
    _ = try? await checkpointJob(engine: FakeEngine()).runTestAttempt(
      tracks: [.microphone: audio], language: nil, checkpoint: access(store, meetingID: UUID())) { _ in }
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
    let run = Task { try await job.runTestAttempt(tracks: [.microphone: audio], language: nil, checkpoint: blocking) { _ in } }
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
        loadEngine: { state.log.append("load") }, transcribe: { samples, _ in FakeSpeech.transcribe(samples) },
        unloadEngine: { state.log.append("unload") },
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }))
    let run = Task { try await job.runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in } }
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
    _ = try await job.runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in }
    #expect(Array(state.log.prefix(5)) == ["pressure-wait", "use", "release", "use", "load"])
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
        transcribe: { samples, _ in
          calls += 1
          if calls == 2 || calls == 3 { throw Broken() }
          return FakeSpeech.transcribe(samples)
        },
        unloadEngine: {},
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }),
      configuration: config)
    let result = try await job.runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in }
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
        loadEngine: {}, transcribe: { samples, _ in FakeSpeech.transcribe(samples) }, unloadEngine: {},
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }))
    let result = try await job.runTestAttempt(
      tracks: [.microphone: audio], language: nil,
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
    let run = Task { try await job.runTestAttempt(tracks: [.microphone: audio], language: nil, checkpoint: access) { _ in } }
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
      meetingID: meetingID, attemptID: MeetingTestAttempt.id, tracks: [.microphone: audio],
      order: [.microphone], language: nil,
      engine: .init(requested: .parakeet, resolved: .parakeet, modelIdentity: "ultra:r1"),
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
          key: key, tracks: [.microphone: .init(pieces: [bad])]))
      let engine = FakeEngine()
      let result = try await checkpointJob(engine: engine).runTestAttempt(
        tracks: [.microphone: audio], language: nil, checkpoint: access(store, meetingID: meetingID)) { _ in }
      #expect(result.resumedPieces == 0)
      #expect(engine.calls.count > 0)
    }
  }

  /// #3973 C1: the engine operation gives the engine back as soon as the decode has physically
  /// ended, without waiting for a dictation that started meanwhile; the job then waits for
  /// that dictation (before its speaker analysis) holding nothing, and a cancel ends that wait.
  /// #3973 C1: every decode acquires the engine again, so a model that changed between two
  /// operations (dictation's Parakeet swapped while it held the engine) is seen at the next
  /// acquisition and fails the pass: words from two models are never mixed in one transcript.
  @Test("a model that changed between two decode operations fails the pass", .timeLimit(.minutes(1)))
  func aModelChangedBetweenOperationsFailsThePass() async throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [
      try segment(in: dir, index: 1, startMs: 0, seconds: 2),
      try segment(in: dir, index: 2, startMs: 5_000, seconds: 2),
    ])
    var identity = "model-a"
    var log: [String] = []
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { true }, waitUntilDictationIdle: {},
        beginModelUse: { log.append("use") }, endModelUse: { log.append("release") },
        loadEngine: { log.append("load \(identity)") },
        transcribe: { samples, _ in
          log.append("decode")
          identity = "model-b"  // swapped while the engine was given back
          return FakeSpeech.transcribe(samples)
        },
        unloadEngine: { log.append("unload") },
        analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) },
        engineIdentity: { identity }))
    await #expect(throws: MeetingTranscriptionJob.JobError.engineUnavailable("model_changed")) {
      _ = try await job.runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in }
    }
    #expect(log.filter { $0 == "decode" }.count == 1, "no decode ran on the changed model")
    #expect(log.last == "release", "the changed model was given back")
    #expect(!job.isEngineResident)
  }

  @Test(
    "after the last decode the engine is given back at once; the next unit waits for dictation",
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
          transcribe: { samples, _ in
            state.dictating = true  // the user starts dictating during the final decode
            return FakeSpeech.transcribe(samples)
          },
          unloadEngine: { state.log.append("unload") },
          analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }))
      // #3972 C5: the page's pause line shows during this wait and clears after it.
      var waiting = false
      job.onWaitingForDictation = { waiting = $0 }
      let run = Task { try await job.runTestAttempt(tracks: [.microphone: audio], language: nil) { _ in } }
      var iterator = paused.makeAsyncIterator()
      _ = await iterator.next()
      #expect(
        state.log == ["use", "release", "use", "load", "unload", "release"], "released before any wait")
      #expect(waiting, "the wait for dictation is reported")
      if cancelDuringWait {
        job.cancel()
        _ = try? await run.value
      } else {
        state.endDictation()
        _ = try await run.value
      }
      #expect(
        state.log == ["use", "release", "use", "load", "unload", "release"], "nothing taken again")
      #expect(!waiting, "cleared after the wait ends")
    }
  }


  // MARK: - #3973 C3: Whisper results, yields and the resolved engine

  /// A whole-run job (the production shape) whose engine is `transcribe`.
  private func wholeRunJob(
    transcribe: @escaping @MainActor ([Float], String?) async throws -> ASRResult,
    analyze: @escaping @Sendable (MeetingTrackAudio) async -> MeetingSpeakerAnalysis = { _ in
      MeetingSpeakerAnalysis(outcome: .single, segments: [])
    },
    resolution: MeetingEngineResolution? = nil,
    isDictationIdle: @escaping @MainActor () -> Bool = { true },
    waitUntilDictationIdle: @escaping @MainActor () async -> Void = {}
  ) -> MeetingTranscriptionJob {
    var config = MeetingTranscriptionJob.Configuration()
    config.cutsPieces = false
    return MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: isDictationIdle, waitUntilDictationIdle: waitUntilDictationIdle,
        beginModelUse: {}, endModelUse: {},
        loadEngine: {}, transcribe: transcribe, unloadEngine: {}, analyzeSpeakers: analyze,
        resolution: resolution),
      configuration: config)
  }

  @Test("#3973 C3: a Whisper result (sentences, no words) is a success: speakers found per sentence, no gap")
  func whisperResultIsASuccess() async throws {
    let dir = try folder()
    let files = [try segment(in: dir, index: 1, startMs: 0, seconds: 4)]
    let text = "Hello there. Bye now."
    let job = wholeRunJob(
      transcribe: { _, _ in
        ASRResult(
          text: text, language: "en", duration: 4, processingTime: 0, backendType: .whisper,
          wordTimings: nil, wordTimingCoverage: nil,
          segmentTimings: [
            ASRSegmentTiming(range: 0..<12, startMs: 0, endMs: 1_000),
            ASRSegmentTiming(range: 13..<21, startMs: 1_500, endMs: 2_500),
          ])
      },
      analyze: { _ in
        MeetingSpeakerAnalysis(
          outcome: .labeled,
          segments: [
            SpeakerSegment(speakerId: "1", startMs: 0, endMs: 1_200, quality: 1),
            SpeakerSegment(speakerId: "2", startMs: 1_300, endMs: 4_000, quality: 1),
          ])
      })

    let result = try await job.runTestAttempt(
      tracks: [.callSound: MeetingTrackAudio(files: files)], language: nil) { _ in }

    #expect(result.failedPieces == 0)
    #expect(result.failedRanges.isEmpty)
    #expect(result.speakerOutcomes[.callSound] == .labeled, "speaker analysis ran on it")
    #expect(result.composition.text == "Hello there.\n\nBye now.")
    #expect(result.composition.turns.map(\.speakerId) == ["sys:1", "sys:2"])
    #expect(result.composition.turns.allSatisfy { $0.granularity == .segment })
  }

  @Test("#3973 C3: a decode that gave way to dictation waits for it and runs again, with no gap counted")
  func yieldIsRetriedNotFailed() async throws {
    let dir = try folder()
    let files = [try segment(in: dir, index: 1, startMs: 0, seconds: 3)]
    // Dictation is pressed during each of the first four decodes and preempts it: more yields
    // than the two failures a piece may have, so only the wait-and-retry path can succeed.
    let yields = 4
    var calls = 0
    var waits = 0
    var dictating = false
    let job = wholeRunJob(
      transcribe: { samples, _ in
        calls += 1
        if calls <= yields {
          dictating = true
          throw MeetingEngineYield()
        }
        return FakeSpeech.transcribe(samples)
      },
      isDictationIdle: { !dictating },
      waitUntilDictationIdle: {
        waits += 1
        dictating = false
      })

    let result = try await job.runTestAttempt(
      tracks: [.microphone: MeetingTrackAudio(files: files)], language: nil) { _ in }

    #expect(calls == yields + 1)
    #expect(waits == yields, "each yield waited for dictation before decoding again")
    #expect(result.failedPieces == 0)
    #expect(!result.composition.text.isEmpty)
  }

  @Test("#3973 C3: yields with no dictation running stop after a bound and become a visible gap")
  func idleYieldsAreBounded() async throws {
    let dir = try folder()
    let files = [try segment(in: dir, index: 1, startMs: 0, seconds: 3)]
    var calls = 0
    let job = wholeRunJob(transcribe: { _, _ in
      calls += 1
      throw MeetingEngineYield()
    })

    let result = try await job.runTestAttempt(
      tracks: [.microphone: MeetingTrackAudio(files: files)], language: nil) { _ in }

    #expect(calls == 2 * MeetingTranscriptionJob.idleYieldLimit)
    #expect(result.failedPieces == 1)
  }

  @Test("#3973 C3: a Whisper result with no bound sentence stays sentence-level, also after a resume")
  func unboundWhisperResultStaysSegmentLevel() {
    let result = ASRResult(
      text: "Hello", language: "en", duration: 4, processingTime: 0, backendType: .whisper,
      wordTimings: nil, wordTimingCoverage: nil, segmentTimings: [])
    let piece = MeetingTranscriptionJob.wholeRunPiece(result: result, startMs: 0, endMs: 4_000)
    #expect(piece.isSegmentLevel)

    // Through the checkpoint writer and reader, as a resumed pass reads it.
    let stored = MeetingProcessingCheckpoint.Piece(
      startSample: 0, endSample: 64_000, forcedCut: false, text: piece.text, words: [],
      segments: MeetingTranscriptionJob.storedSegments(piece))
    #expect(stored.segments == [])
    #expect(MeetingTranscriptionJob.trackPiece(stored)?.isSegmentLevel == true)

    let parakeet = ASRResult(
      text: "Hello", language: "en", duration: 4, processingTime: 0, backendType: .parakeet,
      wordTimings: nil, wordTimingCoverage: nil, segmentTimings: nil)
    let wordPiece = MeetingTranscriptionJob.wholeRunPiece(result: parakeet, startMs: 0, endMs: 4_000)
    #expect(!wordPiece.isSegmentLevel)
    #expect(MeetingTranscriptionJob.storedSegments(wordPiece) == nil)
  }

  @Test("#3973 C3: the result names the engine the pass resolved to and why, not the one asked for")
  func resultCarriesTheResolution() async throws {
    let dir = try folder()
    let files = [try segment(in: dir, index: 1, startMs: 0, seconds: 2)]
    let job = wholeRunJob(
      transcribe: { samples, _ in FakeSpeech.transcribe(samples) },
      resolution: MeetingEngineResolution(engine: .parakeet, fallbackReason: .notDownloaded))
    let attempt = MeetingAttemptConfiguration(
      requestedEngine: .whisper, languageIntent: nil, requestedEffectiveLanguage: nil)

    let result = try await job.run(
      tracks: [.microphone: MeetingTrackAudio(files: files)], language: nil,
      onStage: { _ in }, attempt: attempt)

    #expect(result.resolved.requestedEngine == .whisper)
    #expect(result.resolved.resolvedEngine == .parakeet)
    #expect(result.resolved.fallbackReason == .notDownloaded)
  }
}
