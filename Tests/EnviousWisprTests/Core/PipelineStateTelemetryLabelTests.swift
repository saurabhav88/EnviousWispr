import Foundation
import Testing

@testable import EnviousWisprCore

/// Telemetry Bible Phase 1 (#1170): `PipelineState.telemetryLabel` is the stable
/// lowercase `app_phase` value carried on `telemetry.flush_requested`. The mapping
/// is a total switch — every case has an explicit label, and `.error` collapses
/// to "error" regardless of its associated message.
@Suite("PipelineState telemetry label")
struct PipelineStateTelemetryLabelTests {

  @Test("every PipelineState case maps to its stable telemetry label")
  func everyCaseMapsToStableLabel() {
    #expect(PipelineState.idle.telemetryLabel == "idle")
    #expect(PipelineState.loadingModel.telemetryLabel == "loading_model")
    #expect(PipelineState.recording.telemetryLabel == "recording")
    #expect(PipelineState.transcribing.telemetryLabel == "transcribing")
    #expect(PipelineState.polishing.telemetryLabel == "polishing")
    #expect(PipelineState.complete.telemetryLabel == "complete")
    #expect(PipelineState.error(.modelWedged).telemetryLabel == "error")
  }

  @Test("error label is independent of the associated message")
  func errorLabelIgnoresMessage() {
    #expect(PipelineState.error(.asrFailed).telemetryLabel == "error")
    #expect(PipelineState.error(.deviceRemoved).telemetryLabel == "error")
  }
}
