/// The sizes of the EG-1 model family (#4473).
///
/// A logical size, not an artifact revision: which bytes serve a size is decided by model
/// delivery when the work runs.
public enum EGOneSize: Sendable, Hashable, CaseIterable {
  case full
  case mini
  case micro
}

/// Which local polish model a piece of work means (#4473).
///
/// A provider alone stopped being enough once EG-1 has sizes: two sizes of one provider are two
/// different models, and a lookup keyed by provider would hand one size's work to another size's
/// weights. EG-1 always carries a size; every other provider never does. The two ways to build
/// a value keep that true, so no caller can construct an EG-1 identity without a size or give a
/// size to a provider that has none.
public struct LocalPolishModelID: Sendable, Hashable {
  public let provider: LLMProvider
  public let size: EGOneSize?

  private init(provider: LLMProvider, size: EGOneSize?) {
    self.provider = provider
    self.size = size
  }

  /// EG-1 at one of its sizes.
  public static func egOne(_ size: EGOneSize) -> LocalPolishModelID {
    LocalPolishModelID(provider: .egOne, size: size)
  }

  /// The identity of a provider's one local model, while each provider has exactly one.
  ///
  /// EG-1 is its full size here because that is the only EG-1 the app ships until sizes are
  /// selectable. This is a pure calculation: it reads no setting and no installed file. The
  /// change that makes sizes selectable replaces every call of this function for EG-1 with the
  /// user's size, so it must not grow a default the compiler cannot see.
  public static func singleModel(for provider: LLMProvider) -> LocalPolishModelID {
    switch provider {
    case .egOne:
      return .egOne(.full)
    case .s1Mini, .openAI, .gemini, .claude, .ollama, .appleIntelligence, .none:
      return LocalPolishModelID(provider: provider, size: nil)
    }
  }
}
