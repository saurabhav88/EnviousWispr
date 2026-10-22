@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

/// #3972 R2, R14, R18, R27: when these fail, a meeting records nothing, records after the user
/// pressed Stop, keeps a microphone open, mislabels why call sound is missing, loses a quit's
/// last minute, or places audio at the wrong time.
@Suite("MeetingRecorder", .tags(.productOutcome), .serialized)
@MainActor
struct MeetingRecorderTests {

  // MARK: - Fakes

  /// A one-shot pause a fake can park in; the test waits (bounded) until something is parked,
  /// then lets it go. `open()` also releases anything parked, for cleanup.
  @MainActor
  final class Gate {
    private var parked: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Bool, Never>] = []
    private var opened = false

    func pass() async {
      guard !opened else { return }
      await withCheckedContinuation { continuation in
        parked = continuation
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
      }
    }

    /// True once something is parked; false if nothing parked within `timeout`.
    func waitUntilParked(timeout: Duration = .seconds(10)) async -> Bool {
      guard parked == nil else { return true }
      return await withCheckedContinuation { continuation in
        entryWaiters.append(continuation)
        Task { @MainActor in
          // deadline-fallback: a regression that never parks fails the test instead of hanging.
          try? await Task.sleep(for: timeout)
          self.expire()
        }
      }
    }

    private func expire() {
      let waiters = entryWaiters
      entryWaiters.removeAll()
      waiters.forEach { $0.resume(returning: false) }
    }

    func open() {
      opened = true
      parked?.resume()
      parked = nil
    }
  }

  @MainActor
  final class FakeMicrophone: MeetingMicrophoneSource {
    var onSamples: (@Sendable ([Float], Float) -> Void)?
    var onInterrupted: ((EngineInterruptionCause) -> Void)?
    var onStalled: (() -> Void)?
    var openTargets: [String?] = []
    var openGate: Gate?
    var beginGate: Gate?
    var openError: Error?
    var preRoll: [Float]?
    var stopCount = 0
    var boundUID = "BuiltInMicrophoneDevice"

    func open(targetUID: String?, inputChannelByDeviceUID: [String: Int]) async throws -> String? {
      openTargets.append(targetUID)
      if let openGate { await openGate.pass() }
      if let openError { throw openError }
      return boundUID
    }

    func beginDelivery() async throws {
      if let preRoll { onSamples?(preRoll, 0.1) }
      if let beginGate { await beginGate.pass() }
    }

    func stopNow() { stopCount += 1 }
  }

  final class FakeCallSound: MeetingCallSoundSource {
    var startError: Error?
    var stopCount = 0
    let handler: CallSoundPipeline.SampleHandler
    init(handler: @escaping CallSoundPipeline.SampleHandler) { self.handler = handler }
    func start() throws { if let startError { throw startError } }
    func stop() { stopCount += 1 }
    var currentLevel: Float { 0 }
  }

  final class Clock: Sendable {
    let now = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000)
    func advance(seconds: Double) {
      now.withLock { $0 += AudioConvertNanosToHostTime(UInt64(seconds * 1_000_000_000)) }
    }
  }

  final class Segments: Sendable {
    let list = OSAllocatedUnfairLock<[(MeetingTrackKind, MeetingSegmentInfo)]>(initialState: [])
    func of(_ track: MeetingTrackKind) -> [MeetingSegmentInfo] {
      list.withLock { $0.filter { $0.0 == track }.map(\.1) }
    }
  }

  @MainActor
  final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
  }

  private struct Rig {
    let recorder: MeetingRecorder
    let microphones: [FakeMicrophone]
    let callBox: Box<[FakeCallSound]>
    let clock: Clock
    let segments: Segments
    let failureBox: Box<[MeetingTrackKind]>
    /// Yields each failure the recorder reports, in order.
    let failureSignal: AsyncStream<MeetingTrackKind>
    let reopenGate: Gate
    let folder: URL

    @MainActor func calls() -> [FakeCallSound] { callBox.value }
    @MainActor func failures() -> [MeetingTrackKind] { failureBox.value }
  }

  private func rig(
    microphones count: Int = 1, callSound: Bool = true, callSupported: Bool = true,
    callStartError: Error? = nil, folder existing: URL? = nil
  ) throws -> Rig {
    let folder = try existing ?? MeetingAudioFixture.folder("MeetingRecorderTests")
    let microphones = (0..<count).map { _ in FakeMicrophone() }
    let next = Box(0)
    let callBox = Box<[FakeCallSound]>([])
    let failureBox = Box<[MeetingTrackKind]>([])
    let (failureSignal, failureContinuation) = AsyncStream<MeetingTrackKind>.makeStream()
    let clock = Clock()
    let segments = Segments()
    let reopenGate = Gate()
    let sources = MeetingRecorder.Sources(
      makeMicrophone: {
        defer { next.value += 1 }
        return microphones[min(next.value, microphones.count - 1)]
      },
      makeCallSound: { handler, _ in
        guard callSupported else { return nil }
        let fake = FakeCallSound(handler: handler)
        fake.startError = callStartError
        callBox.value.append(fake)
        return fake
      },
      hostTime: { clock.now.withLock { $0 } },
      reopenDelay: { await reopenGate.pass() })
    let recorder = MeetingRecorder(
      configuration: .init(
        meetingID: UUID(), folder: folder, captureCallSound: callSound,
        microphoneUID: "Chosen", inputChannelByDeviceUID: [:]),
      sources: sources,
      onSegment: { track, info in segments.list.withLock { $0.append((track, info)) } },
      onFailure: { track, _ in
        failureBox.value.append(track)
        failureContinuation.yield(track)
      })
    return Rig(
      recorder: recorder, microphones: microphones, callBox: callBox, clock: clock,
      segments: segments, failureBox: failureBox, failureSignal: failureSignal,
      reopenGate: reopenGate, folder: folder)
  }

  /// Delivers `seconds` of microphone audio as if it arrived now (after advancing the clock by
  /// its duration plus `late`).
  private func speak(_ mic: FakeMicrophone, _ clock: Clock, seconds: Double, late: Double = 0) {
    clock.advance(seconds: seconds + late)
    mic.onSamples?([Float](repeating: 0.1, count: Int(seconds * 16_000)), 0.2)
  }

  // MARK: - Start and stop

  @Test("start then stop records both tracks to finished files and reports both finalized")
  func startStopRecordsBothTracks() async throws {
    let r = try rig()
    let result = try await r.recorder.start()
    #expect(result == .init(microphone: .captured, callSound: .captured))
    #expect(r.recorder.boundMicrophoneUID == "BuiltInMicrophoneDevice")
    #expect(r.microphones[0].openTargets == ["Chosen"])
    speak(r.microphones[0], r.clock, seconds: 1)
    let call = [Float](repeating: 0.2, count: 16_000)
    call.withUnsafeBufferPointer { r.calls()[0].handler($0, r.recorder.anchor, false) }
    let report = await r.recorder.stop()
    #expect(report == .init(microphone: .finalized, callSound: .finalized))
    #expect(r.segments.of(.microphone).map(\.frameCount) == [16_000])
    #expect(r.segments.of(.callSound).map(\.frameCount) == [16_000])
    #expect(r.microphones[0].stopCount == 1)
    #expect(r.calls()[0].stopCount == 1)
    #expect(await r.recorder.stop() == report, "a second stop returns the first report")
    await #expect(throws: MeetingRecorder.RecorderError.alreadyStarted) {
      _ = try await r.recorder.start()
    }
  }

  @Test("a microphone that fails to open is released, its file closed, and nothing is recorded")
  func microphoneFailureReleasesEverything() async throws {
    let r = try rig()
    r.microphones[0].openError = AudioError.formatCreationFailed(source: "test")
    await #expect(throws: (any Error).self) { _ = try await r.recorder.start() }
    #expect(r.microphones[0].stopCount == 1)
    #expect(r.microphones[0].onSamples == nil)
    #expect(r.calls().isEmpty, "call sound never starts without a microphone")
    #expect(try FileManager.default.contentsOfDirectory(atPath: r.folder.path).isEmpty)
  }

  @Test("a stop while the microphone is opening ends the start and the late open is released")
  func stopDuringOpen() async throws {
    let r = try rig()
    let gate = Gate()
    r.microphones[0].openGate = gate
    let start = Task { try await r.recorder.start() }
    defer { gate.open() }
    #expect(await gate.waitUntilParked(), "the fake was never entered")
    let report = await r.recorder.stop()
    gate.open()
    await #expect(throws: MeetingRecorder.RecorderError.stoppedDuringStart) {
      _ = try await start.value
    }
    #expect(r.microphones[0].stopCount == 1)
    #expect(r.microphones[0].onSamples == nil, "no live source is left installed")
    #expect(report.microphone == .finalized)
    #expect(r.calls().isEmpty)
  }

  @Test("a stop while delivery is starting ends the start and releases the source")
  func stopDuringBeginDelivery() async throws {
    let r = try rig()
    let gate = Gate()
    r.microphones[0].beginGate = gate
    let start = Task { try await r.recorder.start() }
    defer { gate.open() }
    #expect(await gate.waitUntilParked(), "the fake was never entered")
    await r.recorder.stop()
    gate.open()
    await #expect(throws: MeetingRecorder.RecorderError.stoppedDuringStart) {
      _ = try await start.value
    }
    #expect(r.microphones[0].stopCount == 1)
    #expect(r.microphones[0].onSamples == nil)
  }

  @Test("a microphone lost while opening fails the start and is released, never reported captured")
  func lossDuringOpenFailsStart() async throws {
    let r = try rig()
    let gate = Gate()
    r.microphones[0].openGate = gate
    defer { gate.open() }
    let start = Task { try await r.recorder.start() }
    #expect(await gate.waitUntilParked(), "the fake was never entered")
    r.microphones[0].onInterrupted?(.deviceRemoved)
    gate.open()
    await #expect(throws: MeetingRecorder.RecorderError.microphoneUnavailable("device_removed")) {
      _ = try await start.value
    }
    #expect(r.microphones[0].stopCount == 1)
    #expect(r.calls().isEmpty)
  }

  @Test("a microphone that stalls while delivery starts fails the start and is released")
  func stallDuringDeliveryFailsStart() async throws {
    let r = try rig()
    let gate = Gate()
    r.microphones[0].beginGate = gate
    defer { gate.open() }
    let start = Task { try await r.recorder.start() }
    #expect(await gate.waitUntilParked(), "the fake was never entered")
    r.microphones[0].onStalled?()
    gate.open()
    await #expect(throws: MeetingRecorder.RecorderError.microphoneUnavailable("no_buffers")) {
      _ = try await start.value
    }
    #expect(r.microphones[0].stopCount == 1)
    #expect(r.microphones[0].onSamples == nil)
  }

  /// Feeds two 100 ms runs of steady 0.25 through a real pipeline into the recorder's call
  /// writer, the second starting `gapMs` after the first ends, and returns the read-back track.
  private func callTrack(gapMs: Double) async throws -> [Float] {
    let r = try rig(callSound: true)
    _ = try await r.recorder.start()
    let pipeline = CallSoundPipeline(onSamples: r.calls()[0].handler)
    try pipeline.configure(.init(sampleRate: 48_000))
    pipeline.setAccepting(true)
    let anchor = r.recorder.anchor
    for startSeconds in [0.0, 0.1 + gapMs / 1_000] {
      var samples = [Float](repeating: 0.25, count: 4_800)
      let list = AudioBufferList.allocate(maximumBuffers: 1)
      samples.withUnsafeMutableBufferPointer { memory in
        list[0] = AudioBuffer(
          mNumberChannels: 1, mDataByteSize: UInt32(memory.count * 4),
          mData: UnsafeMutableRawPointer(memory.baseAddress))
        pipeline.ingest(
          UnsafePointer(list.unsafeMutablePointer),
          hostTime: anchor + CallSoundPipeline.ticks(seconds: startSeconds))
      }
      free(list.unsafeMutablePointer)
    }
    pipeline.drain()
    pipeline.finishRun()
    await r.recorder.stop()
    let files = r.segments.of(.callSound).map {
      (r.folder.appendingPathComponent($0.fileName), $0.startMs)
    }
    let audio = MeetingTrackAudio(files: files)
    return try audio.read(from: 0, count: audio.endSample)
  }

  @Test(
    "a call-sound break the pipeline detects (over 4 ms) stays on disk at its true place",
    arguments: [4.5, 5.0, 50.0])
  func callSoundBreakSurvivesToDisk(gapMs: Double) async throws {
    let track = try await callTrack(gapMs: gapMs)
    let firstRise = try #require(track.firstIndex { $0 >= 0.125 })
    // The second run's rise: the first upward crossing well after the first run ends.
    let searchFrom = firstRise + 1_500
    let secondRise = try #require(
      (searchFrom..<track.count).first { track[$0 - 1] < 0.125 && track[$0] >= 0.125 },
      "no silent break before the second run (gap \(gapMs) ms)")
    let expected = firstRise + 1_600 + Int(gapMs * 16)
    #expect(abs(secondRise - expected) <= 16, "gap \(gapMs) ms: at \(secondRise), expected \(expected)")
  }

  @Test("a call-sound break of 3 ms (within the pipeline's 4 ms tolerance) is joined, by contract")
  func callSoundJitterIsJoined() async throws {
    let track = try await callTrack(gapMs: 3)
    let firstRise = try #require(track.firstIndex { $0 >= 0.125 })
    // 2 × 4,800 frames at 48 kHz: every one of the 3,200 output samples, none held back.
    #expect(track.count == 3_200, "track holds \(track.count) samples")
    try #require(track.count >= firstRise + 3_000)
    #expect(track[(firstRise + 200)..<(firstRise + 3_000)].allSatisfy { $0 >= 0.125 })
  }

  @Test("audio handed over inside delivery start (pre-roll) is not recorded or backdated")
  func preRollIsNotRecorded() async throws {
    let r = try rig(callSound: false)
    r.microphones[0].preRoll = [Float](repeating: 0.3, count: 1_600)
    _ = try await r.recorder.start()
    speak(r.microphones[0], r.clock, seconds: 0.5)
    await r.recorder.stop()
    #expect(r.recorder.microphoneSourceHealth.framesNotAdmitted == 1_600)
    #expect(r.segments.of(.microphone).map(\.frameCount) == [8_000])
  }

  @Test("audio arriving after stop is not recorded")
  func lateSamplesAreNotRecorded() async throws {
    let r = try rig(callSound: false)
    _ = try await r.recorder.start()
    let late = try #require(r.microphones[0].onSamples)
    speak(r.microphones[0], r.clock, seconds: 0.5)
    await r.recorder.stop()
    late([Float](repeating: 0.1, count: 800), 0.1)
    #expect(r.segments.of(.microphone).map(\.frameCount) == [8_000])
    #expect(r.recorder.microphoneSourceHealth.framesNotAdmitted == 800)
  }

  @Test("call sound: off, unsupported and a failed start each say so; a failure is never 'denied'")
  func callSoundStatuses() async throws {
    let off = try rig(callSound: false)
    #expect(try await off.recorder.start().callSound == .off)
    await off.recorder.stop()
    let unsupported = try rig(callSupported: false)
    #expect(try await unsupported.recorder.start().callSound == .unsupported)
    await unsupported.recorder.stop()
    let failed = try rig(callStartError: CocoaError(.featureUnsupported))
    let result = try await failed.recorder.start()
    #expect(result == .init(microphone: .captured, callSound: .failed))
    #expect(await failed.recorder.stop().callSound == nil)
  }

  // DEBUG only: these wait on the recorder's reopen task through a test seam.
  #if DEBUG
  // MARK: - Microphone loss

  @Test("a lost microphone reopens on the system default after the pause, with a counted gap")
  func lostMicrophoneReopensOnDefault() async throws {
    let r = try rig(microphones: 2, callSound: false)
    _ = try await r.recorder.start()
    speak(r.microphones[0], r.clock, seconds: 1)
    r.microphones[0].onInterrupted?(.deviceRemoved)
    #expect(r.microphones[0].stopCount == 1)
    defer { r.reopenGate.open() }
    #expect(await r.reopenGate.waitUntilParked(), "the reopen never paused")
    r.clock.advance(seconds: 3)
    r.reopenGate.open()
    await r.recorder.reopenTaskForTesting?.value
    #expect(r.microphones[1].openTargets == [nil], "reopens on the system default")
    #expect(r.recorder.microphoneSourceHealth.reopens == 1)
    speak(r.microphones[1], r.clock, seconds: 1)
    await r.recorder.stop()
    #expect(r.segments.of(.microphone).count == 2)
    #expect(r.recorder.microphoneHealth?.gaps == 1)
    #expect(r.microphones[1].stopCount == 1)
  }

  @Test("a microphone that stops delivering while recording is replaced and the stall counted")
  func stallWhileRecordingReopens() async throws {
    let r = try rig(microphones: 2, callSound: false)
    _ = try await r.recorder.start()
    r.microphones[0].onStalled?()
    #expect(r.microphones[0].stopCount == 1)
    defer { r.reopenGate.open() }
    #expect(await r.reopenGate.waitUntilParked(), "the reopen never paused")
    r.reopenGate.open()
    await r.recorder.reopenTaskForTesting?.value
    #expect(r.recorder.microphoneSourceHealth.stalls == 1)
    #expect(r.recorder.microphoneSourceHealth.reopens == 1)
    #expect(r.microphones[1].openTargets == [nil])
    await r.recorder.stop()
  }

  @Test("a stop during the reopen pause cancels the reopen: no microphone opens again")
  func stopCancelsReopen() async throws {
    let r = try rig(microphones: 2, callSound: false)
    _ = try await r.recorder.start()
    r.microphones[0].onInterrupted?(.engineLost)
    defer { r.reopenGate.open() }
    #expect(await r.reopenGate.waitUntilParked(), "the reopen never paused")
    let reopen = r.recorder.reopenTaskForTesting
    await r.recorder.stop()
    r.reopenGate.open()
    await reopen?.value
    #expect(r.microphones[1].openTargets.isEmpty)
  }
  #endif

  // MARK: - Writer outcomes

  @Test(
    "a microphone file failure is reported once, and stop reports it failed",
    .timeLimit(.minutes(1)))
  func writerFailureReportedOnce() async throws {
    let folder = try MeetingAudioFixture.folder("MeetingRecorderTests")
    let r = try rig(callSound: false, folder: folder)
    _ = try await r.recorder.start()
    // Unlistable folder: the writer cannot tell which indexes are free (C2a).
    try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }
    speak(r.microphones[0], r.clock, seconds: 0.5)
    speak(r.microphones[0], r.clock, seconds: 0.5)
    let report = await r.recorder.stop()
    #expect(report.microphone == .failed)
    // The failure reaches the owner through a MainActor hop; wait for that signal.
    var failures = r.failureSignal.makeAsyncIterator()
    #expect(await failures.next() == .microphone)
    #expect(r.failures() == [.microphone])
  }

  @Test("quit stops the microphone first and closes both files against one deadline")
  func quitStopsSourcesThenCloses() async throws {
    let r = try rig()
    _ = try await r.recorder.start()
    speak(r.microphones[0], r.clock, seconds: 0.5)
    let report = r.recorder.stopForQuit(deadline: .now() + .seconds(5))
    #expect(r.microphones[0].stopCount == 1)
    #expect(r.calls()[0].stopCount == 1)
    #expect(report == .init(microphone: .finalized, callSound: .finalized))
    #expect(r.segments.of(.microphone).map(\.frameCount) == [8_000])
  }

  // MARK: - Timing (R27)

  @Test("a late burst within 1.5 s stays contiguous; a longer stall starts a segment at its time")
  func arrivalTimingRules() async throws {
    let r = try rig(callSound: false)
    _ = try await r.recorder.start()
    let mic = r.microphones[0]
    speak(mic, r.clock, seconds: 1)  // stamped 0 s
    speak(mic, r.clock, seconds: 1, late: 0.3)  // arrives 0.3 s late: same segment
    speak(mic, r.clock, seconds: 1, late: 3)  // a 3 s stall: new segment
    await r.recorder.stop()
    let segments = r.segments.of(.microphone)
    #expect(segments.map(\.frameCount) == [32_000, 16_000])
    #expect(segments.first?.startMs == 0)
    #expect(abs((segments.last?.startMs ?? 0) - 5_300) <= 1)
    #expect(r.recorder.microphoneHealth?.gaps == 1)
  }

  @Test("150 steady 0.1 s chunks stay one contiguous segment with nothing dropped")
  func longSteadyProgression() async throws {
    let r = try rig(callSound: false)
    _ = try await r.recorder.start()
    // 15 s: within the writer's 20 s handoff, since this test hands audio over instantly.
    for _ in 0..<150 { speak(r.microphones[0], r.clock, seconds: 0.1) }
    await r.recorder.stop()
    let segments = r.segments.of(.microphone)
    #expect(segments.map(\.frameCount) == [240_000])
    #expect(segments.first?.startMs == 0)
    #expect(r.recorder.microphoneHealth?.gaps == 0)
    #expect(r.recorder.microphoneHealth?.droppedFrames == 0)
  }

  // MARK: - Real microphone

  nonisolated static func authorizedBuiltInMicrophoneUID() -> String? {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return nil }
    guard case .success(let candidates, _) = AudioDeviceEnumerator.inputDeviceSnapshot()
    else { return nil }
    return candidates.first {
      $0.rawTransport == kAudioDeviceTransportTypeBuiltIn && !$0.uid.isEmpty
    }?.uid
  }

  @Test(
    "the real recorder writes a readable, non-silent microphone file from the built-in mic",
    .tags(.realBoundary),
    .enabled(if: MeetingRecorderTests.authorizedBuiltInMicrophoneUID() != nil),
    .timeLimit(.minutes(1)))
  func realRecorderWritesReadableFile() async throws {
    let uid = try #require(Self.authorizedBuiltInMicrophoneUID())
    let folder = try MeetingAudioFixture.folder("MeetingRecorderTests-real")
    let segments = Segments()
    let recorder = MeetingRecorder(
      configuration: .init(
        meetingID: UUID(), folder: folder, captureCallSound: false, microphoneUID: uid,
        inputChannelByDeviceUID: [:]),
      onSegment: { track, info in segments.list.withLock { $0.append((track, info)) } },
      onFailure: { _, _ in })
    _ = try await recorder.start()
    #expect(recorder.boundMicrophoneUID == uid)
    // test-fixture-timer: a live observation window, not a completion signal.
    try await Task.sleep(for: .seconds(1))
    let report = await recorder.stop()
    #expect(report.microphone == .finalized)
    let file = try #require(segments.of(.microphone).first)
    let decoded = try MeetingAudioFixture.decode(folder.appendingPathComponent(file.fileName))
    #expect(decoded.count > 8_000)
    #expect(decoded.contains { abs($0) > 0.000_001 }, "the built-in microphone gave only zero")
  }
}
