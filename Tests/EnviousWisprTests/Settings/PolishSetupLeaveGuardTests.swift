import EnviousWisprCore
import EnviousWisprLLM
import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit

/// #3438. Leaving AI Polish while the chosen model is not set up asks first, once per problem,
/// and every button is judged against what is true when it is pressed. When this is wrong, a
/// person is let go without being told, is asked again after answering, or an answer about an
/// old problem silences a new one.
@MainActor
@Suite("Leaving AI Polish with an unfinished setup (#3438)", .tags(.productOutcome))
struct PolishSetupLeaveGuardTests {

  // MARK: - Fixture

  @MainActor @Observable
  final class World {
    var onboardingComplete = true { didSet { onTransition?() } }
    var provider: LLMProvider = .openAI { didSet { onTransition?() } }
    var openAIKeySaved: Bool? = false
    var egOneInstall: EGOneInstallState = .installed(version: "1.2")
    @ObservationIgnored var onTransition: (() -> Void)?

    var inputs: PolishSetupInputs {
      PolishSetupInputs(
        onboardingComplete: onboardingComplete,
        configuration: PolishSetupConfiguration(
          provider: provider, model: provider == .none ? "" : "model",
          credentialRevision: provider == .openAI ? 1 : nil),
        facts: PolishSetupFacts(
          egOneInstall: egOneInstall, egOneHealth: .green,
          s1MiniInstall: .installed(version: "1"), s1MiniHealth: .green,
          appleStatus: .available, appleFailureReasons: [], appleIsChecking: false,
          validationProvider: nil, cloudValidation: .idle,
          credentialRevisions: [.openAI: 1], cloudVerdicts: [:],
          openAIKeySaved: openAIKeySaved, geminiKeySaved: true, claudeKeySaved: true,
          ollamaSetup: .ready, ollamaModel: .installed),
        ollamaLastCommitAt: nil)
    }
  }

  private static func monitor(_ world: World) -> PolishSetupMonitor {
    let monitor = PolishSetupMonitor(readInputs: { world.inputs })
    world.onTransition = { [weak monitor] in monitor?.configurationOrEligibilityChanged() }
    monitor.start()
    return monitor
  }

  private static func request(
    _ intent: SettingsNavigationIntent, from page: SettingsPage = .aiPolish,
    world: World, monitor: PolishSetupMonitor, previous: LLMProvider? = nil,
    keyNotSaved: Bool = false
  ) -> PolishSetupLeaveRequest? {
    PolishSetupLeaveGuard.request(
      for: intent, from: page, monitor: monitor, previousProvider: previous,
      currentProvider: world.provider, keyNotSaved: keyNotSaved)
  }

  // MARK: - When it asks

  @Test("only leaving AI Polish for another page asks, and the request keeps its kind")
  func asksOnlyWhenLeaving() throws {
    let world = World()
    let monitor = Self.monitor(world)
    defer { monitor.stop() }
    // Arriving, staying, or moving between other pages never asks.
    #expect(
      Self.request(.sidebar(.aiPolish), from: .history, world: world, monitor: monitor) == nil)
    #expect(Self.request(.destination(.aiPolish), world: world, monitor: monitor) == nil)
    #expect(
      Self.request(.sidebar(.keybinds), from: .history, world: world, monitor: monitor) == nil)

    let sidebar = try #require(Self.request(.sidebar(.dictation), world: world, monitor: monitor))
    #expect(sidebar.intent == .sidebar(.dictation))
    #expect(sidebar.problem == .cloudKeyMissing(.openAI))
    let link = try #require(
      Self.request(.destination(.dictation(.microphone)), world: world, monitor: monitor))
    #expect(link.intent == .destination(.dictation(.microphone)))
  }

  @Test("polish off, onboarding unfinished, or a set-up model: no question")
  func quietWhenNothingToSay() {
    let world = World()
    let monitor = Self.monitor(world)
    defer { monitor.stop() }
    world.onboardingComplete = false
    #expect(Self.request(.sidebar(.history), world: world, monitor: monitor) == nil)
    world.onboardingComplete = true
    world.provider = .none
    #expect(Self.request(.sidebar(.history), world: world, monitor: monitor) == nil)
    world.provider = .openAI
    world.openAIKeySaved = true
    #expect(Self.request(.sidebar(.history), world: world, monitor: monitor) == nil)
    // A key read that failed is unknown, never "missing".
    world.openAIKeySaved = nil
    #expect(Self.request(.sidebar(.history), world: world, monitor: monitor) == nil)
  }

  @Test("Leave anyway answers this problem once; Finish setup is not an answer")
  func answersAreRemembered() throws {
    let world = World()
    let monitor = Self.monitor(world)
    defer { monitor.stop() }
    let first = try #require(Self.request(.sidebar(.history), world: world, monitor: monitor))
    // Finish setup: stay, and the next leave asks again.
    #expect(
      PolishSetupLeaveGuard.resolve(
        .finishSetup, request: first, monitor: monitor, previousProvider: nil,
        currentProvider: world.provider, keyNotSaved: false) == .stay)
    let again = try #require(Self.request(.sidebar(.history), world: world, monitor: monitor))
    // Leave anyway: go, and the same problem does not ask again.
    #expect(
      PolishSetupLeaveGuard.resolve(
        .leaveAnyway, request: again, monitor: monitor, previousProvider: nil,
        currentProvider: world.provider, keyNotSaved: false) == .navigate(.sidebar(.history)))
    #expect(Self.request(.sidebar(.history), world: world, monitor: monitor) == nil)
    // The banner and the card keep their own answers.
    #expect(monitor.shows(.banner))
  }

  @Test("an answer is judged against the state when pressed, never the state when asked")
  func answersAreJudgedLive() throws {
    let world = World()
    world.provider = .egOne
    world.egOneInstall = .notInstalled
    let monitor = Self.monitor(world)
    defer { monitor.stop() }
    let asked = try #require(Self.request(.sidebar(.history), world: world, monitor: monitor))

    // Repaired while the question was open: go, without acknowledging anything.
    world.egOneInstall = .installed(version: "1.2")
    #expect(
      PolishSetupLeaveGuard.resolve(
        .leaveAnyway, request: asked, monitor: monitor, previousProvider: nil,
        currentProvider: world.provider, keyNotSaved: false) == .navigate(.sidebar(.history)))

    // Broken again in another way (a new episode): the old answer does nothing, the person
    // stays, and the new problem is still unanswered.
    world.egOneInstall = .paused
    #expect(
      PolishSetupLeaveGuard.resolve(
        .leaveAnyway, request: asked, monitor: monitor, previousProvider: nil,
        currentProvider: world.provider, keyNotSaved: false) == .stay)
    #expect(monitor.shows(.leaveDialog), "the stale answer acknowledged the new episode")
    let next = try #require(Self.request(.sidebar(.history), world: world, monitor: monitor))
    #expect(next.problem == .localEngineDownloadPaused(.egOne))
    #expect(next.episode != asked.episode)
  }

  @Test("Go back is offered only for a different, fully set-up previous model")
  func goBackOffer() throws {
    let world = World()
    let monitor = Self.monitor(world)
    defer { monitor.stop() }
    let withEGOne = try #require(
      Self.request(.sidebar(.history), world: world, monitor: monitor, previous: .egOne))
    #expect(withEGOne.goBackProvider == .egOne)
    // Same provider, polish off, or a previous model that is not set up: no offer.
    #expect(
      Self.request(.sidebar(.history), world: world, monitor: monitor, previous: .openAI)?
        .goBackProvider == nil)
    #expect(
      Self.request(.sidebar(.history), world: world, monitor: monitor, previous: LLMProvider.none)?
        .goBackProvider == nil)
    world.egOneInstall = .notInstalled
    #expect(
      Self.request(.sidebar(.history), world: world, monitor: monitor, previous: .egOne)?
        .goBackProvider == nil)
  }

  @Test("Go back is validated before anything changes")
  func goBackValidatedFirst() throws {
    let world = World()
    let monitor = Self.monitor(world)
    defer { monitor.stop() }
    let asked = try #require(
      Self.request(.sidebar(.history), world: world, monitor: monitor, previous: .egOne))
    #expect(
      PolishSetupLeaveGuard.resolve(
        .goBack(.egOne), request: asked, monitor: monitor, previousProvider: .egOne,
        currentProvider: world.provider, keyNotSaved: false)
        == .restoreProvider(.egOne, then: .sidebar(.history)))

    // EG-1 stops being set up while the dialog is open: no effect, the provider is untouched.
    world.egOneInstall = .paused
    #expect(
      PolishSetupLeaveGuard.resolve(
        .goBack(.egOne), request: asked, monitor: monitor, previousProvider: .egOne,
        currentProvider: world.provider, keyNotSaved: false) == .stay)
    #expect(world.provider == .openAI)
  }

  @Test("a sidebar return keeps the remembered tab; a link sets its own")
  func intentsKeepTheirTabs() {
    var state = SettingsNavigationState()
    state.perform(.destination(.dictation(.microphone)))
    state.perform(.sidebar(.aiPolish))
    state.perform(.sidebar(.dictation))
    #expect(state.selectedPage == .dictation)
    #expect(state.dictationTab == .microphone)
    state.perform(.destination(.dictation(.chimes)))
    #expect(state.dictationTab == .chimes)
    state.perform(.destination(.appSettings(.privacy)))
    state.perform(.sidebar(.history))
    state.perform(.sidebar(.appSettings))
    #expect(state.appSettingsTab == .privacy)
  }

  @Test("'not saved yet' applies only to a missing cloud key with a typed draft")
  func keyNotSavedOnlyForAMissingKey() throws {
    let world = World()
    let monitor = Self.monitor(world)
    defer { monitor.stop() }
    let typed = try #require(
      Self.request(.sidebar(.history), world: world, monitor: monitor, keyNotSaved: true))
    #expect(typed.keyNotSaved)
    world.provider = .egOne
    world.egOneInstall = .notInstalled
    let local = try #require(
      Self.request(.sidebar(.history), world: world, monitor: monitor, keyNotSaved: true))
    #expect(local.keyNotSaved == false)
  }

  @Test("an informational notice's OK answers it; Escape (closing) does not")
  func informationalOK() throws {
    let world = World()
    world.provider = .egOne
    world.egOneInstall = .downloading(fractionCompleted: 0.3, upgrade: nil)
    let monitor = Self.monitor(world)
    defer { monitor.stop() }
    let asked = try #require(Self.request(.sidebar(.history), world: world, monitor: monitor))
    #expect(asked.problem == .localEngineDownloading(.egOne))
    #expect(
      PolishSetupLeaveGuard.resolve(
        .ok, request: asked, monitor: monitor, previousProvider: nil,
        currentProvider: world.provider, keyNotSaved: false) == .navigate(.sidebar(.history)))
    #expect(Self.request(.sidebar(.history), world: world, monitor: monitor) == nil)
  }
}
