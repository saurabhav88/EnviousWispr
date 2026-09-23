import Foundation

/// Version 1 is pinned inside the bundled delivery manifest and its digest.
/// Shard order matters because llama.cpp loads the first shard as entrypoint.
public struct EGOneCheckerContract: Codable, Sendable, Equatable {
  public struct Base: Codable, Sendable, Equatable {
    public let revision: String
    public let variant: String
    public let shardSHA256: [String]
    public let promptTemplateID: String
    public let runtimeABI: String
  }

  public let version: Int
  public let adapterFileName: String
  public let adapterSizeBytes: Int64
  public let adapterSHA256: String
  public let format: String
  /// String keeps manifest canonicalization exact across Swift and authoring tools.
  public let qualifiedThreshold: String
  public let qualifiedLanguages: [String]
  public let base: Base
}

/// Construct only after the caller has proved `baseManifest` admitted through
/// `ModelDeliveryController.isAdmitted`. This value carries the admitted pin,
/// not an independently discovered set of files.
public struct AdmittedEGOneBase: Sendable, Equatable {
  public let family: ModelFamily
  public let revision: String
  public let variant: String
  public let shardSHA256: [String]
  public let promptTemplateID: String
  public let runtimeABI: String

  public init(manifest: DeliveryManifest, promptTemplateID: String) {
    family = manifest.identity.family
    revision = manifest.identity.revision
    variant = manifest.identity.variant
    shardSHA256 = manifest.files.map(\.sha256)
    self.promptTemplateID = promptTemplateID
    runtimeABI = manifest.identity.runtimeABI
  }
}

public enum EGOneCheckerRefusal: Sendable, Equatable {
  case baseFamilyMismatch
  case baseRevisionMismatch
  case baseVariantMismatch
  case shardHashMismatch
  case promptTemplateMismatch
  case runtimeMismatch
}

public enum EGOneCheckerCompatibility: Sendable, Equatable {
  case compatible
  case refused(EGOneCheckerRefusal)
}

/// Pure qualification gate. Delivery admission and runtime readiness are
/// separate checks and cannot be inferred from this answer.
public func compatibility(
  contract: EGOneCheckerContract, admittedBase: AdmittedEGOneBase
) -> EGOneCheckerCompatibility {
  guard admittedBase.family == .egOne else { return .refused(.baseFamilyMismatch) }
  guard admittedBase.revision == contract.base.revision else {
    return .refused(.baseRevisionMismatch)
  }
  guard admittedBase.variant == contract.base.variant else {
    return .refused(.baseVariantMismatch)
  }
  guard admittedBase.shardSHA256 == contract.base.shardSHA256 else {
    return .refused(.shardHashMismatch)
  }
  guard admittedBase.promptTemplateID == contract.base.promptTemplateID else {
    return .refused(.promptTemplateMismatch)
  }
  guard admittedBase.runtimeABI == contract.base.runtimeABI else {
    return .refused(.runtimeMismatch)
  }
  return .compatible
}
