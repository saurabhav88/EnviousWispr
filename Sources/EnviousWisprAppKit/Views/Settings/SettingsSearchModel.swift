import EnviousWisprCore
import Foundation
import Observation

/// One Settings window's search (#3482 plan §3.3, §3.4): what was typed, the ranked places, the
/// selected result and whether the dropdown is open. Window-local and owned by the window view, so
/// two windows never share a query. It never navigates; the window turns a chosen result into a
/// guarded navigation and resets the search only when that navigation commits.
@MainActor
@Observable
final class SettingsSearchModel {
  /// The index, built once per window from the bundled vocabulary on the first non-empty query.
  enum IndexState {
    case notLoaded
    case loading
    case ready(SettingsSearchIndex)
    /// The vocabulary is missing or invalid: search says it is unavailable, never "no results".
    case unavailable
  }

  /// The meaning pass (plan §3.7 item 8): word results show at once; a final "no results" waits
  /// until the pass completes or is skipped. Until the pass is wired it is always skipped.
  enum MeaningPass: Equatable {
    case pending
    case completed
    case skipped
  }

  private(set) var query = ""
  private(set) var results: [SettingsSearchResult] = []
  /// Follows the top result until the person moves it; then stays on that entry by id while it
  /// is still a result.
  private(set) var selectedEntryID: String?
  private(set) var isPanelPresented = false
  private(set) var indexState: IndexState = .notLoaded
  private(set) var meaningPass: MeaningPass = .skipped
  /// Increments on every query change and reset; work for an older generation is dropped.
  private(set) var generation = 0

  private var selectionMovedByUser = false
  /// Return pressed while the index was still loading, for this generation: the top result
  /// opens as soon as it exists, unless the person types again first.
  private var pendingSubmit: Int?
  /// Opens a result chosen by a Return that arrived before results did (set by the field).
  @ObservationIgnored var submitWhenReady: ((SettingsSearchRequest) -> Void)?
  private var announcement: Task<Void, Never>?
  private let loadIndex: @Sendable () async -> SettingsSearchIndex?
  /// The meaning pass (plan §3.7a): nil means words only. Skipped for the rest of the window
  /// session after any skip the worker reports.
  private let meaningWorker: SettingsSearchMeaningWorker?
  private var meaningSkipped = false
  private var meaningView: SettingsSearchPlaceVectors.View?
  private var meaningTask: Task<Void, Never>?
  private let announce: @MainActor (String) -> Void
  private let announcementDelay: Duration

  /// `loadIndex` builds the index off the main actor and answers nil when the vocabulary cannot
  /// be used. `announce` speaks the result count after typing pauses.
  init(
    loadIndex: @escaping @Sendable () async -> SettingsSearchIndex?,
    meaningWorker: SettingsSearchMeaningWorker? = nil,
    announce: @escaping @MainActor (String) -> Void,
    announcementDelay: Duration = .milliseconds(700)
  ) {
    self.loadIndex = loadIndex
    self.meaningWorker = meaningWorker
    meaningPass = meaningWorker == nil ? .skipped : .completed
    self.announce = announce
    self.announcementDelay = announcementDelay
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
      announce: announce)
  }

  // MARK: - What the panel shows

  /// The selected result, when it is one of the results on screen.
  var selectedResult: SettingsSearchResult? {
    results.first { $0.entryID == selectedEntryID }
  }

  /// "No settings match" shows only for a finished, empty search: never while the index loads,
  /// when it is unavailable, or while the meaning pass may still add results.
  var showsNoResults: Bool {
    guard !query.isEmpty, case .ready = indexState else { return false }
    return results.isEmpty && meaningPass != .pending
  }

  var isUnavailable: Bool {
    if case .unavailable = indexState { return true }
    return false
  }

  // MARK: - Typing

  /// The field's text changed. A non-empty query opens the panel; an empty one closes it.
  func setQuery(_ text: String) {
    guard text != query else { return }
    query = text
    generation &+= 1
    selectionMovedByUser = false
    pendingSubmit = nil
    cancelAnnouncement()
    cancelMeaning()
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      results = []
      selectedEntryID = nil
      isPanelPresented = false
      return
    }
    isPanelPresented = true
    refresh()
  }

  private func refresh() {
    switch indexState {
    case .ready(let index):
      deliver(index.results(for: query), for: generation)
    case .notLoaded:
      indexState = .loading
      let load = loadIndex
      Task { [weak self] in
        let index = await load()
        self?.indexLoaded(index)
      }
    case .loading, .unavailable:
      break
    }
  }

  private func indexLoaded(_ index: SettingsSearchIndex?) {
    guard let index else {
      indexState = .unavailable
      results = []
      selectedEntryID = nil
      return
    }
    indexState = .ready(index)
    if !query.isEmpty { deliver(index.results(for: query), for: generation) }
  }

  /// Word results for `generation`: shown at once, then the meaning pass may re-order them.
  private func deliver(_ wordResults: [SettingsSearchResult], for generation: Int) {
    guard generation == self.generation else { return }
    show(wordResults, for: generation)
    startMeaning(wordResults, for: generation)
  }

  /// Results for `generation`; a stale generation is dropped. Delivery never opens the panel.
  private func show(_ newResults: [SettingsSearchResult], for generation: Int) {
    guard generation == self.generation else { return }
    results = newResults
    if !selectionMovedByUser || selectedResult == nil {
      selectionMovedByUser = false
      selectedEntryID = newResults.first?.entryID
    }
    if pendingSubmit == generation {
      pendingSubmit = nil
      if let request = requestForSelection() {
        submitWhenReady?(request)
        return
      }
    }
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

  /// Return in the field: the selected visible result, or, while the index is still loading,
  /// the top result once it arrives (nil now in that case).
  func submit() -> SettingsSearchRequest? {
    if let request = requestForSelection() { return request }
    if isPanelPresented, case .loading = indexState { pendingSubmit = generation }
    return nil
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
    cancelAnnouncement()
  }

  /// Typing or Cmd+F with a retained non-empty search shows it again.
  func reopenPanel() {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    isPanelPresented = true
  }

  // MARK: - Meaning pass

  /// Encodes the typed text off the main actor and re-orders the word results by meaning, adding
  /// places only the meaning model found (shown without a hint). Word results never wait for it.
  private func startMeaning(_ wordResults: [SettingsSearchResult], for generation: Int) {
    guard let worker = meaningWorker, !meaningSkipped, case .ready(let index) = indexState else {
      meaningPass = .skipped
      return
    }
    meaningPass = .pending
    let text = query
    let languages = Self.meaningLanguages(index)
    let appLanguage = index.appLanguage
    let cachedView = meaningView
    meaningTask = Task { [weak self] in
      let outcome = await worker.encode(text, generation: generation)
      switch outcome {
      case .stale:
        return
      case .skipped:
        self?.meaningFinished(nil, skipped: true, for: generation)
      case .vector(_, let values):
        var view = cachedView
        if view == nil, let places = await worker.placeVectors {
          view = await Task.detached {
            places.view(
              entryIDs: SettingsSearchCatalog.entries.map(\.id), appLanguage: appLanguage,
              vocabularyLanguages: languages)
          }.value
        }
        guard let view, let similarities = view.similarities(query: values) else {
          // Assets built for another map, or a bad vector: words only for this window.
          self?.meaningFinished(nil, skipped: true, for: generation)
          return
        }
        let hits = wordResults.map {
          SettingsSearchWordHit(entryID: $0.entryID, coverage: $0.coverage, score: $0.score)
        }
        let fused = SettingsSearchMeaningFusion.rank(wordHits: hits, similarities: similarities)
        self?.meaningView = view
        self?.meaningFinished(fused.map { Self.results(from: $0, words: wordResults) }, skipped: false, for: generation)
      }
    }
  }

  private func meaningFinished(
    _ fused: [SettingsSearchResult]?, skipped: Bool, for generation: Int
  ) {
    if skipped { meaningSkipped = true }
    guard generation == self.generation else { return }
    if let fused { show(fused, for: generation) }
    meaningPass = skipped ? .skipped : .completed
  }

  private func cancelMeaning() {
    meaningTask?.cancel()
    meaningTask = nil
    let next = generation
    if let worker = meaningWorker { Task { await worker.advance(to: next) } }
    if !meaningSkipped, meaningWorker != nil { meaningPass = .completed }
  }

  /// The bench-validated meaning view: the app language's name rows and vocabulary blocks, plus
  /// the Mac's other preferred languages' blocks; English blocks only when English is the app
  /// language (a German window's English block was never measured).
  static func meaningLanguages(_ index: SettingsSearchIndex) -> [String] {
    index.languages.filter { $0 != "en" || index.appLanguage == "en" }
  }

  /// Fused order back to result rows: word results keep their scores and hints; a place only the
  /// meaning model found has no hint (it matched no authored word).
  static func results(
    from fused: [SettingsSearchFusedResult], words: [SettingsSearchResult]
  ) -> [SettingsSearchResult] {
    let byID = Dictionary(words.map { ($0.entryID, $0) }, uniquingKeysWith: { first, _ in first })
    let kinds = Dictionary(
      SettingsSearchCatalog.entries.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
    return fused.compactMap { item in
      if let word = byID[item.entryID] { return word }
      guard let kind = kinds[item.entryID] else { return nil }
      return SettingsSearchResult(entryID: item.entryID, kind: kind, coverage: 0, score: 0, hint: nil)
    }
  }

  /// Escape, the clear button, a committed navigation or the window closing.
  func reset() {
    query = ""
    results = []
    selectedEntryID = nil
    selectionMovedByUser = false
    isPanelPresented = false
    pendingSubmit = nil
    generation &+= 1
    cancelAnnouncement()
    cancelMeaning()
  }

  // MARK: - Announcement

  private func scheduleAnnouncement(for generation: Int) {
    cancelAnnouncement()
    let delay = announcementDelay
    announcement = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self, generation == self.generation,
        self.isPanelPresented
      else { return }
      self.announce(SettingsSearchCopy.resultCount(self.results.count))
    }
  }

  private func cancelAnnouncement() {
    announcement?.cancel()
    announcement = nil
  }
}
