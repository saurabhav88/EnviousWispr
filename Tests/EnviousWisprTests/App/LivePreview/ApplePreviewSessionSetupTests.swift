import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLivePreview

/// A parked framework operation. Entry is published only AFTER its release handle exists.
/// The parent waits through Core's tested deadline helper, then awaits the subject's result.
@MainActor
final class PreviewSetupGate {
  private let entries: AsyncStream<Void>
  private let entered: AsyncStream<Void>.Continuation
  private var parked: CheckedContinuation<Void, Never>?

  init() {
    (entries, entered) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  deinit { entered.finish() }

  func pause() async {
    await withCheckedContinuation { continuation in
      parked = continuation
      entered.yield(())
      entered.finish()
    }
  }

  func waitForEntry() async -> Bool {
    let stream = entries
    let result = await withDeadline(seconds: 5) {
      for await _ in stream { return true }
      return false
    }
    entered.finish()
    return result == true
  }

  func release() {
    let continuation = parked
    parked = nil
    continuation?.resume()
  }
}

@MainActor
@Suite("Apple preview setup fallback", .tags(.productOutcome))
struct ApplePreviewSessionSetupTests {
  private struct Resource: Sendable { let id: Int }
  private enum FixtureError: Error, Equatable { case attach, start }

  @MainActor
  private final class Rig {
    var events: [String] = []
    var nextID = 0
    var current = true
    var failAttach = false
    var failStart = false
    var onAttach: (() async throws -> Void)?
    var onStart: (() async throws -> Void)?

    func run(phrases: [String] = ["Hint"]) async throws -> Resource {
      try await ApplePreviewSessionSetup.start(
        phrases: phrases,
        make: {
          self.nextID += 1
          self.events.append("make\(self.nextID)")
          return Resource(id: self.nextID)
        },
        attach: { resource, phrases in
          self.events.append("attach\(resource.id):\(phrases.joined(separator: ","))")
          try await self.onAttach?()
          if self.failAttach { throw FixtureError.attach }
        },
        start: { resource in
          self.events.append("start\(resource.id)")
          try await self.onStart?()
          if self.failStart { throw FixtureError.start }
        },
        discard: { resource in self.events.append("discard\(resource.id)") },
        isCurrent: { self.current },
        contextFailed: { _ in self.events.append("contextFailed") })
    }
  }

  @Test("successful attachment starts that resource once; an empty list never attaches")
  func normalAndEmpty() async throws {
    let hinted = Rig()
    #expect(try await hinted.run().id == 1)
    #expect(hinted.events == ["make1", "attach1:Hint", "start1"])
    let empty = Rig()
    #expect(try await empty.run(phrases: []).id == 1)
    #expect(empty.events == ["make1", "start1"])
  }

  @Test("attachment failure discards the attempted resource before one fresh unhinted start")
  func freshFallback() async throws {
    let rig = Rig()
    rig.failAttach = true
    #expect(try await rig.run().id == 2)
    #expect(rig.events == ["make1", "attach1:Hint", "discard1", "contextFailed", "make2", "start2"])
  }

  @Test("a failed fallback is discarded and propagated without a third attempt")
  func fallbackFailure() async {
    let rig = Rig()
    rig.failAttach = true
    rig.failStart = true
    do {
      _ = try await rig.run()
      Issue.record("a failed native start must not return a session")
    } catch {
      #expect(error as? FixtureError == .start)
    }
    #expect(rig.events == ["make1", "attach1:Hint", "discard1", "contextFailed", "make2", "start2", "discard2"])
  }

  @Test("a framework cancellation error never becomes an unhinted fallback")
  func frameworkCancellation() async {
    let rig = Rig()
    rig.onAttach = { throw CancellationError() }
    do {
      _ = try await rig.run()
      Issue.record("framework cancellation must propagate")
    } catch {
      #expect(error is CancellationError)
    }
    #expect(rig.events == ["make1", "attach1:Hint", "discard1"])
  }

  @Test("a normal start failure is discarded without retrying attachment or startup")
  func startFailure() async {
    let rig = Rig()
    rig.failStart = true
    do {
      _ = try await rig.run()
      Issue.record("start failure must propagate")
    } catch {
      #expect(error as? FixtureError == .start)
    }
    #expect(rig.events == ["make1", "attach1:Hint", "start1", "discard1"])
  }

  @Test("cancellation at either suspension discards without fallback, and the next open succeeds",
    arguments: [true, false])
  func cancellationDiscards(duringAttach: Bool) async throws {
    let rig = Rig()
    let gate = PreviewSetupGate()
    if duringAttach { rig.onAttach = { await gate.pause() } }
    else { rig.onStart = { await gate.pause() } }
    let task = Task { try await rig.run() }
    let arrived = await gate.waitForEntry()
    task.cancel()
    gate.release()
    do {
      _ = try await task.value
      Issue.record("cancelled setup must not return a session")
    } catch {
      #expect(error is CancellationError)
    }
    #expect(arrived, "the framework operation must really have been suspended")
    let expected = duringAttach
      ? ["make1", "attach1:Hint", "discard1"]
      : ["make1", "attach1:Hint", "start1", "discard1"]
    #expect(rig.events == expected)
    rig.onAttach = nil
    rig.onStart = nil
    #expect(try await rig.run().id == 2)
    #expect(Array(rig.events.suffix(3)) == ["make2", "attach2:Hint", "start2"])
  }

  @Test("supersession during attachment discards without starting or creating a fallback")
  func supersededDuringAttachment() async {
    let rig = Rig()
    let gate = PreviewSetupGate()
    rig.onAttach = { await gate.pause() }
    let task = Task { try await rig.run() }
    let arrived = await gate.waitForEntry()
    rig.current = false
    gate.release()
    do {
      _ = try await task.value
      Issue.record("superseded setup must not return a session")
    } catch {
      if case .superseded? = error as? LivePreviewError {} else {
        Issue.record("expected superseded, received \(error)")
      }
    }
    #expect(arrived)
    #expect(rig.events == ["make1", "attach1:Hint", "discard1"])
  }

  @Test("already abandoned setup never creates native resources")
  func initiallySuperseded() async {
    let rig = Rig()
    rig.current = false
    do {
      _ = try await rig.run()
      Issue.record("superseded setup must refuse")
    } catch {
      if case .superseded? = error as? LivePreviewError {} else {
        Issue.record("expected superseded, received \(error)")
      }
    }
    #expect(rig.events.isEmpty)
  }
}
