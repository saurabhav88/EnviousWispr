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
      // Match the pinned FluidAudio loader's compute policy
      // (`ModelHub.swift:356-369` at fork pin bf9fe27f; the authority re-homed
      // there through upstream's download-stack unification, #1981). Keep this
      // heart-path policy explicit across dependency updates (#1784).
      //
      // Deliberately NOT copied from `ModelHub.loadModelsOnce` (#1784 audit,
      // 2026-07-30; re-verified against the new owner, #1981): its per-model
      // structural layout validation (`ModelCache.validateCompiledModelLayout`)
      // and — in the `loadModels` wrapper around it — the purge-then-redownload
      // recovery. The recovery has no equivalent here because this path has no
      // download source to re-fetch from. The structural checks are REDUNDANT
      // rather than unreachable: the `Bundle` lookup above already proves the
      // named resource exists, and `MLModel(contentsOf:configuration:)` is the
      // authority on whether the compiled model is loadable — a failure
      // surfaces as `.loadFailed` carrying the real CoreML error instead of a
      // synthesized one.
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
