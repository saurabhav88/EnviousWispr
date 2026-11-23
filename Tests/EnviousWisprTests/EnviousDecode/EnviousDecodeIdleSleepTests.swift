import Testing

@testable import EnviousDecodeKit

/// #3853: when the polish helper frees its models. Pure rule, tested with a made-up clock.
///
/// When this fails, a user who chose "unload polish model after" gets a helper that never frees
/// its memory, frees it while a request is using it, or frees it because a health check or a
/// refused request counted as use.
@Suite("EnviousDecode idle sleep rule (#3853)", .tags(.productOutcome))
struct EnviousDecodeIdleSleepTests {
  static let second: UInt64 = 1_000_000_000

  @Test("never: no idle time means the helper never sleeps")
  func neverSleeps() {
    for idle in [nil, 0, -5] as [Int?] {
      let rule = EnviousDecodeIdleSleep(idleSeconds: idle, startedAt: 0)
      #expect(rule.idleNanoseconds == nil)
      #expect(!rule.shouldSleep(at: 10_000 * Self.second, modelsLoaded: true, isLoading: false))
    }
  }

  @Test("sleeps exactly when the whole idle time has passed since the last use")
  func sleepsAfterIdleTime() {
    var rule = EnviousDecodeIdleSleep(idleSeconds: 10, startedAt: 100 * Self.second)
    #expect(!rule.shouldSleep(at: 109 * Self.second, modelsLoaded: true, isLoading: false))
    #expect(rule.shouldSleep(at: 110 * Self.second, modelsLoaded: true, isLoading: false))
    // A request ending at 105 s moves the deadline to 115 s.
    rule.noteUse(at: 105 * Self.second)
    #expect(!rule.shouldSleep(at: 114 * Self.second, modelsLoaded: true, isLoading: false))
    #expect(rule.shouldSleep(at: 115 * Self.second, modelsLoaded: true, isLoading: false))
  }

  @Test("no sleep while models are not loaded or are loading")
  func notWhileUnloadedOrLoading() {
    let rule = EnviousDecodeIdleSleep(idleSeconds: 1, startedAt: 0)
    #expect(!rule.shouldSleep(at: 100 * Self.second, modelsLoaded: false, isLoading: false))
    #expect(!rule.shouldSleep(at: 100 * Self.second, modelsLoaded: true, isLoading: true))
  }

  @Test("an older use never moves the clock back, and a backwards clock is not idle")
  func clockEdges() {
    var rule = EnviousDecodeIdleSleep(idleSeconds: 5, startedAt: 50 * Self.second)
    rule.noteUse(at: 20 * Self.second)
    #expect(!rule.shouldSleep(at: 54 * Self.second, modelsLoaded: true, isLoading: false))
    #expect(rule.shouldSleep(at: 55 * Self.second, modelsLoaded: true, isLoading: false))
    #expect(!rule.shouldSleep(at: 10 * Self.second, modelsLoaded: true, isLoading: false))
  }

  @Test("repeated sleep and wake cycles each wait a full idle time")
  func repeatedCycles() {
    var rule = EnviousDecodeIdleSleep(idleSeconds: 3, startedAt: 0)
    var now: UInt64 = 0
    for _ in 0..<5 {
      now += 3 * Self.second
      #expect(rule.shouldSleep(at: now, modelsLoaded: true, isLoading: false))
      // It sleeps; a request wakes it and finishes one second later.
      now += Self.second
      rule.noteUse(at: now)
      #expect(!rule.shouldSleep(at: now + 2 * Self.second, modelsLoaded: true, isLoading: false))
    }
  }
}
