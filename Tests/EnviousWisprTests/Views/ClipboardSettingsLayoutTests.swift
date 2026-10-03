import AppKit
import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #3385: the Clipboard tab's four rows keep a bounded switch and readable text at every
/// window width. **When this fails, a switch claims the whole row again (a click on empty
/// space toggles a clipboard setting), or a row's text is cut instead of wrapping.**
///
/// The rows are built with the production `SettingsRow`, the page's own copy resources and the
/// page's exact switch modifiers (`ClipboardSettingsWiringTests` pins that the page uses those
/// modifiers); the real page is hosted whole for the width relation. Relations only; printed
/// sizes are this Mac's. Limits: plain buttons are not NSViews and there is no accessibility
/// tree here, so the "?" and switch hit rectangles and presses are final Live UAT.
@MainActor
@Suite("Clipboard settings layout (#3385)", .tags(.productOutcome))
struct ClipboardSettingsLayoutTests {

  init() { _ = NSApplication.shared }

  typealias Copy = DictationSettingsCopy.Clipboard

  /// Row widths inside the content card: the shell's page widths less the page margins and
  /// the card's row padding.
  static let rowWidths: [CGFloat] = [380, 508, 578, 1058].map {
    $0 - 2 * SettingsLayout.contentH - 2 * SettingsLayout.rowPaddingH
  }

  static let rows: [(LocalizedStringResource, LocalizedStringResource, LocalizedStringResource)] = [
    (Copy.autoCopyTitle, Copy.autoCopyShort, Copy.autoCopyHelp),
    (Copy.restoreTitle, Copy.restoreShort, Copy.restoreHelp),
    (Copy.smartInsertionTitle, Copy.smartInsertionShort, Copy.smartInsertionHelp),
    (Copy.quickAddTitle, Copy.quickAddShort, Copy.quickAddHelp),
  ]

  struct Frames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
      value.merge(nextValue()) { $1 }
    }
  }

  @MainActor final class Box { var frames: [String: CGRect] = [:] }

  static func probe(_ key: String) -> some View {
    GeometryReader { proxy in
      Color.clear.preference(key: Frames.self, value: [key: proxy.frame(in: .named("row"))])
    }
  }

  /// One production row at `width`: the switch's frame and the row's frame.
  static func measure(
    _ row: (LocalizedStringResource, LocalizedStringResource, LocalizedStringResource),
    width: CGFloat
  ) -> (toggle: CGRect, row: CGRect)? {
    let box = Box()
    let view = SettingsRow(icon: "doc.on.clipboard", title: row.0, short: row.1, help: row.2) {
      Toggle("", isOn: .constant(true))
        .labelsHidden()
        .toggleStyle(BrandedToggleStyle())
        .fixedSize()
        .accessibilityLabel(Text(row.0))
        .background(probe("toggle"))
    }
    .background(probe("row"))
    .frame(width: width)
    .fixedSize(horizontal: false, vertical: true)
    .coordinateSpace(name: "row")
    .onPreferenceChange(Frames.self) { value in MainActor.assumeIsolated { box.frames = value } }
    let host = NSHostingView(rootView: AnyView(view))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.contentView = nil
    guard let toggle = box.frames["toggle"], let frame = box.frames["row"] else { return nil }
    return (toggle, frame)
  }

  @Test("the Clipboard recording note stays visible at the minimum width")
  func recordingNoteVisible() throws {
    let frame = try LivePreviewSettingsLayoutTests.frame(width: 460) { probe in
      SettingsSectionHeading(resolvedTitle: "CLIPBOARD") {
        Text(DictationSettingsCopy.Engine.nextRecordingNote).font(.stHelper)
          .foregroundStyle(.stTextSecondary).fixedSize(horizontal: false, vertical: true)
          .background(probe)
      }
    }
    print("CLIPBOARD-NOTE visible=true frame=\(frame)")
    #expect(frame.width > 150 && frame.height >= 17)
    #expect(frame.minX >= 0 && frame.maxX <= 460)
  }

  @Test("every switch stays the size of its track, inside its row, at every width")
  func switchesAreBounded() throws {
    for width in Self.rowWidths {
      for row in Self.rows {
        let measured = try #require(Self.measure(row, width: width), "no frames at \(width)")
        print(
          "ClipboardRow width=\(width) title=\(String(localized: row.0)) toggle=\(measured.toggle) row=\(measured.row)"
        )
        #expect(measured.toggle.width > 20 && measured.toggle.width < 80, "\(measured.toggle)")
        #expect(measured.toggle.maxX <= width + 0.5, "the switch leaves its \(width)pt row")
        #expect(abs(measured.toggle.maxX - width) < 1, "the switch dropped below the text")
      }
    }
  }

  @Test("text wraps rather than being cut: a narrower row is never shorter")
  func rowsWrap() throws {
    for row in Self.rows {
      let heights = try Self.rowWidths.map {
        try #require(Self.measure(row, width: $0)).row.height
      }
      print(
        "ClipboardRowHeights title=\(String(localized: row.0)) widths=\(Self.rowWidths) heights=\(heights)"
      )
      #expect(heights.allSatisfy { $0 > 0 })
      #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 >= $1 }, "\(heights)")
    }
  }

  @Test("the real page is taller in a narrow window than a wide one, never empty")
  func pageReflows() {
    func height(_ pageWidth: CGFloat) -> CGFloat {
      let name = "ew.clipboardLayout." + UUID().uuidString
      let suite = TestDefaults.suite(name)!
      suite.removePersistentDomain(forName: name)
      let page = ClipboardSettingsView()
        .environment(SettingsManager(defaults: suite))
        .frame(width: pageWidth)
      let host = NSHostingView(rootView: AnyView(page))
      return host.fittingSize.height
    }
    let narrow = height(380)
    let wide = height(1058)
    print("ClipboardPage width=380 height=\(narrow) width=1058 height=\(wide)")
    #expect(narrow > 0 && wide > 0)
    #expect(narrow >= wide, "380pt page \(narrow) vs 1058pt page \(wide)")
  }
}
