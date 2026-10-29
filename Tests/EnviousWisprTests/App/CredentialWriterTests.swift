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
    var keys: [String] = []
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
    events: @escaping CredentialWriter.Emit = { _, _, _ in },
    discover: (@MainActor (LLMProvider, String) async throws -> [LLMModelInfo])? = nil
  ) -> Fixture {
    let keychain = Self.fixtureKeychain(storage: storage)
    let presence = SavedKeyPresence()
    let log = DiscoveryLog()
    let access = CredentialAccessLane()
    let discovery = LLMModelDiscoveryCoordinator(
      keychainManager: keychain,
      cacheDefaults: TestDefaults.suite("ew.tests.credential-writer.cache.\(UUID().uuidString)")!,
      savedKeyPresence: presence, credentialAccess: access,
      discoverModels: { provider, key in
        log.asked.append(provider)
        log.keys.append(key)
        if let discover { return try await discover(provider, key) }
        return [
          LLMModelInfo(
            id: "model-\(provider.rawValue)", displayName: "m", provider: provider,
            isAvailable: true, isRemote: true)
        ]
      })
    let settings = SettingsManager(
      defaults: TestDefaults.suite("ew.tests.credential-writer.\(UUID().uuidString)")!)
    var writer = CredentialWriter(
      keychainManager: keychain, presence: presence, discovery: discovery, access: access)
    writer.emit = events
    return Fixture(
      writer: writer, keychain: keychain, presence: presence, discovery: discovery, log: log,
      settings: settings)
  }

  @Test("Save and Clear perform their blocking storage work off the main thread")
  func storageRunsOffMain() async throws {
    let storage = ThreadRecordingCredentialStore()
    let fx = Self.fixture(storage: storage)
    guard case .stored(let validation, _) = await fx.writer.save(
      "synthetic", for: .openAI, settings: fx.settings, surface: .dictation)
    else { Issue.record("the synthetic save failed"); return }
    await validation.value
    guard case .cleared = await fx.writer.clear(.openAI)
    else { Issue.record("the synthetic clear failed"); return }
    #expect(storage.mainThreadEntries == [false, false])
  }

  private static func isOnMainThread() -> Bool { Thread.isMainThread }

  @Test("MainActor makes progress while credential storage is parked")
  func mainActorProgressesDuringStorage() async throws {
    let storage = ThreadRecordingCredentialStore(pausing: .store)
    let fx = Self.fixture(storage: storage)
    defer { storage.release() }
    let operation = Task {
      if case .stored(let validation, _) = await fx.writer.save(
        "synthetic", for: .openAI, settings: fx.settings, surface: .dictation) {
        await validation.value
      }
    }
    try #require(await storage.entered.wait())
    #expect(Self.isOnMainThread() == true)
    #expect(storage.mainThreadEntries == [false])
    #expect(fx.presence.state(for: .openAI) == .unknown)
    storage.release()
    await operation.value
    #expect(fx.presence.state(for: .openAI) == .present)
  }

  @Test("a queued cancelled Clear still commits after the preceding Save exactly once")
  func cancelledQueuedClearStillReconciles() async throws {
    let storage = ThreadRecordingCredentialStore(pausing: .store)
    var events: [String] = []
    let fx = Self.fixture(storage: storage, events: { _, action, _ in events.append(action) })
    let queued = CredentialTestSignal()
    fx.writer.access.onQueuedForTesting = { queued.open() }
    defer { storage.release() }
    let saving = Task {
      if case .stored(let validation, _) = await fx.writer.save(
        "synthetic", for: .openAI, settings: fx.settings, surface: .dictation) {
        await validation.value
      }
    }
    try #require(await storage.entered.wait())
    let secondWriter = fx.writer
    var cleared = false
    let clearing = Task {
      if case .cleared = await secondWriter.clear(.openAI, settings: fx.settings) { cleared = true }
    }
    try #require(await queued.wait())
    clearing.cancel()
    storage.release()
    await saving.value
    await clearing.value
    #expect(cleared == true)
    #expect(events == ["save", "remove"])
    #expect(fx.presence.state(for: .openAI) == .absent)
    #expect(fx.presence.revision(for: .openAI) == 2)
    #expect(fx.log.asked.isEmpty)
  }

  @Test("newer Gemini discovery survives an older credential outcome", arguments: CredentialMutationScenario.allCases)
  func newerDiscoverySurvivesMutation(scenario: CredentialMutationScenario) async throws {
    let storage = ThreadRecordingCredentialStore(
      pausing: scenario.isClear ? .delete : .store, failing: scenario.fails)
    try storage.seed("old-openai", key: KeychainManager.openAIKeyID)
    try storage.seed("gemini-key", key: KeychainManager.geminiKeyID)
    let fx = Self.fixture(storage: storage)
    fx.settings.llmProvider = .openAI
    fx.presence.recordSaved(.openAI)
    fx.presence.recordSaved(.gemini)
    let queued = CredentialTestSignal()
    fx.writer.access.onQueuedForTesting = { queued.open() }
    defer { storage.release() }
    var succeeded = false
    let mutation = Task {
      if scenario.isClear {
        if case .cleared = await fx.writer.clear(.openAI, settings: fx.settings) { succeeded = true }
      } else if case .stored(let validation, _) = await fx.writer.save(
        "new-openai", for: .openAI, settings: fx.settings, surface: .dictation) {
        succeeded = true
        await validation.value
      }
    }
    try #require(await storage.entered.wait())
    fx.settings.llmProvider = .gemini
    let newer = Task {
      await fx.discovery.validateKeyAndDiscoverModels(provider: .gemini, settings: fx.settings)
    }
    try #require(await queued.wait())
    #expect(fx.discovery.stateProvider == .gemini)
    storage.release()
    await mutation.value
    await newer.value
    #expect(succeeded == (scenario.fails == false))
    #expect(fx.log.asked == [.gemini])
    #expect(fx.log.keys == ["gemini-key"])
    #expect(fx.discovery.stateProvider == .gemini)
    #expect(fx.discovery.keyValidationState == .valid)
    #expect(fx.discovery.discoveredModels.map(\.id) == ["model-gemini"])
    if scenario.fails { #expect(fx.presence.state(for: .openAI) == .unknown) }
    else { #expect(fx.presence.state(for: .openAI) == (scenario.isClear ? .absent : .present)) }
  }

  @Test("a missing credential signal fails at its deadline")
  func credentialSignalDeadline() async {
    #expect(await CredentialTestSignal().wait(deadlineMs: 1) == false)
  }

  @Test("provider A to B to A invalidates both late success and failure without view callbacks", arguments: [false, true])
  func networkABARejectsStalePublication(failing: Bool) async throws {
    let entered = CredentialTestSignal()
    let finish = CredentialTestSignal()
    let fx = Self.fixture(discover: { provider, _ in
      entered.open()
      #expect(await finish.wait())
      if failing { throw LLMError.invalidAPIKey }
      return [LLMModelInfo(id: "late-model", displayName: "late", provider: provider,
        isAvailable: true, isRemote: true)]
    })
    try fx.keychain.store(key: KeychainManager.openAIKeyID, value: "synthetic")
    fx.presence.recordSaved(.openAI)
    fx.settings.llmProvider = .openAI
    defer { finish.open() }
    let check = Task {
      await fx.discovery.validateKeyAndDiscoverModels(provider: .openAI, settings: fx.settings)
    }
    try #require(await entered.wait())
    fx.settings.llmProvider = .gemini
    fx.settings.llmProvider = .openAI
    let modelAfterSelection = fx.settings.llmModel
    finish.open()
    await check.value
    #expect(fx.discovery.keyValidationState == .idle)
    #expect(fx.discovery.cloudVerdict == nil)
    #expect(fx.discovery.discoveredModels.isEmpty)
    #expect(fx.settings.llmModel == modelAfterSelection)
  }

  @Test("synchronous admission order wins over reversed Task execution")
  func admissionOrderPrecedesTaskScheduling() async throws {
    var events: [String] = []
    let fx = Self.fixture(events: { _, action, _ in events.append(action) })
    let holding = CredentialTestSignal()
    let release = CredentialTestSignal()
    let queued = CredentialTestSignal()
    defer { release.open() }
    let holder = Task {
      await fx.writer.access.run {
        holding.open()
        #expect(await release.wait())
      }
    }
    try #require(await holding.wait())
    fx.writer.access.onQueuedForTesting = { queued.open() }
    let saveAdmission = fx.writer.admit(.openAI, settings: fx.settings, surface: .dictation)
    let clearAdmission = fx.writer.admit(.openAI, settings: fx.settings, surface: .dictation)
    let clearing = Task {
      _ = await fx.writer.clear(.openAI, settings: fx.settings, admission: clearAdmission)
    }
    // The old lane queues Clear before Save's task even exists. The corrected lane has
    // already reserved Save then Clear at their synchronous admission points instead.
    try #require(await queued.wait())
    let saving = Task {
      if case .stored(let validation, _) = await fx.writer.save(
        "synthetic-A", for: .openAI, settings: fx.settings, surface: .dictation,
        admission: saveAdmission) { await validation.value }
    }
    release.open()
    await holder.value
    await saving.value
    await clearing.value
    #expect(events == ["save", "remove"])
    #expect(fx.presence.state(for: .openAI) == .absent)
    #expect(fx.presence.revision(for: .openAI) == 2)
    #expect(throws: (any Error).self) { try fx.keychain.retrieve(key: KeychainManager.openAIKeyID) }
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
        case .stored(let validation, _) = await fx.writer.save(
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
        case .stored(let validation, _) = await fx.writer.save(
          "synthetic", for: provider, settings: fx.settings, surface: .dictation)
      else {
        Issue.record("\(provider): save failed")
        continue
      }
      await validation.value
      let before = try #require(fx.presence.revision(for: provider.llmProvider))
      guard case .cleared = await fx.writer.clear(provider) else {
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
        case .failed = await fx.writer.save(
          "synthetic", for: provider, settings: fx.settings, surface: .dictation)
      else {
        Issue.record("\(provider): a failing store reported success")
        continue
      }
      #expect(fx.presence.state(for: provider.llmProvider) == .unknown)
      #expect(fx.presence.revision(for: provider.llmProvider) == before + 1)
      guard case .failed = await fx.writer.clear(provider) else {
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
        if case .stored(let validation, _) = await writer.save(
          secret, for: provider, settings: settings, surface: .dictation)
        {
          await validation.value
        }
        _ = await writer.clear(provider)
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

enum CredentialStoreOperation: Sendable, Equatable { case store, delete, read }
enum CredentialMutationScenario: Sendable, CaseIterable {
  case save, clear, failedSave, failedClear
  var isClear: Bool { switch self { case .clear, .failedClear: true; default: false } }
  var fails: Bool { switch self { case .failedSave, .failedClear: true; default: false } }
}

/// Immutable store location; every recorded entry and gate admission is locked. The
/// semaphore keeps an early release, so the entered signal cannot race waiter registration.
final class ThreadRecordingCredentialStore: LegacyKeyFileStorage, @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [Bool] = []
  private var paused = false
  private let pausing: CredentialStoreOperation?
  private let failing: Bool
  private let releaseGate = DispatchSemaphore(value: 0)
  let entered = CredentialTestSignal()
  private let store = FileLegacyKeyStore(storageDirectory: TestTemporaryDirectory.url
    .appending(path: "ew-thread-credentials-\(UUID().uuidString)"))
  init(pausing: CredentialStoreOperation? = nil, failing: Bool = false) {
    self.pausing = pausing
    self.failing = failing
  }
  var mainThreadEntries: [Bool] { lock.withLock { entries } }
  func release() { releaseGate.signal() }
  func seed(_ value: String, key: String) throws { try store.store(key: key, value: value) }
  private func visit(_ operation: CredentialStoreOperation) throws {
    let hold = lock.withLock { () -> Bool in
      if operation != .read { entries.append(Thread.isMainThread) }
      guard pausing == operation && paused == false else { return false }
      paused = true
      return true
    }
    if hold {
      entered.open()
      // Incorrect main-thread execution records the bug but never parks the main actor.
      if Thread.isMainThread == false {
        // deadline-fallback: release the worker even if an assertion aborts its driver.
        guard releaseGate.wait(timeout: .now() + 5) == .success else {
          throw KeyStoreError.storeFailed(-1)
        }
      }
    }
    if failing && operation == .store { throw KeyStoreError.storeFailed(-25308) }
    if failing && operation == .delete { throw KeyStoreError.deleteFailed(-25308) }
  }
  func store(key: String, value: String) throws {
    try visit(.store)
    try store.store(key: key, value: value)
  }
  func retrieve(key: String) throws -> String {
    let result = Result { try store.retrieve(key: key) }
    try visit(.read)
    return try result.get()
  }
  func delete(key: String) throws {
    try visit(.delete)
    try store.delete(key: key)
  }
}

/// The existing saved-key fixture's bounded one-shot signal, shared by these credential
/// fixtures. Resolution/registration is locked; a signal before wait is remembered.
final class CredentialTestSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Bool, Never>?
  private var resolution: Bool?
  func open() { finish(true) }
  func wait(deadlineMs: Int = 2000) async -> Bool {
    let timer = Task {
      // deadline-fallback: absent subject signals must fail, never hang.
      do { try await Task.sleep(for: .milliseconds(deadlineMs)) } catch { return }
      self.finish(false)
    }
    defer { timer.cancel() }
    return await withCheckedContinuation { c in
      lock.lock()
      if let resolution { lock.unlock(); c.resume(returning: resolution) }
      else { continuation = c; lock.unlock() }
    }
  }
  private func finish(_ value: Bool) {
    lock.lock()
    guard resolution == nil else { lock.unlock(); return }
    resolution = value
    let c = continuation
    continuation = nil
    lock.unlock()
    c?.resume(returning: value)
  }
}
