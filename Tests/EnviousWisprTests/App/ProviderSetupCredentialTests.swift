import EnviousWisprCore
import EnviousWisprServices
import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM
import EnviousWisprAppKitTestSupport

/// #3765: the AI Polish screen's API key Save and Clear, pressed through the same actions the
/// buttons call (`ProviderSetupKeyActions`), with the screen state on a real
/// `ProviderSetupModel` and the credential owners over a temporary key folder.
///
/// When this fails, the user sees a key field that does not empty after Clear, a missing-key
/// notice after a successful Save, a failure with no message, or a key check that never runs.
@MainActor
@Suite(.tags(.productOutcome))
struct ProviderSetupKeyActionTests {
  private struct FailingStorage: LegacyKeyFileStorage {
    func store(key: String, value: String) throws { throw KeyStoreError.storeFailed(-25308) }
    func retrieve(key: String) throws -> String { throw KeyStoreError.retrieveFailed(-25300) }
    func delete(key: String) throws { throw KeyStoreError.deleteFailed(-25308) }
  }

  @MainActor
  final class Asked {
    var providers: [LLMProvider] = []
  }

  private static func owners(failing: Bool = false, asked: Asked = Asked())
    -> ProviderSetupKeyActions.Owners
  {
    let folder = TestTemporaryDirectory.url
      .appending(path: "ew-tests-key-actions-\(UUID().uuidString)")
    let storage: any LegacyKeyFileStorage =
      failing ? FailingStorage() : FileLegacyKeyStore(storageDirectory: folder)
    let keychain = KeychainManager(backend: .legacyFiles, legacyStore: storage)
    let presence = SavedKeyPresence()
    let discovery = LLMModelDiscoveryCoordinator(
      keychainManager: keychain,
      cacheDefaults: TestDefaults.suite("ew.tests.key-actions.cache.\(UUID().uuidString)")!,
      savedKeyPresence: presence,
      discoverModels: { provider, _ in
        asked.providers.append(provider)
        return [LLMModelInfo(
          id: "m", displayName: "m", provider: provider, isAvailable: true, isRemote: true)]
      })
    return ProviderSetupKeyActions.Owners(
      keychainManager: keychain, presence: presence, discovery: discovery,
      settings: SettingsManager(
        defaults: TestDefaults.suite("ew.tests.key-actions.\(UUID().uuidString)")!),
      surface: .dictation)
  }

  private static let providers: [LLMProvider] = [.openAI, .gemini, .claude]

  private static func draft(_ model: ProviderSetupModel, _ provider: LLMProvider) -> String {
    switch provider {
    case .openAI: return model.openAIKey
    case .gemini: return model.geminiKey
    default: return model.claudeKey
    }
  }

  private static func setDraft(_ model: ProviderSetupModel, _ provider: LLMProvider, _ text: String) {
    switch provider {
    case .openAI: model.openAIKey = text
    case .gemini: model.geminiKey = text
    default: model.claudeKey = text
    }
  }

  private static func saved(_ model: ProviderSetupModel, _ provider: LLMProvider) -> Bool? {
    switch provider {
    case .openAI: return model.openAIKeySaved
    case .gemini: return model.geminiKeySaved
    default: return model.claudeKeySaved
    }
  }

  private static func edited(_ model: ProviderSetupModel, _ provider: LLMProvider) -> Bool {
    switch provider {
    case .openAI: return model.openAIKeyEdited
    case .gemini: return model.geminiKeyEdited
    default: return model.claudeKeyEdited
    }
  }

  @Test("Save success: Saved!, the key counts as saved and unedited, and its check runs")
  func saveSuccess() async throws {
    for provider in Self.providers {
      let asked = Asked()
      let owners = Self.owners(asked: asked)
      let model = ProviderSetupModel()
      Self.setDraft(model, provider, "synthetic-\(UUID().uuidString)")
      let check = ProviderSetupKeyActions.save(
        Self.draft(model, provider), provider: provider, model: model, owners: owners)
      #expect(model.keyStoreStatus == .saved, "\(provider)")
      #expect(Self.saved(model, provider) == true, "\(provider)")
      #expect(Self.edited(model, provider) == false, "\(provider): the field now matches the store")
      #expect(owners.presence.state(for: provider) == .present)
      await try #require(check, "\(provider): no key check started").value
      #expect(asked.providers == [provider])
      #expect(try owners.keychainManager.retrieve(key: Self.keyID(provider)) == Self.draft(model, provider))
    }
  }

  @Test("Save failure: the failure sentence, the draft and saved flag kept, the key unknown")
  func saveFailure() throws {
    for provider in Self.providers {
      let asked = Asked()
      let owners = Self.owners(failing: true, asked: asked)
      let model = ProviderSetupModel()
      Self.setDraft(model, provider, "synthetic")
      let check = ProviderSetupKeyActions.save(
        "synthetic", provider: provider, model: model, owners: owners)
      #expect(check == nil)
      guard case .failed(let sentence) = model.keyStoreStatus else {
        Issue.record("\(provider): \(model.keyStoreStatus)")
        continue
      }
      #expect(sentence == AIPolishKeychainFailureMessage.text(
        for: KeyStoreError.storeFailed(-25308), action: .save))
      #expect(Self.draft(model, provider) == "synthetic")
      #expect(Self.saved(model, provider) == nil)
      #expect(Self.edited(model, provider) == true, "\(provider): still not saved")
      #expect(owners.presence.state(for: provider) == .unknown)
      #expect(asked.providers.isEmpty)
    }
  }

  @Test("Clear success: the field empties, the key counts as absent, discovery resets")
  func clearSuccess() async throws {
    for provider in Self.providers {
      let owners = Self.owners()
      let model = ProviderSetupModel()
      Self.setDraft(model, provider, "synthetic")
      await try #require(ProviderSetupKeyActions.save(
        "synthetic", provider: provider, model: model, owners: owners)).value
      model.keyStoreStatus = .failed("an older failure")
      let cleared = ProviderSetupKeyActions.clear(provider: provider, model: model, owners: owners)
      #expect(cleared, "\(provider): the view hides the key again")
      #expect(model.keyStoreStatus == .none)
      #expect(Self.draft(model, provider) == "")
      #expect(Self.saved(model, provider) == false)
      #expect(Self.edited(model, provider) == false)
      #expect(owners.presence.state(for: provider) == .absent)
      #expect(owners.discovery.stateProvider == nil)
    }
  }

  @Test("Clear failure: the failure sentence, the field and saved flag kept, the key unknown")
  func clearFailure() throws {
    for provider in Self.providers {
      let owners = Self.owners(failing: true)
      let model = ProviderSetupModel()
      Self.setDraft(model, provider, "synthetic")
      model.setKeySaved(true, for: provider)
      let cleared = ProviderSetupKeyActions.clear(provider: provider, model: model, owners: owners)
      #expect(cleared == false, "\(provider): the reveal state stays")
      guard case .failed(let sentence) = model.keyStoreStatus else {
        Issue.record("\(provider): \(model.keyStoreStatus)")
        continue
      }
      #expect(sentence == AIPolishKeychainFailureMessage.text(
        for: KeyStoreError.deleteFailed(-25308), action: .clear))
      #expect(Self.draft(model, provider) == "synthetic")
      #expect(Self.saved(model, provider) == true)
      #expect(owners.presence.state(for: provider) == .unknown)
    }
  }

  @Test("a provider with no key row does nothing")
  func noKeyRowProviders() {
    let owners = Self.owners()
    let model = ProviderSetupModel()
    for provider in LLMProvider.allCases where !Self.providers.contains(provider) {
      #expect(ProviderSetupKeyActions.save("x", provider: provider, model: model, owners: owners) == nil)
      #expect(ProviderSetupKeyActions.clear(provider: provider, model: model, owners: owners) == false)
    }
    #expect(model.keyStoreStatus == .none)
  }

  private static func keyID(_ provider: LLMProvider) -> String {
    switch provider {
    case .openAI: return KeychainManager.openAIKeyID
    case .gemini: return KeychainManager.geminiKeyID
    default: return KeychainManager.claudeKeyID
    }
  }
}

/// #3765: the AI Polish screen's Saved badge, which stays on the screen after the credential
/// effects moved into `CredentialWriter`.
///
/// When this fails, the user sees "Saved!" wipe out a later failure message, or a "Saved!"
/// that never goes away.
@MainActor
@Suite(.tags(.productOutcome))
struct ProviderSetupSavedBadgeTests {
  /// A wait the test opens by hand, standing in for the two seconds.
  @MainActor
  final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
      if opened { return }
      await withCheckedContinuation { continuation = $0 }
    }
    func open() {
      opened = true
      continuation?.resume()
      continuation = nil
    }
  }

  @Test("Saved! clears itself when nothing else happened")
  func savedClears() async {
    let model = ProviderSetupModel()
    let gate = Gate()
    let clearing = model.showSavedBadge(wait: { await gate.wait() })
    #expect(model.keyStoreStatus == .saved)
    gate.open()
    await clearing.value
    #expect(model.keyStoreStatus == .none)
  }

  @Test("a failure inside the two seconds survives the earlier Saved!'s clearing")
  func laterFailureSurvives() async {
    let model = ProviderSetupModel()
    let gate = Gate()
    let clearing = model.showSavedBadge(wait: { await gate.wait() })
    model.keyStoreStatus = .failed("The key could not be cleared.")
    gate.open()
    await clearing.value
    #expect(model.keyStoreStatus == .failed("The key could not be cleared."))
  }
}

/// #3765: one owner for the credential effects of Save and Clear.
///
/// Drift Guard: the easy regression is a screen (or a new door) calling the key store,
/// `SavedKeyPresence`'s mutations or `apiKeyChanged` itself again, so two copies drift; the
/// first copy to get a fix leaves the other emitting or recording differently. Parsed with
/// SwiftParser, so comments and strings never count as calls.
@Suite(.tags(.driftGuard))
struct ProviderSetupCredentialOwnershipTests {
  /// Every call in `Sources/` whose callee is a member named one of `names`, as
  /// (file name, callee name). Declarations do not count.
  private static func calls(named names: Set<String>) throws -> [(String, String)] {
    let root = RepoRoot.sourceURL("Sources")
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    else { return [] }
    var found: [(String, String)] = []
    for case let url as URL in walker where url.pathExtension == "swift" {
      let prepared = try CachedSwiftParser.snapshot(at: url)
      let visitor = CallVisitor(names: names)
      visitor.walk(prepared.tree)
      found += visitor.hits.map { (url.lastPathComponent, $0) }
    }
    return found
  }

  private final class CallVisitor: SyntaxVisitor {
    let names: Set<String>
    var hits: [String] = []
    init(names: Set<String>) {
      self.names = names
      super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
      if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
        let name = member.declName.baseName.text
        // `store`/`delete` count only with the key-store label, so unrelated stores
        // (defaults, spools) never match.
        let labels = node.arguments.map { $0.label?.text ?? "_" }
        let keyed = (name == "store" || name == "delete") ? labels.first == "key" : true
        if names.contains(name), keyed { hits.append(name) }
      }
      return .visitChildren
    }
  }

  @Test("the scan can see its subjects")
  func scanSeesSubjects() throws {
    let found = try Self.calls(named: ["apiKeyChanged", "recordSaved", "store"])
    #expect(found.contains { $0.0 == "CredentialWriter.swift" && $0.1 == "apiKeyChanged" })
    #expect(found.contains { $0.0 == "KeychainManager.swift" && $0.1 == "store" })
  }

  @Test("only the credential writer emits api_key.changed and records saves and clears")
  func oneOwnerForCredentialEffects() throws {
    let found = try Self.calls(
      named: ["apiKeyChanged", "recordSaved", "recordCleared", "recordUncertain"])
    let files = Set(found.map(\.0))
    #expect(files == ["CredentialWriter.swift"], "callers: \(found)")
  }

  @Test("only the credential writer stores or deletes an API key through KeychainManager")
  func oneOwnerForKeyWrites() throws {
    let found = try Self.calls(named: ["store", "delete"])
    // KeychainManager's own implementation forwards to its storage backends.
    let outside = found.filter { $0.0 != "KeychainManager.swift" }
    #expect(Set(outside.map(\.0)) == ["CredentialWriter.swift"], "callers: \(outside)")
  }
}
