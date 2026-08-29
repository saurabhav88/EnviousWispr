import EnviousWisprPostProcessing
import SwiftUI

/// Vocabulary Packs tab of the Dictionary page (#633 Phase 9). One row per
/// installed ASR-mined pack: a toggle to enable it and a "See all" button
/// that opens the pack's full word list with the spoken variants each word
/// catches (#992). Default OFF. Enabling a pack feeds its known mis-hearing
/// fixes into the corrector; raw dictation is unaffected when off. Bible §10.2.
/// #2492: no section header here — the left sub-menu's selected tab already
/// says "Vocabulary Packs"; repeating it inside the content would be the same
/// title rendered twice.
struct VocabPacksSection: View {
  @Environment(VocabularyPackManager.self) private var packManager
  /// #2495 UI decision (recorded on issue #2495): "See all" fills the whole
  /// Vocabulary Packs pane instead of opening a small popup, so the per-word
  /// editing controls have room. `selectedPack` therefore switches this
  /// view's own content rather than presenting a `.sheet`.
  @State private var selectedPack: VocabularyPackID?

  var body: some View {
    if let selectedPack {
      VocabularyPackDetailSection(id: selectedPack, onClose: { self.selectedPack = nil })
    } else {
      packList
    }
  }

  private var packList: some View {
    BrandedPanel(
      icon: "shippingbox",
      header: "Vocabulary Packs",
      description:
        "Ready-made word lists for a field. Turn one on and EnviousWispr starts fixing the words it already knows that field gets wrong."
    ) {
      let ids = packManager.availablePackIDs
      if ids.isEmpty {
        Text("No vocabulary packs available.")
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(ids, id: \.self) { packCard($0) }
        }
      }
    }
  }

  /// One pack, as its own recessed card.
  ///
  /// **The controls are pinned to the TITLE line, and that is the fix.** They
  /// were previously centred against a three-line block, so "See all" landed
  /// mid-paragraph at a different horizontal position in every row — the
  /// button's x followed the intrinsic width of whichever blurb sat beside it
  /// (founder screenshot, 2026-08-29). Anchoring them to the first line puts
  /// every button in the same place and next to the thing it acts on.
  private func packCard(_ id: VocabularyPackID) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      // ViewThatFits: at the app's 750pt minimum window this card is too
      // narrow for a name, a button and a toggle on one line (cloud review,
      // PR #2499). The one-line form is tried first.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          Text(id.displayName).settingsRowLabel()
          Spacer(minLength: 12)
          packControls(id)
        }
        VStack(alignment: .leading, spacing: 8) {
          Text(id.displayName).settingsRowLabel()
          packControls(id)
        }
      }

      Text(id.blurb)
        .settingsReadingCopy()
        .fixedSize(horizontal: false, vertical: true)
      Text(rowDetail(for: id))
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.stPageBg)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color.stDivider, lineWidth: 1)
    )
  }

  @ViewBuilder
  private func packControls(_ id: VocabularyPackID) -> some View {
    HStack(spacing: 10) {
      // No `.controlSize` here: this control owns its own metrics, so the
      // modifier the previous system `Button` needed became a dead line
      // that reads as if it still sizes something.
      SettingsActionButton(title: "See all", isEnabled: true) { selectedPack = id }
        .accessibilityLabel("See all words in the \(id.displayName) pack")

      Toggle(
        "",
        isOn: Binding(
          get: { packManager.isEnabled(id) },
          set: { packManager.setEnabled(id, $0) }
        )
      )
      .toggleStyle(BrandedToggleStyle())
      .labelsHidden()
      // BrandedToggleStyle's internal Spacer otherwise claims the whole
      // remaining row (swift-patterns.md RULE: plain-button-content-shape).
      .fixedSize()
      .accessibilityLabel("Enable \(id.displayName) pack")
    }
  }

  /// "248 fixes · e.g. async, bazel, cypress"
  private func rowDetail(for id: VocabularyPackID) -> String {
    let count = packManager.termCount(id)
    let examples = packManager.exampleCanonicals(id, limit: 3)
    let countText = "\(count) \(count == 1 ? "fix" : "fixes")"
    guard !examples.isEmpty else { return countText }
    return "\(countText) · e.g. \(examples.joined(separator: ", "))"
  }
}
