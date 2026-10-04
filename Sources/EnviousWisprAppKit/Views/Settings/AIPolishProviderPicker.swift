import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprPipeline
import EnviousWisprServices
import SwiftUI

/// The AI Polish provider card and its dropdown (#3385, founder's Claude Design 2026-10-03):
/// one card naming the chosen provider (mark, name, group, Recommended, a short line, its
/// status) that opens a dropdown of every provider in three groups, each row "<tagline> ·
/// <status>". Choosing a row writes the same `settings.llmProvider` the rail used to write;
/// the cloud key check that follows a switch is the lifecycle's job (`ProviderSetupLifecycle`).
struct AIPolishProviderPicker: View {
  /// The editor's state, for the saved-key reads the cloud statuses need.
  let model: ProviderSetupModel

  @Environment(SettingsManager.self) private var settings
  @Environment(SetupCoordinator.self) private var setup
  @Environment(AIAvailabilityCoordinator.self) private var aiAvailability
  @Environment(LLMModelDiscoveryCoordinator.self) private var llmDiscovery
  @Environment(SavedKeyPresence.self) private var savedKeyPresence
  @Environment(LocalPolishRuntimeSet.self) private var localPolishRuntimes
  @State private var isOpen = false

  static let menuWidth: CGFloat = 380

  /// The dropdown rows' facts. Every row reads the coordinator's verdict with its provider,
  /// and the mapping keeps a verdict about another provider from counting.
  private var facts: PolishSetupFacts {
    .live(
      localPolishRuntimes: localPolishRuntimes, aiAvailability: aiAvailability, setup: setup,
      validationProvider: llmDiscovery.stateProvider,
      cloudValidation: llmDiscovery.keyValidationState,
      openAIKeySaved: model.openAIKeySaved, geminiKeySaved: model.geminiKeySaved,
      claudeKeySaved: model.claudeKeySaved,
      savedKeyPresence: savedKeyPresence,
      cloudVerdicts: llmDiscovery.cloudVerdicts,
      ollamaModel: settings.ollamaModel)
  }

  private func status(for provider: LLMProvider) -> ProviderStatus? {
    let selected = provider == settings.llmProvider
    return ProviderStatusMapping.status(
      for: provider,
      context: ProviderStatusContext(selected: selected, healthApplies: selected),
      facts: facts)
  }

  var body: some View {
    if let entry = PolishRailCatalog.entry(for: settings.llmProvider) {
      card(entry)
        // The list opens under the card's LEADING edge, as in the design. A popover centres
        // on its anchor, so the anchor is a clear strip as wide as the list, pinned to the
        // card's bottom-left corner.
        .overlay(alignment: .bottomLeading) {
          Color.clear
            .frame(width: Self.menuWidth, height: 1)
            .allowsHitTesting(false)
            .settingsDropdown(isPresented: $isOpen, width: Self.menuWidth) {
              menu
            }
        }
    }
  }

  // MARK: - The card

  private func card(_ entry: PolishRailProvider) -> some View {
    let status = status(for: entry.provider)
    return Button {
      isOpen.toggle()
    } label: {
      HStack(spacing: 14) {
        ProviderLogoTile(provider: entry.provider, size: 46, isSelected: true)
        VStack(alignment: .leading, spacing: 3) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.name)
              .font(.stRowTitle)
              .foregroundStyle(Color.stTextPrimary)
            Text(entry.group.heading)
              .font(.stHelper)
              .foregroundStyle(Color.stTextSecondary)
            if entry.recommended {
              AIPolishRecommendedPill()
            }
          }
          Text(entry.short)
            .font(.stRowHelper)
            .foregroundStyle(Color.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
          if let status {
            ProviderStatusChip(status: status)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Founder 2026-10-03: "not immediately clear it's clickable". A worded cue in
        // button styling says what the card does before anyone hovers (Codex's first pick,
        // after Apple's pop-up button guidance). Drawn only: `action: nil` keeps it from being
        // a second control inside the card, whose whole area stays the one target.
        SettingsActionButton(
          title: LocalizedStringResource(
            "Change", comment: "AI Polish: cue on the provider card that opens the provider list."),
          isEnabled: true, emphasis: .outlined, size: .medium,
          trailingSystemImage: "chevron.up.chevron.down", action: nil
        )
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: PolishSectionLayout.cardRadius, style: .continuous)
          .fill(Color.stAccent.opacity(0.08))
      )
      .overlay(
        RoundedRectangle(cornerRadius: PolishSectionLayout.cardRadius, style: .continuous)
          // The input-strength border, so the card reads as a control at rest, not a panel.
          .strokeBorder(isOpen ? Color.stAccent : Color.stInputBorder, lineWidth: 1)
          .allowsHitTesting(false)
      )
      // The card hover: the whole target answers with an accent border, as the design's
      // own hover does.
      .settingsHoverCard(cornerRadius: PolishSectionLayout.cardRadius)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // The card is the dropdown's button: it names the setting, says the choice and its
    // group, and its status, so VoiceOver hears what a sighted user reads on it.
    .accessibilityLabel(
      String(
        localized: "AI polish model",
        comment: "VoiceOver: the AI Polish provider card under the Model heading; it opens the provider list.")
    )
    .accessibilityValue(
      [
        "\(entry.name), \(entry.group.accessibilityPhrase)",
        entry.recommended ? AIPolishRecommendedPill.title : nil,
        status.map { String(localized: "Status: \($0.label)") },
      ].compactMap { $0 }.joined(separator: ", ")
    )
    .accessibilityHint(
      String(
        localized: "Opens the list of AI polish models",
        comment: "VoiceOver hint on the AI Polish provider card."))
  }

  // MARK: - The dropdown

  @ViewBuilder private var menu: some View {
    ForEach(Array(PolishRailGroup.allCases.enumerated()), id: \.element) { index, group in
      SettingsDropdownHeading(title: group.heading, showsDivider: index > 0)
      ForEach(PolishRailCatalog.providers(in: group)) { entry in
        row(entry)
      }
    }
  }

  private func row(_ entry: PolishRailProvider) -> some View {
    let isChosen = entry.provider == settings.llmProvider
    let status = status(for: entry.provider)
    return SettingsDropdownRow(
      isChosen: isChosen,
      spokenTitle: [
        "\(entry.name), \(entry.group.accessibilityPhrase)",
        entry.recommended ? AIPolishRecommendedPill.title : nil,
        status.map { String(localized: "Status: \($0.label)") },
      ].compactMap { $0 }.joined(separator: ", "),
      action: {
        settings.llmProvider = entry.provider
        isOpen = false
      },
      leading: {
        ProviderLogoTile(provider: entry.provider, size: 26, isSelected: isChosen)
      },
      title: entry.name,
      subtitle: {
        subtitle(entry.tagline, status: status)
      })
  }

  /// "<tagline> · <status>", the status word in its tone colour; the tagline alone when the
  /// provider has no status the app can stand behind.
  private func subtitle(_ tagline: String, status: ProviderStatus?) -> some View {
    var line = Text(tagline).foregroundColor(Color.stTextSecondary)
    if let status {
      line =
        line + Text(verbatim: " · ").foregroundColor(Color.stTextSecondary)
        + Text(status.label).foregroundColor(status.tone.color)
    }
    return line.font(.stHelper).lineLimit(1)
  }
}

/// The "Recommended" pill on EG-1's card. 14pt text (the Settings type floor) in the design's
/// solid accent.
struct AIPolishRecommendedPill: View {
  static let title = String(
    localized: "Recommended",
    comment: "AI Polish: the pill on the recommended provider, EG-1.")

  var body: some View {
    Text(Self.title)
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(Color.white)
      .padding(.horizontal, 8)
      .padding(.vertical, 1)
      .background(Capsule().fill(Color.stAccentSolid))
      .accessibilityHidden(true)
  }
}
