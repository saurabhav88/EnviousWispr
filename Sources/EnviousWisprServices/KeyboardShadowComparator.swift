import EnviousWisprCore
import Foundation
import os

// #3544 P2: the comparison between today's record-key path ("live") and the keyboard listener
// running beside it in shadow ("shadow"). Values only; nothing here acts on a decision.

/// One record-gesture decision, as a closed set both lanes map to through the same functions.
package enum GestureOutcome: Sendable, Equatable {
  // Press
  case duplicate
  case start
  case tripleCancel
  case lockIntent
  case ignoredCooldown
  case stopLocked
  case lateAfterWindow
  // Release
  case releaseIgnored
  case releaseSuppressedLocked
  case quickRelease
  case holdStop
  // Lone-tap timer
  case loneTapStop
  case loneTapStale
  /// The pending lone-tap wait was retired by a later press (fresh start, lock, triple, stop).
  case loneTapCancelled
  /// The pending wait was retired by a reset or a refusal the executor made. The shadow never
  /// sees executor refusals, so this can only be compared as incomplete.
  case loneTapRetired

  package init(_ decision: RecordGesture.PressDecision) {
    switch decision {
    case .start: self = .start
    case .tripleCancel: self = .tripleCancel
    case .lockIntent: self = .lockIntent
    case .ignoredCooldown: self = .ignoredCooldown
    case .stopLocked: self = .stopLocked
    case .lateAfterWindow: self = .lateAfterWindow
    }
  }

  package init(_ decision: RecordGesture.ReleaseDecision) {
    switch decision {
    case .ignored: self = .releaseIgnored
    case .suppressedLocked: self = .releaseSuppressedLocked
    case .quick: self = .quickRelease
    case .hold: self = .holdStop
    }
  }

  package init(_ check: RecordGesture.LoneTapCheck) {
    switch check {
    case .stale: self = .loneTapStale
    case .stop: self = .loneTapStop
    }
  }
}

/// What a gesture owner saw and decided for one input, captured where the decision was made.
/// The live engine reports these through its DEBUG observer; the shadow policy builds the same
/// value from the same `RecordGesture` calls.
package struct GestureObservation: Sendable, Equatable {
  package enum Kind: Sendable, Equatable {
    case press
    case release
    case timer
  }

  package let kind: Kind
  package let keyCode: UInt16
  package let outcome: GestureOutcome
  /// The input's handling time and accepted occurrence time. For a timer, the quick release that
  /// scheduled it.
  package let handled: TimeInterval
  package let occurred: TimeInterval?
  /// Accepted occurrence time of the attempt's first press, read before this decision applied.
  package let attemptStartOccurred: TimeInterval?
  package let afterStopTimerMs: Int?
  /// The lone-tap deadline, for a quick release and its timer.
  package let deadline: TimeInterval?
  /// For a press that consumed a stop-timer marker: the first press of the attempt that stop
  /// ended. Ties a timing difference to the exact attempt both lanes saw.
  package let markerOrigin: TimeInterval?
  /// For a timer stop: when the stop was requested.
  package let stopRequestedAt: TimeInterval?
  /// The owner's configuration generation and its decision order, stamped when the decision was
  /// made, never when it is reported.
  package var generation: UInt64 = 0
  package var sequence: UInt64 = 0
  /// False when the decision was made under a record binding the flagsChanged-only listener
  /// cannot see (a Carbon chord), captured at decision time.
  package var listenerScope = true

  package init(
    kind: Kind, keyCode: UInt16, outcome: GestureOutcome, handled: TimeInterval,
    occurred: TimeInterval?, attemptStartOccurred: TimeInterval?, afterStopTimerMs: Int? = nil,
    deadline: TimeInterval? = nil, markerOrigin: TimeInterval? = nil,
    stopRequestedAt: TimeInterval? = nil
  ) {
    self.kind = kind
    self.keyCode = keyCode
    self.outcome = outcome
    self.handled = handled
    self.occurred = occurred
    self.attemptStartOccurred = attemptStartOccurred
    self.afterStopTimerMs = afterStopTimerMs
    self.deadline = deadline
    self.markerOrigin = markerOrigin
    self.stopRequestedAt = stopRequestedAt
  }
}

/// One normalized record from either lane.
package struct ShadowRecord: Sendable, Equatable {
  package enum Lane: Sendable, Equatable {
    case live
    case shadow
  }

  package enum Category: Sendable, Equatable {
    /// A physical key edge.
    case ingress
    /// A record-gesture decision, or a non-record role's predicted action.
    case decision
    /// A lone-tap timer's resolution; it refers to its quick release, never a new physical edge.
    case timer
  }

  package enum Outcome: Sendable, Equatable {
    case edge
    case gesture(GestureOutcome)
    /// A non-record role's press or release, predicted, never executed.
    case rolePress
    case roleRelease
    /// Cancel's release after its press was consumed.
    case consumedTail
    /// Nothing decided: disabled, suspended, unarmed, unavailable or unowned.
    case noDecision
  }

  package let lane: Lane
  /// Configuration generation both lanes must share for a pair.
  package let generation: UInt64
  /// Lane-local order. Never a pairing key.
  package let sequence: UInt64
  package let category: Category
  package let keyCode: UInt16
  package let role: ShortcutRole?
  package let phase: KeyStateTracker.Phase?
  package let outcome: Outcome
  /// The event's own time before acceptance (ingress), when known.
  package let rawOccurred: TimeInterval?
  /// The accepted occurrence time the decision used.
  package let acceptedOccurred: TimeInterval?
  package let handled: TimeInterval
  package let attemptStartOccurred: TimeInterval?
  package let afterStopTimerMs: Int?
  package let deadline: TimeInterval?
  package let markerOrigin: TimeInterval?
  package let stopRequestedAt: TimeInterval?
  package let evidence: KeyStateTracker.Evidence?
  /// Aggregate-only evidence left this key's state unproven.
  package let ambiguous: Bool
  /// False for a decision the listener cannot see (a Carbon chord record binding).
  package var listenerScope = true
  /// The arming and action availability a non-record role was decided under (bit per role),
  /// captured at decision time. Different contexts make a difference unexplained by mapping.
  package var context: UInt8 = 0

  package init(
    lane: Lane, generation: UInt64, sequence: UInt64, category: Category, keyCode: UInt16,
    role: ShortcutRole?, phase: KeyStateTracker.Phase?, outcome: Outcome,
    rawOccurred: TimeInterval?, acceptedOccurred: TimeInterval?, handled: TimeInterval,
    attemptStartOccurred: TimeInterval? = nil, afterStopTimerMs: Int? = nil,
    deadline: TimeInterval? = nil, markerOrigin: TimeInterval? = nil,
    stopRequestedAt: TimeInterval? = nil, evidence: KeyStateTracker.Evidence? = nil,
    ambiguous: Bool = false
  ) {
    self.lane = lane
    self.generation = generation
    self.sequence = sequence
    self.category = category
    self.keyCode = keyCode
    self.role = role
    self.phase = phase
    self.outcome = outcome
    self.rawOccurred = rawOccurred
    self.acceptedOccurred = acceptedOccurred
    self.handled = handled
    self.attemptStartOccurred = attemptStartOccurred
    self.afterStopTimerMs = afterStopTimerMs
    self.deadline = deadline
    self.markerOrigin = markerOrigin
    self.stopRequestedAt = stopRequestedAt
    self.evidence = evidence
    self.ambiguous = ambiguous
  }

  /// A gesture decision or timer record built from an observation, for either lane, carrying the
  /// generation and order the observation was stamped with when it was decided.
  package init(
    lane: Lane, role: ShortcutRole?, observation o: GestureObservation,
    evidence: KeyStateTracker.Evidence? = nil
  ) {
    let category: Category
    let phase: KeyStateTracker.Phase?
    switch o.kind {
    case .press: (category, phase) = (.decision, .press)
    case .release: (category, phase) = (.decision, .release)
    case .timer: (category, phase) = (.timer, nil)
    }
    self.init(
      lane: lane, generation: o.generation, sequence: o.sequence, category: category,
      keyCode: o.keyCode, role: role, phase: phase, outcome: .gesture(o.outcome),
      rawOccurred: nil, acceptedOccurred: o.occurred, handled: o.handled,
      attemptStartOccurred: o.attemptStartOccurred, afterStopTimerMs: o.afterStopTimerMs,
      deadline: o.deadline, markerOrigin: o.markerOrigin, stopRequestedAt: o.stopRequestedAt,
      evidence: evidence)
    listenerScope = o.listenerScope
  }

  /// The `context` bits for a decision made under `armed` roles and `available` actions: one bit
  /// per role armed, then one per action available (Quick Add, Paste Last, Copy Last).
  package static func context(armed: Set<ShortcutRole>, available: Set<ShortcutRole>) -> UInt8 {
    var bits: UInt8 = 0
    for (i, role) in ShortcutRole.allCases.enumerated() where armed.contains(role) {
      bits |= 1 << UInt8(i)
    }
    for (i, role) in [ShortcutRole.quickAdd, .pasteLast, .copyLast].enumerated()
    where available.contains(role) {
      bits |= 1 << UInt8(5 + i)
    }
    return bits
  }

  /// What identifies the physical event (or, for a timer, its quick release) across lanes. Role,
  /// phase and outcome are deliberately absent: they are what the comparison checks.
  fileprivate var identity: Identity? {
    let anchor = category == .ingress ? rawOccurred : acceptedOccurred
    guard let anchor else { return nil }
    return Identity(generation: generation, category: category, keyCode: keyCode, anchor: anchor)
  }
}

private struct Identity: Hashable {
  let generation: UInt64
  let category: ShadowRecord.Category
  let keyCode: UInt16
  let anchor: TimeInterval
}

/// One comparison verdict.
package enum ShadowComparison: Sendable, Equatable {
  case agreement(live: ShadowRecord, shadow: ShadowRecord)
  /// The outcomes differ and the captured evidence proves it is the listener deciding earlier
  /// through the same policy (the #3534 race), not a different reading of the keys.
  case expectedTiming(live: ShadowRecord, shadow: ShadowRecord)
  case mappingError(live: ShadowRecord, shadow: ShadowRecord)
  case ambiguity(Ambiguity)
  /// Evidence was lost or never matched; a session with any of these cannot claim zero
  /// unexplained disagreements.
  case incomplete(Incomplete)

  package enum Ambiguity: Sendable, Equatable {
    case missingIdentity(ShadowRecord)
    case competingCounterparts(ShadowRecord, count: Int)
    case uncertainKeyState(live: ShadowRecord, shadow: ShadowRecord)
    case executorRetired(live: ShadowRecord, shadow: ShadowRecord)
    /// After a proven race the two lanes are in different attempts on that key; a pair where the
    /// shadow is still in the race's first attempt, or live in its second, follows from the race.
    case divergedAfterTiming(live: ShadowRecord, shadow: ShadowRecord)
    /// The lanes decided under different arming or availability (a recording transition between
    /// them), so a different role or outcome is not a mapping error.
    case contextDiffered(live: ShadowRecord, shadow: ShadowRecord)
  }

  package struct Incomplete: Sendable, Equatable {
    package enum Reason: Sendable, Equatable {
      case overflow
      case flush
      /// A record older than the retained identity history: it cannot be checked for duplicates.
      case outsideHistory
    }
    package let reason: Reason
    package let liveUnmatched: Int
    package let shadowUnmatched: Int
    package let unprovenTiming: Int

    package init(reason: Reason, liveUnmatched: Int, shadowUnmatched: Int, unprovenTiming: Int) {
      self.reason = reason
      self.liveUnmatched = liveUnmatched
      self.shadowUnmatched = shadowUnmatched
      self.unprovenTiming = unprovenTiming
    }
  }
}

/// Pairs live and shadow records and classifies each pair (#3544 P2). Called off the tap
/// callback. Every verdict depends only on the records' own evidence (identity, attempt origins,
/// captured times), never on the order the two lanes' records arrive in; evidence that is not yet
/// complete is held, bounded, and reported incomplete if it never completes.
///
/// Exits, in the order `add` and `classify` take them:
/// 1. no identity anchor: ambiguity.missingIdentity.
/// 2. a same-lane twin, several counterparts, or an identity already settled (paired or rejected,
///    kept for the last `pendingLimit` identities): ambiguity.competingCounterparts. A record whose
///    producer sequence is at or below what left that history fails closed as
///    incomplete.outsideHistory.
/// 3. either side aggregate-ambiguous or reconciled: ambiguity.uncertainKeyState.
/// 4. different role or phase: ambiguity.contextDiffered when the two were decided under different
///    arming or availability, otherwise mappingError.
/// 5. equal outcome: agreement.
/// 6. either side retired by the executor: ambiguity.executorRetired.
/// 7. a half of the #3534 race (see `raceHalf`): held until both halves exist and the joined
///    evidence checks out, then two expectedTiming; never approved alone.
/// 8. the two lanes are in different attempts (attempt origins differ): a consequence of a race;
///    ambiguity.divergedAfterTiming once that race's lineage is proven, held until then.
/// 9. anything else: ambiguity.contextDiffered under different contexts, otherwise mappingError.
/// Held evidence (pending records, race halves, dependent pairs, proven lineages) is each bounded
/// by `pendingLimit`; eviction and `flush` report what was lost as incomplete.
package final class KeyboardShadowComparator: Sendable {

  /// Pending records kept per lane, and the bound on every other held collection.
  package static let pendingLimit = 256

  /// One #3534 race: the attempt both lanes began with the same first press.
  private struct RaceKey: Hashable, Sendable {
    let generation: UInt64
    let keyCode: UInt16
    let role: ShortcutRole?
    let firstPress: TimeInterval
  }

  private struct Pair: Sendable {
    let live: ShadowRecord
    let shadow: ShadowRecord
  }

  /// The two halves a race needs before either is approved.
  private struct RaceEvidence: Sendable {
    var press: Pair?
    var timer: Pair?
  }

  /// A proven race's lineage: the shadow stayed in the attempt begun at `firstPress`, live began a
  /// new one at `secondPress`. Pairs from either attempt on this key follow from the race.
  private struct Lineage: Hashable, Sendable {
    let generation: UInt64
    let keyCode: UInt16
    let firstPress: TimeInterval
    let secondPress: TimeInterval
  }

  private struct State: Sendable {
    var pending: [ShadowRecord.Lane: [ShadowRecord]] = [.live: [], .shadow: []]
    var races: [RaceKey: RaceEvidence] = [:]
    var raceOrder: [RaceKey] = []
    var lineages: [Lineage] = []
    /// Pairs from two different attempts, waiting for a lineage that explains them.
    var dependents: [Pair] = []
    /// Identities already paired or rejected as competing, newest last, at most `pendingLimit`.
    /// A later record with one of them is a duplicate, whatever order the lanes arrived in.
    var settled: [Settled] = []
    /// Per lane, the highest producer sequence among records whose identity left `settled`. A
    /// record at or below it is older than the history and cannot be checked, so it fails closed.
    var watermark: [ShadowRecord.Lane: UInt64] = [:]
    /// Generations below this were closed by `flush(generationsBefore:)`; a later record from one
    /// can never reopen their comparison.
    var closedBefore: UInt64 = 0
  }

  private struct Settled: Sendable {
    let identity: Identity
    let sequences: [ShadowRecord.Lane: UInt64]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  package init() {}

  /// Add one record; returns every verdict it settles.
  package func add(_ record: ShadowRecord) -> [ShadowComparison] {
    state.withLock { s in
      guard let identity = record.identity else {
        return [.ambiguity(.missingIdentity(record))]
      }
      if record.generation < s.closedBefore {
        return [
          .incomplete(
            .init(
              reason: .outsideHistory, liveUnmatched: record.lane == .live ? 1 : 0,
              shadowUnmatched: record.lane == .shadow ? 1 : 0, unprovenTiming: 0))
        ]
      }
      if let w = s.watermark[record.lane], record.sequence <= w {
        return [
          .incomplete(
            .init(
              reason: .outsideHistory, liveUnmatched: record.lane == .live ? 1 : 0,
              shadowUnmatched: record.lane == .shadow ? 1 : 0, unprovenTiming: 0))
        ]
      }
      if s.settled.contains(where: { $0.identity == identity }) {
        return [.ambiguity(.competingCounterparts(record, count: 1))]
      }
      let other: ShadowRecord.Lane = record.lane == .live ? .shadow : .live
      let sameLaneTwin = s.pending[record.lane, default: []].contains { $0.identity == identity }
      let counterparts = s.pending[other, default: []].indices.filter {
        s.pending[other]![$0].identity == identity
      }
      if sameLaneTwin || counterparts.count > 1 {
        let removed =
          s.pending[other]!.filter { $0.identity == identity }
          + s.pending[record.lane]!.filter { $0.identity == identity } + [record]
        s.pending[other]!.removeAll { $0.identity == identity }
        s.pending[record.lane]!.removeAll { $0.identity == identity }
        Self.settle(&s, identity, removed)
        return [.ambiguity(.competingCounterparts(record, count: counterparts.count))]
      }
      if let index = counterparts.first {
        let match = s.pending[other]!.remove(at: index)
        let (live, shadow) = record.lane == .live ? (record, match) : (match, record)
        Self.settle(&s, identity, [live, shadow])
        return Self.classify(&s, Pair(live: live, shadow: shadow))
      }
      s.pending[record.lane, default: []].append(record)
      if s.pending[record.lane]!.count > Self.pendingLimit {
        s.pending[record.lane]!.removeFirst()
        return [Self.overflow(live: record.lane == .live ? 1 : 0, shadow: record.lane == .shadow ? 1 : 0)]
      }
      return []
    }
  }

  /// End a configuration generation or session: everything still unmatched, unproven or
  /// unexplained is reported as one incomplete verdict, never dropped silently.
  package func flush() -> [ShadowComparison] {
    state.withLock { s in
      let live = s.pending[.live, default: []].count
      let shadow = s.pending[.shadow, default: []].count
      let unproven = s.races.count + s.dependents.count
      s = State()
      guard live + shadow + unproven > 0 else { return [] }
      return [
        .incomplete(
          .init(
            reason: .flush, liveUnmatched: live, shadowUnmatched: shadow,
            unprovenTiming: unproven))
      ]
    }
  }

  /// Remember an identity as used, evicting the oldest past the bound and raising each lane's
  /// watermark to the evicted records' sequences.
  private static func settle(_ s: inout State, _ identity: Identity, _ records: [ShadowRecord]) {
    var sequences: [ShadowRecord.Lane: UInt64] = [:]
    for r in records { sequences[r.lane] = max(sequences[r.lane] ?? 0, r.sequence) }
    s.settled.append(Settled(identity: identity, sequences: sequences))
    guard s.settled.count > pendingLimit else { return }
    let evicted = s.settled.removeFirst()
    for (lane, sequence) in evicted.sequences {
      s.watermark[lane] = max(s.watermark[lane] ?? 0, sequence)
    }
  }

  /// Up to `limit` still-unmatched records per lane from generations older than `generation`, for
  /// the log line that lets a timestamp or identity mismatch be diagnosed, not only counted.
  package func pendingSamples(generationsBefore generation: UInt64, limit: Int) -> [ShadowRecord] {
    state.withLock { s in
      let live = s.pending[.live, default: []].filter { $0.generation < generation }.prefix(limit)
      let shadow = s.pending[.shadow, default: []].filter { $0.generation < generation }
        .prefix(limit)
      return Array(live) + Array(shadow)
    }
  }

  /// Close every configuration generation older than `generation`: what is still unmatched,
  /// unproven or unexplained there is reported as one incomplete verdict and dropped; newer
  /// generations and the identity history are kept.
  package func flush(generationsBefore generation: UInt64) -> [ShadowComparison] {
    state.withLock { s in
      let old = { (r: ShadowRecord) in r.generation < generation }
      let live = s.pending[.live, default: []].filter(old).count
      let shadow = s.pending[.shadow, default: []].filter(old).count
      s.pending[.live]?.removeAll(where: old)
      s.pending[.shadow]?.removeAll(where: old)
      let oldRaces = s.raceOrder.filter { $0.generation < generation }
      for key in oldRaces { s.races.removeValue(forKey: key) }
      s.raceOrder.removeAll { $0.generation < generation }
      let dependents = s.dependents.filter { $0.live.generation < generation }.count
      s.dependents.removeAll { $0.live.generation < generation }
      s.lineages.removeAll { $0.generation < generation }
      let unproven = oldRaces.count + dependents
      s.closedBefore = max(s.closedBefore, generation)
      guard live + shadow + unproven > 0 else { return [] }
      return [
        .incomplete(
          .init(
            reason: .flush, liveUnmatched: live, shadowUnmatched: shadow,
            unprovenTiming: unproven))
      ]
    }
  }

  private static func overflow(live: Int = 0, shadow: Int = 0, unproven: Int = 0)
    -> ShadowComparison
  {
    .incomplete(
      .init(reason: .overflow, liveUnmatched: live, shadowUnmatched: shadow, unprovenTiming: unproven))
  }

  // MARK: - Classification

  private static func classify(_ s: inout State, _ pair: Pair) -> [ShadowComparison] {
    let (live, shadow) = (pair.live, pair.shadow)
    if live.ambiguous || shadow.ambiguous || live.evidence == .reconciled
      || shadow.evidence == .reconciled
    {
      return [.ambiguity(.uncertainKeyState(live: live, shadow: shadow))]
    }
    // The same physical event read as a different role or phase is a mapping error, whatever the
    // outcomes and timing say.
    guard live.role == shadow.role, live.phase == shadow.phase else {
      if live.context != shadow.context {
        return [.ambiguity(.contextDiffered(live: live, shadow: shadow))]
      }
      return [.mappingError(live: live, shadow: shadow)]
    }
    if live.outcome == shadow.outcome {
      return [.agreement(live: live, shadow: shadow)]
    }
    if live.outcome == .gesture(.loneTapRetired) || shadow.outcome == .gesture(.loneTapRetired) {
      return [.ambiguity(.executorRetired(live: live, shadow: shadow))]
    }
    if let race = raceHalf(pair) {
      return addRaceHalf(&s, key: race.key, isPress: race.isPress, pair: pair)
    }
    if live.attemptStartOccurred != shadow.attemptStartOccurred {
      if lineage(of: pair, in: s.lineages) != nil {
        return [.ambiguity(.divergedAfterTiming(live: live, shadow: shadow))]
      }
      s.dependents.append(pair)
      if s.dependents.count > pendingLimit {
        s.dependents.removeFirst()
        return [overflow(unproven: 1)]
      }
      return []
    }
    if live.context != shadow.context {
      return [.ambiguity(.contextDiffered(live: live, shadow: shadow))]
    }
    return [.mappingError(live: live, shadow: shadow)]
  }

  /// Whether this pair is one half of the #3534 race, and which attempt it belongs to.
  ///
  /// Press half: live started fresh where the shadow locked, live consumed a stop-timer marker
  /// (`afterStopTimerMs`) whose origin is the first press the shadow locked against.
  ///
  /// Timer half: live's wait stopped the attempt, the shadow's was cancelled by the second press,
  /// both scheduled from the same first press, each deadline following its OWN release (the later
  /// of occurrence and that lane's handling) plus the window. The deadlines may differ when one
  /// lane handled the release late, so they are not compared with each other.
  private static func raceHalf(_ pair: Pair) -> (key: RaceKey, isPress: Bool)? {
    let (live, shadow) = (pair.live, pair.shadow)
    if live.category == .decision, live.outcome == .gesture(.start),
      shadow.outcome == .gesture(.lockIntent), live.afterStopTimerMs != nil,
      let first = shadow.attemptStartOccurred, live.markerOrigin == first
    {
      return (
        RaceKey(
          generation: live.generation, keyCode: live.keyCode, role: live.role, firstPress: first),
        true
      )
    }
    if live.category == .timer, live.outcome == .gesture(.loneTapStop),
      shadow.outcome == .gesture(.loneTapCancelled), let first = live.attemptStartOccurred,
      first == shadow.attemptStartOccurred, followsDeadlineFormula(live),
      followsDeadlineFormula(shadow)
    {
      return (
        RaceKey(
          generation: live.generation, keyCode: live.keyCode, role: live.role, firstPress: first),
        false
      )
    }
    return nil
  }

  /// `RecordGesture.release`'s deadline: the later of the release's occurrence and its handling,
  /// plus the window, for the times this lane recorded.
  private static func followsDeadlineFormula(_ r: ShadowRecord) -> Bool {
    guard let deadline = r.deadline, let occurred = r.acceptedOccurred else { return false }
    return deadline == max(occurred, r.handled) + RecordGesture.window
  }

  /// The joined check, from the captured times alone: the second press happened inside the
  /// first-press window, live's measurement of it agrees, it happened before live requested the
  /// stop, and live requested the stop before it handled that press.
  private static func joinedEvidenceHolds(key: RaceKey, press: Pair, timer: Pair) -> Bool {
    guard let stoppedAt = timer.live.stopRequestedAt,
      let second = press.live.acceptedOccurred,
      let afterStop = press.live.afterStopTimerMs,
      afterStop >= 0,
      second >= key.firstPress,
      second - key.firstPress <= RecordGesture.window,
      Int((second - key.firstPress) * 1000) == afterStop,
      second <= stoppedAt,
      stoppedAt <= press.live.handled
    else { return false }
    return true
  }

  /// Approve a race only when both halves exist and their joined evidence holds; until then hold
  /// it. Approval proves a lineage and settles the dependent pairs it explains.
  private static func addRaceHalf(
    _ s: inout State, key: RaceKey, isPress: Bool, pair: Pair
  ) -> [ShadowComparison] {
    var evidence = s.races[key] ?? RaceEvidence()
    if isPress { evidence.press = pair } else { evidence.timer = pair }
    guard let press = evidence.press, let timer = evidence.timer,
      joinedEvidenceHolds(key: key, press: press, timer: timer),
      let second = press.live.acceptedOccurred
    else {
      if s.races[key] == nil { s.raceOrder.append(key) }
      s.races[key] = evidence
      if s.raceOrder.count > pendingLimit {
        s.races.removeValue(forKey: s.raceOrder.removeFirst())
        return [overflow(unproven: 1)]
      }
      return []
    }
    s.races.removeValue(forKey: key)
    s.raceOrder.removeAll { $0 == key }
    var results: [ShadowComparison] = [
      .expectedTiming(live: timer.live, shadow: timer.shadow),
      .expectedTiming(live: press.live, shadow: press.shadow),
    ]
    s.lineages.append(
      Lineage(
        generation: key.generation, keyCode: key.keyCode, firstPress: key.firstPress,
        secondPress: second))
    if s.lineages.count > pendingLimit {
      s.lineages.removeFirst()
      results.append(overflow(unproven: 1))
    }
    let settled = s.dependents.filter { lineage(of: $0, in: s.lineages) != nil }
    s.dependents.removeAll { lineage(of: $0, in: s.lineages) != nil }
    results += settled.map { .ambiguity(.divergedAfterTiming(live: $0.live, shadow: $0.shadow)) }
    return results
  }

  /// The proven lineage a different-attempt pair belongs to: same configuration and key, and the
  /// shadow still in the race's first attempt or live in its second (the other side may have
  /// ended its attempt). Pairs where neither side is in a proven lineage are not explained.
  private static func lineage(of pair: Pair, in lineages: [Lineage]) -> Lineage? {
    lineages.first { l in
      l.generation == pair.live.generation && l.keyCode == pair.live.keyCode
        && (pair.shadow.attemptStartOccurred == l.firstPress
          || pair.live.attemptStartOccurred == l.secondPress)
    }
  }
}
