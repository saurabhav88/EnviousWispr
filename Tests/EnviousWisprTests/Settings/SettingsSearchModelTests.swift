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

  static func ready(_ model: SettingsSearchModel) async -> Bool {
    await waitUntil {
      if case .ready = model.indexState { return true }
      if case .unavailable = model.indexState { return true }
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

  @Test("a search typed while the index loads gets its own results, never 'no results' first")
  func loadingNeverSaysNoResults() async throws {
    let ready = try Self.index.get()
    let gate = AsyncGate()
    let model = SettingsSearchModel(
      loadIndex: {
        await gate.wait()
        return ready
      }, announce: { _ in }, announcementDelay: .milliseconds(20))
    model.setQuery("zzqx")
    #expect(model.showsNoResults == false, "said no results while the index was still loading")
    model.setQuery("dock")
    await gate.open()
    #expect(await Self.waitUntil { model.results.first?.entryID == "showInDock" })
  }

  @Test("a missing vocabulary is 'unavailable', never 'no results'")
  func unavailableIsNotNoResults() async throws {
    let model = SettingsSearchModel(
      loadIndex: { nil }, announce: { _ in }, announcementDelay: .milliseconds(20))
    model.setQuery("mic")
    #expect(await Self.ready(model))
    #expect(model.isUnavailable)
    #expect(model.showsNoResults == false)
    #expect(model.results.isEmpty)
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

  @Test("Return before any result is on screen opens nothing, now or later")
  func returnBeforeResults() async throws {
    let ready = try Self.index.get()
    let gate = AsyncGate()
    let model = SettingsSearchModel(
      loadIndex: {
        await gate.wait()
        return ready
      }, announce: { _ in }, announcementDelay: .milliseconds(20))
    model.setQuery("dock")
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
