import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3972 R34, R48: the EnviousMeet page says where the text of a summary goes, for every kind
/// of engine. These sentences are privacy claims. (#4287 moved the engine choice to the
/// Summaries tab; `MeetingSummariesTabTests` covers that tab.)
@MainActor
@Suite("EnviousMeet page summary copy (#3972)", .tags(.productOutcome))
struct MeetingsPageSummaryCopyTests {
  @Test("the help and footnote say where the text goes for every kind of provider")
  func privacyCopy() {
    let help = String(localized: MeetingsCopy.writeSummaryHelp)
    for hosted in ["OpenAI", "Gemini", "Claude"] { #expect(help.contains(hosted)) }
    #expect(help.contains("Ollama hosted model sends them to Ollama's servers"))
    #expect(help.contains("Apple Intelligence and Ollama models on this Mac keep them on your Mac"))
    #expect(help.contains("does not stop a summary that has already started"))
    #expect(help.contains("any meeting that has a transcript"))
    // #4287: summaries no longer use AI Polish's engine, so the copy must not say they do.
    #expect(help.contains("summary engine on this tab"))
    #expect(!help.contains("AI Polish"))
    #expect(!String(localized: MeetingsCopy.writeSummaryShort).contains("AI Polish"))
  }
}
