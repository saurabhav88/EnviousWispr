import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import Foundation
import Observation
import Testing

@testable import EnviousWisprAppKit

/// #4353 D4: a cloud provider with no model, or a chosen model that stopped working, is a setup
/// problem with its own card ("Select a new cloud model" opens dictation's model menu). Only
/// the provider's own answer, for the key saved now, says a model stopped working.
@MainActor
@Suite("Cloud model setup warnings (#4353)", .tags(.productOutcome))
struct CloudModelSetupTests {

  private static func facts(
    keySaved: Bool? = true, revision: UInt64 = 1, model: String?,
    evidence: [LLMProvider: [String: CloudModelObservation]] = [:]
  ) -> PolishSetupFacts {
    PolishSetupFacts(
      egOneInstall: .installed(version: "1"), egOneHealth: .green,
      s1MiniInstall: .installed(version: "1"), s1MiniHealth: .green,
      appleStatus: .available, appleFailureReasons: [], appleIsChecking: false,
      validationProvider: nil, cloudValidation: .idle,
      credentialRevisions: [.openAI: revision], cloudVerdicts: [:],
      openAIKeySaved: keySaved, geminiKeySaved: true, claudeKeySaved: true,
      ollamaSetup: .ready, ollamaModel: .installed,
      selectedCloudModel: model, cloudModelEvidence: evidence)
  }

  private static func evidence(
    revision: UInt64 = 1, unavailable: Set<String>, at: ContinuousClock.Instant = .now
  ) -> [LLMProvider: [String: CloudModelObservation]] {
    [.openAI: Dictionary(uniqueKeysWithValues: unavailable.map {
      ($0, CloudModelObservation(credentialRevision: revision, works: false, observedAt: at))
    })]
  }

  private static func readiness(_ facts: PolishSetupFacts) -> PolishSetupReadiness {
    PolishSetupReadiness.evaluate(provider: .openAI, facts: facts)
  }

  // MARK: - Readiness

  @Test("a saved key with no model chosen asks for a model")
  func emptyModel() {
    #expect(Self.readiness(Self.facts(model: "")) == .problem(.cloudNoModel(.openAI)))
  }

  @Test("a missing key comes first, before the model")
  func keyFirst() {
    #expect(
      Self.readiness(Self.facts(keySaved: false, model: ""))
        == .problem(.cloudKeyMissing(.openAI)))
  }

  @Test("live discovery for the saved key confirmed the chosen model unavailable")
  func confirmedUnavailable() {
    let facts = Self.facts(model: "gpt-x", evidence: Self.evidence(unavailable: ["gpt-x"]))
    #expect(Self.readiness(facts) == .problem(.cloudModelUnavailable(.openAI, "gpt-x")))
  }

  @Test("evidence about another key, another model, or no evidence raises nothing")
  func noFalseWarning() {
    #expect(
      Self.readiness(
        Self.facts(
          revision: 2, model: "gpt-x", evidence: Self.evidence(revision: 1, unavailable: ["gpt-x"]))
      )
        == .noProblem)
    #expect(
      Self.readiness(Self.facts(model: "gpt-x", evidence: Self.evidence(unavailable: ["gpt-y"])))
        == .noProblem)
    #expect(Self.readiness(Self.facts(model: "gpt-x")) == .noProblem)
    // A caller that does not judge the model (the import gate, the status chip).
    #expect(Self.readiness(Self.facts(model: nil)) == .noProblem)
  }

  // MARK: - The card

  @Test("the card names what to do and opens the model menu")
  func cardWords() {
    let empty = PolishSetupCardModel(problem: .cloudNoModel(.claude))
    #expect(empty.title == "Choose a model for Claude.")
    #expect(empty.line == "Pasted without AI polish.")
    #expect(empty.primaryLabel == "Select a new cloud model")
    #expect(empty.dismissLabel == "Not now")
    let gone = PolishSetupCardModel(problem: .cloudModelUnavailable(.openAI, "gpt-4o-mini"))
    #expect(gone.title == "gpt-4o-mini no longer works.")
    #expect(gone.primaryLabel == "Select a new cloud model")
    #expect(PolishSetupProblem.cloudNoModel(.openAI).opensModelMenu)
    #expect(PolishSetupProblem.cloudKeyMissing(.openAI).opensModelMenu == false)
  }

  @Test("the short reasons and tags")
  func reasonsAndTags() {
    #expect(PolishSetupSurfaceCopy.shortReason(.cloudNoModel(.gemini)) == "Gemini needs a model")
    #expect(
      PolishSetupSurfaceCopy.shortReason(.cloudModelUnavailable(.gemini, "gemini-x"))
        == "gemini-x no longer works")
    #expect(PolishSetupProblem.cloudNoModel(.gemini).telemetryTag == "cloud_no_model")
    #expect(
      PolishSetupProblem.cloudModelUnavailable(.gemini, "gemini-x").telemetryTag
        == "cloud_model_unavailable")
  }

  // MARK: - What a dictation learned

  @MainActor @Observable
  final class World {
    var configuration = PolishSetupConfiguration(
      provider: .openAI, model: "gpt-x", credentialRevision: 1)
    {
      didSet { onTransition?() }
    }
    var model = "gpt-x"
    var revision: UInt64 = 1
    /// The one owner of model answers, as `LLMModelDiscoveryCoordinator` is in the app.
    var observations: [LLMProvider: [String: CloudModelObservation]] = [:]
    var remembered: [LLMProvider: String] = [:]
    @ObservationIgnored var onTransition: (() -> Void)?
    var inputs: PolishSetupInputs {
      var facts = CloudModelSetupTests.facts(revision: revision, model: model)
      facts.cloudModelEvidence = observations
      return PolishSetupInputs(
        onboardingComplete: true, configuration: configuration, facts: facts,
        ollamaLastCommitAt: nil, rememberedCloudModels: remembered)
    }
    func record(_ provider: LLMProvider, _ model: String, _ observation: CloudModelObservation) {
      observations[provider, default: [:]][model] = CloudModelObservation.merged(
        observations[provider]?[model], with: observation)
    }
  }

  private static func monitor(_ world: World) -> PolishSetupMonitor {
    let monitor = PolishSetupMonitor(
      readInputs: { world.inputs },
      recordCloudModelOutcome: { world.record($0, $1, $2) })
    world.onTransition = { [weak monitor] in monitor?.configurationOrEligibilityChanged() }
    return monitor
  }

  private static func take(_ monitor: PolishSetupMonitor) -> PolishSetupTakeContext {
    let context = monitor.currentContext()
    return PolishSetupTakeContext(
      provider: context.configuration.provider, model: context.configuration.model,
      configurationRevision: context.configurationRevision,
      episode: context.episode?.rawValue)
  }

  @Test("a dictation's 404 raises the warning for that model until a working dictation")
  func takeReportsUnavailable() {
    let world = World()
    let monitor = Self.monitor(world)
    monitor.start()
    defer { monitor.stop() }
    #expect(monitor.eligibleProblem == nil)
    let take = Self.take(monitor)
    #expect(
      monitor.confirmedSetupProblem(.cloudModelUnavailable, for: take) == .cloudModelUnavailable)
    monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-1", context: take, result: .failed, evidence: .cloudModelUnavailable,
        setupProblem: .cloudModelUnavailable, observedAt: .now))
    #expect(monitor.eligibleProblem == .cloudModelUnavailable(.openAI, "gpt-x"))

    let next = Self.take(monitor)
    monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-2", context: next, result: .polished, evidence: nil, setupProblem: nil,
        observedAt: .now))
    #expect(monitor.eligibleProblem == nil)
  }

  @Test("a late failure about an older model never marks the newer choice")
  func lateFailureAfterNewerChoice() {
    let world = World()
    let monitor = Self.monitor(world)
    monitor.start()
    defer { monitor.stop() }
    let old = Self.take(monitor)
    world.configuration = PolishSetupConfiguration(
      provider: .openAI, model: "gpt-new", credentialRevision: 1)
    world.model = "gpt-new"
    _ = monitor.currentContext()
    let taken = monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-old", context: old, result: .failed, evidence: .cloudModelUnavailable,
        setupProblem: .cloudModelUnavailable, observedAt: .now))
    #expect(taken == false)
    #expect(monitor.eligibleProblem == nil)
  }

  @Test("an empty selection is confirmed only for a take that asked for no model")
  func emptySelectionConfirmation() {
    let world = World()
    world.configuration = PolishSetupConfiguration(
      provider: .openAI, model: "", credentialRevision: 1)
    world.model = ""
    let monitor = Self.monitor(world)
    monitor.start()
    defer { monitor.stop() }
    let take = Self.take(monitor)
    #expect(monitor.confirmedSetupProblem(.cloudNoModel, for: take) == .cloudNoModel)
    #expect(monitor.eligibleProblem == .cloudNoModel(.openAI))
    let chosen = PolishSetupTakeContext(
      provider: .openAI, model: "gpt-x", configurationRevision: 1, episode: nil)
    #expect(monitor.confirmedSetupProblem(.cloudNoModel, for: chosen) == nil)
  }

  // MARK: - Whole-diff review round 1

  @Test("#4353 another provider is judged with its own remembered model, not the chosen one's")
  func otherProviderUsesItsRememberedModel() {
    let world = World()
    // Now on Claude with no model; OpenAI remembers a working pick.
    world.configuration = PolishSetupConfiguration(
      provider: .claude, model: "", credentialRevision: 1)
    world.model = ""
    world.remembered = [.openAI: "gpt-x"]
    let monitor = Self.monitor(world)
    #expect(monitor.readiness(for: .openAI) == .noProblem, "Go back to OpenAI must stay offered")
    // Nothing remembered for OpenAI: going back would land on no model.
    world.remembered = [:]
    #expect(monitor.readiness(for: .openAI) == .problem(.cloudNoModel(.openAI)))
    // A remembered pick the provider confirmed gone is judged as gone.
    world.remembered = [.openAI: "gpt-old"]
    world.observations = Self.evidence(unavailable: ["gpt-old"], at: .now - .seconds(5))
    #expect(monitor.readiness(for: .openAI) == .problem(.cloudModelUnavailable(.openAI, "gpt-old")))
  }

  @Test("#4353 a newer key rejection wins over a model warning; a working take restores the model check")
  func keyRejectionBeatsModelWarning() {
    let world = World()
    world.observations = Self.evidence(unavailable: ["gpt-x"], at: .now - .seconds(5))
    let monitor = Self.monitor(world)
    monitor.start()
    defer { monitor.stop() }
    #expect(monitor.eligibleProblem == .cloudModelUnavailable(.openAI, "gpt-x"))
    let take = Self.take(monitor)
    monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-key", context: take, result: .failed, evidence: .cloudKeyRejectedClassified,
        setupProblem: .cloudKeyRejected, observedAt: .now))
    #expect(monitor.eligibleProblem == .cloudKeyRejected(.openAI), "the key comes before the model")
    #expect(monitor.readiness(for: .openAI) == .problem(.cloudKeyRejected(.openAI)))

    // An empty choice is hidden behind a rejected key the same way.
    world.configuration = PolishSetupConfiguration(
      provider: .openAI, model: "", credentialRevision: 1)
    world.model = ""
    #expect(monitor.readiness(for: .openAI) == .problem(.cloudKeyRejected(.openAI)))
  }

  // MARK: - One newest answer per model and key (chunk 3 repair, findings 1 to 3)

  @Test("a failure under an old key says nothing about a new key")
  func newKeyDropsOldFailure() {
    let world = World()
    let monitor = Self.monitor(world)
    monitor.start()
    defer { monitor.stop() }
    let take = Self.take(monitor)
    monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-1", context: take, result: .failed, evidence: .cloudModelUnavailable,
        setupProblem: .cloudModelUnavailable, observedAt: .now))
    #expect(monitor.eligibleProblem == .cloudModelUnavailable(.openAI, "gpt-x"))
    world.revision = 2
    world.configuration = PolishSetupConfiguration(
      provider: .openAI, model: "gpt-x", credentialRevision: 2)
    _ = monitor.currentContext()
    #expect(monitor.eligibleProblem == nil)
  }

  @Test("newest definitive answer wins in both directions; an older one arriving late does not")
  func newestDefinitiveWins() {
    let t0 = ContinuousClock.now
    var map: [LLMProvider: [String: CloudModelObservation]] = [:]
    func record(works: Bool, _ ms: Int) {
      map[.openAI, default: [:]]["gpt-x"] = CloudModelObservation.merged(
        map[.openAI]?["gpt-x"],
        with: CloudModelObservation(
          credentialRevision: 1, works: works, observedAt: t0 + .milliseconds(ms)))
    }
    func readiness() -> PolishSetupReadiness {
      Self.readiness(Self.facts(model: "gpt-x", evidence: map))
    }
    record(works: false, 10)
    #expect(readiness() == .problem(.cloudModelUnavailable(.openAI, "gpt-x")))
    record(works: true, 20)
    #expect(readiness() == .noProblem)
    record(works: false, 15)
    #expect(readiness() == .noProblem, "an older failure arriving late won")
    record(works: false, 30)
    #expect(readiness() == .problem(.cloudModelUnavailable(.openAI, "gpt-x")))
  }

  @Test("a working dictation clears a warning that came from discovery")
  func successClearsDiscoveryWarning() {
    let world = World()
    world.observations = Self.evidence(unavailable: ["gpt-x"], at: .now - .seconds(5))
    let monitor = Self.monitor(world)
    monitor.start()
    defer { monitor.stop() }
    #expect(monitor.eligibleProblem == .cloudModelUnavailable(.openAI, "gpt-x"))
    let take = Self.take(monitor)
    monitor.ingest(
      PolishTakeOutcome(
        takeID: "take-ok", context: take, result: .polished, evidence: nil, setupProblem: nil,
        observedAt: .now))
    #expect(monitor.eligibleProblem == nil)
  }

  // MARK: - Opening the model menu

  @Test("a card opens the model menu only for its own surface, a cloud provider, models loaded")
  func menuRequestDecision() {
    let request = ModelMenuRequest(surface: .dictation)
    #expect(
      ModelMenuRequest.toOpen(
        pending: request, surface: .dictation, providerIsCloud: true, modelsLoaded: true)
        == request)
    #expect(
      ModelMenuRequest.toOpen(
        pending: request, surface: .fileImport, providerIsCloud: true, modelsLoaded: true) == nil)
    #expect(
      ModelMenuRequest.toOpen(
        pending: request, surface: .dictation, providerIsCloud: false, modelsLoaded: true) == nil)
    // Not loaded yet: left pending (not consumed), and acted on once the models arrive.
    #expect(
      ModelMenuRequest.toOpen(
        pending: request, surface: .dictation, providerIsCloud: true, modelsLoaded: false) == nil)
    #expect(
      ModelMenuRequest.toOpen(
        pending: nil, surface: .dictation, providerIsCloud: true, modelsLoaded: true) == nil)
  }

  @Test("a control asked to be revealed is kept until the window takes it")
  func revealRequest() {
    let navigation = NavigationCoordinator()
    navigation.requestReveal(.polishModel)
    #expect(navigation.pendingReveal == .polishModel)
    navigation.consumeReveal()
    #expect(navigation.pendingReveal == nil)
  }

  @Test("each ask is its own, consumed only by the request it names")
  func modelMenuRequests() throws {
    let navigation = NavigationCoordinator()
    navigation.requestModelMenu(on: .dictation)
    let first = try #require(navigation.pendingModelMenu)
    #expect(first.surface == .dictation)
    navigation.requestModelMenu(on: .dictation)
    let second = try #require(navigation.pendingModelMenu)
    #expect(second != first)
    navigation.consumeModelMenu(first)
    #expect(navigation.pendingModelMenu == second, "a stale consume must not drop a newer ask")
    navigation.consumeModelMenu(second)
    #expect(navigation.pendingModelMenu == nil)
  }
}

// MARK: - Transcribe a File's one document notice (#4353 D9)

@MainActor
@Suite("Transcribe a File cloud setup notice (#4353)", .tags(.productOutcome))
struct FileImportCloudSetupNoticeTests {
  private func part(_ id: Int, _ setup: CloudPolishSetupOutcome?) -> FileImportCoordinator.Part {
    FileImportCoordinator.Part(id: id, text: "words \(id)", isUnpolished: false, cloudSetup: setup)
  }

  @Test("one notice per document: a gone model first, then no model, else none")
  func aggregation() {
    let gone = CloudPolishSetupOutcome.modelUnavailable(provider: .openAI, model: "gpt-x")
    let none = CloudPolishSetupOutcome.noModelChosen(provider: .openAI)
    #expect(FileImportCoordinator.cloudSetupNotice(for: [part(0, nil), part(1, nil)]) == nil)
    #expect(FileImportCoordinator.cloudSetupNotice(for: [part(0, none), part(1, none)]) == none)
    #expect(
      FileImportCoordinator.cloudSetupNotice(for: [part(0, none), part(1, gone), part(2, nil)])
        == gone)
  }

  @Test("the notice names the provider or the model the run used")
  func sentence() {
    #expect(
      TranscribeFileView.cloudSetupSentence(.noModelChosen(provider: .claude))
        == "Choose a model for Claude.")
    #expect(
      TranscribeFileView.cloudSetupSentence(.modelUnavailable(provider: .openAI, model: "gpt-x"))
        == "gpt-x no longer works. Select a new cloud model.")
  }
}
