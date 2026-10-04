import EnviousWisprCore
import EnviousWisprLLM
import Observation

/// Which cloud providers have an API key saved on this Mac, for every surface that is not the
/// AI Polish editor (#3438). Presence and a process-lifetime credential revision per provider;
/// never the key itself.
///
/// Three states, never two: only an empty stored value or `errSecItemNotFound` confirms
/// absence, every other read failure is unknown, and unknown never becomes "no key".
///
/// **No read of its own.** Every value here is a result some existing path already produced:
/// the editor's own Keychain reads, saves and clears (`ProviderSetupKeys.load`, `saveKey`,
/// `clearKey`). A background read here would race those writes through the Keychain's legacy
/// migration (read the old file, write it to the Keychain, delete the file), and could restore
/// a key the person had just replaced. So until a path reports, a provider stays unknown,
/// and unknown shows no warning.
///
/// **Revision.** Moves only when a save or a clear succeeds, or one fails part-way, so a
/// verdict earned on a key that was then replaced or cleared stops counting
/// (`PolishCloudVerdict`). Reading the same key again does not move it.
@MainActor @Observable
final class SavedKeyPresence {
  static let cloudProviders: [LLMProvider] = [.openAI, .gemini, .claude]

  private(set) var states: [LLMProvider: SavedKeyState] = [
    .openAI: .unknown, .gemini: .unknown, .claude: .unknown,
  ]
  private(set) var revisions: [LLMProvider: UInt64] = [.openAI: 0, .gemini: 0, .claude: 0]

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

  func revision(for provider: LLMProvider) -> UInt64? {
    revisions[provider]
  }

  /// A path read this provider's key (the editor on appear, or Check again). No revision
  /// change: the same key read again is the same credential.
  func recordRead(_ state: SavedKeyState, for provider: LLMProvider) {
    guard Self.cloudProviders.contains(provider) else { return }
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
    states[provider] = state
    onChange?()
  }
}
