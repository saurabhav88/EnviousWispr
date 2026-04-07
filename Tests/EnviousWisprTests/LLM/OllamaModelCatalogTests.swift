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
}
