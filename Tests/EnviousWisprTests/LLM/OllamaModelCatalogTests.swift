import Foundation
import Testing

@testable import EnviousWisprLLM

@Suite("OllamaModelCatalog")
struct OllamaModelCatalogTests {

  // MARK: - Parameter Size Parsing

  @Test("parses standard billion values")
  func parsesBillions() {
    #expect(OllamaSetupService.parseParameterSize("3B") == 3.0)
    #expect(OllamaSetupService.parseParameterSize("7B") == 7.0)
    #expect(OllamaSetupService.parseParameterSize("70B") == 70.0)
  }

  @Test("parses fractional billion values")
  func parsesFractionalBillions() {
    #expect(OllamaSetupService.parseParameterSize("3.2B") == 3.2)
    #expect(OllamaSetupService.parseParameterSize("1.1B") == 1.1)
    #expect(OllamaSetupService.parseParameterSize("3.8B") == 3.8)
  }

  @Test("parses million values as fractional billions")
  func parsesMillions() {
    let result = OllamaSetupService.parseParameterSize("500M")
    #expect(result != nil)
    #expect(abs(result! - 0.5) < 0.001)

    let result2 = OllamaSetupService.parseParameterSize("125M")
    #expect(result2 != nil)
    #expect(abs(result2! - 0.125) < 0.001)
  }

  @Test("parses trillion values")
  func parsesTrillion() {
    #expect(OllamaSetupService.parseParameterSize("1T") == 1000.0)
    #expect(OllamaSetupService.parseParameterSize("1.5T") == 1500.0)
  }

  @Test("returns nil for invalid input")
  func parsesInvalid() {
    #expect(OllamaSetupService.parseParameterSize("") == nil)
    #expect(OllamaSetupService.parseParameterSize("abc") == nil)
    #expect(OllamaSetupService.parseParameterSize("B") == nil)
    #expect(OllamaSetupService.parseParameterSize("3X") == nil)
  }

  @Test("handles case insensitivity")
  func parsesCaseInsensitive() {
    #expect(OllamaSetupService.parseParameterSize("3b") == 3.0)
    #expect(OllamaSetupService.parseParameterSize("500m") != nil)
  }

  // MARK: - Canonical Name

  @Test("strips :latest suffix")
  func canonicalStripsLatest() {
    #expect(OllamaSetupService.canonicalModelName("llama3.2:latest") == "llama3.2")
  }

  @Test("preserves other tags")
  func canonicalPreservesTags() {
    #expect(OllamaSetupService.canonicalModelName("llama3.2:1b") == "llama3.2:1b")
    #expect(OllamaSetupService.canonicalModelName("qwen2.5:7b") == "qwen2.5:7b")
  }

  @Test("bare name stays unchanged")
  func canonicalBareName() {
    #expect(OllamaSetupService.canonicalModelName("mistral") == "mistral")
  }

  // MARK: - Weak Model Detection

  @Test("models under 3B are weak when parameter size is known")
  func weakByParameterSize() {
    #expect(OllamaSetupService.isWeakModel("anything", parameterBillions: 1.1) == true)
    #expect(OllamaSetupService.isWeakModel("anything", parameterBillions: 2.0) == true)
    #expect(OllamaSetupService.isWeakModel("anything", parameterBillions: 2.9) == true)
  }

  @Test("3B models are weak (threshold is <=3)")
  func weakAtThreshold() {
    #expect(OllamaSetupService.isWeakModel("anything", parameterBillions: 3.0) == true)
  }

  @Test("models above 3B are not weak")
  func notWeakAboveThreshold() {
    #expect(OllamaSetupService.isWeakModel("anything", parameterBillions: 3.1) == false)
    #expect(OllamaSetupService.isWeakModel("anything", parameterBillions: 7.0) == false)
    #expect(OllamaSetupService.isWeakModel("anything", parameterBillions: 70.0) == false)
  }

  @Test("falls back to hardcoded list when parameter size unknown")
  func weakFallbackList() {
    #expect(OllamaSetupService.isWeakModel("tinyllama", parameterBillions: nil) == true)
    #expect(OllamaSetupService.isWeakModel("phi-2", parameterBillions: nil) == true)
    #expect(OllamaSetupService.isWeakModel("gemma2:2b", parameterBillions: nil) == true)
  }

  @Test("defaults to not weak when unknown name and no parameter size")
  func notWeakByDefault() {
    #expect(OllamaSetupService.isWeakModel("some-custom-model", parameterBillions: nil) == false)
  }

  @Test("parses :Nb size tag from name when parameter size is unknown")
  func weakFromSizeTag() {
    // Common 1-3B variants should be classified as weak by tag alone (#272).
    #expect(OllamaSetupService.isWeakModel("llama3.2:1b", parameterBillions: nil) == true)
    #expect(OllamaSetupService.isWeakModel("llama3.2:3b", parameterBillions: nil) == true)
    #expect(OllamaSetupService.isWeakModel("qwen2.5:3b", parameterBillions: nil) == true)
    #expect(OllamaSetupService.isWeakModel("gemma2:0.5b-instruct", parameterBillions: nil) == true)
  }

  @Test("size-tag parser leaves larger models non-weak")
  func notWeakFromSizeTag() {
    #expect(OllamaSetupService.isWeakModel("llama3.1:8b", parameterBillions: nil) == false)
    #expect(OllamaSetupService.isWeakModel("llama3.1:70b", parameterBillions: nil) == false)
    #expect(OllamaSetupService.isWeakModel("gemma4:latest", parameterBillions: nil) == false)
  }

  @Test("bare llama3.2 is weak (3B default); other bare names remain unknown")
  func weakFromBarePrefix() {
    // Default Ollama model shipped by the app is the bare name `llama3.2`
    // (3B). Needs to hit the weak path or it falls into the thinking-token
    // headroom intended only for larger models (#272 codex round 3).
    #expect(OllamaSetupService.isWeakModel("llama3.2", parameterBillions: nil) == true)
    #expect(OllamaSetupService.isWeakModel("llama3.2:latest", parameterBillions: nil) == true)
  }

  @Test("size tag wins over prefix when a larger variant is explicit")
  func sizeTagWinsOverPrefix() {
    // Hypothetical future tag: bare `llama3.2` is weak, but an explicit 70b
    // variant must NOT be classified as weak just because the family prefix
    // is in the fallback list.
    #expect(OllamaSetupService.isWeakModel("llama3.2:70b", parameterBillions: nil) == false)
    #expect(OllamaSetupService.isWeakModel("llama3.2:8b", parameterBillions: nil) == false)
  }

  // MARK: - Thinking-Capable Detection (#272)

  @Test("known thinking-capable families are detected across tag variants")
  func thinkingCapableFamilies() {
    #expect(OllamaSetupService.isThinkingCapableModel("gemma4:latest") == true)
    #expect(OllamaSetupService.isThinkingCapableModel("gemma4:8b") == true)
    #expect(OllamaSetupService.isThinkingCapableModel("qwen3") == true)
    #expect(OllamaSetupService.isThinkingCapableModel("qwen3:7b") == true)
    #expect(OllamaSetupService.isThinkingCapableModel("deepseek-r1") == true)
    #expect(OllamaSetupService.isThinkingCapableModel("deepseek-r1:14b") == true)
    #expect(OllamaSetupService.isThinkingCapableModel("gpt-oss:20b") == true)
  }

  @Test("non-thinking models are not flagged as thinking-capable")
  func notThinkingCapable() {
    // Prevents regression where non-thinking 7B+ models would get the
    // 2048-token budget and risk outrunning the 15s pipeline timeout.
    #expect(OllamaSetupService.isThinkingCapableModel("llama3.2") == false)
    #expect(OllamaSetupService.isThinkingCapableModel("llama3.1:8b") == false)
    #expect(OllamaSetupService.isThinkingCapableModel("mistral") == false)
    #expect(OllamaSetupService.isThinkingCapableModel("gemma2:2b") == false)
    #expect(OllamaSetupService.isThinkingCapableModel("gemma3:12b") == false)
    #expect(OllamaSetupService.isThinkingCapableModel("phi-2") == false)
    #expect(OllamaSetupService.isThinkingCapableModel("qwen2.5:7b") == false)
  }
}
