import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation

// MARK: - Observed correction watcher (#996 §3.1 steps 1–7)
//
// One watch per paste. The synchronous registry callback does two constant-
// time checks and books the paste; everything else (gates, Accessibility
// capture, alignment, filtering, judging) runs in a deferred task on the main
// actor. There is no app blocklist (founder 2026-09-19: no restrictions on
// where we watch; nothing leaves the Mac); the only destination refusal is the
// system's own secure-field subrole, which is a capability limit. Nothing here
// writes vocabulary: judged corrections are handed to
// `LearnedCorrectionCoordinator`, which saves at once and offers Undo
// (2026-09-21 plan §3.1 steps 8 and 10).
//
// Three guards, kept separate on purpose:
//   generation  the paste. A new paste supersedes everything before it.
//   cancelled   the toggle went off, the model disappeared, or capture never
//               began. A new dictation finishes a live observation but does
//               not cancel evidence already read from the previous paste.
//               Every pending suspension re-checks it before any side effect;
//               an observer ending (`.ended`) does NOT set it, because a
//               settled snapshot already sent to the judge is still evidence
//               about that paste.
//   revision    the edit. Bumped on every reported text change; a judge answer
//               about an older revision is `stale_result`.
//
// Generation × event:
//
//   event                      | guard                          | effect
//   ---------------------------|--------------------------------|---------------------------------
//   pasteCompleted, toggle off | (sync)                         | learn_skipped{toggle_off} (deferred)
//   pasteCompleted, watch on   | (sync)                         | learn_skipped{watch_active} (deferred)
//   pasteCompleted             | (sync)                         | generation+1, paste booked, task
//   begin: gates fail          | current, not cancelled         | learn_skipped{reason}, watch cleared
//   begin: after capabilities  | current, not cancelled         | else nothing (cancelled: no capture)
//   begin: capture ended       | current, not cancelled         | observation_ended{reason, 0}
//   begin: captured            | current, not cancelled         | observer.start
//   observer .changed          | current, not cancelled, live   | revision+1, remembered
//   observer .settled          | current, not cancelled, live,  | reserve burst n+1 → align → filter →
//                              |   bursts < 2, new snapshot     |   reserve call and pair keys → judge
//   observer .ended            | current, live                  | observation_ended{reason, bursts};
//                              |                                |   pending judge answers stay valid
//   judge answer               | current, not cancelled,        | learn_judged, vocabulary saves
//                              |   revision unchanged           |
//   judge answer               | otherwise                      | stale_result counted, dropped
//   recordingStarted           | live, observing                | observer.finish: pending fix
//                              |                                |   flushed as .settled, then .ended
//                              |                                |   {next_dictation}; answers stay valid
//   recordingStarted           | live, not yet observing        | cancelled, observer.stop,
//                              |                                |   observation_ended{next_dictation}
//   toggle off (next tick)     | live                           | cancelled, observer.stop,
//                              |                                |   learn_skipped{toggle_off}; no
//                              |                                |   observation row (closed set)
//   new paste while judging    | generation+1                   | old answers stale
//
// Interrupter × boundary. Five things can interrupt a watch: a new paste (P,
// generation), a new dictation (D, `recordingStarted`), the toggle going off
// (T, `learnFromEditsChanged` or a re-read of the setting), the observer ending
// on its own (E) and a text change (R, revision). Six places resume work after
// a queue or a suspension; each one re-checks every interrupter that applies:
//
//   boundary                     | P       | D        | T                    | E      | R
//   -----------------------------|---------|----------|----------------------|--------|-------
//   B1 begin entry (queued task) | drop    | drop     | skipped{toggle_off}  | n/a    | n/a
//   B2 after `await capabilities`| drop    | drop     | skipped{toggle_off}  | n/a    | n/a
//   B3 observer event entry      | drop    | drop     | cancel: stop, count  | n/a    | n/a
//   B4 judge task start          | stale   | ask      | cancel + stale       | ask    | stale
//   B5 after `await judge`       | stale   | apply    | cancel + stale       | apply  | stale
//   B6 learn loop                | re-checked before EACH save: the sink and every
//                                |   `learn` can re-enter synchronously (the presenter,
//                                |   a setting observer); only a newer paste, toggle-off,
//                                |   model removal or revision change drops the rest of
//                                |   the answer as one stale result. A pill that replaces
//                                |   the previous pill does not stop later saves.
//
// T sets `cancelled` even after E: the observation row was emitted once and
// is not repeated, and a pending answer about text the user asked us to stop
// watching is never applied. D no longer cancels (#996 cursor-aware settling,
// Codex r30): a settled snapshot is evidence about THAT paste whatever is
// dictated next, so a live observation finishes through the observer (flushing
// a pending fix like a send) and pending answers stay valid; accepted pairs
// save immediately, even when the Undo pill cannot claim the overlay slot.

/// The runtime arm the watcher may ask. Production selection comes from
/// `CorrectionJudgeArmSelection.select` and its measured qualification table;
/// tests inject an arm directly.
struct SelectedCorrectionJudge {
  let arm: TelemetryService.LearnFromEditsTelemetry.Arm
  let judge: any CorrectionJudging
  /// The delivered classifier's pinned revision (the delivery manifest's), or
  /// `uat_door` for the Debug export door; nil for the rules and AFM arms. Only
  /// Judge 1's Sentry reports read it (#3105).
  var revision: String? = nil
}

/// The active application, sampled ONCE per gate pass so pid and bundle id
/// describe the same process.
struct FrontmostApplication: Equatable, Sendable {
  let pid: pid_t
  let bundleID: String?
}

/// The watcher's three telemetry events (#996 §4): why a paste was not
/// watched, how a watched paste ended, and what the judge answered. Counts,
/// durations and closed enums only, never text. `TelemetryService` conforms in
/// the wiring; tests pass a spy. The learned coordinator's four events live on
/// `LearnedCorrectionTelemetrySink`; `LearnFromEditsRuntimeTelemetrySink` is
/// the union the runtime composes.
@MainActor
protocol LearnFromEditsTelemetrySink: AnyObject {
  typealias T = TelemetryService.LearnFromEditsTelemetry
  /// `takeID` (#3105) is the paste's take, the join key to its own rows; nil
  /// when the paste carried none (the wire row omits the key).
  func learnSkipped(reason: T.SkipReason, takeID: String?)
  /// `regionDetail` (#3105): the observer's counts-only loss shape for a watch
  /// that lost the text; nil for every other end.
  func learnObservationEnded(
    reason: PastedRegionEndReason, settledBursts: Int, appClass: T.AppClass, durationMs: Int,
    unfinishedEdits: Int, takeID: String?, regionDetail: PastedRegionEndDetail?)
  /// `queueWaitMs` nil = not measured by this arm (the wire row omits the key).
  func learnJudged(
    arm: T.Arm, outcome: T.JudgeOutcome, candidates: Int, accepted: Int, latencyMs: Int,
    queueWaitMs: Int?, takeID: String?)
}

@MainActor
struct ObservedCorrectionWatcherDependencies {
  let isLearnFromEditsOn: () -> Bool
  /// nil = `model_unavailable`.
  let selectJudge: () -> SelectedCorrectionJudge?
  let frontmost: () -> FrontmostApplication?
  let observer: any PastedRegionObserving
  /// The observer scheduler's clock, so the paste deadline shares its domain.
  let nowMs: () -> Int
  let userWords: () -> [CustomWord]
  let packTerms: () -> [CustomWord]
  /// Saves an accepted correction at once and offers Undo (2026-09-21 plan).
  let coordinator: LearnedCorrectionCoordinator
  /// Bound on ONE judge call, whatever the arm: the AFM judge bounds itself,
  /// the rules judge is immediate, but a Core ML `prediction` can wedge and
  /// nothing above it would ever answer. Production: `correctionJudgeDeadlineSeconds`
  /// plus one, so the AFM judge's own deadline reports first. Tests shorten it.
  var judgeDeadlineSeconds: Double = WordSuggestionService.correctionJudgeDeadlineSeconds + 1
  let telemetry: any LearnFromEditsTelemetrySink
  /// Judge 1 defects reach Sentry once per process per kind (#3105).
  var failureReporter: LearnJudgeFailureReporter = .shared
}

@MainActor
final class ObservedCorrectionWatcher: PasteCompletionObserver {

  /// Plan §3.1 step 4: at most two settled bursts are judged per paste.
  static let maxJudgeCallsPerPaste = 2

  private struct Watch {
    let generation: UInt64
    let event: PasteCompletionEvent
    let pastedAtMs: Int
    var selected: SelectedCorrectionJudge?
    var target: PastedRegionTarget?
    var appClass: TelemetryService.LearnFromEditsTelemetry.AppClass = .other
    var revision: UInt64 = 0
    var settledSnapshots: Set<String> = []
    var settledBursts = 0
    /// Distinct runs withheld as deletion-only half-typed fixes (#3105), per
    /// paste: keyed by pair so a run still present in the second settled
    /// snapshot is not counted twice.
    var unfinishedPairKeys: Set<String> = []
    var judgeCalls = 0
    /// Pairs already reserved for the judge in this paste; burst two never
    /// re-sends them.
    var sentPairKeys: Set<String> = []
    /// The observer finished (naturally). Judge answers may still arrive.
    var ended = false
    /// Cut short before or during observation by toggle-off, model removal, or
    /// a watch that never reached capture. A new dictation is not cancellation.
    var cancelled = false
    var isLive: Bool { !ended && !cancelled }
  }

  private let deps: ObservedCorrectionWatcherDependencies
  private var watch: Watch?
  private var generation: UInt64 = 0
  /// Diagnostics: reserved judge calls not asked, or answers dropped, because
  /// a newer paste, toggle-off, model removal, or edit superseded them.
  private(set) var staleResults = 0
  /// Diagnostics: watches cut short because the toggle went off mid-watch.
  private(set) var toggledOffMidWatch = 0
  /// `learn_skipped{model_unavailable}` is reported ONCE per launch. The arm
  /// selection is fixed for the process (production has no judge on every
  /// macOS today), so a row per paste would add one contentless event to
  /// every dictation for every user; the first row already says it.
  private var reportedModelUnavailable = false

  init(dependencies: ObservedCorrectionWatcherDependencies) {
    self.deps = dependencies
  }

  var isWatching: Bool { watch?.isLive ?? false }

  // MARK: Step 1: the synchronous callback

  func pasteCompleted(_ event: PasteCompletionEvent) {
    guard deps.isLearnFromEditsOn() else {
      Task { @MainActor [deps] in deps.telemetry.learnSkipped(reason: .toggleOff, takeID: event.takeID) }
      return
    }
    guard !isWatching else {
      Task { @MainActor [deps] in deps.telemetry.learnSkipped(reason: .watchActive, takeID: event.takeID) }
      return
    }
    // Reserve the watch BEFORE scheduling: a second paste arriving before the
    // task runs sees `watch_active`, never a duplicate deferred start.
    generation &+= 1
    let gen = generation
    watch = Watch(generation: gen, event: event, pastedAtMs: deps.nowMs())
    Task { @MainActor [weak self] in
      await self?.begin(generation: gen)
    }
  }

  /// A new dictation started. A LIVE observation finishes through the
  /// observer, which flushes a fix typed before the recording the way a send
  /// does (Wispr Flow's second stop signal; Codex r30) and delivers
  /// `.ended(.nextDictationStarted)` through `handle`, so that burst's answer
  /// stays valid like any other observer end. A watch that never reached
  /// observation is cancelled outright (no capture, one row below); one that
  /// already ended keeps its row and its pending answers untouched.
  func recordingStarted() {
    guard let w = watch, !w.cancelled else { return }
    guard !w.ended else { return }
    if deps.observer.isObserving {
      deps.observer.finish(.nextDictationStarted)
      return
    }
    watch?.cancelled = true
    w.event.editCapture?.cancelEditWatchCapture()
    deps.observer.stop()
    emitEnded(reason: .nextDictationStarted, generation: w.generation)
  }

  /// The setting changed (wired from the settings observer). Off cancels the
  /// current watch and every pending answer; on changes nothing in flight.
  func learnFromEditsChanged(isOn: Bool) {
    guard !isOn, let w = watch else { return }
    cancelForToggleOff(generation: w.generation)
  }

  /// #996 phase D: the delivered judge is being removed. A live watch is cut
  /// and its capture stopped, with NO telemetry: the observation vocabulary has
  /// no reason for it and `toggle_off` / `next_dictation_started` would be
  /// lies. A judgement already in flight finishes against the actor, which the
  /// wiring drains before the bytes go; its answer is dropped as stale by the
  /// cancelled watch. Idempotent.
  func modelBecameUnavailable() {
    // The watch's `selected` is a strong reference to the judge (cloud review
    // P2): an ended watch would keep the model mapped until the next paste, and
    // removal would report success without reclaiming the disk. Dropped here;
    // an in-flight judgement holds its own copy and the wiring drains the
    // actor before the bytes go.
    watch?.selected = nil
    guard let w = watch, !w.cancelled else { return }
    watch?.cancelled = true
    guard !w.ended else { return }
    w.event.editCapture?.cancelEditWatchCapture()
    deps.observer.stop()
  }

  /// One accounting for the toggle going off wherever it is noticed (B3, B4,
  /// B5 or the setting observer): a LIVE watch is cut, capture stops and the
  /// paste is counted as learn_skipped{toggle_off} (the observation vocabulary
  /// has no reason for it, so it is counted rather than dropped from the
  /// funnel); a watch whose observation already ended is only voided, its
  /// pending answers drop as stale. Idempotent per watch.
  private func cancelForToggleOff(generation gen: UInt64) {
    guard let w = watch, w.generation == gen, !w.cancelled else { return }
    watch?.cancelled = true
    guard !w.ended else { return }
    // A pending capture stops reading for a watch that no longer exists.
    w.event.editCapture?.cancelEditWatchCapture()
    deps.observer.stop()
    toggledOffMidWatch += 1
    deps.telemetry.learnSkipped(reason: .toggleOff, takeID: w.event.takeID)
  }

  // MARK: Steps 2–3: the deferred gates and capture

  private func begin(generation gen: UInt64) async {
    guard let booked = watch, booked.generation == gen, booked.isLive else { return }
    guard deps.isLearnFromEditsOn() else {
      skip(.toggleOff, generation: gen)
      return
    }
    guard let selected = deps.selectJudge() else {
      skip(.modelUnavailable, generation: gen, report: !reportedModelUnavailable)
      reportedModelUnavailable = true
      return
    }
    let capabilities = await selected.judge.capabilities
    // Anything can have happened during the await: a new paste, a dictation,
    // the toggle. Re-read the watch; a cancelled or superseded one does no AX work.
    guard var w = watch, w.generation == gen, w.isLive else { return }
    guard deps.isLearnFromEditsOn() else {
      skip(.toggleOff, generation: gen)
      return
    }
    guard let frontmost = deps.frontmost(), frontmost.bundleID == w.event.destinationBundleID
    else {
      skip(.destinationMismatch, generation: gen)
      return
    }
    w.selected = selected
    // #3106 PR A: the paste's own arrival session reads the field and owns the retries (its capture
    // grace runs from THIS request, however long the gates above took). The watcher only asks.
    guard let editCapture = w.event.editCapture else {
      watch = w
      watch?.ended = true
      emitEnded(reason: .captureUnsupported, generation: gen)
      return
    }
    let outcome = await editCapture.editWatchCapture(pastedAtMs: w.pastedAtMs)
    // Anything can have happened during the await: a new paste, a dictation,
    // the toggle. The same re-reads as after the capabilities await; a stale
    // answer never starts a watch on a later take.
    guard let live = watch, live.generation == gen, live.isLive else { return }
    guard deps.isLearnFromEditsOn() else {
      skip(.toggleOff, generation: gen)
      return
    }
    guard let again = deps.frontmost(), again.pid == frontmost.pid else {
      skip(.destinationMismatch, generation: gen)
      return
    }
    switch outcome {
    case .skipped(let reason):
      switch reason {
      case .secureField: skip(.secureField, generation: gen)
      case .noFocusedElement: skip(.noFocusedElement, generation: gen)
      case .destinationMismatch: skip(.destinationMismatch, generation: gen)
      }
    case .ended(let reason):
      watch = w
      watch?.ended = true
      emitEnded(reason: reason, generation: gen)
    case .captured(let target):
      w.target = target
      // A recognised browser (Safari, or a Chromium family member, which is
      // also a manual-accessibility host) is counted as `browser` so the
      // funnel can be read per destination class; other Electron hosts are
      // `manual_accessibility`; everything else `native`.
      w.appClass = PasteLandingAppClass.classify(
        bundleIdentifier: w.event.destinationBundleID,
        isManualAccessibilityHost: target.isManualAccessibilityHost)
      watch = w
      deps.observer.start(target) { [weak self] event in
        self?.handle(event, generation: gen)
      }
    }
  }

  private func skip(
    _ reason: TelemetryService.LearnFromEditsTelemetry.SkipReason, generation gen: UInt64,
    report: Bool = true
  ) {
    guard let w = watch, w.generation == gen else { return }
    watch = nil
    if report { deps.telemetry.learnSkipped(reason: reason, takeID: w.event.takeID) }
  }

  // MARK: Step 4: observation events

  private func handle(_ event: PastedRegionEvent, generation gen: UInt64) {
    guard let w = watch, w.generation == gen, w.isLive else { return }
    // B3: toggle-off mid-watch is noticed at this tick.
    guard deps.isLearnFromEditsOn() else {
      cancelForToggleOff(generation: gen)
      return
    }
    switch event {
    case .changed:
      watch?.revision &+= 1
    case .settled(let region):
      guard w.settledBursts < Self.maxJudgeCallsPerPaste, !w.settledSnapshots.contains(region)
      else { return }
      watch?.settledSnapshots.insert(region)
      watch?.settledBursts += 1
      judgeBurst(region: region, generation: gen, revision: w.revision)
    case .ended(let reason):
      watch?.ended = true
      // Only an end the OBSERVER delivered carries its loss detail; a
      // capture-time end never started an observation (#3105).
      emitEnded(reason: reason, generation: gen, detail: Self.lossDetail(reason, from: deps.observer))
    }
  }

  private func emitEnded(
    reason: PastedRegionEndReason, generation gen: UInt64, detail: PastedRegionEndDetail? = nil
  ) {
    guard let w = watch, w.generation == gen else { return }
    deps.telemetry.learnObservationEnded(
      reason: reason, settledBursts: w.settledBursts, appClass: w.appClass,
      durationMs: max(0, deps.nowMs() - w.pastedAtMs), unfinishedEdits: w.unfinishedPairKeys.count,
      takeID: w.event.takeID, regionDetail: detail)
  }

  /// The observer's loss detail belongs only to the ends the observer itself
  /// decided from a read (a watcher-decided end such as a new dictation has none).
  static func lossDetail(
    _ reason: PastedRegionEndReason, from observer: any PastedRegionObserving
  ) -> PastedRegionEndDetail? {
    switch reason {
    case .regionRemoved, .anchorAmbiguous, .editDistanceExceeded: observer.lastEndDetail
    default: nil
    }
  }

  // MARK: Steps 5–7: align, filter, judge

  /// Synchronous up to the reservation: alignment, filtering and the
  /// reservation of the call count and pair keys all happen before any
  /// suspension, so two bursts cannot both submit the same pair.
  private func judgeBurst(region: String, generation gen: UInt64, revision: UInt64) {
    guard let w = watch, w.generation == gen, w.isLive, let selected = w.selected,
      let target = w.target, w.judgeCalls < Self.maxJudgeCallsPerPaste
    else { return }
    let alignment = EditAlignment.align(pasted: target.pastedText, edited: region)
    guard !alignment.limitExceeded, !alignment.runs.isEmpty else { return }
    let language = w.event.language
    // The live words only: there is no rejection memory and no open-proposal
    // ledger any more (2026-09-21 plan §3.1 step 11).
    let inputs = CorrectionCandidateFilter.Inputs(
      userWords: deps.userWords(), packTerms: deps.packTerms())
    var filtered = CorrectionCandidateFilter.filter(runs: alignment.runs, inputs: inputs)
    filtered.removeAll { w.sentPairKeys.contains($0.pairKey) }
    for run in filtered where run.disposition == .ineligible(.unfinishedEdit) {
      watch?.unfinishedPairKeys.insert(run.pairKey)
    }
    let eligible = filtered.filter {
      if case .candidate = $0.disposition { return true }
      return false
    }
    guard !eligible.isEmpty else { return }
    // One request per judge WINDOW of the pasted sentence: the judge was
    // trained and examined on the PASTED sentence (`Sentence:` is the
    // dictation, `Edit:` the pair; `train_edit_judge.py`, the exam,
    // `CoreMLCorrectionJudge`), so each request's context is the immutable
    // pasted text centred on that group's first candidate through the run's
    // ORIGINAL-side token range, and every candidate in the request lies
    // inside that window (cloud review of PR #3054, rounds 5 and 6). Groups
    // beyond the per-paste call budget are left unreserved.
    let arm = selected.arm
    let judge = selected.judge
    for group in Self.windowGroups(eligible, in: target.pastedText) {
      guard let live = watch, live.generation == gen, live.isLive,
        live.judgeCalls < Self.maxJudgeCallsPerPaste
      else { return }
      let prepared = CorrectionCandidateFilter.prepare(group)
      guard let first = prepared.candidates.first, let anchor = prepared.byID[first.id] else { continue }
      let context = Self.contextExcerpt(target.pastedText, focusTokens: anchor.run.originalRange)
      let request: CorrectionJudgeRequest
      do {
        request = try CorrectionJudgeRequest(
          candidates: prepared.candidates, context: context, language: language)
      } catch {
        // A request the watcher built and the judge contract refused is our
        // defect, not the user's edit: report its closed cause, no text.
        deps.failureReporter.report(
          .requestBuildFailed,
          cause: (error as? CorrectionJudgeRequestError)?.causeCode ?? "other",
          arm: arm.rawValue, judgeRevision: selected.revision)
        continue
      }
      // Reservation, atomically with the checks above (no suspension so far).
      watch?.judgeCalls += 1
      for key in prepared.byID.values.map(\.pairKey) { watch?.sentPairKeys.insert(key) }
      Task { @MainActor [weak self] in
        await self?.ask(
          judge, arm: arm, request: request, prepared: prepared, generation: gen,
          revision: revision)
      }
    }
  }

  private func ask(
    _ judge: any CorrectionJudging, arm: TelemetryService.LearnFromEditsTelemetry.Arm,
    request: CorrectionJudgeRequest, prepared: CorrectionCandidateFilter.Prepared,
    generation gen: UInt64, revision: UInt64
  ) async {
    // B4: the queued call may run after the watch moved on. A reserved call
    // that is no longer about the current text is not asked at all.
    guard stillWanted(generation: gen, revision: revision) else { return }
    let started = deps.nowMs()
    let outcome =
      await withDeadline(seconds: deps.judgeDeadlineSeconds) { await judge.judge(request) }
      ?? .bypass(.deadline)
    let latency = max(0, deps.nowMs() - started)
    // B5: the paste, the watch, the toggle or the text may have moved on while
    // the judge thought; a superseded, cancelled or revised watch drops the answer.
    guard stillWanted(generation: gen, revision: revision) else { return }
    let accepted: Int
    switch outcome {
    case .verdict(let decisions):
      accepted = decisions.filter { $0.verdict.vocabularyCorrection }.count
    case .bypass: accepted = 0
    }
    // Queue wait is a property of the AFM arm's permit; the watcher does not
    // measure it, so it is reported as unknown rather than as zero.
    deps.telemetry.learnJudged(
      arm: arm, outcome: .init(outcome), candidates: prepared.candidates.count,
      accepted: accepted, latencyMs: latency, queueWaitMs: nil,
      takeID: watch?.event.takeID)
    guard case .verdict(let decisions) = outcome else { return }
    #if DEBUG
      // Local debug log only (plan §11 UAT tokens): what the judge was asked and
      // what it answered, pair by pair, so a Live UAT can read a refusal from
      // app.log the way it reads a save. Release logs no user text.
      for decision in decisions {
        let pair =
          prepared.byID[decision.id].map { "\"\($0.run.coreOriginal)\" -> \"\($0.run.coreReplacement)\"" }
          ?? "id \(decision.id)"
        LearnedCorrectionCoordinator.debugLog("judged \(pair) verdict=\(decision.verdict)")
      }
    #endif
    for decision in decisions where decision.verdict.vocabularyCorrection {
      guard let f = prepared.byID[decision.id], case .candidate(let expectedTarget) = f.disposition
      else {
        continue
      }
      // B6: the emission above and each save below run injected callbacks
      // synchronously (the presenter, the words coordinator); any of them may
      // have cancelled or superseded the watch, and a stale watch saves no
      // more. A save that merely replaced the previous pill is not a reason
      // to stop: the settled evidence for the next pair is still valid.
      guard stillWanted(generation: gen, revision: revision) else { return }
      deps.coordinator.learn(
        original: f.run.coreOriginal, corrected: f.run.coreReplacement,
        expectedTarget: expectedTarget)
    }
  }

  /// The B4/B5 check: the toggle is re-read first (off cancels through the
  /// one toggle-off accounting), then the watch must be the same paste, not
  /// cancelled and at the revision the request described. Anything else counts
  /// one stale result.
  private func stillWanted(generation gen: UInt64, revision: UInt64) -> Bool {
    if !deps.isLearnFromEditsOn() { cancelForToggleOff(generation: gen) }
    guard let w = watch, w.generation == gen, !w.cancelled, w.revision == revision else {
      staleResults += 1
      return false
    }
    return true
  }

  /// At most `CorrectionJudgeRequest.maxContextUTF16` units of the settled
  /// text, cut on a Character boundary so no grapheme is split.
  /// The judge's `Sentence:` context, at most `maxContextUTF16` units of the
  /// settled region. A region longer than that is CENTRED on `focusTokens`
  /// (the edited-side TOKEN range of the candidate the judge will see, from
  /// `EditAlignment.Run.editedRange`, counted the way the aligner counts:
  /// whitespace-separated words), then moved forward to a word boundary, so a
  /// fix late in a long dictation is judged with its own sentence and not
  /// with the paragraph's opening (cloud review of PR #3054, two rounds: a
  /// text search for the replacement found an EARLIER occurrence belonging to
  /// a run the filter had dropped). With no focus the prefix is kept.
  static func contextExcerpt(
    _ text: String, focusTokens: Range<Int>? = nil,
    limit: Int = CorrectionJudgeRequest.maxContextUTF16
  ) -> String {
    String(text[excerptWindow(text, focusTokens: focusTokens, limit: limit)])
  }

  /// The window `contextExcerpt` cuts, as a range of `text`, so a caller can
  /// also ask which OTHER candidates fall inside it (cloud review of PR #3054,
  /// round 6: two eligible edits more than a window apart were sent in one
  /// request and the second was judged without its sentence).
  static func excerptWindow(
    _ text: String, focusTokens: Range<Int>? = nil,
    limit: Int = CorrectionJudgeRequest.maxContextUTF16
  ) -> Range<String.Index> {
    let total = text.utf16.count
    guard total > limit else { return text.startIndex..<text.endIndex }
    var start = text.startIndex
    if let focusTokens, !focusTokens.isEmpty, let hit = Self.tokenSpan(focusTokens, in: text) {
      let hitStart = text.utf16.distance(from: text.startIndex, to: hit.lowerBound)
      let hitLength = text.utf16.distance(from: hit.lowerBound, to: hit.upperBound)
      // Leave the hit in the middle of the window, and never start past the
      // point where a full window would run off the end.
      var want = max(0, hitStart - (limit - min(hitLength, limit)) / 2)
      want = min(want, max(0, total - limit))
      var walked = 0
      var index = text.startIndex
      while index < text.endIndex, walked < want {
        walked += String(text[index]).utf16.count
        index = text.index(after: index)
      }
      start = index
      // Forward to the next word start, never back: backing up would push the
      // window's END before the text's end when the start was clamped there.
      while start < text.endIndex, start > text.startIndex,
        !text[text.index(before: start)].isWhitespace
      {
        start = text.index(after: start)
      }
    }
    var used = 0
    var end = start
    while end < text.endIndex {
      let unit = String(text[end]).utf16.count
      if used + unit > limit { break }
      used += unit
      end = text.index(after: end)
    }
    return start..<end
  }

  /// Split eligible runs into groups that each fit ONE judge window of the
  /// pasted text. The anchor of a group is the run `prepare` would put FIRST
  /// (capitalised replacements first, then source order), so the window the
  /// group is admitted to is the window the request is centred on; every run
  /// whose original tokens lie inside it joins, the rest anchor the next
  /// group. A pair key occurs once (a second edit of the same pair is the same
  /// correction pair), and a run whose original tokens cannot be found in the pasted
  /// text is left out rather than judged under an unrelated window (Codex
  /// round 8).
  static func windowGroups(
    _ runs: [CorrectionCandidateFilter.Filtered], in text: String,
    limit: Int = CorrectionJudgeRequest.maxContextUTF16
  ) -> [[CorrectionCandidateFilter.Filtered]] {
    var seenPairKeys = Set<String>()
    var remaining = runs.filter { run in
      guard tokenSpan(run.run.originalRange, in: text) != nil else { return false }
      return seenPairKeys.insert(run.pairKey).inserted
    }
    var groups: [[CorrectionCandidateFilter.Filtered]] = []
    while !remaining.isEmpty {
      let ordered = CorrectionCandidateFilter.prepare(remaining)
      guard let first = ordered.candidates.first, let anchor = ordered.byID[first.id] else { break }
      let window = excerptWindow(text, focusTokens: anchor.run.originalRange, limit: limit)
      var inside: [CorrectionCandidateFilter.Filtered] = []
      var outside: [CorrectionCandidateFilter.Filtered] = []
      for run in remaining {
        if run.pairKey == anchor.pairKey {
          inside.append(run)
          continue
        }
        guard let span = tokenSpan(run.run.originalRange, in: text) else { continue }
        if span.lowerBound >= window.lowerBound, span.upperBound <= window.upperBound {
          inside.append(run)
        } else {
          outside.append(run)
        }
      }
      groups.append(inside)
      remaining = outside
    }
    return groups
  }

  /// The character span of whitespace-separated tokens `range` in `text`, the
  /// same tokenisation `EditAlignment.align` uses (`splitWords`: split on
  /// `Character.isWhitespace`). `nil` when the text has fewer tokens.
  static func tokenSpan(_ range: Range<Int>, in text: String) -> Range<String.Index>? {
    var tokenIndex = -1
    var inToken = false
    var spanStart: String.Index?
    var index = text.startIndex
    while index < text.endIndex {
      let isSpace = text[index].isWhitespace
      if !isSpace, !inToken {
        tokenIndex += 1
        if tokenIndex == range.lowerBound { spanStart = index }
      }
      if isSpace, inToken, tokenIndex == range.upperBound - 1, let spanStart {
        return spanStart..<index
      }
      inToken = !isSpace
      index = text.index(after: index)
    }
    if let spanStart, tokenIndex == range.upperBound - 1 { return spanStart..<text.endIndex }
    return nil
  }
}
