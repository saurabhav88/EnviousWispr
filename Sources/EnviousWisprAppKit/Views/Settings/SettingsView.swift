import AppKit
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Unified single-window view: History + all settings tabs in one sidebar.
struct UnifiedWindowView: View {
  @Environment(NavigationCoordinator.self) private var navigationCoordinator
  @Environment(UpdateCoordinatorHolder.self) private var updateCoordinatorHolder
  @Environment(CustomWordsCoordinator.self) private var customWordsCoordinator
  /// #2772 finding 15: the sidebar dot while an import runs. Shows an ACTIVE import job,
  /// including preparation. Stop clears the dot immediately; the physical engine release may
  /// finish later, and `isEngineHeld` is what protects the resource until it does.
  @Environment(FileImportCoordinator.self) private var fileImportCoordinator
  /// The page and the Dictation tab on screen (#3385). One value, for the
  /// window's life only; see `SettingsNavigationState`.
  @State private var navigationState = SettingsNavigationState()
  /// #3438: the leave guard. The monitor decides whether a warning may show; the window keeps
  /// only this visit's state: the pending question, the provider chosen when the AI Polish
  /// visit began, whether a typed key is unsaved (yes/no only), and sidebar focus.
  @Environment(PolishSetupMonitor.self) private var polishSetupMonitor
  @Environment(SettingsManager.self) private var settings
  /// The question on screen and its identity; a dismissal clears only the one it belongs to.
  @State private var pendingLeave: PolishSetupLeaveRequest?
  @State private var pendingLeaveID: UInt64 = 0
  @State private var providerWhenVisitBegan: LLMProvider?
  @State private var hasUnsavedKeyDraft = false
  @FocusState private var focusedSidebarPage: SettingsPage?
  /// #3482: this window's Settings search, and whether its field has keyboard focus.
  @State private var search = SettingsSearchModel.live { message in
    AccessibilityNotification.Announcement(message).post()
  }
  @FocusState private var searchFocused: Bool

  /// Owned HERE so a language download survives the user navigating to another section: this view
  /// is retained, the pages inside `detailContent` are not. See
  /// `LivePreviewSettingsView.packs`.
  @State private var livePreviewPacks = LivePreviewPacksModel(
    catalog: LivePreviewPacksModel.liveCatalog())

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
      // #3482 §3.3: the dropdown floats above both cards, outside their clip shapes.
      .overlayPreferenceValue(SettingsSearchFieldAnchorKey.self) { anchor in
        searchDropdown(anchor)
      }
      .background(
        SettingsWindowCloseObserver {
          search.reset(endedBy: .windowClose)
          navigationState.endWindowSession()
        })
      // #3482 §3.4: a direct tab change drops an arrival meant for another tab.
      .onChange(of: navigationState.dictationTab) { _, _ in navigationState.noteTabChange() }
      // #3482 §8.1: the failed-search row follows "Share usage metrics", read at every terminal.
      .onAppear { search.usageMetricsOn = { settings.shareUsageMetrics } }
      .onChange(of: settings.shareUsageMetrics) { _, isOn in search.usageMetricsChanged(isOn: isOn) }
      .onChange(of: navigationState.appSettingsTab) { _, _ in navigationState.noteTabChange() }
      .onChange(of: navigationState.dictionaryTab) { _, _ in navigationState.noteTabChange() }
      .focusedSceneValue(\.settingsFind) {
        search.reopenPanel()
        searchFocused = true
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.stWindowBg)
      // Keep the app name as the window title (Window menu / VoiceOver) but hide
      // its titlebar text so it doesn't duplicate the centered wordmark (#1311).
      .background(MainWindowTitleHider())
      .toolbar { SettingsWindowToolbar() }
    }
    .tint(.stAccentSolid)
    // #3482: an arrival that moves focus to a setting first lets go of the search field.
    .environment(\.settingsArrivalReleaseSearchFocus) { searchFocused = false }
    // `initial: true`: a request made before this window existed (the menu's
    // Settings item opens the window and asks in the same breath) still lands.
    .onChange(of: navigationCoordinator.pendingDestination, initial: true) { _, destination in
      if let destination {
        // Accepted here: from now on the guard holds it, as navigation or as the pending
        // destination of a leave question.
        navigationCoordinator.consume()
        navigate(.destination(destination))
      }
    }
    .onPreferenceChange(PolishSetupUnsavedKeyDraftKey.self) { hasUnsavedKeyDraft = $0 }
    .alert(
      leaveQuestion?.content.title ?? "",
      isPresented: leaveIsPresented,
      presenting: leaveQuestion
    ) { question in
      ForEach(Array(question.content.buttons.enumerated()), id: \.offset) { _, button in
        Button(button.title, role: button.role == .cancel ? .cancel : nil) {
          respond(
            button.action,
            reportedAs: button.action.promptAction(
              isCancelRole: button.role == .cancel, event: NSApp.currentEvent),
            to: question.id)
        }
      }
    } message: { question in
      Text(question.content.message)
    }
  }

  // MARK: - Navigation through one guard (#3438)

  private struct LeaveQuestion {
    let id: UInt64
    let content: PolishSetupLeaveDialogContent
  }

  private var leaveQuestion: LeaveQuestion? {
    pendingLeave.map { LeaveQuestion(id: pendingLeaveID, content: .make(for: $0)) }
  }

  /// Closing the alert (Escape with no Cancel button, or the system) clears only the question
  /// it was showing; a newer one that arrived meanwhile stays.
  private var leaveIsPresented: Binding<Bool> {
    let shownID = pendingLeaveID
    return Binding(
      get: { pendingLeave != nil },
      set: { presented in
        if !presented, pendingLeaveID == shownID { pendingLeave = nil }
      })
  }

  /// Every way of changing page comes through here: a sidebar row, an in-page link, and a
  /// request from the menu or elsewhere. Leaving AI Polish while the chosen model is not set up
  /// asks first; while that question is open, the latest request replaces the pending one.
  private func navigate(_ intent: SettingsNavigationIntent) {
    if let pending = pendingLeave {
      // The latest request wins; the question on screen keeps its identity.
      pendingLeave = PolishSetupLeaveGuard.replacingPendingDestination(of: pending, with: intent)
      return
    }
    if let request = PolishSetupLeaveGuard.request(
      for: intent, from: navigationState.selectedPage, monitor: polishSetupMonitor,
      previousProvider: providerWhenVisitBegan, currentProvider: settings.llmProvider,
      keyNotSaved: hasUnsavedKeyDraft)
    {
      pendingLeaveID &+= 1
      pendingLeave = request
      polishSetupMonitor.recordPrompt(.leaveDialog, .shown, subject: request.promptSubject)
      return
    }
    commit(intent)
  }

  private func commit(_ intent: SettingsNavigationIntent) {
    let wasOnAIPolish = navigationState.selectedPage == .aiPolish
    navigationState.perform(intent)
    // #3482 §3.4, §8.1: every committed navigation ends the search (a Stay never reaches here),
    // reporting how it ended after the navigation committed.
    switch intent {
    case .search:
      search.finish(endedBy: .searchResult)
    case .sidebar(let page):
      search.finish(
        endedBy: .sidebar, sidebarPage: page.rawValue, sidebarTab: openTab(on: page))
    case .destination:
      search.finish(endedBy: .externalDestination)
    }
    search.reset()
    // A new AI Polish visit begins: remember what was chosen before the person changes it.
    if intent.page == .aiPolish, !wasOnAIPolish { providerWhenVisitBegan = settings.llmProvider }
  }

  /// A button on the question `id`. The question's latest destination is read now; the
  /// answer is validated by the guard before anything changes.
  private func respond(
    _ action: PolishSetupLeaveAction, reportedAs reported: PolishSetupPromptEvent.Action,
    to id: UInt64
  ) {
    guard id == pendingLeaveID, let request = pendingLeave else { return }
    pendingLeave = nil
    // Reported as pressed (Escape as `closed`), before the guard judges it against the live
    // state.
    polishSetupMonitor.recordPrompt(.leaveDialog, reported, subject: request.promptSubject)
    switch PolishSetupLeaveGuard.resolve(
      action, request: request, monitor: polishSetupMonitor,
      previousProvider: providerWhenVisitBegan, currentProvider: settings.llmProvider,
      keyNotSaved: hasUnsavedKeyDraft)
    {
    case .stay:
      break
    case .openSystemSettings:
      if let url = URL(string: AppleIntelligenceSettings.systemSettingsURL) {
        NSWorkspace.shared.open(url)
      }
    case .navigate(let intent):
      leave(to: intent)
    case .restoreProvider(let provider, let intent):
      // The normal setter: the same path as choosing it in the dropdown.
      settings.llmProvider = provider
      // Validated as fully set up a moment ago; if that is somehow no longer true, stay rather
      // than raise a second alert over this one's dismissal.
      if PolishSetupLeaveGuard.request(
        for: intent, from: .aiPolish, monitor: polishSetupMonitor,
        previousProvider: providerWhenVisitBegan, currentProvider: settings.llmProvider,
        keyNotSaved: hasUnsavedKeyDraft) == nil
      {
        leave(to: intent)
      }
    }
  }

  /// The tab a page shows now, as a raw value, for the sidebar-bypass row (§8.1).
  private func openTab(on page: SettingsPage) -> String? {
    switch page {
    case .dictation: return navigationState.dictationTab.rawValue
    case .appSettings: return navigationState.appSettingsTab.rawValue
    case .dictionary: return navigationState.dictionaryTab.rawValue
    default: return nil
    }
  }

  private func leave(to intent: SettingsNavigationIntent) {
    commit(intent)
    // #3482 §3.4: a search arrival owns focus (the reveal moves it to the chosen control).
    if case .search = intent { return }
    focusedSidebarPage = intent.page
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
      .padding(.bottom, 10)

      // #3482 §3.3: Settings search, between the identity header and the divider.
      SettingsSearchField(model: search, isFocused: $searchFocused) { request in
        navigate(.search(request))
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 10)

      Divider().overlay(Color.stDivider)

      // Custom rows (not a system List) so the selected row can carry the
      // brand gradient + glow the mockup calls for — macOS sidebar selection
      // can't render a gradient and greys out when the window is inactive.
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          sidebarRow(.history)
          ForEach(Array(SettingsGroup.allCases.enumerated()), id: \.element) { index, group in
            Divider()
              .overlay(Color.stDivider)
              .padding(.horizontal, 4)
              .padding(.top, 10)
              .padding(.bottom, 6)
            Text(group.heading)
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
      .searchPanelBlocksBackground(search.isPanelPresented)

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
      .searchPanelBlocksBackground(search.isPanelPresented)
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
    switch navigationState.selectedPage {
    case .history:
      // History owns its own list/detail split layout, no page header.
      HistoryContentView()
    case .dictation:
      page(.dictation) {
        DictationSettingsView(selection: $navigationState.dictationTab, packs: livePreviewPacks)
      }
    case .transcribeFile:
      page(.transcribeFile) { TranscribeFileView() }
    case .keybinds:
      page(.keybinds) { KeybindsSettingsView() }
    case .aiPolish:
      page(.aiPolish) { AIPolishSettingsView() }
    case .dictionary:
      page(.dictionary) { YourWordsView(selection: $navigationState.dictionaryTab) }
    case .snippets:
      page(.snippets) { SnippetsView() }
    case .appSettings:
      page(.appSettings) { AppSettingsView(selection: $navigationState.appSettingsTab) }
    #if DEBUG
      case .diagnostics:
        page(.diagnostics) { DiagnosticsSettingsView() }
    #endif
    }
  }

  /// #3482 §3.3, §3.4: the dropdown under the search field, above both cards, and the surface
  /// that turns an outside click into closing it (the field and the panel stay clickable).
  @ViewBuilder
  private func searchDropdown(_ anchor: Anchor<CGRect>?) -> some View {
    if search.isPanelPresented, let anchor {
      GeometryReader { proxy in
        let field = proxy[anchor]
        let width = max(0, min(440, proxy.size.width - field.minX - 8))
        let top = field.maxY + 6
        ZStack(alignment: .topLeading) {
          Color.clear
            .contentShape(
              Path { path in
                path.addRect(CGRect(origin: .zero, size: proxy.size))
                path.addRect(field)
              }, eoFill: true
            )
            .onTapGesture { search.dismissPanel() }
            .accessibilityHidden(true)
          SettingsSearchPanel(
            model: search, availableHeight: max(0, proxy.size.height - top - 8)
          ) { request in navigate(.search(request)) }
            .frame(width: width)
            .frame(maxHeight: max(0, proxy.size.height - top - 8), alignment: .top)
            .offset(x: field.minX, y: top)
        }
      }
    }
  }

  /// Every sidebar row selects a page; updates live in the toolbar dropdown.
  private func sidebarRow(_ section: SettingsPage) -> some View {
    let selected = navigationState.selectedPage == section
    return SidebarNavRow(
      label: section.label, isSelected: selected, activity: sidebarActivity(section)
    ) {
      Image(systemName: section.icon)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(selected ? .white : .stAccent)
    } action: {
      navigate(.sidebar(section))
    }
    .focused($focusedSidebarPage, equals: section)
  }

  /// The load-bearing notification surface for a background bulk-import
  /// enrichment run (#1701 Chunk 2, plan §3.1 point 6): independent of
  /// whether either transient pill was ever seen, this badge tells the
  /// user something is in progress just by opening Settings at all. Reads
  /// `pendingEnrichmentCount` (observable in-memory), never the total's mere
  /// presence — same reasoning as the progress card (Codex Chunk 2 review
  /// finding 5).
  private func yourWordsEnrichmentBadgeVisible(for section: SettingsPage) -> Bool {
    section == .dictionary && customWordsCoordinator.pendingEnrichmentCount > 0
  }

  /// Which sidebar rows carry the "something is running here" dot.
  ///
  /// #2772 finding 15. Founder: "transcribe is supposed to show it's active". The point is
  /// the long run he walked away from — the sidebar is how he knows it is still going.
  ///
  /// **Through the badge that already exists, deliberately.** `SidebarNavRow(showsBadge:)`
  /// has done this job for Your Words since #1701, and its accessibility value already says
  /// "in progress". A second dot mechanism would be a second answer to one question.
  ///
  /// #3385: the badge is now `SidebarNavRow(activity:)`, and the activity names WHICH
  /// thing is running, so the dot and its spoken value come from this one answer. Before,
  /// the Dictionary dot was announced as "Importing in progress". File import reads
  /// `isRunning`, which Stop clears at the press, never the engine claim it still holds.
  private func sidebarActivity(_ section: SettingsPage) -> SettingsShellCopy.SidebarActivity {
    if section == .transcribeFile && fileImportCoordinator.isRunning { return .fileImport }
    if section == .aiPolish && polishSetupMonitor.shows(.sidebarTag) { return .polishNeedsSetup }
    if yourWordsEnrichmentBadgeVisible(for: section) { return .dictionaryEnrichment }
    return .none
  }

  /// Tags a page's content with its section so `SettingsContentView` renders the
  /// page-header card as its first item (Option B — the header lives with the
  /// setting cards, not floating under the top bar).
  /// #3385: superseded; pages have no header (tracker A5). What remains is the
  /// window-navigation action every page can call.
  @ViewBuilder
  private func page(_ drawn: SettingsPage, @ViewBuilder content: () -> some View) -> some View {
    content()
      // #3545: every control on the page carries the page it was drawn in; a tabbed page overrides
      // this around the tab it draws, so the tab strip and fixed headings keep the page-only tag.
      .environment(\.settingsArrivalContent, SettingsArrivalContent(page: drawn))
      // #3482 §3.4: the page's one search-arrival owner, above every scroll view on the page.
      .modifier(SettingsArrivalModifier())
      // The only place `navigationState` is in scope, so the only place this can
      // be supplied without threading a binding through every page.
      .environment(\.settingsNavigate) { navigate(.destination($0)) }
      // #3482: the arrival a search navigation asked for, nil for every other navigation.
      .environment(\.settingsReveal, navigationState.reveal)
      .environment(\.settingsRevealAcknowledge) { navigationState.acknowledgeReveal(token: $0) }
      .environment(\.settingsNavigationEpoch, navigationState.epoch)
      .environment(\.settingsArrivalStillCurrent) { reveal in
        navigationState.arrivalIsCurrent(token: reveal.token, entryID: reveal.entryID)
      }
  }
}


/// One toolbar owner shared by the shell and its offscreen layout harness.
struct SettingsWindowToolbar: ToolbarContent {
  var appName: String = AppConstants.appName
  // Literal render fixtures can exercise the existing German labels without
  // changing the process language or the user's catalog/defaults.
  var giftCaption: LocalizedStringResource = "What's New & Updates"
  var statusTextOverride: String? = nil
  var recordTitleOverride: String? = nil

  var body: some ToolbarContent {

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
        // macOS 26 gives adjacent items in one placement a SHARED Liquid Glass
        // capsule and packs them flush, so the record button's gradient pill was
        // drawn over the status badge and covered its words. `ToolbarSpacer` is
        // the documented way to split the run into separate groups. Both items
        // paint their own pill, so both hide the system capsule for the same
        // reason the principal wordmark does. Below macOS 26 there is no shared
        // capsule and no spacer API, so the pair stays as it was.
        if #available(macOS 26.0, *) {
          ToolbarItem(placement: .primaryAction) {
            StatusBadge(textOverride: statusTextOverride)
          }
          .sharedBackgroundVisibility(.hidden)
          ToolbarSpacer(.fixed, placement: .primaryAction)
          // #3153: feedback lives beside Record (founder, 2026-09-25). Its own group, so the
          // shared Liquid Glass capsule does not merge it into the record pill.
          ToolbarItem(placement: .primaryAction) {
            WhatsNewToolbarButton(caption: giftCaption)
          }
          .sharedBackgroundVisibility(.hidden)
          ToolbarSpacer(.fixed, placement: .primaryAction)
          ToolbarItem(placement: .primaryAction) {
            FeedbackToolbarButton()
          }
          .sharedBackgroundVisibility(.hidden)
          ToolbarSpacer(.fixed, placement: .primaryAction)
          ToolbarItem(placement: .primaryAction) {
            RecordButton(titleOverride: recordTitleOverride)
          }
          .sharedBackgroundVisibility(.hidden)
        } else {
          ToolbarItem(placement: .primaryAction) {
            StatusBadge(textOverride: statusTextOverride)
          }
          ToolbarItem(placement: .primaryAction) {
            WhatsNewToolbarButton(caption: giftCaption)
          }
          ToolbarItem(placement: .primaryAction) {
            FeedbackToolbarButton()
          }
          ToolbarItem(placement: .primaryAction) {
            RecordButton(titleOverride: recordTitleOverride)
          }
        }
        }

  /// The centered top-bar identity: the brand mark plus the app wordmark. Held
  /// as a property so the toolbar can wrap it in either the glass-hidden or the
  /// plain `ToolbarItem` depending on the OS, without duplicating the label.
  private var wordmarkToolbarLabel: some View {
    HStack(spacing: 7) {
      WisprLogoMark()
        .frame(width: 16, height: 16)
      Text(appName)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.stTextPrimary)
    }
    .fixedSize()
  }

}
