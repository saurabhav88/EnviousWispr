#if DEBUG
@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

/// #4355 PR B: the recorder's echo wiring across the real native and file boundaries. When this
/// fails, the shipped echo cleaner is not reached from meeting capture, or its cleaned copy does
/// not reach the files, the proof and the final pass's choice. Capture is injected (a fake
/// microphone and call sound); hardware and a live call are the Live UAT's.
@Suite(
  "Meeting recorder echo cleanup, real library and files (#4355)",
  .tags(.productOutcome, .realBoundary), .realBoundaryRun, .serialized)
@MainActor
struct MeetingRecorderEchoRealBoundaryTests {
  typealias Fakes = MeetingRecorderTests

  @Test(
    "a 40 ms half-level echo of the call sound is removed from the cleaned copy the final pass chooses"
  )
  func shippedLibraryThroughTheRecorder() async throws {
    let folder = try MeetingAudioFixture.folder("MeetingRecorderEchoReal")
    let microphone = Fakes.FakeMicrophone()
    let calls = Fakes.Box<[Fakes.FakeCallSound]>([])
    let clock = Fakes.Clock()
    var sources = MeetingRecorder.Sources(
      makeMicrophone: { microphone },
      makeCallSound: { handler, _, onReport in
        let fake = Fakes.FakeCallSound(handler: handler, onReport: onReport)
        calls.value.append(fake)
        return fake
      },
      hostTime: { clock.now.withLock { $0 } }, reopenDelay: {})
    // The production worker (real library on its own queue) and the production pump timer.
    sources.echoPumpInterval = .milliseconds(10)
    let recorder = MeetingRecorder(
      configuration: .init(
        meetingID: UUID(), folder: folder, captureCallSound: true, microphoneUID: nil,
        inputChannelByDeviceUID: [:]),
      sources: sources, onSegment: { _, _ in }, onFailure: { _, _ in })
    let result = try await recorder.start()
    #expect(result.echoProvenance == MeetingRecorder.echoProvenance)
    let call = try #require(calls.value.first)

    var state: UInt32 = 4355
    let seconds = 8
    let total = seconds * 16_000
    let render: [Float] = (0..<total).map { _ in
      state = state &* 1_664_525 &+ 1_013_904_223
      return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.5
    }
    let delay = 640
    let mic = (0..<total).map { $0 >= delay ? render[$0 - delay] * 0.5 : 0 }
    let chunk = 400  // divides the 8 s exactly, and 100 ms (1,600) too
    for start in stride(from: 0, to: total, by: chunk) {
      clock.advance(seconds: Double(chunk) / 16_000)
      let chunkStart =
        clock.now.withLock { $0 }
        &- MeetingRecorder.hostTicks(
          forSeconds: Double(chunk) / 16_000)
      Array(render[start..<(start + chunk)]).withUnsafeBufferPointer {
        call.handler($0, chunkStart, false)
      }
      microphone.onSamples?(Array(mic[start..<(start + chunk)]), 0.2)
      if start % 1_600 == 0 {
        // test-fixture-timer: capture arrives in real time; 20 ms per 100 ms of audio keeps the
        // fed audio inside the worker's 500 ms backlog bound without asserting on time.
        try await Task.sleep(for: .milliseconds(20))
        recorder.pumpEchoForTesting()
      }
    }
    let stopStarted = DispatchTime.now().uptimeNanoseconds
    await recorder.stop()
    // This Mac only; the budget's fallback is raw, never lost audio.
    print("MEETING_ECHO_REAL stopMs=\((DispatchTime.now().uptimeNanoseconds - stopStarted) / 1_000_000)")

    let report = MeetingTrackRecovery.recover(folder: folder)
    let raw = report.segments[.microphone] ?? []
    #expect(!raw.isEmpty)
    #expect(raw.reduce(0) { $0 + $1.frameCount } == total)
    #expect(report.cleanedSegments.count == raw.count)
    #expect(!report.cleanedConfirmed.isEmpty)
    guard
      case .cleaned(let twins, _) = MeetingMicrophoneSelection.decide(
        raw: raw, report: report, provenance: result.echoProvenance)
    else {
      Issue.record("the cleaned copy was not chosen")
      return
    }
    let rawAudio = MeetingTrackAudio(
      files: raw.map { (folder.appendingPathComponent($0.fileName), $0.startMs) })
    let cleanedAudio = MeetingTrackAudio(
      files: twins.map { (folder.appendingPathComponent($0.fileName), $0.startMs) })
    #expect(MeetingMicrophoneSelection.readMatches(cleanedAudio, raw: rawAudio))
    // The last 2 s: the echo is mostly gone from the cleaned copy, untouched in raw.
    let from = total - 2 * 16_000
    let before = try rawAudio.read(from: from, count: 2 * 16_000).reduce(0.0) {
      $0 + Double($1 * $1)
    }
    let after = try cleanedAudio.read(from: from, count: 2 * 16_000).reduce(0.0) {
      $0 + Double($1 * $1)
    }
    #expect(before > 0)
    print("MEETING_ECHO_REAL energyKept=\(after / before)")
    #expect(after < before * 0.1, "echo energy kept: \(after / before)")
  }
}
#endif
