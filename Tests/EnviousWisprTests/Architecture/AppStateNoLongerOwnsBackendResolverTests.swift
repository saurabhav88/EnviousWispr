import Foundation
import Testing

/// PR9 of #763 — same-PR ship gate for the PR8 deferred-cleanup obligation.
///
/// PR8 promoted seven AppState symbols from `private` to `internal` so
/// `DictationRuntime`'s router-injected resolver closures could read them
/// via `[weak appState]` captures. PR8 explicitly deferred the move (would
/// have broken its 18→18 collaborator-count cascade promise). PR9 absorbs
/// all seven into `DictationLifecycleCoordinator` and rewires the routers'
/// resolver closures to capture `[weak dictationLifecycleCoordinator]`
/// instead.
///
/// This test reads `Sources/EnviousWispr/App/AppState.swift` and asserts
/// NONE of the seven identifiers appear anywhere in the file — code or
/// comments. The intentionally-strict check fails the build if a stray
/// PR8 leftover survives.
///
/// PR9 plan: `docs/feature-requests/issue-775-2026-05-19-pr9-lifecycle-coordinator.md`.
@Suite struct AppStateNoLongerOwnsBackendResolverTests {

  @Test func appStateDoesNotContainAnyPR8DeferredSymbol() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: "Sources/EnviousWispr/App/AppState.swift"),
      encoding: .utf8
    )

    // Exact identifier strings — must NOT appear anywhere in AppState.swift.
    // Includes the bare enum name + the three resolver-state vars + the three
    // resolver helper methods. The enum-name freeze (see issue #775 body and
    // parent migration plan §PR9) requires `LastCapturingBackend` to be
    // preserved byte-for-byte inside the new home, so we look for that exact
    // spelling here.
    let bannedIdentifiers: [String] = [
      "LastCapturingBackend",
      "lastCapturingBackend",
      "prevParakeetActive",
      "prevWhisperKitActive",
      "activeCaptureBackend",
      "isCurrentSession",
      "activeTelemetryTarget",
    ]

    var found: [String] = []
    for identifier in bannedIdentifiers where source.contains(identifier) {
      found.append(identifier)
    }

    #expect(
      found.isEmpty,
      """
      AppState.swift still contains PR8 deferred-cleanup identifiers: \
      \(found.joined(separator: ", ")). PR9 must remove all seven from \
      AppState in the same PR (no shim, no deferral). The owning home is \
      `DictationLifecycleCoordinator` under DictationRuntime; the routers' \
      injected resolver closures capture the new home. See PR9 plan \
      `docs/feature-requests/issue-775-2026-05-19-pr9-lifecycle-coordinator.md`.
      """
    )
  }
}
