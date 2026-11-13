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
    /// The person left a provider (switched away, Add my key later, See all left; nil: every
    /// provider). The live owner removes this panel's key writes that did not pass (M82 r1).
    var leave: (LLMProvider?) -> Void = { _ in }
    /// A check for this provider is about to be scheduled: the live owner registers the write
    /// now, so a leave before the check task runs is seen (M82 r2, member a). `keep`: the field
    /// still holds the key read from the store, unchanged, so that key is never removed.
    var begin: (LLMProvider, _ keep: Bool) -> Void = { _, _ in }
    /// Typed key outcomes for Setup's telemetry (M82 r1); never the key.
    var report: (SetupKeyEvent) -> Void = { _ in }
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
  var provider: LLMProvider = .openAI {
    didSet { if oldValue != provider { inputs.leave(oldValue) } }
  }
  private var disposed = false

  init(inputs: Inputs) { self.inputs = inputs }

  /// Add my key later: the key outcome is skipped. The screen then sends `skipPolish`, which
  /// leaves See all and disposes this panel.
  func later() { inputs.report(.skipped) }

  /// See all was left (or the window model detached): this panel's unpassed key writes go,
  /// including one whose check is still running when it ends. Called once by its owner.
  func dispose() {
    guard !disposed else { return }
    disposed = true
    inputs.leave(nil)
  }

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

  /// The digest of the key last read from or agreed with the store (nil: no cloud slot).
  private func storedDigest(_ provider: LLMProvider) -> Data? {
    switch provider {
    case .openAI: keys.openAIKeyPersistedDigest
    case .gemini: keys.geminiKeyPersistedDigest
    case .claude: keys.claudeKeyPersistedDigest
    default: nil
    }
  }

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
    guard !disposed, busyProvider == nil, CredentialProvider(provider) != nil else { return nil }
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
    // The person's already-saved key, re-checked without edits, is theirs: an unfinished or
    // failed re-check (offline, a provider outage) must never delete it.
    // The submitted (trimmed) key against the key last read from or agreed with the store, both
    // normalized the same way; an empty field never reaches here, so an unfinished read cannot
    // mark a typed key as kept.
    inputs.begin(provider, ProviderSetupModel.digest(value) == storedDigest(provider))
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
      guard !self.disposed else { return }  // a stale answer reports and shows nothing
      switch answer {
      case .accepted(let revision, let models):
        self.results[provider] = Result(phase: .picker, revision: revision, models: models)
        // The field now agrees with a stored, passed key: the existing persisted-digest owner
        // records it, so re-checking this same value is a kept write (M82 r4).
        if self.inputs.isCurrent(provider, revision) {
          self.keys.setKeySaved(true, for: provider, persistedValue: value)
        }
        if self.inputs.isCurrent(provider, revision) { self.inputs.report(.passed) }
      case .rejected(let revision):
        self.results[provider] = Result(phase: .rejected, revision: revision)
        if self.inputs.isCurrent(provider, revision) {
          self.inputs.report(.rejected(provider, revision: revision))
        }
      case .retry:
        self.results[provider] = Result(phase: .retry)
      }
    }
  }

  static func live(
    settings: SettingsManager, writer: CredentialWriter, list: CloudModelListHolder,
    report: @escaping (SetupKeyEvent) -> Void = { _ in }
  ) -> SetupCloudPanelModel {
    let presence = writer.presence
    let discovery = writer.discovery
    func isCurrent(_ provider: LLMProvider, _ revision: UInt64) -> Bool {
      presence.revision(for: provider) == revision && !presence.hasPendingMutation(for: provider)
    }
    let ledger = SetupCloudKeyLedger { provider, revision in
      // Revision-bound: only this panel's own write, still the stored key with no other
      // mutation reserved, and never a key whose check passed. `admit` runs synchronously
      // after this check, so no other write can slip between them; a later write queues
      // behind the removal and survives it.
      guard let credential = CredentialProvider(provider), isCurrent(provider, revision),
        discovery.cloudVerdicts[provider].map({
          $0.credentialRevision == revision && $0.result == .accepted
        }) != true
      else { return }
      let admission = writer.admit(credential, settings: settings, surface: .dictation)
      Task { _ = await writer.clear(credential, settings: settings, admission: admission) }
    }
    return SetupCloudPanelModel(
      inputs: Inputs(
        hydrate: { keys in
          ProviderSetupKeys.load(
            into: keys, using: writer.keychainManager, presence: presence,
            access: writer.access)
        },
        check: { provider, key, progress in
          // The write the panel registered; a write left before this ran stores nothing.
          guard let credential = CredentialProvider(provider), let write = ledger.adopt(provider)
          else { return .retry }
          let outcome = await writer.save(
            key, for: credential, settings: settings, surface: .dictation, setupProgress: progress)
          guard case .stored(let validation, let revision?) = outcome else {
            ledger.finish(write, revision: nil, passed: false)
            return .retry
          }
          if !ledger.isLeft(write) { report(.saved) }
          await validation.value
          let passed = discovery.cloudVerdicts[provider].map {
            $0.credentialRevision == revision && $0.result == .accepted
          } == true
          ledger.finish(write, revision: revision, passed: passed)
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
        list: { list.snapshot?.list },
        leave: { ledger.leave($0) },
        begin: { ledger.begin($0, keep: $1) },
        report: report))
  }
}

/// A key outcome from Setup's cloud panel, for the visit's telemetry (M82 r1). Never the key.
enum SetupKeyEvent: Equatable {
  /// The store accepted a typed key (its check has not answered yet).
  case saved
  case passed
  /// The check rejected this provider's key at this stored revision.
  case rejected(LLMProvider, revision: UInt64)
  /// Add my key later.
  case skipped
}

/// The cloud panel's own key writes (M82 r1): which providers it stored a key for, whether that
/// key's check passed, and whether the person already left that provider. A write that did not
/// pass is removed when its provider is left, or as soon as its check ends if the person left
/// while it ran. It outlives the panel view, so a check finishing after See all closed still
/// cleans up. `discard` holds the revision guards.
@MainActor
final class SetupCloudKeyLedger {
  struct Write: Equatable {
    fileprivate let id: Int
    fileprivate let provider: LLMProvider
  }

  private struct Entry {
    var id: Int
    /// The write re-stores the key already saved, unchanged: never removed.
    var keep = false
    var adopted = false
    var revision: UInt64?
    var finished = false
    var passed = false
    var left = false
  }

  private var entries: [LLMProvider: Entry] = [:]
  private var nextID = 0
  private let discard: (LLMProvider, UInt64) -> Void

  init(discard: @escaping (LLMProvider, UInt64) -> Void) { self.discard = discard }

  /// A check for `provider` was scheduled (queued, nothing stored yet); it replaces any earlier
  /// entry for that provider.
  @discardableResult
  func begin(_ provider: LLMProvider, keep: Bool = false) -> Write {
    nextID &+= 1
    entries[provider] = Entry(id: nextID, keep: keep)
    return Write(id: nextID, provider: provider)
  }

  /// The owner call for the registered write starts. nil: the person already left that provider
  /// while it was queued, so nothing may be stored (the entry goes); with no registered write
  /// one is begun now.
  func adopt(_ provider: LLMProvider) -> Write? {
    guard var entry = entries[provider], !entry.adopted else {
      let write = begin(provider)
      entries[provider]?.adopted = true
      return write
    }
    if entry.left {
      entries[provider] = nil
      return nil
    }
    entry.adopted = true
    entries[provider] = entry
    return Write(id: entry.id, provider: provider)
  }

  /// Whether the person left this write's provider (its telemetry stops).
  func isLeft(_ write: Write) -> Bool {
    guard let entry = entries[write.provider], entry.id == write.id else { return true }
    return entry.left
  }

  /// The save and its check ended. `revision` nil: nothing known was stored.
  func finish(_ write: Write, revision: UInt64?, passed: Bool) {
    guard var entry = entries[write.provider], entry.id == write.id else { return }
    entry.revision = revision
    entry.finished = true
    entry.passed = passed
    entries[write.provider] = entry
    if entry.left { settle(write.provider) }
  }

  /// The person left `provider` (nil: every provider).
  func leave(_ provider: LLMProvider?) {
    for key in provider.map({ [$0] }) ?? Array(entries.keys) {
      guard var entry = entries[key] else { continue }
      entry.left = true
      entries[key] = entry
      if entry.finished { settle(key) }
    }
  }

  private func settle(_ provider: LLMProvider) {
    guard let entry = entries.removeValue(forKey: provider) else { return }
    if !entry.passed, !entry.keep, let revision = entry.revision { discard(provider, revision) }
  }
}
