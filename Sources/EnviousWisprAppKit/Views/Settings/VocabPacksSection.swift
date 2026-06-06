import EnviousWisprPostProcessing
import SwiftUI

/// Vocabulary Packs section of the Your Words settings tab (#633 Phase 9).
/// One toggle per installed ASR-mined pack. Default OFF. Enabling a pack feeds
/// its known mis-hearing fixes into the corrector (exact-match only); raw
/// dictation is unaffected when off. Bible §10.2.
struct VocabPacksSection: View {
  @Environment(VocabularyPackManager.self) private var packManager

  var body: some View {
    BrandedSection(header: "Vocabulary packs") {
      let ids = packManager.availablePackIDs
      if ids.isEmpty {
        BrandedRow(showDivider: false) {
          Text("No vocabulary packs available.")
            .font(.stHelper)
            .foregroundStyle(.stTextTertiary)
        }
      } else {
        ForEach(Array(ids.enumerated()), id: \.element) { index, id in
          BrandedRow(showDivider: index < ids.count - 1) {
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 2) {
                Text(id.displayName)
                  .font(.body)
                Text(id.blurb)
                  .font(.stHelper)
                  .foregroundStyle(.stTextTertiary)
                Text(rowDetail(for: id))
                  .font(.stHelper)
                  .foregroundStyle(.stTextTertiary)
                  .padding(.top, 2)
              }
              Spacer()
              Toggle(
                "",
                isOn: Binding(
                  get: { packManager.isEnabled(id) },
                  set: { packManager.setEnabled(id, $0) }
                )
              )
              .toggleStyle(BrandedToggleStyle())
              .labelsHidden()
            }
          }
        }
      }
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
