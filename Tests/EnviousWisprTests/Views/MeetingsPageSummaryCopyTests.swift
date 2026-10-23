import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3972 R34, R48: the EnviousMeet page says who writes meeting summaries, and where the text
/// goes, for every AI Polish provider. These sentences are privacy claims.
@MainActor
@Suite("EnviousMeet page summary copy (#3972)", .tags(.productOutcome))
struct MeetingsPageSummaryCopyTests {
  @Test("the Summaries line names the provider, or the problem with the fix link, for every provider")
  func writerMatrix() {
    func of(_ provider: LLMProvider, _ model: String = "m") -> MeetingsView.SummaryWriter {
      MeetingsView.summaryWriter(provider, model: model)
    }
    #expect(of(.none) == .problem(.noProvider))
    #expect(of(.egOne) == .problem(.notForSummaries))
    #expect(of(.s1Mini) == .problem(.notForSummaries))
    #expect(of(.ollama, "eg-1:q4") == .problem(.notForSummaries))
    #expect(of(.appleIntelligence) == .provider(.appleIntelligence))
    #expect(of(.ollama, "llama3.2") == .provider(.ollama))
    #expect(of(.ollama, "gpt-oss:120b-cloud") == .provider(.ollama))
    #expect(of(.openAI) == .provider(.openAI))
    #expect(of(.gemini) == .provider(.gemini))
    #expect(of(.claude) == .provider(.claude))
    for provider in LLMProvider.allCases {
      let line = String(localized: MeetingsView.summaryWriterLine(of(provider)))
      switch of(provider) {
      case .provider(let named): #expect(line.contains(named.displayName), "\(provider)")
      case .problem: #expect(!line.isEmpty)
      }
    }
    #expect(
      String(localized: MeetingsView.summaryWriterLine(of(.none))).contains("no summary"))
  }

  @Test("the help and footnote say where the text goes for every kind of provider")
  func privacyCopy() {
    let help = String(localized: MeetingsCopy.writeSummaryHelp)
    for hosted in ["OpenAI", "Gemini", "Claude"] { #expect(help.contains(hosted)) }
    #expect(help.contains("Ollama hosted model sends them to Ollama's servers"))
    #expect(help.contains("Apple Intelligence and Ollama models on this Mac keep them on your Mac"))
    #expect(help.contains("does not stop a summary that has already started"))
    #expect(help.contains("any meeting that has a transcript"))
  }
}
