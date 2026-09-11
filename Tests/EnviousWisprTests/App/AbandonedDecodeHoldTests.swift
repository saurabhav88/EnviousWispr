import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// #2787 — after a session ends while its vendor decode is still running, the
/// shared engine stays claimed until that decode returns.
///
/// **When this fails, the user sees a second recording start on top of a decode
/// that never returned** — the state the customer's Mac Studio was in four
/// times on macOS 27 RC day — or, in the other direction, "Restart the app"
/// after the engine is in fact free.
@Suite(.tags(.productOutcome))
@MainActor
struct AbandonedDecodeHoldTests {

  /// A vendor decode the test controls: parked inside `track` until opened.
  private final class Decode: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    private var hasEntered = false

    func run(under occupancy: VendorDecodeOccupancy) -> Task<Void, Never> {
      Task { @MainActor in
        await occupancy.track { await self.park() }
      }
    }

    private func park() async {
      await withCheckedContinuation { c in
        let waiters = lock.withLock { () -> [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] in
          parked = c
          hasEntered = true
          let ws = enteredWaiters
          enteredWaiters.removeAll()
          return ws
        }
        for waiter in waiters { waiter.continuation.resume(returning: true) }
      }
    }

    /// `true` once the decode is parked inside the occupancy; bounded.
    func entered() async -> Bool {
      await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        let id = UUID()
        // Check and register under ONE lock hold: a producer finishing between
        // a separate check and the registration would strand the waiter.
        let alreadyEntered = lock.withLock {
          if hasEntered { return true }
          enteredWaiters.append((id, c))
          return false
        }
        if alreadyEntered {
          c.resume(returning: true)
          return
        }
        Task {
          try? await Task.sleep(for: .seconds(5))  // deadline-fallback: bounds the signal wait
          self.expireEnteredWaiter(id)
        }
      }
    }

    private func expireEnteredWaiter(_ id: UUID) {
      let waiter = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
        guard let index = enteredWaiters.firstIndex(where: { $0.id == id }) else { return nil }
        return enteredWaiters.remove(at: index).continuation
      }
      waiter?.resume(returning: false)
    }

    func finish() {
      let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        let p = parked
        parked = nil
        return p
      }
      c?.resume()
    }
  }

  /// Resolves when `onSettled` fires, or `false` at the deadline.
  private final class Settled: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double?
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Double?, Never>)] = []

    func fire(_ s: Double) {
      let ws = lock.withLock { () -> [(id: UUID, continuation: CheckedContinuation<Double?, Never>)] in
        seconds = s
        let w = waiters
        waiters.removeAll()
        return w
      }
      for w in ws { w.continuation.resume(returning: s) }
    }

    func value() async -> Double? {
      await withCheckedContinuation { (c: CheckedContinuation<Double?, Never>) in
        let id = UUID()
        let known = lock.withLock { () -> Double? in
          if let seconds { return seconds }
          waiters.append((id, c))
          return nil
        }
        if let known {
          c.resume(returning: known)
          return
        }
        Task {
          try? await Task.sleep(for: .seconds(5))  // deadline-fallback: bounds the signal wait
          self.expireWaiter(id)
        }
      }
    }

    private func expireWaiter(_ id: UUID) {
      let waiter = lock.withLock { () -> CheckedContinuation<Double?, Never>? in
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
        return waiters.remove(at: index).continuation
      }
      waiter?.resume(returning: nil)
    }
  }

  private func dictationToken(_ lease: EngineLease) throws -> EngineLease.Token {
    guard case .granted(let token) = lease.admit(.dictation) else {
      throw TestFailure("dictation could not claim a free lease")
    }
    return token
  }

  private struct TestFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  @Test("a session that ends with the engine idle hands the lease straight back")
  func idleEngineReleasesNormally() throws {
    let lease = EngineLease()
    let hold = AbandonedDecodeHold(lease: lease, occupancy: VendorDecodeOccupancy())
    let token = try dictationToken(lease)
    hold.releaseFromDictation(token)
    #expect(lease.isBusy == false)
    #expect(hold.isHolding == false)
    // The next press claims cleanly.
    guard case .granted = lease.admit(.dictation) else {
      Issue.record("the lease was not free after a normal release")
      return
    }
  }

  @Test(
    "a session that ends mid-decode keeps the engine claimed as abandonedDecode until the decode returns"
  )
  func busyEngineIsHeldUntilTheDecodeReturns() async throws {
    let lease = EngineLease()
    let occupancy = VendorDecodeOccupancy()
    let hold = AbandonedDecodeHold(lease: lease, occupancy: occupancy)
    let settled = Settled()
    hold.onSettled = { settled.fire($0) }
    let token = try dictationToken(lease)

    let decode = Decode()
    let vendorCall = decode.run(under: occupancy)
    #expect(await decode.entered())

    // The user stopped waiting: the session's terminal releases the dictation claim.
    hold.releaseFromDictation(token)
    #expect(hold.isHolding)
    #expect(lease.currentHolder == .abandonedDecode)
    // A record press, a replay, an import: all refused, naming the abandoned decode.
    for holder in [SharedEngineHolder.dictation, .crashRecovery, .fileImport] {
      guard case .refused(let by) = lease.admit(holder) else {
        Issue.record("\(holder) claimed the engine while a decode was still running")
        continue
      }
      #expect(by == .abandonedDecode)
    }

    // The decode finally returns: the hold settles and the lease is free.
    decode.finish()
    _ = await vendorCall.value
    let seconds = await settled.value()
    #expect(seconds != nil, "onSettled never fired after the decode returned")
    #expect(hold.isHolding == false)
    #expect(lease.isBusy == false)
    guard case .granted = lease.admit(.dictation) else {
      Issue.record("the lease was not free after the decode returned")
      return
    }
  }

  @Test("a hold that never settles keeps refusing: the honest state is 'restart the app'")
  func unreturnedDecodeKeepsRefusing() async throws {
    let lease = EngineLease()
    let occupancy = VendorDecodeOccupancy()
    let hold = AbandonedDecodeHold(lease: lease, occupancy: occupancy)
    let token = try dictationToken(lease)
    let decode = Decode()
    let vendorCall = decode.run(under: occupancy)
    #expect(await decode.entered())
    hold.releaseFromDictation(token)
    // A NEGATIVE: nothing must free the lease while the decode is parked.
    // Yield is the honest instrument (a-test-that-proves-a-NEGATIVE-has-no-
    // signal-to-park-on); the binding precondition is the in-flight count.
    for _ in 0..<20 { await Task.yield() }
    #expect(occupancy.inFlight == 1)
    #expect(lease.currentHolder == .abandonedDecode)
    #expect(
      DictationNarrator.copy(for: .sharedEngineBusy(holder: .abandonedDecode))
        == "Previous take still running. Restart the app.")
    decode.finish()
    _ = await vendorCall.value
  }

  #if DEBUG
    @Test("the hold reports one started and one settled event, in that order")
    func telemetryPair() async throws {
      let lease = EngineLease()
      let occupancy = VendorDecodeOccupancy()
      let hold = AbandonedDecodeHold(lease: lease, occupancy: occupancy)
      let settled = Settled()
      hold.onSettled = { settled.fire($0) }
      let names = Names()
      TelemetryService.shared.testEventHook = { @Sendable event in
        if event.name.hasPrefix("engine.abandoned_decode_hold") { names.add(event.name) }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      let token = try dictationToken(lease)
      let decode = Decode()
      let vendorCall = decode.run(under: occupancy)
      #expect(await decode.entered())
      hold.releaseFromDictation(token)
      decode.finish()
      _ = await vendorCall.value
      _ = await settled.value()
      #expect(
        names.all == [
          "engine.abandoned_decode_hold_started", "engine.abandoned_decode_hold_settled",
        ])
    }

    private final class Names: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [String] = []
      var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
      }
      func add(_ n: String) {
        lock.lock()
        stored.append(n)
        lock.unlock()
      }
    }
  #endif
}
