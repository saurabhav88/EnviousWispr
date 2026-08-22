@preconcurrency import AVFoundation
import CoreAudio
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAudio

/// #2142 — a receipt across the real microphone boundary.
///
/// Unit tests can prove routing and buffering with stand-ins, but they cannot
/// prove that CoreAudio opens the built-in microphone and delivers live samples
/// through the production manager. This suite is gated on both the device and
/// an existing TCC grant. The release receipt runs through
/// `scripts/test-real-microphone.sh`, which rejects a skipped test.
@Suite("Live microphone capture", .tags(.productOutcome), .serialized)
@MainActor
struct AudioCaptureManagerLiveInputTests {

  private struct Receipt: Sendable {
    var bufferCount = 0
    var frameCount = 0
    var maximumMagnitude: Float = 0
    var sampleRate: Double?
    var channelCount: UInt32?

    mutating func observe(_ buffer: AVAudioPCMBuffer) {
      bufferCount += 1
      frameCount += Int(buffer.frameLength)
      sampleRate = sampleRate ?? buffer.format.sampleRate
      channelCount = channelCount ?? buffer.format.channelCount
      guard let channel = buffer.floatChannelData?.pointee else { return }
      for index in 0..<Int(buffer.frameLength) {
        maximumMagnitude = max(maximumMagnitude, abs(channel[index]))
      }
    }
  }

  private struct StopReceipt: Sendable {
    let capture: CaptureResult
    let receipt: Receipt
  }

  /// `.enabled(if:)` is evaluated outside actor isolation during discovery.
  /// Read only existing system facts: do not request permission or mutate the
  /// user's selected input device merely to decide whether this receipt runs.
  nonisolated private static func authorizedBuiltInMicrophoneUID() -> String? {
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return nil }
    guard case .success(let candidates, _) = AudioDeviceEnumerator.inputDeviceSnapshot()
    else { return nil }
    return candidates.first {
      $0.rawTransport == kAudioDeviceTransportTypeBuiltIn && !$0.uid.isEmpty
    }?.uid
  }

  @Test(
    "the built-in microphone produces non-zero 16 kHz mono samples and stops cleanly",
    .tags(.realBoundary),
    .enabled(if: AudioCaptureManagerLiveInputTests.authorizedBuiltInMicrophoneUID() != nil),
    .timeLimit(.minutes(1)))
  func builtInMicrophoneProducesNonZeroSamplesAndCleanStop() async throws {
    let microphoneUID = try #require(
      Self.authorizedBuiltInMicrophoneUID(),
      "requires microphone permission and a built-in input device")
    let microphoneID = try #require(AudioDeviceEnumerator.deviceID(forUID: microphoneUID))
    #expect(
      CoreAudioDeviceLiveness.classify(deviceID: microphoneID) == .alive,
      "the built-in microphone must be alive before the capture receipt runs")
    #expect(
      CoreAudioDeviceMute.classify(deviceID: microphoneID) == .unmuted,
      "the built-in microphone must be unmuted before the capture receipt runs")
    let manager = AudioCaptureManager()
    manager.preferredInputDeviceIDOverride = microphoneUID
    manager.warmEnginePolicy = .off

    let stream = try await manager.startCapture()
    let sessionID = manager.currentCaptureSessionID
    #expect(sessionID > 0, "a live capture must mint a real session identity")
    guard manager.zeroSignalDiscriminatorDevice?.deviceUID == microphoneUID else {
      _ = await manager.stopCapture(sessionID: sessionID)
      Issue.record("capture fell back instead of binding the requested built-in microphone")
      return
    }

    let collector = Task { @MainActor in
      var receipt = Receipt()
      for await buffer in stream {
        receipt.observe(buffer)
      }
      return receipt
    }

    // CoreAudio can legitimately emit a silent startup buffer. Observe a short
    // live window so this receipt measures the device rather than that transient.
    try await Task.sleep(for: .seconds(1))
    let stopAndCollect = Task { @MainActor in
      let capture = await manager.stopCapture(sessionID: sessionID)
      return StopReceipt(capture: capture, receipt: await collector.value)
    }
    guard let stopped = await Self.waitForStopReceipt(from: stopAndCollect) else {
      stopAndCollect.cancel()
      collector.cancel()
      Issue.record("stopCapture and stream completion exceeded two seconds")
      return
    }
    let capture = stopped.capture
    let receipt = stopped.receipt

    #expect(receipt.bufferCount > 0, "the real microphone produced no buffer within one second")
    #expect(receipt.frameCount > 0)
    #expect(receipt.sampleRate == AudioCaptureManager.targetSampleRate)
    #expect(receipt.channelCount == 1)
    #expect(
      receipt.maximumMagnitude > 0.000_001,
      "the built-in microphone delivered only digital zero")
    #expect(!capture.samples.isEmpty, "the manager must retain the live samples for transcription")
    #expect(
      capture.samples.contains { abs($0) > 0.000_001 },
      "the manager retained only digital zero")
    #expect(!manager.isCapturing, "stopCapture must end the live session")
  }

  private static func waitForStopReceipt(
    from operation: Task<StopReceipt, Never>
  ) async -> StopReceipt? {
    let (receipts, continuation) = AsyncStream.makeStream(
      of: StopReceipt.self, bufferingPolicy: .bufferingNewest(1))
    let relay = Task {
      continuation.yield(await operation.value)
      continuation.finish()
    }

    let result = await withTaskGroup(of: StopReceipt?.self) { group in
      group.addTask {
        for await receipt in receipts { return receipt }
        return nil
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(2))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }

    relay.cancel()
    return result
  }
}
