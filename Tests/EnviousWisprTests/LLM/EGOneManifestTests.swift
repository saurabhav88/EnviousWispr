import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM

/// EG-1 manifest contract + the stub-URL ship guard (#1271).
@Suite("EGOneManifest (#1271)")
struct EGOneManifestTests {

  /// The display label the SHIPPED manifest must carry, paired with the
  /// revision it belongs to. The revision is in the NAME deliberately: when
  /// the pin moves, this constant has to be renamed as well as revalued, so
  /// the pairing cannot be updated by half.
  private static let expectedDisplayVersionForV3EG2 = "1.1"

  static func makeManifest(
    modelName: String = "eg-1",
    promptTemplateID: String = "eg1-v1",
    downloadURL: String = "https://models.enviouslabs.co/eg1/eg-1-v1-q5km.gguf"
  ) -> EGOneManifest {
    EGOneManifest(
      modelName: modelName, version: "v1",
      contextTokens: 32768, promptTemplateID: promptTemplateID,
      minAppVersion: "2.3.0", downloadURL: URL(string: downloadURL)!)
  }

  @Test func knownTemplateMapsToEGOneFixed() {
    #expect(Self.makeManifest().promptFamily == .egOneFixed)
  }

  // MARK: - displayVersion (#2109)

  /// The load-bearing invariant of the whole feature: `displayVersion` is
  /// COSMETIC and must never reach a path. `artifactFileName` is built from
  /// `version`, and if a future edit ever swapped them the app would look for
  /// a file that does not exist. Asserted with the two deliberately
  /// DISAGREEING so a swap cannot pass.
  @Test func displayVersionNeverReachesTheArtifactFileName() {
    let manifest = EGOneManifest(
      modelName: "eg-1", version: "v3-eg2",
      contextTokens: 16384, promptTemplateID: "eg1-v1",
      minAppVersion: "2.3.0",
      downloadURL: URL(string: "https://models.enviouslabs.co/eg1/x.gguf")!,
      displayVersion: "1.1")

    #expect(manifest.artifactFileName == "eg-1-v3-eg2.gguf")
    #expect(!manifest.artifactFileName.contains("1.1"))
  }

  /// A manifest WITHOUT the key must decode, not throw: every build that
  /// predates the field, and any malformed bundle, has to keep working.
  @Test func decodesWithoutDisplayVersion() throws {
    let json = """
      {"modelName":"eg-1","version":"v3-eg2","contextTokens":16384,
       "promptTemplateID":"eg1-v1","minAppVersion":"2.3.0",
       "downloadURL":"https://models.enviouslabs.co/eg1/x.gguf"}
      """
    let manifest = try JSONDecoder().decode(EGOneManifest.self, from: Data(json.utf8))
    #expect(manifest.displayVersion == nil)
    #expect(manifest.resolvedDisplayVersion == nil)
  }

  @Test func decodesWithDisplayVersion() throws {
    let json = """
      {"modelName":"eg-1","version":"v3-eg2","contextTokens":16384,
       "promptTemplateID":"eg1-v1","minAppVersion":"2.3.0",
       "downloadURL":"https://models.enviouslabs.co/eg1/x.gguf",
       "displayVersion":"1.1"}
      """
    let manifest = try JSONDecoder().decode(EGOneManifest.self, from: Data(json.utf8))
    #expect(manifest.resolvedDisplayVersion == "1.1")
  }

  /// Blank-after-trimming is absent, not a label. A manifest carrying `""`
  /// or `"  "` would otherwise paint an empty string next to "EG-1".
  @Test(arguments: ["", "   ", "\n"])
  func blankDisplayVersionResolvesToNoLabel(_ raw: String) {
    let manifest = EGOneManifest(
      modelName: "eg-1", version: "v3-eg2",
      contextTokens: 16384, promptTemplateID: "eg1-v1",
      minAppVersion: "2.3.0",
      downloadURL: URL(string: "https://models.enviouslabs.co/eg1/x.gguf")!,
      displayVersion: raw)
    #expect(manifest.resolvedDisplayVersion == nil)
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
    // sha256/sizeBytes removed (#1417 §3.6): dead fields with no runtime
    // reader, superseded by the delivery manifest's own per-shard
    // verification (ManifestFetchTask/CacheAdmission, contract invariant 1).
    #expect(manifest.modelName == LLMProvider.egOneModelName)
    #expect(manifest.promptFamily != nil)
    #expect(manifest.activationBlockers().isEmpty)

    // #2109: the shipped manifest must carry a renderable display version.
    // Its ABSENCE is the malformed-build case the settings row silently
    // tolerates by showing no label — which is right at runtime and wrong to
    // ship, so it is caught here instead.
    #expect(manifest.resolvedDisplayVersion != nil)

    // Pinned to the literal, deliberately. This CANNOT establish that "1.1"
    // is the correct label for revision `v3-eg2` — that correspondence is a
    // founder decision, not a derivable fact, and the plan records it as an
    // accepted known limit (§14 Q3). What it does establish is that the two
    // cannot drift apart silently: changing the manifest without changing
    // this line, or the reverse, fails here.
    #expect(manifest.resolvedDisplayVersion == Self.expectedDisplayVersionForV3EG2)
    #expect(manifest.version == "v3-eg2")
  }
}
