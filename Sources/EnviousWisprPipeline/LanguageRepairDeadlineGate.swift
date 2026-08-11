import Foundation
import os

/// Arbitrates the single 100 ms deadline that now covers BOTH language
/// resolution and cursor-insertion repair (#1921), and owns the entire
/// diagnostic record of what that deadline saw (#1946).
///
/// Before #1921 only repair sat inside `withOrderedDeadline`; language
/// resolution ran ahead of it, unbounded, on the paste path. Moving resolution
/// inside the same deadline creates a question the old code never had to answer:
/// **which stage timed out?** It matters because the existing `onTimeout`
/// permanently disables `SeamCasingOracleRuntime`, and doing that because the
/// LANGUAGE stage stalled would kill an unrelated, healthy component for the
/// rest of the process.
///
/// A plain "did the repair stage begin" flag is not enough, and this is the
/// whole reason a lock exists here. `withOrderedDeadline` cancels
/// best-effort — its own comment says cancellation "cannot preempt a blocked
/// thread" (`TaskTimeout.swift:129`) — and `onTimeout()` runs synchronously
/// before the nil resume. So with a flag, the timeout can observe "still
/// resolving", decline to disable, and the un-preempted operation can then walk
/// straight into the oracle anyway.
///
/// Four states rather than three, which grounded review r3 found: `TaskTimeout`
/// runs `await operation()` and its `claim()` as separate steps
/// (`TaskTimeout.swift:123-125`), so repair can FINISH and the timeout can still
/// win `claim()` in the gap. A three-state gate reads that as still-running,
/// concludes the oracle is stuck, and disables a component that had just
/// succeeded. `completed` is that gap.
///
/// **One lock, not two (integration review round 2).** An earlier version of
/// this type kept `oracleTouched` in a SECOND `OSAllocatedUnfairLock`, read just
/// before the phase lock was claimed. That is check-then-act: between the read
/// and the claim, repair can consult the oracle and block, and the timeout then
/// claims with a stale `false` and leaves a genuinely stuck oracle enabled.
/// Merging the flag into the phase makes the two facts one atomic transition,
/// and it is simpler than what it replaced. Every mutation below is exactly one
/// `withLock`, so neither side can lose a window.
///
/// **#1946 extends that same argument to the DIAGNOSTIC record, for the same
/// reason.** The plan's first design put phase durations in a second lock owned
/// by the wiring, on the theory that "where" and "how long" are disjoint facts.
/// They are not: both answer *"what was true when the timeout claimed?"*, and
/// two locks cannot answer that atomically. Because the operation is never
/// preempted (`TaskTimeout.swift:123-132`), a mark written after the phase was
/// claimed could contradict evidence the timeout had already returned — a
/// diagnostic that looks self-consistent and is false, which is worse than the
/// coarse label it replaces. So every mark lives here, behind this lock, and
/// `freeze` makes everything after the claim inert.
package final class LanguageRepairDeadlineGate: Sendable {

  // MARK: - Outward shape

  /// Which stage the deadline caught, as a stable label for logs and telemetry.
  ///
  /// Raw values are a SHIPPED closed set consumed by `paste.completed`; treat
  /// them like any other telemetry vocabulary and never repurpose one.
  package enum TimeoutPhase: String, Sendable, Equatable {
    case resolvingLanguage = "language"
    /// Repair running, no oracle consultation had begun. Covers both repair's
    /// own spacing work AND the main-thread hop that fetches the oracle, which
    /// is why the hop carries its own duration below — the phase alone cannot
    /// separate them.
    case repairBeforeOracle = "repair_pre_oracle"
    /// A consultation was IN FLIGHT when the deadline fired. Only this phase
    /// may honestly be reported as an oracle timeout.
    case repairAfterOracle = "repair_oracle"
    /// The oracle was consulted, every consultation RETURNED, and repair then
    /// crossed the deadline in its own work. Whole-diff review found the first
    /// version reporting this as `repair_oracle`, which asserts a stall that
    /// demonstrably did not happen — the exact defect this change exists to end.
    case repairAfterOracleReturned = "repair_post_oracle"
    case completed = "completed"
    case alreadyTimedOut = "already_timed_out"
  }

  /// The immutable projection of everything the gate knows, frozen at one
  /// instant. The mutable state it is derived from never leaves this type.
  /// NOT `Equatable`: `DictationLanguageResolver.Resolution` is `Sendable` only
  /// (`DictationLanguageResolver.swift:47`), and widening a shipped type's
  /// conformances to buy a test convenience is the wrong trade. Tests compare
  /// the fields they are actually asserting on.
  package struct Snapshot: Sendable {
    package var phase: TimeoutPhase
    package var resolution: DictationLanguageResolver.Resolution?
    /// True ONLY for an oracle that was genuinely consulted. This is the safety
    /// net's input and #1946 does not change how it is computed.
    package var shouldDisableOracle: Bool
    package var languageMs: Double?
    package var oracleFetchMs: Double?
    package var repairMs: Double?
    /// Label of the consultation still running when the snapshot froze.
    package var oracleInFlight: String?
    package var oracleInFlightMs: Double?
    package var oracleClosuresCompleted: Int
    package var oracleClosureMaxMs: Double?
  }

  /// The one sequencing point that is NOT already a phase transition.
  ///
  /// `languageResolved` and `repairReturned` used to live here too. They are now
  /// folded into `beginRepair` and `completeRepair`, because a separate `mark`
  /// call meant TWO lock takes around one logical event, and the timer can claim
  /// between them. For `repairReturned` that was not merely a lost datum: the
  /// phase was still `.repair(oracleTouched: true)` in the gap, so a timeout
  /// landing there would permanently disable an oracle whose work had ALREADY
  /// completed — the instrument causing the exact failure it exists to diagnose
  /// (`validation-discipline.md`: a diagnostic must not widen a window in the
  /// code it observes; whole-diff review r2).
  ///
  /// This one is safe to leave standalone because it changes no phase: a timeout
  /// racing it costs one missing duration, never a wrong action.
  package enum Mark: Sendable {
    case oracleFetched
  }

  // MARK: - Internal state

  private enum Phase: Sendable {
    /// Resolution in flight. Repair has not been authorised.
    case resolvingLanguage
    /// Repair genuinely running, carrying whether the word oracle has actually
    /// been consulted yet. This is the only phase that may disable the oracle,
    /// and only with `oracleTouched` true.
    case repair(DictationLanguageResolver.Resolution, oracleTouched: Bool)
    /// Repair returned; the operation has not claimed its result yet.
    case completed(DictationLanguageResolver.Resolution)
    /// Terminal.
    case timedOut
  }

  private struct OracleUse: Sendable {
    let token: UInt64
    let label: String
    let startedAt: Double
  }

  private struct State: Sendable {
    var phase: Phase = .resolvingLanguage
    /// Set by the first `timeOut()` / `completeRepair()`. Every later mutation
    /// is inert, which is what stops an un-preempted operation rewriting
    /// evidence already returned. Holding the SNAPSHOT rather than a flag is
    /// what makes re-freezing genuinely idempotent: recomputing would re-measure
    /// `oracleInFlightMs` against a later clock and hand two callers two
    /// different answers about the same instant.
    var frozen: Snapshot?
    var lastMarkAt: Double
    var languageMs: Double?
    var oracleFetchMs: Double?
    var repairMs: Double?
    /// Monotonic. Never reused, which is what makes a completion correlatable.
    var nextToken: UInt64 = 1
    /// A STACK, not a single label: consultations can nest, and a label alone
    /// cannot tell a stale completion from a live consultation that happens to
    /// carry the same label.
    var oracleUses: [OracleUse] = []
    var oracleClosuresCompleted = 0
    var oracleClosureMaxMs: Double?
  }

  private let state: OSAllocatedUnfairLock<State>
  private let now: @Sendable () -> Double

  /// `now` reads a MONOTONIC clock in seconds, injectable for the same reason
  /// `TerminalResolutionBudget` takes one (`TerminalContextResolver.swift:113-123`,
  /// #1893): an assertion about a duration must not depend on wall time, because
  /// a busy-wait guarantees a floor and never a ceiling.
  package init(
    now: @escaping @Sendable () -> Double = {
      Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }
  ) {
    self.now = now
    self.state = OSAllocatedUnfairLock(initialState: State(lastMarkAt: now()))
  }

  /// The frozen record, whichever path froze it, or nil if neither has yet.
  ///
  /// Exists so the DEBUG trace can report a HEALTHY delivery's phase timings.
  /// Telemetry deliberately stays timeout-only — a healthy dictation must send
  /// nothing, because the fields' presence is itself the signal — but the local
  /// log has no such constraint, and without this the per-app cost of the
  /// main-thread hop could only be measured by waiting for a failure.
  package var frozenEvidence: Snapshot? { state.withLock { $0.frozen } }

  // MARK: - Phase transitions

  /// Authorises repair, carrying the resolution the timeout would otherwise lose.
  ///
  /// Returns `false` when the deadline already claimed the phase, which is the
  /// signal for the operation to return the legacy payload WITHOUT calling
  /// repair. That is the guarantee a cancellation flag cannot give, because the
  /// operation may not have been preempted at all.
  package func beginRepair(_ resolution: DictationLanguageResolver.Resolution) -> Bool {
    state.withLock {
      guard $0.frozen == nil, case .resolvingLanguage = $0.phase else { return false }
      let t = now()
      $0.languageMs = max(0, t - $0.lastMarkAt) * 1000
      $0.lastMarkAt = t
      $0.phase = .repair(resolution, oracleTouched: false)
      return true
    }
  }

  /// Record how long a sequencing step took, measured by this gate's own clock.
  ///
  /// One clock and one lock: the caller says WHICH step finished, never how long
  /// it took, so there is no second time source to disagree with the snapshot.
  package func mark(_ mark: Mark) {
    state.withLock {
      guard $0.frozen == nil else { return }
      let t = now()
      let elapsed = max(0, t - $0.lastMarkAt) * 1000
      $0.lastMarkAt = t
      switch mark {
      case .oracleFetched: $0.oracleFetchMs = elapsed
      }
    }
  }

  /// May the word oracle be consulted right now — and if so, take a token.
  ///
  /// Called from the oracle's own closures on EVERY consultation, not merely the
  /// first, which is what makes it a guard rather than a notification. Three
  /// jobs, and they must be one transition:
  ///
  /// 1. **Record** that the oracle was genuinely reached. `beginRepair` runs
  ///    before `CursorInsertionRepair.repair`, but repair has early exits and
  ///    does all its spacing work before it ever consults word knowledge. Arming
  ///    on "repair began" lets a timeout in that window permanently disable an
  ///    oracle that was never touched — the exact harm this gate exists to
  ///    prevent, moved one step later rather than removed.
  /// 2. **Refuse** once the deadline has fired. Cancellation cannot preempt a
  ///    blocked thread, so without this an un-preempted repair walks into the
  ///    real oracle AFTER the timeout already gave up — the unbounded blocking
  ///    call the deadline exists to bound. The wrapper's refusal keeps the
  ///    capital, so a late refusal can only be safe.
  /// 3. **Name** which consultation is running, so a post-authorisation timeout
  ///    says whether the dictionary, the name tagger or the noun tagger stalled
  ///    (#1946). Without this the four post-authorisation closures produce
  ///    byte-identical evidence and the instrument answers nothing.
  ///
  /// - Returns: a unique token to pass to `completeOracleUse`, or `nil` when the
  ///   consultation is refused. A refused caller must NOT call the completion.
  package func beginOracleUse(_ label: String) -> UInt64? {
    state.withLock {
      guard $0.frozen == nil, case .repair(let resolution, _) = $0.phase else { return nil }
      $0.phase = .repair(resolution, oracleTouched: true)
      let token = $0.nextToken
      $0.nextToken += 1
      $0.oracleUses.append(OracleUse(token: token, label: label, startedAt: now()))
      return token
    }
  }

  /// Finish the consultation identified by `token`.
  ///
  /// Removes ONLY that token, so a stale or duplicate completion cannot clear a
  /// newer consultation that happens to carry the same label — the defect a
  /// label-correlated API has and this one does not. Unknown, duplicate and
  /// post-freeze tokens are inert by construction.
  package func completeOracleUse(_ token: UInt64) {
    state.withLock {
      guard $0.frozen == nil,
        let index = $0.oracleUses.firstIndex(where: { $0.token == token })
      else { return }
      let use = $0.oracleUses.remove(at: index)
      let elapsed = max(0, now() - use.startedAt) * 1000
      $0.oracleClosuresCompleted += 1
      $0.oracleClosureMaxMs = max($0.oracleClosureMaxMs ?? 0, elapsed)
    }
  }

  // MARK: - Freezing

  /// Marks repair finished and freezes the record. Must be called immediately
  /// after repair returns and before the deadline operation's closure returns,
  /// so the window in which a healthy oracle looks stuck is as small as the
  /// runtime allows.
  ///
  /// Inert from any other phase: a `completeRepair` that never began must not
  /// promote `resolvingLanguage` into a completed run.
  @discardableResult
  package func completeRepair() -> Snapshot {
    state.withLock {
      let t = now()
      if $0.frozen == nil, case .repair(let resolution, _) = $0.phase {
        $0.repairMs = max(0, t - $0.lastMarkAt) * 1000
        $0.lastMarkAt = t
        $0.phase = .completed(resolution)
      }
      return Self.freeze(&$0, now: t)
    }
  }

  /// Claims the phase for the deadline and reports everything it saw.
  ///
  /// - Returns: the complete frozen `Snapshot`. `shouldDisableOracle` is true
  ///   ONLY for an oracle that was genuinely consulted, which is unchanged by
  ///   #1946 — the safety net's input is the same fact it always was.
  package func timeOut() -> Snapshot {
    state.withLock {
      let snapshot = Self.freeze(&$0, now: now())
      // Only a timeout is terminal. A `completeRepair` that already froze keeps
      // its `.completed` snapshot, which correctly reports `shouldDisableOracle
      // == false`: repair returned, so whatever it consulted answered in time.
      $0.phase = .timedOut
      return snapshot
    }
  }

  /// Project the current state and make every later mutation inert.
  ///
  /// Idempotent BY STORING the projection: a second freeze returns the first
  /// one's evidence rather than re-measuring an in-flight duration against a
  /// later clock, so two callers can never be told two different things about
  /// the same instant.
  private static func freeze(_ state: inout State, now: Double) -> Snapshot {
    if let already = state.frozen { return already }
    let inFlight = state.oracleUses.last

    // CHARGE THE UNFINISHED STAGE BEFORE PROJECTING.
    //
    // Every duration above is written when its stage FINISHES, so on a timeout
    // the one stage that never finished — the slow one, the entire reason this
    // record exists — was reported as `-`. The first version logged
    // `phase=language lang=-ms` and that blank sat in a passing test's output
    // without anyone reading it. Whole-diff review r3 caught it.
    //
    // Which field it belongs to is derived from the phase, so an in-flight
    // duration can never be confused with a completed one: the phase names the
    // stage, and that stage's number is the partial.
    let running = max(0, now - state.lastMarkAt) * 1000
    switch state.phase {
    case .resolvingLanguage:
      state.languageMs = running
    case .repair:
      // Before the fetch completed, the running stage IS the fetch; after it,
      // repair's own work. `oracleFetchMs` is the only thing that distinguishes
      // them, because both live in the same phase.
      if state.oracleFetchMs == nil {
        state.oracleFetchMs = running
      } else {
        state.repairMs = running
      }
    case .completed, .timedOut:
      break  // nothing is running; every stage already recorded its own time
    }
    let phase: TimeoutPhase
    var resolution: DictationLanguageResolver.Resolution?
    var shouldDisable = false
    switch state.phase {
    // Nothing ran. Nothing to report, nothing to punish.
    case .resolvingLanguage:
      phase = .resolvingLanguage
    // Repair is still running. Disable ONLY if the oracle was genuinely
    // consulted — repair may have stalled in its own spacing work, or have
    // taken an early exit, without ever reaching it.
    case .repair(let r, let oracleTouched):
      // Three outcomes, not two. `oracleTouched` says a consultation happened at
      // some point; `inFlight` says one is happening NOW, and only the second
      // justifies reporting an oracle stall.
      phase =
        oracleTouched
        ? (inFlight != nil ? .repairAfterOracle : .repairAfterOracleReturned)
        : .repairBeforeOracle
      resolution = r
      // DELIBERATELY UNCHANGED, and this is the one place the diagnostic and the
      // safety net are allowed to disagree. Whole-diff review proposed gating
      // this on an active token too, which would NARROW the latch — a change to
      // the guard, which the founder ruled out for this change (2026-08-10).
      // So a returned-consultation timeout still latches exactly as it always
      // has, while the evidence now says honestly that nothing was in flight.
      // Whether that latch is right is a real question, and it is now ASKABLE
      // from the data instead of invisible: look for `repair_post_oracle`.
      shouldDisable = oracleTouched
    // Repair already returned, so whatever it consulted answered in time.
    case .completed(let r):
      phase = .completed
      resolution = r
    case .timedOut:
      phase = .alreadyTimedOut
    }
    let snapshot = Snapshot(
      phase: phase,
      resolution: resolution,
      shouldDisableOracle: shouldDisable,
      languageMs: state.languageMs,
      oracleFetchMs: state.oracleFetchMs,
      repairMs: state.repairMs,
      oracleInFlight: inFlight?.label,
      oracleInFlightMs: inFlight.map { max(0, now - $0.startedAt) * 1000 },
      oracleClosuresCompleted: state.oracleClosuresCompleted,
      oracleClosureMaxMs: state.oracleClosureMaxMs)
    state.frozen = snapshot
    return snapshot
  }
}
