import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// EG-1 manifest contract + the stub-URL ship guard (#1271).
@Suite("EGOneManifest (#1271)")
struct EGOneManifestTests {

  static func makeManifest(
    modelName: String = "eg-1",
    promptTemplateID: String = "eg1-v1",
    downloadURL: String = "https://models.enviouslabs.co/eg1/eg-1-v1-q5km.gguf"
  ) -> EGOneManifest {
    EGOneManifest(
      modelName: modelName, version: "v1", sha256: String(repeating: "a", count: 64),
      sizeBytes: 1000, contextTokens: 32768, promptTemplateID: promptTemplateID,
      minAppVersion: "2.3.0", downloadURL: URL(string: downloadURL)!)
  }

  @Test func knownTemplateMapsToEGOneFixed() {
    #expect(Self.makeManifest().promptFamily == .egOneFixed)
  }

  @Test func unknownTemplateRefusesActivation() {
    let manifest = Self.makeManifest(promptTemplateID: "eg2-v1")
    #expect(manifest.promptFamily == nil)
    #expect(manifest.activationBlockers().contains("unknown_prompt_template"))
  }

  @Test func modelNameMismatchRefusesActivation() {
    let manifest = Self.makeManifest(modelName: "eg-2")
    #expect(manifest.activationBlockers().contains("model_name_mismatch"))
  }

  @Test func nonHTTPSRefusesActivation() {
    let manifest = Self.makeManifest(downloadURL: "http://models.enviouslabs.co/x.gguf")
    #expect(manifest.activationBlockers().contains("non_https_url"))
  }

  @Test func validManifestHasNoBlockers() {
    #expect(Self.makeManifest().activationBlockers().isEmpty)
  }

  @Test func decodeIgnoresUnknownFutureFields() throws {
    let json = """
      {"modelName":"eg-1","version":"v1","sha256":"\(String(repeating: "b", count: 64))",
       "sizeBytes":5,"contextTokens":32768,"promptTemplateID":"eg1-v1",
       "minAppVersion":"2.3.0","downloadURL":"https://models.enviouslabs.co/x.gguf",
       "futureField":"ignored","anotherThing":42}
      """
    let manifest = try JSONDecoder().decode(EGOneManifest.self, from: Data(json.utf8))
    #expect(manifest.modelName == "eg-1")
  }

  @Test func artifactFileNameIsVersioned() {
    #expect(Self.makeManifest().artifactFileName == "eg-1-v1.gguf")
  }

  // MARK: - Stub-URL ship guard (#1271, Gate 2)

  /// Parse the CHECKED-IN manifest from its repo path (the same
  /// parse-the-file-directly mechanism the architecture ceilings/freeze
  /// tests use — no Bundle access, runs under plain SwiftPM/CI) and assert
  /// a release can never carry a placeholder: HTTPS, approved first-party
  /// host, real-looking hash and size, known template, canonical name.
  @Test func shippedManifestIsNotAStub() throws {
    let thisFile = URL(fileURLWithPath: #filePath)
    let repoRoot =
      thisFile
      .deletingLastPathComponent()  // LLM
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
    let manifestURL = repoRoot.appendingPathComponent(
      "Sources/EnviousWispr/Resources/eg1-manifest.json")
    let data = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(EGOneManifest.self, from: data)

    #expect(manifest.downloadURL.scheme == "https")
    #expect(manifest.downloadURL.host == "models.enviouslabs.co")
    let forbidden = ["stub", "example", "invalid", "localhost", "placeholder"]
    for token in forbidden {
      #expect(!manifest.downloadURL.absoluteString.lowercased().contains(token))
    }
    #expect(manifest.sha256.count == 64)
    #expect(manifest.sha256.allSatisfy { $0.isHexDigit })
    // Not a degenerate hash (all one character = placeholder smell).
    #expect(Set(manifest.sha256).count > 4)
    #expect(manifest.sizeBytes > 1_000_000_000)  // a real 4B-model GGUF
    #expect(manifest.modelName == LLMProvider.egOneModelName)
    #expect(manifest.promptFamily != nil)
    #expect(manifest.activationBlockers().isEmpty)
  }
}
