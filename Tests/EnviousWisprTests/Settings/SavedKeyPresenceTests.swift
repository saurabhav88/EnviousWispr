import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

/// #3438. Which cloud keys are saved, for the surfaces that warn about an unfinished setup,
/// and the typed key verdict tied to the key it was earned on. When this is wrong, a person
/// with a working key is told it is missing or rejected, or a person whose key was rejected
/// is told nothing.
@MainActor
@Suite("Saved key presence and the typed key verdict (#3438)", .tags(.productOutcome))
struct SavedKeyPresenceTests {

  // MARK: - Fixtures

  /// A key store in its own temporary folder; never the real Keychain or key files.
  private static func fixtureKeychain() -> KeychainManager {
    let folder = FileManager.default.temporaryDirectory
      .appending(path: "ew-tests-saved-key-presence-\(UUID().uuidString)")
    return KeychainManager(
      backend: .legacyFiles, legacyStore: FileLegacyKeyStore(storageDirectory: folder))
  }

  private static func settings() -> SettingsManager {
    SettingsManager(
      defaults: TestDefaults.suite("ew.tests.saved-key-presence.\(UUID().uuidString)")!)
  }

  private static func cacheDefaults() -> UserDefaults {
    TestDefaults.suite("ew.tests.saved-key-presence.cache.\(UUID().uuidString)")!
  }

  /// A one-shot signal. `wait` returns true when it was opened, false when the deadline passed
  /// first, so a signal that never comes fails the test instead of hanging it. Opening and the
  /// waiter's registration happen under one lock, so an open before the wait is not lost.
  private final class Signal: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool, Never>?
    /// The first result wins: opened (true) or timed out (false). Remembered, so a wait that
    /// starts after either still gets it.
    private var resolution: Bool?
    private let lock = NSLock()

    func open() { finish(true) }

    func wait(deadlineMs: Int = 2000) async -> Bool {
      let timer = Task {
        // deadline-fallback: fail if the signal never arrives.
        do {
          try await Task.sleep(for: .milliseconds(deadlineMs))
        } catch {
          return
        }
        self.finish(false)
      }
      defer { timer.cancel() }
      return await withCheckedContinuation { c in
        lock.lock()
        if let resolution {
          lock.unlock()
          c.resume(returning: resolution)
        } else {
          continuation = c
          lock.unlock()
        }
      }
    }

    private func finish(_ value: Bool) {
      lock.lock()
      guard resolution == nil else {
        lock.unlock()
        return
      }
      resolution = value
      let c = continuation
      continuation = nil
      lock.unlock()
      c?.resume(returning: value)
    }
  }

  private static func row(_ id: String, provider: LLMProvider) -> LLMModelInfo {
    LLMModelInfo(id: id, displayName: id, provider: provider, isAvailable: true, isRemote: true)
  }

  // MARK: - Presence

  @Test("every cloud provider starts unknown, never absent")
  func startsUnknown() {
    let presence = SavedKeyPresence()
    for provider in SavedKeyPresence.cloudProviders {
      #expect(presence.state(for: provider) == .unknown)
      #expect(presence.savedFlag(for: provider) == nil)
      #expect(presence.revision(for: provider) == 0)
    }
  }

  @Test("save and clear move the credential revision; a read and a failed write say what they know")
  func mutationsAndRevisions() {
    let presence = SavedKeyPresence()
    presence.recordRead(.present, for: .claude)
    #expect(presence.state(for: .claude) == .present)
    #expect(presence.revision(for: .claude) == 0)

    presence.recordSaved(.claude)
    #expect(presence.state(for: .claude) == .present)
    #expect(presence.revision(for: .claude) == 1)

    presence.recordCleared(.claude)
    #expect(presence.state(for: .claude) == .absent)
    #expect(presence.revision(for: .claude) == 2)

    presence.recordUncertain(.claude)
    #expect(presence.state(for: .claude) == .unknown)
    #expect(presence.revision(for: .claude) == 3)

    // Another provider is untouched.
    #expect(presence.revision(for: .openAI) == 0)
    #expect(presence.state(for: .openAI) == .unknown)
    // Key-less providers are never recorded.
    presence.recordSaved(.ollama)
    #expect(presence.revision(for: .ollama) == nil)
  }

  @Test("a stored key is present, no key is absent, an empty key is absent")
  func classification() throws {
    let keychain = Self.fixtureKeychain()
    #expect(SavedKeyState.read(.gemini, keychain: keychain) == .absent)
    try keychain.store(key: KeychainManager.geminiKeyID, value: "test-not-a-real-key")
    #expect(SavedKeyState.read(.gemini, keychain: keychain) == .present)
    try keychain.store(key: KeychainManager.openAIKeyID, value: "")
    #expect(SavedKeyState.read(.openAI, keychain: keychain) == .absent)
    #expect(SavedKeyState.read(.ollama, keychain: keychain) == .absent)
  }

  @Test("the signal gives up at its deadline when nothing opens it")
  func signalDeadlineControl() async {
    let start = ContinuousClock.now
    let opened = await Signal().wait(deadlineMs: 50)
    #expect(opened == false)
    #expect(ContinuousClock.now - start < .seconds(2))
  }

  // MARK: - The typed verdict

  private func check(
    _ provider: LLMProvider, presence: SavedKeyPresence, keychain: KeychainManager,
    answer: @escaping @MainActor (LLMProvider, String) async throws -> [LLMModelInfo]
  ) async -> LLMModelDiscoveryCoordinator {
    let discovery = LLMModelDiscoveryCoordinator(
      keychainManager: keychain, cacheDefaults: Self.cacheDefaults(),
      savedKeyPresence: presence, discoverModels: answer)
    await discovery.validateKeyAndDiscoverModels(provider: provider, settings: Self.settings())
    return discovery
  }

  @Test("a key the provider accepts, refuses, or could not be asked about")
  func verdictPerOutcome() async throws {
    let keychain = Self.fixtureKeychain()
    try keychain.store(key: KeychainManager.openAIKeyID, value: "test-not-a-real-key")
    let presence = SavedKeyPresence()
    presence.recordSaved(.openAI)

    let accepted = await check(.openAI, presence: presence, keychain: keychain) { p, _ in
      [Self.row("gpt-test", provider: p)]
    }
    #expect(
      accepted.cloudVerdict
        == PolishCloudVerdict(provider: .openAI, credentialRevision: 1, result: .accepted))

    let rejected = await check(.openAI, presence: presence, keychain: keychain) { _, _ in
      throw LLMError.invalidAPIKey
    }
    #expect(
      rejected.cloudVerdict
        == PolishCloudVerdict(provider: .openAI, credentialRevision: 1, result: .rejected))

    // No network: the legacy verdict reads invalid, but nothing says the key was refused.
    let offline = await check(.openAI, presence: presence, keychain: keychain) { _, _ in
      throw URLError(.notConnectedToInternet)
    }
    #expect(
      offline.cloudVerdict
        == PolishCloudVerdict(provider: .openAI, credentialRevision: 1, result: .inconclusive))
    if case .invalid = offline.keyValidationState {
    } else {
      Issue.record("legacy verdict changed: \(offline.keyValidationState)")
    }
  }

  @Test("a Gemini permission failure still reads as an invalid key but is not a rejection")
  func geminiPermissionIsNotARejection() async throws {
    let keychain = Self.fixtureKeychain()
    try keychain.store(key: KeychainManager.geminiKeyID, value: "test-not-a-real-key")
    let presence = SavedKeyPresence()
    presence.recordSaved(.gemini)
    let discovery = await check(.gemini, presence: presence, keychain: keychain) { _, _ in
      throw ModelDiscoveryFailure.permissionDenied
    }
    #expect(
      discovery.keyValidationState == .invalid(LLMModelDiscoveryCoordinator.invalidKeyMessage))
    #expect(discovery.cloudVerdict?.result == .inconclusive)
  }

  @Test("Gemini: only Google's structured API_KEY_INVALID reason is a refused key")
  func geminiProducerClassification() {
    // Google's error envelope for an invalid key (AIP-193 ErrorInfo in `details`).
    let invalidKeyEnvelope = """
      {"error": {"code": 400, "message": "API key not valid. Please pass a valid API key.",
      "status": "INVALID_ARGUMENT", "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo",
      "reason": "API_KEY_INVALID", "domain": "googleapis.com", "metadata": {"service": "generativelanguage.googleapis.com"}}]}}
      """
    #expect(
      LLMModelDiscovery.geminiFailure(statusCode: 400, body: invalidKeyEnvelope) as? LLMError
        == .invalidAPIKey)
    // The token only in message text: still shown as an invalid key, not proof of one.
    let textOnly = #"{"error": {"code": 400, "message": "reason API_KEY_INVALID", "status": "INVALID_ARGUMENT"}}"#
    #expect(
      LLMModelDiscovery.geminiFailure(statusCode: 400, body: textOnly) as? ModelDiscoveryFailure
        == .invalidKeyUnconfirmed)
    // Not JSON at all.
    #expect(
      LLMModelDiscovery.geminiFailure(statusCode: 400, body: "API_KEY_INVALID <html>")
        as? ModelDiscoveryFailure == .invalidKeyUnconfirmed)
    #expect(
      LLMModelDiscovery.geminiFailure(statusCode: 400, body: "bad request") as? ModelDiscoveryFailure
        == .httpStatus(400))
    // A permission failure, whatever its body says.
    #expect(
      LLMModelDiscovery.geminiFailure(statusCode: 403, body: invalidKeyEnvelope)
        as? ModelDiscoveryFailure == .permissionDenied)
    #expect(LLMModelDiscovery.geminiFailure(statusCode: 200, body: "") == nil)
  }

  @Test("an unconfirmed Gemini key error still reads invalid but is not a rejection")
  func geminiUnconfirmedIsNotARejection() async throws {
    let keychain = Self.fixtureKeychain()
    try keychain.store(key: KeychainManager.geminiKeyID, value: "test-not-a-real-key")
    let presence = SavedKeyPresence()
    presence.recordSaved(.gemini)
    let discovery = await check(.gemini, presence: presence, keychain: keychain) { _, _ in
      throw ModelDiscoveryFailure.invalidKeyUnconfirmed
    }
    #expect(
      discovery.keyValidationState == .invalid(LLMModelDiscoveryCoordinator.invalidKeyMessage))
    #expect(discovery.cloudVerdict?.result == .inconclusive)
  }

  @Test("no saved key is a presence fact, never a rejection")
  func missingKeyIsNotARejection() async {
    let presence = SavedKeyPresence()
    presence.recordCleared(.gemini)
    let discovery = await check(.gemini, presence: presence, keychain: Self.fixtureKeychain()) {
      _, _ in
      Issue.record("no key, so the provider must not be asked")
      return []
    }
    #expect(discovery.cloudVerdict == nil)
    #expect(discovery.keyValidationState == .invalid(LLMModelDiscoveryCoordinator.noKeyMessage))
  }

  @Test("a key replaced while its check runs publishes nothing about the old key")
  func replacedDuringCheckPublishesNothing() async throws {
    let keychain = Self.fixtureKeychain()
    try keychain.store(key: KeychainManager.claudeKeyID, value: "test-old-key")
    let presence = SavedKeyPresence()
    presence.recordSaved(.claude)
    let entered = Signal()
    let release = Signal()
    let discovery = LLMModelDiscoveryCoordinator(
      keychainManager: keychain, cacheDefaults: Self.cacheDefaults(),
      savedKeyPresence: presence,
      discoverModels: { _, _ in
        entered.open()
        // If the test fails before releasing, the deadline still lets this return.
        #expect(await release.wait(), "the test never released the provider")
        throw LLMError.invalidAPIKey
      })
    let settings = Self.settings()
    let check = Task { @MainActor in
      await discovery.validateKeyAndDiscoverModels(provider: .claude, settings: settings)
    }
    defer { release.open() }
    #expect(await entered.wait(), "the check never reached the provider")
    #expect(discovery.cloudVerdict?.result == .checking)
    // The person saves a new key while the old one is still being checked.
    presence.recordSaved(.claude)
    release.open()
    await check.value
    #expect(discovery.cloudVerdict == nil, "a verdict about the replaced key was published")
    #expect(discovery.keyValidationState == .idle)
    #expect(discovery.isDiscoveringModels == false)
  }

  @Test("reset and a provider change drop the typed verdict")
  func resetDropsTheVerdict() async throws {
    let keychain = Self.fixtureKeychain()
    try keychain.store(key: KeychainManager.openAIKeyID, value: "test-not-a-real-key")
    let presence = SavedKeyPresence()
    presence.recordSaved(.openAI)
    let discovery = await check(.openAI, presence: presence, keychain: keychain) { _, _ in
      throw LLMError.invalidAPIKey
    }
    #expect(discovery.cloudVerdict?.result == .rejected)
    discovery.loadCachedModels(for: .gemini, settings: Self.settings(), surface: .dictation)
    #expect(discovery.cloudVerdict == nil)

    let again = await check(.openAI, presence: presence, keychain: keychain) { _, _ in
      throw LLMError.invalidAPIKey
    }
    again.reset()
    #expect(again.cloudVerdict == nil)
  }

  @Test("the readiness answer follows the verdict only for the key saved now")
  func readinessFollowsTheCurrentKey() async throws {
    let keychain = Self.fixtureKeychain()
    try keychain.store(key: KeychainManager.openAIKeyID, value: "test-not-a-real-key")
    let presence = SavedKeyPresence()
    presence.recordSaved(.openAI)
    let discovery = await check(.openAI, presence: presence, keychain: keychain) { _, _ in
      throw LLMError.invalidAPIKey
    }
    func readiness() -> PolishSetupReadiness {
      PolishSetupReadiness.evaluate(
        provider: .openAI,
        facts: PolishSetupFacts(
          egOneInstall: .installed(version: "1"), egOneHealth: .green,
          s1MiniInstall: .installed(version: "1"), s1MiniHealth: .green,
          appleStatus: .available, appleFailureReasons: [], appleIsChecking: false,
          validationProvider: discovery.stateProvider,
          cloudValidation: discovery.keyValidationState,
          credentialRevisions: presence.revisions, cloudVerdict: discovery.cloudVerdict,
          openAIKeySaved: presence.savedFlag(for: .openAI), geminiKeySaved: true,
          claudeKeySaved: true, ollamaSetup: .ready, ollamaModel: .installed))
    }
    #expect(readiness() == .problem(.cloudKeyRejected(.openAI)))
    // A new key is saved: the rejection was about the old one.
    presence.recordSaved(.openAI)
    #expect(readiness() == .noProblem)
  }
}
