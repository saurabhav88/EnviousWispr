import EnviousWisprCore
import EnviousWisprModelDelivery
import Foundation

/// What each EG-1 size is, as a delivered artifact for the EnviousDecode engine (#4473 P4).
///
/// One size is two independent deliveries:
/// - the MODEL: the polish model's folder with the draft model in its `helper` sub-folder.
///   The two are one registration, so they are admitted together or not at all: the engine
///   never sees a polish model without the draft model that was matched to it.
/// - the CHECKER: the size's learned-word adapter, admitted on its own.
///
/// This type names the six registrations and builds each from a delivery manifest it is
/// GIVEN. It reads no bundled resource and holds no address: the manifests with their
/// download sources are authored after the files are uploaded and verified. Nothing here is
/// registered at launch yet.
///
/// The engine is handed FOLDERS, not an entrypoint file. That hand-off is decided here, by
/// the manifest's runtime ABI, and never by a file name or extension: a manifest of another
/// ABI gets no folders.
public enum EGOneArtifactCatalog {
  /// The runtime ABI of every artifact the EnviousDecode helper loads.
  public static let runtimeABI = "enviousdecode-v1"
  /// The component (top path segment) that holds the draft model inside a model's folder.
  public static let draftComponent = "helper"
  /// The variant of a 6-bit MLX polish model, and of a float32 MLX checker adapter.
  public static let modelVariant = "mlx-q6"
  public static let checkerVariant = "mlx-f32"

  /// The delivered identity of one size's model or checker, and where it is installed.
  public struct Artifact: Sendable, Equatable {
    public let family: ModelFamily
    public let name: String
    public let variant: String
    /// The folder under `EnviousWispr/Models`.
    public let installFolder: String
  }

  /// The full size keeps EG-1's own family, name and folder, so an installed EG-1 is the
  /// revision it replaces. Mini and Micro are their own families with their own folders.
  public static func model(_ size: EGOneSize) -> Artifact {
    switch size {
    case .full:
      Artifact(family: .egOne, name: "eg-1", variant: modelVariant, installFolder: "eg-1")
    case .mini:
      Artifact(
        family: .egOneMini, name: "eg-1-mini", variant: modelVariant, installFolder: "eg-1-mini")
    case .micro:
      Artifact(
        family: .egOneMicro, name: "eg-1-micro", variant: modelVariant,
        installFolder: "eg-1-micro")
    }
  }

  public static func checker(_ size: EGOneSize) -> Artifact {
    switch size {
    case .full:
      Artifact(
        family: .egOneChecker, name: "eg1c", variant: checkerVariant,
        installFolder: "eg-1-checker")
    case .mini:
      Artifact(
        family: .egOneMiniChecker, name: "eg1c-mini", variant: checkerVariant,
        installFolder: "eg-1-mini-checker")
    case .micro:
      Artifact(
        family: .egOneMicroChecker, name: "eg1c-micro", variant: checkerVariant,
        installFolder: "eg-1-micro-checker")
    }
  }

  /// Why a manifest is not the artifact it is offered as. Nothing is registered.
  public enum Refusal: Error, Equatable, Sendable {
    /// Family, name, variant or runtime ABI is not this artifact's.
    case identityMismatch(expected: String, found: String)
    /// A model manifest with no file, or no draft model file, outside or inside `helper`.
    case draftModelMissing
    case polishModelMissing
    /// A checker manifest whose contract is not the MLX adapter layout.
    case checkerLayout(String)
  }

  /// The registration of one size's model, from the manifest given. The manifest must be this
  /// size's model (family, name, variant, ABI) and must hold both parts: polish model files
  /// outside `helper`, and draft model files inside it.
  public static func modelRegistration(
    _ size: EGOneSize, manifest: DeliveryManifest, appSupport: URL
  ) throws -> DeliveryRegistration {
    let artifact = model(size)
    try require(artifact, manifest.identity)
    let components = Set(manifest.files.map { topSegment($0.resolvedInstallPath) })
    guard components.contains(draftComponent) else { throw Refusal.draftModelMissing }
    guard components.count > 1 else { throw Refusal.polishModelMissing }
    return registration(artifact, manifest: manifest, appSupport: appSupport)
  }

  /// The registration of one size's checker adapter, from the manifest given. The manifest
  /// must be this size's checker and carry the MLX adapter contract; `DeliveryManifest`
  /// has already checked that contract's files and hashes when it was loaded.
  public static func checkerRegistration(
    _ size: EGOneSize, manifest: DeliveryManifest, appSupport: URL
  ) throws -> DeliveryRegistration {
    let artifact = checker(size)
    try require(artifact, manifest.identity)
    guard let contract = manifest.checkerContract else {
      throw Refusal.checkerLayout("no checker contract")
    }
    guard contract.format == LearnedWordCheckerContract.mlxLoRAFormat else {
      throw Refusal.checkerLayout("format \(contract.format)")
    }
    guard contract.base.runtimeABI == runtimeABI else {
      throw Refusal.checkerLayout("base ABI \(contract.base.runtimeABI)")
    }
    return registration(artifact, manifest: manifest, appSupport: appSupport)
  }

  /// The folders the engine launches with, for an installed model registration: the polish
  /// model's folder and the draft model's folder inside it. Nil for a manifest of another
  /// runtime ABI (a llama model is one file and is launched through its entrypoint). The
  /// caller must have proved the registration admitted; this reads nothing from disk.
  public static func launchFolders(for registration: DeliveryRegistration)
    -> (model: URL, draft: URL)?
  {
    guard registration.manifest.identity.runtimeABI == runtimeABI,
      registration.manifest.identity.family.checkerBaseFamily == nil
    else { return nil }
    return (
      registration.installDirectory,
      registration.installDirectory.appendingPathComponent(draftComponent, isDirectory: true)
    )
  }

  /// The folder the helper is told for an installed checker registration (it holds the
  /// adapter's weights and settings files). Nil for a manifest that is not an MLX checker.
  public static func checkerFolder(for registration: DeliveryRegistration) -> URL? {
    guard registration.manifest.identity.runtimeABI == runtimeABI,
      registration.manifest.checkerContract?.format == LearnedWordCheckerContract.mlxLoRAFormat
    else { return nil }
    return registration.installDirectory
  }

  // MARK: - The engine

  /// The helper's limit on MLX's reusable buffer cache: 256 MiB, the value every speed and
  /// qualification receipt of the helper was recorded with. It bounds the cache MLX keeps for
  /// reuse between requests; it is not a limit on the process's total memory.
  public static let cacheLimitBytes = 256 * 1024 * 1024

  /// The engine for one size's registered model. The draft model is the `helper` folder of the
  /// same package, so its identity is the model registration's own: the two are admitted
  /// together.
  public static func engine(for registration: DeliveryRegistration) -> EnviousDecodeEngine {
    EnviousDecodeEngine(
      draftModelURL: registration.installDirectory.appendingPathComponent(
        draftComponent, isDirectory: true),
      draftArtifactIdentity: registration.manifest.identity, cacheLimitBytes: cacheLimitBytes)
  }

  /// The engine of a size whose manifest could not be read (a damaged app bundle). Its runtime
  /// has no delivery, so it never launches anything; this only gives that runtime an engine of
  /// the right kind, with the size's own folder and no revision.
  public static func unregisteredEngine(_ size: EGOneSize, appSupport: URL) -> EnviousDecodeEngine {
    let artifact = model(size)
    return EnviousDecodeEngine(
      draftModelURL: appSupport.appendingPathComponent("EnviousWispr/Models", isDirectory: true)
        .appendingPathComponent(artifact.installFolder, isDirectory: true)
        .appendingPathComponent(draftComponent, isDirectory: true),
      draftArtifactIdentity: ModelIdentity(
        family: artifact.family, name: artifact.name, revision: "", variant: artifact.variant,
        runtimeABI: runtimeABI),
      cacheLimitBytes: cacheLimitBytes)
  }

  // MARK: - Private

  private static func require(_ artifact: Artifact, _ identity: ModelIdentity) throws {
    let expected =
      "\(artifact.family.rawValue)/\(artifact.name)/\(artifact.variant)/\(runtimeABI)"
    let found =
      "\(identity.family.rawValue)/\(identity.name)/\(identity.variant)/\(identity.runtimeABI)"
    guard expected == found, !identity.revision.isEmpty else {
      throw Refusal.identityMismatch(expected: expected, found: found)
    }
  }

  private static func topSegment(_ path: String) -> String {
    path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
  }

  private static func registration(
    _ artifact: Artifact, manifest: DeliveryManifest, appSupport: URL
  ) -> DeliveryRegistration {
    let root = appSupport.appendingPathComponent("EnviousWispr", isDirectory: true)
    return DeliveryRegistration(
      manifest: manifest,
      installDirectory: root.appendingPathComponent("Models", isDirectory: true)
        .appendingPathComponent(artifact.installFolder, isDirectory: true),
      metadataDirectory: root.appendingPathComponent("ModelDelivery", isDirectory: true))
  }
}
