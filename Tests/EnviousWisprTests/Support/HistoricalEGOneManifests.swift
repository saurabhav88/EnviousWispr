import Foundation

/// #4473: where a test reads a delivery manifest by name.
///
/// The two manifests of the llama (GGUF) EG-1 revision are not app resources any more: EG-1
/// runs on its own engine, with its own manifests. Their bytes are kept as test fixtures,
/// unchanged, because they are the revision the new full size REPLACES on a user's Mac, and
/// the suites that prove that replacement, and the single-file checker layout S1-mini still
/// uses, read them as that old revision. Every other name is a bundled app resource.
enum DeliveryManifestFiles {
  private static let historical = [
    "eg1-delivery-manifest": "eg1-llama-delivery-manifest",
    "eg1-checker-delivery-manifest": "eg1-llama-checker-delivery-manifest",
  ]

  /// The file of the manifest `name` (no extension).
  static func url(_ name: String) -> URL {
    if let fixture = historical[name] {
      return RepoRoot.sourceURL("Tests/EnviousWisprTests/ModelDelivery/Fixtures/\(fixture).json")
    }
    return RepoRoot.sourceURL("Sources/EnviousWispr/Resources/\(name).json")
  }
}
