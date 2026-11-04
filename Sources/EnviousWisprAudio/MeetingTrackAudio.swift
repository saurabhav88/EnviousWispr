@preconcurrency import AVFoundation
import Darwin
import EnviousWisprCore
import FluidAudio
import Foundation

/// Reads one EnviousMeet track back from its segment files on the meeting timeline (#3972 §3.6,
/// R15, R22).
///
/// The timeline is in samples at 16 kHz from the meeting's anchor. Each segment file sits at the
/// start time in its name; the frame count comes from the file itself, never from metadata.
/// Anything between segments is a gap and reads as silence. A file that cannot be read, has the
/// wrong format or holds no audio is left out and listed in `problems`, so missing audio is
/// never mistaken for a gap; a read that fails later throws. Reads open only the files a range
/// touches, so a five-hour track costs one read's worth of memory at a time.
public final class MeetingTrackAudio: @unchecked Sendable {
  public struct Segment: Sendable, Equatable {
    public let url: URL
    public let startSample: Int
    public let frameCount: Int
    /// Where this segment's audio is read from: its start, or later where an earlier segment
    /// already covers the timeline (the earlier file wins an overlap).
    public let readStartSample: Int
    public var endSample: Int { startSample + frameCount }
  }

  /// A stretch of the timeline with no gap longer than `contiguityToleranceSamples`.
  public struct Run: Sendable, Equatable {
    public let startSample: Int
    public let endSample: Int
    public var sampleCount: Int { endSample - startSample }
  }

  public enum Problem: Sendable, Hashable {
    case unreadable(fileName: String)
    case incompatibleFormat(fileName: String)
    case empty(fileName: String)
    /// Part of this file repeats timeline an earlier file already covers; that part is not read.
    case overlap(fileName: String, samples: Int)
  }

  public enum ReadError: Error, Equatable {
    case unreadable(fileName: String)
    case shortRead(fileName: String, expected: Int, got: Int)
  }

  public let segments: [Segment]
  public let problems: [Problem]
  /// Segments closer than this are one run. Writer-made segments start on exact 1 ms
  /// boundaries; the tolerance covers files whose start was rounded to a millisecond.
  public static let contiguityToleranceSamples = 160

  /// `files` are one track's segment files, in any order.
  public init(files: [(url: URL, startMs: Int)]) {
    var found: [(url: URL, start: Int, frames: Int)] = []
    var problems: [Problem] = []
    for file in files {
      let name = file.url.lastPathComponent
      switch Self.inspect(file.url) {
      case .readable(let frames):
        found.append((file.url, file.startMs * Self.samplesPerMs, frames))
      case .empty: problems.append(.empty(fileName: name))
      case .incompatible: problems.append(.incompatibleFormat(fileName: name))
      case .unreadable: problems.append(.unreadable(fileName: name))
      }
    }
    // Deterministic order: by start, then by name.
    found.sort { ($0.start, $0.url.lastPathComponent) < ($1.start, $1.url.lastPathComponent) }
    var segments: [Segment] = []
    var coveredUntil = Int.min
    for file in found {
      let end = file.start + file.frames
      let readStart = max(file.start, coveredUntil)
      if readStart > file.start {
        problems.append(
          .overlap(fileName: file.url.lastPathComponent, samples: min(end, readStart) - file.start))
      }
      segments.append(
        Segment(
          url: file.url, startSample: file.start, frameCount: file.frames,
          readStartSample: min(readStart, end)))
      coveredUntil = max(coveredUntil, end)
    }
    self.segments = segments
    self.problems = problems
  }

  public var endSample: Int { segments.map(\.endSample).max() ?? 0 }
  public var isEmpty: Bool { segments.isEmpty }

  public var runs: [Run] {
    var runs: [Run] = []
    for segment in segments where segment.endSample > segment.readStartSample {
      if let last = runs.last,
        segment.readStartSample - last.endSample <= Self.contiguityToleranceSamples
      {
        runs[runs.count - 1] = Run(
          startSample: last.startSample, endSample: max(last.endSample, segment.endSample))
      } else {
        runs.append(Run(startSample: segment.readStartSample, endSample: segment.endSample))
      }
    }
    return runs
  }

  /// Reads `count` samples starting at timeline sample `start`; gaps read as silence. Throws when
  /// a file the range needs cannot be read in full.
  public func read(from start: Int, count: Int) throws -> [Float] {
    guard count > 0 else { return [] }
    var out = [Float](repeating: 0, count: count)
    try out.withUnsafeMutableBufferPointer { buffer in
      try copy(into: buffer.baseAddress!, from: start, count: count)
    }
    return out
  }

  /// Copies the range into an initialized destination, leaving gap samples untouched.
  func copy(into destination: UnsafeMutablePointer<Float>, from start: Int, count: Int) throws {
    let end = start + count
    for segment in segments where segment.endSample > start && segment.readStartSample < end {
      let readStart = max(start, segment.readStartSample)
      let readEnd = min(end, segment.endSample)
      let frames = readEnd - readStart
      guard frames > 0 else { continue }
      let name = segment.url.lastPathComponent
      let file: AVAudioFile
      do {
        file = try AVAudioFile(forReading: segment.url)
      } catch {
        throw ReadError.unreadable(fileName: name)
      }
      file.framePosition = AVAudioFramePosition(readStart - segment.startSample)
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)),
        (try? file.read(into: buffer, frameCount: AVAudioFrameCount(frames))) != nil,
        let data = buffer.floatChannelData
      else {
        throw ReadError.unreadable(fileName: name)
      }
      guard Int(buffer.frameLength) == frames else {
        throw ReadError.shortRead(fileName: name, expected: frames, got: Int(buffer.frameLength))
      }
      (destination + (readStart - start)).update(from: data[0], count: frames)
    }
  }

  /// The whole track timeline as the diarizer's input, gaps as silence, read lazily.
  public var diarizerSource: some AudioSampleSource { TimelineSource(audio: self) }

  struct TimelineSource: AudioSampleSource {
    let audio: MeetingTrackAudio
    var sampleCount: Int { audio.endSample }
    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws
    {
      guard count > 0 else { return }
      destination.initialize(repeating: 0, count: count)
      try audio.copy(into: destination, from: offset, count: count)
    }
  }

  // MARK: - File inspection

  static let samplesPerMs = Int(MeetingAudioFormat.sampleRate) / 1_000

  enum Inspection: Equatable {
    case readable(frames: Int)
    case empty
    case incompatible
    case unreadable
  }

  /// Whether `url` is a readable 16 kHz mono 16-bit integer PCM file, and its frame count as
  /// the file itself reports it.
  static func inspect(_ url: URL) -> Inspection {
    guard let file = try? AVAudioFile(forReading: url) else { return .unreadable }
    let format = file.fileFormat.streamDescription.pointee
    guard format.mFormatID == kAudioFormatLinearPCM, format.mChannelsPerFrame == 1,
      format.mBitsPerChannel == 16, format.mSampleRate == MeetingAudioFormat.sampleRate,
      format.mFormatFlags & kAudioFormatFlagIsFloat == 0
    else { return .incompatible }
    let frames = Int(file.length)
    return frames > 0 ? .readable(frames: frames) : .empty
  }
}

/// Rebuilds a meeting folder's segment lists from the files themselves after a crash, force
/// quit or interrupted close (#3972 R3, R15). File names are the source of truth for track,
/// index and start; the files are the source of truth for frame counts.
///
/// Promotes each readable `.caf.partial` to its final name with an exclusive rename (never over
/// an existing file), lists every readable final, and reports every file it could not use.
/// Running it again changes nothing further. Run it only when no writer owns the folder (at
/// launch, or after a close that did not time out); the owner refuses a newer-format meeting
/// before calling it.
public enum MeetingTrackRecovery {
  public enum Problem: Sendable, Hashable {
    case folderUnreadable(errno: Int32)
    case unreadablePartial(fileName: String)
    case emptyPartial(fileName: String)
    /// A partial whose final name already exists: both are kept, the partial is not read.
    case partialBesideFinal(fileName: String)
    case promotionFailed(fileName: String, errno: Int32)
    /// The promoting renames happened but could not be made durable; the files are kept.
    case directorySyncFailed(errno: Int32)
    case unreadableFinal(fileName: String)
    case incompatibleFinal(fileName: String)
    case emptyFinal(fileName: String)
    /// Two files of one track share an index (different start times): both are kept and listed.
    case duplicateIndex(track: MeetingTrackKind, index: Int)
    /// #4355 PR B: a cleaned-copy proof that could not be read; it confirms nothing.
    case unreadableProof(fileName: String)
  }

  public struct Report: Sendable, Equatable {
    /// Readable RAW finals per track, by start time then index: the recording's audio.
    public var segments: [MeetingTrackKind: [MeetingSegmentInfo]] = [:]
    /// #4355 PR B: readable finals of the microphone's echo-cleaned copy, by start then index.
    /// Never part of `segments`: a derivative that playback and damage marking never read.
    public var cleanedSegments: [MeetingSegmentInfo] = []
    /// The highest index any recognized file uses per track (either copy), readable or not.
    public var highestIndex: [MeetingTrackKind: Int] = [:]
    public var promoted: [String] = []
    /// Problems of raw files: these can mean lost recording audio.
    public var problems: [Problem] = []
    /// #4355 PR B: problems of cleaned-copy files. They only disable the cleaned copy for the
    /// final pass; they never mark recording audio as damaged.
    public var cleanedProblems: [Problem] = []
    /// #4355 PR B: the twins the cleaned-copy proofs in the folder list as finished whole.
    public var cleanedConfirmed: [MeetingSegmentInfo] = []

    public init() {}
  }

  /// `syncDirectory` makes the promoting renames durable (nil on success, else errno); nil uses
  /// the writer's directory sync. A parameter so a test can make it fail.
  public static func recover(
    folder: URL, syncDirectory: ((URL) -> Int32?)? = nil
  ) -> Report {
    let syncDirectory = syncDirectory ?? MeetingTrackWriter.syncDirectory
    var report = Report()
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    } catch {
      let code = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code
      report.problems.append(.folderUnreadable(errno: Int32(code ?? Int(EIO))))
      return report
    }
    let recognized = names.compactMap { name in
      MeetingSegmentNaming.parse(name).map { (name: name, parsed: $0) }
    }.sorted { $0.name < $1.name }
    for file in recognized {
      report.highestIndex[file.parsed.track] = max(
        report.highestIndex[file.parsed.track] ?? 0, file.parsed.index)
    }

    // 1. Promote readable partials, never over an existing file.
    var finals = Set(recognized.filter { !$0.parsed.partial }.map(\.name))
    var promotedAny = false
    func note(_ problem: Problem, _ variant: MeetingSegmentVariant) {
      if variant == .cleaned {
        report.cleanedProblems.append(problem)
      } else {
        report.problems.append(problem)
      }
    }
    for file in recognized where file.parsed.partial {
      let finalName = MeetingSegmentNaming.fileName(
        track: file.parsed.track, variant: file.parsed.variant, index: file.parsed.index,
        startMs: file.parsed.startMs, partial: false)
      if finals.contains(finalName) {
        note(.partialBesideFinal(fileName: file.name), file.parsed.variant)
        continue
      }
      switch MeetingTrackAudio.inspect(folder.appendingPathComponent(file.name)) {
      case .readable:
        let from = folder.appendingPathComponent(file.name).path
        let to = folder.appendingPathComponent(finalName).path
        if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 {
          finals.insert(finalName)
          report.promoted.append(finalName)
          promotedAny = true
        } else {
          note(.promotionFailed(fileName: file.name, errno: errno), file.parsed.variant)
        }
      case .empty: note(.emptyPartial(fileName: file.name), file.parsed.variant)
      case .incompatible, .unreadable:
        note(.unreadablePartial(fileName: file.name), file.parsed.variant)
      }
    }
    if promotedAny, let code = syncDirectory(folder) {
      report.problems.append(.directorySyncFailed(errno: code))
    }

    // 2. List readable finals, frame counts from the files.
    var seen: [String: Int] = [:]
    for name in finals.sorted() {
      guard let parsed = MeetingSegmentNaming.parse(name) else { continue }
      let key = "\(parsed.track.rawValue)-\(parsed.variant.rawValue)-\(parsed.index)"
      seen[key, default: 0] += 1
      if seen[key] == 2 {
        note(.duplicateIndex(track: parsed.track, index: parsed.index), parsed.variant)
      }
      switch MeetingTrackAudio.inspect(folder.appendingPathComponent(name)) {
      case .readable(let frames):
        let info = MeetingSegmentInfo(
          index: parsed.index, fileName: name, startMs: parsed.startMs, frameCount: frames)
        if parsed.variant == .cleaned {
          report.cleanedSegments.append(info)
        } else {
          report.segments[parsed.track, default: []].append(info)
        }
      case .empty: note(.emptyFinal(fileName: name), parsed.variant)
      case .incompatible: note(.incompatibleFinal(fileName: name), parsed.variant)
      case .unreadable: note(.unreadableFinal(fileName: name), parsed.variant)
      }
    }
    for track in report.segments.keys {
      report.segments[track]?.sort { ($0.startMs, $0.index) < ($1.startMs, $1.index) }
    }
    report.cleanedSegments.sort { ($0.startMs, $0.index) < ($1.startMs, $1.index) }

    // 3. The cleaned-copy proofs: only twins one of them lists may be used (#4355 PR B).
    for name in names.filter(MeetingSegmentNaming.isCleanedProof).sorted() {
      guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path),
        let proof = try? JSONDecoder().decode(MeetingCleanedProof.self, from: data)
      else {
        report.cleanedProblems.append(.unreadableProof(fileName: name))
        continue
      }
      report.cleanedConfirmed.append(contentsOf: proof.segments)
    }
    return report
  }
}

/// #4355 PR B: which microphone copy one final-transcript attempt reads, decided once per attempt
/// from what recovery found. The cleaned copy is used only as a complete set: every raw
/// microphone segment has exactly one readable cleaned twin with the same index, start and frame
/// count, a cleaned-copy proof lists that twin as finished, no cleaned file had a problem, and the
/// recording's echo provenance is known. Anything less reads the whole raw set; the two copies are
/// never mixed segment by segment.
public enum MeetingMicrophoneSelection {
  public enum RawReason: String, Sendable, Equatable {
    case noProvenance, noCleanedCopy, cleanedProblem, incomplete, mismatch
    /// The twins exist but no proof lists every one as finished whole (a cleaned-copy failure,
    /// a crash, or a close that could not write the proof).
    case unconfirmed
  }

  public enum Decision: Sendable, Equatable {
    case cleaned([MeetingSegmentInfo], MeetingEchoProvenance)
    case raw(RawReason)
  }

  public static func decide(
    raw: [MeetingSegmentInfo], report: MeetingTrackRecovery.Report,
    provenance: MeetingEchoProvenance?
  ) -> Decision {
    guard let provenance else { return .raw(.noProvenance) }
    guard !report.cleanedSegments.isEmpty else { return .raw(.noCleanedCopy) }
    guard report.cleanedProblems.isEmpty else { return .raw(.cleanedProblem) }
    guard report.cleanedSegments.count == raw.count else { return .raw(.incomplete) }
    let twins = Dictionary(grouping: report.cleanedSegments, by: \.index)
    for segment in raw {
      guard let found = twins[segment.index], found.count == 1, let twin = found.first,
        twin.startMs == segment.startMs, twin.frameCount == segment.frameCount
      else { return .raw(.mismatch) }
    }
    let confirmed = Set(
      report.cleanedConfirmed.map { "\($0.fileName)|\($0.startMs)|\($0.frameCount)" })
    for twin in report.cleanedSegments
    where !confirmed.contains("\(twin.fileName)|\(twin.startMs)|\(twin.frameCount)") {
      return .raw(.unconfirmed)
    }
    return .cleaned(report.cleanedSegments, provenance)
  }

  /// The cleaned set as read: every file inspected clean and placed exactly where its raw twin
  /// was. Checked after reading, because a file can fail between recovery and the read.
  public static func readMatches(_ cleaned: MeetingTrackAudio, raw: MeetingTrackAudio) -> Bool {
    cleaned.problems.isEmpty && cleaned.segments.count == raw.segments.count
      && zip(cleaned.segments, raw.segments).allSatisfy {
        $0.startSample == $1.startSample && $0.frameCount == $1.frameCount
          && $0.readStartSample == $1.readStartSample
      }
  }
}
