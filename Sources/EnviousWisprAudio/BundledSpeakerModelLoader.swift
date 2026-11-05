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
package enum BundledSpeakerModelLoader {
  package enum LoadError: Error {
    case resourceNotFound(String)
    case loadFailed(String, Error)
    case pldaMalformed
  }

  /// The PLDA JSON's name in the bundle, renamed from the vendor's generic
  /// `plda-parameters.json` so nothing generic sits at the bundle root (#2809).
  static let pldaResourceName = "speaker-plda-parameters"

  package static func load(in bundle: Bundle) throws -> OfflineDiarizerModels {
    let start = CFAbsoluteTimeGetCurrent()

    // Segmentation, embedding and PLDA use `.all`; FBank follows `fbankComputeUnits`.
    let segmentationModel = try loadModel(
      named: ModelNames.OfflineDiarizer.segmentation, in: bundle, computeUnits: .all)
    let fbankModel = try loadModel(
      named: ModelNames.OfflineDiarizer.fbank, in: bundle,
      computeUnits: fbankComputeUnits(ProcessInfo.processInfo.operatingSystemVersion))
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

  /// #4376: FBank on the CPU-only path runs through Apple's BNNS, which on macOS 14 corrupts
  /// memory (FluidInference/FluidAudio#878, fixed in macOS 15). Measured on an M1 Mac mini,
  /// macOS 14.8.9, with the bundled models and the default diarizer config on a two-voice clip:
  /// `.cpuOnly` FBank crashed 22 of 30 runs (EXC_BAD_ACCESS in BNNSGraphContextExecute_v2) and
  /// every run that finished found 1 speaker; `.cpuAndGPU` and `.all` finished 50 of 50 each
  /// with 2 speakers. So macOS 14 keeps FBank off the CPU-only path. macOS 15 and later keep
  /// `.cpuOnly`, the vendor's default (the M1 runs that finished took 0.43 s vs 0.77 s per 30 s).
  /// Probe: AgentArtifacts run `20261104-201708-4376-bnns-probe-0fcb`.
  package static func fbankComputeUnits(_ os: OperatingSystemVersion) -> MLComputeUnits {
    os.majorVersion < 15 ? .cpuAndGPU : .cpuOnly
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
