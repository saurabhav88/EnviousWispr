import Foundation
import Observation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprLivePreview
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices
@testable import EnviousWisprWhisperPreviewAdapter

/// #3973 G3: live words are display only. The real `MeetingCoordinator`, the real
/// `MeetingRecorder` and its real track writers record known audio while the live-words engine
/// is held (in preparation, in a feed, or in its end); Stop returns, the final pass starts on
/// the files on disk, and those files hold exactly the audio offered. Only the capture sources
/// and the live-words engines are fakes. `recordingIsolatedFromLiveWords` also runs the real
/// `MeetingTranscriptionJob` (the production configuration) with a fake speech decoder that
/// keeps the samples it was given; the other tests use the coordinator harness's fake job.
///
/// **What the user sees when this fails:** a meeting loses audio, Stop hangs, or the transcript
/// waits for live words because the live-words engine stalled.
@MainActor
@Suite("Meeting live words through the coordinator (#3973)", .tags(.productOutcome), .serialized)
struct MeetingLiveWordsIntegrationTests {
  typealias World = MeetingLiveWordsTests.World
  typealias Gate = MeetingLiveWordsTests.Gate
  typealias Gates = MeetingLiveWordsTests.Gates

  /// A coordinator over the real recorder with fake capture sources, and live words over fake
  /// engines.
  @MainActor
  final class Rig {
    let harness: MeetingCoordinatorTests.Harness
    let world: World
    let owner: MeetingLiveWords
    let clock = MeetingRecorderTests.Clock()
    let releases = MeetingRecorderTests.ReleaseTimer()
    var microphones: [MeetingRecorderTests.FakeMicrophone] = []
    var calls: [MeetingRecorderTests.FakeCallSound] = []
    var recorders: [MeetingRecorder] = []
    var language: LanguageMode = .locked("ja")
    var micOpenError: Error?
    /// Passed when the final pass starts (a signal, never held).
    let passStarted = Gate(open: true)
    /// With `realJob`: the samples the pass's decoder received, one entry per decode call.
    var decoded: [[Float]] = []
    let realJob: Bool
    lazy var coordinator = MeetingCoordinator(dependencies: dependencies())

    init(
      world: World, callSound: Bool = true, realJob: Bool = false,
      choiceOwner: MeetingLiveWordsChoice.Initializer? = nil
    ) throws {
      harness = try MeetingCoordinatorTests.Harness()
      harness.callSound = callSound
      self.realJob = realJob
      self.world = world
      owner = MeetingLiveWordsTests.owner(world, choiceOwner: choiceOwner)
      let started = passStarted
      harness.jobBehavior = { _ in
        await started.pass()
        return MeetingCoordinatorTests.result()
      }
    }

    private func dependencies() -> MeetingCoordinator.Dependencies {
      var deps = harness.dependencies()
      deps.makeRecorder = { [self] configuration, onSegment, onFailure in
        let mic = MeetingRecorderTests.FakeMicrophone()
        mic.openError = micOpenError
        microphones.append(mic)
        let clock = self.clock
        var sources = MeetingRecorder.Sources(
          makeMicrophone: { mic },
          makeCallSound: { [self] handler, _, _ in
            let call = MeetingRecorderTests.FakeCallSound(handler: handler)
            calls.append(call)
            return call
          },
          hostTime: { clock.now.withLock { $0 } },
          reopenDelay: {})
        // #4248: the hold releases against this fake clock only when a test fires it; Stop
        // releases the rest.
        sources.releaseScheduler = releases.scheduler
        let recorder = MeetingRecorder(
          configuration: configuration, sources: sources, onSegment: onSegment,
          onFailure: onFailure)
        recorders.append(recorder)
        return recorder
      }
      if realJob {
        let started = passStarted
        deps.makeJob = { [self] _ in
          var configuration = MeetingTranscriptionJob.Configuration()
          configuration.cutsPieces = false  // as MeetingWiring builds it (#4052)
          return MeetingTranscriptionJob(
            dependencies: .init(
              isDictationIdle: { true }, waitUntilDictationIdle: {}, beginModelUse: {},
              endModelUse: {}, loadEngine: { await started.pass() },
              transcribe: { [self] samples, _ in
                decoded.append(samples)
                return ASRResult(
                  text: "words", language: nil, duration: Double(samples.count) / 16_000,
                  processingTime: 0, backendType: .parakeet)
              },
              unloadEngine: {},
              analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }),
            configuration: configuration)
        }
      }
      deps.liveWords = owner
      deps.meetingLanguage = { [self] in language }
      deps.liveVocabulary = {
        LivePreviewVocabulary(lookups: nil, contextualPhrases: ["Envious"], dictionaryEnabled: true)
      }
      return deps
    }

    /// Offers known microphone audio as the HAL source would, in 100 ms chunks.
    func speak(_ samples: [Float]) {
      let mic = microphones[microphones.count - 1]
      var offset = 0
      while offset < samples.count {
        let chunk = Array(samples[offset..<min(offset + 1_600, samples.count)])
        clock.advance(seconds: Double(chunk.count) / 16_000)
        mic.onSamples?(chunk, 0.2)
        offset += chunk.count
      }
    }

    #if DEBUG  // the writer's DEBUG-only queue seam
    /// #4248: moves the clock past the microphone's silence hold and runs its due releases, so
    /// the audio spoken so far reaches live words, as it would 3 s later in a meeting.
    func releaseHeld() async {
      let writer = recorders.last?.microphoneWriterForTesting
      await writer?.queueBarrierForTesting()
      clock.advance(seconds: MeetingRecorder.silenceHoldSeconds + 0.5)
      releases.fire(upTo: clock.now.withLock { $0 })
      await writer?.queueBarrierForTesting()
    }
    #endif

    /// Offers known call audio as the tap would.
    func play(_ samples: [Float]) {
      let recorder = recorders[recorders.count - 1]
      samples.withUnsafeBufferPointer { calls[calls.count - 1].handler($0, recorder.anchor, false) }
    }

    /// The track as the real writer saved it, from the meeting's recorded segments.
    func saved(_ meetingID: UUID, _ track: MeetingTrackKind) throws -> [Float] {
      let record = try #require(coordinator.record(id: meetingID))
      let folder = harness.store.folder(for: meetingID)
      let files = (record.segments[track] ?? []).map {
        (folder.appendingPathComponent($0.fileName), $0.startMs)
      }
      let audio = MeetingTrackAudio(files: files)
      return try audio.read(from: 0, count: audio.endSample)
    }
  }

  /// Distinct, position-revealing patterns (exact in 16-bit PCM to within 1e-3).
  static func micPattern(_ count: Int) -> [Float] {
    (0..<count).map { Float($0 % 800) / 1_000 + 0.05 }
  }
  static func callPattern(_ count: Int) -> [Float] {
    (0..<count).map { -Float($0 % 600) / 1_000 - 0.05 }
  }

  static func same(_ a: [Float], _ b: [Float]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-3 }
  }

  enum Held: CaseIterable, Sendable { case preparation, feed, end }

  /// Runs `step` with a deadline: a step a regression blocks fails and releases `gate` instead
  /// of hanging the suite.
  static func bounded(
    _ what: String, gate: Gate, sourceLocation: SourceLocation = #_sourceLocation,
    _ step: @escaping @MainActor () async -> Void
  ) async {
    let task = Task { @MainActor in await step() }
    await PreviewWait.within(what, sourceLocation: sourceLocation, onExpiry: gate.open) {
      await task.value
    }
  }

  @Test(
    "with the live-words engine held, recording continues, Stop returns and the pass decodes the files",
    arguments: Held.allCases)
  func recordingIsolatedFromLiveWords(_ held: Held) async throws {
    let world = World()
    let gate = Gate()
    defer { gate.open() }
    world.engineGates = { _ in
      switch held {
      case .preparation: Gates(prepare: gate)
      case .feed: Gates(feed: gate)
      case .end: Gates(end: gate)
      }
    }
    world.apple = .ready(world.appleCandidate())
    let rig = try Rig(world: world, realJob: true)
    let outcome = await rig.coordinator.start(from: .menu)
    let meetingID = try #require(rig.coordinator.meetings.first?.id)
    #expect(outcome == .recording(meetingID: meetingID))
    switch held {
    case .preparation:
      await PreviewWait.within("preparation held", onExpiry: gate.open) { await gate.reached(1) }
    case .feed, .end:
      await MeetingLiveWordsTests.until("live words running", rig.owner, release: gate.open) {
        MeetingLiveWordsTests.bothRunning($0)
      }
    }
    // Independent oracles: each track's whole sequence, offered in two parts.
    let mic = Self.micPattern(32_000)
    let call = Self.callPattern(16_000)
    rig.speak(Array(mic[..<1_600]))
    rig.play(Array(call[..<1_600]))
    if held == .feed {
      await PreviewWait.within("a feed held", onExpiry: gate.open) { await gate.reached(1) }
    }
    // Recorded while the live work stays held.
    rig.speak(Array(mic[1_600...]))
    rig.play(Array(call[1_600...]))
    await Self.bounded("Stop", gate: gate) { await rig.coordinator.stop() }
    if held == .end {
      await PreviewWait.within("an end held", onExpiry: gate.open) { await gate.reached(1) }
    }
    await PreviewWait.within("the final pass starting", onExpiry: gate.open) {
      await rig.passStarted.reached(1)
    }
    #expect(!rig.owner.closingEngines.isEmpty, "the live work is still held")
    await MeetingCoordinatorTests.eventually("the transcript ready") {
      rig.coordinator.record(id: meetingID)?.state == .ready
    }
    #expect(rig.decoded.count == 2, "one decode per track")
    #expect(!rig.owner.closingEngines.isEmpty, "the pass finished while the live work was held")
    // The files on disk, and what the decoder received, are exactly the offered audio.
    #expect(Self.same(try rig.saved(meetingID, .microphone), mic))
    #expect(Self.same(try rig.saved(meetingID, .callSound), call))
    #expect(rig.decoded.filter { Self.same($0, mic) }.count == 1, "the microphone decoded once")
    #expect(rig.decoded.filter { Self.same($0, call) }.count == 1, "the call sound decoded once")
    gate.open()
    #expect(await rig.owner.waitForCleanups(seconds: 10))
    let sessions = world.appleEngines.flatMap(\.sessions)
    #expect(sessions.allSatisfy { $0.ends == 1 }, "each live session ended once")
    if held != .preparation { #expect(sessions.count == 2) }
  }

  @Test("the live words choice is frozen at start, and only captured tracks get live words")
  func frozenLanguageAndCapturedTracks() async throws {
    let world = World()
    world.apple = .ready(world.appleCandidate())
    world.choice = .ready(engine: .apple, language: "ja-JP")
    let rig = try Rig(world: world, callSound: false)
    rig.language = .locked("fr")  // the transcript's language never steers live words
    await rig.coordinator.start(from: .menu)
    world.choice = .ready(engine: .apple, language: "fr-FR")  // belongs to the next meeting
    await MeetingLiveWordsTests.until("mic running", rig.owner) {
      MeetingLiveWordsTests.status($0, .microphone) == .running
    }
    #expect(world.languages == [.locked("ja-JP")])
    #expect(MeetingLiveWordsTests.status(rig.owner, .callSound) == .off(.notCaptured))
    #expect(world.appleEngines.count == 1, "no recognizer for the call sound it did not record")
    await rig.coordinator.stop()
    #expect(await rig.owner.waitForCleanups(seconds: 10))
  }

  @Test("a recording that fails to start starts no live-words engine")
  func failedStartStartsNoEngine() async throws {
    let world = World()
    world.apple = .ready(world.appleCandidate())
    let rig = try Rig(world: world)
    rig.micOpenError = AudioError.formatCreationFailed(source: "test")
    let outcome = await rig.coordinator.start(from: .menu)
    guard case .failed = outcome else {
      Issue.record("expected a failed start, got \(outcome)")
      return
    }
    #expect(rig.coordinator.liveTranscript == nil)
    #expect(world.languages.isEmpty && world.appleEngines.isEmpty)
  }

  @Test("live lines stay after Stop and give way to the transcript once the pass is ready")
  func linesGiveWayToTheTranscript() async throws {
    let world = World()
    world.apple = .ready(world.appleCandidate())
    let rig = try Rig(world: world)
    let passGate = Gate()
    defer { passGate.open() }
    rig.harness.jobBehavior = { _ in
      await passGate.pass()
      return MeetingCoordinatorTests.result()
    }
    await rig.coordinator.start(from: .menu)
    let meetingID = try #require(rig.coordinator.meetings.first?.id)
    await MeetingLiveWordsTests.until("running", rig.owner) {
      MeetingLiveWordsTests.bothRunning($0)
    }
    try #require(world.appleEngines[0].sessions.first).emit(
      .update(finalized: "Live line.", inProgress: ""))
    await MeetingLiveWordsTests.until("the live line", rig.owner) {
      ($0.transcript?.lines.map(\.text) ?? []) == ["Live line."]
    }
    rig.speak(Self.micPattern(16_000))  // a second of audio, so the pass has something to read
    await rig.coordinator.stop()
    await PreviewWait.within("the pass", onExpiry: passGate.open) { await passGate.reached(1) }
    #expect(rig.coordinator.liveTranscript?.lines.map(\.text) == ["Live line."], "kept meanwhile")
    passGate.open()
    await MeetingCoordinatorTests.eventually("the transcript ready") {
      rig.coordinator.record(id: meetingID)?.state == .ready
    }
    #expect(rig.coordinator.liveTranscript == nil, "the transcript replaced the live words")
    #expect(await rig.owner.waitForCleanups(seconds: 10))
  }

  @Test("a failed pass keeps the live words; a successful Retry replaces them")
  func failedPassKeepsLines() async throws {
    let world = World()
    world.apple = .ready(world.appleCandidate())
    let rig = try Rig(world: world)
    let runs = OSAllocatedUnfairLock(initialState: 0)
    rig.harness.jobBehavior = { _ in
      let run = runs.withLock { state -> Int in
        state += 1
        return state
      }
      if run == 1 { throw MeetingTranscriptionJob.JobError.engineUnavailable("test") }
      return MeetingCoordinatorTests.result()
    }
    await rig.coordinator.start(from: .menu)
    let meetingID = try #require(rig.coordinator.meetings.first?.id)
    await MeetingLiveWordsTests.until("running", rig.owner) { MeetingLiveWordsTests.bothRunning($0) }
    try #require(world.appleEngines[0].sessions.first).emit(
      .update(finalized: "Live line.", inProgress: ""))
    await MeetingLiveWordsTests.until("the live line", rig.owner) {
      ($0.transcript?.lines.map(\.text) ?? []) == ["Live line."]
    }
    rig.speak(Self.micPattern(16_000))
    await rig.coordinator.stop()
    await MeetingCoordinatorTests.eventually("the pass failed") {
      rig.coordinator.record(id: meetingID)?.state == .failed
    }
    #expect(rig.coordinator.liveTranscript?.meetingID == meetingID)
    #expect(rig.coordinator.liveTranscript?.lines.map(\.text) == ["Live line."], "kept on failure")
    #expect(await rig.coordinator.transcribeAgain(meetingID: meetingID, engine: .parakeet))
    await MeetingCoordinatorTests.eventually("the transcript ready") {
      rig.coordinator.record(id: meetingID)?.state == .ready
    }
    #expect(rig.coordinator.liveTranscript == nil, "the transcript replaced the live words")
    #expect(await rig.owner.waitForCleanups(seconds: 10))
  }

  @Test("Delete clears the live words before its first write returns, and refuses late words")
  func deleteClearsBeforeItsWrite() async throws {
    let world = World()
    world.apple = .ready(world.appleCandidate())
    let rig = try Rig(world: world)
    await rig.coordinator.start(from: .menu)
    let meetingID = try #require(rig.coordinator.meetings.first?.id)
    await MeetingLiveWordsTests.until("running", rig.owner) { MeetingLiveWordsTests.bothRunning($0) }
    let mic = try #require(world.appleEngines[0].sessions.first)
    mic.emit(.update(finalized: "Live line.", inProgress: ""))
    await MeetingLiveWordsTests.until("the live line", rig.owner) {
      ($0.transcript?.lines.isEmpty ?? true) == false
    }
    // Every store write waits behind this hold, so the deletion mark cannot land yet.
    let hold = MeetingDocumentsOwnerTests.holdFileQueue()
    let release: @Sendable () -> Void = { _ = hold.signal() }
    let deleting = Task { @MainActor in await rig.coordinator.delete(meetingID: meetingID) }
    await MeetingLiveWordsTests.until("the live words cleared", rig.owner, release: release) {
      $0.transcript == nil
    }
    #expect(rig.coordinator.record(id: meetingID)?.deletionRequested != true, "the write is held")
    mic.emit(.update(finalized: "Late words.", inProgress: ""))
    #expect(rig.coordinator.liveTranscript == nil, "late words are refused")
    release()
    await PreviewWait.within("Delete", onExpiry: release) { await deleting.value }
    #expect(rig.coordinator.record(id: meetingID) == nil)
    #expect(rig.coordinator.liveTranscript == nil)
    #expect(await rig.owner.waitForCleanups(seconds: 10))
    #expect(mic.ends == 1)
  }

  #if DEBUG  // releases the microphone hold through the writer's DEBUG-only queue seam
  @Test(
    "Delete and Quit return while live words are held; a late result never reaches the next meeting"
  )
  func deleteAndQuitStayResponsive() async throws {
    let world = World()
    let feed = Gate()
    defer { feed.open() }
    world.engineGates = { $0 == 0 ? Gates(feed: feed) : Gates() }
    world.apple = .ready(world.appleCandidate())
    let rig = try Rig(world: world)
    await rig.coordinator.start(from: .menu)
    let first = try #require(rig.coordinator.meetings.first?.id)
    await MeetingLiveWordsTests.until("running", rig.owner, release: feed.open) {
      MeetingLiveWordsTests.bothRunning($0)
    }
    let oldMic = try #require(world.appleEngines[0].sessions.first)
    rig.speak(Self.micPattern(1_600))
    await rig.releaseHeld()
    await PreviewWait.within("the feed held", onExpiry: feed.open) { await feed.reached(1) }
    // Returns with the feed still held.
    await Self.bounded("Delete", gate: feed) { await rig.coordinator.delete(meetingID: first) }
    #expect(rig.coordinator.liveTranscript == nil, "Delete clears the live words")
    #expect(rig.coordinator.record(id: first) == nil)
    // The next meeting: the held Apple cleanup leaves its live words off.
    await rig.coordinator.start(from: .menu)
    let second = try #require(rig.coordinator.meetings.first { $0.id != first }?.id)
    await MeetingLiveWordsTests.until("the next meeting's status", rig.owner, release: feed.open) {
      MeetingLiveWordsTests.status($0, .microphone) == .off(.previousStillClosing)
    }
    oldMic.emit(.update(finalized: "From the deleted meeting.", inProgress: ""))
    #expect(rig.coordinator.liveTranscript?.meetingID == second)
    #expect(rig.coordinator.liveTranscript?.lines.isEmpty == true)
    // Quit is synchronous and returns with the old cleanup still held.
    rig.coordinator.prepareForTermination(deadline: .now() + .seconds(5))
    #expect(rig.owner.closingEngines == [.apple])
    feed.open()
    #expect(await rig.owner.waitForCleanups(seconds: 10))
    #expect(oldMic.ends == 1)
  }
  #endif

  @Test("the meeting's Universal route maps admission and language to the owner's resolution")
  func universalRouteWiring() async {
    func environment(admitted: Bool) -> WhisperPreviewEngineResolver.Environment {
      WhisperPreviewEngineResolver.Environment(
        artifactIdentity: "test", modelPath: "/nonexistent/model.gguf",
        isAdmitted: { admitted },
        isHeartStreaming: {
          Issue.record("the meeting route never asks about the heart at readiness")
          return true
        })
    }
    let ready = await WhisperPreviewDeliveryWiring.meetingResolver(environment(admitted: true))(
      .auto)
    guard case .ready = ready else {
      Issue.record("expected ready, got \(ready)")
      return
    }
    let missing = await WhisperPreviewDeliveryWiring.meetingResolver(environment(admitted: false))(
      .auto)
    guard case .blocked(.modelNotInstalled) = missing else {
      Issue.record("expected modelNotInstalled, got \(missing)")
      return
    }
  }

  @Test("the meeting's Universal decode waits only while a streaming dictation is under way")
  func meetingDecodeWaitsOnlyForActiveStreamingDictation() throws {
    let settings = SettingsManager(defaults: try #require(TestDefaults.suite("ew-3973-\(UUID().uuidString)")))
    settings.selectedBackend = .parakeet
    settings.useStreamingASR = true
    #expect(WhisperPreviewDeliveryWiring.heartIsStreaming(settings: settings), "control: streaming set")
    #expect(!WhisperPreviewDeliveryWiring.meetingDecodeMustWait(settings: settings, dictationActive: false))
    #expect(WhisperPreviewDeliveryWiring.meetingDecodeMustWait(settings: settings, dictationActive: true))
    settings.useStreamingASR = false
    #expect(!WhisperPreviewDeliveryWiring.meetingDecodeMustWait(settings: settings, dictationActive: true))
  }
}
