#if DEBUG
  import Foundation
  import Testing

  @testable import EnviousWisprAppKit

  /// #4254 runtime checkpoint: when these fail, Quit in a debug build can hang, quit twice,
  /// skip the quit owner's own wait, or leave the checkpoint without its quit witness line.
  @MainActor
  @Suite("Quit witness gate", .serialized, .timeLimit(.minutes(1)), .tags(.harnessContract))
  struct QuitWitnessGateTests {
    enum Event: Equatable {
      case wrote(String)
      case forwarded
      case replied(Bool)
    }

    /// Every gate effect in order, read by awaiting the next one; the suite time limit bounds a missing one.
    final class Events {
      private let stream: AsyncStream<Event>
      private let continuation: AsyncStream<Event>.Continuation
      private var iterator: AsyncStream<Event>.AsyncIterator

      init() {
        (stream, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        iterator = stream.makeAsyncIterator()
      }

      func send(_ event: Event) { continuation.yield(event) }

      /// The next effect. A missing one hangs only until the suite's time limit.
      func next() async throws -> Event {
        guard let event = await iterator.next() else {
          Issue.record("the event stream ended")
          throw CancellationError()
        }
        return event
      }
    }

    @Test("an owner that agrees at once gets one reply after the witness is written")
    func immediateApproval() async throws {
      let events = Events()
      let gate = QuitWitnessGate(write: { events.send(.wrote($0)) })
      let answer = gate.request(
        line: "w",
        forward: { _ in
          events.send(.forwarded)
          return true
        },
        reply: { events.send(.replied($0)) })
      #expect(answer == false, "Quit is always answered later")
      #expect(try await events.next() == .wrote("w"))
      #expect(try await events.next() == .forwarded)
      #expect(try await events.next() == .replied(true))
    }

    @Test("an owner that answers later keeps the reply; the gate does not reply for it")
    func deferredApproval() async throws {
      let events = Events()
      var held: QuitWitnessGate.Reply?
      let gate = QuitWitnessGate(write: { events.send(.wrote($0)) })
      _ = gate.request(
        line: "w",
        forward: { reply in
          held = reply
          events.send(.forwarded)
          return false
        },
        reply: { events.send(.replied($0)) })
      #expect(try await events.next() == .wrote("w"))
      #expect(try await events.next() == .forwarded)
      let reply = try #require(held)
      reply(true)
      #expect(try await events.next() == .replied(true), "only the owner's reply arrives")
    }

    @Test("a denied Quit does not block the next Quit")
    func deniedThenAgain() async throws {
      let events = Events()
      var held: QuitWitnessGate.Reply?
      let gate = QuitWitnessGate(write: { events.send(.wrote($0)) })
      let forward: @MainActor (@escaping QuitWitnessGate.Reply) -> Bool = { reply in
        held = reply
        events.send(.forwarded)
        return false
      }
      _ = gate.request(line: "1", forward: forward, reply: { events.send(.replied($0)) })
      #expect(try await events.next() == .wrote("1"))
      #expect(try await events.next() == .forwarded)
      let deny = try #require(held)
      deny(false)
      #expect(try await events.next() == .replied(false))
      _ = gate.request(line: "2", forward: forward, reply: { events.send(.replied($0)) })
      #expect(try await events.next() == .wrote("2"))
      #expect(try await events.next() == .forwarded, "the second Quit reaches the owner")
    }

    @Test("a Quit while the witness is still being written is not forwarded again")
    func repeatedWhileWriting() async throws {
      let events = Events()
      var release: CheckedContinuation<Void, Never>?
      let gate = QuitWitnessGate(write: { line in
        events.send(.wrote(line))
        await withCheckedContinuation { release = $0 }
      })
      var forwards = 0
      let forward: @MainActor (@escaping QuitWitnessGate.Reply) -> Bool = { _ in
        forwards += 1
        events.send(.forwarded)
        return true
      }
      _ = gate.request(line: "1", forward: forward, reply: { events.send(.replied($0)) })
      #expect(try await events.next() == .wrote("1"))
      let second = gate.request(line: "2", forward: forward, reply: { events.send(.replied($0)) })
      #expect(second == false)
      let resume = try #require(release)
      resume.resume()
      #expect(try await events.next() == .forwarded)
      #expect(try await events.next() == .replied(true))
      #expect(forwards == 1, "one forward for two Quits during one write")
    }
  }
#endif
