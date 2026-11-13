import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Observation

/// View-lifetime drafts and presentation only. Saved keys and check evidence remain with their
/// existing owners. The model can be retained by See all while switching between its tabs.
@MainActor @Observable
final class SetupCloudPanelModel {
  enum Phase: Equatable {
    case idle, empty, checking, loading, rejected, retry, picker, noModels
  }

  enum Answer {
    case accepted(UInt64, [LLMModelInfo])
    case rejected(UInt64)
    case retry
  }

  struct Inputs {
    var hydrate: (ProviderSetupModel) -> Task<Void, Never>?
    var check:
      (LLMProvider, String, @escaping LLMModelDiscoveryCoordinator.SetupProgress) async -> Answer
    var isCurrent: (LLMProvider, UInt64) -> Bool
    var canChoose: (LLMProvider, String, UInt64) -> Bool
    var list: () -> CloudModelList?
  }

  private struct Result {
    var phase: Phase = .idle
    var revision: UInt64?
    var models: [LLMModelInfo] = []
    var selection: String?
  }

  let keys = ProviderSetupModel()
  private let inputs: Inputs
  private var results: [LLMProvider: Result] = [:]
  private var busyProvider: LLMProvider?
  private var startedRead = false
  var provider: LLMProvider = .openAI

  init(inputs: Inputs) { self.inputs = inputs }

  func hydrate() {
    guard !startedRead else { return }
    startedRead = true
    _ = inputs.hydrate(keys)
  }

  var key: String {
    switch provider {
    case .openAI: keys.openAIKey
    case .gemini: keys.geminiKey
    case .claude: keys.claudeKey
    default: ""
    }
  }

  func edit(_ value: String) {
    guard value != key else { return }
    switch provider {
    case .openAI: keys.openAIKey = value
    case .gemini: keys.geminiKey = value
    case .claude: keys.claudeKey = value
    default: return
    }
    results[provider] = nil
  }

  var isChecking: Bool { busyProvider != nil }

  var waitingForOtherProviderMessage: LocalizedStringResource? {
    guard let busyProvider, busyProvider != provider else { return nil }
    return "Finishing the previous key check. You can check this provider next."
  }

  private var current: Result {
    guard let result = results[provider] else { return Result() }
    if let revision = result.revision, !inputs.isCurrent(provider, revision) { return Result() }
    return result
  }

  var phase: Phase {
    let state = current
    return state.phase == .picker && models.isEmpty ? .noModels : state.phase
  }

  var models: [LLMModelInfo] {
    let state = current
    guard state.phase == .picker, let revision = state.revision else { return [] }
    return OllamaModelPickerPresentation.cloudGroups(
      from: state.models.filter { $0.provider == provider }, chosenModel: state.selection ?? "",
      list: inputs.list()
    ).selectable.filter { inputs.canChoose(provider, $0.id, revision) }
  }

  func recommended(_ model: LLMModelInfo) -> Bool {
    CloudModelPresentation.isRecommended(model.id, provider: model.provider, list: inputs.list())
  }

  var chosen: LLMModelInfo? { models.first { $0.id == current.selection } }

  func select(_ id: String) {
    guard models.contains(where: { $0.id == id }) else { return }
    results[provider]?.selection = id
  }

  @discardableResult
  func check() -> Task<Void, Never>? {
    guard busyProvider == nil, CredentialProvider(provider) != nil else { return nil }
    let provider = provider
    let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      results[provider] = Result(phase: .empty)
      return nil
    }
    let operation = keys.beginKeyMutation(for: provider)
    let edit = operation.edit
    busyProvider = provider
    results[provider] = Result(phase: .checking)
    let run = inputs.check
    return Task { [weak self] in
      let answer = await run(provider, value) { [weak self] phase, revision in
        guard let self, self.keys.keyEditRevision(provider) == edit,
          let revision, self.inputs.isCurrent(provider, revision)
        else { return }
        let displayed: Phase = phase == .listingModels ? .checking : .loading
        self.results[provider] = Result(phase: displayed, revision: revision)
      }
      guard let self else { return }
      self.keys.endKeyMutation(operation)
      self.busyProvider = nil
      guard self.keys.keyEditRevision(provider) == edit else { return }
      switch answer {
      case .accepted(let revision, let models):
        self.results[provider] = Result(phase: .picker, revision: revision, models: models)
      case .rejected(let revision):
        self.results[provider] = Result(phase: .rejected, revision: revision)
      case .retry:
        self.results[provider] = Result(phase: .retry)
      }
    }
  }

  static func live(
    settings: SettingsManager, writer: CredentialWriter, list: CloudModelListHolder
  ) -> SetupCloudPanelModel {
    let presence = writer.presence
    let discovery = writer.discovery
    func isCurrent(_ provider: LLMProvider, _ revision: UInt64) -> Bool {
      presence.revision(for: provider) == revision && !presence.hasPendingMutation(for: provider)
    }
    return SetupCloudPanelModel(
      inputs: Inputs(
        hydrate: { keys in
          ProviderSetupKeys.load(
            into: keys, using: writer.keychainManager, presence: presence,
            access: writer.access)
        },
        check: { provider, key, progress in
          guard let credential = CredentialProvider(provider) else { return .retry }
          let outcome = await writer.save(
            key, for: credential, settings: settings, surface: .dictation, setupProgress: progress)
          guard case .stored(let validation, let revision?) = outcome else { return .retry }
          await validation.value
          guard isCurrent(provider, revision), let verdict = discovery.cloudVerdicts[provider],
            verdict.credentialRevision == revision
          else { return .retry }
          switch verdict.result {
          case .rejected: return .rejected(revision)
          case .accepted where discovery.stateProvider == provider:
            return .accepted(revision, discovery.discoveredModels)
          case .accepted, .checking, .inconclusive: return .retry
          }
        },
        isCurrent: isCurrent,
        canChoose: { provider, model, revision in
          guard isCurrent(provider, revision) else { return false }
          return OnboardingLiveMapping.cloudEvidence(
            provider: provider, selectedModel: model, verdict: discovery.cloudVerdicts[provider],
            currentRevision: revision, observations: discovery.cloudModelObservations
          )?.isCurrentPass == true
        },
        list: { list.snapshot?.list }))
  }
}
