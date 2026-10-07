import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #3482 PR B: choosing a Settings search result goes through the one navigation owner, lands on
/// the right page and tab, and publishes where to arrive. **When this fails, the user picks a
/// result and lands on the wrong page, on the wrong Dictionary tab, loses their unfinished AI
/// Polish setup without being asked, or arrives at a control that is not on screen.**
/// Expectations are literal (plan §18.2), not read back from the Settings Map they test.
@MainActor
@Suite("Settings search navigation (#3482)", .tags(.productOutcome))
struct SettingsSearchNavigationTests {

  private static func request(_ entryID: String) throws -> SettingsSearchRequest {
    try #require(SettingsSearchRequest(entryID: entryID), "\(entryID) is not a requestable entry")
  }

  // MARK: - Resolving a chosen entry

  private struct Row {
    let entryID: String
    let destination: SettingsDestination
    let dictionaryTab: DictionaryTab?
    let target: SettingsMapID
    let fallbacks: [SettingsMapID]
  }

  /// Written out from plan §18.2 and the §5 conditional-target audit, never derived from the map.
  private static let rows: [Row] = [
    Row(
      entryID: "inputDevice", destination: .dictation(.microphone), dictionaryTab: nil,
      target: .inputDevice, fallbacks: []),
    Row(
      entryID: "pauseDuration", destination: .dictation(.engine), dictionaryTab: nil,
      target: .pauseDuration, fallbacks: [.stopOnSilence]),
    Row(
      entryID: "apiKey.openAI", destination: .aiPolish, dictionaryTab: nil,
      target: .apiKeyOpenAI, fallbacks: [.aiPolishProvider, .enableAIPolish]),
    Row(
      entryID: "inputSocket", destination: .dictation(.microphone), dictionaryTab: nil,
      target: .inputSocket, fallbacks: [.inputDevice]),
    Row(
      entryID: "enableDictionary", destination: .dictionary, dictionaryTab: nil,
      target: .enableDictionary, fallbacks: []),
    Row(
      entryID: "selfLearningDictionary", destination: .dictionary, dictionaryTab: .learnFrom,
      target: .selfLearningDictionary, fallbacks: []),
    Row(
      entryID: "theme", destination: .appSettings(.appearance), dictionaryTab: nil,
      target: .theme, fallbacks: []),
  ]

  @Test("a chosen entry carries its page, tab and arrival targets from the map")
  func requestsResolveToLiteralDestinations() throws {
    for row in Self.rows {
      let request = try Self.request(row.entryID)
      #expect(request.entryID == row.entryID)
      #expect(request.destination == row.destination, "\(row.entryID): \(request.destination)")
      #expect(request.dictionaryTab == row.dictionaryTab, "\(row.entryID)")
      #expect(request.target == row.target, "\(row.entryID): \(request.target)")
      #expect(request.fallbacks == row.fallbacks, "\(row.entryID): \(request.fallbacks)")
    }
  }

  @Test("an id that is not a searchable place cannot be requested")
  func unsearchableIDsAreRefused() {
    for id in ["window.settings", "page.aiPolish", "section.microphone", "no.such.id", ""] {
      #expect(SettingsSearchRequest(entryID: id) == nil, "\(id) produced a request")
    }
  }

  @Test("every searchable entry can be requested and its targets exist")
  func everyEntryIsRequestable() {
    var unrequestable: [String] = []
    var missingTargets: [String] = []
    for entry in SettingsSearchCatalog.entries {
      guard let request = SettingsSearchRequest(entryID: entry.id) else {
        unrequestable.append(entry.id)
        continue
      }
      for target in [request.target] + request.fallbacks where SettingsMap.byID[target] == nil {
        missingTargets.append("\(entry.id) -> \(target.rawValue)")
      }
    }
    #expect(SettingsSearchCatalog.entries.isEmpty == false)
    #expect(unrequestable.isEmpty, "entries with no destination or target: \(unrequestable)")
    #expect(missingTargets.isEmpty, "targets with no map node: \(missingTargets)")
  }

  // MARK: - §18.2 entry + state -> arrival target

  /// What is on screen is the state: the anchors the page has mounted. Primary when mounted,
  /// else the first mounted declared fallback.
  @Test(
    "the arrival is the primary control when it is on screen, else the declared fallback",
    arguments: [
      // inputDevice, defaults
      ("inputDevice", Set<SettingsMapID>([.inputDevice]), SettingsMapID?.some(.inputDevice)),
      // pauseDuration, auto-stop on / off
      ("pauseDuration", [.pauseDuration, .stopOnSilence], .pauseDuration),
      ("pauseDuration", [.stopOnSilence], .stopOnSilence),
      // OpenAI key: provider OpenAI / provider Ollama / AI Polish Off
      ("apiKey.openAI", [.apiKeyOpenAI, .aiPolishProvider, .enableAIPolish], .apiKeyOpenAI),
      ("apiKey.openAI", [.aiPolishProvider, .enableAIPolish], .aiPolishProvider),
      ("apiKey.openAI", [.enableAIPolish], .enableAIPolish),
      // input socket, single-input device
      ("inputSocket", [.inputDevice], .inputDevice),
      // dictionary enable heading and the learning switch, defaults
      ("enableDictionary", [.enableDictionary], .enableDictionary),
      ("selfLearningDictionary", [.selfLearningDictionary], .selfLearningDictionary),
      ("theme", [.theme], .theme),
      // nothing mounted, primary or fallback: no arrival (an implementation failure upstream)
      ("pauseDuration", [], nil),
    ] as [(String, Set<SettingsMapID>, SettingsMapID?)])
  func arrivalTarget(entryID: String, mounted: Set<SettingsMapID>, expected: SettingsMapID?) throws
  {
    var state = SettingsNavigationState()
    state.perform(.search(try Self.request(entryID)))
    let reveal = try #require(state.reveal)
    #expect(reveal.arrival(mounted: mounted) == expected, "\(entryID) with \(mounted)")
  }

  // MARK: - The reducer

  @Test("a search commit goes to the page and tab and publishes one reveal")
  func searchCommitPublishesAReveal() throws {
    var state = SettingsNavigationState()
    state.perform(.search(try Self.request("theme")))
    #expect(state.selectedPage == .appSettings)
    #expect(state.appSettingsTab == .appearance)
    #expect(
      state.reveal
        == SettingsReveal(entryID: "theme", anchor: .theme, fallbacks: [], token: 1))

    state.perform(.search(try Self.request("inputDevice")))
    #expect(state.selectedPage == .dictation)
    #expect(state.dictationTab == .microphone)
    #expect(
      state.reveal
        == SettingsReveal(entryID: "inputDevice", anchor: .inputDevice, fallbacks: [], token: 2))
  }

  @Test("choosing the same result again reveals again")
  func sameResultTwiceRevealsTwice() throws {
    var state = SettingsNavigationState()
    let theme = try Self.request("theme")
    state.perform(.search(theme))
    let first = try #require(state.reveal)
    state.perform(.search(theme))
    let second = try #require(state.reveal)
    #expect(first.entryID == second.entryID && first.anchor == second.anchor)
    #expect(second.token == first.token + 1)
    #expect(second != first)
  }

  @Test("entries that share a control keep their own identity")
  func sharedAnchorKeepsTheChosenEntry() throws {
    // Both are choices on the one input device row.
    #expect(SettingsMap.node(.inputDeviceAuto).target == .inputDevice)
    #expect(SettingsMap.node(.inputDeviceDevice).target == .inputDevice)
    var state = SettingsNavigationState()
    state.perform(.search(try Self.request("inputDevice.auto")))
    #expect(state.reveal?.entryID == "inputDevice.auto")
    #expect(state.reveal?.anchor == .inputDevice)
    state.perform(.search(try Self.request("inputDevice.device")))
    #expect(state.reveal?.entryID == "inputDevice.device")
    #expect(state.reveal?.anchor == .inputDevice)
  }

  @Test("a sidebar click or a link ends a pending reveal, and tokens never repeat")
  func ordinaryNavigationClearsTheReveal() throws {
    var state = SettingsNavigationState()
    state.perform(.search(try Self.request("theme")))
    #expect(state.reveal?.token == 1)
    state.perform(.sidebar(.history))
    #expect(state.reveal == nil)
    state.perform(.search(try Self.request("theme")))
    #expect(state.reveal?.token == 2)
    state.perform(.destination(.keybinds))
    #expect(state.reveal == nil)
    state.apply(.dictation(.chimes))
    #expect(state.reveal == nil)
    state.perform(.search(try Self.request("theme")))
    #expect(state.reveal?.token == 3)
  }

  @Test("the reveal reaches pages through the environment, and a bare page sees none")
  func environmentDefaultIsNoReveal() {
    #expect(EnvironmentValues().settingsReveal == nil)
    var values = EnvironmentValues()
    let reveal = SettingsReveal(entryID: "theme", anchor: .theme, fallbacks: [], token: 1)
    values.settingsReveal = reveal
    #expect(values.settingsReveal == reveal)
  }

  // MARK: - Dictionary tab lifted into the navigation state

  @Test("a fresh window shows Your Words, and a Dictionary result opens its tab")
  func dictionaryTabIsWindowState() throws {
    var state = SettingsNavigationState()
    #expect(state.dictionaryTab == .yourWords)

    state.perform(.search(try Self.request("selfLearningDictionary")))
    #expect(state.selectedPage == .dictionary)
    #expect(state.dictionaryTab == .learnFrom)
    // The other pages' remembered tabs are untouched.
    #expect(state.dictationTab == .engine)
    #expect(state.appSettingsTab == .appearance)

    // Coming back from the sidebar keeps the tab; a link with no tab does not reset it.
    state.perform(.sidebar(.history))
    state.perform(.sidebar(.dictionary))
    #expect(state.dictionaryTab == .learnFrom)
    state.perform(.destination(.dictionary))
    #expect(state.dictionaryTab == .learnFrom)

    // An entry with no Dictionary tab (the fixed Enable Dictionary heading) keeps it as well.
    state.perform(.search(try Self.request("enableDictionary")))
    #expect(state.dictionaryTab == .learnFrom)
  }

  @Test("the Dictionary page shows the tab it is bound to")
  func dictionaryPageFollowsItsBinding() async throws {
    let (home, words) = try SettingsMapRenderingTests.dictionaryHome()
    var onQuickAdd: [SettingsMapID] = []
    for tab in [DictionaryTab.quickAdd, .yourWords] {
      let list = try await SettingsMapRenderingTests.registrations(
        AnyView(
          YourWordsView(selection: .constant(tab)).environment(home.settings).environment(words)))
      // The rail registers all four tab rows whatever is selected; the content below it is the
      // bound tab's, and only it.
      let rail = Set(DictionaryTab.allCases.map(\.mapID))
      let ids = SettingsMapRenderingTests.mapped(list).filter { rail.contains($0) == false }
      let tabs = Set(ids.compactMap { SettingsMap.node($0).dictionaryTab })
      if tab == .quickAdd { onQuickAdd = ids }
      #expect(tabs.isSubset(of: [tab]), "\(tab) rendered \(tabs)")
    }
    #expect(
      onQuickAdd.contains { SettingsMap.node($0).dictionaryTab == .quickAdd },
      "the quick add tab rendered none of its own controls")
  }
}

// MARK: - Through the AI Polish leave guard

/// §18.2's last row: a search result chosen while AI Polish setup is unfinished asks first.
@MainActor
@Suite("Settings search through the AI Polish leave guard (#3482)", .tags(.productOutcome))
struct SettingsSearchLeaveGuardTests {
  typealias World = PolishSetupLeaveGuardTests.World

  private static func ask(
    _ intent: SettingsNavigationIntent, state: SettingsNavigationState, world: World,
    monitor: PolishSetupMonitor
  ) -> PolishSetupLeaveRequest? {
    PolishSetupLeaveGuard.request(
      for: intent, from: state.selectedPage, monitor: monitor, previousProvider: nil,
      currentProvider: world.provider, keyNotSaved: false)
  }

  private static func answer(
    _ action: PolishSetupLeaveAction, _ request: PolishSetupLeaveRequest, world: World,
    monitor: PolishSetupMonitor
  ) -> PolishSetupLeaveGuard.Outcome {
    PolishSetupLeaveGuard.resolve(
      action, request: request, monitor: monitor, previousProvider: nil,
      currentProvider: world.provider, keyNotSaved: false)
  }

  @Test("Stay keeps AI Polish and publishes nothing; Leave anyway arrives at the Theme row")
  func theme_fromUnfinishedAIPolish() throws {
    let world = World()
    let monitor = PolishSetupLeaveGuardTests.monitor(world)
    defer { monitor.stop() }
    var state = SettingsNavigationState()
    state.perform(.destination(.aiPolish))
    let theme = try #require(SettingsSearchRequest(entryID: "theme"))
    let intent = SettingsNavigationIntent.search(theme)

    let asked = try #require(Self.ask(intent, state: state, world: world, monitor: monitor))
    #expect(asked.intent == intent, "the question lost the chosen entry")
    #expect(asked.problem == .cloudKeyMissing(.openAI))

    // Stay: nothing navigates, nothing is revealed.
    #expect(Self.answer(.finishSetup, asked, world: world, monitor: monitor) == .stay)
    #expect(state.selectedPage == .aiPolish)
    #expect(state.reveal == nil)

    // Choose again and leave: the whole request comes back and arrives at the Theme row.
    let again = try #require(Self.ask(intent, state: state, world: world, monitor: monitor))
    let outcome = Self.answer(.leaveAnyway, again, world: world, monitor: monitor)
    #expect(outcome == .navigate(intent))
    guard case .navigate(let go) = outcome else { return }
    state.perform(go)
    #expect(state.selectedPage == .appSettings)
    #expect(state.appSettingsTab == .appearance)
    #expect(state.reveal?.entryID == "theme")
    #expect(state.reveal?.anchor == .theme)
  }

  @Test("the latest request replaces the pending one and keeps the whole request")
  func latestRequestWins() throws {
    let world = World()
    let monitor = PolishSetupLeaveGuardTests.monitor(world)
    defer { monitor.stop() }
    let state = SettingsNavigationState(selectedPage: .aiPolish)
    var pending = try #require(
      Self.ask(.sidebar(.history), state: state, world: world, monitor: monitor))
    let latest = SettingsNavigationIntent.search(
      try #require(SettingsSearchRequest(entryID: "selfLearningDictionary")))
    // What `UnifiedWindowView.navigate` does while a question is open.
    pending.intent = latest
    #expect(Self.answer(.leaveAnyway, pending, world: world, monitor: monitor) == .navigate(latest))
  }

  @Test("a result on the AI Polish page itself never asks")
  func resultOnTheSamePageDoesNotAsk() throws {
    let world = World()
    let monitor = PolishSetupLeaveGuardTests.monitor(world)
    defer { monitor.stop() }
    let state = SettingsNavigationState(selectedPage: .aiPolish)
    let key = SettingsNavigationIntent.search(
      try #require(SettingsSearchRequest(entryID: "apiKey.openAI")))
    #expect(key.page == .aiPolish)
    #expect(Self.ask(key, state: state, world: world, monitor: monitor) == nil)
    // Arriving at AI Polish from another page never asks either.
    let history = SettingsNavigationState(selectedPage: .history)
    #expect(Self.ask(key, state: history, world: world, monitor: monitor) == nil)
  }
}
