import SwiftUI

/// Phase 4 (#634) — Learning section of the Your Words settings tab. Two rows:
/// auto-learn (Phase 7 #629) and contacts import (Phase 6 #636). Both ship
/// disabled with "Coming soon" captions until those phases land. Bible §10.2.
struct LearningSection: View {
  var body: some View {
    BrandedSection(header: "Learning") {
      // Row 1: Auto-learn from transcripts (Phase 7 #629)
      BrandedRow(showDivider: true) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Learn from my transcripts")
                .font(.body)
              Text(
                "EnviousWispr will watch for edits to text it just pasted, to suggest custom words. Edits stay on this Mac."
              )
              .font(.stHelper)
              .foregroundStyle(.stTextTertiary)
            }
            Spacer()
            Toggle("", isOn: .constant(false))
              .toggleStyle(BrandedToggleStyle())
              .disabled(true)
              .labelsHidden()
          }
          Text("Coming soon")
            .font(.stHelper)
            .foregroundStyle(.stTextTertiary)
            .padding(.top, 2)
        }
      }

      // Row 2: Import from Contacts (Phase 6 #636)
      BrandedRow(showDivider: false) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Import from Contacts")
                .font(.body)
              Text(
                "Add the names of people you know to your custom word list. Names stay on your Mac."
              )
              .font(.stHelper)
              .foregroundStyle(.stTextTertiary)
            }
            Spacer()
            Button("Review") {}
              .disabled(true)
          }
          Text("Coming soon")
            .font(.stHelper)
            .foregroundStyle(.stTextTertiary)
            .padding(.top, 2)
        }
      }
    }
  }
}
