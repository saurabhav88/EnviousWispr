import AppKit
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #3385: the Live Preview tab's controls keep their own targets. **When this fails, a click on
/// the empty middle of the row toggles Live Preview (measured once at 738pt wide, #2436), or the
/// install row's "?" is swallowed by the row's button.** Production components hosted here: the
/// shared `SettingsRow` action variant and `LivePreviewLanguageMenuButton`. The switch is the
/// production `BrandedToggleStyle` with the same modifiers the page applies to it.
///
/// Limits, measured in Chunk 4: this process exposes no accessibility tree and plain-style
/// buttons are not NSViews, so activation is not exercised here; frames are. The full page is
/// not hosted (it needs the delivery home and a pack catalogue); its presses, the switch's hit
/// bounds on the real page and the remedy are final Live UAT items.
@MainActor
@Suite("Live Preview settings layout (#3385)", .tags(.productOutcome))
struct LivePreviewSettingsLayoutTests {

  init() { _ = NSApplication.shared }

  static let minimumRowWidth: CGFloat = SettingsRowLayoutTests.minimumWindowRowWidth
  static let ordinaryRowWidth: CGFloat = SettingsRowLayoutTests.ordinaryWindowRowWidth

  @Test("the switch stays the size of its track inside a wide row")
  func toggleTargetIsBounded() throws {
    for width in [Self.minimumRowWidth, Self.ordinaryRowWidth] {
      let frame = try Self.frame(width: width) { probe in
        HStack {
          Spacer(minLength: 12)
          Toggle("", isOn: .constant(true))
            .labelsHidden()
            .toggleStyle(BrandedToggleStyle())
            .fixedSize()
            .background(probe)
        }
      }
      print("LivePreviewToggle width=\(width) frame=\(frame)")
      #expect(frame.width > 20 && frame.width < 80, "the switch is \(frame.width) wide in \(width)")
      #expect(abs(frame.maxX - width) < 1, "the switch sits at the trailing edge")
    }
  }

  @Test("the language button is its own bounded control")
  func languageButtonIsBounded() throws {
    let frame = try Self.frame(width: Self.minimumRowWidth) { probe in
      HStack {
        Spacer(minLength: 0)
        LivePreviewLanguageMenuButton(
          name: "Portuguese (Brazil)", provenance: "Auto, from your Mac", action: {}
        )
        .background(probe)
      }
    }
    print("LivePreviewLanguageButton frame=\(frame)")
    #expect(frame.width > 60 && frame.width < 260, "language button is \(frame.width) wide")
  }

  /// Chevron spacing only: the action row's trailing slot ends before the row does, leaving
  /// room for the "?". Whether the "?" is outside the button is structural, read by
  /// `LivePreviewSettingsWiringTests.actionRowHelpIsASibling`; plain-style buttons are not
  /// NSViews here, so the two controls' own rectangles cannot be measured (final Live UAT).
  @Test("the install row leaves room for its separate help button")
  func installRowKeepsHelpOutsideTheButton() throws {
    for width in [Self.minimumRowWidth, Self.ordinaryRowWidth] {
      let frame = try Self.frame(width: width) { probe in
        SettingsRow(
          icon: "arrow.down.circle",
          resolvedTitle: "Install new languages",
          resolvedShort: "Download a language from macOS to preview it.",
          resolvedHelp: "Help.",
          primaryAction: {}
        ) {
          Image(systemName: "chevron.right").background(probe)
        }
      }
      print("LivePreviewInstallRow width=\(width) chevron=\(frame)")
      #expect(frame.maxX < width - 12, "the chevron ends at \(frame.maxX); no room for help")
      #expect(frame.maxX > width - 60, "the chevron is not trailing: \(frame.maxX) in \(width)")
    }
  }

  @Test("Ready is below the short line; language moves below at 502pt and the switch alone stays trailing")
  func previewSecondaryControlPlacement() throws {
    for width: CGFloat in [432, 502, 503, 982] {
      let language = try Self.frame(width: width) { probe in
        SettingsRow(icon: "text.viewfinder", resolvedTitle: "Show words while you speak",
          resolvedShort: "See words before you finish your dictation.", resolvedHelp: "Help.") {
          Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(BrandedToggleStyle()).fixedSize()
        }
        .rowStatus { ProviderStatusChip(status: .init(label: "Ready", tone: .ready), isHeadline: true) }
        .rowSupplementaryControl(belowWidth: 502) {
          LivePreviewLanguageMenuButton(name: "English (United States)", provenance: "Auto · from your Mac", action: {})
            .background(probe)
        }
      }
      let toggle = try Self.frame(width: width) { probe in
        SettingsRow(icon: "text.viewfinder", resolvedTitle: "Show words while you speak",
          resolvedShort: "See words before you finish your dictation.", resolvedHelp: "Help.") {
          Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(BrandedToggleStyle()).fixedSize().background(probe)
        }
        .rowStatus { ProviderStatusChip(status: .init(label: "Ready", tone: .ready), isHeadline: true) }
        .rowSupplementaryControl(belowWidth: 502) {
          LivePreviewLanguageMenuButton(name: "English (United States)", provenance: "Auto · from your Mac", action: {})
        }
      }
      print("PREVIEW-R1 row=\(width) language=\(language) switch=\(toggle) below=\(width <= 502)")
      #expect(abs(toggle.maxX - width) < 1)
      if width <= 502 {
        #expect(language.minX == 37)
        #expect(language.minY >= toggle.maxY + 10)
      } else {
        #expect(language.maxX <= toggle.minX - 11)
      }
    }
  }

  // MARK: - Harness

  static let space = "live-preview-layout"

  static func frame<Content: View>(
    width: CGFloat, @ViewBuilder _ content: (AnyView) -> Content
  ) throws -> CGRect {
    let box = FrameBox()
    let probe = AnyView(
      GeometryReader { proxy in
        Color.clear.preference(key: FrameKey.self, value: proxy.frame(in: .named(space)))
      })
    let root = content(probe)
      .frame(width: width)
      .fixedSize(horizontal: false, vertical: true)
      .coordinateSpace(name: space)
      .onPreferenceChange(FrameKey.self) { value in
        MainActor.assumeIsolated { box.frame = value }
      }
    let host = NSHostingView(rootView: root)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.contentView = nil
    return try #require(box.frame, "the probe never reported a frame")
  }

  @MainActor final class FrameBox { var frame: CGRect? }

  struct FrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
      value = nextValue() ?? value
    }
  }
}
