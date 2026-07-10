import EnviousWisprCore
import Foundation
import Security
import Testing

@testable import EnviousWisprLLM

/// #1446: `getAPIKey` used to throw `.apiKeyMissing` from BOTH of its exits — the
/// `guard` that fires when no key was ever configured (the user's own setup) and
/// the `catch` that fires when a stored key could not be read (a Keychain
/// migration, entitlement, or corruption bug of OURS). One reason, one Sentry
/// fingerprint, so a real regression was indistinguishable from a fresh install.
///
/// The exhaustive `switch` in `telemetryChannel` proves every reason CHOOSES a
/// channel; it can never prove that a thrown error is CLASSIFIED as the right
/// reason. Only these tests can, which is why they exist: if the catch arm ever
/// reverts to `.apiKeyMissing`, a Keychain regression silently stops paging us
/// and nothing else in the suite notices.
///
/// Both exits are reached with no network: `getAPIKey` is the first statement of
/// `polish`, so the throw happens before any request is built.
@Suite("Connector API-key classification")
struct ConnectorAPIKeyTests {

  /// Stands in for a key that was never saved. Reports absence the way the real
  /// stores do, with `errSecItemNotFound`.
  private struct EmptyKeyStore: LegacyKeyFileStorage {
    func store(key: String, value: String) throws {}
    func retrieve(key: String) throws -> String {
      throw KeyStoreError.retrieveFailed(errSecItemNotFound)
    }
    func delete(key: String) throws {}
  }

  /// Stands in for a key that IS stored but cannot be read back: a corrupt entry,
  /// a locked Keychain, a missing entitlement. `-1` is what both real stores report
  /// for "the item is there but its bytes would not come back."
  private struct UnreadableKeyStore: LegacyKeyFileStorage {
    func store(key: String, value: String) throws { throw KeyStoreError.storeFailed(-1) }
    func retrieve(key: String) throws -> String { throw KeyStoreError.retrieveFailed(-1) }
    func delete(key: String) throws {}
  }

  /// The `.legacyFiles` backend is the DEBUG/dev one (`KeychainManager` fails closed
  /// away from the production Keychain), so these never touch the founder's real keys.
  private func emptyKeychain() -> KeychainManager {
    KeychainManager(backend: .legacyFiles, legacyStore: EmptyKeyStore())
  }

  private func unreadableKeychain() -> KeychainManager {
    KeychainManager(backend: .legacyFiles, legacyStore: UnreadableKeyStore())
  }

  private func config(keychainId: String?) -> LLMProviderConfig {
    LLMProviderConfig(
      model: "test-model", apiKeyKeychainId: keychainId, maxTokens: 64,
      temperature: 0, thinkingBudget: nil, reasoningEffort: nil)
  }

  // MARK: - No key was ever saved: the user's setup, not a defect

  /// THE production shape, and the one that matters. `LLMPolishStep` hands the
  /// connector a fixed key id for every cloud provider (`KeychainManager.openAIKeyID`
  /// / `.geminiKeyID`), whether or not a key was ever saved — so a fresh install with
  /// cloud polish selected reaches the `catch`, never the `nil` guard. Classifying
  /// that as `.apiKeyUnreadable` would page us for every no-key user and defeat the
  /// entire downgrade. Absence must be read from the STORE, not from the id.
  @Test(
    "OpenAI with a key id but nothing stored -> apiKeyMissing (never apiKeyUnreadable)",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "the no-key path reaches the catch arm, not the nil guard")
  )
  func openAIKeyIdButNothingStored() async {
    let connector = OpenAIConnector(keychainManager: emptyKeychain())
    await #expect(throws: LLMError.classified(.apiKeyMissing)) {
      _ = try await connector.polish(
        text: "hello there", instructions: .default,
        config: config(keychainId: KeychainManager.openAIKeyID), onToken: nil)
    }
  }

  @Test(
    "Gemini with a key id but nothing stored -> apiKeyMissing (never apiKeyUnreadable)",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "the no-key path reaches the catch arm, not the nil guard")
  )
  func geminiKeyIdButNothingStored() async {
    let connector = GeminiConnector(keychainManager: emptyKeychain())
    await #expect(throws: LLMError.classified(.apiKeyMissing)) {
      _ = try await connector.polish(
        text: "hello there", instructions: .default,
        config: config(keychainId: KeychainManager.geminiKeyID), onToken: nil)
    }
  }

  /// The `nil` guard is unreachable in production (see above) but must stay correct
  /// for any future caller that omits the id.
  @Test("OpenAI with no configured key id -> apiKeyMissing")
  func openAINoKeyConfigured() async {
    let connector = OpenAIConnector(keychainManager: unreadableKeychain())
    await #expect(throws: LLMError.classified(.apiKeyMissing)) {
      _ = try await connector.polish(
        text: "hello there", instructions: .default, config: config(keychainId: nil),
        onToken: nil)
    }
  }

  @Test("Gemini with no configured key id -> apiKeyMissing")
  func geminiNoKeyConfigured() async {
    let connector = GeminiConnector(keychainManager: unreadableKeychain())
    await #expect(throws: LLMError.classified(.apiKeyMissing)) {
      _ = try await connector.polish(
        text: "hello there", instructions: .default, config: config(keychainId: nil),
        onToken: nil)
    }
  }

  // MARK: - A key IS configured but cannot be read: our defect, its own fingerprint

  @Test(
    "OpenAI with a stored-but-unreadable key -> apiKeyUnreadable, not apiKeyMissing",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "a Keychain-read defect hid behind a user-configuration state")
  )
  func openAIStoredKeyUnreadable() async {
    let connector = OpenAIConnector(keychainManager: unreadableKeychain())
    await #expect(throws: LLMError.classified(.apiKeyUnreadable)) {
      _ = try await connector.polish(
        text: "hello there", instructions: .default,
        config: config(keychainId: KeychainManager.openAIKeyID), onToken: nil)
    }
  }

  @Test(
    "Gemini with a stored-but-unreadable key -> apiKeyUnreadable, not apiKeyMissing",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1446",
      "a Keychain-read defect hid behind a user-configuration state")
  )
  func geminiStoredKeyUnreadable() async {
    let connector = GeminiConnector(keychainManager: unreadableKeychain())
    await #expect(throws: LLMError.classified(.apiKeyUnreadable)) {
      _ = try await connector.polish(
        text: "hello there", instructions: .default,
        config: config(keychainId: KeychainManager.geminiKeyID), onToken: nil)
    }
  }

  // MARK: - Adversarial: the two exits must not collapse back into one

  @Test("the two key failures are distinguishable to us and identical to the user")
  func exitsStayDistinct() async throws {
    // Same connector, same config, same key id — only the STORE's answer differs.
    // That is the whole distinction, so the test isolates exactly it.
    let cfg = config(keychainId: KeychainManager.openAIKeyID)

    var missing: PolishFailureReason?
    do {
      _ = try await OpenAIConnector(keychainManager: emptyKeychain())
        .polish(text: "hello there", instructions: .default, config: cfg, onToken: nil)
    } catch let error as LLMError {
      missing = PolishFailureReason.from(error)
    }
    var unreadable: PolishFailureReason?
    do {
      _ = try await OpenAIConnector(keychainManager: unreadableKeychain())
        .polish(text: "hello there", instructions: .default, config: cfg, onToken: nil)
    } catch let error as LLMError {
      unreadable = PolishFailureReason.from(error)
    }

    let missingReason = try #require(missing)
    let unreadableReason = try #require(unreadable)
    #expect(missingReason != unreadableReason)
    // Different fingerprint, different channel...
    #expect(missingReason.telemetryTag != unreadableReason.telemetryTag)
    #expect(missingReason.telemetryChannel(provider: .openAI) == .nonAlertingAnalytics)
    #expect(unreadableReason.telemetryChannel(provider: .openAI) == .alertingSentryError)
    // ...but the same sentence on screen, because re-entering the key fixes both.
    #expect(
      missingReason.composedMessage(provider: .openAI)
        == unreadableReason.composedMessage(provider: .openAI))
  }
}
