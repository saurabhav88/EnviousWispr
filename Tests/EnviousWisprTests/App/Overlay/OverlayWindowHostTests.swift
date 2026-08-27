import AppKit
import CoreGraphics
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprAppKit
import EnviousWisprAppKitTestSupport

/// #2292 chunk C3. The retained window.
///
/// **Product Outcome.** When these fail the user sees the pill flicker as it is
/// destroyed and rebuilt (#930), jump sideways after they dragged it (#2195), or
/// a hidden window keeps swallowing clicks over an empty patch of screen.
///
/// **These build NO window (#2455 C4).** They used to: the recorder was an
/// `NSPanel` subclass, so every case here displayed a real pill for as long as the
/// suite ran. The host now drives an `OverlayPanelDriving` and the recorder is
/// inert. What is asserted — which commands, in which order, with which geometry —
/// is unchanged, because none of it was ever about AppKit's response.
/// The probe on 2026-08-21 established what a retained panel costs
/// (`docs/audits/2026-08-21-overlay-probe-results.md`); this suite establishes
/// that OUR host retains exactly one and places it correctly. Screens are faked
/// so geometry is deterministic and a full-screen space is reachable, neither of
/// which a test can arrange on a real display.
///
/// **Every case observes the panel through an `OverlayPanelCommandRecorder`
/// rather than a `#if DEBUG` accessor on the host (#2377, P6-C2).** That is what
/// lets this whole file — and its production counterpart — build and run in
/// RELEASE: the recorder is a pure `OverlayPanelDriving` implementation injected
/// through the same `DesktopOverlayEffects` seam production code uses, not a
/// compiled-out hatch.
@MainActor
@Suite(.tags(.productOutcome))
struct OverlayWindowHostTests {

  init() { _ = NSApplication.shared }

  private static let screen = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860))

  /// The same display with a full-screen space present. `visibleFrame` does NOT
  /// shrink when another app goes full screen (#1341, measured 2026-07-17), so
  /// the Bottom rule drops to the true screen edge instead.
  private static let fullScreened = ScreenGeometry(
    id: ScreenID(rawValue: 1),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    visibleFrame: CGRect(x: 0, y: 85, width: 1512, height: 860),
    hasFullScreenSpace: true)

  private static func makeHost(
    _ geometry: @escaping @autoclosure () -> ScreenGeometry = screen,
    effects: DesktopOverlayEffects = .recording()
  ) -> OverlayWindowHost {
    OverlayWindowHost(
      screens: { OverlayScreenResolver { geometry() } }, effects: effects)
  }

  private static func host(effects: DesktopOverlayEffects = .recording()) -> OverlayWindowHost {
    makeHost(effects: effects)
  }

  /// A view whose FRAME and FITTING size are independently settable.
  ///
  /// **The earlier fixture made every value coincide**, so no test could tell a
  /// `.fixed` width from a fitting size from a frame fallback — three different
  /// code paths producing one indistinguishable number. Cloud review named it;
  /// a plain `NSView` also reports `fittingSize == .zero`, which is what made
  /// the coincidence invisible.
  private final class SizedView: NSView {
    var fitting: NSSize = .zero
    override var intrinsicContentSize: NSSize { fitting }
  }

  private static func view(
    width: CGFloat, height: CGFloat, fitting: NSSize? = nil
  ) -> SizedView {
    let v = SizedView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    v.fitting = fitting ?? .zero
    return v
  }

  /// **The headline metric of the whole change.** The shipped panel destroys and
  /// rebuilds itself on every panel-replacing transition, and four compensating
  /// mechanisms exist only because of that.
  @Test("one panel is constructed however many presentations arrive")
  func onePanelForEveryPresentation() {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    for i in 0..<12 {
      h.present(
        Self.view(width: 185 + CGFloat(i), height: 44), width: .fixed(185 + CGFloat(i)),
        fixedHeight: nil, isFresh: i == 0, position: .bottom)
    }
    h.hide()
    h.present(
      Self.view(width: 320, height: 120), width: .fixed(320), fixedHeight: nil, isFresh: true,
      position: .bottom)

    #expect(recorder.constructionCount == 1)
  }

  /// #2195 end to end through the host, not just through the placement value.
  @Test("a continuing presentation keeps the pill where the user dragged it")
  func continuingKeepsTheDraggedPosition() throws {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(recorder.panel)

    // The user drags it well left of centre. the driver's synchronous `onMove` callback is how the host
    // learns; there is no rebuild for the fact to survive.
    // #2455 C4: one call replaces the setFrameOrigin + delegate-notification pair. The
    // driver owns the delegate relationship now, so a test says what the USER did
    // rather than reproducing AppKit\'s notification plumbing.
    panel.simulateUserMove(to: CGPoint(x: 120, y: 85))

    h.present(
      Self.view(width: 320, height: 120), width: .fixed(320), fixedHeight: nil, isFresh: false,
      position: .bottom)

    #expect(panel.frame.origin.x == 120, "the pill snapped back to centre — this is #2195")
  }

  /// The paired case: a genuinely FRESH presentation must still centre, or the
  /// guard above is satisfied by a host that never centres anything.
  @Test("a fresh presentation is centred even after a drag")
  func freshRecentresAfterADrag() throws {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(recorder.panel)
    // #2455 C4: one call replaces the setFrameOrigin + delegate-notification pair. The
    // driver owns the delegate relationship now, so a test says what the USER did
    // rather than reproducing AppKit\'s notification plumbing.
    panel.simulateUserMove(to: CGPoint(x: 120, y: 85))
    h.hide()

    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)

    // EXACT, not within a point (#2455 C4). The tolerance existed because AppKit
    // aligns a real window frame to whole points, so a placement value of 663.5
    // landed at 663.0. The recorder stores the `CGRect` it was handed, so there is
    // no rounding to absorb — and a tolerance with nothing to absorb is slack that
    // hides real drift.
    #expect(panel.frame.origin.x == Self.screen.visibleFrame.midX - 92.5)
  }

  /// **A programmatic move is not a drag**, and telling them apart is what makes
  /// anchor promotion safe. The probe measured `NSEvent.pressedMouseButtons`
  /// reading 0 even mid-drag, so the depth flag is the only working
  /// discriminator and this is its guard.
  ///
  /// **Observed through the FRAME, not `placementForTesting`.** A programmatic
  /// move wrongly promoted to a drag is invisible in isolation — the panel is
  /// still exactly where the host put it — so the proof is a SECOND, continuing
  /// presentation: an anchored pill preserves X; a merely-repositioned one
  /// recentres. `continuingKeepsTheDraggedPosition` is this test's mirror image.
  @Test("the host's own frame changes never count as a user drag")
  func programmaticMovesAreNotDrags() throws {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(recorder.panel)
    // Every present/resize/reposition below moves the panel, and each fires
    // the driver's `onMove` callback for real.
    h.resizeCurrentPresentation(to: CGSize(width: 240, height: 60))
    h.repositionForActiveSpaceChange()
    h.present(
      Self.view(width: 300, height: 60), width: .fixed(300), fixedHeight: nil, isFresh: false,
      position: .bottom)

    let recentredX = Self.screen.visibleFrame.midX - 300 / 2
    #expect(
      abs(panel.frame.origin.x - recentredX) <= 0.5,
      """
      the host mistook its own frame change for the user dragging the pill, so the \
      continuation preserved X instead of recentring
      """)
  }

  @Test("a real drag does count")
  func aRealDragCounts() throws {
    // Paired with the case above: a host that never promotes would recentre
    // here too.
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(recorder.panel)
    // #2455 C4: one call replaces the setFrameOrigin + delegate-notification pair. The
    // driver owns the delegate relationship now, so a test says what the USER did
    // rather than reproducing AppKit\'s notification plumbing.
    panel.simulateUserMove(to: CGPoint(x: 400, y: 300))

    // The same proof as `continuingKeepsTheDraggedPosition`: a continuation
    // preserves X only when the drag was recorded as user-anchored.
    h.present(
      Self.view(width: 320, height: 120), width: .fixed(320), fixedHeight: nil, isFresh: false,
      position: .bottom)

    #expect(
      panel.frame.origin.x == 400,
      """
      the drag was not recorded as user-anchored, so the continuation recentred instead of \
      preserving X
      """)
  }

  /// `orderOut`, never `close`. Closing is what forces the rebuild.
  @Test("hiding orders the panel out and keeps it alive")
  func hideOrdersOutWithoutClosing() throws {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(recorder.panel)
    #expect(panel.isVisible)

    h.hide()

    #expect(panel.isVisible == false, "a hidden panel still on screen swallows clicks")
    #expect(recorder.panel === panel, "hiding released the panel — it must be retained")
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    #expect(recorder.constructionCount == 1, "showing after a hide rebuilt the panel")
  }

  /// **The recorder's own coverage.** Every other test in this file reads
  /// `recorder.panel`/`recorder.constructionCount`, which only exercise
  /// `.constructed`.
  /// Nothing directly asserted `setFrame`, `setContentView` or
  /// `orderFrontRegardless` ever appear — a recorder that silently stopped
  /// recording any one of those would leave every OTHER test in this file
  /// green, because they all read the PANEL's own state, never the recorder's
  /// command log. Codex found this gap in chunk review.
  @Test("present, resize and hide issue the panel commands in order")
  func panelCommandOrderIsObservable() throws {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }

    let view = Self.view(width: 185, height: 44)
    let presentStart = recorder.commands.count
    #expect(
      h.present(
        view, width: .fixed(185), fixedHeight: nil, isFresh: true, position: .bottom))

    let panel = try #require(recorder.panel)
    let panelID = ObjectIdentifier(panel)
    let presented = Array(recorder.commands[presentStart...])

    // Locate `.constructed` explicitly rather than assuming position 0, then
    // assert the three commands the HOST issues after it.
    //
    // #2455 C4: the original reason was an AppKit fact — `NSPanel`'s own
    // designated initializer appended a `.setContentView` receipt before
    // construction finished, because the recorder WAS an `NSPanel`. That cannot
    // happen now. Locating `.constructed` is kept anyway: it makes the
    // command-order contract independent of how the recorder flattens each
    // driver's receipts, which is a property of the assertion rather than of
    // whichever double is underneath it.
    guard
      let constructedIndex = presented.firstIndex(where: {
        if case .constructed = $0 { return true }
        return false
      })
    else {
      Issue.record("present never constructed a panel")
      return
    }
    guard case .constructed(let constructedID) = presented[constructedIndex] else {
      Issue.record("unreachable: index was located by matching .constructed")
      return
    }
    let afterConstruction = Array(presented[(constructedIndex + 1)...])
    try #require(
      afterConstruction.count == 3,
      """
      expected exactly setFrame → setContentView → orderFrontRegardless after construction, \
      got \(afterConstruction)
      """)

    guard case .setFrame(let frameID, let frame, let display, let animated) = afterConstruction[0],
      case .setContentView(let contentID, let viewID) = afterConstruction[1],
      case .orderFrontRegardless(let frontID) = afterConstruction[2]
    else {
      Issue.record("present did not issue frame → content → order-front after construction")
      return
    }

    #expect(constructedID == panelID)
    #expect(frameID == panelID)
    #expect(frame.size == CGSize(width: 185, height: 44))
    #expect(display == false)
    #expect(animated == false)
    #expect(contentID == panelID)
    #expect(viewID == ObjectIdentifier(view))
    #expect(frontID == panelID)

    let resizeStart = recorder.commands.count
    h.resizeCurrentPresentation(to: CGSize(width: 240, height: 60))
    let resized = Array(recorder.commands[resizeStart...])
    try #require(resized.count == 1)
    guard
      case .setFrame(let resizeID, let resizedFrame, let resizeDisplay, let resizeAnimated) =
        resized[0]
    else {
      Issue.record("resize did not issue exactly one setFrame")
      return
    }
    #expect(resizeID == panelID)
    #expect(resizedFrame.size == CGSize(width: 240, height: 60))
    #expect(resizeDisplay)
    #expect(resizeAnimated == false)

    let hideStart = recorder.commands.count
    h.hide()
    #expect(
      Array(recorder.commands[hideStart...]) == [
        .orderOut(panel: panelID),
        .setContentView(panel: panelID, view: nil),
      ])
  }

  /// **`hide()` must ORDER OUT, not close — and the check for it moved (#2455 C4).**
  ///
  /// This suite carried a `hideNeverCloses` case that observed
  /// `NSWindow.willCloseNotification` on the recorder. That worked only while the
  /// recorder WAS an `NSPanel`. Against a pure driver the notification can never
  /// fire, so the test passed by construction and proved nothing — a mutation
  /// control's worth of coverage, silently reduced to zero by the very change that
  /// made the fake inert.
  ///
  /// Two things replaced it, and both are stronger than the original:
  /// `OverlayPanelDriving` declares NO `close`, so the call is unrepresentable
  /// rather than merely unasserted; and `OverlayRetainedWindowRealPanelTests` in
  /// `EnviousWisprDesktopEffectsTests` still observes `willCloseNotification` on a
  /// real panel, where it can actually fire.


  /// **Three sizing paths, three DIFFERENT numbers**, so each is separable.
  @Test("fixed, fitting and frame-fallback widths are told apart")
  func sizingPathsAreDistinguishable() throws {
    // fixed 300, fitting 211, frame 150 — no two alike.
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    let v = Self.view(width: 150, height: 40, fitting: NSSize(width: 211, height: 58))

    h.present(v, width: .fixed(300), fixedHeight: nil, isFresh: true, position: .bottom)
    let panel = try #require(recorder.panel)
    #expect(panel.frame.width == 300, "a fixed width was not honoured")
    #expect(panel.frame.height == 58, "height did not come from the fitting size")

    h.present(
      Self.view(width: 150, height: 40, fitting: NSSize(width: 211, height: 58)),
      width: .measured, fixedHeight: nil, isFresh: true, position: .bottom)
    #expect(panel.frame.width == 211, "a measured width did not come from the fitting size")

    // Fitting size zero: the frame is the only remaining truth.
    h.present(
      Self.view(width: 150, height: 40), width: .measured, fixedHeight: nil, isFresh: true,
      position: .bottom)
    #expect(panel.frame.width == 150, "the frame fallback did not apply")
  }

  /// A presentation that cannot be sized must not present. A zero-sized panel is
  /// an invisible pill that reports success — the failure nothing would report.
  @Test("a presentation that cannot be sized is refused, not shown at zero")
  func unsizablePresentationIsRefused() {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    let empty = Self.view(width: 0, height: 0)
    h.present(empty, width: .measured, fixedHeight: nil, isFresh: true, position: .bottom)

    #expect(recorder.panel == nil, "an unsizable presentation created a zero-sized window")
    #expect(recorder.constructionCount == 0)
    // A retained panel makes `panel != nil` useless as a success signal, and the
    // shipped import-status owner depends on exactly that check.
    #expect(
      h.present(empty, width: .measured, fixedHeight: nil, isFresh: true, position: .bottom)
        == false,
      "a refused presentation reported success — the slot owner would claim it")
  }

  /// A morph must actually swap the content. Nothing else in this suite would
  /// notice a host that resized the panel and left the old view in it.
  @Test("morphing replaces the panel's content view")
  func morphReplacesContent() throws {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(recorder.panel)

    let replacement = Self.view(width: 320, height: 120)
    h.present(replacement, width: .fixed(320), fixedHeight: nil, isFresh: false, position: .bottom)

    #expect(panel.contentView === replacement, "the panel kept the previous presentation's view")
  }

  /// **The copied panel configuration is pinned.** Removing the floating level,
  /// all-Spaces behaviour, movability or the shadow would otherwise leave every
  /// test green while changing what the user sees: a pill behind other windows,
  /// one that vanishes on a Space swipe, or one that cannot be dragged.
  @Test("the panel's shipped configuration is unchanged")
  func panelConfigurationIsPinned() throws {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(recorder.panel)

    #expect(panel.level == .floating)
    #expect(panel.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary])
    #expect(panel.isMovableByWindowBackground)
    #expect(panel.hasShadow)
    #expect(panel.isOpaque == false)
    #expect(panel.isReleasedWhenClosed == false, "a released panel cannot be retained")
    // #2455 C4: `styleMask` is not on `OverlayPanelDriving`. It is a property of
    // the REAL panel's construction, not of anything the host does, so asserting
    // it here was testing the factory through the host. It moved to
    // `LiveOverlayPanelDriverTests` in `EnviousWisprDesktopEffectsTests`, which is
    // the target that can see a real `NSPanel`.
  }

  /// Top continuity through the HOST, not just the placement value: a
  /// content-sized outgoing pill re-anchors by its top edge, a fixed-height one
  /// by its centre. Nothing at host level distinguished these.
  @Test("Top continuity re-anchors by top edge when the outgoing pill was content-sized")
  func topContinuityContentSized() throws {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    h.present(
      Self.view(width: 185, height: 44, fitting: NSSize(width: 185, height: 44)),
      width: .fixed(185), fixedHeight: nil, isFresh: true, position: .top)
    let panel = try #require(recorder.panel)
    let before = panel.frame

    h.present(
      Self.view(width: 185, height: 92, fitting: NSSize(width: 185, height: 92)),
      width: .fixed(185), fixedHeight: nil, isFresh: false, position: .top)

    #expect(abs(panel.frame.maxY - before.maxY) <= 0.5, "the top edge moved")
  }

  @Test("Top continuity re-anchors by centre when the outgoing pill had a fixed height")
  func topContinuityFixedHeight() throws {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: true,
      position: .top)
    let panel = try #require(recorder.panel)
    let before = panel.frame

    h.present(
      Self.view(width: 185, height: 44, fitting: NSSize(width: 185, height: 44)),
      width: .fixed(185), fixedHeight: nil, isFresh: false, position: .top)

    #expect(abs(panel.frame.midY - before.midY) <= 0.5, "the centre moved")
  }

  /// **Component-contract guard, NOT product evidence.** Asked directly whether
  /// this pairing is reachable, cloud review answered no: no current production
  /// path produces a measured width with a fixed height, since a faithful
  /// wiring yields either `fitToContent -> (.measured, nil)` or fixed
  /// dimensions, and the only reserved height belongs to the fixed-width
  /// recording pill. It is kept because `present` deliberately exposes the two
  /// axes independently, so the contract is real even where no caller uses it —
  /// but it must never be cited as coverage of a shipped behaviour.
  ///
  /// **The one combination that separates the two sizing predicates.**
  ///
  /// `currentWasContentSized` keys on HEIGHT. The earlier predicate ORed the
  /// axes — `width == .measured || fixedHeight == nil` — which agrees with the
  /// correct one everywhere EXCEPT a measured width with a fixed height. Without
  /// this case the fix is real and completely unguarded: a mutant restoring the
  /// old predicate stays green.
  ///
  /// A measured-width, fixed-height pill is content-sized HORIZONTALLY and fixed
  /// VERTICALLY, so Top continuity must re-anchor it by its CENTRE.
  @Test("a measured width with a fixed height is not content-sized vertically")
  func measuredWidthWithFixedHeightIsNotContentSized() throws {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    h.present(
      Self.view(width: 150, height: 40, fitting: NSSize(width: 211, height: 58)),
      width: .measured, fixedHeight: 92, isFresh: true, position: .top)
    let panel = try #require(recorder.panel)
    #expect(panel.frame.width == 211)
    #expect(panel.frame.height == 92)
    let before = panel.frame

    h.present(
      Self.view(width: 185, height: 44, fitting: NSSize(width: 185, height: 44)),
      width: .fixed(185), fixedHeight: nil, isFresh: false, position: .top)

    #expect(
      abs(panel.frame.midY - before.midY) <= 0.5,
      "re-anchored by top edge — the outgoing pill's fixed HEIGHT makes it centre-anchored")
  }

  /// **Hiding must release the hosting view, and nothing observed that until a
  /// mutant survived.** The shipped panel got this for free by being destroyed.
  /// `RecordingOverlayView` runs a `.task` polling the audio level every 50 ms
  /// and `OverlayCapsuleBackground` runs a `repeatForever` animation; a retained
  /// panel that is merely ordered out keeps both running for the rest of the
  /// session, invisibly and forever.
  ///
  /// The window is correctly hidden either way, so no visibility assertion can
  /// see it — this had to be a direct observation of the content view.
  @Test("hiding releases the hosting view so its work stops")
  func hideReleasesTheHostingView() throws {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(recorder.panel)
    #expect(panel.contentView != nil)

    h.hide()

    #expect(
      panel.contentView == nil,
      "a hidden pill kept its view, so its 50ms polling loop runs for the rest of the session")
  }

  /// **The host observes Space changes itself, and nothing in the suite covered
  /// this before it moved.** The panel used to own the observer and hand the
  /// geometry back across the seam; every fact the callback needs — the anchor,
  /// the screen, the window — already lives here.
  ///
  /// **Driving the injected observer is the observation**, and it proves the same
  /// thing the real notification did: the host REGISTERED. A direct call to
  /// `repositionForActiveSpaceChange()` would not — it would bypass registration
  /// entirely, which is the half that can break.
  ///
  /// #2455 C4: this posted a real `NSWorkspace` notification, which reached every
  /// workspace observer in the process, not just this host's. The fake now fires
  /// exactly one subscription and nothing else in the app hears it.
  @Test("the host re-anchors a Bottom pill when the active Space changes")
  func spaceChangeReachesTheHost() throws {
    var geometry = Self.screen
    let recorder = OverlayPanelCommandRecorder()
    let workspace = RecordingWorkspaceObserver()
    let h = OverlayWindowHost(
      screens: { OverlayScreenResolver { geometry } },
      effects: recorder.makeEffects(workspace: workspace))
    defer { recorder.panel?.orderOut() }
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(recorder.panel)
    #expect(panel.frame.origin.y == 85)
    #expect(workspace.observerCount == 1, "the host must subscribe exactly once")

    // A full-screen space appears: `visibleFrame` does not shrink, so the pill
    // must drop to the true screen edge (#1341).
    let spaceChangeStart = recorder.commands.count
    geometry = Self.fullScreened
    workspace.simulateActiveSpaceChange()
    // No run-loop settle: the fake calls back synchronously, so there is no
    // posted notification to deliver. The real observer used `queue: .main` and
    // the notification centre guarantees the main thread, so the ordering the
    // host sees is unchanged.

    #expect(
      panel.frame.origin.y == 0,
      "the Space change never reached the host — it is not registered")

    // One Host animated move must yield exactly one `setFrame` receipt. Count ALL
    // frame receipts first: filtering to `animated == true` would hide the extra
    // non-animated receipt this normalization exists to suppress.
    let spaceChangeCommands = Array(recorder.commands[spaceChangeStart...])
    let frameCommands = spaceChangeCommands.filter {
      if case .setFrame = $0 { return true }
      return false
    }
    try #require(
      frameCommands.count == 1,
      """
      expected exactly one setFrame receipt for the Space-change reposition, got \
      \(spaceChangeCommands)
      """)

    guard case .setFrame(_, _, let display, let animated) = frameCommands[0] else {
      Issue.record("the Space-change command was not setFrame")
      return
    }
    #expect(display)
    #expect(animated)

    // **A SECOND swipe, and this is the assertion that matters.** The first one
    // proves only that the host is listening. The host moves the window itself
    // to re-anchor, and that move fires the driver's `onMove` — so if the programmatic
    // guard did not hold, the host would record its OWN reposition as the user
    // dragging the pill and refuse to follow Spaces ever again. One swipe cannot
    // see that; the pill would look correct and then silently stop.
    geometry = Self.screen
    workspace.simulateActiveSpaceChange()

    #expect(
      panel.frame.origin.y == 85,
      "the first automatic Space move was mistaken for a drag, so the pill stopped following Spaces"
    )
  }

  /// A `.measured` width must come from the view, and no default may stand in
  /// for it. Escape Recovery's real width is computed from text metrics, so a
  /// literal there would look plausible and silently disagree with the pill.
  @Test("a measured width is taken from the view, not from a default")
  func measuredWidthComesFromTheView() throws {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    h.present(
      Self.view(width: 271, height: 58), width: .measured, fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(recorder.panel)
    #expect(panel.frame.width == 271)
  }

  /// The #1060 reserved interaction frame survives the migration. It is NOT
  /// universal — only the non-preview recording pill asks for it — so the host
  /// must honour a fixed height when given one and measure when not.
  @Test("a fixed height is honoured and overrides the view's own")
  func fixedHeightIsHonoured() throws {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.host(effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: true,
      position: .bottom)
    let panel = try #require(recorder.panel)
    #expect(panel.frame.height == 92)
  }

  // MARK: - A continuation stays on ITS OWN display (#2292 C10)

  /// A SHORT second display, and short is the whole point.
  ///
  /// The clamp is `min(requestedY, visibleFrame.maxY - height - margin)`, so
  /// reading the wrong screen only MOVES the pill when the wrong screen's
  /// ceiling is LOWER. Two displays of the same height give identical answers
  /// and the defect is invisible; so does a taller second display, because a
  /// looser clamp changes nothing. A short one is the case that bites, and the
  /// first version of this test used a tall one and passed against the bug.
  private static let shortSecondary = ScreenGeometry(
    id: ScreenID(rawValue: 2),
    frame: CGRect(x: 0, y: 0, width: 1512, height: 400),
    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 380))

  /// A host whose POINTER screen and CONTAINING screen can disagree, which is
  /// exactly the situation a moved pointer creates.
  private static func splitHost(
    pointer: @escaping () -> ScreenGeometry,
    containing: @escaping (CGRect) -> ScreenGeometry?,
    effects: DesktopOverlayEffects = .recording()
  ) -> OverlayWindowHost {
    OverlayWindowHost(
      screens: { OverlayScreenResolver(containing: containing, current: pointer) },
      effects: effects)
  }

  /// **The regression, stated as the user sees it.** Start dictating on the
  /// main display, move the pointer to a shorter second display, and the
  /// recording-to-processing transition yanks the pill downward on the display
  /// it is still sitting on.
  ///
  /// The mechanism is a coordinate-space mix: the continuation inherits
  /// `panel.frame`, which is in the ORIGINAL display's space, while the clamp
  /// measured it against the POINTER's display. A Top pill sits at 845 on the
  /// tall display; the short display's ceiling is 280, so the wrong anchor
  /// drags it 565 points down a screen the pointer is not even on.
  @Test("a continuation is clamped against the display it is on, not the pointer's")
  func continuationKeepsItsOwnScreen() throws {
    var pointer = Self.screen
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.splitHost(
      pointer: { pointer }, containing: { _ in Self.screen }, effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }

    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: true,
      position: .top)
    let first = try #require(recorder.panel).frame

    // The pointer moves to the SHORT display. The panel has not moved.
    pointer = Self.shortSecondary
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: false,
      position: .top)
    let after = try #require(recorder.panel).frame

    #expect(
      after.origin.y == first.origin.y,
      "the pill was dragged down its own display by a clamp read off the pointer's screen")
    #expect(after.origin.x == first.origin.x, "a continuation must preserve X (#2195)")
  }

  /// **The fallback is the disconnected-display case.** When nothing contains
  /// the panel any more, the pointer's screen is the right answer: re-home the
  /// pill onto a screen that exists rather than clamp it against one that does
  /// not. Asserted so the `?? screen` is a decision rather than an accident.
  @Test("a continuation with no containing screen falls back to the pointer's")
  func continuationFallsBackWhenItsScreenIsGone() throws {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.splitHost(
      pointer: { Self.screen }, containing: { _ in nil }, effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }

    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: true,
      position: .top)
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: false,
      position: .top)

    let panel = try #require(recorder.panel)
    #expect(
      panel.frame.maxY <= Self.screen.visibleFrame.maxY - OverlayPlacementState.topClampMargin,
      "the fallback produced a frame outside the only screen that exists")
  }

  /// **The twin C10 missed, found by the review gate and unguarded until now.**
  /// A resize is a continuation by definition — the pill is on screen and Live
  /// Preview is growing it — so it has exactly the same coordinate-space
  /// problem as a transition, in a different method.
  ///
  /// This case exists because the mutation control for the fix came back
  /// UNCAUGHT: the repair was right and nothing would have failed if it were
  /// reverted, which is the state that let the defect live in two methods in
  /// the first place.
  @Test("a resize is clamped against the display the pill is on")
  func resizeKeepsItsOwnScreen() throws {
    var pointer = Self.screen
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.splitHost(
      pointer: { pointer }, containing: { _ in Self.screen }, effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }

    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: true,
      position: .top)
    let before = try #require(recorder.panel).frame

    // Live Preview grows the pill while the pointer sits on the SHORT display.
    pointer = Self.shortSecondary
    h.resizeCurrentPresentation(to: CGSize(width: 185, height: 92))

    let after = try #require(recorder.panel).frame
    #expect(
      after.origin.y == before.origin.y,
      "the growing pill was dragged down its own display by the pointer's clamp")
  }

  /// **The third member of the screen class, found by enumerating it rather
  /// than by a third review round.** A drag ends with the panel where it was
  /// dropped and the pointer where it is; releasing across a display boundary
  /// separates them. The recorded id is what `isUserAnchored(on:)` checks, so
  /// the wrong one makes a deliberately placed pill stop counting as
  /// user-anchored on its own display.
  ///
  /// **Observed through TWO continuations rather than `placementForTesting`.**
  /// `isUserAnchored(on:)` has no receipt; what it decides is directly
  /// observable as X-preservation-versus-recentring on the next presentation,
  /// exactly as the drag tests above prove the same fact. `containingScreen` is
  /// mutable so the SAME drag can be continued once resolved to the landing
  /// screen (must preserve X) and once resolved to the pointer's display, which
  /// the panel never touched (must recentre).
  @Test("a drag records the screen the panel landed on, not the pointer's")
  func dragRecordsTheLandingScreen() throws {
    var containingScreen: ScreenGeometry? = Self.screen
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.splitHost(
      pointer: { Self.shortSecondary }, containing: { _ in containingScreen },
      effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }
    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
      position: .bottom)
    let panel = try #require(recorder.panel)

    // #2455 C4: one call replaces the setFrameOrigin + delegate-notification pair. The
    // driver owns the delegate relationship now, so a test says what the USER did
    // rather than reproducing AppKit\'s notification plumbing.
    panel.simulateUserMove(to: CGPoint(x: 120, y: 85))

    // Continued on the LANDING screen (id 1, where `containing` placed the
    // panel): the drag is user-anchored there, so X is preserved.
    h.present(
      Self.view(width: 320, height: 120), width: .fixed(320), fixedHeight: nil, isFresh: false,
      position: .bottom)
    #expect(
      panel.frame.origin.x == 120,
      """
      the drag was recorded against the pointer's display, so the pill is not user-anchored \
      on the one it is actually on
      """)

    // The SAME drag, continued on the pointer's display (id 2, which the panel
    // never touched): not user-anchored there, so X recentres instead of
    // preserving the dragged value.
    containingScreen = Self.shortSecondary
    h.present(
      Self.view(width: 320, height: 120), width: .fixed(320), fixedHeight: nil, isFresh: false,
      position: .bottom)
    let recentredX = Self.shortSecondary.visibleFrame.midX - 320 / 2
    #expect(
      panel.frame.origin.x == recentredX,
      "the drag was recorded against a display the panel never touched")
  }

  /// A FRESH presentation still belongs where the POINTER is, which is the
  /// shipped target resolution and must not be collateral damage of the fix
  /// above. Without this, anchoring everything to the containing screen would
  /// look correct and quietly stop new pills following the user.
  ///
  /// Asserted on Y, not X: both fixtures span the same horizontal range, so a
  /// centre-X assertion cannot tell them apart and would pass either way.
  @Test("a fresh presentation still follows the pointer's screen")
  func freshPresentationFollowsThePointer() throws {
    let recorder = OverlayPanelCommandRecorder()
    let h = Self.splitHost(
      pointer: { Self.shortSecondary }, containing: { _ in Self.screen },
      effects: recorder.makeEffects())
    defer { recorder.panel?.orderOut() }

    h.present(
      Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: true,
      position: .top)

    let panel = try #require(recorder.panel)
    let expected = OverlayPlacementState.clampedOriginY(
      requestedY: OverlayPlacementState.freshOriginY(for: .top, on: Self.shortSecondary),
      height: 92, on: Self.shortSecondary)
    #expect(
      panel.frame.origin.y == expected,
      "a fresh pill was placed on the containing screen instead of the pointer's")
  }
}
