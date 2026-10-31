import CoreML
import Darwin
import EnviousWisprAppKitTestSupport
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

/// #4254 on the real pinned Silero model: when these fail, meeting Whisper's speech detection
/// disagrees with dictation's on the same audio, misses real speech, calls silence speech, or
/// costs more memory or time than the plan's measurements allow.
///
/// The model comes through the production loader from a fixture bundle holding the checked-in
/// asset, so a missing model fails, never silently skips detection. Measurements write their
/// receipt to `EW_4254_QA_OUT` when set.
@Suite(
  "Meeting speech detector on the real model", .serialized, .tags(.productOutcome, .realBoundary),
  .realBoundaryRun)
struct MeetingSpeechDetectorRealBoundaryTests {
  static let chunk = MeetingSpeechDetector.chunkSize

  /// A bundle holding the checked-in pinned model, flat, as the app bundle does.
  private static func modelBundle() throws -> Bundle {
    let checkedIn = RepoRoot.sourceURL(
      "Sources/EnviousWispr/Resources/VAD/\(BundledVADModelLoader.pinnedModelName).mlmodelc")
    try #require(FileManager.default.fileExists(atPath: checkedIn.path), "model missing")
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("MeetingSpeechDetectorRealBoundary-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("\(BundledVADModelLoader.pinnedModelName).mlmodelc"),
      withDestinationURL: checkedIn)
    return try #require(Bundle(path: root.path))
  }

  private static func fixture(_ path: String) throws -> [Float] {
    let samples = try VADInputConditioningFixtureTests.loadPCM16(at: RepoRoot.sourceURL(path))
    try #require(!samples.isEmpty)
    return samples
  }

  private static let twoVoice = "Tests/Fixtures/speaker-diarization/two-voice-30s.wav"
  private static let conditioning = [
    "Tests/Fixtures/vad-conditioning/fixture-noisy-cabin.wav",
    "Tests/Fixtures/vad-conditioning/fixture-noisy-mild.wav",
  ]

  // MARK: - Dictation parity

  /// Same whole chunks through dictation's `SilenceDetector` and the meeting detector: the
  /// unpadded ranges must be identical (padding is a separate, later contract).
  @Test("on the same audio, meeting and dictation detection find the same speech")
  func dictationParity() async throws {
    let bundle = try Self.modelBundle()
    for path in Self.conditioning + [Self.twoVoice] {
      let samples = try Self.fixture(path)
      let whole = (samples.count / Self.chunk) * Self.chunk
      let dictation = SilenceDetector(silenceTimeout: 1.5, modelBundle: bundle)
      try await dictation.prepare()
      await dictation.reset()
      var offset = 0
      while offset < whole {
        _ = await dictation.processChunk(Array(samples[offset..<(offset + Self.chunk)]))
        offset += Self.chunk
      }
      await dictation.finalizeSegments(totalSampleCount: whole)
      let expected = await dictation.speechSegments.map { $0.startSample..<$0.endSample }

      let meeting = MeetingSpeechDetector(modelBundle: bundle)
      try await meeting.append(Array(samples[0..<whole]))
      try await meeting.finish()
      let got = await meeting.unpaddedSpans
      #expect(got == expected, "\(path): meeting \(got) vs dictation \(expected)")
      #expect(!expected.isEmpty || path.contains("mild"), "\(path): control has speech")
    }
  }

  // MARK: - Speech and silence

  @Test("real speech is found; exact zeros and the silent gaps are not speech")
  func speechAndSilence() async throws {
    let bundle = try Self.modelBundle()
    let speech = try Self.fixture(Self.twoVoice)
    let spans = try await MeetingSpeechDetector.spans(in: speech, modelBundle: bundle)
    let covered = spans.reduce(0) { $0 + $1.count }
    #expect(!spans.isEmpty)
    #expect(Double(covered) / Double(speech.count) > 0.6, "most of the recording is speech")
    let zeros = [Float](repeating: 0, count: 20 * 16_000)
    #expect(try await MeetingSpeechDetector.spans(in: zeros, modelBundle: bundle) == [])
    // Speech, 10 s of zeros, speech: the zeros are never inside a range beyond the padding.
    let gap = 10 * 16_000
    let joined = speech + [Float](repeating: 0, count: gap) + speech
    let joinedSpans = try await MeetingSpeechDetector.spans(in: joined, modelBundle: bundle)
    let gapRange = speech.count..<(speech.count + gap)
    let pad = AudioConstants.speechPaddingSamples
    let insideGap = joinedSpans.filter {
      $0.lowerBound >= gapRange.lowerBound + pad && $0.upperBound <= gapRange.upperBound - pad
    }
    #expect(insideGap.isEmpty, "no speech inside the zero gap: \(joinedSpans)")
  }

  // MARK: - Q-a measurements

  private static func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
  }

  private static func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
  }

  @Test(
    "Q-a: load cost, hour cost, memory, release cycles, contention and cancellation",
    .timeLimit(.minutes(20)))
  func measurements() async throws {
    let bundle = try Self.modelBundle()
    let clock = ContinuousClock()
    var lines: [String] = ["# #4254 chunk 1 Q-a, \(Date()), this Mac (M5 Max), Debug test build"]

    // 1. Model load cost per decode (fresh detector, first chunk includes the load).
    let oneChunk = [Float](repeating: 0.01, count: Self.chunk)
    var loads: [Double] = []
    for _ in 0..<5 {
      let start = clock.now
      _ = try await MeetingSpeechDetector.spans(in: oneChunk, modelBundle: bundle)
      loads.append(Self.seconds(clock.now - start) * 1000)
    }
    lines.append("load_plus_one_chunk_ms=\(loads.map { String(format: "%.1f", $0) })")

    // 2. One hour of real speech (the two-voice fixture repeated), final detection.
    let speech = try Self.fixture(Self.twoVoice)
    let hour = 3_600 * 16_000
    var building: [Float] = []
    building.reserveCapacity(hour)
    while building.count < hour { building.append(contentsOf: speech.prefix(hour - building.count)) }
    let audio = building
    building = []
    let tenMinutes = Array(audio.prefix(10 * 60 * 16_000))
    let before = Self.footprintMB()
    let start = clock.now
    let spans = try await MeetingSpeechDetector.spans(in: audio, modelBundle: bundle)
    let hourSeconds = Self.seconds(clock.now - start)
    let after = Self.footprintMB()
    lines.append(
      "hour_detect_s=\(String(format: "%.2f", hourSeconds)) spans=\(spans.count) footprint_mb_before=\(String(format: "%.0f", before)) after=\(String(format: "%.0f", after))"
    )
    // Concatenated speech-only input the final decode would build (calculated storage).
    let speechSamples = spans.reduce(0) { $0 + $1.count }
    lines.append(
      "calc_mb raw=\(hour * 4 / 1_048_576) speech_only=\(speechSamples * 4 / 1_048_576) (Float32)")
    #expect(hourSeconds < 120, "an hour of detection stays well under two minutes on this Mac")

    // 3. Create, process and release three times: residency before, during, after.
    var cycles: [String] = []
    for _ in 0..<3 {
      let b = Self.footprintMB()
      var d: MeetingSpeechDetector? = MeetingSpeechDetector(modelBundle: bundle)
      try await d?.append(Array(audio.prefix(60 * 16_000)))
      let during = Self.footprintMB()
      try await d?.finish()
      d = nil
      let a = Self.footprintMB()
      cycles.append(String(format: "%.0f/%.0f/%.0f", b, during, a))
    }
    lines.append("cycles_mb before/during/after=\(cycles)")

    // 4. Contention: dictation's detector per-chunk latency alone, then with two live meeting
    // detectors and a final detection running at the same time. Dictation's VAD step, not
    // press-to-recording.
    func dictationChunkMs() async throws -> [Double] {
      let dictation = SilenceDetector(silenceTimeout: 1.5, modelBundle: bundle)
      try await dictation.prepare()
      await dictation.reset()
      var times: [Double] = []
      for i in 0..<200 {
        let offset = (i * Self.chunk) % (speech.count - Self.chunk)
        let s = clock.now
        _ = await dictation.processChunk(Array(speech[offset..<(offset + Self.chunk)]))
        times.append(Self.seconds(clock.now - s) * 1000)
      }
      return times.sorted()
    }
    let alone = try await dictationChunkMs()
    let load = Task.detached {
      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<2 {
          group.addTask {
            let live = MeetingSpeechDetector(modelBundle: bundle)
            for i in 0..<400 {
              try Task.checkCancellation()
              let offset = (i * 1_600) % (speech.count - 1_600)
              try await live.append(Array(speech[offset..<(offset + 1_600)]))
            }
          }
        }
        group.addTask {
          _ = try await MeetingSpeechDetector.spans(
            in: Array(audio.prefix(10 * 60 * 16_000)), modelBundle: bundle)
        }
        try await group.waitForAll()
      }
    }
    let contended = try await dictationChunkMs()
    load.cancel()
    _ = try? await load.value
    func pct(_ v: [Double], _ p: Double) -> String {
      String(format: "%.2f", v[Int(Double(v.count - 1) * p)])
    }
    lines.append(
      "dictation_chunk_ms alone p50=\(pct(alone, 0.5)) p95=\(pct(alone, 0.95)) max=\(pct(alone, 1)) | contended p50=\(pct(contended, 0.5)) p95=\(pct(contended, 0.95)) max=\(pct(contended, 1))"
    )

    // 5. Task cancellation during final preparation of an hour.
    let prep = Task.detached {
      try await MeetingSpeechDetector.spans(in: audio, modelBundle: bundle)
    }
    try await Task.sleep(for: .milliseconds(300))  // settle: let preparation get under way, then cancel
    let cancelAt = clock.now
    prep.cancel()
    var cancelled = false
    do { _ = try await prep.value } catch is CancellationError { cancelled = true }
    let cancelMs = Self.seconds(clock.now - cancelAt) * 1000
    lines.append("task_cancel_ms=\(String(format: "%.1f", cancelMs)) cancelled=\(cancelled)")
    #expect(cancelled)
    lines.append(
      "not_measured: M1/8 GB floor; user Cancel stays at the job's unit boundary (not task cancellation)"
    )

    let text = lines.joined(separator: "\n") + "\n"
    print(text)
    if let out = ProcessInfo.processInfo.environment["EW_4254_QA_OUT"] {
      try text.write(toFile: out, atomically: true, encoding: .utf8)
    }
  }
}
