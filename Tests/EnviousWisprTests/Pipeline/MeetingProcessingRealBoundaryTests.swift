@preconcurrency import AVFoundation
import CryptoKit
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
  private func segments(
    from source: URL, into folder: URL, track: MeetingTrackKind = .callSound
  ) throws -> MeetingTrackAudio {
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
        track: track, index: index, startMs: startSample / 16, partial: false)
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
        transcribe: { samples, language in
          try await engine.transcribe(samples: samples, language: language)
        },
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
    .tags(.realBoundary), .timeLimit(.minutes(3)), .realBoundaryRun)
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
    let result = try await job.runTestAttempt(tracks: [.callSound: audio], language: nil) { _ in }
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

  /// #3973 C3: the same pass on the real Whisper Large v3 Turbo (the #3705 evaluation copy,
  /// never the app's data) through the meeting's own Whisper engine: real speech becomes
  /// sentence-timed, labeled turns, the engine is freed at the end, and a checkpoint saved by
  /// the pass rebuilds the same transcript without decoding again.
  @Test(
    "#3973 C3: a two-voice recording becomes sentence-timed turns through the real Whisper pass, and resumes from its checkpoint",
    .enabled(if: WhisperProductionWiringRealBoundaryTests.modelIsPresent),
    .tags(.realBoundary), .timeLimit(.minutes(3)), .realBoundaryRun)
  func twoVoiceRecordingOnWhisper() async throws {
    let fixture = WhisperProductionWiringRealBoundaryTests.repoRoot
      .appending(path: "Tests/Fixtures/speaker-diarization/two-voice-30s.wav")
    let dir = try folder("two-voice-whisper")
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = try segments(from: fixture, into: dir)
    let speakerBundle = try Self.speakerModelBundle()
    let engine = LiveMeetingWhisperEngine(driver: LiveWhisperExecutorDriver())
    let modelPath = WhisperProductionWiringRealBoundaryTests.evaluationModel.path
    final class Counts { var decodes = 0 }
    let counts = Counts()
    func job() -> MeetingTranscriptionJob {
      var configuration = MeetingTranscriptionJob.Configuration()
      configuration.cutsPieces = false
      return MeetingTranscriptionJob(
        dependencies: .init(
          isDictationIdle: { true }, waitUntilDictationIdle: {}, beginModelUse: {},
          endModelUse: {},
          loadEngine: { try await engine.load(modelPath: modelPath) },
          transcribe: { samples, language in
            counts.decodes += 1
            return try await engine.transcribe(samples: samples, language: language)
          },
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
          engineIdentity: { "whisper-large-v3-turbo-gguf:eval" },
          resolution: MeetingEngineResolution(engine: .whisper, effectiveLanguage: "en")),
        configuration: configuration)
    }
    let saved = OSAllocatedUnfairLock<MeetingProcessingCheckpoint?>(initialState: nil)
    let access = MeetingTranscriptionJob.CheckpointAccess(
      meetingID: UUID(), load: { saved.withLock { $0 } },
      save: { checkpoint in saved.withLock { $0 = checkpoint } })
    let attempt = MeetingAttemptConfiguration(
      requestedEngine: .whisper, languageIntent: "en", requestedEffectiveLanguage: "en")

    let result = try await job().run(
      tracks: [.callSound: audio], language: "en", checkpoint: access, onStage: { _ in },
      attempt: attempt)
    let words = result.composition.text.split(whereSeparator: \.isWhitespace).count
    print(
      "MEETING_REAL whisper two-voice words=\(words) turns=\(result.composition.turns.count) speakers=\(result.composition.speakerCount) outcome=\(result.speakerOutcomes[.callSound].map(\.rawValue) ?? "none")"
    )
    #expect(words >= 10)
    #expect(result.failedPieces == 0)
    #expect(
      result.speakerOutcomes[.callSound] == .labeled
        || result.speakerOutcomes[.callSound] == .single)
    #expect(result.composition.turns.allSatisfy { $0.granularity == .segment })
    #expect(result.resolved.resolvedEngine == .whisper)
    #expect(await engine.isLoaded == false, "the engine is freed when the pass ends")
    let decodes = counts.decodes
    #expect(decodes >= 1)

    let resumed = try await job().run(
      tracks: [.callSound: audio], language: "en", checkpoint: access, onStage: { _ in },
      attempt: attempt)
    #expect(counts.decodes == decodes, "every piece came from the checkpoint")
    #expect(resumed.composition == result.composition)
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
    .tags(.realBoundary), .timeLimit(.minutes(30)), .realBoundaryRun)
  func threeHourMeeting() async throws { try await longMeeting("3H") }

  @Test(
    "a five-hour meeting completes with measured memory and time",
    .enabled(
      if: MeetingProcessingRealBoundaryTests.ultraIsInstalled
        && MeetingProcessingRealBoundaryTests.longAudio("5H") != nil),
    .tags(.realBoundary), .timeLimit(.minutes(30)), .realBoundaryRun)
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
    let result = try await job.runTestAttempt(
      tracks: [.callSound: audio], language: nil,
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
    .tags(.realBoundary), .timeLimit(.minutes(30)), .realBoundaryRun)
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

// MARK: - #4254 representative voices (plan §16.5)

/// One case of `Tests/Fixtures/meeting-voices/manifest.json` (written by its
/// `generate-fixtures.py`): literal scripts per voice, and the whole reference when the words
/// have one order (nil for overlapping voices, which are scored per voice).
struct MeetingVoiceCase: Decodable, Sendable {
  struct Voice: Decodable, Sendable { let text: String }
  let id: String
  let file: String
  let reference: String?
  let language: String?
  let voices: [Voice]
  let sha256: String

  static let fixtureDirectory = "Tests/Fixtures/meeting-voices"
  static let expectedCount = 7

  static func load(root: URL) throws -> [MeetingVoiceCase] {
    try JSONDecoder().decode(
      [MeetingVoiceCase].self,
      from: Data(contentsOf: root.appending(path: "\(fixtureDirectory)/manifest.json")))
  }

  /// The literal word sequences the output is scored against.
  var references: [[String]] {
    if let reference { return [Self.words(reference)] }
    return voices.map { Self.words($0.text) }
  }

  static func words(_ text: String) -> [String] {
    text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
  }

  /// Ordered alignment of `words` to `reference` by longest common subsequence: reference words
  /// missing (deletions, in order) and words not in the reference (insertions). A substitution
  /// is one of each.
  static func edits(_ words: [String], against reference: [String]) -> (
    missing: [String], extra: [String], missingAt: [Int]
  ) {
    let n = words.count
    let m = reference.count
    var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
      for j in stride(from: m - 1, through: 0, by: -1) {
        table[i][j] =
          words[i] == reference[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
      }
    }
    var missing: [String] = []
    var missingAt: [Int] = []
    var extra: [String] = []
    var (i, j) = (0, 0)
    while i < n || j < m {
      if i < n, j < m, words[i] == reference[j] {
        i += 1
        j += 1
      } else if j < m, i == n || table[i][j + 1] >= table[i + 1][j] {
        missing.append(reference[j])
        missingAt.append(j)
        j += 1
      } else {
        extra.append(words[i])
        i += 1
      }
    }
    return (missing, extra, missingAt)
  }

}

extension MeetingProcessingRealBoundaryTests {
  struct DetectionUnavailable: Error {}

  /// The approved #3705 turbo Q8_0, by content.
  nonisolated static let turboDigest = "b2e30cc286bc9f3aba4db9099fc7403543497c05ce7100d0d83091ddfd25a183"

  /// #4254 §16.5: each representative voice case enters the meeting pass as the microphone track
  /// or the call-sound track, on the real turbo model with the pinned speech detector, beside
  /// the same pass with detection unavailable (today's undetected decode). Detection may lose no
  /// word the undetected decode keeps; music and noise alone give no words.
  /// **What the user sees when this fails:** a quiet, soft, brief, overlapping, accompanied or
  /// non-English contribution is missing from the saved meeting transcript, or background
  /// music becomes words.
  @Test(
    "#4254: representative voices keep their words through the real meeting pass on each track",
    .enabled(
      if: WhisperProductionWiringRealBoundaryTests.modelIsPresent && PinnedVADModel.isCheckedIn),
    .tags(.realBoundary), .timeLimit(.minutes(20)), .realBoundaryRun,
    arguments: [MeetingTrackKind.microphone, .callSound])
  func representativeVoicesFinal(track: MeetingTrackKind) async throws {
    let root = WhisperProductionWiringRealBoundaryTests.repoRoot
    let modelPath = WhisperProductionWiringRealBoundaryTests.evaluationModel.path
    let digest = SHA256.hash(data: try Data(contentsOf: URL(filePath: modelPath), options: .mappedIfSafe))
      .map { String(format: "%02x", $0) }.joined()
    try #require(digest == Self.turboDigest, "requires the approved turbo Q8_0 model")
    let cases = try MeetingVoiceCase.load(root: root)
    try #require(cases.count == MeetingVoiceCase.expectedCount, "every §16.5 case is in the manifest")

    // The pinned detector through its production loader, from a bundle linking the asset.
    let vadRoot = TestTemporaryDirectory.url
      .appendingPathComponent("MeetingVoices-VAD-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: vadRoot, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: vadRoot.appendingPathComponent("\(BundledVADModelLoader.pinnedModelName).mlmodelc"),
      withDestinationURL: PinnedVADModel.url)
    let vadPath = vadRoot.path
    let detections = OSAllocatedUnfairLock(initialState: 0)

    func pass(_ fixture: URL, language: String, detect: Bool) async throws -> String {
      let dir = try folder("voices")
      defer { try? FileManager.default.removeItem(at: dir) }
      let audio = try segments(from: fixture, into: dir, track: track)
      let engine = LiveMeetingWhisperEngine(
        driver: LiveWhisperExecutorDriver(),
        detectSpeech: { samples in
          guard detect else { throw DetectionUnavailable() }
          detections.withLock { $0 += 1 }
          return try await MeetingSpeechDetector.spans(
            in: samples, modelBundle: Bundle(path: vadPath) ?? .main)
        })
      var configuration = MeetingTranscriptionJob.Configuration()
      configuration.cutsPieces = false
      let job = MeetingTranscriptionJob(
        dependencies: .init(
          isDictationIdle: { true }, waitUntilDictationIdle: {}, beginModelUse: {}, endModelUse: {},
          loadEngine: { try await engine.load(modelPath: modelPath) },
          transcribe: { samples, language in
            try await engine.transcribe(samples: samples, language: language)
          },
          unloadEngine: { await engine.unload() },
          analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }),
        configuration: configuration)
      let result = try await job.runTestAttempt(tracks: [track: audio], language: language) { _ in }
      #expect(result.failedPieces == 0, "no piece failed")
      return result.composition.text
    }

    var lost: [String: [String]] = [:]
    for item in cases {
      let fixture = root.appending(path: "\(MeetingVoiceCase.fixtureDirectory)/\(item.file)")
      let bytes = try Data(contentsOf: fixture)
      try #require(
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == item.sha256,
        "\(item.id): fixture matches its manifest hash")
      let language = item.language ?? "en"
      let before = detections.withLock { $0 }
      let detected = try await pass(fixture, language: language, detect: true)
      #expect(detections.withLock { $0 } > before, "\(item.id): the detector really ran")
      let undetected = try await pass(fixture, language: language, detect: false)
      let words = MeetingVoiceCase.words(detected)
      let baseline = MeetingVoiceCase.words(undetected)
      if item.references == [[]] {
        print("VOICES final track=\(track.rawValue) case=\(item.id) detected=\(words) undetected=\(baseline)")
        #expect(words.isEmpty, "\(item.id): music and noise alone give no words: \(detected)")
        continue
      }
      for (index, reference) in item.references.enumerated() {
        let g = MeetingVoiceCase.edits(words, against: reference)
        let u = MeetingVoiceCase.edits(baseline, against: reference)
        print(
          "VOICES final track=\(track.rawValue) case=\(item.id) ref=\(index) "
            + "detected_missing=\(g.missing) detected_extra=\(g.extra) "
            + "undetected_missing=\(u.missing) undetected_extra=\(u.extra) "
            + "detected=\"\(detected)\" undetected=\"\(undetected)\"")
        // By reference occurrence: a word detection lost is never offset by one it kept elsewhere.
        let kept = Set(u.missingAt)
        let vadLost = g.missingAt.filter { !kept.contains($0) }.map { "\($0):\(reference[$0])" }
        if !vadLost.isEmpty { lost["\(item.id)#\(index)"] = vadLost }
      }
    }
    #expect(lost.isEmpty, "words detection lost that the undetected decode kept: \(lost)")
  }
}
