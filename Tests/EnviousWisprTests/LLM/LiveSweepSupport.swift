import EnviousWisprCore
import Foundation

@testable import EnviousWisprLLM

/// A key store holding values handed to the test process through the environment, so a sweep
/// can run on a key that is not mirrored in the dev file store without writing it to disk or
/// printing it: `get-key launch <name> TEST_RUNNER_EW_LIVE_OPENAI_KEY -- scripts/xcode-test.sh ...`.
struct EnvironmentKeyStore: LegacyKeyFileStorage {
  let values: [String: String]
  func store(key: String, value: String) throws {}
  func retrieve(key: String) throws -> String {
    guard let value = values[key] else { throw KeyStoreError.retrieveFailed(errSecItemNotFound) }
    return value
  }
  func delete(key: String) throws {}
}

/// Shared input and sanity check for the key-gated live sweeps (#3425).
///
/// The sentences are real dictations from the founder's own `app.log` (Parakeet transcripts as
/// they reached the polish step: fillers, false starts, run-ons, one mis-heard word), not
/// constructed examples. A sweep passes a model only if the SHIPPED connector, building the
/// SHIPPED request for that exact model id, returns usable cleaned text for every one of them.
enum LiveSweepSupport {

  /// The sweep's key manager: the key from `envVar` when it is set (non-empty), otherwise
  /// the dev file store exactly as before. The `.legacyFiles` backend never touches the
  /// production Keychain.
  static func keychain(keyID: String, envVar: String) -> KeychainManager {
    if let value = ProcessInfo.processInfo.environment[envVar], !value.isEmpty {
      return KeychainManager(
        backend: .legacyFiles, legacyStore: EnvironmentKeyStore(values: [keyID: value]))
    }
    return KeychainManager()
  }

  /// Narrow a sweep to the models named in `EW_SWEEP_ONLY` (comma separated); every model
  /// when it is unset. For re-running just the models a finding is about.
  static func narrowed(_ models: [LLMModelInfo]) -> [LLMModelInfo] {
    guard let raw = ProcessInfo.processInfo.environment["EW_SWEEP_ONLY"], !raw.isEmpty else {
      return models
    }
    let wanted = Set(raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
    return models.filter { wanted.contains($0.id) }
  }

  static let realDictations: [String] = [
    "All that matters to the user is that hey, like it it's just gonna be better about pasting where it's supposed to paste.",
    "Also I find these black boxes really ugly. Can we do something better for the button options or toggle options?",
    "also look at the actual real code in UX and make sure that we're not missing anything. I want it fully operational.",
    "Also one other small thing, you're missing the border around the application. So it's hard to tell where the application starts and doesn't stop.",
    "And then on the selection screen when we are hitting change we shouldn't be showing the settings below. So like that should be hidden.",
    "Also think about what the statuses should read. I don't think the statuses should read live. It should be installed, not installed, key needed or key valid.",
    "So I had added a YU specific model sections. I think we should add those back to this design.",
    "Can we run a test to see how many applications answer the who has the keyboard focused correctly?",
  ]

  /// The exact prompt envelope production sends for `provider` (the `.cloudFixed` v6 system
  /// prompt via `DefaultPromptPlanner`), so a sweep measures what users get, not a stand-in.
  static func productionEnvelope(
    provider: LLMProvider, modelID: String, transcript: String
  ) -> PromptEnvelope {
    let input = PromptBuildInput(
      transcript: transcript, provider: provider, modelID: modelID, appName: nil,
      language: nil, polishVocabulary: .empty)
    return DefaultPromptPlanner().plan(input: input).envelope
  }

  /// A loose usability check for polished real dictation. Returns the problem, or nil when the
  /// text is usable. Deliberately not a quality grader: it catches an empty reply, leaked
  /// thinking or markup, a rewrite that dropped or invented most of the words, and runaway
  /// length. Whether the cleanup is GOOD is judged by Live UAT, not here.
  static func problem(input: String, output: String) -> String? {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "empty output" }
    let lowered = trimmed.lowercased()
    for artifact in ["<thinking", "</thinking", "<think>", "\"type\":\"thinking\"", "```"] {
      if lowered.contains(artifact) { return "artifact \(artifact) in output" }
    }
    if trimmed.count > Int(Double(input.count) * 1.5) + 20 { return "output far longer than input" }
    func words(_ text: String) -> Set<String> {
      Set(
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter {
          $0.count > 2
        })
    }
    let inputWords = words(input)
    guard !inputWords.isEmpty else { return nil }
    let kept = Double(inputWords.intersection(words(trimmed)).count) / Double(inputWords.count)
    // 0.5, not higher: the first sweep measured gpt-4 at 52% and gpt-3.5-turbo at 58% on one
    // sentence, ordinary paraphrasing by older models that this change did not touch.
    if kept < 0.5 { return "kept only \(Int(kept * 100))% of the input words" }
    return nil
  }

  /// Median of a list of milliseconds (empty is 0).
  static func medianMs(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[sorted.count / 2]
  }
}
