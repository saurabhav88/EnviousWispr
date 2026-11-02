import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4321. The Settings window's decisions for the EnviousMeet Summaries leave question, through
/// the same calls `UnifiedWindowView` makes. When this is wrong, "Go back to" offers or restores
/// the wrong engine (or changes dictation's), a later visit forgets the engine it began with, a
/// Meetings tab click or search result loses its destination, or "key not saved yet" appears for
/// a key that was saved or belongs to another provider. The window's own wiring is proven in Live
/// UAT, not here.
@MainActor
@Suite("Settings window decisions for the Summaries leave question (#4321)", .tags(.productOutcome))
struct SummarySetupNavigationTests {
  typealias World = PolishSetupLeaveGuardTests.World

  private static func onSummaries() -> SettingsNavigationState {
    var state = SettingsNavigationState()
    state.perform(.destination(.meetings(.summaries)))
    return state
  }

  private static func ask(
    _ intent: SettingsNavigationIntent, from state: SettingsNavigationState, world: World,
    monitor: PolishSetupMonitor, previous: LLMProvider? = nil, keyNotSaved: Bool = false
  ) -> PolishSetupLeaveRequest? {
    PolishSetupLeaveGuard.request(
      for: intent, from: state, scope: .meetingSummary, monitor: monitor,
      previousProvider: previous, currentProvider: world.provider, keyNotSaved: keyNotSaved)
  }

  // MARK: - When a visit begins

  @Test(
    "a Summaries visit begins on entry by tab, sidebar memory, search or link, never while staying")
  func visitBeginsOnlyOnEntry() throws {
    let scope = PolishSetupScope.meetingSummary
    func after(_ state: SettingsNavigationState, _ intent: SettingsNavigationIntent)
      -> SettingsNavigationState
    {
      var next = state
      next.perform(intent)
      return next
    }
    // From another Meetings tab, by the tab strip's destination.
    var general = SettingsNavigationState()
    general.perform(.destination(.meetings(.general)))
    #expect(scope.entered(from: general, to: after(general, .destination(.meetings(.summaries)))))
    // A sidebar click on Meetings whose remembered tab is Summaries.
    var elsewhere = Self.onSummaries()
    elsewhere.perform(.sidebar(.history))
    #expect(scope.entered(from: elsewhere, to: after(elsewhere, .sidebar(.meetings))))
    // A coordinator request (the menu, a notification) to Summaries.
    let history = SettingsNavigationState()
    #expect(scope.entered(from: history, to: after(history, .destination(.meetings(.summaries)))))
    // A search result on the Summaries tab.
    let entry = try #require(
      SettingsMapID.allCases.first {
        SettingsMap.node($0).destination == .meetings(.summaries)
      })
    let search = try #require(SettingsSearchRequest(entryID: entry.rawValue))
    #expect(scope.entered(from: history, to: after(history, .search(search))))

    // Staying on Summaries, or moving between other places, begins nothing.
    let summaries = Self.onSummaries()
    #expect(scope.entered(from: summaries, to: after(summaries, .sidebar(.meetings))) == false)
    #expect(scope.entered(from: summaries, to: summaries) == false)
    #expect(scope.entered(from: history, to: after(history, .destination(.meetings(.general)))) == false)
    // Dictation's visits are judged the same way, on the AI Polish page only.
    #expect(
      PolishSetupScope.dictation.entered(from: history, to: after(history, .sidebar(.aiPolish))))
    #expect(PolishSetupScope.dictation.entered(from: history, to: summaries) == false)
  }

  // MARK: - Routes keep their destination

  @Test("a tab click, a search result and a link leaving Summaries keep their whole destination")
  func routesKeepTheirDestination() throws {
    let world = World()
    let monitor = PolishSetupLeaveGuardTests.monitor(world)
    defer { monitor.stop() }
    let summaries = Self.onSummaries()

    let tab = try #require(
      Self.ask(.destination(.meetings(.callApps)), from: summaries, world: world, monitor: monitor))
    #expect(tab.intent == .destination(.meetings(.callApps)))

    let search = try #require(SettingsSearchRequest(entryID: "selfLearningDictionary"))
    let fromSearch = try #require(
      Self.ask(.search(search), from: summaries, world: world, monitor: monitor))
    #expect(fromSearch.intent == .search(search))

    // The latest request replaces the pending destination and keeps the summary scope; Leave
    // anyway goes there.
    let latest = SettingsNavigationIntent.destination(.appSettings(.privacy))
    let replaced = PolishSetupLeaveGuard.replacingPendingDestination(of: tab, with: latest)
    #expect(replaced.scope == .meetingSummary)
    #expect(replaced.episode == tab.episode)
    #expect(
      PolishSetupLeaveGuard.resolve(
        .leaveAnyway, request: replaced, monitor: monitor, previousProvider: nil,
        currentProvider: world.provider, keyNotSaved: false) == .navigate(latest))
  }

  // MARK: - Go back

  @Test("Go back restores the summary engine through its own setter and leaves dictation alone")
  func goBackRestoresOnlyTheSummaryEngine() throws {
    let suite = try #require(TestDefaults.suite("ew-4321-restore-\(UUID().uuidString)"))
    let settings = SettingsManager(defaults: suite)
    settings.llmProvider = .gemini
    settings.meetingSummaryLLMProvider = .claude

    PolishSetupLeaveGuard.restore(.appleIntelligence, scope: .meetingSummary, in: settings)
    #expect(settings.meetingSummaryLLMProvider == .appleIntelligence)
    #expect(settings.llmProvider == .gemini)

    PolishSetupLeaveGuard.restore(.egOne, scope: .dictation, in: settings)
    #expect(settings.llmProvider == .egOne)
    #expect(settings.meetingSummaryLLMProvider == .appleIntelligence)
  }

  @Test("after Go back, the window leaves only when the restored engine is set up")
  func goBackRecheck() throws {
    let world = World()
    let monitor = PolishSetupLeaveGuardTests.monitor(world)
    defer { monitor.stop() }
    let asked = try #require(
      Self.ask(
        .sidebar(.history), from: Self.onSummaries(), world: world, monitor: monitor,
        previous: .egOne))
    #expect(
      PolishSetupLeaveGuard.resolve(
        .goBack(.egOne), request: asked, monitor: monitor, previousProvider: .egOne,
        currentProvider: world.provider, keyNotSaved: false)
        == .restoreProvider(.egOne, then: .sidebar(.history)))
    // The window's recheck after the setter, from the guarded place in the request's scope.
    world.provider = .egOne
    #expect(
      Self.ask(
        .sidebar(.history), from: PolishSetupScope.meetingSummary.guardedState, world: world,
        monitor: monitor, previous: .egOne) == nil)
    // Had the restored engine stopped being set up, the window would stay.
    world.egOneInstall = .notInstalled
    #expect(
      Self.ask(
        .sidebar(.history), from: PolishSetupScope.meetingSummary.guardedState, world: world,
        monitor: monitor, previous: .egOne) != nil)
  }

  // MARK: - Key not saved yet

  @Test("only the chosen cloud provider's typed, unsaved, non-empty key counts as a draft")
  func unsavedKeyDraft() {
    let model = ProviderSetupModel()
    #expect(model.hasUnsavedKeyDraft(for: .claude) == false)
    model.claudeKey = "sk-ant-typed"
    #expect(model.hasUnsavedKeyDraft(for: .claude))
    // Another provider's field, or a local engine, never counts.
    #expect(model.hasUnsavedKeyDraft(for: .openAI) == false)
    #expect(model.hasUnsavedKeyDraft(for: .egOne) == false)
    #expect(model.hasUnsavedKeyDraft(for: .appleIntelligence) == false)
    // Saved (the field matches what was last saved): not a draft.
    model.claudeKeyPersistedDigest = ProviderSetupModel.digest("sk-ant-typed")
    #expect(model.hasUnsavedKeyDraft(for: .claude) == false)
    // Emptied: not a draft.
    model.claudeKey = ""
    #expect(model.hasUnsavedKeyDraft(for: .claude) == false)
  }

  @Test("'not saved yet' reaches the Summaries question only for a missing summary key")
  func keyNotSavedOnSummaries() throws {
    let world = World()
    let monitor = PolishSetupLeaveGuardTests.monitor(world)
    defer { monitor.stop() }
    let typed = try #require(
      Self.ask(
        .sidebar(.history), from: Self.onSummaries(), world: world, monitor: monitor,
        keyNotSaved: true))
    #expect(typed.keyNotSaved)
    #expect(
      PolishSetupLeaveDialogContent.make(for: typed).message
        == "Your OpenAI key is not saved yet. Until then, EnviousMeet can't write meeting summaries."
    )
  }
}
