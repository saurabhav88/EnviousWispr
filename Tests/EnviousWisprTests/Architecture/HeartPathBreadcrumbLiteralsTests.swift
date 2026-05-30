import Foundation
import Testing

/// PR8 of #763 — locks the heart-path Sentry breadcrumb / error / extras
/// string literals at unit-test layer, replacing the manual MCP post-merge
/// check. Reads the three router source files, asserts every known literal
/// still appears at least once. Fails the build locally if a refactor renames
/// or removes one.
///
/// AppLogger heart-path log prefixes are per-router (`[AudioEventRouter]` /
/// `[ASREventRouter]` / `[WedgeRecoveryRouter]`) per founder decision Q4
/// 2026-05-19. The per-router prefixes are asserted present here. A regression
/// that re-merges the prefixes is caught by the epic #763 freeze test, which
/// scans all of `Sources/` for the deleted root-state type's name.
@Suite struct HeartPathBreadcrumbLiteralsTests {
  private static let routerSourcePaths = [
    "Sources/EnviousWisprAppKit/App/DictationRuntime/AudioEventRouter.swift",
    "Sources/EnviousWisprAppKit/App/DictationRuntime/ASREventRouter.swift",
    "Sources/EnviousWisprAppKit/App/DictationRuntime/WedgeRecoveryRouter.swift",
  ]

  /// Literal strings that MUST appear at least once in the union of the
  /// router source files. These are the Sentry breadcrumb messages,
  /// error-type spellings, category strings, and extras-dict keys consumed
  /// by Sentry triage queries. Drift here breaks PostHog/Sentry dashboards.
  private static let requiredLiterals: [String] = [
    "\"Audio XPC interrupted\"",
    "\"Audio route changed\"",
    ".audioXPCInterrupted",
    ".xpcServiceError",
    "\"xpc.handler\"",
    "\"xpc.was_capturing\"",
    "\"xpc.kind\"",
    "\"capture_session_id\"",
    "\"capture.route\"",
    "\"audio.recording_duration_ms\"",
    "\"parakeet_state\"",
    "\"whisperkit_state\"",
    "\"audio_route\"",
    "[AudioEventRouter] Audio onEngineInterrupted",
    "[ASREventRouter] ASR onServiceInterrupted",
  ]

  @Test func requiredLiteralsPresent() throws {
    let union = try Self.routerSourcePaths
      .map { try String(contentsOf: RepoRoot.sourceURL($0), encoding: .utf8) }
      .joined(separator: "\n")
    var missing: [String] = []
    for literal in Self.requiredLiterals {
      if !union.contains(literal) {
        missing.append(literal)
      }
    }
    #expect(
      missing.isEmpty,
      """
      Heart-path breadcrumb literals missing from router source files: \
      \(missing). These strings are consumed by Sentry triage queries and \
      PostHog dashboards; renaming them silently breaks observability. \
      If the rename is intentional, update both this test and the \
      downstream consumer dashboards in the same PR.
      """)
  }
}
