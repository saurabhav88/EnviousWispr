import Foundation
import Testing

/// PR8 of #763 — locks the heart-path Sentry breadcrumb / error / extras
/// string literals at unit-test layer, replacing the manual MCP post-merge
/// check. Reads the three router source files, asserts every known literal
/// still appears at least once. Fails the build locally if a refactor renames
/// or removes one.
///
/// AppLogger heart-path log prefixes are per-router (`[AudioEventRouter]` /
/// `[WedgeRecoveryRouter]`) per founder decision Q4 2026-05-19. The
/// per-router prefixes are asserted present here. A regression that
/// re-merges the prefixes is caught by the epic #763 freeze test, which
/// scans all of `Sources/` for the deleted root-state type's name.
/// (#1908: `ASREventRouter.swift` itself, and its `[ASREventRouter]` prefix,
/// were deleted along with the XPC path it bridged — see the two NOTEs below
/// for the same pattern on earlier deletions.)
@Suite struct HeartPathBreadcrumbLiteralsTests {
  private static let routerSourcePaths = [
    "Sources/EnviousWisprAppKit/App/DictationRuntime/AudioEventRouter.swift",
    "Sources/EnviousWisprAppKit/App/DictationRuntime/WedgeRecoveryRouter.swift",
  ]

  /// Literal strings that MUST appear at least once in the union of the
  /// router source files. These are the Sentry breadcrumb messages,
  /// error-type spellings, category strings, and extras-dict keys consumed
  /// by Sentry triage queries. Drift here breaks PostHog/Sentry dashboards.
  // NOTE (#1533): the `"Audio route changed"` breadcrumb + its `"audio_route"`
  // extra were removed with the `AVAudioEngineConfigurationChange` observer — its
  // notification could not fire after the engine backend was deleted (and in
  // practice never fired in production, per the 2026-05-02 finding). Route-change
  // evidence survives via `AudioSystemEventReporter`'s CoreAudio listeners, not
  // this router breadcrumb.
  // NOTE (#1543): the boundary-failure breadcrumb literals (the "Audio XPC
  // interrupted" message, the interrupted-error case, the `xpc.*` extras,
  // `capture.route`, `audio.recording_duration_ms`) were removed with the
  // audio-capture boundary itself — those breadcrumbs can no longer be produced
  // in-process. The engine-interruption breadcrumb survives, now spelled "Audio
  // engine interrupted."
  // NOTE (#1908): the `[ASREventRouter] ASR onServiceInterrupted` literal was
  // removed with `ASREventRouter.swift` itself — the last XPC helper
  // collapsed in-process, so `asrManager.onServiceInterrupted` (the only
  // thing that router ever wired) has no live producer anywhere.
  private static let requiredLiterals: [String] = [
    "\"Audio engine interrupted\"",
    "\"parakeet_state\"",
    "\"whisperkit_state\"",
    "[AudioEventRouter] Audio onEngineInterrupted",
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
