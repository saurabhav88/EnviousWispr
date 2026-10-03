import AppKit
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// C4 installs this immediately left of Feedback, retaining the shell's existing
/// toolbar background and spacer treatment. Requires the shell's SettingsManager.
struct WhatsNewToolbarButton: View {
  var showsCaption = true
  var caption: LocalizedStringResource = "What's New & Updates"
  @Environment(SettingsManager.self) private var settings
  @Environment(UpdateCoordinatorHolder.self) private var updates
  @State private var presentation = WhatsNewMenuPresentation()
  @State private var openedFromKeyboard = false
  @State private var openedFromAccessibility = false
  @State private var isMounted = false
  @FocusState private var buttonFocused: Bool
  @AccessibilityFocusState private var accessibilityFocused: Bool

  var body: some View {
    Button(action: openMenu) {
      HStack(spacing: 6) {
        Image(systemName: "gift")
          .foregroundStyle(.stAccent)
          .overlay(alignment: .topTrailing) {
            if settings.hasUnreadWhatsNew {
              Circle()
                .fill(Color.stAccent)
                .frame(width: 6, height: 6)
                .offset(x: 3, y: -2)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
          }
        if showsCaption {
          Text(caption)
            .font(.stRowLabel)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Color.stSectionBg, in: Capsule())
      .overlay(Capsule().strokeBorder(Color.stDivider, lineWidth: 1).allowsHitTesting(false))
      .contentShape(Rectangle())
      .fixedSize()
    }
    .buttonStyle(.plain)
    .focused($buttonFocused)
    .accessibilityFocused($accessibilityFocused)
    .accessibilityLabel(Text(caption))
    .help(Text(caption))
    .accessibilityValue(
      settings.hasUnreadWhatsNew ? Text("New release notes") : Text("No new release notes")
    )
    .popover(isPresented: $presentation.isPresented, arrowEdge: .bottom) {
      WhatsNewMenuView(coordinator: updates.coordinator)
        .onAppear { presentation.didOpen(settings: settings) }
        .onExitCommand { presentation.dismiss() }
    }
    .onAppear { isMounted = true }
    .onDisappear {
      isMounted = false
      openedFromKeyboard = false
      openedFromAccessibility = false
    }
    .onChange(of: presentation.isPresented) { _, isShowing in
      guard isShowing == false else { return }
      defer {
        openedFromKeyboard = false
        openedFromAccessibility = false
      }
      guard isMounted else { return }
      if openedFromKeyboard { buttonFocused = true }
      if openedFromAccessibility && NSWorkspace.shared.isVoiceOverEnabled {
        accessibilityFocused = true
      }
    }
  }

  private func openMenu() {
    openedFromKeyboard = buttonFocused
    openedFromAccessibility = accessibilityFocused
    presentation.requestOpen()
  }
}

/// Current release only, with actions outside the scroll so they stay reachable.
/// Does not own, cancel or infer the progress of Sparkle's attended update check.
struct WhatsNewMenuView: View {
  let coordinator: UpdateCoordinator?
  let entries: [WhatsNewMenuPresentation.ReleaseEntry]
  let version: String

  init(
    coordinator: UpdateCoordinator?,
    entries: [WhatsNewMenuPresentation.ReleaseEntry] = WhatsNewMenuPresentation.entries(),
    version: String = WhatsNewConstants.currentContentVersion
  ) {
    self.coordinator = coordinator
    self.entries = entries
    self.version = version
  }

  var body: some View {
    let status = WhatsNewMenuPresentation.updateStatus(coordinator?.service.state)
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("What's New")
          .font(.stRowTitle)
          .foregroundStyle(.stTextPrimary)
          .accessibilityAddTraits(.isHeader)
        Text("v\(version)")
          .font(.stRowHelper)
          .foregroundStyle(.stTextSecondary)
      }
      Text(status.text)
        .font(.stRowHelper)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          ForEach(entries) { entry in
            HStack(alignment: .top, spacing: 10) {
              SettingsRowIcon(systemName: entry.icon)
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 5) {
                Text(entry.title)
                  .font(.stRowLabel.weight(.semibold))
                  .foregroundStyle(.stTextPrimary)
                Text(entry.description)
                  .font(.stRowHelper)
                  .foregroundStyle(.stTextSecondary)
                if let destination = entry.readMoreURL {
                  Link("Read more", destination: destination)
                    .font(.stRowLabel)
                    .foregroundStyle(.stAccent)
                    .padding(.vertical, 5)
                }
              }
              .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 8)
      }
      .frame(height: 320)

      Divider()
      Link(destination: WhatsNewMenuPresentation.releasesURL) {
        Label("All release notes on GitHub", systemImage: "arrow.up.right.square")
          .font(.stRowLabel)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
      }
      .foregroundStyle(.stAccent)
      Button {
        coordinator?.checkForUpdatesFromWhatsNew()
      } label: {
        Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
          .font(.stRowLabel)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 5)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.stAccent)
      .disabled(status.canCheck == false)
    }
    .padding(18)
    .frame(width: 380)
    .background(Color.stSectionBg)
  }
}
