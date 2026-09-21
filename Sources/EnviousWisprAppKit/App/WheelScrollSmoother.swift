import AppKit
import EnviousWisprCore
import Foundation

/// Rewrites this process's NON-precise scroll-wheel events (a clicking mouse
/// wheel) into a larger distance delivered as a short glide, so a notch moves
/// the page the way Chrome does instead of the way AppKit does (#3062).
///
/// AppKit turns one wheel notch into one event of about 0.7 line after system
/// acceleration and `NSScrollView` scrolls 10 points per line in one frame.
/// Chromium multiplies the same notch by 40 pixels and animates it. A reporter's
/// 60 fps video measured 7 points per notch here against about 100 in Chrome,
/// with no dropped frame on our side: the app was simply asked to move less.
///
/// Mechanism: one local `.scrollWheel` monitor. A physical non-precise notch is
/// swallowed and its boosted distance (`Tuning`: a floor per click, a
/// multiplier above it) is added to a glide; a timer then
/// emits a burst of synthesized events that KEEP the notch's line units, so
/// `NSScrollView`'s own line multiplication, elasticity and edge clamping run
/// exactly as for a physical notch. Nothing is ever marked precise and no
/// `phase` or `momentumPhase` is fabricated. Precise devices (trackpad, Magic
/// Mouse), phased events, and command/option/control chords pass through
/// untouched. Reduce Motion gets the distance in one event and no glide.
///
/// Delivery: an `NSEvent` built from a `CGEvent` never resolves a window and
/// carries a screen-space location (measured 2026-09-20, see the unit test's
/// factory), so a synthesized event handed to `NSApplication.sendEvent` would
/// reach nothing. Instead the view under the PHYSICAL notch is hit-tested once,
/// exactly as AppKit does before dispatching a wheel event, and every glide
/// step is sent to that view's `scrollWheel(with:)`; the responder chain then
/// finds the nearest scroll view, nested boxes included. The cursor's later
/// position never enters. Delivery is synchronous on the main thread, so the
/// one event being delivered is remembered by identity and, should it ever
/// re-enter the monitor, is returned unchanged (a `CGEvent` field stamp was
/// tried first and did not survive the round trip reliably). Owner:
/// `AppLifecycleCoordinator` starts, retains and stops one instance; every
/// decision lives here.
/// Registers and removes one process-local scroll-wheel monitor. The live
/// conformer is `LiveScrollWheelMonitor` in `EnviousWisprDesktopEffects`, the
/// only module allowed to call `NSEvent.addLocalMonitorForEvents`; tests pass a
/// recorder that never touches the desktop.
@MainActor
package protocol ScrollWheelMonitoring: AnyObject {
  /// Returns the framework's token, or `nil` when AppKit refused.
  func install(_ handler: @escaping @MainActor (NSEvent) -> NSEvent?) -> Any?
  func remove(_ token: Any)
}

@MainActor
final class WheelScrollSmoother {
  /// The numbers that decide the feel. Mice differ enormously in what one
  /// click delivers after driver and system acceleration: the reporter's mouse
  /// sends about 0.7 line per slow click, the founder's Razer Naga 0.1 line
  /// (both measured 2026-09-21 from the first-notch log line below). A plain
  /// multiplier cannot fit both, so every click moves at least `minLines`,
  /// and faster spins, whose deltas grow with acceleration, scale by `gain`.
  struct Tuning: Equatable {
    /// Multiplier on the click's line delta.
    var gain: Double = 4.0
    /// Floor per click, in lines (AppKit scrolls 10 points per line); 4 lines
    /// is Chromium's 40 pixels per tick.
    var minLines: Double = 4.0
    /// Time constant of the exponential ease-out.
    var tau: TimeInterval = 0.050
    /// Every glide ends within this long after its last click, whatever `tau` says.
    var hardDeadline: TimeInterval = 0.200

    nonisolated static let shipped = Tuning()

    /// Boosted distance for one axis: the floor for any non-zero delta, the
    /// multiplier once that exceeds the floor, sign preserved.
    func boost(_ delta: Double) -> Double {
      guard delta != 0 else { return 0 }
      return (delta < 0 ? -1 : 1) * max(abs(delta) * gain, minLines)
    }

    #if DEBUG
      /// Dev builds read overrides from `defaults` on every click so the feel
      /// can be dialled in live: `defaults write <bundle id> EWWheelGain 6`,
      /// `EWWheelMinLines`, `EWWheelTauMs`, `EWWheelDeadlineMs`. Delete the key
      /// to return to the shipped value. Compiled out of release entirely.
      static func fromDefaults() -> Tuning {
        var tuning = Tuning()
        let defaults = UserDefaults.standard
        if let v = defaults.object(forKey: "EWWheelGain") as? Double { tuning.gain = v }
        if let v = defaults.object(forKey: "EWWheelMinLines") as? Double { tuning.minLines = v }
        if let v = defaults.object(forKey: "EWWheelTauMs") as? Double { tuning.tau = v / 1000 }
        if let v = defaults.object(forKey: "EWWheelDeadlineMs") as? Double {
          tuning.hardDeadline = v / 1000
        }
        return tuning
      }
    #endif
  }
  /// Remainders below this (lines) are flushed in one final step.
  nonisolated static let finishEpsilon: Double = 0.02
  /// `NSScrollView`'s default line scroll, for the integer point-delta field.
  nonisolated static let pointsPerLine: Double = 10.0

  enum Verdict: Equatable {
    case passThrough
    /// The click's RAW line deltas; the smoother applies its tuning.
    case boost(dx: Double, dy: Double)
  }

  /// Pure event classification and synthesis. Nested so the smoother stays the
  /// only owner of wheel policy.
  enum Planner {
    static func classify(_ event: NSEvent) -> Verdict {
      guard event.type == .scrollWheel,
        !event.hasPreciseScrollingDeltas,
        event.phase.isEmpty,
        event.momentumPhase.isEmpty,
        event.modifierFlags.intersection([.command, .option, .control]).isEmpty
      else { return .passThrough }
      return .boost(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
    }

    /// A non-precise scroll event with the given line deltas, in the template's
    /// window and location. `nil` when Core Graphics refuses the copy, which the
    /// caller treats as "this step scrolls nothing".
    static func makeEvent(template: CGEvent, dx: Double, dy: Double) -> NSEvent? {
      guard let cg = template.copy() else { return nil }
      // Writing the whole-line integer field resets the fixed-point field, so
      // the fractional line value is written LAST (measured in the unit test:
      // the other order read back 0 for a 0.3-line step).
      cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(dy.rounded()))
      cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(dx.rounded()))
      cg.setIntegerValueField(
        .scrollWheelEventPointDeltaAxis1,
        value: Int64((dy * WheelScrollSmoother.pointsPerLine).rounded()))
      cg.setIntegerValueField(
        .scrollWheelEventPointDeltaAxis2,
        value: Int64((dx * WheelScrollSmoother.pointsPerLine).rounded()))
      cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
      cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
      cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
      cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
      cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
      return NSEvent(cgEvent: cg)
    }
  }

  /// The animation math: an exponential ease-out over the remaining distance,
  /// with an exact flush so the total emitted always equals the total added.
  struct Glide: Equatable {
    var remainingX: Double = 0
    var remainingY: Double = 0
    var lastTick: TimeInterval = 0
    var lastNotchAt: TimeInterval = 0

    var isIdle: Bool { remainingX == 0 && remainingY == 0 }

    mutating func add(dx: Double, dy: Double, at now: TimeInterval) {
      if isIdle { lastTick = now }
      remainingX += dx
      remainingY += dy
      lastNotchAt = now
    }

    mutating func cancel() {
      self = Glide()
    }

    /// One frame's worth. `forceFlush` emits the whole remainder.
    mutating func step(at now: TimeInterval, tau: TimeInterval, forceFlush: Bool) -> (
      dx: Double, dy: Double, finished: Bool
    ) {
      let dt = max(0, now - lastTick)
      lastTick = now
      let nearlyDone =
        abs(remainingX) < WheelScrollSmoother.finishEpsilon
        && abs(remainingY) < WheelScrollSmoother.finishEpsilon
      if forceFlush || nearlyDone {
        let out = (dx: remainingX, dy: remainingY, finished: true)
        cancel()
        return out
      }
      let fraction = 1 - exp(-dt / tau)
      let dx = remainingX * fraction
      let dy = remainingY * fraction
      remainingX -= dx
      remainingY -= dy
      return (dx, dy, false)
    }
  }

  private let monitorEffects: any ScrollWheelMonitoring
  private let now: @MainActor () -> TimeInterval
  private let reduceMotion: @MainActor () -> Bool
  private let isAppHidden: @MainActor () -> Bool
  private let isPresentable: @MainActor (NSWindow) -> Bool
  private let windowOf: @MainActor (NSEvent) -> NSWindow?
  private let hitTest: @MainActor (NSEvent, NSWindow) -> NSView?
  private let emit: @MainActor (NSEvent, NSView) -> Void
  private let frameInterval: TimeInterval

  /// The active numbers. Dev builds refresh them from `defaults` on every
  /// click; release builds always use `Tuning.shipped`.
  private(set) var tuning = Tuning.shipped
  private var monitor: Any?
  private var timer: Timer?
  private(set) var glide = Glide()
  private var template: CGEvent?
  private weak var targetWindow: NSWindow?
  private weak var targetView: NSView?
  /// Identity of the synthesized event currently inside `emit`, so a re-entry
  /// into `handle` with that very event is recognised as ours.
  private var delivering: ObjectIdentifier?
  private var loggedFirstNotch = false

  init(
    monitor: any ScrollWheelMonitoring,
    now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    reduceMotion: @escaping @MainActor () -> Bool = {
      NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    },
    isAppHidden: @escaping @MainActor () -> Bool = { NSApp.isHidden },
    isPresentable: @escaping @MainActor (NSWindow) -> Bool = {
      $0.isVisible && !$0.isMiniaturized
    },
    // An event built from a `CGEvent` in a test process resolves no window;
    // the real app's events do. The seam keeps the window check in the
    // smoother instead of dropping it.
    windowOf: @escaping @MainActor (NSEvent) -> NSWindow? = { $0.window },
    // `hitTest` takes a point in the receiver's SUPERVIEW's coordinates; the
    // frame view (the content view's superview) has none, so window
    // coordinates are its own, which is what `locationInWindow` is.
    hitTest: @escaping @MainActor (NSEvent, NSWindow) -> NSView? = { event, window in
      window.contentView?.superview?.hitTest(event.locationInWindow) ?? window.contentView
    },
    emit: @escaping @MainActor (NSEvent, NSView) -> Void = { event, view in
      view.scrollWheel(with: event)
    },
    frameInterval: TimeInterval = 1.0 / 120.0
  ) {
    self.monitorEffects = monitor
    self.now = now
    self.reduceMotion = reduceMotion
    self.isAppHidden = isAppHidden
    self.isPresentable = isPresentable
    self.windowOf = windowOf
    self.hitTest = hitTest
    self.emit = emit
    self.frameInterval = frameInterval
  }

  /// Install the monitor. Idempotent. A nil monitor (AppKit refused) leaves the
  /// app scrolling exactly as it did before this type existed.
  func start() {
    guard monitor == nil else { return }
    monitor = monitorEffects.install { [weak self] event in
      guard let self else { return event }
      return self.handle(event)
    }
  }

  /// Remove the monitor and drop any in-flight glide. Idempotent. The owner
  /// calls this before releasing the instance: `deinit` cannot touch main-actor
  /// state, and a timer left running would only reach a deallocated owner
  /// through its `[weak self]` closure, which is a no-op.
  func stop() {
    if let monitor {
      monitorEffects.remove(monitor)
      self.monitor = nil
    }
    cancelGlide()
  }

  /// The monitor body, separated so tests can drive it without installing a
  /// process-wide monitor. Returns the event AppKit should dispatch, or `nil`
  /// when the notch was folded into a glide.
  func handle(_ event: NSEvent) -> NSEvent? {
    if isSynthetic(event) { return event }
    guard case .boost(let rawDx, let rawDy) = Planner.classify(event) else {
      // A precise, phased or chorded PHYSICAL event ends any glide.
      if event.type == .scrollWheel { cancelGlide() }
      return event
    }
    // No window, or nothing under the pointer, means nothing of ours would
    // receive it: pass through untouched.
    guard let cg = event.cgEvent, let window = windowOf(event), let hit = hitTest(event, window)
    else { return event }
    // The scroll SURFACE, not the leaf under the pointer: a `List` swaps its row
    // views as it scrolls, so two clicks over the same list hit two different
    // leaves, and a fast spin can recycle the stored row (Codex diff review r1).
    // The innermost enclosing scroll view is the one AppKit's responder chain
    // would reach first, nested boxes included.
    let view = hit.enclosingScrollView ?? hit
    logNotch(event)
    #if DEBUG
      tuning = Tuning.fromDefaults()
    #endif
    let dx = tuning.boost(rawDx)
    let dy = tuning.boost(rawDy)
    if reduceMotion() {
      // The whole boosted distance in one step, delivered the same way a glide
      // step is; the physical notch is swallowed either way.
      cancelGlide()
      if let boosted = Planner.makeEvent(template: cg, dx: dx, dy: dy) {
        deliver(boosted, to: view)
        return nil
      }
      return event
    }
    if !glide.isIdle, view !== targetView {
      // A notch over another view, sheet or window: the old remainder belonged
      // to a different scroll view, so it is dropped rather than delivered there.
      cancelGlide()
    }
    template = cg.copy()
    targetWindow = window
    targetView = view
    glide.add(dx: dx, dy: dy, at: now())
    startTimerIfNeeded()
    return nil
  }

  /// One animation frame. Public to the test target only through `@testable`.
  func tick() {
    guard !glide.isIdle, let template else {
      cancelGlide()
      return
    }
    guard !isAppHidden(), let window = targetWindow, isPresentable(window),
      let view = targetView, view.window === window
    else {
      cancelGlide()
      return
    }
    let now = now()
    let forceFlush = reduceMotion() || now - glide.lastNotchAt >= tuning.hardDeadline
    let step = glide.step(at: now, tau: tuning.tau, forceFlush: forceFlush)
    if let event = Planner.makeEvent(template: template, dx: step.dx, dy: step.dy) {
      deliver(event, to: view)
    }
    if step.finished { cancelGlide() }
  }

  /// True only for the event currently being delivered by `deliver`.
  func isSynthetic(_ event: NSEvent) -> Bool {
    delivering == ObjectIdentifier(event)
  }

  private func deliver(_ event: NSEvent, to view: NSView) {
    delivering = ObjectIdentifier(event)
    defer { delivering = nil }
    emit(event, view)
  }

  private func startTimerIfNeeded() {
    guard timer == nil else { return }
    let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func cancelGlide() {
    timer?.invalidate()
    timer = nil
    glide.cancel()
    template = nil
    targetWindow = nil
    targetView = nil
  }

  /// One debug line per launch describing the first physical notch seen, so a
  /// vendor driver whose events differ from the synthetic UAT shape (#3062 spike)
  /// is diagnosable from `app.log` without an Instruments session. Dev builds
  /// log every notch, which is how the tuning above gets its numbers.
  private func logNotch(_ event: NSEvent) {
    #if !DEBUG
      guard !loggedFirstNotch else { return }
    #endif
    let label = loggedFirstNotch ? "wheel notch" : "first wheel notch"
    loggedFirstNotch = true
    let line =
      "\(label) precise=\(event.hasPreciseScrollingDeltas) "
      + "dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY) legacyDy=\(event.deltaY) "
      + "phase=\(event.phase.rawValue) momentum=\(event.momentumPhase.rawValue) "
      + "fixedPt=\(event.cgEvent?.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) ?? .nan) "
      + "point=\(event.cgEvent?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) ?? 0)"
    Task { await AppLogger.shared.log(line, level: .debug, category: "WheelScroll") }
  }
}
