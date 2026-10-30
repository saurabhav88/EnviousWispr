import SwiftUI

// Debug builds only, like the Diagnostics page that hosts it (#3736). English-only developer
// text, so the Release String Catalog carries none of it.
#if DEBUG
  /// Pill Preview: pick any pill and play it on demand. Everything it shows comes from
  /// `PillPreviewCatalog`; the pill itself is drawn by the real overlay.
  struct PillPreviewSection: View {
    @Environment(PillPreviewController.self) private var controller
    @Environment(CallPopupPreviewController.self) private var callPopups

    var body: some View {
      @Bindable var controller = controller
      @Bindable var callPopups = callPopups

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
          BrandedRow {
            Picker("Call pop-up", selection: $callPopups.selectedID) {
              ForEach(callPopups.entries) { entry in
                Text(entry.title).tag(entry.id)
              }
            }
          }
          BrandedRow {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Button("Play") { callPopups.play() }
                Button("Dismiss") { callPopups.dismiss() }
              }
              Text(callPopupStatusText)
                .font(.stHelper)
                .foregroundStyle(.stTextSecondary)
              if let event = callPopups.lastEvent {
                Text(event)
                  .font(.stHelper)
                  .foregroundStyle(.stTextSecondary)
              }
              Text(
                "Shows the real call pop-up under the menu bar for as long as the real one stays. Any button only closes it. Play does nothing while a real call pop-up is on screen."
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
      .onChange(of: controller.isReviewEnabled) { _, enabled in
        if !enabled { callPopups.dismiss() }
      }
    }

    private var callPopupStatusText: String {
      switch callPopups.outcome {
      case .idle: return "Pick a call pop-up and press Play."
      case .shown(let title): return "Shown: \(title)"
      case .ended(let title): return "Closed: \(title)"
      case .notShown(let reason): return "Not shown: \(reason)."
      }
    }

    private var statusText: String {
      switch controller.outcome {
      case .idle: return "Pick a pill and press Play."
      case .pending(let title): return "Waiting to show: \(title)…"
      case .shown(let title): return "Shown: \(title)"
      case .notShown(let reason): return "Not shown: \(reason)."
      }
    }
  }
#endif
