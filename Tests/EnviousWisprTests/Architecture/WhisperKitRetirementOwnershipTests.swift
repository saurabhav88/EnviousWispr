import Foundation
import Testing

/// #1386 PR-2b. Freezes the ONE thing seven Codex rounds could not see.
///
/// The retirement coordinator is reached only through a closure `SetupCoordinator` calls once,
/// and that closure captures it weakly. A local `let` in the setup function is therefore not
/// enough: it dies when the function returns, the weak reference goes nil, and `runLaunch()`
/// silently does nothing — forever, on every launch, for every user.
///
/// The withdrawn move/migrate design had this same defect and shipped it through seven review
/// rounds, because a reference-lifetime bug is invisible to anything that reads code: the call
/// site is present and correct, the coordinator is correct, and the tests pass. Only running
/// the real app finds it, and only if you check the disk rather than the log.
@Suite struct WhisperKitRetirementOwnershipTests {

  private var bootstrapper: String {
    get throws {
      let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift")
      return try String(contentsOf: url, encoding: .utf8)
    }
  }

  @Test("the retirement coordinator has a strong owner that outlives setup")
  func retirementCoordinatorIsStoredNotJustCaptured() throws {
    let source = try bootstrapper

    #expect(
      source.contains("let whisperKitRetirement: WhisperKitLegacyUpgradeCoordinator?"),
      "the coordinator must be a STORED property, not a local binding")
    #expect(
      source.contains("self.whisperKitRetirement = whisperKitRetirement"),
      "the stored property must actually be assigned — declaring it is not owning it")
  }

  @Test("retirement is still invoked from the deferred, on-screen phase")
  func retirementRunsAfterTheAppIsOnScreen() throws {
    let source = try bootstrapper

    // Retirement reads ~/Documents, which can raise the Files-and-Folders prompt. Calling it
    // during construction throws a permission dialog at a user who has not seen the app yet —
    // an easy accidental "Don't Allow", which leaves their copy unreadable and retirement
    // declined. It belongs in the deferred phase, and this asserts it stays there.
    #expect(source.contains("runDocumentsMigration: { [weak whisperKitRetirement] in"))
    #expect(source.contains("await whisperKitRetirement?.runLaunch()"))
  }
}
