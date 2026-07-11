import Foundation
import Testing

@testable import EnviousWisprAudio

/// #1224: `BundledVADModelLoader` resolves and loads the VAD model directly
/// from a caller-supplied bundle — never through FluidAudio's network-capable
/// default `VadManager` init.
@Suite("BundledVADModelLoader")
struct BundledVADModelLoaderTests {

  /// The repo-checked-in asset this loader is meant to find in production —
  /// used here to build a fixture bundle, since a SwiftPM test target's own
  /// `Bundle.main` never bundles this XPC-only resource.
  private static var checkedInModelURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // this file's name -> .../Audio/
      .deletingLastPathComponent()  // Audio/ -> .../EnviousWisprTests/
      .deletingLastPathComponent()  // EnviousWisprTests/ -> .../Tests/
      .deletingLastPathComponent()  // Tests/ -> repo root
      .appendingPathComponent(
        "Sources/EnviousWisprAudioService/Resources/VAD/silero-vad-unified-256ms-v6.0.0.mlmodelc")
  }

  @Test("loads the model given a bundle containing the real resource")
  func loadsBundledModel() throws {
    let checkedIn = Self.checkedInModelURL
    #expect(FileManager.default.fileExists(atPath: checkedIn.path))

    // Flat, no "VAD/" subdirectory — matches how Tuist's `.folderReference`
    // actually embeds the model at the top level of Contents/Resources in a
    // real built bundle (Codex code-diff review r1 P1).
    let fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("BundledVADModelLoaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }

    try FileManager.default.copyItem(
      at: checkedIn,
      to: fixtureRoot.appendingPathComponent("silero-vad-unified-256ms-v6.0.0.mlmodelc"))

    let fixtureBundle = try #require(Bundle(path: fixtureRoot.path))
    _ = try BundledVADModelLoader.loadModel(in: fixtureBundle)
  }

  @Test("throws resourceNotFound given a bundle that does not carry the asset")
  func throwsWhenResourceMissing() {
    // The test target's own `Bundle.main` never bundles this XPC-only asset.
    #expect(throws: BundledVADModelLoader.LoadError.self) {
      try BundledVADModelLoader.loadModel(in: .main)
    }
  }
}
