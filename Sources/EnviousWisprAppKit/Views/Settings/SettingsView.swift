import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Unified single-window view: History + all settings tabs in one sidebar.
struct UnifiedWindowView: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(NavigationCoordinator.self) private var navigationCoordinator
  @Environment(UpdateCoordinatorHolder.self) private var updateCoordinatorHolder
  @Environment(CustomWordsCoordinator.self) private var customWordsCoordinator
  @State private var selectedSection: SettingsSection = .history

  var body: some View {
    // Two-card frame: a self-contained sidebar card and content card, each
    // inset from the window edge and each other by the same amount, floating on
    // the darker window canvas. Replaces `NavigationSplitView`, whose macOS-26
    // sidebar floats with a system shape we can't align to the content card;
    // building the two panes ourselves lets both share one radius, border, and
    // inset so they read as balanced, uniform cards (founder, 2026-07-03).
    // `NavigationStack` hosts the window toolbar (top bar) without imposing the
    // floating sidebar.
    NavigationStack {
      HStack(spacing: SettingsLayout.windowFrameInset) {
        sidebarCard
        detailCard
      }
      .padding(SettingsLayout.windowFrameInset)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.stWindowBg)
      // Keep the app name as the window title (Window menu / VoiceOver) but hide
      // its titlebar text so it doesn't duplicate the centered wordmark (#1311).
      .background(MainWindowTitleHider())
      .toolbar {
        // macOS 26 wraps each toolbar item in a Liquid Glass capsule; hide it on
        // the principal item so the centered wordmark sits flush on the bar with
        // no grey oval behind it. Below macOS 26 there is no such capsule, so the
        // plain item is used. `sharedBackgroundVisibility` returns ToolbarContent,
        // so it attaches to the item, not to the label view.
        if #available(macOS 26.0, *) {
          ToolbarItem(placement: .principal) { wordmarkToolbarLabel }
            .sharedBackgroundVisibility(.hidden)
        } else {
          ToolbarItem(placement: .principal) { wordmarkToolbarLabel }
        }
        // Active-phase cue (loading / transcribing / polishing), invisible at
        // rest. Placed trailing next to the record button (not centered, which
        // would collide with the principal wordmark) so pages without the
        // History status row still explain why the record button is disabled.
        ToolbarItem(placement: .primaryAction) {
          StatusBadge()
        }
        ToolbarItem(placement: .primaryAction) {
          RecordButton()
        }
      }
    }
    .tint(.stAccentSolid)
    .onChange(of: navigationCoordinator.pendingSection) { _, newSection in
      if let section = newSection {
        selectedSection = section
        navigationCoordinator.consume()
      }
    }
  }

  /// The left navigation, rendered as a self-contained rounded card that floats
  /// on the window canvas. Paired with `detailCard` (same radius, border, and
  /// inset) so the two read as balanced, equally-spaced panels.
  private var sidebarCard: some View {
    VStack(spacing: 0) {
      // Consolidated app identity, top-left (logo + name + version chip).
      HStack(spacing: 10) {
        WisprLogoMark()
          .frame(width: 30, height: 30)
        VStack(alignment: .leading, spacing: 2) {
          Text(AppConstants.appName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.stTextPrimary)
          Text("v\(AppConstants.appVersion)")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.stTextSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
              Color.stTextSecondary.opacity(0.10),
              in: RoundedRectangle(cornerRadius: 5))
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14)
      .padding(.top, 12)
      .padding(.bottom, 12)

      Divider().overlay(Color.stDivider)

      // Custom rows (not a system List) so the selected row can carry the
      // brand gradient + glow the mockup calls for — macOS sidebar selection
      // can't render a gradient and greys out when the window is inactive.
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(SettingsGroup.allCases.enumerated()), id: \.element) { index, group in
            if index != 0 {
              Divider()
                .overlay(Color.stDivider)
                .padding(.horizontal, 4)
                .padding(.top, 10)
                .padding(.bottom, 6)
            }
            Text(group.rawValue)
              .font(.stSectionHeader)
              .tracking(0.6)
              .foregroundStyle(.stTextSecondary)
              .padding(.horizontal, 10)
              .padding(.top, index == 0 ? 4 : 0)
              .padding(.bottom, 3)

            ForEach(group.sections) { section in
              sidebarRow(section)
            }
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
      }
      .scrollContentBackground(.hidden)

      // Issue #343: in-app update banner. Fixed sibling of the scroll (NOT a
      // scrolling row) so it stays pinned to the bottom of the sidebar card.
      if let coordinator = updateCoordinatorHolder.coordinator,
        coordinator.service.shouldShowBanner,
        case .available(let u) = coordinator.service.state
      {
        UpdateAvailableBanner(update: u)
          .padding(.horizontal, 10)
          .padding(.bottom, 10)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
    .frame(width: 200)
    .frame(maxHeight: .infinity)
    .background(Color.stSidebarBg)
    .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.windowCardRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsLayout.windowCardRadius, style: .continuous)
        .strokeBorder(Color.stDivider, lineWidth: 1)
    )
  }

  /// The right content pane, wrapped as a rounded card matching `sidebarCard`
  /// (same radius, border, and inset) so the window reads as two balanced,
  /// equally-inset panels on the canvas.
  private var detailCard: some View {
    detailContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipShape(
        RoundedRectangle(cornerRadius: SettingsLayout.windowCardRadius, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: SettingsLayout.windowCardRadius, style: .continuous)
          .strokeBorder(Color.stDivider, lineWidth: 1)
      )
  }

  @ViewBuilder
  private var detailContent: some View {
    switch selectedSection {
    case .history:
      // History owns its own list/detail split layout, no page header.
      HistoryContentView()
    case .whatsNew:
      page(.whatsNew) { WhatsNewSettingsView() }
    case .appearance:
      page(.appearance) { AppearanceSettingsView() }
    case .speechEngine:
      page(.speechEngine) { SpeechEngineSettingsView() }
    case .audio:
      page(.audio) { AudioSettingsView() }
    case .recordingSounds:
      page(.recordingSounds) { RecordingSoundsSettingsView() }
    case .shortcuts:
      page(.shortcuts) { ShortcutsSettingsView() }
    case .aiPolish:
      page(.aiPolish) { AIPolishSettingsView() }
    case .wordCorrection:
      page(.wordCorrection) { YourWordsView() }
    case .clipboard:
      page(.clipboard) { ClipboardSettingsView() }
    case .permissions:
      page(.permissions) { PermissionsSettingsView() }
    case .checkForUpdates:
      // Issue #958: D1 action row never selects this case (no `.tag`), but the
      // exhaustive switch requires an arm.
      EmptyView()
    case .openSourceLicenses:
      page(.openSourceLicenses) { OpenSourceLicensesView() }
    #if DEBUG
      case .diagnostics:
        page(.diagnostics) { DiagnosticsSettingsView() }
    #endif
    }
  }

  /// One sidebar row. `checkForUpdates` fires its action and never selects
  /// (#958); `whatsNew` carries the animated unread glyph; everything else is a
  /// standard nav row that sets `selectedSection`.
  @ViewBuilder
  private func sidebarRow(_ section: SettingsSection) -> some View {
    if section == .checkForUpdates {
      SidebarNavRow(label: section.label, isSelected: false) {
        Image(systemName: section.icon)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(.stAccent)
      } action: {
        updateCoordinatorHolder.coordinator?.checkForUpdatesFromSettings()
      }
    } else if section == .whatsNew {
      let selected = selectedSection == section
      SidebarNavRow(label: section.label, isSelected: selected) {
        WhatsNewSidebarGlyph(
          isUnread: settings.hasUnreadWhatsNew,
          restColor: selected ? .white : .stAccent)
      } action: {
        selectedSection = section
      }
    } else {
      let selected = selectedSection == section
      SidebarNavRow(
        label: section.label, isSelected: selected,
        showsBadge: yourWordsEnrichmentBadgeVisible(for: section)
      ) {
        Image(systemName: section.icon)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(selected ? .white : .stAccent)
      } action: {
        selectedSection = section
      }
    }
  }

  /// The load-bearing notification surface for a background bulk-import
  /// enrichment run (#1701 Chunk 2, plan §3.1 point 6): independent of
  /// whether either transient pill was ever seen, this badge tells the
  /// founder something is in progress just by opening Settings at all.
  /// DEBUG-only because the whole import feature is (§316). Reads
  /// `pendingEnrichmentCount` (observable in-memory), never the total's mere
  /// presence — same reasoning as the progress card (Codex Chunk 2 review
  /// finding 5).
  private func yourWordsEnrichmentBadgeVisible(for section: SettingsSection) -> Bool {
    #if DEBUG
      section == .wordCorrection && customWordsCoordinator.pendingEnrichmentCount > 0
    #else
      false
    #endif
  }

  /// The centered top-bar identity: the brand mark plus the app wordmark. Held
  /// as a property so the toolbar can wrap it in either the glass-hidden or the
  /// plain `ToolbarItem` depending on the OS, without duplicating the label.
  private var wordmarkToolbarLabel: some View {
    HStack(spacing: 7) {
      WisprLogoMark()
        .frame(width: 16, height: 16)
      Text(AppConstants.appName)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.stTextPrimary)
    }
    .fixedSize()
  }

  /// Tags a page's content with its section so `SettingsContentView` renders the
  /// page-header card as its first item (Option B — the header lives with the
  /// setting cards, not floating under the top bar).
  @ViewBuilder
  private func page(
    _ section: SettingsSection, @ViewBuilder content: () -> some View
  ) -> some View {
    content()
      .environment(\.settingsPageSection, section)
  }
}

/// A single sidebar navigation row. When selected it carries the brand-purple
/// gradient pill, a lavender hairline, and a soft glow (the "spiced" selection);
/// otherwise it's a quiet lavender-icon row. Drawn manually so the selection
/// looks identical whether or not the window is the key window.
private struct SidebarNavRow<Icon: View>: View {
  let label: String
  let isSelected: Bool
  /// Small in-progress dot (#1701 Chunk 2). Paired with an accessibility
  /// value rather than color/shape alone, per accessibility-noncolor-motion.
  var showsBadge: Bool = false
  @ViewBuilder var icon: () -> Icon
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        icon()
          .frame(width: 19, height: 18)
        Text(label)
          .font(.stBody)
          .foregroundStyle(isSelected ? Color.white : .stTextBody)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
        Spacer(minLength: 2)
        if showsBadge {
          Circle()
            .fill(isSelected ? Color.white : Color.stAccentSolid)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
        }
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(
              LinearGradient(
                colors: [
                  Color(.sRGB, red: 0.604, green: 0.361, blue: 0.965, opacity: 1),
                  Color(.sRGB, red: 0.486, green: 0.227, blue: 0.929, opacity: 1),
                ],
                startPoint: .top, endPoint: .bottom)
            )
            .overlay(
              RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                  Color(.sRGB, red: 0.773, green: 0.714, blue: 1.0, opacity: 0.5),
                  lineWidth: 1)
            )
            .shadow(color: Color.stAccent.opacity(0.40), radius: 7, y: 2)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityValue(showsBadge ? "Importing in progress" : "")
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}
