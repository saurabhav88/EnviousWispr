import EnviousWisprCore
import EnviousWisprLLM
import Foundation
import Testing

/// #4473: the identity of a local polish model. It exists so that two sizes of EG-1 are two
/// models everywhere a provider used to stand for "the" model. When these fail, work meant for
/// one size could be handed to another size's weights once sizes are selectable.
@Suite("Local polish model identity (#4473)", .tags(.driftGuard))
struct LocalPolishModelIDTests {
  @Test("EG-1's one model is the full size; no other provider has a size")
  func singleModelDerivation() {
    let egOne = LocalPolishModelID.singleModel(for: .egOne)
    #expect(egOne.provider == .egOne)
    #expect(egOne.size == .full)
    #expect(egOne == .egOne(.full))

    let others: [LLMProvider] = [
      .s1Mini, .openAI, .gemini, .claude, .ollama, .appleIntelligence, .none,
    ]
    for provider in others {
      let id = LocalPolishModelID.singleModel(for: provider)
      #expect(id.provider == provider)
      #expect(id.size == nil, "\(provider) must not carry an EG-1 size")
    }
  }

  @Test("the three sizes of EG-1 and S1-mini are four different models")
  func sizesAreDistinctModels() {
    let models: Set<LocalPolishModelID> = [
      .egOne(.full), .egOne(.mini), .egOne(.micro), .singleModel(for: .s1Mini),
    ]
    #expect(models.count == 4)
    #expect(EGOneSize.allCases == [.full, .mini, .micro])
  }

  @MainActor
  @Test("a size no runtime serves gets no runtime, never another size's")
  func lookupNeverSubstitutesAnotherSize() throws {
    let suite = "ew-model-id-\(UUID().uuidString)"
    let store = try #require(TestDefaults.suite(suite))
    defer { store.removePersistentDomain(forName: suite) }
    let coordinator = LocalPolishServerCoordinator()
    let egOne = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, defaults: store,
      coordinator: coordinator, provider: .egOne)
    let s1Mini = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, defaults: store,
      coordinator: coordinator, provider: .s1Mini)
    let set = LocalPolishRuntimeSet(egOne: egOne, s1Mini: s1Mini)

    #expect(egOne.modelID == .egOne(.full))
    #expect(s1Mini.modelID == .singleModel(for: .s1Mini))
    #expect(set.runtime(for: .egOne(.full)) === egOne)
    #expect(set.runtime(for: .egOne(.mini)) == nil)
    #expect(set.runtime(for: .egOne(.micro)) == nil)
  }
}
