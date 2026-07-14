import AVFAudio
import EnviousWisprCore
import Foundation

@testable import EnviousWisprPipeline

// #1548 D1 — the recording FSM gates Arming → Live on the FIRST converted
// buffer (transport, not signal). The kernel wires `onBufferCaptured` BEFORE it
// calls `beginCapturePhase()`, so an integration fake that wants its session to
// reach `.live`/`.recording` must fire `onBufferCaptured` with one buffer from
// inside `beginCapturePhase` — otherwise the session parks in Arming forever.
// This is the shared factory for that first buffer, so every integration fake
// stops re-deriving the same `AVAudioPCMBuffer` boilerplate.
enum TransportGateTestBuffer {
  /// A single silent capture-sized mono float buffer. Amplitude is irrelevant to
  /// the transport gate — a zero-filled buffer is still transport.
  static func makeFirstBuffer(frameCount: Int = AudioConstants.captureBufferSize)
    -> AVAudioPCMBuffer?
  {
    let frames = max(1, frameCount)
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioConstants.sampleRate,
        channels: AVAudioChannelCount(AudioConstants.channels),
        interleaved: false),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
    else { return nil }
    buffer.frameLength = AVAudioFrameCount(frames)
    return buffer
  }
}
