import Foundation
import Testing
import UserNotifications

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

  /// The English case above would also pass if the builder ignored the catalog and returned its
  /// `defaultValue`; a fixture table with a DIFFERENT value proves the keyed lookup wins.
  @Test("Body is looked up by key, and the table value wins over the English default")
  func bodyComesFromTheTable() throws {
    let lproj = FileManager.default.temporaryDirectory
      .appendingPathComponent("notification-copy-\(UUID().uuidString)/en.lproj")
    try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
    let table = ["notification.update.ready.body": "Fixture %@ ready"]
    try PropertyListSerialization.data(fromPropertyList: table, format: .xml, options: 0)
      .write(to: lproj.appendingPathComponent("Localizable.strings"))
    let fixture = try #require(Bundle(path: lproj.path))
    #expect(
      UpdateNotificationPresenter.body(displayVersion: "2.6.0", bundle: fixture)
        == "Fixture 2.6.0 ready")
  }

  /// The category registers this stable identifier; response handling routes both body and action taps.
  @Test("The Install button keeps its English title and its identifier")
  func installAction() {
    let action = UpdateNotificationPresenter.makeInstallAction()
    #expect(action.title == "Install")
    #expect(action.identifier == "com.enviouswispr.updateReady.install")
    #expect(action.options.contains(.foreground))
  }
}
