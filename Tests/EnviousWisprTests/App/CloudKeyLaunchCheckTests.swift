import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM
import EnviousWisprAppKitTestSupport

/// #4721: the once-per-launch check of the saved cloud keys both AI engines use. When this is
/// wrong, a person is never warned that the key behind their dictation polish or meeting
/// summaries stopped working, is warned about the wrong engine, or is warned while offline.
@MainActor
@Suite("Launch key check runner (#4721)", .tags(.productOutcome))
struct CloudKeyLaunchCheckTests {

  /// Every check the runner asked for, and a scripted answer per provider.
  @MainActor
  final class Script {
    var asked: [(provider: LLMProvider, key: String, models: [String])] = []
    var answers: [LLMProvider: [Result<LLMModelDiscovery.SavedKeyCheck, any Error>]] = [:]
    var lines: [String] = []
    var lineSignal: (count: Int, signal: CredentialTestSignal)?

    func answer(
      _ provider: LLMProvider, key: String, models: [String]
    ) throws -> LLMModelDiscovery.SavedKeyCheck {
      asked.append((provider, key, models))
      guard var queue = answers[provider], !queue.isEmpty else {
        throw LLMModelDiscovery.SavedKeyCheckFailure(
          error: URLError(.notConnectedToInternet), listAnsweredAt: nil)
      }
      let next = queue.removeFirst()
      answers[provider] = queue
      return try next.get()
    }

    func log(_ line: String) {
      lines.append(line)
      if let pending = lineSignal, lines.count >= pending.count { pending.signal.open() }
    }

    /// Opens once `count` log lines exist (one per checked or skipped provider).
    func waitForLines(_ count: Int) async -> Bool {
      if lines.count >= count { return true }
      let signal = CredentialTestSignal()
      lineSignal = (count, signal)
      return await signal.wait(deadlineMs: 5000)
    }
  }

  struct Fixture {
    let settings: SettingsManager
    let presence: SavedKeyPresence
    let keychain: KeychainManager
    let access: CredentialAccessLane
    let discovery: LLMModelDiscoveryCoordinator
    let runner: CloudKeyLaunchCheck
    let script: Script
  }

  static func fixture(keys: [String: String] = [:], onboarded: Bool = true) throws -> Fixture {
    let folder = TestTemporaryDirectory.url
      .appending(path: "ew-tests-launch-key-check-\(UUID().uuidString)")
    let store = FileLegacyKeyStore(storageDirectory: folder)
    for (id, value) in keys { try store.store(key: id, value: value) }
    let keychain = KeychainManager(backend: .legacyFiles, legacyStore: store)
    let presence = SavedKeyPresence()
    let access = CredentialAccessLane()
    let settings = SettingsManager(
      defaults: try #require(TestDefaults.suite("ew.tests.launch-key-check.\(UUID().uuidString)")))
    settings.onboardingState = onboarded ? .completed : .notStarted
    let discovery = LLMModelDiscoveryCoordinator(
      keychainManager: keychain,
      cacheDefaults: try #require(
        TestDefaults.suite("ew.tests.launch-key-check.cache.\(UUID().uuidString)")),
      savedKeyPresence: presence, credentialAccess: access, validationEmitter: { _, _, _, _, _ in },
      discoverModels: { _, _ in [] })
    let script = Script()
    let runner = CloudKeyLaunchCheck(
      settings: settings, savedKeyPresence: presence, keychain: keychain,
      credentialAccess: access, discovery: discovery,
      check: { provider, key, models in try script.answer(provider, key: key, models: models) },
      log: { script.log($0) })
    return Fixture(
      settings: settings, presence: presence, keychain: keychain, access: access,
      discovery: discovery, runner: runner, script: script)
  }

  static func accepted(_ rows: [LLMModelInfo] = []) -> Result<
    LLMModelDiscovery.SavedKeyCheck, any Error
  > {
    .success(LLMModelDiscovery.SavedKeyCheck(listAnsweredAt: .now, chosenModels: rows))
  }

  static let rejected: Result<LLMModelDiscovery.SavedKeyCheck, any Error> = .failure(
    LLMModelDiscovery.SavedKeyCheckFailure(error: LLMError.invalidAPIKey, listAnsweredAt: .now))
  static let offline: Result<LLMModelDiscovery.SavedKeyCheck, any Error> = .failure(
    LLMModelDiscovery.SavedKeyCheckFailure(
      error: URLError(.notConnectedToInternet), listAnsweredAt: nil))

  static func row(_ id: String, _ provider: LLMProvider, _ availability: LLMModelAvailability)
    -> LLMModelInfo
  {
    LLMModelInfo(
      id: id, displayName: id, provider: provider, availability: availability, isRemote: false,
      availabilityObservedAt: .now)
  }

  /// What a setup monitor for `scope` would conclude from the live evidence now, through the
  /// same projection the monitors use (`PolishSetupReadiness.evaluate`).
  static func readiness(_ fx: Fixture, scope: PolishSetupScope) -> PolishSetupReadiness {
    let engine = PolishSetupEngineSelection(settings: fx.settings, scope: scope)
    let facts = PolishSetupFacts(
      egOneInstall: .installed(version: "1"), egOneHealth: .green,
      s1MiniInstall: .installed(version: "1"), s1MiniHealth: .green,
      appleStatus: .available, appleFailureReasons: [], appleIsChecking: false,
      validationProvider: nil, cloudValidation: .idle,
      credentialRevisions: fx.presence.revisions, cloudVerdicts: fx.discovery.cloudVerdicts,
      openAIKeySaved: fx.presence.savedFlag(for: .openAI),
      geminiKeySaved: fx.presence.savedFlag(for: .gemini),
      claudeKeySaved: fx.presence.savedFlag(for: .claude),
      ollamaSetup: .ready, ollamaModel: .installed,
      selectedCloudModel: engine.model, cloudModelEvidence: fx.discovery.cloudModelObservations)
    return PolishSetupReadiness.evaluate(provider: engine.provider, facts: facts)
  }

  // MARK: - Who is checked

  @Test("before setup is finished nothing is checked")
  func notOnboardedChecksNothing() async throws {
    let fx = try Self.fixture(keys: [KeychainManager.claudeKeyID: "c"], onboarded: false)
    fx.settings.llmProvider = .claude
    fx.runner.start()
    await Task.yield()
    #expect(fx.script.asked.isEmpty)
    #expect(fx.script.lines.isEmpty)
  }

  @Test("local engines are never checked")
  func localEnginesNotTargets() throws {
    let fx = try Self.fixture()
    fx.settings.llmProvider = .egOne
    fx.settings.meetingSummaryLLMProvider = .ollama
    #expect(CloudKeyLaunchCheck.targets(settings: fx.settings).isEmpty)
  }

  @Test(
    "dictation on Claude and summaries on Gemini: each provider checked with its own key and model")
  func twoProvidersEachChecked() async throws {
    let fx = try Self.fixture(keys: [
      KeychainManager.claudeKeyID: "claude-k", KeychainManager.geminiKeyID: "gemini-k",
    ])
    fx.settings.llmProvider = .claude
    fx.settings.llmModel = "claude-opus-9"
    fx.settings.meetingSummaryLLMProvider = .gemini
    fx.settings.meetingSummaryLLMModel = "gemini-9-flash"
    fx.script.answers = [.claude: [Self.accepted()], .gemini: [Self.accepted()]]

    fx.runner.start()
    #expect(await fx.script.waitForLines(2))

    #expect(fx.script.asked.map(\.provider) == [.claude, .gemini])
    #expect(fx.script.asked.map(\.key) == ["claude-k", "gemini-k"])
    #expect(
      fx.script.asked.map(\.models) == [
        [fx.settings.effectiveLLMModel], [fx.settings.effectiveMeetingSummaryLLMModel],
      ])
    #expect(fx.discovery.cloudVerdicts[.claude]?.result == .accepted)
    #expect(fx.discovery.cloudVerdicts[.gemini]?.result == .accepted)
    #expect(fx.presence.state(for: .claude) == .present)
  }

  @Test(
    "both engines on Claude: one check, both models; a withdrawn summary model warns only summaries"
  )
  func sharedProviderDistinctModels() async throws {
    let fx = try Self.fixture(keys: [KeychainManager.claudeKeyID: "claude-k"])
    fx.settings.llmProvider = .claude
    fx.settings.llmModel = "claude-opus-9"
    fx.settings.meetingSummaryLLMProvider = .claude
    fx.settings.meetingSummaryLLMModel = "claude-sonnet-9"
    let dictationModel = fx.settings.effectiveLLMModel
    let summaryModel = fx.settings.effectiveMeetingSummaryLLMModel
    try #require(dictationModel != summaryModel)
    fx.script.answers = [
      .claude: [
        Self.accepted([
          Self.row(dictationModel, .claude, .available),
          Self.row(summaryModel, .claude, .confirmedUnavailable),
        ])
      ]
    ]

    fx.runner.start()
    #expect(await fx.script.waitForLines(1))

    #expect(fx.script.asked.count == 1)
    #expect(fx.script.asked.first?.models == [dictationModel, summaryModel])
    #expect(Self.readiness(fx, scope: .dictation) == .noProblem)
    #expect(
      Self.readiness(fx, scope: .meetingSummary)
        == .problem(.cloudModelUnavailable(.claude, summaryModel)))
  }

  @Test("a refused key becomes each engine's key warning")
  func rejectedKeyWarnsBothEngines() async throws {
    let fx = try Self.fixture(keys: [KeychainManager.claudeKeyID: "bad"])
    fx.settings.llmProvider = .claude
    fx.settings.meetingSummaryLLMProvider = .claude
    fx.script.answers = [.claude: [Self.rejected]]

    fx.runner.start()
    #expect(await fx.script.waitForLines(1))

    #expect(fx.discovery.cloudVerdicts[.claude]?.result == .rejected)
    #expect(Self.readiness(fx, scope: .dictation) == .problem(.cloudKeyRejected(.claude)))
    #expect(Self.readiness(fx, scope: .meetingSummary) == .problem(.cloudKeyRejected(.claude)))
    #expect(fx.script.lines == ["provider=claude outcome=rejected retry=false"])
  }

  @Test("no saved key: no request and no warning")
  func missingKeySendsNothing() async throws {
    let fx = try Self.fixture()
    fx.settings.llmProvider = .openAI
    fx.runner.start()
    #expect(await fx.script.waitForLines(1))
    #expect(fx.script.asked.isEmpty)
    #expect(fx.discovery.cloudVerdicts[.openAI] == nil)
    #expect(fx.script.lines == ["provider=openAI outcome=skipped retry=false"])
  }

  // MARK: - Offline and the one retry

  @Test("offline at launch: no warning; one retry on a later return, then none")
  func offlineRetriesOnceOnLaterActivation() async throws {
    let fx = try Self.fixture(keys: [KeychainManager.claudeKeyID: "claude-k"])
    fx.settings.llmProvider = .claude
    fx.script.answers = [.claude: [Self.offline, Self.rejected]]

    fx.runner.start()
    // An activation while the launch run is still going does nothing.
    fx.runner.appBecameActive()
    #expect(await fx.script.waitForLines(1))
    // A check that could not tell, with no earlier answer about this key: unknown, which
    // shows no warning (only a confirmed problem does).
    #expect(Self.readiness(fx, scope: .dictation) == .unknown)

    fx.runner.appBecameActive()
    #expect(await fx.script.waitForLines(2))
    fx.runner.appBecameActive()
    await Task.yield()

    #expect(fx.script.asked.count == 2)
    #expect(
      fx.script.lines == [
        "provider=claude outcome=inconclusive retry=false",
        "provider=claude outcome=rejected retry=true",
      ])
    #expect(Self.readiness(fx, scope: .dictation) == .problem(.cloudKeyRejected(.claude)))
  }

  @Test("a Save since launch cancels the retry before any request")
  func saveSinceLaunchCancelsRetry() async throws {
    let fx = try Self.fixture(keys: [KeychainManager.claudeKeyID: "claude-k"])
    fx.settings.llmProvider = .claude
    fx.script.answers = [.claude: [Self.offline, Self.rejected]]
    fx.runner.start()
    #expect(await fx.script.waitForLines(1))

    let admission = fx.discovery.admitCredentialMutation(
      provider: .claude, settings: fx.settings, surface: .dictation)
    fx.discovery.finishCredentialMutation(admission, cleared: false, settings: fx.settings)
    fx.runner.appBecameActive()
    #expect(await fx.script.waitForLines(2))

    #expect(fx.script.asked.count == 1)
    #expect(fx.script.lines.last == "provider=claude outcome=skipped retry=true")
  }

  @Test("an engine switched away while the retry waits for the key read is not checked")
  func retrySkipsProviderSwitchedAwayDuringLaneWait() async throws {
    let fx = try Self.fixture(keys: [KeychainManager.claudeKeyID: "claude-k"])
    fx.settings.llmProvider = .claude
    fx.script.answers = [.claude: [Self.offline, Self.rejected]]
    fx.runner.start()
    #expect(await fx.script.waitForLines(1))

    // Hold the key-read lane so the retry waits in its queue.
    let queued = CredentialTestSignal()
    fx.access.onQueuedForTesting = { queued.open() }
    let gate = CredentialTestSignal()
    let turn = fx.access.reserve()
    let holder = Task { await fx.access.run(turn: turn) { _ = await gate.wait(deadlineMs: 5000) } }
    fx.runner.appBecameActive()
    try #require(await queued.wait())
    fx.settings.llmProvider = .egOne
    gate.open()
    await holder.value
    #expect(await fx.script.waitForLines(2))

    #expect(fx.script.asked.count == 1, "the retry contacted a provider no engine uses any more")
    #expect(fx.script.lines.last == "provider=claude outcome=skipped retry=true")
  }

  @Test("a model probe that could not tell is not retried")
  func inconclusiveProbeNotRetried() async throws {
    let fx = try Self.fixture(keys: [KeychainManager.claudeKeyID: "claude-k"])
    fx.settings.llmProvider = .claude
    fx.script.answers = [
      .claude: [Self.accepted([Self.row(fx.settings.effectiveLLMModel, .claude, .inconclusive)])]
    ]
    fx.runner.start()
    #expect(await fx.script.waitForLines(1))
    fx.runner.appBecameActive()
    await Task.yield()
    #expect(fx.script.asked.count == 1)
  }
}
