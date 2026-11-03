import EnviousWisprCore
import Foundation

/// The cloud model one surface last had for each cloud provider (#4353 D1).
///
/// One `llmModel` field per surface used to serve every cloud provider, so a provider round
/// trip (OpenAI → Claude → OpenAI) refilled the provider default and the user's pick was lost.
/// `SettingsManager` keeps one of these per surface (dictation, Transcribe a File, meeting
/// summaries) and restores from it on a provider change.
///
/// Only OpenAI, Gemini and Claude have entries, and an entry must look like that provider's
/// id. The shape check alone is not enough: `modelIDLooksLikeCloudProvider` answers `true`
/// for every non-cloud provider, so the provider is restricted first.
///
/// Ids are kept byte-for-byte, including retired ids: deciding whether an id still works is
/// not this type's job.
///
/// Persisted as a bare JSON object keyed by provider raw value (`{"openAI":"gpt-6-luna"}`).
public struct CloudModelMemory: Equatable, Sendable, Codable {
  public static let cloudProviders: Set<LLMProvider> = [.openAI, .gemini, .claude]

  private var entries: [String: String]

  public init() { entries = [:] }

  /// The remembered id for `provider`, or `nil` when this surface never had one.
  public func model(for provider: LLMProvider) -> String? {
    entries[provider.rawValue]
  }

  /// Whether `model` may be remembered for `provider`.
  public static func accepts(_ model: String, for provider: LLMProvider) -> Bool {
    cloudProviders.contains(provider) && !model.isEmpty
      && LLMProvider.modelIDLooksLikeCloudProvider(model, provider)
  }

  /// Remembers `model` for `provider`. Returns `false` and changes nothing when the pair is
  /// not acceptable.
  @discardableResult
  public mutating func record(_ model: String, for provider: LLMProvider) -> Bool {
    guard Self.accepts(model, for: provider) else { return false }
    entries[provider.rawValue] = model
    return true
  }

  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode([String: String].self)
    // A stored entry this build cannot use (an unknown provider, a foreign id) is dropped
    // rather than failing the whole memory.
    var memory = CloudModelMemory()
    for (key, model) in raw {
      if let provider = LLMProvider(rawValue: key) { memory.record(model, for: provider) }
    }
    self = memory
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(entries)
  }
}
