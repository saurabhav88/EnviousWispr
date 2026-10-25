@preconcurrency import AVFoundation
import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing
import os

@testable import EnviousWisprASR
@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage
import EnviousWisprAppKitTestSupport

/// #3972 C3b: the meeting pass on real models. When these fail, a meeting's transcript is empty
/// or unlabeled on real speech, or a long meeting exhausts memory. Gated on the installed Ultra
/// model (never downloaded here); the long runs also need a corpus file named by environment.
@Suite("Meeting processing on real models", .serialized, .tags(.productOutcome))
@MainActor
struct MeetingProcessingRealBoundaryTests {

  nonisolated static var ultraDirectory: URL {
    ParakeetInstallLocation.directory(for: .ultra, dataDirectory: StorageRoot.live.dataDirectory)
  }

  nonisolated static var ultraIsInstalled: Bool {
    AsrModels.modelsExist(at: ultraDirectory, version: .ultra)
  }

  nonisolated static func longAudio(_ label: String) -> URL? {
    guard let path = ProcessInfo.processInfo.environment["EW_MEETING_LONG_AUDIO_\(label)"],
      FileManager.default.fileExists(atPath: path)
    else { return nil }
    return URL(fileURLWithPath: path)
  }

  /// Splits a 16 kHz mono file into the meeting's 60 s segment files, streaming.
  private func segments(from source: URL, into folder: URL) throws -> MeetingTrackAudio {
    let input = try AVAudioFile(forReading: source)
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let chunk = AVAudioFrameCount(960_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
    var files: [(url: URL, startMs: Int)] = []
    var index = 1
    var startSample = 0
    while input.framePosition < input.length {
      let remaining = AVAudioFrameCount(input.length - input.framePosition)
      try input.read(into: buffer, frameCount: min(chunk, remaining))
      guard buffer.frameLength > 0 else { break }
      let name = MeetingSegmentNaming.fileName(
        track: .callSound, index: index, startMs: startSample / 16, partial: false)
      let url = folder.appendingPathComponent(name)
      let out = try AVAudioFile(
        forWriting: url,
        settings: [
          AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
          AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
      try out.write(from: buffer)
      files.append((url, startSample / 16))
      startSample += Int(buffer.frameLength)
      index += 1
    }
    return MeetingTrackAudio(files: files)
  }

  private func folder(_ label: String) throws -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent(
        "MeetingRealBoundary-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A job on the real meeting engine (installed Ultra, cache-only) and the real speaker step.
  /// The repo's bundled speaker models, linked into a temporary bundle (the pattern of
  /// `OfflineSpeakerAnalyzerRealBoundaryTests`, whose builder is private to its file).
  private static func speakerModelBundle() throws -> Bundle {
    let resources = RepoRoot.sourceURL("Sources/EnviousWispr/Resources")
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("MeetingRealBoundary-models-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in [
      ModelNames.OfflineDiarizer.segmentation, ModelNames.OfflineDiarizer.fbank,
      ModelNames.OfflineDiarizer.embedding, ModelNames.OfflineDiarizer.pldaRho,
    ] {
      try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("\(name).mlmodelc"),
        withDestinationURL: resources.appendingPathComponent("SpeakerModels/\(name).mlmodelc"))
    }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("speaker-plda-parameters.json"),
      withDestinationURL: resources.appendingPathComponent("speaker-plda-parameters.json"))
    return try #require(Bundle(path: root.path))
  }

  /// In the test process the app's resources are not `Bundle.main`; the speaker models come
  /// from the same fixture bundle the real speaker-analyzer test builds from the repo's resources.
  private func realJob() throws -> (MeetingTranscriptionJob, MeetingParakeetEngine) {
    let speakerBundle = try Self.speakerModelBundle()
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting, parakeetSelection: ParakeetSelectionProvider())
    let engine = MeetingParakeetEngine(offlineModeAdmission: manager, isModelSourceUsable: { true })
    let selection = ParakeetModelSelection(
      model: .ultra, revision: nil, directory: Self.ultraDirectory, cacheOnly: true,
      displayBytes: 1, repairable: false, generation: 0)
    let job = MeetingTranscriptionJob(
      dependencies: .init(
        isDictationIdle: { true }, waitUntilDictationIdle: {}, beginModelUse: {}, endModelUse: {},
        loadEngine: { try await engine.load(selection: selection) },
        transcribe: { try await engine.transcribe(samples: $0, language: nil) },
        unloadEngine: { await engine.unload() },
        analyzeSpeakers: { audio in
          await MeetingSpeakerAnalyzer.analyze(
            audio,
            makeWork: { track in
              Task<[SpeakerSegment], Error> {
                let models = try BundledSpeakerModelLoader.load(in: speakerBundle)
                let analyzer = OfflineSpeakerAnalyzer()
                analyzer.initialize(models: models)
                return try await analyzer.analyze(meetingTrack: track) { _, _ in }
              }
            })
        },
        engineIdentity: { "ultra" }))
    return (job, engine)
  }

  @Test(
    "a two-voice recording becomes a labeled transcript through the real meeting pass",
    .enabled(if: MeetingProcessingRealBoundaryTests.ultraIsInstalled),
    .tags(.realBoundary), .timeLimit(.minutes(3)))
  func twoVoiceRecording() async throws {
    let fixture = URL(filePath: #filePath)
      .deletingLastPathComponent()  // Pipeline
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appending(path: "Tests/Fixtures/speaker-diarization/two-voice-30s.wav")
    let dir = try folder("two-voice")
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = try segments(from: fixture, into: dir)
    let (job, engine) = try realJob()
    let result = try await job.run(tracks: [.callSound: audio]) { _ in }
    let words = result.composition.text.split(whereSeparator: \.isWhitespace).count
    print(
      "MEETING_REAL two-voice words=\(words) speakers=\(result.composition.speakerCount) outcome=\(result.speakerOutcomes[.callSound].map(\.rawValue) ?? "none")"
    )
    #expect(words >= 10)
    #expect(
      result.speakerOutcomes[.callSound] == .labeled
        || result.speakerOutcomes[.callSound] == .single)
    #expect(!engine.isLoaded, "the engine is unloaded when the pass ends")
  }

  /// Footprint of this process (what the system counts against memory), in MB.
  nonisolated static func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard status == KERN_SUCCESS else { return -1 }
    return Double(info.phys_footprint) / 1_048_576
  }

  @Test(
    "a three-hour meeting completes with measured memory and time",
    .enabled(
      if: MeetingProcessingRealBoundaryTests.ultraIsInstalled
        && MeetingProcessingRealBoundaryTests.longAudio("3H") != nil),
    .tags(.realBoundary), .timeLimit(.minutes(30)))
  func threeHourMeeting() async throws { try await longMeeting("3H") }

  @Test(
    "a five-hour meeting completes with measured memory and time",
    .enabled(
      if: MeetingProcessingRealBoundaryTests.ultraIsInstalled
        && MeetingProcessingRealBoundaryTests.longAudio("5H") != nil),
    .tags(.realBoundary), .timeLimit(.minutes(30)))
  func fiveHourMeeting() async throws { try await longMeeting("5H") }

  @MainActor final class Stages {
    var start: [String: Date] = [:]
    var peak: [String: Double] = [:]
    var current = "start"
  }

  private func longMeeting(_ label: String) async throws {
    let source = try #require(Self.longAudio(label))
    let dir = try folder(label)
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = try segments(from: source, into: dir)
    let peak = OSAllocatedUnfairLock(initialState: 0.0)
    let sampling = OSAllocatedUnfairLock(initialState: true)
    let baseline = Self.footprintMB()
    defer { sampling.withLock { $0 = false } }
    let sampler = Task.detached {
      while sampling.withLock({ $0 }) {
        let now = Self.footprintMB()
        peak.withLock { $0 = max($0, now) }
        // test-fixture-timer: a sampling interval for the memory measurement, not a wait.
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
    let stages = Stages()
    let store = MeetingProcessingCheckpointStore(meetingFolder: dir)
    let meetingID = UUID()
    let (job, _) = try realJob()
    let started = Date()
    let result = try await job.run(
      tracks: [.callSound: audio],
      checkpoint: .init(
        meetingID: meetingID,
        load: {
          if case .checkpoint(let c) = store.load() { return c }
          return nil
        },
        save: { try store.save($0) })
    ) { stage in
      let name: String
      switch stage {
      case .transcribing: name = "asr"
      case .findingSpeakers: name = "speakers"
      case .composing: name = "compose"
      }
      if name != stages.current {
        stages.peak[stages.current] = peak.withLock { $0 }
        peak.withLock { $0 = Self.footprintMB() }
        stages.current = name
        stages.start[name] = Date()
      }
    }
    stages.peak[stages.current] = peak.withLock { $0 }
    sampling.withLock { $0 = false }
    await sampler.value
    let after = Self.footprintMB()
    let checkpointBytes =
      (try? FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.size] as? NSNumber)?
      .intValue ?? -1
    let words = result.composition.text.split(whereSeparator: \.isWhitespace).count
    func at(_ s: String) -> String {
      stages.start[s].map { String(format: "%.1f", $0.timeIntervalSince(started)) } ?? "-"
    }
    print(
      "MEETING_LONG \(label) audio_s=\(Int(result.audioSeconds)) total_s=\(String(format: "%.1f", Date().timeIntervalSince(started))) "
        + "speakers_start_s=\(at("speakers")) compose_start_s=\(at("compose")) "
        + "baseline_mb=\(Int(baseline)) peak_load_mb=\(Int(stages.peak["start"] ?? -1)) "
        + "peak_asr_mb=\(Int(stages.peak["asr"] ?? -1)) peak_pass_mb=\(Int(stages.peak.values.max() ?? -1)) "
        + "peak_speakers_mb=\(Int(stages.peak["speakers"] ?? -1)) peak_compose_mb=\(Int(stages.peak["compose"] ?? -1)) "
        + "after_mb=\(Int(after)) words=\(words) speakers=\(result.composition.speakerCount) "
        + "outcome=\(result.speakerOutcomes[.callSound].map(\.rawValue) ?? "none") "
        + "pieces_failed=\(result.failedPieces) checkpoint_bytes=\(checkpointBytes)")
    #expect(words > 1_000)
    #expect(result.failedPieces == 0)
    // Long-meeting acceptance, not only a measurement: speakers must be labeled.
    #expect(result.speakerOutcomes[.callSound] == .labeled)
    #expect(result.composition.speakerCount > 1)
  }
}

extension MeetingProcessingRealBoundaryTests {
  /// Diagnosis only (#3972 C3b): the same 3-hour track through the diarizer's array input and its
  /// lazy-source input, timed, to see which path is slow. Not part of the shipped behaviour.
  @Test(
    "diarizer timing: array input vs lazy source on the three-hour track",
    .enabled(
      if: ProcessInfo.processInfo.environment["EW_MEETING_DIARIZER_COMPARE"] == "1"
        && MeetingProcessingRealBoundaryTests.longAudio("3H") != nil),
    .tags(.realBoundary), .timeLimit(.minutes(30)))
  func diarizerInputComparison() async throws {
    let source = try #require(Self.longAudio("3H"))
    let dir = try folder("compare")
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = try segments(from: source, into: dir)
    let bundle = try Self.speakerModelBundle()
    let samples = try audio.read(from: 0, count: audio.endSample)

    let models1 = try BundledSpeakerModelLoader.load(in: bundle)
    let arrayAnalyzer = OfflineSpeakerAnalyzer()
    arrayAnalyzer.initialize(models: models1)
    var started = Date()
    let arraySegments = try await arrayAnalyzer.analyze(samples: samples, sampleRate: 16_000) { _, _ in }
    let arraySeconds = Date().timeIntervalSince(started)

    let models2 = try BundledSpeakerModelLoader.load(in: bundle)
    let lazyAnalyzer = OfflineSpeakerAnalyzer()
    lazyAnalyzer.initialize(models: models2)
    started = Date()
    let lazySegments = try await lazyAnalyzer.analyze(meetingTrack: audio) { _, _ in }
    let lazySeconds = Date().timeIntervalSince(started)
    print(
      "MEETING_DIARIZER_COMPARE array_s=\(String(format: "%.1f", arraySeconds)) lazy_s=\(String(format: "%.1f", lazySeconds)) "
        + "array_speakers=\(Set(arraySegments.map(\.speakerId)).count) lazy_speakers=\(Set(lazySegments.map(\.speakerId)).count)")
  }
}
