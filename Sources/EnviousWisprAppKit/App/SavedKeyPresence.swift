import EnviousWisprCore
import EnviousWisprLLM
import Observation
import Foundation

/// Which cloud providers have an API key saved on this Mac, for every surface that is not the
/// AI Polish editor (#3438). Presence and a process-lifetime credential revision per provider;
/// never the key itself.
///
/// Three states, never two: only an empty stored value or `errSecItemNotFound` confirms
/// absence, every other read failure is unknown, and unknown never becomes "no key".
///
/// The editor and off-page readers share the credential access lane. A Keychain read can migrate
/// a legacy key, so reads and writes stay ordered even when the caller only uses presence.
///
/// **Revision.** Moves only when a save or a clear succeeds, or one fails part-way, so a
/// verdict earned on a key that was then replaced or cleared stops counting
/// (`PolishCloudVerdict`). Reading the same key again does not move it.
@MainActor @Observable
final class SavedKeyPresence {
  nonisolated static let cloudProviders: [LLMProvider] = [.openAI, .gemini, .claude]

  private(set) var states: [LLMProvider: SavedKeyState] = [
    .openAI: .unknown, .gemini: .unknown, .claude: .unknown,
  ]
  private(set) var revisions: [LLMProvider: UInt64] = [.openAI: 0, .gemini: 0, .claude: 0]
  /// Accepted but not yet reconciled writes, shared by editors and the dev door. These
  /// transient tokens never change durable presence/revisions before storage completes.
  private var pendingMutations: [UUID: LLMProvider] = [:]

  func beginMutation(for provider: LLMProvider) -> UUID {
    let id = UUID()
    pendingMutations[id] = provider
    return id
  }
  func endMutation(_ id: UUID) { pendingMutations[id] = nil }
  func hasPendingMutation(for provider: LLMProvider) -> Bool {
    pendingMutations.values.contains(provider)
  }

  /// When the newest answer about each provider was produced. A read reported later but taken
  /// earlier (a dictation's key read arriving after the editor's Check again) is not newer, so
  /// it never replaces a newer answer.
  @ObservationIgnored private var answeredAt: [LLMProvider: ContinuousClock.Instant] = [:]

  /// Told synchronously after every change here, so a reader whose configuration includes the
  /// credential revision never misses one between two observations (#3438 monitor).
  @ObservationIgnored var onChange: (@MainActor () -> Void)?

  func state(for provider: LLMProvider) -> SavedKeyState {
    states[provider] ?? .absent
  }

  /// The flag shape `PolishSetupFacts` stores: true present, false absent, nil unknown.
  func savedFlag(for provider: LLMProvider) -> Bool? {
    state(for: provider).asSavedFlag
  }

  /// Populate History's provider choices without opening the credential editor.
  func readUnknown(using keychain: KeychainManager, access: CredentialAccessLane = .live) async {
    guard Self.cloudProviders.contains(where: { state(for: $0) == .unknown }) else { return }
    await access.run {
      for credential in CredentialProvider.allCases {
        let provider = credential.llmProvider
        guard !Task.isCancelled, state(for: provider) == .unknown,
          !hasPendingMutation(for: provider)
        else { continue }
        let revision = revision(for: provider)
        let readAt = ContinuousClock.now
        let result = await CredentialIO.perform(.read(credential.keyID), using: keychain)
        guard self.revision(for: provider) == revision, !hasPendingMutation(for: provider)
        else { continue }
        recordRead(.fromRead(result), for: provider, readAt: readAt)
      }
    }
  }

  func revision(for provider: LLMProvider) -> UInt64? {
    revisions[provider]
  }

  /// A path read this provider's key (the editor on appear, or Check again, or a dictation's
  /// own read) at `readAt`. No revision change: the same key read again is the same credential.
  /// Ignored when an answer produced after `readAt` is already recorded.
  func recordRead(
    _ state: SavedKeyState, for provider: LLMProvider,
    readAt: ContinuousClock.Instant = .now
  ) {
    guard Self.cloudProviders.contains(provider) else { return }
    if let newer = answeredAt[provider], newer > readAt { return }
    answeredAt[provider] = readAt
    states[provider] = state
    onChange?()
  }

  /// A save succeeded: the key is present and is a new credential.
  func recordSaved(_ provider: LLMProvider) {
    recordMutation(provider, state: .present)
  }

  /// A clear succeeded: no key, and any verdict about the old one stops counting.
  func recordCleared(_ provider: LLMProvider) {
    recordMutation(provider, state: .absent)
  }

  /// A save or clear failed and the stored state is no longer known. The revision moves too,
  /// so no verdict about the previous credential survives the uncertainty.
  func recordUncertain(_ provider: LLMProvider) {
    recordMutation(provider, state: .unknown)
  }

  private func recordMutation(_ provider: LLMProvider, state: SavedKeyState) {
    guard Self.cloudProviders.contains(provider) else { return }
    revisions[provider, default: 0] &+= 1
    answeredAt[provider] = .now
    states[provider] = state
    onChange?()
  }
}
