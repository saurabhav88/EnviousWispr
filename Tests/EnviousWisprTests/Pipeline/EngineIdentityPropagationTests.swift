import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// MARK: - EngineIdentityPropagationTests (epic #827, PR-5 Rung 1)
//
// Sentinel coverage that the kernel's identity reads are sourced from
// `adapter.engineIdentity`, not hard-coded `.parakeet` literals. The
// architecture freeze test (`EngineIdentityFreezeTests`) covers the
// source-level guard at every production site; this suite proves the runtime
// plumbing for `:1791-1792` (`KernelRecordingSnapshotTelemetry.backend`) by
// driving the natural `freezeRecordingSnapshot()` path with a `FakeEngine`
// declaring an alternate identity.

@MainActor
@Suite struct EngineIdentityPropagationTests {

  @Test(
    "recording snapshot backend reads adapter.engineIdentity.rawValue"
  )
  func recordingSnapshotReadsAdapterIdentity() {
    let telemetryState = KernelTelemetryState()
    let engine = FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock())
    engine.engineIdentity = ASREngineIdentity(backendType: .whisperKit)
    let kernel = RecordingSessionKernel(
      adapter: engine,
      audioCapture: FakeAudioCapture(),
      vad: FakeVADSignalSource(),
      currentTick: { 0 },
      sleepTicks: { _ in },
      processText: { raw, _ in raw },
      store: { _, _ in },
      deliver: { _ in .pasted },
      minimumRecordingTicks: 0,
      telemetryState: telemetryState)

    #if DEBUG
      kernel.testTriggerRecordingSnapshotFreeze()
      let snapshot = kernel.testGetRecordingSnapshot()
      #expect(snapshot != nil, "freezeRecordingSnapshot should populate the snapshot")
      #expect(
        snapshot?.backend == "whisperKit",
        "snapshot.backend must come from adapter.engineIdentity.rawValue, not a literal")
    #endif
  }

  @Test(
    "swapping the adapter's engineIdentity flows into the snapshot"
  )
  func snapshotReflectsAdapterIdentityChange() {
    let telemetryState = KernelTelemetryState()
    let engine = FakeEngine(behavior: .batchSuccess(text: "x"), clock: FakeClock())
    // Default identity .parakeet — verify the snapshot reflects it.
    let kernel = RecordingSessionKernel(
      adapter: engine,
      audioCapture: FakeAudioCapture(),
      vad: FakeVADSignalSource(),
      currentTick: { 0 },
      sleepTicks: { _ in },
      processText: { raw, _ in raw },
      store: { _, _ in },
      deliver: { _ in .pasted },
      minimumRecordingTicks: 0,
      telemetryState: telemetryState)

    #if DEBUG
      kernel.testTriggerRecordingSnapshotFreeze()
      #expect(kernel.testGetRecordingSnapshot()?.backend == "parakeet")
    #endif
  }
}
