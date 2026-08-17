import Testing

@testable import EnviousWisprLLM

/// The install-state vocabulary's own decisions (#2109). These are the two
/// questions every renderer and action site asks, pulled onto the enum so they
/// are answered once and exhaustively rather than re-derived per call site.
@Suite struct EGOneInstallStateTests {

  /// The dead-button guard. `paused` and `updatePaused` are the Resume and
  /// Finish-upgrade doors; if either stopped accepting a start, the row would
  /// render its button and silently ignore the press — invisible at compile
  /// time and indistinguishable, to a user, from the app being broken.
  @Test func pausedStatesAcceptADownloadStart() {
    #expect(EGOneInstallState.paused.acceptsDownloadStart)
    #expect(EGOneInstallState.updatePaused(resumable: true, targetVersion: "1.1").acceptsDownloadStart)
    #expect(EGOneInstallState.updatePaused(resumable: false, targetVersion: "1.1").acceptsDownloadStart)
  }

  /// Two-way control: the in-flight and finished states must REFUSE, or the
  /// property is just "true" wearing a name and proves nothing above.
  @Test func inFlightAndInstalledStatesRefuseADownloadStart() {
    #expect(EGOneInstallState.downloading(fractionCompleted: 0.5).acceptsDownloadStart == false)
    #expect(EGOneInstallState.verifying.acceptsDownloadStart == false)
    #expect(EGOneInstallState.installed(version: "1.1").acceptsDownloadStart == false)
  }

}
