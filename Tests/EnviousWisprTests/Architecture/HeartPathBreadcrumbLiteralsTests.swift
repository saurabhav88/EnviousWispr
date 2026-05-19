import Foundation
import Testing

/// PR8 of #763 — locks the heart-path Sentry breadcrumb / error / extras
/// string literals at unit-test layer, replacing the manual MCP post-merge
/// check. Reads the three router source files plus AppState, asserts every
/// known literal still appears at least once. Fails the build locally if a
/// refactor renames or removes one.
///
/// AppLogger log prefixes flipped 2026-05-19 from `[AppState]` →
/// `[AudioEventRouter]` / `[ASREventRouter]` / `[WedgeRecoveryRouter]` per
/// founder decision Q4. The new prefixes are asserted here; the old ones are
/// asserted ABSENT so a regression rename does not slip back in.
@Suite struct HeartPathBreadcrumbLiteralsTests {
  private static let routerSourcePaths = [
    "Sources/EnviousWispr/App/DictationRuntime/AudioEventRouter.swift",
    "Sources/EnviousWispr/App/DictationRuntime/ASREventRouter.swift",
    "Sources/EnviousWispr/App/DictationRuntime/WedgeRecoveryRouter.swift",
  ]
  private static let appStateSourcePath =
    "Sources/EnviousWispr/App/AppState.swift"

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

  /// Old log prefixes that MUST NOT reappear in router source files. Locked
  /// 2026-05-19 to prevent a refactor from quietly restoring `[AppState]`
  /// prefixes (which would re-merge log clusters in Sentry and undo the
  /// founder's Q4 decision).
  private static let forbiddenInRouters: [String] = [
    "[AppState] Audio onEngineInterrupted",
    "[AppState] ASR onServiceInterrupted",
  ]

  @Test func requiredLiteralsPresent() throws {
    let union = try Self.routerSourcePaths
      .map { try String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8) }
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

  @Test func forbiddenLogPrefixesAbsent() throws {
    let union = try Self.routerSourcePaths
      .map { try String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8) }
      .joined(separator: "\n")
    var present: [String] = []
    for literal in Self.forbiddenInRouters {
      if union.contains(literal) {
        present.append(literal)
      }
    }
    #expect(
      present.isEmpty,
      """
      Forbidden `[AppState] …` log prefixes detected in router source files: \
      \(present). Per founder Q4 decision 2026-05-19, routers emit \
      per-router prefixes. Restoring `[AppState]` prefixes would re-merge \
      Sentry clusters and undo the rename.
      """)
  }

  @Test func appStateNoLongerEmitsHeartPathLogPrefixes() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.appStateSourcePath), encoding: .utf8)
    let forbidden = [
      "[AppState] Audio onEngineInterrupted",
      "[AppState] ASR onServiceInterrupted",
    ]
    var present: [String] = []
    for literal in forbidden {
      if source.contains(literal) {
        present.append(literal)
      }
    }
    #expect(
      present.isEmpty,
      """
      AppState still emits heart-path log prefixes: \(present). \
      PR8 moved these to the routers; their presence in AppState means a \
      regression re-added the routing logic to the old home.
      """)
  }
}
