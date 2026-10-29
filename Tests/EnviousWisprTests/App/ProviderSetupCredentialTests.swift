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

  private static func owners(
    failing: Bool = false, asked: Asked = Asked(), storageOverride: (any LegacyKeyFileStorage)? = nil,
    surface: ProviderSetupSurface = .dictation
  )
    -> ProviderSetupKeyActions.Owners
  {
    let folder = TestTemporaryDirectory.url
      .appending(path: "ew-tests-key-actions-\(UUID().uuidString)")
    let storage: any LegacyKeyFileStorage =
      storageOverride ?? (failing ? FailingStorage() : FileLegacyKeyStore(storageDirectory: folder))
    let keychain = KeychainManager(backend: .legacyFiles, legacyStore: storage)
    let presence = SavedKeyPresence()
    let access = CredentialAccessLane()
    let discovery = LLMModelDiscoveryCoordinator(
      keychainManager: keychain,
      cacheDefaults: TestDefaults.suite("ew.tests.key-actions.cache.\(UUID().uuidString)")!,
      savedKeyPresence: presence, credentialAccess: access,
      validationEmitter: { _, _, _, _, _ in },
      discoverModels: { provider, _ in
        asked.providers.append(provider)
        return [LLMModelInfo(
          id: "m", displayName: "m", provider: provider, isAvailable: true, isRemote: true)]
      })
    return ProviderSetupKeyActions.Owners(
      keychainManager: keychain, presence: presence, discovery: discovery,
      settings: SettingsManager(
        defaults: TestDefaults.suite("ew.tests.key-actions.\(UUID().uuidString)")!),
      surface: surface, emit: { _, _, _ in }, access: access)
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
      try await #require(check, "\(provider): no save operation started").value
      #expect(model.keyStoreStatus == .saved, "\(provider)")
      #expect(Self.saved(model, provider) == true, "\(provider)")
      #expect(Self.edited(model, provider) == false, "\(provider): the field now matches the store")
      #expect(owners.presence.state(for: provider) == .present)
      #expect(asked.providers == [provider])
      #expect(try owners.keychainManager.retrieve(key: Self.keyID(provider)) == Self.draft(model, provider))
    }
  }

  @Test("Save failure: the failure sentence, the draft and saved flag kept, the key unknown")
  func saveFailure() async throws {
    for provider in Self.providers {
      let asked = Asked()
      let owners = Self.owners(failing: true, asked: asked)
      let model = ProviderSetupModel()
      Self.setDraft(model, provider, "synthetic")
      let check = ProviderSetupKeyActions.save(
        "synthetic", provider: provider, model: model, owners: owners)
      try await #require(check, "the save operation was not admitted").value
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
      try await #require(ProviderSetupKeyActions.save(
        "synthetic", provider: provider, model: model, owners: owners)).value
      model.keyStoreStatus = .failed("an older failure")
      let cleared = await ProviderSetupKeyActions.clear(provider: provider, model: model, owners: owners).value
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
  func clearFailure() async throws {
    for provider in Self.providers {
      let owners = Self.owners(failing: true)
      let model = ProviderSetupModel()
      Self.setDraft(model, provider, "synthetic")
      model.setKeySaved(true, for: provider, persistedValue: "synthetic")
      let cleared = await ProviderSetupKeyActions.clear(provider: provider, model: model, owners: owners).value
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
  func noKeyRowProviders() async {
    let owners = Self.owners()
    let model = ProviderSetupModel()
    for provider in LLMProvider.allCases where !Self.providers.contains(provider) {
      #expect(ProviderSetupKeyActions.save("x", provider: provider, model: model, owners: owners) == nil)
      #expect(await ProviderSetupKeyActions.clear(provider: provider, model: model, owners: owners).value == false)
    }
    #expect(model.keyStoreStatus == .none)
  }

  @Test("a late Save keeps a newer draft and records the actual stored digest", arguments: [false, true])
  func savePreservesEdits(returnToOriginal: Bool) async throws {
    let storage = ThreadRecordingCredentialStore(pausing: .store)
    let owners = Self.owners(storageOverride: storage)
    owners.settings.llmProvider = .openAI
    let model = ProviderSetupModel()
    model.openAIKey = "saved-A"
    defer { storage.release() }
    let saving = try #require(ProviderSetupKeyActions.save(
      "saved-A", provider: .openAI, model: model, owners: owners))
    try #require(await storage.entered.wait())
    #expect(model.hasPendingKeyMutation == true)
    #expect(model.keyStoreStatus == .none)
    #expect(ProviderSetupKeyActions.save("duplicate", provider: .openAI, model: model, owners: owners) == nil)
    #expect(await ProviderSetupKeyActions.clear(provider: .openAI, model: model, owners: owners).value == false)
    model.openAIKey = "new-B"
    if returnToOriginal { model.openAIKey = "saved-A" }
    storage.release()
    await saving.value
    #expect(model.openAIKey == (returnToOriginal ? "saved-A" : "new-B"))
    #expect(model.openAIKeyPersistedDigest == ProviderSetupModel.digest("saved-A"))
    #expect(model.openAIKeySaved == true)
    #expect(model.openAIKeyEdited == (returnToOriginal == false))
    #expect(model.keyStoreStatus == .none)
    #expect(model.hasPendingKeyMutation == false)
    #expect(try owners.keychainManager.retrieve(key: KeychainManager.openAIKeyID) == "saved-A")
  }

  @Test("a late Clear preserves edits and never hides the newer field", arguments: [false, true])
  func clearPreservesNewerPresentation(changeProvider: Bool) async throws {
    let storage = ThreadRecordingCredentialStore(pausing: .delete)
    try storage.seed("saved-A", key: KeychainManager.openAIKeyID)
    let owners = Self.owners(storageOverride: storage)
    owners.settings.llmProvider = .openAI
    owners.presence.recordSaved(.openAI)
    let model = ProviderSetupModel()
    model.openAIKey = "saved-A"
    model.setKeySaved(true, for: .openAI, persistedValue: "saved-A")
    var hidden = false
    defer { storage.release() }
    let clearing = ProviderSetupKeyActions.clear(provider: .openAI, model: model, owners: owners,
      onCleared: { hidden = true })
    try #require(await storage.entered.wait())
    if changeProvider {
      owners.settings.llmProvider = .gemini
      model.invalidateKeyPresentation()
      model.geminiKey = "new-gemini"
    } else { model.openAIKey = "new-B" }
    storage.release()
    #expect(await clearing.value == false)
    #expect(hidden == false)
    #expect(model.openAIKey == (changeProvider ? "saved-A" : "new-B"))
    #expect(model.openAIKeySaved == false)
    #expect(model.openAIKeyPersistedDigest == ProviderSetupModel.digest(""))
    #expect(model.keyStoreStatus == .none)
    #expect(owners.presence.state(for: .openAI) == .absent)
    if changeProvider { #expect(model.geminiKey == "new-gemini") }
  }

  @Test("a late failed Save cannot put an old error beside newer typing")
  func failurePreservesNewerTyping() async throws {
    let storage = ThreadRecordingCredentialStore(pausing: .store, failing: true)
    let owners = Self.owners(storageOverride: storage)
    let model = ProviderSetupModel()
    model.openAIKey = "saved-A"
    defer { storage.release() }
    let saving = try #require(ProviderSetupKeyActions.save(
      "saved-A", provider: .openAI, model: model, owners: owners))
    try #require(await storage.entered.wait())
    model.openAIKey = "new-B"
    storage.release()
    await saving.value
    #expect(model.openAIKey == "new-B")
    #expect(model.keyStoreStatus == .none)
    #expect(owners.presence.state(for: .openAI) == .unknown)
  }

  @Test("asynchronous key loading keeps a newer draft but the stored-value digest")
  func readPreservesNewerDraft() async throws {
    let storage = ThreadRecordingCredentialStore(pausing: .read)
    try storage.seed("stored-A", key: KeychainManager.openAIKeyID)
    let owners = Self.owners(storageOverride: storage)
    let model = ProviderSetupModel()
    defer { storage.release() }
    let reading = ProviderSetupKeys.load(into: model, using: owners.keychainManager,
      presence: owners.presence, access: owners.access)
    try #require(await storage.entered.wait())
    #expect(model.hasCompletedKeyRead == false)
    model.openAIKey = "new-B"
    storage.release()
    await reading.value
    #expect(model.openAIKey == "new-B")
    #expect(model.openAIKeyPersistedDigest == ProviderSetupModel.digest("stored-A"))
    #expect(model.openAIKeySaved == true)
    #expect(model.openAIKeyEdited == true)
    #expect(model.hasCompletedKeyRead == true)
    #expect(model.keyReadTask == nil)
  }

  @Test("discarded editor presentation never receives a late Save badge")
  func disposalDropsPresentation() async throws {
    let storage = ThreadRecordingCredentialStore(pausing: .store)
    let owners = Self.owners(storageOverride: storage)
    let model = ProviderSetupModel()
    model.openAIKey = "saved-A"
    defer { storage.release() }
    let saving = try #require(ProviderSetupKeyActions.save(
      "saved-A", provider: .openAI, model: model, owners: owners))
    try #require(await storage.entered.wait())
    model.invalidateKeyPresentation(discardRead: true)
    storage.release()
    await saving.value
    #expect(model.keyStoreStatus == .none)
    #expect(owners.presence.state(for: .openAI) == .present)
    #expect(model.hasPendingKeyMutation == false)
  }

  @Test("a provider A to B to A change rejects the late Save without a render")
  func providerABASuppressesLateSave() async throws {
    let storage = ThreadRecordingCredentialStore(pausing: .store)
    let asked = Asked()
    let owners = Self.owners(asked: asked, storageOverride: storage)
    owners.settings.llmProvider = .openAI
    let model = ProviderSetupModel()
    model.openAIKey = "saved-A"
    defer { storage.release() }
    let saving = try #require(ProviderSetupKeyActions.save(
      "saved-A", provider: .openAI, model: model, owners: owners))
    try #require(await storage.entered.wait())
    owners.settings.llmProvider = .none
    owners.settings.llmProvider = .openAI
    // No model invalidation or view rendering: the setter's revision is the authority.
    storage.release()
    await saving.value
    #expect(model.keyStoreStatus == .none)
    #expect(model.openAIKeySaved == true)
    #expect(asked.providers.isEmpty)
    #expect(owners.presence.state(for: .openAI) == .present)
  }

  @Test("switching import ownership to a follower suppresses a late Save of the same provider")
  func importOwnershipProtectsLateSave() async throws {
    let storage = ThreadRecordingCredentialStore(pausing: .store)
    let asked = Asked()
    let owners = Self.owners(asked: asked, storageOverride: storage, surface: .fileImport)
    owners.settings.llmProvider = .openAI
    owners.settings.fileImportLLMProvider = .openAI
    owners.settings.llmModel = "deliberate-model"
    let model = ProviderSetupModel()
    model.openAIKey = "saved-A"
    defer { storage.release() }
    let saving = try #require(ProviderSetupKeyActions.save(
      "saved-A", provider: .openAI, model: model, owners: owners))
    try #require(await storage.entered.wait())
    owners.settings.fileImportLLMProvider = nil
    storage.release()
    await saving.value
    #expect(model.keyStoreStatus == .none)
    #expect(asked.providers.isEmpty)
    #expect(owners.settings.llmModel == "deliberate-model")
    #expect(model.openAIKeySaved == true)
  }

  @Test("metadata-only refresh keeps drafts already typed before refresh admission", arguments: [false, true])
  func metadataRefreshPreservesExistingDraft(cleared: Bool) async throws {
    let storage = ThreadRecordingCredentialStore()
    if cleared == false { try storage.seed("current-C", key: KeychainManager.openAIKeyID) }
    let owners = Self.owners(storageOverride: storage)
    let model = ProviderSetupModel()
    model.openAIKey = "new-B"
    model.setKeySaved(true, for: .openAI, persistedValue: "older-A")
    let refresh = ProviderSetupKeys.load(into: model, using: owners.keychainManager,
      presence: owners.presence, access: owners.access, preserveDrafts: true)
    await refresh.value
    #expect(model.openAIKey == "new-B")
    #expect(model.openAIKeySaved == (cleared == false))
    #expect(model.openAIKeyPersistedDigest == ProviderSetupModel.digest(cleared ? "" : "current-C"))
    #expect(model.openAIKeyEdited == true)
    #expect(owners.presence.state(for: .openAI) == (cleared ? .absent : .present))
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

  @Test("an older badge expiry never clears a newer Saved badge")
  func olderExpiryPreservesNewerSave() async {
    let model = ProviderSetupModel()
    let first = Gate()
    let second = Gate()
    let oldExpiry = model.showSavedBadge(wait: { await first.wait() })
    let newExpiry = model.showSavedBadge(wait: { await second.wait() })
    first.open()
    await oldExpiry.value
    #expect(model.keyStoreStatus == .saved)
    second.open()
    await newExpiry.value
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
