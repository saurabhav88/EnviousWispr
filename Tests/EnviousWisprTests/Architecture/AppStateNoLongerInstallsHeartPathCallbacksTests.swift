import Foundation
import Testing

/// PR8 of #763 — locks the no-shim rule by asserting AppState no longer
/// installs heart-path event-routing closures. Fails the build if any of
/// the seven `audioCapture.on*` slots, `asrManager.onServiceInterrupted`, or
/// the `AVAudioEngineConfigurationChange` observer block reappears in
/// AppState. The closures now live in `AudioEventRouter`, `ASREventRouter`,
/// or `WedgeRecoveryRouter`.
@Suite struct AppStateNoLongerInstallsHeartPathCallbacksTests {
  private static let sourcePath =
    "Sources/EnviousWispr/App/AppState.swift"

  /// Assignment patterns that MUST NOT appear in AppState.swift post-PR8.
  private static let forbiddenAssignments: [String] = [
    "audioCapture.onEngineInterrupted =",
    "audioCapture.onXPCServiceError =",
    "audioCapture.onCaptureStalled =",
    "audioCapture.onXPCReplyFailed =",
    "audioCapture.onCaptureSessionInterruption =",
    "audioCapture.onVADAutoStop =",
    "asrManager.onServiceInterrupted =",
  ]

  /// The AVAudioEngineConfigurationChange observer needs a two-part guard:
  /// (1) any addObserver call inside AppState.swift, AND (2) any reference to
  /// .AVAudioEngineConfigurationChange. If BOTH appear in AppState, the
  /// observer has been reintroduced. Codex code-diff r1 [P3] flagged that a
  /// single-line pattern would miss the multiline shape the original AppState
  /// used (`addObserver(` on one line, `forName:` on the next).
  private static let observerInstallSentinels: [String] = [
    "NotificationCenter.default.addObserver",
    ".AVAudioEngineConfigurationChange",
  ]

  @Test func forbiddenAssignmentsAbsent() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    var present: [String] = []
    for pattern in Self.forbiddenAssignments {
      if source.contains(pattern) {
        present.append(pattern)
      }
    }
    #expect(
      present.isEmpty,
      """
      AppState still installs heart-path event-routing callbacks: \(present). \
      PR8 of #763 moved these to AudioEventRouter / ASREventRouter / \
      WedgeRecoveryRouter under DictationRuntime. The no-shim rule (epic \
      #763 Decision 4) prohibits AppState from re-installing them.
      """)
  }

  /// Locks the AVAudioEngineConfigurationChange observer move regardless of
  /// formatting. Fails if AppState contains BOTH an `addObserver` call AND a
  /// reference to the configuration-change notification name. Either signal
  /// alone is benign; the conjunction proves the observer is back.
  @Test func configChangeObserverNotReinstalled() throws {
    let source = try String(
      contentsOf: URL(fileURLWithPath: Self.sourcePath), encoding: .utf8)
    let hasAllSentinels = Self.observerInstallSentinels.allSatisfy {
      source.contains($0)
    }
    #expect(
      !hasAllSentinels,
      """
      AppState.swift contains both `NotificationCenter.default.addObserver` \
      and `.AVAudioEngineConfigurationChange` — the heart-path route-change \
      observer has been reinstalled. PR8 of #763 moved this to \
      AudioEventRouter.init. The no-shim rule (epic #763 Decision 4) \
      prohibits AppState from owning this observer.
      """)
  }
}
