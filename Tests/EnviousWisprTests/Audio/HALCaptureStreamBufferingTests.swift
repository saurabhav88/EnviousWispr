@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

/// #3972 R14: when these fail, dictation loses buffers it used to keep, or an hours-long
/// meeting piles captured audio into a stream nobody reads; or a meeting's microphone client
/// stops dictation's.
@Suite("HAL capture stream buffering", .tags(.productOutcome), .serialized)
@MainActor
struct HALCaptureStreamBufferingTests {

  private func buffer() -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
    buffer.frameLength = 160
    return buffer
  }

  #if DEBUG
    @Test("dictation's default stream keeps every unread buffer")
    func dictationDefaultKeepsEveryBuffer() async {
      let source = HALDeviceInputSource()
      let stream = source.makeCaptureStream()
      for _ in 0..<5 { source.yieldToCaptureStreamForTesting(buffer()) }
      source.finishCaptureStreamForTesting()
      var count = 0
      for await _ in stream { count += 1 }
      #expect(count == 5)
    }

    @Test("a meeting's stream keeps nothing: buffers nobody reads are not retained")
    func meetingStreamRetainsNothing() async {
      let source = HALDeviceInputSource()
      source.captureStreamBufferingPolicy = .bufferingNewest(0)
      let stream = source.makeCaptureStream()
      var results: [String] = []
      for _ in 0..<5 {
        if case .dropped = source.yieldToCaptureStreamForTesting(buffer()) {
          results.append("dropped")
        }
      }
      source.finishCaptureStreamForTesting()
      var count = 0
      for await _ in stream { count += 1 }
      #expect(count == 0)
      #expect(results.count == 5)
    }
  #endif

  // MARK: - Real microphone

  @Test(
    "two independent clients on the built-in microphone both deliver; stopping one leaves the other",
    .tags(.realBoundary),
    .enabled(if: MeetingRecorderTests.authorizedBuiltInMicrophoneUID() != nil),
    .timeLimit(.minutes(1)), .realBoundaryRun)
  func twoIndependentClients() async throws {
    let uid = try #require(MeetingRecorderTests.authorizedBuiltInMicrophoneUID())
    let countA = OSAllocatedUnfairLock(initialState: 0)
    let countB = OSAllocatedUnfairLock(initialState: 0)
    let a = HALDeviceInputSource()
    let b = HALDeviceInputSource()
    defer {
      a.stopSynchronously()
      b.stopSynchronously()
    }
    for (source, count) in [(a, countA), (b, countB)] {
      source.targetDeviceUID = uid
      source.captureStreamBufferingPolicy = .bufferingNewest(0)
      source.onSamples = { samples, _ in count.withLock { $0 += samples.count } }
      _ = try await source.prepare()
      _ = try await source.startCapture()
    }
    // test-fixture-timer: a live observation window, not a completion signal.
    try await Task.sleep(for: .milliseconds(700))
    #expect(countA.withLock { $0 } > 0)
    #expect(countB.withLock { $0 } > 0)
    a.stopSynchronously()
    let bAtStop = countB.withLock { $0 }
    try await Task.sleep(for: .milliseconds(700))  // test-fixture-timer: as above.
    #expect(countB.withLock { $0 } > bAtStop, "stopping one client stopped the other")
  }
}
