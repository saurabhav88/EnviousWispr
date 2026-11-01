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
/// costs more memory or time than the plan's measurements report.
///
/// The model comes through the production loader from a fixture bundle holding the checked-in
/// asset, so a missing model fails, never silently skips detection. Measurements write their
/// receipt to `EW_4254_QA_OUT` when set.
@Suite(
  "Meeting speech detector on the real model", .serialized, .tags(.productOutcome, .realBoundary),
  .realBoundaryRun,
  .enabled(if: PinnedVADModel.isCheckedIn, "pinned VAD model missing"))
struct MeetingSpeechDetectorRealBoundaryTests {
  static let chunk = MeetingSpeechDetector.chunkSize

  static var modelURL: URL { PinnedVADModel.url }

  /// A bundle holding the checked-in pinned model, flat, as the app bundle does.
  private static func modelBundle() throws -> Bundle {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("MeetingSpeechDetectorRealBoundary-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("\(BundledVADModelLoader.pinnedModelName).mlmodelc"),
      withDestinationURL: modelURL)
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

  @Test("real speech is found; exact zeros and the interior of a silent gap are not speech")
  func speechAndSilence() async throws {
    let bundle = try Self.modelBundle()
    let speech = try Self.fixture(Self.twoVoice)
    let spans = try await MeetingSpeechDetector.spans(in: speech, modelBundle: bundle)
    let covered = spans.reduce(0) { $0 + $1.count }
    #expect(!spans.isEmpty)
    #expect(Double(covered) / Double(speech.count) > 0.6, "most of the recording is speech")
    let zeros = [Float](repeating: 0, count: 20 * 16_000)
    #expect(try await MeetingSpeechDetector.spans(in: zeros, modelBundle: bundle) == [])
    // Speech, 10 s of zeros, speech: no returned range may touch the gap's interior (2 s in
    // from each edge, beyond the padding and the 1.5 s minimum silence), including one range
    // that would span the whole gap.
    let gap = 10 * 16_000
    let joined = speech + [Float](repeating: 0, count: gap) + speech
    let joinedSpans = try await MeetingSpeechDetector.spans(in: joined, modelBundle: bundle)
    let interior = (speech.count + 2 * 16_000)..<(speech.count + gap - 2 * 16_000)
    let touching = joinedSpans.filter { $0.overlaps(interior) }
    #expect(touching.isEmpty, "no range overlaps the gap's interior: \(joinedSpans)")
    #expect(joinedSpans.count >= 2, "speech on both sides of the gap")
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

  private static func pct(_ v: [Double], _ p: Double) -> String {
    String(format: "%.2f", v[Int(Double(v.count - 1) * p)])
  }

  @Test(
    "Q-a: load cost, hour cost, peak memory, release cycles, contention and cancellation",
    .timeLimit(.minutes(20)))
  func measurements() async throws {
    let bundle = try Self.modelBundle()
    let clock = ContinuousClock()
    var lines: [String] = ["# #4254 chunk 1 Q-a, \(Date()), this Mac (M5 Max), Debug test build"]

    // 1. Model load cost per decode (fresh detector; the first chunk includes the load).
    // Earlier tests in this process may already have loaded the model, so the first figure is
    // the first load in this test, not a proven cold CoreML compile.
    let oneChunk = [Float](repeating: 0.01, count: Self.chunk)
    var loads: [Double] = []
    for _ in 0..<5 {
      let start = clock.now
      _ = try await MeetingSpeechDetector.spans(in: oneChunk, modelBundle: bundle)
      loads.append(Self.seconds(clock.now - start) * 1000)
    }
    lines.append("load_plus_one_chunk_ms=\(loads.map { String(format: "%.1f", $0) })")

    // 2. One hour of real speech (the two-voice fixture repeated), final detection, with the
    // peak footprint sampled while it runs.
    let speech = try Self.fixture(Self.twoVoice)
    let hour = 3_600 * 16_000
    var building: [Float] = []
    building.reserveCapacity(hour)
    while building.count < hour {
      building.append(contentsOf: speech.prefix(hour - building.count))
    }
    let audio = building
    building = []
    let tenMinutes = Array(audio.prefix(10 * 60 * 16_000))
    let peak = PeakSampler()
    // detached: samples the process from outside the detector being measured.
    let sampler = Task.detached {
      while !Task.isCancelled {
        peak.note(Self.footprintMB())
        try? await Task.sleep(for: .milliseconds(50))  // test-fixture-timer: sampling period
      }
    }
    let before = Self.footprintMB()
    let start = clock.now
    let spans = try await MeetingSpeechDetector.spans(in: audio, modelBundle: bundle)
    let hourSeconds = Self.seconds(clock.now - start)
    let after = Self.footprintMB()
    sampler.cancel()
    _ = await sampler.value
    lines.append(
      "hour_detect_s=\(String(format: "%.2f", hourSeconds)) spans=\(spans.count) footprint_mb before=\(String(format: "%.0f", before)) peak=\(String(format: "%.0f", peak.max)) after=\(String(format: "%.0f", after))"
    )
    let speechSamples = spans.reduce(0) { $0 + $1.count }
    lines.append(
      "calc_storage_mb raw=\(hour * 4 / 1_048_576) speech_only=\(speechSamples * 4 / 1_048_576) (Float32; calculated, not measured; this input has almost no 1.5 s pauses)"
    )

    // 2b. Decode-input memory, measured: the hour's raw input (held above) plus a separately
    // allocated, reserved concatenated input with the 8,000-sample look-ahead, worst case all
    // speech. The native decoder's own copy is measured by the transcribe.cpp Q-a test.
    let lookAhead = 8_000
    let concatBefore = Self.footprintMB()
    let concatPeak = PeakSampler()
    let concatSampler = Task.detached {
      while !Task.isCancelled {
        concatPeak.note(Self.footprintMB())
        try? await Task.sleep(for: .milliseconds(20))  // test-fixture-timer: sampling period
      }
    }
    var concatenated: [Float] = []
    concatenated.reserveCapacity(audio.count + lookAhead)
    // Worst case: the whole hour is one speech stretch.
    concatenated.append(contentsOf: audio)
    concatenated.append(contentsOf: repeatElement(0, count: lookAhead))
    let concatHeld = Self.footprintMB()
    concatPeak.note(concatHeld)
    concatSampler.cancel()
    _ = await concatSampler.value
    lines.append(
      "measured_decode_input_mb raw_hour_held_before=\(String(format: "%.0f", concatBefore)) with_concatenated=\(String(format: "%.0f", concatHeld)) peak=\(String(format: "%.0f", concatPeak.max)) concatenated_samples=\(concatenated.count)"
    )
    concatenated = []
    lines.append("after_concatenated_freed_mb=\(String(format: "%.0f", Self.footprintMB()))")

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

    // 4. Under contention: two live meeting detectors (one per track) and a final detection,
    // each proven running before and during every measurement window. Measured: dictation's
    // VAD startup component (model preparation plus its first chunk), its per-chunk VAD step,
    // and an hour of final detection with a fresh detector. Not press-to-recording latency:
    // the audio engine and recognizer start do not use the VAD model and are not measured here.
    func dictationStartMs() async throws -> Double {
      let dictation = SilenceDetector(silenceTimeout: 1.5, modelBundle: bundle)
      let s = clock.now
      try await dictation.prepare()
      await dictation.reset()
      _ = await dictation.processChunk(Array(speech[0..<Self.chunk]))
      return Self.seconds(clock.now - s) * 1000
    }
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
    var startAlone: [Double] = []
    for _ in 0..<10 { startAlone.append(try await dictationStartMs()) }
    let alone = try await dictationChunkMs()
    let activity = Activity()
    // detached: the competing meeting detectors run off this test's task, as a pass and two
    // live tracks would, while dictation is measured here.
    let load = Task.detached {
      try await withThrowingTaskGroup(of: Void.self) { group in
        for track in 0..<2 {
          group.addTask {
            let live = MeetingSpeechDetector(modelBundle: bundle)
            for i in 0..<10_000_000 {
              try Task.checkCancellation()
              let offset = (i * 1_600) % (speech.count - 1_600)
              try await live.append(Array(speech[offset..<(offset + 1_600)]))
              activity.liveChunk(track: track)
            }
          }
        }
        group.addTask {
          // Final detection, again and again, so it is running in every window.
          while true {
            try Task.checkCancellation()
            let final = MeetingSpeechDetector(modelBundle: bundle)
            var offset = 0
            while offset < tenMinutes.count {
              try Task.checkCancellation()
              let end = min(offset + Self.chunk, tenMinutes.count)
              try await final.append(Array(tenMinutes[offset..<end]))
              activity.finalChunk()
              offset = end
            }
            try await final.finish()
          }
        }
        try await group.waitForAll()
      }
    }
    // Every competitor has started before the first window.
    try await BoundedWait.until(activity.started[0])
    try await BoundedWait.until(activity.started[1])
    try await BoundedWait.until(activity.started[2])
    var windows: [String] = []
    /// Runs `body` as one measurement window and records each competitor's progress in it.
    func window<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
      let before = activity.counts
      let value = try await body()
      let after = activity.counts
      let deltas = zip(after, before).map { $0 - $1 }
      windows.append("\(name)=\(deltas)")
      #expect(deltas.allSatisfy { $0 > 0 }, "every competitor ran during \(name): \(deltas)")
      return value
    }
    var startContended: [Double] = []
    for n in 0..<10 {
      startContended.append(try await window("start\(n)") { try await dictationStartMs() })
    }
    let contended = try await window("chunks") { try await dictationChunkMs() }
    let hourContendedSeconds = try await window("hour") { () async throws -> Double in
      let s = clock.now
      _ = try await MeetingSpeechDetector.spans(in: audio, modelBundle: bundle)
      return Self.seconds(clock.now - s)
    }
    load.cancel()
    _ = try? await load.value
    lines.append("competition_window_progress [track1, track2, final_chunks]: \(windows.joined(separator: " "))")
    startAlone.sort()
    startContended.sort()
    lines.append(
      "dictation_vad_start_ms (prepare + first chunk) alone p50=\(Self.pct(startAlone, 0.5)) max=\(Self.pct(startAlone, 1)) | contended p50=\(Self.pct(startContended, 0.5)) max=\(Self.pct(startContended, 1))"
    )
    lines.append(
      "dictation_chunk_ms alone p50=\(Self.pct(alone, 0.5)) p95=\(Self.pct(alone, 0.95)) max=\(Self.pct(alone, 1)) | contended p50=\(Self.pct(contended, 0.5)) p95=\(Self.pct(contended, 0.95)) max=\(Self.pct(contended, 1))"
    )
    lines.append(
      "final_detection_preparation_s hour alone=\(String(format: "%.2f", hourSeconds)) contended=\(String(format: "%.2f", hourContendedSeconds)) (fresh detector, load included; detector preparation cost only, not a Delete, quit or engine-switch delay)"
    )

    // 5. Task cancellation during final preparation of an hour.
    // detached: the cancellation target must be its own task.
    let prep = Task.detached {
      try await MeetingSpeechDetector.spans(in: audio, modelBundle: bundle)
    }
    try await Task.sleep(for: .milliseconds(300))  // settle: let preparation get under way
    let cancelAt = clock.now
    prep.cancel()
    var cancelled = false
    do { _ = try await prep.value } catch is CancellationError { cancelled = true }
    let cancelMs = Self.seconds(clock.now - cancelAt) * 1000
    lines.append("task_cancel_ms=\(String(format: "%.1f", cancelMs)) cancelled=\(cancelled)")
    #expect(cancelled)
    lines.append(
      "not_measured: M1/8 GB floor; actual dictation press-to-recording responsiveness; end-to-end Delete, quit and engine-switch delay (each has its own path); user Cancel stays at the job's unit boundary"
    )

    let text = lines.joined(separator: "\n") + "\n"
    print(text)
    if let out = ProcessInfo.processInfo.environment["EW_4254_QA_OUT"] {
      try text.write(toFile: out, atomically: true, encoding: .utf8)
    }
  }
}

/// The highest footprint a sampler saw.
final class PeakSampler: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0.0
  func note(_ mb: Double) { lock.withLock { value = Swift.max(value, mb) } }
  var max: Double { lock.withLock { value } }
}

/// Counts each competing detector's progress (live track 1, live track 2, final chunks), to
/// prove each ran before and during every measurement window.
final class Activity: @unchecked Sendable {
  private let lock = NSLock()
  private var values = [0, 0, 0]
  /// Fired at each competitor's first progress.
  let started = [BoundedWait.Signal(), BoundedWait.Signal(), BoundedWait.Signal()]
  private func bump(_ i: Int) {
    let first = lock.withLock { () -> Bool in
      values[i] += 1
      return values[i] == 1
    }
    if first { started[i].fire() }
  }
  func liveChunk(track: Int) { bump(track) }
  func finalChunk() { bump(2) }
  var counts: [Int] { lock.withLock { values } }
}

/// The checked-in pinned VAD model the real-model suite loads (kept outside the suite so its
/// `@Suite` trait can read it).
enum PinnedVADModel {
  static var url: URL {
    RepoRoot.sourceURL(
      "Sources/EnviousWispr/Resources/VAD/\(BundledVADModelLoader.pinnedModelName).mlmodelc")
  }
  static var isCheckedIn: Bool { FileManager.default.fileExists(atPath: url.path) }
}
