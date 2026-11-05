import AVFoundation
import CoreAudio
import EnviousWisprAppKitTestSupport
import Foundation
import Testing
import os

@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprCore
@testable import EnviousWisprStorage

/// #4355 PR B: the microphone's echo-cleaned copy on disk. When these fail, the cleaned copy is
/// placed, muted or cut differently from the raw audio, a cleaned-copy failure costs raw
/// recording audio, or a damaged or partial cleaned set is read as if it were whole.
@Suite(
  "Meeting writer cleaned copy (#4355)", .serialized, .tags(.productOutcome, .realBoundary),
  .realBoundaryRun)
struct MeetingTrackWriterCleanedSetTests {
  static let rawLevel: Float = 0.25
  static let cleanedLevel: Float = -0.125
  static let provenance = MeetingEchoProvenance(
    library: "webrtc-audio-processing 2.1 846fe90 ew-4355.3", configuration: "aec3-16k-mono")

  /// Stands in for the capture and echo worker that chunk 4 connects: it builds worker results
  /// exactly as `MeetingEchoCanceller` returns them (raw samples, an equally long cleaned copy,
  /// raw again with a reason when substituted) and hands each to the REAL writer's paired append.
  struct PairedWriterProducer {
    let recording: UUID
    let anchor: UInt64
    let writer: MeetingTrackWriter

    static func ticks(_ samples: Int) -> UInt64 {
      MeetingMicrophoneSilence.ticks(forSamples: samples)
    }

    func result(at sample: Int, count: Int, substituted: Bool) -> MeetingEchoResult {
      let raw = [Float](repeating: MeetingTrackWriterCleanedSetTests.rawLevel, count: count)
      let cleaned =
        substituted
        ? raw : [Float](repeating: MeetingTrackWriterCleanedSetTests.cleanedLevel, count: count)
      return MeetingEchoResult(
        acquired: MeetingAcquisitionTime(
          recording: recording, hostTicks: anchor &+ Self.ticks(sample), provenance: .estimated),
        run: 0, raw: raw, cleaned: cleaned, substitution: substituted ? .reacquiring : nil)
    }

    func hand(_ result: MeetingEchoResult, startsNewRun: Bool = false, withCopy: Bool = true) {
      result.raw.withUnsafeBufferPointer { raw in
        result.cleaned.withUnsafeBufferPointer { cleaned in
          writer.append(
            raw, cleaned: withCopy ? cleaned : nil, hostTime: result.acquired.hostTicks,
            startsNewRun: startsNewRun)
        }
      }
    }
  }

  final class Collector: Sendable {
    let segments = OSAllocatedUnfairLock<[MeetingSegmentInfo]>(initialState: [])
    let failures = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// Every published slice: its span, and its first sample.
    let released = OSAllocatedUnfairLock<[(MeetingAudioSpan, Float)]>(initialState: [])
  }

  struct Rig {
    let dir: URL
    let recording = UUID()
    let anchor: UInt64
    let collector = Collector()
    let writer: MeetingTrackWriter
    let producer: PairedWriterProducer

    /// A 1 s segment length and a 0 s hold, so rollover and masking happen in a few seconds of
    /// audio. The anchor is in the past, so every chunk is due as soon as it is drained.
    init(cleanedCopy: Bool = true, hold: Double? = 0) throws {
      dir = TestTemporaryDirectory.url
        .appendingPathComponent("MeetingCleanedSet-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      anchor = mach_absolute_time() &- MeetingMicrophoneSilence.ticks(nanos: 600_000_000_000)
      let collector = self.collector
      writer = MeetingTrackWriter(
        configuration: .init(
          meetingID: recording, track: .microphone, folder: dir, anchorHostTime: anchor,
          segmentSeconds: 1, silenceHoldSeconds: hold, cleanedCopy: cleanedCopy),
        onSegmentFinalized: { info in collector.segments.withLock { $0.append(info) } },
        onFailure: { _ in collector.failures.withLock { $0 += 1 } },
        onReleased: { frames, chunk in
          let first = frames.first ?? .nan
          collector.released.withLock { $0.append((chunk.span, first)) }
        }, now: { mach_absolute_time() }, scheduler: .live)
      producer = PairedWriterProducer(recording: recording, anchor: anchor, writer: writer)
    }

    func names() throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func samples(_ name: String) throws -> [Float] {
      let file = try AVAudioFile(forReading: dir.appendingPathComponent(name))
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
      try file.read(into: buffer)
      return Array(
        UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
  }

  static func near(_ value: Float, _ target: Float) -> Bool { abs(value - target) < 0.001 }

  @Test(
    "raw and cleaned twins share segments, positions, pre-anchor trim, mute, gaps and rollover; live words get the cleaned samples"
  )
  func twinsMatchRawPlacement() async throws {
    let rig = try Rig()
    // Muted from 0.5 s to 0.75 s on the acquisition clock: both copies take zeros there.
    rig.writer.setSilencedIntervals([
      MeetingSilenceInterval(
        start: MeetingAcquisitionTime(
          recording: rig.recording, hostTicks: rig.anchor &+ PairedWriterProducer.ticks(8_000),
          provenance: .observed),
        end: MeetingAcquisitionTime(
          recording: rig.recording, hostTicks: rig.anchor &+ PairedWriterProducer.ticks(12_000),
          provenance: .observed))
    ])
    // 50 ms before the anchor is trimmed from both copies.
    let early = MeetingEchoResult(
      acquired: MeetingAcquisitionTime(
        recording: rig.recording, hostTicks: rig.anchor &- PairedWriterProducer.ticks(800),
        provenance: .estimated),
      run: 0, raw: [Float](repeating: Self.rawLevel, count: 1_600),
      cleaned: [Float](repeating: Self.cleanedLevel, count: 1_600), substitution: nil)
    rig.producer.hand(early)
    // 0.05 s to 1.6 s in 100 ms chunks (rolls over at 1 s); the chunk at 1.15 s is substituted.
    var sample = 800
    while sample < 25_600 {
      rig.producer.hand(
        rig.producer.result(at: sample, count: 1_600, substituted: sample == 18_400))
      sample += 1_600
    }
    // A 3 s jump: a gap starts a new segment; then a producer run break starts another.
    rig.producer.hand(rig.producer.result(at: 80_000, count: 1_600, substituted: false))
    rig.producer.hand(
      rig.producer.result(at: 81_600, count: 1_600, substituted: false), startsNewRun: true)
    #expect(await rig.writer.finish() == .finalized)

    let health = rig.writer.currentHealth
    #expect(rig.collector.failures.withLock { $0 } == 0)
    #expect(!health.cleanedFailed)
    #expect(health.preAnchorFrames == 800)
    let raw = rig.collector.segments.withLock { $0 }
    #expect(raw.count == 4)
    #expect(health.cleanedSegmentsFinalized == raw.count)
    let names = try rig.names()
    #expect(!names.contains { $0.hasSuffix(MeetingAudioFormat.partialExtension) })
    for segment in raw {
      let twinName = MeetingSegmentNaming.fileName(
        track: .microphone, variant: .cleaned, index: segment.index, startMs: segment.startMs,
        partial: false)
      #expect(names.contains(twinName), "\(twinName)")
      let rawSamples = try rig.samples(segment.fileName)
      let twin = try rig.samples(twinName)
      #expect(rawSamples.count == segment.frameCount && twin.count == segment.frameCount)
      #expect(!rawSamples.isEmpty)
      for i in rawSamples.indices {
        // The same zeros at the same samples; elsewhere raw is raw and the twin is cleaned
        // (or raw again where the worker substituted).
        if rawSamples[i] == 0 {
          #expect(twin[i] == 0)
        } else {
          #expect(Self.near(rawSamples[i], Self.rawLevel))
          #expect(Self.near(twin[i], Self.cleanedLevel) || Self.near(twin[i], Self.rawLevel))
        }
      }
    }
    // Segment 1 (0 s to 1 s): the mute zeroed 0.5 s to 0.75 s of both copies.
    let first = try rig.samples(raw[0].fileName)
    let firstTwin = try rig.samples(
      MeetingSegmentNaming.fileName(
        track: .microphone, variant: .cleaned, index: raw[0].index, startMs: raw[0].startMs,
        partial: false))
    #expect(first[8_000..<12_000].allSatisfy { $0 == 0 })
    #expect(firstTwin[8_000..<12_000].allSatisfy { $0 == 0 })
    #expect(Self.near(firstTwin[4_000], Self.cleanedLevel))
    // The substituted chunk (1.15 s to 1.25 s) is raw in both copies; its neighbour is cleaned.
    let secondTwin = try rig.samples(
      MeetingSegmentNaming.fileName(
        track: .microphone, variant: .cleaned, index: raw[1].index, startMs: raw[1].startMs,
        partial: false))
    #expect(Self.near(secondTwin[2_400 + 100], Self.rawLevel))
    #expect(Self.near(secondTwin[4_000 + 100], Self.cleanedLevel))
    #expect(raw.map(\.startMs) == [0, 1_000, 5_000, 5_100])

    // Live words got the cleaned samples, at the spans actually written.
    let released = rig.collector.released.withLock { $0 }
    #expect(!released.isEmpty)
    #expect(released.reduce(0) { $0 + $1.0.sampleCount } == raw.reduce(0) { $0 + $1.frameCount })
    #expect(released.first?.0.startSample == 0)
    #expect(released.contains { Self.near($0.1, Self.cleanedLevel) })
    #expect(Set(released.map(\.0.run)).count == 3)
  }

  @Test(
    "a cleaned-copy failure at write, at finalize, or a chunk without its copy leaves raw writing whole and leaves no partial twin"
  )
  func derivativeFailureNeverCostsRaw() async throws {
    for fault in [MeetingTrackWriter.CleanedFault.write, .finalize, nil] {
      let rig = try Rig(hold: nil)
      if let fault { rig.writer.setCleanedFaultForTesting(fault) }
      var sample = 0
      while sample < 40_000 {
        // With no injected fault, the chunk at 1 s comes without its copy.
        let missing = fault == nil && sample == 16_000
        rig.producer.hand(
          rig.producer.result(at: sample, count: 1_600, substituted: false), withCopy: !missing)
        sample += 1_600
      }
      #expect(await rig.writer.finish() == .finalized, "\(String(describing: fault))")
      let health = rig.writer.currentHealth
      #expect(rig.collector.failures.withLock { $0 } == 0)
      #expect(!health.failed)
      #expect(health.cleanedFailed)
      let raw = rig.collector.segments.withLock { $0 }
      #expect(raw.count == 3)
      #expect(raw.reduce(0) { $0 + $1.frameCount } == 40_000)
      let names = try rig.names()
      #expect(!names.contains { $0.hasSuffix(MeetingAudioFormat.partialExtension) })
      let twins = names.filter { $0.hasPrefix(MeetingSegmentNaming.cleanedMicrophoneStem + "-") }
      #expect(twins.count < raw.count)
      // After the failure every live slice is raw.
      let released = rig.collector.released.withLock { $0 }
      #expect(released.last.map { Self.near($0.1, Self.rawLevel) } == true)
    }
  }

  @Test(
    "recovery keeps the copies apart, promotes both partials, and the final pass uses cleaned only as a complete set"
  )
  func recoveryAndWholeSetSelection() async throws {
    let rig = try Rig(hold: nil)
    var sample = 0
    while sample < 40_000 {
      rig.producer.hand(rig.producer.result(at: sample, count: 1_600, substituted: false))
      sample += 1_600
    }
    // The state a crash leaves: the last segment of each copy still `.partial`.
    await rig.writer.waitUntilWritten()
    let copy = rig.dir.deletingLastPathComponent()
      .appendingPathComponent("crash-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.copyItem(at: rig.dir, to: copy)
    _ = await rig.writer.finish()
    let partials = try FileManager.default.contentsOfDirectory(atPath: copy.path)
      .filter { $0.hasSuffix(MeetingAudioFormat.partialExtension) }
    #expect(partials.count == 2)

    let report = MeetingTrackRecovery.recover(folder: copy)
    #expect(report.problems.isEmpty)
    #expect(report.cleanedProblems.isEmpty)
    #expect(report.promoted.count == 2)
    let raw = report.segments[.microphone] ?? []
    #expect(raw.count == 3)
    #expect(raw.allSatisfy { !$0.fileName.hasPrefix(MeetingSegmentNaming.cleanedMicrophoneStem) })
    #expect(report.cleanedSegments.count == 3)
    #expect(report.highestIndex[.microphone] == 3)

    // A crash leaves no proof: every twin is there and readable, and the pass still reads raw.
    #expect(report.cleanedConfirmed.isEmpty)
    #expect(
      MeetingMicrophoneSelection.decide(raw: raw, report: report, provenance: Self.provenance)
        == .raw(.unconfirmed))

    // After the clean close, the writer's proof confirms every twin.
    let closed = MeetingTrackRecovery.recover(folder: rig.dir)
    let closedRaw = closed.segments[.microphone] ?? []
    #expect(closedRaw.count == 3)
    #expect(closed.cleanedConfirmed.count == 3)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: rig.dir.path)
        .filter(MeetingSegmentNaming.isCleanedProof) == [
          MeetingSegmentNaming.cleanedProofName(first: 1, last: 3)
        ])

    // Complete, matching, with provenance: cleaned.
    guard
      case .cleaned(let chosen, let provenance) = MeetingMicrophoneSelection.decide(
        raw: closedRaw, report: closed, provenance: Self.provenance)
    else {
      Issue.record("a complete cleaned set was not chosen")
      return
    }
    #expect(provenance == Self.provenance)
    let rawAudio = MeetingTrackAudio(
      files: closedRaw.map { (rig.dir.appendingPathComponent($0.fileName), $0.startMs) })
    let cleanedAudio = MeetingTrackAudio(
      files: chosen.map { (rig.dir.appendingPathComponent($0.fileName), $0.startMs) })
    #expect(MeetingMicrophoneSelection.readMatches(cleanedAudio, raw: rawAudio))
    #expect(Self.near(try cleanedAudio.read(from: 100, count: 1)[0], Self.cleanedLevel))

    // No provenance: raw.
    #expect(
      MeetingMicrophoneSelection.decide(raw: closedRaw, report: closed, provenance: nil)
        == .raw(.noProvenance))
    // One twin missing: raw, whole; the raw set still reads.
    var missing = closed
    missing.cleanedSegments.removeLast()
    #expect(
      MeetingMicrophoneSelection.decide(raw: closedRaw, report: missing, provenance: Self.provenance)
        == .raw(.incomplete))
    #expect(Self.near(try rawAudio.read(from: 100, count: 1)[0], Self.rawLevel))
    // A twin with another frame count, or two twins for one index: raw.
    var mismatched = closed
    let last = mismatched.cleanedSegments.removeLast()
    mismatched.cleanedSegments.append(
      MeetingSegmentInfo(
        index: last.index, fileName: last.fileName, startMs: last.startMs,
        frameCount: last.frameCount - 1))
    #expect(
      MeetingMicrophoneSelection.decide(raw: closedRaw, report: mismatched, provenance: Self.provenance)
        == .raw(.mismatch))
    var doubled = closed
    doubled.cleanedSegments[1] = doubled.cleanedSegments[0]
    #expect(
      MeetingMicrophoneSelection.decide(raw: closedRaw, report: doubled, provenance: Self.provenance)
        == .raw(.mismatch))

    // A damaged cleaned file: a cleaned problem only. Raw has no problem and no gap.
    let damagedName = try #require(closed.cleanedSegments.first?.fileName)
    try Data([0, 1, 2, 3]).write(to: rig.dir.appendingPathComponent(damagedName))
    let damaged = MeetingTrackRecovery.recover(folder: rig.dir)
    #expect(damaged.problems.isEmpty)
    #expect(!damaged.cleanedProblems.isEmpty)
    #expect((damaged.segments[.microphone] ?? []).count == 3)
    #expect(
      MeetingMicrophoneSelection.decide(raw: closedRaw, report: damaged, provenance: Self.provenance)
        == .raw(.cleanedProblem))
  }

  @Test("the store lists, measures and deletes both copies; playback reads only raw")
  func storeAndPlaybackSeeTheRightCopies() async throws {
    let rig = try Rig(hold: nil)
    let root = rig.dir.deletingLastPathComponent()
      .appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
    let store = MeetingStore(root: root)
    let meeting = rig.recording
    try FileManager.default.createDirectory(
      at: store.folder(for: meeting), withIntermediateDirectories: true)
    var sample = 0
    while sample < 24_000 {
      rig.producer.hand(rig.producer.result(at: sample, count: 1_600, substituted: false))
      sample += 1_600
    }
    _ = await rig.writer.finish()
    let names = try rig.names()
    for name in names {
      try FileManager.default.copyItem(
        at: rig.dir.appendingPathComponent(name),
        to: store.folder(for: meeting).appendingPathComponent(name))
    }
    // An unfinished twin is audio too.
    let partialTwin = MeetingSegmentNaming.fileName(
      track: .microphone, variant: .cleaned, index: 9, startMs: 9_000, partial: true)
    try Data([1, 2]).write(to: store.folder(for: meeting).appendingPathComponent(partialTwin))

    let files = try store.segmentFiles(meeting: meeting)
    let cleaned = files.filter { $0.variant == .cleaned }
    let raw = files.filter { $0.variant == .raw }
    #expect(raw.count == 2)
    #expect(cleaned.count == 3)
    #expect(try store.highestIndex(meeting: meeting, track: .microphone) == 9)
    let expectedBytes = try files.reduce(Int64(0)) {
      $0 + Int64(try $1.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    #expect(try store.audioBytes(meeting: meeting) == expectedBytes)
    #expect(expectedBytes > 0)

    // Playback is built from the record, which lists raw segments only.
    var record = MeetingRecord(
      id: meeting, engine: .parakeet, trackStatus: [.microphone: .captured])
    record.segments[.microphone] = rig.collector.segments.withLock { $0 }
    let source = MeetingPlaybackSource(record: record, folder: store.folder(for: meeting))
    let played = (source.files[.microphone] ?? []).map(\.url.lastPathComponent)
    #expect(played.count == 2)
    #expect(played.allSatisfy { !$0.hasPrefix(MeetingSegmentNaming.cleanedMicrophoneStem) })

    let proofs = try FileManager.default.contentsOfDirectory(
      atPath: store.folder(for: meeting).path
    ).filter(MeetingSegmentNaming.isCleanedProof)
    #expect(proofs.count == 1)
    try store.deleteAudio(meeting: meeting)
    #expect(try store.segmentFiles(meeting: meeting).isEmpty)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: store.folder(for: meeting).path)
        .filter(MeetingSegmentNaming.isCleanedProof).isEmpty)
    for file in files { #expect(!FileManager.default.fileExists(atPath: file.url.path)) }
  }

  @Test("a twin whose finalization fails after its rename, on the last segment, never completes a set the pass would choose")
  func failedLastTwinNeverQualifies() async throws {
    let rig = try Rig(hold: nil)
    var sample = 0
    while sample < 40_000 {
      rig.producer.hand(rig.producer.result(at: sample, count: 1_600, substituted: false))
      sample += 1_600
    }
    await rig.writer.waitUntilWritten()
    // Segments 1 and 2 finalized cleanly; the fault hits only the last twin, after its rename.
    #expect(rig.writer.currentHealth.cleanedSegmentsFinalized == 2)
    rig.writer.setCleanedFaultForTesting(.afterRename)
    #expect(await rig.writer.finish() == .finalized)
    #expect(rig.writer.currentHealth.cleanedFailed)
    #expect(rig.collector.failures.withLock { $0 } == 0)
    let report = MeetingTrackRecovery.recover(folder: rig.dir)
    let raw = report.segments[.microphone] ?? []
    #expect(raw.count == 3)
    #expect(report.cleanedSegments.count == 2)
    #expect(
      MeetingMicrophoneSelection.decide(raw: raw, report: report, provenance: Self.provenance)
        == .raw(.incomplete))
  }

  @Test("when cleanup of a failed twin fails too, or the proof cannot be written, every twin can be readable and the pass still reads raw")
  func noProofMeansRaw() async throws {
    for fault in [MeetingTrackWriter.CleanedFault.afterRenameKeepingTwin, .proof] {
      let rig = try Rig(hold: nil)
      var sample = 0
      while sample < 40_000 {
        rig.producer.hand(rig.producer.result(at: sample, count: 1_600, substituted: false))
        sample += 1_600
      }
      await rig.writer.waitUntilWritten()
      rig.writer.setCleanedFaultForTesting(fault)
      #expect(await rig.writer.finish() == .finalized, "\(fault)")
      #expect(rig.writer.currentHealth.cleanedFailed)
      #expect(rig.collector.failures.withLock { $0 } == 0)
      let report = MeetingTrackRecovery.recover(folder: rig.dir)
      let raw = report.segments[.microphone] ?? []
      #expect(raw.count == 3)
      // Every twin is on disk and readable: the failed cleanup or proof left them.
      #expect(report.cleanedSegments.count == 3)
      #expect(report.cleanedProblems.isEmpty)
      #expect(report.cleanedConfirmed.isEmpty)
      #expect(
        MeetingMicrophoneSelection.decide(raw: raw, report: report, provenance: Self.provenance)
          == .raw(.unconfirmed))
    }
  }

  @Test("closing twice publishes the proof once: both closes succeed, nothing is marked failed, and the set is still chosen")
  func repeatedCloseKeepsTheProof() async throws {
    let rig = try Rig(hold: nil)
    var sample = 0
    while sample < 24_000 {
      rig.producer.hand(rig.producer.result(at: sample, count: 1_600, substituted: false))
      sample += 1_600
    }
    #expect(await rig.writer.finish() == .finalized)
    #expect(await rig.writer.finish() == .finalized)
    #expect(rig.writer.close(until: .now() + 10) == .finalized)
    #expect(!rig.writer.currentHealth.cleanedFailed)
    let report = MeetingTrackRecovery.recover(folder: rig.dir)
    let raw = report.segments[.microphone] ?? []
    #expect(raw.count == 2)
    #expect(report.cleanedConfirmed.count == 2)
    guard case .cleaned = MeetingMicrophoneSelection.decide(
      raw: raw, report: report, provenance: Self.provenance)
    else {
      Issue.record("the closed-twice set was not chosen")
      return
    }
  }
}
