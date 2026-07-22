import Testing

@testable import EnviousWisprAppKit

@Suite("RecoveryEngineClaim claim/release ceremony")
@MainActor
struct RecoveryEngineClaimTests {

  @Test("tryBegin() forwards the live closure's result when granted")
  func tryBeginForwardsGrantedResult() {
    let claim = RecoveryEngineClaim.live(tryBegin: { true }, end: {})

    #expect(claim.tryBegin() == true)
  }

  @Test("tryBegin() forwards the live closure's result when refused")
  func tryBeginForwardsRefusedResult() {
    let claim = RecoveryEngineClaim.live(tryBegin: { false }, end: {})

    #expect(claim.tryBegin() == false)
  }

  @Test("end() forwards to the live closure exactly once per call")
  func endForwardsToLiveClosure() {
    var endCallCount = 0
    let claim = RecoveryEngineClaim.live(tryBegin: { true }, end: { endCallCount += 1 })

    claim.end()

    #expect(endCallCount == 1)
  }
}
