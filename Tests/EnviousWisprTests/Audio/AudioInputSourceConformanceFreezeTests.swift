import CoreAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

// #1377 slice 2a — freezes the `AudioInputSource` contract the sole capture
// backend must satisfy, so a change cannot silently ship a heart-path
// regression. Protocol CONFORMANCE is already compiler-enforced; this locks the
// hardware-free behavioral invariants a stored property can't express:
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

  /// Every shipped conformer. A future backend appends its source here; the
  /// parametric tests then cover it automatically.
  enum ConformerKind: String, CaseIterable, Sendable {
    case halDeviceInput
  }

  private func make(_ kind: ConformerKind) -> any AudioInputSource {
    switch kind {
    case .halDeviceInput: return HALDeviceInputSource()
    }
  }

  /// The backend tag each conformer must expose. Frozen here so a tag rename or
  /// collision is caught at test time, not in production Sentry extras.
  private func expectedTag(_ kind: ConformerKind) -> String {
    switch kind {
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

// #1377 slice 2b / #1378 — locks candidate D's additive device-target contract:
// default nil follows the live system-default input, and a pinned UID is
// reflected. WHICH device actually binds is hardware-dependent and proven by
// Live UAT, not here.
@MainActor
@Suite("HALDeviceInputSource device target — #1377")
struct HALDeviceInputSourceDeviceTargetTests {

  @Test("default target is nil (automatic path follows system default)")
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

  @Test("nil target resolves to current system default input")
  func nilTargetResolvesToDefaultInput() {
    let source = HALDeviceInputSource()
    source.defaultInputDeviceIDProvider = { 42 }
    #expect(source.resolvedDeviceIDForTesting() == 42)
  }

  @Test("unresolvable target falls back to current system default input")
  func missingTargetFallsBackToDefaultInput() {
    let source = HALDeviceInputSource()
    source.targetDeviceUID = "gone"
    source.resolveDeviceIDForUID = { _ in nil }
    source.defaultInputDeviceIDProvider = { 42 }
    #expect(source.resolvedDeviceIDForTesting() == 42)
  }

  @Test("resolvable target wins over system default input")
  func resolvedTargetWins() {
    let source = HALDeviceInputSource()
    source.targetDeviceUID = "present"
    source.resolveDeviceIDForUID = { uid in uid == "present" ? 99 : nil }
    source.defaultInputDeviceIDProvider = { 42 }
    #expect(source.resolvedDeviceIDForTesting() == 99)
  }

  @Test("warm automatic source is reusable while bound to current system default")
  func automaticReuseMatchesCurrentDefault() {
    let source = HALDeviceInputSource()
    source.defaultInputDeviceIDProvider = { 42 }
    source.setBoundDeviceIDForTesting(42)

    #expect(source.boundDeviceMatchesResolvedTargetForReuse())
  }

  @Test("warm automatic source rejects stale system default")
  func automaticReuseRejectsStaleDefault() {
    let source = HALDeviceInputSource()
    var currentDefault: AudioDeviceID = 42
    source.defaultInputDeviceIDProvider = { currentDefault }
    source.setBoundDeviceIDForTesting(42)

    currentDefault = 43

    #expect(!source.boundDeviceMatchesResolvedTargetForReuse())
  }

  @Test("warm explicit source follows fallback default when target is missing")
  func explicitMissingTargetReuseTracksFallbackDefault() {
    let source = HALDeviceInputSource()
    source.targetDeviceUID = "missing"
    source.resolveDeviceIDForUID = { _ in nil }
    var currentDefault: AudioDeviceID = 42
    source.defaultInputDeviceIDProvider = { currentDefault }
    source.setBoundDeviceIDForTesting(42)

    #expect(source.boundDeviceMatchesResolvedTargetForReuse())

    currentDefault = 43

    #expect(!source.boundDeviceMatchesResolvedTargetForReuse())
  }
}
