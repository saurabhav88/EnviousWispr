import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

@MainActor
@Suite("Setup cloud discovery", .tags(.productOutcome))
struct SetupCloudDiscoveryTests {
  @Test("Setup publishes progress on the saved revision and leaves the dictation choice alone")
  func setupCheck() async throws {
    let fixture = Fixture()
    fixture.settings.llmProvider = .openAI
    fixture.settings.llmModel = "keep-this-model"
    let progress = ProgressLog()
    let outcome = await fixture.writer.save(
      "synthetic", for: .openAI, settings: fixture.settings, surface: .dictation,
      setupProgress: { phase, revision in
        progress.phases.append(phase)
        progress.revisions.append(revision)
        progress.verdicts.append(fixture.discovery.cloudVerdicts[.openAI]?.result)
      })
    guard case .stored(let validation, let revision?) = outcome else {
      Issue.record("Synthetic key was not stored")
      return
    }
    try await BoundedWait.result(of: validation).get()
    #expect(progress.phases == [.listingModels, .probingModels])
    #expect(progress.revisions == [revision, revision])
    #expect(progress.verdicts == [.checking, .checking])
    #expect(fixture.discovery.cloudVerdicts[.openAI]?.result == .accepted)
    #expect(fixture.discovery.discoveredModels.map(\.id) == ["example"])
    #expect(fixture.settings.llmProvider == .openAI)
    #expect(fixture.settings.llmModel == "keep-this-model")
  }

  @Test(
    "The three Settings surfaces still publish ordinary discovery and preserve explicit cloud choices"
  )
  func settingsCheck() async throws {
    for surface in [ProviderSetupSurface.dictation, .fileImport, .meetingSummary] {
      let fixture = Fixture()
      let settings = fixture.settings
      settings.llmProvider = .openAI
      settings.fileImportLLMProvider = .openAI
      settings.meetingSummaryLLMProvider = .openAI
      settings.llmModel = "dictation-choice"
      settings.fileImportLLMModel = "import-choice"
      settings.meetingSummaryLLMModel = "meeting-choice"
      let outcome = await fixture.writer.save(
        "synthetic", for: .openAI, settings: settings, surface: surface)
      guard case .stored(let validation, _) = outcome else {
        Issue.record("Synthetic key was not stored")
        return
      }
      try await BoundedWait.result(of: validation).get()
      #expect(fixture.discovery.cloudVerdicts[.openAI]?.result == .accepted)
      #expect(fixture.discovery.discoveredModels.map(\.id) == ["example"])
      #expect(settings.llmModel == "dictation-choice")
      #expect(settings.fileImportLLMModel == "import-choice")
      #expect(settings.meetingSummaryLLMModel == "meeting-choice")
    }
  }

  private final class ProgressLog {
    var phases: [LLMModelDiscoveryCoordinator.SetupPhase] = []
    var revisions: [UInt64?] = []
    var verdicts: [PolishCloudVerdict.Result?] = []
  }

  @MainActor
  private struct Fixture {
    let settings: SettingsManager
    let discovery: LLMModelDiscoveryCoordinator
    let writer: CredentialWriter

    init() {
      let defaults = TestDefaults.suite("ew.tests.setup-cloud.\(UUID().uuidString)")!
      settings = SettingsManager(defaults: defaults)
      let presence = SavedKeyPresence()
      let manager = KeychainManager(
        backend: .legacyFiles,
        legacyStore: FileLegacyKeyStore(
          storageDirectory: TestTemporaryDirectory.url.appending(path: UUID().uuidString)))
      let access = CredentialAccessLane()
      discovery = LLMModelDiscoveryCoordinator(
        keychainManager: manager, cacheDefaults: defaults, savedKeyPresence: presence,
        credentialAccess: access, validationEmitter: { _, _, _, _, _ in },
        setupDiscovery: { provider, _, didList in
          await didList()
          return [Self.row(provider)]
        },
        discoverModels: { provider, _ in [Self.row(provider)] })
      writer = CredentialWriter(
        keychainManager: manager, presence: presence, discovery: discovery, access: access,
        emit: { _, _, _ in })
    }

    private static func row(_ provider: LLMProvider) -> LLMModelInfo {
      LLMModelInfo(
        id: "example", displayName: "Example", provider: provider, availability: .available,
        isRemote: true)
    }
  }
}
