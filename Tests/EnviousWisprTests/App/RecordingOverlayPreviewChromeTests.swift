import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #2202: the preview pill's header — timer hard left, live meter, mode on the
/// right.
///
/// The property worth protecting is that **the header is the same height in both
/// recording modes**. Today's capsule scales its mark to 2x when hands-free
/// locks, which is the single biggest height change anywhere in the pill; the
/// whole reason the mode moved onto a badge is that a badge costs no height. A
/// regression here does not look like a bug, it looks like the pill twitching
/// when you double-press, which is the class of thing #2201 just finished
/// removing.
@MainActor
@Suite(.tags(.productOutcome))
struct RecordingOverlayPreviewChromeTests {

  init() { _ = NSApplication.shared }

  private static let previewWidth: CGFloat = 400

  private final class HeightLog: @unchecked Sendable {
    private(set) var reported: [CGFloat] = []
    func record(_ h: CGFloat) { reported.append(h) }
  }

  /// Measure the whole pill with a KNOWN display state, in a given lock mode.
  private func pillHeight(
    locked: Bool,
    showing display: LivePreviewDisplay,
    design: RecordingPillDesign = .readingWell
  ) throws -> CGFloat {
    let log = HeightLog()

    let view = RecordingOverlayView(
      audioLevelProvider: { 0.4 },
      recordingElapsedProvider: { 127 },
      livePreviewProvider: { display },
      onContentHeightChange: { log.record($0) },
      chrome: design.chrome,
      isLocked: locked,
      noticeText: nil,
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

    return try #require(
      log.reported.last,
      "the view never reported a height — the measurement is missing, not failing")
  }

  // MARK: - The property the badge exists to buy

  @Test("the preview pill is the same height in hold-to-talk and hands-free")
  func headerHeightIsIdenticalAcrossModes() throws {
    let text = LivePreviewDisplay.text("the quarterly numbers came in ahead of plan")
    let unlocked = try pillHeight(locked: false, showing: text)
    let locked = try pillHeight(locked: true, showing: text)

    #expect(
      unlocked == locked,
      """
      hold-to-talk measured \(unlocked)pt and hands-free \(locked)pt for the same \
      words. The mode must not change the pill's size — that is the whole reason \
      it is carried on a badge rather than by scaling the mark.
      """)
  }

  @Test(
    "no display state makes the mode change the pill's height",
    arguments: RecordingOverlayPreviewChromeTests.displayStates)
  func modeIsHeightNeutralInEveryState(state: LivePreviewDisplay) throws {
    let unlocked = try pillHeight(locked: false, showing: state)
    let locked = try pillHeight(locked: true, showing: state)
    #expect(unlocked == locked, "\(state): \(unlocked)pt unlocked vs \(locked)pt locked")
  }

  nonisolated static let displayStates: [LivePreviewDisplay] = [
    .waiting,
    .unavailable("On-screen preview does not support this language yet."),
    .text("the quarterly numbers came in"),
  ]

  // MARK: - The capsule is untouched
  //
  // The 185pt non-preview capsule is out of scope for #2198; the founder is
  // redesigning it separately.
  //
  // **The first version of this test asserted the capsule CHANGES height with the
  // mode, and it was wrong** — a premise written from the design's own
  // justification instead of from a measurement. `scaleEffect` is a rendering
  // transform and does not participate in layout: an `HStack` holding a 24pt box
  // reports `fittingSize` 95x44 at `scaleEffect(1.0)` and 95x44 at 2.0. The
  // capsule is already height-neutral; the 2x mark overflows its slot visually.
  // Removing the timer does not change height either, because the 24pt mark is
  // taller than the 13pt text beside it.
  //
  // So the useful guard is not "does it still change" but "is it still exactly
  // what it was", pinned to the measured value.

  /// The capsule's content height, measured on `main` before #2202 touched
  /// anything: 24pt mark + 10pt vertical padding either side.
  private static let capsuleContentHeight: CGFloat = 44

  @Test(
    "the capsule's height is untouched by this chunk, in both modes",
    arguments: [false, true])
  func capsuleHeightIsPinned(locked: Bool) throws {
    let height = try pillHeight(locked: locked, showing: .off, design: .classic)
    #expect(
      height == Self.capsuleContentHeight,
      """
      the capsule measured \(height)pt (locked: \(locked)), not the \
      \(Self.capsuleContentHeight)pt it has always been. This chunk is gated on \
      its own chrome and must not reach the layout the founder reserved.
      """)
  }

  // MARK: - The padding migration left nothing behind

  /// #2202 zeroes the shared root padding for the preview layout and gives each
  /// section its own. **The notice banner is the third section and it was missed**
  /// — a two-part edit whose second half failed its safety check aborted the whole
  /// script before writing, and only the half that was retried landed. Cloud
  /// review caught it; nothing in this suite did, because every other case used a
  /// notice-free pill.
  ///
  /// The property: a preview pill showing a notice must be TALLER than the same
  /// pill without one by more than the text itself, which is only true if the
  /// notice carries an inset. Asserting the padding constant would test the
  /// constant; asserting the height tests the outcome.
  @Test("a notice inside the preview pill keeps an inset of its own")
  func noticeKeepsItsInsetAfterThePaddingMigration() throws {
    let text = LivePreviewDisplay.text("the quarterly numbers came in")
    let without = try pillHeight(locked: false, showing: text)

    let log = HeightLog()
    let view = RecordingOverlayView(
      audioLevelProvider: { 0.4 },
      recordingElapsedProvider: { 127 },
      livePreviewProvider: { text },
      onContentHeightChange: { log.record($0) },
      chrome: RecordingPillDesign.readingWell.chrome,
      isLocked: false,
      noticeText: "Recording stops in one minute.",
      initialPreview: text
    )
    let host = NSHostingView(rootView: view.frame(width: Self.previewWidth))
    let frame = NSRect(x: 0, y: 0, width: Self.previewWidth, height: 65)
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = frame
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let with = try #require(log.reported.last, "the notice pill never reported a height")

    // One line of 11pt notice text is ~14pt. Anything at or below that means the
    // notice is sitting flush against the pill's bottom edge.
    let grew = with - without
    #expect(
      grew > 20,
      """
      adding a notice grew the preview pill by only \(grew)pt, which is about the \
      text alone. The notice lost its inset when the shared root padding was zeroed \
      and is flush against the pill's edge.
      """)
  }

  // MARK: - Copy

  @Test("both header words are the ones the design names")
  func headerCopyIsWhatShipped() {
    #expect(LivePreviewCopy.listeningMode == "Listening")
    #expect(LivePreviewCopy.handsFreeMode == "Hands-free")
  }

  /// The pill's copy avoids the word "live" — a constraint that already exists on
  /// this enum and that a new string is the likeliest thing to break.
  @Test("the new header strings keep the pill's no-live rule")
  func headerCopyAvoidsLive() {
    for s in [LivePreviewCopy.listeningMode, LivePreviewCopy.handsFreeMode] {
      #expect(
        !s.lowercased().contains("live"),
        "\"\(s)\" reintroduces the word the pill's copy deliberately avoids")
    }
  }

  /// #2202: the header says `Listening`, so the reading well must not say it too.
  /// A first-time user's very first sight of this feature is the waiting state,
  /// and the same word twice in one small box is worse than either alone.
  ///
  /// #2222: THIS COMPARISON USED TO BE `.waiting` AGAINST `.text("")`, WHICH IS
  /// EQUAL BY CONSTRUCTION — both rendered the same `previewText("")`, so the
  /// assertion could not fail, while this comment claimed the well "renders
  /// nothing". It rendered an empty well: 75pt against the header's 34pt.
  /// The binding comparison is `.off`, which is the only state that genuinely
  /// draws no well, and it is what "one header tall" has to mean.
  @Test("the waiting state is header-only in the preview layout")
  func waitingIsHeaderOnly() throws {
    let waiting = try pillHeight(locked: false, showing: .waiting)
    let headerOnly = try pillHeight(locked: false, showing: .off)

    #expect(
      waiting == headerOnly,
      """
      the waiting state measured \(waiting)pt against \(headerOnly)pt for the \
      header alone. Before any words arrive the preview pill must not reserve a \
      well, or a normal recording visibly resizes before the user has spoken.
      """)
  }

  /// The paired ACCEPTED case, so the fix above cannot be satisfied by emptying
  /// every layout. The capsule has no header, so it is the one place the waiting
  /// sentence still has to appear — and a guard that only checks the preview side
  /// would report clean after silently deleting it.
  @Test("the capsule still says something while waiting, because it has no header")
  func capsuleWaitingKeepsItsSentence() throws {
    let waiting = try pillHeight(locked: false, showing: .waiting, design: .classic)
    let off = try pillHeight(locked: false, showing: .off, design: .classic)

    #expect(
      waiting > off,
      """
      the capsule's waiting state measured \(waiting)pt against \(off)pt with the \
      preview off. The capsule draws no header, so removing its waiting sentence \
      would leave a user with no indication anything is listening.
      """)
  }
}
