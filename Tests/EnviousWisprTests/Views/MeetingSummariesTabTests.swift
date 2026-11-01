import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4287: the EnviousMeet Summaries tab.
///
/// When these fail, the user sees the Summaries tab in the wrong place, offers S1-mini or lets
/// them pick EG-1 before it can summarize, or a pick that changes dictation's engine.
@MainActor
@Suite("EnviousMeet Summaries tab (#4287)", .tags(.productOutcome))
struct MeetingSummariesTabTests {
  @Test("the Summaries tab sits between Models and Call Apps")
  func tabOrder() {
    #expect(MeetingsTab.allCases == [.general, .models, .summaries, .callApps, .permissions])
    #expect(MeetingsTab.summaries.mapID == .meetingsTabSummaries)
    #expect(MeetingsTab.summaries.icon == "sparkles")
  }

  @Test("exactly six engines are offered, in the AI Polish order, without S1-mini")
  func offeredEngines() {
    #expect(
      MeetingSummaryEngineChoices.providers.map(\.provider)
        == [.egOne, .appleIntelligence, .ollama, .openAI, .gemini, .claude])
  }

  @Test("EG-1 is Coming soon and cannot be picked until it can write summaries")
  func egOneComingSoon() throws {
    #expect(!MeetingSummaryEngineChoices.isSelectable(.egOne))
    let egOne = try #require(PolishRailCatalog.entry(for: .egOne))
    #expect(
      MeetingSummaryEngineChoices.subtitle(for: egOne)
        == String(localized: MeetingsCopy.summaryEngineComingSoon))
    for provider in [LLMProvider.appleIntelligence, .ollama, .openAI, .gemini, .claude] {
      #expect(MeetingSummaryEngineChoices.isSelectable(provider), "\(provider)")
    }
  }

  @Test("every engine choice has its own Summaries map identity")
  func choiceIdentities() {
    let ids = MeetingSummaryEngineChoices.providers.map(\.meetingSummaryMapID)
    #expect(Set(ids).count == 6)
    #expect(!ids.contains(.meetingSummaryEngine))
  }

  @Test("the automatic-summary switch now lives on the Summaries tab")
  func toggleMoved() throws {
    let node = try #require(SettingsMap.nodes.first { $0.id == .meetingWriteSummary })
    #expect(node.parent == .meetingsTabSummaries)
    #expect(node.destination == .meetings(.summaries))
  }
}

/// #4287: the summary engine card's status reuses AI Polish's readiness mapping.
@MainActor
@Suite("EnviousMeet Summaries card status (#4287)", .tags(.productOutcome))
struct MeetingSummariesCardStatusTests {
  private func facts(
    provider: LLMProvider, keySaved: Bool?, validation: LLMModelDiscoveryCoordinator.KeyValidationState
  ) -> PolishSetupFacts {
    PolishSetupFacts(
      egOneInstall: .installed(version: "1"), egOneHealth: .green,
      s1MiniInstall: .installed(version: "1"), s1MiniHealth: .green,
      appleStatus: .available, appleFailureReasons: [], appleIsChecking: false,
      validationProvider: provider, cloudValidation: validation, credentialRevisions: [:],
      cloudVerdicts: [:], openAIKeySaved: keySaved, geminiKeySaved: keySaved,
      claudeKeySaved: keySaved, ollamaSetup: .ready, ollamaModel: .installed)
  }

  @Test("no engine says nothing")
  func noEngine() {
    #expect(
      MeetingSummariesTab.cardStatus(
        provider: .none, model: "", facts: facts(provider: .none, keySaved: nil, validation: .idle))
        == nil)
  }

  @Test("an engine or model that cannot summarize says so")
  func cannotSummarize() {
    let label = String(localized: MeetingsCopy.summaryEngineCantSummarize)
    let f = facts(provider: .egOne, keySaved: nil, validation: .idle)
    #expect(MeetingSummariesTab.cardStatus(provider: .egOne, model: "eg-1", facts: f)?.label == label)
    #expect(
      MeetingSummariesTab.cardStatus(provider: .ollama, model: "eg-1:latest", facts: f)?.label
        == label)
  }

  @Test("a supported engine shows the same readiness as AI Polish, for ready and missing-key states")
  func readinessMatchesAIPolish() {
    for (keySaved, validation) in [
      (Optional(true), LLMModelDiscoveryCoordinator.KeyValidationState.valid), (Optional(false), .idle),
    ] {
      let f = facts(provider: .openAI, keySaved: keySaved, validation: validation)
      let expected = ProviderStatusMapping.status(
        for: .openAI, context: ProviderStatusContext(selected: true, healthApplies: false), facts: f)
      let shown = MeetingSummariesTab.cardStatus(provider: .openAI, model: "gpt-4o-mini", facts: f)
      #expect(shown != nil, "a chosen cloud engine shows a status")
      #expect(shown == expected)
    }
  }
}

/// #4287 UAT finding: the setup card on the Summaries tab said what AI POLISH sends and does.
/// When these fail, the Summaries tab tells the user a summary sends their dictated text, app
/// name and custom words (it sends the meeting transcript and notes), or talks about dictation.
@MainActor
@Suite("EnviousMeet Summaries setup copy (#4287)", .tags(.productOutcome))
struct MeetingSummariesSetupCopyTests {
  @Test("every cloud engine's summary lines name the transcript and notes, never dictation or polish")
  func cloudLines() throws {
    for provider in [LLMProvider.openAI, .gemini, .claude] {
      let key = try #require(ProviderSetupSummaryCopy.keyShort(provider))
      let privacy = try #require(ProviderSetupSummaryCopy.privacy(provider))
      for line in [key, privacy, ProviderSetupSummaryCopy.modelLine(provider)] {
        #expect(!line.localizedCaseInsensitiveContains("dictation"), "\(provider): \(line)")
        #expect(!line.localizedCaseInsensitiveContains("polish"), "\(provider): \(line)")
      }
      #expect(key.contains("transcript") && key.contains("notes"))
      #expect(privacy.contains("transcript") && privacy.contains("never audio"))
    }
    #expect(ProviderSetupSummaryCopy.privacy(.openAI)?.contains("store: false") == true)
    #expect(ProviderSetupSummaryCopy.privacy(.gemini)?.contains("store: false") == true)
    #expect(ProviderSetupSummaryCopy.privacy(.claude)?.contains("store: false") == false)
  }

  @Test("the missing-key notice and the Ollama model line describe summaries")
  func otherLines() {
    let missingKey = String(localized: ProviderSetupSummaryCopy.missingKey)
    #expect(missingKey.contains("summary"))
    #expect(!missingKey.localizedCaseInsensitiveContains("polish"))
    let ollama = ProviderSetupSummaryCopy.modelLine(.ollama)
    #expect(ollama.contains("transcript"))
    #expect(!ollama.contains("Prepare"))
  }
}
