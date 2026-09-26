import ApplicationServices
import EnviousWisprCore
import Foundation

// MARK: - Preparation primitives (#3106 step 1, chunk 2)

/// The ONE cumulative time budget for everything the arrival session reads and registers before
/// the paste is written.
///
/// Before each Accessibility call, `admit(_:)` is asked with the exact handle that call messages:
/// it refuses when the budget is spent, and otherwise installs the REMAINING time as that handle's
/// messaging timeout, so no call ever receives a fresh full bound. A refusal is remembered, and
/// every later call is refused too.
@MainActor
package final class PasteLandingPrepareBudget {

  /// Why a call was refused. Kept apart from any Accessibility answer, so a spent budget is never
  /// mistaken for an unreadable field.
  package enum Refusal: Sendable, Equatable {
    /// The cumulative budget ran out.
    case exhausted
    /// The remaining time could not be installed on the handle, so the call would be unbounded.
    case timeoutNotInstalled
  }

  /// The whole preparation may take this long. The same 0.5 s that bounds the paste path's own
  /// focused-element query and the learn watcher's capture (`PasteService.axMessagingTimeoutSeconds`),
  /// but spent ONCE across every call instead of once per call: a healthy host answers in
  /// milliseconds, so this is a failure bound, not a latency target.
  package static let defaultMs = Int(PasteService.axMessagingTimeoutSeconds * 1000)

  private let totalMs: Int
  private let startMs: Int
  private let scheduler: any PastedRegionScheduling
  private let ax: any PastedRegionAXOperations
  package private(set) var refusal: Refusal?

  package init(
    totalMs: Int = PasteLandingPrepareBudget.defaultMs,
    scheduler: any PastedRegionScheduling, ax: any PastedRegionAXOperations
  ) {
    self.totalMs = totalMs
    self.scheduler = scheduler
    self.ax = ax
    self.startMs = scheduler.nowMs
  }

  /// Milliseconds spent since the budget was created: the log's `before_ms`.
  package var elapsedMs: Int { scheduler.nowMs - startMs }

  /// The preparation's final accounting, sampled ONCE after the last call. Exhausted also when
  /// the last admitted call used up the remaining time: no later admission would ever refuse it,
  /// so `refusal` alone would call a 500 ms preparation complete (final review, #3106).
  package func completedPreparation() -> (elapsedMs: Int, exhausted: Bool) {
    let elapsed = elapsedMs
    return (elapsed, refusal == .exhausted || elapsed >= totalMs)
  }

  /// Whether the next Accessibility call on `handle` may run. Installs the remaining time on that
  /// exact handle first.
  package func admit(_ handle: AXUIElement) -> Bool {
    guard refusal == nil else { return false }
    let remainingMs = totalMs - elapsedMs
    guard remainingMs > 0 else {
      refusal = .exhausted
      return false
    }
    guard ax.setMessagingTimeout(handle, seconds: Double(remainingMs) / 1000) else {
      refusal = .timeoutNotInstalled
      return false
    }
    return true
  }
}

/// The focused element as the arrival session may use it (#3106).
package enum PasteLandingFocus {
  case element(AXUIElement)
  /// The application answered that nothing is focused.
  case noFocus
  /// The query failed, or the element's owner is another process or cannot be read.
  case unreadable
}

/// Whether the field captured when the recording started is in the window that is focused now
/// (#3106): the one fact knowable BEFORE the write that the paste would go to a different window
/// of the same application.
package enum PasteLandingTargetWindow: String, Sendable, CaseIterable {
  case same
  case different
  /// No captured field, a stale one, an absent or non-element answer, a failed call, or a refusal
  /// by the budget.
  case unknown
}

// MARK: - Shared preparation (#3106; owned by the arrival session since PR A)

@MainActor
extension PasteArrivalCapture {

  /// The focused element of `application` (owned by `pid`), read through the budget. Nil when the
  /// budget refused a call.
  ///
  /// The element's own process is checked, as `PasteService.focusedElement` does: an element
  /// another process owns, or one whose owner cannot be read, is `unreadable`, never `noFocus`.
  /// Only a genuine "nothing is focused" answer may later support a `no_target` landing.
  package static func focus(
    of application: AXUIElement, pid: pid_t, ax: any PastedRegionAXOperations,
    budget: PasteLandingPrepareBudget
  ) -> PasteLandingFocus? {
    guard budget.admit(application) else { return nil }
    switch ax.focusedElement(ofApplication: application) {
    case .noFocus: return .noFocus
    case .queryFailed: return .unreadable
    case .element(let element):
      guard budget.admit(element) else { return nil }
      guard let owner = ax.pid(of: element), owner == pid else { return .unreadable }
      return .element(element)
    }
  }

  /// `same` or `different` only when BOTH windows are read as elements; `unknown` otherwise.
  package static func targetWindow(
    captured: AXUIElement?, application: AXUIElement, ax: any PastedRegionAXOperations,
    budget: PasteLandingPrepareBudget
  ) -> PasteLandingTargetWindow {
    guard let captured, budget.admit(captured),
      case .window(let capturedWindow) = ax.window(of: captured),
      budget.admit(application),
      case .window(let focusedWindow) = ax.focusedWindow(of: application)
    else { return .unknown }
    return CFEqual(capturedWindow, focusedWindow) ? .same : .different
  }

  /// The notifications an arrival session needs: value-changed and destroyed on the field plus
  /// focus-changed on the application, or only focus-changed when nothing was focused.
  package static func requiredNotifications(hasElement: Bool) -> Set<PastedRegionAXNotification> {
    hasElement
      ? [.valueChanged, .elementDestroyed, .focusedElementChanged] : [.focusedElementChanged]
  }

  /// The selected text of `text` for a UTF-16 `range`, or nil for any range that is negative,
  /// overflowing, out of bounds, or splits a character's scalars. Never clamped.
  nonisolated package static func selectedText(
    in text: String, range: PastedRegionSelectedRange
  ) -> String? {
    guard case .range(let location, let length) = range, location >= 0, length >= 0 else {
      return nil
    }
    let (end, overflow) = location.addingReportingOverflow(length)
    let units = text.utf16
    guard !overflow, end <= units.count else { return nil }
    let lower = units.index(units.startIndex, offsetBy: location)
    let upper = units.index(units.startIndex, offsetBy: end)
    guard lower.samePosition(in: text.unicodeScalars) != nil,
      upper.samePosition(in: text.unicodeScalars) != nil
    else { return nil }
    return String(text[lower..<upper])
  }

  /// The production DEBUG sink. Release builds log nothing.
  private static let debugLog: @MainActor (String) -> Void = { line in
    #if DEBUG
      Task { await AppLogger.shared.log(line, level: .info, category: "PasteLanding") }
    #endif
  }
}

// MARK: - The arrival session (#3106 PR A)

/// What an arrival session concluded about one key paste: at the first NEW occurrence of the
/// submitted text, or at `PasteLandingPolicy.landingDeadlineMs(bundleID:)` after dispatch (300 ms
/// unless the app is measured slower). Evidence, not
/// policy: `PasteLandingPolicy` decides which results are misses.
package enum PasteArrivalLanding: Sendable, Equatable {
  /// More occurrences of the text than before the write.
  case found(Found)
  /// The same readable field, read the same way, still holds the text as often as before the
  /// write, and nothing (focus, lifetime, an incomplete registration) invalidates the comparison.
  case absent
  /// Nothing was focused before the write and throughout, with the focus notification registered.
  case noTarget
  /// The field could not be read at all: never evidence either way.
  case cannotRead(CannotRead)
  /// Something makes a negative untrustworthy.
  case inconclusive(Inconclusive)

  package enum Found: String, Sendable, CaseIterable {
    /// The field read before the write, through the same reader, holds more occurrences. Nothing
    /// else proves a NEW occurrence: another field may already have held the phrase.
    case sameField = "same_field"
  }

  package enum CannotRead: String, Sendable, CaseIterable {
    case baselineUnreadable = "baseline_unreadable"
    case secureField = "secure_field"
    case unsupported
    case queryFailed = "query_failed"
    case permissionLost = "permission_lost"
  }

  package enum Inconclusive: String, Sendable, CaseIterable {
    case cancelled
    case budgetSpent = "budget_spent"
    case registrationIncomplete = "registration_incomplete"
    case countIncomplete = "count_incomplete"
    case unstable
    case moved
    case readerChanged = "reader_changed"
    case countDecreased = "count_decreased"
    /// The count is unchanged but the field's text is not: an edit the comparison cannot explain.
    case valueChanged = "value_changed"
    case focusChanged = "focus_changed"
    case elementDestroyed = "element_destroyed"
    case selectionUnavailable = "selection_unavailable"
    case selectionOverlap = "selection_overlap"
    case manualAccessibilityUnknown = "manual_accessibility_unknown"
    /// A host that needs the manual-accessibility opt-in answered "no focus" before the write: that
    /// answer can hide a focused field, and a later opt-in does not prove it was true.
    case manualAccessibilityHost = "manual_accessibility_host"
    case appSwitched = "app_switched"
    case appTerminated = "app_terminated"
  }

  /// The closed `observed` vocabulary.
  package var observed: String {
    switch self {
    case .found: "found"
    case .absent: "absent"
    case .noTarget: "no_target"
    case .cannotRead: "cannot_read"
    case .inconclusive: "inconclusive"
    }
  }

  /// The closed `reason` vocabulary; `absent` and `no_target` carry their own name.
  package var reason: String {
    switch self {
    case .found(let found): found.rawValue
    case .absent: "absent"
    case .noTarget: "no_target"
    case .cannotRead(let cause): cause.rawValue
    case .inconclusive(let cause): cause.rawValue
    }
  }
}

/// The late-hit check that follows a potential eligible miss.
package enum PasteArrivalLateCheck: Sendable, Equatable {
  /// The decision was not a potential eligible miss: nothing was watched after it.
  case notApplicable
  /// The shadow ran to `arrivalShadowMs` without seeing the text.
  case completedNoHit
  /// The text appeared after the decision, this many ms after dispatch: the deadline was too short
  /// for this paste.
  case found(ms: Int)
  /// The session ended before the shadow finished.
  case censored

  package var status: String {
    switch self {
    case .notApplicable: "not_applicable"
    case .completedNoHit: "completed_no_hit"
    case .found: "found"
    case .censored: "censored"
    }
  }
}

/// The one terminal observation a committed session reports, as values.
package struct PasteArrivalObservation: Sendable, Equatable {
  package let takeID: String?
  package let tier: String
  package let landing: PasteArrivalLanding
  package let appClass: TelemetryService.LearnFromEditsTelemetry.AppClass
  package let hostExposedFocus: Bool
  package let targetWindow: PasteLandingTargetWindow
  package let beforeMs: Int
  /// Dispatch to the landing decision.
  package let resolveMs: Int
  package let lateCheck: PasteArrivalLateCheck

  package init(
    takeID: String?, tier: String, landing: PasteArrivalLanding,
    appClass: TelemetryService.LearnFromEditsTelemetry.AppClass, hostExposedFocus: Bool,
    targetWindow: PasteLandingTargetWindow, beforeMs: Int, resolveMs: Int,
    lateCheck: PasteArrivalLateCheck
  ) {
    self.takeID = takeID
    self.tier = tier
    self.landing = landing
    self.appClass = appClass
    self.hostExposedFocus = hostExposedFocus
    self.targetWindow = targetWindow
    self.beforeMs = beforeMs
    self.resolveMs = resolveMs
    self.lateCheck = lateCheck
  }
}

/// One key paste's arrival session (#3106 PR A): the ONE post-write reader and retry owner.
///
/// Lifecycle: `prepare` (a factory, synchronously before the write: pre-dispatch baseline, target
/// window and notification registration under one `PasteLandingPrepareBudget`) → `commit()` right
/// after a dispatched write, or `cancelUnlessCommitted()` on every other exit → a landing decision
/// at the first new occurrence or at the deadline → for a potential eligible miss, a late-hit
/// shadow → one report. `cancel()` ends a committed session early. #996 asks the same session for
/// its edit-watch target with `editWatchCapture`, on its own timer.
///
/// Reads never overlap: every read is one synchronous `attemptArrival` on the main actor.
@MainActor
package final class PasteArrivalCapture: PasteEditCapturing {

  /// What the caller knows about the paste being observed.
  package struct Context: Sendable {
    package let tier: PasteTier
    package let pid: pid_t
    /// Carried on the report; never logged.
    package let takeID: String?
    /// Classification only; never telemetry.
    package let bundleID: String?
    /// The text this tier submitted (possibly context-adjusted), which is what the field receives.
    package let payload: String

    package init(tier: PasteTier, pid: pid_t, takeID: String?, bundleID: String?, payload: String) {
      self.tier = tier
      self.pid = pid
      self.takeID = takeID
      self.bundleID = bundleID
      self.payload = payload
    }
  }

  /// The focused field immediately before the write.
  enum Baseline {
    case field(
      element: AXUIElement, reader: PastedRegionTextReader, value: String,
      occurrences: PastedRegionLocator.Occurrences, selection: PastedRegionSelectedRange)
    case noFocus
    case unreadable
  }

  package enum Phase: Sendable, Equatable {
    /// Prepared, not yet written.
    case armed
    /// Written; reading toward the landing decision.
    case watching
    /// Decided a potential eligible miss; reading toward the late-hit horizon.
    case shadowing
    /// Reported, or cancelled before commit. Nothing further happens.
    case finished
  }

  /// The only tiers a session may be prepared for: the three key pastes.
  package static let observedTiers: Set<PasteTier> = [.cgEvent, .appleScript, .menuPaste]

  package let context: Context
  private let application: AXUIElement
  let baseline: Baseline
  private let frontmostBefore: pid_t?
  /// Nil when the question could not be asked or answered: never "does not support it". An
  /// edit-only session asks it at #996's first request instead of before a write.
  private var manualAX: Bool?
  private let hostExposedFocus: Bool
  package let targetWindow: PasteLandingTargetWindow
  private let ax: any PastedRegionAXOperations
  private let scheduler: any PastedRegionScheduling
  private let reader: PastedRegionObserver
  private let reporter: @MainActor (PasteArrivalObservation) -> Void
  private let log: @MainActor (String) -> Void
  private var terminationWaiters: [CheckedContinuation<Void, Never>] = []

  fileprivate(set) var beforeMs = 0
  fileprivate var prepareBudgetExhausted = false
  private var registration: (any PastedRegionAXRegistration)?
  package private(set) var registrationComplete = false
  /// Focus and lifetime notifications invalidate a negative; a value notification only wakes a read.
  private var sawFocusChanged = false
  private var sawElementDestroyed = false
  /// The element focused before the write (nil when nothing was, or it could not be read). A focus
  /// notification naming this element announces no change: Chrome re-posts the unchanged page
  /// focus after a Cmd+V into it (#3152, measured), which must not void a genuine miss.
  private var focusedBefore: AXUIElement?
  /// Focus notifications that named `focusedBefore`: counted, never treated as a move.
  private var focusReannouncements = 0
  /// The destination the decision was made on stayed observable through the shadow. Anything that
  /// loses it (focus, lifetime, app switch, an unreadable or different read) censors the late check:
  /// "no late hit" is claimed only for a field that was actually still being watched.
  private var shadowObservable = true
  /// Explicit cancellation: no later #996 request may read a field a newer paste now owns.
  private var cancelled = false

  package private(set) var phase: Phase = .armed
  private var committedAtMs = 0
  private var generation = 0
  private var manualAccessibilityEnabled = false
  private var manualAccessibilityAttempts = 0
  private static let maxManualAccessibilityAttempts = 3
  private var poll: (any PastedRegionScheduledWork)?
  private var deadline: (any PastedRegionScheduledWork)?
  private var shadowEnd: (any PastedRegionScheduledWork)?
  package private(set) var landing: PasteArrivalLanding?
  private var resolveMs = 0
  private var lateCheck: PasteArrivalLateCheck = .notApplicable
  private var reported = false
  private var landingWaiters: [CheckedContinuation<PasteArrivalLanding?, Never>] = []

  /// #996's request: one per session, on its own timer.
  private var editRequest: EditRequest?
  private var wasCommitted = false
  /// Test signals from the subject itself: a waiter joined, and #996's request made one read.
  package var onLandingWaiter: (@MainActor () -> Void)?
  package var onEditAttempt: (@MainActor () -> Void)?

  private init(
    context: Context, application: AXUIElement, baseline: Baseline, frontmostBefore: pid_t?,
    manualAX: Bool?, hostExposedFocus: Bool, targetWindow: PasteLandingTargetWindow,
    ax: any PastedRegionAXOperations, scheduler: any PastedRegionScheduling,
    reporter: @escaping @MainActor (PasteArrivalObservation) -> Void,
    log: @escaping @MainActor (String) -> Void
  ) {
    self.context = context
    self.application = application
    self.baseline = baseline
    self.frontmostBefore = frontmostBefore
    self.manualAX = manualAX
    self.hostExposedFocus = hostExposedFocus
    self.targetWindow = targetWindow
    self.ax = ax
    self.scheduler = scheduler
    self.reader = PastedRegionObserver(ax: ax, scheduler: scheduler)
    self.reporter = reporter
    self.log = log
  }

  /// The destination's class from the bundle id and the manual-accessibility answer snapshotted at
  /// prepare. With that answer unread, a browser is still a browser; anything else is `other`.
  package var appClass: TelemetryService.LearnFromEditsTelemetry.AppClass {
    guard let manualAX else {
      let byBundle = PasteLandingAppClass.classify(
        bundleIdentifier: context.bundleID, isManualAccessibilityHost: false)
      return byBundle == .browser ? .browser : .other
    }
    return PasteLandingAppClass.classify(
      bundleIdentifier: context.bundleID, isManualAccessibilityHost: manualAX)
  }

  // MARK: Prepare

  /// Prepares and arms a session, synchronously, immediately before the paste command. Nil for a
  /// tier this session does not observe. Never enables manual accessibility: the baseline is what
  /// the destination exposes as it is. A spent budget or an incomplete count is recorded and only
  /// ever weakens the later verdict; it never delays the write.
  /// - Parameter restoringCapturedTimeoutTo: the messaging timeout `capturedTarget` carried
  ///   before preparation, put back once preparation ends (the delivery path's own handle; an
  ///   observer may not change what it observes).
  package static func prepare(
    _ context: Context, capturedTarget: AXUIElement?,
    restoringCapturedTimeoutTo restoreSeconds: Double,
    ax: any PastedRegionAXOperations, scheduler: any PastedRegionScheduling,
    report: @escaping @MainActor (PasteArrivalObservation) -> Void = PasteArrivalCapture.liveReport,
    log: (@MainActor (String) -> Void)? = nil
  ) -> PasteArrivalCapture? {
    guard observedTiers.contains(context.tier) else { return nil }
    let budget = PasteLandingPrepareBudget(scheduler: scheduler, ax: ax)
    let application = ax.applicationElement(pid: context.pid)
    let frontmostBefore = ax.frontmostPID()
    let manualAX: Bool? =
      budget.admit(application) ? ax.supportsManualAccessibility(application) : nil

    var element: AXUIElement?
    let baseline: Baseline
    switch Self.focus(of: application, pid: context.pid, ax: ax, budget: budget) {
    case nil, .unreadable?:
      baseline = .unreadable
    case .noFocus?:
      baseline = .noFocus
    case .element(let focused)?:
      element = focused
      baseline = baselineField(focused, payload: context.payload, ax: ax, budget: budget)
    }
    let targetWindow = Self.targetWindow(
      captured: capturedTarget, application: application, ax: ax, budget: budget)

    let session = PasteArrivalCapture(
      context: context, application: application, baseline: baseline,
      frontmostBefore: frontmostBefore, manualAX: manualAX,
      hostExposedFocus: capturedTarget != nil, targetWindow: targetWindow,
      ax: ax, scheduler: scheduler, reporter: report, log: log ?? Self.debugLog)
    session.arm(element: element, budget: budget)
    let finished = budget.completedPreparation()
    session.beforeMs = finished.elapsedMs
    session.prepareBudgetExhausted = finished.exhausted
    if let capturedTarget { _ = ax.setMessagingTimeout(capturedTarget, seconds: restoreSeconds) }
    return session
  }

  /// Tier 1 (AX direct) wrote the field itself, so there is no key paste to observe: no baseline,
  /// no registration, no deadline, shadow, report or log line. The session exists only so #996 asks
  /// the SAME owner for its edit-watch capture as after a key paste (a fresh read, its own 1.5 s),
  /// with `payload` the text that route actually submitted. Created only after a delivered write.
  package static func editOnly(
    pid: pid_t, bundleID: String?, payload: String, ax: any PastedRegionAXOperations,
    scheduler: any PastedRegionScheduling
  ) -> PasteArrivalCapture {
    let session = PasteArrivalCapture(
      context: .init(tier: .axDirect, pid: pid, takeID: nil, bundleID: bundleID, payload: payload),
      application: ax.applicationElement(pid: pid), baseline: .unreadable, frontmostBefore: nil,
      manualAX: nil, hostExposedFocus: false, targetWindow: .unknown, ax: ax, scheduler: scheduler,
      reporter: { _ in }, log: { _ in })
    session.wasCommitted = true
    session.phase = .finished
    return session
  }

  /// A secure, unreadable, over-limit or refused field is `unreadable`; otherwise its text's
  /// occurrence count (possibly incomplete), the reader that produced it, and the selection.
  private static func baselineField(
    _ element: AXUIElement, payload: String, ax: any PastedRegionAXOperations,
    budget: PasteLandingPrepareBudget
  ) -> Baseline {
    guard budget.admit(element) else { return .unreadable }
    if SelectionReader.isSecureField(ax.subrole(of: element)) { return .unreadable }
    // AXValue first, the range reader only for an absent or non-text value: the same order as
    // every capture, so the reader recorded here is the one a later attempt will use.
    var reader = PastedRegionTextReader.value
    guard
      var read = PastedRegionObserver.readText(
        of: element, using: reader, ax: ax, admit: budget.admit)
    else { return .unreadable }
    if read == .absent || read == .notText {
      reader = .range
      guard
        let ranged = PastedRegionObserver.readText(
          of: element, using: reader, ax: ax, admit: budget.admit)
      else { return .unreadable }
      read = ranged
    }
    guard case .text(let text) = read else { return .unreadable }
    let selection: PastedRegionSelectedRange =
      budget.admit(element) ? ax.selectedRange(of: element) : .unavailable
    return .field(
      element: element, reader: reader, value: text,
      occurrences: PastedRegionLocator.occurrences(ofPasted: payload, in: text),
      selection: selection)
  }

  /// Registers the notifications before the write. A partial registration is kept, so teardown
  /// invalidates exactly what succeeded; the verdict treats it as incomplete.
  private func arm(element: AXUIElement?, budget: PasteLandingPrepareBudget) {
    focusedBefore = element
    let generation = self.generation
    registration = ax.registerLanding(
      pid: context.pid, element: element, application: application, admit: budget.admit,
      handler: { [weak self] notification, named in
        self?.notified(notification, named: named, generation: generation)
      })
    let required = Self.requiredNotifications(hasElement: element != nil)
    registrationComplete =
      registration.map { required.isSubset(of: $0.registeredNotifications) } ?? false
  }

  // MARK: Commit, cancel, wakeups

  /// The write was dispatched: start reading. Idempotent; a cancelled session stays cancelled.
  package func commit() {
    guard phase == .armed else { return }
    phase = .watching
    wasCommitted = true
    committedAtMs = scheduler.nowMs
    // No Accessibility call here: `commit` runs on the delivery path, before the clipboard restore
    // is scheduled. The manual-accessibility opt-in happens at the first read instead.
    let generation = self.generation
    deadline = scheduler.schedule(
      afterMs: PasteLandingPolicy.landingDeadlineMs(bundleID: context.bundleID)
    ) { [weak self] in
      guard let self, generation == self.generation else { return }
      self.decideAtDeadline()
    }
    schedulePoll()
  }

  /// Every exit that is not a dispatched write. Silent: nothing was written, nothing is reported.
  package func cancelUnlessCommitted() {
    guard phase == .armed else { return }
    finish()
  }

  /// Ends a committed session early (app quit, a superseding paste). Before the decision the
  /// landing is `inconclusive(cancelled)`; after it the decision stands and the late check is
  /// censored. Exactly one report either way.
  package func cancel() {
    cancelled = true
    if let request = editRequest { resolveEditRequest(request, .ended(.captureUnsupported)) }
    switch phase {
    case .armed:
      cancelUnlessCommitted()
    case .watching:
      publish(.inconclusive(.cancelled))
      lateCheck = .censored
      complete()
    case .shadowing:
      lateCheck = .censored
      complete()
    case .finished:
      break
    }
  }

  /// The landing decision; nil for a session that was never committed. Concurrent callers share
  /// one decision.
  package func landingDecision() async -> PasteArrivalLanding? {
    if let landing { return landing }
    if phase == .finished || phase == .armed { return nil }
    return await withCheckedContinuation { continuation in
      landingWaiters.append(continuation)
      onLandingWaiter?()
    }
  }

  /// The manual-accessibility opt-in, before a read. Asked behind the reader's own guards and
  /// bound (a query behind a failed timeout could block the main actor); an edit-only session, or
  /// a key paste whose preparation could not ask, asks the support question here. Success is
  /// recorded only when the write succeeds: a host too busy to answer is asked again at a later
  /// read, up to `maxManualAccessibilityAttempts` bounded attempts per session.
  private func enableManualAccessibilityIfNeeded() {
    guard !manualAccessibilityEnabled, manualAX != false,
      manualAccessibilityAttempts < Self.maxManualAccessibilityAttempts,
      ax.isTrusted(), ax.isProcessRunning(context.pid), ax.frontmostPID() == context.pid,
      ax.setMessagingTimeout(application, seconds: PasteService.axMessagingTimeoutSeconds)
    else { return }
    manualAccessibilityAttempts += 1
    if manualAX == nil { manualAX = ax.supportsManualAccessibility(application) }
    guard manualAX == true else { return }
    manualAccessibilityEnabled = ax.enableManualAccessibility(application)
  }

  private func notified(
    _ notification: PastedRegionAXNotification, named: AXUIElement, generation: Int
  ) {
    guard generation == self.generation, phase != .finished else { return }
    switch notification {
    case .focusedElementChanged:
      // Only an element OTHER than the pre-write focus is a move. A move away and back still
      // counts: the notification naming the other element set the flag, and nothing clears it.
      if let focusedBefore, CFEqual(named, focusedBefore) {
        focusReannouncements += 1
      } else {
        sawFocusChanged = true
        if phase == .shadowing { shadowObservable = false }
      }
    case .elementDestroyed:
      sawElementDestroyed = true
      if phase == .shadowing { shadowObservable = false }
    case .valueChanged: break
    }
    // Every notification is a reason to look, never an answer by itself.
    if phase == .watching || phase == .shadowing { read() }
  }

  private func schedulePoll() {
    poll?.cancel()
    let generation = self.generation
    poll = scheduler.schedule(afterMs: PastedRegionTiming.arrivalPollMs) { [weak self] in
      guard let self, generation == self.generation,
        self.phase == .watching || self.phase == .shadowing
      else { return }
      self.read()
      if self.phase == .watching || self.phase == .shadowing { self.schedulePoll() }
    }
  }

  // MARK: Reading

  /// One read. A new occurrence ends the watch at once (before the decision: `found`; during the
  /// shadow: a late hit). Anything else waits for the next wakeup.
  private func read() {
    enableManualAccessibilityIfNeeded()
    let attempt = reader.attemptArrival(pid: context.pid, pastedText: context.payload)
    guard let found = newOccurrence(in: attempt) else {
      if phase == .shadowing, !stillObservable(attempt) { shadowObservable = false }
      return
    }
    switch phase {
    case .watching:
      publish(.found(found))
      complete()
    case .shadowing:
      lateCheck = .found(ms: scheduler.nowMs - committedAtMs)
      complete()
    case .armed, .finished:
      break
    }
  }

  /// `found` only when the field read before the write, through the same reader, now holds more
  /// occurrences by a complete count. A different element, a changed reader, an incomplete count,
  /// or no readable baseline proves nothing new: that field may already have held the phrase.
  private func newOccurrence(in attempt: PastedRegionArrivalAttempt) -> PasteArrivalLanding.Found? {
    guard case .readable(let field) = attempt, case .complete(let hits) = field.occurrences,
      case .field(let element, let reader, _, .complete(let before), _) = baseline,
      CFEqual(element, field.element), field.reader == reader, hits.count > before.count
    else { return nil }
    return .sameField
  }

  /// Whether a shadow read still sees the destination the decision was made on.
  private func stillObservable(_ attempt: PastedRegionArrivalAttempt) -> Bool {
    switch (baseline, attempt) {
    case (.field(let element, let reader, _, _, _), .readable(let field)):
      // A read that could not finish counting did not look everywhere.
      guard case .complete = field.occurrences else { return false }
      return CFEqual(element, field.element) && field.reader == reader
    case (.noFocus, .noFocus):
      return true
    default:
      return false
    }
  }

  // MARK: The decision

  /// The deadline passed without a new occurrence: one bounded final read, then the negative rules.
  private func decideAtDeadline() {
    guard phase == .watching else { return }
    enableManualAccessibilityIfNeeded()
    let attempt = reader.attemptArrival(pid: context.pid, pastedText: context.payload)
    if let found = newOccurrence(in: attempt) {
      publish(.found(found))
      complete()
      return
    }
    let decision = negative(from: attempt)
    shadowObservable = stillObservable(attempt)
    publish(decision)
    if PasteLandingPolicy.isMiss(decision, appClass: appClass) {
      startShadow()
    } else {
      complete()
    }
  }

  /// What a final read with no new occurrence is worth. Only a comparison nothing invalidates may
  /// become `absent` or `noTarget`; every doubt is `inconclusive`, every unreadable answer
  /// `cannotRead`.
  private func negative(from attempt: PastedRegionArrivalAttempt) -> PasteArrivalLanding {
    // Whole-app causes first: every check below only asks whether a comparison can be trusted, and
    // must not hide that the app quit, lost the front, or took back our permission.
    if !ax.isProcessRunning(context.pid) { return .inconclusive(.appTerminated) }
    if ax.frontmostPID() != frontmostBefore { return .inconclusive(.appSwitched) }
    if case .permissionLost = attempt { return .cannotRead(.permissionLost) }
    if prepareBudgetExhausted { return .inconclusive(.budgetSpent) }
    switch baseline {
    case .unreadable:
      return .cannotRead(.baselineUnreadable)
    case .noFocus:
      guard registrationComplete else { return .inconclusive(.registrationIncomplete) }
      if sawFocusChanged { return .inconclusive(.focusChanged) }
      // An Electron host that was never opted in answers "no focus" while a field has it; when
      // whether this is such a host is unknown, "nothing focused" cannot be trusted either.
      guard manualAX != nil else { return .inconclusive(.manualAccessibilityUnknown) }
      // A host that needs the opt-in (a Chromium browser, which counts as a browser miss) may hide
      // a focused field until opted in, and even an opt-in that succeeds after the write does not
      // prove its pre-write "no focus" or expose the field at once. Never no_target.
      if manualAX == true { return .inconclusive(.manualAccessibilityHost) }
      switch attempt {
      case .noFocus: return .noTarget
      case .permissionLost: return .cannotRead(.permissionLost)
      case .appTerminated: return .inconclusive(.appTerminated)
      case .destinationMismatch: return .inconclusive(.appSwitched)
      case .readable, .unstable, .secureField, .unsupported, .queryFailed:
        // Something focused now that was not before, without the text: not a clean no-target.
        return .inconclusive(.moved)
      }
    case .field(let element, let reader, let beforeValue, let before, let selection):
      guard registrationComplete else { return .inconclusive(.registrationIncomplete) }
      if sawFocusChanged { return .inconclusive(.focusChanged) }
      if sawElementDestroyed { return .inconclusive(.elementDestroyed) }
      guard manualAX != nil else { return .inconclusive(.manualAccessibilityUnknown) }
      switch attempt {
      case .readable(let field):
        guard CFEqual(field.element, element) else { return .inconclusive(.moved) }
        guard field.reader == reader else { return .inconclusive(.readerChanged) }
        guard case .complete(let beforeHits) = before,
          case .complete(let afterHits) = field.occurrences
        else { return .inconclusive(.countIncomplete) }
        if afterHits.count < beforeHits.count { return .inconclusive(.countDecreased) }
        // Equal counts. The field must also be byte-identical (UTF-16 units, never `String ==`,
        // which equates canonically equivalent text): any other edit means the comparison no
        // longer describes only this paste.
        guard field.value.utf16.elementsEqual(beforeValue.utf16) else {
          return .inconclusive(.valueChanged)
        }
        // With none before, the text simply is not there. With some before, a paste over a
        // selection holding an identical occurrence leaves the field identical whether or not it
        // arrived, so a VALID selection must rule that out.
        guard !beforeHits.isEmpty else { return .absent }
        guard case .range(let location, let length) = selection,
          PasteArrivalCapture.selectedText(in: beforeValue, range: selection) != nil
        else { return .inconclusive(.selectionUnavailable) }
        // Validated above: non-negative, no overflow, in bounds, on scalar boundaries.
        let overlaps =
          length > 0
          && beforeHits.contains { hit in
            hit.start < location + length && location < hit.end
          }
        return overlaps ? .inconclusive(.selectionOverlap) : .absent
      case .unstable: return .inconclusive(.unstable)
      case .noFocus: return .inconclusive(.moved)
      case .destinationMismatch: return .inconclusive(.appSwitched)
      case .appTerminated: return .inconclusive(.appTerminated)
      case .secureField: return .cannotRead(.secureField)
      case .unsupported: return .cannotRead(.unsupported)
      case .queryFailed: return .cannotRead(.queryFailed)
      case .permissionLost: return .cannotRead(.permissionLost)
      }
    }
  }

  private func startShadow() {
    phase = .shadowing
    deadline?.cancel()
    deadline = nil
    let generation = self.generation
    let remaining = max(0, PastedRegionTiming.arrivalShadowMs - (scheduler.nowMs - committedAtMs))
    shadowEnd = scheduler.schedule(afterMs: remaining) { [weak self] in
      guard let self, generation == self.generation, self.phase == .shadowing else { return }
      self.lateCheck = self.shadowObservable ? .completedNoHit : .censored
      self.complete()
    }
  }

  // MARK: Publication and teardown

  /// Fixes the landing decision once and releases everyone waiting for it.
  private func publish(_ decision: PasteArrivalLanding) {
    guard landing == nil else { return }
    landing = decision
    resolveMs = scheduler.nowMs - committedAtMs
    let waiters = landingWaiters
    landingWaiters = []
    for waiter in waiters { waiter.resume(returning: decision) }
  }

  /// The session's end after a commit: exactly one report, then teardown.
  private func complete() {
    guard !reported, let landing else {
      finish()
      return
    }
    reported = true
    let observation = PasteArrivalObservation(
      takeID: context.takeID, tier: context.tier.rawValue, landing: landing, appClass: appClass,
      hostExposedFocus: hostExposedFocus, targetWindow: targetWindow, beforeMs: beforeMs,
      resolveMs: resolveMs, lateCheck: lateCheck)
    log(logLine(observation))
    reporter(observation)
    finish()
  }

  /// Shape only: no text, selection, window title or take id. The UAT harness reads this line.
  private func logLine(_ o: PasteArrivalObservation) -> String {
    var line =
      "PASTE_LANDING tier=\(o.tier) observed=\(o.landing.observed) reason=\(o.landing.reason) "
      + "app=\(context.bundleID ?? "unknown") app_class=\(o.appClass.rawValue) "
      + "host_exposed_focus=\(o.hostExposedFocus) manual_ax=\(manualAX.map(String.init) ?? "unknown") "
      + "target_window=\(o.targetWindow.rawValue) before_ms=\(o.beforeMs) resolve_ms=\(o.resolveMs) "
      + "late_check=\(o.lateCheck.status)"
    if case .found(let ms) = o.lateCheck { line += " late_found_ms=\(ms)" }
    return line + " focus_reannounced=\(focusReannouncements)"
  }

  /// The production reporter: the vendor event.
  package static let liveReport: @MainActor (PasteArrivalObservation) -> Void = { o in
    var lateFoundMs: Int?
    if case .found(let ms) = o.lateCheck { lateFoundMs = ms }
    TelemetryService.shared.pasteLandingObserved(
      takeID: o.takeID, tier: o.tier, observed: o.landing.observed, reason: o.landing.reason,
      appClass: o.appClass.rawValue, hostExposedFocus: o.hostExposedFocus,
      targetWindow: o.targetWindow.rawValue, beforeMs: o.beforeMs, resolveMs: o.resolveMs,
      lateCheckStatus: o.lateCheck.status, lateFoundMs: lateFoundMs)
  }

  /// Returns once the session has finished: reported, or cancelled before commit. The one thing an
  /// off-path owner awaits to keep a committed session alive through its whole shadow (its timers
  /// hold it weakly).
  package func terminated() async {
    guard phase != .finished else { return }
    await withCheckedContinuation { continuation in terminationWaiters.append(continuation) }
  }

  /// Invalidates the registration and every timer once, silences queued callbacks, and releases
  /// every waiter. #996's request keeps its own timer and ends on its own terms.
  private func finish() {
    guard phase != .finished else { return }
    phase = .finished
    generation += 1
    registration?.invalidate()
    registration = nil
    poll?.cancel()
    poll = nil
    deadline?.cancel()
    deadline = nil
    shadowEnd?.cancel()
    shadowEnd = nil
    let waiters = landingWaiters
    landingWaiters = []
    for waiter in waiters { waiter.resume(returning: landing) }
    let terminated = terminationWaiters
    terminationWaiters = []
    for waiter in terminated { waiter.resume() }
  }
}

// MARK: - #996's edit-watch capture

extension PasteArrivalCapture {

  /// #996's one request, timed from its FIRST ask rather than from dispatch: the watcher asks only
  /// after its own gates (the toggle, a judge, the frontmost app), which can take longer than the
  /// landing shadow.
  final class EditRequest {
    let startedAtMs: Int
    let pastedAtMs: Int
    var result: PastedRegionCaptureOutcome?
    var last: PastedRegionCaptureOutcome = .ended(.dictatedTextNotFound)
    var waiters: [CheckedContinuation<PastedRegionCaptureOutcome, Never>] = []
    var retry: (any PastedRegionScheduledWork)?

    init(startedAtMs: Int, pastedAtMs: Int) {
      self.startedAtMs = startedAtMs
      self.pastedAtMs = pastedAtMs
    }
  }

  /// The edit-watch target for #996, read through this session's reader: a FRESH read at the
  /// request (an early landing target is never reused unchecked), then retries every
  /// `arrivalPollMs` for up to `arrivalShadowMs` while the answer is "not there yet" (no new
  /// occurrence, no focus, unstable), exactly the two answers the watcher's old grace retried.
  /// The target is the NEW occurrence only: when it cannot be told apart from an older identical
  /// one the answer is `anchorAmbiguous`, never a watch on the older text. Concurrent callers share
  /// one answer.
  package func editWatchCapture(pastedAtMs: Int) async -> PastedRegionCaptureOutcome {
    // First: a cancelled session hands out nothing, not even an answer it already has (a newer
    // paste may own that field now).
    guard !cancelled else { return .ended(.captureUnsupported) }
    if let request = editRequest {
      if let result = request.result { return result }
      return await withCheckedContinuation { continuation in request.waiters.append(continuation) }
    }
    // Never committed: nothing was pasted, nothing to capture.
    guard wasCommitted else { return .ended(.captureUnsupported) }
    let request = EditRequest(startedAtMs: scheduler.nowMs, pastedAtMs: pastedAtMs)
    editRequest = request
    return await withCheckedContinuation { continuation in
      request.waiters.append(continuation)
      stepEditRequest(request)
    }
  }

  package func cancelEditWatchCapture() {
    guard let request = editRequest else { return }
    resolveEditRequest(request, .ended(.captureUnsupported))
  }

  private func stepEditRequest(_ request: EditRequest) {
    guard request.result == nil else { return }
    // Before every attempt, like the landing reads: a failed opt-in is asked again (bounded).
    enableManualAccessibilityIfNeeded()
    let (outcome, retryable) = editAttempt(pastedAtMs: request.pastedAtMs)
    request.last = outcome
    onEditAttempt?()
    let elapsed = scheduler.nowMs - request.startedAtMs
    guard retryable, elapsed < PastedRegionTiming.arrivalShadowMs else {
      resolveEditRequest(request, outcome)
      return
    }
    let wait = min(PastedRegionTiming.arrivalPollMs, PastedRegionTiming.arrivalShadowMs - elapsed)
    request.retry = scheduler.schedule(afterMs: wait) { [weak self, weak request] in
      guard let self, let request else { return }
      self.stepEditRequest(request)
    }
  }

  private func resolveEditRequest(_ request: EditRequest, _ outcome: PastedRegionCaptureOutcome) {
    guard request.result == nil else { return }
    request.result = outcome
    request.retry?.cancel()
    request.retry = nil
    let waiters = request.waiters
    request.waiters = []
    // The outcome holds Accessibility handles (not `Sendable`), so resuming several waiters with
    // it is a region-checker error. Every waiter is a main-actor caller of `editWatchCapture` and
    // the handles are only ever used on the main actor, so sharing the value is safe (the pattern `HALDeviceInputSource`
    // uses for its audio buffers).
    nonisolated(unsafe) let shared = outcome
    for waiter in waiters { waiter.resume(returning: shared) }
  }

  /// One read projected onto the watcher's capture answers, and whether it may be retried.
  private func editAttempt(pastedAtMs: Int) -> (PastedRegionCaptureOutcome, retryable: Bool) {
    switch reader.attemptArrival(pid: context.pid, pastedText: context.payload) {
    case .readable(let field):
      guard case .complete(let hits) = field.occurrences else {
        return (.ended(.captureUnsupported), false)
      }
      switch newRegion(in: field, hits: hits) {
      case .notYet:
        return (.ended(.dictatedTextNotFound), true)
      case .ambiguous(let why):
        #if DEBUG
          let line = "arrival_ambiguous_probe \(why) value_utf16=\(field.value.utf16.count)"
          Task { await AppLogger.shared.log(line, level: .info, category: "LearnFromEdits") }
        #endif
        return (.ended(.anchorAmbiguous), false)
      case .region(let hit):
        return (
          .captured(
            PastedRegionTarget(
              pid: context.pid, application: field.application, element: field.element,
              pastedText: context.payload, renderedText: hit.text,
              anchors: PastedRegionLocator.anchors(
                around: hit.start, end: hit.end, in: field.value),
              isManualAccessibilityHost: field.manualAccessibility ?? false,
              pastedAtMs: pastedAtMs, reader: field.reader)),
          false
        )
      }
    case .unstable: return (.ended(.dictatedTextNotFound), true)
    case .noFocus: return (.skipped(.noFocusedElement), true)
    case .secureField: return (.skipped(.secureField), false)
    case .destinationMismatch: return (.skipped(.destinationMismatch), false)
    case .unsupported: return (.ended(.captureUnsupported), false)
    case .queryFailed(let error):
      return (.ended(PastedRegionObserver.endReason(forQueryFailure: error)), false)
    case .permissionLost: return (.ended(.permissionLost), false)
    case .appTerminated: return (.ended(.appTerminated), false)
    }
  }

  private enum NewRegion {
    case notYet
    /// Which rule refused, as counts only (#3105 probe; logged in DEBUG builds).
    case ambiguous(String)
    case region(PastedRegionLocator.Located)
  }

  /// Which occurrence is the one this paste added.
  ///
  /// With a comparable baseline (the same element, the same reader, a complete count): no more
  /// occurrences than before is "not yet", more than one more is ambiguous, and exactly one more
  /// must be SHOWN to be new: the pre-write selection is where the paste went, and the value must
  /// read as the old text with the paste inserted there. When that cannot be shown (no valid
  /// selection, or other edits), the two alignments of the changed span must agree on one
  /// occurrence. A caret is never used: it could point at an older identical occurrence.
  ///
  /// The one exception to "proven new": without a comparable baseline (another element, another
  /// reader, an incomplete count, no readable field before) a SINGLE occurrence is watched, as the
  /// watcher's capture always did. That keeps #996's behaviour; it does not prove the occurrence is
  /// this paste's, and several occurrences there are ambiguous.
  private func newRegion(
    in field: PastedRegionReadableField, hits: [PastedRegionLocator.Located]
  ) -> NewRegion {
    guard
      case .field(
        let element, let reader, let beforeValue, .complete(let beforeHits), let selection) =
        baseline,
      CFEqual(element, field.element), field.reader == reader
    else {
      switch hits.count {
      case 0: return .notYet
      case 1: return .region(hits[0])
      default:
        let why: String
        switch baseline {
        case .noFocus: why = "baseline_no_focus"
        case .unreadable: why = "baseline_unreadable"
        case .field(_, _, _, .complete, _): why = "baseline_other_field_or_reader"
        case .field: why = "baseline_incomplete"
        }
        return .ambiguous("rule=\(why) hits=\(hits.count)")
      }
    }
    guard hits.count > beforeHits.count else { return .notYet }
    guard hits.count == beforeHits.count + 1 else {
      return .ambiguous("rule=hit_count hits=\(hits.count) before_hits=\(beforeHits.count)")
    }
    let before = Array(beforeValue.utf16)
    let after = Array(field.value.utf16)
    if case .range(let location, let length) = selection,
      PasteArrivalCapture.selectedText(in: beforeValue, range: selection) != nil
    {
      // The old text before the selection, then the insertion, then the old text after it.
      let tail = before.count - (location + length)
      let insertedEnd = after.count - tail
      if insertedEnd >= location, after.count >= tail,
        after[..<location].elementsEqual(before[..<location]),
        after[insertedEnd...].elementsEqual(before[(location + length)...]),
        let inserted = hits.first(where: { $0.start >= location && $0.end <= insertedEnd }),
        hits.filter({ $0.start >= location && $0.end <= insertedEnd }).count == 1
      {
        return .region(inserted)
      }
    }
    // Both alignments of the changed span: common prefix first, then common suffix first.
    let limit = min(before.count, after.count)
    let prefix = zip(before, after).prefix(while: ==).count
    let suffixAfterPrefix = zip(before.reversed(), after.reversed()).prefix(while: ==).count
    let suffix = min(suffixAfterPrefix, limit - prefix)
    let prefixAfterSuffix = min(prefix, limit - suffixAfterPrefix)
    let spans = [
      (prefix, after.count - suffix),
      (prefixAfterSuffix, after.count - suffixAfterPrefix),
    ]
    let picks = spans.map { span in hits.filter { $0.start >= span.0 && $0.end <= span.1 } }
    if picks.allSatisfy({ $0.count == 1 }), picks[0][0].start == picks[1][0].start {
      return .region(picks[0][0])
    }
    return .ambiguous(
      "rule=changed_span hits=\(hits.count) before_hits=\(beforeHits.count) "
        + "picks=\(picks[0].count),\(picks[1].count) before_utf16=\(before.count) "
        + "prefix=\(prefix) suffix=\(suffixAfterPrefix)")
  }
}
