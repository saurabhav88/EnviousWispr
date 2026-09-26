import Foundation

/// A learned-word checker adapter's signed pin (#3105), one shape for every
/// checker family (`ModelFamily.checkerBaseFamily`). Version 1 is pinned
/// inside the bundled delivery manifest and its digest. Shard order matters
/// because llama.cpp loads the first shard as entrypoint.
public struct LearnedWordCheckerContract: Codable, Sendable, Equatable {
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
  public let base: Base
}

/// Construct only after the caller has proved `baseManifest` admitted through
/// `ModelDeliveryController.isAdmitted`. This value carries the admitted pin,
/// not an independently discovered set of files.
public struct AdmittedCheckerBase: Sendable, Equatable {
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

public enum LearnedWordCheckerRefusal: Sendable, Equatable {
  case baseFamilyMismatch
  case baseRevisionMismatch
  case baseVariantMismatch
  case shardHashMismatch
  case promptTemplateMismatch
  case runtimeMismatch
}

public enum LearnedWordCheckerCompatibility: Sendable, Equatable {
  case compatible
  case refused(LearnedWordCheckerRefusal)
}

/// Pure qualification gate. Delivery admission and runtime readiness are
/// separate checks and cannot be inferred from this answer. A checker runs
/// only on the base family its own family maps to: an EG-1 adapter is never
/// pinned to S1-mini, or the reverse.
public func compatibility(
  contract: LearnedWordCheckerContract, checkerFamily: ModelFamily,
  admittedBase: AdmittedCheckerBase
) -> LearnedWordCheckerCompatibility {
  guard let required = checkerFamily.checkerBaseFamily, admittedBase.family == required else {
    return .refused(.baseFamilyMismatch)
  }
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
