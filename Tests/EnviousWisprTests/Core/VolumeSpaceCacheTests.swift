import EnviousWisprCore
import Foundation
import Testing
import os

@Suite(.tags(.productOutcome))
struct VolumeSpaceCacheTests {
  #if DEBUG
    private final class PublishSignal: Sendable {
      private struct Waiter {
        let id: UUID
        let predicate: @Sendable (String, UInt64) -> Bool
        let continuation: CheckedContinuation<Void, Never>
      }
      private struct State {
        var events: [(String, UInt64)] = []
        var waiters: [Waiter] = []
        var timedOutIDs: Set<UUID> = []
      }
      private let lock = OSAllocatedUnfairLock(initialState: State())

      init(on cache: VolumeSpaceCache) {
        cache.installPublishHookForTesting { [self] path, gen in
          let ready: [CheckedContinuation<Void, Never>] = lock.withLock { s in
            s.events.append((path, gen))
            var matched: [CheckedContinuation<Void, Never>] = []
            s.waiters.removeAll { w in
              if w.predicate(path, gen) {
                matched.append(w.continuation)
                return true
              }
              return false
            }
            return matched
          }
          for c in ready { c.resume() }
        }
      }

      func awaitMatch(
        label: String, timeout: Duration = .seconds(5),
        where predicate: @escaping @Sendable (String, UInt64) -> Bool
      ) async {
        let id = UUID()
        let timeoutTask = Task {
          try? await Task.sleep(for: timeout)
          let (timedOut, shouldRecord) = lock.withLock { s -> (CheckedContinuation<Void, Never>?, Bool) in
            if let idx = s.waiters.firstIndex(where: { $0.id == id }) {
              return (s.waiters.remove(at: idx).continuation, true)
            }
            if !s.events.contains(where: predicate) { s.timedOutIDs.insert(id) }
            return (nil, false)
          }
          if shouldRecord, let timedOut {
            Issue.record("VolumeSpaceCache publish timed out: \(label)")
            timedOut.resume()
          }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
          enum Disposition { case matched, timedOut, parked }
          let disposition = lock.withLock { s -> Disposition in
            if s.timedOutIDs.remove(id) != nil { return .timedOut }
            if s.events.contains(where: predicate) { return .matched }
            s.waiters.append(Waiter(id: id, predicate: predicate, continuation: c))
            return .parked
          }
          switch disposition {
          case .matched: c.resume()
          case .timedOut:
            Issue.record("VolumeSpaceCache publish timed out: \(label)")
            c.resume()
          case .parked: break
          }
        }
        timeoutTask.cancel()
      }
    }
  #endif

  @Test("fresh plain space covering need returns plain and never calls importantUsage reader")
  func plainEnoughSkipsImportantReader() {
    let importantCalls = OSAllocatedUnfairLock(initialState: 0)
    let cache = VolumeSpaceCache(
      readPlain: { _ in 2_000 },
      readImportant: { _ in
        importantCalls.withLock { $0 += 1 }
        return 100
      })

    #expect(cache.availableBytes(at: "/tmp", neededBytes: 1_500) == 2_000)
    #expect(importantCalls.withLock { $0 } == 0)
  }

  #if DEBUG
    @Test("stale lower generation is treated as unknown until requested generation completes")
    func minGenerationIgnoresEarlierCachedAnswer() async {
      let gate = DispatchSemaphore(value: 0)
      defer { gate.signal(); gate.signal() }
      let values = OSAllocatedUnfairLock(initialState: [Int64(100), Int64(5_000)])
      let cache = VolumeSpaceCache(
        readPlain: { _ in 50 },
        readImportant: { _ in
          gate.wait()
          return values.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        })
      let signal = PublishSignal(on: cache)

      let gen1 = cache.requestRefresh(at: "/a")
      gate.signal()
      await signal.awaitMatch(label: "gen1") { $0 == "/a" && $1 >= gen1 }
      #expect(cache.availableBytes(at: "/a", neededBytes: 1_000, minGeneration: gen1) == 100)

      let gen2 = cache.requestRefresh(at: "/a")
      #expect(cache.availableBytes(at: "/a", neededBytes: 1_000, minGeneration: gen2) == nil)
      gate.signal()
      await signal.awaitMatch(label: "gen2") { $0 == "/a" && $1 >= gen2 }
      #expect(cache.availableBytes(at: "/a", neededBytes: 1_000, minGeneration: gen2) == 5_000)
    }

    @Test("mid-flight supersede re-reads at back of queue so another path gets a turn")
    func midFlightSupersedeInterleavesFairlyAcrossPaths() async {
      let releaseFirst = DispatchSemaphore(value: 0)
      defer { releaseFirst.signal() }
      let (enteredStream, enteredCont) = AsyncStream.makeStream(of: Void.self)
      var enteredIter = enteredStream.makeAsyncIterator()
      let order = OSAllocatedUnfairLock(initialState: [String]())
      let aReads = OSAllocatedUnfairLock(initialState: 0)

      let cache = VolumeSpaceCache(
        readPlain: { _ in 10 },
        readImportant: { path in
          order.withLock { $0.append(path) }
          if path == "/a" {
            let n = aReads.withLock { s in s += 1; return s }
            if n == 1 {
              enteredCont.yield()
              releaseFirst.wait()
              return 111
            }
            return 222
          }
          return 333
        })
      let signal = PublishSignal(on: cache)

      _ = cache.requestRefresh(at: "/a")
      let enterGuard = Task {
        try? await Task.sleep(for: .seconds(5))
        enteredCont.finish()
      }
      let enteredOk = await enteredIter.next() != nil
      enterGuard.cancel()
      #expect(enteredOk, "first readImportant(/a) never entered")

      let genA2 = cache.requestRefresh(at: "/a")
      let genB = cache.requestRefresh(at: "/b")
      releaseFirst.signal()

      await signal.awaitMatch(label: "genA2") { $0 == "/a" && $1 >= genA2 }
      await signal.awaitMatch(label: "genB") { $0 == "/b" && $1 >= genB }

      #expect(order.withLock { $0 } == ["/a", "/b", "/a"])
      #expect(cache.importantBytes(at: "/a", minGeneration: genA2) == 222)
      #expect(cache.importantBytes(at: "/b", minGeneration: genB) == 333)
    }
  #endif

  @Test("hung importantUsage reader never blocks caller or queues duplicate closures")
  func hungReaderDoesNotBlockOrPileUp() async {
    let (enteredStream, enteredCont) = AsyncStream.makeStream(of: Void.self)
    var enteredIter = enteredStream.makeAsyncIterator()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let calls = OSAllocatedUnfairLock(initialState: 0)

    let cache = VolumeSpaceCache(
      readPlain: { _ in 10 },
      readImportant: { _ in
        let n = calls.withLock { s in s += 1; return s }
        if n == 1 {
          enteredCont.yield()
          release.wait()
        }
        return 999
      })

    let gen1 = cache.requestRefresh(at: "/hung")
    let timeoutTask = Task {
      try? await Task.sleep(for: .seconds(5))
      enteredCont.finish()
    }
    let enteredOk = await enteredIter.next() != nil
    timeoutTask.cancel()
    #expect(enteredOk, "hung worker never entered readImportant")

    let gen2 = cache.requestRefresh(at: "/hung")
    let gen3 = cache.requestRefresh(at: "/hung")

    #expect(gen3 > gen2 && gen2 > gen1)
    #expect(cache.importantBytes(at: "/hung", minGeneration: gen1) == nil)
    #expect(cache.availableBytes(at: "/hung", neededBytes: 1_000, minGeneration: gen3) == nil)
    #expect(calls.withLock { $0 } == 1)
  }
}
