import CoreML
import FluidAudio
import Foundation

/// Constructs the offline diarizer's models by hand from the bundled `.mlmodelc` folders,
/// never through `ModelHub` (#2809). `OfflineDiarizerModels.init` is public and the vendor
/// documents manual `MLModel(contentsOf:)` construction for bundled assets — this loader
/// never calls `OfflineDiarizerModels.load`, `ModelHub.loadModels`, or `prepareModels`, so it
/// can neither read nor write `ModelHub.offlineMode` and never touches the network.
///
/// Same shape as `BundledVADModelLoader`: takes the caller's `Bundle` explicitly (this
/// framework links into more than one process), no `subdirectory:` lookup because Tuist's
/// `.folderReference` embeds each `.mlmodelc` at the top level of `Contents/Resources`.
enum BundledSpeakerModelLoader {
  enum LoadError: Error {
    case resourceNotFound(String)
    case loadFailed(String, Error)
    case pldaMalformed
  }

  /// The PLDA JSON's name in the bundle, renamed from the vendor's generic
  /// `plda-parameters.json` so nothing generic sits at the bundle root (#2809).
  static let pldaResourceName = "speaker-plda-parameters"

  static func load(in bundle: Bundle) throws -> OfflineDiarizerModels {
    let start = CFAbsoluteTimeGetCurrent()

    // FBank runs faster on CPU (the vendor's own default loader policy,
    // `OfflineDiarizerModels.swift`); segmentation, embedding and PLDA use `.all`.
    let segmentationModel = try loadModel(
      named: ModelNames.OfflineDiarizer.segmentation, in: bundle, computeUnits: .all)
    let fbankModel = try loadModel(
      named: ModelNames.OfflineDiarizer.fbank, in: bundle, computeUnits: .cpuOnly)
    let embeddingModel = try loadModel(
      named: ModelNames.OfflineDiarizer.embedding, in: bundle, computeUnits: .all)
    let pldaRhoModel = try loadModel(
      named: ModelNames.OfflineDiarizer.pldaRho, in: bundle, computeUnits: .all)
    let pldaPsi = try loadPLDAPsi(in: bundle)

    return OfflineDiarizerModels(
      segmentationModel: segmentationModel,
      fbankModel: fbankModel,
      embeddingModel: embeddingModel,
      pldaRhoModel: pldaRhoModel,
      pldaPsi: pldaPsi,
      compilationDuration: CFAbsoluteTimeGetCurrent() - start
    )
  }

  private static func loadModel(
    named name: String, in bundle: Bundle, computeUnits: MLComputeUnits
  ) throws -> MLModel {
    guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
      throw LoadError.resourceNotFound(name)
    }
    do {
      let configuration = MLModelConfiguration()
      configuration.computeUnits = computeUnits
      return try MLModel(contentsOf: url, configuration: configuration)
    } catch {
      throw LoadError.loadFailed(name, error)
    }
  }

  /// Mirrors the vendor's own private `OfflineDiarizerModels.loadPLDAPsi`: the JSON is
  /// `{"tensors": {"psi": {"data_base64": "..."}}}`, the decoded bytes are little-endian
  /// Float32 (native byte order on Apple Silicon), widened to `Double` for the vendor's
  /// `pldaPsi: [Double]`. Kept as our own 20-line parser because the vendor's version reads
  /// from a DIRECTORY path list, never a bundle resource (#2809).
  private static func loadPLDAPsi(in bundle: Bundle) throws -> [Double] {
    guard let url = bundle.url(forResource: pldaResourceName, withExtension: "json") else {
      throw LoadError.resourceNotFound(pldaResourceName)
    }
    guard
      let data = try? Data(contentsOf: url),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tensors = root["tensors"] as? [String: Any],
      let psi = tensors["psi"] as? [String: Any],
      let base64 = psi["data_base64"] as? String,
      let decoded = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters])
    else {
      throw LoadError.pldaMalformed
    }
    let floatCount = decoded.count / MemoryLayout<Float>.size
    guard floatCount > 0, floatCount * MemoryLayout<Float>.size == decoded.count else {
      throw LoadError.pldaMalformed
    }
    var floats = [Float](repeating: 0, count: floatCount)
    _ = floats.withUnsafeMutableBytes { destination in
      decoded.copyBytes(to: destination)
    }
    return floats.map(Double.init)
  }
}
