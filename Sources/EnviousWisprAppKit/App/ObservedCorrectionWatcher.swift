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
// writes vocabulary or the ledger: judged corrections are handed to
// `CorrectionProposalCoordinator`, which owns steps 8–10.
//
// Three guards, kept separate on purpose:
//   generation  the paste. A new paste supersedes everything before it.
//   cancelled   the watch was cut short by something other than the observer
//               (a new dictation, the toggle going off). Every pending
//               suspension re-checks it before any side effect; an observer
//               ending (`.ended`) does NOT set it, because a settled snapshot
//               already sent to the judge is still evidence about that paste.
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
//   judge answer               | current, not cancelled,        | learn_judged, proposals
//                              |   revision unchanged           |
//   judge answer               | otherwise                      | stale_result counted, dropped
//   recordingStarted           | live                           | cancelled, observer.stop,
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
//   B4 judge task start          | stale   | stale    | cancel + stale       | ask    | stale
//   B5 after `await judge`       | stale   | stale    | cancel + stale       | apply  | stale
//   B6 propose loop              | re-checked before EACH proposal: the sink and every
//                                |   `propose` can re-enter synchronously (an offer that
//                                |   starts a dictation, a setting observer); the rest
//                                |   of the answer is dropped as one stale result
//
// D and T set `cancelled` even after E: the observation row was emitted once
// and is not repeated, but a pending answer about text that is being replaced
// (D) or that the user asked us to stop watching (T) is never applied.

/// The runtime arm the watcher may ask. Production selection comes from
/// `CorrectionJudgeArmSelection.select` with the measured table (empty today,
/// so production yields `.unavailable` and nothing is watched); tests inject
/// an arm directly.
struct SelectedCorrectionJudge {
  let arm: TelemetryService.LearnFromEditsTelemetry.Arm
  let judge: any CorrectionJudging
}

/// The active application, sampled ONCE per gate pass so pid and bundle id
/// describe the same process.
struct FrontmostApplication: Equatable, Sendable {
  let pid: pid_t
  let bundleID: String?
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
  let coordinator: CorrectionProposalCoordinator
  let telemetry: any LearnFromEditsTelemetrySink
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
    var supportedLanguages: Set<String>?
    var target: PastedRegionTarget?
    var appClass: TelemetryService.LearnFromEditsTelemetry.AppClass = .other
    var revision: UInt64 = 0
    var settledSnapshots: Set<String> = []
    var settledBursts = 0
    var judgeCalls = 0
    /// Pairs already reserved for the judge in this paste; burst two never
    /// re-sends them.
    var sentPairKeys: Set<String> = []
    /// The observer finished (naturally). Judge answers may still arrive.
    var ended = false
    /// Cut short by a new dictation or the toggle: no pending work may act.
    var cancelled = false
    var isLive: Bool { !ended && !cancelled }
  }

  private let deps: ObservedCorrectionWatcherDependencies
  private var watch: Watch?
  private var generation: UInt64 = 0
  /// Diagnostics: reserved judge calls not asked, or answers dropped, because a
  /// newer paste, a dictation, the toggle or an edit superseded them.
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
      Task { @MainActor [deps] in deps.telemetry.learnSkipped(reason: .toggleOff) }
      return
    }
    guard !isWatching else {
      Task { @MainActor [deps] in deps.telemetry.learnSkipped(reason: .watchActive) }
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

  /// A new dictation started: the pasted text is about to be replaced by the
  /// next one, so the current watch is cancelled (pending work included).
  func recordingStarted() {
    guard let w = watch, !w.cancelled else { return }
    watch?.cancelled = true
    // An observation that already ended emitted its row; only its pending
    // answers are voided (they drop as stale at B4/B5).
    guard !w.ended else { return }
    deps.observer.stop()
    emitEnded(reason: .nextDictationStarted, generation: w.generation)
  }

  /// The setting changed (wired from the settings observer). Off cancels the
  /// current watch and every pending answer; on changes nothing in flight.
  func learnFromEditsChanged(isOn: Bool) {
    guard !isOn, let w = watch else { return }
    cancelForToggleOff(generation: w.generation)
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
    deps.observer.stop()
    toggledOffMidWatch += 1
    deps.telemetry.learnSkipped(reason: .toggleOff)
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
    guard let language = w.event.language, let supported = capabilities.supportedLanguages,
      supported.contains(language)
    else {
      skip(.languageUnsupported, generation: gen)
      return
    }
    guard let frontmost = deps.frontmost(), frontmost.bundleID == w.event.destinationBundleID
    else {
      skip(.destinationMismatch, generation: gen)
      return
    }
    w.selected = selected
    w.supportedLanguages = capabilities.supportedLanguages
    switch deps.observer.capture(
      pid: frontmost.pid, pastedText: w.event.pastedText, pastedAtMs: w.pastedAtMs)
    {
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
      w.appClass = target.isManualAccessibilityHost ? .manualAccessibility : .native
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
    guard watch?.generation == gen else { return }
    watch = nil
    if report { deps.telemetry.learnSkipped(reason: reason) }
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
      emitEnded(reason: reason, generation: gen)
    }
  }

  private func emitEnded(reason: PastedRegionEndReason, generation gen: UInt64) {
    guard let w = watch, w.generation == gen else { return }
    deps.telemetry.learnObservationEnded(
      reason: reason, settledBursts: w.settledBursts, appClass: w.appClass,
      durationMs: max(0, deps.nowMs() - w.pastedAtMs))
  }

  // MARK: Steps 5–7: align, filter, judge

  /// Synchronous up to the reservation: alignment, filtering, the refresh of
  /// open pairs and the reservation of the call count and pair keys all happen
  /// before any suspension, so two bursts cannot both submit the same pair.
  private func judgeBurst(region: String, generation gen: UInt64, revision: UInt64) {
    guard let w = watch, w.generation == gen, w.isLive, let selected = w.selected,
      let target = w.target, w.judgeCalls < Self.maxJudgeCallsPerPaste
    else { return }
    let alignment = EditAlignment.align(pasted: target.pastedText, edited: region)
    guard !alignment.limitExceeded, !alignment.runs.isEmpty else { return }
    let language = w.event.language
    let inputs = CorrectionCandidateFilter.Inputs(
      userWords: deps.userWords(), packTerms: deps.packTerms(),
      openProposals: deps.coordinator.openProposalsByPairKey,
      rejectedPairKeys: deps.coordinator.rejectedPairKeys,
      dictationLanguage: language,
      supportedLanguages: w.supportedLanguages)
    let context = Self.contextExcerpt(region)
    var filtered = CorrectionCandidateFilter.filter(runs: alignment.runs, inputs: inputs)
    for f in filtered {
      if case .refreshOpen(let id) = f.disposition {
        deps.coordinator.refresh(
          id: id, contextExcerpt: context, sourceBundleID: w.event.destinationBundleID)
      }
    }
    filtered.removeAll { w.sentPairKeys.contains($0.pairKey) }
    let prepared = CorrectionCandidateFilter.prepare(filtered)
    guard !prepared.candidates.isEmpty else { return }
    let request: CorrectionJudgeRequest
    do {
      request = try CorrectionJudgeRequest(
        candidates: prepared.candidates, context: context, language: language)
    } catch {
      return
    }
    // Reservation, atomically with the checks above (no suspension so far).
    watch?.judgeCalls += 1
    for key in prepared.byID.values.map(\.pairKey) { watch?.sentPairKeys.insert(key) }
    let arm = selected.arm
    let judge = selected.judge
    let bundleID = w.event.destinationBundleID
    Task { @MainActor [weak self] in
      await self?.ask(
        judge, arm: arm, request: request, prepared: prepared, language: language,
        context: context, bundleID: bundleID, generation: gen, revision: revision)
    }
  }

  private func ask(
    _ judge: any CorrectionJudging, arm: TelemetryService.LearnFromEditsTelemetry.Arm,
    request: CorrectionJudgeRequest, prepared: CorrectionCandidateFilter.Prepared,
    language: String?, context: String, bundleID: String?, generation gen: UInt64,
    revision: UInt64
  ) async {
    // B4: the queued call may run after the watch moved on. A reserved call
    // that is no longer about the current text is not asked at all.
    guard stillWanted(generation: gen, revision: revision) else { return }
    let started = deps.nowMs()
    let outcome = await judge.judge(request)
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
      accepted: accepted, latencyMs: latency, queueWaitMs: nil)
    guard case .verdict(let decisions) = outcome else { return }
    for decision in decisions where decision.verdict.vocabularyCorrection {
      guard let f = prepared.byID[decision.id], case .candidate(let state) = f.disposition else {
        continue
      }
      // B6: the emission above and each proposal below run injected callbacks
      // synchronously; any of them may have cancelled or superseded the watch.
      guard stillWanted(generation: gen, revision: revision) else { return }
      _ = deps.coordinator.propose(
        original: f.run.coreOriginal, corrected: f.run.coreReplacement, state: state,
        language: language, contextExcerpt: context, sourceBundleID: bundleID,
        advisorySafeAlias: decision.verdict.safeAlias)
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
  static func contextExcerpt(_ text: String) -> String {
    let limit = CorrectionJudgeRequest.maxContextUTF16
    guard text.utf16.count > limit else { return text }
    var out = ""
    for character in text {
      if out.utf16.count + String(character).utf16.count > limit { break }
      out.append(character)
    }
    return out
  }
}
