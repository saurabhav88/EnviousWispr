import CoreML
import Foundation

/// One owner for "compile an `.mlpackage` on device, once, and keep it".
/// `MLModel.compileModel(at:)` writes a fresh `<name>_<UUID>.mlmodelc` into the
/// process temporary directory on every call and never removes it, so a caller
/// that compiles per load leaks one model-sized folder per load. This cache
/// moves the compile out of the temporary directory under a caller-supplied
/// content key and serves it on every later load.
enum CompiledModelCache {
  /// Load the compiled model from the cache, or compile the package into the
  /// cache first. Compile output lands in a temporary sibling and is moved
  /// into place atomically, so a crash mid-compile leaves no half cache.
  /// Throws the underlying error; callers map it to their own failure type.
  static func model(
    package: URL, key: String, cacheDirectory: URL, configuration: MLModelConfiguration
  ) async throws -> MLModel {
    let fm = FileManager.default
    let cached = cacheDirectory.appendingPathComponent("\(key).mlmodelc", isDirectory: true)
    if fm.fileExists(atPath: cached.path) {
      if let model = try? MLModel(contentsOf: cached, configuration: configuration) {
        pruneSuperseded(in: cacheDirectory, keeping: cached)
        return model
      }
      try? fm.removeItem(at: cached)
    }
    try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    let compiled = try await MLModel.compileModel(at: package)
    let staging = cacheDirectory.appendingPathComponent(
      "\(key).\(UUID().uuidString).tmp", isDirectory: true)
    do {
      try fm.moveItem(at: compiled, to: staging)
    } catch {
      try? fm.removeItem(at: compiled)
      throw error
    }
    do {
      try fm.moveItem(at: staging, to: cached)
    } catch {
      // A concurrent load won the race; theirs is byte-equivalent.
      try? fm.removeItem(at: staging)
      guard fm.fileExists(atPath: cached.path) else { throw error }
    }
    let model = try MLModel(contentsOf: cached, configuration: configuration)
    pruneSuperseded(in: cacheDirectory, keeping: cached)
    return model
  }

  /// A new revision compiles beside the previous one; the superseded siblings
  /// are pruned once the new compile has LOADED (cloud review P2). A prune
  /// failure is logged by absence only: the next load tries again.
  private static func pruneSuperseded(in cacheDirectory: URL, keeping current: URL) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: cacheDirectory.path) else { return }
    for name in entries where name.hasSuffix(".mlmodelc") && name != current.lastPathComponent {
      try? fm.removeItem(at: cacheDirectory.appendingPathComponent(name, isDirectory: true))
    }
  }
}
