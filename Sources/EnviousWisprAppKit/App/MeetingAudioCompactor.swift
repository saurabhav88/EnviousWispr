import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprStorage
import Foundation

/// #3147 PR4B contract: one claimed compaction of one meeting, as `MeetingCoordinator` hands it
/// out (`claimAudioCompaction`). Carries what the claim was made against, so publication can
/// refuse a meeting that changed meanwhile (generation, segments, the claim itself).
struct MeetingAudioCompactionTicket: Equatable, Sendable {
  let meetingID: UUID
  let claimID: UUID
  let transcriptGeneration: UUID?
  let sourceSegments: [MeetingTrackKind: [MeetingSegmentInfo]]
}

/// #3147 PR4B contract: what finishing a compaction did.
enum MeetingAudioCompactionOutcome: Equatable, Sendable {
  /// The verified inventory is the meeting's reader authority now.
  case committed
  /// The meeting changed after the claim (generation, segments, deletion, a newer claim):
  /// nothing was published.
  case stale
  /// Nothing to do (no bytes saved, or the meeting is not eligible).
  case skipped
  /// Publication failed; the previous representation stays the authority.
  case failed
}

/// #3147 PR4B contract: an inventory whose every output was reopened, decoded and checked by
/// the compactor. Only this file's verification path constructs one (`fileprivate init`), so
/// publication can never be handed an unchecked inventory. Owned by lane B after the contract.
struct VerifiedMeetingAudioInventory: Sendable {
  let inventory: MeetingCompressedInventory

  fileprivate init(_ inventory: MeetingCompressedInventory) {
    self.inventory = inventory
  }
}

/// #3147 PR4B contract: prepares a meeting's compacted audio off the main actor and returns it
/// verified. It writes only its own uncommitted outputs; it never publishes a record and never
/// removes an original file.
@MainActor
protocol MeetingAudioCompacting: AnyObject {
  func prepare(
    ticket: MeetingAudioCompactionTicket, record: MeetingRecord, folder: URL
  ) async throws -> VerifiedMeetingAudioInventory
}

/// #3147 PR4B lane B: prepares one meeting's compacted audio and proves it before anyone may
/// publish it.
///
/// Off the main actor, at utility priority, it captures the exact source set (every recorder CAF
/// final, raw and cleaned, and every cleaned-copy proof, each by its full SHA-256), encodes each
/// segment on its own with the production `.meeting` encoder into `<final name>.partial` files
/// named for a new inventory id (never one large file, never closing a gap), reopens and checks
/// every output (AAC 16 kHz mono, decoded length within the encoder's tolerance of the recorder's
/// frame count, its own identity), then hashes every source again and refuses anything that
/// changed meanwhile. It writes only those `.partial` files: it never promotes them, never
/// commits a record, and never touches an original. Any failure or cancellation removes the
/// partial files this call created, and only those; `prepare` returns only after that.
final class MeetingAudioCompactor: MeetingAudioCompacting {
  enum PreparationError: Error, Equatable {
    /// The record or folder is not something to compact now (the reason, for the log).
    case notEligible(String)
    /// A source file, proof or the folder's recorder files changed while preparing.
    case sourceChanged
    /// The verified result would not save any bytes.
    case noSavings
    /// The encoder failed for one segment.
    case encodeFailed(fileName: String)
    /// An output did not reopen as the expected audio.
    case verificationFailed(fileName: String)
  }

  struct Dependencies: Sendable {
    /// Encodes one source file to one destination (the production `.meeting` encoder).
    var encode: @Sendable (URL, URL) throws -> SpeechAudioEncoder.Output = { source, destination in
      try SpeechAudioEncoder.encode(fileAt: source, purpose: .meeting, to: destination)
    }
    /// Runs after every output is encoded and checked, before the sources are hashed again.
    /// Nothing in the app; a test changes a source here.
    var afterEncoding: @Sendable (URL) -> Void = { _ in }
  }

  private let deps: Dependencies

  init(dependencies: Dependencies = Dependencies()) {
    deps = dependencies
  }

  func prepare(
    ticket: MeetingAudioCompactionTicket, record: MeetingRecord, folder: URL
  ) async throws -> VerifiedMeetingAudioInventory {
    guard record.id == ticket.meetingID else { throw PreparationError.notEligible("meeting") }
    guard !record.deletionRequested else { throw PreparationError.notEligible("deleting") }
    guard record.compressedAudio == nil else { throw PreparationError.notEligible("compacted") }
    guard record.committedTranscriptGeneration == ticket.transcriptGeneration else {
      throw PreparationError.sourceChanged
    }
    guard record.segments == ticket.sourceSegments else { throw PreparationError.sourceChanged }
    let deps = deps
    let id = UUID()
    // Detached: synchronous hashing and encoding of every segment (minutes of audio) must not
    // run on the main actor, and a plain Task would inherit it. Awaited at once; cancelling the
    // caller cancels it, and the await returns only once it removed its own outputs.
    let work = Task.detached(priority: .utility) {
      try Self.build(ticket: ticket, folder: folder, inventoryID: id, deps: deps)
    }
    let inventory = try await withTaskCancellationHandler {
      try await work.value
    } onCancel: {
      work.cancel()
    }
    let verified = VerifiedMeetingAudioInventory(inventory)
    // Cancelled after the work's last check: its result is not handed on, and its outputs go.
    if Task.isCancelled {
      Self.discard(verified, folder: folder)
      throw CancellationError()
    }
    return verified
  }

  /// Removes the uncommitted outputs of `verified` (its `.partial` files), for a preparation that
  /// will not be published. Never removes anything the inventory does not name, nor a promoted
  /// output. Returns how many files it removed.
  @discardableResult
  nonisolated static func discard(_ verified: VerifiedMeetingAudioInventory, folder: URL) -> Int {
    var removed = 0
    for segment in verified.inventory.segments {
      let url = folder.appendingPathComponent(partialName(segment.compressed.fileName))
      if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
    }
    return removed
  }

  /// The uncommitted name of a compacted file: its final name plus `.partial`, exactly the
  /// candidate name `MeetingStore.commitCompressedAudio` promotes
  /// (`MeetingSegmentNaming.compactedFileName(..., partial: true)`).
  nonisolated static func partialName(_ finalName: String) -> String {
    finalName + "." + MeetingSegmentNaming.compactedPartialExtension.dropFirst(
      MeetingSegmentNaming.compactedExtension.count + 1)
  }

  // MARK: - Off the main actor

  private struct Source {
    let track: MeetingTrackKind
    let variant: MeetingSegmentVariant
    let info: MeetingSegmentInfo
    let identity: MeetingAudioFileIdentity
  }

  nonisolated private static func build(
    ticket: MeetingAudioCompactionTicket, folder: URL, inventoryID: UUID, deps: Dependencies
  ) throws -> MeetingCompressedInventory {
    var created: [URL] = []
    do {
      let snapshot = try capture(folder: folder, expected: ticket.sourceSegments)
      var segments: [MeetingCompressedSegment] = []
      for source in snapshot.sources {
        try Task.checkCancellation()
        let finalName = MeetingSegmentNaming.compactedFileName(
          source: source.info, track: source.track, variant: source.variant,
          inventoryID: inventoryID, partial: false)
        let partialURL = folder.appendingPathComponent(partialName(finalName))
        let sourceURL = folder.appendingPathComponent(source.info.fileName)
        do {
          _ = try deps.encode(sourceURL, partialURL)
        } catch let error as CancellationError {
          throw error
        } catch {
          throw PreparationError.encodeFailed(fileName: source.info.fileName)
        }
        created.append(partialURL)
        let reader = MeetingTrackAudio(sources: [
          .init(url: partialURL, startMs: source.info.startMs, logicalFrames: source.info.frameCount)
        ])
        guard reader.problems.isEmpty, reader.segments.count == 1 else {
          throw PreparationError.verificationFailed(fileName: finalName)
        }
        segments.append(
          MeetingCompressedSegment(
            track: source.track, variant: source.variant, source: source.info,
            sourceIdentity: source.identity,
            compressed: MeetingSegmentInfo(
              index: source.info.index, fileName: finalName, startMs: source.info.startMs,
              frameCount: source.info.frameCount),
            compressedIdentity: try MeetingStore.audioFileIdentity(at: partialURL)))
      }
      deps.afterEncoding(folder)
      try Task.checkCancellation()
      // Nothing the result was made from may have changed: same recorder files, same bytes.
      let again = try capture(folder: folder, expected: ticket.sourceSegments)
      guard again.sources.map(\.info) == snapshot.sources.map(\.info),
        again.sources.map(\.identity) == snapshot.sources.map(\.identity),
        again.proofs == snapshot.proofs
      else { throw PreparationError.sourceChanged }
      try Task.checkCancellation()

      let inventory = MeetingCompressedInventory(
        id: inventoryID, transcriptGeneration: ticket.transcriptGeneration, segments: segments,
        cleanedProofs: snapshot.proofs)
      // The result must be one complete representation of exactly these segments.
      let logical = snapshot.sources.map {
        MeetingLogicalSegment(track: $0.track, variant: $0.variant, segment: $0.info)
      }
      guard (try? MeetingAudioSelection.select(logical: logical, inventory: inventory)) != nil
      else { throw PreparationError.verificationFailed(fileName: "inventory") }
      let before = snapshot.sources.reduce(Int64(0)) { $0 + $1.identity.byteCount }
      let after = segments.reduce(Int64(0)) { $0 + $1.compressedIdentity.byteCount }
      guard after < before else { throw PreparationError.noSavings }
      return inventory
    } catch {
      for url in created { try? FileManager.default.removeItem(at: url) }
      throw error
    }
  }

  /// The recorder's files as they are now: every CAF final, raw and cleaned, by start then
  /// index, each read and hashed, and every cleaned-copy proof by its bytes. Refuses a folder
  /// that is not a finished recording: an unpromoted partial, an unreadable or empty file, two
  /// files for one segment, or raw finals other than `expected`.
  nonisolated private static func capture(
    folder: URL, expected: [MeetingTrackKind: [MeetingSegmentInfo]]
  ) throws -> (sources: [Source], proofs: [String: MeetingAudioFileIdentity]) {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    } catch {
      throw PreparationError.notEligible("folder")
    }
    var sources: [Source] = []
    var keys: Set<String> = []
    for name in names {
      guard let parsed = MeetingSegmentNaming.parse(name) else { continue }
      guard !parsed.partial else { throw PreparationError.notEligible("partial") }
      guard keys.insert("\(parsed.track.rawValue)-\(parsed.variant.rawValue)-\(parsed.index)")
        .inserted
      else { throw PreparationError.notEligible("duplicate") }
      let url = folder.appendingPathComponent(name)
      guard case .readable(let frames) = MeetingTrackAudio.inspect(url) else {
        throw PreparationError.notEligible("unreadable")
      }
      sources.append(
        Source(
          track: parsed.track, variant: parsed.variant,
          info: MeetingSegmentInfo(
            index: parsed.index, fileName: name, startMs: parsed.startMs, frameCount: frames),
          identity: try MeetingStore.audioFileIdentity(at: url)))
    }
    sources.sort {
      ($0.track.rawValue, $0.variant.rawValue, $0.info.startMs, $0.info.index)
        < ($1.track.rawValue, $1.variant.rawValue, $1.info.startMs, $1.info.index)
    }
    for track in MeetingTrackKind.allCases {
      let found = sources.filter { $0.track == track && $0.variant == .raw }.map(\.info)
      let listed = (expected[track] ?? []).sorted { ($0.startMs, $0.index) < ($1.startMs, $1.index) }
      guard found == listed else { throw PreparationError.sourceChanged }
    }
    guard !sources.isEmpty else { throw PreparationError.notEligible("no audio") }
    var proofs: [String: MeetingAudioFileIdentity] = [:]
    for name in names where MeetingSegmentNaming.isCleanedProof(name) {
      proofs[name] = try MeetingStore.audioFileIdentity(at: folder.appendingPathComponent(name))
    }
    return (sources, proofs)
  }
}
