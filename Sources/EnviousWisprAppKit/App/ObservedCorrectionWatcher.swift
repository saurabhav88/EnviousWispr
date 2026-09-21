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
//   B4 judge task start          | stale   | stale    | cancel + stale       | ask    | stale
//   B5 after `await judge`       | stale   | stale    | cancel + stale       | apply  | stale
//   B6 propose loop              | re-checked before EACH proposal: the sink and every
//                                |   `propose` can re-enter synchronously (an offer that
//                                |   starts a dictation, a setting observer); the rest
//                                |   of the answer is dropped as one stale result
//
// T sets `cancelled` even after E: the observation row was emitted once and
// is not repeated, and a pending answer about text the user asked us to stop
// watching is never applied. D no longer cancels (#996 cursor-aware settling,
// Codex r30): a settled snapshot is evidence about THAT paste whatever is
// dictated next, so a live observation finishes through the observer (flushing
// a pending fix like a send) and pending answers stay valid; a card that
// cannot show while the pipeline is busy waits in Pending.

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
  /// Bound on ONE judge call, whatever the arm: the AFM judge bounds itself,
  /// the rules judge is immediate, but a Core ML `prediction` can wedge and
  /// nothing above it would ever answer. Production: `correctionJudgeDeadlineSeconds`
  /// plus one, so the AFM judge's own deadline reports first. Tests shorten it.
  var judgeDeadlineSeconds: Double = WordSuggestionService.correctionJudgeDeadlineSeconds + 1
  /// Capture grace (#996, app matrix 2026-09-20): a key-event paste (Tier 2
  /// Cmd+V into Slack, Word, Chrome) lands AFTER the completion event fires,
  /// so the first read of the focused field can still show the pre-paste text
  /// (Slack and Word: `dictated_text_not_found` 25 ms after the paste, the text
  /// present a second later). The capture is retried this many more times,
  /// `captureRetryDelayMs` apart, before `dictated_text_not_found` or
  /// `no_focused_element` is final. 10 × 150 ms = 1.5 s: the Tier 2b MENU
  /// paste (an AppleScript click on Edit › Paste, Slack when the key event
  /// is refused) lands later than the key event and missed a 0.9 s grace
  /// twice on 2026-09-20; 1.5 s is also the settle interval, so a person who
  /// starts fixing inside it is caught by the first poll after capture.
  var captureRetries = 10
  var captureRetryDelayMs = 150
  /// The wait between capture attempts; tests inject an immediate one.
  var sleepMs: (Int) async -> Void = { ms in
    try? await Task.sleep(for: .milliseconds(ms))
  }
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
    guard let frontmost = deps.frontmost(), frontmost.bundleID == w.event.destinationBundleID
    else {
      skip(.destinationMismatch, generation: gen)
      return
    }
    w.selected = selected
    var outcome = deps.observer.capture(
      pid: frontmost.pid, pastedText: w.event.pastedText, pastedAtMs: w.pastedAtMs)
    var retries = deps.captureRetries
    while retries > 0, Self.deservesCaptureGrace(outcome) {
      retries -= 1
      await deps.sleepMs(deps.captureRetryDelayMs)
      // Anything can have happened during the wait: a new paste, a dictation,
      // the toggle. The same re-reads as after the capabilities await.
      guard let live = watch, live.generation == gen, live.isLive else { return }
      guard deps.isLearnFromEditsOn() else {
        skip(.toggleOff, generation: gen)
        return
      }
      guard let again = deps.frontmost(), again.pid == frontmost.pid else {
        skip(.destinationMismatch, generation: gen)
        return
      }
      outcome = deps.observer.capture(
        pid: frontmost.pid, pastedText: w.event.pastedText, pastedAtMs: w.pastedAtMs)
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
      w.appClass =
        if BrowserAddressBarDetector.family(forBundleIdentifier: w.event.destinationBundleID) != nil {
          .browser
        } else if target.isManualAccessibilityHost {
          .manualAccessibility
        } else {
          .native
        }
      watch = w
      deps.observer.start(target) { [weak self] event in
        self?.handle(event, generation: gen)
      }
    }
  }

  /// The two capture answers a slow host gives before the paste has landed:
  /// no focused element yet, or a field that does not contain the text yet.
  /// Everything else (secure field, wrong app, permission, unreadable value,
  /// an ambiguous or oversize value, a captured target) is final at once.
  static func deservesCaptureGrace(_ outcome: PastedRegionCaptureOutcome) -> Bool {
    switch outcome {
    case .ended(.dictatedTextNotFound), .skipped(.noFocusedElement): return true
    case .captured, .skipped, .ended: return false
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
      rejectedPairKeys: deps.coordinator.rejectedPairKeys)
    var filtered = CorrectionCandidateFilter.filter(runs: alignment.runs, inputs: inputs)
    for f in filtered {
      if case .refreshOpen(let id) = f.disposition {
        // An open proposal's excerpt is centred on ITS run.
        deps.coordinator.refresh(
          id: id,
          contextExcerpt: Self.contextExcerpt(
            region, focusTokens: f.run.editedRange, limit: CorrectionProposal.contextExcerptLimit),
          sourceBundleID: w.event.destinationBundleID)
      }
    }
    filtered.removeAll { w.sentPairKeys.contains($0.pairKey) }
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
    // beyond the per-paste call budget are left unreserved. The proposal
    // excerpts stored below stay on the edited region: that is what the card
    // and the Pending row show.
    let arm = selected.arm
    let judge = selected.judge
    let bundleID = w.event.destinationBundleID
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
        continue
      }
      // Reservation, atomically with the checks above (no suspension so far).
      watch?.judgeCalls += 1
      for key in prepared.byID.values.map(\.pairKey) { watch?.sentPairKeys.insert(key) }
      Task { @MainActor [weak self] in
        await self?.ask(
          judge, arm: arm, request: request, prepared: prepared, language: language,
          context: context, region: region, bundleID: bundleID, generation: gen, revision: revision)
      }
    }
  }

  private func ask(
    _ judge: any CorrectionJudging, arm: TelemetryService.LearnFromEditsTelemetry.Arm,
    request: CorrectionJudgeRequest, prepared: CorrectionCandidateFilter.Prepared,
    language: String?, context: String, region: String, bundleID: String?,
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
      accepted: accepted, latencyMs: latency, queueWaitMs: nil)
    guard case .verdict(let decisions) = outcome else { return }
    #if DEBUG
      // Local debug log only (plan §11 UAT tokens): what the judge was asked and
      // what it answered, pair by pair, so a Live UAT can read a refusal from
      // app.log the way it reads a proposal. Release logs no user text.
      for decision in decisions {
        let pair =
          prepared.byID[decision.id].map { "\"\($0.run.coreOriginal)\" -> \"\($0.run.coreReplacement)\"" }
          ?? "id \(decision.id)"
        CorrectionProposalCoordinator.debugLog("judged \(pair) verdict=\(decision.verdict)")
      }
    #endif
    for decision in decisions where decision.verdict.vocabularyCorrection {
      guard let f = prepared.byID[decision.id], case .candidate(let state) = f.disposition else {
        continue
      }
      // B6: the emission above and each proposal below run injected callbacks
      // synchronously; any of them may have cancelled or superseded the watch.
      guard stillWanted(generation: gen, revision: revision) else { return }
      // The proposal keeps an excerpt around ITS OWN edit (the Pending row and
      // the card read it), not the judge's window around the first candidate.
      _ = deps.coordinator.propose(
        original: f.run.coreOriginal, corrected: f.run.coreReplacement, state: state,
        language: language,
        contextExcerpt: Self.contextExcerpt(
          region, focusTokens: f.run.editedRange, limit: CorrectionProposal.contextExcerptLimit),
        sourceBundleID: bundleID, advisorySafeAlias: decision.verdict.safeAlias)
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
  /// proposal), and a run whose original tokens cannot be found in the pasted
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
