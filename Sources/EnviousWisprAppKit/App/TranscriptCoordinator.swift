import EnviousWisprCore
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Observation

/// Manages transcript history state, search, and persistence.
@MainActor @Observable
final class TranscriptCoordinator {
  /// The unfiltered store, PRIVATE (#2087).
  ///
  /// Read-time expiry only works if consumers honour it, and every consumer
  /// reading this array directly bypassed it silently — the code compiled, the
  /// list rendered, and the only symptom was a held recovery still reachable
  /// past the 24 hours the user was promised. Three sites did exactly that.
  ///
  /// Guarding it was tried and is not enough: a scanner over the source can
  /// match a name, not a type, so it flags an unrelated `transcripts` elsewhere
  /// and misses a bare access from an extension. The compiler makes the mistake
  /// unavailable instead. Read `visibleTranscripts` or `filteredTranscripts`.
  private var transcripts: [Transcript] = []
  var searchQuery: String = "" {
    didSet { reconcileSelectionWithDisplayedSet() }
  }

  /// The row the list has selected.
  ///
  /// #2807: the detail pane resolves from what is DISPLAYED, and this setter is the one
  /// door every selection change goes through: the list's binding, the filter, a search, a
  /// deletion. A selection that resolves inside the displayed set lifts the live-transcript
  /// suppression; a selection going away, whoever cleared it, arms it. The coordinator cannot
  /// tell a user's deselect from a row vanishing under the list's binding, so both arm it —
  /// the cost is a status view where the live transcript used to be, which is the same thing
  /// the user sees after deleting a row.
  var selectedTranscriptID: UUID? {
    didSet {
      if let selected = selectedTranscriptID {
        if filteredTranscripts.contains(where: { $0.id == selected }) {
          liveFallbackSuppressed = false
        }
      } else if oldValue != nil {
        liveFallbackSuppressed = true
      }
    }
  }

  /// Which kind of History row is listed (#2807). View state: never persisted, so a relaunch
  /// starts at All.
  var historyFilter: HistoryFilter = .all {
    didSet { reconcileSelectionWithDisplayedSet() }
  }

  /// #2807: whether the detail pane may show the live transcript when nothing is selected.
  ///
  /// The live fallback exists for one moment: a dictation just finished and History is open
  /// with nothing selected, so the pane shows what was just said. It is UNRELATED to anything
  /// the user did in the list. So when a selection is cleared because a filter, a search or a
  /// deletion took the row away, the pane must show nothing rather than a transcript from
  /// another time. Lifted only by a selection that resolves inside the displayed set, or by a
  /// completed dictation landing in it (`append`), which is the moment the fallback is for.
  private var liveFallbackSuppressed = false

  /// The completed dictation the live fallback is showing, if this object saw it land (#2807).
  ///
  /// The fallback is the live pipeline's transcript, which this object cannot see; what it
  /// CAN see is the row `append` inserted for it. Kept so a filter or a search that stops
  /// listing that row also stops the pane showing its text: the pane must follow the list.
  /// Nil until a dictation completes in this session, or after Delete All removes the row.
  private var liveFallbackRowID: UUID?

  /// Re-render pulse for pending Escape Recovery rows (#2087).
  ///
  /// This type has no clock, and Observation redraws on a STATE change — a
  /// remaining-time computed from `Date()` is not one. Without a pulse a row
  /// would keep showing whatever it said when something else last mutated
  /// state, and an expired row would stay on screen until an unrelated edit
  /// happened to refresh it. Reading this in a view is what subscribes it.
  ///
  /// Only runs while a live pending row exists, so the ordinary case — feature
  /// off, or no recovery held — has no timer at all.
  private(set) var expiryPulse: Int = 0

  private let store: TranscriptStore
  private let pendingPulseInterval: Duration
  private let pendingPulseSleep: @Sendable (Duration) async -> Void

  /// Escape Recovery telemetry emitters, injected (#2087).
  ///
  /// Seams rather than direct `TelemetryService.shared` calls, so a test can
  /// assert an event fired with the right take id and age WITHOUT reaching the
  /// network client — and so the events are observable at all, since the funnel
  /// is the instrument that decides whether this feature earns its keep.
  private let emitEscapeRecoveryKept: (_ ageMs: Int, _ takeID: String) -> Void
  private let emitEscapeRecoveryExpired: (_ ageMs: Int, _ takeID: String) -> Void
  private let emitEscapeRecoveryRestoredFromHistory: (_ ageMs: Int, _ takeID: String) -> Void
  private let recordEscapeRecoveryKeep: @MainActor (_ outcome: String, _ takeID: String?) -> Void
  /// #2811, phase 4 of #2807 §3e — same seam-not-direct-call reason as the escape-recovery
  /// emitters above.
  private let emitRenameTelemetry: (_ outcome: TelemetryService.FileImportRenameOutcome) -> Void
  private var loadTask: Task<Void, Never>?
  private var pulseTask: Task<Void, Never>?

  /// Rows that are still OFFERED, at read time (#2087).
  ///
  /// Read-time expiry is authoritative: a pending row at or past its retention
  /// window is never rendered, searched or counted, whether or not the sweep
  /// that deletes its file has run. The sweep reclaims disk; this decides
  /// visibility. Tying visibility to the sweep would leave an expired row on
  /// screen whenever the sweep failed, threw, or had not run yet.
  var visibleTranscripts: [Transcript] {
    // Reading the pulse HERE is what makes the redraw work, and it is load
    // bearing rather than decorative. Observation invalidates a view when a
    // property the view READ changes; this result depends on `Date()`, which
    // Observation cannot see. Touching `expiryPulse` during the read makes
    // every consumer of this list a subscriber to the pulse automatically,
    // instead of relying on each view to remember to read a counter whose
    // relevance is not obvious from its name.
    _ = expiryPulse
    let now = Date()
    return transcripts.filter { Self.isVisible($0, at: now) }
  }

  /// The rows History lists: visible rows, inside the kind filter, then inside the search.
  ///
  /// #2807: the kind filter runs FIRST and reads `isImported`, which is the row's only kind.
  /// A pending Escape-recovery row is a dictation that was cancelled, so it stays under All
  /// and Dictations exactly as it did before the filter existed, and is absent under
  /// Transcripts. The search then keeps its own rule below.
  var filteredTranscripts: [Transcript] {
    let visible = visibleTranscripts
    let listed: [Transcript]
    switch historyFilter {
    case .all: listed = visible
    case .dictations: listed = visible.filter { !$0.isImported }
    case .transcripts: listed = visible.filter { $0.isImported }
    }
    guard !searchQuery.isEmpty else { return listed }
    // Pending rows are excluded from search DELIBERATELY: an accidental Escape
    // would otherwise pollute results for 24 hours, and the row is reachable
    // the whole time by scrolling History, which is where the user left it.
    return listed.filter {
      // #2772: the imported file's name is on the row, and it is the thing a person looking
      // for a meeting they transcribed types, so it is searchable. Searching "marketing" for
      // `marketing_sync.wav` removed the row while its badge said the word. Found by the
      // cloud review of PR #2786.
      // #2811, phase 4 of #2807: a renamed speaker's name does not enter `displayText` — the
      // epic's own "find the row with 'Zach, Ariana' on it" walkthrough needs an explicit
      // match against the speaker names themselves, a genuinely new gap this phase closes
      // (plan §6 downstream consumer matrix).
      $0.escapeRecoveredAt == nil
        && ($0.displayText.localizedCaseInsensitiveContains(searchQuery)
          || ($0.importedFileName?.localizedCaseInsensitiveContains(searchQuery) ?? false)
          || ($0.speakerNames?.values.contains {
            $0.localizedCaseInsensitiveContains(searchQuery)
          } ?? false))
    }
  }

  /// Completed rows. A held recovery is an OFFER, not a dictation the
  /// user made — counting it would inflate the stat the moment they cancelled
  /// something, which is the opposite of what cancelling meant.
  ///
  /// **Two questions, two counts (#2772).** This one is the sidebar's, beside the search
  /// field: how many rows History lists, so an import that appears in the list is counted
  /// in it. `dictationCount` is onboarding's: how many DICTATIONS exist, read as
  /// `producedWords = transcriptCount > transcriptCountAtTakeStart`, where an import
  /// finishing during a practice take must not mark that take successful for a user who
  /// said nothing. One count serving both was wrong for one of them whichever way it went:
  /// first it counted imports and broke onboarding, then it excluded them and History
  /// showed a row its own count did not have. Found by Codex, twice.
  ///
  /// `deletableCount` deliberately counts imports too: it answers "how many rows would
  /// Delete All take", where an uncounted row is a row destroyed without warning.
  ///
  /// #2807: counts inside the filter and the search, because the number sits beside the list
  /// it describes. Under All with an empty search it is exactly the pre-filter count. Renamed
  /// from `transcriptCount`, because a Transcript is now a file import and this counts every
  /// kind.
  var listedCount: Int {
    filteredTranscripts.filter { $0.escapeRecoveredAt == nil }.count
  }

  /// How many dictations exist: every completed row that is not an import, whatever the
  /// filter shows. Onboarding's success detector reads this one.
  var dictationCount: Int {
    _ = expiryPulse
    let now = Date()
    return transcripts.filter {
      Self.isVisible($0, at: now) && $0.escapeRecoveredAt == nil && !$0.isImported
    }.count
  }

  /// How many rows a Delete All would actually take, from the user's point of
  /// view (#2087).
  ///
  /// Deliberately NOT `listedCount`. That one answers "how many rows does the
  /// list show" and excludes held recoveries, which is right for a statistic
  /// and wrong for a destructive confirmation: with only held rows on screen it
  /// reads zero, so the dialog would offer to delete "all 0 transcripts" and
  /// then delete them. A confirmation must count what it is about to destroy.
  var deletableCount: Int { visibleTranscripts.count }

  /// The Delete All confirmation, assembled HERE rather than in the view.
  ///
  /// Not a style preference. While the view interpolated a count of its own
  /// choosing, the correct count and the wrong one were both in scope and
  /// equally easy to type, and nothing a unit test can reach observed which was
  /// picked — a mutation swapping them survived the whole suite. Owning the
  /// sentence removes the choice from the call site and puts the decision
  /// somewhere a test can see it.
  var deleteAllConfirmationMessage: String {
    let count = deletableCount
    // "all 1 transcripts" is what centralising the sentence without reading it
    // produced, and a test then pinned it. One row is not a plural, and "all"
    // reads as boilerplate when there is nothing to be exhaustive about.
    //
    // #2807: Delete All is GLOBAL while the list can be filtered or searched, so the
    // sentence says that a hidden row goes too. The count is the global one for the same
    // reason: a confirmation must count what it is about to destroy, not what is on screen.
    let subject =
      count == 1
      ? "the only item in History, even if a filter or search is hiding it"
      : "all \(count) items in History, including any hidden by a filter or search"
    return "This will permanently delete \(subject). This action cannot be undone."
  }

  /// What the list shows when it has no rows (#2807), or nil while it has some.
  ///
  /// Four different absences, because the fix for each is different: nothing has ever been
  /// recorded; nothing of the chosen kind; nothing matches the search. Answered here so the
  /// view cannot pick the global "nothing yet" for a list that a filter emptied.
  var emptyState: HistoryEmptyState? {
    guard !visibleTranscripts.isEmpty else { return .nothingYet }
    guard filteredTranscripts.isEmpty else { return nil }
    guard searchQuery.isEmpty else { return .noMatches }
    switch historyFilter {
    // Unreachable: with no search, All lists every visible row, and there is at least one.
    case .all: return .nothingYet
    case .dictations: return .noDictations
    case .transcripts: return .noTranscripts
    }
  }

  /// What the detail pane shows (#2807), resolved from the DISPLAYED set.
  ///
  /// A selected row that the filter or the search does not list, or that expired since it was
  /// picked, is `.empty` rather than the live fallback: the pane must never answer a narrowing
  /// of the list with a transcript from another time. With nothing selected the live fallback
  /// stands unless something cleared a selection out from under the user.
  var detail: HistoryDetail {
    guard let selected = selectedTranscriptID else {
      // ONE source for the just-finished dictation: its History row, never the live
      // pipeline's copy beside it. The row is what the list shows, so the pane cannot
      // show a text the list does not; a row this object has not seen yet, or that
      // the list stopped showing, is nothing rather than the live transcript.
      if let fallbackRow = liveFallbackRowID {
        guard !liveFallbackSuppressed,
          let row = filteredTranscripts.first(where: { $0.id == fallbackRow })
        else { return .empty }
        return .row(row)
      }
      return liveFallbackSuppressed ? .empty : .liveFallback
    }
    if let match = filteredTranscripts.first(where: { $0.id == selected }) {
      return .row(match)
    }
    return .empty
  }

  /// The detail pane follows the list (#2807). Called when the filter or the search changes,
  /// and after any write that replaces rows, because a cleanup can change the text a search
  /// matched on.
  ///
  /// A selection that the displayed set no longer lists is cleared, and the live fallback is
  /// suppressed by the setter, so a filter or a search never reveals it. With nothing selected
  /// the same question is asked of the fallback's own row: if the list stops showing the
  /// dictation the pane is showing, the pane goes empty. Where that row is unknown, any
  /// narrowing of the list suppresses the fallback, because nothing can prove the pane's text
  /// is among the rows on screen. Widening the list later does not bring either back; only a
  /// selection, or the next completed dictation, does.
  private func reconcileSelectionWithDisplayedSet() {
    let displayed = filteredTranscripts
    if let selected = selectedTranscriptID {
      guard !displayed.contains(where: { $0.id == selected }) else { return }
      selectedTranscriptID = nil
      return
    }
    guard !liveFallbackSuppressed else { return }
    let fallbackRowIsListed: Bool
    if let fallbackRow = liveFallbackRowID {
      fallbackRowIsListed = displayed.contains(where: { $0.id == fallbackRow })
    } else {
      fallbackRowIsListed = historyFilter == .all && searchQuery.isEmpty
    }
    if !fallbackRowIsListed {
      liveFallbackSuppressed = true
    }
  }

  /// Held rows IN MEMORY whose window has elapsed.
  ///
  /// The pulse's sweep trigger: a direct statement of "there is something to
  /// clean up", which cannot race the way a before/after comparison does.
  ///
  /// Says "in memory" precisely because that is what it reads. An earlier
  /// version of this comment claimed it represented files still on disk, which
  /// was wrong in a way that mattered: swept rows stayed in the array, so it
  /// never returned to zero and the pulse re-swept every minute.
  private var lapsedPendingCount: Int {
    let now = Date()
    return transcripts.filter { $0.escapeRecoveredAt != nil && !Self.isVisible($0, at: now) }.count
  }

  /// Live pending rows — a countdown still worth redrawing.
  private var livePendingCount: Int {
    let now = Date()
    return transcripts.filter { $0.escapeRecoveredAt != nil && Self.isVisible($0, at: now) }.count
  }

  /// How many files the LAST sweep meant to remove and could not — disk truth,
  /// straight from `PendingSweepResult.unremovable`.
  ///
  /// The store promises a failed removal is retried on the next sweep, and this
  /// is what keeps that promise: without it the pulse stopped as soon as nothing
  /// was counting down, so the retry never came and the file plus its expiry
  /// event waited for History to reload.
  ///
  /// Deliberately NOT `lapsedPendingCount`. That reads this object's own list,
  /// which can outlive the file it describes — `load()` preserves in-memory rows
  /// absent from both namespaces — so retrying on it means retrying forever, a
  /// directory walk every minute for the life of the app. Only the sweep can say
  /// whether a file is still there.
  private var unremovablePendingCount = 0

  /// Rows still counting down ON DISK, from the last COMPLETE sweep (#2186).
  ///
  /// The countdown used to arm only from `livePendingCount`, which reads
  /// `transcripts`, which only `load()` fills — and `load()`'s one production
  /// caller is the History view. So a row carried over from a PREVIOUS session
  /// was invisible to the timer for the entire session: nothing deleted it at
  /// its moment, and it waited for a relaunch. Founder, 2026-08-20: "As long as
  /// the application is running, the timer should be ticking… and then it just
  /// deletes."
  ///
  /// Written only when `walkComplete`, because the store's count means nothing
  /// otherwise — a walk that could not enumerate the directory reports zero,
  /// which would read as "nothing is counting down" and stop the pulse on the
  /// one occasion it must keep running. An incomplete walk leaves this ALONE and
  /// `lastSweepIncomplete` keeps the pulse alive on its own.
  private var liveOnDiskPendingCount = 0

  /// Expired rows the last sweep KEPT because their spool survives (#2186).
  /// A retry owed, not a failure and not a countdown.
  private var pendingRetainedForSpool = 0

  /// Whether the last sweep failed to READ the directory, or threw.
  ///
  /// Separate from the count because it means the opposite of what the count
  /// would say on its own: a walk that never happened reports zero unremovable
  /// files, which is the same number a completely successful walk reports. Held
  /// so the pulse keeps retrying rather than concluding it is finished on the
  /// strength of a measurement that was never taken.
  private var lastSweepIncomplete = false

  /// Something may still need clearing: a lapsed row this object can see, a file
  /// the last sweep could not remove, or a sweep that could not look.
  ///
  /// The lapsed half is what makes the FIRST walk happen after a row ages out.
  /// It settles because a sweep that removes everything it can also drops any
  /// lapsed row it did not find, so this returns to zero after one pass.
  private var pendingSweepIsDue: Bool {
    lapsedPendingCount > 0 || unremovablePendingCount > 0 || lastSweepIncomplete
      || liveOnDiskLapsedByNow || pendingRetainedForSpool > 0
  }

  /// #2186: a disk row that has crossed its deadline SINCE the last sweep.
  ///
  /// `lapsedPendingCount` cannot see it — that reads `transcripts`, and a row
  /// carried over from a previous session is not in memory unless History
  /// loaded it. Without this the pulse would arm (because live rows exist on
  /// disk) and then never find anything due, so it would spin until it stopped
  /// and delete nothing at the moment it was supposed to.
  ///
  /// Deliberately time-based rather than a stored flag: the pulse's whole job is
  /// to notice a deadline passing while nothing else changes, and only a clock
  /// read can do that. The sweep it triggers is what corrects the count.
  private var liveOnDiskLapsedByNow: Bool {
    guard liveOnDiskPendingCount > 0 else { return false }
    return Date() >= nextDiskExpiryDeadline ?? .distantFuture
  }

  /// When the soonest disk row is due, from the last complete sweep (#2186).
  private var nextDiskExpiryDeadline: Date?

  /// Whether the pulse has any reason to keep running.
  ///
  /// ONE authority for arming, for the in-loop stop and for `stopPulseIfIdle`,
  /// because three copies of this predicate drifting apart is exactly how the
  /// retry got stranded.
  ///
  /// A lapsed row in memory is deliberately NOT part of this, and the loop's
  /// order is what makes that safe: it sweeps first, then asks this. So a stale
  /// row costs exactly one walk — the sweep drops it — rather than keeping the
  /// pulse alive over a file that is already gone.
  private var pendingPulseHasWork: Bool {
    livePendingCount > 0 || unremovablePendingCount > 0 || lastSweepIncomplete
      || liveOnDiskPendingCount > 0 || pendingRetainedForSpool > 0
  }

  /// A held row is visible only while `PendingAdmission` calls it live.
  /// Permanent rows carry no stamp and are always visible.
  ///
  /// Asked through the shared authority rather than re-derived, for the reason
  /// that type's own documentation gives: two copies of the retention
  /// comparison diverge the moment one side gains a condition the other lacks.
  /// An earlier version of this method compared elapsed time directly and so
  /// omitted future-skew rejection — a clock-skewed stamp would have stayed
  /// visible in History indefinitely while the store refused to return it,
  /// recreating precisely the divergence chunk 5 existed to remove.
  private static func isVisible(_ transcript: Transcript, at now: Date) -> Bool {
    guard let stamped = transcript.escapeRecoveredAt else { return true }
    return PendingAdmission.verdict(stampedAt: stamped, now: now) == .live
  }

  /// - Parameters:
  ///   - pendingPulseInterval: how often a held row's countdown and expiry are
  ///     re-evaluated. One minute: the countdown is rendered in hours, so a
  ///     minute bounds staleness three orders of magnitude below the window it
  ///     measures, while costing one wakeup a minute and only while a row is
  ///     actually being held.
  ///   - pendingPulseSleep: the wait between pulses. Injected rather than
  ///     hard-coded so a test drives the loop on a signal instead of a real
  ///     clock — a clock-based test of this would be flaky by construction and
  ///     would take a day to exercise the case that matters.
  init(
    store: TranscriptStore,
    pendingPulseInterval: Duration = .seconds(60),
    pendingPulseSleep: (@Sendable (Duration) async -> Void)? = nil,
    emitEscapeRecoveryKept: ((_ ageMs: Int, _ takeID: String) -> Void)? = nil,
    emitEscapeRecoveryExpired: ((_ ageMs: Int, _ takeID: String) -> Void)? = nil,
    emitEscapeRecoveryRestoredFromHistory: ((_ ageMs: Int, _ takeID: String) -> Void)? = nil,
    recordEscapeRecoveryKeep: (@MainActor (_ outcome: String, _ takeID: String?) -> Void)? = nil,
    emitRenameTelemetry: ((_ outcome: TelemetryService.FileImportRenameOutcome) -> Void)? = nil
  ) {
    self.store = store
    self.pendingPulseInterval = pendingPulseInterval
    self.pendingPulseSleep = pendingPulseSleep ?? { try? await Task.sleep(for: $0) }
    self.emitEscapeRecoveryKept =
      emitEscapeRecoveryKept
      ?? { ageMs, takeID in
        TelemetryService.shared.escapeRecoveryKept(ageMs: ageMs, takeID: takeID)
      }
    self.emitEscapeRecoveryExpired =
      emitEscapeRecoveryExpired
      ?? { ageMs, takeID in
        TelemetryService.shared.escapeRecoveryExpired(ageMs: ageMs, takeID: takeID)
      }
    self.emitEscapeRecoveryRestoredFromHistory =
      emitEscapeRecoveryRestoredFromHistory
      ?? { ageMs, takeID in
        TelemetryService.shared.escapeRecoveryRestored(
          source: .history, ageMs: ageMs, pasteResult: .pasted, takeID: takeID)
      }
    self.recordEscapeRecoveryKeep = recordEscapeRecoveryKeep ?? Self.logKeep
    self.emitRenameTelemetry =
      emitRenameTelemetry
      ?? { outcome in TelemetryService.shared.trackFileImportRename(outcome: outcome) }
  }

  /// Report that a HELD recovery was pasted from History (#2087).
  ///
  /// `EscapeRecoveryRestoreSource` has two cases and only `.pill` had a
  /// producer, so every restore that went through History was invisible and the
  /// funnel understated the one number the feature is judged on. History's Paste
  /// button has shipped since chunk 10; nothing about it changed, it simply was
  /// never counted.
  ///
  /// Silent for an ordinary row and for a lapsed one. A row that is no longer
  /// offerable was refused by `textForDelivery` before this is reached, so
  /// reporting here would count a paste that did not happen.
  func reportRestoredFromHistory(_ transcript: Transcript) {
    guard
      let stampedAt = transcript.escapeRecoveredAt,
      let takeID = transcript.escapeRecoveryTakeID,
      Self.isVisible(transcript, at: Date())
    else { return }
    emitEscapeRecoveryRestoredFromHistory(
      Int(Date().timeIntervalSince(stampedAt) * 1000), takeID)
  }

  /// Sweep pending rows that aged out un-restored, reporting each (#2087).
  ///
  /// Read-time expiry already hides them, so this reclaims disk and produces the
  /// `expired` half of the ratio that judges the feature. The store returns ONLY
  /// rows that genuinely expired AND were actually deleted — a corrupt file is
  /// swept without a receipt, and a failed removal is not reported until it is
  /// confirmed gone, so a stuck file cannot re-emit the same expiry forever.
  ///
  /// Inert until activation: no pending rows exist to sweep.
  /// ASYNC, and off the main actor for the walk itself.
  ///
  /// `deleteExpiredPending` enumerates a directory and decodes one JSON file per
  /// pending row. Running that synchronously on `@MainActor` put a filesystem
  /// walk in front of History opening — the two loads beside it already hop off
  /// for exactly this reason, and the sweep had no business being the one thing
  /// that blocks the window.
  func sweepExpiredPending(now: Date = Date()) async {
    // No guard here: the STORE coalesces, so a second caller awaits the sweep
    // in flight and then runs its own pass with its own clock. A flag at this
    // layer would defeat both halves — `await` resuming before the work was
    // done, and a row that lapsed DURING the in-flight sweep never being
    // re-examined by the later clock that can see it.
    // Captured BEFORE the await, so a removal that lands while this walk is in
    // flight makes the walk stale by construction rather than by timing.
    let generation = diskStateGeneration
    do {
      let swept = try await store.deleteExpiredPending(now: now)
      #if DEBUG
        // The ONE window this guard exists for: the walk has finished and has
        // not yet written its result. A Live removal here is what makes the
        // result stale, and it cannot be staged from outside — the two tasks
        // resume in whatever order the runtime picks, so a test that raced them
        // would prove nothing on the run where it happened to win.
        onSweepWalkFinishedForTesting?()
      #endif
      // The four fields below DESCRIBE the directory, and this walk looked at a
      // directory a later removal has since changed — so its whole picture is
      // superseded, not merely its count. Applying any part of it writes a state
      // that never existed. The deletions and telemetry beneath this block are
      // FACTS about files that really went, so they are recorded either way, and
      // the newer walk arms the pulse from the state it actually finds.
      let describesCurrentDirectory = generation == diskStateGeneration
      // Replaced, never accumulated: this is the state of the directory after
      // the pass that just ran, so a file that finally went must stop counting.
      if describesCurrentDirectory {
        unremovablePendingCount = swept.unremovable
        lastSweepIncomplete = !swept.walkComplete
      }
      // #2186: DISK truth, and only from a walk that could actually look.
      // `walkComplete == false` means the store counted nothing, so its zero is
      // "I could not see" rather than "nothing is counting down" — writing it
      // here would stop the timer on the one occasion it must keep going.
      // `lastSweepIncomplete` above already keeps the pulse alive in that case.
      if swept.walkComplete, describesCurrentDirectory {
        liveOnDiskPendingCount = swept.remainingLive
        nextDiskExpiryDeadline = swept.nextLiveDeadline
      }
      // #2186: rows the sweep KEPT because their spool is still on disk. Not a
      // failure and not a live countdown — a retry owed. Without it the sweep
      // reads as finished (nothing deleted, nothing unremovable, walk complete),
      // the pulse stops, and the row waits for a relaunch instead of going on
      // the pass after recovery clears its spool. Same stranded retry the
      // `unremovable` count already exists to prevent, by a second route.
      if describesCurrentDirectory {
        pendingRetainedForSpool = swept.retainedForSpool
      }
      // Evict on EVERY deletion, not only the telemetry-eligible ones. A
      // future-skewed or corrupt row is deleted without a receipt, and leaving
      // it in memory kept `lapsedPendingCount` above zero — so the pulse
      // re-walked the directory every minute for a file that was already gone.
      if !swept.deletedIDs.isEmpty {
        transcripts.removeAll { swept.deletedIDs.contains($0.id) }
      }
      // `walkComplete` FIRST, and it is not a formality: `unremovable == 0` has
      // two causes — the sweep saw everything and cleared it, or it could not
      // read the directory at all. The second masks work instead of proving
      // there is none, so acting on it would evict the only remaining record of
      // rows whose files are still there.
      //
      // Nothing resisted removal, so every not-live file this pass could see is
      // gone — which means a row still lapsed at this SAME `now` has no file at
      // all, and memory is simply stale. Dropping it is what makes the sweep
      // trigger return to zero.
      //
      // Without this the trigger never settles whenever an unrelated LIVE row
      // keeps the pulse running: the stale row is lapsed forever, so the
      // directory is walked every minute for the life of the app. `load()`
      // preserves rows absent from both namespaces, so this state is reachable
      // rather than theoretical.
      //
      // The same `now` the sweep used, never a fresh `Date()`. A row exactly on
      // its boundary would otherwise be live to the sweep and lapsed to this
      // line, and it would be evicted on the strength of a disagreement between
      // two clocks rather than a fact about the disk.
      if swept.walkComplete, swept.unremovable == 0 {
        transcripts.removeAll { $0.escapeRecoveredAt != nil && !Self.isVisible($0, at: now) }
      }
      // #2807: an evicted row may have been the selected one. Clearing it here, where the
      // expiry is detected, is what lets the next completed dictation show in the pane
      // instead of hiding behind an id that resolves to nothing. Cloud review of PR #2815.
      reconcileSelectionWithDisplayedSet()
      for row in swept.expired {
        guard let takeID = row.takeID else { continue }
        // The row's REAL age, not the retention constant. A Mac left off for
        // three days sweeps rows that are 72 hours old, and the gap between
        // deadline and sweep is the part worth seeing.
        emitEscapeRecoveryExpired(Int(now.timeIntervalSince(row.stampedAt) * 1000), takeID)
      }
      // The sweep is where outstanding work is DISCOVERED, so it is what must
      // make sure the retry is running. Relying on the caller left this to
      // ordering luck: `load()` happens to arm afterwards, so a sweep reached
      // any other way could learn that a file resisted removal — or that it
      // could not look at all — and then have nothing scheduled to try again.
      // Idempotent: from inside the pulse's own loop the task already exists.
      startPulseIfNeeded()
    } catch {
      // A sweep that THREW measured nothing, so it must not read as a finished
      // one — same reasoning as an unreadable directory, one layer out.
      //
      // Gated with the success path for one reason: a superseded FAILURE landing
      // after a newer walk succeeded would mark the directory unread when it had
      // just been read. `startPulseIfNeeded` below is unconditional, so a genuine
      // failure still leaves a retry armed either way.
      if generation == diskStateGeneration {
        lastSweepIncomplete = true
      }
      startPulseIfNeeded()
      // History is a limb, not the heart. A failed sweep leaves rows the
      // read-time filter already hides.
      Task {
        await AppLogger.shared.log(
          "Failed to sweep expired pending transcripts: \(error)",
          level: .info, category: "TranscriptCoordinator"
        )
      }
    }
  }

  // No `deinit` teardown: `deinit` is nonisolated and cannot touch main-actor
  // state, and none is needed — the loop holds `self` weakly, so once this
  // object goes away the next wake finds nothing and returns. Nothing is
  // retained in the meantime.

  func load() {
    loadTask?.cancel()
    loadTask = Task {
      // #2087: sweep BEFORE reading, so the load cannot pick up a row this pass
      // is about to delete. Reclaims disk and produces the `expired` half of the
      // ratio that judges the feature.
      //
      // Placed here rather than at process launch deliberately: this is the
      // path that already does History disk I/O, and read-time expiry means an
      // unswept row is invisible regardless — so the sweep governs disk and
      // telemetry, never what the user can see. That is also why a missed sweep
      // is not a user-facing bug.
      await sweepExpiredPending()
      guard !Task.isCancelled else { return }
      do {
        // #2772: taken BEFORE the read, so a write that lands while it is in flight can be
        // recognised as newer than what the disk handed back.
        let revisionAtRead = historyWriteRevision
        // And the deletion generation, for the opposite race: a row DELETED while this read
        // was suspended is still in the picture the disk handed back, and the merge below
        // would reinstate it. For an import that is worse than a stale list, because the
        // cleanup's update then finds the row and rewrites its file — the deletion
        // `updateExistingRow` exists to respect. Every removal bumps this synchronously
        // (`invalidateDiskState`), so a mismatch means re-read rather than trust.
        let generationAtRead = diskStateGeneration
        var diskRows = try await store.loadAll()
        // Phase C union-by-ID merge. Preserve any in-memory rows whose IDs
        // are not yet on disk (append-during-load race window) in their
        // existing order, then append disk rows. Protects the newest-first
        // invariant under multiple concurrent completions while a slow
        // startup load is still running.
        // #2087: pending rows are ADDITIVE and never authoritative. Keep writes
        // the permanent copy before deleting the pending file, so a crash
        // between those two steps leaves the same id in both namespaces — root
        // wins, and the user sees the row they kept exactly once rather than a
        // permanent row shadowed by a copy still counting down.
        let pendingRows = (try? await store.loadPending()) ?? []
        guard !Task.isCancelled else { return }
        guard generationAtRead == diskStateGeneration else {
          load()
          return
        }
        // #2772: a row written SINCE this read began is newer than the disk copy that came
        // back, and the merge below prefers the disk one whenever the id already exists. An
        // import writes twice under one id, so without this the raw version read at the
        // start of a load replaces the cleaned version saved a moment later, and History
        // shows unpolished words until something else refreshes it. Found by Codex.
        let newerRows = Dictionary(
          uniqueKeysWithValues:
            transcripts
            .filter { (writtenAtRevision[$0.id] ?? 0) > revisionAtRead }
            .map { ($0.id, $0) })
        diskRows = diskRows.map { newerRows[$0.id] ?? $0 }
        let rootIDs = Set(diskRows.map(\.id))
        let heldRows = pendingRows.filter { !rootIDs.contains($0.id) }
        let knownIDs = rootIDs.union(heldRows.map(\.id))
        let inFlightRows = transcripts.filter { !knownIDs.contains($0.id) }
        // Merged rather than re-sorted: both inputs are already newest-first,
        // and re-sorting the combined list could reorder permanent rows that
        // share a `createdAt`. With no held rows this returns `diskRows`
        // unchanged, so History is byte-identical for anyone who never turns
        // Escape Recovery on.
        transcripts = inFlightRows + Self.mergeNewestFirst(heldRows, diskRows)
        reconcileSelectionWithDisplayedSet()
        startPulseIfNeeded()
      } catch {
        await AppLogger.shared.log(
          "Failed to load transcripts: \(error)",
          level: .info, category: "TranscriptCoordinator"
        )
      }
    }
  }

  // periphery:ignore - test seam
  func waitForLoadForTesting() async {
    await loadTask?.value
  }

  /// Append a just-completed transcript to the in-memory cache.
  ///
  /// Precondition: the transcript has already been persisted by
  /// the finalization `save` closure. This method does no disk I/O. Caller
  /// must not invoke it twice for the same transcript — duplicate-ID
  /// protection would mask heart-path bugs.
  func append(_ transcript: Transcript) {
    transcripts.insert(transcript, at: 0)
    // #2807: a COMPLETED dictation landing in the displayed set with nothing selected is the
    // one moment the live fallback exists for, so it may show again. A held recovery is a
    // cancellation, not a completion, and an import never comes through here; neither lifts
    // the suppression, and nor does a row the current filter does not list.
    if transcript.escapeRecoveredAt == nil {
      liveFallbackRowID = transcript.id
      // A selection that no longer resolves is no selection: the row expired between
      // renders or was swept, and read-time expiry hides it without a state change. Left
      // in place it would hide this completion behind an empty pane. Cloud review of PR #2815.
      if let selected = selectedTranscriptID,
        !filteredTranscripts.contains(where: { $0.id == selected })
      {
        selectedTranscriptID = nil
      }
      if selectedTranscriptID == nil {
        // The pane follows the list in BOTH directions: a completion the list shows lets
        // the fallback show again, and one the list does not show (a search or a filter
        // that excludes it) suppresses a fallback that was showing the previous dictation.
        liveFallbackSuppressed = !filteredTranscripts.contains(where: { $0.id == transcript.id })
      }
    }
    // A held row appended at runtime is the production route once the feature
    // is activated, and it arrives with a countdown already running. Without
    // this the pulse would only ever start at launch, so a recovery held during
    // a session would show a countdown frozen at the value it had when the row
    // appeared. No-op for an ordinary dictation, which carries no stamp.
    startPulseIfNeeded()
  }

  /// Save a row to disk AND show it, replacing an existing row with the same id.
  ///
  /// #2772: a file import writes TWICE under one id — the raw words the moment transcription
  /// lands, then the cleaned document when the cleanup finishes. `append` would have put two
  /// rows on screen for one recording, because it inserts unconditionally while the store,
  /// which names its file by id, was correctly overwriting. The two would then disagree
  /// until the next launch re-read the disk.
  ///
  /// Throws, deliberately. The import STOPS before polishing when the first write fails,
  /// which it cannot do if this swallows the error.
  func saveAndShow(_ transcript: Transcript) throws {
    try store.save(transcript)
    // Stamped so an in-flight `load()` cannot publish the version it read BEFORE this write.
    historyWriteRevision += 1
    writtenAtRevision[transcript.id] = historyWriteRevision
    if let existing = transcripts.firstIndex(where: { $0.id == transcript.id }) {
      transcripts[existing] = transcript
    } else {
      transcripts.insert(transcript, at: 0)
    }
    reconcileSelectionWithDisplayedSet()
    startPulseIfNeeded()
  }

  /// Save a row that must ALREADY be in History, reporting whether it was.
  ///
  /// #2772: an import's two writes are minutes apart, and History is reachable the whole
  /// time. Between them the user can delete the raw row. `saveAndShow` INSERTS an id it does
  /// not find, so the second write put the row back and rewrote its file, undoing an
  /// explicit deletion with nothing on screen to say so. Found by the cloud review of
  /// PR #2786.
  ///
  /// Update-only by CONSTRUCTION rather than by a tombstone the caller has to remember to
  /// check: this method has no insert branch, so no future caller can reach one.
  ///
  /// The in-memory list is the oracle, not the disk. `delete` and `deleteAll` empty both on
  /// this actor, and the list is what the user is looking at.
  @discardableResult
  func updateExistingRow(_ transcript: Transcript) throws -> Bool {
    guard let existing = transcripts.firstIndex(where: { $0.id == transcript.id }) else {
      return false
    }
    try store.save(transcript)
    historyWriteRevision += 1
    writtenAtRevision[transcript.id] = historyWriteRevision
    transcripts[existing] = transcript
    // #2807: the cleaned text can stop matching the search the row was selected under.
    reconcileSelectionWithDisplayedSet()
    startPulseIfNeeded()
    return true
  }

  /// The turn-cleanup write (#2810 addendum §3 E), and the one future rename write (phase
  /// 4) will share it. Reads the CURRENT row from `transcripts` at call time — never a value
  /// captured earlier — so "merge into the latest existing row, never overwrite newer
  /// names" holds structurally: whichever call runs second reads what the first one left.
  /// Goes through `updateExistingRow`, inheriting its "never resurrect a deleted row" guard
  /// for free.
  @discardableResult
  func mergeSpeakerFields(
    id: UUID, analysis: TranscriptSpeakerAnalysis, turns: [Turn]?,
    explicitRename: (speakerId: String, name: String)? = nil
  ) throws -> Bool {
    guard let existing = transcripts.first(where: { $0.id == id }) else { return false }
    let merged = existing.mergingSpeakerFields(
      analysis: analysis, turns: turns, explicitRename: explicitRename)
    return try updateExistingRow(merged)
  }

  /// Whether a row is in History right now. The import's "Saved to History" badge asks this
  /// live rather than remembering that a write once succeeded (#2772): a row can be deleted
  /// at any moment after either of the import's writes, and a remembered success then
  /// describes a file that is gone.
  func hasRow(id: UUID) -> Bool {
    transcripts.contains { $0.id == id }
  }

  /// The CURRENT row, read fresh from `transcripts` at call time — never a snapshot (#2811,
  /// phase 4 of #2807). Mirrors `hasRow(id:)`'s own "the in-memory list is the oracle"
  /// contract: a caller about to carry another writer's speaker fields forward, or decide
  /// whether a rename/retry is eligible, must read this rather than trust a value it captured
  /// earlier.
  func currentRow(id: UUID) -> Transcript? {
    transcripts.first { $0.id == id }
  }

  /// Renames a speaker id across every turn showing it, for a row History renders directly
  /// (#2811, phase 4 of #2807) — the History-side twin of `FileImportCoordinator
  /// .renameSpeaker`, both ordinary, symmetric callers of `mergeSpeakerFields` above. Re-reads
  /// the row's CURRENT analysis and turns TOGETHER, atomically, immediately before writing —
  /// never a value captured when a popover opened (§3 Design correction 2).
  func renameSpeaker(id transcriptID: UUID, speakerId: String, name: String) -> RenameFailure? {
    guard let current = currentRow(id: transcriptID), current.turns != nil,
      let analysis = current.speakerAnalysis
    else {
      emitRenameTelemetry(.failed)
      return RenameFailure(message: "Couldn't save the name.", currentName: nil)
    }
    do {
      let saved = try mergeSpeakerFields(
        id: transcriptID, analysis: analysis, turns: current.turns,
        explicitRename: (speakerId, name))
      guard saved else {
        emitRenameTelemetry(.failed)
        return RenameFailure(
          message: "This recording was removed from History.", currentName: nil)
      }
      emitRenameTelemetry(.saved)
      return nil
    } catch {
      emitRenameTelemetry(.failed)
      return RenameFailure(
        message: "Couldn't save the name.", currentName: current.speakerNames?[speakerId])
    }
  }

  /// Counts writes, so a disk read that began earlier can be told it is stale.
  ///
  /// `load()` prefers the DISK row whenever an id already exists, which is right for a
  /// launch and wrong for a write that landed while it was reading: an import's raw row read
  /// at the start of a load would replace the cleaned row saved a moment later, and History
  /// would show the unpolished version until something else refreshed it. Found by Codex.
  private var historyWriteRevision = 0
  private var writtenAtRevision: [UUID: Int] = [:]

  func delete(_ transcript: Transcript) {
    do {
      // #2807: the displayed set BEFORE the removal, so the neighbour is the row the user
      // saw beside the one they deleted.
      let displayed = filteredTranscripts
      try store.delete(id: transcript.id)
      transcripts.removeAll { $0.id == transcript.id }
      if selectedTranscriptID == transcript.id {
        // The next row in the same filter, else the previous one, else nothing — and
        // nothing means the status view, never the live fallback (the setter arms that).
        selectedTranscriptID = Self.neighbour(of: transcript.id, in: displayed)
      } else if selectedTranscriptID == nil, transcript.id == liveFallbackRowID {
        // The pane was showing this row's text through the fallback; the row is gone.
        liveFallbackSuppressed = true
      }
      if transcript.id == liveFallbackRowID { liveFallbackRowID = nil }
      refreshDiskStateThenStopIfIdle()
    } catch {
      Task {
        await AppLogger.shared.log(
          "Failed to delete transcript: \(error)",
          level: .info, category: "TranscriptCoordinator"
        )
      }
    }
  }

  /// Text for a Copy or Paste started from History, or `nil` if the row is no
  /// longer being offered (#2087).
  ///
  /// A view holds the row it was RENDERED with, which is a snapshot. For an
  /// ordinary dictation that is harmless. For a held recovery it is not: the
  /// offer can lapse between the row appearing and the button being pressed, and
  /// pasting from the snapshot would hand back text the user was told had gone —
  /// the one thing the 24-hour promise says will not happen.
  ///
  /// Re-reads by id rather than trusting the caller's copy, so a row deleted in
  /// another pane is also refused. Inert, not merely harmless.
  func textForDelivery(_ transcript: Transcript) -> String? {
    guard transcript.escapeRecoveredAt != nil else { return transcript.displayText }
    let now = Date()
    guard
      let current = transcripts.first(where: { $0.id == transcript.id }),
      Self.isVisible(current, at: now)
    else { return nil }
    return current.displayText
  }

  /// Everything the pill needs to restore a held row, or nil if it may not be
  /// restored (#2087).
  ///
  /// ONE authority rather than three lookups at the call site, because the
  /// refusal must be indivisible: text, age and join key have to describe the
  /// SAME row at the SAME instant, and a caller that fetched them separately
  /// could paste text while reporting a different row's age — or, worse, paste a
  /// row that lapsed between the second lookup and the third.
  ///
  /// Refuses on the same rule `textForDelivery` uses, and for the same reason: a
  /// recovery can lapse between the pill appearing and the press, and pasting a
  /// snapshot would hand back text the user was told had gone.
  func restorableHeldRow(id: UUID) -> (text: String, stampedAt: Date, takeID: String?)? {
    let now = Date()
    guard
      let row = transcripts.first(where: { $0.id == id }),
      let stampedAt = row.escapeRecoveredAt,
      Self.isVisible(row, at: now)
    else { return nil }
    return (row.displayText, stampedAt, row.escapeRecoveryTakeID)
  }

  /// Make a held recovery permanent (#2087).
  ///
  /// Inert, not merely harmless, when the row is no longer offerable: the store
  /// revalidates and silently ignores a row that expired between render and
  /// click, so a Keep press arriving a moment too late writes nothing rather
  /// than resurrecting text the user was told had gone.
  ///
  /// The in-memory row is replaced only after the store call returns, and it is
  /// replaced rather than mutated because `Transcript` is immutable. Idempotent:
  /// a second Keep finds no pending file and changes nothing.
  func keep(_ transcript: Transcript) {
    guard transcript.escapeRecoveredAt != nil else { return }
    do {
      // Only on a CONFIRMED promotion. The store silently ignores a row that
      // expired between render and click, and clearing the stamp anyway would
      // put an expired recovery on screen as permanent History — resurrecting
      // in the UI precisely the text the store just refused to write.
      guard try store.promotePending(id: transcript.id) else {
        // The refusal is the interesting case and it was the silent one: the
        // user pressed Keep, the row lapsed a moment earlier, and nothing
        // anywhere recorded that the press happened. That is precisely the
        // report a support conversation starts from.
        recordEscapeRecoveryKeep("refused-not-offerable", transcript.escapeRecoveryTakeID)
        return
      }
      // #2087: only on a CONFIRMED promotion, and only with the persisted take
      // id. A `kept` event for a row that was not promoted would overstate the
      // one ratio this funnel exists to measure.
      if let takeID = transcript.escapeRecoveryTakeID, let stamped = transcript.escapeRecoveredAt {
        emitEscapeRecoveryKept(Int(Date().timeIntervalSince(stamped) * 1000), takeID)
        recordEscapeRecoveryKeep("kept", takeID)
      } else {
        // Promoted, but with nothing to join it to. The user keeps their text
        // either way — this records the bookkeeping gap rather than letting the
        // Keep disappear from the count it belongs in.
        recordEscapeRecoveryKeep("kept-unreported", nil)
      }
      guard let index = transcripts.firstIndex(where: { $0.id == transcript.id }) else { return }
      transcripts[index] = transcripts[index].promotedFromPending()
      refreshDiskStateThenStopIfIdle()
    } catch {
      Task {
        await AppLogger.shared.log(
          "Failed to keep transcript: \(error)",
          level: .info, category: "TranscriptCoordinator"
        )
      }
    }
  }

  /// One line per Keep press, on every outcome including the refusals.
  ///
  /// Founder 2026-08-18, on the sibling Undo path: we must be able to tell after
  /// the fact how often this is used and when it fails. Telemetry answers that
  /// across users; this answers it for the ONE user in front of you, which is
  /// the only thing a support conversation can read. Shape only — no transcript
  /// and no text — and `take` is our own opaque join key.
  private static func logKeep(outcome: String, takeID: String?) {
    let take = takeID ?? "MISSING (keep not reported to telemetry)"
    Task {
      await AppLogger.shared.log(
        "escape recovery keep: outcome=\(outcome) take=\(take)",
        level: .info, category: "EscapeRecovery"
      )
    }
  }

  func deleteAll() {
    do {
      try store.deleteAll()
      transcripts.removeAll()
      selectedTranscriptID = nil
      // #2807: an empty History shows nothing, whatever the live pipeline last produced.
      liveFallbackSuppressed = true
      liveFallbackRowID = nil
      refreshDiskStateThenStopIfIdle()
    } catch {
      Task {
        await AppLogger.shared.log(
          "Failed to delete all transcripts: \(error)",
          level: .info, category: "TranscriptCoordinator"
        )
      }
    }
  }

  /// The row to select after `id` is deleted from `displayed`: the one after it, else the one
  /// before it, else nil (#2807). Pure, so the choice is unit-drivable.
  private static func neighbour(of id: UUID, in displayed: [Transcript]) -> UUID? {
    guard let index = displayed.firstIndex(where: { $0.id == id }) else { return nil }
    if index + 1 < displayed.count { return displayed[index + 1].id }
    if index > 0 { return displayed[index - 1].id }
    return nil
  }

  // MARK: - Escape Recovery expiry pulse (#2087)

  /// Interleave two newest-first lists without disturbing either's order.
  ///
  /// On a TIE the permanent row goes first, deliberately: a held row is an
  /// unresolved offer, and an offer should not displace a dictation the user
  /// actually completed at the same instant.
  ///
  /// A plain `sorted` over the concatenation is the obvious alternative and is
  /// rejected for a narrower reason than it first appears. `Array.sorted` is
  /// NOT documented as stable, so its behaviour on tied `createdAt` values is
  /// unspecified — today's implementation happens to preserve input order, and
  /// nothing promises the next toolchain will. That makes the tie case a
  /// silent, toolchain-dependent reordering of shipped History, caused by an
  /// opt-in feature the user may never have turned on. This merge specifies the
  /// answer instead of inheriting it.
  ///
  /// Honest limit: because the current sort IS stable in practice, the two
  /// implementations differ observably only in which row wins a tie — which is
  /// exactly what `heldRowLosesATieWithAPermanentRow` pins.
  private static func mergeNewestFirst(
    _ held: [Transcript], _ permanent: [Transcript]
  ) -> [Transcript] {
    guard !held.isEmpty else { return permanent }
    var result: [Transcript] = []
    result.reserveCapacity(held.count + permanent.count)
    var h = 0
    var p = 0
    while h < held.count, p < permanent.count {
      if held[h].createdAt > permanent[p].createdAt {
        result.append(held[h])
        h += 1
      } else {
        result.append(permanent[p])
        p += 1
      }
    }
    result.append(contentsOf: held[h...])
    result.append(contentsOf: permanent[p...])
    return result
  }

  private func startPulseIfNeeded() {
    guard pulseTask == nil, pendingPulseHasWork else { return }
    pulseTask = Task { [weak self, pendingPulseInterval, pendingPulseSleep] in
      while !Task.isCancelled {
        await pendingPulseSleep(pendingPulseInterval)
        guard let self, !Task.isCancelled else { return }
        // Bumped BEFORE the stop check, so the pulse that carries the last row
        // past its deadline is itself delivered — otherwise the final expiry
        // would stop the timer and never redraw, leaving the expired row on
        // screen until something unrelated moved.
        self.expiryPulse &+= 1
        // #2087: the pulse is where an expiry is DETECTED, so it is where the
        // file must go and the event must fire. Sweeping only on `load()` left
        // cleanup and telemetry waiting for the user to reopen History — which
        // for a row that aged out while they watched could be days, or never.
        //
        // Asks "can I see a lapsed row" rather than comparing the live count
        // before and after. The comparison version could never fire: both reads
        // happen after the wait, so they are always equal, and it only appeared
        // to work because the row sometimes expired BETWEEN them. A test that
        // removed the wall clock is what exposed it.
        if self.pendingSweepIsDue {
          await self.sweepExpiredPending()
        }
        // AFTER the sweep above, never before: this asks whether a countdown is
        // running or a file resisted removal, and the sweep is what settles the
        // second half. Stopping on the live count alone is what stranded a
        // failed removal, because the retry it was promised never came.
        if !self.pendingPulseHasWork {
          self.pulseTask = nil
          return
        }
      }
    }
  }

  private func stopPulseIfIdle() {
    guard !pendingPulseHasWork else { return }
    pulseTask?.cancel()
    pulseTask = nil
  }

  /// #2186: after an action that REMOVES pending files, re-read disk truth
  /// before deciding the pulse is idle.
  ///
  /// `liveOnDiskPendingCount` is a CACHE of the last sweep, and Keep, Delete and
  /// Delete All all change the directory it describes. Calling `stopPulseIfIdle`
  /// on the stale value means `pendingPulseHasWork` still sees the removed row,
  /// so the pulse never stops — a directory walk every minute for the life of
  /// the app, which is precisely the stranded-retry this file's own comments
  /// warn about, reintroduced through a cache those comments predate.
  ///
  /// A sweep rather than zeroing the count: zeroing is wrong whenever ANOTHER
  /// pending row is still counting down, and it would stop that row's timer.
  /// Only the directory knows. The sweep re-arms if work remains, so the stop
  /// below can then be trusted. Cloud review, P2.
  private func refreshDiskStateThenStopIfIdle() {
    // SYNCHRONOUS first, and that is a contract rather than an optimisation:
    // `Keep stops the pulse once the last held row is gone` asserts the pulse is
    // gone the instant Keep returns. Making this purely async broke it — the
    // full lane caught it, this suite did not, because the new tests await the
    // refresh and the old one does not.
    //
    // The cache is INVALIDATED rather than trusted or preserved. It describes a
    // directory this removal just changed, so keeping it blocks the stop (the
    // round-2 P2), and believing its old value is what made it stale. Zeroing
    // can only stop the pulse EARLY; the refresh below re-arms within moments if
    // another row is still counting down, and only the directory can say.
    invalidateDiskState()
    stopPulseIfIdle()
    refreshTask = Task { [weak self] in
      await self?.sweepExpiredPending()
      self?.stopPulseIfIdle()
    }
  }

  /// Drops what this coordinator believes about the pending directory, and
  /// supersedes any walk already in flight over it.
  ///
  /// Both halves belong to one removal and are why this is a function rather
  /// than four assignments at the call site: zeroing without bumping leaves an
  /// older walk free to write its stale picture back, and bumping without
  /// zeroing leaves the removed row counting until the refresh lands.
  private func invalidateDiskState() {
    liveOnDiskPendingCount = 0
    nextDiskExpiryDeadline = nil
    pendingRetainedForSpool = 0
    diskStateGeneration &+= 1
  }

  /// Bumped by every pending REMOVAL, and read by `sweepExpiredPending` across
  /// its one `await`, so a walk that started before a removal cannot write its
  /// picture of the directory over a newer one's.
  ///
  /// Cloud review, P2: the store serialises the walks, but each sweep writes its
  /// result back on the main actor AFTER resuming, and resumptions are not
  /// ordered — so without this, two quick removals can let the first walk's
  /// stale count land on top of the second walk's empty one and strand the pulse
  /// until a row that no longer exists reaches its former deadline.
  ///
  /// A generation rather than cancellation: the walk itself is still doing real
  /// work — it deletes files and its deletions must be recorded whoever wins —
  /// and only the four fields DESCRIBING the directory go stale. Those four are
  /// gated together rather than one at a time; they are one snapshot, and a
  /// partial application is a directory state that never existed.
  private var diskStateGeneration = 0

  /// Held so a test can await the refresh rather than guess at a duration —
  /// a signal the subject itself fires, never a sleep or a yield count.
  private var refreshTask: Task<Void, Never>?

  #if DEBUG
    // periphery:ignore - test seam
    var hasPendingPulseForTesting: Bool { pulseTask != nil }

    /// Bumps the pulse the way the loop does, so a test can assert that reading
    /// the visible list actually subscribes to it — without driving the loop.
    // periphery:ignore - test seam
    func bumpExpiryPulseForTesting() {
      expiryPulse &+= 1
    }

    /// The unfiltered rows. Only for assertions about state the read-time
    /// filter deliberately HIDES — an expired row that must keep its stamp, for
    /// instance. Anything a user would see is asserted through
    /// `visibleTranscripts`, which is what production reads.
    // periphery:ignore - test seam
    var rawTranscriptsForTesting: [Transcript] { transcripts }

    /// The pulse's sweep trigger, so a test can assert it returns to zero
    /// after a sweep rather than keeping the directory walk alive.
    // periphery:ignore - test seam
    var lapsedPendingCountForTesting: Int { lapsedPendingCount }

    /// #2186: the disk deadline the pulse waits for.
    ///
    /// A seam rather than a wall-clock wait. The production deadline comes from
    /// the store's own walk, and a test that made a row expire a fraction of a
    /// second in the future and let the loop spin until it did would be flaky by
    /// construction — the same defect `pulseSweepsOnDetection` records having
    /// already been fixed once in this file.
    // periphery:ignore - test seam
    func setDiskExpiryDeadlineForTesting(_ date: Date?) {
      nextDiskExpiryDeadline = date
    }

    // periphery:ignore - test seam
    var liveOnDiskPendingCountForTesting: Int { liveOnDiskPendingCount }

    /// Fired once the pending walk has finished and BEFORE its result is
    /// written back — the only window in which a removal can make that result
    /// stale. A seam rather than a raced pair of tasks: the two resume in an
    /// order the runtime picks, so a racing test proves nothing on the run where
    /// it happens to win.
    // periphery:ignore - test seam
    var onSweepWalkFinishedForTesting: (@MainActor () -> Void)?

    /// What a removal does to this coordinator's picture of the directory, with
    /// the refresh it would also arm left off — so a test can put a removal in
    /// the window above without a second walk racing in to correct the answer.
    // periphery:ignore - test seam
    func simulateRemovalDuringWalkForTesting() {
      invalidateDiskState()
    }

    /// Awaits the post-removal disk refresh. Captured before awaiting because
    /// the task clears nothing but may be replaced by a later removal.
    // periphery:ignore - test seam
    func waitForRefreshForTesting() async {
      let running = refreshTask
      await running?.value
    }

    /// Awaits the pulse loop's own completion — a real signal, so a test never
    /// guesses how long the loop needs. Captured before awaiting because the
    /// loop nils the handle as it exits.
    // periphery:ignore - test seam
    func waitForPulseForTesting() async {
      let running = pulseTask
      await running?.value
    }

    /// The deadline behind `waitForPulseForTesting`. A loop that stopped
    /// honouring its own exit condition would otherwise spin forever and HANG
    /// the suite — no test name, no assertion, just a wedged run — which is
    /// worse than having no test. A test bounds its iterations and calls this,
    /// so the regression fails loudly instead.
    // periphery:ignore - test seam
    func cancelPulseForTesting() {
      pulseTask?.cancel()
      pulseTask = nil
    }

    // periphery:ignore - test seam
    func setTranscriptsForTesting(_ rows: [Transcript]) {
      transcripts = rows
      startPulseIfNeeded()
    }
  #endif
}

/// Which kind of History row the list shows (#2807).
///
/// Two words, by meaning: a **Dictation** is a take made with the hotkey, a **Transcript** is
/// a file put through Transcribe a File, and History is the collection of both. The kind is
/// read from `Transcript.isImported`; nothing stores a second flag.
enum HistoryFilter: String, CaseIterable, Sendable {
  case all
  case dictations
  case transcripts

  /// The word on the control.
  var title: String {
    switch self {
    case .all: return "All"
    case .dictations: return "Dictations"
    case .transcripts: return "Transcripts"
    }
  }
}

/// Why the History list is empty (#2807). Each case has a different fix, so each gets its own
/// sentence.
enum HistoryEmptyState: Equatable, Sendable {
  /// Nothing has ever been recorded or imported.
  case nothingYet
  /// Rows exist, none of them a dictation.
  case noDictations
  /// Rows exist, none of them a transcript.
  case noTranscripts
  /// Rows exist, none matching the search.
  case noMatches
}

/// What the History detail pane shows (#2807).
enum HistoryDetail {
  /// A row the list displays: the selected one, or the just-finished dictation's own row.
  case row(Transcript)
  /// Nothing is selected, no completed dictation has landed in this session, and nothing has
  /// narrowed the list: the live pipeline's transcript, if any.
  case liveFallback
  /// Nothing to show, and the live transcript must not stand in.
  case empty
}
