import Foundation
import Testing

@testable import EnviousWisprAudio

// #1376 — locks the changed-only semantics of the `onRouteResolved` producer
// (`CaptureRouteDecision.routeResolvedChanged`), the single authority both
// `AudioCaptureManager` and `AudioCaptureProxy` fire through: first resolution
// fires, an identical warm-reuse resolution is a no-op, and a reason change
// re-fires. Pure predicate — no audio hardware, no timing.
@Suite("onRouteResolved changed-only predicate — #1376")
struct RouteResolvedProducerTests {

  private func decision(
    _ source: CaptureSourceType, _ reason: CaptureRouteReason
  ) -> CaptureRouteDecision {
    CaptureRouteDecision(sourceType: source, reason: reason, rationale: "t")
  }

  @Test("fires on the first resolution (prior nil)")
  func firstResolution() {
    #expect(
      CaptureRouteDecision.routeResolvedChanged(
        from: nil, to: decision(.halDeviceInput, .noBTAutoInput)))
  }

  @Test("no-op when reason and sourceType are unchanged (identical warm reuse)")
  func unchangedNoOp() {
    let d = decision(.halDeviceInput, .noBTAutoInput)
    #expect(!CaptureRouteDecision.routeResolvedChanged(from: d, to: d))
  }

  @Test("re-fires when the reason differs (same sourceType)")
  func reasonChanged() {
    let prior = decision(.halDeviceInput, .btOutputAutoInput)
    let next = decision(.halDeviceInput, .btOutputUserSelectedDevice)
    #expect(CaptureRouteDecision.routeResolvedChanged(from: prior, to: next))
  }

  @Test("re-fires when a no-BT reason changes to a BT reason")
  func noBTToBTReasonChanged() {
    let prior = decision(.halDeviceInput, .noBTAutoInput)
    let next = decision(.halDeviceInput, .btOutputAutoInput)
    #expect(CaptureRouteDecision.routeResolvedChanged(from: prior, to: next))
  }
}
