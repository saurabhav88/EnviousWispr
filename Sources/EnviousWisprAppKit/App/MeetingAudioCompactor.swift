import EnviousWisprCore
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
