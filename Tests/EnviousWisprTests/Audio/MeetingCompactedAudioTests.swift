import AVFoundation
import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprCore
import EnviousWisprStorage

/// Recorder CAF tones and their compacted AAC twins, made with the production `.meeting`
/// encoder, for the compacted-audio suites (#3147 PR4B).
enum CompactedAudioFixture {
  /// Writes a 16 kHz mono 16-bit CAF tone (`frequency` Hz at amplitude 0.5) and returns its
  /// recorder descriptor.
  @discardableResult
  static func tone(
    in folder: URL, track: MeetingTrackKind = .microphone, variant: MeetingSegmentVariant = .raw,
    index: Int, startMs: Int, frames: Int, frequency: Double
  ) throws -> MeetingSegmentInfo {
    let name = MeetingSegmentNaming.fileName(
      track: track, variant: variant, index: index, startMs: startMs, partial: false)
    let processing = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let file = try AVAudioFile(
      forWriting: folder.appendingPathComponent(name),
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
      ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for i in 0..<frames {
      buffer.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * frequency * Double(i) / 16_000))
    }
    try file.write(from: buffer)
    return MeetingSegmentInfo(index: index, fileName: name, startMs: startMs, frameCount: frames)
  }

  /// Encodes `source` with the production `.meeting` encoder under its compacted final name and
  /// returns the inventory entry.
  static func compact(
    _ source: MeetingSegmentInfo, in folder: URL, track: MeetingTrackKind = .microphone,
    variant: MeetingSegmentVariant = .raw, inventoryID: UUID
  ) throws -> MeetingCompressedSegment {
    let name = MeetingSegmentNaming.compactedFileName(
      source: source, track: track, variant: variant, inventoryID: inventoryID, partial: false)
    let url = folder.appendingPathComponent(name)
    _ = try SpeechAudioEncoder.encode(
      fileAt: folder.appendingPathComponent(source.fileName), purpose: .meeting, to: url)
    return MeetingCompressedSegment(
      track: track, variant: variant, source: source,
      sourceIdentity: try MeetingStore.audioFileIdentity(
        at: folder.appendingPathComponent(source.fileName)),
      compressed: MeetingSegmentInfo(
        index: source.index, fileName: name, startMs: source.startMs,
        frameCount: source.frameCount),
      compressedIdentity: try MeetingStore.audioFileIdentity(at: url))
  }

  /// Writes the cleaned-copy proof for `twins` and returns its name and identity.
  static func proof(in folder: URL, twins: [MeetingSegmentInfo]) throws -> (
    String, MeetingAudioFileIdentity
  ) {
    let name = MeetingSegmentNaming.cleanedProofName(
      first: twins.map(\.index).min()!, last: twins.map(\.index).max()!)
    let data = try JSONEncoder().encode(MeetingCleanedProof(segments: twins))
    try data.write(to: folder.appendingPathComponent(name))
    return (name, try MeetingStore.audioFileIdentity(at: folder.appendingPathComponent(name)))
  }

  /// Largest absolute difference between two equally long sample runs.
  static func maxDifference(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).map { abs($0 - $1) }.max() ?? 0
  }
}

/// #3147 PR4B: when these fail, a compacted meeting plays or is transcribed from audio shifted
/// on its timeline, with a gap filled or a boundary moved, from a mix of compacted and original
/// files, or with an echo-cleaned copy used without its proof.
@Suite("Compacted meeting audio readers and recovery", .tags(.productOutcome))
struct MeetingCompactedAudioTests {
  private typealias C = CompactedAudioFixture

  /// A meeting folder: microphone segments 1 (0-1 s) and 2 (2-2.5 s, after a 1 s gap), their
  /// cleaned twins with a proof, and one call segment, all compacted under one inventory.
  private struct Meeting {
    let folder: URL
    let raw: [MeetingSegmentInfo]
    let cleaned: [MeetingSegmentInfo]
    let call: MeetingSegmentInfo
    let inventory: MeetingCompressedInventory
  }

  private func meeting() throws -> Meeting {
    let folder = try MeetingAudioFixture.folder("MeetingCompactedAudioTests")
    let raw = [
      try C.tone(in: folder, index: 1, startMs: 0, frames: 16_000, frequency: 440),
      try C.tone(in: folder, index: 2, startMs: 2_000, frames: 8_000, frequency: 660),
    ]
    let cleaned = [
      try C.tone(
        in: folder, variant: .cleaned, index: 1, startMs: 0, frames: 16_000, frequency: 330),
      try C.tone(
        in: folder, variant: .cleaned, index: 2, startMs: 2_000, frames: 8_000, frequency: 550),
    ]
    let call = try C.tone(
      in: folder, track: .callSound, index: 3, startMs: 500, frames: 12_000, frequency: 880)
    let proof = try C.proof(in: folder, twins: cleaned)
    let id = UUID()
    var segments = try raw.map { try C.compact($0, in: folder, inventoryID: id) }
    segments += try cleaned.map {
      try C.compact($0, in: folder, variant: .cleaned, inventoryID: id)
    }
    segments.append(try C.compact(call, in: folder, track: .callSound, inventoryID: id))
    let inventory = MeetingCompressedInventory(
      id: id, transcriptGeneration: nil, segments: segments, cleanedProofs: [proof.0: proof.1])
    return Meeting(folder: folder, raw: raw, cleaned: cleaned, call: call, inventory: inventory)
  }

  private func compactedName(_ meeting: Meeting, _ source: MeetingSegmentInfo) throws -> String {
    try #require(meeting.inventory.segments.first { $0.source == source }).compressed.fileName
  }

  // MARK: - Reader

  @Test("compacted segments read at the recorder's start and length; the gap stays silence")
  func readsAtLogicalTimeline() throws {
    let m = try meeting()
    let compacted = MeetingTrackAudio(
      segments: try m.raw.map {
        MeetingSegmentInfo(
          index: $0.index, fileName: try compactedName(m, $0), startMs: $0.startMs,
          frameCount: $0.frameCount)
      }, in: m.folder)
    let original = MeetingTrackAudio(segments: m.raw, in: m.folder)
    #expect(compacted.problems.isEmpty)
    #expect(compacted.segments.map(\.startSample) == [0, 32_000])
    #expect(compacted.segments.map(\.frameCount) == [16_000, 8_000])
    #expect(compacted.segments.allSatisfy { $0.compressed })
    #expect(compacted.endSample == original.endSample)
    #expect(compacted.runs == original.runs)
    // The gap (1-2 s) is silence, not codec padding.
    #expect(try compacted.read(from: 16_000, count: 16_000).allSatisfy { $0 == 0 })
    // A forward seek into the second segment and a backward one into the first read the same
    // tone as the original, sample-aligned (AAC at 48 kbps stays within a small error).
    for (start, count) in [(34_000, 1_600), (4_000, 1_600)] {
      let a = try compacted.read(from: start, count: count)
      let b = try original.read(from: start, count: count)
      #expect(C.maxDifference(a, b) < 0.1, "at \(start)")
      #expect(a.contains { abs($0) > 0.3 }, "real audio at \(start)")
      // Sample-aligned: the original matches best with no shift at all (a one-sample shift of
      // these tones alone moves the error by about as much as the codec does).
      let wide = try original.read(from: start - 32, count: count + 64)
      let errors = (0...64).map { lag in
        zip(a, wide[lag..<(lag + count)]).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
      }
      #expect(errors.firstIndex(of: errors.min()!) == 32, "best shift at \(start)")
    }
  }

  @Test("codec length differences never move a boundary: short decodes end in silence")
  func logicalLengthWins() throws {
    let m = try meeting()
    let name = try compactedName(m, m.raw[1])
    let url = m.folder.appendingPathComponent(name)
    let decoded = Int(try AVAudioFile(forReading: url).length)
    // Asked for 400 frames more than the file has (within the 800-frame tolerance): the
    // segment keeps the logical end and its last frames read as silence.
    let longer = MeetingTrackAudio(sources: [
      .init(url: url, startMs: 0, logicalFrames: decoded + 400)
    ])
    #expect(longer.problems.isEmpty)
    #expect(longer.endSample == decoded + 400)
    #expect(try longer.read(from: decoded, count: 400).allSatisfy { $0 == 0 })
    // Asked for fewer: the segment ends at the logical end.
    let shorter = MeetingTrackAudio(sources: [
      .init(url: url, startMs: 0, logicalFrames: decoded - 400)
    ])
    #expect(shorter.endSample == decoded - 400)
    // Farther than the encoder's own tolerance: refused as the wrong file.
    let wrong = MeetingTrackAudio(sources: [
      .init(url: url, startMs: 0, logicalFrames: decoded + 2_000)
    ])
    #expect(wrong.problems == [.incompatibleFormat(fileName: name)])
    // A compacted file handed to the recorder-file reader is never read as a CAF.
    let asRecorder = MeetingTrackAudio(files: [(url, 0)])
    #expect(asRecorder.problems == [.incompatibleFormat(fileName: name)])
  }

  // MARK: - Recovery

  @Test("recovery reads the committed inventory alone, and carries the cleaned proof across")
  func recoveryUsesInventory() throws {
    let m = try meeting()
    let before = Set(try FileManager.default.contentsOfDirectory(atPath: m.folder.path))
    let report = MeetingTrackRecovery.recover(folder: m.folder, inventory: m.inventory, identity: MeetingStore.audioFileIdentity(at:))
    #expect(report.representation == .aacM4A)
    #expect(report.problems.isEmpty && report.cleanedProblems.isEmpty)
    #expect(report.compressedProblems.isEmpty)
    #expect(
      report.segments[.microphone]?.map(\.fileName) == (try m.raw.map { try compactedName(m, $0) }))
    #expect(report.segments[.microphone]?.map(\.frameCount) == [16_000, 8_000])
    #expect(report.segments[.callSound]?.map(\.startMs) == [500])
    #expect(
      report.cleanedSegments.map(\.fileName) == (try m.cleaned.map { try compactedName(m, $0) }))
    #expect(report.highestIndex == [.microphone: 2, .callSound: 3])
    let provenance = MeetingEchoProvenance.compactionFixture
    guard
      case .cleaned(let set, _) = MeetingMicrophoneSelection.decide(
        raw: report.segments[.microphone] ?? [], report: report, provenance: provenance)
    else {
      Issue.record("the proof did not carry across to the compacted twins")
      return
    }
    #expect(set == report.cleanedSegments)
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: m.folder.path)) == before)
  }

  @Test("a proof changed after the inventory was made confirms nothing")
  func changedProofIsNotProof() throws {
    let m = try meeting()
    let proofName = try #require(m.inventory.cleanedProofs.keys.first)
    let url = m.folder.appendingPathComponent(proofName)
    var data = try Data(contentsOf: url)
    data.append(contentsOf: Array(" ".utf8))
    try data.write(to: url)
    let report = MeetingTrackRecovery.recover(folder: m.folder, inventory: m.inventory, identity: MeetingStore.audioFileIdentity(at:))
    #expect(report.cleanedProblems == [.unreadableProof(fileName: proofName)])
    #expect(report.cleanedConfirmed.isEmpty)
    #expect(
      MeetingMicrophoneSelection.decide(
        raw: report.segments[.microphone] ?? [], report: report, provenance: .compactionFixture)
        == .raw(.cleanedProblem))
  }

  @Test("a missing compacted file with unchanged originals reads the originals, whole")
  func fallsBackToVerifiedOriginals() throws {
    let m = try meeting()
    try FileManager.default.removeItem(
      at: m.folder.appendingPathComponent(try compactedName(m, m.raw[1])))
    let report = MeetingTrackRecovery.recover(folder: m.folder, inventory: m.inventory, identity: MeetingStore.audioFileIdentity(at:))
    #expect(report.representation == .pcmCAF)
    #expect(report.compressedProblems.contains(.fellBackToOriginals))
    #expect(report.problems.isEmpty)
    #expect(report.segments[.microphone] == m.raw)
    #expect(report.segments[.callSound] == [m.call])
    #expect(report.cleanedSegments == m.cleaned)
    // Every file is an original: never a mix.
    #expect(
      (report.segments.values.flatMap { $0 } + report.cleanedSegments).allSatisfy {
        MeetingSegmentNaming.parse($0.fileName) != nil
      })
    #expect(
      MeetingMicrophoneSelection.decide(
        raw: report.segments[.microphone] ?? [], report: report, provenance: .compactionFixture)
        == .cleaned(m.cleaned, .compactionFixture))
  }

  @Test("a missing compacted file with a changed original is damage, never a mix")
  func damageWithoutVerifiedOriginals() throws {
    let m = try meeting()
    let missing = try compactedName(m, m.raw[1])
    try FileManager.default.removeItem(at: m.folder.appendingPathComponent(missing))
    try C.tone(in: m.folder, index: 1, startMs: 0, frames: 16_000, frequency: 450)
    let report = MeetingTrackRecovery.recover(folder: m.folder, inventory: m.inventory, identity: MeetingStore.audioFileIdentity(at:))
    #expect(report.representation == .aacM4A)
    #expect(report.problems == [.unreadableFinal(fileName: missing)])
    #expect(report.compressedProblems.contains(.originalsUnavailable))
    #expect(report.segments[.microphone]?.map(\.fileName) == [try compactedName(m, m.raw[0])])
  }

  @Test("a refused inventory is never read; recorder files it does not cover are reported")
  func refusedAndUncovered() throws {
    let m = try meeting()
    let extra = try C.tone(in: m.folder, index: 4, startMs: 3_000, frames: 1_600, frequency: 300)
    let duplicated = MeetingCompressedInventory(
      id: m.inventory.id, transcriptGeneration: nil,
      segments: m.inventory.segments + [m.inventory.segments[0]],
      cleanedProofs: m.inventory.cleanedProofs)
    let report = MeetingTrackRecovery.recover(folder: m.folder, inventory: duplicated, identity: MeetingStore.audioFileIdentity(at:))
    #expect(report.compressedProblems.contains(.uncoveredOriginal(fileName: extra.fileName)))
    #expect(
      report.compressedProblems.contains(
        .selectionRefused(.duplicateInInventory(m.inventory.segments[0].key))))
    // The originals are intact, so they are read whole; the uncovered file is not among them.
    #expect(report.compressedProblems.contains(.fellBackToOriginals))
    #expect(report.segments[.microphone] == m.raw)
    #expect(report.highestIndex[.microphone] == 4)
  }

  @Test("with an inventory, recovery never promotes or renames a recorder partial")
  func noPromotionUnderInventory() throws {
    let m = try meeting()
    let partial = try MeetingAudioFixture.writeSegment(
      in: m.folder, index: 5, startMs: 4_000, frames: 1_600, partial: true)
    _ = MeetingTrackRecovery.recover(folder: m.folder, inventory: m.inventory, identity: MeetingStore.audioFileIdentity(at:))
    #expect(FileManager.default.fileExists(atPath: partial.path))
  }
}

extension MeetingEchoProvenance {
  static var compactionFixture: MeetingEchoProvenance {
    MeetingEchoProvenance(library: "compaction test", configuration: "aec3-16k-mono")
  }
}
