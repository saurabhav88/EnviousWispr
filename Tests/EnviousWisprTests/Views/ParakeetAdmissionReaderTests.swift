import Testing

@testable import EnviousWisprAppKit

/// #4320: the shared Fast model readiness check. When this fails, the user sees "Model ready"
/// (or "Checking") that is not true for the engine they picked: a stale reply landing after a
/// switch, a superseded check winning, or an answer read against a delivery state that moved.
/// Each case reaches one protection of `ParakeetAdmissionReader.recheck` on one ordinary input.
@MainActor
@Suite("Parakeet admission reader (#4320)", .tags(.productOutcome))
struct ParakeetAdmissionReaderTests {

  /// The delivery mirror the reader compares before and after the read.
  struct Key: Equatable {
    var state: Int
    var revision: Int
  }

  /// A value the test changes while a check is parked (a class, so the parked task sees it).
  @MainActor final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
  }

  /// A disk read that parks until released; `arrived` signals the park (subject-side signal,
  /// bounded by `FastAdmissionReadSignals`' hang net).
  @MainActor final class ParkedRead {
    let arrived = FastAdmissionReadSignals()
    private var reply: CheckedContinuation<Bool, Never>?
    func read() async -> Bool {
      await withCheckedContinuation { continuation in
        reply = continuation
        arrived.record(nil)
      }
    }
    func release(_ value: Bool) {
      reply?.resume(returning: value)
      reply = nil
    }
  }

  @Test("a re-check clears the previous answer while it reads, then lands the new one")
  func validCompletion() async throws {
    let reader = ParakeetAdmissionReader()
    let finished = FastAdmissionReadSignals()
    await reader.recheck(
      snapshot: { Key(state: 1, revision: 1) }, read: { false }, eligible: { true },
      onFinished: { finished.record($0) })
    try #require(reader.admitted == false, "precondition: a known answer before the re-check")
    var seenWhileReading: Bool?? = .none
    await reader.recheck(
      snapshot: { Key(state: 1, revision: 1) },
      read: {
        seenWhileReading = reader.admitted
        return true
      },
      eligible: { true },
      onFinished: { finished.record($0) })
    #expect(seenWhileReading == .some(nil), "the previous answer must be cleared while checking")
    #expect(reader.admitted == true)
    #expect(finished.values == [false, true])
  }

  @Test("with no delivery to ask the answer stays unknown and nothing is read")
  func noDeliveryStaysUnknown() async {
    let reader = ParakeetAdmissionReader()
    var reads = 0
    await reader.recheck(
      snapshot: { Key?.none },
      read: {
        reads += 1
        return true
      }, eligible: { true })
    #expect(reader.admitted == nil)
    #expect(reads == 0)
  }

  @Test("an older reply never replaces a newer check")
  func supersededRequestIsDropped() async throws {
    let reader = ParakeetAdmissionReader()
    let parked = ParkedRead()
    let finished = FastAdmissionReadSignals()
    let first = Task {
      await reader.recheck(
        snapshot: { Key(state: 1, revision: 1) }, read: { await parked.read() },
        eligible: { true }, onFinished: { finished.record($0) })
    }
    try #require(await parked.arrived.wait(after: 0), "first check never parked")
    await reader.recheck(
      snapshot: { Key(state: 1, revision: 1) }, read: { false },
      eligible: { true }, onFinished: { finished.record($0) })
    #expect(reader.admitted == false)
    parked.release(true)
    await first.value
    #expect(reader.admitted == false, "the superseded reply must not land")
    #expect(finished.count == 2)
  }

  @Test("a cancelled check does not land its reply")
  func cancelledCheckIsDropped() async throws {
    let reader = ParakeetAdmissionReader()
    let parked = ParkedRead()
    let task = Task {
      await reader.recheck(
        snapshot: { Key(state: 1, revision: 1) }, read: { await parked.read() },
        eligible: { true })
    }
    try #require(await parked.arrived.wait(after: 0), "check never parked")
    task.cancel()
    parked.release(true)
    await task.value
    #expect(reader.admitted == nil)
  }

  @Test(
    "a reply read against a delivery state or revision that moved is dropped",
    arguments: [Key(state: 2, revision: 1), Key(state: 1, revision: 2)])
  func movedDeliveryIsDropped(after moved: Key) async throws {
    let reader = ParakeetAdmissionReader()
    let parked = ParkedRead()
    let current = Box(Key(state: 1, revision: 1))
    let task = Task {
      await reader.recheck(
        snapshot: { current.value }, read: { await parked.read() }, eligible: { true })
    }
    try #require(await parked.arrived.wait(after: 0), "check never parked")
    current.value = moved
    parked.release(true)
    await task.value
    #expect(reader.admitted == nil)
  }

  @Test("the view going away while a check is in flight drops its reply")
  func invalidationDropsReply() async throws {
    let reader = ParakeetAdmissionReader()
    await reader.recheck(snapshot: { Key(state: 1, revision: 1) }, read: { true }, eligible: { true })
    try #require(reader.admitted == true, "precondition: a known answer before the view goes away")
    reader.invalidate()
    #expect(reader.admitted == nil, "going away must clear a known answer at once")

    let parked = ParkedRead()
    let task = Task {
      await reader.recheck(
        snapshot: { Key(state: 1, revision: 1) }, read: { await parked.read() },
        eligible: { true })
    }
    try #require(await parked.arrived.wait(after: 0), "check never parked")
    reader.invalidate()
    parked.release(true)
    await task.value
    #expect(reader.admitted == nil)
  }

  @Test("eligibility is read again after the read: a switch during the read drops the reply")
  func eligibilityChangeDuringReadIsHonoured() async throws {
    let reader = ParakeetAdmissionReader()
    let parked = ParkedRead()
    let eligible = Box(true)
    let task = Task {
      await reader.recheck(
        snapshot: { Key(state: 1, revision: 1) }, read: { await parked.read() },
        eligible: { eligible.value })
    }
    try #require(await parked.arrived.wait(after: 0), "check never parked")
    eligible.value = false
    parked.release(true)
    await task.value
    #expect(reader.admitted == nil)
  }
}
