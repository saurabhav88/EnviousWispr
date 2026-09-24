import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3142: the update notification body a user reads, built by the same
/// `UpdateNotificationPresenter.body(displayVersion:)` that `deliver` posts.
/// Oracle: the literal sentence shipped before the catalog existed.
@Suite("Update notification copy", .tags(.productOutcome))
@MainActor
struct UpdateNotificationCopyTests {
  @Test("Body names the version and reads exactly as before the catalog")
  func bodyFormatsVersion() {
    #expect(
      UpdateNotificationPresenter.body(displayVersion: "2.6.0")
        == "Version 2.6.0 is ready. Click to install."
    )
  }
}
