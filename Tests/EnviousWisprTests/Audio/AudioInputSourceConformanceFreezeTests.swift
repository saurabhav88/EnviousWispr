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

  // MARK: - #1714: warm compatibility, delegated to InputDeviceResolver
  //
  // The three PURE resolution behaviours that used to live here — nil target
  // resolves to the default, a missing pinned target falls back to the default,
  // a present pinned target wins — moved to `InputDeviceResolverTests` when
  // `resolvedDeviceIDForTesting()` was deleted. They are behaviours of the
  // resolver now, not of this file. The three WARM behaviours stay here, because
  // they are about what THIS source does with its committed bind, and are
  // rewritten against the injected resolver plus a complete four-field bind.

  /// A committed bind, stated in full. A partial setter used to sit beside the
  /// complete one and moved only the numeric id; #1714 deleted it, because a
  /// partial value can no longer express a four-field #1844 bind.
  private func committedBind(
    _ deviceID: AudioDeviceID, source: String = "system_default"
  ) -> BoundInputDevice {
    BoundInputDevice(
      deviceID: deviceID, deviceUID: "uid-\(deviceID)", transportLabel: "built_in",
      resolutionSource: source)
  }

  @Test("warm automatic source is reusable while bound to current system default")
  func automaticReuseMatchesCurrentDefault() {
    let source = HALDeviceInputSource()
    source.inputDeviceResolver = InputDeviceResolver(
      defaultInputDeviceID: { 42 },
      inputDeviceSnapshot: { Issue.record("Auto must not enumerate"); return .complete([]) }
    )
    source.setBoundInputDeviceForTesting(committedBind(42))

    #expect(source.boundDeviceMatchesResolvedTargetForReuse())
  }

  @Test("warm automatic source rejects stale system default")
  func automaticReuseRejectsStaleDefault() {
    let source = HALDeviceInputSource()
    nonisolated(unsafe) var currentDefault: AudioDeviceID = 42
    source.inputDeviceResolver = InputDeviceResolver(
      defaultInputDeviceID: { currentDefault },
      inputDeviceSnapshot: { Issue.record("Auto must not enumerate"); return .complete([]) }
    )
    source.setBoundInputDeviceForTesting(committedBind(42))

    #expect(source.boundDeviceMatchesResolvedTargetForReuse())

    currentDefault = 43

    #expect(!source.boundDeviceMatchesResolvedTargetForReuse())
  }

  @Test("a source with no committed bind is never warm-compatible")
  func noBindIsNeverCompatible() {
    // Guards the delegation: the predicate now reads the whole bind, so an
    // absent one must refuse rather than pass a partial value to the resolver.
    let source = HALDeviceInputSource()
    source.inputDeviceResolver = InputDeviceResolver(
      defaultInputDeviceID: { 42 }, inputDeviceSnapshot: { .complete([]) })

    #expect(!source.boundDeviceMatchesResolvedTargetForReuse())
  }

  // MARK: - #1844: the warm-reuse decision
  //
  // Why this is unit-frozen rather than left to review: verified on real hardware
  // 2026-07-30, this decision runs on EVERY dictation, not just a second take.
  // `preWarm()` opens the unit cold, then the recording's own `prepare()` reuses
  // it — bt-route.log showed one "prepared with device 121" from pre-warm followed
  // by "Reusing warm HALDeviceInput source" for the take, with the same bound UID
  // on both. And a wrong answer here would be SILENT: capture keeps working from
  // the live unit, only the health-check identity would be wrong.
  //
  // `warmReuseBindForTesting` drives the decision with the "is a unit live" fact
  // supplied, so no `AudioUnit` is fabricated. WHICH device a cold open binds
  // remains hardware-dependent and stays Live UAT's job, as noted above.

  @Test("live unit + committed bind → reuse that complete bind (#1844 positive control)")
  func warmReuseReturnsCommittedBind() {
    let source = HALDeviceInputSource()
    let committed = BoundInputDevice(
      deviceID: 121,
      deviceUID: "BC-87-FA-9C-7E-71:input",
      transportLabel: "bluetooth",
      resolutionSource: "system_default"
    )
    source.setBoundInputDeviceForTesting(committed)

    let reused = source.warmReuseBindForTesting(hasLiveUnit: true)

    // WHOLE value, not just the id: a warm return that handed back the right
    // number with a stale UID would defeat the identity re-check the health
    // verdict depends on, and an id-only assertion would pass it.
    #expect(reused == committed, "the warm return must hand back the complete live bind")
  }

  @Test("no live unit → no reuse, so cold preparation runs (#1844 negative control)")
  func noLiveUnitRefusesReuse() {
    let source = HALDeviceInputSource()
    // A complete, stale bind is still NOT grounds for reuse without a live unit.
    source.setBoundInputDeviceForTesting(
      BoundInputDevice(
        deviceID: 121, deviceUID: "BC-87-FA-9C-7E-71:input", transportLabel: "bluetooth",
        resolutionSource: "system_default"))

    #expect(source.warmReuseBindForTesting(hasLiveUnit: false) == nil)
  }

  @Test("live unit with no bind → no reuse; repair, never a nil bind (#1844)")
  func liveUnitWithoutBindRefusesReuse() {
    let source = HALDeviceInputSource()
    // The broken-invariant state: a unit is live but no bind was committed.
    #expect(source.warmReuseBindForTesting(hasLiveUnit: true) == nil)
  }

  @Test("bind cleared by teardown → no reuse (#1844)")
  func clearedBindEndsReuse() {
    let source = HALDeviceInputSource()
    let committed = BoundInputDevice(
      deviceID: 121,
      deviceUID: "BC-87-FA-9C-7E-71:input",
      transportLabel: "bluetooth",
      resolutionSource: "system_default"
    )
    source.setBoundInputDeviceForTesting(committed)
    #expect(source.warmReuseBindForTesting(hasLiveUnit: true) == committed)

    // All four fields at once, the way `teardownUnit()` clears them.
    source.setBoundInputDeviceForTesting(nil)

    #expect(source.warmReuseBindForTesting(hasLiveUnit: true) == nil)
  }

  @Test("warm explicit source follows fallback default when target is missing")
  func explicitMissingTargetReuseTracksFallbackDefault() {
    let source = HALDeviceInputSource()
    source.targetDeviceUID = "missing"
    nonisolated(unsafe) var currentDefault: AudioDeviceID = 42
    source.inputDeviceResolver = InputDeviceResolver(
      defaultInputDeviceID: { currentDefault },
      // The pinned device is genuinely absent from the list.
      inputDeviceSnapshot: {
        .complete([
          InputDeviceCandidate(
            id: 42, uid: "something-else", rawTransport: kAudioDeviceTransportTypeBuiltIn)
        ])
      }
    )
    source.setBoundInputDeviceForTesting(committedBind(42))

    #expect(source.boundDeviceMatchesResolvedTargetForReuse())

    currentDefault = 43

    #expect(!source.boundDeviceMatchesResolvedTargetForReuse())
  }

  @Test("a reconnected pinned device rejects the warm fallback bind (founder decision)")
  func reconnectedPinnedDeviceRejectsFallbackBind() {
    // The founder's rule running forwards: AirPods come back, so the take they
    // lost is theirs again. Refusing compatibility here is what makes the
    // manager tear the warm source down so the next open is cold and pinned.
    let source = HALDeviceInputSource()
    source.targetDeviceUID = "airpods"
    source.inputDeviceResolver = InputDeviceResolver(
      defaultInputDeviceID: { nil },
      inputDeviceSnapshot: {
        .complete([
          InputDeviceCandidate(
            id: 77, uid: "airpods", rawTransport: kAudioDeviceTransportTypeBluetooth)
        ])
      }
    )
    // Bound to the built-in mic the fallback picked while they were gone.
    source.setBoundInputDeviceForTesting(committedBind(30, source: "list_fallback"))

    #expect(!source.boundDeviceMatchesResolvedTargetForReuse())
  }
}

// #1714 — freezes the cold-attempt finalisation contract.
//
// Every cold `prepare()` exit must produce exactly one finalised attempt, and
// warm reuse must produce none. Two fields, not one, because binding is a single
// step and several fallible setup steps follow it: collapsing them would make
// "could not open the microphone" indistinguishable from "opened it, then the
// converter failed", which are different bugs with different owners.
//
// Scope stated honestly: the resolution-failure exit is driven through the REAL
// `prepare()` with an injected failing resolver. The three post-resolution rows
// need a live `AudioUnit` no seam can construct, so they are frozen as the
// outcome matrix here and confirmed by structural audit plus Live UAT rather
// than by fabricating hardware.
@MainActor
@Suite("HAL cold-attempt finalisation — #1714")
struct HALInputResolutionFinalizationTests {

  @Test("a cold attempt that fails at resolution finalises exactly once, before the throw")
  func resolutionFailureFinalisesOnceBeforeThrow() async {
    let source = HALDeviceInputSource()
    // Successful but empty enumeration: the resolver's proven-absence path.
    source.inputDeviceResolver = InputDeviceResolver(
      defaultInputDeviceID: { nil }, inputDeviceSnapshot: { .complete([]) })

    nonisolated(unsafe) var finalised: [FinalizedInputResolutionAttempt] = []
    source.onInputResolutionAttemptFinalized = { finalised.append($0) }

    await #expect(throws: AudioError.self) { try await source.prepare() }

    #expect(finalised.count == 1, "exactly one finalised attempt per cold exit")
    #expect(finalised.first?.bindOutcome == .notAttempted)
    #expect(finalised.first?.prepareOutcome == .failed)
    // The frozen facts travel with it, so no consumer re-reads hardware.
    #expect(finalised.first?.resolution.enumerationOutcome == .succeeded)
    #expect(finalised.first?.resolution.inputDeviceCount == 0)
    #expect(finalised.first?.resolution.defaultPresent == false)
  }

  @Test("a device-list read failure with no default also finalises exactly once")
  func readFailureFinalisesOnce() async {
    let source = HALDeviceInputSource()
    source.inputDeviceResolver = InputDeviceResolver(
      defaultInputDeviceID: { nil }, inputDeviceSnapshot: { .readFailed })

    nonisolated(unsafe) var finalised: [FinalizedInputResolutionAttempt] = []
    source.onInputResolutionAttemptFinalized = { finalised.append($0) }

    await #expect(throws: AudioError.self) { try await source.prepare() }

    #expect(finalised.count == 1)
    #expect(finalised.first?.bindOutcome == .notAttempted)
    #expect(finalised.first?.prepareOutcome == .failed)
    #expect(finalised.first?.resolution.enumerationOutcome == .readFailed)
  }

  @Test("warm reuse finalises nothing — a reused bind is not a new resolution")
  func warmReuseFinalisesNothing() {
    let source = HALDeviceInputSource()
    source.setBoundInputDeviceForTesting(
      BoundInputDevice(
        deviceID: 121, deviceUID: "uid-121", transportLabel: "bluetooth",
        resolutionSource: "list_fallback"))

    nonisolated(unsafe) var finalised: [FinalizedInputResolutionAttempt] = []
    source.onInputResolutionAttemptFinalized = { finalised.append($0) }

    // The warm early return, driven through the same seam #1844 froze.
    let reused = source.warmReuseBindForTesting(hasLiveUnit: true)

    #expect(reused != nil)
    #expect(reused?.resolutionSource == "list_fallback", "warm reuse carries the ORIGINAL source")
    #expect(finalised.isEmpty)
  }

  @Test("a nil callback changes nothing — observability is a limb")
  func nilCallbackIsHarmless() async {
    let source = HALDeviceInputSource()
    source.inputDeviceResolver = InputDeviceResolver(
      defaultInputDeviceID: { nil }, inputDeviceSnapshot: { .complete([]) })
    source.onInputResolutionAttemptFinalized = nil

    await #expect(throws: AudioError.self) { try await source.prepare() }
  }

  // MARK: - The outcome matrix, driven through the PRODUCTION accumulator
  //
  // These instantiate `InputResolutionAttemptState` — the same type `prepare()`
  // mutates — so deleting or inverting a transition turns them red. An earlier
  // version asserted a table this suite wrote itself, which proved only that the
  // copy agreed with the copy and stayed green when the success transition was
  // removed.

  private func selectedResolution() -> InputDeviceResolution {
    InputDeviceResolution(
      outcome: .selected(42, source: .systemDefault),
      defaultPresent: true,
      enumerationOutcome: .notAttempted,
      inputDeviceCount: nil,
      eligibleDeviceCount: nil,
      selectedTransport: nil
    )
  }

  @Test("an exit before binding is not_attempted / failed")
  func preBindOutcome() {
    let state = InputResolutionAttemptState()
    let result = state.finalized(resolution: selectedResolution())

    #expect(result.bindOutcome == .notAttempted)
    #expect(result.prepareOutcome == .failed)
  }

  @Test("a failed bind is failed / failed")
  func bindFailureOutcome() {
    var state = InputResolutionAttemptState()
    state.recordBind(succeeded: false)
    let result = state.finalized(resolution: selectedResolution())

    #expect(result.bindOutcome == .failed)
    #expect(result.prepareOutcome == .failed)
  }

  @Test("a successful bind followed by setup failure is succeeded / failed")
  func postBindFailureOutcome() {
    var state = InputResolutionAttemptState()
    state.recordBind(succeeded: true)
    let result = state.finalized(resolution: selectedResolution())

    #expect(result.bindOutcome == .succeeded)
    #expect(result.prepareOutcome == .failed)
  }

  @Test("full preparation success is succeeded / succeeded")
  func prepareSuccessOutcome() {
    var state = InputResolutionAttemptState()
    state.recordBind(succeeded: true)
    state.recordPrepareSucceeded()
    let result = state.finalized(resolution: selectedResolution())

    #expect(result.bindOutcome == .succeeded)
    #expect(result.prepareOutcome == .succeeded)
  }

  @Test("a prepare can never report success on a device that was never bound")
  func successWithoutBindIsUnrepresentable() {
    // The invariant is structural, not a test-only assertion: `prepareOutcome`
    // is derived from the bind, so this combination cannot be constructed even
    // by calling the transitions out of order.
    var neverBound = InputResolutionAttemptState()
    neverBound.recordPrepareSucceeded()
    #expect(neverBound.finalized(resolution: selectedResolution()).prepareOutcome == .failed)

    var bindFailed = InputResolutionAttemptState()
    bindFailed.recordBind(succeeded: false)
    bindFailed.recordPrepareSucceeded()
    #expect(bindFailed.finalized(resolution: selectedResolution()).prepareOutcome == .failed)
  }

  @Test("the wire values telemetry will carry are frozen")
  func wireValuesAreFrozen() {
    #expect(InputBindOutcome.notAttempted.rawValue == "not_attempted")
    #expect(InputBindOutcome.failed.rawValue == "failed")
    #expect(InputBindOutcome.succeeded.rawValue == "succeeded")
    #expect(InputPrepareOutcome.failed.rawValue == "failed")
    #expect(InputPrepareOutcome.succeeded.rawValue == "succeeded")
  }
}
