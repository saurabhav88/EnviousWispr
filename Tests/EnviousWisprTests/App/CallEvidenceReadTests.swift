import EnviousWisprCore
import EnviousWisprServices
import Foundation
import os
import Testing

@testable import EnviousWisprAppKit

@Suite("Call evidence worker recovery", .tags(.productOutcome))
struct CallEvidenceReadTests {
  @Test("Caller timeout holds the lane until the real worker finishes, then healthy reads recover",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/4127"))
  func workerRecovery() async {
    _ = await recoverWorker(rule: .callWindow(.zoom), family: .zoom, trusted: true, expected: .unknown)
  }

  @Test("Teams outer timeout and occupied lane retain Ask evidence only with trust",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/4094"), arguments: [true, false])
  func teamsUnavailableEvidence(trusted: Bool) async {
    let expected: CallEvidenceReader.Evidence = trusted
      ? .microphoneOnly(family: .teams, room: "pid-70000") : .unknown
    let evidence = await recoverWorker(
      rule: .callApp(.teams), family: .teams, trusted: trusted, expected: expected)
    var ask = CallDetectionPolicyTests.Story()
    ask.read([.init(pid: 70_000, rule: .callApp(.teams), input: .active, evidence: evidence)])
    if case .ask = ask.interaction { #expect(trusted) } else { #expect(trusted == false) }
    var automatic = CallDetectionPolicyTests.Story()
    automatic.mode = .startByItself
    automatic.read([.init(pid: 70_000, rule: .callApp(.teams), input: .active, evidence: evidence)])
    #expect(automatic.starts.isEmpty)
  }

  @Test("A completed Teams worker unknown is never upgraded to microphone evidence")
  func teamsCompletedUnknown() async {
    let result = await CallEvidenceRead.bounded(
      rule: .callApp(.teams), pid: 70_000, bound: .seconds(10), lane: .init(),
      isTrusted: { true }, read: { _, _ in .unknown })
    #expect(result == .unknown)
  }

  private func recoverWorker(
    rule: CallAppCatalog.Rule, family: CallAppFamily, trusted: Bool,
    expected: CallEvidenceReader.Evidence
  ) async -> CallEvidenceReader.Evidence {
    let lane = CallEvidenceRead.Lane()
    let gate = DispatchSemaphore(value: 0)
    let arrival = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { gate.signal(); arrival.continuation.finish() }
    // deadline-fallback: prove that the worker actually entered its controlled blocking read.
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
      arrival.continuation.yield(false)
      arrival.continuation.finish()
    }
    let unexpectedReads = OSAllocatedUnfairLock(initialState: 0)
    let first = await CallEvidenceRead.bounded(
      rule: rule, pid: 70_000, bound: .zero, lane: lane, isTrusted: { trusted },
      read: { _, _ in
        // Arrival is a precondition only. Completion is acknowledged behind this queue block.
        arrival.continuation.yield(true)
        arrival.continuation.finish()
        // deadline-fallback: release a broken fixture; this is not a latency assertion.
        _ = gate.wait(timeout: .now() + 10)
        return .none
      })
    #expect(first == expected)
    var entered = false
    for await value in arrival.stream { entered = value; break }
    #expect(entered)
    guard entered else { return first }
    #expect(lane.reading.withLock { $0 })
    let refused = await CallEvidenceRead.bounded(
      rule: rule, pid: 70_000, lane: lane, isTrusted: { trusted },
      read: { _, _ in
        unexpectedReads.withLock { $0 += 1 }
        return .call(family: family, room: "healthy")
      })
    #expect(refused == expected)

    let signal = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { signal.continuation.finish() }
    // This acknowledgement is behind the worker, after its actual reading=false transition.
    lane.queue.async {
      signal.continuation.yield(true)
      signal.continuation.finish()
    }
    // deadline-fallback: a missing queue acknowledgement fails instead of hanging the suite.
    DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
      signal.continuation.yield(false)
      signal.continuation.finish()
    }
    gate.signal()
    var completed = false
    for await value in signal.stream { completed = value; break }
    #expect(completed)
    #expect(lane.reading.withLock { $0 } == false)
    #expect(unexpectedReads.withLock { $0 } == 0)

    let healthy = await CallEvidenceRead.bounded(
      rule: rule, pid: 70_000, bound: .seconds(10), lane: lane, isTrusted: { trusted },
      read: { _, _ in .call(family: family, room: "healthy") })
    #expect(healthy == .call(family: family, room: "healthy"))
    return first
  }
}
