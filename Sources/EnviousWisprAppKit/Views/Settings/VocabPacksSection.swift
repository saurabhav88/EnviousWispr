import EnviousWisprPostProcessing
import SwiftUI

/// Vocabulary Packs section of the Your Words settings tab (#633 Phase 9).
/// One row per installed ASR-mined pack: a toggle to enable it and a "See all"
/// button that opens the pack's full word list with the spoken variants each
/// word catches (#992). Default OFF. Enabling a pack feeds its known mis-hearing
/// fixes into the corrector; raw dictation is unaffected when off. Bible §10.2.
struct VocabPacksSection: View {
  @Environment(VocabularyPackManager.self) private var packManager
  @State private var selectedPack: VocabularyPackID?

  var body: some View {
    BrandedSection(header: "Vocabulary packs") {
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
            HStack(alignment: .center) {
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
              Spacer()
              Button("See all") { selectedPack = id }
                .controlSize(.small)
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
        }
      }
    }
    .sheet(item: $selectedPack) { id in
      VocabularyPackDetailSheet(id: id, terms: packManager.packTerms(id))
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
