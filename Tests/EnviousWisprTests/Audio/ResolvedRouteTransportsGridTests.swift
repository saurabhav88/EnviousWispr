import CoreAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

// #1376 — locks `ResolvedRouteTransports.derive` as a total function over the
// `CaptureSourceType × CaptureRouteReason` grid: reason passthrough, fallback
// presence-iff-a-fallback-rung, capture-session-path-is-built-in-only, and the
// selection-mode split. The selected/effective TRANSPORT values depend on live
// CoreAudio device state (verified at Live UAT), so these tests assert the
// deterministic structural invariants only.
@Suite("ResolvedRouteTransports.derive — #1376")
struct ResolvedRouteTransportsGridTests {

  private func makeDecision(
    _ source: CaptureSourceType, _ reason: CaptureRouteReason
  ) -> CaptureRouteDecision {
    CaptureRouteDecision(
      sourceType: source, reason: reason, rationale: "test",
      vpAvailable: false, fallbackAllowed: false)
  }

  // #1529 — a fixed fake default device, injected via `derive`'s device-lookup
  // closures, so tests asserting a specific `effective`/`selected` label never
  // depend on which mic is actually live on the machine running the suite.
  private let fakeDefaultDeviceID = AudioDeviceID(42)

  private func fakeDefaultInputDeviceID() -> AudioDeviceID? { fakeDefaultDeviceID }
  private func fakeDefaultOutputDeviceID() -> AudioDeviceID? { nil }
  private func fakeTransportLabelForDevice(_ deviceID: AudioDeviceID) -> String? {
    deviceID == fakeDefaultDeviceID ? "built_in" : nil
  }
  private func fakeTransportLabelForUID(_ uid: String) -> String? { nil }

  @Test(
    "derive is total over the sourceType × reason grid",
    arguments: [CaptureSourceType.audioEngine, .halDeviceInput],
    [
      CaptureRouteReason.btOutputAutoInput, .btOutputUserSelectedDevice, .noBTAutoInput,
      .noBTUserSelectedDevice, .forcedEngine, .forcedHALDeviceInput,
      .fallbackToEngine, .failedNoFallback,
    ])
  func totalOverGrid(source: CaptureSourceType, reason: CaptureRouteReason) {
    let r = ResolvedRouteTransports.derive(
      decision: makeDecision(source, reason),
      preferredInputDeviceIDOverride: "", selectedInputDeviceUID: "")

    #expect(r.routeReason == reason.rawValue)

    let isFallbackRung = (reason == .fallbackToEngine || reason == .failedNoFallback)
    #expect((r.routeFallbackReason != nil) == isFallbackRung)
    if isFallbackRung { #expect(r.routeFallbackReason == reason.rawValue) }

    // Empty UIDs → Auto; no user-selected transport.
    #expect(r.inputSelectionMode == "auto")
    #expect(r.selected == "unknown")

    #expect(r.routeResolutionSource == "app_derived")
    // Totality: effective is always a non-empty label.
    #expect(!r.effective.isEmpty)
  }

  @Test("explicit Bluetooth pick under BT output: mode=explicit, route reason is unified")
  func explicitBTMicUsesUnifiedReason() {
    let r = ResolvedRouteTransports.derive(
      decision: makeDecision(.halDeviceInput, .btOutputUserSelectedDevice),
      preferredInputDeviceIDOverride: "fake-bt-uid", selectedInputDeviceUID: "")
    #expect(r.inputSelectionMode == "explicit")
    #expect(r.routeReason == "btOutputUserSelectedDevice")
  }

  @Test("bound HAL transport wins over live re-derivation")
  func boundHALTransportWins() {
    let r = ResolvedRouteTransports.derive(
      decision: makeDecision(.halDeviceInput, .btOutputAutoInput),
      preferredInputDeviceIDOverride: "", selectedInputDeviceUID: "",
      actualBoundTransport: "bluetooth")
    #expect(r.effective == "bluetooth")
    #expect(r.routeResolutionSource == "helper_reported")
  }

  @Test("wired pick under BT output uses unified explicit reason")
  func wiredUnderBTOutput() {
    let r = ResolvedRouteTransports.derive(
      decision: makeDecision(.halDeviceInput, .btOutputUserSelectedDevice),
      preferredInputDeviceIDOverride: "fake-wired-uid", selectedInputDeviceUID: "")
    #expect(r.inputSelectionMode == "explicit")
    #expect(r.routeReason == "btOutputUserSelectedDevice")
  }

  @Test("selection mode follows the settings picker; a bare selectedInputDeviceUID stays Auto")
  func selectionModeFollowsPicker() {
    // The mic picker binds to preferredInputDeviceIDOverride and the resolver
    // uses ONLY that, so a bare selectedInputDeviceUID is Auto to the resolver
    // — mode/selected must agree with route_reason, not claim explicit (#1387).
    let r = ResolvedRouteTransports.derive(
      decision: makeDecision(.audioEngine, .noBTAutoInput),
      preferredInputDeviceIDOverride: "", selectedInputDeviceUID: "fake-uid")
    #expect(r.inputSelectionMode == "auto")
    #expect(r.selected == "unknown")
  }

  @Test("bare selectedInputDeviceUID under BT output does NOT misreport explicit (cloud review P2)")
  func bareSelectedUnderBTOutputStaysConsistentWithRouteReason() {
    // The exact misclassification the cloud reviewer flagged: a stored device
    // UID in selectedInputDeviceUID with an empty picker must not emit
    // explicit/bluetooth while route_reason stays Auto. All three agree on Auto.
    // #1529 — the fake default device is injected so `effective == "built_in"`
    // holds regardless of which mic is actually live on this machine.
    let r = ResolvedRouteTransports.derive(
      decision: makeDecision(.halDeviceInput, .btOutputAutoInput),
      preferredInputDeviceIDOverride: "", selectedInputDeviceUID: "fake-bt-uid",
      defaultInputDeviceID: fakeDefaultInputDeviceID,
      defaultOutputDeviceID: fakeDefaultOutputDeviceID,
      transportLabelForDevice: fakeTransportLabelForDevice,
      transportLabelForUID: fakeTransportLabelForUID)
    #expect(r.inputSelectionMode == "auto")
    #expect(r.selected == "unknown")
    #expect(r.routeReason == "btOutputAutoInput")
    #expect(r.effective == "built_in")
  }

  @Test("an explicit picker choice reports explicit + its transport (consistent with route_reason)")
  func explicitPickerReportsExplicit() {
    // preferredInputDeviceIDOverride set (the picker) → explicit, and the
    // resolver saw the same value, so route_reason is a user-selected reason.
    let r = ResolvedRouteTransports.derive(
      decision: makeDecision(.halDeviceInput, .btOutputUserSelectedDevice),
      preferredInputDeviceIDOverride: "fake-bt-uid", selectedInputDeviceUID: "")
    #expect(r.inputSelectionMode == "explicit")
  }

  @Test("a disconnected pinned device falls effective back to the default input (engine parity)")
  func disconnectedPinFallsBackToDefault() {
    // AVAudioEngineSource resolves a missing pinned UID to nil and captures from
    // the system-default input (`resolvedDeviceID ?? defaultInputDeviceID()`),
    // so the effective transport must match Auto, NOT report "unknown".
    // #1529 — both calls inject the SAME fake default device so the comparison
    // is deterministic instead of racing two independent live CoreAudio reads.
    let disconnected = ResolvedRouteTransports.derive(
      decision: makeDecision(.audioEngine, .noBTUserSelectedDevice),
      preferredInputDeviceIDOverride: "fake-disconnected-uid", selectedInputDeviceUID: "",
      defaultInputDeviceID: fakeDefaultInputDeviceID,
      defaultOutputDeviceID: fakeDefaultOutputDeviceID,
      transportLabelForDevice: fakeTransportLabelForDevice,
      transportLabelForUID: fakeTransportLabelForUID)
    let auto = ResolvedRouteTransports.derive(
      decision: makeDecision(.audioEngine, .noBTAutoInput),
      preferredInputDeviceIDOverride: "", selectedInputDeviceUID: "",
      defaultInputDeviceID: fakeDefaultInputDeviceID,
      defaultOutputDeviceID: fakeDefaultOutputDeviceID,
      transportLabelForDevice: fakeTransportLabelForDevice,
      transportLabelForUID: fakeTransportLabelForUID)
    #expect(disconnected.effective == auto.effective)
    // The user's pick is unavailable, so `selected` stays unknown.
    #expect(disconnected.selected == "unknown")
    #expect(disconnected.inputSelectionMode == "explicit")
  }
}
