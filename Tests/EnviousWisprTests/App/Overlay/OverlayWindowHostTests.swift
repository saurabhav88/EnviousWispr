#if DEBUG
// **The whole file is DEBUG-only, and that is structural rather than stylistic.**
// Every case here reads a `*ForTesting` accessor, and those live inside `#if
// DEBUG` on the types they belong to. Without this wrapper the RELEASE build of
// the test target does not compile — which a Debug-only local run cannot see, by
// construction, and which CI's `build-release` job catches instead.
  import AppKit
  import CoreGraphics
  import EnviousWisprCore
  import SwiftUI
  import Testing

  @testable import EnviousWisprAppKit

  /// #2292 chunk C3. The retained window.
  ///
  /// **Product Outcome.** When these fail the user sees the pill flicker as it is
  /// destroyed and rebuilt (#930), jump sideways after they dragged it (#2195), or
  /// a hidden window keeps swallowing clicks over an empty patch of screen.
  ///
  /// These touch AppKit, so they build a real `NSPanel` — that is the point. The
  /// probe on 2026-08-21 established what a retained panel costs
  /// (`docs/audits/2026-08-21-overlay-probe-results.md`); this suite establishes
  /// that OUR host retains exactly one and places it correctly. Screens are faked
  /// so geometry is deterministic and a full-screen space is reachable, neither of
  /// which a test can arrange on a real display.
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

    /// **Orders the panel out when the test ends.**
    ///
    /// These tests build REAL `NSPanel`s and `orderFrontRegardless()` them, which
    /// is the point — the suite is about window behaviour. But `NSApp` retains an
    /// ordered-in window, so without this every case leaves a floating pill on the
    /// developer's screen for the life of the xctest process. Measured: 34 of them
    /// stacked over the founder's terminal, from one lane.
    ///
    /// Not a production change and not a seam on a guard: the test orders out what
    /// the test ordered in, using the DEBUG accessor that already exists.
    private static func makeHost(
      _ geometry: @escaping @autoclosure () -> ScreenGeometry = screen
    ) -> OverlayWindowHost {
      OverlayWindowHost(screens: { OverlayScreenResolver { geometry() } })
    }

    private static func host() -> OverlayWindowHost { makeHost() }

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
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      for i in 0..<12 {
        h.present(
          Self.view(width: 185 + CGFloat(i), height: 44), width: .fixed(185 + CGFloat(i)),
          fixedHeight: nil, isFresh: i == 0, position: .bottom)
      }
      h.hide()
      h.present(
        Self.view(width: 320, height: 120), width: .fixed(320), fixedHeight: nil, isFresh: true,
        position: .bottom)

      #expect(h.panelConstructionCount == 1)
    }

    /// #2195 end to end through the host, not just through the placement value.
    @Test("a continuing presentation keeps the pill where the user dragged it")
    func continuingKeepsTheDraggedPosition() throws {
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
        position: .bottom)
      let panel = try #require(h.panelForTesting)

      // The user drags it well left of centre. `windowDidMove` is how the host
      // learns; there is no rebuild for the fact to survive.
      panel.setFrameOrigin(NSPoint(x: 120, y: 85))
      h.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))

      h.present(
        Self.view(width: 320, height: 120), width: .fixed(320), fixedHeight: nil, isFresh: false,
        position: .bottom)

      #expect(panel.frame.origin.x == 120, "the pill snapped back to centre — this is #2195")
    }

    /// The paired case: a genuinely FRESH presentation must still centre, or the
    /// guard above is satisfied by a host that never centres anything.
    @Test("a fresh presentation is centred even after a drag")
    func freshRecentresAfterADrag() throws {
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
        position: .bottom)
      let panel = try #require(h.panelForTesting)
      panel.setFrameOrigin(NSPoint(x: 120, y: 85))
      h.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
      h.hide()

      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
        position: .bottom)

      // Within a point, not exact: **AppKit aligns a window frame to whole
      // points**, so a placement value of 663.5 lands at 663.0. The value type is
      // right and the window is right; an exact float comparison against the
      // unrounded computation is what was wrong. Half a point is tight enough that
      // a pill left at 120 still fails this.
      #expect(abs(panel.frame.origin.x - (Self.screen.visibleFrame.midX - 92.5)) <= 0.5)
    }

    /// **A programmatic move is not a drag**, and telling them apart is what makes
    /// anchor promotion safe. The probe measured `NSEvent.pressedMouseButtons`
    /// reading 0 even mid-drag, so the depth flag is the only working
    /// discriminator and this is its guard.
    @Test("the host's own frame changes never count as a user drag")
    func programmaticMovesAreNotDrags() {
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
        position: .bottom)
      // Every present/resize/reposition below moves the panel, and each fires
      // `windowDidMove` for real.
      h.resizeCurrentPresentation(to: CGSize(width: 240, height: 60))
      h.repositionForActiveSpaceChange()
      h.present(
        Self.view(width: 300, height: 60), width: .fixed(300), fixedHeight: nil, isFresh: false,
        position: .bottom)

      #expect(
        h.placementForTesting.isUserAnchored(on: Self.screen.id) == false,
        "the host mistook its own frame change for the user dragging the pill")
    }

    @Test("a real drag does count")
    func aRealDragCounts() throws {
      // Paired with the case above: a host that never promotes would pass it.
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
        position: .bottom)
      let panel = try #require(h.panelForTesting)
      panel.setFrameOrigin(NSPoint(x: 400, y: 300))
      h.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))

      #expect(h.placementForTesting.isUserAnchored(on: Self.screen.id))
    }

    /// `orderOut`, never `close`. Closing is what forces the rebuild.
    @Test("hiding orders the panel out and keeps it alive")
    func hideOrdersOutWithoutClosing() throws {
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
        position: .bottom)
      let panel = try #require(h.panelForTesting)
      #expect(panel.isVisible)

      h.hide()

      #expect(panel.isVisible == false, "a hidden panel still on screen swallows clicks")
      #expect(h.panelForTesting === panel, "hiding released the panel — it must be retained")
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
        position: .bottom)
      #expect(h.panelConstructionCount == 1, "showing after a hide rebuilt the panel")
    }

    /// **`hide()` must ORDER OUT, and a mutation control is what proved this test
    /// was needed.** Substituting `close()` for `orderOut` left all eight cases
    /// green: with `isReleasedWhenClosed = false` a closed panel is still alive,
    /// still the same instance, still `isVisible == false`, and the construction
    /// count is unchanged — every assertion the suite had. The distinction that
    /// matters is not observable through any of them.
    ///
    /// `close()` posts `willCloseNotification`; `orderOut` does not. Observing the
    /// notification needs no production seam and no text matching, so it holds
    /// whatever the method is called. The C5 freeze assertion (zero `.close()`
    /// calls in the overlay module) is a second, structural protection — but it
    /// does not exist yet, and deferring to it would have left the central claim
    /// of this change unguarded for two chunks.
    @Test("hiding never closes the window")
    func hideNeverCloses() throws {
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
        position: .bottom)
      let panel = try #require(h.panelForTesting)

      nonisolated(unsafe) var closed = false
      let token = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: panel, queue: nil
      ) { _ in closed = true }
      defer { NotificationCenter.default.removeObserver(token) }

      h.hide()
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
        position: .bottom)
      h.hide()

      #expect(
        closed == false,
        "the panel was CLOSED rather than ordered out — every rebuild this change removes comes from that")
    }

    /// **Three sizing paths, three DIFFERENT numbers**, so each is separable.
    @Test("fixed, fitting and frame-fallback widths are told apart")
    func sizingPathsAreDistinguishable() throws {
      // fixed 300, fitting 211, frame 150 — no two alike.
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      let v = Self.view(width: 150, height: 40, fitting: NSSize(width: 211, height: 58))

      h.present(v, width: .fixed(300), fixedHeight: nil, isFresh: true, position: .bottom)
      let panel = try #require(h.panelForTesting)
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
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      let empty = Self.view(width: 0, height: 0)
      h.present(empty, width: .measured, fixedHeight: nil, isFresh: true, position: .bottom)

      #expect(h.panelForTesting == nil, "an unsizable presentation created a zero-sized window")
      #expect(h.panelConstructionCount == 0)
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
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
        position: .bottom)
      let panel = try #require(h.panelForTesting)

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
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
        position: .bottom)
      let panel = try #require(h.panelForTesting)

      #expect(panel.level == .floating)
      #expect(panel.collectionBehavior == [.canJoinAllSpaces, .fullScreenAuxiliary])
      #expect(panel.isMovableByWindowBackground)
      #expect(panel.hasShadow)
      #expect(panel.isOpaque == false)
      #expect(panel.isReleasedWhenClosed == false, "a released panel cannot be retained")
      #expect(panel.styleMask.contains(.borderless))
      #expect(panel.styleMask.contains(.nonactivatingPanel))
    }

    /// Top continuity through the HOST, not just the placement value: a
    /// content-sized outgoing pill re-anchors by its top edge, a fixed-height one
    /// by its centre. Nothing at host level distinguished these.
    @Test("Top continuity re-anchors by top edge when the outgoing pill was content-sized")
    func topContinuityContentSized() throws {
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      h.present(
        Self.view(width: 185, height: 44, fitting: NSSize(width: 185, height: 44)),
        width: .fixed(185), fixedHeight: nil, isFresh: true, position: .top)
      let panel = try #require(h.panelForTesting)
      let before = panel.frame

      h.present(
        Self.view(width: 185, height: 92, fitting: NSSize(width: 185, height: 92)),
        width: .fixed(185), fixedHeight: nil, isFresh: false, position: .top)

      #expect(abs(panel.frame.maxY - before.maxY) <= 0.5, "the top edge moved")
    }

    @Test("Top continuity re-anchors by centre when the outgoing pill had a fixed height")
    func topContinuityFixedHeight() throws {
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: true,
        position: .top)
      let panel = try #require(h.panelForTesting)
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
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      h.present(
        Self.view(width: 150, height: 40, fitting: NSSize(width: 211, height: 58)),
        width: .measured, fixedHeight: 92, isFresh: true, position: .top)
      let panel = try #require(h.panelForTesting)
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
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
        position: .bottom)
      let panel = try #require(h.panelForTesting)
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
    /// Posting the real `NSWorkspace` notification is the observation: it proves
    /// the host is REGISTERED, which a direct call to
    /// `repositionForActiveSpaceChange()` would not.
    @Test("the host re-anchors a Bottom pill when the active Space changes")
    func spaceChangeReachesTheHost() throws {
      var geometry = Self.screen
      let h = OverlayWindowHost(screens: { OverlayScreenResolver { geometry } })
      defer { h.panelForTesting?.orderOut(nil) }
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: nil, isFresh: true,
        position: .bottom)
      let panel = try #require(h.panelForTesting)
      #expect(panel.frame.origin.y == 85)

      // A full-screen space appears: `visibleFrame` does not shrink, so the pill
      // must drop to the true screen edge (#1341).
      geometry = Self.fullScreened
      NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
      RunLoop.main.run(until: Date())  // settle: deliver a posted notification, no polling

      #expect(
        panel.frame.origin.y == 0,
        "the Space-change notification never reached the host — it is not registered")

      // **A SECOND swipe, and this is the assertion that matters.** The first one
      // proves only that the host is listening. The host moves the window itself
      // to re-anchor, and that move fires `windowDidMove` — so if the programmatic
      // guard did not hold, the host would record its OWN reposition as the user
      // dragging the pill and refuse to follow Spaces ever again. One swipe cannot
      // see that; the pill would look correct and then silently stop.
      geometry = Self.screen
      NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
      RunLoop.main.run(until: Date())  // settle: deliver a posted notification, no polling

      #expect(
        panel.frame.origin.y == 85,
        "the first automatic Space move was mistaken for a drag, so the pill stopped following Spaces")
    }

    /// A `.measured` width must come from the view, and no default may stand in
    /// for it. Escape Recovery's real width is computed from text metrics, so a
    /// literal there would look plausible and silently disagree with the pill.
    @Test("a measured width is taken from the view, not from a default")
    func measuredWidthComesFromTheView() throws {
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      h.present(
        Self.view(width: 271, height: 58), width: .measured, fixedHeight: nil, isFresh: true,
        position: .bottom)
      let panel = try #require(h.panelForTesting)
      #expect(panel.frame.width == 271)
    }

    /// The #1060 reserved interaction frame survives the migration. It is NOT
    /// universal — only the non-preview recording pill asks for it — so the host
    /// must honour a fixed height when given one and measure when not.
    @Test("a fixed height is honoured and overrides the view's own")
    func fixedHeightIsHonoured() throws {
      let h = Self.host()
      defer { h.panelForTesting?.orderOut(nil) }
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: true,
        position: .bottom)
      let panel = try #require(h.panelForTesting)
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
      containing: @escaping (CGRect) -> ScreenGeometry?
    ) -> OverlayWindowHost {
      OverlayWindowHost(
        screens: { OverlayScreenResolver(containing: containing, current: pointer) })
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
      let h = Self.splitHost(pointer: { pointer }, containing: { _ in Self.screen })
      defer { h.panelForTesting?.orderOut(nil) }

      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: true,
        position: .top)
      let first = try #require(h.panelForTesting).frame

      // The pointer moves to the SHORT display. The panel has not moved.
      pointer = Self.shortSecondary
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: false,
        position: .top)
      let after = try #require(h.panelForTesting).frame

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
      let h = Self.splitHost(pointer: { Self.screen }, containing: { _ in nil })
      defer { h.panelForTesting?.orderOut(nil) }

      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: true,
        position: .top)
      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: false,
        position: .top)

      let panel = try #require(h.panelForTesting)
      #expect(
        panel.frame.maxY <= Self.screen.visibleFrame.maxY - OverlayPlacementState.topClampMargin,
        "the fallback produced a frame outside the only screen that exists")
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
      let h = Self.splitHost(pointer: { Self.shortSecondary }, containing: { _ in Self.screen })
      defer { h.panelForTesting?.orderOut(nil) }

      h.present(
        Self.view(width: 185, height: 44), width: .fixed(185), fixedHeight: 92, isFresh: true,
        position: .top)

      let panel = try #require(h.panelForTesting)
      let expected = OverlayPlacementState.clampedOriginY(
        requestedY: OverlayPlacementState.freshOriginY(for: .top, on: Self.shortSecondary),
        height: 92, on: Self.shortSecondary)
      #expect(
        panel.frame.origin.y == expected,
        "a fresh pill was placed on the containing screen instead of the pointer's")
    }
  }
#endif
