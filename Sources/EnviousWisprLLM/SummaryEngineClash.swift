import EnviousWisprCore
import Foundation

/// #4287 PR 3 (founder decision 19, interpretation A): while an EnviousMeet summary call runs on
/// a local engine, a dictation that would polish with the SAME local engine skips AI polish and
/// says so; recording, transcription and paste are untouched. Different engines never clash.
///
/// The one rule for "the same local engine": Apple Intelligence with Apple Intelligence, EG-1
/// with EG-1, and Ollama with Ollama when both run on this Mac (any two models: one Ollama
/// server, shared memory). A hosted Ollama model is not local. #4319: an EG-1 summary also
/// clashes with S1-mini dictation, because both bundled models share one server process and the
/// summary holds it; the busy engine named is then the summary's, EG-1. The summary side only ever
/// reports a local call (`MeetingSummaryOwner` records the running call only for local
/// execution), so its locality is already settled when it reaches here.
public enum SummaryEngineClash {
  /// The engine both requests would use, or nil when this dictation may polish.
  /// - Parameters:
  ///   - dictation: the polish request's provider (the step's entry snapshot).
  ///   - dictationOllamaRemote: for Ollama, whether this request's model is hosted, from the
  ///     readiness probe of this attempt; nil for every other provider.
  ///   - runningLocalSummary: the provider of the summary call running on a local engine now
  ///     (for EG-1, held from the attempt's reservation to its release, #4319).
  public static func busyEngine(
    dictation: LLMProvider, dictationOllamaRemote: Bool?, runningLocalSummary: LLMProvider?
  ) -> LLMProvider? {
    guard let summary = runningLocalSummary else { return nil }
    if summary == .egOne, dictation == .s1Mini { return .egOne }
    guard summary == dictation else { return nil }
    switch dictation {
    case .appleIntelligence, .egOne:
      return dictation
    case .ollama:
      // Only a model this attempt's probe reported as local; an unknown answer never skips.
      return dictationOllamaRemote == false ? dictation : nil
    case .s1Mini, .openAI, .gemini, .claude, .none:
      return nil
    }
  }
}

/// Thrown by the live polish step when `SummaryEngineClash` finds the engine busy with a
/// summary. `TextProcessingRunner` turns it into a skip with a notice, never a failure.
public struct SummaryEngineBusy: Error, Equatable, Sendable {
  /// The engine writing the summary. Usually the dictation's own provider; for S1-mini dictation
  /// during an EG-1 summary it is EG-1, the model holding the shared server (#4319).
  public let provider: LLMProvider

  public init(provider: LLMProvider) {
    self.provider = provider
  }

  /// The dictation notice: polish was skipped because this engine is writing a summary.
  public var notice: PolishNotice {
    PolishNotice(
      leadIn: .skipped,
      text: String(
        localized:
          "AI polish skipped: \(provider.displayName) is writing your EnviousMeet summary.",
        comment:
          "Dictation notice: AI polish was skipped for this dictation because the same AI engine on this Mac (the value: Apple Intelligence, EG-1 or Ollama) is busy writing a meeting summary; the text was still pasted. EnviousMeet is the meeting recorder's name."
      ))
  }
}
