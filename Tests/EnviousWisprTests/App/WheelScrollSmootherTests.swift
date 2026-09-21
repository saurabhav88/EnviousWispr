import AppKit
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3062: a clicking mouse wheel moves the page 4x farther per notch, as a short
/// glide, while trackpads and chords pass through untouched. When this fails,
/// the user sees a notch move the wrong distance, glide the wrong way, keep
/// gliding into a hidden window, or a trackpad gesture altered.
@MainActor
@Suite("WheelScrollSmoother (#3062)", .tags(.productOutcome))
struct WheelScrollSmootherTests {
  /// A real, never-shown window so `NSEvent(cgEvent:)` resolves `event.window`
  /// and the smoother has a target to check. `isVisible` stays false until the
  /// test says otherwise through the injected seam.
  private let window: NSWindow
  /// Window number to window, for the `windowOf` seam (see `wheelEvent`).
  private let windows = WindowTable()

  private final class WindowTable {
    var value: [Int: NSWindow] = [:]
  }

  init() {
    _ = NSApplication.shared
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
  }

  // MARK: - Event factory

  /// A scroll event as a physical device would deliver it: `.line` units for a
  /// clicking wheel (non-precise), `.pixel` for a trackpad (precise).
  private func wheelEvent(
    dy: Double, dx: Double = 0, precise: Bool = false,
    modifiers: CGEventFlags = [], location: CGPoint = CGPoint(x: 200, y: 150),
    in window: NSWindow? = nil
  ) throws -> NSEvent {
    let cg = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2,
        wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0))
    // Fractional line deltas are what system acceleration actually produces
    // (0.7 line for a slow notch); the factory only takes whole numbers.
    cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
    cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
    cg.flags = modifiers
    cg.location = location
    let target = window ?? self.window
    // `NSEvent(cgEvent:)` resolves no window and drops the window-number
    // fields on the way back out (measured 2026-09-20); `eventSourceUserData`
    // is the one field that survives, so the window number rides there and
    // the injected `windowOf` seam looks it up. The smoother only compares
    // that field against its own marker, so a window number never collides.
    cg.setIntegerValueField(.eventSourceUserData, value: Int64(target.windowNumber))
    windows.value[target.windowNumber] = target
    return try #require(NSEvent(cgEvent: cg))
  }

  private struct Harness {
    var now: TimeInterval = 100
    var reduceMotion = false
    var appHidden = false
    var presentable = true
    var emitted: [(event: NSEvent, view: NSView)] = []
  }

  private func makeSmoother(_ harness: Harness) -> (WheelScrollSmoother, Box) {
    let box = Box(harness)
    let smoother = WheelScrollSmoother(
      monitor: RecordingMonitor(),
      now: { box.value.now },
      reduceMotion: { box.value.reduceMotion },
      isAppHidden: { box.value.appHidden },
      isPresentable: { _ in box.value.presentable },
      windowOf: { [windows] event in
        guard let cg = event.cgEvent else { return nil }
        let number = Int(cg.getIntegerValueField(.eventSourceUserData))
        return windows.value[number]
      },
      // Each window's content view stands in for the view under the pointer.
      hitTest: { _, window in window.contentView },
      emit: { box.value.emitted.append((event: $0, view: $1)) })
    return (smoother, box)
  }

  private final class Box {
    var value: Harness
    init(_ value: Harness) { self.value = value }
  }

  /// Records installs and removals; never touches AppKit's monitor registry.
  private final class RecordingMonitor: ScrollWheelMonitoring {
    var installed = 0
    var removed = 0
    var handler: (@MainActor (NSEvent) -> NSEvent?)?
    func install(_ handler: @escaping @MainActor (NSEvent) -> NSEvent?) -> Any? {
      installed += 1
      self.handler = handler
      return NSObject()
    }
    func remove(_ token: Any) {
      removed += 1
      handler = nil
    }
  }

  // MARK: - Classification

  @Test("A non-precise notch is classified with its raw deltas on both axes")
  func classifyKeepsRawDeltas() throws {
    let event = try wheelEvent(dy: -0.7, dx: 0.25)
    #expect(!event.hasPreciseScrollingDeltas)
    let verdict = WheelScrollSmoother.Planner.classify(event)
    guard case .boost(let dx, let dy) = verdict else {
      Issue.record("expected boost, got \(verdict)")
      return
    }
    #expect(abs(dy - (-0.7)) < 1e-4)
    #expect(abs(dx - 0.25) < 1e-4)
  }

  @Test("Every click moves at least the floor; bigger deltas scale by the gain; zero stays zero")
  func tuningFloorsThenScales() {
    let tuning = WheelScrollSmoother.Tuning.shipped
    // The founder's Razer: 0.1 line per click -> the floor, 4 lines (40 pt).
    #expect(abs(tuning.boost(-0.1) - (-4)) < 1e-9)
    // The reporter's mouse: 0.7 line -> 2.8 by gain, still under the floor.
    #expect(abs(tuning.boost(-0.7) - (-4)) < 1e-9)
    // A fast spin: 3 lines -> 12 by gain, above the floor.
    #expect(abs(tuning.boost(3) - 12) < 1e-9)
    #expect(tuning.boost(0) == 0)
  }

  @Test("A precise (trackpad) event passes through as the same instance")
  func preciseEventsPassThrough() throws {
    let event = try wheelEvent(dy: -3, precise: true)
    #expect(event.hasPreciseScrollingDeltas)
    #expect(WheelScrollSmoother.Planner.classify(event) == .passThrough)
    let (smoother, box) = makeSmoother(Harness())
    #expect(smoother.handle(event) === event)
    #expect(box.value.emitted.isEmpty)
  }

  @Test("Command, option and control chords pass through; shift does not")
  func chordedEventsPassThrough() throws {
    for flags in [CGEventFlags.maskCommand, .maskAlternate, .maskControl] {
      let event = try wheelEvent(dy: -1, modifiers: flags)
      #expect(WheelScrollSmoother.Planner.classify(event) == .passThrough, "\(flags)")
    }
    let shifted = try wheelEvent(dy: -1, modifiers: .maskShift)
    #expect(WheelScrollSmoother.Planner.classify(shifted) != .passThrough)
  }

  @Test("A synthesized event keeps line units, no phases, and a fractional delta")
  func synthesizedEventShape() throws {
    let physical = try wheelEvent(dy: -1)
    let cg = try #require(physical.cgEvent)
    let synthetic = try #require(
      WheelScrollSmoother.Planner.makeEvent(template: cg, dx: 0, dy: -0.3))
    #expect(!synthetic.hasPreciseScrollingDeltas)
    #expect(synthetic.phase.isEmpty && synthetic.momentumPhase.isEmpty)
    // Fractional line deltas survive the copy to within the field's 1/65536
    // fixed-point step (Codex r1 Q1a; the exact step measured 2026-09-20).
    #expect(abs(synthetic.scrollingDeltaY - (-0.3)) < 1e-4)
  }

  // MARK: - Glide math (pure)

  @Test("A glide's steps sum to the added distance, keep one sign, end by the deadline")
  func glideSumsToTotal() {
    let tuning = WheelScrollSmoother.Tuning.shipped
    var glide = WheelScrollSmoother.Glide()
    glide.add(dx: 0, dy: -2.8, at: 0)
    var now: TimeInterval = 0
    var total = 0.0
    var steps = 0
    while true {
      now += 0.008
      let flush = now - glide.lastNotchAt >= tuning.hardDeadline
      let step = glide.step(at: now, tau: tuning.tau, forceFlush: flush)
      #expect(step.dy <= 0, "monotone sign")
      #expect(step.dx == 0)
      total += step.dy
      steps += 1
      if step.finished { break }
      #expect(steps < 100)
    }
    #expect(abs(total - (-2.8)) < 1e-9)
    #expect(steps >= 3)
    #expect(now <= tuning.hardDeadline + 0.008 + 1e-9)
    #expect(glide.isIdle)
  }

  @Test("A second notch mid-glide joins the same glide: no zero step, exact combined total")
  func glideCoalescesANotchMidway() {
    let tuning = WheelScrollSmoother.Tuning.shipped
    var glide = WheelScrollSmoother.Glide()
    glide.add(dx: 0, dy: -2.8, at: 0)
    var now: TimeInterval = 0
    var total = 0.0
    var added = false
    while true {
      now += 0.008
      if !added, now >= 0.040 {
        glide.add(dx: 0, dy: -2.8, at: now)
        added = true
      }
      let flush = now - glide.lastNotchAt >= tuning.hardDeadline
      let step = glide.step(at: now, tau: tuning.tau, forceFlush: flush)
      #expect(step.dy < 0, "no zero step at t=\(now)")
      total += step.dy
      if step.finished { break }
    }
    #expect(abs(total - (-5.6)) < 1e-9)
    #expect(now <= 0.040 + tuning.hardDeadline + 0.016)
  }

  // MARK: - Smoother lifecycle

  @Test("Reduce Motion delivers one boosted step to the view and starts no glide")
  func reduceMotionSkipsGlide() throws {
    var harness = Harness()
    harness.reduceMotion = true
    let (smoother, box) = makeSmoother(harness)
    let event = try wheelEvent(dy: -0.7)
    #expect(smoother.handle(event) == nil)
    #expect(smoother.glide.isIdle)
    let out = try #require(box.value.emitted.first)
    #expect(box.value.emitted.count == 1)
    #expect(abs(out.event.scrollingDeltaY - (-4)) < 1e-4)
    #expect(out.view === window.contentView)
    box.value.now += 0.008
    smoother.tick()
    #expect(box.value.emitted.count == 1)
  }

  @Test("A notch is swallowed and ticks deliver its 4x distance to the view under the notch")
  func ticksEmitBoostedDistanceToTheNotchView() throws {
    let (smoother, box) = makeSmoother(Harness())
    let event = try wheelEvent(dy: -0.7, location: CGPoint(x: 123, y: 45))
    #expect(smoother.handle(event) == nil)
    #expect(!smoother.glide.isIdle)
    var total = 0.0
    for _ in 0..<40 {
      box.value.now += 0.008
      smoother.tick()
      if smoother.glide.isIdle { break }
    }
    #expect(smoother.glide.isIdle)
    #expect(box.value.emitted.count >= 3)
    for emitted in box.value.emitted {
      #expect(!emitted.event.hasPreciseScrollingDeltas)
      #expect(emitted.view === window.contentView)
      total += emitted.event.scrollingDeltaY
    }
    #expect(abs(total - (-4)) < 1e-3)
  }

  @Test("A glide driven through tick() ends by the hard deadline even while the ease-out has remainder left")
  func glideEndsByTheHardDeadlineThroughTick() throws {
    let (smoother, box) = makeSmoother(Harness())
    let tuning = WheelScrollSmoother.Tuning.shipped
    _ = smoother.handle(try wheelEvent(dy: -0.1))
    // With tau 50 ms and 4 lines, the pure ease-out still holds about 0.07 line
    // at 200 ms, above the finish epsilon, so only the deadline can end it here.
    // The deadline plus one frame: the first tick at or after the deadline flushes.
    var elapsed: TimeInterval = 0
    while elapsed < tuning.hardDeadline + 0.008 {
      box.value.now += 0.008
      elapsed += 0.008
      smoother.tick()
    }
    #expect(smoother.glide.isIdle, "not finished \(elapsed * 1000) ms after the notch")
    let total = box.value.emitted.map(\.event.scrollingDeltaY).reduce(0, +)
    #expect(abs(total - (-4)) < 1e-3)
  }

  @Test("Reduce Motion enabled mid-glide flushes the exact remainder once, then stops")
  func reduceMotionMidGlideFlushes() throws {
    let (smoother, box) = makeSmoother(Harness())
    _ = smoother.handle(try wheelEvent(dy: -1))
    box.value.now += 0.008
    smoother.tick()
    let first = box.value.emitted.map(\.event.scrollingDeltaY).reduce(0, +)
    #expect(first > -4 && first < 0)
    box.value.reduceMotion = true
    box.value.now += 0.008
    smoother.tick()
    #expect(smoother.glide.isIdle)
    let total = box.value.emitted.map(\.event.scrollingDeltaY).reduce(0, +)
    #expect(abs(total - (-4)) < 1e-3)
    let count = box.value.emitted.count
    box.value.now += 0.008
    smoother.tick()
    #expect(box.value.emitted.count == count)
  }

  @Test("A hidden app, a non-presentable window, or a view gone from its window cancels the remainder")
  func hiddenOrGoneWindowCancels() throws {
    for scenario in ["appHidden", "notPresentable", "gone"] {
      let (smoother, box) = makeSmoother(Harness())
      let transient = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
        styleMask: [.titled], backing: .buffered, defer: false)
      transient.isReleasedWhenClosed = false
      _ = smoother.handle(try wheelEvent(dy: -1, in: transient))
      if scenario == "gone" {
        // The app keeps every window it created, so a window cannot vanish
        // under a test; the view under the notch leaving its window is the
        // shape that does happen (a page swap, a sheet dismissed).
        transient.contentView = NSView()
      }
      box.value.now += 0.008
      switch scenario {
      case "appHidden":
        box.value.appHidden = true
        smoother.tick()
      case "notPresentable":
        box.value.presentable = false
        smoother.tick()
      default:
        smoother.tick()
      }
      #expect(smoother.glide.isIdle, Comment(rawValue: scenario))
      #expect(box.value.emitted.isEmpty, Comment(rawValue: scenario))
    }
  }

  @Test("A notch in another window cancels the old remainder and glides there")
  func notchInAnotherWindowResetsTarget() throws {
    let other = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    let (smoother, box) = makeSmoother(Harness())
    _ = smoother.handle(try wheelEvent(dy: -1))
    box.value.now += 0.008
    smoother.tick()
    let beforeSwitch = box.value.emitted.count
    _ = smoother.handle(try wheelEvent(dy: -1, in: other))
    #expect(abs(smoother.glide.remainingY - (-4)) < 1e-4, "old remainder dropped")
    for _ in 0..<40 {
      box.value.now += 0.008
      smoother.tick()
      if smoother.glide.isIdle { break }
    }
    let afterSwitch = box.value.emitted[beforeSwitch...]
    #expect(afterSwitch.allSatisfy { $0.view === other.contentView })
    #expect(abs(afterSwitch.map(\.event.scrollingDeltaY).reduce(0, +) - (-4)) < 1e-3)
  }

  @Test("Two clicks over different rows of one scroll view share a glide aimed at that scroll view")
  func leavesInsideOneScrollViewShareTheGlide() throws {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 2000))
    let rowA = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
    let rowB = NSView(frame: NSRect(x: 0, y: 40, width: 300, height: 40))
    document.addSubview(rowA)
    document.addSubview(rowB)
    scrollView.documentView = document
    window.contentView?.addSubview(scrollView)
    let box = Box(Harness())
    var leaf: NSView = rowA
    let smoother = WheelScrollSmoother(
      monitor: RecordingMonitor(),
      now: { box.value.now },
      reduceMotion: { false },
      isAppHidden: { false },
      isPresentable: { _ in true },
      windowOf: { [windows] event in
        guard let cg = event.cgEvent else { return nil }
        return windows.value[Int(cg.getIntegerValueField(.eventSourceUserData))]
      },
      hitTest: { _, _ in leaf },
      emit: { box.value.emitted.append((event: $0, view: $1)) })
    _ = smoother.handle(try wheelEvent(dy: -0.1))
    box.value.now += 0.008
    smoother.tick()
    leaf = rowB
    _ = smoother.handle(try wheelEvent(dy: -0.1))
    #expect(abs(smoother.glide.remainingY) > 4, "the first click's remainder survived the second")
    for _ in 0..<60 {
      box.value.now += 0.008
      smoother.tick()
      if smoother.glide.isIdle { break }
    }
    #expect(box.value.emitted.allSatisfy { $0.view === scrollView })
    #expect(abs(box.value.emitted.map(\.event.scrollingDeltaY).reduce(0, +) - (-8)) < 1e-3)
  }

  @Test("A precise physical event mid-glide cancels the glide and passes through")
  func precisePhysicalEventCancelsGlide() throws {
    let (smoother, _) = makeSmoother(Harness())
    _ = smoother.handle(try wheelEvent(dy: -1))
    #expect(!smoother.glide.isIdle)
    let trackpad = try wheelEvent(dy: -3, precise: true)
    #expect(smoother.handle(trackpad) === trackpad)
    #expect(smoother.glide.isIdle)
  }

  @Test("A synthesized event re-entering the handler during delivery passes through untouched")
  func syntheticReentryLeavesGlideAlone() throws {
    let reentry = Box(Harness())
    var smootherRef: WheelScrollSmoother?
    let smoother = WheelScrollSmoother(
      monitor: RecordingMonitor(),
      now: { reentry.value.now },
      reduceMotion: { false },
      isAppHidden: { false },
      isPresentable: { _ in true },
      windowOf: { [windows] event in
        guard let cg = event.cgEvent else { return nil }
        return windows.value[Int(cg.getIntegerValueField(.eventSourceUserData))]
      },
      hitTest: { _, window in window.contentView },
      emit: { event, _ in
        // The view re-dispatching our event through the app would land here.
        guard let smoother = smootherRef else { return }
        let before = smoother.glide
        #expect(smoother.isSynthetic(event))
        #expect(smoother.handle(event) === event)
        #expect(smoother.glide == before)
        reentry.value.emitted.append((event: event, view: NSView()))
      })
    smootherRef = smoother
    _ = smoother.handle(try wheelEvent(dy: -1))
    reentry.value.now += 0.008
    smoother.tick()
    #expect(reentry.value.emitted.count == 1)
    // Outside delivery the same event is no longer "ours".
    #expect(!smoother.isSynthetic(try #require(reentry.value.emitted.first?.event)))
  }

  @Test("start() installs one monitor whose handler is the smoother's; stop() removes it and clears the remainder")
  func startInstallsOnceAndStopRemoves() throws {
    let monitor = RecordingMonitor()
    let box = Box(Harness())
    let smoother = WheelScrollSmoother(
      monitor: monitor,
      now: { box.value.now },
      reduceMotion: { false },
      isAppHidden: { false },
      isPresentable: { _ in true },
      windowOf: { [windows] event in
        guard let cg = event.cgEvent else { return nil }
        return windows.value[Int(cg.getIntegerValueField(.eventSourceUserData))]
      },
      hitTest: { _, window in window.contentView },
      emit: { box.value.emitted.append((event: $0, view: $1)) })
    smoother.start()
    smoother.start()
    #expect(monitor.installed == 1)
    // A notch through the installed handler is swallowed into a glide.
    let handler = try #require(monitor.handler)
    #expect(handler(try wheelEvent(dy: -1)) == nil)
    #expect(!smoother.glide.isIdle)
    smoother.stop()
    #expect(monitor.removed == 1)
    #expect(smoother.glide.isIdle)
    box.value.now += 0.008
    smoother.tick()
    #expect(box.value.emitted.isEmpty)
    smoother.stop()
    #expect(monitor.removed == 1)
  }
}
