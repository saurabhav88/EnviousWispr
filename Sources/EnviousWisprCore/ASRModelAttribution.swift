import Foundation

/// Which speech model a load, a take or a file import used (#3546 plan §3.7 T1).
///
/// The same vocabulary as `model_delivery.model_name`: the delivery manifest's
/// identity name, its revision cut to eight characters, and its variant. The
/// name alone could not tell the two retired WhisperKit manifests apart (they shared name
/// and revision and differed by variant), so the variant travels too.
///
/// `public` because the `TelemetryService` emitters that carry it are public.
public struct ASRModelIdentity: Sendable, Equatable, Codable {
  public let name: String
  /// The first eight characters of the manifest revision, or `nil` when no
  /// manifest named one. Never a placeholder.
  public let revision: String?
  public let variant: String?

  public init(name: String, revision: String?, variant: String?) {
    self.name = name
    self.revision = revision.map { String($0.prefix(8)) }
    self.variant = variant
  }
}

/// A model identity plus how far the work using it got (#3546 plan §3.7 T1).
///
/// `loaded` is true only once that identity was published as ready; a request
/// that never loaded reports `false`. `inferenceReached` is true only once
/// audio entered that model's inference, so an early failure is never reported
/// as exposure to the model.
public struct ASRModelAttribution: Sendable, Equatable {
  public let identity: ASRModelIdentity
  public let loaded: Bool
  public let inferenceReached: Bool

  public init(identity: ASRModelIdentity, loaded: Bool, inferenceReached: Bool) {
    self.identity = identity
    self.loaded = loaded
    self.inferenceReached = inferenceReached
  }

  /// The exact telemetry keys. A missing revision or variant is omitted,
  /// never sent as an empty string.
  public var telemetryProperties: [String: Any] {
    var props: [String: Any] = [
      "asr_model": identity.name,
      "asr_model_loaded": loaded,
      "asr_model_inference_reached": inferenceReached,
    ]
    if let revision = identity.revision { props["asr_model_revision"] = revision }
    if let variant = identity.variant { props["asr_model_variant"] = variant }
    return props
  }

  /// Every key `telemetryProperties` can write, for allowlists and hooks.
  public static let telemetryKeys: [String] = [
    "asr_model", "asr_model_revision", "asr_model_variant", "asr_model_loaded",
    "asr_model_inference_reached",
  ]
}

extension ParakeetModel {
  /// The delivery manifest identity name. A test pins it to both bundled
  /// Parakeet manifests.
  package var manifestName: String {
    switch self {
    case .v3: "parakeet-tdt-0.6b-v3-coreml"
    case .ultra: "parakeet-ultra-coreml"
    }
  }

  /// The delivery manifest variant, pinned the same way.
  package var manifestVariant: String { "int8" }
}

extension ParakeetModelSelection {
  /// The identity this request names.
  package var modelIdentity: ASRModelIdentity {
    ASRModelIdentity(name: model.manifestName, revision: revision, variant: model.manifestVariant)
  }
}
