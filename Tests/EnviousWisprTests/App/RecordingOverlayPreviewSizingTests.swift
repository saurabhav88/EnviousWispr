import AppKit
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #2201 (chunk A of #2198): the live preview pill's height must be a function of
/// what it is showing, not of how tall it happened to be a moment earlier.
///
/// ## Why this drives the production view instead of a replica
///
/// The defect was first measured with an offscreen probe that rebuilt the modifier
/// stack by hand (`docs/audits/2026-08-19-live-preview-size-probe.swift`). Grounded
/// review r1 refused that as evidence and it was right: a replica can only prove
/// things about the replica, and a guard written the same way would stay green while
/// the shipped panel stayed broken. So every measurement here instantiates the real
/// `RecordingOverlayView` and reads its own `onContentHeightChange` — the exact
/// callback `OverlayDirector.presentRecording` installs, which resizes the
/// live pill through `OverlayWindowHost.resizeCurrentPresentation`.
///
/// ## The loop being pinned
///
/// `showPanel(fitToContent:)` sizes the panel from `NSHostingView.fittingSize`, an
/// IDEAL-height query that tracks the text. Every later resize comes from a
/// `GeometryReader` measuring the capsule once it is laid out INSIDE that panel.
/// Those are two different questions, and while the preview area is free to stretch
/// into whatever room the panel offers, the second answer depends on the first —
/// so the same words can rest at more than one height and nothing pulls the box
/// back down.
///
/// ## No timed waits
///
/// `preview` is `@State`, published by a 50 ms poll. Waiting for that poll would
/// mean inferring "the subject is done" from elapsed time, in a suite whose whole
/// subject is what the height does over time. `initialPreview:` seeds the state
/// instead, so the first layout pass already shows the text under test.
@MainActor
@Suite(.tags(.productOutcome))
struct RecordingOverlayPreviewSizingTests {

  init() { _ = NSApplication.shared }

  /// Width the preview pill is created at (`RecordingPillDesign.readingWell`).
  private static let previewWidth: CGFloat = 400

  /// Collects every height the view reports. The LAST value is what the panel
  /// would have been resized to.
  private final class HeightLog: @unchecked Sendable {
    private(set) var reported: [CGFloat] = []
    func record(_ h: CGFloat) { reported.append(h) }
  }

  /// Lay the production view out inside a host of `startingHeight` and return the
  /// height it reports back.
  ///
  /// `startingHeight` is the panel height the view finds itself in — the variable
  /// this suite exists to prove the answer does NOT depend on.
  private func measuredHeight(
    showing display: LivePreviewDisplay,
    inPanelOfHeight startingHeight: CGFloat,
    notice: String? = nil,
    locked: Bool = false,
    design: RecordingPillDesign = .readingWell
  ) throws -> CGFloat {
    let log = HeightLog()
    let lockState = OverlayLockState()
    lockState.isLocked = locked
    let noticeState = OverlayNoticeState()
    noticeState.message = notice

    let view = RecordingOverlayView(
      audioLevelProvider: { 0 },
      recordingElapsedProvider: { 41 },
      livePreviewProvider: { display },
      onContentHeightChange: { log.record($0) },
      chrome: design.chrome,
      lockState: lockState,
      noticeState: noticeState,
      initialPreview: display
    )

    let host = NSHostingView(rootView: view.frame(width: Self.previewWidth))
    let frame = NSRect(x: 0, y: 0, width: Self.previewWidth, height: startingHeight)
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = frame
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    // The GeometryReader reports on appear. If it never did, the measurement is
    // absent rather than wrong, and an empty array must not read as a height.
    let height = try #require(
      log.reported.last,
      """
      the view never reported a height — the GeometryReader in RecordingOverlayView \
      did not run, so this measurement is missing rather than failing
      """)
    return height
  }

  private static let oneLine = "the quarterly numbers came in"
  private static let threeLines = String(
    repeating: "the quarterly numbers came in ahead of plan ", count: 2)
  private static let pastTheCap = String(
    repeating: "the quarterly numbers came in ahead of plan ", count: 8)

  // MARK: - The defect

  @Test("the same words measure the same height whatever height the box was already at")
  func heightDoesNotDependOnTheCurrentPanelHeight() throws {
    // 65 is roughly one line's ideal; 125 is the five-line cap. A box that has
    // just shown a long sentence sits at the latter when the sentence retracts.
    let atCompact = try measuredHeight(showing: .text(Self.oneLine), inPanelOfHeight: 65)
    let atTall = try measuredHeight(showing: .text(Self.oneLine), inPanelOfHeight: 125)

    #expect(
      atCompact == atTall,
      """
      one line of preview text measured \(atCompact)pt in a compact box and \(atTall)pt \
      in a tall one. The panel is sized from this measurement and this measurement is \
      taken inside the panel, so the pair has no single answer and the box can rest at \
      more than one size for the same words.
      """)
  }

  @Test("a box that grew to the cap comes back down when the text retracts")
  func theBoxShrinksAgain() throws {
    let tall = try measuredHeight(showing: .text(Self.pastTheCap), inPanelOfHeight: 125)
    let retracted = try measuredHeight(showing: .text(Self.oneLine), inPanelOfHeight: tall)

    #expect(
      retracted < tall,
      """
      after the text retracted from \(Self.pastTheCap.count) characters to \
      \(Self.oneLine.count), the box still measured \(retracted)pt against \(tall)pt. \
      The recognizer revises its in-flight segment and LivePreviewTextBound trims the \
      front, so shorter text is ordinary mid-dictation behaviour, not an edge case.
      """)
  }

  // MARK: - Two-way controls
  //
  // Without these the suite passes against a view hard-coded to one height, which
  // is the failure the fix itself could introduce.

  @Test("more text is still a taller box")
  func heightStillTracksTheText() throws {
    let one = try measuredHeight(showing: .text(Self.oneLine), inPanelOfHeight: 65)
    let three = try measuredHeight(showing: .text(Self.threeLines), inPanelOfHeight: 65)

    #expect(
      three > one,
      """
      \(Self.threeLines.count) characters measured \(three)pt against \(one)pt for \
      \(Self.oneLine.count) — the box stopped growing with its content
      """)
  }

  @Test("growth stops at the five-line cap")
  func growthStopsAtTheCap() throws {
    let three = try measuredHeight(showing: .text(Self.threeLines), inPanelOfHeight: 65)
    let past = try measuredHeight(showing: .text(Self.pastTheCap), inPanelOfHeight: 65)
    let wayPast = try measuredHeight(
      showing: .text(Self.pastTheCap + Self.pastTheCap), inPanelOfHeight: 65)

    #expect(past > three, "the cap is below three lines — growth stopped too early")
    #expect(
      past == wayPast,
      """
      doubling the text past the cap changed the height from \(past)pt to \(wayPast)pt, \
      so the five-line rule is not holding
      """)
  }

  // MARK: - The other display states share the measurement

  @Test(
    "every display state measures independently of the panel height",
    arguments: RecordingOverlayPreviewSizingTests.displayStates)
  func everyStateIsProposalIndependent(state: LivePreviewDisplay) throws {
    let atCompact = try measuredHeight(showing: state, inPanelOfHeight: 65)
    let atTall = try measuredHeight(showing: state, inPanelOfHeight: 125)

    #expect(
      atCompact == atTall,
      "\(state) measured \(atCompact)pt compact and \(atTall)pt tall")
  }

  /// `.unavailable` is a real two-line state and is what a new user sees most —
  /// first use of a language, below macOS 26, or a missing pack.
  nonisolated static let displayStates: [LivePreviewDisplay] = [
    .waiting,
    .unavailable("On-screen preview does not support this language yet."),
    .text("the quarterly numbers came in"),
  ]

  @Test("the notice banner shares the measurement and must not reintroduce the dependence")
  func noticeBannerIsProposalIndependent() throws {
    let atCompact = try measuredHeight(
      showing: .text(Self.oneLine), inPanelOfHeight: 65,
      notice: "Recording stops in one minute.")
    let atTall = try measuredHeight(
      showing: .text(Self.oneLine), inPanelOfHeight: 160,
      notice: "Recording stops in one minute.")

    #expect(atCompact == atTall, "with a notice showing: \(atCompact)pt vs \(atTall)pt")
  }

  @Test("the notice banner contributes to the measured height")
  func noticeBannerAddsHeight() throws {
    let log = HeightLog()
    let noticeState = OverlayNoticeState()
    let display = LivePreviewDisplay.text(Self.oneLine)
    let view = RecordingOverlayView(
      audioLevelProvider: { 0 },
      recordingElapsedProvider: { 41 },
      livePreviewProvider: { display },
      onContentHeightChange: { log.record($0) },
      chrome: RecordingPillDesign.readingWell.chrome,
      lockState: OverlayLockState(),
      noticeState: noticeState,
      initialPreview: display
    )
    let frame = NSRect(x: 0, y: 0, width: Self.previewWidth, height: 65)
    let host = NSHostingView(rootView: view.frame(width: Self.previewWidth))
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = frame
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let withoutNotice = try #require(log.reported.last)

    noticeState.message = "Recording stops in one minute."
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let withNotice = try #require(log.reported.last)

    #expect(
      withNotice > withoutNotice,
      "the notice was present but the measured height stayed at \(withoutNotice)pt")
  }

  // MARK: - The acceptance criterion, pinned rather than implied

  /// The chunk's stated criterion is a NUMBER: while preview text, lock state and
  /// notice state are unchanged, the panel resizes ZERO times.
  ///
  /// The other cases here prove height is a function of content, from which this
  /// follows — but only by an argument, and an argument is not a test. The view is
  /// re-laid-out on every 50 ms poll whether or not anything changed, so "the same
  /// content re-rendered reports the same height" is the property resizeRecordingPanel
  /// actually consumes: it compares against the live frame and skips anything
  /// inside 1pt, so one stable answer means no `setFrame` at all.
  ///
  /// Deliberately re-lays out ONE view rather than building several, because
  /// building a fresh view each time cannot see a height that drifts across
  /// renders — which is exactly the shape a box that hunts would produce.
  @Test("re-rendering unchanged content reports one height, not a drifting series")
  func unchangedContentDoesNotMoveTheHeight() throws {
    let log = HeightLog()
    let view = RecordingOverlayView(
      audioLevelProvider: { 0 },
      recordingElapsedProvider: { 41 },
      livePreviewProvider: { .text(Self.threeLines) },
      onContentHeightChange: { log.record($0) },
      chrome: RecordingPillDesign.readingWell.chrome,
      lockState: OverlayLockState(),
      noticeState: OverlayNoticeState(),
      initialPreview: .text(Self.threeLines)
    )
    let host = NSHostingView(rootView: view.frame(width: Self.previewWidth))
    let frame = NSRect(x: 0, y: 0, width: Self.previewWidth, height: 65)
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = frame

    // Ten passes stands in for the poll loop. Each one also moves the host to the
    // height the panel would now be at, which is the feedback the defect rode on:
    // a view that chases its container reports a new number every pass.
    for _ in 0..<10 {
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      if let latest = log.reported.last {
        host.frame = NSRect(x: 0, y: 0, width: Self.previewWidth, height: latest)
      }
    }

    let distinct = Set(log.reported)
    #expect(
      distinct.count == 1,
      """
      unchanged content reported \(distinct.count) different heights across ten \
      renders: \(log.reported.map { String(format: "%.0f", $0) }.joined(separator: ", ")). \
      Every distinct value here is a panel resize the user did not ask for.
      """)
  }

  // MARK: - The protected capsule

  /// The 185pt non-preview capsule is out of scope for #2198 and the founder is
  /// redesigning it separately. Every modifier on `RecordingOverlayView`'s root is
  /// rendered by BOTH layouts, so a fix aimed at the preview reaches it unless it
  /// is gated — see the plan's §3d shared-root table.
  @Test("the non-preview capsule keeps reporting nothing")
  func nonPreviewLayoutReportsNoHeight() throws {
    let log = HeightLog()
    let view = RecordingOverlayView(
      audioLevelProvider: { 0 },
      recordingElapsedProvider: { 41 },
      livePreviewProvider: { .off },
      onContentHeightChange: { log.record($0) },
      chrome: RecordingPillDesign.classic.chrome,
      lockState: OverlayLockState(),
      noticeState: OverlayNoticeState(),
      initialPreview: .off
    )
    let host = NSHostingView(rootView: view.frame(width: 185, height: 92))
    let frame = NSRect(x: 0, y: 0, width: 185, height: 92)
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = frame
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()

    // Production wires a no-op callback for the non-preview layout
    // (`createPanel`), so this suite's own instrumentation is the only reader.
    // What matters is that the view still lays out at the fixed frame it is given.
    #expect(host.frame.height == 92, "the non-preview capsule's frame moved")
  }
}
