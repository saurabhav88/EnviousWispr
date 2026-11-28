#if canImport(FoundationModels)
  import FoundationModels

  /// Both FoundationModels error types that report an exceeded context window.
  enum AppleContextOverflow {
    static func isOverflow(_ error: any Error) -> Bool {
      if #available(macOS 27.0, *),
        let modelError = error as? LanguageModelError,
        case .contextSizeExceeded = modelError
      {
        return true
      }
      if #available(macOS 26.0, *),
        let generationError = error as? LanguageModelSession.GenerationError,
        case .exceededContextWindowSize = generationError
      {
        return true
      }
      return false
    }
  }
#endif
