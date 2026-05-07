import SwiftUI

/// Phase 4 (#634) — Vocabulary Packs section of the Your Words settings tab.
/// Empty-state until Phase 5 (#635) ships pack data + install/uninstall logic.
/// Bible §10.2.
struct VocabPacksSection: View {
  var body: some View {
    BrandedSection(header: "Vocabulary packs") {
      BrandedRow(showDivider: false) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Vocabulary packs coming soon")
            .font(.body)
            .foregroundStyle(.stTextSecondary)
          Text(
            "Curated themed bundles like Tech, Meeting Notes, Medical, Legal. One-click install."
          )
          .font(.stHelper)
          .foregroundStyle(.stTextTertiary)
        }
      }
    }
  }
}
