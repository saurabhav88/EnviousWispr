import SwiftUI

// Debug builds only, like the Diagnostics page that hosts it (#3736). English-only developer
// text, so the Release String Catalog carries none of it.
#if DEBUG
  /// Pill Preview: pick any pill and play it on demand. Everything it shows comes from
  /// `PillPreviewCatalog`; the pill itself is drawn by the real overlay.
  struct PillPreviewSection: View {
    @Environment(PillPreviewController.self) private var controller

    var body: some View {
      @Bindable var controller = controller

      BrandedSection(header: "Pill Preview") {
        BrandedRow(showDivider: controller.isReviewEnabled) {
          VStack(alignment: .leading, spacing: 4) {
            Toggle("Pill review mode", isOn: $controller.isReviewEnabled)
              .toggleStyle(BrandedToggleStyle())
            Text(
              "Play any pill on demand to see how it looks and how long it stays. Uses the real pill code. Buttons on a preview do nothing. Debug builds only."
            )
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
          }
        }
        if controller.isReviewEnabled {
          BrandedRow {
            Picker("Pill", selection: $controller.selectedID) {
              ForEach(PillPreviewCatalog.orderedGroups, id: \.group) { section in
                Section(section.group) {
                  ForEach(section.entries) { entry in
                    Text(entry.title).tag(entry.id)
                  }
                }
              }
            }
          }
          BrandedRow {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Button("Play") { controller.play() }
                Button("Dismiss") { controller.dismiss() }
              }
              Text(statusText)
                .font(.stHelper)
                .foregroundStyle(.stTextSecondary)
              if let event = controller.lastEvent {
                Text(event)
                  .font(.stHelper)
                  .foregroundStyle(.stTextSecondary)
              }
              Text(
                "Play does nothing while a real dictation or a real pill is on screen, so a preview never replaces a real one."
              )
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
            }
          }
          BrandedRow(showDivider: false) {
            VStack(alignment: .leading, spacing: 4) {
              Text("Not previewable")
                .font(.stHelper)
                .foregroundStyle(.stTextSecondary)
              ForEach(PillPreviewCatalog.exclusions, id: \.title) { exclusion in
                Text("\(exclusion.title): \(exclusion.reason)")
                  .font(.stHelper)
                  .foregroundStyle(.stTextSecondary)
              }
            }
          }
        }
      }
    }

    private var statusText: String {
      switch controller.outcome {
      case .idle: return "Pick a pill and press Play."
      case .pending(let title): return "Showing: \(title)…"
      case .shown(let title): return "Showing: \(title)"
      case .notShown(let reason): return "Not shown: \(reason)."
      }
    }
  }
#endif
