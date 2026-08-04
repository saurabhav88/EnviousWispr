import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #1305: the `.llmModel` → `ollamaModel` mirror decision. "" means "nothing
/// armed" (empty discovery cleared the picker) and must never wipe the
/// remembered `ollamaModel` preference; non-empty picks mirror as before.
/// The decision is pure so its three-way matrix can be tested without
/// constructing the sync home's unrelated collaborators.
@MainActor
@Suite("PipelineSettingsSync llmModel mirror guard (#1305)")
struct PipelineSettingsSyncMirrorGuardTests {

  @Test("a non-empty ollama pick mirrors")
  func nonEmptyOllamaPickMirrors() {
    #expect(
      PipelineSettingsSync.shouldMirrorLLMModelToOllama(provider: .ollama, llmModel: "mistral"))
  }

  @Test("an empty llmModel (nothing armed) never mirrors")
  func emptyNeverMirrors() {
    #expect(
      !PipelineSettingsSync.shouldMirrorLLMModelToOllama(provider: .ollama, llmModel: ""))
  }

  @Test("non-ollama providers never mirror, empty or not")
  func nonOllamaNeverMirrors() {
    #expect(
      !PipelineSettingsSync.shouldMirrorLLMModelToOllama(provider: .openAI, llmModel: "gpt-4o"))
    #expect(
      !PipelineSettingsSync.shouldMirrorLLMModelToOllama(provider: .none, llmModel: ""))
  }
}
