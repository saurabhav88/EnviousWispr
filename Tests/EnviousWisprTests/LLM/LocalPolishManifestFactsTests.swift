import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprLocalPolish
import Foundation
import Testing

/// #4473: the one conversion from a model's manifest to the facts the local polish runtime
/// consumes. When it is wrong, the user sees AI polish refused for a valid model, or a model
/// that should have been blocked (wrong model, unknown prompt contract, insecure download)
/// allowed to start.
@Suite("Manifest facts the local polish runtime consumes (#4473)", .tags(.productOutcome))
struct LocalPolishManifestFactsTests {
  private func manifest(
    modelName: String, promptTemplateID: String, downloadURL: String = "https://example.invalid/m"
  ) -> EGOneManifest {
    EGOneManifest(
      modelName: modelName, version: "rev-a", contextTokens: 16384,
      promptTemplateID: promptTemplateID, minAppVersion: "0",
      downloadURL: URL(string: downloadURL)!)
  }

  @Test("a valid EG-1 manifest projects its values and has no blocker")
  func validEGOne() {
    let facts = manifest(modelName: "eg-1", promptTemplateID: "eg1-v2-named-language")
      .runtimeFacts(expectedModelName: "eg-1")
    #expect(
      facts
        == LocalPolishManifestFacts(
          modelName: "eg-1", revision: "rev-a", contextTokens: 16384,
          promptFamily: .egOneEnvelopeNamedLanguage, activationBlockers: []))
  }

  @Test("a valid S1-mini manifest projects its values and has no blocker")
  func validS1Mini() {
    let facts = manifest(modelName: "s1-mini", promptTemplateID: "s1-control-line-v1")
      .runtimeFacts(expectedModelName: "s1-mini")
    #expect(
      facts
        == LocalPolishManifestFacts(
          modelName: "s1-mini", revision: "rev-a", contextTokens: 16384,
          promptFamily: .s1ControlLine, activationBlockers: []))
  }

  @Test("the expected name is the selected provider's model, so a manifest cannot validate itself")
  func wrongModelIsBlocked() {
    let facts = manifest(modelName: "s1-mini", promptTemplateID: "s1-control-line-v1")
      .runtimeFacts(expectedModelName: "eg-1")
    #expect(facts.activationBlockers == ["model_name_mismatch"])
    #expect(facts.modelName == "s1-mini")
  }

  @Test("an unknown prompt contract has no prompt family and is blocked")
  func unknownTemplateIsBlocked() {
    let facts = manifest(modelName: "eg-1", promptTemplateID: "eg1-v99")
      .runtimeFacts(expectedModelName: "eg-1")
    #expect(facts.promptFamily == nil)
    #expect(facts.activationBlockers == ["unknown_prompt_template"])
  }

  @Test("every blocker is kept, in the manifest owner's order")
  func blockersKeepTheirOrder() {
    let facts = manifest(
      modelName: "other", promptTemplateID: "eg1-v99", downloadURL: "http://example.invalid/m"
    ).runtimeFacts(expectedModelName: "eg-1")
    #expect(
      facts.activationBlockers
        == ["model_name_mismatch", "unknown_prompt_template", "non_https_url"])
  }
}
