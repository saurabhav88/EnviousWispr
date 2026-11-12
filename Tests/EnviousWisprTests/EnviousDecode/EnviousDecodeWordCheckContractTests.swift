import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// #4473 P3: the delivery manifest of a learned-word adapter in the MLX layout (two files: the
/// weights and their settings), which the EnviousDecode helper loads.
///
/// When this fails, the app admits an adapter the helper cannot load or must not load: a
/// manifest with the weights but no settings file, with a file the loader does not read, or
/// with a contract that pins another file than the weights. The helper then refuses to start
/// with it on every launch and the dictionary silently stops learning, or bytes nobody pinned
/// are loaded. Encounter: every install and update of a size's adapter. Owner: plan #4473 P3.
/// Rig: the shipped EG-1 checker manifest, rewritten into the MLX layout and signed again.
@Suite(
  "A learned-word adapter in the MLX layout is admitted only as its two pinned files (#4473)",
  .tags(.driftGuard))
struct EnviousDecodeWordCheckContractTests {
  static var resources: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/EnviousWispr/Resources", isDirectory: true)
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// A manifest's JSON with a change made and its digest computed again.
  static func signed(_ name: String, mutate: (inout [String: Any]) -> Void) throws -> Data {
    var object = try #require(
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: DeliveryManifestFiles.url(name)))
        as? [String: Any])
    mutate(&object)
    object.removeValue(forKey: "manifestDigest")
    let canonical = try JSONSerialization.data(
      withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    object["manifestDigest"] = sha256(canonical)
    return try JSONSerialization.data(withJSONObject: object)
  }

  static let weights = Data(repeating: 7, count: 4096)
  static let settings = Data(#"{"fine_tune_type":"lora","num_layers":24}"#.utf8)

  static func file(_ name: String, _ bytes: Data) -> [String: Any] {
    ["path": name, "sizeBytes": bytes.count, "sha256": sha256(bytes), "component": name]
  }

  /// The shipped EG-1 checker manifest as an MLX adapter: the two files, and a contract that
  /// pins the weights. `change` then alters it before it is signed.
  static func mlxManifest(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
    try signed("eg1-checker-delivery-manifest") { object in
      object["files"] = [
        file("adapters.safetensors", weights), file("adapter_config.json", settings),
      ]
      object["totalBytes"] = weights.count + settings.count
      var admission = object["admission"] as! [String: Any]
      admission["entrypointFile"] = "adapters.safetensors"
      object["admission"] = admission
      var contract = object["checkerContract"] as! [String: Any]
      contract["adapterFileName"] = "adapters.safetensors"
      contract["adapterSizeBytes"] = weights.count
      contract["adapterSHA256"] = sha256(weights)
      contract["format"] = "mlx-lora"
      object["checkerContract"] = contract
      change(&object)
    }
  }

  static func refused(_ data: Data) -> Bool {
    do {
      _ = try DeliveryManifest.load(from: data)
      return false
    } catch DeliveryManifest.ManifestError.structurallyInvalid(let reason) {
      return reason == "invalid learned-word checker contract"
    } catch {
      return false
    }
  }

  @Test(
    "the two-file MLX adapter is admitted with its base pin, every other set of files or pinned file is refused, and the one-file GGUF adapter is read as before"
  )
  func theMLXLayoutIsAdmittedExactlyAndGGUFIsUnchanged() throws {
    // Accepted: both files are in the manifest with their own hashes, the contract pins the
    // weights, and the base pin is checked like a GGUF adapter's.
    let manifest = try DeliveryManifest.load(from: try Self.mlxManifest())
    let contract = try #require(manifest.checkerContract)
    #expect(contract.format == "mlx-lora" && contract.adapterFileName == "adapters.safetensors")
    #expect(contract.adapterSHA256 == Self.sha256(Self.weights))
    #expect(
      manifest.files.map(\.resolvedInstallPath) == ["adapters.safetensors", "adapter_config.json"])
    #expect(
      manifest.files.map(\.sha256) == [Self.sha256(Self.weights), Self.sha256(Self.settings)])
    #expect(manifest.totalBytes == 4096 + Int64(Self.settings.count))
    let base = try DeliveryManifest.load(
      from: Data(contentsOf: DeliveryManifestFiles.url("eg1-delivery-manifest")))
    #expect(
      compatibility(
        contract: contract, checkerFamily: .egOneChecker,
        admittedBase: AdmittedCheckerBase(manifest: base, promptTemplateID: "eg1-v2-named-language")
      ) == .compatible)
    let otherBase = try DeliveryManifest.load(
      from: try Self.signed("eg1-delivery-manifest") { object in
        var identity = object["identity"] as! [String: Any]
        identity["revision"] = "next"
        object["identity"] = identity
      })
    #expect(
      compatibility(
        contract: contract, checkerFamily: .egOneChecker,
        admittedBase: AdmittedCheckerBase(
          manifest: otherBase, promptTemplateID: "eg1-v2-named-language"))
        == .refused(.baseRevisionMismatch))
    // The order of the two files does not matter; their names and number do.
    #expect(
      !Self.refused(
        try Self.mlxManifest { object in
          object["files"] = Array((object["files"] as! [[String: Any]]).reversed())
        }))

    // Refused: the weights alone.
    #expect(
      Self.refused(
        try Self.mlxManifest { object in
          object["files"] = [Self.file("adapters.safetensors", Self.weights)]
          object["totalBytes"] = Self.weights.count
        }))
    // Refused: a settings file under a name the loader does not read.
    #expect(
      Self.refused(
        try Self.mlxManifest { object in
          object["files"] = [
            Self.file("adapters.safetensors", Self.weights),
            Self.file("config.json", Self.settings),
          ]
        }))
    // Refused: a third file.
    let extra = Data("extra".utf8)
    #expect(
      Self.refused(
        try Self.mlxManifest { object in
          object["files"] = [
            Self.file("adapters.safetensors", Self.weights),
            Self.file("adapter_config.json", Self.settings), Self.file("notes.txt", extra),
          ]
          object["totalBytes"] = Self.weights.count + Self.settings.count + extra.count
        }))
    // Refused: the contract pins the settings file, or a weights hash that is not the file's.
    #expect(
      Self.refused(
        try Self.mlxManifest { object in
          var contract = object["checkerContract"] as! [String: Any]
          contract["adapterFileName"] = "adapter_config.json"
          contract["adapterSizeBytes"] = Self.settings.count
          contract["adapterSHA256"] = Self.sha256(Self.settings)
          object["checkerContract"] = contract
        }))
    #expect(
      Self.refused(
        try Self.mlxManifest { object in
          var contract = object["checkerContract"] as! [String: Any]
          contract["adapterSHA256"] = Self.sha256(Self.settings)
          object["checkerContract"] = contract
        }))
    // Refused: a format this app does not load, and the GGUF format over the two MLX files.
    for format in ["safetensors-lora", "gguf-lora", ""] {
      #expect(
        Self.refused(
          try Self.mlxManifest { object in
            var contract = object["checkerContract"] as! [String: Any]
            contract["format"] = format
            object["checkerContract"] = contract
          }), "format \(format)")
    }

    // GGUF controls: the shipped one-file manifest is read as it was, digest included; the MLX
    // format over its one file, and a second file beside it, are refused.
    let shipped = try DeliveryManifest.load(
      from: Data(
        contentsOf: DeliveryManifestFiles.url("eg1-checker-delivery-manifest")))
    #expect(
      shipped.manifestDigest == "d911630224094b506c1bf3552487a711b280f9716ed5124b76b35870f6fcd034")
    #expect(shipped.checkerContract?.format == "gguf-lora" && shipped.files.count == 1)
    #expect(!Self.refused(try Self.signed("eg1-checker-delivery-manifest") { _ in }))
    #expect(
      Self.refused(
        try Self.signed("eg1-checker-delivery-manifest") { object in
          var contract = object["checkerContract"] as! [String: Any]
          contract["format"] = "mlx-lora"
          object["checkerContract"] = contract
        }))
    #expect(
      Self.refused(
        try Self.signed("eg1-checker-delivery-manifest") { object in
          var files = object["files"] as! [[String: Any]]
          files.append(Self.file("adapter_config.json", Self.settings))
          object["files"] = files
          object["totalBytes"] = 66_094_912 + Self.settings.count
        }))
  }
}
