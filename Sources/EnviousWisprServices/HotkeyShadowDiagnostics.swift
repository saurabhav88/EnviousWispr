#if DEBUG
  import EnviousWisprCore
  import Foundation
  import os

  /// The DEBUG side of #3544 P2's shadow mode (plan §3.4): one isolated `Segment` per listener
  /// installation, and the one logging channel they share.
  ///
  /// **Why a segment is a whole object.** Everything a comparison needs lives in it: the shadow
  /// policy, the handoff, the comparator, the tally and a serial worker. The listener's sink holds
  /// its own segment, so a callback from an earlier installation can only ever reach that
  /// installation's (closed) segment. The shadow policy's lone-tap timers fire on the segment's
  /// worker, the same serial queue that closes it, so no shadow record can be emitted after its
  /// segment closed. Live records go to the current segment, and a live record stamped with a
  /// generation older than the segment's first is counted, never compared. Loss (a full handoff,
  /// dropped log lines) is counted in the segment that suffered it, so no segment can look clean
  /// because of another's accounting.
  package final class HotkeyShadowDiagnostics: Sendable {

    private let current = OSAllocatedUnfairLock<Segment?>(initialState: nil)
    /// Live records made while no installation was live; reported by the next segment.
    private let outsideInstallation = OSAllocatedUnfairLock(initialState: 0)
    private let clock: RecordGestureEngine.Clock
    private let lines: AsyncStream<String>.Continuation
    private let logTask: Task<Void, Never>

    /// - Parameters:
    ///   - log: one owned consumer awaits each line before taking the next. Cancellation stops it
    ///     at the next line; it cannot interrupt a logger that ignores cancellation.
    ///   - logCapacity: lines waiting for that consumer; more are dropped and counted.
    package init(
      clock: @escaping RecordGestureEngine.Clock,
      log: @escaping @Sendable (String) async -> Void = HotkeyShadowDiagnostics.appLog,
      logCapacity: Int = 256
    ) {
      self.clock = clock
      let (stream, continuation) = AsyncStream.makeStream(
        of: String.self, bufferingPolicy: .bufferingOldest(logCapacity))
      lines = continuation
      logTask = Task {
        for await line in stream {
          guard !Task.isCancelled else { break }
          await log(line)
        }
      }
    }

    deinit {
      current.withLock { $0?.stopTimer() }
      lines.finish()
      logTask.cancel()
    }

    package static let appLog: @Sendable (String) async -> Void = { line in
      await AppLogger.shared.log(line, level: .info, category: "KeyboardShadow")
    }

    // MARK: - Segments (main)

    /// A segment for an installation about to be attempted. It compares nothing until
    /// `activate`; a failed install simply drops it.
    package func makeSegment(
      installation: UInt64, generation: UInt64, snapshot: ShadowKeyboardPolicy.Snapshot
    ) -> Segment {
      Segment(
        installation: installation, firstGeneration: generation, snapshot: snapshot,
        clock: clock, lines: lines)
    }

    /// The installation went live: `segment` receives live records from now on.
    package func activate(_ segment: Segment) {
      let previous = current.withLock { c -> Segment? in
        let previous = c
        c = segment
        return previous
      }
      previous?.close(reason: "replaced")
      let outside = outsideInstallation.withLock { n -> Int in
        defer { n = 0 }
        return n
      }
      segment.noteOutsideInstallation(outside)
      segment.start()
    }

    /// The installation ended (stop, suspend): close its segment. Call after the listener has
    /// been removed, so no callback can still be running for it.
    package func close(reason: String) {
      let segment = current.withLock { c -> Segment? in
        let s = c
        c = nil
        return s
      }
      segment?.close(reason: reason)
    }

    // MARK: - Producers

    /// A live record for the current segment; nothing while none is live.
    package func submit(_ record: ShadowRecord) {
      guard let segment = current.withLock({ $0 }) else {
        outsideInstallation.withLock { $0 += 1 }
        return
      }
      segment.submit(record)
    }

    package func configure(_ snapshot: ShadowKeyboardPolicy.Snapshot) {
      current.withLock { $0 }?.policy.configure(snapshot)
    }

    package func closeGenerations(before generation: UInt64) {
      current.withLock { $0 }?.closeGenerations(before: generation)
    }

    package func recordExecution(_ kind: String) {
      current.withLock { $0 }?.recordExecution(kind)
    }

    /// The live executor ended the attempt whose first press was at `attemptOrigin`.
    package func liveEndedAttempt(origin attemptOrigin: TimeInterval?) {
      current.withLock { $0 }?.policy.refuse(attemptOrigin: attemptOrigin)
    }

    // MARK: - Test seams

    package var currentSegmentForTesting: Segment? { current.withLock { $0 } }

    /// The current segment's running tally after draining it; empty when none is live.
    package func drainForTesting() -> Tally {
      current.withLock { $0 }?.drainForTesting() ?? Tally()
    }

    // MARK: - Tally

    /// A tally of verdicts over one segment.
    package struct Tally: Sendable, Equatable {
      package var agreements = 0
      package var expectedTiming = 0
      package var mappingErrors = 0
      package var ambiguities = 0
      package var incomplete = 0
      package var droppedRecords = 0
      package var suppressedLines = 0
      /// Live records outside the flagsChanged-only listener's reach (a Carbon chord record
      /// binding), not compared until P5 moves chords to the listener.
      package var outOfScope = 0
      /// Live records stamped with a generation from before this segment began.
      package var earlierGeneration = 0
      /// Live records made while no installation was live, before this segment began.
      package var outsideInstallation = 0
      /// What the live executor did with decisions (refusals, publication), by kind.
      package var executions: [String: Int] = [:]

      package init() {}

      /// True while nothing was lost and nothing is unexplained.
      package var clean: Bool {
        mappingErrors == 0 && ambiguities == 0 && incomplete == 0 && droppedRecords == 0
          && suppressedLines == 0
      }
    }

    // MARK: - Segment

    /// One installation's comparison, isolated from every other.
    package final class Segment: Sendable {
      package static let handoffCapacity = 1024
      package static let linesPerDrain = 64
      package static let samplesPerClose = 8
      static let drainInterval: TimeInterval = 0.25

      package let installation: UInt64
      package let firstGeneration: UInt64
      package let policy: ShadowKeyboardPolicy
      private let handoff = Handoff()
      private let tally = OSAllocatedUnfairLock(initialState: Tally())
      private let comparator = KeyboardShadowComparator()
      private let worker: DispatchQueue
      private let clock: RecordGestureEngine.Clock
      private let lines: AsyncStream<String>.Continuation
      /// `DispatchSourceTimer` is not `Sendable`; it is created, cancelled and released only
      /// under this lock.
      private let timer = OSAllocatedUnfairLock<DispatchSourceTimer?>(uncheckedState: nil)
      /// Test seam: called on the worker after a buffer is taken and before it is processed.
      private let drainGate = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

      fileprivate init(
        installation: UInt64, firstGeneration: UInt64, snapshot: ShadowKeyboardPolicy.Snapshot,
        clock: @escaping RecordGestureEngine.Clock, lines: AsyncStream<String>.Continuation
      ) {
        self.installation = installation
        self.firstGeneration = firstGeneration
        self.clock = clock
        self.lines = lines
        let worker = DispatchQueue(
          label: "com.enviouswispr.keyboard-shadow-segment", qos: .utility)
        self.worker = worker
        let handoff = self.handoff
        // The shadow's lone-tap timers fire on this segment's worker, which also closes it.
        let scheduler: RecordGestureEngine.Scheduler = { delay, fire in
          let source = DispatchSource.makeTimerSource(queue: worker)
          source.setEventHandler { [weak source] in
            source?.cancel()
            fire()
          }
          source.schedule(deadline: .now() + max(0, delay), repeating: .never)
          source.activate()
          return RecordGestureEngine.TimerHandle(cancel: { source.cancel() })
        }
        policy = ShadowKeyboardPolicy(
          snapshot: snapshot, clock: clock, scheduler: scheduler,
          emit: { record in handoff.submit(record) })
        policy.beginInstallation(installation)
      }

      /// The listener sink's DEBUG work, on the listener thread.
      package func listenerEvent(_ event: KeyEventValue) {
        policy.ingest(event, handled: clock(), installation: installation)
      }

      fileprivate func submit(_ record: ShadowRecord) {
        if record.lane == .live, record.generation < firstGeneration {
          tally.withLock { $0.earlierGeneration += 1 }
          return
        }
        handoff.submit(record)
      }

      fileprivate func noteOutsideInstallation(_ count: Int) {
        guard count > 0 else { return }
        tally.withLock { $0.outsideInstallation += count }
      }

      fileprivate func recordExecution(_ kind: String) {
        tally.withLock { $0.executions[kind, default: 0] += 1 }
      }

      fileprivate func start() {
        timer.withLockUnchecked { current in
          guard current == nil else { return }
          let source = DispatchSource.makeTimerSource(queue: worker)
          source.setEventHandler { [weak self] in self?.drain() }
          source.schedule(deadline: .now() + Self.drainInterval, repeating: Self.drainInterval)
          source.activate()
          current = source
        }
      }

      fileprivate func stopTimer() {
        timer.withLockUnchecked { current in
          current?.cancel()
          current = nil
        }
      }

      /// No more admissions or shadow timers; then, on the worker and after everything already
      /// emitted, compare, flush, log samples and one summary.
      fileprivate func close(reason: String) {
        policy.endInstallation()
        stopTimer()
        worker.async { [self] in
          drain()
          let samples = comparator.pendingSamples(
            generationsBefore: .max, limit: Self.samplesPerClose)
          let flushed = comparator.flush(generationsBefore: .max)
          tally.withLock { t in for v in flushed { Self.count(v, into: &t) } }
          for r in samples { emit("[shadow] unmatched \(Self.describe(r))") }
          let summary = tally.withLock { $0 }
          emit(Self.summaryLine(reason: reason, installation: installation, summary))
        }
      }

      fileprivate func closeGenerations(before generation: UInt64) {
        worker.async { [self] in
          drain()
          let flushed = comparator.flush(generationsBefore: generation)
          tally.withLock { t in for v in flushed { Self.count(v, into: &t) } }
        }
      }

      // MARK: Worker

      private func drain() {
        guard var taken = handoff.take() else { return }
        drainGate.withLock { $0 }?()
        var verdicts: [ShadowComparison] = []
        for i in 0..<taken.count {
          if let r = taken.buffer[i] { verdicts += comparator.add(r) }
          taken.buffer[i] = nil
        }
        handoff.giveBack(taken.buffer)
        let (dropped, outOfScope) = (taken.dropped, taken.outOfScope)
        let settled = verdicts
        tally.withLock { t in
          t.droppedRecords += dropped
          t.outOfScope += outOfScope
          for v in settled { Self.count(v, into: &t) }
        }
        if dropped > 0 { emit("[shadow] dropped=\(dropped) records: the handoff was full") }
        var formatted = 0
        var suppressed = 0
        for v in verdicts {
          if case .agreement = v { continue }
          if formatted < Self.linesPerDrain {
            formatted += 1
            emit(Self.line(v))
          } else {
            suppressed += 1
          }
        }
        if suppressed > 0 {
          let count = suppressed
          tally.withLock { $0.suppressedLines += count }
          emit("[shadow] suppressed=\(count) lines this drain")
        }
      }

      /// Queue one line; a line the channel does not take is counted against this segment.
      private func emit(_ line: String) {
        // Dropped by a full channel or refused by a finished one: either way the line is lost.
        if case .enqueued = lines.yield(line) { return }
        tally.withLock { $0.suppressedLines += 1 }
      }

      private static func count(_ v: ShadowComparison, into t: inout Tally) {
        switch v {
        case .agreement: t.agreements += 1
        case .expectedTiming: t.expectedTiming += 1
        case .mappingError: t.mappingErrors += 1
        case .ambiguity: t.ambiguities += 1
        case .incomplete: t.incomplete += 1
        }
      }

      // MARK: Formatting (worker only)

      package static func summaryLine(reason: String, installation: UInt64, _ t: Tally) -> String {
        let executions = t.executions.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }
          .joined(separator: ",")
        return "[shadow] segment_closed installation=\(installation) reason=\(reason) "
          + "clean=\(t.clean) agreements=\(t.agreements) expected_timing=\(t.expectedTiming) "
          + "mapping_errors=\(t.mappingErrors) ambiguities=\(t.ambiguities) "
          + "incomplete=\(t.incomplete) dropped=\(t.droppedRecords) "
          + "suppressed_lines=\(t.suppressedLines) out_of_scope=\(t.outOfScope) "
          + "earlier_generation=\(t.earlierGeneration) "
          + "outside_installation=\(t.outsideInstallation) executions=[\(executions)]"
      }

      private static func describe(_ r: ShadowRecord) -> String {
        func t(_ v: TimeInterval?) -> String { v.map { String(format: "%.17g", $0) } ?? "nil" }
        return "lane=\(r.lane) gen=\(r.generation) seq=\(r.sequence) cat=\(r.category) "
          + "key=\(r.keyCode) role=\(r.role.map { "\($0)" } ?? "nil") "
          + "phase=\(r.phase.map { "\($0)" } ?? "nil") outcome=\(r.outcome) "
          + "raw=\(t(r.rawOccurred)) accepted=\(t(r.acceptedOccurred)) handled=\(t(r.handled)) "
          + "first=\(t(r.attemptStartOccurred)) context=\(r.context) "
          + "evidence=\(r.evidence.map { "\($0)" } ?? "nil")"
      }

      private static func line(_ v: ShadowComparison) -> String {
        switch v {
        case .agreement(let l, let s):
          return "[shadow] agreement live{\(describe(l))} shadow{\(describe(s))}"
        case .expectedTiming(let l, let s):
          return "[shadow] expected_timing live{\(describe(l))} shadow{\(describe(s))}"
        case .mappingError(let l, let s):
          return "[shadow] MAPPING_ERROR live{\(describe(l))} shadow{\(describe(s))}"
        case .ambiguity(let a):
          switch a {
          case .missingIdentity(let r):
            return "[shadow] ambiguity=missing_identity {\(describe(r))}"
          case .competingCounterparts(let r, let n):
            return "[shadow] ambiguity=competing count=\(n) {\(describe(r))}"
          case .uncertainKeyState(let l, let s):
            return "[shadow] ambiguity=uncertain_key live{\(describe(l))} shadow{\(describe(s))}"
          case .executorRetired(let l, let s):
            return
              "[shadow] ambiguity=executor_retired live{\(describe(l))} shadow{\(describe(s))}"
          case .divergedAfterTiming(let l, let s):
            return
              "[shadow] ambiguity=diverged_after_timing live{\(describe(l))} shadow{\(describe(s))}"
          case .contextDiffered(let l, let s):
            return
              "[shadow] ambiguity=context_differed live{\(describe(l))} shadow{\(describe(s))}"
          }
        case .incomplete(let i):
          return "[shadow] incomplete reason=\(i.reason) live_unmatched=\(i.liveUnmatched) "
            + "shadow_unmatched=\(i.shadowUnmatched) unproven=\(i.unprovenTiming)"
        }
      }

      // MARK: Test seams

      /// Drain on the worker and return the running tally, without closing.
      package func drainForTesting() -> Tally {
        worker.sync { [self] in
          drain()
          return tally.withLock { $0 }
        }
      }

      /// The tally once every step queued on the worker so far (including a close) has run.
      package func settledTallyForTesting() -> Tally {
        worker.sync { tally.withLock { $0 } }
      }

      /// Hold each drain after it took a buffer, before processing it.
      package func setDrainGateForTesting(_ gate: (@Sendable () -> Void)?) {
        drainGate.withLock { $0 = gate }
      }
    }

    /// The bounded handoff a segment's two lanes write into. A write stores one preallocated
    /// slot under a short lock; the worker swaps the filled buffer for the spare in constant time
    /// and processes it outside the lock, so the writer's buffer is never shared and never copied
    /// on write.
    private final class Handoff: Sendable {
      private struct Buffers: Sendable {
        var filling = [ShadowRecord?](repeating: nil, count: Segment.handoffCapacity)
        /// The empty buffer the next swap installs; nil while the worker holds it.
        var spare: [ShadowRecord?]? = [ShadowRecord?](
          repeating: nil, count: Segment.handoffCapacity)
        var count = 0
        var dropped = 0
        var outOfScope = 0
      }
      private let state = OSAllocatedUnfairLock(initialState: Buffers())

      func submit(_ record: ShadowRecord) {
        state.withLock { b in
          guard record.listenerScope else {
            b.outOfScope += 1
            return
          }
          guard b.count < Segment.handoffCapacity else {
            b.dropped += 1
            return
          }
          b.filling[b.count] = record
          b.count += 1
        }
      }

      struct Taken {
        var buffer: [ShadowRecord?]
        let count: Int
        let dropped: Int
        let outOfScope: Int
      }

      /// Swap the filled buffer out; nil when the worker has not returned the previous one,
      /// which a single serial worker never does.
      func take() -> Taken? {
        state.withLock { b in
          guard let spare = b.spare else { return nil }
          let taken = Taken(
            buffer: b.filling, count: b.count, dropped: b.dropped, outOfScope: b.outOfScope)
          b.filling = spare
          b.spare = nil
          b.count = 0
          b.dropped = 0
          b.outOfScope = 0
          return taken
        }
      }

      func giveBack(_ buffer: [ShadowRecord?]) {
        state.withLock { $0.spare = buffer }
      }
    }
  }
#endif
