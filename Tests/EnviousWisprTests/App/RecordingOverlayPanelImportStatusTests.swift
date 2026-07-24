import EnviousWisprPipeline
import Testing

@testable import EnviousWisprAppKit

/// Pins the bulk-import-status pill's Heart & Limbs state machine (#1701
/// Phase 3 review findings, round 1 and round 3): a fast enrichment run must
/// let "Finished" replace this feature's own still-pending "Importing", but
/// neither call may ever interrupt a genuine recording or processing panel.
/// `RecordingOverlayPanel` is otherwise real-NSPanel/window-server UI code
/// with no existing test file (the established runtime-only exemption); this
/// narrow state-machine logic — ownership, generation-stamping, guard
/// branching — is deterministically testable without rendering.
@MainActor
@Suite("RecordingOverlayPanel — bulk-import status pill (#1701 Phase 3)")
struct RecordingOverlayPanelImportStatusTests {

  @Test("a still-pending Importing pill is replaced by Finished, not dropped")
  func pendingImportingReplacedByFinished() {
    let overlay = RecordingOverlayPanel()
    defer { overlay.hide() }

    // No `await`/suspension between these two calls — the first main-queue
    // work item cannot run during this synchronous MainActor stretch, so
    // this reproduces the exact race a fast (or unavailable-model) drain
    // hits: "Finished" arriving before "Importing" has ever been rendered.
    overlay.showImportStatus(message: "Importing your words now.")
    overlay.showImportStatus(message: "Finished importing your words.")

    #expect(overlay.importStatusMessageForTesting == "Finished importing your words.")
  }

  @Test("a pending recording panel refuses import status entirely")
  func pendingRecordingRefusesImportStatus() {
    let overlay = RecordingOverlayPanel()
    defer { overlay.hide() }

    overlay.show(intent: .recording(audioLevel: 0))
    overlay.showImportStatus(message: "Finished importing your words.")

    #expect(overlay.currentIntent == .recording(audioLevel: 0))
    #expect(
      overlay.importStatusMessageForTesting == nil,
      "a limb must never claim ownership of a slot a genuine recording panel holds")
  }

  @Test("recording superseding a pending import status leaves no stale ownership")
  func recordingSupersedesPendingImportStatus() {
    let overlay = RecordingOverlayPanel()
    defer { overlay.hide() }

    overlay.showImportStatus(message: "Importing your words now.")
    overlay.show(intent: .recording(audioLevel: 0))
    overlay.showImportStatus(message: "Finished importing your words.")

    #expect(overlay.currentIntent == .recording(audioLevel: 0))
    #expect(
      overlay.importStatusMessageForTesting == nil,
      "the stale import token must lose all ownership once recording superseded it")
  }
}
