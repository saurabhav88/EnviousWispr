import CWebRTCAEC
import Foundation
import Testing

/// The shipped echo cleaner framework (#4355), called through its real C boundary: argument
/// refusal, honest warm-up metrics, and echo actually removed from a deterministic signal.
@Suite("Meeting echo cleaner framework (#4355)", .tags(.productOutcome))
struct CWebRTCAECBinaryTests {
  private static let frame = Int(EW_AEC_FRAME_SAMPLES)

  /// Deterministic noise in [-0.25, 0.25] (a fixed linear congruential generator).
  private static func noise(_ count: Int, seed: UInt32) -> [Float] {
    var state = seed
    return (0..<count).map { _ in
      state = state &* 1_664_525 &+ 1_013_904_223
      return (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.5
    }
  }

  private static func energy(_ samples: ArraySlice<Float>) -> Double {
    samples.reduce(0) { $0 + Double($1) * Double($1) }
  }

  @Test("the boundary refuses a null instance, a null buffer and a wrong frame size")
  func refusesBadArguments() throws {
    let aec = try #require(ew_aec_create())
    defer { ew_aec_destroy(aec) }
    var buffer = [Float](repeating: 0, count: Self.frame)
    var out = buffer
    #expect(ew_aec_process_render(nil, buffer, Int32(Self.frame)) == EW_AEC_ERR_ARGUMENT)
    #expect(ew_aec_process_render(aec, nil, Int32(Self.frame)) == EW_AEC_ERR_ARGUMENT)
    #expect(ew_aec_process_render(aec, buffer, Int32(Self.frame - 1)) == EW_AEC_ERR_ARGUMENT)
    #expect(ew_aec_process_capture(aec, buffer, nil, Int32(Self.frame)) == EW_AEC_ERR_ARGUMENT)
    #expect(
      ew_aec_process_capture(aec, &buffer, &out, Int32(Self.frame * 2)) == EW_AEC_ERR_ARGUMENT)
    #expect(ew_aec_set_stream_delay_ms(aec, -1) == EW_AEC_ERR_ARGUMENT)
    #expect(ew_aec_reset(nil) == EW_AEC_ERR_ARGUMENT)
    #expect(ew_aec_get_metrics(aec, nil) == EW_AEC_ERR_ARGUMENT)
    ew_aec_destroy(nil)
  }

  @Test("a fresh instance reports no measured metrics, and the build names upstream v2.1")
  func warmUpMetricsAreAbsent() throws {
    let aec = try #require(ew_aec_create())
    defer { ew_aec_destroy(aec) }
    var metrics = EWAECMetrics()
    #expect(ew_aec_get_metrics(aec, &metrics) == EW_AEC_OK)
    #expect(metrics.has_erle == 0)
    #expect(metrics.has_delay == 0)
    let version = String(cString: ew_aec_version())
    #expect(version.hasPrefix("webrtc-audio-processing 2.1 846fe90 ew-4355."))
  }

  /// The microphone hears the render signal 40 ms later at half level, the delay the speaker
  /// rig measured. After 8 s of adaptation the last 2 s keep under a tenth of the echo energy.
  @Test("echo of the render signal is removed from the microphone, and reset starts over")
  func removesEcho() throws {
    let aec = try #require(ew_aec_create())
    defer { ew_aec_destroy(aec) }
    let seconds = 10
    let total = Int(EW_AEC_SAMPLE_RATE) * seconds
    let delay = Int(EW_AEC_SAMPLE_RATE) / 25
    let render = Self.noise(total, seed: 4355)
    let mic = (0..<total).map { $0 >= delay ? render[$0 - delay] * 0.5 : 0 }
    var cleaned = [Float](repeating: 0, count: total)
    var renderFrames = 0
    var captureFrames = 0
    for start in stride(from: 0, to: total, by: Self.frame) {
      let range = start..<(start + Self.frame)
      let r = Array(render[range])
      let m = Array(mic[range])
      var out = [Float](repeating: 0, count: Self.frame)
      #expect(ew_aec_process_render(aec, r, Int32(Self.frame)) == EW_AEC_OK)
      renderFrames += 1
      #expect(ew_aec_process_capture(aec, m, &out, Int32(Self.frame)) == EW_AEC_OK)
      captureFrames += 1
      cleaned.replaceSubrange(range, with: out)
    }
    #expect(renderFrames == total / Self.frame && captureFrames == total / Self.frame)
    let allFinite = cleaned.allSatisfy { $0.isFinite }
    #expect(allFinite)
    let tail = (total - 2 * Int(EW_AEC_SAMPLE_RATE))..<total
    let before = Self.energy(mic[tail])
    let after = Self.energy(cleaned[tail])
    #expect(before > 0)
    #expect(after < before * 0.1, "echo energy kept: \(after / before)")

    var metrics = EWAECMetrics()
    #expect(ew_aec_get_metrics(aec, &metrics) == EW_AEC_OK)
    #expect(ew_aec_get_metrics(aec, &metrics) == EW_AEC_OK)
    #expect(metrics.has_delay == 1)

    #expect(ew_aec_reset(aec) == EW_AEC_OK)
    var fresh = EWAECMetrics()
    #expect(ew_aec_get_metrics(aec, &fresh) == EW_AEC_OK)
    #expect(fresh.has_erle == 0 && fresh.has_delay == 0)
  }
}
