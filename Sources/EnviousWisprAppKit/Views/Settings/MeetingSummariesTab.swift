import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import SwiftUI

/// #4287: the engines the Summaries tab offers, in the AI Polish list's order. S1-mini is left
/// out (founder 2026-10-31: tested, not good enough to summarize).
enum MeetingSummaryEngineChoices {
  static let providers: [PolishRailProvider] = PolishRailCatalog.all.filter {
    $0.provider != .s1Mini
  }

  /// Whether a provider card can be picked now. The single gate is `MeetingSummary.capability`
  /// (native EG-1 summarizes since #4319).
  static func isSelectable(_ provider: LLMProvider) -> Bool {
    switch provider {
    case .egOne:
      return MeetingSummary.capability(
        .egOne, model: LLMProvider.egOneModelName, ollamaModelIsRemote: nil) != .notForSummaries
    case .appleIntelligence, .ollama, .openAI, .gemini, .claude: return true
    case .s1Mini, .none: return false
    }
  }

  /// The line under a card's name: where it runs, or that it is not ready to pick yet.
  static func subtitle(for entry: PolishRailProvider) -> String {
    isSelectable(entry.provider)
      ? entry.group.heading : String(localized: MeetingsCopy.engineComingSoon)
  }
}

/// #4287: EnviousMeet's Summaries tab (founder decisions 7-12, plan I4): the automatic-summary
/// switch, the summary engine card with its engine choices, and the chosen engine's AI Polish
/// setup controls on the `.meetingSummary` surface, all independent of dictation's AI Polish.
struct MeetingSummariesTab: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(SetupCoordinator.self) private var setup
  @Environment(AIAvailabilityCoordinator.self) private var aiAvailability
  @Environment(LLMModelDiscoveryCoordinator.self) private var llmDiscovery
  @Environment(SavedKeyPresence.self) private var savedKeyPresence
  @Environment(LocalPolishRuntimeSet.self) private var localPolishRuntimes
  @State private var setupModel = ProviderSetupModel()
  @State private var choicesOpen: Bool?

  private var provider: LLMProvider { settings.effectiveMeetingSummaryLLMProvider }

  /// A user with no engine sees the choices open; Keep current closes them.
  private var isExpanded: Binding<Bool> {
    Binding(
      get: { choicesOpen ?? (provider == .none) },
      set: { choicesOpen = $0 })
  }

  var body: some View {
    SettingsContentView {
      VStack(alignment: .leading, spacing: 16) {
        BrandedSection {
          BrandedRow(showDivider: false) { MeetingWriteSummaryRow() }
        }
        SettingsSummaryCard(
          map: .id(.meetingSummaryEngine),
          isExpanded: isExpanded,
          changeAccessibilityLabel: MeetingsCopy.changeSummaryEngine,
          change: .meetingSummaryEngineChange,
          keepCurrent: .meetingSummaryEngineKeepCurrent
        ) {
          summary
        } status: {
          status
        } choices: {
          choiceGrid
        }
        // An engine that cannot be picked shows no setup. EG-1's setup here offers its
        // download but no Remove, which would change dictation's engine too (#4319).
        if provider != .none, MeetingSummaryEngineChoices.isSelectable(provider) {
          ProviderSetupSection(model: setupModel, surface: .meetingSummary)
        }
      }
    }
    .modifier(ProviderSetupLifecycle(model: setupModel, surface: .meetingSummary))
  }

  @ViewBuilder
  private var summary: some View {
    if let entry = PolishRailCatalog.entry(for: provider) {
      HStack(alignment: .center, spacing: 12) {
        ProviderLogoTile(provider: provider, size: 36, isSelected: true)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.name).settingsRowLabel()
          Text(entry.group.heading).font(.stRowHelper).foregroundStyle(.stTextSecondary)
        }
        Spacer(minLength: 8)
      }
      .accessibilityElement(children: .combine)
    } else {
      noEngineSummary
    }
  }

  /// The chosen engine's status on the card: "Can't write summaries" when summary capability
  /// refuses it, otherwise the same readiness the AI Polish card shows (`ProviderStatusMapping`
  /// over the live setup facts, read for the summary surface's own provider and model).
  @ViewBuilder
  private var status: some View {
    if let status = Self.cardStatus(
      provider: provider, model: settings.effectiveMeetingSummaryLLMModel, facts: statusFacts)
    {
      ProviderStatusChip(status: status, isHeadline: true)
    }
  }

  /// The setup facts, as `ProviderSetupSection` builds them, for this surface's provider. A key
  /// verdict counts only when the shared discovery state is about this provider.
  private var statusFacts: PolishSetupFacts {
    let aboutThisSurface = llmDiscovery.stateProvider == provider
    return .live(
      localPolishRuntimes: localPolishRuntimes, aiAvailability: aiAvailability, setup: setup,
      validationProvider: aboutThisSurface ? llmDiscovery.stateProvider : nil,
      cloudValidation: aboutThisSurface ? llmDiscovery.keyValidationState : .idle,
      openAIKeySaved: setupModel.openAIKeySaved, geminiKeySaved: setupModel.geminiKeySaved,
      claudeKeySaved: setupModel.claudeKeySaved,
      savedKeyPresence: savedKeyPresence,
      cloudVerdicts: llmDiscovery.cloudVerdicts,
      ollamaModel: settings.meetingSummaryOllamaModel)
  }

  /// Pure, for tests: nil says nothing (no engine, or a state never observed).
  static func cardStatus(provider: LLMProvider, model: String, facts: PolishSetupFacts)
    -> ProviderStatus?
  {
    guard provider != .none else { return nil }
    if MeetingSummary.capability(provider, model: model, ollamaModelIsRemote: nil)
      == .notForSummaries
    {
      return ProviderStatus(
        label: String(localized: MeetingsCopy.summaryEngineCantSummarize), tone: .unavailable)
    }
    // Health is probed only where the engine may be started (dictation's AI Polish page).
    return ProviderStatusMapping.status(
      for: provider, context: ProviderStatusContext(selected: true, healthApplies: false),
      facts: facts)
  }

  /// With no engine chosen the card opens on its choices, which replace the summary slot, so
  /// the no-engine line leads the choices.
  private var choiceGrid: some View {
    VStack(alignment: .leading, spacing: 12) {
      if provider == .none { noEngineSummary }
      engineCards
    }
  }

  private var noEngineSummary: some View {
    EngineSummaryContent(
      icon: "sparkles", name: String(localized: MeetingsCopy.summaryEngineNone),
      short: String(localized: MeetingsCopy.summaryEngineNoneShort))
  }

  private var engineCards: some View {
    LazyVGrid(
      columns: [GridItem(.adaptive(minimum: 150), spacing: 10, alignment: .top)],
      alignment: .leading, spacing: 10
    ) {
      ForEach(MeetingSummaryEngineChoices.providers) { entry in
        MeetingSummaryEngineCard(
          entry: entry,
          isSelected: provider == entry.provider,
          isSelectable: MeetingSummaryEngineChoices.isSelectable(entry.provider)
        ) {
          PolishSettings.setProvider(entry.provider, on: .meetingSummary, in: settings)
          choicesOpen = false
        }
      }
    }
  }
}

/// One engine choice: the provider's real logo, name and where it runs, like the Transcribe a
/// File polish cards. A card that cannot be picked is disabled for the pointer, the keyboard and
/// VoiceOver, and says why.
struct MeetingSummaryEngineCard: View {
  let entry: PolishRailProvider
  let isSelected: Bool
  let isSelectable: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          ProviderLogoTile(provider: entry.provider, size: 26, isSelected: isSelected)
          Spacer(minLength: 4)
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? Color.stAccent : Color.stTextSecondary)
            .accessibilityHidden(true)
        }
        Text(entry.name).font(.stRowLabel).fixedSize(horizontal: false, vertical: true)
        Text(MeetingSummaryEngineChoices.subtitle(for: entry))
          .font(.stRowHelper)
          .foregroundStyle(Color.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(12)
      .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(isSelected ? Color.stAccentLight : Color.stSectionBg)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(
            isSelected ? Color.stAccent : Color.stDivider, lineWidth: isSelected ? 1.5 : 1
          )
          .allowsHitTesting(false)
      )
      .contentShape(Rectangle())
      .opacity(isSelectable ? 1 : 0.55)
    }
    .buttonStyle(.plain)
    .disabled(!isSelectable)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .settingsMapRegistration(entry.meetingSummaryMapID)
  }
}
