#if DEBUG
  import Testing

  @testable import EnviousWisprAudio

  /// #1317 proof-bench: the all-zero injector's zero-range math, especially boundary
  /// chunks where only part of a chunk is zeroed (so the caller recomputes level
  /// instead of reporting a false 0.0).
  @Suite("DebugZeroFillController")
  struct DebugZeroFillControllerTests {

    @Test("not armed → never zeroes")
    func notArmed() {
      let c = DebugZeroFillController()
      #expect(c.zeroRange(count: 640, context: .live) == nil)
      #expect(c.zeroRange(count: 640, context: .preRollDrain) == nil)
      #expect(c.zeroesPreRoll == false)
      #expect(c.status().hit == false)
    }

    @Test("zero_from_start zeroes live AND pre-roll, whole chunk")
    func zeroFromStart() {
      let c = DebugZeroFillController()
      c.arm(mode: .zeroFromStart, trialID: "t1")
      #expect(c.zeroesPreRoll == true)
      #expect(c.zeroRange(count: 640, context: .preRollDrain) == 0..<640)
      #expect(c.zeroRange(count: 640, context: .live) == 0..<640)
      let s = c.status()
      #expect(s.hit == true)
      #expect(s.trialID == "t1")
      #expect(s.mode == "zero_from_start")
      #expect(s.zeroedSampleCount == 1280)
    }

    @Test("zero_after leaves pre-roll and the leading live samples untouched")
    func zeroAfterPreRollAndLead() {
      let c = DebugZeroFillController()
      c.arm(mode: .zeroAfter(threshold: 1000), trialID: "t2")
      #expect(c.zeroesPreRoll == false)
      // pre-roll always passes through for zero_after
      #expect(c.zeroRange(count: 5000, context: .preRollDrain) == nil)
      // first 640 live (seen 0→640, < 1000) → untouched
      #expect(c.zeroRange(count: 640, context: .live) == nil)
    }

    @Test("zero_after boundary chunk zeroes only the tail past the threshold")
    func zeroAfterBoundary() {
      let c = DebugZeroFillController()
      c.arm(mode: .zeroAfter(threshold: 1000), trialID: "t3")
      _ = c.zeroRange(count: 640, context: .live)  // seen → 640
      // next chunk spans the threshold: seen 640, threshold 1000 → boundary at 360
      #expect(c.zeroRange(count: 640, context: .live) == 360..<640)
      // subsequent chunk fully past threshold → whole chunk
      #expect(c.zeroRange(count: 640, context: .live) == 0..<640)
      #expect(c.status().zeroedSampleCount == (640 - 360) + 640)
    }

    @Test("zero_next zeroes a bounded budget then restores")
    func zeroNextBounded() {
      let c = DebugZeroFillController()
      c.arm(mode: .zeroNext(budget: 800), trialID: "t4")
      // pre-roll untouched
      #expect(c.zeroRange(count: 640, context: .preRollDrain) == nil)
      // first live chunk fully within budget
      #expect(c.zeroRange(count: 640, context: .live) == 0..<640)
      // second chunk: 160 left in budget → zero [0,160), rest restored
      #expect(c.zeroRange(count: 640, context: .live) == 0..<160)
      // budget spent → restore
      #expect(c.zeroRange(count: 640, context: .live) == nil)
      #expect(c.status().zeroedSampleCount == 800)
    }

    @Test("zero-count chunk is a no-op")
    func zeroCount() {
      let c = DebugZeroFillController()
      c.arm(mode: .zeroFromStart, trialID: "t5")
      #expect(c.zeroRange(count: 0, context: .live) == nil)
    }

    @Test("negative threshold/budget never produces a negative range (no RT crash)")
    func negativeBudgetIsSafe() {
      // Bypass the upstream parser/manager guards and hand the controller a
      // negative threshold/budget directly — this is what would crash the capture
      // thread if the range math were unsafe. Assert every returned range has a
      // non-negative lower bound across several chunks.
      let after = DebugZeroFillController()
      after.arm(mode: .zeroAfter(threshold: -1), trialID: "neg1")
      for _ in 0..<4 {
        if let r = after.zeroRange(count: 640, context: .live) {
          #expect(r.lowerBound >= 0)
          #expect(r.upperBound <= 640)
        }
      }
      let next = DebugZeroFillController()
      next.arm(mode: .zeroNext(budget: -1), trialID: "neg2")
      for _ in 0..<4 {
        if let r = next.zeroRange(count: 640, context: .live) {
          #expect(r.lowerBound >= 0)
          #expect(r.upperBound <= 640)
        }
      }
    }

    @Test("disarm clears all state")
    func disarm() {
      let c = DebugZeroFillController()
      c.arm(mode: .zeroFromStart, trialID: "t6")
      _ = c.zeroRange(count: 640, context: .live)
      c.disarm()
      #expect(c.status().armed == false)
      #expect(c.status().hit == false)
      #expect(c.status().zeroedSampleCount == 0)
      #expect(c.zeroRange(count: 640, context: .live) == nil)
    }
  }
#endif
