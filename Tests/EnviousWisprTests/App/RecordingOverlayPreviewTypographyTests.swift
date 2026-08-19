import AppKit
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #2203: the preview pill's reading well.
///
/// **The property under test is that five lines still means five lines.** Before
/// this chunk the type size lived in two independent literals — the `Text`'s own
/// `.font(.system(size: 12))` and a second hardcoded 12 inside `previewHeight` —
/// with a doc comment asserting the cap "tracks the type size", which it did not.
/// Raising one without the other silently changes how many lines fit, and nothing
/// would have gone red.
///
/// Bigger type also needs `lineSpacing`, and a cap that counts only glyph heights
/// under-measures by one gap per line boundary. Both of those turn "five lines"
/// into four-and-a-bit without changing any number that looks like a line count.
@MainActor
@Suite(.tags(.productOutcome))
struct RecordingOverlayPreviewTypographyTests {

  init() { _ = NSApplication.shared }

  private static let previewWidth: CGFloat = 400

  private final class HeightLog: @unchecked Sendable {
    private(set) var reported: [CGFloat] = []
    func record(_ h: CGFloat) { reported.append(h) }
  }

  private func pillHeight(showing display: LivePreviewDisplay) throws -> CGFloat {
    let log = HeightLog()
    let view = RecordingOverlayView(
      audioLevelProvider: { 0 },
      recordingElapsedProvider: { 41 },
      livePreviewProvider: { display },
      onContentHeightChange: { log.record($0) },
      usesPreviewLayout: true,
      lockState: OverlayLockState(),
      noticeState: OverlayNoticeState(),
      initialPreview: display
    )
    let host = NSHostingView(rootView: view.frame(width: Self.previewWidth))
    let frame = NSRect(x: 0, y: 0, width: Self.previewWidth, height: 65)
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = frame
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    return try #require(log.reported.last, "the view never reported a height")
  }

  /// Roughly one line at 400pt wide, then multiples of it.
  private static func words(lines: Int) -> String {
    String(repeating: "the quarterly numbers came in ahead of plan and we should ", count: lines)
  }

  // MARK: - The cap counts gaps, not just glyphs

  @Test("the cap counts the gaps between lines, not only the lines")
  func capIncludesLineSpacing() {
    let one = RecordingOverlayView.previewHeight(lines: 1)
    let two = RecordingOverlayView.previewHeight(lines: 2)
    let five = RecordingOverlayView.previewHeight(lines: 5)

    // Two lines cost one gap more than twice one line.
    #expect(
      two == one * 2 + RecordingOverlayView.previewLineSpacing,
      """
      two lines measured \(two)pt against \(one * 2)pt for twice one line. The cap \
      is not counting the gap between them, so the last line clips.
      """)

    // Five lines cost four gaps.
    #expect(
      five == one * 5 + RecordingOverlayView.previewLineSpacing * 4,
      "five lines measured \(five)pt, which is not five glyph heights plus four gaps")
  }

  @Test("one line has no gap to count")
  func singleLineHasNoGap() {
    let font = NSFont.systemFont(ofSize: RecordingOverlayView.previewFontSize)
    let glyph = ceil(font.ascender - font.descender + font.leading)
    #expect(RecordingOverlayView.previewHeight(lines: 1) == glyph)
  }

  @Test("a zero-line cap does not go negative on the gap count")
  func zeroLinesIsSafe() {
    #expect(RecordingOverlayView.previewHeight(lines: 0) == 0)
  }

  // MARK: - The type size has ONE home

  /// The defect this chunk exists to remove: two literals that had to agree.
  /// If someone changes the font on the `Text` without changing the constant, the
  /// rendered line height stops matching the cap and the fifth line clips.
  @Test("the cap is derived from the same size the text renders at")
  func capTracksTheTextsOwnFontSize() {
    let font = NSFont.systemFont(ofSize: RecordingOverlayView.previewFontSize)
    let glyph = ceil(font.ascender - font.descender + font.leading)
    let five = RecordingOverlayView.previewHeight(lines: 5)

    #expect(
      five == glyph * 5 + RecordingOverlayView.previewLineSpacing * 4,
      """
      the five-line cap is \(five)pt but the type actually renders at \
      \(RecordingOverlayView.previewFontSize)pt, whose lines are \(glyph)pt. The cap \
      and the text have drifted apart again.
      """)
  }

  // MARK: - What the user sees

  /// **Asserts the PROPERTY, not a guess about where the text wraps.**
  ///
  /// The first version of this walked 1...5 repetitions of a sample sentence and
  /// required each to be strictly taller than the last. It failed at 162pt — the
  /// capped height — because at 14pt one repetition wraps to more than one line,
  /// so the box reached its cap before the loop reached 5. The test had encoded a
  /// guess about text metrics as though it were the rule.
  ///
  /// What the founder's rule actually says is: grow a line at a time, then hold.
  /// So: never shrink as text is added, grow in several distinct steps rather than
  /// jumping straight to the cap, and end flat.
  @Test("the box grows in steps as text is added, then holds")
  func growthIsSteppedThenFlat() throws {
    var heights: [CGFloat] = []
    for units in 1...10 {
      heights.append(try pillHeight(showing: .text(Self.words(lines: units))))
    }

    for (i, h) in heights.enumerated() where i > 0 {
      #expect(
        h >= heights[i - 1],
        """
        adding text SHRANK the box at step \(i + 1): \(heights[i - 1])pt -> \(h)pt. \
        Sequence: \(heights.map { String(format: "%.0f", $0) }.joined(separator: ", "))
        """)
    }

    let distinct = Set(heights).count
    #expect(
      distinct >= 4,
      """
      only \(distinct) distinct heights across ten lengths: \
      \(heights.map { String(format: "%.0f", $0) }.joined(separator: ", ")). The box \
      is meant to grow a line at a time, not jump to its cap.
      """)

    #expect(
      heights.last == heights[heights.count - 2],
      "the box was still growing at the longest text — the cap is not holding")
  }

  @Test("past five lines the box stops growing")
  func growthStopsAtFive() throws {
    let five = try pillHeight(showing: .text(Self.words(lines: 5)))
    let eight = try pillHeight(showing: .text(Self.words(lines: 8)))
    let twenty = try pillHeight(showing: .text(Self.words(lines: 20)))

    #expect(
      eight == twenty, "eight lines \(eight)pt vs twenty \(twenty)pt — the cap is not holding")
    #expect(
      eight >= five,
      "eight lines measured \(eight)pt, less than five lines at \(five)pt")
  }

  @Test("a box at the cap returns to one-line height when the text retracts")
  func theCapIsNotAOneWayDoor() throws {
    let long = try pillHeight(showing: .text(Self.words(lines: 8)))
    let short = try pillHeight(showing: .text("back to one line"))
    #expect(short < long, "retracted to \(short)pt from \(long)pt")
  }
}
