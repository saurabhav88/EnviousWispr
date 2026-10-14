import Foundation
import Testing

/// #1386 PR-2b; #3735. Freezes the ONE thing seven Codex rounds could not see.
///
/// The migration is reached only through closures (`SetupCoordinator` calls one once), and they
/// capture it weakly. A local `let` in the setup function is therefore not enough: it dies when
/// the function returns, the weak reference goes nil, and `runLaunch()` silently does nothing —
/// forever, on every launch, for every user.
///
/// The withdrawn move/migrate design had this same defect and shipped it through seven review
/// rounds, because a reference-lifetime bug is invisible to anything that reads code: the call
/// site is present and correct, the coordinator is correct, and the tests pass. Only running
/// the real app finds it, and only if you check the disk rather than the log.
@Suite(.tags(.driftGuard)) struct WhisperModelMigrationOwnershipTests {

  private var bootstrapper: String {
    get throws {
      let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift")
      return try String(contentsOf: url, encoding: .utf8)
    }
  }

  @Test("the migration has a strong owner that outlives setup")
  func migrationIsStoredNotJustCaptured() throws {
    let source = try bootstrapper

    #expect(
      source.contains("let whisperMigration: WhisperModelMigration"),
      "the migration must be a STORED property, not a local binding")
    #expect(
      source.contains("self.whisperMigration = whisperMigration"),
      "the stored property must actually be assigned — declaring it is not owning it")
  }

  @Test("the migration is still invoked from the deferred, on-screen phase")
  func migrationRunsAfterTheAppIsOnScreen() throws {
    let source = try bootstrapper

    // Its deletions and any download belong after launch work, never inside construction.
    #expect(source.contains("runDocumentsMigration: { [weak whisperMigration] in"))
    #expect(source.contains("await whisperMigration?.runLaunch()"))
  }
}
