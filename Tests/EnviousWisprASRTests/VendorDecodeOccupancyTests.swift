import Foundation
import Testing
import WhisperKit

@testable import EnviousWisprASR

/// #2787 — the engine stays visibly BUSY for exactly as long as a vendor
/// decode is running, whoever is still waiting for it.
///
/// **When this fails, the user sees one of two wrong things:** a second
/// recording minted on top of a decode that never returned (the engine reads
/// idle while Core ML still owns it), or "restart the app" after the decode
/// has in fact returned (the engine reads busy after the call unwound). The
/// customer's Mac Studio on the macOS 27 RC produced the first; this is the
/// instrument the hold reads to prevent both.
@Suite(.tags(.productOutcome))
@MainActor
struct VendorDecodeOccupancyTests {

  /// Parks a tracked operation until the test releases it, and announces the
  /// moment it is parked so the test waits on a signal rather than a guess.
  private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    private var hasEntered = false

    func park() async {
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

    /// Resolves `true` once `park()` has been reached, `false` after the
    /// deadline. Bounded so a subject that never reaches the gate fails the
    /// test instead of hanging the suite.
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

    func open() {
      let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
        let p = parked
        parked = nil
        return p
      }
      c?.resume()
    }
  }

  @Test("idle before, busy during, idle after a decode that returns")
  func countsOneDecode() async {
    let occupancy = VendorDecodeOccupancy()
    let gate = Gate()
    #expect(occupancy.isIdle)
    let decode = Task { @MainActor in
      await occupancy.track {
        await gate.park()
        return "text"
      }
    }
    #expect(await gate.entered())
    #expect(occupancy.inFlight == 1)
    #expect(occupancy.isIdle == false)
    gate.open()
    _ = await decode.value
    #expect(occupancy.isIdle)
  }

  @Test("a decode that throws still releases the count")
  func throwingDecodeReleases() async {
    let occupancy = VendorDecodeOccupancy()
    struct Boom: Error {}
    await #expect(throws: Boom.self) {
      try await occupancy.track { () throws -> Void in throw Boom() }
    }
    #expect(occupancy.isIdle)
  }

  @Test("awaitIdle returns at once when nothing is running")
  func awaitIdleImmediate() async {
    let occupancy = VendorDecodeOccupancy()
    await occupancy.awaitIdle()
    #expect(occupancy.isIdle)
  }

  @Test("awaitIdle resumes only when the decode returns, not when its awaiting task is cancelled")
  func awaitIdleWaitsForTheVendorCallNotTheWaiter() async {
    let occupancy = VendorDecodeOccupancy()
    let gate = Gate()
    // The session's own await: cancelled by the user long before the decode returns.
    let sessionWait = Task { @MainActor in
      await occupancy.track { await gate.park() }
    }
    #expect(await gate.entered())
    sessionWait.cancel()
    let resumed = Resumed()
    let waiterA = Task { @MainActor in
      await occupancy.awaitIdle()
      resumed.mark("a")
    }
    let waiterB = Task { @MainActor in
      await occupancy.awaitIdle()
      resumed.mark("b")
    }
    // A NEGATIVE has no signal to park on: the waiters' whole job here is to
    // stay silent. Yielding gives them the opportunity they must decline; it is
    // weaker than the signal waits around it (swift-testing-patterns.md
    // a-test-that-proves-a-NEGATIVE-has-no-signal-to-park-on). The binding
    // precondition is the count, asserted on the same line.
    for _ in 0..<20 { await Task.yield() }
    #expect(occupancy.inFlight == 1)
    #expect(resumed.names.isEmpty, "a cancelled waiter is not a returned decode")
    gate.open()
    _ = await sessionWait.value
    _ = await waiterA.value
    _ = await waiterB.value
    #expect(resumed.names.sorted() == ["a", "b"])
    #expect(occupancy.isIdle)
  }

  @Test("two overlapping decodes: idle only after both return")
  func overlappingDecodes() async {
    let occupancy = VendorDecodeOccupancy()
    let first = Gate()
    let second = Gate()
    let a = Task { @MainActor in await occupancy.track { await first.park() } }
    let b = Task { @MainActor in await occupancy.track { await second.park() } }
    #expect(await first.entered())
    #expect(await second.entered())
    #expect(occupancy.inFlight == 2)
    first.open()
    _ = await a.value
    #expect(occupancy.inFlight == 1)
    #expect(occupancy.isIdle == false)
    second.open()
    _ = await b.value
    #expect(occupancy.isIdle)
  }

  /// The real seam: `ASRManager.transcribe` counts the backend call it issues.
  /// A parked fake backend is the shape of a vendor decode that does not
  /// return; the manager's occupancy must read busy for as long as it is
  /// parked, and idle the moment it returns.
  @Test("ASRManager.transcribe is counted for the whole vendor call")
  func managerTranscribeIsCounted() async throws {
    let parakeet = FakeASRBackend(initiallyReady: true)
    await parakeet.gateTranscribe()
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting, parakeetBackendFactory: { parakeet })
    manager.setInitialBackendType(.parakeet)
    try await manager.loadModel()
    #expect(manager.vendorDecodeOccupancy.isIdle)
    let decode = Task { @MainActor in
      try await manager.transcribe(audioSamples: [0.0], options: .default)
    }
    #expect(await parakeet.transcribeParked(), "the fake never reached its gate")
    #expect(manager.vendorDecodeOccupancy.inFlight == 1)
    await parakeet.releaseTranscribeGate()
    let result = try await decode.value
    #expect(result.text == "ok")
    #expect(manager.vendorDecodeOccupancy.isIdle)
  }

  /// The WhisperKit STREAMING path never touches `ASRManager.transcribe`; its
  /// session decodes through the decoder interface. The decorator counts every
  /// one of those decodes, so a stream stopped mid-decode reads busy until the
  /// vendor call actually returns.
  @Test("the streaming decoder decorator counts each vendor decode for its whole duration")
  func streamingDecoderIsCounted() async throws {
    let occupancy = VendorDecodeOccupancy()
    let gate = Gate()
    let decoder = OccupiedWhisperKitDecoder(
      base: ParkedDecoder(gate: gate), occupancy: occupancy)
    let decode = Task { @MainActor in
      try await decoder.transcribe(audioArray: [0.0], decodeOptions: nil, shouldContinueDecoding: nil)
    }
    #expect(await gate.entered())
    #expect(occupancy.inFlight == 1)
    gate.open()
    let results = try await decode.value
    #expect(results.isEmpty)
    #expect(occupancy.isIdle)
    #expect(decoder.encodeText("x") == [7], "pass-through must reach the base decoder")
  }

  /// A decoder that parks inside `transcribe` until the gate opens.
  private struct ParkedDecoder: WhisperKitTranscribing {
    let gate: Gate
    func transcribe(
      audioArray: [Float], decodeOptions: DecodingOptions?,
      shouldContinueDecoding: (@Sendable () -> Bool)?
    ) async throws -> [TranscriptionResult] {
      await gate.park()
      return []
    }
    func encodeText(_ text: String) -> [Int] { [7] }
  }

  @Test("a refused transcribe (backend not owned) never touches the count")
  func refusedTranscribeNotCounted() async {
    let manager = ASRManager(
      engineMutationScope: .alwaysAllowedForTesting,
      parakeetBackendFactory: { FakeASRBackend(initiallyReady: true) })
    manager.setInitialBackendType(.whisperKit)
    await #expect(throws: ASRManagerNotOwnedError(backend: .whisperKit)) {
      _ = try await manager.transcribe(audioSamples: [0.0], options: .default)
    }
    #expect(manager.vendorDecodeOccupancy.isIdle)
  }

  private final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var names: [String] {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
    func mark(_ name: String) {
      lock.lock()
      stored.append(name)
      lock.unlock()
    }
  }
}
