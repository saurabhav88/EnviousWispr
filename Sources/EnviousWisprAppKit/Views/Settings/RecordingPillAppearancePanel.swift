import EnviousWisprCore
import SwiftUI

/// Choose the recording pill's design, per capability group (#2376 Phase 4, C7).
///
/// **Two groups, and the one that does not apply is GREYED WITH ITS REASON
/// rather than hidden.** Hiding it would leave a user who turns Live Preview on
/// wondering where the other pills went, and would give no clue to a user whose
/// engine cannot run here that the switch is not the thing standing in their way.
///
/// **The groups and their offerability come from `PillCatalog`, never from this
/// view.** A design this page greys out is exactly a design the pill would
/// refuse, because `offers` is defined in terms of the same `resolve` the
/// director calls. A local `allCases.filter { $0.canHoldWords == x }` would be a
/// second derivation of that rule even on the day it agreed.
///
/// **The reason is stated ONCE, at group level.** Two precedents were considered
/// and both rejected: `EngineCard` puts a reason inside a card that stays
/// selectable, and `LivePreviewSettingsView` deliberately moved its reason OUT of
/// the disabled control onto another card, on the recorded grounds that two
/// places saying why is how they come to disagree. Here the requirement is the
/// reason WITH the greyed group, so it is rendered once in that group's header
/// and nowhere else.
struct RecordingPillAppearancePanel: View {

  @Environment(PillAppearanceModel.self) private var model

  private let columns = [GridItem(.adaptive(minimum: 210, maximum: .infinity), spacing: 12)]

  var body: some View {
    BrandedPanel(
      icon: "waveform.badge.mic",
      header: "Recording Pill",
      description:
        "Choose how the pill looks while you are dictating. Changes apply the next time you record."
    ) {
      VStack(alignment: .leading, spacing: 18) {
        group(holdingWords: false)
        group(holdingWords: true)
      }
    }
  }

  private var hasWords: Bool { model.wordsCapability.hasWords }

  @ViewBuilder
  private func group(holdingWords: Bool) -> some View {
    let isActive = holdingWords == hasWords
    VStack(alignment: .leading, spacing: 8) {
      Text(holdingWords ? "Shows your words as you speak" : "Without live words")
        .font(.stRowTitle)
        .foregroundStyle(isActive ? .stTextPrimary : .stTextSecondary)

      // The reason, rendered ONLY on the inactive group and only once.
      if !isActive,
        let reason = Self.reason(for: model.wordsCapability, groupHoldsWords: holdingWords)
      {
        Text(reason)
          .settingsReadingCopy()
      }

      LazyVGrid(columns: columns, spacing: 12) {
        ForEach(model.designs(holdingWords: holdingWords), id: \.self) { design in
          RecordingPillDesignCard(
            design: design,
            isSelected: model.selection(holdingWords: holdingWords) == design,
            isEnabled: model.offers(design, holdingWords: holdingWords) && isActive,
            onSelect: { model.choose(design, holdingWords: holdingWords) })
        }
      }
    }
    // One animation on the container, never per `ForEach` child.
    .animation(.easeInOut(duration: 0.15), value: isActive)
  }

  /// Why the inactive group is inactive, in that user's terms.
  ///
  /// **Two refusals, two sentences, and that is the whole reason the capability
  /// carries a reason at all.** One sentence for both would tell a user whose
  /// engine cannot run on this Mac to turn on a setting that would not help them.
  static func reason(for capability: PillWordsCapability, groupHoldsWords: Bool) -> String? {
    if groupHoldsWords {
      switch capability {
      case .available: return nil
      case .previewOff:
        return
          "These need Live Preview, which is currently off. Turn it on in Live Preview settings."
      case .engineUnsupported:
        return "These need Live Preview, which the engine you have selected cannot run on this Mac."
      case .modelBeingRemoved:
        return "These need Live Preview, which is unavailable while the model you removed finishes clearing."
      }
    }
    // The wordless group is inactive exactly when words ARE available.
    return capability.hasWords
      ? "Live Preview is on, so the pill shows your words. These become available if you turn it off."
      : nil
  }
}

/// One selectable pill design.
///
/// A new card rather than a generalised `AppearanceCard`: that one is private to
/// the light/dark grid this phase must leave untouched, and widening it would
/// mean editing the very control the page already ships.
private struct RecordingPillDesignCard: View {
  let design: RecordingPillDesign
  let isSelected: Bool
  let isEnabled: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Image(systemName: iconName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(isSelected && isEnabled ? .stAccent : .stTextSecondary)
            .frame(width: 22, alignment: .center)
          Text(design.displayName)
            .font(.stRowTitle)
            .foregroundStyle(isSelected && isEnabled ? .stAccent : .stTextPrimary)
          Spacer(minLength: 0)
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(isEnabled ? Color.stAccent : Color.stTextSecondary)
          }
        }
        Text(design.summary)
          .settingsReadingCopy()
          .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
      }
      .padding(14)
      // Before `.buttonStyle(.plain)`, so the whole card is the hit target rather
      // than the label's glyphs.
      .contentShape(Rectangle())
      .background(Color.stSectionBg)
      .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
      .overlay(
        RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
          .strokeBorder(
            isSelected && isEnabled ? Color.stAccent : Color.stDivider,
            lineWidth: isSelected && isEnabled ? 2 : 1)
      )
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.45)
    // **Addressed by role and title, never by an accessibility identifier**
    // (swift-patterns). A greyed card must REPORT as disabled rather than merely
    // look it: the mistake `EngineCard` records for itself is a control that is
    // visible and inaudible.
    .accessibilityElement(children: .combine)
    .accessibilityLabel(design.displayName)
    .accessibilityValue(isSelected ? "Selected" : "")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  private var iconName: String {
    switch design {
    case .classic: return "capsule"
    case .readingWell: return "text.alignleft"
    case .levelRail: return "waveform"
    }
  }
}
