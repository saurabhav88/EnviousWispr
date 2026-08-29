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
  @State private var selectedPack: VocabularyPackID?

  var body: some View {
    BrandedSection {
      let ids = packManager.availablePackIDs
      if ids.isEmpty {
        BrandedRow(showDivider: false) {
          Text("No vocabulary packs available.")
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
        }
      } else {
        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
          BrandedRow(showDivider: index < ids.count - 1) {
            // ViewThatFits: the Dictionary rail (#2492) leaves this row roughly
            // 228pt at the app's 750pt minimum window — enough for the old
            // full-width page, not for text + a button + a toggle on one line
            // (cloud review, PR #2499). The horizontal row is tried first.
            ViewThatFits(in: .horizontal) {
              HStack(alignment: .center) {
                packInfo(id)
                Spacer()
                packControls(id)
              }
              VStack(alignment: .leading, spacing: 8) {
                packInfo(id)
                packControls(id)
              }
            }
          }
        }
      }
    }
    .sheet(item: $selectedPack) { id in
      VocabularyPackDetailSheet(id: id, terms: packManager.packTerms(id))
    }
  }

  @ViewBuilder
  private func packInfo(_ id: VocabularyPackID) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(id.displayName)
        .font(.body)
      Text(id.blurb)
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
      Text(rowDetail(for: id))
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .padding(.top, 2)
    }
  }

  @ViewBuilder
  private func packControls(_ id: VocabularyPackID) -> some View {
    HStack {
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
      .accessibilityLabel("Enable \(id.displayName) pack")
      .padding(.leading, 6)
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
