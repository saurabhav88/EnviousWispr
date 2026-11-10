import EnviousWisprCore
import EnviousWisprModelDelivery
import Foundation

/// Everything that decides WHICH local polish process runs (#4473).
///
/// Two requests with equal specs want the same process, so the coordinator leaves a resident
/// server alone; any difference (another model, other bytes, another context size, other flags,
/// another checker) is a different process and the old one stops first. Equality covers every
/// field and nothing else: the port and bearer chosen for one spawn, the readiness budget, the
/// renderer and the retry intent are execution details and live outside this type.
public struct LocalPolishLaunchSpec: Sendable, Equatable {
  /// Which engine binary serves the model.
  public enum EngineKind: Sendable, Equatable {
    case llamaServer
  }

  public let engineKind: EngineKind
  /// The logical model the work means.
  public let modelID: LocalPolishModelID
  /// The registration whose admitted bytes are served.
  public let artifactIdentity: ModelIdentity
  public let serverBinaryURL: URL
  public let modelURL: URL
  public let contextTokens: Int
  public let learnedWordAdapterURL: URL?
  /// Extra launch arguments appended after the standard set.
  public let extraArguments: [String]
  /// Arguments that belong only to the adapter, removed for fallback.
  public let learnedWordAdapterArguments: [String]

  public init(
    engineKind: EngineKind, modelID: LocalPolishModelID, artifactIdentity: ModelIdentity,
    serverBinaryURL: URL, modelURL: URL, contextTokens: Int, learnedWordAdapterURL: URL?,
    extraArguments: [String], learnedWordAdapterArguments: [String]
  ) {
    self.engineKind = engineKind
    self.modelID = modelID
    self.artifactIdentity = artifactIdentity
    self.serverBinaryURL = serverBinaryURL
    self.modelURL = modelURL
    self.contextTokens = contextTokens
    self.learnedWordAdapterURL = learnedWordAdapterURL
    self.extraArguments = extraArguments
    self.learnedWordAdapterArguments = learnedWordAdapterArguments
  }

  /// The same launch without its checker adapter: what the process manager executes when the
  /// adapter fails. It is an execution copy only; the requested spec is never replaced by it.
  func withoutLearnedWordAdapter() -> LocalPolishLaunchSpec {
    LocalPolishLaunchSpec(
      engineKind: engineKind, modelID: modelID, artifactIdentity: artifactIdentity,
      serverBinaryURL: serverBinaryURL, modelURL: modelURL, contextTokens: contextTokens,
      learnedWordAdapterURL: nil, extraArguments: extraArguments,
      learnedWordAdapterArguments: [])
  }
}
