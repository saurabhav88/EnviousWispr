@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

/// #2809: `BundledSpeakerModelLoader` resolves and loads the four offline diarizer models
/// plus the PLDA JSON directly from a caller-supplied bundle — never through `ModelHub`
/// (which would download). What fails when this fails: speakers never work at all, on
/// every file import, silently.
///
/// A SwiftPM test target's own `Bundle.main` never carries the app target's resources, so
/// every test here builds a fixture bundle from the checked-in resources, the same pattern
/// as `BundledVADModelLoaderTests`. Symlinked rather than copied (~21 MB across four
/// models) so the suite stays fast.
@Suite("BundledSpeakerModelLoader", .tags(.productOutcome))
struct BundledSpeakerModelLoaderTests {

  private static var checkedInResourcesRoot: URL {
    RepoRoot.sourceURL("Sources/EnviousWispr/Resources")
  }

  /// A fixture bundle root containing exactly the resources named, symlinked flat at the
  /// top level — matching how Tuist's `.folderReference` actually embeds a built bundle.
  private static func makeFixtureBundle(including names: Set<String>) throws -> Bundle {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("BundledSpeakerModelLoaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let modelNames: [String] = [
      ModelNames.OfflineDiarizer.segmentation, ModelNames.OfflineDiarizer.fbank,
      ModelNames.OfflineDiarizer.embedding, ModelNames.OfflineDiarizer.pldaRho,
    ]
    for name in modelNames where names.contains(name) {
      try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("\(name).mlmodelc"),
        withDestinationURL: checkedInResourcesRoot.appendingPathComponent(
          "SpeakerModels/\(name).mlmodelc"))
    }
    if names.contains("speaker-plda-parameters") {
      try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("speaker-plda-parameters.json"),
        withDestinationURL: checkedInResourcesRoot.appendingPathComponent(
          "speaker-plda-parameters.json"))
    }
    return try #require(Bundle(path: root.path))
  }

  private static let allResourceNames: Set<String> = [
    ModelNames.OfflineDiarizer.segmentation, ModelNames.OfflineDiarizer.fbank,
    ModelNames.OfflineDiarizer.embedding, ModelNames.OfflineDiarizer.pldaRho,
    "speaker-plda-parameters",
  ]

  @Test("loads all four models plus the PLDA psi vector from a complete bundle")
  func loadsCompleteBundle() throws {
    let bundle = try Self.makeFixtureBundle(including: Self.allResourceNames)
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: bundle.bundlePath)) }

    let models = try BundledSpeakerModelLoader.load(in: bundle)

    // #2809 addendum §2.5 item 2: FBank runs on CPU, the rest use `.all` — the library's
    // own default inference policy, frozen here at the CONSTRUCTION site since nothing
    // else in this app builds these models.
    #expect(models.segmentationModel.configuration.computeUnits == .all)
    #expect(models.fbankModel.configuration.computeUnits == .cpuOnly)
    #expect(models.embeddingModel.configuration.computeUnits == .all)
    #expect(models.pldaRhoModel.configuration.computeUnits == .all)
    #expect(!models.pldaPsi.isEmpty)
  }

  @Test("throws resourceNotFound naming the missing model, not a generic failure")
  func throwsResourceNotFoundForMissingModel() throws {
    var incomplete = Self.allResourceNames
    incomplete.remove(ModelNames.OfflineDiarizer.embedding)
    let bundle = try Self.makeFixtureBundle(including: incomplete)
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: bundle.bundlePath)) }

    #expect {
      _ = try BundledSpeakerModelLoader.load(in: bundle)
    } throws: { error in
      guard case .resourceNotFound(let name) = error as? BundledSpeakerModelLoader.LoadError
      else { return false }
      return name == ModelNames.OfflineDiarizer.embedding
    }
  }

  @Test("throws resourceNotFound when the PLDA JSON is missing")
  func throwsResourceNotFoundForMissingPLDA() throws {
    var incomplete = Self.allResourceNames
    incomplete.remove("speaker-plda-parameters")
    let bundle = try Self.makeFixtureBundle(including: incomplete)
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: bundle.bundlePath)) }

    #expect(throws: BundledSpeakerModelLoader.LoadError.self) {
      try BundledSpeakerModelLoader.load(in: bundle)
    }
  }

  @Test("throws loadFailed for a truncated model directory, naming the model")
  func throwsLoadFailedForTruncatedModel() throws {
    let bundle = try Self.makeFixtureBundle(including: Self.allResourceNames)
    let root = URL(fileURLWithPath: bundle.bundlePath)
    defer { try? FileManager.default.removeItem(at: root) }

    // Replace the FBank symlink with an empty (but present) directory: CoreML must reject
    // it, proving the loader's failure is real, not an unreached code path.
    let fbankURL = root.appendingPathComponent("\(ModelNames.OfflineDiarizer.fbank).mlmodelc")
    try FileManager.default.removeItem(at: fbankURL)
    try FileManager.default.createDirectory(at: fbankURL, withIntermediateDirectories: true)

    #expect {
      _ = try BundledSpeakerModelLoader.load(in: bundle)
    } throws: { error in
      guard case .loadFailed(let name, _) = error as? BundledSpeakerModelLoader.LoadError
      else { return false }
      return name == ModelNames.OfflineDiarizer.fbank
    }
  }

  @Test("throws pldaMalformed for a JSON file that isn't the expected shape")
  func throwsPldaMalformedForBadJSON() throws {
    let bundle = try Self.makeFixtureBundle(including: Self.allResourceNames)
    let root = URL(fileURLWithPath: bundle.bundlePath)
    defer { try? FileManager.default.removeItem(at: root) }

    let pldaURL = root.appendingPathComponent("speaker-plda-parameters.json")
    try FileManager.default.removeItem(at: pldaURL)
    try Data("{}".utf8).write(to: pldaURL)

    #expect {
      _ = try BundledSpeakerModelLoader.load(in: bundle)
    } throws: { error in
      guard case .pldaMalformed = error as? BundledSpeakerModelLoader.LoadError else {
        return false
      }
      return true
    }
  }

  @Test("never reaches ModelHub — the analyzer's only entry point is initialize(models:)")
  func neverReachesModelHub() throws {
    // Named files only, not the whole directory: a silently-empty directory listing (a
    // moved file, a permissions problem) must fail loudly here, never read as "no hits".
    let names = ["BundledSpeakerModelLoader.swift", "OfflineSpeakerAnalyzer.swift"]
    // Code lines only — this file's own doc comments name these symbols in prose to
    // explain why they must never be called, which a bare substring search cannot tell
    // apart from an actual reference.
    func codeLines(of text: String) -> [String] {
      text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }
    let forbidden = ["prepareModels", "ModelHub", "OfflineDiarizerModels.load"]
    for name in names {
      let url = RepoRoot.sourceURL("Sources/EnviousWisprAudio/\(name)")
      let source = try String(contentsOf: url, encoding: .utf8)
      let code = codeLines(of: source).joined(separator: "\n")
      for symbol in forbidden {
        #expect(!code.contains(symbol), "\(name) references \(symbol) in code, not just a comment")
      }
    }
  }
}
