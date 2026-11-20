import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3546: which Parakeet row Settings shows while Ultra arrives.
///
/// **What the user sees when this fails:** Settings shows the Ultra download as
/// if dictation were broken while v3 works, hides the Resume of a download the
/// user paused, offers no way to retry a model the app stopped loading, or
/// sends Cancel/Resume to the wrong download. Expected English is typed from
/// the shipped strings, not read from the code under test.
@MainActor
@Suite("Parakeet upgrade Settings row (#3546)", .tags(.productOutcome))
struct ParakeetUpgradeSettingsRowTests {
  typealias View = SpeechEngineSettingsView

  static func row(
    retry: Bool = false, background: Bool,
    upgrade: ParakeetUpgradeCoordinator.BackgroundUpgradeState = .idle,
    foreground: DeliveryState = .notReady
  ) -> View.ParakeetRow? {
    View.parakeetRow(
      needsExplicitRetry: retry, rowIsBackgroundUpgrade: background, background: upgrade,
      foreground: foreground)
  }

  @Test("while v3 serves, the background download shows with Cancel for the upgrade")
  func backgroundDownloading() throws {
    let row = try #require(
      Self.row(
        background: true,
        upgrade: .downloading(fraction: 0.1, bytesWritten: 63_231_450, totalBytes: 632_314_500)))
    #expect(row.title == "Downloading speech model...")
    #expect(row.detail == "60 MB of 603 MB")
    #expect(row.showsCancel)
    #expect(row.action == nil)
    #expect(row.owner == .backgroundUpgrade)
    let status = SpeechEngineStatus.parakeet(
      installed: true, removing: false, leftovers: false, row: row)
    #expect(status.operation == .working(
      title: "Downloading speech model...", detail: "60 MB of 603 MB",
      fraction: 0.1, cancel: .parakeetUpgrade))
    #expect(status.showsInstallLine)
  }

  @Test("a declined upgrade shows Resume for the upgrade, also after relaunch")
  func backgroundDeclined() throws {
    let row = try #require(Self.row(background: true, upgrade: .declined))
    #expect(row.title == "Download paused. Resume anytime.")
    #expect(row.action == .fastModelResume)
    #expect(row.showsCancel == false)
    #expect(row.owner == .backgroundUpgrade)
  }

  @Test(
    "idle, deferred and failed background states stay silent while v3 serves",
    arguments: [
      ParakeetUpgradeCoordinator.BackgroundUpgradeState.idle, .deferredDisk, .failed,
    ])
  func backgroundSilent(_ state: ParakeetUpgradeCoordinator.BackgroundUpgradeState) {
    #expect(Self.row(background: true, upgrade: state) == nil)
  }

  @Test("the serving model's own download states are unchanged and act in the foreground")
  func foregroundUnchanged() throws {
    let row = try #require(
      Self.row(
        background: false,
        foreground: .downloading(
          fractionCompleted: 0.5, bytesWritten: 316_157_250, totalBytes: 632_314_500)))
    #expect(row.title == "Downloading speech model...")
    #expect(row.detail == "301 MB of 603 MB")
    #expect(row.owner == .foreground)
    let status = SpeechEngineStatus.parakeet(
      installed: false, removing: false, leftovers: true, row: row)
    #expect(status.operation == .working(
      title: "Downloading speech model...", detail: "301 MB of 603 MB",
      fraction: 0.5, cancel: .parakeetForeground))
    #expect(status.showsInstallLine == false)
    #expect(status.offersLeftoverRemoval == false)
    #expect(Self.row(background: false, foreground: .admitted) == nil)
    let paused = try #require(Self.row(background: false, foreground: .cancelled(resumable: true)))
    #expect(paused.action == .fastModelResume)
    #expect(paused.owner == .foreground)
  }

  @Test("after the policy stopped loading, Settings offers the explicit Retry first")
  func explicitRetry() throws {
    let row = try #require(
      Self.row(
        retry: true, background: true,
        upgrade: .downloading(fraction: 0.1, bytesWritten: 1, totalBytes: 2)))
    #expect(row.title == "Speech model couldn't load.")
    #expect(row.action == .fastModelTryAgain)
    #expect(row.showsCancel == false)
    #expect(row.owner == .retry)
  }
}
