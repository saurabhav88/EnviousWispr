import Testing

@testable import EnviousWisprAppKit

@Suite("RecoveryEngineClaim claim/release ceremony")
@MainActor
struct RecoveryEngineClaimTests {

  @Test("end() forwards to the live closure exactly once per call")
  func endForwardsToLiveClosure() {
    var endCallCount = 0
    let claim = RecoveryEngineClaim.live(tryBegin: { true }, end: { endCallCount += 1 })

    claim.end()

    #expect(endCallCount == 1)
  }
}
