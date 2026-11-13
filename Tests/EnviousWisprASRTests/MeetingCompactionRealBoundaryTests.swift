import AVFoundation
import CryptoKit
import EnviousWisprAudio
import EnviousWisprCore
@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprTranscribeCpp

/// #3147 PR4B, plan section 16 C6: does a compacted meeting (each recorder segment re-encoded as
/// AAC-LC by the production `.meeting` encoder) give the app the same audio, at the same times,
/// and the same words from both engines, as the original recording?
///
/// **What the user sees when this fails:** after the app compacts a meeting, playing it jumps,
/// loses or misplaces a stretch, a gap fills with sound, the echo-cleaned microphone copy is no
/// longer used for Transcribe again, or Transcribe again gives worse words. Original audio is only
/// ever removed after this passes on every supported macOS, the macOS 14 floor included.
///
/// The matrix is frozen in `Tests/Fixtures/meeting-compaction/c6-matrix.json`: one meeting built
/// from the pinned meeting-voices corpus (microphone and call tracks, three segments each, a real
/// gap and a contiguous boundary on each, a proof-backed echo-cleaned microphone copy, noise,
/// music and Russian), read in three arms through the production reader route (`C6Route`):
/// - `original`: no inventory, the recorder's CAF files;
/// - `compacted`: the committed inventory, CAF still on disk;
/// - `retired`: the committed inventory with the source CAF removed (a temporary copy only).
///
/// Run on this Mac (`--host local`) or a backup Mac (`--host <name>`; the backup route forwards
/// no other test settings, so the harness needs none): the Mac must have the app's Parakeet Ultra
/// and Whisper turbo Q8_0 models installed (the test checks the Whisper sha256).
/// `scripts/xcode-test.sh --host <local|name> --real-boundary --filter EnviousWisprASRTests/MeetingCompactionRealBoundaryTests`,
/// then score the log: `python3 -I Tests/Fixtures/meeting-compaction/score_c6.py <worktree> <log>`.
/// Every test asserts its own expected count; a missing engine or model fails, never skips.
enum C6Fixture {
  /// The approved Whisper turbo Q8_0: the override or #3705 copy the other real-boundary suites
  /// use when present, else the copy the app itself installs, so a backup Mac with the app's
  /// models needs no test settings. The sha256 is checked before use either way.
  static var whisperModelPath: String {
    if TranscribeCppRealBoundaryFixture.modelIsPresent {
      return TranscribeCppRealBoundaryFixture.modelPath
    }
    return URL.applicationSupportDirectory.appending(
      path: "EnviousWispr/Models/whisper-gguf/whisper-large-v3-turbo-Q8_0.gguf"
    ).path
  }

  static let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()  // EnviousWisprASRTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root
  static let matrixURL = repoRoot.appending(
    path: "Tests/Fixtures/meeting-compaction/c6-matrix.json")

  /// Instrument control only (`TEST_RUNNER_EW_C6_CONTROL=identity`): the compacted and retired
  /// arms read the ORIGINAL files, so every check must pass with identical audio and words. A
  /// control run prints `C6 mode control=identity`, and `score_c6.py` refuses any log that holds
  /// it: a control never counts as C6 evidence.
  static var identityControl: Bool {
    ProcessInfo.processInfo.environment["EW_C6_CONTROL"] == "identity"
  }

  /// The arm's folder and inventory: the committed inventory, or the original files in the
  /// identity control.
  static func arm(_ meeting: Meeting, folder: URL) -> (
    folder: URL, inventory: MeetingCompressedInventory?
  ) {
    identityControl ? (meeting.folder, nil) : (folder, meeting.inventory)
  }

  // MARK: - The frozen matrix

  struct Matrix: Decodable {
    struct Gates: Decodable {
      let meetingBitRate: Int
      let sampleRate: Double
      let durationToleranceMs: Double
      let maxMBPerTrackHour: Double
      let maxWERIncreasePoints: Double
      let seekMinCorrelation: Double
      let seekMaxLagSamples: Int
      let seekSearchLagSamples: Int
      let levelToleranceDb: Double
      let cleanedLevelRatio: Double
      let cleanedLevelRatioTolerance: Double
    }
    struct Provenance: Decodable {
      let library: String
      let configuration: String
    }
    struct SegmentSpec: Decodable {
      let index: Int
      let clip: String
      let language: String
      let place: String
    }
    struct TrackSpec: Decodable {
      let track: MeetingTrackKind
      let segments: [SegmentSpec]
      let cleanedTwin: Bool
    }
    struct Meeting: Decodable {
      let gapMs: Int
      let provenance: Provenance
      let cleanedGain: Float
      let tracks: [TrackSpec]
    }
    struct Seek: Decodable {
      let id: String
      let track: MeetingTrackKind
      let anchor: String
      let index: Int
      let offsetMs: Int
      let lengthMs: Int
      let kind: String
    }
    struct SizeTrack: Decodable {
      let seconds: Int
      let segmentSeconds: Int
    }
    struct Expected: Decodable {
      let clips: Int
      let segments: Int
      let compactedFiles: Int
      let seekWindowsPerArm: Int
      let calibrationWindows: Int
      let transcribedRowsPerEngine: Int
      let sizeSegments: Int
      let engines: [String]
      let testsInSuite: Int
    }
    let version: Int
    let gates: Gates
    let meeting: Meeting
    let seeks: [Seek]
    let sizeTrack: SizeTrack
    let expected: Expected
  }

  static func matrix() throws -> Matrix {
    let matrix = try JSONDecoder().decode(Matrix.self, from: Data(contentsOf: matrixURL))
    try #require(matrix.version == 2, "c6-matrix.json is version \(matrix.version), not 2")
    try #require(
      matrix.gates.meetingBitRate == SpeechAudioEncoder.Purpose.meeting.bitRate,
      "the production meeting bitrate is not the matrix's \(matrix.gates.meetingBitRate)")
    return matrix
  }

  // MARK: - The pinned corpus

  struct CorpusEntry: Decodable {
    let id: String
    let reference: String?
    let file: String
    let sha256: String
    let language: String?
  }

  struct Clip {
    let id: String
    let reference: String
    let samples: [Float]
  }

  /// Every clip the matrix names, hash-checked against the corpus manifest and decoded through
  /// the app's own file decoder (16 kHz mono).
  static func clips(_ matrix: Matrix) async throws -> [String: Clip] {
    let dir = repoRoot.appending(path: "Tests/Fixtures/meeting-voices")
    let corpus = try JSONDecoder().decode(
      [CorpusEntry].self, from: Data(contentsOf: dir.appending(path: "manifest.json")))
    let names = Set(matrix.meeting.tracks.flatMap { $0.segments.map(\.clip) })
    try #require(names.count == matrix.expected.clips, "matrix names \(names.count) clips")
    var clips: [String: Clip] = [:]
    for name in names.sorted() {
      let entry = try #require(corpus.first { $0.id == name }, "corpus clip \(name) missing")
      let url = dir.appending(path: entry.file).standardizedFileURL
      let digest = try sha256(url)
      try #require(digest == entry.sha256, "\(name) does not match its corpus hash")
      let decoded = try await AudioFileDecoder.decode(url: url).samples
      // Whole milliseconds (16 samples), as the recorder's segments are, so a contiguous
      // segment starts exactly where the one before it ends (`startMs` is in milliseconds).
      let samples = Array(decoded.prefix(decoded.count / 16 * 16))
      try #require(!samples.isEmpty, "\(name) decoded to no samples")
      clips[name] = Clip(id: name, reference: entry.reference ?? "", samples: samples)
      print("C6 clip id=\(name) sha256=\(digest) samples=\(samples.count)")
    }
    return clips
  }

  // MARK: - Files

  static func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }

  static func identity(_ url: URL) throws -> MeetingAudioFileIdentity {
    let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
    return MeetingAudioFileIdentity(
      byteCount: try #require(size).int64Value, sha256: try sha256(url))
  }

  static func tempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appending(path: "ew-c6-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// The recorder's file format (`MeetingAudioFormat`): 16 kHz mono 16-bit integer PCM in CAF.
  static func writeCAF(_ samples: [Float], to url: URL) throws {
    let processing = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: MeetingAudioFormat.sampleRate, channels: 1,
      interleaved: false)!
    let file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: MeetingAudioFormat.sampleRate,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
      ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(
      pcmFormat: processing, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer {
      buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
    }
    try file.write(from: buffer)
  }

  // MARK: - The meeting

  struct Placed {
    let track: MeetingTrackKind
    let variant: MeetingSegmentVariant
    let spec: Matrix.SegmentSpec
    let info: MeetingSegmentInfo
    let reference: String
  }

  struct Meeting {
    let folder: URL
    let placed: [Placed]
    let inventory: MeetingCompressedInventory
    let provenance: MeetingEchoProvenance
  }

  /// Writes the matrix's meeting as the recorder would leave it (CAF segments, the cleaned twins
  /// and their proof), then compacts every segment with the production encoder into names that
  /// carry one inventory id, and returns the inventory a successful compaction would commit.
  static func meeting(_ matrix: Matrix, clips: [String: Clip]) throws -> Meeting {
    let folder = try tempDir("meeting")
    let inventoryID = UUID()
    var placed: [Placed] = []
    var compressed: [MeetingCompressedSegment] = []
    var proofs: [String: MeetingAudioFileIdentity] = [:]
    for track in matrix.meeting.tracks {
      var cursorMs = 0
      var cleanedInfos: [MeetingSegmentInfo] = []
      for spec in track.segments {
        let clip = try #require(clips[spec.clip])
        let startMs: Int
        switch spec.place {
        case "start": startMs = 0
        case "gap": startMs = cursorMs + matrix.meeting.gapMs
        case "contiguous": startMs = cursorMs
        default: throw C6Failure("unknown place \(spec.place)")
        }
        cursorMs = startMs + clip.samples.count * 1_000 / Int(MeetingAudioFormat.sampleRate)
        var variants: [(MeetingSegmentVariant, [Float])] = [(.raw, clip.samples)]
        if track.cleanedTwin {
          variants.append((.cleaned, clip.samples.map { $0 * matrix.meeting.cleanedGain }))
        }
        for (variant, samples) in variants {
          let name = MeetingSegmentNaming.fileName(
            track: track.track, variant: variant, index: spec.index, startMs: startMs,
            partial: false)
          let url = folder.appending(path: name)
          try writeCAF(samples, to: url)
          let info = MeetingSegmentInfo(
            index: spec.index, fileName: name, startMs: startMs, frameCount: samples.count)
          if variant == .cleaned { cleanedInfos.append(info) }
          placed.append(
            Placed(
              track: track.track, variant: variant, spec: spec, info: info,
              reference: clip.reference))

          let outName = MeetingSegmentNaming.compactedFileName(
            source: info, track: track.track, variant: variant, inventoryID: inventoryID,
            partial: false)
          let outURL = folder.appending(path: outName)
          let output = try SpeechAudioEncoder.encode(fileAt: url, purpose: .meeting, to: outURL)
          compressed.append(
            MeetingCompressedSegment(
              track: track.track, variant: variant, source: info,
              sourceIdentity: try identity(url),
              compressed: MeetingSegmentInfo(
                index: spec.index, fileName: outName, startMs: startMs,
                frameCount: samples.count),
              compressedIdentity: try identity(outURL)))
          print(
            "C6 segment track=\(track.track.rawValue) variant=\(variant.rawValue) "
              + "index=\(spec.index) clip=\(spec.clip) startMs=\(startMs) "
              + "sourceFrames=\(samples.count) encodedFrames=\(output.frames) bytes=\(output.bytes)"
          )
        }
      }
      if !cleanedInfos.isEmpty {
        let proofName = MeetingSegmentNaming.cleanedProofName(
          first: cleanedInfos.map(\.index).min()!, last: cleanedInfos.map(\.index).max()!)
        let proofURL = folder.appending(path: proofName)
        try JSONEncoder().encode(MeetingCleanedProof(segments: cleanedInfos)).write(to: proofURL)
        proofs[proofName] = try identity(proofURL)
      }
    }
    let inventory = MeetingCompressedInventory(
      id: inventoryID, transcriptGeneration: nil, segments: compressed, cleanedProofs: proofs)
    let provenance = MeetingEchoProvenance(
      library: matrix.meeting.provenance.library,
      configuration: matrix.meeting.provenance.configuration)
    return Meeting(folder: folder, placed: placed, inventory: inventory, provenance: provenance)
  }

  /// The `retired` arm: a copy of the meeting folder with every source CAF the inventory names
  /// removed (the original folder is never touched).
  static func retiredCopy(_ meeting: Meeting) throws -> URL {
    let copy = try tempDir("retired")
    try FileManager.default.removeItem(at: copy)
    try FileManager.default.copyItem(at: meeting.folder, to: copy)
    for segment in meeting.inventory.segments {
      try FileManager.default.removeItem(at: copy.appending(path: segment.source.fileName))
    }
    return copy
  }

  // MARK: - Measurements

  static func sampleIndex(ms: Int) -> Int { ms * Int(MeetingAudioFormat.sampleRate) / 1_000 }

  static func rms(_ x: ArraySlice<Float>) -> Double {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
  }

  /// The best normalized correlation of `reference` against `test` read from `base + lag` for
  /// lags in `-search...search` samples, and the lag that gives it. `base` is where `reference`
  /// starts inside `test` when nothing moved.
  static func bestCorrelation(_ reference: [Float], _ test: [Float], base: Int, search: Int)
    -> (correlation: Double, lag: Int)
  {
    var best = (correlation: -1.0, lag: 0)
    for lag in -search...search {
      var dot = 0.0
      var a2 = 0.0
      var b2 = 0.0
      for i in 0..<reference.count {
        let j = base + i + lag
        guard j >= 0, j < test.count else { continue }
        let a = Double(reference[i])
        let b = Double(test[j])
        dot += a * b
        a2 += a * a
        b2 += b * b
      }
      guard a2 > 0, b2 > 0 else { continue }
      let c = dot / (a2 * b2).squareRoot()
      if c > best.correlation { best = (c, lag) }
    }
    return best
  }

  static func db(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-12)) }

  /// Pearson correlation of the two windows' 10 ms RMS envelopes: a content check for noise and
  /// music, whose waveform a perceptual codec does not keep but whose loudness over time it does.
  static func envelopeCorrelation(_ a: [Float], _ b: [Float]) -> Double {
    let frame = 160
    func envelope(_ x: [Float]) -> [Double] {
      stride(from: 0, to: x.count - frame + 1, by: frame).map { rms(x[$0..<($0 + frame)]) }
    }
    let ea = envelope(a)
    let eb = envelope(b)
    let n = min(ea.count, eb.count)
    guard n > 1 else { return -1 }
    let ma = ea.prefix(n).reduce(0, +) / Double(n)
    let mb = eb.prefix(n).reduce(0, +) / Double(n)
    var dot = 0.0
    var va = 0.0
    var vb = 0.0
    for i in 0..<n {
      dot += (ea[i] - ma) * (eb[i] - mb)
      va += (ea[i] - ma) * (ea[i] - ma)
      vb += (eb[i] - mb) * (eb[i] - mb)
    }
    guard va > 0, vb > 0 else { return -1 }
    return dot / (va * vb).squareRoot()
  }

  /// One seek window's content check, shared by the reader arms and the codec calibration.
  /// `a` is the original window; `b` holds the test window at `lead` with `search` samples of
  /// room on each side. Speech and boundary windows: best waveform correlation and its lag.
  /// Level windows (noise, music): envelope correlation at the requested time and the level.
  static func windowMatches(
    kind: String, _ a: [Float], _ b: [Float], lead: Int, gates: Matrix.Gates
  ) -> (ok: Bool, detail: String) {
    let centre = Array(b[lead..<(lead + a.count)])
    if kind == "level" {
      let envelope = envelopeCorrelation(a, centre)
      let delta = db(rms(centre[...]) / max(rms(a[...]), 1e-12))
      return (
        envelope >= gates.seekMinCorrelation && abs(delta) <= gates.levelToleranceDb,
        "envelope=\(String(format: "%.4f", envelope)) deltaDb=\(String(format: "%.2f", delta))"
      )
    }
    let found = bestCorrelation(a, b, base: lead, search: gates.seekSearchLagSamples)
    return (
      found.correlation >= gates.seekMinCorrelation && abs(found.lag) <= gates.seekMaxLagSamples,
      "correlation=\(String(format: "%.4f", found.correlation)) lagSamples=\(found.lag)"
    )
  }
}

struct C6Failure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// The production reader route a meeting's Transcribe again and playback take, from files to
/// samples: recovery lists the logical segments, the single reader-authority selector
/// (`MeetingAudioSelection`) chooses one physical file per logical segment from the COMPLETE key
/// set (raw, cleaned and call together), `MeetingMicrophoneSelection` decides the microphone copy
/// as the coordinator does (`MeetingCoordinator` final pass), and `MeetingTrackAudio` reads it.
///
/// INTEGRATION POINT (main, after lane B): this is the only place the harness calls the reader
/// route. When lane B's recovery/reader migration lands, replace the body with its entry point
/// (recovery that reads the committed inventory and translates the cleaned proof through it) so
/// the three arms run exactly the code the coordinator runs. Until then the compacted and retired
/// arms fail here, which is the expected dry-run result, never a pass.
enum C6Route {
  struct Tracks {
    let rawMicrophone: MeetingTrackAudio
    /// The microphone copy transcription reads, after the coordinator's decision.
    let transcribedMicrophone: MeetingTrackAudio
    let usedCleaned: Bool
    let call: MeetingTrackAudio
    let selected: [MeetingSelectedSegment]
  }

  /// The production reader route, as `MeetingCoordinator`'s final pass runs it (#3147 PR4B
  /// I1): recovery with the meeting's committed inventory (identities by full streaming
  /// SHA-256, the store's definition), each track built from recovery's lists with
  /// `MeetingTrackAudio(segments:in:)` (a compacted file at the recorder's frame count), then
  /// the microphone decision. `selected` is the selector's answer for the complete logical key
  /// set (raw, cleaned and call), and must name exactly the files recovery listed.
  static func open(
    folder: URL, inventory: MeetingCompressedInventory?, provenance: MeetingEchoProvenance?
  ) throws -> Tracks {
    let report = MeetingTrackRecovery.recover(
      folder: folder, inventory: inventory, identity: C6Fixture.identity)
    guard report.problems.isEmpty, report.cleanedProblems.isEmpty,
      report.compressedProblems.isEmpty
    else {
      throw C6Failure(
        "recovery problems \(report.problems) cleaned \(report.cleanedProblems) compacted \(report.compressedProblems)"
      )
    }
    var logical: [MeetingLogicalSegment] = []
    if let inventory {
      for entry in inventory.segments {
        logical.append(
          MeetingLogicalSegment(track: entry.track, variant: entry.variant, segment: entry.source))
      }
    } else {
      for track in MeetingTrackKind.allCases {
        for segment in report.segments[track] ?? [] {
          logical.append(MeetingLogicalSegment(track: track, variant: .raw, segment: segment))
        }
      }
      for segment in report.cleanedSegments {
        logical.append(
          MeetingLogicalSegment(track: .microphone, variant: .cleaned, segment: segment))
      }
    }
    let selected: [MeetingSelectedSegment]
    do {
      selected = try MeetingAudioSelection.select(logical: logical, inventory: inventory)
    } catch {
      throw C6Failure("selector refused: \(error)")
    }
    let listed = Set(
      (report.segments.values.flatMap { $0 } + report.cleanedSegments).map(\.fileName))
    guard listed == Set(selected.map(\.fileName)) else {
      throw C6Failure("recovery listed other files than the selector chose")
    }
    func audio(_ track: MeetingTrackKind, _ variant: MeetingSegmentVariant) throws
      -> MeetingTrackAudio
    {
      let segments = variant == .cleaned ? report.cleanedSegments : (report.segments[track] ?? [])
      let audio = MeetingTrackAudio(segments: segments, in: folder)
      guard audio.problems.isEmpty, !audio.isEmpty else {
        throw C6Failure("\(track.rawValue)/\(variant.rawValue) unreadable: \(audio.problems)")
      }
      return audio
    }
    let raw = try audio(.microphone, .raw)
    var transcribed = raw
    var usedCleaned = false
    switch MeetingMicrophoneSelection.decide(
      raw: report.segments[.microphone] ?? [], report: report, provenance: provenance)
    {
    case .cleaned:
      // As the coordinator: a cleaned set that cannot be read where its raw twins are falls
      // back to the raw copy, whole.
      if let cleaned = try? audio(.microphone, .cleaned),
        MeetingMicrophoneSelection.readMatches(cleaned, raw: raw)
      {
        transcribed = cleaned
        usedCleaned = true
      }
    case .raw:
      break
    }
    return Tracks(
      rawMicrophone: raw, transcribedMicrophone: transcribed, usedCleaned: usedCleaned,
      call: try audio(.callSound, .raw), selected: selected)
  }
}

@Suite("#3147 C6 compacted meeting audio parity", .serialized, .tags(.productOutcome))
struct MeetingCompactionRealBoundaryTests {
  typealias F = C6Fixture

  /// Every segment of the matrix meeting compacts to AAC-LC 16 kHz mono with its duration kept,
  /// and the selector maps every logical segment to exactly its compacted file.
  @Test(
    "every segment compacts to AAC-LC 16 kHz mono with its duration kept", .tags(.realBoundary),
    .realBoundaryRun)
  func compactsEverySegment() async throws {
    let matrix = try F.matrix()
    let clips = try await F.clips(matrix)
    let meeting = try F.meeting(matrix, clips: clips)
    defer { try? FileManager.default.removeItem(at: meeting.folder) }
    #expect(meeting.placed.count == matrix.expected.segments)
    #expect(meeting.inventory.segments.count == matrix.expected.compactedFiles)
    var checked = 0
    for segment in meeting.inventory.segments {
      let url = meeting.folder.appending(path: segment.compressed.fileName)
      let file = try AVAudioFile(forReading: url)
      let format = file.fileFormat.streamDescription.pointee
      #expect(format.mFormatID == kAudioFormatMPEG4AAC, "\(segment.compressed.fileName): not AAC")
      #expect(file.fileFormat.sampleRate == matrix.gates.sampleRate)
      #expect(file.fileFormat.channelCount == 1)
      let decoded = try await AudioFileDecoder.decode(url: url).samples
      let errorMs =
        abs(Double(decoded.count - segment.source.frameCount)) / matrix.gates.sampleRate * 1_000
      print(
        "C6 duration file=\(segment.compressed.fileName) logicalFrames=\(segment.source.frameCount) "
          + "decodedFrames=\(decoded.count) errorMs=\(String(format: "%.2f", errorMs))")
      #expect(errorMs <= matrix.gates.durationToleranceMs, "\(segment.compressed.fileName)")
      let parsed = try #require(MeetingSegmentNaming.parseAny(segment.compressed.fileName))
      #expect(parsed.encoding == .aacM4A)
      #expect(parsed.inventoryID == meeting.inventory.id)
      checked += 1
    }
    #expect(checked == matrix.expected.compactedFiles)

    // Codec calibration of the seek check: every speech and level window, read from its
    // segment's source CAF and from the compacted file as the app's file decoder decodes it,
    // must pass the same check the reader arms use, so a failing arm is the reader's fault.
    var calibrated = 0
    for seek in matrix.seeks where seek.kind == "speech" || seek.kind == "level" {
      let variants: [MeetingSegmentVariant] =
        seek.track == .microphone ? [.raw, .cleaned] : [.raw]
      for variant in variants {
        let segment = try #require(
          meeting.inventory.segments.first {
            $0.track == seek.track && $0.variant == variant && $0.source.index == seek.index
          })
        let source = try await AudioFileDecoder.decode(
          url: meeting.folder.appending(path: segment.source.fileName)
        ).samples
        let decoded = try await AudioFileDecoder.decode(
          url: meeting.folder.appending(path: segment.compressed.fileName)
        ).samples
        let start = F.sampleIndex(ms: seek.offsetMs)
        let count = F.sampleIndex(ms: seek.lengthMs)
        let search = matrix.gates.seekSearchLagSamples
        let from = max(0, start - search)
        try #require(start + count + search <= min(source.count, decoded.count), "\(seek.id)")
        let checkedWindow = F.windowMatches(
          kind: seek.kind, Array(source[start..<(start + count)]),
          Array(decoded[from..<(start + count + search)]), lead: start - from,
          gates: matrix.gates)
        print(
          "C6 calibration id=\(seek.id) variant=\(variant.rawValue) kind=\(seek.kind) "
            + checkedWindow.detail)
        #expect(checkedWindow.ok, "\(seek.id) \(variant.rawValue): \(checkedWindow.detail)")
        calibrated += 1
      }
    }
    #expect(calibrated == matrix.expected.calibrationWindows)
  }

  /// One track-hour in recorder-length segments, each compacted on its own, fits the size gate.
  @Test("one compacted track-hour fits 25 MB", .tags(.realBoundary), .realBoundaryRun)
  func trackHourFits() async throws {
    let matrix = try F.matrix()
    let clips = try await F.clips(matrix)
    let dir = try F.tempDir("size")
    defer { try? FileManager.default.removeItem(at: dir) }
    var speech: [Float] = []
    for name in clips.keys.sorted() { speech.append(contentsOf: clips[name]!.samples) }
    let rate = Int(MeetingAudioFormat.sampleRate)
    let total = matrix.sizeTrack.seconds * rate
    let perSegment = matrix.sizeTrack.segmentSeconds * rate
    var bytes: Int64 = 0
    var segments = 0
    var cursor = 0
    while segments * perSegment < total {
      var chunk: [Float] = []
      chunk.reserveCapacity(perSegment)
      while chunk.count < perSegment {
        let take = min(perSegment - chunk.count, speech.count - cursor % speech.count)
        let start = cursor % speech.count
        chunk.append(contentsOf: speech[start..<(start + take)])
        cursor += take
      }
      let info = MeetingSegmentInfo(
        index: segments + 1,
        fileName: MeetingSegmentNaming.fileName(
          track: .callSound, variant: .raw, index: segments + 1,
          startMs: segments * matrix.sizeTrack.segmentSeconds * 1_000, partial: false),
        startMs: segments * matrix.sizeTrack.segmentSeconds * 1_000, frameCount: perSegment)
      let source = dir.appending(path: info.fileName)
      try F.writeCAF(chunk, to: source)
      let out = dir.appending(
        path: MeetingSegmentNaming.compactedFileName(
          source: info, track: .callSound, variant: .raw, inventoryID: UUID(), partial: false))
      let output = try SpeechAudioEncoder.encode(fileAt: source, purpose: .meeting, to: out)
      bytes += output.bytes
      segments += 1
      try FileManager.default.removeItem(at: source)
      try FileManager.default.removeItem(at: out)
    }
    let mbPerHour = Double(bytes) / Double(matrix.sizeTrack.seconds) * 3_600 / 1_000_000
    print(
      "C6 size segments=\(segments) seconds=\(matrix.sizeTrack.seconds) bytes=\(bytes) "
        + "mbPerTrackHour=\(String(format: "%.2f", mbPerHour)) limit=\(matrix.gates.maxMBPerTrackHour)"
    )
    #expect(segments == matrix.expected.sizeSegments)
    #expect(mbPerHour <= matrix.gates.maxMBPerTrackHour)
  }

  /// The compacted and retired arms read the same timeline as the original: same segment
  /// placement and runs, silence in the gaps, the right content at every requested time, and the
  /// proof-backed cleaned microphone copy still chosen.
  @Test(
    "timeline, gaps, boundaries and seeks match the original", .tags(.realBoundary),
    .realBoundaryRun)
  func timelineMatches() async throws {
    let matrix = try F.matrix()
    let clips = try await F.clips(matrix)
    let meeting = try F.meeting(matrix, clips: clips)
    defer { try? FileManager.default.removeItem(at: meeting.folder) }
    let retired = try F.retiredCopy(meeting)
    defer { try? FileManager.default.removeItem(at: retired) }

    let original = try C6Route.open(
      folder: meeting.folder, inventory: nil, provenance: meeting.provenance)
    #expect(original.selected.allSatisfy { $0.encoding == .pcmCAF })
    #expect(original.usedCleaned)
    // The raw-selection branch: with no recorded provenance the coordinator reads the raw
    // microphone copy, whole.
    let rawAttempt = try C6Route.open(folder: meeting.folder, inventory: nil, provenance: nil)
    #expect(rawAttempt.usedCleaned == false)
    #expect(
      try rawAttempt.transcribedMicrophone.read(from: 0, count: original.rawMicrophone.endSample)
        == original.rawMicrophone.read(from: 0, count: original.rawMicrophone.endSample))
    print("C6 mode control=\(F.identityControl ? "identity" : "none")")
    for (arm, armFolder) in [("compacted", meeting.folder), ("retired", retired)] {
      let (folder, inventory) = F.arm(meeting, folder: armFolder)
      let tracks = try C6Route.open(
        folder: folder, inventory: inventory, provenance: meeting.provenance)
      #expect(tracks.selected.count == matrix.expected.compactedFiles, "\(arm)")
      #expect(
        tracks.selected.allSatisfy { $0.encoding == (F.identityControl ? .pcmCAF : .aacM4A) },
        "\(arm)")
      #expect(tracks.usedCleaned, "\(arm): the cleaned copy was not chosen")
      for (name, a, b) in [
        ("microphone", original.rawMicrophone, tracks.rawMicrophone),
        ("cleaned", original.transcribedMicrophone, tracks.transcribedMicrophone),
        ("call", original.call, tracks.call),
      ] {
        #expect(a.segments.map(\.startSample) == b.segments.map(\.startSample), "\(arm) \(name)")
        #expect(a.segments.map(\.frameCount) == b.segments.map(\.frameCount), "\(arm) \(name)")
        #expect(a.runs == b.runs, "\(arm) \(name) runs")
        #expect(a.endSample == b.endSample, "\(arm) \(name) end")
      }
      // The cleaned copy, not the raw one, reaches transcription.
      let ratio =
        F.rms(
          try tracks.transcribedMicrophone.read(from: 0, count: tracks.rawMicrophone.endSample)[...]
        )
        / F.rms(try tracks.rawMicrophone.read(from: 0, count: tracks.rawMicrophone.endSample)[...])
      print("C6 cleaned arm=\(arm) levelRatio=\(String(format: "%.3f", ratio))")
      #expect(
        abs(ratio - matrix.gates.cleanedLevelRatio) <= matrix.gates.cleanedLevelRatioTolerance)

      // Negative control of the seek instrument, every run: speech one second later is not
      // the requested content, so it must fall below the correlation bar.
      let probe = try #require(
        matrix.seeks.first { $0.kind == "speech" && $0.track == .microphone })
      let probeSegment = try #require(
        meeting.placed.first {
          $0.track == .microphone && $0.variant == .raw && $0.info.index == probe.index
        })
      let probeStart = F.sampleIndex(ms: probeSegment.info.startMs + probe.offsetMs)
      let probeCount = F.sampleIndex(ms: probe.lengthMs)
      let wrong = F.bestCorrelation(
        try original.rawMicrophone.read(from: probeStart, count: probeCount),
        try tracks.rawMicrophone.read(
          from: probeStart + F.sampleIndex(ms: 1_000), count: probeCount),
        base: 0, search: matrix.gates.seekSearchLagSamples)
      print(
        "C6 seek-control arm=\(arm) wrongTimeCorrelation=\(String(format: "%.4f", wrong.correlation))")
      #expect(
        wrong.correlation < matrix.gates.seekMinCorrelation,
        "\(arm): the seek check cannot tell times apart")

      var windows = 0
      for (copy, seeks) in [
        ("raw", matrix.seeks),
        ("cleaned", matrix.seeks.filter { $0.track == .microphone }),
      ] {
        for seek in seeks {
          let (reference, test) = (
            copy == "cleaned"
              ? original.transcribedMicrophone
              : (seek.track == .microphone ? original.rawMicrophone : original.call),
            copy == "cleaned"
              ? tracks.transcribedMicrophone
              : (seek.track == .microphone ? tracks.rawMicrophone : tracks.call)
          )
          let segment = try #require(
            meeting.placed.first {
              $0.track == seek.track && $0.variant == .raw && $0.info.index == seek.index
            })
          let anchorMs =
            seek.anchor == "afterSegment"
            ? segment.info.startMs + segment.info.frameCount * 1_000
              / Int(MeetingAudioFormat.sampleRate)
            : segment.info.startMs
          let start = F.sampleIndex(ms: anchorMs + seek.offsetMs)
          let count = F.sampleIndex(ms: seek.lengthMs)
          let a = try reference.read(from: start, count: count)
          let search = matrix.gates.seekSearchLagSamples
          let from = max(0, start - search)
          let lead = start - from
          let b = try test.read(from: from, count: count + lead + search)
          let bCentre = Array(b[lead..<(lead + count)])
          switch seek.kind {
          case "gap":
            let peak = (a + bCentre).map(abs).max() ?? 0
            print("C6 seek arm=\(arm) copy=\(copy) id=\(seek.id) kind=gap peak=\(peak)")
            #expect(peak == 0, "\(arm) \(copy) \(seek.id): a gap is not silent")
          case "level":
            let checked = F.windowMatches(kind: "level", a, b, lead: lead, gates: matrix.gates)
            // The same window one second later must not pass: the check sees content.
            let later = try test.read(from: start + F.sampleIndex(ms: 1_000), count: count)
            let wrongTime = F.envelopeCorrelation(a, later)
            print(
              "C6 seek arm=\(arm) copy=\(copy) id=\(seek.id) kind=level \(checked.detail) "
                + "wrongTimeEnvelope=\(String(format: "%.4f", wrongTime))")
            #expect(checked.ok, "\(arm) \(copy) \(seek.id): \(checked.detail)")
            #expect(
              wrongTime < matrix.gates.seekMinCorrelation,
              "\(arm) \(copy) \(seek.id): the level check cannot tell times apart")
          default:
            let checked = F.windowMatches(kind: seek.kind, a, b, lead: lead, gates: matrix.gates)
            print("C6 seek arm=\(arm) copy=\(copy) id=\(seek.id) kind=\(seek.kind) \(checked.detail)")
            #expect(checked.ok, "\(arm) \(copy) \(seek.id): \(checked.detail)")
          }
          windows += 1
        }
      }
      #expect(windows == matrix.expected.seekWindowsPerArm, "\(arm): \(windows) windows")
    }
  }

  @Test(
    "Parakeet hears the compacted meeting as well as the original", .tags(.realBoundary),
    .realBoundaryRun)
  func parakeetParity() async throws {
    try #require(
      ParakeetRealBoundaryFixture.ultraIsInstalled, "Parakeet Ultra is not installed on this Mac")
    try await withParakeetOfflineModeExclusion {
      let backend = ParakeetBackend()
      do {
        try await backend.prepare(
          selection: ParakeetModelSelection(
            model: .ultra, revision: nil,
            directory: ParakeetRealBoundaryFixture.ultraInstallDirectory, cacheOnly: true,
            displayBytes: ParakeetModel.v3ShippedBytes, repairable: false, generation: 1),
          progressCallback: nil)
        print(
          "C6 engine name=parakeet model=ultra dir=\(ParakeetRealBoundaryFixture.ultraInstallDirectory.path)"
        )
        try await Self.parity(engine: "parakeet") { samples, _ in
          let result = try await backend.transcribe(audioSamples: samples, options: .default)
          #expect(result.backendType == .parakeet)
          return result.text
        }
        await backend.unload()
      } catch {
        await backend.unload()
        throw error
      }
    }
  }

  @Test(
    "Whisper hears the compacted meeting as well as the original", .tags(.realBoundary),
    .realBoundaryRun)
  func whisperParity() async throws {
    try #require(
      FileManager.default.fileExists(atPath: F.whisperModelPath),
      "the Whisper model is not on this Mac: \(F.whisperModelPath)")
    try #require(
      try TranscribeCppRealBoundaryFixture.modelDigestMatches(at: F.whisperModelPath),
      "requires the approved turbo Q8_0 model")
    let executor = TranscribeCppExecutor()
    let model = try await executor.load(
      modelPath: F.whisperModelPath, lane: .heart)
    print("C6 engine name=whisper model=\(F.whisperModelPath)")
    do {
      try await Self.parity(engine: "whisper") { samples, language in
        try await executor.transcribe(model, samples: samples, language: language, lane: .heart)
          .text
      }
      await executor.unload(model)
    } catch {
      await executor.unload(model)
      throw error
    }
  }

  /// Every matrix segment (raw microphone, cleaned microphone and call) read through the route
  /// in the original and compacted arms and transcribed with identical options; the retired arm
  /// must read the same samples as the compacted one. Prints one `C6 raw` line per segment for
  /// the eval scorer (`score_c6.py`), which owns the WER gate.
  private static func parity(
    engine: String, transcribe: (_ samples: [Float], _ language: String) async throws -> String
  ) async throws {
    let matrix = try F.matrix()
    let clips = try await F.clips(matrix)
    let meeting = try F.meeting(matrix, clips: clips)
    defer { try? FileManager.default.removeItem(at: meeting.folder) }
    let retiredFolder = try F.retiredCopy(meeting)
    defer { try? FileManager.default.removeItem(at: retiredFolder) }
    let original = try C6Route.open(
      folder: meeting.folder, inventory: nil, provenance: meeting.provenance)
    print("C6 mode control=\(F.identityControl ? "identity" : "none")")
    let compactedArm = F.arm(meeting, folder: meeting.folder)
    let compacted = try C6Route.open(
      folder: compactedArm.folder, inventory: compactedArm.inventory,
      provenance: meeting.provenance)
    let retiredArm = F.arm(meeting, folder: retiredFolder)
    let retired = try C6Route.open(
      folder: retiredArm.folder, inventory: retiredArm.inventory, provenance: meeting.provenance)
    func track(_ tracks: C6Route.Tracks, _ placed: F.Placed) -> MeetingTrackAudio {
      switch (placed.track, placed.variant) {
      case (.microphone, .cleaned): tracks.transcribedMicrophone
      case (.microphone, _): tracks.rawMicrophone
      case (.callSound, _): tracks.call
      }
    }
    var rows = 0
    for placed in meeting.placed {
      let start = F.sampleIndex(ms: placed.info.startMs)
      let count = placed.info.frameCount
      let originalSamples = try track(original, placed).read(from: start, count: count)
      let compactedSamples = try track(compacted, placed).read(from: start, count: count)
      let retiredSamples = try track(retired, placed).read(from: start, count: count)
      #expect(retiredSamples == compactedSamples, "\(placed.info.fileName): retired arm differs")
      let originalText = try await transcribe(originalSamples, placed.spec.language)
      let compactedText = try await transcribe(compactedSamples, placed.spec.language)
      // Committed corpus text only, never user speech.
      let raw = try JSONEncoder().encode([
        "engine": engine, "track": placed.track.rawValue, "variant": placed.variant.rawValue,
        "segment": String(placed.info.index), "clip": placed.spec.clip,
        "language": placed.spec.language, "reference": placed.reference,
        "original": originalText, "compressed": compactedText,
      ])
      print("C6 raw \(String(decoding: raw, as: UTF8.self))")
      rows += 1
    }
    #expect(rows == matrix.expected.transcribedRowsPerEngine, "\(engine): \(rows) rows")
  }
}
