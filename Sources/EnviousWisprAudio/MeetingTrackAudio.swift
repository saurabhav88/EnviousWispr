@preconcurrency import AVFoundation
import Darwin
import EnviousWisprCore
import FluidAudio
import Foundation

/// Reads one EnviousMeet track back from its segment files on the meeting timeline (#3972 §3.6,
/// R15, R22).
///
/// The timeline is in samples at 16 kHz from the meeting's anchor. Each segment file sits at the
/// start time in its name; a recorder CAF's frame count comes from the file itself, never from
/// metadata. A compacted AAC file (#3147 PR4B) keeps the recorder's frame count (`logicalFrames`):
/// AAC decodes to the same 16 kHz mono Float32 samples a CAF does, and codec padding never moves
/// a boundary or fills a gap (a decode shorter than the logical count reads as silence at its end,
/// within `SpeechAudioEncoder.durationToleranceFrames`; a longer one is cut at the logical end).
/// Anything between segments is a gap and reads as silence. A file that cannot be read, has the
/// wrong format or holds no audio is left out and listed in `problems`, so missing audio is
/// never mistaken for a gap; a read that fails later throws. Reads open only the files a range
/// touches, so a five-hour track costs one read's worth of memory at a time.
public final class MeetingTrackAudio: @unchecked Sendable {
  public struct Segment: Sendable, Equatable {
    public let url: URL
    public let startSample: Int
    public let frameCount: Int
    /// #3147 PR4B: the file holds compacted AAC; `frameCount` is the recorder's logical count.
    public var compressed = false
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

  /// One file a track reads.
  public struct SourceFile: Sendable, Equatable {
    public let url: URL
    public let startMs: Int
    /// The recorder's frame count when the file is compacted AAC; nil for a recorder CAF, whose
    /// length is read from the file.
    public let logicalFrames: Int?

    public init(url: URL, startMs: Int, logicalFrames: Int?) {
      self.url = url
      self.startMs = startMs
      self.logicalFrames = logicalFrames
    }
  }

  /// `files` are one track's recorder CAF segment files, in any order.
  public convenience init(files: [(url: URL, startMs: Int)]) {
    self.init(sources: files.map { SourceFile(url: $0.url, startMs: $0.startMs, logicalFrames: nil) })
  }

  /// #3147 PR4B: one track's segments as recovery listed them (`MeetingTrackRecovery.Report`),
  /// in any order: a compacted file (by its name) is read at the segment's logical frame count,
  /// a recorder CAF at its own length.
  public convenience init(segments: [MeetingSegmentInfo], in folder: URL) {
    self.init(
      sources: segments.map { info in
        let compacted = MeetingSegmentNaming.parseAny(info.fileName)?.encoding == .aacM4A
        return SourceFile(
          url: folder.appendingPathComponent(info.fileName), startMs: info.startMs,
          logicalFrames: compacted ? info.frameCount : nil)
      })
  }

  public init(sources files: [SourceFile]) {
    var found: [(url: URL, start: Int, frames: Int, compressed: Bool)] = []
    var problems: [Problem] = []
    for file in files {
      let name = file.url.lastPathComponent
      switch Self.inspect(file.url, logicalFrames: file.logicalFrames) {
      case .readable(let frames):
        found.append(
          (file.url, file.startMs * Self.samplesPerMs, frames, file.logicalFrames != nil))
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
          compressed: file.compressed, readStartSample: min(readStart, end)))
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
      let offset = readStart - segment.startSample
      // A compacted file may decode a little shorter than its logical length: the frames it
      // does not have read as silence (the logical boundary stays where the recorder put it).
      let available = segment.compressed ? max(0, min(frames, Int(file.length) - offset)) : frames
      let target = destination + (readStart - start)
      if available < frames {
        (target + available).update(repeating: 0, count: frames - available)
      }
      guard available > 0 else { continue }
      file.framePosition = AVAudioFramePosition(offset)
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(available)),
        (try? file.read(into: buffer, frameCount: AVAudioFrameCount(available))) != nil,
        let data = buffer.floatChannelData
      else {
        throw ReadError.unreadable(fileName: name)
      }
      guard Int(buffer.frameLength) == available else {
        throw ReadError.shortRead(
          fileName: name, expected: available, got: Int(buffer.frameLength))
      }
      target.update(from: data[0], count: available)
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

  package enum Inspection: Equatable {
    case readable(frames: Int)
    case empty
    case incompatible
    case unreadable
  }

  /// With `logicalFrames` nil: whether `url` is a readable 16 kHz mono 16-bit integer PCM file,
  /// and its frame count as the file itself reports it. With a logical count (#3147 PR4B):
  /// whether `url` is 16 kHz mono AAC whose length is within the encoder's tolerance of it; the
  /// logical count is then the segment's length.
  package static func inspect(_ url: URL, logicalFrames: Int? = nil) -> Inspection {
    guard let file = try? AVAudioFile(forReading: url) else { return .unreadable }
    let format = file.fileFormat.streamDescription.pointee
    if let logicalFrames {
      guard format.mFormatID == kAudioFormatMPEG4AAC, format.mChannelsPerFrame == 1,
        format.mSampleRate == MeetingAudioFormat.sampleRate,
        file.processingFormat.sampleRate == MeetingAudioFormat.sampleRate,
        file.processingFormat.channelCount == 1
      else { return .incompatible }
      guard logicalFrames > 0, file.length > 0 else { return .empty }
      guard abs(file.length - Int64(logicalFrames)) <= SpeechAudioEncoder.durationToleranceFrames
      else { return .incompatible }
      return .readable(frames: logicalFrames)
    }
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
    /// #3147 PR4B: which files the lists name: the recorder's CAF, or the committed compacted
    /// inventory's AAC.
    public var representation: MeetingAudioEncoding = .pcmCAF
    /// #3147 PR4B: what reading a committed inventory found that is not the recording's damage
    /// (the lists above carry that): a refused inventory, a fall back to the verified originals,
    /// an original the inventory does not cover. Logged, never read as audio.
    public var compressedProblems: [CompressedProblem] = []

    public init() {}
  }

  /// #3147 PR4B: a finding about the committed compacted inventory.
  public enum CompressedProblem: Sendable, Equatable {
    /// The selector refused the inventory; nothing of it was read.
    case selectionRefused(MeetingAudioSelection.Refusal)
    /// A compacted file could not be used (missing, wrong size or format, unreadable).
    case compressedUnusable(Problem)
    /// The compacted set was not usable, and every original it was made from is still on disk
    /// with exactly the bytes the inventory recorded: the originals were read instead, whole.
    case fellBackToOriginals
    /// The compacted set was not usable and the originals are not all there unchanged.
    case originalsUnavailable
    /// A recorder file outside the committed inventory: kept, never read beside it.
    case uncoveredOriginal(fileName: String)
  }

  /// `syncDirectory` makes the promoting renames durable (nil on success, else errno); nil uses
  /// the writer's directory sync. A parameter so a test can make it fail.
  ///
  /// #3147 PR4B: with a committed `inventory` (the record's `compressedAudio`) the lists come
  /// from it alone, through `MeetingAudioSelection`: its compacted files at the recorder's
  /// descriptors, and cleaned-copy proof only from the proof files it recorded, unchanged, and
  /// only for twins whose exact source descriptor it maps. Nothing is promoted or renamed. A
  /// compacted file that cannot be used is damage, never a reason to read a mix: the originals
  /// are read instead only when every one is on disk with the bytes the inventory recorded.
  /// `identity` gives a file's exact bytes (`MeetingStore.audioFileIdentity(at:)`, the one
  /// definition the inventory was made and committed with).
  public static func recover(
    folder: URL, inventory: MeetingCompressedInventory?,
    identity: (URL) throws -> MeetingAudioFileIdentity,
    syncDirectory: ((URL) -> Int32?)? = nil
  ) -> Report {
    if let inventory {
      return recoverCompacted(folder: folder, inventory: inventory, identity: identity)
    }
    return recover(folder: folder, syncDirectory: syncDirectory)
  }

  /// The recorder's files alone (a meeting with no committed compacted inventory).
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

extension MeetingTrackRecovery {
  /// The lists from a committed compacted inventory (see `recover`).
  static func recoverCompacted(
    folder: URL, inventory: MeetingCompressedInventory,
    identity: (URL) throws -> MeetingAudioFileIdentity
  ) -> Report {
    var report = Report()
    report.representation = .aacM4A
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    } catch {
      let code = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code
      report.problems.append(.folderUnreadable(errno: Int32(code ?? Int(EIO))))
      return report
    }
    for name in names {
      guard let parsed = MeetingSegmentNaming.parseAny(name) else { continue }
      report.highestIndex[parsed.track] = max(
        report.highestIndex[parsed.track] ?? 0, parsed.index)
    }
    for segment in inventory.segments {
      report.highestIndex[segment.track] = max(
        report.highestIndex[segment.track] ?? 0, segment.source.index)
    }
    // Recorder files the inventory does not map are reported, never read beside it.
    let mapped = Set(inventory.segments.map(\.source.fileName))
    for name in names.sorted() {
      guard let parsed = MeetingSegmentNaming.parse(name), !parsed.partial, !mapped.contains(name)
      else { continue }
      report.compressedProblems.append(.uncoveredOriginal(fileName: name))
    }

    // The logical set the inventory describes, each segment once, so the selector itself judges
    // a repeated or conflicting entry (it refuses the inventory then).
    var logicalKeys: Set<MeetingAudioSegmentKey> = []
    let logical = inventory.segments.filter { logicalKeys.insert($0.key).inserted }.map {
      MeetingLogicalSegment(track: $0.track, variant: $0.variant, segment: $0.source)
    }
    var compacted = Report()
    var usable = true
    do throws(MeetingAudioSelection.Refusal) {
      let selected = try MeetingAudioSelection.select(logical: logical, inventory: inventory)
      let byKey = Dictionary(
        inventory.segments.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
      for item in selected {
        guard let entry = byKey[item.key] else { continue }
        let info = MeetingSegmentInfo(
          index: item.logical.index, fileName: item.fileName, startMs: item.logical.startMs,
          frameCount: item.logical.frameCount)
        let url = folder.appendingPathComponent(item.fileName)
        let problem: Problem?
        // The exact committed bytes, not only a plausible header: a changed payload is damage.
        if (try? identity(url)) != entry.compressedIdentity {
          problem =
            FileManager.default.fileExists(atPath: url.path)
            ? .incompatibleFinal(fileName: item.fileName)
            : .unreadableFinal(fileName: item.fileName)
        } else {
          switch MeetingTrackAudio.inspect(url, logicalFrames: item.logical.frameCount) {
          case .readable: problem = nil
          case .empty: problem = .emptyFinal(fileName: item.fileName)
          case .incompatible: problem = .incompatibleFinal(fileName: item.fileName)
          case .unreadable: problem = .unreadableFinal(fileName: item.fileName)
          }
        }
        if let problem {
          usable = false
          if item.key.variant == .cleaned {
            compacted.cleanedProblems.append(problem)
          } else {
            compacted.problems.append(problem)
          }
        } else if item.key.variant == .cleaned {
          compacted.cleanedSegments.append(info)
        } else {
          compacted.segments[item.key.track, default: []].append(info)
        }
      }
    } catch {
      usable = false
      report.compressedProblems.append(.selectionRefused(error))
    }

    if !usable {
      for problem in compacted.problems + compacted.cleanedProblems {
        report.compressedProblems.append(.compressedUnusable(problem))
      }
      if let originals = verifiedOriginals(folder: folder, inventory: inventory, identity: identity)
      {
        report.compressedProblems.append(.fellBackToOriginals)
        report.representation = .pcmCAF
        report.segments = originals.segments
        report.cleanedSegments = originals.cleanedSegments
        report.cleanedConfirmed = originals.cleanedConfirmed
        report.cleanedProblems = originals.cleanedProblems
        sortLists(&report)
        return report
      }
      report.compressedProblems.append(.originalsUnavailable)
      // The compacted files' damage stays the recording's damage: never silently a gap.
    }
    report.segments = compacted.segments
    report.cleanedSegments = compacted.cleanedSegments
    report.problems.append(contentsOf: compacted.problems)
    report.cleanedProblems.append(contentsOf: compacted.cleanedProblems)

    // Cleaned-copy proof, carried across representations: a proof file counts only when the
    // inventory recorded it and its bytes are unchanged, and each twin it lists must be the exact
    // source descriptor of an inventory cleaned segment. A matching file name is not proof.
    let cleanedEntries = inventory.segments.filter {
      $0.variant == .cleaned && $0.track == .microphone
    }
    for (name, recorded) in inventory.cleanedProofs.sorted(by: { $0.key < $1.key }) {
      let url = folder.appendingPathComponent(name)
      guard MeetingSegmentNaming.isCleanedProof(name), !name.contains("/"),
        (try? identity(url)) == recorded,
        let data = FileManager.default.contents(atPath: url.path),
        let proof = try? JSONDecoder().decode(MeetingCleanedProof.self, from: data)
      else {
        report.cleanedProblems.append(.unreadableProof(fileName: name))
        continue
      }
      for twin in proof.segments {
        guard let entry = cleanedEntries.first(where: { $0.source == twin }) else { continue }
        report.cleanedConfirmed.append(
          MeetingSegmentInfo(
            index: entry.source.index, fileName: entry.compressed.fileName,
            startMs: entry.source.startMs, frameCount: entry.source.frameCount))
      }
    }
    sortLists(&report)
    return report
  }

  /// The originals as one complete representation, only when every source file the inventory
  /// names is on disk with exactly the recorded bytes; nil otherwise. Proof is read the
  /// recorder's way (the proofs list these exact CAF names).
  static func verifiedOriginals(
    folder: URL, inventory: MeetingCompressedInventory,
    identity: (URL) throws -> MeetingAudioFileIdentity
  ) -> Report? {
    var report = Report()
    var keys: Set<MeetingAudioSegmentKey> = []
    for segment in inventory.segments {
      // A repeated segment is read once, and only when every entry names the same original.
      guard keys.insert(segment.key).inserted else {
        guard inventory.segments.first(where: { $0.key == segment.key })?.source == segment.source
        else { return nil }
        continue
      }
      let url = folder.appendingPathComponent(segment.source.fileName)
      guard (try? identity(url)) == segment.sourceIdentity,
        case .readable(let frames) = MeetingTrackAudio.inspect(url),
        frames == segment.source.frameCount
      else { return nil }
      if segment.variant == .cleaned {
        report.cleanedSegments.append(segment.source)
      } else {
        report.segments[segment.track, default: []].append(segment.source)
      }
    }
    for (name, recorded) in inventory.cleanedProofs.sorted(by: { $0.key < $1.key }) {
      let url = folder.appendingPathComponent(name)
      guard MeetingSegmentNaming.isCleanedProof(name), !name.contains("/"),
        (try? identity(url)) == recorded,
        let data = FileManager.default.contents(atPath: url.path),
        let proof = try? JSONDecoder().decode(MeetingCleanedProof.self, from: data)
      else {
        report.cleanedProblems.append(.unreadableProof(fileName: name))
        continue
      }
      report.cleanedConfirmed.append(contentsOf: proof.segments)
    }
    return report
  }

  private static func sortLists(_ report: inout Report) {
    for track in report.segments.keys {
      report.segments[track]?.sort { ($0.startMs, $0.index) < ($1.startMs, $1.index) }
    }
    report.cleanedSegments.sort { ($0.startMs, $0.index) < ($1.startMs, $1.index) }
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
