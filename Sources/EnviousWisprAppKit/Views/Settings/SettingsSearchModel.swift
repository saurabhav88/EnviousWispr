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
  private let announce: @MainActor (String) -> Void
  private let announcementDelay: Duration

  /// `loadIndex` builds the index off the main actor and answers nil when the vocabulary cannot
  /// be used. `announce` speaks the result count after typing pauses.
  init(
    loadIndex: @escaping @Sendable () async -> SettingsSearchIndex?,
    announce: @escaping @MainActor (String) -> Void,
    announcementDelay: Duration = .milliseconds(700)
  ) {
    self.loadIndex = loadIndex
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

  /// Results for `generation`; a stale generation is dropped. Delivery never opens the panel.
  private func deliver(_ newResults: [SettingsSearchResult], for generation: Int) {
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
