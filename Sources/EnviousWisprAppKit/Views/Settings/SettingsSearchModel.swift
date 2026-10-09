import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Observation

/// One Settings window's search (#3482 plan §3.3, §3.4): what was typed, the ranked places, the
/// selected result and whether the dropdown is open. Window-local and owned by the window view, so
/// two windows never share a query. It never navigates; the window turns a chosen result into a
/// guarded navigation and resets the search only when that navigation commits.
@MainActor
@Observable
final class SettingsSearchModel {
  /// The index search answers from (#3545 plan §3.5). The first non-empty query builds a
  /// title-only index synchronously and answers from it while the full index (with the bundled
  /// vocabulary) loads; the full index then replaces it and the current query runs again.
  enum IndexState {
    case notLoaded
    /// Answering from the title-only index while the full index loads.
    case loading(titleOnly: SettingsSearchIndex)
    case ready(SettingsSearchIndex)
    /// The vocabulary could not be used: the title-only index answers for this window.
    case titleOnly(SettingsSearchIndex)
  }

  /// The index answering now, nil before the first non-empty query.
  var answeringIndex: SettingsSearchIndex? {
    switch indexState {
    case .notLoaded: nil
    case .loading(let index), .ready(let index), .titleOnly(let index): index
    }
  }

  /// The meaning pass (plan §3.7 item 8): word results show at once; a final "no results" waits
  /// until the pass completes, is skipped or is abandoned at its deadline (#3545).
  enum MeaningPass: Equatable {
    case pending
    case completed
    case skipped
    /// The pass ran past `meaningDeadline`: the word results are final for this search, and the
    /// work still running can no longer change them.
    case abandoned
  }

  /// The longest a meaning pass (encoding, the vector view and scoring, once the model is loaded)
  /// may hold "No settings match" and the result-count announcement (#3545 plan §3.5). An explicit
  /// wait cap (founder 2026-10-09): the p99 of 29 ordinary process-cold passes that included the
  /// model load, 713.4 ms, measured on an M5 Max in a Debug test process by
  /// `scripts/settings-map/meaning-deadline-campaign.sh`
  /// (`.validation/runs/20261009-003707-3545-meaning-deadline`; 30 warm passes p99 11.0 ms). A
  /// pass no longer waits for the load (see `MeaningModel`), so the cap guards an encoder that
  /// stalls; after it, meaning stays off for that window session. The 8 GB M1 floor is unmeasured.
  static let meaningDeadline: Duration = .milliseconds(714)

  private(set) var query = ""
  private(set) var results: [SettingsSearchResult] = []
  /// Follows the top result until the person moves it; then stays on that entry by id while it
  /// is still a result.
  private(set) var selectedEntryID: String?
  private(set) var isPanelPresented = false
  private(set) var indexState: IndexState = .notLoaded
  private(set) var meaningPass: MeaningPass = .skipped

  /// The meaning model's load (founder 2026-10-09, #3545): a search never waits for it. While it
  /// loads, searches answer by words alone; when it is ready, the search on screen runs again
  /// with meaning. However long the load takes, it is never given up, so nobody has to reopen the
  /// window or the app to get meaning back.
  enum MeaningModel: Equatable {
    case notLoaded
    case loading
    case ready
  }

  private(set) var meaningModel: MeaningModel = .notLoaded
  /// Identifies the current load request; a window close moves it on, so an older request's
  /// answer never writes this window session's state.
  private var meaningLoadAttempt = 0
  /// Increments on every query change and reset; work for an older generation is dropped.
  private(set) var generation = 0

  private var selectionMovedByUser = false
  private var announcement: Task<Void, Never>?
  private let loadIndex: @Sendable () async -> SettingsSearchIndex?
  /// Builds the title-only index on the main actor, before the full index exists.
  private let titleIndex: @MainActor () -> SettingsSearchIndex
  /// The meaning pass (plan §3.7a): nil means words only. Skipped for the rest of the window
  /// session after any skip the worker reports.
  private let meaningWorker: SettingsSearchMeaningWorker?
  private var meaningSkipped = false
  private var meaningView: SettingsSearchPlaceVectors.View?
  private var meaningTask: Task<Void, Never>?
  /// Identifies the running pass. A query change, a reset, an index swap or a new pass moves it
  /// on, so work for an older pass never writes state, even for the same query generation.
  private var meaningPassID = 0
  private var meaningDeadlineTask: Task<Void, Never>?
  /// Returns when a pass's deadline has passed; tests pass a gate they open.
  private let meaningDeadlineElapses: @Sendable () async -> Void
  /// The worker reset a window close asked for; the next pass waits for it, so a reopened window
  /// never asks the worker before its transient failure is cleared.
  private var workerReset: Task<Void, Never>?
  /// Test seam (#3545 T8): called each time a pass's work returns, with whether it was used. A
  /// pass abandoned at its deadline still reports here when its late work ends.
  @ObservationIgnored var meaningWorkReturned: (@MainActor (_ used: Bool) -> Void)?
  /// Encoding plus scoring time of the last completed meaning pass, for `meaning_elapsed_ms`.
  private(set) var meaningElapsedMilliseconds: Double?

  // MARK: Telemetry (plan §8.1)

  /// One attempt: from the first non-empty query until a committed navigation or a dismissal.
  struct Attempt: Equatable {
    /// Share usage metrics was on when it began and has not been switched off since.
    var eligible: Bool
    /// The last query/result snapshot the panel presented; frozen while the panel is closed.
    var query = ""
    var resultCount = 0
    var meaningPending = false
    var meaningElapsedMilliseconds: Double?
    var frozen = false
  }

  private(set) var attempt: Attempt?
  /// Reads "Share usage metrics" now; the window sets it once its settings are in scope.
  @ObservationIgnored var usageMetricsOn: @MainActor () -> Bool
  private let emitFinished: @MainActor (SettingsSearchFinished) -> Void
  private let announce: @MainActor (String) -> Void
  private let announcementDelay: Duration

  /// `loadIndex` builds the index off the main actor and answers nil when the vocabulary cannot
  /// be used. `announce` speaks the result count after typing pauses.
  init(
    loadIndex: @escaping @Sendable () async -> SettingsSearchIndex?,
    titleIndex: @escaping @MainActor () -> SettingsSearchIndex = SettingsSearchModel
      .windowTitleIndex,
    meaningWorker: SettingsSearchMeaningWorker? = nil,
    meaningDeadlineElapses: @escaping @Sendable () async -> Void = {
      try? await Task.sleep(for: SettingsSearchModel.meaningDeadline)
    },
    usageMetricsOn: @escaping @MainActor () -> Bool = { false },
    emitFinished: @escaping @MainActor (SettingsSearchFinished) -> Void = { _ in },
    announce: @escaping @MainActor (String) -> Void,
    announcementDelay: Duration = .milliseconds(700)
  ) {
    self.loadIndex = loadIndex
    self.titleIndex = titleIndex
    self.usageMetricsOn = usageMetricsOn
    self.emitFinished = emitFinished
    self.meaningWorker = meaningWorker
    self.meaningDeadlineElapses = meaningDeadlineElapses
    meaningPass = meaningWorker == nil ? .skipped : .completed
    self.announce = announce
    self.announcementDelay = announcementDelay
  }

  /// The title-only index for this app's languages: the same inputs as the full index.
  static func windowTitleIndex() -> SettingsSearchIndex {
    SettingsSearchIndex.titleOnly(
      appLanguage: Bundle.main.preferredLocalizations.first ?? "en",
      preferredLanguages: Locale.preferredLanguages)
  }

  /// The search everyone sees in the app: English, the app language and the Mac's supported
  /// preferred languages, frozen when the index is built.
  static func live(announce: @escaping @MainActor (String) -> Void) -> SettingsSearchModel {
    SettingsSearchModel(
      loadIndex: {
        // The interface language the app launched in (interface-localization.md FACT:
        // app-language-drives-locale-current): "en" or "de".
        let appLanguage = Bundle.main.preferredLocalizations.first ?? "en"
        switch SettingsSearchIndex.load(
          appLanguage: appLanguage, preferredLanguages: Locale.preferredLanguages)
        {
        case .success(let index):
          #if DEBUG
            if !index.leftOut.isEmpty {
              let leftOut = index.leftOut
              Task {
                await AppLogger.shared.log(
                  "Settings search vocabulary: left out \(leftOut.count) broken part(s): \(leftOut.joined(separator: "; "))",
                  level: .info, category: "SettingsSearch")
              }
            }
          #endif
          return index
        case .failure(let error):
          #if DEBUG
            Task {
              await AppLogger.shared.log(
                "Settings search index unavailable: \(error)", level: .info,
                category: "SettingsSearch")
            }
          #endif
          return nil
        }
      },
      meaningWorker: .bundled(),
      emitFinished: { TelemetryService.shared.settingsSearchFinished($0) },
      announce: announce)
  }

  // MARK: - What the panel shows

  /// The selected result, when it is one of the results on screen.
  var selectedResult: SettingsSearchResult? {
    results.first { $0.entryID == selectedEntryID }
  }

  /// "No settings match" shows for an empty answer from any index once the meaning pass, if
  /// running, has finished: never a blank panel while the full index loads (#3545).
  var showsNoResults: Bool {
    guard !query.isEmpty, answeringIndex != nil else { return false }
    return results.isEmpty && meaningPass != .pending
  }

  // MARK: - Typing

  /// The field's text changed. A non-empty query opens the panel; an empty one closes it.
  func setQuery(_ text: String) {
    guard text != query else { return }
    query = text
    generation &+= 1
    selectionMovedByUser = false
    cancelAnnouncement()
    cancelMeaning()
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      finish(endedBy: .queryEmpty)
      results = []
      selectedEntryID = nil
      isPanelPresented = false
      return
    }
    if attempt == nil { attempt = Attempt(eligible: usageMetricsOn()) }
    isPanelPresented = true
    attempt?.frozen = false
    refresh()
    recordSnapshot()
  }

  private func refresh() {
    if case .notLoaded = indexState {
      // Answers now from titles; the full index loads once, off the main actor.
      indexState = .loading(titleOnly: titleIndex())
      let load = loadIndex
      Task { [weak self] in
        let index = await load()
        self?.indexLoaded(index)
      }
    }
    if let index = answeringIndex { deliver(index.results(for: query), for: generation) }
  }

  /// The full index arrived (or could not be built): it replaces the title-only answers by running
  /// the CURRENT query again; a cleared query stays cleared and a closed panel stays closed.
  private func indexLoaded(_ index: SettingsSearchIndex?) {
    guard case .loading(let titles) = indexState else { return }
    guard let index else {
      // The title-only index keeps answering for this window; its answer is now final.
      indexState = .titleOnly(titles)
      recordSnapshot()
      return
    }
    indexState = .ready(index)
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    cancelMeaning()
    deliver(index.results(for: query), for: generation)
  }

  /// Word results for `generation`: shown at once, then the meaning pass may re-order them.
  private func deliver(_ wordResults: [SettingsSearchResult], for generation: Int) {
    guard generation == self.generation else { return }
    // Pending first, so the snapshot shows never record an unfinished search as finished.
    startMeaning(wordResults, for: generation)
    show(wordResults, for: generation)
  }

  /// Results for `generation`; a stale generation is dropped. Delivery never opens the panel.
  private func show(_ newResults: [SettingsSearchResult], for generation: Int) {
    guard generation == self.generation else { return }
    results = newResults
    if !selectionMovedByUser || selectedResult == nil {
      selectionMovedByUser = false
      selectedEntryID = newResults.first?.entryID
    }
    recordSnapshot()
    scheduleAnnouncement(for: generation)
  }

  // MARK: - Keyboard

  /// Up (-1) or Down (+1) through the visible results, stopping at either end.
  func moveSelection(by step: Int) {
    guard isPanelPresented, !results.isEmpty else { return }
    let current = results.firstIndex { $0.entryID == selectedEntryID } ?? 0
    let next = min(max(current + step, 0), results.count - 1)
    selectedEntryID = results[next].entryID
    selectionMovedByUser = true
  }

  /// Return: the request for the selected visible result, or nil (a closed panel shows nothing,
  /// so Return never chooses a hidden result).
  func requestForSelection() -> SettingsSearchRequest? {
    guard isPanelPresented, let entryID = selectedResult?.entryID else { return nil }
    return SettingsSearchRequest(entryID: entryID)
  }

  /// Return in the field: only a result the person can see (a Return before results exist does
  /// nothing, so it never opens a result that was not on screen).
  func submit() -> SettingsSearchRequest? {
    requestForSelection()
  }

  /// A result row clicked.
  func request(for entryID: String) -> SettingsSearchRequest? {
    guard isPanelPresented, results.contains(where: { $0.entryID == entryID }) else { return nil }
    return SettingsSearchRequest(entryID: entryID)
  }

  // MARK: - Panel and reset

  /// An outside click: close the panel; keep the query, results and selection.
  func dismissPanel() {
    isPanelPresented = false
    attempt?.frozen = true
    cancelAnnouncement()
  }

  /// Typing or Cmd+F with a retained non-empty search shows it again.
  func reopenPanel() {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    isPanelPresented = true
    attempt?.frozen = false
    recordSnapshot()
  }

  // MARK: - Telemetry (plan §8.1)

  /// Share usage metrics changed: switching it off invalidates the attempt for good.
  func usageMetricsChanged(isOn: Bool) {
    if !isOn { attempt?.eligible = false }
  }

  /// The panel's current query/result snapshot, kept while it is presented.
  private func recordSnapshot() {
    guard var current = attempt, !current.frozen, isPanelPresented, !query.isEmpty else { return }
    current.query = query
    current.resultCount = results.count
    // Results still coming (the index loading, or the meaning pass running) or not available at
    // all: the attempt can only end as abandoned, never as "found nothing" with its text.
    // While the full index loads, title-only answers can still change, so the attempt is not yet
    // final either way: it is recorded as pending, as before.
    switch indexState {
    case .ready, .titleOnly: current.meaningPending = meaningPass == .pending
    case .notLoaded, .loading: current.meaningPending = true
    }
    current.meaningElapsedMilliseconds =
      meaningPass == .completed ? meaningElapsedMilliseconds : nil
    attempt = current
  }

  /// Ends the attempt with one row (deduplicated: a finished attempt is gone). A committed
  /// navigation passes how it ended; the sidebar also passes the page and tab it opened.
  func finish(
    endedBy: SettingsSearchFinished.EndedBy, sidebarPage: String? = nil, sidebarTab: String? = nil
  ) {
    guard let ended = attempt else { return }
    attempt = nil
    guard ended.eligible, usageMetricsOn(), !ended.query.isEmpty else { return }
    let outcome = Self.outcome(endedBy: endedBy, snapshot: ended)
    emitFinished(
      SettingsSearchFinished(
        outcome: outcome, endedBy: endedBy, resultCount: ended.resultCount,
        appLanguage: appLanguageCode, meaningElapsedMilliseconds: ended.meaningElapsedMilliseconds,
        sidebarPage: sidebarPage, sidebarTab: sidebarTab, typedQuery: ended.query))
  }

  static func outcome(
    endedBy: SettingsSearchFinished.EndedBy, snapshot: Attempt
  ) -> SettingsSearchFinished.Outcome {
    switch endedBy {
    case .searchResult:
      return .resultChosen
    case .sidebar:
      if snapshot.resultCount > 0 { return .sidebarBypass }
      return snapshot.meaningPending ? .abandoned : .zeroResults
    case .externalDestination, .escape, .clear, .queryEmpty, .windowClose:
      if snapshot.meaningPending { return .abandoned }
      return snapshot.resultCount == 0 ? .zeroResults : .abandoned
    }
  }

  private var appLanguageCode: String {
    if let index = answeringIndex { return index.appLanguage }
    return Bundle.main.preferredLocalizations.first == "de" ? "de" : "en"
  }

  // MARK: - Meaning pass

  /// Encodes the typed text off the main actor and re-orders the word results by meaning, adding
  /// places only the meaning model found (shown without a hint). Word results never wait for it.
  private func startMeaning(_ wordResults: [SettingsSearchResult], for generation: Int) {
    guard let worker = meaningWorker, !meaningSkipped, case .ready(let index) = indexState else {
      meaningPass = .skipped
      return
    }
    guard meaningModel == .ready else {
      // The words answer now; meaning joins when its model is ready.
      meaningPass = .skipped
      startMeaningLoad(worker)
      return
    }
    meaningPassID &+= 1
    let pass = meaningPassID
    meaningPass = .pending
    meaningElapsedMilliseconds = nil
    let text = query
    let languages = Self.meaningLanguages(index)
    let appLanguage = index.appLanguage
    let cachedView = meaningView
    let workerReset = workerReset
    // The deadline is the model's own task: it never waits on the worker, so an encoder that does
    // not return cannot hold the panel.
    let deadline = meaningDeadlineElapses
    meaningDeadlineTask = Task { [weak self] in
      guard !Task.isCancelled else { return }
      await deadline()
      guard !Task.isCancelled else { return }
      self?.meaningExpired(pass)
    }
    meaningTask = Task { [weak self] in
      // A cancelled task still enters; work for a pass that is no longer wanted stops before
      // each costly stage (the load, the encoder, the vector view, scoring) and says so once.
      guard !Task.isCancelled, self?.isCurrent(pass) == true else {
        self?.meaningWorkReturned?(false)
        return
      }
      await workerReset?.value
      guard !Task.isCancelled, self?.isCurrent(pass) == true else {
        self?.meaningWorkReturned?(false)
        return
      }
      // §8.1 meaning_elapsed_ms is query encoding plus scoring only: the model load and the
      // vector view's construction are excluded.
      if case .skipped = await worker.ensureLoaded() {
        self?.meaningFinished(nil, skipped: true, pass: pass)
        return
      }
      guard !Task.isCancelled, self?.isCurrent(pass) == true else {
        self?.meaningWorkReturned?(false)
        return
      }
      let encodeStart = ContinuousClock.now
      let outcome = await worker.encode(text, generation: generation)
      let encodeTime = encodeStart.duration(to: .now)
      switch outcome {
      case .stale:
        self?.meaningWorkReturned?(false)
      case .skipped:
        self?.meaningFinished(nil, skipped: true, pass: pass)
      case .vector(_, let values):
        guard !Task.isCancelled, self?.isCurrent(pass) == true else {
          self?.meaningWorkReturned?(false)
          return
        }
        var view = cachedView
        if view == nil, let places = await worker.placeVectors {
          guard !Task.isCancelled, self?.isCurrent(pass) == true else {
            self?.meaningWorkReturned?(false)
            return
          }
          view = await Task.detached {
            places.view(
              entryIDs: SettingsSearchCatalog.entries.map(\.id), appLanguage: appLanguage,
              vocabularyLanguages: languages)
          }.value
        }
        guard let view else {
          self?.meaningFinished(nil, skipped: true, pass: pass)
          return
        }
        guard !Task.isCancelled, self?.isCurrent(pass) == true else {
          self?.meaningWorkReturned?(false)
          return
        }
        let hits = wordResults.map {
          SettingsSearchWordHit(entryID: $0.entryID, coverage: $0.coverage, score: $0.score)
        }
        // Scoring and fusion off the main actor; the pass is checked again on return.
        let scoreStart = ContinuousClock.now
        let scored = await Task.detached { () -> [SettingsSearchFusedResult]?? in
          guard let similarities = view.similarities(query: values) else { return .none }
          return .some(SettingsSearchMeaningFusion.rank(wordHits: hits, similarities: similarities))
        }.value
        let elapsed = encodeTime + scoreStart.duration(to: .now)
        guard let fused = scored else {
          // A bad vector: words only for this window.
          self?.meaningFinished(nil, skipped: true, pass: pass)
          return
        }
        self?.meaningFinished(
          fused.map { Self.results(from: $0, words: wordResults) }, skipped: false, view: view,
          elapsed: elapsed, pass: pass)
      }
    }
  }

  /// Starts the meaning model's load once per window session; a load already running is shared.
  private func startMeaningLoad(_ worker: SettingsSearchMeaningWorker) {
    guard meaningModel == .notLoaded else { return }
    meaningModel = .loading
    meaningLoadAttempt &+= 1
    let attempt = meaningLoadAttempt
    let workerReset = workerReset
    Task { [weak self] in
      await workerReset?.value
      let readiness = await worker.ensureLoaded()
      self?.meaningLoadFinished(readiness, attempt: attempt)
    }
  }

  /// The load ended. Ready: the search on screen runs again with meaning (a cleared search stays
  /// cleared, a closed panel stays closed). Failed: words only for this window session.
  private func meaningLoadFinished(
    _ readiness: SettingsSearchMeaningWorker.Readiness, attempt: Int
  ) {
    guard attempt == meaningLoadAttempt, meaningModel == .loading else { return }
    switch readiness {
    case .ready:
      meaningModel = .ready
      guard case .ready(let index) = indexState,
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return }
      cancelMeaning()
      deliver(index.results(for: query), for: generation)
    case .skipped:
      meaningModel = .notLoaded
      meaningSkipped = true
    }
  }

  /// Whether `pass` is the pass the panel is waiting on. Every write a pass makes checks this.
  private func isCurrent(_ pass: Int) -> Bool {
    pass == meaningPassID && meaningPass == .pending
  }

  private func meaningFinished(
    _ fused: [SettingsSearchResult]?, skipped: Bool, view: SettingsSearchPlaceVectors.View? = nil,
    elapsed: Duration? = nil, pass: Int
  ) {
    let used = isCurrent(pass)
    defer { meaningWorkReturned?(used) }
    guard used else { return }
    meaningDeadlineTask?.cancel()
    meaningDeadlineTask = nil
    if skipped { meaningSkipped = true }
    if let view { meaningView = view }
    meaningElapsedMilliseconds = elapsed.map {
      Double($0.components.seconds) * 1_000 + Double($0.components.attoseconds) / 1e15
    }
    meaningPass = skipped ? .skipped : .completed
    if let fused {
      show(fused, for: generation)
    } else {
      recordSnapshot()
      // The pass ended without new results: the word results are final, so say how many.
      scheduleAnnouncement(for: generation)
    }
  }

  /// The pass ran past its deadline: the word results are final now, and the meaning pass is off
  /// for the rest of this window session, like any other transient failure (#3545 plan §3.5,
  /// G6); a window close clears it. A load still running goes on and serves the next session.
  /// The work stops at its next check, and nothing it returns is used.
  private func meaningExpired(_ pass: Int) {
    guard isCurrent(pass) else { return }
    meaningSkipped = true
    meaningDeadlineTask = nil
    meaningTask?.cancel()
    meaningTask = nil
    meaningPass = .abandoned
    meaningElapsedMilliseconds = nil
    recordSnapshot()
    scheduleAnnouncement(for: generation)
  }

  private func cancelMeaning() {
    meaningPassID &+= 1
    meaningTask?.cancel()
    meaningTask = nil
    meaningDeadlineTask?.cancel()
    meaningDeadlineTask = nil
    let next = generation
    if let worker = meaningWorker { Task { await worker.advance(to: next) } }
    if !meaningSkipped, meaningWorker != nil { meaningPass = .completed }
  }

  /// The meaning view uses the window's active-language snapshot (plan §3.7a): English, the app
  /// language and the Mac's supported preferred languages, the same set as the word leg.
  static func meaningLanguages(_ index: SettingsSearchIndex) -> [String] {
    index.languages
  }

  /// Fused order back to result rows: word results keep their scores and hints; a place only the
  /// meaning model found has no hint (it matched no authored word).
  static func results(
    from fused: [SettingsSearchFusedResult], words: [SettingsSearchResult]
  ) -> [SettingsSearchResult] {
    let byID = Dictionary(words.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
    let kinds = Dictionary(
      SettingsSearchCatalog.entries.map { ($0.id, $0.kind) },
      uniquingKeysWith: { first, _ in first })
    return fused.compactMap { item in
      if let word = byID[item.entryID] { return word }
      guard let kind = kinds[item.entryID] else { return nil }
      return SettingsSearchResult(
        entryID: item.entryID, kind: kind, coverage: 0, score: 0, hint: nil)
    }
  }

  /// Escape, the clear button, a committed navigation or the window closing. `endedBy` finishes
  /// the attempt first (nil when the caller already finished it, as a navigation commit does).
  func reset(endedBy: SettingsSearchFinished.EndedBy? = nil) {
    if let endedBy { finish(endedBy: endedBy) }
    query = ""
    results = []
    selectedEntryID = nil
    selectionMovedByUser = false
    isPanelPresented = false
    generation &+= 1
    cancelAnnouncement()
    cancelMeaning()
    if endedBy == .windowClose { startNewWindowSession() }
  }

  /// A closed window's transient meaning failure is retried in the next window session (#3545
  /// plan §3.5): the skip clears here, and the worker's after the reset task this queues, which
  /// the next pass waits for. A load still running is kept, never started twice.
  private func startNewWindowSession() {
    meaningSkipped = false
    // Readiness is checked again after the queued worker reset: a transient failure may have
    // discarded the encoder, and any reload must leave word answers final. A load still running
    // is shared by the worker, and the old request's answer is ignored.
    meaningModel = .notLoaded
    meaningLoadAttempt &+= 1
    guard let worker = meaningWorker else { return }
    let previous = workerReset
    workerReset = Task {
      await previous?.value
      await worker.resetTransientFailure()
    }
  }

  // MARK: - Announcement

  private func scheduleAnnouncement(for generation: Int) {
    cancelAnnouncement()
    let delay = announcementDelay
    announcement = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self, generation == self.generation,
        self.isPanelPresented, !self.results.isEmpty || self.meaningPass != .pending
      else { return }
      self.announce(SettingsSearchCopy.resultCount(self.results.count))
    }
  }

  private func cancelAnnouncement() {
    announcement?.cancel()
    announcement = nil
  }
}
