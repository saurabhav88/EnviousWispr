import Foundation
import MLX
import MLXLMCommon
import MLXNN

// #4473 P2: loads a DFlash draft model from a local folder, strictly. The draft proposes the
// tokens that the polish model then checks. A draft that loads with a tensor missing, extra or
// wrongly shaped keeps freshly initialised weights somewhere, drafts nonsense, and the engine
// only looks slow, because every wrong draft is rejected. So a folder that is not exactly the
// model its configuration describes does not load at all.

/// The library's loader takes any `BaseLanguageModel`. The draft's own `sanitize(weights:)`
/// (the identity) satisfies it; nothing is renamed and nothing is dropped.
extension DFlashDraftModel: BaseLanguageModel {}

enum DFlashDraftLoadError: Error, Equatable {
  /// The folder holds no `.safetensors` file.
  case noWeightFiles
  /// Two weight files in the folder hold a tensor of the same name.
  case duplicateTensor(String)
  /// The weight files hold tensors the model has no place for.
  case unexpectedTensors([String])
}

enum DFlashDraftLoader {
  static let configurationFileName = "config.json"

  /// Reads `config.json`, builds the model, loads every `.safetensors` file in `directory` and
  /// returns the model evaluated. Local files only: no download, no model-name lookup, no
  /// fallback model.
  static func load(from directory: URL) throws -> DFlashDraftModel {
    let configurationData = try Data(
      contentsOf: directory.appendingPathComponent(configurationFileName))
    let decoder = JSONDecoder()
    let configuration = try decoder.decode(DFlashDraftConfiguration.self, from: configurationData)
    // The same file read as the library reads any model's: its quantization blocks, if present.
    let base = try decoder.decode(BaseConfiguration.self, from: configurationData)
    let model = DFlashDraftModel(configuration)

    let suppliedNames = try tensorNames(in: directory)

    // Before the library sees the files: every supplied tensor must have a place in the model
    // as the configuration builds it. The library's update does not report a tensor for a
    // layer index past the model's layer count; it stops the whole process there (its
    // missing-key pass forms a range from the longer list to the shorter one). A quantized
    // layer stores `scales` and `biases` beside its `weight`, so those two names are accepted
    // here where the layer's `weight` is a parameter; the library's check below settles them.
    let declaredNames = Set(model.parameters().flattened().map { $0.0 })
    let unplaced = suppliedNames.filter { name in
      if declaredNames.contains(name) { return false }
      for suffix in [".scales", ".biases"] where name.hasSuffix(suffix) {
        return !declaredNames.contains(name.dropLast(suffix.count) + ".weight")
      }
      return true
    }.sorted()
    guard unplaced.isEmpty else { throw DFlashDraftLoadError.unexpectedTensors(unplaced) }

    // The library's loader: every file in the folder (so no file is picked over another by
    // name), quantization as the configuration states it, and `verify: [.all]`, which refuses
    // an unknown tensor, a missing parameter and a wrong shape. It also evaluates the model.
    try loadWeights(
      modelDirectory: directory, model: model, quantization: base.quantization,
      perLayerQuantization: base.perLayerQuantization, weightFileSelection: .allFilesPresent)
    return model
  }

  /// The tensor names in the folder's top-level `.safetensors` files: the same files the
  /// library loads for `.allFilesPresent`. Reading the names does not read the tensor data.
  static func tensorNames(in directory: URL) throws -> Set<String> {
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "safetensors" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    guard !files.isEmpty else { throw DFlashDraftLoadError.noWeightFiles }

    var names = Set<String>()
    for file in files {
      for name in try loadArrays(url: file).keys.sorted() {
        guard names.insert(name).inserted else {
          throw DFlashDraftLoadError.duplicateTensor(name)
        }
      }
    }
    return names
  }
}
