import AVFoundation
import EnviousWisprAppKitTestSupport
import Foundation
import Testing
import os

@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

/// #4355 PR B: the microphone copy a final pass reads. When these fail, a transcript resumes
/// words decoded from the other copy, or transcription and speaker analysis disagree on which
/// audio the microphone track is.
@Suite("Meeting pass microphone copy and provenance (#4355)", .serialized, .tags(.productOutcome))
@MainActor
struct MeetingTranscriptionJobProvenanceTests {
  static let provenance = MeetingEchoProvenance(
    library: "webrtc-audio-processing 2.1 846fe90 ew-4355.3", configuration: "aec3-16k-mono")

  private func folder() throws -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent("MeetingProvenanceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A 16 kHz mono 16-bit CAF holding `seconds` of the constant `level`.
  private func file(
    in dir: URL, variant: MeetingSegmentVariant, level: Float, seconds: Double = 4,
    track: MeetingTrackKind = .microphone
  ) throws -> (url: URL, startMs: Int) {
    let url = dir.appendingPathComponent(
      MeetingSegmentNaming.fileName(
        track: track, variant: variant, index: 1, startMs: 0, partial: false))
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let out = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
      ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(seconds * 16_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = level }
    try out.write(from: buffer)
    return (url, 0)
  }

  private func key(_ audio: MeetingTrackAudio, _ copy: MeetingMicrophoneCopy) throws
    -> MeetingProcessingCheckpoint.Key
  {
    try MeetingTranscriptionJob.key(
      meetingID: UUID(uuidString: "43550000-0000-4000-8000-000000000001")!,
      attemptID: MeetingTestAttempt.id, tracks: [.microphone: audio], order: [.microphone],
      language: nil,
      engine: .init(requested: .parakeet, resolved: .parakeet, modelIdentity: "ultra:r1"),
      microphoneCopy: copy, MeetingTranscriptionJob.Configuration())
  }

  @Test(
    "the checkpoint key names the microphone copy and its provenance; version 5 work is never reused"
  )
  func keyCarriesCopyAndProvenance() throws {
    let dir = try folder()
    let audio = MeetingTrackAudio(files: [try file(in: dir, variant: .raw, level: 0.25)])
    #expect(audio.segments.count == 1)
    let raw = try key(audio, .raw(nil))
    let cleaned = try key(audio, .cleaned(Self.provenance))
    let otherCleaner = try key(
      audio,
      .cleaned(MeetingEchoProvenance(library: "another build", configuration: "aec3-16k-mono")))
    // Raw fallback still carries the recording's provenance: the same files recorded under
    // another cleaner, or with none, are different inputs.
    let rawUnderCleaner = try key(audio, .raw(Self.provenance))
    let rawUnderOther = try key(
      audio, .raw(MeetingEchoProvenance(library: "another build", configuration: "aec3-16k-mono")))
    #expect(rawUnderCleaner != raw)
    #expect(rawUnderCleaner != rawUnderOther)
    #expect(rawUnderCleaner != cleaned)
    #expect(rawUnderCleaner.microphoneCopy == .raw(Self.provenance))
    #expect(raw.processingVersion == 7)
    #expect(raw != cleaned)
    #expect(cleaned != otherCleaner)
    #expect(raw.microphoneCopy == .raw(nil))
    #expect(cleaned.microphoneCopy == .cleaned(Self.provenance))

    // Round trip keeps the copy; a key written before it decodes with none and version 5.
    let decoded = try JSONDecoder().decode(
      MeetingProcessingCheckpoint.Key.self, from: try JSONEncoder().encode(cleaned))
    #expect(decoded == cleaned)
    var object = try #require(
      try JSONSerialization.jsonObject(with: try JSONEncoder().encode(raw)) as? [String: Any])
    object.removeValue(forKey: "microphoneCopy")
    object["processingVersion"] = 5
    let old = try JSONDecoder().decode(
      MeetingProcessingCheckpoint.Key.self, from: try JSONSerialization.data(withJSONObject: object)
    )
    #expect(old.microphoneCopy == nil)
    #expect(old != raw)
  }

  @Test(
    "transcription and speaker analysis both read the copy the attempt chose, and a raw checkpoint never resumes a cleaned pass"
  )
  func bothConsumersReadTheChosenCopy() async throws {
    let rawDir = try folder()
    let cleanedDir = try folder()
    let raw = MeetingTrackAudio(files: [try file(in: rawDir, variant: .raw, level: 0.25)])
    let cleaned = MeetingTrackAudio(
      files: [try file(in: cleanedDir, variant: .cleaned, level: -0.125)])
    #expect(raw.segments.count == 1 && cleaned.segments.count == 1)

    let heard = OSAllocatedUnfairLock(initialState: [Float]())
    let analyzed = OSAllocatedUnfairLock(initialState: [String]())
    var config = MeetingTranscriptionJob.Configuration()
    config.pieceTargetSeconds = 20
    config.pieceSearchSeconds = 5
    func job() -> MeetingTranscriptionJob {
      MeetingTranscriptionJob(
        dependencies: .init(
          isDictationIdle: { true }, waitUntilDictationIdle: {}, beginModelUse: {},
          endModelUse: {}, loadEngine: {},
          transcribe: { samples, _ in
            // The level the engine was handed (the constant file level, after 16-bit storage).
            heard.withLock { $0.append(samples.first { $0 != 0 } ?? 0) }
            return ASRResult(
              text: "w", language: nil, duration: Double(samples.count) / 16_000,
              processingTime: 0, backendType: .parakeet,
              wordTimings: [ASRWordTiming(word: "w", range: 0..<1, startMs: 0, endMs: 400)])
          }, unloadEngine: {},
          analyzeSpeakers: { audio in
            analyzed.withLock { $0.append(contentsOf: audio.segments.map(\.url.lastPathComponent)) }
            return MeetingSpeakerAnalysis(outcome: .single, segments: [])
          }),
        configuration: config)
    }
    let stored = OSAllocatedUnfairLock<MeetingProcessingCheckpoint?>(initialState: nil)
    let access = MeetingTranscriptionJob.CheckpointAccess(
      meetingID: UUID(uuidString: "43550000-0000-4000-8000-000000000002")!,
      load: { stored.withLock { $0 } }, save: { checkpoint in stored.withLock { $0 = checkpoint } })

    // A raw pass first, which leaves a checkpoint.
    let first = try await job().run(
      tracks: [.microphone: raw], microphoneCopy: .raw(nil), language: nil, checkpoint: access,
      onStage: { _ in }, attempt: MeetingTestAttempt.attempt(language: nil))
    #expect(first.resumedPieces == 0)
    #expect(stored.withLock { $0 } != nil)

    // The cleaned pass of the same attempt: nothing resumes from the raw checkpoint, and both
    // consumers read the cleaned file.
    heard.withLock { $0.removeAll() }
    analyzed.withLock { $0.removeAll() }
    let second = try await job().run(
      tracks: [.microphone: cleaned], microphoneCopy: .cleaned(Self.provenance), language: nil,
      checkpoint: access, onStage: { _ in }, attempt: MeetingTestAttempt.attempt(language: nil))
    #expect(second.resumedPieces == 0)
    let levels = heard.withLock { $0 }
    #expect(!levels.isEmpty)
    #expect(levels.allSatisfy { abs($0 - -0.125) < 0.001 })
    let names = analyzed.withLock { $0 }
    #expect(!names.isEmpty)
    #expect(names.allSatisfy { $0.hasPrefix(MeetingSegmentNaming.cleanedMicrophoneStem + "-") })
    #expect(stored.withLock { $0 }?.key.microphoneCopy == .cleaned(Self.provenance))
  }

  /// #4355 PR B (founder 2026-11-04): the pass hides text echo only when it reads the raw
  /// microphone. When this fails, a cleaned meeting hides the user's own words that repeat the
  /// call, or a raw fallback (older recording, crash) shows the call's words as the user's.
  @Test("the pass hides repeated call words on the raw microphone and never on the cleaned copy")
  func echoHidingFollowsTheChosenCopy() async throws {
    let dir = try folder()
    let call = MeetingTrackAudio(
      files: [try file(in: dir, variant: .raw, level: 0.25, track: .callSound)])
    let raw = MeetingTrackAudio(files: [try file(in: dir, variant: .raw, level: 0.25)])
    let cleaned = MeetingTrackAudio(files: [try file(in: dir, variant: .cleaned, level: 0.125)])
    func job() -> MeetingTranscriptionJob {
      MeetingTranscriptionJob(
        dependencies: .init(
          isDictationIdle: { true }, waitUntilDictationIdle: {}, beginModelUse: {},
          endModelUse: {}, loadEngine: {},
          transcribe: { samples, _ in
            // Both tracks hear the same three words at the same time: the echo case.
            ASRResult(
              text: "see you tomorrow", language: nil, duration: Double(samples.count) / 16_000,
              processingTime: 0, backendType: .parakeet,
              wordTimings: [
                ASRWordTiming(word: "see", range: 0..<3, startMs: 100, endMs: 400),
                ASRWordTiming(word: "you", range: 4..<7, startMs: 400, endMs: 700),
                ASRWordTiming(word: "tomorrow", range: 8..<16, startMs: 700, endMs: 1200),
              ])
          }, unloadEngine: {},
          analyzeSpeakers: { _ in MeetingSpeakerAnalysis(outcome: .single, segments: []) }))
    }
    let rawPass = try await job().run(
      tracks: [.microphone: raw, .callSound: call], microphoneCopy: .raw(nil), language: nil,
      onStage: { _ in }, attempt: MeetingTestAttempt.attempt(language: nil))
    #expect(!rawPass.composition.echoTurnIDs.isEmpty, "raw: the repeated call words are hidden")
    let cleanedPass = try await job().run(
      tracks: [.microphone: cleaned, .callSound: call],
      microphoneCopy: .cleaned(Self.provenance), language: nil,
      onStage: { _ in }, attempt: MeetingTestAttempt.attempt(language: nil))
    #expect(cleanedPass.composition.echoTurnIDs.isEmpty, "cleaned: nothing is hidden")
    #expect(
      cleanedPass.composition.turns.contains { $0.speakerId.hasPrefix("mic") },
      "cleaned: the microphone words stay visible")
  }
}
