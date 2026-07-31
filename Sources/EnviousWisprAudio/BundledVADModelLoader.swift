import CoreML
import Foundation

/// Resolves and loads the Silero VAD CoreML model bundled directly into the
/// caller's own process bundle (#1224) — never through FluidAudio's
/// network-capable default `VadManager` init.
///
/// `EnviousWisprAudio` is a static framework linked into multiple executables
/// (the main app for in-process capture, and the ASR service), each with its
/// own `Bundle.main`. This loader takes the bundle explicitly
/// rather than assuming `.main` internally, so it resolves correctly no
/// matter which process is calling.
enum BundledVADModelLoader {
  enum LoadError: Error {
    case resourceNotFound
    case loadFailed(Error)
  }

  static func loadModel(in bundle: Bundle) throws -> MLModel {
    // No `subdirectory:` — Tuist's `.folderReference` embeds the referenced
    // folder directly at the top level of `Contents/Resources`, flattening
    // away its source-tree parent directories (confirmed against a real
    // built bundle: `Contents/Resources/silero-vad-....mlmodelc`, not
    // `Contents/Resources/VAD/...`). Same top-level lookup shape as the
    // existing `OutputClassifier.mlpackage` precedent
    // (`CoreMLOutputClassifier.load(resourceURL:)`).
    guard
      let url = bundle.url(
        forResource: "silero-vad-unified-256ms-v6.0.0", withExtension: "mlmodelc")
    else {
      throw LoadError.resourceNotFound
    }
    do {
      // Match the pinned FluidAudio VAD loader (`DownloadUtils.swift:301-303`).
      // Keep this heart-path policy explicit across dependency updates (#1784).
      //
      // Deliberately NOT copied from `DownloadUtils.loadModelsOnce` (#1784
      // audit, 2026-07-30): its aggregate cache-presence check, its three
      // per-model structural checks (path exists, path is a directory, contains
      // `coremldata.bin`), and — in the `loadModels` wrapper around it — the
      // delete-cache-then-redownload retry. The retry has no equivalent here
      // because this path has no download source to re-fetch from. The three
      // structural checks are REDUNDANT rather than unreachable: the `Bundle`
      // lookup above already proves the named resource exists, and
      // `MLModel(contentsOf:configuration:)` is the authority on whether the
      // compiled model is loadable — a failure surfaces as `.loadFailed`
      // carrying the real CoreML error instead of a synthesized one.
      //
      // Do not upgrade that to "corruption is impossible here." App-bundle
      // resources are covered by the code signature's resource seal, but a seal
      // is integrity EVIDENCE, not proof: bad bytes can be signed at packaging
      // time, and bytes can change after the initial validation.
      let configuration = MLModelConfiguration()
      configuration.computeUnits = .cpuAndNeuralEngine
      configuration.allowLowPrecisionAccumulationOnGPU = true
      return try MLModel(contentsOf: url, configuration: configuration)
    } catch {
      throw LoadError.loadFailed(error)
    }
  }
}
