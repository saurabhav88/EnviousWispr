import AppKit
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// C4 installs this immediately left of Feedback, retaining the shell's existing
/// toolbar background and spacer treatment. Requires the shell's SettingsManager.
/// Icon only at every window width (founder, 2026-10-03): the caption is the button's
/// accessible name and tooltip, so the toolbar always has room for Feedback and Record.
struct WhatsNewToolbarButton: View {
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
      WhatsNewGiftGlyph(isUnread: settings.hasUnreadWhatsNew)
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
              }
              .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 8)
      }
      // Fixed height so the links below never move; the bar stays visible so
      // readers can tell more notes sit below the fold (founder, 2026-10-03).
      .scrollIndicators(.visible)
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

/// The gift icon: an animated rainbow while there are new release notes, plain accent
/// purple otherwise (founder, 2026-10-03). Ported from main's retired
/// `WhatsNewSidebarGlyph`, including its Reduce Motion handling.
struct WhatsNewGiftGlyph: View {
  let isUnread: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let rainbowColors: [Color] = [
    Color(red: 1.0, green: 0.165, blue: 0.251),
    Color(red: 1.0, green: 0.549, blue: 0.0),
    Color(red: 1.0, green: 0.843, blue: 0.0),
    Color(red: 0.0, green: 0.98, blue: 0.604),
    Color(red: 0.118, green: 0.565, blue: 1.0),
    Color(red: 0.541, green: 0.169, blue: 0.886),
  ]

  var body: some View {
    if isUnread {
      TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : (1.0 / 30.0))) { context in
        let t = context.date.timeIntervalSinceReferenceDate
        let phase = reduceMotion ? 0.25 : (t.truncatingRemainder(dividingBy: 3.0) / 3.0)

        LinearGradient(
          colors: Self.rainbowColors,
          startPoint: UnitPoint(x: phase - 1.0, y: 0.0),
          endPoint: UnitPoint(x: phase, y: 1.0)
        )
        .mask(Image(systemName: "gift").font(.system(size: 15, weight: .semibold)))
        .compositingGroup()
      }
      .frame(width: 18, height: 18)
      .accessibilityHidden(true)
    } else {
      Image(systemName: "gift")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(Color.stAccent)
        .accessibilityHidden(true)
    }
  }
}
