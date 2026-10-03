import AppKit
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #3385: where a request to open Settings lands, and which tab a page shows when the user
/// comes back to it. **When this fails, the user lands on the wrong screen or loses the tab
/// they were on.** Everything here is the real reducer the window uses
/// (`SettingsNavigationState`), not a copy of its logic.
@Suite("Settings destinations and remembered tabs", .tags(.productOutcome))
struct SettingsDestinationTests {

  @Test("a fresh window opens on History with Engine as the Dictation tab")
  func freshDefaults() {
    let state = SettingsNavigationState()
    #expect(state.selectedPage == .history)
    #expect(state.dictationTab == .engine)
  }

  @Test("returning to Dictation Settings from the sidebar shows the tab used last")
  func sidebarReturnRemembersTheTab() {
    var state = SettingsNavigationState()
    state.apply(.dictation(.chimes))
    state.selectSidebar(.keybinds)
    #expect(state.selectedPage == .keybinds)
    state.selectSidebar(.dictation)
    #expect(state.selectedPage == .dictation)
    #expect(state.dictationTab == .chimes)
  }

  @Test("a request for a tab goes there and becomes the remembered tab")
  func explicitDestinationOverrides() {
    var state = SettingsNavigationState()
    state.apply(.dictation(.clipboard))
    state.apply(.dictation(.microphone))
    #expect(state.selectedPage == .dictation)
    #expect(state.dictationTab == .microphone)
    state.selectSidebar(.history)
    state.selectSidebar(.dictation)
    #expect(state.dictationTab == .microphone)
  }

  @Test("opening another page by request keeps the remembered Dictation tab")
  func standaloneDestinationKeepsTheTab() {
    var state = SettingsNavigationState()
    state.apply(.dictation(.livePreview))
    state.apply(.appSettings(.permissions))
    #expect(state.selectedPage == .appSettings)
    #expect(state.dictationTab == .livePreview)
  }

  /// Every destination names its page; written out case by case so a new destination that
  /// maps to the wrong page cannot pass by sharing a default.
  @Test("every destination lands on its own page")
  func destinationPages() {
    let expected: [(SettingsDestination, SettingsPage)] = [
      (.history, .history),
      (.keybinds, .keybinds), (.transcribeFile, .transcribeFile), (.aiPolish, .aiPolish),
      (.dictionary, .dictionary), (.snippets, .snippets),
      (.appSettings(.appearance), .appSettings),
    ]
    for (destination, page) in expected {
      #expect(destination.page == page, "\(destination) landed on \(destination.page)")
    }
    for tab in DictationTab.allCases {
      #expect(SettingsDestination.dictation(tab).page == .dictation)
    }
    #if DEBUG
      #expect(SettingsDestination.diagnostics.page == .diagnostics)
    #endif
  }

  // The superseded one-row height assertion now lives in
  // SettingsTabStripLayoutTests: founder 2026-10-02 (#3385) requires wrapping.

  /// The actual strip, above flexible content. Wrapping replaces the one-row
  /// outcome by founder decision 2026-10-02 (#3385); the height reader remains.
  @MainActor
  static func stripHeight(width: CGFloat, parentHeight: CGFloat) throws -> CGFloat {
    @MainActor final class Box { var height: CGFloat? }
    let box = Box()
    let root = VStack(spacing: 0) {
      SettingsTabStrip(
        items: DictationTab.allCases.map {
          SettingsTabItem(id: $0, icon: $0.icon, label: $0.label)
        }, selection: .constant(DictationTab.engine))
      .background(GeometryReader { proxy in
        Color.clear.preference(key: StripHeightKey.self, value: proxy.size.height)
      })
      Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(width: width, height: parentHeight)
    .onPreferenceChange(StripHeightKey.self) { value in
      MainActor.assumeIsolated { box.height = value }
    }
    let host = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: parentHeight),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.contentView = nil
    return try #require(box.height, "the strip never reported a height")
  }

  struct StripHeightKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
      value = nextValue() ?? value
    }
  }

  @Test("every explicit tab becomes the remembered tab across sidebar navigation")
  func everyTabRemembersAndOverrides() {
    for tab in DictationTab.allCases {
      var state = SettingsNavigationState()
      state.apply(.dictation(.clipboard))
      state.apply(.dictation(tab))
      #expect(state.dictationTab == tab)
      state.selectSidebar(.history)
      state.selectSidebar(.dictation)
      #expect(state.selectedPage == .dictation)
      #expect(state.dictationTab == tab)
    }
  }

  @Test("the sidebar has eight release rows, and Dictation Settings is in RECORD")
  func sidebarRows() {
    let release = SettingsPage.allCases.filter {
      #if DEBUG
        return $0 != .diagnostics
      #else
        return true
      #endif
    }
    #expect(release.count == 8)
    #expect(SettingsPage.dictation.group == .record)
  }

  @Test("each Dictation tab has its own icon")
  func tabIcons() {
    #expect(
      DictationTab.allCases.map(\.icon) == [
        "waveform", "mic", "text.viewfinder", "capsule", "bell.and.waveform", "clipboard",
      ])
  }
}
