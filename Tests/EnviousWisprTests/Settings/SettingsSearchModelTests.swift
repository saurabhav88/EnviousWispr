import EnviousWisprServices
import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit

/// The Settings search field's behaviour (#3482 plan §3.3, §3.4). When this fails, typing in
/// Settings search shows a stale or wrong selection, Return opens something the person cannot
/// see, or a closed search comes back on its own.
@MainActor
@Suite("Settings search field model (#3482)", .tags(.productOutcome))
struct SettingsSearchModelTests {
  @Test("the result list never runs past the window: at most eight rows, else the room left")
  func listHeightFitsTheWindow() {
    let eightRows = SettingsSearchPanel.rowHeight * SettingsSearchPanel.visibleRows
    #expect(SettingsSearchPanel.listHeight(available: .infinity) == eightRows)
    #expect(SettingsSearchPanel.listHeight(available: 1_000) == eightRows)
    // The smallest window (750 x 440) leaves less than eight rows under the field; uncapped, the
    // list ran about 123 pt past the window's bottom edge (live UAT, 2026-10-07).
    #expect(SettingsSearchPanel.listHeight(available: 287) == 285)
    #expect(SettingsSearchPanel.listHeight(available: 0) == 0)
  }

  static let index = Result { try SettingsSearchMatchingTests.index("en", preferred: ["en-US"]) }

  @MainActor @Observable final class SpokenLog { var lines: [String] = [] }
  @MainActor final class FinishedLog { var rows: [SettingsSearchFinished] = [] }

  /// A model on the real index; announcements are collected, not spoken.
  static func model(spoken: SpokenLog = SpokenLog()) throws -> SettingsSearchModel {
    let ready = try Self.index.get()
    return SettingsSearchModel(
      loadIndex: { ready }, announce: { spoken.lines.append($0) },
      announcementDelay: .milliseconds(20))
  }

  /// Waits for `condition` to hold, woken by the Observation changes it reads; false at the
  /// deadline. The deadline only bounds the wait and never feeds an assertion.
  static func waitUntil(
    seconds: Double = 5, _ condition: @escaping @MainActor () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition() {
      if ContinuousClock.now >= deadline { return false }
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let once = ResumeOnce(continuation)
        withObservationTracking {
          _ = condition()
        } onChange: {
          Task { @MainActor in once.resume() }
        }
        if condition() { once.resume() }
        Task {
          try? await Task.sleep(until: deadline)  // deadline-fallback: bounds a signal wait
          once.resume()
        }
      }
    }
    return true
  }

  /// The full index has arrived, or could not be built and the title-only index answers.
  static func ready(_ model: SettingsSearchModel) async -> Bool {
    await waitUntil {
      if case .ready = model.indexState { return true }
      if case .titleOnly = model.indexState { return true }
      return false
    }
  }

  @Test("the waiter gives up at its deadline when nothing changes")
  func waiterDeadline() async {
    let started = ContinuousClock.now
    #expect(await Self.waitUntil(seconds: 0.05) { false } == false)
    #expect(ContinuousClock.now - started < .seconds(4), "the waiter ignored its deadline")
  }

  @Test("typing opens the panel with the top match selected; clearing the text closes it")
  func typingAndClearing() async throws {
    let model = try Self.model()
    model.setQuery("mic")
    #expect(await Self.ready(model))
    #expect(model.isPanelPresented)
    #expect(model.results.first?.entryID == "inputDevice")
    #expect(model.selectedEntryID == "inputDevice")
    model.setQuery("")
    #expect(model.isPanelPresented == false)
    #expect(model.results.isEmpty)
    #expect(model.selectedEntryID == nil)
  }

  @Test("arrow keys move the selection; a new search starts at its top match")
  func selectionFollowsTheUser() async throws {
    let model = try Self.model()
    model.setQuery("mic")
    #expect(await Self.ready(model))
    let second = try #require(model.results.dropFirst().first?.entryID)
    model.moveSelection(by: 1)
    #expect(model.selectedEntryID == second)
    model.moveSelection(by: -5)
    #expect(model.selectedEntryID == model.results.first?.entryID, "Up stops at the top")
    model.moveSelection(by: 1)
    model.setQuery("dock")
    #expect(model.selectedEntryID == model.results.first?.entryID)
  }

  @Test("Return chooses only a result the panel is showing")
  func returnNeverChoosesAHiddenResult() async throws {
    let model = try Self.model()
    model.setQuery("dock")
    #expect(await Self.ready(model))
    #expect(model.requestForSelection()?.entryID == "showInDock")
    model.dismissPanel()
    #expect(model.requestForSelection() == nil, "Return chose a result behind a closed panel")
    #expect(model.request(for: "showInDock") == nil)
    model.reopenPanel()
    #expect(model.requestForSelection()?.entryID == "showInDock")
    #expect(model.request(for: "notAResult") == nil)
  }

  @Test("an outside click closes the panel but keeps the search; reset clears everything")
  func dismissKeepsResetClears() async throws {
    let model = try Self.model()
    model.setQuery("dark")
    #expect(await Self.ready(model))
    let results = model.results.map(\.entryID)
    model.dismissPanel()
    #expect(model.isPanelPresented == false)
    #expect(model.query == "dark")
    #expect(model.results.map(\.entryID) == results)
    let generation = model.generation
    model.reset()
    #expect(model.query.isEmpty && model.results.isEmpty && model.selectedEntryID == nil)
    #expect(model.isPanelPresented == false)
    #expect(model.generation > generation)
    model.reopenPanel()
    #expect(model.isPanelPresented == false, "an empty search reopened")
  }

  /// A small index whose answers the test controls: each place found by its one title word.
  static func fixture(_ rows: [(SettingsMapID, String)]) -> SettingsSearchIndex {
    let documents = rows.map { id, title in
      SettingsSearchIndex.Document(
        id: id.rawValue, kind: .setting, parentID: nil, titles: ["en": title], descriptions: [:],
        context: [:], bias: 0)
    }
    return SettingsSearchIndex(
      documents: documents, blocks: [:], appLanguage: "en", interface: ["en"], languages: ["en"],
      stop: [], markers: [])
  }

  /// A model that answers from `titles` at once and from `full` once `gate` opens; counts how
  /// often the full index is asked for.
  static func gatedModel(
    _ gate: AsyncGate, loads: LoadCounter = LoadCounter(),
    titles: SettingsSearchIndex, full: SettingsSearchIndex?,
    usageMetricsOn: @escaping @MainActor () -> Bool = { false },
    emitFinished: @escaping @MainActor (SettingsSearchFinished) -> Void = { _ in }
  ) -> SettingsSearchModel {
    SettingsSearchModel(
      loadIndex: {
        await loads.count()
        await gate.wait()
        return full
      }, titleIndex: { titles }, usageMetricsOn: usageMetricsOn, emitFinished: emitFinished,
      announce: { _ in }, announcementDelay: .milliseconds(20))
  }

  // #3545 T8. Replaces #3482's "a search typed while the index loads ... never 'no results'
  // first": the panel now answers from titles at once instead of showing nothing while the full
  // index loads, so an unmatched search says "No settings match" from its title-only answer.
  @Test("a search typed while the full index loads is answered from titles; the full index reruns the current one")
  func titleAnswersWhileLoading() async throws {
    let gate = AsyncGate()
    let loads = LoadCounter()
    let model = Self.gatedModel(
      gate, loads: loads,
      titles: Self.fixture([(.theme, "alpha"), (.inputDevice, "beta")]),
      full: Self.fixture([(.showInDock, "beta")]))
    model.setQuery("alpha")
    // Before setQuery returned: visible, selected, choosable, from titles.
    #expect(model.isPanelPresented)
    #expect(model.results.map(\.entryID) == ["theme"])
    #expect(model.selectedEntryID == "theme")
    #expect(model.requestForSelection()?.entryID == "theme")
    if case .loading = model.indexState {} else { Issue.record("not answering from titles: \(model.indexState)") }
    // A later search during the same load also answers at once, from titles.
    model.setQuery("beta")
    #expect(model.results.map(\.entryID) == ["inputDevice"])
    model.setQuery("zzqx")
    #expect(model.results.isEmpty)
    #expect(model.showsNoResults, "a blank panel while the full index loads")
    model.setQuery("beta")
    await gate.open()
    #expect(await Self.waitUntil { model.results.map(\.entryID) == ["showInDock"] })
    #expect(await loads.value == 1, "the full index was loaded more than once")
    // The full index answers "alpha" with nothing: it really replaced the title index.
    model.setQuery("alpha")
    #expect(model.results.isEmpty)
  }

  @Test("the full index keeps a selection the person moved, and never reopens or revives a search")
  func swapKeepsThePersonsState() async throws {
    // Titles answer A then B; the person moves to B. The full index puts C first; B survives.
    let gate = AsyncGate()
    let model = Self.gatedModel(
      gate, titles: Self.fixture([(.theme, "gamma"), (.inputDevice, "gamma")]),
      full: Self.fixture([(.showInDock, "gamma"), (.theme, "gamma"), (.inputDevice, "gamma")]))
    model.setQuery("gamma")
    #expect(model.results.map(\.entryID) == ["theme", "inputDevice"])
    model.moveSelection(by: 1)
    #expect(model.selectedEntryID == "inputDevice")
    await gate.open()
    #expect(await Self.waitUntil { model.results.first?.entryID == "showInDock" })
    #expect(model.selectedEntryID == "inputDevice", "the full index took back the person's selection")

    // A closed panel stays closed when the full index arrives.
    let closedGate = AsyncGate()
    let closed = Self.gatedModel(
      closedGate, titles: Self.fixture([(.theme, "beta")]), full: Self.fixture([(.showInDock, "beta")]))
    closed.setQuery("beta")
    closed.dismissPanel()
    await closedGate.open()
    #expect(await Self.waitUntil { closed.results.first?.entryID == "showInDock" })
    #expect(closed.isPanelPresented == false, "the full index reopened a closed panel")
    #expect(closed.query == "beta")

    // A search cleared while loading stays cleared.
    let resetGate = AsyncGate()
    let reset = Self.gatedModel(
      resetGate, titles: Self.fixture([(.theme, "beta")]), full: Self.fixture([(.showInDock, "beta")]))
    reset.setQuery("beta")
    reset.reset()
    await resetGate.open()
    #expect(await Self.ready(reset))
    #expect(reset.query.isEmpty && reset.results.isEmpty && reset.isPanelPresented == false)
  }

  @Test("a vocabulary that cannot be used leaves search answering by title, and the attempt final")
  func unusableVocabularyKeepsTitleSearch() async throws {
    let finished = FinishedLog()
    let gate = AsyncGate()
    let model = Self.gatedModel(
      gate, titles: Self.fixture([(.theme, "beta")]), full: nil, usageMetricsOn: { true },
      emitFinished: { finished.rows.append($0) })
    model.setQuery("zzqx")
    #expect(model.attempt?.meaningPending == true, "titles answer while the full index loads")
    await gate.open()
    #expect(await Self.ready(model))
    if case .titleOnly = model.indexState {} else { Issue.record("expected title-only: \(model.indexState)") }
    #expect(model.attempt?.meaningPending == false, "the title-only answer is final now")
    #expect(model.showsNoResults)
    model.setQuery("beta")
    #expect(model.results.map(\.entryID) == ["theme"])
    model.setQuery("zzqx")
    model.reset(endedBy: .escape)
    #expect(finished.rows.map(\.outcome) == [.zeroResults])
  }

  @Test("the title-only index holds every searchable place and builds quickly enough to measure")
  func titleIndexCoversTheCatalog() {
    let started = ContinuousClock.now
    let index = SettingsSearchIndex.titleOnly(appLanguage: "en", preferredLanguages: ["en-US"])
    let elapsed = started.duration(to: .now)
    #expect(index.places.count == SettingsSearchCatalog.entries.count)
    #expect(index.places.allSatisfy { !$0.visibleTitle.isEmpty }, "a place with no title words")
    print("TITLE-INDEX places=\(index.places.count) build=\(elapsed)")
  }

  /// The built app's English and German text, whatever language this test process runs in.
  static let builtCatalogWithLabels: SettingsSearchIndex.Copy = {
    var copy = SettingsSearchMatchingTests.builtCatalog
    copy.dynamicLabel = { id, language in
      SettingsSearchPresentation.dynamicTitleResource(of: id).flatMap {
        try? SettingsMapExportTests.resolve($0, language)
      }
    }
    return copy
  }()

  @Test("a German window's title index names run-time places in German and in English")
  func titleIndexLabelsFollowTheLanguage() throws {
    let german = SettingsSearchIndex.titleOnly(
      appLanguage: "de", preferredLanguages: ["de-DE", "en-US"], copy: Self.builtCatalogWithLabels)
    let english = SettingsSearchIndex.titleOnly(
      appLanguage: "en", preferredLanguages: ["en-US"], copy: Self.builtCatalogWithLabels)
    let id = SettingsMapID.lockedLanguage.rawValue
    let de = try #require(german.places.first { $0.id == id })
    let en = try #require(english.places.first { $0.id == id })
    #expect(de.visibleTitle["diktiersprache"] != nil, "German label missing: \(de.visibleTitle)")
    #expect(de.otherTitle["dictation"] != nil, "English label missing under German: \(de.otherTitle)")
    #expect(en.visibleTitle["dictation"] != nil, "English label missing: \(en.visibleTitle)")
    #expect(en.visibleTitle["diktiersprache"] == nil)
    // A German search finds it by its German name.
    #expect(german.results(for: "diktiersprache").first?.entryID == id)
  }

  @Test("nothing matching shows no results once the search is finished")
  func noResults() async throws {
    let model = try Self.model()
    model.setQuery("zzqx")
    #expect(await Self.ready(model))
    #expect(model.showsNoResults)
    #expect(model.meaningPass == .skipped)
  }

  @Test("the result count is spoken after typing pauses, and only for the current search")
  func announcement() async throws {
    let spoken = SpokenLog()
    let model = try Self.model(spoken: spoken)
    model.setQuery("dock")
    #expect(await Self.ready(model))
    model.setQuery("dar")
    model.setQuery("dark")
    #expect(await Self.waitUntil { spoken.lines.count >= 1 })
    #expect(spoken.lines == [SettingsSearchCopy.resultCount(model.results.count)])
    model.setQuery("mic")
    model.reset()
    try await Task.sleep(for: .milliseconds(150))  // test-fixture-timer: outlive the 20 ms announcement timer to show a cancelled one never speaks
    #expect(spoken.lines.count == 1, "a reset search was still announced: \(spoken.lines)")
  }

  // #3545: while the full index loads, titles answer at once, so "before any result is on screen"
  // is a search with no title match that the full index then answers. Same guard: Return opens
  // only what the panel shows.
  @Test("Return before any result is on screen opens nothing, now or later")
  func returnBeforeResults() async throws {
    let gate = AsyncGate()
    let model = Self.gatedModel(
      gate, titles: Self.fixture([(.theme, "alpha")]), full: Self.fixture([(.showInDock, "delta")]))
    model.setQuery("delta")
    #expect(model.results.isEmpty)
    #expect(model.submit() == nil, "Return opened a result nobody could see")
    await gate.open()
    #expect(await Self.waitUntil { model.results.first?.entryID == "showInDock" })
    #expect(model.submit()?.entryID == "showInDock", "a later Return opens the visible result")
  }

  @Test("every searchable place has a result title, a breadcrumb and a request")
  func everyResultCanBeShown() throws {
    for entry in SettingsSearchCatalog.entries {
      let id = try #require(SettingsMapID(rawValue: entry.id))
      _ = SettingsMap.takeRecordedFaults()
      let title = SettingsSearchPresentation.title(of: id)
      #expect(title.isEmpty == false, "\(entry.id) has no result title")
      #expect(SettingsMap.takeRecordedFaults() == [], "\(entry.id): wiring fault")
      #expect(
        SettingsSearchPresentation.breadcrumb(of: id).isEmpty == false,
        "\(entry.id) has no breadcrumb")
      #expect(SettingsSearchRequest(entryID: entry.id) != nil, "\(entry.id) cannot be opened")
    }
  }

  @Test("a choice's breadcrumb names its page and its setting")
  func breadcrumbs() throws {
    #expect(SettingsSearchPresentation.title(of: .themeDark) == "Dark")
    let crumb = SettingsSearchPresentation.breadcrumb(of: .themeDark)
    #expect(crumb.hasPrefix("App Settings"), "\(crumb)")
    #expect(crumb.hasSuffix("Theme"), "\(crumb)")
    #expect(SettingsSearchPresentation.title(of: .apiKeyReveal) == "Show key")
  }
}

/// Resumes a continuation once, whichever of the change or the deadline comes first.
@MainActor final class ResumeOnce {
  private var continuation: CheckedContinuation<Void, Never>?
  init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
  func resume() {
    continuation?.resume()
    continuation = nil
  }
}

/// A one-shot gate a test opens to let a parked load finish.
actor LoadCounter {
  private(set) var value = 0
  func count() { value += 1 }
}

actor AsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    waiters.forEach { $0.resume() }
    waiters = []
  }
}
