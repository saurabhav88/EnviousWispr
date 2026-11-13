import EnviousWisprCore
import Foundation

/// #3147 PR4A (D5): sources a summary item may link to. Only the validator in this file can make
/// one (the initializer is file-private), so no view can show a link the validator did not
/// accept. Lane C owns this file after the contract chunk and writes the validator here.
struct ValidatedMeetingSummarySource: Equatable, Sendable {
  let itemID: UUID
  let sources: [MeetingSummarySource]

  fileprivate init(itemID: UUID, sources: [MeetingSummarySource]) {
    self.itemID = itemID
    self.sources = sources
  }
}
