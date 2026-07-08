import Foundation
import Testing

@testable import EnviousWisprAudio

// #1377 slice 2a — freezes the `AudioInputSource` contract every capture engine
// must satisfy, so a new candidate conformer (slices 2b/2c: HAL, VoiceProcessingIO)
// cannot silently ship a heart-path regression. Protocol CONFORMANCE is already
// compiler-enforced; this locks the hardware-free behavioral invariants a stored
// property can't express:
//   - a fresh conformer has NOT started a session (`captureGeneration == 0`),
//   - it is not capturing,
//   - it exposes a NON-EMPTY, UNIQUE `captureSourceType` tag (catches a
//     copy-paste that reuses a sibling's backend tag),
//   - the watchdog callback is wired (settable) — the signal whose absence turns
//     a zombie zero-buffer capture silent.
//
// The RUNTIME wiring the freeze cannot reach without hardware (that
// `captureGeneration` actually increments in `startCapture`, that the watchdog
// truly fires and cancels on `stop()`/`deactivateCapture()`) is exercised by the
// bake-off Live UAT (`Tests/RuntimeUAT/`) per the plan §11 — named honestly, not
// faked with a mocked engine.
@MainActor
@Suite("AudioInputSource conformance freeze — #1377")
struct AudioInputSourceConformanceFreezeTests {

  /// Every shipped/candidate conformer. Slices 2b/2c append their new sources
  /// here; the parametric tests then cover them automatically.
  enum ConformerKind: String, CaseIterable, Sendable {
    case audioEngine
    case captureSession
    /// Candidate D (#1377 slice 2b, reinstated 2026-07-08).
    case halDeviceInput
  }

  private func make(_ kind: ConformerKind) -> any AudioInputSource {
    switch kind {
    case .audioEngine: return AVAudioEngineSource()
    case .captureSession: return AVCaptureSessionSource()
    case .halDeviceInput: return HALDeviceInputSource()
    }
  }

  /// The backend tag each conformer must expose. Frozen here so a tag rename or
  /// collision is caught at test time, not in production Sentry extras.
  private func expectedTag(_ kind: ConformerKind) -> String {
    switch kind {
    case .audioEngine: return "av_audio_engine"
    case .captureSession: return "av_capture_session"
    case .halDeviceInput: return "hal_device_input"
    }
  }

  @Test("fresh conformer has started no session", arguments: ConformerKind.allCases)
  func freshConformerHasNoSession(_ kind: ConformerKind) {
    let source = make(kind)
    #expect(source.captureGeneration == 0)
    #expect(source.isCapturing == false)
  }

  @Test("conformer exposes its frozen backend tag", arguments: ConformerKind.allCases)
  func conformerExposesFrozenTag(_ kind: ConformerKind) {
    let source = make(kind)
    #expect(source.captureSourceType == expectedTag(kind))
    #expect(!source.captureSourceType.isEmpty)
  }

  @Test("stall watchdog callback is settable (heart-path liveness signal)")
  func stallWatchdogWired() {
    for kind in ConformerKind.allCases {
      let source = make(kind)
      // Assigning proves the property is a real, wired seam — the freeze guards
      // against a conformer that drops the watchdog and goes silently zombie.
      source.onCaptureStalled = { _ in }
      #expect(source.onCaptureStalled != nil)
    }
  }

  @Test("every conformer's backend tag is unique")
  func backendTagsAreUnique() {
    let tags = ConformerKind.allCases.map { make($0).captureSourceType }
    #expect(Set(tags).count == tags.count)
  }
}

// #1377 slice 2a — locks candidate A's additive device-target contract: the
// default is nil (built-in, byte-identical to today's `.automatic` path), and a
// pinned UID is reflected. WHICH device actually binds is hardware-dependent and
// proven by the bake-off Live UAT, not here.
@MainActor
@Suite("AVCaptureSessionSource device target — #1377")
struct AVCaptureSessionSourceDeviceTargetTests {

  @Test("default target is nil (automatic path leaves it built-in)")
  func defaultTargetIsNil() {
    let source = AVCaptureSessionSource()
    #expect(source.targetDeviceUID == nil)
  }

  @Test("a pinned target UID is reflected")
  func pinnedTargetReflected() {
    let source = AVCaptureSessionSource()
    source.targetDeviceUID = "BC-87-FA-9C-7E-71:input"
    #expect(source.targetDeviceUID == "BC-87-FA-9C-7E-71:input")
  }
}

// #1377 slice 2b (reinstated 2026-07-08) — locks candidate D's identical
// additive device-target contract to candidate A's: default nil (built-in),
// pinned UID reflected. WHICH device actually binds is hardware-dependent and
// proven by the bake-off Live UAT (the founder's Bose headset spike), not here.
@MainActor
@Suite("HALDeviceInputSource device target — #1377")
struct HALDeviceInputSourceDeviceTargetTests {

  @Test("default target is nil (automatic path leaves it built-in)")
  func defaultTargetIsNil() {
    let source = HALDeviceInputSource()
    #expect(source.targetDeviceUID == nil)
  }

  @Test("a pinned target UID is reflected")
  func pinnedTargetReflected() {
    let source = HALDeviceInputSource()
    source.targetDeviceUID = "BC-87-FA-9C-7E-71:input"
    #expect(source.targetDeviceUID == "BC-87-FA-9C-7E-71:input")
  }
}
