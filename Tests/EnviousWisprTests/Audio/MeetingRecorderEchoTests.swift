@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

/// #4355 PR B: meeting capture through the echo worker. When these fail, microphone audio is
/// lost, duplicated or reordered on its way through echo cleanup, a recording without call
/// sound gets a cleaned copy the final pass would use, or Stop and Quit close the file before
/// accepted audio reached it.
@Suite("Meeting recorder echo cleanup (#4355)", .tags(.productOutcome), .serialized)
@MainActor
struct MeetingRecorderEchoTests {
  typealias Fakes = MeetingRecorderTests
  typealias Echo = MeetingEchoCancellerTests

  struct Rig {
    let recorder: MeetingRecorder
    let microphone: Fakes.FakeMicrophone
    let calls: Fakes.Box<[Fakes.FakeCallSound]>
    let clock: Fakes.Clock
    let releases: Fakes.ReleaseTimer
    let folder: URL
    let executor: Echo.ManualExecutor
    let backend: Echo.FakeBackend?
    let reopenGate: Fakes.Gate
    /// The failure callback the recorder gave each call-sound source.
    let callFailures: Fakes.Box<[@Sendable (String) -> Void]>
    @MainActor var call: Fakes.FakeCallSound? { calls.value.first }
  }

  /// The real recorder with fake capture and a fake AEC backend on a manual executor; the
  /// worker reads the real monotonic clock so Stop's budget means real time.
  func rig(
    callSound: Bool = true, callSupported: Bool = true, callStartError: Error? = nil,
    backend: Echo.FakeBackend? = Echo.FakeBackend(), nativeAvailable: Bool = true
  ) throws -> Rig {
    let folder = try MeetingAudioFixture.folder("MeetingRecorderEchoTests")
    let microphone = Fakes.FakeMicrophone()
    let calls = Fakes.Box<[Fakes.FakeCallSound]>([])
    let clock = Fakes.Clock()
    let releases = Fakes.ReleaseTimer()
    let executor = Echo.ManualExecutor()
    let reopenGate = Fakes.Gate()
    let callFailures = Fakes.Box<[@Sendable (String) -> Void]>([])
    let box = OSAllocatedUnfairLock<Echo.FakeBackend?>(initialState: backend)
    var sources = MeetingRecorder.Sources(
      makeMicrophone: { microphone },
      makeCallSound: { handler, onFailure, onReport in
        guard callSupported else { return nil }
        callFailures.value.append(onFailure)
        let fake = Fakes.FakeCallSound(handler: handler, onReport: onReport)
        fake.startError = callStartError
        calls.value.append(fake)
        return fake
      },
      hostTime: { clock.now.withLock { $0 } },
      reopenDelay: { await reopenGate.pass() })
    sources.releaseScheduler = releases.scheduler
    sources.echoPumpInterval = nil
    sources.makeEchoCanceller = { recording in
      MeetingEchoCanceller(
        recording: recording,
        makeBackend: {
          guard nativeAvailable else { return nil }
          let taken: Echo.FakeBackend? = box.withLock { b in
            defer { b = nil }
            return b
          }
          return taken
        },
        now: { DispatchTime.now().uptimeNanoseconds }, schedule: executor.schedule,
        after: { _, _ in })
    }
    let recorder = MeetingRecorder(
      configuration: .init(
        meetingID: UUID(), folder: folder, captureCallSound: callSound, microphoneUID: nil,
        inputChannelByDeviceUID: [:]),
      sources: sources, onSegment: { _, _ in }, onFailure: { _, _ in })
    return Rig(
      recorder: recorder, microphone: microphone, calls: calls, clock: clock, releases: releases,
      folder: folder, executor: executor, backend: backend, reopenGate: reopenGate,
      callFailures: callFailures)
  }

  /// `count` samples of `level` on the microphone, arriving now (after the clock moved by their
  /// duration), with the same span of call sound first when `render` is set.
  func speak(_ rig: Rig, _ count: Int, level: Float = 0.25, render: Bool = true) {
    rig.clock.advance(seconds: Double(count) / 16_000)
    if render, let call = rig.call {
      let start =
        rig.clock.now.withLock { $0 }
        &- MeetingRecorder.hostTicks(
          forSeconds: Double(count) / 16_000)
      [Float](repeating: 0.1, count: count).withUnsafeBufferPointer {
        call.handler($0, start, false)
      }
    }
    rig.microphone.onSamples?([Float](repeating: level, count: count), 0.2)
  }

  func files(_ rig: Rig, prefix: String) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: rig.folder.path)
      .filter { $0.hasPrefix(prefix + "-") }.sorted()
  }

  func frames(_ rig: Rig, _ names: [String]) throws -> Int {
    try names.reduce(0) {
      $0 + Int(try AVAudioFile(forReading: rig.folder.appendingPathComponent($1)).length)
    }
  }

  @Test(
    "paired capture: every microphone sample reaches both copies once, in order; the clean close proves the set and it is chosen"
  )
  func pairedCaptureIsWholeAndChosen() async throws {
    let rig = try rig()
    let result = try await rig.recorder.start()
    #expect(result.callSound == .captured)
    #expect(result.echoProvenance == MeetingRecorder.echoProvenance)
    let bridge = try #require(rig.recorder.echoBridgeForTesting)
    // 3 s in 100 ms chunks; the worker runs between chunks, results drain on the next admission
    // or the explicit pump, as the bridge's timer does.
    for _ in 0..<30 {
      speak(rig, 1_600)
      rig.executor.runAll()
      bridge.pump()
    }
    let stopReport = await rig.recorder.stop()
    let backend = try #require(rig.backend)
    #expect(backend.captures == 300)
    #expect(backend.renders > 0)
    let raw = try files(rig, prefix: "mic")
    let cleaned = try files(rig, prefix: MeetingSegmentNaming.cleanedMicrophoneStem)
      .filter { !MeetingSegmentNaming.isCleanedProof($0) }
    #expect(try frames(rig, raw) == 48_000)
    #expect(try frames(rig, cleaned) == 48_000)
    let report = MeetingTrackRecovery.recover(folder: rig.folder)
    #expect(report.cleanedConfirmed.count == cleaned.count)
    guard
      case .cleaned(let twins, let provenance) = MeetingMicrophoneSelection.decide(
        raw: report.segments[.microphone] ?? [], report: report,
        provenance: result.echoProvenance)
    else {
      Issue.record("a clean paired recording was not chosen")
      return
    }
    #expect(provenance == MeetingRecorder.echoProvenance)
    // The fake halves what it cleans once trusted (after two metric reads, 2 s): the last
    // second of the twin is half the raw level.
    let audio = MeetingTrackAudio(
      files: twins.map { (rig.folder.appendingPathComponent($0.fileName), $0.startMs) })
    let tail = try audio.read(from: 47_000, count: 1)[0]
    #expect(abs(tail - 0.125) < 0.001)
    // #4355 telemetry, against the files: every sample offered is eligible, and passthrough is
    // exactly the samples whose cleaned copy is still the raw level (warm-up before trust).
    let echo = try #require(stopReport.echoSummary)
    let twin = try audio.read(from: 0, count: 48_000)
    let rawLevel = twin.filter { abs($0 - 0.25) < 0.001 }.count
    #expect(rawLevel > 0 && rawLevel < 48_000)
    #expect(echo.eligibleSamples == 48_000)
    #expect(echo.passthroughSamples == rawLevel)
    #expect(echo.initOutcome == .ok)
    #expect(echo.resetCount == 0 && echo.resetReason == "none")
  }

  @Test(
    "no call sound (off, unsupported, failed) or no library: raw is whole, no cleaned set can be chosen"
  )
  func withoutEchoCleanupRawIsWhole() async throws {
    struct TapFailed: Error {}
    for scenario in ["off", "unsupported", "failed", "native"] {
      let rig = try rig(
        callSound: scenario != "off", callSupported: scenario != "unsupported",
        callStartError: scenario == "failed" ? TapFailed() : nil,
        nativeAvailable: scenario != "native")
      let result = try await rig.recorder.start()
      for _ in 0..<10 {
        speak(rig, 1_600, render: scenario == "native")
        rig.executor.runAll()
        rig.recorder.pumpEchoForTesting()
      }
      let stopReport = await rig.recorder.stop()
      #expect(try frames(rig, try files(rig, prefix: "mic")) == 16_000, "\(scenario)")
      // #4355 telemetry: no call sound is a known no-reference; no library is a failed start
      // whose every eligible sample passed through.
      let echo = try #require(stopReport.echoSummary, "\(scenario)")
      switch scenario {
      case "off": #expect(echo == .noReference)
      case "native":
        // Every chunk of the recording, not only the first: a failed cleaner is a fallback.
        #expect(echo.initOutcome == .failed)
        #expect(echo.eligibleSamples == 16_000)
        #expect(echo.passthroughSamples == 16_000)
      default:
        #expect(echo.initOutcome == .noReference, "\(scenario)")
        #expect(echo.passthroughSamples == echo.eligibleSamples, "\(scenario)")
      }
      let report = MeetingTrackRecovery.recover(folder: rig.folder)
      #expect(report.cleanedConfirmed.isEmpty, "\(scenario)")
      if scenario != "native" { #expect(result.echoProvenance == nil, "\(scenario)") }
      if case .cleaned = MeetingMicrophoneSelection.decide(
        raw: report.segments[.microphone] ?? [], report: report,
        provenance: MeetingRecorder.echoProvenance)
      {
        Issue.record("\(scenario): a cleaned set was chosen")
      }
      if scenario == "off" {
        #expect(try files(rig, prefix: MeetingSegmentNaming.cleanedMicrophoneStem).isEmpty)
      }
    }
  }

  @Test(
    "results reach the writer with no further microphone buffer: the timer's pump alone delivers them"
  )
  func pumpDeliversWithoutAnotherBuffer() async throws {
    let rig = try rig()
    _ = try await rig.recorder.start()
    speak(rig, 1_600)
    rig.executor.runAll()
    let writer = try #require(rig.recorder.microphoneWriterForTesting)
    rig.releases.fire(upTo: .max)
    await writer.waitUntilWritten()
    #expect(writer.currentHealth.framesWritten == 0)
    rig.recorder.pumpEchoForTesting()
    await writer.waitUntilWritten()
    rig.releases.fire(upTo: .max)
    await writer.waitUntilWritten()
    #expect(writer.currentHealth.framesWritten == 1_600)
    await rig.recorder.stop()
  }

  @Test(
    "Stop and Quit while AEC3 is parked in a call settle raw within the budget; every sample is written once"
  )
  func stopAndQuitWhileNativeIsParked() async throws {
    for quit in [false, true] {
      let arrived = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      let backend = Echo.FakeBackend()
      backend.onCapture = {
        arrived.signal()
        _ = release.wait(timeout: .now() + 10)  // deadline-fallback: released below
      }
      let queue = DispatchQueue(label: "test.recorder.echo.worker")
      let folder = try MeetingAudioFixture.folder("MeetingRecorderEchoParked")
      let microphone = Fakes.FakeMicrophone()
      let clock = Fakes.Clock()
      let box = OSAllocatedUnfairLock<Echo.FakeBackend?>(initialState: backend)
      var sources = MeetingRecorder.Sources(
        makeMicrophone: { microphone },
        makeCallSound: { handler, _, onReport in
          Fakes.FakeCallSound(handler: handler, onReport: onReport)
        },
        hostTime: { clock.now.withLock { $0 } }, reopenDelay: {})
      sources.echoPumpInterval = nil
      sources.makeEchoCanceller = { recording in
        MeetingEchoCanceller(
          recording: recording,
          makeBackend: {
            let taken: Echo.FakeBackend? = box.withLock { b in
              defer { b = nil }
              return b
            }
            return taken
          },
          now: { DispatchTime.now().uptimeNanoseconds },
          schedule: { work in queue.async(execute: work) }, after: { _, _ in })
      }
      let recorder = MeetingRecorder(
        configuration: .init(
          meetingID: UUID(), folder: folder, captureCallSound: true, microphoneUID: nil,
          inputChannelByDeviceUID: [:]),
        sources: sources, onSegment: { _, _ in }, onFailure: { _, _ in })
      _ = try await recorder.start()
      for _ in 0..<5 {
        clock.advance(seconds: 0.1)
        microphone.onSamples?([Float](repeating: 0.25, count: 1_600), 0.2)
      }
      #expect(blockThread(on: arrived))  // deadline-fallback: bounded (10 s)
      let started = Date()
      if quit {
        recorder.stopForQuit(deadline: .now() + .seconds(2))
      } else {
        await recorder.stop()
      }
      #expect(Date().timeIntervalSince(started) < 5)
      release.signal()
      let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
      let raw = names.filter { $0.hasPrefix("mic-") }.sorted()
      let total = try raw.reduce(0) {
        $0 + Int(try AVAudioFile(forReading: folder.appendingPathComponent($1)).length)
      }
      #expect(total == 8_000, "quit: \(quit)")
      let report = MeetingTrackRecovery.recover(folder: folder)
      #expect(report.problems.isEmpty)
    }
  }

  @Test(
    "the call sound ending mid-meeting (its failure, a layout stop, a failed rebuild) ends trust: later audio is raw in the cleaned copy, earlier cleaning stays"
  )
  func callSoundLossEndsTrust() async throws {
    for loss in ["failure", "stopped_layout", "rebuild_failed"] {
      let rig = try rig()
      let result = try await rig.recorder.start()
      // 3 s paired: trusted after two metric reads (2 s), so the fake halves the last second.
      for _ in 0..<30 {
        speak(rig, 1_600)
        rig.executor.runAll()
        rig.recorder.pumpEchoForTesting()
      }
      if loss == "failure" {
        let failed = try #require(rig.callFailures.value.first)
        failed("stopped")
      } else {
        rig.call?.onReport(
          CallSoundChangeReport(
            outcome: loss, reason: loss == "stopped_layout" ? nil : "output_device",
            configuredRateHz: 48_000, nominalRateHz: 48_000, measuredRateBucket: nil,
            outputTransport: nil))
      }
      // 1 s more microphone with no call sound.
      for _ in 0..<10 {
        speak(rig, 1_600, render: false)
        rig.executor.runAll()
        rig.recorder.pumpEchoForTesting()
      }
      await rig.recorder.stop()
      let report = MeetingTrackRecovery.recover(folder: rig.folder)
      guard
        case .cleaned(let twins, _) = MeetingMicrophoneSelection.decide(
          raw: report.segments[.microphone] ?? [], report: report,
          provenance: result.echoProvenance)
      else {
        Issue.record("\(loss): the cleaned copy was not chosen")
        continue
      }
      let audio = MeetingTrackAudio(
        files: twins.map { (rig.folder.appendingPathComponent($0.fileName), $0.startMs) })
      let before = try audio.read(from: 47_000, count: 1)[0]
      let after = try audio.read(from: 63_000, count: 1)[0]
      #expect(abs(before - 0.125) < 0.001, "\(loss): cleaned before")
      #expect(abs(after - 0.25) < 0.001, "\(loss): raw after")
      let counters = try #require(rig.recorder.echoBridgeForTesting).countersForTesting
      #expect(counters.resetRequests[.callSoundLost] == 1, "\(loss)")
      #expect(counters.resetCauses[.callLost] == 1, "\(loss): the reset ran")
    }
  }

  @Test(
    "Quit during an unfinished Stop: Quit takes over at its own deadline, every sample is written once"
  )
  func quitDuringUnfinishedStop() async throws {
    let arrived = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let backend = Echo.FakeBackend()
    backend.onCapture = {
      arrived.signal()
      _ = release.wait(timeout: .now() + 10)  // deadline-fallback: released below
    }
    let queue = DispatchQueue(label: "test.recorder.echo.worker.overlap")
    let folder = try MeetingAudioFixture.folder("MeetingRecorderEchoOverlap")
    let microphone = Fakes.FakeMicrophone()
    let clock = Fakes.Clock()
    let box = OSAllocatedUnfairLock<Echo.FakeBackend?>(initialState: backend)
    var sources = MeetingRecorder.Sources(
      makeMicrophone: { microphone },
      makeCallSound: { handler, _, onReport in
        Fakes.FakeCallSound(handler: handler, onReport: onReport)
      },
      hostTime: { clock.now.withLock { $0 } }, reopenDelay: {})
    sources.echoPumpInterval = nil
    sources.makeEchoCanceller = { recording in
      MeetingEchoCanceller(
        recording: recording,
        makeBackend: {
          let taken: Echo.FakeBackend? = box.withLock { b in
            defer { b = nil }
            return b
          }
          return taken
        },
        now: { DispatchTime.now().uptimeNanoseconds },
        schedule: { work in queue.async(execute: work) }, after: { _, _ in })
    }
    let recorder = MeetingRecorder(
      configuration: .init(
        meetingID: UUID(), folder: folder, captureCallSound: true, microphoneUID: nil,
        inputChannelByDeviceUID: [:]),
      sources: sources, onSegment: { _, _ in }, onFailure: { _, _ in })
    _ = try await recorder.start()
    for _ in 0..<5 {
      clock.advance(seconds: 0.1)
      microphone.onSamples?([Float](repeating: 0.25, count: 1_600), 0.2)
    }
    #expect(blockThread(on: arrived))  // deadline-fallback: bounded (10 s)
    // Whatever happens below, the parked native call is released when the test ends.
    defer { release.signal() }
    let bridge = try #require(recorder.echoBridgeForTesting)
    let began = DispatchSemaphore(value: 0)
    bridge.onSettleBeganForTesting = { began.signal() }
    let started = Date()
    let stopping = Task { await recorder.stop() }
    // Waited off the main actor, so Stop (main actor) can reach its settle meanwhile.
    let stopSettling = await Task.detached { blockThread(on: began) }.value  // deadline-fallback: bounded (10 s)
    try #require(stopSettling, "Stop never began settling the echo worker")
    // Stop owns the settle and waits on the parked worker (its half of 1 s); Quit's half of
    // 400 ms ends first, so Quit hands the owed audio over raw and closes the files.
    let quitReport = recorder.stopForQuit(deadline: .now() + .milliseconds(400))
    let stopReport = await stopping.value
    #expect(Date().timeIntervalSince(started) < 5)
    #expect(stopReport == quitReport)
    // #4355 telemetry: Quit's raw takeover counts every owed sample once, as passthrough.
    let echo = try #require(quitReport.echoSummary)
    #expect(echo.eligibleSamples == 8_000)
    #expect(echo.passthroughSamples == 8_000)
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    let raw = names.filter { $0.hasPrefix("mic-") }.sorted()
    let total = try raw.reduce(0) {
      $0 + Int(try AVAudioFile(forReading: folder.appendingPathComponent($1)).length)
    }
    #expect(total == 8_000)
    #expect(MeetingTrackRecovery.recover(folder: folder).problems.isEmpty)
  }

  @Test(
    "a reset that ran is in the frozen summary even when the next native call parks through Stop"
  )
  func resetCountedBeforeAParkedCapture() async throws {
    final class Hook: @unchecked Sendable {
      // Test-only: touched on the worker queue inside capture, and once by the test before start.
      var park: (() -> Void)?
    }
    let arrived = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let backend = Echo.FakeBackend()
    let hook = Hook()
    // Re-arms on every capture until one follows a reset; that one parks.
    hook.park = { [unowned backend] in
      if backend.resets > 0 {
        arrived.signal()
        _ = release.wait(timeout: .now() + 10)  // deadline-fallback: released by the defer
      } else {
        backend.onCapture = hook.park
      }
    }
    backend.onCapture = hook.park
    let queue = DispatchQueue(label: "test.recorder.echo.worker.reset")
    let folder = try MeetingAudioFixture.folder("MeetingRecorderEchoResetParked")
    let microphone = Fakes.FakeMicrophone()
    let clock = Fakes.Clock()
    let calls = Fakes.Box<[Fakes.FakeCallSound]>([])
    let box = OSAllocatedUnfairLock<Echo.FakeBackend?>(initialState: backend)
    var sources = MeetingRecorder.Sources(
      makeMicrophone: { microphone },
      makeCallSound: { handler, _, onReport in
        let fake = Fakes.FakeCallSound(handler: handler, onReport: onReport)
        calls.value.append(fake)
        return fake
      },
      hostTime: { clock.now.withLock { $0 } }, reopenDelay: {})
    sources.echoPumpInterval = nil
    sources.makeEchoCanceller = { recording in
      MeetingEchoCanceller(
        recording: recording,
        makeBackend: {
          let taken: Echo.FakeBackend? = box.withLock { b in
            defer { b = nil }
            return b
          }
          return taken
        },
        now: { DispatchTime.now().uptimeNanoseconds },
        schedule: { work in queue.async(execute: work) }, after: { _, _ in })
    }
    let recorder = MeetingRecorder(
      configuration: .init(
        meetingID: UUID(), folder: folder, captureCallSound: true, microphoneUID: nil,
        inputChannelByDeviceUID: [:]),
      sources: sources, onSegment: { _, _ in }, onFailure: { _, _ in })
    _ = try await recorder.start()
    clock.advance(seconds: 0.1)
    microphone.onSamples?([Float](repeating: 0.25, count: 1_600), 0.2)
    try #require(calls.value.first).onReport(
      CallSoundChangeReport(
        outcome: "rebuilt", reason: "output_device", configuredRateHz: 48_000,
        nominalRateHz: 48_000, measuredRateBucket: nil, outputTransport: nil))
    clock.advance(seconds: 0.1)
    microphone.onSamples?([Float](repeating: 0.25, count: 1_600), 0.2)
    let parked = await Task.detached { blockThread(on: arrived) }.value  // deadline-fallback: bounded (10 s)
    try #require(parked, "no capture followed the reset")
    let report = await recorder.stop()
    let echo = try #require(report.echoSummary)
    #expect(echo.resetCount == 1)
    #expect(echo.resetCauses == [.callRebuild: 1])
    #expect(echo.eligibleSamples == 3_200)
    // The parked call finishing later changes nothing frozen: the worker queue is serial, so
    // once an empty block runs on it, the parked drain (and its late result) has finished.
    release.signal()
    queue.sync {}
    let bridge = try #require(recorder.echoBridgeForTesting)
    #expect(bridge.summary == echo)
  }

  @Test("a microphone reopen and a call-sound rebuild restart AEC3")
  func reopenAndRebuildReset() async throws {
    let rig = try rig()
    _ = try await rig.recorder.start()
    speak(rig, 1_600)
    rig.executor.runAll()
    let backend = try #require(rig.backend)
    #expect(backend.resets == 0)
    // A rebuild the tap reports.
    rig.call?.onReport(
      CallSoundChangeReport(
        outcome: "rebuilt", reason: "output_device", configuredRateHz: 48_000,
        nominalRateHz: 48_000,
        measuredRateBucket: nil, outputTransport: nil))
    speak(rig, 1_600)
    rig.executor.runAll()
    #expect(backend.resets == 1)
    // The microphone is lost and reopened: its first buffer starts a new run.
    rig.microphone.onInterrupted?(.deviceRemoved)
    #expect(await rig.reopenGate.waitUntilParked())
    rig.reopenGate.open()
    await rig.recorder.reopenTaskForTesting?.value
    speak(rig, 1_600)
    rig.executor.runAll()
    #expect(backend.resets == 2)
    let stopReport = await rig.recorder.stop()
    // #4355 telemetry: the resets that ran, with their causes, not the requests.
    let echo = try #require(stopReport.echoSummary)
    #expect(echo.resetCount == 2)
    #expect(echo.resetCauses == [.callRebuild: 1, .micRun: 1])
    #expect(echo.resetReason == "multiple")
  }
}
