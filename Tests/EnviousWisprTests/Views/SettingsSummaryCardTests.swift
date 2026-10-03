import AppKit
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #3385: the shared summary card (used first by the Engine tab). Collapsed, it shows the
/// current choice; expanded, the choices. **Whatever needs the user's attention (a download's
/// progress and Cancel, a warning, a remedy) stays on screen in BOTH states**, and at the
/// 750-point minimum window nothing spills out of the card. When this fails, a user opens the
/// engine choices and loses sight of the download they were watching, or cannot reach Change.
/// The card is the production component; only its three slots are fixed-size stand-ins whose
/// frames the test can read.
@MainActor
@Suite("Settings summary card (#3385)", .tags(.productOutcome))
struct SettingsSummaryCardTests {

  init() { _ = NSApplication.shared }

  /// The Engine tab's content width in the 750-point window: 750, minus three 14-point frame
  /// insets, the 200-point sidebar and the content card's two 24-point margins.
  static let minimumWidth: CGFloat = 750 - 14 * 3 - 200 - 24 * 2

  @Test("collapsed: summary and status show, the choices do not")
  func collapsed() throws {
    let frames = try Self.measure(width: Self.minimumWidth + 300, expanded: false)
    #expect(frames["summary"] != nil, "summary missing: \(frames)")
    #expect(frames["status"] != nil, "status missing: \(frames)")
    #expect(frames["choices"] == nil, "choices shown while collapsed: \(frames)")
  }

  @Test("expanded: the choices and the status show, the summary does not")
  func expanded() throws {
    let frames = try Self.measure(width: Self.minimumWidth + 300, expanded: true)
    #expect(frames["choices"] != nil, "choices missing: \(frames)")
    #expect(frames["status"] != nil, "status hidden while the choices are open: \(frames)")
    #expect(frames["summary"] == nil, "summary still shown while expanded: \(frames)")
  }

  @Test("at the 750-point minimum every part stays inside the card's width")
  func minimumWidthContainment() throws {
    let width = Self.minimumWidth
    #expect(width == 460, "the minimum content width moved to \(width); recheck the fixture")
    for expanded in [false, true] {
      let frames = try Self.measure(width: width, expanded: expanded)
      #expect(frames.isEmpty == false, "the harness returned nothing, which is not a pass")
      for (name, frame) in frames {
        #expect(frame.minX >= -0.5 && frame.maxX <= width + 0.5, "\(name) at \(frame) in \(width)")
      }
      // The status region shares the summary surface's 14pt inset in both states.
      #expect(abs((frames["status"]?.minX ?? -1) - 14) < 0.5, "status at \(String(describing: frames["status"]))")
    }
  }

  // Pressing Change and Keep current engine is NOT tested here, by measurement: in this test
  // process the hosted card's accessibility tree is a single empty AXGroup (no buttons are
  // exposed without an accessibility client), and plain-style SwiftUI buttons are not NSViews,
  // so there is nothing to press. The presses are verified on the rebuilt app instead: the
  // UI harness's backend switch opens "Change speech engine" and reads the cards, and PR1's
  // Live UAT presses "Keep current engine" and checks the cards close.

  // MARK: - Harness

  static func measure(width: CGFloat, expanded: Bool) throws -> [String: CGRect] {
    @MainActor final class Box { var frames: [String: CGRect] = [:] }
    let box = Box()
    let root = SettingsSummaryCard(
      isExpanded: .constant(expanded),
      changeAccessibilityLabel: LocalizedStringResource(stringLiteral: "Change speech engine"),
      keepCurrentTitle: LocalizedStringResource(stringLiteral: "Keep current engine")
    ) {
      Self.probe("summary", width: 200, height: 40)
    } status: {
      Self.probe("status", width: 300, height: 28)
    } choices: {
      Self.probe("choices", width: 400, height: 120)
    }
    .frame(width: width)
    .fixedSize(horizontal: false, vertical: true)
    .coordinateSpace(name: space)
    .onPreferenceChange(FramesKey.self) { frames in
      MainActor.assumeIsolated { box.frames = frames }
    }
    let host = NSHostingView(rootView: root)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    print("SettingsSummaryCard width=\(width) expanded=\(expanded) frames=\(box.frames)")
    window.contentView = nil
    return box.frames
  }

  static let space = "summary-card"

  static func probe(_ name: String, width: CGFloat, height: CGFloat) -> some View {
    Color.gray
      .frame(width: width, height: height)
      .background(
        GeometryReader { proxy in
          Color.clear.preference(key: FramesKey.self, value: [name: proxy.frame(in: .named(space))])
        })
  }

  struct FramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
      value.merge(nextValue()) { $1 }
    }
  }
}
