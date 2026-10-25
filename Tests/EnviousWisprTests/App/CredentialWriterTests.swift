import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM
import EnviousWisprAppKitTestSupport

/// #3765: storing and clearing one provider's API key, the path the AI Polish screen's Save
/// and Clear buttons and the dev control door both take.
///
/// When this fails, the user sees a saved key the app does not count as saved, a key check
/// that never starts after Save, or a verdict about an old key that survives a Clear or a
/// failed store.
@MainActor
@Suite(.tags(.productOutcome))
struct CredentialWriterTests {
  /// A key store in its own temporary folder; never the real Keychain or key files.
  private static func fixtureKeychain(storage: (any LegacyKeyFileStorage)? = nil)
    -> KeychainManager
  {
    let folder = TestTemporaryDirectory.url
      .appending(path: "ew-tests-credential-writer-\(UUID().uuidString)")
    return KeychainManager(
      backend: .legacyFiles, legacyStore: storage ?? FileLegacyKeyStore(storageDirectory: folder))
  }

  /// A store whose every write fails, as a locked or unwritable store does.
  private struct FailingStorage: LegacyKeyFileStorage {
    func store(key: String, value: String) throws { throw KeyStoreError.storeFailed(-25308) }
    func retrieve(key: String) throws -> String { throw KeyStoreError.retrieveFailed(-25300) }
    func delete(key: String) throws { throw KeyStoreError.deleteFailed(-25308) }
  }

  /// Records the key checks discovery was asked to run.
  @MainActor
  final class DiscoveryLog {
    var asked: [LLMProvider] = []
  }

  private struct Fixture {
    let writer: CredentialWriter
    let keychain: KeychainManager
    let presence: SavedKeyPresence
    let discovery: LLMModelDiscoveryCoordinator
    let log: DiscoveryLog
    let settings: SettingsManager
  }

  private static func fixture(
    storage: (any LegacyKeyFileStorage)? = nil,
    events: @escaping CredentialWriter.Emit = { _, _, _ in }
  ) -> Fixture {
    let keychain = Self.fixtureKeychain(storage: storage)
    let presence = SavedKeyPresence()
    let log = DiscoveryLog()
    let discovery = LLMModelDiscoveryCoordinator(
      keychainManager: keychain,
      cacheDefaults: TestDefaults.suite("ew.tests.credential-writer.cache.\(UUID().uuidString)")!,
      savedKeyPresence: presence,
      discoverModels: { provider, _ in
        log.asked.append(provider)
        return [
          LLMModelInfo(
            id: "model-\(provider.rawValue)", displayName: "m", provider: provider,
            isAvailable: true, isRemote: true)
        ]
      })
    let settings = SettingsManager(
      defaults: TestDefaults.suite("ew.tests.credential-writer.\(UUID().uuidString)")!)
    var writer = CredentialWriter(
      keychainManager: keychain, presence: presence, discovery: discovery)
    writer.emit = events
    return Fixture(
      writer: writer, keychain: keychain, presence: presence, discovery: discovery, log: log,
      settings: settings)
  }

  @Test("the providers are exactly the three cloud providers, each with its fixed key id")
  func providerDomain() {
    #expect(CredentialProvider.allCases.map(\.llmProvider) == SavedKeyPresence.cloudProviders)
    #expect(
      CredentialProvider.allCases.map(\.keyID) == [
        KeychainManager.openAIKeyID, KeychainManager.geminiKeyID, KeychainManager.claudeKeyID,
      ])
    for provider in LLMProvider.allCases {
      #expect(
        (CredentialProvider(provider) != nil) == SavedKeyPresence.cloudProviders.contains(provider),
        "\(provider)")
    }
  }

  @Test("save stores the key, counts it as a new key, then starts that provider's key check")
  func saveStoresRecordsAndChecks() async throws {
    for provider in CredentialProvider.allCases {
      let fx = Self.fixture()
      let before = try #require(fx.presence.revision(for: provider.llmProvider))
      let value = "synthetic-\(UUID().uuidString)"
      guard
        case .stored(let validation) = fx.writer.save(
          value, for: provider, settings: fx.settings, surface: .dictation)
      else {
        Issue.record("\(provider): save failed")
        continue
      }
      // Recorded before the check runs, so the check's verdict is about THIS key.
      #expect(fx.presence.state(for: provider.llmProvider) == .present)
      #expect(fx.presence.revision(for: provider.llmProvider) == before + 1)
      #expect(try fx.keychain.retrieve(key: provider.keyID) == value)
      await validation.value
      #expect(fx.log.asked == [provider.llmProvider], "\(provider)")
      #expect(fx.discovery.stateProvider == provider.llmProvider)
      #expect(fx.discovery.cloudVerdict?.credentialRevision == before + 1)
    }
  }

  @Test("clear deletes the key, counts it as absent, and resets discovery")
  func clearDeletesRecordsAndResets() async throws {
    for provider in CredentialProvider.allCases {
      let fx = Self.fixture()
      guard
        case .stored(let validation) = fx.writer.save(
          "synthetic", for: provider, settings: fx.settings, surface: .dictation)
      else {
        Issue.record("\(provider): save failed")
        continue
      }
      await validation.value
      let before = try #require(fx.presence.revision(for: provider.llmProvider))
      guard case .cleared = fx.writer.clear(provider) else {
        Issue.record("\(provider): clear failed")
        continue
      }
      #expect(fx.presence.state(for: provider.llmProvider) == .absent)
      #expect(fx.presence.revision(for: provider.llmProvider) == before + 1)
      #expect(fx.discovery.stateProvider == nil, "\(provider): discovery reset")
      #expect(throws: (any Error).self) { try fx.keychain.retrieve(key: provider.keyID) }
    }
  }

  @Test("a failed save or clear makes the key unknown, drops old verdicts and starts nothing")
  func failuresAreUncertain() async throws {
    for provider in CredentialProvider.allCases {
      let fx = Self.fixture(storage: FailingStorage())
      fx.presence.recordRead(.present, for: provider.llmProvider)
      let before = try #require(fx.presence.revision(for: provider.llmProvider))
      guard
        case .failed = fx.writer.save(
          "synthetic", for: provider, settings: fx.settings, surface: .dictation)
      else {
        Issue.record("\(provider): a failing store reported success")
        continue
      }
      #expect(fx.presence.state(for: provider.llmProvider) == .unknown)
      #expect(fx.presence.revision(for: provider.llmProvider) == before + 1)
      guard case .failed = fx.writer.clear(provider) else {
        Issue.record("\(provider): a failing delete reported success")
        continue
      }
      #expect(fx.presence.state(for: provider.llmProvider) == .unknown)
      #expect(fx.presence.revision(for: provider.llmProvider) == before + 2)
      #expect(fx.log.asked.isEmpty, "\(provider): no key check after a failed store")
    }
  }
}

/// #3765: the `api_key.changed` event the Save and Clear paths emit (#1173).
///
/// Observability Contract: when this fails, the API-key dashboard miscounts saves and clears
/// or groups them under the wrong provider. No user sees it.
@MainActor
@Suite(.tags(.observabilityContract))
struct CredentialWriterTelemetryTests {
  @MainActor
  final class Events {
    var seen: [[String]] = []
  }

  @Test("one event per attempt: provider, save or remove, success or failure, never the key")
  func oneEventPerAttempt() async throws {
    struct FailingStorage: LegacyKeyFileStorage {
      func store(key: String, value: String) throws { throw KeyStoreError.storeFailed(-1) }
      func retrieve(key: String) throws -> String { throw KeyStoreError.retrieveFailed(-25300) }
      func delete(key: String) throws { throw KeyStoreError.deleteFailed(-1) }
    }
    for failing in [false, true] {
      for provider in CredentialProvider.allCases {
        let events = Events()
        let folder = TestTemporaryDirectory.url
          .appending(path: "ew-tests-credential-events-\(UUID().uuidString)")
        let storage: any LegacyKeyFileStorage =
          failing ? FailingStorage() : FileLegacyKeyStore(storageDirectory: folder)
        let keychain = KeychainManager(backend: .legacyFiles, legacyStore: storage)
        let presence = SavedKeyPresence()
        let discovery = LLMModelDiscoveryCoordinator(
          keychainManager: keychain,
          cacheDefaults: TestDefaults.suite("ew.tests.credential-events.\(UUID().uuidString)")!,
          savedKeyPresence: presence, discoverModels: { _, _ in [] })
        var writer = CredentialWriter(
          keychainManager: keychain, presence: presence, discovery: discovery)
        writer.emit = { events.seen.append([$0, $1, $2]) }
        let settings = SettingsManager(
          defaults: TestDefaults.suite("ew.tests.credential-events.s.\(UUID().uuidString)")!)
        let secret = "synthetic-\(UUID().uuidString)"
        if case .stored(let validation) = writer.save(
          secret, for: provider, settings: settings, surface: .dictation)
        {
          await validation.value
        }
        _ = writer.clear(provider)
        let result = failing ? "failure" : "success"
        #expect(
          events.seen == [
            [provider.llmProvider.rawValue, "save", result],
            [provider.llmProvider.rawValue, "remove", result],
          ], "\(provider) failing=\(failing)")
        #expect(events.seen.joined().contains(secret) == false)
      }
    }
  }
}
