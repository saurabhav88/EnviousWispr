import EnviousWisprCore
import Foundation

/// Manifest describing one first-party polish model artifact (#1271).
///
/// The manifest is the HOT-SWAP contract: the runtime loads whatever the
/// manifest points at, the prompt builder is selected by
/// `promptTemplateID` (never hardcoded to one model), and the health probe
/// plus telemetry key off manifest identity. Shipping EG-2 is a new
/// manifest entry plus (at most) a new prompt-template registry row —
/// zero limb refactor.
///
/// Phase 1 ships ONE manifest as an app-bundle resource
/// (`Contents/Resources/eg1-manifest.json`, app-target resource in
/// `Project.swift`). Decoding is non-strict: unknown future fields are
/// ignored, so an older app can still read a newer manifest and fail
/// closed on `promptTemplateID` rather than on decode.
public struct EGOneManifest: Codable, Sendable, Equatable {
  /// Canonical model name. MUST equal `LLMProvider.egOneModelName` for
  /// Phase 1 — `EGOneRuntime` refuses activation on mismatch (Core and
  /// Services identify the provider's model by that fixed literal and
  /// cannot read this manifest; agreement is enforced here, the one layer
  /// that sees both).
  public let modelName: String
  /// Artifact version, e.g. "v1". Part of the on-disk filename so model
  /// updates are atomic swaps, never in-place rewrites.
  public let version: String
  /// SHA-256 of the GGUF artifact (lowercase hex). BLOCKING: a file that
  /// does not hash to this value is never served (deleted, re-downloaded).
  public let sha256: String
  /// Exact artifact size in bytes. Used for the disk-space preflight and
  /// as a cheap first-pass integrity check before hashing.
  public let sizeBytes: Int64
  /// Context window (tokens) to launch the server with (`-c`). Sized from
  /// the 2026-07-02 length-ladder data; never below the product's
  /// max-dictation needs so nothing is silently truncated.
  public let contextTokens: Int
  /// Prompt-template identity the model was TRAINED with. Maps through
  /// `promptFamily` below; an unknown value refuses activation (RED,
  /// "app update required") rather than mis-prompting a future model.
  public let promptTemplateID: String
  /// Minimum app version that can run this artifact (informational in
  /// Phase 1; enforced when remote manifests arrive).
  public let minAppVersion: String
  /// HTTPS download URL for the GGUF artifact.
  public let downloadURL: URL
  /// HTTPS URL of the EG-1 model license that governs the artifact.
  public let licenseURL: URL?

  public init(
    modelName: String, version: String, sha256: String, sizeBytes: Int64,
    contextTokens: Int, promptTemplateID: String, minAppVersion: String,
    downloadURL: URL, licenseURL: URL? = nil
  ) {
    self.modelName = modelName
    self.version = version
    self.sha256 = sha256
    self.sizeBytes = sizeBytes
    self.contextTokens = contextTokens
    self.promptTemplateID = promptTemplateID
    self.minAppVersion = minAppVersion
    self.downloadURL = downloadURL
    self.licenseURL = licenseURL
  }

  /// Prompt-template registry: manifest `promptTemplateID` → prompt family.
  /// Returns nil for unknown ids — the caller must treat that as
  /// "cannot activate", never fall back to a guessed prompt.
  public var promptFamily: PromptFamily? {
    switch promptTemplateID {
    case "eg1-v1": return .egOneFixed
    default: return nil
    }
  }

  /// On-disk artifact filename (versioned, immutable).
  public var artifactFileName: String { "\(modelName)-\(version).gguf" }

  /// Full activation validation. Returns the reasons the manifest cannot
  /// be activated by THIS app build; empty means activatable.
  public func activationBlockers() -> [String] {
    var blockers: [String] = []
    if modelName != LLMProvider.egOneModelName {
      blockers.append("model_name_mismatch")
    }
    if promptFamily == nil {
      blockers.append("unknown_prompt_template")
    }
    if downloadURL.scheme != "https" {
      blockers.append("non_https_url")
    }
    return blockers
  }

  /// Decode from a bundled resource. Non-strict (unknown fields ignored).
  public static func loadBundled(
    from bundle: Bundle = .main, resourceName: String = "eg1-manifest"
  ) throws -> EGOneManifest {
    guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
      throw EGOneManifestError.resourceMissing(resourceName)
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(EGOneManifest.self, from: data)
  }
}

public enum EGOneManifestError: Error, Sendable, Equatable {
  case resourceMissing(String)
}
