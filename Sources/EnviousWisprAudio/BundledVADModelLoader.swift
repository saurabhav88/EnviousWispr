import CoreML
import Foundation

/// Resolves and loads the Silero VAD CoreML model bundled directly into the
/// caller's own process bundle (#1224) — never through FluidAudio's
/// network-capable default `VadManager` init.
///
/// `EnviousWisprAudio` is a static framework linked into multiple executables
/// (the audio XPC service, and the main app's direct-capture-mode fallback),
/// each with its own `Bundle.main`. This loader takes the bundle explicitly
/// rather than assuming `.main` internally, so it resolves correctly no
/// matter which process is calling.
enum BundledVADModelLoader {
  enum LoadError: Error {
    case resourceNotFound
    case loadFailed(Error)
  }

  static func loadModel(in bundle: Bundle) throws -> MLModel {
    guard
      let url = bundle.url(
        forResource: "silero-vad-unified-256ms-v6.0.0", withExtension: "mlmodelc",
        subdirectory: "VAD")
    else {
      throw LoadError.resourceNotFound
    }
    do {
      return try MLModel(contentsOf: url, configuration: MLModelConfiguration())
    } catch {
      throw LoadError.loadFailed(error)
    }
  }
}
