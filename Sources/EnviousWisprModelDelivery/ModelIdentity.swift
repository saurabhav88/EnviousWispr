import Foundation

/// The model families the delivery layer can move bytes for (epic #1348).
/// Ollama is deliberately absent: its daemon owns bytes; our scope there is
/// telemetry only (contract scope guardrails).
public enum ModelFamily: String, Codable, Sendable, CaseIterable {
  case parakeet
  case whisperKit = "whisper_kit"
  case egOne = "eg_one"
}

/// Canonical identity of one deliverable model (contract §3, D2 §1).
///
/// `revision` is the BYTE pin (upstream commit SHA / our version tag);
/// `runtimeABI` is the CODE pin (the runtime build the bytes were validated
/// against). They move independently — #1339's existence proof: the FluidAudio
/// code pin and the HF model revision advanced separately. A `runtimeABI`
/// change with identical bytes never touches delivery (invariant 9); it
/// signals the backend adapter, not this layer.
public struct ModelIdentity: Hashable, Codable, Sendable {
  public let family: ModelFamily
  public let name: String
  public let revision: String
  public let variant: String
  public let runtimeABI: String

  public init(
    family: ModelFamily, name: String, revision: String, variant: String, runtimeABI: String
  ) {
    self.family = family
    self.name = name
    self.revision = revision
    self.variant = variant
    self.runtimeABI = runtimeABI
  }

  /// Filesystem-safe key for staging dirs, admission markers, and telemetry
  /// joins: `family/name-revision-variant` flattened. Revision is included so
  /// a pin bump can never alias the previous revision's marker (D2 §3 — for
  /// the shared FluidAudio install dir the marker, not the path, carries the
  /// revision binding).
  public var cacheKey: String {
    let variantSuffix = variant.isEmpty ? "" : "-\(variant)"
    return "\(family.rawValue)-\(name)-\(revision)\(variantSuffix)"
  }
}
