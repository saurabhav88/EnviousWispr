import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing
import os

/// #3544 P2: pairing today's record-key decisions with the listener's shadow decisions.
///
/// Observability Contract: this is the instrument P2's acceptance reads ("0 unexplained
/// disagreements"). When it fails, a real mapping error is filed as agreement or as an expected
/// timing gain, or lost evidence is reported as a clean session.
@Suite(.tags(.observabilityContract), .timeLimit(.minutes(1)))
struct KeyboardShadowComparatorTests {

  private static func decision(
    _ lane: ShadowRecord.Lane, _ outcome: GestureOutcome, at t: TimeInterval?,
    role: ShortcutRole? = .record, phase: KeyStateTracker.Phase = .press, generation: UInt64 = 1,
    afterStop: Int? = nil, attemptStart: TimeInterval? = nil, marker: TimeInterval? = nil,
    handled: TimeInterval? = nil, ambiguous: Bool = false
  ) -> ShadowRecord {
    ShadowRecord(
      lane: lane, generation: generation, sequence: 0, category: .decision, keyCode: 61,
      role: role, phase: phase, outcome: .gesture(outcome), rawOccurred: nil,
      acceptedOccurred: t, handled: handled ?? (t ?? 0) + 0.01, attemptStartOccurred: attemptStart,
      afterStopTimerMs: afterStop, markerOrigin: marker, ambiguous: ambiguous)
  }

  /// Both halves of one #3534 race on the attempt whose first press was at 10.
  /// Both halves of one #3534 race on the attempt whose first press was at 10: live's stop is
  /// requested at 10.625 and live handles the second press (which happened at 10.25) at 10.8.
  private static func race(
    role: ShortcutRole? = .record, marker: TimeInterval = 10, stoppedAt: TimeInterval? = 10.625,
    afterStop: Int = 250, second: TimeInterval = 10.25, liveHandled: TimeInterval = 10.8
  ) -> [ShadowRecord] {
    [
      timer(.live, .loneTapStop, release: 10.125, first: 10, deadline: 10.625, stoppedAt: stoppedAt),
      timer(.shadow, .loneTapCancelled, release: 10.125, first: 10, deadline: 10.625),
      decision(
        .live, .start, at: second, role: role, afterStop: afterStop, marker: marker,
        handled: liveHandled),
      decision(.shadow, .lockIntent, at: second, attemptStart: 10),
    ]
  }

  /// Every verdict `records` produce, plus the flush.
  private static func run(_ records: [ShadowRecord]) -> [String] {
    let comparator = KeyboardShadowComparator()
    var kinds: [String] = []
    for record in records { kinds += comparator.add(record).map(kind) }
    return kinds + comparator.flush().map(kind)
  }

  private static func timer(
    _ lane: ShadowRecord.Lane, _ outcome: GestureOutcome, release: TimeInterval,
    first: TimeInterval, deadline: TimeInterval, stoppedAt: TimeInterval? = nil
  ) -> ShadowRecord {
    ShadowRecord(
      lane: lane, generation: 1, sequence: 0, category: .timer, keyCode: 61, role: .record,
      phase: nil, outcome: .gesture(outcome), rawOccurred: nil, acceptedOccurred: release,
      handled: release, attemptStartOccurred: first, deadline: deadline,
      stopRequestedAt: stoppedAt)
  }

  private static func kind(_ c: ShadowComparison) -> String {
    switch c {
    case .agreement: "agreement"
    case .expectedTiming: "expectedTiming"
    case .mappingError: "mappingError"
    case .ambiguity: "ambiguity"
    case .incomplete: "incomplete"
    }
  }

  @Test("equal decisions agree whichever lane arrives first")
  func agreementInEitherOrder() {
    for liveFirst in [true, false] {
      let comparator = KeyboardShadowComparator()
      let live = Self.decision(.live, .start, at: 10)
      let shadow = Self.decision(.shadow, .start, at: 10)
      let first = comparator.add(liveFirst ? live : shadow)
      let second = comparator.add(liveFirst ? shadow : live)
      #expect(first.isEmpty)
      #expect(second.map(Self.kind) == ["agreement"])
      #expect(comparator.flush().isEmpty)
    }
  }

  @Test("a different role for the same physical event is a mapping error")
  func roleMismatchIsMappingError() {
    let comparator = KeyboardShadowComparator()
    _ = comparator.add(Self.decision(.live, .start, at: 10))
    let result = comparator.add(Self.decision(.shadow, .start, at: 10, role: .cancel))
    #expect(result.map(Self.kind) == ["mappingError"])
  }

  @Test("a different outcome in the same attempt with no race is a mapping error")
  func outcomeMismatchInOneAttempt() {
    let comparator = KeyboardShadowComparator()
    _ = comparator.add(Self.decision(.live, .quickRelease, at: 10.1, phase: .release, attemptStart: 10))
    let result = comparator.add(
      Self.decision(.shadow, .holdStop, at: 10.1, phase: .release, attemptStart: 10))
    #expect(result.map(Self.kind) == ["mappingError"])
  }

  @Test("lanes in different attempts with no proven race are held, then reported incomplete")
  func unexplainedDifferentAttemptsAreIncomplete() {
    #expect(
      Self.run([
        Self.decision(.live, .start, at: 10.25),
        Self.decision(.shadow, .lockIntent, at: 10.25, attemptStart: 10),
      ]) == ["incomplete"])
  }

  @Test("a press half alone is held, then reported unproven, never approved")
  func pressHalfAloneIsUnproven() {
    let comparator = KeyboardShadowComparator()
    _ = comparator.add(
      Self.decision(.live, .start, at: 10.25, afterStop: 250, marker: 10, handled: 10.8))
    let result = comparator.add(
      Self.decision(.shadow, .lockIntent, at: 10.25, attemptStart: 10))
    #expect(result.isEmpty)
    #expect(
      comparator.flush() == [
        .incomplete(.init(reason: .flush, liveUnmatched: 0, shadowUnmatched: 0, unprovenTiming: 1))
      ])
  }

  @Test("a stop marker from another first press is not proof")
  func unrelatedMarkerIsRejected() {
    #expect(Self.run(Self.race(marker: 9)) == ["incomplete"])
  }

  @Test("the same race under another role is a mapping error")
  func roleMismatchInARaceIsMappingError() {
    #expect(Self.run(Self.race(role: .cancel)) == ["mappingError", "incomplete"])
  }

  @Test("a timer whose deadline does not follow its own release is not proof")
  func deadlineFormulaIsChecked() {
    let comparator = KeyboardShadowComparator()
    _ = comparator.add(Self.timer(.live, .loneTapStop, release: 10.125, first: 10, deadline: 10.75))
    let result = comparator.add(
      Self.timer(.shadow, .loneTapCancelled, release: 10.125, first: 10, deadline: 10.625))
    #expect(result.map(Self.kind) == ["mappingError"])
  }

  @Test("a race, the release that follows it and a newer fresh start classify the same in every arrival order")
  func lineageIsOrderIndependent() {
    let race = Self.race()
    let pairs: [[ShadowRecord]] = [
      Array(race[0...1]),  // timer half
      Array(race[2...3]),  // press half
      [
        // Live is in the attempt the second press began; the shadow is still locked in the first.
        Self.decision(.live, .quickRelease, at: 10.375, phase: .release, attemptStart: 10.25),
        Self.decision(.shadow, .releaseSuppressedLocked, at: 10.375, phase: .release, attemptStart: 10),
      ],
      [Self.decision(.live, .start, at: 12), Self.decision(.shadow, .start, at: 12)],
    ]
    func permutations(_ items: [Int]) -> [[Int]] {
      guard items.count > 1 else { return [items] }
      return items.indices.flatMap { i -> [[Int]] in
        var rest = items
        let head = rest.remove(at: i)
        return permutations(rest).map { [head] + $0 }
      }
    }
    for order in permutations([0, 1, 2, 3]) {
      let kinds = Self.run(order.flatMap { pairs[$0] }).sorted()
      #expect(kinds == ["agreement", "ambiguity", "expectedTiming", "expectedTiming"], "\(order)")
    }
  }

  @Test("a different-attempt pair outside any proven lineage is never excused")
  func unrelatedLineageIsNotExcused() {
    var records = Self.race()
    records += [
      Self.decision(.live, .quickRelease, at: 20.1, phase: .release, attemptStart: 20),
      Self.decision(.shadow, .holdStop, at: 20.1, phase: .release, attemptStart: 19.9),
    ]
    #expect(Self.run(records) == ["expectedTiming", "expectedTiming", "incomplete"])
  }

  @Test("proven lineages beyond the bound are evicted and reported")
  func lineageBound() {
    let comparator = KeyboardShadowComparator()
    var overflowed = 0
    var sequence: UInt64 = 0
    for g in 0...UInt64(KeyboardShadowComparator.pendingLimit) {
      for record in Self.race() {
        sequence += 1
        let r = ShadowRecord(
          lane: record.lane, generation: g + 1, sequence: sequence, category: record.category,
          keyCode: record.keyCode, role: record.role, phase: record.phase, outcome: record.outcome,
          rawOccurred: nil, acceptedOccurred: record.acceptedOccurred, handled: record.handled,
          attemptStartOccurred: record.attemptStartOccurred,
          afterStopTimerMs: record.afterStopTimerMs, deadline: record.deadline,
          markerOrigin: record.markerOrigin, stopRequestedAt: record.stopRequestedAt)
        overflowed += comparator.add(r).filter { Self.kind($0) == "incomplete" }.count
      }
    }
    #expect(overflowed == 1)
  }

  @Test(
    "the joined race evidence is checked: missing stop time, stop after handling, wrong elapsed, outside the window"
  )
  func joinedEvidenceControls() {
    #expect(Self.run(Self.race()) == ["expectedTiming", "expectedTiming"])
    #expect(Self.run(Self.race(stoppedAt: nil)) == ["incomplete"])
    #expect(Self.run(Self.race(liveHandled: 10.5)) == ["incomplete"])
    #expect(Self.run(Self.race(afterStop: 200)) == ["incomplete"])
    #expect(Self.run(Self.race(afterStop: 600, second: 10.6, liveHandled: 10.9)) == ["incomplete"])
  }

  @Test("the timer side of the race waits for the press proof, in either order")
  func timerSideWaitsForProof() {
    for timerFirst in [true, false] {
      let comparator = KeyboardShadowComparator()
      let liveTimer = Self.timer(
        .live, .loneTapStop, release: 10.125, first: 10, deadline: 10.625, stoppedAt: 10.625)
      let shadowTimer = Self.timer(
        .shadow, .loneTapCancelled, release: 10.125, first: 10, deadline: 10.625)
      let livePress = Self.decision(
        .live, .start, at: 10.25, afterStop: 250, marker: 10, handled: 10.8)
      let shadowPress = Self.decision(.shadow, .lockIntent, at: 10.25, attemptStart: 10)
      var kinds: [String] = []
      let order =
        timerFirst
        ? [liveTimer, shadowTimer, livePress, shadowPress]
        : [livePress, shadowPress, liveTimer, shadowTimer]
      for record in order { kinds += comparator.add(record).map(Self.kind) }
      #expect(kinds == ["expectedTiming", "expectedTiming"])
      #expect(comparator.flush().isEmpty)
    }
  }

  @Test("a timer difference never proven is reported incomplete, not approved")
  func unprovenTimerIsIncomplete() {
    let comparator = KeyboardShadowComparator()
    _ = comparator.add(
      Self.timer(.live, .loneTapStop, release: 10.125, first: 10, deadline: 10.625))
    let pending = comparator.add(
      Self.timer(.shadow, .loneTapCancelled, release: 10.125, first: 10, deadline: 10.625))
    #expect(pending.isEmpty)
    let flushed = comparator.flush()
    #expect(
      flushed == [
        .incomplete(.init(reason: .flush, liveUnmatched: 0, shadowUnmatched: 0, unprovenTiming: 1))
      ])
  }

  @Test("a record with no occurrence time cannot be paired")
  func missingIdentityIsAmbiguity() {
    let comparator = KeyboardShadowComparator()
    #expect(comparator.add(Self.decision(.live, .start, at: nil)).map(Self.kind) == ["ambiguity"])
  }

  @Test("two candidates for one event are ambiguity, never a nearest guess")
  func competingCounterpartsAreAmbiguity() {
    let comparator = KeyboardShadowComparator()
    _ = comparator.add(Self.decision(.shadow, .start, at: 10))
    let result = comparator.add(Self.decision(.shadow, .start, at: 10))
    #expect(result.map(Self.kind) == ["ambiguity"])
    #expect(comparator.flush().isEmpty)
  }

  @Test("an aggregate-only uncertain key is ambiguity even when the outcomes match")
  func uncertainKeyStateIsAmbiguity() {
    let comparator = KeyboardShadowComparator()
    _ = comparator.add(Self.decision(.live, .start, at: 10))
    let result = comparator.add(Self.decision(.shadow, .start, at: 10, ambiguous: true))
    #expect(result.map(Self.kind) == ["ambiguity"])
  }

  @Test("records under different configurations never pair and are flushed as incomplete")
  func generationMismatchIsIncomplete() {
    let comparator = KeyboardShadowComparator()
    #expect(comparator.add(Self.decision(.live, .start, at: 10, generation: 1)).isEmpty)
    #expect(comparator.add(Self.decision(.shadow, .start, at: 10, generation: 2)).isEmpty)
    #expect(
      comparator.flush() == [
        .incomplete(.init(reason: .flush, liveUnmatched: 1, shadowUnmatched: 1, unprovenTiming: 0))
      ])
  }

  @Test("the 257th unmatched record evicts the oldest and says so")
  func overflowIsReported() {
    let comparator = KeyboardShadowComparator()
    var results: [ShadowComparison] = []
    for i in 0...KeyboardShadowComparator.pendingLimit {
      results += comparator.add(Self.decision(.live, .start, at: 10 + Double(i)))
    }
    #expect(
      results == [
        .incomplete(
          .init(reason: .overflow, liveUnmatched: 1, shadowUnmatched: 0, unprovenTiming: 0))
      ])
  }

  @Test("execution records are live-only and never paired")
  func executionRecordsAreNotPaired() {
    let comparator = KeyboardShadowComparator()
    let execution = ShadowRecord(
      lane: .live, generation: 1, sequence: 0, category: .execution, keyCode: 61, role: .record,
      phase: .press, outcome: .noDecision, rawOccurred: nil, acceptedOccurred: 10, handled: 10)
    #expect(comparator.add(execution).isEmpty)
    #expect(comparator.flush().isEmpty)
  }

  /// `records` with lane-local producer sequences 1, 2, ... in the given order.
  private static func sequenced(_ records: [ShadowRecord]) -> [ShadowRecord] {
    var next: [ShadowRecord.Lane: UInt64] = [:]
    return records.map { r in
      let seq = (next[r.lane] ?? 0) + 1
      next[r.lane] = seq
      return ShadowRecord(
        lane: r.lane, generation: r.generation, sequence: seq, category: r.category,
        keyCode: r.keyCode, role: r.role, phase: r.phase, outcome: r.outcome,
        rawOccurred: r.rawOccurred, acceptedOccurred: r.acceptedOccurred, handled: r.handled,
        attemptStartOccurred: r.attemptStartOccurred, afterStopTimerMs: r.afterStopTimerMs,
        deadline: r.deadline, markerOrigin: r.markerOrigin, stopRequestedAt: r.stopRequestedAt,
        evidence: r.evidence, ambiguous: r.ambiguous)
    }
  }

  @Test("duplicates arriving after pairing cannot become another agreement")
  func lateDuplicateIdentityIsAmbiguity() {
    let records = [
      Self.decision(.live, .start, at: 10),
      Self.decision(.shadow, .start, at: 10),
      Self.decision(.live, .start, at: 10),
      Self.decision(.shadow, .start, at: 10),
    ]
    let kinds = Self.run(records)
    #expect(kinds.contains("ambiguity"))
    #expect(kinds.filter { $0 == "agreement" }.count == 1)
  }

  @Test("two records per lane for one identity never yield more than one agreement, in any order")
  func duplicateIdentityPermutations() {
    let records = [
      Self.decision(.live, .start, at: 10), Self.decision(.live, .start, at: 10),
      Self.decision(.shadow, .start, at: 10), Self.decision(.shadow, .start, at: 10),
    ]
    func permutations(_ items: [Int]) -> [[Int]] {
      guard items.count > 1 else { return [items] }
      return items.indices.flatMap { i -> [[Int]] in
        var rest = items
        let head = rest.remove(at: i)
        return permutations(rest).map { [head] + $0 }
      }
    }
    for order in permutations([0, 1, 2, 3]) {
      let kinds = Self.run(order.map { records[$0] })
      #expect(kinds.contains("ambiguity"), "\(order)")
      #expect(kinds.filter { $0 == "agreement" }.count <= 1, "\(order)")
      #expect(kinds.contains("expectedTiming") == false, "\(order)")
      #expect(kinds.contains("mappingError") == false, "\(order)")
    }
  }

  @Test("a duplicate of a held race half is ambiguity and leaves the race unproven")
  func duplicateOfHeldRaceHalf() {
    let race = Self.race()
    let kinds = Self.run([race[0], race[1], race[0]])
    #expect(kinds == ["ambiguity", "incomplete"])
  }

  @Test("a record older than the retained identity history fails closed")
  func recordOlderThanHistoryFailsClosed() {
    let comparator = KeyboardShadowComparator()
    var pairs: [ShadowRecord] = []
    for i in 0...KeyboardShadowComparator.pendingLimit {
      pairs += [
        Self.decision(.live, .start, at: 10 + Double(i)),
        Self.decision(.shadow, .start, at: 10 + Double(i)),
      ]
    }
    for record in Self.sequenced(pairs) { _ = comparator.add(record) }
    let late = ShadowRecord(
      lane: .live, generation: 1, sequence: 1, category: .decision, keyCode: 61, role: .record,
      phase: .press, outcome: .gesture(.start), rawOccurred: nil, acceptedOccurred: 10,
      handled: 10.01)
    #expect(
      comparator.add(late) == [
        .incomplete(.init(reason: .outsideHistory, liveUnmatched: 1, shadowUnmatched: 0, unprovenTiming: 0))
      ])
  }

  #if DEBUG
    @Test("the live engine's real decisions and the shadow's agree on a calm double tap")
    func liveEngineAndShadowAgree() {
      let comparator = KeyboardShadowComparator()
      let verdicts = OSAllocatedUnfairLock<[ShadowComparison]>(initialState: [])
      let clock = HotkeyTestClock(500)
      let timers = HotkeyTestScheduler(clock: clock)
      let engine = RecordGestureEngine(
        binding: .keyboard(keyCode: ModifierKeyCodes.rightOption, modifiers: []),
        mode: .pushToTalk, clock: clock.uptime, scheduler: timers.scheduler)
      engine.setObservationGeneration(1)
      engine.setObserver { observation in
        let record = ShadowRecord(lane: .live, role: .record, observation: observation)
        let result = comparator.add(record)
        verdicts.withLock { $0 += result }
      }
      let shadow = ShadowKeyboardPolicy(
        snapshot: .init(
          generation: 1, bindings: .shipped, mode: .pushToTalk, enabled: true, suspended: false,
          armed: [.record], available: []),
        clock: clock.uptime, scheduler: timers.scheduler,
        emit: { record in
          // Live ingress capture arrives with HotkeyService wiring (chunk 6); compare decisions.
          guard record.category != .ingress else { return }
          let result = comparator.add(record)
          verdicts.withLock { $0 += result }
        })
      for (isPress, t) in [(true, 0.0), (false, 0.125), (true, 0.25), (false, 0.375)] {
        clock.now = 500 + t
        let input = RecordGesture.InputTime.accepting(stamp: 500 + t, handled: 500 + t)
        engine.ingest(isPress: isPress, input: input)
        shadow.ingest(
          KeyEventValue(
            kind: .flagsChanged, keyCode: 61, rawFlags: isPress ? 0x80040 : 0, timestamp: 500 + t),
          handled: 500 + t)
      }
      let kinds = verdicts.withLock { $0 }.map(Self.kind)
      // start, quickRelease, lockIntent, loneTapCancelled, releaseSuppressedLocked
      #expect(kinds == Array(repeating: "agreement", count: 5))
      #expect(comparator.flush().isEmpty)
    }

    @Test("a real live engine that handled the second press late proves the race on both halves")
    func liveEngineRaceIsExpectedTiming() {
      let comparator = KeyboardShadowComparator()
      let verdicts = OSAllocatedUnfairLock<[ShadowComparison]>(initialState: [])
      let clock = HotkeyTestClock(500)
      let liveTimers = HotkeyTestScheduler(clock: clock)
      let shadowTimers = HotkeyTestScheduler(clock: clock)
      let engine = RecordGestureEngine(
        binding: .keyboard(keyCode: ModifierKeyCodes.rightOption, modifiers: []),
        mode: .pushToTalk, clock: clock.uptime, scheduler: liveTimers.scheduler)
      engine.setObservationGeneration(1)
      engine.setObserver { o in
        let result = comparator.add(ShadowRecord(lane: .live, role: .record, observation: o))
        verdicts.withLock { $0 += result }
      }
      let shadow = ShadowKeyboardPolicy(
        snapshot: .init(
          generation: 1, bindings: .shipped, mode: .pushToTalk, enabled: true, suspended: false,
          armed: [.record], available: []),
        clock: clock.uptime, scheduler: shadowTimers.scheduler,
        emit: { record in
          guard record.category != .ingress else { return }
          let result = comparator.add(record)
          verdicts.withLock { $0 += result }
        })
      func shadowKey(_ isPress: Bool, _ t: TimeInterval) {
        clock.now = 500 + t
        shadow.ingest(
          KeyEventValue(
            kind: .flagsChanged, keyCode: 61, rawFlags: isPress ? 0x80040 : 0, timestamp: 500 + t),
          handled: 500 + t)
      }
      func live(_ isPress: Bool, occurred: TimeInterval, handled: TimeInterval) {
        clock.now = 500 + handled
        engine.ingest(
          isPress: isPress,
          input: .accepting(stamp: 500 + occurred, handled: 500 + handled))
      }
      // The listener hears everything on time.
      shadowKey(true, 0)
      shadowKey(false, 0.125)
      shadowKey(true, 0.25)
      // Today's path: the second press waits behind a busy main thread until after the stop.
      live(true, occurred: 0, handled: 0)
      live(false, occurred: 0.125, handled: 0.125)
      clock.now = 500.625
      liveTimers.fireDue()
      live(true, occurred: 0.25, handled: 0.8)
      let kinds = verdicts.withLock { $0 }.map(Self.kind)
      #expect(kinds == ["agreement", "agreement", "expectedTiming", "expectedTiming"])
      #expect(comparator.flush().isEmpty)
    }
  #endif
}
