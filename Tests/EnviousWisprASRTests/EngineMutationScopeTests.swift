import Testing

@testable import EnviousWisprASR

@Suite("EngineMutationScope claim/release/wake/telemetry ceremony")
@MainActor
struct EngineMutationScopeTests {

  @Test("a granted claim runs the operation and returns .completed")
  func grantedClaimRunsOperation() async {
    let scope = EngineMutationScope.live(
      tryBegin: { true }, end: { false }, wake: {}, onRefused: { _ in })

    let outcome = await scope.withClaim(site: "test") { 42 }

    guard case .completed(let value) = outcome else {
      Issue.record("expected .completed")
      return
    }
    #expect(value == 42)
  }

  @Test("a refused claim never runs the operation, returns .refused, and reports the site")
  func refusedClaimSkipsOperationAndReportsSite() async {
    var reportedSite: String?
    var operationRan = false
    let scope = EngineMutationScope.live(
      tryBegin: { false }, end: { false }, wake: {},
      onRefused: { site in reportedSite = site })

    let outcome = await scope.withClaim(site: "myOperation") {
      operationRan = true
      return 1
    }

    guard case .refused = outcome else {
      Issue.record("expected .refused")
      return
    }
    #expect(operationRan == false)
    #expect(reportedSite == "myOperation")
  }

  @Test("refusal telemetry fires exactly once per refused claim, not on a granted claim")
  func refusalTelemetryFiresExactlyOnceAndOnlyOnRefusal() async {
    var refusalCount = 0
    let refusing = EngineMutationScope.live(
      tryBegin: { false }, end: { false }, wake: {},
      onRefused: { _ in refusalCount += 1 })
    _ = await refusing.withClaim(site: "site") { 1 }
    #expect(refusalCount == 1)

    var grantedRefusalCount = 0
    let granting = EngineMutationScope.live(
      tryBegin: { true }, end: { false }, wake: {},
      onRefused: { _ in grantedRefusalCount += 1 })
    _ = await granting.withClaim(site: "site") { 1 }
    #expect(grantedRefusalCount == 0)
  }

  @Test("a granted claim releases and forwards a wake on normal completion")
  func releaseAndWakeOnNormalCompletion() async {
    var released = false
    var woke = false
    let scope = EngineMutationScope.live(
      tryBegin: { true },
      end: {
        released = true
        return true
      },
      wake: { woke = true },
      onRefused: { _ in })

    _ = await scope.withClaim(site: "site") { 1 }

    #expect(released)
    #expect(woke)
  }

  @Test("a granted claim releases and forwards a wake even when the operation throws")
  func releaseAndWakeOnThrownError() async {
    struct ProbeError: Error {}
    var released = false
    var woke = false
    let scope = EngineMutationScope.live(
      tryBegin: { true },
      end: {
        released = true
        return true
      },
      wake: { woke = true },
      onRefused: { _ in })

    await #expect(throws: ProbeError.self) {
      _ = try await scope.withClaim(site: "site") {
        throw ProbeError()
      }
    }

    #expect(released)
    #expect(woke)
  }

  @Test("end() returning false (no wake owed) does not forward a wake")
  func noWakeWhenNotOwed() async {
    var woke = false
    let scope = EngineMutationScope.live(
      tryBegin: { true },
      end: { false },
      wake: { woke = true },
      onRefused: { _ in })

    _ = await scope.withClaim(site: "site") { 1 }

    #expect(woke == false)
  }

  @Test("release and wake fire exactly once per claim, never twice, when a wake is owed")
  func coalescedWakeNotDoubleFired() async {
    var endCallCount = 0
    var wakeCount = 0
    let scope = EngineMutationScope.live(
      tryBegin: { true },
      end: {
        endCallCount += 1
        return true
      },
      wake: { wakeCount += 1 },
      onRefused: { _ in })

    _ = await scope.withClaim(site: "site") { 1 }

    #expect(endCallCount == 1)
    #expect(wakeCount == 1)
  }
}
